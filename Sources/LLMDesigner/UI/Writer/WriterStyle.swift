import AppKit

/// Colours of Writer Studio: a dark sheet that matches the dark design, or white paper. Around the sheet lies the
/// app's desk (`Theme.desk`), which follows the design.
struct WriterPalette: Equatable {
    let isLight: Bool
    let windowBackground: NSColor
    let page: NSColor
    let pageBorder: NSColor
    let text: NSColor
    let secondaryText: NSColor
    let tertiaryText: NSColor
    let accent: NSColor
    let codeBlock: NSColor
    let inlineCodeText: NSColor
    let inlineCodeBackground: NSColor
    let quoteBar: NSColor
    let selection: NSColor
    let rule: NSColor
    let tableBorder: NSColor
    let tableHeader: NSColor
    /// A table's printed lines (`WriterTableLines`), stronger than the helper lines between other cells.
    var tableLine: NSColor { text.withAlphaComponent(isLight ? 0.55 : 0.5) }
    /// Slides: title slides centre their text; documents keep it natural.
    var alignment: NSTextAlignment = .natural
    /// A slide's text over its background: nothing of the page is drawn.
    var isSlide = false
    /// How the document's page is set: DIN A4, paperback or Normseite (see WriterStyle+Pages.swift).
    var format: WriterPageFormat = .standard
    /// The user's own paper and text size, for `format == .custom`.
    var pageSetup: WriterPageSetup?

    /// The text size in print: the format's, or the user's own.
    var printSize: CGFloat {
        format == .custom ? CGFloat(pageSetup?.fontSize ?? Double(WriterFont.printSize)) : format.printSize
    }

    /// Screen points per point of print for this family on this page.
    func screenScale(_ family: WriterFont) -> CGFloat {
        family.screenScale(onSlide: isSlide, format: format, printSize: printSize)
    }

    static let dark = WriterPalette(
        isLight: false,
        windowBackground: NSColor(Theme.desk),
        page: NSColor(hex: 0x141417),
        pageBorder: NSColor.white.withAlphaComponent(0.07),
        text: NSColor(hex: 0xE8E8EC),
        secondaryText: NSColor(hex: 0xA1A1A9),
        tertiaryText: NSColor(hex: 0x6E6E77),
        accent: NSColor(hex: 0xA996FF),
        codeBlock: NSColor.white.withAlphaComponent(0.045),
        inlineCodeText: NSColor(hex: 0xE4DAFF),
        inlineCodeBackground: NSColor.white.withAlphaComponent(0.08),
        quoteBar: NSColor(hex: 0xA996FF).withAlphaComponent(0.55),
        selection: NSColor(hex: 0xA996FF).withAlphaComponent(0.32),
        rule: NSColor.white.withAlphaComponent(0.16),
        tableBorder: NSColor.white.withAlphaComponent(0.15),
        tableHeader: NSColor.white.withAlphaComponent(0.05)
    )

    static let light = WriterPalette(
        isLight: true,
        windowBackground: NSColor(Theme.desk),
        page: NSColor(hex: 0xFFFFFF),
        pageBorder: NSColor.black.withAlphaComponent(0.08),
        text: NSColor(hex: 0x1C1C1F),
        secondaryText: NSColor(hex: 0x55555D),
        tertiaryText: NSColor(hex: 0x8A8A92),
        accent: NSColor(hex: 0x6A54E0),
        codeBlock: NSColor(hex: 0xF3F2F7),
        inlineCodeText: NSColor(hex: 0x5B43D6),
        inlineCodeBackground: NSColor(hex: 0xEEEBFA),
        quoteBar: NSColor(hex: 0x6A54E0).withAlphaComponent(0.6),
        selection: NSColor(hex: 0xD9D2FF),
        rule: NSColor.black.withAlphaComponent(0.15),
        tableBorder: NSColor.black.withAlphaComponent(0.16),
        tableHeader: NSColor(hex: 0xF4F3F8)
    )
}

extension WriterPalette {
    /// The same colours on a page of this format.
    func with(format: WriterPageFormat, setup: WriterPageSetup? = nil) -> WriterPalette {
        var palette = self
        palette.format = format
        palette.pageSetup = format == .custom ? setup ?? WriterPageSetup() : nil
        return palette
    }

