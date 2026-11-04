import Foundation

/// Formulas go to the LaTeX engine as they are written, and LaTeX is a programming language: `\input{/pfad}` would put a
/// file of this Mac into the PDF, and Tectonic's `--untrusted` only stops shell commands. A document can come from
/// someone else. So a formula with a command that reaches the disk, or one that can build such a command out of pieces,
/// is printed as code. A formula wrongly caught here still shows, only not typeset.
enum LaTeXSafety {
    /// Commands that make other commands, change how the input is read or run code. Without them, a command that
    /// reaches the disk has to stand there literally, which the checks below see.
    private static let forbiddenCommands: Set<String> = [
        "csname", "endcsname", "expandafter", "noexpand", "scantokens", "scantextokens", "detokenize", "unexpanded", "string",
        "uppercase", "lowercase", "catcode", "lccode", "uccode", "sfcode", "mathcode", "delcode", "endlinechar", "newlinechar", "escapechar",
        "def", "edef", "gdef", "xdef", "let", "futurelet", "global", "long", "outer", "protected",
        "newcommand", "renewcommand", "providecommand", "DeclareRobustCommand", "newenvironment", "renewenvironment",
        "NewDocumentCommand", "RenewDocumentCommand", "ProvideDocumentCommand", "DeclareDocumentCommand", "NewExpandableDocumentCommand",
        "RenewExpandableDocumentCommand", "ProvideExpandableDocumentCommand", "DeclareExpandableDocumentCommand", "NewDocumentEnvironment",
        "RenewDocumentEnvironment", "NewCommandCopy", "RenewCommandCopy", "DeclareCommandCopy", "UseName", "UseExpandable", "ExpandArgs", "useexpandable",
        "makeatletter", "makeatother", "ExplSyntaxOn", "ExplSyntaxOff", "immediate", "shipout", "special", "usepackage", "RequirePackage", "LoadClass",
        "documentclass", "endinput", "loop", "repeat", "pgfextra", "tikz", "fvset", "VerbatimEnvironment",
    ]

    /// Parts of command names that mean the disk or running code, whichever package the command comes from
    /// (`\lstinputlisting`, `\tcbinputlisting`, `\VerbatimInput`, `\pdffiledump`, `\XeTeXpicfile`, `\directlua` …).
    private static let forbiddenParts = ["input", "include", "file", "read", "write", "open", "close", "lua", "pdf", "picture", "image", "font", "listing", "system", "shell", "minted"]

    /// Environments a formula may have. Anything else (`filecontents`, `verbatim`, …) has no business in one.
    private static let environments: Set<String> = [
        "matrix", "pmatrix", "bmatrix", "Bmatrix", "vmatrix", "Vmatrix", "smallmatrix", "matrix*", "pmatrix*", "bmatrix*", "Bmatrix*", "vmatrix*", "Vmatrix*",
        "cases", "dcases", "rcases", "drcases", "aligned", "alignedat", "gathered", "split", "array", "subarray", "CD",
        "align", "align*", "alignat", "alignat*", "flalign", "flalign*", "gather", "gather*", "multline", "multline*", "equation", "equation*", "eqnarray", "eqnarray*",
    ]

    static func isSafeFormula(_ latex: String) -> Bool {
        // `^^5c` is a backslash to TeX's tokenizer, so it could spell any command unseen.
        guard !latex.contains("^^") else { return false }
        let characters = Array(latex)
        var index = 0
        while index < characters.count {
            defer { index += 1 }
            guard characters[index] == "\\", index + 1 < characters.count else { continue }
            guard characters[index + 1].isLetter else {
                // `\\`, `\,`, `\{`: the next character belongs to it, so a `\\input` is a line break and a word.
                index += 1
                continue
            }
            var end = index + 1
            while end < characters.count, characters[end].isLetter { end += 1 }
            let name = String(characters[(index + 1)..<end])
            guard isAllowed(command: name) else { return false }
            if name == "begin", let environment = argument(after: end, in: characters), !environments.contains(environment) { return false }
            index = end - 1
        }
        return true
    }

    private static func isAllowed(command name: String) -> Bool {
        guard !forbiddenCommands.contains(name) else { return false }
        let lowered = name.lowercased()
        return !forbiddenParts.contains { lowered.contains($0) }
    }

    /// The `{…}` after a command, spaces before it allowed.
    private static func argument(after position: Int, in characters: [Character]) -> String? {
        var start = position
        while start < characters.count, characters[start].isWhitespace { start += 1 }
        guard start < characters.count, characters[start] == "{" else { return "" }
        guard let close = characters[start...].firstIndex(of: "}") else { return "" }
        return String(characters[(start + 1)..<close]).trimmingCharacters(in: .whitespaces)
    }
}
