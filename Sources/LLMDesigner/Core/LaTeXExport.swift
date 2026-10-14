import Foundation
import SwiftMath

enum PaperSize: String, CaseIterable, Identifiable {
    case a4, a5, letter

    var id: String { rawValue }

    var label: String {
        switch self {
        case .a4: "DIN A4"
        case .a5: "DIN A5"
        case .letter: "US Letter"
        }
    }

    fileprivate var geometry: String {
        switch self {
        case .a4: "a4paper,margin=2.5cm"
        case .a5: "a5paper,margin=1.8cm"
        case .letter: "letterpaper,margin=1in"
        }
    }
}

enum PDFExportError: LocalizedError {
    case noEngine
    case compileFailed(String)

    var errorDescription: String? {
        switch self {
        case .noEngine:
            return "Keine LaTeX-Engine gefunden. Installiere Tectonic mit „brew install tectonic“ (oder MacTeX) und versuche es erneut."
        case .compileFailed(let log):
            return log.isEmpty ? "LaTeX konnte das Dokument nicht setzen." : "LaTeX konnte das Dokument nicht setzen:\n\(log)"
        }
    }
}

/// Converts chat content (Markdown with LaTeX formulas) into a complete LaTeX document.
enum LaTeXWriter {
    struct Part {
        /// Bold line above the content, e.g. "Gemma sagt:".
        var label: String?
        var text: String
        /// User messages are shown verbatim in the app, so they are not interpreted as Markdown.
        var isPlainText = false
        /// LaTeX label at the start of this part (target of a table-of-contents entry).
        var anchor: String?
        /// LaTeX labels in front of individual Markdown blocks, keyed by block index.
        var blockAnchors: [Int: String] = [:]
        /// Pictures attached to the message, set above the text. The engine copies them next to the document.
        var images: [URL] = []
    }

    struct OutlineEntry {
        var title: String
        var level: Int
        var label: String
    }

    struct Outline {
        var summary: String
        var entries: [OutlineEntry]
    }

    /// How formulas are written. Later modes are fallbacks when LaTeX refuses the document.
    enum MathMode: CaseIterable {
        case native        // formulas go to LaTeX unchanged
        case safe          // formulas SwiftMath cannot parse are printed as code
        case plain         // all formulas are printed as code
    }

    static func document(parts: [Part], outline: Outline? = nil, paper: PaperSize, math: MathMode) -> String {
        var body: [String] = []
        for part in parts {
            var section = ""
            if let anchor = part.anchor { section += anchorCommand(anchor) }
            if let label = part.label, !label.isEmpty {
                section += "\\noindent\\textbf{\(escape(label))}\\par\n"
            }
            for image in part.images {
                section += "\\begin{center}\\includegraphics[width=0.7\\linewidth,height=0.35\\textheight,keepaspectratio]{\(image.lastPathComponent)}\\end{center}\n"
            }
            section += part.isPlainText ? plainText(part.text) : blocks(part.text, math: math, anchors: part.blockAnchors)
            body.append(section)
        }
        let contents = outline.map { tableOfContents($0, math: math) } ?? ""
        return preamble(paper) + "\\begin{document}\n" + contents + body.joined(separator: "\n\n\\bigskip\n\n") + "\n\\end{document}\n"
    }

    /// Table of contents on its own page(s): linked entries with page numbers via `\pageref`.
    private static func tableOfContents(_ outline: Outline, math: MathMode) -> String {
        var output = "\\section*{Inhaltsverzeichnis}\n"
        let summary = outline.summary.trimmingCharacters(in: .whitespacesAndNewlines)
        if !summary.isEmpty {
            output += "{\\itshape \(inline(summary, math: math))\\par}\n\\medskip\n"
        }
        var number = 0
        for entry in outline.entries {
            let title = inline(entry.title, math: math)
            let page = "\\dotfill\\pageref*{\(entry.label)}\\par\n"
            if entry.level == 0 {
                number += 1
                output += "\\vspace{4pt}\\noindent\\hyperref[\(entry.label)]{\\textbf{\(number)\\quad \(title)}}" + page
            } else {
                output += "\\noindent\\hspace*{1.6em}\\hyperref[\(entry.label)]{\(title)}" + page
            }
        }
        return output + "\\clearpage\n\n"
    }

    private static func anchorCommand(_ label: String) -> String {
        "\\phantomsection\\label{\(label)}%\n"
    }