    /// The text of a slide over its background: light text on a dark background or dark text on a light one, with the
    /// background design's accent.
    static func slide(tone: SlideTone, accent: UInt32?, alignment: NSTextAlignment = .natural) -> WriterPalette {
        let isLight = tone == .dark
        let ink: NSColor = isLight ? NSColor(hex: 0x17171B) : NSColor(hex: 0xF7F7FA)
        let accentColor = accent.map { NSColor(hex: $0) } ?? (isLight ? NSColor(hex: 0x5B43D6) : NSColor(hex: 0xB9A9FF))
        return WriterPalette(
            isLight: isLight,
            windowBackground: .clear,
            page: .clear,
            pageBorder: .clear,
            text: ink,
            secondaryText: ink.withAlphaComponent(isLight ? 0.74 : 0.78),
            tertiaryText: ink.withAlphaComponent(isLight ? 0.45 : 0.5),
            accent: accentColor,
            codeBlock: ink.withAlphaComponent(0.07),
            inlineCodeText: ink,
            inlineCodeBackground: ink.withAlphaComponent(0.1),
            quoteBar: accentColor.withAlphaComponent(0.8),
            selection: accentColor.withAlphaComponent(isLight ? 0.28 : 0.38),
            rule: ink.withAlphaComponent(0.3),
            tableBorder: ink.withAlphaComponent(0.28),
            tableHeader: ink.withAlphaComponent(0.08),
            alignment: alignment,
            isSlide: true
        )
    }
}

extension NSColor {
    convenience init(hex: UInt32) {
        self.init(
            srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
            green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255,
            alpha: 1
        )
    }
}

/// Turns the meaning stored in the text (block, list level, inline marks) into fonts, colours and spacing.
enum WriterStyler {
    static let listIndent: CGFloat = 26
    static let listStep: CGFloat = 24

    static func bodySize(_ family: WriterFont) -> CGFloat { family.bodySize }

    private struct FontKey: Hashable {
        let family: WriterFont
        let size: CGFloat
        let weight: CGFloat
        let italic: Bool
        let monospaced: Bool
    }

    nonisolated(unsafe) private static var fontCache: [FontKey: NSFont] = [:]
    private static let fontCacheLock = NSLock()

    static func font(_ family: WriterFont, size: CGFloat, weight: NSFont.Weight = .regular, italic: Bool = false, monospaced: Bool = false) -> NSFont {
        // Code is always set in the system's monospaced font, whatever the text's font is.
        let key = FontKey(family: monospaced ? .mono : family, size: size, weight: weight.rawValue, italic: italic, monospaced: monospaced)
        fontCacheLock.lock()
        defer { fontCacheLock.unlock() }
        if let cached = fontCache[key] { return cached }
        let made = makeFont(key.family, size: size, weight: weight, italic: italic, monospaced: monospaced)
        fontCache[key] = made
        return made
    }

    private static func makeFont(_ family: WriterFont, size: CGFloat, weight: NSFont.Weight, italic: Bool, monospaced: Bool) -> NSFont {
        // An installed family: bold from the semibold weight on, as the families have no semibold cut.
        if let name = family.familyName, !monospaced {
            let bold = weight.rawValue >= NSFont.Weight.semibold.rawValue
            var traits: NSFontTraitMask = italic ? .italicFontMask : .unitalicFontMask
            traits.formUnion(bold ? .boldFontMask : .unboldFontMask)
            if let font = NSFontManager.shared.font(withFamily: name, traits: traits, weight: bold ? 9 : 5, size: size) { return font }
        }
        let base: NSFont = monospaced || family.group == .mono
            ? .monospacedSystemFont(ofSize: size, weight: weight)
            : .systemFont(ofSize: size, weight: weight)
        var descriptor = base.fontDescriptor
        if !monospaced {
            switch family {
            case .serif: descriptor = descriptor.withDesign(.serif) ?? descriptor
            case .rounded: descriptor = descriptor.withDesign(.rounded) ?? descriptor
            default: break
            }
        }
        if italic { descriptor = descriptor.withSymbolicTraits(descriptor.symbolicTraits.union(.italic)) }
        return NSFont(descriptor: descriptor, size: size) ?? base
    }

