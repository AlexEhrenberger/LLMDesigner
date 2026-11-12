import AppKit
import SwiftUI

/// A field from Data Studio in the text: one object that shows the current value („Musterstraße 1“) and is stored
/// as `{{absender.strasse}}`. Never changed in place: choosing another field puts a new attachment there.
final class WriterDataFieldAttachment: NSTextAttachment {
    private(set) var ref = DataRef(block: "")

    convenience init(ref: DataRef) {
        self.init(data: nil, ofType: nil)
        self.ref = ref
    }

    override init(data contentData: Data?, ofType uti: String?) {
        super.init(data: contentData, ofType: uti)
        attachmentCell = WriterDataFieldCell()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        attachmentCell = WriterDataFieldCell()
    }

    var markdown: String { ref.token }

    /// What it reads as now; nil when the block or field doesn't exist (any more).
    @MainActor var value: String? { DataFields.resolver.value(ref) }
}

extension WriterTextView {
    // MARK: Inserting

    func insertDataField(_ ref: DataRef) {
        guard let storage = textStorage else { return }
        let range = citationInsertionPoint
        let field = NSMutableAttributedString(attachment: WriterDataFieldAttachment(ref: ref))
        var attributes = typingAttributes.filter {
            [.writerBold, .writerItalic, .underlineStyle, .strikethroughStyle, .writerBlock, .writerListLevel, .writerBookmark, .writerColor, .writerFont, .font, .foregroundColor, .paragraphStyle].contains($0.key)
                || WriterMarkdown.tableKeys.contains($0.key)
        }
        attributes.removeValue(forKey: .writerCode)
        field.addAttributes(attributes, range: NSRange(location: 0, length: field.length))
        window?.makeFirstResponder(self)
        breakUndoCoalescing()
        guard shouldChangeText(in: range, replacementString: field.string) else { return }
        storage.replaceCharacters(in: range, with: field)
        didChangeText()
        setSelectedRange(NSRange(location: range.location + field.length, length: 0))
        undoManager?.setActionName("Datenfeld")
        onStateChange?()
    }

    func dataField(at location: Int) -> WriterDataFieldAttachment? {
        guard let storage = textStorage, location >= 0, location < storage.length else { return nil }
        return storage.attribute(.attachment, at: location, effectiveRange: nil) as? WriterDataFieldAttachment
    }

    /// Puts the value in place of the field: the text then no longer follows Data Studio.
    func fixDataField(at location: Int) {
        guard let storage = textStorage, let field = dataField(at: location), let value = field.value else { return }
        var attributes = storage.attributes(at: location, effectiveRange: nil)
        attributes.removeValue(forKey: .attachment)
        let text = NSAttributedString(string: value.replacingOccurrences(of: "\n", with: String(WriterMarkdown.lineSeparator)), attributes: attributes)
        performStructureEdit(in: NSRange(location: location, length: 1), with: text)
        undoManager?.setActionName("Datenfeld als Text")
    }

    func replaceDataField(at location: Int, with ref: DataRef) {
        guard let storage = textStorage, dataField(at: location) != nil else { return }
        var attributes = storage.attributes(at: location, effectiveRange: nil)
        attributes.removeValue(forKey: .attachment)
        let field = NSMutableAttributedString(attachment: WriterDataFieldAttachment(ref: ref))
        field.addAttributes(attributes, range: NSRange(location: 0, length: 1))
        performStructureEdit(in: NSRange(location: location, length: 1), with: field)
        undoManager?.setActionName("Datenfeld")
    }

    /// After a change in Data Studio: every field is measured and drawn again.
    @objc func dataFieldsDidChange(_ notification: Notification) {
        guard let storage = textStorage, let layoutManager, storage.length > 0 else { return }
        storage.enumerateAttribute(.attachment, in: NSRange(location: 0, length: storage.length)) { value, range, _ in
            guard value is WriterDataFieldAttachment else { return }
            layoutManager.invalidateLayout(forCharacterRange: range, actualCharacterRange: nil)
            layoutManager.invalidateDisplay(forCharacterRange: range)
        }
    }

