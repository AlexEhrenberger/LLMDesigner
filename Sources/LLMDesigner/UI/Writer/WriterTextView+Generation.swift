import AppKit

/// What the Draw Things sheet opens with.
struct WriterImageGenerationRequest: Identifiable {
    let id = UUID()
    var info: GeneratedImageInfo
    var caption: String
    /// Editing a picture or placeholder that is in the text (its place is tracked while the sheet is open).
    var isExisting: Bool
    /// The picture as it is now, for the sheet's preview.
    var source: String?
    var documentTitle: String
    /// The paragraphs around the place, for the model.
    var context: String
}

/// Pictures made with Draw Things: a placeholder marks the place and says what will be there; the picture is
/// made in the background and appears in its place. Making it anew writes a new file and points the reference
/// at it, so undo brings the old picture back.
extension WriterTextView {
    static let generationKey = "generatedImage"

    /// ⌥⌘G, the toolbar and the context menu: the selected generated picture is edited, else a new one starts
    /// at the caret.
    func generateImageAtCaret() {
        if let image = selectedImage, image.reference.generated { return editGeneratedImage(at: image.location) }
        trackedRanges[Self.generationKey] = nil
        let location = selectedRange().location
        onImageGeneration?(WriterImageGenerationRequest(
            info: onImageDefaults?() ?? GeneratedImageInfo(), caption: "", isExisting: false, source: nil,
            documentTitle: onDocumentTitle?() ?? "", context: surroundingText(at: location)
        ))
    }

    func editGeneratedImage(at location: Int) {
        guard let attachment = image(at: location), attachment.reference.generated else { return }
        let reference = attachment.reference
        trackedRanges[Self.generationKey] = NSRange(location: location, length: 1)
        var info = WriterImageStore.generationInfo(for: reference.source) ?? onImageDefaults?() ?? GeneratedImageInfo()
        info.seed = nil
        onImageGeneration?(WriterImageGenerationRequest(
            info: info, caption: reference.caption, isExisting: true, source: reference.source,
            documentTitle: onDocumentTitle?() ?? "", context: surroundingText(at: location)
        ))
    }

    /// The sheet's result. `generate` makes the picture right away; otherwise the recipe and caption are kept
    /// for later (a placeholder stays a placeholder).
    func applyGeneratedImage(info: GeneratedImageInfo, caption: String, generate: Bool, isExisting: Bool) {
        let caption = caption.trimmingCharacters(in: .whitespacesAndNewlines)
        let tracked = isExisting ? trackedRanges[Self.generationKey] : nil
        trackedRanges[Self.generationKey] = nil
        if let tracked, let attachment = image(at: tracked.location), attachment.reference.generated {
            let location = tracked.location
            let reference = attachment.reference
            let isGenerating = ImageGenerationCenter.phases[reference.source].map { if case .failed = $0 { false } else { true } } ?? false
            if generate && (!reference.isPlaceholder || isGenerating) {
                // A new file; the old picture shows (dimmed) until the new one is there.
                onCancelImageGeneration?(reference.source)
                var next = info
                next.previous = reference.isPlaceholder ? WriterImageStore.generationInfo(for: reference.source)?.previous : reference.source
                let source = WriterImageStore.newGeneratedSource()
                WriterImageStore.saveGenerationInfo(next, for: source)
                updateImage(at: location) {
                    $0.source = source
                    $0.caption = caption
                }
                undoManager?.setActionName("Bild neu generieren")
                onGenerateImage?(source, next)
            } else {
                var kept = info
                kept.previous = WriterImageStore.generationInfo(for: reference.source)?.previous
                if !reference.isPlaceholder, let old = WriterImageStore.generationInfo(for: reference.source) {
                    // The finished picture keeps the seed it was made with.
                    kept.seed = old.seed
                    kept.created = old.created
                    kept.duration = old.duration
                    kept.model = old.model
                }
                WriterImageStore.saveGenerationInfo(kept, for: reference.source)
                updateImage(at: location) { $0.caption = caption }
                refreshGeneratedImage(reference.source)
                if generate { onGenerateImage?(reference.source, kept) }
            }
            selectImage(at: location)
            return
        }

        // A new placeholder at the caret.
        let source = WriterImageStore.newGeneratedSource()
        WriterImageStore.saveGenerationInfo(info, for: source)
        let reference = WriterImageReference(source: source, caption: caption, width: 75, generated: true)
        let block = NSMutableAttributedString(attachment: WriterImageAttachment(reference: reference))
        block.append(NSAttributedString(string: "\n"))
        block.addAttributes([.writerBlock: WriterBlock.image.rawValue, .writerListLevel: 0], range: NSRange(location: 0, length: block.length))
        guard let start = insertBlock(block) else { return }
        undoManager?.setActionName(generate ? "Bild generieren" : "Bildplatzhalter")
        selectImage(at: start)
        scrollRangeToVisible(NSRange(location: start, length: block.length))
        if generate { onGenerateImage?(source, info) }
    }

