import AppKit
import SwiftUI

/// A citation in the text: one object that reads "(LeCun u. a., 2015, S. 436)" in the current style and is
/// stored as Pandoc's `[@lecun2015, S. 436]`. Never changed in place: an edit puts a new attachment there.
final class WriterCitationAttachment: NSTextAttachment {
    private(set) var items: [CitationItem] = []

    convenience init(items: [CitationItem]) {
        self.init(data: nil, ofType: nil)
        self.items = items
    }

    override init(data contentData: Data?, ofType uti: String?) {
        super.init(data: contentData, ofType: uti)
        attachmentCell = WriterCitationCell()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        attachmentCell = WriterCitationCell()
    }

    var markdown: String { CitationMarkup.markdown(items) }
}

/// The reference list in the text (block `.toc`, like the table of contents): every source the document cites,
/// in APA order. Markdown: `[Literatur]`.
final class WriterBibliographyAttachment: NSTextAttachment {
    static let marker = "[Literatur]"

    static func isMarker(_ line: String) -> Bool {
        line.trimmingCharacters(in: .whitespaces) == marker
    }

    override init(data contentData: Data?, ofType uti: String?) {
        super.init(data: contentData, ofType: uti)
        attachmentCell = WriterBibliographyCell()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        attachmentCell = WriterBibliographyCell()
    }
}

/// How a quote goes into the text.
enum CitationInsertion {
    /// Only the reference: (Autor, Jahr, S. x).
    case reference
    /// The exact words in quotation marks with the reference; from 40 words on a block quote (APA).
    case verbatim
    /// The own words with the reference.
    case paraphrase
}

extension WriterTextView {
    // MARK: The style of this document

    /// The keys the document cites, in order.
    var citedKeys: [String] {
        guard let storage = textStorage else { return [] }
        var keys: [String] = []
        storage.enumerateAttribute(.attachment, in: NSRange(location: 0, length: storage.length)) { value, _, _ in
            guard let citation = value as? WriterCitationAttachment else { return }
            for item in citation.items where !keys.contains(where: { $0.caseInsensitiveCompare(item.key) == .orderedSame }) {
                keys.append(item.key)
            }
        }
        return keys
    }

    /// The citation style for the document as it is now (year letters depend on what is cited).
    var citationStyle: CitationStyle {
        if let cached = citationStyleCache { return cached }
        let style = CitationStyle(sources: citations?.sources ?? [], cited: citedKeys)
        citationStyleCache = style
        return style
    }

    /// After an edit: when the cited sources changed, the citations and the reference list are laid out anew.
    func citationsChanged(force: Bool = false) {
        let keys = citedKeys
        guard force || keys != lastCitedKeys else { return }
        lastCitedKeys = keys
        citationStyleCache = nil
        guard let storage = textStorage, let layoutManager else { return }
        storage.enumerateAttribute(.attachment, in: NSRange(location: 0, length: storage.length)) { value, range, _ in
            guard value is WriterCitationAttachment || value is WriterBibliographyAttachment else { return }
            layoutManager.invalidateLayout(forCharacterRange: range, actualCharacterRange: nil)
            layoutManager.invalidateDisplay(forCharacterRange: range)
        }
    }

    // MARK: Inserting

    /// Where a citation goes: citations never replace what is selected. After a selection inside a paragraph,
    /// before one that reaches over a paragraph's end or a picture.
    var citationInsertionPoint: NSRange {
        guard let storage = textStorage else { return NSRange(location: 0, length: 0) }
        let range = selectedRange()
        guard range.length > 0 else { return range }
        let selected = (storage.string as NSString).substring(with: range)
        let crosses = selected.contains("\n") || selected.contains("\u{FFFC}")
        return NSRange(location: crosses ? range.location : NSMaxRange(range), length: 0)
    }

    /// A citation at the caret, inside the text.
    func insertCitation(_ items: [CitationItem]) {
        guard let storage = textStorage, !items.isEmpty else { return }
        let range = citationInsertionPoint
        let text = NSMutableAttributedString()
        // "Text(Autor, 2020)" reads badly: a space before it when the text runs right up to it.
        if range.location > 0, let before = (storage.string as NSString).substring(with: NSRange(location: range.location - 1, length: 1)).first,
           before.isLetter || before.isNumber || before == "“" || before == "." {
            text.append(NSAttributedString(string: " "))
        }
        text.append(NSAttributedString(attachment: WriterCitationAttachment(items: items)))
        replaceInline(range, with: text)
        undoManager?.setActionName("Quellenangabe")
    }

