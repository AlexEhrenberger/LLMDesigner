import AppKit
import SwiftUI

enum InlineMarkdown {
    static func render(_ text: String) -> AttributedString {
        let options = AttributedString.MarkdownParsingOptions(
            interpretedSyntax: .inlineOnlyPreservingWhitespace,
            failurePolicy: .returnPartiallyParsedIfPossible
        )
        var result = (try? AttributedString(markdown: text, options: options)) ?? AttributedString(text)
        for run in result.runs {
            if let intent = run.inlinePresentationIntent, intent.contains(.code) {
                result[run.range].font = .system(size: 13.5, design: .monospaced)
                result[run.range].foregroundColor = Theme.inlineCodeText
                result[run.range].backgroundColor = Theme.inlineCodeBackground
            }
            if run.link != nil {
                result[run.range].foregroundColor = Theme.accent
                result[run.range].underlineStyle = .single
            }
        }
        return result
    }
}

struct MarkdownView: View {
    /// Formulas are pictures in the design's text colour: a change of design draws them again.
    @Environment(\.colorScheme) private var colorScheme
    let text: String
    /// When set, every block gets a scroll identifier so the table of contents can jump to it.
    var anchorMessageID: UUID?
    var highlightedBlock: Int?
    var bookmarkedBlocks: Set<Int> = []

    var body: some View {
        let blocks = MarkdownParser.parse(text)
        VStack(alignment: .leading, spacing: 14) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { index, block in
                view(for: block)
                    .overlay(alignment: .topLeading) {
                        if bookmarkedBlocks.contains(index) { BookmarkGlyph().offset(x: -20, y: 4) }
                    }
                    .background {
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(Theme.accent.opacity(highlightedBlock == index ? 0.16 : 0))
                            .padding(-6)
                            .animation(.easeOut(duration: 0.5), value: highlightedBlock)
                    }
                    .scrollAnchor(anchorMessageID.map { OutlineTarget.viewID($0, index) } ?? "\(index)")
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func view(for block: MarkdownBlock) -> some View {
        switch block {
        case .paragraph(let text):
            RichText.make(text, mathSize: 16)
                .font(.system(size: 15))
                .lineSpacing(4)
                .foregroundStyle(Theme.textPrimary)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)

        case .heading(let level, let text):
            RichText.make(text, mathSize: headingSize(level) + 1)
                .font(.system(size: headingSize(level), weight: .semibold))
                .foregroundStyle(Theme.textPrimary)
                .textSelection(.enabled)
                .padding(.top, level <= 2 ? 6 : 2)

        case .code(let language, let code):
            CodeBlockView(language: language, code: code)

        case .list(let items):
            VStack(alignment: .leading, spacing: 6) {
                ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(item.marker ?? "•")
                            .font(.system(size: 15, weight: item.marker == nil ? .bold : .regular).monospacedDigit())
                            .foregroundStyle(Theme.textSecondary)
                            .frame(minWidth: 14, alignment: .trailing)
                        RichText.make(item.text, mathSize: 16)
                            .font(.system(size: 15))
                            .lineSpacing(4)
                            .foregroundStyle(Theme.textPrimary)
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(.leading, CGFloat(item.level) * 20)
                }
            }

        case .quote(let text):
            RichText.make(text, mathSize: 16)
                .font(.system(size: 15))
                .lineSpacing(4)
                .foregroundStyle(Theme.textSecondary)
                .textSelection(.enabled)
                .padding(.leading, 14)
                .overlay(alignment: .leading) {
                    Rectangle().fill(Theme.accent.opacity(0.6)).frame(width: 3)
                }

        case .table(let header, let rows, _, _):
            TableBlockView(header: header, rows: rows)

        case .math(let latex, let complete):
            MathBlockView(latex: latex, isComplete: complete)

        case .rule, .pageBreak, .columnBreak:
            Rectangle().fill(Theme.border).frame(height: 1).padding(.vertical, 4)
        }
    }

    private func headingSize(_ level: Int) -> CGFloat {
        switch level {
        case 1: 22
        case 2: 19
        case 3: 17
        default: 15.5
        }
    }
}

private struct CodeBlockView: View {
    let language: String
    let code: String
    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(language.isEmpty ? "code" : language)
                    .font(.system(size: 11.5, weight: .medium, design: .monospaced))
                    .foregroundStyle(Theme.textTertiary)
                Spacer()
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(code, forType: .string)
                    copied = true
                    Task {
                        try? await Task.sleep(for: .seconds(1.5))
                        copied = false
                    }
                } label: {
                    Label(copied ? "Kopiert" : "Kopieren", systemImage: copied ? "checkmark" : "doc.on.doc")
                        .font(.system(size: 11.5, weight: .medium))
                        .foregroundStyle(Theme.textSecondary)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 14)
            .frame(height: 34)
            .background(Theme.codeHeader)

            ScrollView(.horizontal) {
                Text(code)
                    .font(.system(size: 13, design: .monospaced))
                    .lineSpacing(3)
                    .foregroundStyle(Theme.textPrimary)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: true, vertical: false)
                    .padding(14)
            }
            .scrollIndicators(.automatic)
        }
        .background(Theme.codeBackground)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Theme.border))
    }
}

private struct TableBlockView: View {
    let header: [String]
    let rows: [[String]]

    var body: some View {
        ScrollView(.horizontal) {
            Grid(alignment: .leading, horizontalSpacing: 0, verticalSpacing: 0) {
                GridRow {
                    ForEach(Array(header.enumerated()), id: \.offset) { _, cell in
                        cellView(cell, isHeader: true)
                    }
                }
                .background(Theme.ink.opacity(0.04))
                ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                    Rectangle().fill(Theme.border).frame(height: 1).gridCellUnsizedAxes(.horizontal)
                    GridRow {
                        ForEach(0..<header.count, id: \.self) { column in
                            cellView(column < row.count ? row[column] : "", isHeader: false)
                        }
                    }
                }
            }
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Theme.border))
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
        .scrollIndicators(.automatic)
    }

    private func cellView(_ text: String, isHeader: Bool) -> some View {
        RichText.make(text, mathSize: 14.5)
            .font(.system(size: 13.5, weight: isHeader ? .semibold : .regular))
            .foregroundStyle(isHeader ? Theme.textPrimary : Theme.textSecondary)
            .textSelection(.enabled)
            .frame(maxWidth: 320, alignment: .leading)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
    }
}
