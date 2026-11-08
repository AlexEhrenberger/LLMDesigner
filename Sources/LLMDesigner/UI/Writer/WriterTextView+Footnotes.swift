import AppKit
import SwiftUI

/// A footnote in the text: a raised number where the note belongs, stored as Pandoc's `^[Text]`. The number is
/// counted in document order, so inserting or deleting a note renumbers the others. Never changed in place: an edit
/// puts a new attachment there.
final class WriterFootnoteAttachment: NSTextAttachment {
    private(set) var text = ""

    convenience init(text: String) {
        self.init(data: nil, ofType: nil)
        self.text = text
    }

    override init(data contentData: Data?, ofType uti: String?) {
        super.init(data: contentData, ofType: uti)
        attachmentCell = WriterFootnoteCell()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        attachmentCell = WriterFootnoteCell()
    }

    var markdown: String { WriterFootnotes.markdown(text) }
}

extension WriterTextView {
    // MARK: Numbers

    /// Each footnote's number, in the order of the text.
    func countFootnotes() -> [ObjectIdentifier: Int] {
        guard let storage = textStorage else { return [:] }
        var numbers: [ObjectIdentifier: Int] = [:]
        storage.enumerateAttribute(.attachment, in: NSRange(location: 0, length: storage.length)) { value, _, _ in
            guard let note = value as? WriterFootnoteAttachment else { return }
            numbers[ObjectIdentifier(note)] = numbers.count + 1
        }
        return numbers
    }

    /// The number of this footnote; one that came in since the last count is counted now.
    func footnoteNumber(of note: WriterFootnoteAttachment) -> Int {
        if let number = footnoteNumbers[ObjectIdentifier(note)] { return number }
        return countFootnotes()[ObjectIdentifier(note)] ?? 1
    }

    /// After an edit: when notes came, went or moved, every note is laid out again with its new number.
    func footnotesChanged() {
        let numbers = countFootnotes()
        guard numbers != footnoteNumbers else { return }
        footnoteNumbers = numbers
        guard let storage = textStorage, let layoutManager else { return }
        storage.enumerateAttribute(.attachment, in: NSRange(location: 0, length: storage.length)) { value, range, _ in
            guard value is WriterFootnoteAttachment else { return }
            layoutManager.invalidateLayout(forCharacterRange: range, actualCharacterRange: nil)
            layoutManager.invalidateDisplay(forCharacterRange: range)
        }
    }

    // MARK: Inserting

    /// ⌥⌘F and the toolbar: asks for the note's text and puts the number after the selection (or at the caret).
    func newFootnote() {
        guard slideLayout == nil, let storage = textStorage else { return }
        if let location = footnoteAtCaret {
            editFootnote(at: location)
            return
        }
        let block = WriterStyler.block(in: storage, at: min(selectedRange().location, max(0, storage.length - 1)))
        guard storage.length == 0 || !(block == .code || block == .raw || block.isEmbed) else {
            onNotice?("Fußnoten gehören in den Text, nicht in Code, Bilder oder Formeln.")
            return
        }
        let range = citationInsertionPoint
        let caret = firstRect(forCharacterRange: range, actualRange: nil)
        let anchor = window.map { convert($0.convertFromScreen(caret), from: nil) } ?? NSRect(x: 0, y: 0, width: 1, height: 1)
        showFootnoteEditor(text: "", number: nil, relativeTo: NSRect(x: anchor.minX, y: anchor.minY, width: max(1, anchor.width), height: max(1, anchor.height))) { [weak self] text in
            guard let self, let text, !text.isEmpty else { return }
            self.insertFootnote(text, at: range)
        }
    }

    /// A footnote with this text at `range` (a caret), as one undoable change.
    func insertFootnote(_ text: String, at range: NSRange) {
        guard let storage = textStorage, NSMaxRange(range) <= storage.length else { return }
        let note = NSMutableAttributedString(attachment: WriterFootnoteAttachment(text: text))
        // The note takes the passage's font and colour, but no underline, strike or link (see WriterMarkdown).
        var attributes = typingAttributes.filter {
            [.writerBold, .writerItalic, .writerBlock, .writerListLevel, .writerBookmark, .writerColor, .writerFont, .writerFontSize,
             .writerComment, .paragraphStyle, .font, .foregroundColor].contains($0.key) || WriterMarkdown.tableKeys.contains($0.key)
                || WriterMarkdown.paragraphKeys.contains($0.key) || WriterMarkdown.containerKeys.contains($0.key)
        }
        if range.location > 0 {
            for (key, value) in storage.attributes(at: range.location - 1, effectiveRange: nil)
            where WriterMarkdown.paragraphKeys.contains(key) || WriterMarkdown.containerKeys.contains(key) || WriterMarkdown.passageKeys.contains(key) {
                attributes[key] = value
            }
        }
        note.addAttributes(attributes, range: NSRange(location: 0, length: note.length))
        window?.makeFirstResponder(self)
        performStructureEdit(in: range, with: note)
        setSelectedRange(NSRange(location: range.location + 1, length: 0))
        undoManager?.setActionName("Fußnote")
        footnotesChanged()
    }