    /// A quote from Citation Studio: as a reference, word for word, or in the user's own words.
    func insertQuote(_ quote: CitationQuote, source: CitationSource, as insertion: CitationInsertion) {
        let item = CitationItem(key: source.citekey, locator: quote.locator)
        let exact = quote.exactText.trimmingCharacters(in: .whitespacesAndNewlines)
        let paraphrase = quote.paraphrase.trimmingCharacters(in: .whitespacesAndNewlines)
        switch insertion {
        case .reference:
            insertCitation([item])
        case .verbatim where exact.split(whereSeparator: \.isWhitespace).count >= 40:
            // From 40 words on APA sets a block quote, without quotation marks.
            let block = NSMutableAttributedString(string: exact.replacingOccurrences(of: "\n", with: " ") + " ")
            block.append(NSAttributedString(attachment: WriterCitationAttachment(items: [item])))
            block.append(NSAttributedString(string: "\n"))
            block.addAttributes([.writerBlock: WriterBlock.quote.rawValue, .writerListLevel: 0], range: NSRange(location: 0, length: block.length))
            setSelectedRange(citationInsertionPoint)
            guard let start = insertBlock(block) else { return }
            setSelectedRange(NSRange(location: start + block.length, length: 0))
            undoManager?.setActionName("Zitat")
        case .verbatim, .paraphrase:
            let words = insertion == .verbatim || paraphrase.isEmpty ? "„\(exact.isEmpty ? paraphrase : exact)“" : paraphrase
            guard let storage = textStorage else { return }
            let range = citationInsertionPoint
            let text = NSMutableAttributedString()
            if range.location > 0, let before = (storage.string as NSString).substring(with: NSRange(location: range.location - 1, length: 1)).first,
               !before.isWhitespace, before != "\n", before != WriterMarkdown.lineSeparator {
                text.append(NSAttributedString(string: " "))
            }
            text.append(NSAttributedString(string: words + " "))
            text.append(NSAttributedString(attachment: WriterCitationAttachment(items: [item])))
            replaceInline(range, with: text)
            undoManager?.setActionName(insertion == .verbatim ? "Zitat" : "Paraphrase")
        }
    }

    /// Puts inline content in place of `range` with the formatting at the caret (bold, a link, the block).
    private func replaceInline(_ range: NSRange, with text: NSMutableAttributedString) {
        guard let storage = textStorage else { return }
        var attributes = typingAttributes.filter {
            [.writerBold, .writerItalic, .underlineStyle, .strikethroughStyle, .writerBlock, .writerListLevel, .writerBookmark, .writerColor, .writerFont].contains($0.key)
                || WriterMarkdown.tableKeys.contains($0.key)
        }
        attributes.removeValue(forKey: .writerCode)
        text.addAttributes(attributes, range: NSRange(location: 0, length: text.length))
        window?.makeFirstResponder(self)
        breakUndoCoalescing()
        guard shouldChangeText(in: range, replacementString: text.string) else { return }
        storage.replaceCharacters(in: range, with: text)
        didChangeText()
        setSelectedRange(NSRange(location: range.location + text.length, length: 0))
        citationsChanged()
        onStateChange?()
    }

    /// The reference list below the current paragraph (or where the caret's empty paragraph is).
    func insertBibliography() {
        if let existing = firstLocation(of: WriterBibliographyAttachment.self) {
            selectEmbed(at: existing)
            scrollRangeToVisible(NSRange(location: existing, length: 1))
            onNotice?("Das Dokument hat schon ein Literaturverzeichnis.")
            return
        }
        let block = NSMutableAttributedString(attachment: WriterBibliographyAttachment())
        block.append(NSAttributedString(string: "\n"))
        block.addAttributes([.writerBlock: WriterBlock.toc.rawValue, .writerListLevel: 0], range: NSRange(location: 0, length: block.length))
        guard let start = insertBlock(block) else { return }
        undoManager?.setActionName("Literaturverzeichnis")
        setSelectedRange(NSRange(location: min(start + block.length, textStorage?.length ?? 0), length: 0))
        setBlockOfEmptyCaretParagraph(.paragraph)
        scrollRangeToVisible(NSRange(location: start, length: block.length))
        citationsChanged(force: true)
    }

