import AppKit

/// Code blocks: language, indentation, formatting, and code written from a formula.
extension WriterTextView {
    // MARK: The block at the caret

    /// The code paragraphs around the caret, as one block.
    var codeRunAtCaret: NSRange? {
        guard let storage = textStorage, storage.length > 0, let paragraph = currentParagraph, paragraph.block == .code else { return nil }
        return WriterStyler.codeRun(around: paragraph.range, in: storage)
    }

    /// The language of the code block at the caret: nil without a block; `fence` is what the document says.
    var codeLanguageAtCaret: (language: CodeLanguage?, isExplicit: Bool)? {
        guard let storage = textStorage, let run = codeRunAtCaret else { return nil }
        let result = WriterStyler.language(of: run, in: storage)
        return (result.language, result.fence != nil)
    }

    /// Sets the language of the code block at the caret; nil lets the app guess.
    func setCodeLanguage(_ language: CodeLanguage?) {
        guard let storage = textStorage, let run = codeRunAtCaret, shouldChangeText(in: run, replacementString: nil) else { return }
        storage.beginEditing()
        if let language { storage.addAttribute(.writerCodeLanguage, value: language.fence, range: run) }
        else { storage.removeAttribute(.writerCodeLanguage, range: run) }
        storage.endEditing()
        didChangeText()
        onStateChange?()
    }

    /// Whole code paragraphs for a block: one per line, each with its newline.
    static func codeParagraphs(_ code: String, fence: String?) -> NSMutableAttributedString {
        var attributes: [NSAttributedString.Key: Any] = [.writerBlock: WriterBlock.code.rawValue, .writerListLevel: 0]
        if let fence { attributes[.writerCodeLanguage] = fence }
        let result = NSMutableAttributedString()
        for line in code.components(separatedBy: "\n") {
            result.append(NSAttributedString(string: line + "\n", attributes: attributes))
        }
        return result
    }

    // MARK: Formatting

    /// ⌥⇧⌘F: tidies the code block at the caret for its language.
    func formatCode() {
        guard let storage = textStorage, let run = codeRunAtCaret else { return }
        guard let language = WriterStyler.language(of: run, in: storage).language else {
            onNotice?("Für diesen Code ist keine Sprache gewählt. Python und SQL lassen sich formatieren.")
            return
        }
        var code = (storage.string as NSString).substring(with: run)
        let hasNewline = code.hasSuffix("\n")
        if hasNewline { code.removeLast() }
        let formatted = CodeFormatter.format(code, language: language)
        guard formatted != code else {
            onNotice?("Der Code ist schon ordentlich formatiert.")
            return
        }
        // The caret stays on its line.
        let caretLine = (storage.string as NSString).substring(with: NSRange(location: run.location, length: max(0, selectedRange().location - run.location)))
            .filter { $0 == "\n" }.count
        let fence = WriterStyler.language(of: run, in: storage).fence
        var text = Self.codeParagraphs(formatted, fence: fence)
        if !hasNewline { text.deleteCharacters(in: NSRange(location: text.length - 1, length: 1)) }
        performStructureEdit(in: run, with: text)
        let lines = formatted.components(separatedBy: "\n")
        let line = min(caretLine, lines.count - 1)
        let offset = lines[..<line].reduce(0) { $0 + $1.utf16.count + 1 } + lines[line].utf16.count
        setSelectedRange(NSRange(location: min(run.location + offset, storage.length), length: 0))
        onStateChange?()
    }

    // MARK: Indentation

    /// Return in a line of code: the next line starts indented as the language wants it. A line that holds only
    /// indentation ends the block, like an empty one.
    func codeNewline(in paragraph: WriterMarkdown.Paragraph) {
        guard let storage = textStorage, let run = codeRunAtCaret else { return super.insertNewline(nil) }
        let location = selectedRange().location
        let lineStart = paragraph.contentRange.location
        let before = (storage.string as NSString).substring(with: NSRange(location: lineStart, length: max(0, location - lineStart)))
        let language = WriterStyler.language(of: run, in: storage).language
        let indent = CodeIndentation.nextIndent(after: before, language: language)
        undoManager?.beginUndoGrouping()
        super.insertNewline(nil)
        if !indent.isEmpty { insertText(indent, replacementRange: selectedRange()) }
        undoManager?.endUndoGrouping()
    }

    /// Whether the paragraph holds only spaces (and the caret is at its end).
    func isIndentOnlyLine(_ paragraph: WriterMarkdown.Paragraph) -> Bool {
        guard let storage = textStorage, paragraph.contentRange.length > 0 else { return false }
        let text = (storage.string as NSString).substring(with: paragraph.contentRange)
        return text.allSatisfy { $0 == " " || $0 == "\t" } && selectedRange().location == NSMaxRange(paragraph.contentRange)
    }

