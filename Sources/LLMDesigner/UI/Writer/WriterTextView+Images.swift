import AppKit
import SwiftUI

/// Pictures in the editor: each one is a paragraph of its own (`WriterImageAttachment`). A click selects it and
/// shows a small bar for its size, caption and removal.
extension WriterTextView {
    // MARK: Embedded blocks (pictures, display formulas, the table of contents)

    /// The attachment of a picture, display formula or table of contents at `location` when its paragraph is one.
    func embed(at location: Int) -> NSTextAttachment? {
        guard let storage = textStorage, location >= 0, location < storage.length,
              WriterStyler.block(in: storage, at: location).isEmbed else { return nil }
        let attachment = storage.attribute(.attachment, at: location, effectiveRange: nil) as? NSTextAttachment
        return attachment is WriterImageAttachment || attachment is WriterMathAttachment || attachment is WriterTOCAttachment ? attachment : nil
    }

    /// The embedded block when it is selected on its own.
    var selectedEmbed: (attachment: NSTextAttachment, location: Int)? {
        let range = selectedRange()
        guard range.length == 1, let attachment = embed(at: range.location) else { return nil }
        return (attachment, range.location)
    }

    /// Any attachment selected on its own (an inline formula too); it draws its own frame instead of the selection.
    var selectedAttachmentLocation: Int? {
        let range = selectedRange()
        guard range.length == 1, let storage = textStorage, range.location < storage.length,
              storage.attribute(.attachment, at: range.location, effectiveRange: nil) is NSTextAttachment,
              !(storage.attribute(.attachment, at: range.location, effectiveRange: nil) is WriterRuleAttachment) else { return nil }
        return range.location
    }

    func selectEmbed(at location: Int) {
        guard let storage = textStorage, location < storage.length,
              storage.attribute(.attachment, at: location, effectiveRange: nil) != nil else { return }
        window?.makeFirstResponder(self)
        setSelectedRange(NSRange(location: location, length: 1))
    }

    /// Removes an embedded block with its paragraph, so no empty line stays behind.
    func deleteEmbed(at location: Int? = nil) {
        guard let storage = textStorage, let location = location ?? selectedEmbed?.location, embed(at: location) != nil else { return }
        let paragraph = (storage.string as NSString).paragraphRange(for: NSRange(location: location, length: 0))
        performStructureEdit(in: paragraph, with: NSAttributedString())
        setSelectedRange(NSRange(location: min(paragraph.location, storage.length), length: 0))
        resetTypingAttributes()
        onStateChange?()
    }

    /// The frame of an attachment in view coordinates.
    func attachmentFrame(at location: Int) -> NSRect? {
        guard let layoutManager, let container = textContainer, let storage = textStorage, storage.editedMask.isEmpty,
              location < storage.length, storage.attribute(.attachment, at: location, effectiveRange: nil) != nil else { return nil }
        let glyphs = layoutManager.glyphRange(forCharacterRange: NSRange(location: location, length: 1), actualCharacterRange: nil)
        guard glyphs.length > 0 else { return nil }
        let rect = layoutManager.boundingRect(forGlyphRange: glyphs, in: container)
        guard !rect.isEmpty else { return nil }
        return rect.offsetBy(dx: textContainerOrigin.x, dy: textContainerOrigin.y)
    }

    /// The picture when it is selected on its own.
    var selectedImage: (reference: WriterImageReference, location: Int)? {
        let range = selectedRange()
        guard range.length == 1, let image = image(at: range.location) else { return nil }
        return (image.reference, range.location)
    }

    func image(at location: Int) -> WriterImageAttachment? {
        guard let storage = textStorage, location >= 0, location < storage.length else { return nil }
        return storage.attribute(.attachment, at: location, effectiveRange: nil) as? WriterImageAttachment
    }

    func selectImage(at location: Int) {
        guard image(at: location) != nil else { return }
        window?.makeFirstResponder(self)
        setSelectedRange(NSRange(location: location, length: 1))
    }

    // MARK: Inserting

