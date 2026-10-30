import AppKit

/// Boxes (definitions, notes …) and sections in columns: both are paragraphs that share an object (`.writerBox`,
/// `.writerColumns`). Changing one puts a new object on its paragraphs, so undo brings the old one back.
extension WriterTextView {
    // MARK: Boxes

    /// The box with the caret and its paragraphs.
    var boxAtCaret: (box: WriterBox, range: NSRange)? {
        guard let storage = textStorage, storage.length > 0 else { return nil }
        let location = min(selectedRange().location, storage.length - 1)
        guard let box = storage.attribute(.writerBox, at: location, effectiveRange: nil) as? WriterBox,
              let range = containerRange(.writerBox, at: location) else { return nil }
        return (box, range)
    }

    /// A box around the selected paragraphs; without a selection a new empty box below the paragraph (or the empty
    /// paragraph at the caret becomes one).
    func insertBox(_ kind: WriterBoxKind) {
        guard let storage = textStorage else { return }
        let box = WriterBox(style: WriterBoxStyle(kind: kind))
        let selected = WriterMarkdown.paragraphs(of: storage, in: selectedRange()).filter { $0.range.length > 0 }
        if selectedRange().length > 0, !selected.isEmpty {
            let fitting = selected.filter { WriterBox.holds($0.block) && $0.cell == nil }
            guard let first = fitting.first, let last = fitting.last else {
                onNotice?("Tabellen, Code und Kapitel können nicht in einen Kasten – markiere Text, Listen oder Formeln.")
                return
            }
            setContainer(.writerBox, to: box, in: NSUnionRange(first.range, last.range), only: fitting, actionName: "Kasten")
            return
        }
        if let paragraph = currentParagraph, paragraph.contentRange.length == 0, paragraph.cell == nil, paragraph.block == .paragraph {
            setContainer(.writerBox, to: box, in: paragraph.range, only: [paragraph], actionName: "Kasten")
            return
        }
        // A new paragraph below, in the box.
        let attributes: [NSAttributedString.Key: Any] = [.writerBlock: WriterBlock.paragraph.rawValue, .writerListLevel: 0, .writerBox: box]
        let text = NSAttributedString(string: "\n", attributes: attributes)
        guard let start = insertBlock(text) else { return }
        setSelectedRange(NSRange(location: start, length: 0))
        typingAttributes = WriterStyler.typingAttributes(block: .paragraph, level: 0, semantic: attributes, family: family, palette: palette)
        undoManager?.setActionName("Kasten")
        onStateChange?()
    }

    /// Gives the box with the caret another look or place.
    func setBoxStyle(_ style: WriterBoxStyle) {
        guard let (box, range) = boxAtCaret, box.style != style else { return }
        replaceContainer(.writerBox, old: box, with: box.with(style), in: range, actionName: "Kasten")
    }

    /// The box's paragraphs become ordinary ones again.
    func removeBox() {
        guard let (box, range) = boxAtCaret else { return }
        replaceContainer(.writerBox, old: box, with: nil, in: range, actionName: "Kasten auflösen")
    }

    // MARK: Columns

    var sectionAtCaret: (section: WriterColumnSection, range: NSRange)? {
        guard let storage = textStorage, storage.length > 0 else { return nil }
        let location = min(selectedRange().location, storage.length - 1)
        guard let section = storage.attribute(.writerColumns, at: location, effectiveRange: nil) as? WriterColumnSection,
              let range = containerRange(.writerColumns, at: location) else { return nil }
        return (section, range)
    }