    /// The font of a block before any inline marks. The book formats have headings of their own sizes.
    static func blockFont(_ block: WriterBlock, family: WriterFont, bold: Bool = false, italic: Bool = false,
                          format: WriterPageFormat = .standard) -> NSFont {
        let body = bodySize(family)
        if format.isBook, block.isHeading { return bookHeadingFont(block, family: family, italic: italic, format: format) }
        switch block {
        case .chapter: return font(family, size: body + 19, weight: .bold, italic: italic)
        case .heading1: return font(family, size: body + 14, weight: .bold, italic: italic)
        case .heading2: return font(family, size: body + 7, weight: .semibold, italic: italic)
        case .heading3: return font(family, size: body + 3, weight: .semibold, italic: italic)
        case .code: return font(family, size: body - 2.5, weight: bold ? .semibold : .regular, monospaced: true)
        case .raw: return font(family, size: body - 3, monospaced: true)
        case .table: return font(family, size: body - 1.5, weight: bold ? .semibold : .regular, italic: italic)
        default: return font(family, size: body, weight: bold ? .bold : .regular, italic: italic || block == .quote)
        }
    }

    /// Where a paragraph stands in a box: it opens it (room for the box's top and title) or closes it (room for its bottom).
    struct BoxEdges {
        var box: WriterBox?
        var opens = false
        var closes = false
    }

    static func paragraphStyle(_ block: WriterBlock, level: Int, family: WriterFont, previous: WriterBlock?, next: WriterBlock?,
                               cell: WriterTableCell? = nil, format: WriterParagraphFormat = WriterParagraphFormat(),
                               palette: WriterPalette = .dark, box: BoxEdges = BoxEdges()) -> NSParagraphStyle {
        let style = NSMutableParagraphStyle()
        style.lineHeightMultiple = 1.32
        style.paragraphSpacing = 10
        switch block {
        case .chapter:
            style.lineHeightMultiple = 1.05
            style.paragraphSpacingBefore = previous == nil ? 0 : 40
            style.paragraphSpacing = 16
        case .heading1:
            style.lineHeightMultiple = 1.1
            style.paragraphSpacingBefore = previous == nil ? 0 : 22
            style.paragraphSpacing = 10
        case .heading2:
            style.lineHeightMultiple = 1.12
            style.paragraphSpacingBefore = previous == nil ? 0 : 16
            style.paragraphSpacing = 8
        case .heading3:
            style.lineHeightMultiple = 1.15
            style.paragraphSpacingBefore = previous == nil ? 0 : 12
            style.paragraphSpacing = 6
        case .bullet, .numbered:
            let indent = listIndent + CGFloat(level) * listStep
            style.headIndent = indent
            style.firstLineHeadIndent = indent
            style.paragraphSpacing = next?.isList == true ? 4 : 12
        case .quote:
            style.headIndent = 20
            style.firstLineHeadIndent = 20
            style.paragraphSpacing = next == .quote ? 0 : 12
            style.paragraphSpacingBefore = previous == .quote ? 0 : 2
        case .code, .raw:
            style.lineHeightMultiple = 1.18
            style.headIndent = 16
            style.firstLineHeadIndent = 16
            style.tailIndent = -16
            style.paragraphSpacingBefore = previous == block ? 0 : 16
            style.paragraphSpacing = next == block ? 0 : 20
        case .rule:
            style.paragraphSpacingBefore = 6
            style.paragraphSpacing = 12
            style.alignment = .center
        case .image, .math:
            style.lineHeightMultiple = 1
            style.paragraphSpacingBefore = previous == nil ? 0 : 10
            style.paragraphSpacing = 16
            style.alignment = .center
        case .toc:
            style.lineHeightMultiple = 1
            style.paragraphSpacingBefore = previous == nil ? 0 : 12
            style.paragraphSpacing = 20
        case .table:
            style.lineHeightMultiple = 1.2
            style.paragraphSpacing = 0
            if let cell { style.textBlocks = [tableBlock(cell, palette: palette)] }
            style.alignment = cell?.table.alignment(of: cell?.column ?? 0).textAlignment ?? .natural
        case .paragraph:
            break
        }
        // AppKit leaves no room below a table; the paragraph after it keeps its distance.
        if block != .table, previous == .table { style.paragraphSpacingBefore = max(style.paragraphSpacingBefore, 16) }
        // A paperback or a Normseite: the print's line distance, indented paragraphs.
        if palette.format.isBook, cell == nil {
            applyBookLayout(to: style, block: block, previous: previous, next: next, family: family, format: palette.format)
        }
        // A centred slide centres its text; lists, quotes, code and objects keep their own alignment.
        if palette.alignment != .natural, cell == nil, [.paragraph, .chapter, .heading1, .heading2, .heading3].contains(block) {
            style.alignment = palette.alignment
        }
        // The paragraph's own alignment wins over both; its indents and line spacing come on top of the block's.
        let own = cell == nil ? format.applying(to: block) : WriterParagraphFormat()
        if let alignment = own.alignment { style.alignment = alignment.textAlignment }
        own.apply(to: style, scale: palette.screenScale(family))
        // The text of the user's own format is set with its line spacing.
        if let setup = palette.pageSetup, cell == nil, abs(setup.lineSpacing - 1) > 0.001, block != .code, block != .raw, !block.isEmbed, block != .rule {
            style.lineHeightMultiple *= CGFloat(setup.lineSpacing)
        }
        // A box keeps room above its first paragraph (and its title) and below its last one; the container narrows its lines.
        if let boxStyle = box.box?.style, cell == nil {
            if box.opens {
                style.paragraphSpacingBefore = WriterBoxStyle.marginTop + WriterBoxStyle.paddingTop + (boxStyle.hasTitle ? WriterBoxStyle.titleHeight : 0)
            }
            if box.closes { style.paragraphSpacing = WriterBoxStyle.paddingBottom + WriterBoxStyle.marginBottom }
        }
        return style
    }