    /// Copies the pictures into the document folder and puts them below the current paragraph.
    func insertImages(_ sources: [AttachmentStore.Source]) {
        var references: [WriterImageReference] = []
        for source in sources {
            do {
                references.append(WriterImageReference(source: try WriterImageStore.importImage(source), caption: "", width: nil))
            } catch {
                onNotice?(error.localizedDescription)
            }
        }
        guard !references.isEmpty else { return }
        let text = NSMutableAttributedString()
        let attributes: [NSAttributedString.Key: Any] = [.writerBlock: WriterBlock.image.rawValue, .writerListLevel: 0]
        for reference in references {
            let start = text.length
            text.append(NSAttributedString(attachment: WriterImageAttachment(reference: reference)))
            text.append(NSAttributedString(string: "\n"))
            text.addAttributes(attributes, range: NSRange(location: start, length: text.length - start))
        }
        guard let start = insertBlock(text) else { return }
        setSelectedRange(NSRange(location: start + text.length, length: 0))
        setBlockOfEmptyCaretParagraph(.paragraph)
        scrollRangeToVisible(NSRange(location: start, length: text.length))
    }

    // MARK: Changing a picture

    /// Gives the picture at `location` (or the selected one) a new size or caption, as one undoable change.
    func updateImage(at location: Int? = nil, _ change: (inout WriterImageReference) -> Void) {
        guard let storage = textStorage, let location = location ?? selectedImage?.location, let attachment = image(at: location) else { return }
        var reference = attachment.reference
        change(&reference)
        guard reference != attachment.reference else { return }
        let range = NSRange(location: location, length: 1)
        guard shouldChangeText(in: range, replacementString: nil) else { return }
        storage.addAttribute(.attachment, value: WriterImageAttachment(reference: reference), range: range)
        didChangeText()
        DispatchQueue.main.async { [weak self] in self?.updateImageControls() }
        onStateChange?()
    }

    func setImageWidth(_ width: Int?, at location: Int? = nil) {
        updateImage(at: location) { $0.width = width }
    }