    func observeDataFields() {
        NotificationCenter.default.addObserver(self, selector: #selector(dataFieldsDidChange(_:)), name: DataFields.changed, object: nil)
    }

    // MARK: The picker (⌥⌘D, "/daten")

    func showDataFieldPicker(replacing location: Int? = nil) {
        let caretLocation = location ?? selectedRange().location
        let anchorRect: NSRect
        if let location, let frame = attachmentFrame(at: location) {
            anchorRect = frame
        } else {
            let caret = firstRect(forCharacterRange: NSRange(location: caretLocation, length: 0), actualRange: nil)
            let anchor = window.map { convert($0.convertFromScreen(caret), from: nil) } ?? NSRect(x: 0, y: 0, width: 1, height: 1)
            anchorRect = NSRect(x: anchor.minX, y: anchor.minY, width: max(1, anchor.width), height: max(1, anchor.height))
        }
        let popover = NSPopover()
        popover.behavior = .transient
        let picker = DataFieldPicker { [weak self, weak popover] ref in
            popover?.close()
            guard let self, let ref else { return }
            self.window?.makeFirstResponder(self)
            if let location { self.replaceDataField(at: location, with: ref) } else { self.insertDataField(ref) }
        }
        popover.contentViewController = NSHostingController(rootView: picker)
        popover.show(relativeTo: anchorRect, of: self, preferredEdge: .maxY)
    }

    /// Typing "/daten" opens the picker in its place.
    func checkDataTrigger() {
        guard let storage = textStorage else { return }
        let caret = selectedRange()
        let trigger = "/daten"
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
            self.showDataFieldPicker()
        }
    }

    func dataFieldLocation(at point: NSPoint) -> Int? {
        guard let layoutManager, let container = textContainer else { return nil }
        let inContainer = NSPoint(x: point.x - textContainerOrigin.x, y: point.y - textContainerOrigin.y)
        let glyph = layoutManager.glyphIndex(for: inContainer, in: container)
        let location = layoutManager.characterIndexForGlyph(at: glyph)
        guard dataField(at: location) != nil, let frame = attachmentFrame(at: location), frame.insetBy(dx: -2, dy: -2).contains(point) else { return nil }
        return location
    }

    func dataFieldMenuItems(at location: Int) -> [NSMenuItem] {
        guard let field = dataField(at: location) else { return [] }
        var items: [NSMenuItem] = []
        let change = ClosureMenuItem(title: "Anderes Datenfeld wählen …") { [weak self] in self?.showDataFieldPicker(replacing: location) }
        change.image = NSImage(systemSymbolName: "arrow.triangle.swap", accessibilityDescription: nil)
        items.append(change)
        if !DataKey.reserved.contains(field.ref.block.lowercased()) {
            let open = ClosureMenuItem(title: "In Data Studio zeigen") { DataFields.openBlock?(field.ref.block) }
            open.image = NSImage(systemSymbolName: "tablecells", accessibilityDescription: nil)
            items.append(open)
        }
        if field.value != nil {
            let fix = ClosureMenuItem(title: "Als festen Text einsetzen") { [weak self] in self?.fixDataField(at: location) }
            fix.image = NSImage(systemSymbolName: "text.badge.checkmark", accessibilityDescription: nil)
            items.append(fix)
        }
        let copy = ClosureMenuItem(title: "Als Markdown kopieren") {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(field.markdown, forType: .string)
        }
        copy.image = NSImage(systemSymbolName: "doc.on.doc", accessibilityDescription: nil)
        let remove = ClosureMenuItem(title: "Datenfeld entfernen") { [weak self] in
            self?.performStructureEdit(in: NSRange(location: location, length: 1), with: NSAttributedString())
        }
        remove.image = NSImage(systemSymbolName: "trash", accessibilityDescription: nil)
        return items + [copy, remove, .separator()]
    }
}

extension DataFields {
    /// Opens Data Studio at a block (set by the app; the text views can't reach the model).
    @MainActor static var openBlock: ((String) -> Void)?
}

// MARK: - Drawing

/// A field as a light underlined tag on the text's baseline in the text's own font; a field whose block is gone shows
/// its token in warning colours. A value of several lines (an address) is drawn as a small block of lines.
final class WriterDataFieldCell: NSTextAttachmentCell {
    private var lastSize = NSSize(width: 40, height: 18)
    private var lastBaseline: CGFloat = -4
    private var lines: [String] = []
    private var isMissing = false

    private var ref: DataRef { (attachment as? WriterDataFieldAttachment)?.ref ?? DataRef(block: "") }