    var hasBibliography: Bool { firstLocation(of: WriterBibliographyAttachment.self) != nil }

    // MARK: Changing a citation

    func citation(at location: Int) -> WriterCitationAttachment? {
        guard let storage = textStorage, location >= 0, location < storage.length else { return nil }
        return storage.attribute(.attachment, at: location, effectiveRange: nil) as? WriterCitationAttachment
    }

    func selectCitation(at location: Int) {
        guard citation(at: location) != nil else { return }
        window?.makeFirstResponder(self)
        setSelectedRange(NSRange(location: location, length: 1))
    }

    /// Replaces the citation's items, as one undoable change.
    func replaceCitation(at location: Int, with items: [CitationItem]) {
        guard let storage = textStorage, citation(at: location) != nil else { return }
        let range = NSRange(location: location, length: 1)
        if items.isEmpty {
            performStructureEdit(in: range, with: NSAttributedString())
        } else {
            let text = NSMutableAttributedString(attachment: WriterCitationAttachment(items: items))
            var attributes = storage.attributes(at: location, effectiveRange: nil)
            attributes.removeValue(forKey: .attachment)
            text.addAttributes(attributes, range: NSRange(location: 0, length: 1))
            performStructureEdit(in: range, with: text)
        }
        undoManager?.setActionName("Quellenangabe")
        citationsChanged(force: true)
    }

    /// A double click: page or place, prefix and "only the year" for each source of the citation.
    func editCitation(at location: Int) {
        guard let citation = citation(at: location), let frame = attachmentFrame(at: location) else { return }
        let popover = NSPopover()
        popover.behavior = .transient
        let editor = CitationItemsEditor(items: citation.items, style: citationStyle) { [weak self, weak popover] items in
            popover?.close()
            guard let self, let items else { return }
            self.replaceCitation(at: location, with: items)
            self.setSelectedRange(NSRange(location: location + (items.isEmpty ? 0 : 1), length: 0))
        }
        popover.contentViewController = NSHostingController(rootView: editor)
        popover.show(relativeTo: frame, of: self, preferredEdge: .maxY)
    }

    func citationMenuItems(at location: Int) -> [NSMenuItem] {
        guard let citation = citation(at: location) else { return [] }
        let edit = ClosureMenuItem(title: "Seite und Zusatz bearbeiten …") { [weak self] in self?.editCitation(at: location) }
        edit.image = NSImage(systemSymbolName: "pencil", accessibilityDescription: nil)
        var items: [NSMenuItem] = [edit]
        if let first = citation.items.first, let source = citationStyle.source(first.key) {
            let open = ClosureMenuItem(title: "„\(source.title)“ in Citation Studio zeigen") { [weak self] in self?.onShowSource?(source.id) }
            open.image = NSImage(systemSymbolName: "quote.bubble", accessibilityDescription: nil)
            items.append(open)
        }
        let copy = ClosureMenuItem(title: "Als Markdown kopieren") {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(citation.markdown, forType: .string)
        }
        copy.image = NSImage(systemSymbolName: "doc.on.doc", accessibilityDescription: nil)
        let remove = ClosureMenuItem(title: "Quellenangabe entfernen") { [weak self] in self?.replaceCitation(at: location, with: []) }
        remove.image = NSImage(systemSymbolName: "trash", accessibilityDescription: nil)
        return items + [copy, remove, .separator()]
    }

    /// The citation under a point (for the context menu).
    func citationLocation(at point: NSPoint) -> Int? {
        guard let layoutManager, let container = textContainer else { return nil }
        let inContainer = NSPoint(x: point.x - textContainerOrigin.x, y: point.y - textContainerOrigin.y)
        let glyph = layoutManager.glyphIndex(for: inContainer, in: container)
        let location = layoutManager.characterIndexForGlyph(at: glyph)
        guard citation(at: location) != nil, let frame = attachmentFrame(at: location), frame.insetBy(dx: -2, dy: -2).contains(point) else { return nil }
        return location
    }

    // MARK: The picker (⌘⇧K, "/cite")