    func editImageCaption(at location: Int? = nil) {
        guard let location = location ?? selectedImage?.location, let attachment = image(at: location) else { return }
        let caption = attachment.reference.caption
        let alert = NSAlert()
        alert.messageText = caption.isEmpty ? "Bildunterschrift hinzufügen" : "Bildunterschrift bearbeiten"
        alert.informativeText = "Steht unter dem Bild; im PDF als „Abbildung 1: …“."
        let field = NSTextField(string: caption)
        field.placeholderString = "z. B. Aufbau des Versuchs"
        field.frame = NSRect(x: 0, y: 0, width: 340, height: 24)
        alert.accessoryView = field
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "Abbrechen")
        alert.window.initialFirstResponder = field
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let text = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        updateImage(at: location) { $0.caption = text }
        selectImage(at: location)
    }

    /// Removes the picture with its paragraph, so no empty line stays behind.
    func deleteImage(at location: Int? = nil) {
        guard let storage = textStorage, let location = location ?? selectedImage?.location, image(at: location) != nil else { return }
        let paragraph = (storage.string as NSString).paragraphRange(for: NSRange(location: location, length: 0))
        performStructureEdit(in: paragraph, with: NSAttributedString())
        setSelectedRange(NSRange(location: min(paragraph.location, storage.length), length: 0))
        resetTypingAttributes()
        onStateChange?()
    }

    func revealImage(at location: Int? = nil) {
        guard let location = location ?? selectedImage?.location, let attachment = image(at: location),
              let url = WriterImageStore.url(for: attachment.reference.source) else { return }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    // MARK: Where pictures are

    /// The picture's box (with its caption) in view coordinates.
    func imageFrame(at location: Int) -> NSRect? {
        // Not while the text storage is in the middle of an edit: layout has to wait for it.
        guard let layoutManager, let container = textContainer, textStorage?.editedMask.isEmpty != false, image(at: location) != nil else { return nil }
        let glyphs = layoutManager.glyphRange(forCharacterRange: NSRange(location: location, length: 1), actualCharacterRange: nil)
        guard glyphs.length > 0 else { return nil }
        let rect = layoutManager.boundingRect(forGlyphRange: glyphs, in: container)
        guard !rect.isEmpty else { return nil }
        return rect.offsetBy(dx: textContainerOrigin.x, dy: textContainerOrigin.y)
    }

    /// The picture under a point (for the context menu).
    func imageLocation(at point: NSPoint) -> Int? {
        guard let layoutManager, let container = textContainer else { return nil }
        let inContainer = NSPoint(x: point.x - textContainerOrigin.x, y: point.y - textContainerOrigin.y)
        let glyph = layoutManager.glyphIndex(for: inContainer, in: container)
        let location = layoutManager.characterIndexForGlyph(at: glyph)
        guard let frame = imageFrame(at: location), frame.contains(point) else { return nil }
        return location
    }

    // MARK: The bar on a selected picture

    func updateImageControls() {
        guard let image = selectedImage, window != nil, let frame = imageFrame(at: image.location) else {
            imageControlsHost?.isHidden = true
            return
        }
        let location = image.location
        let bar = WriterImageBar(
            width: image.reference.width,
            hasCaption: !image.reference.caption.isEmpty,
            isPlot: image.reference.plot != nil,
            onWidth: { [weak self] in self?.setImageWidth($0) },
            onCaption: { [weak self] in self?.editImageCaption() },
            onPlot: { [weak self] in self?.editPlot(at: location) },
            onDelete: { [weak self] in self?.deleteImage() }
        )
        let host: NSHostingView<WriterImageBar>
        if let existing = imageControlsHost as? NSHostingView<WriterImageBar> {
            host = existing
            host.rootView = bar
        } else {
            host = NSHostingView(rootView: bar)
            imageControlsHost = host
        }
        if host.superview !== self { addSubview(host) }
        host.isHidden = false
        let size = host.fittingSize
        // On the picture's top edge when it is big enough, above it otherwise.
        let inside = frame.width >= size.width + 24 && frame.height >= size.height + 40
        let x = min(max(frame.midX - size.width / 2, 8), bounds.width - size.width - 8)
        let y = inside ? frame.minY + 10 : max(0, frame.minY - size.height - 8)
        host.frame = NSRect(x: x, y: y, width: size.width, height: size.height)
    }

    // MARK: Menu

    func imageMenuItems(at location: Int) -> [NSMenuItem] {
        guard let attachment = image(at: location) else { return [] }
        let reference = attachment.reference
        let size = NSMenuItem(title: "Größe", action: nil, keyEquivalent: "")
        size.image = NSImage(systemSymbolName: "arrow.up.left.and.arrow.down.right", accessibilityDescription: nil)
        let sizes = NSMenu()
        for (title, width) in WriterImageBar.sizes {
            let item = ClosureMenuItem(title: title) { [weak self] in self?.setImageWidth(width, at: location) }
            item.state = reference.width == width ? .on : .off
            sizes.addItem(item)
        }
        size.submenu = sizes
        let caption = ClosureMenuItem(title: reference.caption.isEmpty ? "Bildunterschrift hinzufügen …" : "Bildunterschrift bearbeiten …") { [weak self] in
            self?.editImageCaption(at: location)
        }
        caption.image = NSImage(systemSymbolName: "text.below.photo", accessibilityDescription: nil)
        var plotItems: [NSMenuItem] = []
        if reference.plot != nil {
            let plot = ClosureMenuItem(title: "Plot bearbeiten …") { [weak self] in self?.editPlot(at: location) }
            plot.image = NSImage(systemSymbolName: "chart.xyaxis.line", accessibilityDescription: nil)
            plotItems.append(plot)
        }
        let reveal = ClosureMenuItem(title: "Im Finder zeigen") { [weak self] in self?.revealImage(at: location) }
        reveal.image = NSImage(systemSymbolName: "folder", accessibilityDescription: nil)
        reveal.isEnabled = WriterImageStore.url(for: reference.source) != nil
        let delete = ClosureMenuItem(title: "Bild entfernen") { [weak self] in self?.deleteImage(at: location) }
        delete.image = NSImage(systemSymbolName: "trash", accessibilityDescription: nil)
        return plotItems + [size, caption, reveal, delete, .separator()]
    }
}

/// The bar on a selected picture.
struct WriterImageBar: View {
    let width: Int?
    let hasCaption: Bool
    var isPlot = false
    let onWidth: (Int?) -> Void
    let onCaption: () -> Void
    var onPlot: () -> Void = {}
    let onDelete: () -> Void

    /// nil: the picture's own size, at most the column.
    static let sizes: [(String, Int?)] = [("Original", nil), ("33 %", 33), ("50 %", 50), ("75 %", 75), ("100 %", 100)]

