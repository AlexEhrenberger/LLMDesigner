import Foundation

/// The programming languages Writer Studio and Presenter Studio know in code blocks: they are coloured, indented
/// and formatted for their language, and their code can be shown as a flow chart in the content analysis.
enum CodeLanguage: String, CaseIterable, Identifiable, Sendable {
    case python, sql

    var id: String { rawValue }

    var label: String {
        switch self {
        case .python: "Python"
        case .sql: "SQL"
        }
    }

    /// What the code block's fence says in Markdown: ```` ```python ````.
    var fence: String { rawValue }

    /// One level of indentation.
    var indent: String { "    " }

    /// The language a fence's name stands for: `python`, `py`, `sql`, `postgresql`, …
    init?(fence name: String) {
        let name = name.trimmingCharacters(in: .whitespaces).lowercased()
            .split(whereSeparator: { $0 == " " || $0 == "{" || $0 == "," }).first.map(String.init) ?? ""
        switch name {
        case "python", "py", "python3", "py3", "ipython", "pycon": self = .python
        case "sql", "mysql", "postgres", "postgresql", "pgsql", "plpgsql", "sqlite", "tsql", "plsql", "mariadb", "sparksql", "hiveql", "bigquery":
            self = .sql
        default: return nil
        }
    }

    /// A guess for code without a language: only when the code clearly is one (a statement of SQL, a `def` or an
    /// `import` of Python).
    static func detect(_ code: String) -> CodeLanguage? {
        let lines = code.split(separator: "\n", omittingEmptySubsequences: true)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.hasPrefix("#") && !$0.hasPrefix("--") }
        guard let first = lines.first else { return nil }

        let words = Set(code.uppercased().split(whereSeparator: { !$0.isLetter && $0 != "_" }).map(String.init))
        let firstWord = first.uppercased().split(whereSeparator: { !$0.isLetter && $0 != "_" }).first.map(String.init) ?? ""
        let starters: Set<String> = ["SELECT", "INSERT", "UPDATE", "DELETE", "CREATE", "ALTER", "DROP", "WITH", "TRUNCATE", "MERGE"]
        let companions: Set<String> = ["FROM", "INTO", "SET", "TABLE", "VALUES", "WHERE", "JOIN", "AS", "VIEW", "INDEX", "SELECT"]
        // Prose that starts with "select" or "with" has no SQL punctuation and no capitalised keyword.
        let firstOriginal = first.split(whereSeparator: { !$0.isLetter && $0 != "_" }).first.map(String.init) ?? ""
        let looksLikeSQL = firstOriginal == firstOriginal.uppercased() || code.contains(where: { ";*(=,".contains($0) })
        if looksLikeSQL, starters.contains(firstWord), !words.isDisjoint(with: companions.subtracting([firstWord])) { return .sql }
        if looksLikeSQL, firstWord == "SELECT" || firstWord == "WITH", lines.count > 1 { return .sql }

        let pythonStarts = ["def ", "class ", "import ", "from ", "elif ", "else:", "try:", "except", "finally:", "with ", "lambda ", "return ", "@", "async def ", "print("]
        let signals = lines.filter { line in
            if line.hasPrefix("from "), !line.contains(" import ") { return false }
            if line.hasPrefix("with "), !line.hasSuffix(":") { return false }
            if line.hasPrefix("class "), !line.hasSuffix(":") { return false }
            return pythonStarts.contains { line.hasPrefix($0) }
                || ((line.hasPrefix("if ") || line.hasPrefix("for ") || line.hasPrefix("while ")) && line.hasSuffix(":"))
        }
        if signals.count >= 1, lines.contains(where: { $0.hasSuffix(":") || $0.hasPrefix("import ") || $0.hasPrefix("from ") || $0.hasPrefix("print(") }) {
            return .python
        }
        return nil
    }
}