    /// The selected paragraphs (without a selection the paragraph at the caret) are set in columns.
    func setColumns(_ style: WriterColumnStyle) {
        guard let storage = textStorage, storage.length > 0 else { return }
        if let (section, range) = sectionAtCaret {
            guard section.style != style else { return }
            return replaceContainer(.writerColumns, old: section, with: WriterColumnSection(style: style), in: range, actionName: "Spalten")
        }
        var range = selectedRange()
        if range.location >= storage.length { range.location = max(0, storage.length - 1) }
        let paragraphs = WriterMarkdown.paragraphs(of: storage, in: range).filter { $0.range.length > 0 && $0.cell == nil && WriterColumnSection.holds($0.block) }
        guard let first = paragraphs.first, let last = paragraphs.last else {
            onNotice?("Tabellen, Kapitel und Inhaltsverzeichnisse bleiben einspaltig – markiere die Absätze für die Spalten.")
            return
        }
        setContainer(.writerColumns, to: WriterColumnSection(style: style), in: NSUnionRange(first.range, last.range), only: paragraphs, actionName: "Zwei Spalten")
    }

    /// The section with the caret goes back to one column; `fromHere`: only from the caret's paragraph on.
    func removeColumns(fromHere: Bool = false) {
        guard let (section, range) = sectionAtCaret, let storage = textStorage else { return }
        var target = range
        if fromHere {
            let start = (storage.string as NSString).paragraphRange(for: NSRange(location: selectedRange().location, length: 0)).location
            target = NSRange(location: start, length: NSMaxRange(range) - start)
        }
        replaceContainer(.writerColumns, old: section, with: nil, in: target, actionName: "Eine Spalte")
    }

    /// A column break below the paragraph: the text after it starts the next column.
    func insertColumnBreak() {
        guard let (section, _) = sectionAtCaret else {
            onNotice?("Ein Spaltenumbruch gehört in einen Abschnitt mit Spalten.")
            return
        }
        let attributes: [NSAttributedString.Key: Any] = [.writerBlock: WriterBlock.rule.rawValue, .writerListLevel: 0, .writerColumns: section]
        let text = NSMutableAttributedString(attachment: WriterColumnBreakAttachment())
        text.addAttributes(attributes, range: NSRange(location: 0, length: text.length))
        text.append(NSAttributedString(string: "\n", attributes: attributes))
        guard let start = insertBlock(text) else { return }
        setSelectedRange(NSRange(location: min(start + text.length, textStorage?.length ?? 0), length: 0))
        undoManager?.setActionName("Spaltenumbruch")
        onStateChange?()
    }

    // MARK: Shared

    /// Puts a box or section on these paragraphs, as one undoable step.
    private func setContainer(_ key: NSAttributedString.Key, to value: NSObject, in range: NSRange, only paragraphs: [WriterMarkdown.Paragraph],
                              actionName: String) {
        guard let storage = textStorage, shouldChangeText(in: range, replacementString: nil) else { return }
        storage.beginEditing()
        for paragraph in paragraphs { storage.addAttribute(key, value: value, range: paragraph.range) }
        storage.endEditing()
        didChangeText()
        undoManager?.setActionName(actionName)
        needsDisplay = true
        onStateChange?()
    }

    /// Replaces a box or section by another (nil: none) on its paragraphs in `range`, as one undoable step.
    private func replaceContainer(_ key: NSAttributedString.Key, old: NSObject, with new: NSObject?, in range: NSRange, actionName: String) {
        guard let storage = textStorage, range.length > 0, shouldChangeText(in: range, replacementString: nil) else { return }
        storage.beginEditing()
        storage.enumerateAttribute(key, in: range) { value, run, _ in
            guard (value as? NSObject) === old else { return }
            if let new { storage.addAttribute(key, value: new, range: run) } else { storage.removeAttribute(key, range: run) }
        }
        storage.endEditing()
        didChangeText()
        undoManager?.setActionName(actionName)
        resetTypingAttributes()
        needsDisplay = true
        onStateChange?()
    }

    /// Return in an empty last paragraph of a box leaves the box.
    func leaveBoxIfEmptyEnd() -> Bool {
        guard let paragraph = currentParagraph, paragraph.contentRange.length == 0, let box = paragraph.box,
              let range = containerRange(.writerBox, at: paragraph.range.location), NSMaxRange(paragraph.range) >= NSMaxRange(range),
              range.location < paragraph.range.location else { return false }
        replaceContainer(.writerBox, old: box, with: nil, in: paragraph.range, actionName: "Kasten verlassen")
        return true
    }

