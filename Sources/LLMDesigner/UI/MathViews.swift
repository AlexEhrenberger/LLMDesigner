import AppKit
import SwiftUI

/// Builds a `Text` from Markdown that may contain inline formulas. Formulas are swapped for a
/// placeholder before Markdown parsing, so emphasis around a formula (`**$x$**`) still works.
enum RichText {
    private static let placeholder = "\u{E000}"

    static func make(_ source: String, mathSize: CGFloat) -> Text {
        let segments = MathTokenizer.segments(source)
        if segments.count == 1, case .text(let text) = segments[0] {
            return Text(InlineMarkdown.render(text))
        }

        var markdown = ""
        var formulas: [String] = []
        for segment in segments {
            switch segment {
            case .text(let text): markdown += text
            case .math(let latex):
                markdown += placeholder
                formulas.append(latex)
            }
        }

        let attributed = InlineMarkdown.render(markdown)
        var result = Text(verbatim: "")
        var cursor = attributed.startIndex
        var formulaIndex = 0
        while let match = attributed[cursor...].range(of: placeholder), formulaIndex < formulas.count {
            result = Text("\(result)\(Text(AttributedString(attributed[cursor..<match.lowerBound])))\(formula(formulas[formulaIndex], size: mathSize))")
            formulaIndex += 1
            cursor = match.upperBound
        }
        return Text("\(result)\(Text(AttributedString(attributed[cursor...])))")
    }

    private static func formula(_ latex: String, size: CGFloat) -> Text {
        guard let rendered = MathRenderer.render(latex, fontSize: size, display: false, color: NSColor(Theme.textPrimary)) else {
            // SwiftMath can't parse it: show the LaTeX source like inline code instead of failing.
            return Text(InlineMarkdown.render("`\(latex)`"))
        }
        return Text(Image(nsImage: rendered.image)).baselineOffset(rendered.baselineOffset)
    }
}

/// Display formula (`$$…$$`, `\[…\]`, `\begin{equation}`…) rendered centered, scrollable when too wide.
struct MathBlockView: View {
    let latex: String
    let isComplete: Bool

    var body: some View {
        if isComplete, let rendered = MathRenderer.render(latex, fontSize: 19, display: true, color: NSColor(Theme.textPrimary)) {
            ViewThatFits(in: .horizontal) {
                Image(nsImage: rendered.image)
                    .frame(maxWidth: .infinity)
                ScrollView(.horizontal) {
                    Image(nsImage: rendered.image)
                        .padding(.bottom, 6)
                }
                .scrollIndicators(.automatic)
            }
            .padding(.vertical, 4)
            .contentShape(Rectangle())
            .help(latex)
            .contextMenu {
                Button("LaTeX kopieren", systemImage: "doc.on.doc") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(latex, forType: .string)
                }
            }
        } else {
            // Still streaming, or not parseable: show the source quietly.
            Text(latex)
                .font(.system(size: 13, design: .monospaced))
                .foregroundStyle(isComplete ? Theme.textSecondary : Theme.textTertiary)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}
