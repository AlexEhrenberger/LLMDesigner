import AppKit
import NaturalLanguage

/// Dictation into the document and reading it aloud.
extension WriterTextView {
    // MARK: Dictation

    /// Shows words that are still being recognised in grey at the caret. They are not part of the document:
    /// not saved, not undoable, and replaced by the next update.
    func showDictationPreview(_ text: String) {
        guard let storage = textStorage else { return }
        let location = removeDictationPreview() ?? selectedRange().location
        let words = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !words.isEmpty else {
            setSelectedRange(NSRange(location: location, length: 0))
            return
        }
        var attributes = typingAttributes
        attributes[.writerDictationPreview] = true
        let preview = NSAttributedString(string: spaced(words, at: location), attributes: attributes)
        storage.replaceCharacters(in: NSRange(location: location, length: 0), with: preview)
        setSelectedRange(NSRange(location: location, length: 0))
        scrollRangeToVisible(NSRange(location: location, length: preview.length))
    }

    /// Removes the grey preview; returns where it was.
    @discardableResult
    func removeDictationPreview() -> Int? {
        guard let storage = textStorage, storage.length > 0 else { return nil }
        var ranges: [NSRange] = []
        storage.enumerateAttribute(.writerDictationPreview, in: NSRange(location: 0, length: storage.length)) { value, range, _ in
            if value != nil { ranges.append(range) }
        }
        guard !ranges.isEmpty else { return nil }
        for range in ranges.reversed() { storage.deleteCharacters(in: range) }
        return ranges[0].location
    }

    /// Writes recognised text at the caret, as if typed (undoable). "Neuer Absatz" or "neue Zeile" start a
    /// new paragraph.
    func insertDictatedText(_ text: String) {
        let location = removeDictationPreview() ?? selectedRange().location
        setSelectedRange(NSRange(location: location, length: 0))
        resetTypingAttributes()
        breakUndoCoalescing()
        var startsParagraph = false
        for piece in Self.dictationPieces(text) {
            switch piece {
            case .paragraph:
                insertNewline(nil)
                startsParagraph = true
            case .text(var words):
                if startsParagraph, let first = words.first {
                    words = first.uppercased() + words.dropFirst()
                }
                startsParagraph = false
                let caret = selectedRange().location
                insertText(spaced(words, at: caret), replacementRange: NSRange(location: caret, length: 0))
            }
        }
        breakUndoCoalescing()
        scrollRangeToVisible(selectedRange())
    }

    func endDictation() {
        removeDictationPreview()
    }

    enum DictationPiece: Equatable {
        case text(String)
        case paragraph
    }