    /// How a paragraph without an alignment of its own is set: centred on a title slide, justified in a paperback,
    /// otherwise left.
    static func defaultAlignment(_ block: WriterBlock, palette: WriterPalette) -> WriterAlignment {
        if palette.format.isJustified, block == .paragraph { return .justify }
        return palette.alignment == .center && [.paragraph, .chapter, .heading1, .heading2, .heading3].contains(block) ? .center : .left
    }

    /// The cell's box in AppKit's table: the table's lines strong and the others faint, a little room around the text,
    /// the cell's colour or a tinted header row. A merged cell reaches over its rows and columns.
    private static func tableBlock(_ cell: WriterTableCell, palette: WriterPalette) -> NSTextTableBlock {
        let table = cell.table
        let span = table.span(row: cell.row, column: cell.column)
        let block = NSTextTableBlock(table: table.textTable, startingRow: cell.row, rowSpan: span.rows, startingColumn: cell.column, columnSpan: span.columns)
        let style = table.style
        let edges: [(WriterCellEdge, NSRectEdge)] = [(.top, .minY), (.bottom, .maxY), (.left, .minX), (.right, .maxX)]
        // The rows the table has: AppKit doesn't say, the cells' places do (`rowCount` is set when the table is read).
        let rows = max(table.rowCount, cell.row + span.rows)
        for (edge, rectEdge) in edges {
            let printed = style.lines.hasLine(edge, row: cell.row, rowEnd: cell.row + span.rows, column: cell.column,
                                              columnEnd: cell.column + span.columns, rows: rows, columns: table.columns)
            let heavy = style.lines.isHeavy(edge, row: cell.row, rowEnd: cell.row + span.rows, rows: rows)
            let width: CGFloat = printed ? (style.printWidth(heavy: heavy) >= 0.79 ? 2 : 1) * (style.lineWidth.map { $0 >= 1.5 ? 1.5 : 1 } ?? 1) : 1
            block.setWidth(width, type: .absoluteValueType, for: .border, edge: rectEdge)
            block.setBorderColor(printed ? palette.tableLine : palette.tableBorder.withAlphaComponent(0.35), for: rectEdge)
        }
        block.setWidth(9, type: .absoluteValueType, for: .padding, edge: .minX)
        block.setWidth(9, type: .absoluteValueType, for: .padding, edge: .maxX)
        block.setWidth(5, type: .absoluteValueType, for: .padding, edge: .minY)
        block.setWidth(6, type: .absoluteValueType, for: .padding, edge: .maxY)
        // A share of the text width, like the shares LaTeX gets (`X` columns without their padding).
        if cell.table.widths != nil {
            let share = (cell.column..<min(cell.column + span.columns, table.columns)).map { table.width(of: $0) }.reduce(0, +)
            block.setContentWidth(share * 100, type: .percentageValueType)
        }
        block.verticalAlignment = .topAlignment
        if let fill = style.fills[WriterCellPosition(row: cell.row, column: cell.column)] {
            block.backgroundColor = WriterColors.cellFill(fill, onDark: !palette.isLight)
        } else if cell.row == 0 {
            block.backgroundColor = palette.tableHeader
        }
        return block
    }

