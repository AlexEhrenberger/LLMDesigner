import AppKit
import SwiftUI

/// ⌘F (or ⌃F) in Writer and Presenter Studio: finds a word or passage in the open document, or on every slide and
/// speaker card of a presentation. Every place found is marked and the current one stands out; ↩ and ⌘G go on to
/// the next, also onto other slides. Closing the bar selects the current place, so the writing goes on there.
@MainActor
@Observable
final class DocumentFind {
    enum Command {
        case show, next, previous
    }

    struct Match: Equatable {
        enum Place: Int {
            case text, notes
        }
        /// The slide, in a presentation.
        var slideID: PresentationSlide.ID?
        var place: Place
        var range: NSRange
    }

    /// Where a place is in reading order: the slide, its text before its card, then the position.
    private struct Position: Comparable {
        var slide: Int
        var place: Match.Place
        var location: Int

        static func < (a: Position, b: Position) -> Bool {
            (a.slide, a.place.rawValue, a.location) < (b.slide, b.place.rawValue, b.location)
        }
    }

    var isShown = false
    var query = "" {
        didSet { if query != oldValue { search(reveal: true) } }
    }
    var options = TextSearch.Options() {
        didSet { if options != oldValue { search(reveal: true) } }
    }
    /// Presentations: the speaker cards are searched too.
    var searchesNotes = true {
        didSet { if searchesNotes != oldValue { search(reveal: true) } }
    }
    /// Set by Presenter Studio.
    var isPresentation = false
    private(set) var matches: [Match] = []
    private(set) var current: Int?
    /// How many places each slide has (text and card), for the slide list.
    private(set) var countsBySlide: [PresentationSlide.ID: Int] = [:]
    /// Changes whenever the field should take the keyboard, also when the bar is already open.
    private(set) var focusRequest = 0

    @ObservationIgnored weak var controller: WriterEditorController?
    @ObservationIgnored weak var field: NSTextField?
    /// The speaker card shown below the slide, and its slide.
    @ObservationIgnored private weak var notesView: NSTextView?
    @ObservationIgnored private var notesSlideID: PresentationSlide.ID?
    /// The text of every slide as the editor shows it, made once per version of the slide.
    @ObservationIgnored private var slideTexts: [PresentationSlide.ID: (markdown: String, text: String)] = [:]
    @ObservationIgnored private var slideOrder: [PresentationSlide.ID: Int] = [:]
    /// Where the search starts while the query is typed: the caret (or the slide) when the bar opened, later the
    /// place shown.
    @ObservationIgnored private var anchor: Position?
    /// A place on another slide or on the hidden card is shown once it is there; true selects it.
    @ObservationIgnored private var pendingReveal: Bool?
    @ObservationIgnored private var pendingChange: Task<Void, Never>?

    private var app: AppModel? { controller?.app }

    var currentMatch: Match? {
        current.flatMap { matches.indices.contains($0) ? matches[$0] : nil }
    }

    /// The field has the keyboard: a slide that is loaded doesn't take it.
    var fieldHasFocus: Bool { field?.currentEditor() != nil }

    func count(on slideID: PresentationSlide.ID) -> Int {
        isShown ? countsBySlide[slideID] ?? 0 : 0
    }