    /// A search over sources and quotes at the caret; the choice goes into the text.
    func showCitationPicker() {
        guard let citations else { return }
        citations.loadIfNeeded()
        guard !citations.sources.isEmpty else {
            onNotice?("In Citation Studio gibt es noch keine Quellen. Öffne es über „Applikationen“ und füge eine DOI oder ISBN ein.")
            return
        }
        let location = selectedRange().location
        let caret = firstRect(forCharacterRange: NSRange(location: location, length: 0), actualRange: nil)
        let anchor = window.map { convert($0.convertFromScreen(caret), from: nil) } ?? NSRect(x: 0, y: 0, width: 1, height: 1)
        let popover = NSPopover()
        popover.behavior = .transient
        let picker = CitationPicker(library: citations) { [weak self, weak popover] choice in
            popover?.close()
            guard let self, let choice else { return }
            self.window?.makeFirstResponder(self)
            switch choice {
            case .source(let id):
                if let source = citations.source(id) { self.insertCitation([CitationItem(key: source.citekey)]) }
            case .quote(let id, let insertion):
                if let quote = citations.quote(id), let source = citations.source(quote.sourceID) {
                    self.insertQuote(quote, source: source, as: insertion)
                }
            }
        }
        popover.contentViewController = NSHostingController(rootView: picker)
        popover.show(relativeTo: NSRect(x: anchor.minX, y: anchor.minY, width: max(1, anchor.width), height: max(1, anchor.height)), of: self, preferredEdge: .maxY)
    }

    /// Typing "/cite" opens the picker in its place.
    func checkCiteTrigger() {
        guard let storage = textStorage, citations != nil else { return }
        let caret = selectedRange()
        let trigger = "/cite"
        guard caret.length == 0, caret.location >= trigger.count,
              (storage.string as NSString).substring(with: NSRange(location: caret.location - trigger.count, length: trigger.count)) == trigger else { return }
        let start = caret.location - trigger.count
        if start > 0, let before = (storage.string as NSString).substring(with: NSRange(location: start - 1, length: 1)).first, before.isLetter || before.isNumber {
            return
        }
        DispatchQueue.main.async { [weak self] in
            guard let self, let storage = self.textStorage, start + trigger.count <= storage.length,
                  (storage.string as NSString).substring(with: NSRange(location: start, length: trigger.count)) == trigger else { return }
            let range = NSRange(location: start, length: trigger.count)
            if self.shouldChangeText(in: range, replacementString: "") {
                storage.replaceCharacters(in: range, with: "")
                self.didChangeText()
            }
            self.setSelectedRange(NSRange(location: start, length: 0))
            self.showCitationPicker()
        }
    }
}

// MARK: - Drawing

/// A citation as a soft pill in the text, on the text's baseline; an unknown key in warning colours.
final class WriterCitationCell: NSTextAttachmentCell {
    private var lastSize = NSSize(width: 40, height: 18)
    private var lastBaseline: CGFloat = -4
    private var label = ""
    private var isMissing = false

    private var items: [CitationItem] { (attachment as? WriterCitationAttachment)?.items ?? [] }

    private func textFont(_ storage: NSTextStorage?, _ index: Int, _ view: WriterTextView?) -> NSFont {
        if let storage, index < storage.length, let font = storage.attribute(.font, at: index, effectiveRange: nil) as? NSFont { return font }
        return WriterStyler.font(view?.family ?? .serif, size: WriterStyler.bodySize(view?.family ?? .serif), italic: false)
    }

