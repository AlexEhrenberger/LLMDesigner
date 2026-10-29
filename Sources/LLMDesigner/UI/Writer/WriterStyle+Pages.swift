import AppKit

/// A paperback or a Normseite in the editor (see `WriterPageFormat`): the print's line length and line distance at
/// screen size, paragraphs indented without room between them, headings in the format's sizes. The lines of a
/// Normseite stay on a grid (headings take an empty line before and after), so 30 of them are a page as in print.
extension WriterStyler {
    /// Baseline to baseline of the text on screen.
    static func lineHeight(_ format: WriterPageFormat, family: WriterFont) -> CGFloat {
        let distance = format.lineDistance ?? format.printSize * 1.2
        return (distance * family.screenScale(onSlide: false, format: format)).rounded()
    }

    /// One character of the text's font on screen; Courier's are all alike.
    static func characterWidth(_ family: WriterFont) -> CGFloat {
        ("0" as NSString).size(withAttributes: [.font: font(family, size: bodySize(family))]).width
    }

    /// The text column on screen; nil: the standard sheet, as wide as the window allows. The user's own format is as
    /// wide as its text block in print.
    static func columnWidth(_ format: WriterPageFormat, family: WriterFont, setup: WriterPageSetup? = nil) -> CGFloat? {
        switch format {
        case .standard: nil
        case .custom:
            (setup ?? WriterPageSetup()).textWidth * family.screenScale(onSlide: false, format: format, printSize: CGFloat((setup ?? WriterPageSetup()).fontSize))
        case .paperback: (WriterPageFormat.paperbackTextWidth * family.screenScale(onSlide: false, format: format)).rounded()
        case .manuscript: ceil(CGFloat(WriterPageFormat.manuscriptCharactersPerLine) * characterWidth(family)) + 1
        }
    }

    /// A Normseite's headings are as large as its text and bold; a paperback's are a little larger, the third level
    /// is italic. As in print (`WriterPageFormat.latexSetup`).
    static func bookHeadingFont(_ block: WriterBlock, family: WriterFont, italic: Bool, format: WriterPageFormat) -> NSFont {
        let body = bodySize(family)
        guard format == .paperback else { return font(family, size: body, weight: .bold, italic: italic) }
        switch block {
        case .chapter: return font(family, size: (body * 1.44).rounded(), weight: .bold, italic: italic)
        case .heading1: return font(family, size: (body * 1.2).rounded(), weight: .bold, italic: italic)
        case .heading2: return font(family, size: body, weight: .bold, italic: italic)
        default: return font(family, size: body, italic: true)
        }
    }

    /// The line distance of the print, and the print's spacing in lines: text without room between paragraphs, an
    /// indent where a paragraph follows another, headings with whole empty lines around them on a Normseite.
    /// Code, pictures, formulas, tables and the table of contents keep their room.
    static func applyBookLayout(to style: NSMutableParagraphStyle, block: WriterBlock, previous: WriterBlock?, next: WriterBlock?,
                                family: WriterFont, format: WriterPageFormat) {
        let line = lineHeight(format, family: family)
        let isText = block == .paragraph || block.isHeading || block.isList || block == .quote
        guard isText else { return }
        // Lines with larger letters grow; the text's own lines are exactly as far apart as printed.
        style.lineHeightMultiple = 0
        style.minimumLineHeight = line
        style.maximumLineHeight = 0
        let grid = format == .manuscript
        switch block {
        case .paragraph:
            style.paragraphSpacingBefore = 0
            style.paragraphSpacing = 0
            // The first paragraph and the one after a heading start at the margin, as in books.
            if let previous, !previous.isHeading, previous != .rule, previous != .toc {
                style.firstLineHeadIndent = format == .manuscript
                    ? CGFloat(WriterPageFormat.manuscriptIndentCharacters) * characterWidth(family)
                    : bodySize(family)
            }
            if format.isJustified {
                style.alignment = .justified
                style.hyphenationFactor = 0.9
            }
        case .chapter:
            // A chapter begins a new page.
            style.paragraphSpacingBefore = grid ? 0 : 2 * line
            style.paragraphSpacing = grid ? line : 2 * line
        case .heading1, .heading2:
            style.paragraphSpacingBefore = previous == nil ? 0 : line
            style.paragraphSpacing = grid ? line : (line / 2).rounded()
        case .heading3:
            style.paragraphSpacingBefore = previous == nil ? 0 : grid ? line : (line / 2).rounded()
            style.paragraphSpacing = grid ? line : (line / 4).rounded()
        case .bullet, .numbered, .quote:
            let continues = next == block || (block.isList && next?.isList == true)
            let follows = previous == block || (block.isList && previous?.isList == true)
            style.paragraphSpacingBefore = follows || grid ? 0 : (line / 2).rounded()
            style.paragraphSpacing = continues || grid ? 0 : (line / 2).rounded()
        default:
            break
        }
    }
}