    var body: some View {
        HStack(spacing: 2) {
            if isPlot {
                Button(action: onPlot) {
                    Label("Plot bearbeiten", systemImage: "chart.xyaxis.line")
                        .font(.system(size: 11.5, weight: .semibold))
                        .foregroundStyle(Theme.accent)
                        .padding(.horizontal, 9)
                        .frame(height: 24)
                        .background(Capsule().fill(Theme.accent.opacity(0.16)))
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .focusable(false)
                .help("Formel und Plot bearbeiten")
                Rectangle().fill(Color.white.opacity(0.14)).frame(width: 1, height: 16).padding(.horizontal, 4)
            }
            ForEach(Self.sizes, id: \.0) { title, value in
                chip(title, isActive: width == value) { onWidth(value) }
                    .help(value.map { "\($0) % der Spaltenbreite" } ?? "Eigene Größe des Bildes, höchstens die Spaltenbreite")
            }
            Rectangle().fill(Color.white.opacity(0.14)).frame(width: 1, height: 16).padding(.horizontal, 4)
            icon("text.below.photo", help: hasCaption ? "Bildunterschrift bearbeiten" : "Bildunterschrift hinzufügen", action: onCaption)
            icon("trash", help: "Bild entfernen", action: onDelete)
        }
        .padding(4)
        .background(Capsule().fill(Color(hex: 0x1C1C20).opacity(0.96)))
        .overlay(Capsule().strokeBorder(Color.white.opacity(0.12)))
        .shadow(color: .black.opacity(0.35), radius: 10, y: 3)
        .environment(\.colorScheme, .dark)
        .fixedSize()
    }

    private func chip(_ title: String, isActive: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 11.5, weight: .medium).monospacedDigit())
                .foregroundStyle(isActive ? Theme.accent : Theme.textSecondary)
                .padding(.horizontal, 8)
                .frame(height: 24)
                .background(Capsule().fill(isActive ? Theme.accent.opacity(0.18) : .clear))
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .focusable(false)
    }

    private func icon(_ symbol: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Theme.textSecondary)
                .frame(width: 28, height: 24)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .focusable(false)
        .help(help)
    }
}

/// Draws a picture at its width in the column, rounded, with the caption centred below. A missing file shows
/// a placeholder with its name.
final class WriterImageCell: NSTextAttachmentCell {
    private static let captionGap: CGFloat = 8
    private static let maxHeight: CGFloat = 900

    private struct Layout {
        var image: NSRect
        var caption: NSRect
        var size: NSSize
    }

    private var lastLayout: Layout?

    private var reference: WriterImageReference {
        (attachment as? WriterImageAttachment)?.reference ?? WriterImageReference(source: "", caption: "", width: nil)
    }

    /// A plot on the dark sheet shows its dark version.
    @MainActor
    private func displayImage(_ view: WriterTextView?) -> NSImage? {
        let reference = reference
        if reference.plot != nil, view?.palette.isLight == false,
           let dark = WriterImageStore.displayImage(for: WriterImageStore.darkVariant(of: reference.source)) {
            return dark
        }
        return WriterImageStore.displayImage(for: reference.source)
    }

    private func layout(available: CGFloat, view: WriterTextView?) -> Layout {
        let reference = reference
        var imageSize: NSSize
        if let image = displayImage(view), image.size.width > 0, image.size.height > 0 {
            let width = reference.width.map { available * CGFloat($0) / 100 } ?? min(image.size.width, available)
            imageSize = NSSize(width: width, height: width * image.size.height / image.size.width)
            if imageSize.height > Self.maxHeight {
                imageSize = NSSize(width: imageSize.width * Self.maxHeight / imageSize.height, height: Self.maxHeight)
            }
        } else {
            imageSize = NSSize(width: min(available, 320), height: 120)
        }
        imageSize = NSSize(width: max(24, floor(imageSize.width)), height: max(16, floor(imageSize.height)))

        var width = imageSize.width
        var captionRect = NSRect.zero
        if let caption = captionText(view) {
            width = max(width, min(available, ceil(caption.size().width) + 2))
            let bounds = caption.boundingRect(with: NSSize(width: width, height: .greatestFiniteMagnitude), options: [.usesLineFragmentOrigin, .usesFontLeading])
            captionRect = NSRect(x: 0, y: imageSize.height + Self.captionGap, width: width, height: ceil(bounds.height))
        }
        let imageRect = NSRect(x: floor((width - imageSize.width) / 2), y: 0, width: imageSize.width, height: imageSize.height)
        let height = captionRect.isEmpty ? imageSize.height : captionRect.maxY
        return Layout(image: imageRect, caption: captionRect, size: NSSize(width: ceil(width), height: ceil(height)))
    }

