import AppKit

/// Colours of Writer Studio: a dark sheet that matches the app, or white paper.
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

    static let dark = WriterPalette(
        isLight: false,
        windowBackground: NSColor(hex: 0x0C0C0E),
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
        rule: NSColor.white.withAlphaComponent(0.16)
    )

    static let light = WriterPalette(
        isLight: true,
        windowBackground: NSColor(hex: 0x0C0C0E),
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
        rule: NSColor.black.withAlphaComponent(0.15)
    )
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

    static func bodySize(_ family: WriterFont) -> CGFloat { family == .mono ? 15 : 17 }

    static func font(_ family: WriterFont, size: CGFloat, weight: NSFont.Weight = .regular, italic: Bool = false, monospaced: Bool = false) -> NSFont {
        let base: NSFont = monospaced || family == .mono
            ? .monospacedSystemFont(ofSize: size, weight: weight)
            : .systemFont(ofSize: size, weight: weight)
        var descriptor = base.fontDescriptor
        if !monospaced {
            switch family {
            case .serif: descriptor = descriptor.withDesign(.serif) ?? descriptor
            case .rounded: descriptor = descriptor.withDesign(.rounded) ?? descriptor
            case .sans, .mono: break
            }
        }
        if italic { descriptor = descriptor.withSymbolicTraits(descriptor.symbolicTraits.union(.italic)) }
        return NSFont(descriptor: descriptor, size: size) ?? base
    }

    /// The font of a block before any inline marks.
    static func blockFont(_ block: WriterBlock, family: WriterFont, bold: Bool = false, italic: Bool = false) -> NSFont {
        let body = bodySize(family)
        switch block {
        case .heading1: return font(family, size: body + 14, weight: .bold, italic: italic)
        case .heading2: return font(family, size: body + 7, weight: .semibold, italic: italic)
        case .heading3: return font(family, size: body + 3, weight: .semibold, italic: italic)
        case .code: return font(family, size: body - 2.5, weight: bold ? .semibold : .regular, monospaced: true)
        case .raw: return font(family, size: body - 3, monospaced: true)
        default: return font(family, size: body, weight: bold ? .bold : .regular, italic: italic || block == .quote)
        }
    }

    static func paragraphStyle(_ block: WriterBlock, level: Int, family: WriterFont, previous: WriterBlock?, next: WriterBlock?) -> NSParagraphStyle {
        let style = NSMutableParagraphStyle()
        style.lineHeightMultiple = 1.32
        style.paragraphSpacing = 10
        switch block {
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
        case .paragraph:
            break
        }
        return style
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
            attributes[.font] = blockFont(block, family: family)
            attributes[.foregroundColor] = block == .raw ? palette.tertiaryText : palette.text
            return attributes
        }
        if marks.contains(.code) {
            let size = blockFont(block, family: family).pointSize * 0.86
            attributes[.font] = font(family, size: size, weight: marks.contains(.bold) ? .semibold : .regular, monospaced: true)
            attributes[.foregroundColor] = palette.inlineCodeText
            attributes[.backgroundColor] = palette.inlineCodeBackground
            return attributes
        }
        let font = blockFont(block, family: family, bold: marks.contains(.bold), italic: marks.contains(.italic))
        attributes[.font] = font
        // Fonts without an italic cut (SF Pro Rounded) lean instead.
        if marks.contains(.italic) || block == .quote, !font.fontDescriptor.symbolicTraits.contains(.italic) {
            attributes[.obliqueness] = 0.18
        }
        if block.isHeading, marks.contains(.bold) {
            attributes[.font] = blockFont(block, family: family, italic: marks.contains(.italic)).withWeight(.heavy)
        }
        attributes[.foregroundColor] = block == .quote ? palette.secondaryText : palette.text
        return attributes
    }

    private static let displayKeys: [NSAttributedString.Key] = [.font, .foregroundColor, .backgroundColor, .paragraphStyle, .obliqueness]

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
            let hasRule = storage.attribute(.attachment, at: paragraph.range.location, effectiveRange: nil) is WriterRuleAttachment
            if block == .rule && !hasRule { block = .paragraph }
            if hasRule { block = .rule }
            var semantic: [NSAttributedString.Key: Any] = [.writerBlock: block.rawValue, .writerListLevel: block.isList ? paragraph.level : 0]
            if block == .code, let language = paragraph.language { semantic[.writerCodeLanguage] = language }
            storage.addAttributes(semantic, range: paragraph.range)
            if block != .code { storage.removeAttribute(.writerCodeLanguage, range: paragraph.range) }

            let previous = index > 0 ? paragraphs[index - 1].block : previousBlock(in: storage, before: paragraph.range.location)
            let next = index + 1 < paragraphs.count ? paragraphs[index + 1].block : nextBlock(in: storage, after: NSMaxRange(paragraph.range))
            let style = paragraphStyle(block, level: paragraph.level, family: family, previous: previous, next: next)

            for key in displayKeys { storage.removeAttribute(key, range: paragraph.range) }
            storage.addAttribute(.paragraphStyle, value: style, range: paragraph.range)
            storage.enumerateAttributes(in: paragraph.range) { attributes, run, _ in
                storage.addAttributes(displayAttributes(for: attributes, block: block, family: family, palette: palette), range: run)
            }
        }
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
        var attributes = semantic.filter { [.writerBold, .writerItalic, .writerCode, .underlineStyle, .strikethroughStyle, .link].contains($0.key) }
        attributes[.writerBlock] = block.rawValue
        attributes[.writerListLevel] = block.isList ? level : 0
        attributes.merge(displayAttributes(for: attributes, block: block, family: family, palette: palette)) { $1 }
        attributes[.paragraphStyle] = paragraphStyle(block, level: level, family: family, previous: nil, next: nil)
        return attributes
    }
}

private extension NSFont {
    func withWeight(_ weight: NSFont.Weight) -> NSFont {
        let descriptor = fontDescriptor.addingAttributes([.traits: [NSFontDescriptor.TraitKey.weight: weight]])
        return NSFont(descriptor: descriptor, size: pointSize) ?? self
    }
}