    private func textFont(_ storage: NSTextStorage?, _ index: Int, _ view: WriterTextView?) -> NSFont {
        if let storage, index < storage.length, let font = storage.attribute(.font, at: index, effectiveRange: nil) as? NSFont { return font }
        return WriterStyler.font(view?.family ?? .serif, size: WriterStyler.bodySize(view?.family ?? .serif), italic: false)
    }

    override func cellFrame(for textContainer: NSTextContainer, proposedLineFragment lineFrag: NSRect, glyphPosition position: NSPoint, characterIndex charIndex: Int) -> NSRect {
        let view = textContainer.textView as? WriterTextView
        let value = MainActor.assumeIsolated { DataFields.resolver.value(ref) }
        isMissing = value == nil
        let shown = (value ?? ref.token).trimmingCharacters(in: .newlines)
        lines = shown.isEmpty ? ["‹\(MainActor.assumeIsolated { DataFields.resolver.label(ref) })›"] : shown.components(separatedBy: "\n")
        let font = textFont(textContainer.layoutManager?.textStorage, charIndex, view)
        let lineHeight = ceil(font.ascender - font.descender + font.leading) + 1
        let width = lines.map { ($0 as NSString).size(withAttributes: [.font: font]).width }.max() ?? 20
        lastSize = NSSize(width: min(ceil(width) + 4, max(40, lineFrag.width - 4)), height: lineHeight * CGFloat(lines.count))
        // The first line sits on the baseline; further lines hang below it.
        lastBaseline = floor(font.descender) - lineHeight * CGFloat(lines.count - 1)
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
        let tint = isMissing ? NSColor(hex: 0xF2B14C) : NSColor(hex: 0x3FB8B8)
        let isSelected = characterIndex.map { view?.selectedRange() == NSRange(location: $0, length: 1) } ?? false
        // Printing and slide pictures show only the text.
        let decorated = view?.isEditable == true
        if decorated {
            let box = NSBezierPath(roundedRect: frame.insetBy(dx: 0, dy: 1), xRadius: 3, yRadius: 3)
            tint.withAlphaComponent(isSelected ? 0.26 : (palette.isLight ? 0.09 : 0.13)).setFill()
            box.fill()
            if isSelected {
                tint.setStroke()
                box.lineWidth = 1
                box.stroke()
            }
        }
        let storage = view?.textStorage
        let font = characterIndex.map { textFont(storage, $0, view) }
            ?? WriterStyler.font(view?.family ?? .serif, size: WriterStyler.bodySize(view?.family ?? .serif), italic: false)
        var color = (characterIndex.flatMap { index -> NSColor? in
            guard let storage, index < storage.length else { return nil }
            return storage.attribute(.foregroundColor, at: index, effectiveRange: nil) as? NSColor
        }) ?? palette.text
        if isMissing { color = palette.isLight ? tint.blended(withFraction: 0.4, of: .black) ?? tint : tint }
        let lineHeight = frame.height / CGFloat(max(1, lines.count))
        for (number, line) in lines.enumerated() {
            let text = NSAttributedString(string: line, attributes: [.font: font, .foregroundColor: color])
            let size = text.size()
            let y = frame.minY + CGFloat(number) * lineHeight + (lineHeight - size.height) / 2
            text.draw(with: NSRect(x: frame.minX + 2, y: y, width: frame.width - 2, height: size.height), options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
        }
        if decorated {
            // A dotted line under the value says: this text comes from Data Studio.
            let underline = NSBezierPath()
            underline.move(to: NSPoint(x: frame.minX + 1, y: frame.maxY - 1.5))
            underline.line(to: NSPoint(x: frame.maxX - 1, y: frame.maxY - 1.5))
            underline.setLineDash([2, 2], count: 2, phase: 0)
            underline.lineWidth = 1
            tint.withAlphaComponent(0.8).setStroke()
            underline.stroke()
        }
    }

    override func wantsToTrackMouse() -> Bool { true }

    override func wantsToTrackMouse(for theEvent: NSEvent, in cellFrame: NSRect, of controlView: NSView?, atCharacterIndex charIndex: Int) -> Bool { true }

    override func trackMouse(with theEvent: NSEvent, in cellFrame: NSRect, of controlView: NSView?, atCharacterIndex charIndex: Int, untilMouseUp flag: Bool) -> Bool {
        guard let view = controlView as? WriterTextView, view.isEditable else { return false }
        view.window?.makeFirstResponder(view)
        view.setSelectedRange(NSRange(location: charIndex, length: 1))
        if theEvent.clickCount >= 2 { view.showDataFieldPicker(replacing: charIndex) }
        return true
    }
}

// MARK: - Picker

/// The search over Data Studio's blocks at the caret: a block row puts in the whole block, a field row one field.
struct DataFieldPicker: View {
    let choose: (DataRef?) -> Void
    @State private var query = ""
    @State private var expanded: Set<UUID> = []