    /// Tab and ⇧Tab in code: to the next tab stop, or the lines of the selection one level in or out.
    func indentCode(by direction: Int) {
        guard let storage = textStorage, let first = currentParagraph, first.block == .code else { return }
        let range = selectedRange()
        let run = codeRunAtCaret.map { WriterStyler.language(of: $0, in: storage).language } ?? nil
        let unit = (run ?? .python).indent
        let paragraphs = WriterMarkdown.paragraphs(of: storage, in: range).filter { $0.block == .code }
        guard let firstParagraph = paragraphs.first, let lastParagraph = paragraphs.last else { return }

        if range.length == 0, direction > 0 {
            // A tab stop every four columns.
            let column = range.location - first.contentRange.location
            insertText(String(repeating: " ", count: unit.count - column % unit.count), replacementRange: range)
            return
        }
        let union = NSUnionRange(firstParagraph.range, lastParagraph.range)
        let result = NSMutableAttributedString(attributedString: storage.attributedSubstring(from: union))
        var delta = 0
        var firstDelta = 0
        for (number, paragraph) in paragraphs.enumerated().reversed() {
            let content = NSRange(location: paragraph.contentRange.location - union.location, length: paragraph.contentRange.length)
            let line = result.attributedSubstring(from: content).string
            let changed = CodeIndentation.shifted(line, by: direction, unit: unit)
            if direction > 0 && line.isEmpty { continue }
            let attributes = result.attributes(at: content.location, effectiveRange: nil)
            result.replaceCharacters(in: content, with: NSAttributedString(string: changed, attributes: attributes))
            let change = changed.utf16.count - line.utf16.count
            delta += change
            if number == 0 { firstDelta = change }
        }
        performStructureEdit(in: union, with: result)
        if range.length == 0 {
            setSelectedRange(NSRange(location: max(first.contentRange.location, range.location + firstDelta), length: 0))
        } else {
            setSelectedRange(NSRange(location: union.location, length: max(0, union.length + delta)))
        }
        onStateChange?()
    }

    // MARK: Code from a formula

    /// Writes Python for the formula at `location` into a code block below it (and below its plot). A Python block
    /// that is already there is replaced.
    func insertPython(forFormulaAt location: Int) {
        guard let formula = formula(at: location) else { return }
        do {
            let code = try MathPythonTranslator.translate(latex: formula.latex)
            insertCodeBlock(code.text, language: .python, belowParagraphAt: location)
        } catch {
            onNotice?(error.localizedDescription)
        }
    }

    /// The formula the caret stands right behind: an inline one, or a display formula (and its plot) above.
    var formulaBeforeCaret: Int? {
        guard let storage = textStorage else { return nil }
        let caret = selectedRange().location
        if caret > 0, formula(at: caret - 1) != nil { return caret - 1 }
        var location = caret
        for _ in 0..<2 {
            guard location > 0 else { return nil }
            let above = (storage.string as NSString).paragraphRange(for: NSRange(location: location - 1, length: 0))
            if isDisplayFormula(at: above.location) { return above.location }
            location = above.location
        }
        return nil
    }

    func insertCodeBlock(_ code: String, language: CodeLanguage, belowParagraphAt location: Int, replacesExisting: Bool = true) {
        guard let storage = textStorage, location < storage.length else { return }
        let string = storage.string as NSString
        var paragraph = string.paragraphRange(for: NSRange(location: location, length: 0))
        // A plot belongs to its formula: the code goes below both.
        if isDisplayFormula(at: location), let plot = plotBelow(formulaAt: location) {
            paragraph = string.paragraphRange(for: NSRange(location: plot.location, length: 0))
        }
        let end = NSMaxRange(paragraph)
        var replaced = NSRange(location: end, length: 0)
        if replacesExisting, end < storage.length, WriterStyler.block(in: storage, at: end) == .code {
            let run = WriterStyler.codeRun(around: string.paragraphRange(for: NSRange(location: end, length: 0)), in: storage)
            if WriterStyler.language(of: run, in: storage).language == language { replaced = run }
        }
        let insertion = NSMutableAttributedString()
        // The paragraph at the very end of the text has no newline yet.
        if end == storage.length, string.character(at: end - 1) != 0x0A {
            insertion.append(NSAttributedString(string: "\n", attributes: storage.attributes(at: end - 1, effectiveRange: nil).filter { WriterMarkdown.paragraphKeys.contains($0.key) }))
        }
        insertion.append(Self.codeParagraphs(code, fence: language.fence))
        undoManager?.beginUndoGrouping()
        performStructureEdit(in: replaced, with: insertion)
        setSelectedRange(NSRange(location: min(replaced.location + insertion.length, storage.length), length: 0))
        setBlockOfEmptyCaretParagraph(.paragraph)
        undoManager?.endUndoGrouping()
        undoManager?.setActionName("Python-Code")
        scrollRangeToVisible(NSRange(location: replaced.location, length: insertion.length))
    }

    // MARK: Menu

    func codeMenuItems() -> [NSMenuItem] {
        guard let current = codeLanguageAtCaret else { return [] }
        if let run = codeRunAtCaret, mermaidCode(in: run) != nil {
            let diagram = ClosureMenuItem(title: "Als Diagramm einsetzen") { [weak self] in self?.convertMermaidBlock(run) }
            diagram.image = NSImage(systemSymbolName: "point.3.connected.trianglepath.dotted", accessibilityDescription: nil)
            return [diagram, .separator()]
        }
        let format = ClosureMenuItem(title: "Code formatieren (⌥⇧⌘F)") { [weak self] in self?.formatCode() }
        format.image = NSImage(systemSymbolName: "text.alignleft", accessibilityDescription: nil)
        let languageItem = NSMenuItem(title: "Sprache des Codes", action: nil, keyEquivalent: "")
        languageItem.image = NSImage(systemSymbolName: "chevron.left.forwardslash.chevron.right", accessibilityDescription: nil)
        let submenu = NSMenu()
        let auto = ClosureMenuItem(title: "Automatisch erkennen") { [weak self] in self?.setCodeLanguage(nil) }
        auto.state = current.isExplicit ? .off : .on
        submenu.addItem(auto)
        for language in CodeLanguage.allCases {
            let item = ClosureMenuItem(title: language.label) { [weak self] in self?.setCodeLanguage(language) }
            item.state = current.isExplicit && current.language == language ? .on : .off
            submenu.addItem(item)
        }
        languageItem.submenu = submenu
        return [format, languageItem, .separator()]
    }
}
