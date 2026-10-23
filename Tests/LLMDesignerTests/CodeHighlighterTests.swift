import Testing
import AppKit
@testable import LLMDesigner

@Suite("Code einfärben")
struct CodeHighlighterTests {
    /// The kinds of the tokens, by their text.
    private func tokens(_ code: String, _ language: CodeLanguage) -> [(text: String, kind: CodeTokenKind)] {
        let string = code as NSString
        return CodeHighlighter.tokens(in: code, language: language).map { (string.substring(with: $0.range), $0.kind) }
    }

    private func kind(_ text: String, in list: [(text: String, kind: CodeTokenKind)]) -> CodeTokenKind? {
        list.first { $0.text == text }?.kind
    }

    @Test func pythonBasics() {
        let list = tokens("def f(x):\n    # Kommentar\n    return x ** 2 + 1  # Ende\nprint(\"Hallo\", 3.5, None)", .python)
        #expect(kind("def", in: list) == .keyword)
        #expect(kind("f", in: list) == .function)
        #expect(kind("return", in: list) == .keyword)
        #expect(kind("# Kommentar", in: list) == .comment)
        #expect(kind("# Ende", in: list) == .comment)
        #expect(kind("2", in: list) == .number)
        #expect(kind("print", in: list) == .builtin)
        #expect(kind("\"Hallo\"", in: list) == .string)
        #expect(kind("3.5", in: list) == .number)
        #expect(kind("None", in: list) == .constant)
        #expect(kind("x", in: list) == nil)
    }

    @Test func pythonStrings() {
        let list = tokens("a = f\"wert {x}\" + r'\\d+' + \"\"\"zwei\nZeilen\"\"\"\nb = 'offen\nc = 1", .python)
        #expect(kind("f\"wert {x}\"", in: list) == .string)
        #expect(kind("r'\\d+'", in: list) == .string)
        #expect(kind("\"\"\"zwei\nZeilen\"\"\"", in: list) == .string)
        #expect(kind("'offen", in: list) == .string)          // an unfinished string ends with its line
        #expect(kind("1", in: list) == .number)               // and the next line is code again
    }

    @Test func pythonClassAndDecorator() {
        let list = tokens("@dataclass\nclass Punkt:\n    x: int = 0", .python)
        #expect(kind("@dataclass", in: list) == .decorator)
        #expect(kind("class", in: list) == .keyword)
        #expect(kind("Punkt", in: list) == .type)
        #expect(kind("0", in: list) == .number)
    }

    @Test func sqlBasics() {
        let list = tokens("-- Umsatz\nSELECT name, COUNT(*) AS n, 'a''b' FROM \"Kunden\" k\nWHERE k.alter >= 18 AND k.aktiv IS NOT NULL /* x */ GROUP BY name;", .sql)
        #expect(kind("-- Umsatz", in: list) == .comment)
        #expect(kind("SELECT", in: list) == .keyword)
        #expect(kind("COUNT", in: list) == .builtin)
        #expect(kind("'a''b'", in: list) == .string)
        #expect(kind("\"Kunden\"", in: list) == .name)
        #expect(kind("18", in: list) == .number)
        #expect(kind("NULL", in: list) == .constant)
        #expect(kind("/* x */", in: list) == .comment)
        #expect(kind("GROUP", in: list) == .keyword)
        #expect(kind("name", in: list) == nil)
    }

    @Test func sqlLowerCaseAndTypes() {
        let list = tokens("create table t (id serial primary key, name varchar(20));", .sql)
        #expect(kind("create", in: list) == .keyword)
        #expect(kind("serial", in: list) == .type)
        #expect(kind("varchar", in: list) == .type)
        #expect(kind("primary", in: list) == .keyword)
    }

    @Test func languagesFromFences() {
        #expect(CodeLanguage(fence: "python") == .python)
        #expect(CodeLanguage(fence: "py3") == .python)
        #expect(CodeLanguage(fence: "PostgreSQL") == .sql)
        #expect(CodeLanguage(fence: "swift") == nil)
        #expect(CodeLanguage(fence: "") == nil)
    }

    @Test func detection() {
        #expect(CodeLanguage.detect("SELECT * FROM t WHERE a = 1") == .sql)
        #expect(CodeLanguage.detect("import math\nprint(math.pi)") == .python)
        #expect(CodeLanguage.detect("def f(x):\n    return x") == .python)
        #expect(CodeLanguage.detect("Das ist ein Satz, kein Code.") == nil)
        #expect(CodeLanguage.detect("select the best option from the list") == nil)
    }

    @Test func highlightingInTheEditorText() {
        let text = WriterMarkdown.attributedString(from: "```python\ndef f(x):\n    return 1\n```\n")
        let storage = NSTextStorage(attributedString: text)
        WriterStyler.restyleAll(storage, family: .serif, palette: .dark)
        let keyword = storage.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor
        #expect(keyword == CodeTheme.color(.keyword, light: false))
        let plain = (storage.string as NSString).range(of: "(x)")
        #expect((storage.attribute(.foregroundColor, at: plain.location + 1, effectiveRange: nil) as? NSColor) == WriterPalette.dark.text)
        // The fence's language survives the round trip.
        #expect(WriterMarkdown.markdown(from: storage).hasPrefix("```python\n"))
    }
}

@Suite("Code-Blöcke nebeneinander")
struct AdjacentCodeBlockTests {
    @Test func twoBlocksStayTwo() {
        let markdown = "```python\nx = 1\n```\n\n```sql\nSELECT 1;\n```\n"
        let text = WriterMarkdown.attributedString(from: markdown)
        let storage = NSTextStorage(attributedString: text)
        WriterStyler.restyleAll(storage, family: .serif, palette: .dark)
        #expect(WriterMarkdown.markdown(from: storage) == markdown)
        let sql = (storage.string as NSString).range(of: "SELECT")
        let run = WriterStyler.codeRun(around: (storage.string as NSString).paragraphRange(for: sql), in: storage)
        #expect((storage.string as NSString).substring(with: run) == "SELECT 1;")
        #expect(WriterStyler.language(of: run, in: storage).language == .sql)
        #expect((storage.attribute(.foregroundColor, at: sql.location, effectiveRange: nil) as? NSColor) == CodeTheme.color(.keyword, light: false))
    }

    @Test func blocksWithoutLanguageAlsoStayTwo() {
        let markdown = "```\none\n```\n\n```\ntwo\n```\n"
        let text = WriterMarkdown.attributedString(from: markdown)
        #expect(WriterMarkdown.markdown(from: text) == markdown)
    }
}