    /// Display attributes for one stretch of text with these meaning attributes.
    static func displayAttributes(for semantic: [NSAttributedString.Key: Any], block: WriterBlock, family: WriterFont, palette: WriterPalette) -> [NSAttributedString.Key: Any] {
        var attributes = styledAttributes(for: semantic, block: block, family: family, palette: palette)
        if semantic[.writerDictationPreview] != nil { attributes[.foregroundColor] = palette.tertiaryText }
        return attributes
    }

    private static func styledAttributes(for semantic: [NSAttributedString.Key: Any], block: WriterBlock, family: WriterFont, palette: WriterPalette) -> [NSAttributedString.Key: Any] {
        let marks = WriterInline(semantic)
        var attributes: [NSAttributedString.Key: Any] = [:]
        if block == .code || block == .raw {
            attributes[.font] = blockFont(block, family: family, format: palette.format)
            attributes[.foregroundColor] = block == .raw ? palette.tertiaryText : palette.text
            return attributes
        }
        // A passage's own font replaces the document's for this stretch, its own size the block's.
        let passage = WriterSpanStyle(semantic)
        let family = passage.font ?? family
        let color = passage.color.flatMap { WriterColors.display($0, onDark: !palette.isLight) }
        let ownSize = passage.size.map { CGFloat($0) * palette.screenScale(family) }
        if marks.contains(.code) {
            let size = (ownSize ?? blockFont(block, family: family, format: palette.format).pointSize) * 0.86
            attributes[.font] = font(family, size: size, weight: marks.contains(.bold) ? .semibold : .regular, monospaced: true)
            attributes[.foregroundColor] = color ?? palette.inlineCodeText
            attributes[.backgroundColor] = palette.inlineCodeBackground
            return attributes
        }
        // The first row of a table is its header.
        let isHeader = block == .table && semantic[.writerTableRow] as? Int == 0
        let font = blockFont(block, family: family, bold: marks.contains(.bold) || isHeader, italic: marks.contains(.italic), format: palette.format)
        attributes[.font] = font
        // Fonts without an italic cut (SF Pro Rounded) lean instead.
        if marks.contains(.italic) || block == .quote, !font.fontDescriptor.symbolicTraits.contains(.italic) {
            attributes[.obliqueness] = 0.18
        }
        if block.isHeading, marks.contains(.bold) {
            attributes[.font] = blockFont(block, family: family, italic: marks.contains(.italic), format: palette.format).withWeight(.heavy)
        }
        if let ownSize, let current = attributes[.font] as? NSFont {
            attributes[.font] = current.withSize(ownSize)
        }
        // Raised and lowered text: smaller, off the baseline.
        if marks.contains(.superscript) || marks.contains(.subscript), let current = attributes[.font] as? NSFont {
            let size = current.pointSize
            attributes[.font] = current.withSize((size * 0.68).rounded())
            attributes[.baselineOffset] = marks.contains(.superscript) ? (size * 0.36).rounded() : -(size * 0.16).rounded()
        }
        attributes[.foregroundColor] = color ?? (block == .quote ? palette.secondaryText : palette.text)
        // A commented passage is tinted until the comment is done.
        if let comment = semantic[.writerComment] as? WriterComment, !comment.isResolved {
            attributes[.backgroundColor] = commentColor(palette).withAlphaComponent(palette.isLight ? 0.24 : 0.2)
        }
        return attributes
    }

    /// The colour of comments: a warm yellow, deeper on white paper.
    static func commentColor(_ palette: WriterPalette) -> NSColor {
        palette.isLight ? NSColor(hex: 0xE0A800) : NSColor(hex: 0xF2C14C)
    }

    private static let displayKeys: [NSAttributedString.Key] = [.font, .foregroundColor, .backgroundColor, .paragraphStyle, .obliqueness, .baselineOffset]