    // MARK: Changing a footnote

    func footnote(at location: Int) -> WriterFootnoteAttachment? {
        guard let storage = textStorage, location >= 0, location < storage.length else { return nil }
        return storage.attribute(.attachment, at: location, effectiveRange: nil) as? WriterFootnoteAttachment
    }

    /// The footnote right before the caret or selected on its own.
    var footnoteAtCaret: Int? {
        let range = selectedRange()
        if range.length == 1, footnote(at: range.location) != nil { return range.location }
        if range.length == 0, footnote(at: range.location - 1) != nil { return range.location - 1 }
        return nil
    }

    /// Replaces the footnote's text (an empty text removes it), as one undoable change.
    func replaceFootnote(at location: Int, with text: String) {
        guard let storage = textStorage, footnote(at: location) != nil else { return }
        let range = NSRange(location: location, length: 1)
        if text.isEmpty {
            performStructureEdit(in: range, with: NSAttributedString())
            setSelectedRange(NSRange(location: location, length: 0))
        } else {
            let note = NSMutableAttributedString(attachment: WriterFootnoteAttachment(text: text))
            var attributes = storage.attributes(at: location, effectiveRange: nil)
            attributes.removeValue(forKey: .attachment)
            note.addAttributes(attributes, range: NSRange(location: 0, length: 1))
            performStructureEdit(in: range, with: note)
            setSelectedRange(NSRange(location: location + 1, length: 0))
        }
        undoManager?.setActionName(text.isEmpty ? "Fußnote entfernen" : "Fußnote")
        footnotesChanged()
    }

    /// A click on the number: the note's text, to read and change.
    func editFootnote(at location: Int) {
        guard let note = footnote(at: location), let frame = attachmentFrame(at: location) else { return }
        showFootnoteEditor(text: note.text, number: footnoteNumber(of: note), relativeTo: frame) { [weak self] text in
            guard let self, let text, self.footnote(at: location) === note else { return }
            self.replaceFootnote(at: location, with: text)
        }
    }

    /// `number`: the note being changed; nil for a new one.
    private func showFootnoteEditor(text: String, number: Int?, relativeTo rect: NSRect, onDone: @escaping (String?) -> Void) {
        let popover = NSPopover()
        popover.behavior = .transient
        let editor = FootnoteEditor(text: text, number: number, isNew: number == nil) { [weak self, weak popover] result in
            popover?.close()
            self?.window?.makeFirstResponder(self)
            onDone(result.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) })
        }
        popover.contentViewController = NSHostingController(rootView: editor)
        popover.show(relativeTo: rect, of: self, preferredEdge: .maxY)
    }

    func footnoteMenuItems(at location: Int) -> [NSMenuItem] {
        guard let note = footnote(at: location) else { return [] }
        let edit = ClosureMenuItem(title: "Fußnote \(footnoteNumber(of: note)) bearbeiten …") { [weak self] in self?.editFootnote(at: location) }
        edit.image = NSImage(systemSymbolName: "pencil", accessibilityDescription: nil)
        let remove = ClosureMenuItem(title: "Fußnote entfernen") { [weak self] in self?.replaceFootnote(at: location, with: "") }
        remove.image = NSImage(systemSymbolName: "trash", accessibilityDescription: nil)
        return [edit, remove, .separator()]
    }

    /// The footnote under a point (for the context menu).
    func footnoteLocation(at point: NSPoint) -> Int? {
        guard let layoutManager, let container = textContainer else { return nil }
        let inContainer = NSPoint(x: point.x - textContainerOrigin.x, y: point.y - textContainerOrigin.y)
        let glyph = layoutManager.glyphIndex(for: inContainer, in: container)
        let location = layoutManager.characterIndexForGlyph(at: glyph)
        guard footnote(at: location) != nil, let frame = attachmentFrame(at: location), frame.insetBy(dx: -3, dy: -3).contains(point) else { return nil }
        return location
    }

    /// A footnote item for the "Einfügen" part of the context menu.
    func footnoteInsertMenuItem() -> NSMenuItem {
        let item = ClosureMenuItem(title: "Fußnote einfügen …") { [weak self] in self?.newFootnote() }
        item.image = NSImage(systemSymbolName: "textformat.superscript", accessibilityDescription: nil)
        return item
    }
}

// MARK: - Drawing

/// The footnote's number, raised and smaller, in the accent colour so it reads as something to click.
final class WriterFootnoteCell: NSTextAttachmentCell {
    private var lastSize = NSSize(width: 8, height: 12)
    private var lastBaseline: CGFloat = 0
    private var label = "1"
    private var numberFont = NSFont.systemFont(ofSize: 9)

