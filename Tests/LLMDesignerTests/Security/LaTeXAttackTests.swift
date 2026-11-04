import Testing
import Foundation
import PDFKit
@testable import LLMDesigner

/// Documents can come from someone else, and LaTeX can read files. These tests set prepared documents with the real
/// engine and look into the PDF for the content of a neutral file made for the test.
@Suite("Sicherheit: LaTeX liest keine Dateien")
struct LaTeXAttackTests {
    private static let secret = "QQZZ7731"

    /// A neutral file with the marker, one per test, in a path LaTeX can read.
    private func secretFile() throws -> (path: String, cleanup: () -> Void) {
        let folder = URL(fileURLWithPath: "/tmp/llmdlatex\(UUID().uuidString.prefix(8))", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let file = folder.appendingPathComponent("neutral.txt")
        try "\(Self.secret)\n".write(to: file, atomically: true, encoding: .utf8)
        return (file.path, { try? FileManager.default.removeItem(at: folder) })
    }

    private func text(ofPDF data: Data) -> String {
        guard let document = PDFDocument(data: data) else { return "" }
        return (0..<document.pageCount).compactMap { document.page(at: $0)?.string }.joined(separator: "\n")
    }

    /// The control: without the protection the engine does read the file, so the tests below see what they claim to.
    @Test func withoutAnyCheckTheEngineReadsTheFile() async throws {
        guard let engine = LaTeXEngine.locate() else { return }
        let (path, cleanup) = try secretFile()
        defer { cleanup() }
        let pdf = try await engine.compile("\\documentclass{article}\\begin{document}\\input{\(path)}\\end{document}")
        #expect(text(ofPDF: pdf).contains(Self.secret))
    }

    static let attacks: [(String, String)] = [
        ("Formel", "$$\\input{PATH}$$"),
        ("Formel im Text", "Ein Satz $\\input{PATH}$ hier."),
        ("Formel mit Umgebung", "$$\\begin{aligned}\\input{PATH}\\end{aligned}$$"),
        ("Formel mit text", "$$\\text{\\input{PATH}}$$"),
        ("csname", "$$\\csname input\\endcsname{PATH}$$"),
        ("Hochdach-Schreibweise", "$$^^5cinput{PATH}$$"),
        ("expandafter", "$$\\expandafter\\input\\expandafter{PATH}$$"),
        ("openin", "$$\\newread\\f \\openin\\f=PATH \\read\\f to\\x \\text{\\x}$$"),
        ("UseName", "$$\\UseName{input}{PATH}$$"),
        ("lowercase", "$$\\lowercase{\\INPUT{PATH}}$$"),
        ("catcode", "$$\\catcode`\\Q=0 Qinput{PATH}$$"),
        ("Umgebung beenden", "$$\\end{equation*}\\input{PATH}\\begin{equation*}$$"),
        ("Inline-Ausbruch", "$x\\)\\input{PATH}\\($"),
        ("filecontents", "$$\\begin{filecontents}{a.tex}x\\end{filecontents}\\input{PATH}$$"),
        ("Text", "\\input{PATH}"),
        ("Überschrift", "# \\input{PATH}"),
        ("Kapitel", "# \\input{PATH} {.chapter}"),
        ("Liste", "- \\input{PATH}"),
        ("Zitat", "> \\input{PATH}"),
        ("Tabelle", "| \\input{PATH} | b |\n| --- | --- |\n| 1 | 2 |"),
        ("Tabelle mit Formel", "| $\\input{PATH}$ | b |\n| --- | --- |\n| 1 | 2 |"),
        ("Code", "```\n\\input{PATH}\n```"),
        ("Python", "```python\n\\input{PATH}\n```"),
        ("Aus Verbatim ausbrechen", "```\n\\end{Verbatim}\n\\input{PATH}\n\\begin{Verbatim}\n```"),
        ("Python, aus Verbatim ausbrechen", "```python\n\\end{Verbatim}\n\\input{PATH}\n\\begin{Verbatim}\n```"),
        ("Sprache des Codes", "```}\\input{PATH}\nx\n```"),
        ("Bildunterschrift", "![\\input{PATH}](bild.png)"),
        ("Bildunterschrift mit Formel", "![$\\input{PATH}$](bild.png)"),
        ("Link", "[a](http://x}\\input{PATH})"),
        ("Fettdruck", "**\\input{PATH}**"),
        ("Farbe", "<span style=\"color:#000000}\\input{PATH}\">x</span>"),
        ("Schrift", "<span style=\"font-family:'}\\input{PATH}'\">x</span>"),
        ("Größe", "<span style=\"font-size:12pt}\\input{PATH}\">x</span>"),
        ("Kastentitel", "::: {.box kind=eigener title=\"\\input{PATH}\"}\nText\n:::"),
        ("Kastenfarbe", "::: {.box kind=eigener color=\"000000}\\input{PATH}\"}\nText\n:::"),
        ("Spalten", "::: {.columns count=\"2}\\input{PATH}\"}\nText\n:::"),
        ("Zeilenabstand", "::: {line-spacing=\"1}\\input{PATH}\"}\nText\n:::"),
        ("Einzug", "::: {indent=\"1cm}\\input{PATH}\"}\nText\n:::"),
        ("Zitation", "Laut [@\\input{PATH}, S. 1] stimmt es."),
    ]

    @Test(arguments: attacks)
    func noWayIntoThePDF(_ name: String, _ template: String) async throws {
        guard let engine = LaTeXEngine.locate() else { return }
        let (path, cleanup) = try secretFile()
        defer { cleanup() }
        var part = LaTeXWriter.Part(text: "Davor.\n\n" + template.replacingOccurrences(of: "PATH", with: path) + "\n\nDanach.\n")
        part.figures = [:]
        // Every one of them has to compile. If one only failed, this test would prove nothing about it.
        let pdf = try await engine.makePDF(parts: [part], paper: .a4)
        let shown = text(ofPDF: pdf)
        #expect(!shown.contains(Self.secret), "\(name)")
        #expect(shown.contains("Danach"), "\(name)")
    }

    @Test(arguments: attacks.filter { $0.0.hasPrefix("Formel") || ["csname", "expandafter", "openin", "UseName", "lowercase", "catcode"].contains($0.0) })
    func theSourceHasNoCommand(_ name: String, _ template: String) {
        let source = LaTeXWriter.document(parts: [LaTeXWriter.Part(text: template.replacingOccurrences(of: "PATH", with: "/tmp/x.txt"))], paper: .a4, math: .native)
        // In a Verbatim block it is only text.
        let outside = source.replacingOccurrences(of: #"(?s)\\begin\{Verbatim\}.*?\\end\{Verbatim\}"#, with: "", options: .regularExpression)
        #expect(!outside.contains("\\input{/tmp"), "\(name)")
    }

    // Which formulas count.

    static let harmless = [
        "E = mc^2", "\\frac{a}{b}", "\\sum_{i=1}^{n} x_i^2", "\\int_0^\\infty e^{-x}\\,dx", "\\sqrt[3]{x}", "\\begin{aligned} a &= b \\\\ c &= d \\end{aligned}",
        "\\begin{pmatrix} 1 & 2 \\\\ 3 & 4 \\end{pmatrix}", "\\begin{cases} 1 & x > 0 \\\\ 0 & \\text{sonst} \\end{cases}", "\\mathbb{R}", "\\mathrm{d}x", "\\operatorname{sgn}(x)",
        "\\overbrace{a+b}^{c}", "\\hat{x}", "\\left( x \\right)", "\\alpha\\beta\\gamma", "\\begin{array}{cc} 1 & 2 \\end{array}", "a\\\\input", "\\begin{align*} x &= 1 \\end{align*}",
        "\\text{für alle } x", "\\color{red} x", "\\boxed{x}", "\\tag{1}", "\\label{a}", "x^2", "\\%", "\\$", "\\{a\\}", "\\mathcal{L}", "\\nabla", "\\partial", "\\rightarrow", "\\lim_{x\\to 0}",
    ]

    @Test(arguments: harmless)
    func ordinaryFormulasStayFormulas(_ latex: String) {
        #expect(LaTeXSafety.isSafeFormula(latex))
    }

    static let dangerous = [
        "\\input{a}", "\\include{a}", "\\InputIfFileExists{a}{}{}", "\\IfFileExists{a}{}{}", "\\openin1=a", "\\read1 to\\x", "\\readline1 to\\x", "\\openout1=a", "\\write1{x}", "\\immediate\\write1{x}",
        "\\lstinputlisting{a}", "\\VerbatimInput{a}", "\\verbatiminput{a}", "\\tcbinputlisting{a}", "\\inputminted{py}{a}", "\\includegraphics{a}", "\\pdffiledump length 9 {a}", "\\pdfmdfivesum file {a}",
        "\\XeTeXpicfile a", "\\XeTeXpdffile a", "\\font\\x=a", "\\directlua{x}", "\\latelua{x}", "\\csname input\\endcsname", "\\expandafter\\x", "\\scantokens{x}", "\\catcode1=0", "\\def\\x{y}", "\\let\\x\\y",
        "\\newcommand{\\x}{y}", "\\UseName{input}", "\\ExplSyntaxOn", "\\makeatletter", "\\uppercase{x}", "\\lowercase{x}", "\\usepackage{a}", "\\special{x}", "^^5cinput{a}", "\\begin{filecontents}{a}x\\end{filecontents}",
        "\\begin{verbatim}x\\end{verbatim}", "\\begin {filecontents}{a}x\\end{filecontents}", "\\begin{Verbatim}x\\end{Verbatim}", "a\\\\\\input{b}",
    ]

    @Test(arguments: dangerous)
    func dangerousFormulasAreCaught(_ latex: String) {
        #expect(!LaTeXSafety.isSafeFormula(latex))
    }

    /// The fallback prints it as code, so nothing of the document is lost.
    @Test func aCaughtFormulaStaysVisible() {
        let source = LaTeXWriter.document(parts: [LaTeXWriter.Part(text: "$$\\input{a}$$\n\nSatz $\\openin1=b$ hier.\n")], paper: .a4, math: .native)
        #expect(source.contains("\\begin{Verbatim}"))
        #expect(source.contains("\\texttt{\\textbackslash{}openin1=b}"))
    }
}