    /// "3 von 12", "Keine Treffer", or nothing before anything is typed.
    var status: String {
        guard !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return "" }
        guard !matches.isEmpty else { return "Keine Treffer" }
        let total = matches.count >= TextSearch.limit ? "\(TextSearch.limit)+" : "\(matches.count)"
        guard let current else { return "\(total) Treffer" }
        return "\(current + 1) von \(total)"
    }

    /// Presentations: where the current place is.
    var placeDescription: String? {
        guard let match = currentMatch, let slideID = match.slideID, let index = slideOrder[slideID] else { return nil }
        return match.place == .notes ? "Karte \(index + 1)" : "Folie \(index + 1)"
    }

    func perform(_ command: Command) {
        switch command {
        case .show: show()
        case .next: step(by: 1)
        case .previous: step(by: -1)
        }
    }

    // MARK: Opening and closing

    /// Opens the bar (or puts the keyboard back into it). A short selection becomes the query.
    func show() {
        let selection = selectionToFind()
        if let selection {
            anchor = selection.position
        } else if !isShown || editingPosition() != nil {
            anchor = startPosition()
        }
        isShown = true
        focusRequest += 1
        if let text = selection?.text, text != query {
            query = text
        } else {
            search(reveal: true)
        }
    }

    /// Closes the bar; the current place becomes the selection, with the keyboard.
    func close() {
        guard isShown else { return }
        isShown = false
        pendingChange?.cancel()
        pendingReveal = nil
        let match = currentMatch
        controller?.textView?.setFindMatches([], current: nil)
        markNotes()
        guard let match, let controller else { return }
        if match.place == .text, match.slideID == controller.editedSlideID {
            controller.textView?.selectFindMatch(match.range)
        } else if match.place == .notes, match.slideID == notesSlideID, let notesView {
            notesView.window?.makeFirstResponder(notesView)
            notesView.setSelectedRange(match.range)
            notesView.scrollRangeToVisible(match.range)
        } else {
            controller.focus()
        }
    }

    // MARK: Going from place to place

    /// ↩ and ⌘G (backwards with ⇧). From the text it goes on from the caret and selects the place found; with the
    /// bar closed it does that too, without marks.
    private func step(by offset: Int) {
        guard !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return show() }
        let caret = editingPosition()
        refresh()
        guard !matches.isEmpty else { return NSSound.beep() }
        let index: Int
        if let caret {
            index = offset > 0
                ? matches.firstIndex { position(of: $0) > caret } ?? 0
                : matches.lastIndex { position(of: $0) < caret } ?? matches.count - 1
        } else if let current {
            index = (current + offset + matches.count) % matches.count
        } else {
            index = offset > 0 ? 0 : matches.count - 1
        }
        current = index
        anchor = position(of: matches[index])
        apply(reveal: true, select: caret != nil || !isShown)
    }

    // MARK: Following the text

    /// The text was edited: the places are found anew a moment later, without scrolling.
    func textChanged() {
        guard isShown, !query.isEmpty else { return }
        pendingChange?.cancel()
        pendingChange = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(200))
            guard let self, !Task.isCancelled, self.isShown else { return }
            if let match = self.currentMatch { self.anchor = self.position(of: match) }
            self.refresh()
            self.apply(reveal: false)
        }
    }

    /// Presentations: a slide or card changed elsewhere (the model wrote it, a slide moved).
    func deckChanged() {
        textChanged()
    }

    /// A document or slide was put into the editor (called while SwiftUI updates it, so the marks follow right after).
    func textLoaded() {
        DispatchQueue.main.async { [weak self] in
            guard let self, self.isShown || self.pendingReveal != nil, !self.query.isEmpty else { return }
            let reveal = self.pendingReveal
            self.pendingReveal = nil
            if reveal == nil, self.isPresentation, let match = self.currentMatch, match.slideID != self.controller?.shownSlideID {
                // Another slide was chosen: the search goes on from there.
                self.anchor = self.startPosition()
            } else if let match = self.currentMatch {
                self.anchor = self.position(of: match)
            }
            self.refresh()
            self.apply(reveal: reveal != nil, select: reveal == true)
        }
    }

    /// The speaker card's text view, with its slide (again after every slide change).
    func attachNotes(_ view: NSTextView, slideID: PresentationSlide.ID) {
        notesView = view
        notesSlideID = slideID
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.markNotes()
            if let select = self.pendingReveal, let match = self.currentMatch, match.place == .notes, match.slideID == slideID {
                self.pendingReveal = nil
                self.revealNotes(match, select: select)
            }
        }
    }

    // MARK: Finding

    private func search(reveal: Bool) {
        refresh()
        apply(reveal: reveal && isShown)
    }

    /// Finds all places and picks the current one: the first at or after the anchor.
    private func refresh() {
        matches = collectMatches()
        if isPresentation {
            var counts: [PresentationSlide.ID: Int] = [:]
            for match in matches {
                if let id = match.slideID { counts[id, default: 0] += 1 }
            }
            if counts != countsBySlide { countsBySlide = counts }
        }
        guard !matches.isEmpty else { current = nil; return }
        if let anchor {
            current = matches.firstIndex { position(of: $0) >= anchor } ?? 0
        } else {
            current = 0
        }
    }

    private func collectMatches() -> [Match] {
        guard !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, let controller, let textView = controller.textView,
              let storage = textView.textStorage else { return [] }
        guard isPresentation, let deck = app?.selectedPresentation?.deck else {
            return TextSearch.ranges(of: query, in: storage.string, options: options).map { Match(slideID: nil, place: .text, range: $0) }
        }
        var result: [Match] = []
        slideOrder = [:]
        for (index, slide) in deck.slides.enumerated() {
            slideOrder[slide.id] = index
            // The open slide as it is being written; the others as the editor would show them.
            let text = slide.id == controller.editedSlideID ? storage.string : slideText(slide)
            result += TextSearch.ranges(of: query, in: text, options: options).map { Match(slideID: slide.id, place: .text, range: $0) }
            if searchesNotes {
                let notes = slide.id == notesSlideID ? notesView?.string ?? slide.notes : slide.notes
                result += TextSearch.ranges(of: query, in: notes, options: options).map { Match(slideID: slide.id, place: .notes, range: $0) }
            }
            if result.count >= TextSearch.limit { break }
        }
        slideTexts = slideTexts.filter { slideOrder[$0.key] != nil }
        return result
    }

    private func slideText(_ slide: PresentationSlide) -> String {
        if let cached = slideTexts[slide.id], cached.markdown == slide.markdown { return cached.text }
        let text = WriterMarkdown.attributedString(from: slide.markdown).string
        slideTexts[slide.id] = (slide.markdown, text)
        return text
    }

    private func position(of match: Match) -> Position {
        Position(slide: match.slideID.flatMap { slideOrder[$0] } ?? 0, place: match.place, location: match.range.location)
    }

    private var shownSlideIndex: Int {
        guard let id = controller?.shownSlideID else { return 0 }
        return slideOrder[id] ?? app?.selectedPresentation?.deck?.index(of: id) ?? 0
    }

    /// A document is searched from the caret, a presentation from the top of the open slide.
    private func startPosition() -> Position {
        guard !isPresentation, let textView = controller?.textView else { return Position(slide: shownSlideIndex, place: .text, location: 0) }
        return Position(slide: 0, place: .text, location: textView.selectedRange().location)
    }

    /// Where the caret is, when the keyboard is in the text or on the card.
    private func editingPosition() -> Position? {
        guard let textView = controller?.textView, let responder = textView.window?.firstResponder else { return nil }
        if responder === textView {
            return Position(slide: shownSlideIndex, place: .text, location: textView.selectedRange().location)
        }
        if let notesView, responder === notesView, notesSlideID == controller?.shownSlideID {
            return Position(slide: shownSlideIndex, place: .notes, location: notesView.selectedRange().location)
        }
        return nil
    }

    /// A short selection on one line, in the text or on the card.
    private func selectionToFind() -> (text: String, position: Position)? {
        guard let textView = controller?.textView, let responder = textView.window?.firstResponder else { return nil }
        let view: NSTextView
        let place: Match.Place
        if responder === textView {
            view = textView
            place = .text
        } else if let notesView, responder === notesView {
            view = notesView
            place = .notes
        } else {
            return nil
        }
        let range = view.selectedRange()
        guard range.length > 0, range.length <= 120 else { return nil }
        let text = (view.string as NSString).substring(with: range)
        guard !text.contains(where: \.isNewline), !text.contains("\u{FFFC}"), !text.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
        return (text, Position(slide: shownSlideIndex, place: place, location: range.location))
    }

    // MARK: Showing

    /// Marks the places in the text and on the card; `reveal` brings the current one into view (loading its slide
    /// or opening the card first), `select` also selects it there.
    private func apply(reveal: Bool, select: Bool = false) {
        guard let controller, let textView = controller.textView else { return }
        let shown = controller.editedSlideID
        let match = currentMatch
        if isShown {
            let here = matches.filter { $0.place == .text && $0.slideID == shown }.map(\.range)
            let current = match.flatMap { $0.place == .text && $0.slideID == shown ? $0.range : nil }
            textView.setFindMatches(here, current: current)
        } else {
            textView.setFindMatches([], current: nil)
        }
        markNotes()
        guard reveal || select, let match else { return }
        if let slideID = match.slideID, slideID != shown {
            pendingReveal = select
            app?.selectSlide(slideID)
            return
        }
        switch match.place {
        case .text:
            if select { textView.selectFindMatch(match.range) } else { textView.revealFindMatch(match.range) }
        case .notes:
            if let app, !app.presenterNotesVisible {
                pendingReveal = select
                withAnimation(.spring(response: 0.35, dampingFraction: 0.88)) { app.presenterNotesVisible = true }
                return
            }
            revealNotes(match, select: select)
        }
    }

    private func revealNotes(_ match: Match, select: Bool) {
        guard let notesView, notesSlideID == match.slideID, NSMaxRange(match.range) <= (notesView.string as NSString).length else {
            // The card shows another slide for a moment longer.
            pendingReveal = select
            return
        }
        if select {
            notesView.window?.makeFirstResponder(notesView)
            notesView.setSelectedRange(match.range)
        }
        notesView.scrollRangeToVisible(match.range)
    }

    private func markNotes() {
        guard let notesView, let layoutManager = notesView.layoutManager else { return }
        let length = (notesView.string as NSString).length
        let all = NSRange(location: 0, length: length)
        layoutManager.removeTemporaryAttribute(.backgroundColor, forCharacterRange: all)
        layoutManager.removeTemporaryAttribute(.foregroundColor, forCharacterRange: all)
        guard isShown, searchesNotes else { return }
        let current = currentMatch
        for match in matches where match.place == .notes && match.slideID == notesSlideID && NSMaxRange(match.range) <= length {
            let isCurrent = match == current
            layoutManager.addTemporaryAttribute(.backgroundColor, value: isCurrent ? FindColors.current : FindColors.other(onLight: false), forCharacterRange: match.range)
            if isCurrent {
                layoutManager.addTemporaryAttribute(.foregroundColor, value: FindColors.currentText, forCharacterRange: match.range)
            }
        }
    }
}