    var body: some View {
        let resolver = DataFields.resolver
        let blocks = DataFields.blocks.filter { $0.matches(query) }
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                Image(systemName: "tablecells")
                    .foregroundStyle(Theme.accent)
                Text("Datenfeld einfügen")
                    .font(.system(size: 13, weight: .semibold))
                Spacer()
                Text("{{…}}")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(Theme.textTertiary)
            }
            .padding([.horizontal, .top], 12)
            .padding(.bottom, 8)
            SearchField(text: $query, prompt: "Datenblock oder Feld suchen")
                .padding(.horizontal, 10)
                .padding(.bottom, 6)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 1) {
                    row(symbol: "calendar", title: "Heutiges Datum", detail: resolver.value(DataRef(block: "heute")) ?? "", ref: DataRef(block: "heute"))
                    if blocks.isEmpty {
                        Text(DataFields.blocks.isEmpty ? "Noch keine Datenblöcke. Lege in Data Studio einen an – etwa „Absender“ mit deiner Anschrift." : "Nichts passt zur Suche.")
                            .font(.system(size: 12))
                            .foregroundStyle(Theme.textTertiary)
                            .padding(12)
                    }
                    ForEach(blocks) { block in
                        let isOpen = expanded.contains(block.id) || !query.isEmpty
                        HStack(spacing: 0) {
                            Button {
                                if isOpen { expanded.remove(block.id) } else { expanded.insert(block.id) }
                            } label: {
                                Image(systemName: isOpen ? "chevron.down" : "chevron.right")
                                    .font(.system(size: 9, weight: .bold))
                                    .foregroundStyle(Theme.textTertiary)
                                    .frame(width: 20, height: 30)
                                    .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            row(symbol: block.symbol, title: block.displayName, detail: block.composed.replacingOccurrences(of: "\n", with: ", "),
                                ref: DataRef(block: block.key), color: Color(hex: block.color.hex))
                        }
                        if isOpen {
                            ForEach(block.fields.filter { query.isEmpty || $0.name.localizedCaseInsensitiveContains(query) || $0.value.localizedCaseInsensitiveContains(query) || block.displayName.localizedCaseInsensitiveContains(query) }) { field in
                                row(symbol: field.kind.symbol, title: field.name, detail: field.output, ref: DataRef(block: block.key, field: field.key))
                                    .padding(.leading, 24)
                            }
                        }
                    }
                }
                .padding(.horizontal, 6)
                .padding(.bottom, 8)
            }
            .frame(height: 320)
            Divider()
            Button {
                choose(nil)
                DataFields.openBlock?("")
            } label: {
                Label("Data Studio öffnen", systemImage: "arrow.up.forward.app")
                    .font(.system(size: 12))
            }
            .buttonStyle(.plain)
            .foregroundStyle(Theme.accent)
            .padding(10)
        }
        .frame(width: 380)
    }

    private func row(symbol: String, title: String, detail: String, ref: DataRef, color: Color = Theme.accent) -> some View {
        Button {
            choose(ref)
        } label: {
            HStack(spacing: 8) {
                Image(systemName: symbol)
                    .font(.system(size: 11))
                    .foregroundStyle(color)
                    .frame(width: 18)
                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: 6) {
                        Text(title)
                            .font(.system(size: 12.5, weight: .medium))
                            .foregroundStyle(Theme.textPrimary)
                        Text(ref.token)
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundStyle(Theme.textTertiary)
                    }
                    if !detail.isEmpty {
                        Text(detail)
                            .font(.system(size: 11))
                            .foregroundStyle(Theme.textSecondary)
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(.vertical, 5)
            .padding(.horizontal, 6)
            .contentShape(Rectangle())
        }
        .buttonStyle(PickerRowStyle())
    }
}

private struct PickerRowStyle: ButtonStyle {
    @State private var hovering = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(hovering || configuration.isPressed ? Theme.hover : .clear))
            .onHover { hovering = $0 }
    }
}

extension DataFields {
    /// The blocks in the order Data Studio lists them (for pickers outside the studio).
    @MainActor static var blocks: [DataBlock] = []
}