    private func captionText(_ view: WriterTextView?) -> NSAttributedString? {
        let caption = reference.caption.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !caption.isEmpty else { return nil }
        let family = view?.family ?? .serif
        let style = NSMutableParagraphStyle()
        style.alignment = .center
        style.lineHeightMultiple = 1.15
        return NSAttributedString(string: caption, attributes: [
            .font: WriterStyler.font(family, size: WriterStyler.bodySize(family) - 3, italic: true),
            .foregroundColor: view?.palette.secondaryText ?? NSColor.secondaryLabelColor,
            .paragraphStyle: style,
        ])
    }

    override func cellSize() -> NSSize {
        lastLayout?.size ?? NSSize(width: 320, height: 120)
    }

    override func cellBaselineOffset() -> NSPoint { .zero }

    override func cellFrame(for textContainer: NSTextContainer, proposedLineFragment lineFrag: NSRect, glyphPosition position: NSPoint, characterIndex charIndex: Int) -> NSRect {
        let layout = layout(available: max(60, lineFrag.width - 2), view: textContainer.textView as? WriterTextView)
        lastLayout = layout
        return NSRect(origin: .zero, size: layout.size)
    }

    override func draw(withFrame cellFrame: NSRect, in controlView: NSView?) {
        draw(cellFrame, view: controlView as? WriterTextView, characterIndex: nil)
    }

    override func draw(withFrame cellFrame: NSRect, in controlView: NSView?, characterIndex charIndex: Int, layoutManager: NSLayoutManager) {
        draw(cellFrame, view: controlView as? WriterTextView, characterIndex: charIndex)
    }

    private func draw(_ frame: NSRect, view: WriterTextView?, characterIndex: Int?) {
        let layout = lastLayout.flatMap { $0.size == frame.size ? $0 : nil } ?? layout(available: frame.width, view: view)
        let palette = view?.palette ?? .dark
        let imageRect = layout.image.offsetBy(dx: frame.minX, dy: frame.minY)
        let shape = NSBezierPath(roundedRect: imageRect, xRadius: 6, yRadius: 6)

        if let image = displayImage(view) {
            NSGraphicsContext.saveGraphicsState()
            shape.addClip()
            image.draw(in: imageRect, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: [.interpolation: NSImageInterpolation.high.rawValue])
            NSGraphicsContext.restoreGraphicsState()
        } else {
            palette.codeBlock.setFill()
            shape.fill()
            palette.rule.setStroke()
            shape.lineWidth = 1
            shape.setLineDash([5, 4], count: 2, phase: 0)
            shape.stroke()
            let text = NSAttributedString(string: "Bild nicht gefunden\n" + reference.source, attributes: [
                .font: NSFont.systemFont(ofSize: 12),
                .foregroundColor: palette.tertiaryText,
                .paragraphStyle: {
                    let style = NSMutableParagraphStyle()
                    style.alignment = .center
                    style.lineBreakMode = .byTruncatingMiddle
                    return style
                }(),
            ])
            let textRect = imageRect.insetBy(dx: 12, dy: 0)
            let height = text.boundingRect(with: textRect.size, options: [.usesLineFragmentOrigin]).height
            text.draw(with: NSRect(x: textRect.minX, y: textRect.midY - height / 2, width: textRect.width, height: height), options: [.usesLineFragmentOrigin])
        }

        if let characterIndex, let view, view.selectedRange() == NSRange(location: characterIndex, length: 1) {
            palette.accent.setStroke()
            let outline = NSBezierPath(roundedRect: imageRect.insetBy(dx: -3, dy: -3), xRadius: 8, yRadius: 8)
            outline.lineWidth = 2.5
            outline.stroke()
        }

        if let caption = captionText(view), !layout.caption.isEmpty {
            caption.draw(with: layout.caption.offsetBy(dx: frame.minX, dy: frame.minY), options: [.usesLineFragmentOrigin, .usesFontLeading])
        }
    }

    // A click selects the picture, a double click edits its caption.
    override func wantsToTrackMouse() -> Bool { true }

    override func wantsToTrackMouse(for theEvent: NSEvent, in cellFrame: NSRect, of controlView: NSView?, atCharacterIndex charIndex: Int) -> Bool { true }

    override func trackMouse(with theEvent: NSEvent, in cellFrame: NSRect, of controlView: NSView?, atCharacterIndex charIndex: Int, untilMouseUp flag: Bool) -> Bool {
        guard let view = controlView as? WriterTextView else { return false }
        view.selectImage(at: charIndex)
        if theEvent.clickCount >= 2 {
            if reference.plot != nil { view.editPlot(at: charIndex) } else { view.editImageCaption(at: charIndex) }
        }
        return true
    }
}