    override func cellFrame(for textContainer: NSTextContainer, proposedLineFragment lineFrag: NSRect, glyphPosition position: NSPoint, characterIndex charIndex: Int) -> NSRect {
        let view = textContainer.textView as? WriterTextView
        let style = view?.citationStyle
        label = style?.inText(items) ?? CitationMarkup.markdown(items)
        isMissing = style.map { style in items.contains { style.source($0.key) == nil } } ?? true
        let font = textFont(textContainer.layoutManager?.textStorage, charIndex, view)
        let small = NSFont(descriptor: font.fontDescriptor, size: font.pointSize * 0.92) ?? font
        let width = (label as NSString).size(withAttributes: [.font: small]).width
        lastSize = NSSize(width: min(ceil(width) + 12, max(60, lineFrag.width - 4)), height: ceil(font.ascender - font.descender) + 2)
        lastBaseline = floor(font.descender) - 1
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
        let tint = isMissing ? NSColor(hex: 0xF2B14C) : palette.accent
        let isSelected = characterIndex.map { view?.selectedRange() == NSRange(location: $0, length: 1) } ?? false
        let pill = NSBezierPath(roundedRect: frame.insetBy(dx: 1, dy: 1), xRadius: 5, yRadius: 5)
        tint.withAlphaComponent(isSelected ? 0.28 : (palette.isLight ? 0.12 : 0.16)).setFill()
        pill.fill()
        if isSelected {
            tint.setStroke()
            pill.lineWidth = 1.2
            pill.stroke()
        }
        let font = characterIndex.flatMap { index in view.map { textFont($0.textStorage, index, $0) } }
            ?? WriterStyler.font(view?.family ?? .serif, size: WriterStyler.bodySize(view?.family ?? .serif), italic: false)
        let small = NSFont(descriptor: font.fontDescriptor, size: font.pointSize * 0.92) ?? font
        let text = NSAttributedString(string: label, attributes: [
            .font: small,
            .foregroundColor: palette.isLight ? tint.blended(withFraction: 0.35, of: .black) ?? tint : tint.blended(withFraction: 0.25, of: .white) ?? tint,
        ])
        let size = text.size()
        text.draw(with: NSRect(x: frame.minX + 6, y: frame.midY - size.height / 2, width: frame.width - 10, height: size.height),
                  options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
    }

    override func wantsToTrackMouse() -> Bool { true }

    override func wantsToTrackMouse(for theEvent: NSEvent, in cellFrame: NSRect, of controlView: NSView?, atCharacterIndex charIndex: Int) -> Bool { true }

    override func trackMouse(with theEvent: NSEvent, in cellFrame: NSRect, of controlView: NSView?, atCharacterIndex charIndex: Int, untilMouseUp flag: Bool) -> Bool {
        guard let view = controlView as? WriterTextView else { return false }
        view.selectCitation(at: charIndex)
        if theEvent.clickCount >= 2 { view.editCitation(at: charIndex) }
        return true
    }
}

/// The reference list: "Literatur" and the entries with hanging indent, titles in italics.
final class WriterBibliographyCell: NSTextAttachmentCell {
    private var lastSize = NSSize(width: 300, height: 80)
    private var text = NSAttributedString()

    private func build(_ view: WriterTextView?, width: CGFloat) -> NSAttributedString {
        let palette = view?.palette ?? .dark
        let family = view?.family ?? .serif
        let size = WriterStyler.bodySize(family)
        let result = NSMutableAttributedString()
        let heading = NSMutableParagraphStyle()
        heading.paragraphSpacing = 10
        result.append(NSAttributedString(string: "Literatur\n", attributes: [
            .font: WriterStyler.font(family, size: size * 1.25, weight: .semibold),
            .foregroundColor: palette.text, .paragraphStyle: heading,
        ]))
        let entries = view.map { $0.citationStyle.bibliography($0.citedKeys) } ?? []
        let hanging = NSMutableParagraphStyle()
        hanging.headIndent = 24
        hanging.firstLineHeadIndent = 0
        hanging.paragraphSpacing = 7
        hanging.lineHeightMultiple = 1.15
        let regular = WriterStyler.font(family, size: size - 1, italic: false)
        let italic = WriterStyler.font(family, size: size - 1, italic: true)
        if entries.isEmpty {
            result.append(NSAttributedString(string: "Noch keine Quellenangaben im Dokument. Mit ⌘⇧K oder „/cite“ fügst du eine ein – sie erscheint dann hier.", attributes: [
                .font: WriterStyler.font(family, size: size - 2, italic: true), .foregroundColor: palette.tertiaryText, .paragraphStyle: hanging,
            ]))
        }
        for (index, entry) in entries.enumerated() {
            for run in entry.text.runs {
                result.append(NSAttributedString(string: run.text, attributes: [
                    .font: run.italic ? italic : regular, .foregroundColor: palette.text, .paragraphStyle: hanging,
                ]))
            }
            if index < entries.count - 1 { result.append(NSAttributedString(string: "\n", attributes: [.paragraphStyle: hanging, .font: regular])) }
        }
        return result
    }