    /// Short, readable model name: "gemma-4-e4b-…" → "Gemma", "qwen/qwen3.5-9b" → "Qwen".
    static func speakerName(forModel model: String?) -> String {
        guard let model, !model.isEmpty else { return "Assistent" }
        let last = model.split(separator: "/").last.map(String.init) ?? model
        let token = last.split(whereSeparator: { !$0.isLetter }).first.map(String.init) ?? last
        return token.prefix(1).uppercased() + token.dropFirst()
    }

    /// `name` (a persona's) takes the place of the model's name.
    static func speakerLine(template: String, model: String?, name: String? = nil) -> String {
        template.replacingOccurrences(of: "{Modell}", with: name ?? speakerName(forModel: model))
    }

    // MARK: - Preamble

    private static func preamble(_ paper: PaperSize) -> String {
        #"""
        \documentclass[11pt]{article}
        \usepackage[\#(paper.geometry)]{geometry}
        \usepackage{amsmath}
        \usepackage{fontspec}
        \usepackage{unicode-math}
        \setmathfont{latinmodern-math.otf}
        \usepackage[ngerman,shorthands=off]{babel}
        \usepackage{xcolor}
        \usepackage{graphicx}
        \usepackage{fvextra}
        \usepackage{booktabs,xltabular}
        \newcolumntype{L}{>{\raggedright\arraybackslash}X}
        \usepackage{enumitem}
        \usepackage[normalem]{ulem}
        \usepackage{parskip}
        \usepackage{lastpage,refcount}
        \usepackage{fancyhdr}
        \usepackage[hidelinks]{hyperref}
        \urlstyle{same}
        \setlength{\emergencystretch}{3em}
        \pagestyle{fancy}
        \fancyhf{}
        \renewcommand{\headrulewidth}{0pt}
        \fancyfoot[C]{\ifnum\getpagerefnumber{LastPage}>1 \thepage\fi}
        \providecommand{\R}{\mathbb{R}}
        \providecommand{\N}{\mathbb{N}}
        \providecommand{\Z}{\mathbb{Z}}
        \providecommand{\Q}{\mathbb{Q}}
        \providecommand{\C}{\mathbb{C}}
        \providecommand{\degree}{^\circ}
        \providecommand{\abs}[1]{\left|#1\right|}
        \providecommand{\norm}[1]{\left\|#1\right\|}

        """#
    }

    // MARK: - Blocks

    private static func blocks(_ markdown: String, math: MathMode, anchors: [Int: String] = [:]) -> String {
        var output: [String] = []
        for (index, block) in MarkdownParser.parse(markdown).enumerated() {
            let start = output.count
            defer {
                // The label sits directly in front of the block it points to.
                if let label = anchors[index], output.count > start {
                    output[start] = anchorCommand(label) + output[start]
                }
            }
            switch block {
            case .paragraph(let text):
                output.append(inline(text, math: math))
            case .heading(let level, let text):
                let command = ["section", "subsection", "subsubsection"][min(max(level, 1), 3) - 1]
                output.append(level > 3 ? "\\paragraph*{\(inline(text, math: math))}" : "\\\(command)*{\(inline(text, math: math))}")
            case .code(_, let code):
                output.append(verbatim(code))
            case .list(let items):
                output.append(list(items, math: math))
            case .quote(let text):
                output.append("\\begin{quote}\n\(inline(text, math: math))\n\\end{quote}")
            case .table(let header, let rows):
                output.append(table(header: header, rows: rows, math: math))
            case .math(let latex, _):
                output.append(displayMath(latex, math: math))
            case .rule:
                output.append("\\noindent\\rule{\\linewidth}{0.4pt}")
            }
        }
        return output.joined(separator: "\n\n")
    }

    private static func plainText(_ text: String) -> String {
        text.trimmingCharacters(in: .whitespacesAndNewlines)
            .components(separatedBy: "\n\n")
            .map { paragraph in
                paragraph.components(separatedBy: "\n").map(escape).joined(separator: "\\newline\n")
            }
            .joined(separator: "\n\n")
    }

    private static func verbatim(_ code: String) -> String {
        let cleaned = String(code.replacingOccurrences(of: "\t", with: "    ").filter { !isEmoji($0) })
        guard !cleaned.contains("\\end{Verbatim}") else {
            let lines = cleaned.components(separatedBy: "\n").map { escape($0) }
            return "{\\ttfamily\\small\\raggedright\n" + lines.joined(separator: "\\newline\n") + "\\par}"
        }
        return """
        \\begin{Verbatim}[breaklines,breakanywhere,fontsize=\\small,frame=leftline,framerule=0.6pt,rulecolor=\\color{gray!60},xleftmargin=0.8em]
        \(cleaned)
        \\end{Verbatim}
        """
    }

    private static func list(_ items: [MarkdownBlock.ListItem], math: MathMode) -> String {
        var output = ""
        var stack: [String] = []

        func environment(for item: MarkdownBlock.ListItem) -> String {
            item.marker == nil ? "itemize" : "enumerate"
        }
        func open(_ item: MarkdownBlock.ListItem) {
            let name = environment(for: item)
            var options = stack.isEmpty ? ["leftmargin=*", "itemsep=2pt"] : ["itemsep=1pt"]
            if name == "enumerate", let start = item.marker.flatMap({ Int($0.dropLast()) }), start != 1 {
                options.append("start=\(start)")
            }
            output += "\\begin{\(name)}[\(options.joined(separator: ","))]\n"
            stack.append(name)
        }

        for item in items {
            // A list can only go one level deeper at a time; LaTeX needs an \item before nesting.
            let level = min(item.level, stack.count, 3)
            while stack.count > level + 1 { output += "\\end{\(stack.removeLast())}\n" }
            if stack.count == level + 1, stack.last != environment(for: item) {
                output += "\\end{\(stack.removeLast())}\n"
            }
            while stack.count < level + 1 { open(item) }
            output += "\\item " + inline(item.text, math: math) + "\n"
        }
        while let name = stack.popLast() { output += "\\end{\(name)}\n" }
        return output
    }

    private static func table(header: [String], rows: [[String]], math: MathMode) -> String {
        let columns = max(header.count, 1)
        var output = "\\begin{xltabular}{\\linewidth}{@{}\(String(repeating: "L", count: columns))@{}}\n\\toprule\n"
        output += header.map { "\\textbf{\(inline($0, math: math))}" }.joined(separator: " & ") + " \\\\\n\\midrule\n\\endhead\n"
        for row in rows {
            let cells = (0..<columns).map { $0 < row.count ? inline(row[$0], math: math) : "" }
            output += cells.joined(separator: " & ") + " \\\\\n"
        }
        return output + "\\bottomrule\n\\end{xltabular}"
    }

    // MARK: - Math

    private static let numberedEnvironments = ["equation", "align", "gather", "multline", "flalign", "alignat", "eqnarray"]

    private static func displayMath(_ latex: String, math: MathMode) -> String {
        var content = latex.trimmingCharacters(in: .whitespacesAndNewlines)
        if !usesLaTeX(content, math: math) { return verbatim(content) }
        content = content.replacingOccurrences(of: #"\\label\{[^}]*\}"#, with: "", options: .regularExpression)

        // A numbered environment on its own: keep it, but without equation numbers.
        for name in numberedEnvironments where content.hasPrefix("\\begin{\(name)}") || content.hasPrefix("\\begin{\(name)*}") {
            return content
                .replacingOccurrences(of: "\\begin{\(name)}", with: "\\begin{\(name)*}")
                .replacingOccurrences(of: "\\end{\(name)}", with: "\\end{\(name)*}")
        }

        // Inside \[ … \] only the inner variants are allowed.
        let inner: [(String, String?)] = [
            ("align*", "aligned"), ("align", "aligned"), ("gather*", "gathered"), ("gather", "gathered"),
            ("equation*", nil), ("equation", nil), ("multline*", "gathered"), ("multline", "gathered"),
        ]
        for (from, to) in inner {
            content = content
                .replacingOccurrences(of: "\\begin{\(from)}", with: to.map { "\\begin{\($0)}" } ?? "")
                .replacingOccurrences(of: "\\end{\(from)}", with: to.map { "\\end{\($0)}" } ?? "")
        }
        if content.contains("\\\\") && !content.contains("\\begin{") {
            content = "\\begin{gathered}\n\(content)\n\\end{gathered}"
        }
        return "\\[\n\(content)\n\\]"
    }

    private static func inlineMath(_ latex: String, math: MathMode) -> String {
        guard usesLaTeX(latex, math: math) else { return "\\texttt{\(escape(latex))}" }
        return "\\(" + latex.replacingOccurrences(of: #"\\(label|tag)\*?\{[^}]*\}"#, with: "", options: .regularExpression) + "\\)"
    }

    private static func usesLaTeX(_ latex: String, math: MathMode) -> Bool {
        switch math {
        case .native: return true
        case .plain: return false
        case .safe:
            var error: NSError?
            return MTMathListBuilder.build(fromString: MathRenderer.normalize(latex), error: &error) != nil && error == nil
        }
    }

    // MARK: - Inline text

    private static let placeholder = "\u{E000}"

    private static func inline(_ source: String, math: MathMode) -> String {
        var markdown = ""
        var formulas: [String] = []
        // Writer Studio stores underline as <u>…</u>. Placeholders made of letters carry it through the Markdown
        // parser and the escaping (it drops private-use characters).
        let source = source.replacingOccurrences(of: "<u>", with: Self.underlineOpen).replacingOccurrences(of: "</u>", with: Self.underlineClose)
        for segment in MathTokenizer.segments(source.trimmingCharacters(in: .whitespacesAndNewlines)) {
            switch segment {
            case .text(let text): markdown += text
            case .math(let latex):
                markdown += placeholder
                formulas.append(latex)
            }
        }

        let options = AttributedString.MarkdownParsingOptions(
            interpretedSyntax: .inlineOnlyPreservingWhitespace,
            failurePolicy: .returnPartiallyParsedIfPossible
        )
        let attributed = (try? AttributedString(markdown: markdown, options: options)) ?? AttributedString(markdown)

        var output = ""
        var formulaIndex = 0
        for run in attributed.runs {
            let text = String(attributed.characters[run.range])
            let intent = run.inlinePresentationIntent ?? []

            if intent.contains(.code) {
                output += "\\texttt{\(escape(text))}"
                continue
            }

            var piece = ""
            for (index, fragment) in text.components(separatedBy: placeholder).enumerated() {
                if index > 0, formulaIndex < formulas.count {
                    piece += inlineMath(formulas[formulaIndex], math: math)
                    formulaIndex += 1
                }
                piece += escape(fragment).replacingOccurrences(of: "\n", with: "\\newline\n")
                    .replacingOccurrences(of: Self.underlineOpen, with: "\\uline{").replacingOccurrences(of: Self.underlineClose, with: "}")
            }
            if intent.contains(.stronglyEmphasized) { piece = "\\textbf{\(piece)}" }
            if intent.contains(.emphasized) { piece = "\\emph{\(piece)}" }
            if intent.contains(.strikethrough) { piece = "\\sout{\(piece)}" }
            if let link = run.link { piece = "\\href{\(escapeURL(link.absoluteString))}{\(piece)}" }
            output += piece
        }
        return output
    }

    private static let underlineOpen = "LLMDULINEOPENX"
    private static let underlineClose = "LLMDULINECLOSEX"

    /// Characters the Latin Modern text font lacks, mapped to their math equivalents.
    private static let symbolReplacements: [Character: String] = [
        "→": "\\(\\rightarrow\\)", "←": "\\(\\leftarrow\\)", "↔": "\\(\\leftrightarrow\\)",
        "⇒": "\\(\\Rightarrow\\)", "⇐": "\\(\\Leftarrow\\)", "⇔": "\\(\\Leftrightarrow\\)",
        "≤": "\\(\\leq\\)", "≥": "\\(\\geq\\)", "≠": "\\(\\neq\\)", "≈": "\\(\\approx\\)",
        "∞": "\\(\\infty\\)", "√": "\\(\\surd\\)", "∑": "\\(\\sum\\)", "∆": "\\(\\Delta\\)",
        "✓": "\\(\\checkmark\\)", "✔": "\\(\\checkmark\\)", "✗": "\\(\\times\\)", "✘": "\\(\\times\\)",
    ]

    static func escape(_ text: String) -> String {
        var output = ""
        for character in text {
            if let replacement = symbolReplacements[character] {
                output += replacement
                continue
            }
            if isEmoji(character) { continue }
            if let scalar = character.unicodeScalars.first, (0x0370...0x03FF).contains(scalar.value) {
                output += "\\(\(character)\\)"   // Greek letters come from the math font
                continue
            }
            switch character {
            case "\"":
                // Straight quotes would print as two closing quotes; use German „…“ instead.
                let opens = output.last.map { $0.isWhitespace || "([{/-–".contains($0) } ?? true
                output += opens ? "„" : "“"
            case "\\": output += "\\textbackslash{}"
            case "{": output += "\\{"
            case "}": output += "\\}"
            case "$": output += "\\$"
            case "&": output += "\\&"
            case "#": output += "\\#"
            case "%": output += "\\%"
            case "_": output += "\\_"
            case "^": output += "\\textasciicircum{}"
            case "~": output += "\\textasciitilde{}"
            default: output.append(character)
            }
        }
        return output
    }

    private static func escapeURL(_ url: String) -> String {
        url.replacingOccurrences(of: "\\", with: "")
            .replacingOccurrences(of: "%", with: "\\%")
            .replacingOccurrences(of: "#", with: "\\#")
            .replacingOccurrences(of: "{", with: "")
            .replacingOccurrences(of: "}", with: "")
    }

    /// Emoji have no glyphs in the LaTeX fonts and would leave gaps, so they are dropped.
    private static func isEmoji(_ character: Character) -> Bool {
        character.unicodeScalars.contains { scalar in
            scalar.properties.isEmojiPresentation
                || scalar.value == 0xFE0F
                || (0x1F000...0x1FAFF).contains(scalar.value)
        }
    }
}

/// Finds an installed LaTeX engine and turns LaTeX source into PDF data.
struct LaTeXEngine: Sendable {
    enum Kind: String, Sendable {
        case tectonic, xelatex, lualatex
    }

    let kind: Kind
    let executable: URL

    private static let searchDirectories = [
        "/opt/homebrew/bin", "/usr/local/bin", "/Library/TeX/texbin", NSHomeDirectory() + "/.cargo/bin",
    ]

    static func locate() -> LaTeXEngine? {
        for kind in [Kind.tectonic, .xelatex, .lualatex] {
            for directory in searchDirectories {
                let path = "\(directory)/\(kind.rawValue)"
                if FileManager.default.isExecutableFile(atPath: path) {
                    return LaTeXEngine(kind: kind, executable: URL(fileURLWithPath: path))
                }
            }
        }
        return nil
    }

    /// Tries the document with native formulas first, then falls back to printing problematic formulas as code.
    func makePDF(parts: [LaTeXWriter.Part], outline: LaTeXWriter.Outline? = nil, paper: PaperSize) async throws -> Data {
        var lastError: Error = PDFExportError.compileFailed("")
        for mode in LaTeXWriter.MathMode.allCases {
            let source = await MainActor.run { LaTeXWriter.document(parts: parts, outline: outline, paper: paper, math: mode) }
            do {
                return try await compile(source, images: parts.flatMap(\.images))
            } catch {
                lastError = error
            }
        }
        throw lastError
    }

    func compile(_ source: String, images: [URL] = []) async throws -> Data {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("LLMDesigner-PDF-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        for image in Set(images) {
            try? FileManager.default.copyItem(at: image, to: directory.appendingPathComponent(image.lastPathComponent))
        }

        try source.write(to: directory.appendingPathComponent("export.tex"), atomically: true, encoding: .utf8)
        let log = directory.appendingPathComponent("engine.log")

        switch kind {
        case .tectonic:
            // Tectonic reruns by itself until references (page count) are stable.
            try await run(["--chatter", "minimal", "--untrusted", "export.tex"], in: directory, log: log)
        case .xelatex, .lualatex:
            for _ in 0..<2 {
                try await run(["-interaction=nonstopmode", "-halt-on-error", "-no-shell-escape", "export.tex"], in: directory, log: log)
            }
        }

        guard let pdf = try? Data(contentsOf: directory.appendingPathComponent("export.pdf")) else {
            throw PDFExportError.compileFailed(Self.errorExcerpt(from: log))
        }
        return pdf
    }

    private func run(_ arguments: [String], in directory: URL, log: URL) async throws {
        FileManager.default.createFile(atPath: log.path, contents: nil)
        let handle = try FileHandle(forWritingTo: log)
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        process.currentDirectoryURL = directory
        process.standardOutput = handle
        process.standardError = handle
        var environment = ProcessInfo.processInfo.environment
        environment["PATH"] = Self.searchDirectories.joined(separator: ":") + ":/usr/bin:/bin"
        process.environment = environment

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            process.terminationHandler = { finished in
                try? handle.close()
                if finished.terminationStatus == 0 {
                    continuation.resume()
                } else {
                    continuation.resume(throwing: PDFExportError.compileFailed(Self.errorExcerpt(from: log)))
                }
            }
            do {
                try process.run()
            } catch {
                try? handle.close()
                continuation.resume(throwing: error)
            }
        }
    }

    private static func errorExcerpt(from log: URL) -> String {
        guard let text = try? String(contentsOf: log, encoding: .utf8) else { return "" }
        let lines = text.components(separatedBy: .newlines)
        let errors = lines.filter { $0.hasPrefix("!") || $0.localizedCaseInsensitiveContains("error") }
        return (errors.isEmpty ? Array(lines.suffix(6)) : Array(errors.prefix(6)))
            .joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