    // MARK: Menu

    func boxMenuItems() -> [NSMenuItem] {
        var items: [NSMenuItem] = []
        if let (box, _) = boxAtCaret {
            let menu = NSMenu()
            for kind in WriterBoxKind.allCases {
                let item = ClosureMenuItem(title: kind.label) { [weak self] in
                    var style = box.style
                    style.kind = kind
                    style.title = nil
                    self?.setBoxStyle(style)
                }
                item.state = box.style.kind == kind ? .on : .off
                menu.addItem(item)
            }
            menu.addItem(.separator())
            for position in WriterBoxStyle.Position.allCases {
                let item = ClosureMenuItem(title: position.label) { [weak self] in
                    var style = box.style
                    style.position = position
                    self?.setBoxStyle(style)
                }
                item.image = NSImage(systemSymbolName: position.symbol, accessibilityDescription: nil)
                item.state = box.style.position == position ? .on : .off
                menu.addItem(item)
            }
            let wrap = ClosureMenuItem(title: "Text umfließt den Kasten") { [weak self] in
                var style = box.style
                style.wraps.toggle()
                if style.wraps, style.position == .full || style.position == .center { style.position = .right }
                self?.setBoxStyle(style)
            }
            wrap.state = box.style.floats ? .on : .off
            menu.addItem(wrap)
            menu.addItem(.separator())
            menu.addItem(ClosureMenuItem(title: "Kasten auflösen") { [weak self] in self?.removeBox() })
            let entry = NSMenuItem(title: "Kasten", action: nil, keyEquivalent: "")
            entry.image = NSImage(systemSymbolName: box.style.kind.symbol, accessibilityDescription: nil)
            entry.submenu = menu
            items.append(entry)
        } else if selectedEmbed == nil, currentParagraph?.cell == nil {
            let menu = NSMenu()
            for kind in WriterBoxKind.allCases {
                let item = ClosureMenuItem(title: kind.label) { [weak self] in self?.insertBox(kind) }
                item.image = NSImage(systemSymbolName: kind.symbol, accessibilityDescription: nil)
                menu.addItem(item)
            }
            let entry = NSMenuItem(title: hasTextSelection ? "In einen Kasten setzen" : "Kasten einfügen", action: nil, keyEquivalent: "")
            entry.image = NSImage(systemSymbolName: "square.text.square", accessibilityDescription: nil)
            entry.submenu = menu
            items.append(entry)
        }
        if let (section, _) = sectionAtCaret {
            let menu = NSMenu()
            menu.addItem(ClosureMenuItem(title: "Spaltenumbruch einfügen") { [weak self] in self?.insertColumnBreak() })
            let rule = ClosureMenuItem(title: "Linie zwischen den Spalten") { [weak self] in
                var style = section.style
                style.rule.toggle()
                self?.setColumns(style)
            }
            rule.state = section.style.rule ? .on : .off
            menu.addItem(rule)
            menu.addItem(.separator())
            menu.addItem(ClosureMenuItem(title: "Ab hier eine Spalte") { [weak self] in self?.removeColumns(fromHere: true) })
            menu.addItem(ClosureMenuItem(title: "Ganzer Abschnitt eine Spalte") { [weak self] in self?.removeColumns() })
            let entry = NSMenuItem(title: "Spalten", action: nil, keyEquivalent: "")
            entry.image = NSImage(systemSymbolName: "rectangle.split.2x1", accessibilityDescription: nil)
            entry.submenu = menu
            items.append(entry)
        } else if currentParagraph?.cell == nil {
            let columns = ClosureMenuItem(title: hasTextSelection ? "In zwei Spalten setzen" : "Ab hier zwei Spalten") { [weak self] in
                self?.setColumns(WriterColumnStyle())
            }
            columns.image = NSImage(systemSymbolName: "rectangle.split.2x1", accessibilityDescription: nil)
            items.append(columns)
        }
        return items
    }
}