// MARK: - Bar

/// The find bar: field, "3 von 12", previous and next, options, close.
struct DocumentFindBar: View {
    @Bindable var find: DocumentFind

    var body: some View {
        HStack(spacing: 2) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Theme.textTertiary)
                .padding(.leading, 11)
                .padding(.trailing, 5)
            FindField(find: find, placeholder: find.isPresentation ? "In der Präsentation suchen" : "Im Dokument suchen")
                .frame(width: 190)
            if !find.status.isEmpty {
                HStack(spacing: 5) {
                    Text(find.status)
                        .foregroundStyle(find.matches.isEmpty ? Theme.danger : Theme.textSecondary)
                    if let place = find.placeDescription {
                        Text(place)
                            .foregroundStyle(Theme.textTertiary)
                    }
                }
                .font(.system(size: 11.5).monospacedDigit())
                .lineLimit(1)
                .fixedSize()
                .padding(.horizontal, 4)
            }
            Rectangle()
                .fill(Theme.border)
                .frame(width: 1, height: 16)
                .padding(.horizontal, 4)
            IconButton(systemName: "chevron.up", help: "Vorheriger Treffer (⇧⌘G oder ⇧↩)", size: 11.5, frameSize: 26) { find.perform(.previous) }
                .disabled(find.matches.isEmpty)
            IconButton(systemName: "chevron.down", help: "Nächster Treffer (⌘G oder ↩)", size: 11.5, frameSize: 26) { find.perform(.next) }
                .disabled(find.matches.isEmpty)
            optionsMenu
            IconButton(systemName: "xmark", help: "Suche schließen (esc)", size: 11, frameSize: 26) { find.close() }
        }
        .padding(.trailing, 5)
        .frame(height: 38)
        .background(RoundedRectangle(cornerRadius: 11, style: .continuous).fill(Theme.elevated))
        .overlay(RoundedRectangle(cornerRadius: 11, style: .continuous).strokeBorder(Theme.strongBorder))
        .shadow(color: .black.opacity(0.45), radius: 16, y: 6)
    }

    private var hasOptions: Bool {
        find.options.matchesCase || find.options.wholeWords || (find.isPresentation && !find.searchesNotes)
    }

    private var optionsMenu: some View {
        Menu {
            Toggle("Groß- und Kleinschreibung beachten", isOn: $find.options.matchesCase)
            Toggle("Nur ganze Wörter", isOn: $find.options.wholeWords)
            if find.isPresentation {
                Divider()
                Toggle("Moderatorenkarten durchsuchen", isOn: $find.searchesNotes)
            }
        } label: {
            Image(systemName: "textformat")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(hasOptions ? Theme.accent : Theme.textSecondary)
                .frame(width: 26, height: 26)
                .contentShape(Rectangle())
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Suchoptionen")
    }
}