    /// Restyles whole paragraphs around `range`: every paragraph gets one block (taken from its first character),
    /// then fonts, colours and spacing follow from the meaning attributes.
    static func restyle(_ storage: NSTextStorage, around range: NSRange, family: WriterFont, palette: WriterPalette) {
        let string = storage.string as NSString
        guard string.length > 0 else { return }
        // One paragraph more on each side: spacing depends on the neighbours.
        var start = string.paragraphRange(for: NSRange(location: min(range.location, string.length), length: 0)).location
        if start > 0 { start = string.paragraphRange(for: NSRange(location: start - 1, length: 0)).location }
        var end = NSMaxRange(string.paragraphRange(for: NSRange(location: min(NSMaxRange(range), string.length), length: 0)))
        if end < string.length { end = NSMaxRange(string.paragraphRange(for: NSRange(location: end, length: 0))) }
        let paragraphs = WriterMarkdown.paragraphs(of: storage, in: NSRange(location: start, length: end - start))

        for (index, paragraph) in paragraphs.enumerated() where paragraph.range.length > 0 {
            var block = paragraph.block
            if paragraph.cell == nil {
                // A line, a picture, a display formula or the table of contents is a paragraph of its own;
                // without its attachment it is text again. A formula inside text stays an inline one.
                let attachment = storage.attribute(.attachment, at: paragraph.range.location, effectiveRange: nil)
                let hasRule = attachment is WriterRuleAttachment
                let hasImage = attachment is WriterImageAttachment
                let hasTOC = attachment is WriterTOCAttachment || attachment is WriterBibliographyAttachment
                let hasMath = attachment is WriterMathAttachment && paragraph.contentRange.length == 1
                if (block == .rule && !hasRule) || (block == .image && !hasImage) || (block == .toc && !hasTOC)
                    || (block == .math && !hasMath) { block = .paragraph }
                if hasRule { block = .rule }
                if hasImage { block = .image }
                if hasTOC { block = .toc }
            }
            var semantic: [NSAttributedString.Key: Any] = paragraph.cell?.attributes
                ?? [.writerBlock: block.rawValue, .writerListLevel: block.isList ? paragraph.level : 0]
            // The whole paragraph stands in the box and section of its first character, if its block may.
            if paragraph.cell == nil {
                if WriterBox.holds(block), let box = storage.attribute(.writerBox, at: paragraph.range.location, effectiveRange: nil) as? WriterBox {
                    semantic[.writerBox] = box
                }
                if WriterColumnSection.holds(block),
                   let section = storage.attribute(.writerColumns, at: paragraph.range.location, effectiveRange: nil) as? WriterColumnSection {
                    semantic[.writerColumns] = section
                }
            }
            if block == .code, let language = paragraph.language { semantic[.writerCodeLanguage] = language }
            // The whole paragraph is set like its first character: alignment, line spacing, indents.
            let format = paragraph.cell == nil ? paragraph.format.applying(to: block) : WriterParagraphFormat()
            semantic.merge(format.attributes) { $1 }
            storage.addAttributes(semantic, range: paragraph.range)
            if block != .code { storage.removeAttribute(.writerCodeLanguage, range: paragraph.range) }
            for key in WriterParagraphFormat.keys + WriterMarkdown.containerKeys where semantic[key] == nil { storage.removeAttribute(key, range: paragraph.range) }
            // Code has no sizes of its own.
            if block == .code || block == .raw { storage.removeAttribute(.writerFontSize, range: paragraph.range) }
            if paragraph.cell == nil {
                for key in WriterMarkdown.tableKeys { storage.removeAttribute(key, range: paragraph.range) }
            }

            let previous = index > 0 ? paragraphs[index - 1].block : previousBlock(in: storage, before: paragraph.range.location)
            let next = index + 1 < paragraphs.count ? paragraphs[index + 1].block : nextBlock(in: storage, after: NSMaxRange(paragraph.range))
            let ownBox = semantic[.writerBox] as? WriterBox
            let boxBefore = paragraph.range.location > 0 ? storage.attribute(.writerBox, at: paragraph.range.location - 1, effectiveRange: nil) as? WriterBox : nil
            let boxAfter = NSMaxRange(paragraph.range) < storage.length ? storage.attribute(.writerBox, at: NSMaxRange(paragraph.range), effectiveRange: nil) as? WriterBox : nil
            let edges = BoxEdges(box: ownBox, opens: ownBox != nil && boxBefore !== ownBox, closes: ownBox != nil && boxAfter !== ownBox)
            let style = paragraphStyle(block, level: paragraph.level, family: family, previous: previous, next: next, cell: paragraph.cell,
                                       format: format, palette: palette, box: edges)

            for key in displayKeys { storage.removeAttribute(key, range: paragraph.range) }
            storage.addAttribute(.paragraphStyle, value: style, range: paragraph.range)
            storage.enumerateAttributes(in: paragraph.range) { attributes, run, _ in
                storage.addAttributes(displayAttributes(for: attributes, block: block, family: family, palette: palette), range: run)
            }
        }
        highlightCode(storage, in: NSRange(location: start, length: end - start), palette: palette)
    }