    /// Makes the picture at `location` again: with a new seed, or (a placeholder) for the first time.
    func regenerateImage(at location: Int) {
        guard let attachment = image(at: location), attachment.reference.generated else { return }
        let reference = attachment.reference
        guard var info = WriterImageStore.generationInfo(for: reference.source),
              !info.prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return editGeneratedImage(at: location)
        }
        info.seed = nil
        trackedRanges[Self.generationKey] = NSRange(location: location, length: 1)
        applyGeneratedImage(info: info, caption: reference.caption, generate: true, isExisting: true)
    }

    func cancelImageGeneration(at location: Int) {
        guard let attachment = image(at: location) else { return }
        onCancelImageGeneration?(attachment.reference.source)
    }

    /// The picture's phase changed or it is done: its paragraph is laid out and drawn anew.
    func refreshGeneratedImage(_ source: String) {
        guard let storage = textStorage, let layoutManager else { return }
        storage.enumerateAttribute(.attachment, in: NSRange(location: 0, length: storage.length)) { value, range, _ in
            guard let attachment = value as? WriterImageAttachment, attachment.reference.source == source else { return }
            layoutManager.invalidateLayout(forCharacterRange: range, actualCharacterRange: nil)
            layoutManager.invalidateDisplay(forCharacterRange: range)
        }
        if selectedImage?.reference.source == source { DispatchQueue.main.async { [weak self] in self?.updateImageControls() } }
    }

    /// Generated pictures that are being made; their placeholders show the time running.
    var generatingSources: [String] {
        guard let storage = textStorage else { return [] }
        var sources: [String] = []
        storage.enumerateAttribute(.attachment, in: NSRange(location: 0, length: storage.length)) { value, _, _ in
            guard let attachment = value as? WriterImageAttachment, attachment.reference.generated,
                  case .running = ImageGenerationCenter.phases[attachment.reference.source] else { return }
            sources.append(attachment.reference.source)
        }
        return sources
    }

    func redrawGeneratingImages() {
        guard let storage = textStorage, let layoutManager else { return }
        storage.enumerateAttribute(.attachment, in: NSRange(location: 0, length: storage.length)) { value, range, _ in
            guard let attachment = value as? WriterImageAttachment, attachment.reference.generated, attachment.reference.isPlaceholder else { return }
            layoutManager.invalidateDisplay(forCharacterRange: range)
        }
    }

    /// The text before and after a place (without pictures and formulas), for the model.
    func surroundingText(at location: Int) -> String {
        guard let storage = textStorage else { return "" }
        let string = storage.string as NSString
        let location = min(max(0, location), string.length)
        let start = max(0, location - 1400)
        let end = min(string.length, location + 500)
        var before = string.substring(with: NSRange(location: start, length: location - start))
        var after = string.substring(with: NSRange(location: location, length: end - location))
        // Whole paragraphs where the cut falls in the middle of one.
        if start > 0, let newline = before.firstIndex(of: "\n") { before = String(before[before.index(after: newline)...]) }
        if end < string.length, let newline = after.lastIndex(of: "\n") { after = String(after[..<newline]) }
        let text = before + (after.isEmpty ? "" : "\n[Hier steht das Bild]\n" + after)
        return text.replacingOccurrences(of: "\u{FFFC}", with: "").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: Menu

    func generationMenuItems(at location: Int) -> [NSMenuItem] {
        guard let attachment = image(at: location), attachment.reference.generated else { return [] }
        let reference = attachment.reference
        let phase = ImageGenerationCenter.phases[reference.source]
        var items: [NSMenuItem] = []
        let edit = ClosureMenuItem(title: "Bild beschreiben und generieren …") { [weak self] in self?.editGeneratedImage(at: location) }
        edit.image = NSImage(systemSymbolName: "wand.and.stars", accessibilityDescription: nil)
        items.append(edit)
        switch phase {
        case .queued, .running:
            let cancel = ClosureMenuItem(title: "Generieren abbrechen") { [weak self] in self?.cancelImageGeneration(at: location) }
            cancel.image = NSImage(systemSymbolName: "xmark.circle", accessibilityDescription: nil)
            items.append(cancel)
        default:
            let again = ClosureMenuItem(title: reference.isPlaceholder ? "Jetzt generieren" : "Neu generieren (anderer Seed)") { [weak self] in
                self?.regenerateImage(at: location)
            }
            again.image = NSImage(systemSymbolName: "arrow.clockwise", accessibilityDescription: nil)
            items.append(again)
        }
        if let prompt = WriterImageStore.generationInfo(for: reference.source)?.prompt, !prompt.isEmpty {
            let copy = ClosureMenuItem(title: "Prompt kopieren") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(prompt, forType: .string)
            }
            copy.image = NSImage(systemSymbolName: "doc.on.doc", accessibilityDescription: nil)
            items.append(copy)
        }
        return items
    }
}