    override func cellFrame(for textContainer: NSTextContainer, proposedLineFragment lineFrag: NSRect, glyphPosition position: NSPoint, characterIndex charIndex: Int) -> NSRect {
        let width = max(120, lineFrag.width - 4)
        text = build(textContainer.textView as? WriterTextView, width: width)
        let bounds = text.boundingRect(with: NSSize(width: width - 24, height: .greatestFiniteMagnitude), options: [.usesLineFragmentOrigin, .usesFontLeading])
        lastSize = NSSize(width: width, height: ceil(bounds.height) + 28)
        return NSRect(origin: .zero, size: lastSize)
    }

    override func cellSize() -> NSSize { lastSize }
    override func cellBaselineOffset() -> NSPoint { .zero }

    override func draw(withFrame cellFrame: NSRect, in controlView: NSView?) {
        draw(cellFrame, view: controlView as? WriterTextView, characterIndex: nil)
    }

    override func draw(withFrame cellFrame: NSRect, in controlView: NSView?, characterIndex charIndex: Int, layoutManager: NSLayoutManager) {
        draw(cellFrame, view: controlView as? WriterTextView, characterIndex: charIndex)
    }

    private func draw(_ frame: NSRect, view: WriterTextView?, characterIndex: Int?) {
        let palette = view?.palette ?? .dark
        if let characterIndex, view?.selectedRange() == NSRange(location: characterIndex, length: 1) {
            let outline = NSBezierPath(roundedRect: frame.insetBy(dx: 1, dy: 1), xRadius: 8, yRadius: 8)
            palette.accent.withAlphaComponent(0.08).setFill()
            outline.fill()
            palette.accent.setStroke()
            outline.lineWidth = 1.5
            outline.stroke()
        }
        text.draw(with: frame.insetBy(dx: 12, dy: 14), options: [.usesLineFragmentOrigin, .usesFontLeading])
    }

    override func wantsToTrackMouse() -> Bool { true }

    override func wantsToTrackMouse(for theEvent: NSEvent, in cellFrame: NSRect, of controlView: NSView?, atCharacterIndex charIndex: Int) -> Bool { true }

    override func trackMouse(with theEvent: NSEvent, in cellFrame: NSRect, of controlView: NSView?, atCharacterIndex charIndex: Int, untilMouseUp flag: Bool) -> Bool {
        guard let view = controlView as? WriterTextView else { return false }
        view.selectEmbed(at: charIndex)
        return true
    }
}

// MARK: - Editing a citation

/// Page or place, prefix and "only the year" for each source of a citation.
private struct CitationItemsEditor: View {
    @State var items: [CitationItem]
    let style: CitationStyle
    let onDone: ([CitationItem]?) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(style.inText(items))
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Theme.textPrimary)
            ForEach(items.indices, id: \.self) { index in
                VStack(alignment: .leading, spacing: 6) {
                    Text(style.source(items[index].key).map { "\($0.shortReference) – \($0.title)" } ?? "@\(items[index].key) (nicht in Citation Studio)")
                        .font(.system(size: 11.5))
                        .foregroundStyle(Theme.textSecondary)
                        .lineLimit(1)
                    HStack(spacing: 8) {
                        TextField("Zusatz, z. B. vgl.", text: $items[index].prefix)
                            .frame(width: 110)
                        TextField("Seite / Stelle, z. B. 12 oder Kap. 3", text: Binding(
                            get: { items[index].locator },
                            set: { items[index].locator = $0 }
                        ))
                        .onSubmit { normalize(index) }
                        Toggle("nur Jahr", isOn: $items[index].suppressAuthor)
                            .toggleStyle(.checkbox)
                            .help("Wenn der Name schon im Satz steht: „… zeigt Müller (2020)“")
                        Button { items.remove(at: index) } label: { Image(systemName: "minus.circle") }
                            .buttonStyle(.plain)
                            .foregroundStyle(Theme.textTertiary)
                            .help("Diese Quelle aus der Angabe nehmen")
                    }
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 12))
                }
            }
            HStack {
                Button("Entfernen", role: .destructive) { onDone([]) }
                Spacer()
                Button("Abbrechen") { onDone(nil) }
                Button("Übernehmen") {
                    for index in items.indices { normalize(index) }
                    onDone(items)
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(16)
        .frame(width: 460)
        .environment(\.colorScheme, .dark)
    }

    /// "436" becomes "S. 436".
    private func normalize(_ index: Int) {
        guard index < items.count else { return }
        items[index].locator = CitationMarkup.locator(items[index].locator)
    }
}
