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

    var geometry: String {
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
        /// Writer Studio: the files of the pictures in the text (`![…](source)` lines), by their Markdown source.
        /// They become figures with a numbered caption. nil for chats, whose image lines stay text.
        var figures: [String: URL]?
        /// Writer Studio: the model's table of contents, set where the `[TOC]{.dynamic}` marker stands. Its targets
        /// are labels in `blockAnchors`.
        var contents: Outline?
        /// Writer Studio: the formatted reference list, set where the `[Literatur]` marker stands.
        var bibliography: [StyledText]?
    }

    struct OutlineEntry {
        var title: String
        var level: Int
        /// nil: the place wasn't found any more; the entry is listed without a page.
        var label: String?
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

    /// `figureFolder`: where the figure files are, relative to the document (nil: next to it).
    /// `typeface`: the font of a Writer Studio document (nil: LaTeX's own). Fonts that passages carry are set up too.
    /// `format`: a Writer Studio document's page format; a paperback or a Normseite brings its own paper.
    /// `design`: a Writer Studio document's own paper and margins (for the user's own format) and its running heads.
    static func document(parts: [Part], outline: Outline? = nil, paper: PaperSize, math: MathMode, figureFolder: String? = nil,
                         typeface: WriterFont? = nil, format: WriterPageFormat = .standard, design: WriterPageDesign = WriterPageDesign()) -> String {
        var body: [String] = []
        // Writer Studio documents with chapters are set as a report, where \chapter exists.
        let hasChapters = parts.contains { $0.figures != nil && WriterHeadings.hasChapters($0.text) }
        for part in parts {
            var section = ""
            if let anchor = part.anchor { section += anchorCommand(anchor) }
            if let label = part.label, !label.isEmpty {
                section += "\\noindent\\textbf{\(escape(label))}\\par\n"
            }
            for image in part.images {
                section += "\\begin{center}\\includegraphics[width=0.7\\linewidth,height=0.35\\textheight,keepaspectratio]{\(image.lastPathComponent)}\\end{center}\n"
            }
            let structure = part.figures == nil ? nil : Structure(numbered: WriterHeadings.isFormal(part.text), chapters: hasChapters,
                                                                  marksChapters: design.runningHeads?.usesChapter == true,
                                                                  lineSpacing: format.lineSpread(setup: design.setup))
            section += part.isPlainText
                ? plainText(part.text)
                : blocks(part.text, math: math, anchors: part.blockAnchors, figures: part.figures, figureFolder: figureFolder, structure: structure,
                         contents: part.contents, bibliography: part.bibliography, format: format)
            body.append(section)
        }
        let contents = outline.map { tableOfContents($0, math: math) } ?? ""
        let spanFonts = parts.filter { $0.figures != nil }.flatMap { WriterSpans.fonts(in: $0.text) }
        // Writer Studio's text is left-aligned like in the editor (a paperback is justified); a paragraph may be
        // justified, centred or right-aligned. \raggedright takes the indent of a Normseite's paragraphs away.
        let isWriterDocument = parts.contains { $0.figures != nil }
        let start = isWriterDocument && format.isRaggedRight
            ? "\\raggedright\n" + (format.isBook ? "\\setlength{\\parindent}{\(format.paragraphIndent)}\n" : "") : ""
        return preamble(paper, documentClass: hasChapters ? "report" : "article", typeface: typeface, spanFonts: spanFonts, format: format, design: design)
            + "\\begin{document}\n" + start + contents
            + body.joined(separator: "\n\n\\bigskip\n\n") + "\n\\end{document}\n"
    }

    /// The reference list: an unnumbered heading in the table of contents, entries with a hanging indent.
    private static func referenceList(_ entries: [StyledText], chapters: Bool) -> String {
        let command = chapters ? "chapter" : "section"
        var output = "\\\(command)*{Literatur}\n\\addcontentsline{toc}{\(command)}{Literatur}\n"
        guard !entries.isEmpty else { return output + "\\emph{Keine Quellenangaben im Dokument.}" }
        output += "\\begin{list}{}{\\setlength{\\leftmargin}{1.5em}\\setlength{\\itemindent}{-1.5em}\\setlength{\\itemsep}{0.35em}\\setlength{\\parsep}{0pt}}\n"
        for entry in entries {
            output += "\\item " + entry.latex(referenceText) + "\n"
        }
        return output + "\\end{list}"
    }

    /// Text of a reference; its web addresses become breakable links.
    private static func referenceText(_ text: String) -> String {
        var output = ""
        for word in text.split(separator: " ", omittingEmptySubsequences: false) {
            if !output.isEmpty { output += " " }
            if word.hasPrefix("http://") || word.hasPrefix("https://") {
                output += "\\url{" + escapeURL(String(word)) + "}"
            } else {
                output += escape(String(word))
            }
        }
        return output
    }

    /// How a Writer Studio document's headings are set: numbered (it has a table of contents) and with chapters.
    struct Structure {
        var numbered: Bool
        var chapters: Bool
        /// The running heads show the chapter: the top headings set the mark (`\llmdmark`).
        var marksChapters = false
        /// The document's own line spread, which a paragraph's line spacing multiplies.
        var lineSpacing: Double = 1
    }

    /// Table of contents on its own page(s): linked entries with page numbers via `\pageref`.
    /// `standalone`: on pages of its own before the content, with the summary (chat export); otherwise in the
    /// text where a Writer Studio document has it, under a heading of the given command.
    private static func tableOfContents(_ outline: Outline, math: MathMode, standalone: Bool = true, headingCommand: String = "section") -> String {
        var output = "\\\(headingCommand)*{Inhaltsverzeichnis}\n"
        let summary = outline.summary.trimmingCharacters(in: .whitespacesAndNewlines)
        if standalone, !summary.isEmpty {
            output += "{\\itshape \(inline(summary, math: math))\\par}\n\\medskip\n"
        }
        var number = 0
        for entry in outline.entries {
            let title = inline(entry.title, math: math)
            let page = entry.label.map { "\\dotfill\\pageref*{\($0)}\\par\n" } ?? "\\par\n"
            func linked(_ text: String) -> String {
                entry.label.map { "\\hyperref[\($0)]{\(text)}" } ?? text
            }
            if entry.level == 0 {
                number += 1
                output += "\\vspace{4pt}\\noindent" + linked("\\textbf{\(number)\\quad \(title)}") + page
            } else {
                output += "\\noindent\\hspace*{1.6em}" + linked(title) + page
            }
        }
        return output + (standalone ? "\\clearpage\n\n" : "\\bigskip\n")
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

    /// The fonts: the document's text font and a code font (both only when it is set), and one font family per
    /// font that passages use, `\llmdfont<name>`. A font this Mac lacks is skipped, LaTeX's own stays.
    private static func fontSetup(typeface: WriterFont?, spanFonts: [WriterFont]) -> String {
        var lines: [String] = []
        if let typeface {
            lines.append("\\IfFontExistsTF{\(typeface.latexFamily)}{\\setmainfont{\(typeface.latexFamily)}\(typeface.latexOptions ?? "")}{}")
            lines.append("\\IfFontExistsTF{Menlo}{\\setmonofont{Menlo}[Scale=MatchLowercase]}{}")
        }
        var seen = Set<WriterFont>()
        for font in spanFonts where seen.insert(font).inserted {
            let macro = fontMacro(font)
            lines.append("\\IfFontExistsTF{\(font.latexFamily)}{\\newfontfamily\\\(macro){\(font.latexFamily)}\(font.latexOptions ?? "")}{\\newcommand{\\\(macro)}{}}")
        }
        return lines.isEmpty ? "" : lines.joined(separator: "\n") + "\n"
    }

    /// The switch that sets text in a passage's font: letters only, so it is a valid macro name.
    static func fontMacro(_ font: WriterFont) -> String { "llmdfont" + font.rawValue }

    private static func preamble(_ paper: PaperSize, documentClass: String = "article", typeface: WriterFont? = nil,
                                 spanFonts: [WriterFont] = [], format: WriterPageFormat = .standard,
                                 design: WriterPageDesign = WriterPageDesign()) -> String {
        // The classes know 10, 11 and 12 pt; another size of the user's own format is set at the start of the text.
        let size = format == .custom ? CGFloat(design.setup?.fontSize ?? 11) : format.printSize
        let classSize = min(12, max(10, Int(size.rounded())))
        var pageSetup = ""
        if format == .custom, let setup = design.setup {
            if abs(Double(classSize) - setup.fontSize) > 0.01 {
                pageSetup += "\\AtBeginDocument{\\fontsize{\(WriterSpanStyle.format(setup.fontSize))pt}{\(WriterSpanStyle.format(setup.fontSize * 1.2))pt}\\selectfont}\n"
            }
            if abs(setup.lineSpacing - 1) > 0.001 { pageSetup += "\\linespread{\(WriterParagraphFormat.number(setup.lineSpacing))}\n" }
        }
        if let heads = design.runningHeads { pageSetup += heads.latexSetup(title: design.title) }
        return #"""
        \documentclass[\#(classSize)pt]{\#(documentClass)}
        \usepackage[\#(format.geometry(paper: paper, setup: design.setup))]{geometry}
        \usepackage{amsmath}
        \usepackage{fontspec}
        \#(fontSetup(typeface: typeface, spanFonts: spanFonts))
        \usepackage{unicode-math}
        \setmathfont{latinmodern-math.otf}
        \usepackage[ngerman,shorthands=off]{babel}
        \usepackage[table]{xcolor}
        \usepackage{graphicx}
        \usepackage{multirow}
        \usepackage{fvextra}
        \usepackage{booktabs,xltabular}
        \newcolumntype{L}{>{\raggedright\arraybackslash}X}
        \newcolumntype{C}{>{\centering\arraybackslash}X}
        \newcolumntype{R}{>{\raggedleft\arraybackslash}X}
        \newcommand{\llmdjustify}{\leftskip=0pt\rightskip=0pt\parfillskip=0pt plus 1fil\relax}
        \usepackage{float}
        \usepackage{multicol}
        \usepackage{wrapfig}
        \usepackage{tcolorbox}
        \tcbuselibrary{skins,breakable}
        \usepackage[font=small,labelfont=bf]{caption}
        \usepackage{enumitem}
        \usepackage[normalem]{ulem}
        \#(format.isBook ? "" : "\\usepackage{parskip}")
        \usepackage{lastpage,refcount}
        \usepackage{fancyhdr}
        \usepackage[hidelinks]{hyperref}
        \urlstyle{same}
        \setlength{\emergencystretch}{3em}
        \setcounter{secnumdepth}{3}
        \setcounter{tocdepth}{3}
        \pagestyle{fancy}
        \fancyhf{}
        \renewcommand{\headrulewidth}{0pt}
        \fancyfoot[C]{\ifnum\getpagerefnumber{LastPage}>1 \thepage\fi}
        \def\llmdBS{\char`\\}
        \def\llmdOB{\char`\{}
        \def\llmdCB{\char`\}}
        \providecommand{\R}{\mathbb{R}}
        \providecommand{\N}{\mathbb{N}}
        \providecommand{\Z}{\mathbb{Z}}
        \providecommand{\Q}{\mathbb{Q}}
        \providecommand{\C}{\mathbb{C}}
        \providecommand{\degree}{^\circ}
        \providecommand{\abs}[1]{\left|#1\right|}
        \providecommand{\norm}[1]{\left\|#1\right\|}
        \newcommand{\llmdmark}[1]{\markboth{#1}{#1}}
        \#(format.latexSetup)
        \#(pageSetup)
        """#
    }

    // MARK: - Blocks

    private static func blocks(_ markdown: String, math: MathMode, anchors: [Int: String] = [:], figures: [String: URL]? = nil,
                               figureFolder: String? = nil, structure: Structure? = nil, contents: Outline? = nil,
                               bibliography: [StyledText]? = nil, format: WriterPageFormat = .standard) -> String {
        var output: [String] = []
        let annotatedBlocks = MarkdownParser.parseAnnotated(markdown)
        // Writer Studio's boxes and sections in columns, as they open and close around the blocks.
        var openSection: Int?
        var openBox: (serial: Int, floats: Bool)?
        func closeBox() {
            guard let box = openBox else { return }
            output.append("\\end{tcolorbox}" + (box.floats ? "\n\\end{wrapfigure}" : ""))
            openBox = nil
        }
        for (index, annotated) in annotatedBlocks.enumerated() {
            let block = annotated.block
            if structure != nil {
                let sectionDiv = annotated.div(WriterColumnStyle.className)
                let boxDiv = annotated.div(WriterBoxStyle.className)
                if let box = openBox, box.serial != boxDiv?.serial { closeBox() }
                if openSection != sectionDiv?.serial {
                    closeBox()
                    if openSection != nil { output.append("\\end{multicols}}") }
                    openSection = sectionDiv?.serial
                    if let sectionDiv { output.append(columnsOpening(WriterColumnStyle(attributes: sectionDiv.attributes))) }
                }
                if openBox == nil, let boxDiv {
                    let style = WriterBoxStyle(attributes: boxDiv.attributes)
                    let floats = style.floats && openSection == nil
                    output.append(boxOpening(style, serial: boxDiv.serial, floats: floats, math: math))
                    openBox = (boxDiv.serial, floats)
                }
            }
            // Writer Studio aligns and indents paragraphs with divs (`::: {.center indent=1cm}`); chats have none.
            let paragraphFormat = structure == nil ? WriterParagraphFormat() : WriterParagraphFormat(classes: annotated.formatClasses, attributes: annotated.formatAttributes)
            let alignment = paragraphFormat.alignment
            let start = output.count
            defer {
                // The label sits directly in front of the block it points to.
                if let label = anchors[index], output.count > start {
                    output[start] = anchorCommand(label) + output[start]
                }
            }
            switch block {
            case .paragraph(let text):
                let lines = text.components(separatedBy: "\n")
                let images = lines.compactMap(WriterImageReference.parse)
                if structure != nil, lines.count == 1, WriterBibliographyAttachment.isMarker(lines[0]) {
                    output.append(referenceList(bibliography ?? [], chapters: structure?.chapters == true))
                } else if let structure, lines.count == 1, let dynamic = WriterTOCAttachment.kind(of: lines[0]) {
                    if !dynamic {
                        output.append("\\tableofcontents" + (structure.chapters ? "" : "\n\\bigskip"))
                    } else if let contents {
                        output.append(tableOfContents(contents, math: math, standalone: false, headingCommand: structure.chapters ? "chapter" : "section"))
                    }
                } else if let figures, !images.isEmpty, images.count == lines.count {
                    output.append(images.map { figure($0, file: figures[$0.source], folder: figureFolder, math: math) }.joined(separator: "\n\n"))
                } else if structure != nil {
                    // A book's paragraphs are indented, but not the first one and not after a scene break, as in the editor.
                    let flush = format.isBook && (index == 0 || Self.endsSection(annotatedBlocks[index - 1].block))
                    let set = paragraphFormat.applying(to: .paragraph)
                    // A first-line indent of its own replaces the book's.
                    let noIndent = flush && set.firstLine == nil
                    output.append(paragraph((noIndent ? "\\noindent " : "") + inline(text, math: math), alignment: alignment,
                                            largestSize: WriterSpans.largestSize(in: text), format: format,
                                            switches: set.latexSwitches(baseLineSpacing: structure?.lineSpacing ?? 1)))
                } else {
                    output.append(inline(text, math: math))
                }
            case .heading(let level, let text):
                if let structure {
                    // Writer Studio: chapters, and numbers when the document has a table of contents.
                    let (title, classes) = WriterMarkdown.headingAttributes(text)
                    let command = classes.contains("chapter") && level == 1 && structure.chapters
                        ? "chapter" : ["section", "subsection", "subsubsection"][min(max(level, 1), 3) - 1]
                    let set = inline(title, math: math)
                    // A centred or right-aligned title: the switch goes inside, the table of contents gets the title alone.
                    if let switchCommand = alignment.flatMap(headingAlignment) {
                        let short = structure.numbered ? "[\(set)]" : ""
                        output.append("\\\(command)\(structure.numbered ? "" : "*")\(short){\(switchCommand) \(set)}")
                    } else {
                        output.append("\\\(command)\(structure.numbered ? "" : "*"){\(set)}")
                    }
                    // The running heads' {Kapitel}: the chapters, or the first-level headings without them.
                    if structure.marksChapters, command == "chapter" || (!structure.chapters && command == "section") {
                        output[output.count - 1] += "\\llmdmark{\(inline(WriterSpans.strippingStyles(title), math: math))}"
                    }
                    break
                }
                let command = ["section", "subsection", "subsubsection"][min(max(level, 1), 3) - 1]
                output.append(level > 3 ? "\\paragraph*{\(inline(text, math: math))}" : "\\\(command)*{\(inline(text, math: math))}")
            case .code(let language, let code):
                output.append(verbatim(code, language: language))
            case .list(let items):
                let spacing = paragraphFormat.applying(to: .bullet).lineSpacing
                let set = list(items, math: math)
                output.append(spacing.map { "{\\linespread{\(WriterParagraphFormat.number($0 * (structure?.lineSpacing ?? 1)))}\\selectfont\n" + set + "\\par}" } ?? set)
            case .quote(let text):
                let switches = (alignmentCommand(alignment).map { [$0] } ?? [])
                    + paragraphFormat.applying(to: .quote).latexSwitches(baseLineSpacing: structure?.lineSpacing ?? 1)
                let switchCommand = switches.isEmpty ? "" : switches.joined() + "\n"
                output.append("\\begin{quote}\n\(switchCommand)\(inline(text, math: math))\n\\end{quote}")
            case .table(let header, let rows, let alignments, let widths):
                // Writer Studio's tables may have merged cells, lines of their own and coloured cells.
                let style = structure == nil ? nil
                    : annotated.div(WriterTableStyle.className).map { WriterTableStyle(attributes: $0.attributes) } ?? WriterTableStyle()
                output.append(table(header: header, rows: rows, alignments: alignments, widths: widths, math: math, style: style))
            case .math(let latex, _):
                output.append(displayMath(latex, math: math))
            case .rule:
                output.append("\\noindent\\rule{\\linewidth}{0.4pt}")
            case .pageBreak:
                output.append(structure == nil ? "\\noindent\\rule{\\linewidth}{0.4pt}" : "\\clearpage")
            case .columnBreak:
                if openSection != nil { output.append("\\columnbreak") }
            }
        }
        closeBox()
        if openSection != nil { output.append("\\end{multicols}}") }
        return output.joined(separator: "\n\n")
    }

    /// The start of a section in columns: their gap and line, then `multicols`.
    private static func columnsOpening(_ style: WriterColumnStyle) -> String {
        "{\\setlength{\\columnsep}{\(WriterParagraphFormat.number(style.gap))cm}\\setlength{\\columnseprule}{\(style.rule ? "0.4pt" : "0pt")}"
            + "\n\\begin{multicols}{\(style.count)}"
    }

    /// The start of a box: its colour, its frame, where it stands (a floating one in `wrapfigure`, so the text flows
    /// around it), and its title as its first line.
    private static func boxOpening(_ style: WriterBoxStyle, serial: Int, floats: Bool, math: MathMode) -> String {
        let color = "llmdbox" + WriterTableCalc.columnName(serial)
        var options = ["enhanced", "boxsep=0pt", "left=8pt", "right=8pt", "top=6pt", "bottom=6pt"]
        switch style.frame {
        case .bar: options += ["colback=\(color)!7!white", "frame hidden", "borderline west={3pt}{0pt}{\(color)}", "sharp corners"]
        case .outline: options += ["colback=\(color)!4!white", "colframe=\(color)", "boxrule=0.6pt", "arc=2mm"]
        case .filled: options += ["colback=\(color)!15!white", "frame hidden", "arc=2mm"]
        }
        var output = "\\definecolor{\(color)}{HTML}{\(style.printColor)}\n"
        let share = String(format: "%.2f", Double(style.share))
        if floats {
            output += "\\begin{wrapfigure}{\(style.position == .left ? "l" : "r")}{\(share)\\linewidth}\n"
            options += ["width=\\linewidth", "before skip=0pt", "after skip=0pt"]
        } else {
            options += ["breakable", "before skip=8pt", "after skip=10pt"]
            switch style.position {
            case .full: break
            case .left: options += ["width=\(share)\\linewidth", "flush left"]
            case .center: options += ["width=\(share)\\linewidth", "center"]
            case .right: options += ["width=\(share)\\linewidth", "flush right"]
            }
        }
        output += "\\begin{tcolorbox}[\(options.joined(separator: ", "))]"
        if style.hasTitle {
            output += "\n\\noindent\\textbf{\\textcolor{\(color)}{\(inline(style.effectiveTitle, math: math))}}\\par\\smallskip"
        }
        return output
    }

    /// A rule (a scene break) or a table of contents: the paragraph after it starts at the margin in a book.
    private static func endsSection(_ block: MarkdownBlock) -> Bool {
        switch block {
        case .rule, .pageBreak: return true
        case .paragraph(let text): return WriterTOCAttachment.isMarker(text) || WriterBibliographyAttachment.isMarker(text)
        default: return false
        }
    }

    /// The switch that sets a Writer Studio paragraph as the editor shows it; nil for left, which is the text's own.
    private static func alignmentCommand(_ alignment: WriterAlignment?) -> String? {
        switch alignment {
        case .center: "\\centering"
        case .right: "\\raggedleft"
        case .justify: "\\llmdjustify"
        case .left, nil: nil
        }
    }

    /// Headings are short: only centred and right-aligned ones need a switch.
    private static func headingAlignment(_ alignment: WriterAlignment) -> String? {
        alignment == .center || alignment == .right ? alignmentCommand(alignment) : nil
    }

    /// A paragraph of Writer Studio, aligned, and with room between its lines for the largest letters in it. A
    /// paperback is justified, so a paragraph set left there needs its switch.
    /// `switches`: the paragraph's own line spacing and indents (`WriterParagraphFormat.latexSwitches`).
    private static func paragraph(_ text: String, alignment: WriterAlignment?, largestSize: Double?, format: WriterPageFormat,
                                  switches own: [String] = []) -> String {
        var switches: [String] = []
        if let command = alignmentCommand(alignment) {
            switches.append(command)
        } else if alignment == .left, format.isJustified {
            switches.append("\\raggedright")
        }
        // The line spacing's \\selectfont comes before the room for large letters, which it would undo.
        switches += own
        if let largestSize, largestSize > Double(format.printSize) {
            switches.append("\\setlength{\\baselineskip}{\(WriterSpanStyle.format(largestSize * 1.2))pt}")
        }
        guard !switches.isEmpty else { return text }
        return "{" + switches.joined() + " " + text + "\\par}"
    }

    private static func plainText(_ text: String) -> String {
        text.trimmingCharacters(in: .whitespacesAndNewlines)
            .components(separatedBy: "\n\n")
            .map { paragraph in
                paragraph.components(separatedBy: "\n").map(escape).joined(separator: "\\newline\n")
            }
            .joined(separator: "\n\n")
    }

    private static func verbatim(_ code: String, language fence: String? = nil) -> String {
        let cleaned = String(code.replacingOccurrences(of: "\t", with: "    ").filter { !isEmoji($0) })
        // Python and SQL are set in colours (the light theme: the paper is white). Lines break at spaces only: breaking
        // anywhere doesn't work inside the colour groups.
        if let language = fence.flatMap({ CodeLanguage(fence: $0) }) ?? (fence?.isEmpty == false ? nil : CodeLanguage.detect(cleaned)),
           !cleaned.contains("\\end{Verbatim}") {
            return """
            \\begin{Verbatim}[commandchars=\\\\\\{\\},breaklines,fontsize=\\small,frame=leftline,framerule=0.6pt,rulecolor=\\color{gray!60},xleftmargin=0.8em]
            \(colouredCode(cleaned, language: language))
            \\end{Verbatim}
            """
        }
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

    /// Code with its tokens in colours, for a Verbatim environment whose command characters are `\`, `{` and `}`: those
    /// three are written with macros of the preamble, and a token that spans lines is coloured line by line.
    static func colouredCode(_ code: String, language: CodeLanguage) -> String {
        let units = Array(code.utf16)
        let tokens = CodeHighlighter.tokens(in: code, language: language).sorted { $0.range.location < $1.range.location }
        var output = ""

        func emit(_ range: Range<Int>, kind: CodeTokenKind) {
            let text = String(utf16CodeUnits: Array(units[range]), count: range.count)
            output += text.components(separatedBy: "\n").map { line -> String in
                guard !line.isEmpty else { return "" }
                var escaped = ""
                for character in line {
                    switch character {
                    case "\\": escaped += "\\llmdBS{}"
                    case "{": escaped += "\\llmdOB{}"
                    case "}": escaped += "\\llmdCB{}"
                    default: escaped.append(character)
                    }
                }
                guard let hex = CodeTheme.hex(kind, light: true) else { return escaped }
                return "\\textcolor[HTML]{\(String(format: "%06X", hex))}{\(escaped)}"
            }.joined(separator: "\n")
        }

        var position = 0
        for token in tokens {
            let start = token.range.location, end = NSMaxRange(token.range)
            guard start >= position else { continue }
            if start > position { emit(position..<start, kind: .plain) }
            emit(start..<end, kind: token.kind)
            position = end
        }
        if position < units.count { emit(position..<units.count, kind: .plain) }
        return output
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

    /// A picture from a Writer Studio document: at its width in the column, kept in place, with a numbered
    /// caption. A missing file leaves a note instead of breaking the document.
    private static func figure(_ image: WriterImageReference, file: URL?, folder: String?, math: MathMode) -> String {
        let caption = image.caption.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let file else {
            if image.generated {
                // A placeholder for a picture still to be made: a framed note with what it will show.
                let info = WriterImageStore.generationInfo(for: image.source)
                let what = (info?.description.isEmpty == false ? info?.description : caption.isEmpty ? nil : caption) ?? ""
                return "\\begin{center}\\fbox{\\parbox{0.8\\linewidth}{\\centering\\emph{Bild folgt\(what.isEmpty ? "" : ": " + escape(what))}}}\\end{center}"
            }
            return "\\begin{center}\\emph{[Bild fehlt\(caption.isEmpty ? "" : ": " + escape(caption))]}\\end{center}"
        }
        let width = image.width.map { CGFloat($0) / 100 } ?? WriterImageStore.naturalWidthFraction(of: file)
        let path = (folder.map { $0 + "/" } ?? "") + file.lastPathComponent
        var output = "\\begin{figure}[H]\n\\centering\n"
        output += "\\includegraphics[width=\(String(format: "%.2f", width))\\linewidth,height=0.6\\textheight,keepaspectratio]{\(path)}\n"
        if !caption.isEmpty { output += "\\caption{\(inline(caption, math: math))}\n" }
        return output + "\\end{figure}"
    }

    /// A table. `style` is set for Writer Studio, whose tables may merge cells (`<<` and `^^`), have other lines than
    /// the book's three and coloured cells; nil for chats.
    private static func table(header: [String], rows: [[String]], alignments: [MarkdownBlock.Alignment], widths: [Double]?,
                              math: MathMode, style: WriterTableStyle? = nil) -> String {
        let columns = max(header.count, 1)
        let widths = widths?.count == columns ? widths : nil
        let all = [header] + rows
        let spans = style == nil ? [:] : WriterTableMerge.spans(in: all, columns: columns)
        let style = style ?? WriterTableStyle()
        func justification(_ column: Int) -> String {
            switch column < alignments.count ? alignments[column] : .leading {
            case .leading: "\\raggedright"
            case .center: "\\centering"
            case .trailing: "\\raggedleft"
            }
        }
        let spec = (0..<columns).map { column -> String in
            let alignment = column < alignments.count ? alignments[column] : .leading
            // Columns of their own width: tabularx shares the width by the factors of `\hsize`, which add up to the
            // number of columns.
            if let widths {
                let factor = String(format: "%.3f", widths[column] * Double(columns))
                return ">{\\hsize=\(factor)\\hsize\\linewidth=\\hsize\(justification(column))\\arraybackslash}X"
            }
            switch alignment {
            case .leading: return "L"
            case .center: return "C"
            case .trailing: return "R"
            }
        }
        guard !spans.isEmpty || !style.isStandard else {
            var output = "\\begin{xltabular}{\\linewidth}{@{}\(spec.joined())@{}}\n\\toprule\n"
            output += header.map { "\\textbf{\(inline($0, math: math))}" }.joined(separator: " & ") + " \\\\\n\\midrule\n\\endhead\n"
            for row in rows {
                let cells = (0..<columns).map { $0 < row.count ? inline(row[$0], math: math) : "" }
                output += cells.joined(separator: " & ") + " \\\\\n"
            }
            return output + "\\bottomrule\n\\end{xltabular}"
        }

        let lines = style.lines
        let vertical = lines == .grid
        let frame = lines == .grid || lines == .frame
        func text(_ row: Int, _ column: Int) -> String {
            column < all[row].count ? all[row][column] : ""
        }
        func fill(_ start: WriterCellPosition) -> String {
            style.fills[start].map { "\\cellcolor[HTML]{\($0)}" } ?? ""
        }
        /// The column spec of a merged cell from `column` over `count` columns, with the rules at its sides.
        func multicolumnSpec(_ column: Int, _ count: Int) -> String {
            let share = (column..<(column + count)).map { widths?[$0] ?? (1 / Double(columns)) }.reduce(0, +) * Double(columns)
            let room = count > 1 ? "+\(2 * (count - 1))\\tabcolsep" + (vertical ? "+\(count - 1)\\arrayrulewidth" : "") : ""
            let left = column == 0 ? (frame ? "|" : "@{}") : ""
            let right = column + count == columns ? (frame ? "|" : "@{}") : (vertical ? "|" : "")
            return left + ">{\\hsize=\\dimexpr\(String(format: "%.3f", share))\\hsize\(room)\\relax\\linewidth=\\hsize\(justification(column))\\arraybackslash}X" + right
        }

        let edge = frame ? "|" : "@{}"
        var output = "\\begingroup\n"
        if let width = style.lineWidth {
            output += "\\setlength{\\arrayrulewidth}{\(WriterParagraphFormat.number(width))pt}\\setlength{\\heavyrulewidth}{\(WriterParagraphFormat.number(width))pt}\\setlength{\\lightrulewidth}{\(WriterParagraphFormat.number(width))pt}\n"
        } else {
            output += "\\setlength{\\arrayrulewidth}{0.5pt}\n"
        }
        output += "\\begin{xltabular}{\\linewidth}{\(edge)\(spec.joined(separator: vertical ? "|" : ""))\(edge)}\n"

        /// The line under a row: across, or around merged cells that go on into the next row.
        func lineBelow(_ row: Int) -> String {
            guard row + 1 < all.count else { return "" }
            var open: [ClosedRange<Int>] = []
            for column in 0..<columns {
                let (start, span) = WriterTableMerge.cell(at: WriterCellPosition(row: row, column: column), in: spans)
                guard start.row + span.rows - 1 <= row else { continue }
                if let last = open.last, last.upperBound == column - 1 {
                    open[open.count - 1] = last.lowerBound...column
                } else {
                    open.append(column...column)
                }
            }
            if open.isEmpty { return "" }
            if open.count == 1, open[0] == 0...(columns - 1) { return lines == .standard ? "\\midrule\n" : "\\hline\n" }
            let command = lines == .standard ? "\\cmidrule" : "\\cline"
            return open.map { "\(command){\($0.lowerBound + 1)-\($0.upperBound + 1)}" }.joined() + "\n"
        }

        switch lines {
        case .standard: output += "\\toprule\n"
        case .grid, .horizontal, .frame: output += "\\hline\n"
        case .none: break
        }
        for row in all.indices {
            var cells: [String] = []
            var column = 0
            while column < columns {
                let place = WriterCellPosition(row: row, column: column)
                let (start, span) = WriterTableMerge.cell(at: place, in: spans)
                var content = inline(text(start.row, start.column), math: math)
                if start.row == 0 { content = "\\textbf{\(content)}" }
                // A cell over several rows is written in its last row, raised to their middle, so the colours of the
                // rows below don't cover it; its other rows only carry its colour.
                if span.rows > 1 {
                    content = row == start.row + span.rows - 1 ? "\\multirow{-\(span.rows)}{=}{\(justification(start.column)) \(content)}" : ""
                } else if start != place {
                    content = ""
                }
                content = fill(start) + content
                if span.columns > 1 {
                    cells.append("\\multicolumn{\(span.columns)}{\(multicolumnSpec(start.column, span.columns))}{\(content)}")
                } else {
                    cells.append(content)
                }
                column = start.column + span.columns
            }
            output += cells.joined(separator: " & ") + " \\\\\n"
            switch lines {
            case .grid, .horizontal:
                output += lineBelow(row)
            case .standard, .frame:
                if row == 0, all.count > 1 { output += lines == .standard ? lineBelow(row) : "\\hline\n" }
            case .none:
                break
            }
            if row == 0, all.count > 1, spans.allSatisfy({ $0.key.row > 0 || $0.value.rows == 1 }) { output += "\\endhead\n" }
        }
        switch lines {
        case .standard: output += "\\bottomrule\n"
        case .grid, .horizontal, .frame: output += "\\hline\n"
        case .none: break
        }
        return output + "\\end{xltabular}\n\\endgroup"
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
        guard LaTeXSafety.isSafeFormula(latex) else { return false }
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
        // Writer Studio stores underline as <u>…</u>, colours and fonts of passages as <span style="…">, and line
        // breaks in table cells as <br>. Placeholders made of letters carry them through the Markdown parser and
        // the escaping (it drops private-use characters); they are set again run by run, so braces always balance.
        // Bookmarks only matter in the editor.
        let (spanned, styles) = convertSpans(source)
        let source = spanned
            .replacingOccurrences(of: "<u>", with: Self.underlineOpen).replacingOccurrences(of: "</u>", with: Self.underlineClose)
            .replacingOccurrences(of: "<sup>", with: Self.superOpen).replacingOccurrences(of: "</sup>", with: Self.superClose)
            .replacingOccurrences(of: "<sub>", with: Self.subOpen).replacingOccurrences(of: "</sub>", with: Self.subClose)
            .replacingOccurrences(of: #"<br\s*/?>"#, with: Self.lineBreak, options: [.regularExpression, .caseInsensitive])
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
        // What is open across runs: the passages' styles and underline.
        var styleStack: [WriterSpanStyle] = []
        var underlined = 0
        var raised = 0
        var lowered = 0
        for run in attributed.runs {
            let text = String(attributed.characters[run.range])
            let intent = run.inlinePresentationIntent ?? []

            /// Sets one stretch of text in what is open now.
            func wrap(_ piece: String) -> String {
                guard !piece.isEmpty else { return piece }
                var result = piece
                let color = styleStack.reversed().compactMap(\.color).first
                let font = styleStack.reversed().compactMap(\.font).first
                let size = styleStack.reversed().compactMap(\.size).first
                if let size {
                    result = "{\\fontsize{\(WriterSpanStyle.format(size))pt}{\(WriterSpanStyle.format(size * 1.2))pt}\\selectfont{}\(result)}"
                }
                if let font { result = "{\\\(fontMacro(font)){}\(result)}" }
                if let color { result = "\\textcolor[HTML]{\(color)}{\(result)}" }
                if raised > 0 { result = "\\textsuperscript{\(result)}" } else if lowered > 0 { result = "\\textsubscript{\(result)}" }
                if underlined > 0 { result = "\\uline{\(result)}" }
                return result
            }
            /// The stretches of the run between the placeholders, with the state at each.
            func stretches(_ text: String, _ set: (String) -> String) -> String {
                var result = ""
                var rest = Substring(text)
                while !rest.isEmpty {
                    guard let marker = rest.range(of: #"LLMDSPANO\d+X|LLMDSPANCX|LLMDULINEOPENX|LLMDULINECLOSEX|LLMDSU[PB](?:OPEN|CLOSE)X"#, options: .regularExpression) else {
                        result += wrap(set(String(rest)))
                        break
                    }
                    result += wrap(set(String(rest[..<marker.lowerBound])))
                    let token = rest[marker]
                    if token.hasPrefix("LLMDSPANO"), let number = Int(token.dropFirst(9).dropLast()), number < styles.count {
                        styleStack.append(styles[number])
                    } else if token == "LLMDSPANCX" {
                        _ = styleStack.popLast()
                    } else if token == Self.underlineOpen {
                        underlined += 1
                    } else if token == Self.underlineClose {
                        underlined = max(0, underlined - 1)
                    } else if token == Self.superOpen {
                        raised += 1
                    } else if token == Self.superClose {
                        raised = max(0, raised - 1)
                    } else if token == Self.subOpen {
                        lowered += 1
                    } else if token == Self.subClose {
                        lowered = max(0, lowered - 1)
                    }
                    rest = rest[marker.upperBound...]
                }
                return result
            }

            if intent.contains(.code) {
                output += stretches(text) { "\\texttt{\(escape($0))}" }
                continue
            }

            let piece = stretches(text) { fragment in
                var part = ""
                for (index, chunk) in fragment.components(separatedBy: placeholder).enumerated() {
                    if index > 0, formulaIndex < formulas.count {
                        part += inlineMath(formulas[formulaIndex], math: math)
                        formulaIndex += 1
                    }
                    part += escape(chunk).replacingOccurrences(of: "\n", with: "\\newline\n")
                        .replacingOccurrences(of: Self.lineBreak, with: "\\newline{}")
                }
                return part
            }
            var wrapped = piece
            if intent.contains(.stronglyEmphasized) { wrapped = "\\textbf{\(wrapped)}" }
            if intent.contains(.emphasized) { wrapped = "\\emph{\(wrapped)}" }
            if intent.contains(.strikethrough) { wrapped = "\\sout{\(wrapped)}" }
            if let link = run.link { wrapped = "\\href{\(escapeURL(link.absoluteString))}{\(wrapped)}" }
            output += wrapped
        }
        return output
    }

    /// Replaces the spans of a text: colour and font spans by placeholders (`LLMDSPANO<n>X`, `LLMDSPANCX`) that
    /// stand for the n-th style in the result, bookmark spans by nothing.
    static func convertSpans(_ source: String) -> (text: String, styles: [WriterSpanStyle]) {
        let tokens = WriterSpans.tokens(in: source)
        guard !tokens.isEmpty else { return (source, []) }
        var styles: [WriterSpanStyle] = []
        var stack: [Bool] = []
        let result = NSMutableString(string: source)
        // The stack needs the text's order; the replacements are made from the end, so the ranges stay valid.
        var replacements: [(NSRange, String)] = []
        for token in tokens {
            if token.isOpening {
                if let style = WriterSpanStyle(tag: token.tag) {
                    stack.append(true)
                    replacements.append((token.range, "LLMDSPANO\(styles.count)X"))
                    styles.append(style)
                } else {
                    stack.append(false)
                    replacements.append((token.range, ""))
                }
            } else {
                let isStyle = stack.popLast() ?? false
                replacements.append((token.range, isStyle ? "LLMDSPANCX" : ""))
            }
        }
        for (range, text) in replacements.reversed() { result.replaceCharacters(in: range, with: text) }
        return (result as String, styles)
    }

    private static let underlineOpen = "LLMDULINEOPENX"
    private static let underlineClose = "LLMDULINECLOSEX"
    private static let lineBreak = "LLMDLINEBREAKX"
    private static let superOpen = "LLMDSUPOPENX"
    private static let superClose = "LLMDSUPCLOSEX"
    private static let subOpen = "LLMDSUBOPENX"
    private static let subClose = "LLMDSUBCLOSEX"

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
            if let scalar = character.unicodeScalars.first, character.unicodeScalars.count == 1, isMathCharacter(scalar.value) {
                output += "\\(\(character)\\)"   // Greek letters, arrows and mathematical symbols come from the math font
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

    /// Characters the text fonts rarely have but the math font does: Greek, arrows, mathematical operators and symbols.
    private static func isMathCharacter(_ value: UInt32) -> Bool {
        switch value {
        case 0x0370...0x03FF, 0x2190...0x21FF, 0x2200...0x22FF, 0x27C0...0x27EF, 0x27F0...0x27FF, 0x2900...0x297F, 0x2980...0x29FF, 0x2A00...0x2AFF:
            true
        default:
            false
        }
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
    func makePDF(parts: [LaTeXWriter.Part], outline: LaTeXWriter.Outline? = nil, paper: PaperSize, typeface: WriterFont? = nil,
                 format: WriterPageFormat = .standard, design: WriterPageDesign = WriterPageDesign()) async throws -> Data {
        var lastError: Error = PDFExportError.compileFailed("")
        for mode in LaTeXWriter.MathMode.allCases {
            let source = await MainActor.run {
                LaTeXWriter.document(parts: parts, outline: outline, paper: paper, math: mode, typeface: typeface, format: format, design: design)
            }
            do {
                return try await compile(source, images: parts.flatMap(\.images) + parts.flatMap { Array(($0.figures ?? [:]).values) })
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