/// The query field: ↩ goes to the next place, ⇧↩ to the previous one, esc closes the bar.
private struct FindField: NSViewRepresentable {
    let find: DocumentFind
    let placeholder: String

    func makeCoordinator() -> Coordinator { Coordinator(find: find) }

    func makeNSView(context: Context) -> NSTextField {
        let field = FindTextField()
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.font = .systemFont(ofSize: 13)
        field.textColor = NSColor(Theme.textPrimary)
        field.usesSingleLineMode = true
        field.lineBreakMode = .byClipping
        field.cell?.isScrollable = true
        field.cell?.wraps = false
        field.placeholderAttributedString = NSAttributedString(
            string: placeholder,
            attributes: [.foregroundColor: NSColor(Theme.textTertiary), .font: NSFont.systemFont(ofSize: 13)]
        )
        field.stringValue = find.query
        field.delegate = context.coordinator
        find.field = field
        return field
    }

    func updateNSView(_ field: NSTextField, context: Context) {
        context.coordinator.find = find
        find.field = field
        if field.stringValue != find.query { field.stringValue = find.query }
        if context.coordinator.focusRequest != find.focusRequest {
            context.coordinator.focusRequest = find.focusRequest
            (field as? FindTextField)?.takeFocus()
        }
    }

    /// Takes the keyboard as soon as it is in the window: a bar that just appeared isn't yet.
    final class FindTextField: NSTextField {
        private var wantsFocus = false