    /// Splits dictated text at the spoken commands for a new paragraph.
    static func dictationPieces(_ text: String) -> [DictationPiece] {
        let pattern = #"[\s,]*\b(neuer absatz|neue zeile|nächster absatz|new paragraph|new line)\b[\s,.]*"#
        guard let expression = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
            return [.text(text)]
        }
        var pieces: [DictationPiece] = []
        var last = text.startIndex
        for match in expression.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
            guard let range = Range(match.range, in: text) else { continue }
            let before = text[last..<range.lowerBound].trimmingCharacters(in: .whitespaces)
            if !before.isEmpty { pieces.append(.text(before)) }
            pieces.append(.paragraph)
            last = range.upperBound
        }
        let rest = text[last...].trimmingCharacters(in: .whitespaces)
        if !rest.isEmpty { pieces.append(.text(rest)) }
        return pieces
    }

    /// A space in front of the words unless they start a line or follow a space, or begin with punctuation.
    private func spaced(_ words: String, at location: Int) -> String {
        guard let storage = textStorage, location > 0, location <= storage.length else { return words }
        let previous = (storage.string as NSString).character(at: location - 1)
        guard let scalar = Unicode.Scalar(previous) else { return words }
        let character = Character(scalar)
        if character.isWhitespace || character.isNewline || character == WriterMarkdown.lineSeparator { return words }
        if let first = words.first, ".,;:!?)…".contains(first) { return words }
        return " " + words
    }

    // MARK: Reading aloud

    /// What a voice reads for part of the document, and where each spoken piece is in the document.
    struct SpeechScript {
        var text = ""
        /// Per paragraph: its range in `text` and in the document (same length; punctuation added for the
        /// voice comes after it).
        var segments: [(speech: NSRange, document: NSRange)] = []
        /// Sentences of `text`, for highlighting a whole sentence while the macOS voice reports words.
        var sentences: [NSRange] = []

        func documentRange(for speech: NSRange) -> NSRange? {
            let sentence = sentences.first { NSLocationInRange(speech.location, $0) } ?? speech
            var result: NSRange?
            for segment in segments {
                let overlap = NSIntersectionRange(segment.speech, sentence)
                guard overlap.length > 0 else { continue }
                let piece = NSRange(location: segment.document.location + overlap.location - segment.speech.location, length: overlap.length)
                result = result.map { NSUnionRange($0, piece) } ?? piece
            }
            return result
        }
    }

    /// The selection, or everything from the paragraph with the caret on (the whole document when the caret
    /// is at the end). Code blocks, Markdown kept as text and lines are skipped.
    func speechScript() -> SpeechScript {
        guard let storage = textStorage, storage.length > 0 else { return SpeechScript() }
        let selection = selectedRange()
        var range: NSRange
        if hasTextSelection {
            range = selection
        } else if selection.location >= storage.length || storage.string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            range = NSRange(location: 0, length: storage.length)
        } else {
            let start = (storage.string as NSString).paragraphRange(for: NSRange(location: selection.location, length: 0)).location
            range = NSRange(location: start, length: storage.length - start)
        }

        var script = SpeechScript()
        for paragraph in WriterMarkdown.paragraphs(of: storage, in: range) {
            guard ![.code, .raw, .rule].contains(paragraph.block) else { continue }
            let part = NSIntersectionRange(paragraph.contentRange, range)
            guard part.length > 0 else { continue }
            var piece = (storage.string as NSString).substring(with: part)
            piece = piece.replacingOccurrences(of: String(WriterMarkdown.lineSeparator), with: " ")
                .replacingOccurrences(of: "\u{FFFC}", with: " ")
            guard piece.contains(where: { $0.isLetter || $0.isNumber }) else { continue }
            if !script.text.isEmpty { script.text += "\n" }
            let start = (script.text as NSString).length
            script.text += piece
            script.segments.append((NSRange(location: start, length: (piece as NSString).length), part))
            // Headings and list items have no full stop; the voice should still pause after them.
            if let last = piece.trimmingCharacters(in: .whitespaces).last, !".!?:…".contains(last) {
                script.text += "."
            }
        }

        let tokenizer = NLTokenizer(unit: .sentence)
        tokenizer.string = script.text
        tokenizer.enumerateTokens(in: script.text.startIndex..<script.text.endIndex) { tokenRange, _ in
            script.sentences.append(NSRange(tokenRange, in: script.text))
            return true
        }
        return script
    }

    /// Marks the passage being read (or nothing) without touching the text.
    func highlightSpoken(_ range: NSRange?) {
        guard let layoutManager, let storage = textStorage else { return }
        layoutManager.removeTemporaryAttribute(.backgroundColor, forCharacterRange: NSRange(location: 0, length: storage.length))
        guard let range, NSMaxRange(range) <= storage.length else { return }
        layoutManager.addTemporaryAttribute(.backgroundColor, value: palette.accent.withAlphaComponent(palette.isLight ? 0.18 : 0.26), forCharacterRange: range)
        scrollRangeToVisible(range)
    }

    // MARK: Context menu

    override func menu(for event: NSEvent) -> NSMenu? {
        let menu = super.menu(for: event) ?? NSMenu()
        // The system's font and layout submenus would format past the Markdown meaning; the toolbar does that.
        let foreign: Set<Selector> = [#selector(NSFontManager.orderFrontFontPanel(_:)), #selector(NSTextView.alignLeft(_:)), #selector(NSResponder.makeBaseWritingDirectionNatural(_:)), #selector(NSTextView.changeLayoutOrientation(_:))]
        for item in menu.items.reversed() where item.submenu?.items.contains(where: { $0.action.map(foreign.contains) ?? false }) == true {
            menu.removeItem(item)
        }
        let hasSelection = hasTextSelection
        let items = [
            NSMenuItem(
                title: isReadingAloud ? "Vorlesen stoppen" : (hasSelection ? "Markierung vorlesen" : "Ab hier vorlesen"),
                action: #selector(contextReadAloud), keyEquivalent: ""
            ),
            NSMenuItem(title: isDictating ? "Diktat beenden" : "Hier diktieren", action: #selector(contextDictate), keyEquivalent: ""),
            NSMenuItem.separator(),
        ]
        items[0].image = NSImage(systemSymbolName: isReadingAloud ? "stop.fill" : "speaker.wave.2", accessibilityDescription: nil)
        items[1].image = NSImage(systemSymbolName: isDictating ? "mic.slash" : "mic", accessibilityDescription: nil)
        for (index, item) in items.enumerated() {
            item.target = self
            menu.insertItem(item, at: index)
        }
        for (index, item) in assistantMenuItems(hasSelection: hasTextSelection).enumerated() {
            menu.insertItem(item, at: index)
        }
        return menu
    }

    /// The assistant's entries at the top of the context menu.
    private func assistantMenuItems(hasSelection: Bool) -> [NSMenuItem] {
        func item(_ title: String, _ symbol: String, _ command: WriterAssistantCommand) -> NSMenuItem {
            let item = AssistantMenuItem(title: title, command: command) { [weak self] in self?.onAssistant?($0) }
            item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
            return item
        }
        var items: [NSMenuItem] = []
        if hasSelection {
            let rewrite = NSMenuItem(title: "Umformulieren", action: nil, keyEquivalent: "")
            rewrite.image = NSImage(systemSymbolName: "arrow.triangle.2.circlepath", accessibilityDescription: nil)
            let submenu = NSMenu()
            for preset in WriterPrompts.Rewrite.allCases {
                submenu.addItem(item(preset.label, "sparkles", .rewrite(preset)))
            }
            rewrite.submenu = submenu
            items.append(rewrite)
            items.append(item("Ausformulieren", "text.append", .expand))
            items.append(item("Rechtschreibung & Grammatik prüfen", "textformat.abc.dottedunderline", .check(.language)))
            items.append(item("Auf Plausibilität prüfen", "checkmark.seal", .check(.plausibility)))
            items.append(item("Frage zur Markierung …", "questionmark.bubble", .askAboutSelection))
        } else {
            items.append(item("KI-Cursor hierher setzen", "character.cursor.ibeam", .placeCursorHere))
            items.append(item("KI hier weiterschreiben lassen", "sparkles", .continueHere))
            items.append(item("Dokument auf Rechtschreibung prüfen", "textformat.abc.dottedunderline", .check(.language)))
            items.append(item("Dokument auf Plausibilität prüfen", "checkmark.seal", .check(.plausibility)))
        }
        items.append(.separator())
        return items
    }

    @objc private func contextReadAloud() { onReadAloud?() }
    @objc private func contextDictate() { onDictate?() }

    override func cancelOperation(_ sender: Any?) {
        if isReadingAloud {
            onStopReading?()
        } else {
            super.cancelOperation(sender)
        }
    }
}

/// A context menu entry that hands its command to the assistant.
private final class AssistantMenuItem: NSMenuItem {
    private let command: WriterAssistantCommand
    private let handler: (WriterAssistantCommand) -> Void

    init(title: String, command: WriterAssistantCommand, handler: @escaping (WriterAssistantCommand) -> Void) {
        self.command = command
        self.handler = handler
        super.init(title: title, action: #selector(run), keyEquivalent: "")
        target = self
    }

    required init(coder: NSCoder) { fatalError("init(coder:) is not used") }

    @objc private func run() { handler(command) }
}