    static func restyleAll(_ storage: NSTextStorage, family: WriterFont, palette: WriterPalette) {
        storage.beginEditing()
        restyle(storage, around: NSRange(location: 0, length: storage.length), family: family, palette: palette)
        storage.endEditing()
    }

    private static func previousBlock(in storage: NSTextStorage, before location: Int) -> WriterBlock? {
        guard location > 0 else { return nil }
        return block(in: storage, at: location - 1)
    }

    private static func nextBlock(in storage: NSTextStorage, after location: Int) -> WriterBlock? {
        guard location < storage.length else { return nil }
        return block(in: storage, at: location)
    }

    static func block(in storage: NSAttributedString, at location: Int) -> WriterBlock {
        guard location < storage.length else { return .paragraph }
        return (storage.attribute(.writerBlock, at: location, effectiveRange: nil) as? String).flatMap(WriterBlock.init(rawValue:)) ?? .paragraph
    }

    /// Typing attributes for a paragraph with this block and these marks.
    static func typingAttributes(block: WriterBlock, level: Int, semantic: [NSAttributedString.Key: Any], family: WriterFont, palette: WriterPalette) -> [NSAttributedString.Key: Any] {
        var attributes = semantic.filter {
            (WriterInline.keys + [.link] + WriterMarkdown.passageKeys + WriterParagraphFormat.keys + WriterMarkdown.containerKeys).contains($0.key)
        }
        // New text stays in the box and section it is typed in, where its block may.
        if !WriterBox.holds(block) { attributes.removeValue(forKey: .writerBox) }
        if !WriterColumnSection.holds(block) { attributes.removeValue(forKey: .writerColumns) }
        // Code has no colours, fonts or sizes of its own.
        if block == .code || block == .raw {
            for key in WriterMarkdown.passageKeys { attributes.removeValue(forKey: key) }
        }
        let paragraphFormat = WriterParagraphFormat(attributes).applying(to: block)
        for key in WriterParagraphFormat.keys { attributes.removeValue(forKey: key) }
        attributes.merge(paragraphFormat.attributes) { $1 }
        let cell = block == .table ? WriterTableCell(semantic) : nil
        let block: WriterBlock = block == .table && cell == nil ? .paragraph : block
        attributes[.writerBlock] = block.rawValue
        attributes[.writerListLevel] = block.isList ? level : 0
        if let cell { attributes.merge(cell.attributes) { $1 } }
        attributes.merge(displayAttributes(for: attributes, block: block, family: family, palette: palette)) { $1 }
        attributes[.paragraphStyle] = paragraphStyle(block, level: level, family: family, previous: nil, next: nil, cell: cell,
                                                     format: cell == nil ? paragraphFormat : WriterParagraphFormat(), palette: palette)
        return attributes
    }

    /// The size a stretch of text has in points of the print (or of the slide): its own, or its block's.
    static func printedSize(of semantic: [NSAttributedString.Key: Any], block: WriterBlock, family: WriterFont, palette: WriterPalette) -> Double {
        let passage = WriterSpanStyle(semantic)
        if let size = passage.size { return size }
        let family = passage.font ?? family
        let isHeader = block == .table && semantic[.writerTableRow] as? Int == 0
        let screen = blockFont(block, family: family, bold: isHeader, format: palette.format).pointSize
        return (Double(screen / palette.screenScale(family)) * 2).rounded() / 2
    }
}

private extension NSFont {
    func withWeight(_ weight: NSFont.Weight) -> NSFont {
        let descriptor = fontDescriptor.addingAttributes([.traits: [NSFontDescriptor.TraitKey.weight: weight]])
        return NSFont(descriptor: descriptor, size: pointSize) ?? self
    }
}