    private var note: WriterFootnoteAttachment? { attachment as? WriterFootnoteAttachment }

    private static func textFont(_ storage: NSTextStorage?, _ index: Int, _ view: WriterTextView?) -> NSFont {
        if let storage, index < storage.length, let font = storage.attribute(.font, at: index, effectiveRange: nil) as? NSFont { return font }
        return WriterStyler.font(view?.family ?? .serif, size: WriterStyler.bodySize(view?.family ?? .serif), italic: false)
    }

    override func cellFrame(for textContainer: NSTextContainer, proposedLineFragment lineFrag: NSRect, glyphPosition position: NSPoint, characterIndex charIndex: Int) -> NSRect {
        let view = textContainer.textView as? WriterTextView
        label = note.flatMap { note in view.map { String($0.footnoteNumber(of: note)) } } ?? "1"
        let text = Self.textFont(textContainer.layoutManager?.textStorage, charIndex, view)
        numberFont = NSFont(descriptor: text.fontDescriptor, size: text.pointSize * 0.62) ?? text
        let width = (label as NSString).size(withAttributes: [.font: numberFont]).width
        lastSize = NSSize(width: ceil(width) + 2, height: ceil(numberFont.ascender - numberFont.descender))
        // Raised like a superscript: the small number's baseline sits at about 40 % of the text's cap height.
        lastBaseline = floor(text.capHeight * 0.42 + numberFont.descender)
        return NSRect(x: 0, y: lastBaseline, width: lastSize.width, height: lastSize.height)
    }

    override func cellSize() -> NSSize { lastSize }
    override func cellBaselineOffset() -> NSPoint { NSPoint(x: 0, y: lastBaseline) }

    override func draw(withFrame cellFrame: NSRect, in controlView: NSView?) {
        draw(cellFrame, view: controlView as? WriterTextView, characterIndex: nil)
    }

    override func draw(withFrame cellFrame: NSRect, in controlView: NSView?, characterIndex charIndex: Int, layoutManager: NSLayoutManager) {
        draw(cellFrame, view: controlView as? WriterTextView, characterIndex: charIndex)
    }

    private func draw(_ frame: NSRect, view: WriterTextView?, characterIndex: Int?) {
        let palette = view?.palette ?? .dark
        let isSelected = characterIndex.map { view?.selectedRange() == NSRange(location: $0, length: 1) } ?? false
        if isSelected {
            palette.accent.withAlphaComponent(0.25).setFill()
            NSBezierPath(roundedRect: frame.insetBy(dx: -1, dy: 0), xRadius: 3, yRadius: 3).fill()
        }
        let text = NSAttributedString(string: label, attributes: [.font: numberFont, .foregroundColor: palette.accent])
        let size = text.size()
        text.draw(at: NSPoint(x: frame.minX + (frame.width - size.width) / 2, y: frame.minY))
    }

    override func wantsToTrackMouse() -> Bool { true }

    override func wantsToTrackMouse(for theEvent: NSEvent, in cellFrame: NSRect, of controlView: NSView?, atCharacterIndex charIndex: Int) -> Bool { true }

    override func trackMouse(with theEvent: NSEvent, in cellFrame: NSRect, of controlView: NSView?, atCharacterIndex charIndex: Int, untilMouseUp flag: Bool) -> Bool {
        guard let view = controlView as? WriterTextView else { return false }
        view.window?.makeFirstResponder(view)
        view.setSelectedRange(NSRange(location: charIndex, length: 1))
        view.editFootnote(at: charIndex)
        return true
    }
}

// MARK: - Editing a footnote

/// The note's text; Markdown inside it (*kursiv*, **fett**, Formeln, Quellenangaben) is kept.
private struct FootnoteEditor: View {
    @State var text: String
    let number: Int?
    let isNew: Bool
    let onDone: (String?) -> Void
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(isNew ? "Neue Fußnote" : number.map { "Fußnote \($0)" } ?? "Fußnote")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Theme.textPrimary)
            TextEditor(text: $text)
                .font(.system(size: 13))
                .scrollContentBackground(.hidden)
                .padding(6)
                .background(RoundedRectangle(cornerRadius: 6).fill(Theme.ink.opacity(0.05)))
                .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Theme.border))
                .frame(height: 96)
                .focused($focused)
            Text("Steht im PDF unten auf der Seite. Markdown wie *kursiv* bleibt erhalten.")
                .font(.system(size: 11))
                .foregroundStyle(Theme.textTertiary)
            HStack {
                if !isNew {
                    Button("Entfernen", role: .destructive) { onDone("") }
                }
                Spacer()
                Button("Abbrechen") { onDone(nil) }
                    .keyboardShortcut(.cancelAction)
                Button(isNew ? "Einfügen" : "Übernehmen") { onDone(text) }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.return, modifiers: .command)
                    .disabled(isNew && text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(16)
        .frame(width: 380)
        .onAppear { focused = true }
    }
}