        func takeFocus() {
            wantsFocus = true
            DispatchQueue.main.async { [weak self] in self?.focusIfPossible() }
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            DispatchQueue.main.async { [weak self] in self?.focusIfPossible() }
        }

        private func focusIfPossible() {
            guard wantsFocus, let window else { return }
            wantsFocus = false
            if currentEditor() == nil { window.makeFirstResponder(self) }
            currentEditor()?.selectAll(nil)
        }
    }

    @MainActor
    final class Coordinator: NSObject, NSTextFieldDelegate {
        var find: DocumentFind
        var focusRequest = -1

        init(find: DocumentFind) {
            self.find = find
        }

        func controlTextDidChange(_ notification: Notification) {
            guard let field = notification.object as? NSTextField else { return }
            // Pasted text with line breaks is searched as one line.
            find.query = field.stringValue.components(separatedBy: .newlines).joined(separator: " ")
        }

        func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
            switch selector {
            case #selector(NSResponder.insertNewline(_:)), #selector(NSResponder.insertNewlineIgnoringFieldEditor(_:)):
                find.perform(NSApp.currentEvent?.modifierFlags.contains(.shift) == true ? .previous : .next)
                return true
            case #selector(NSResponder.cancelOperation(_:)):
                find.close()
                return true
            default:
                return false
            }
        }
    }
}
