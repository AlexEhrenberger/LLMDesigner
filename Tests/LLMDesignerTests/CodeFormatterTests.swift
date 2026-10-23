import Testing
import Foundation
@testable import LLMDesigner

@Suite("Code formatieren")
struct CodeFormatterTests {
    @Test func pythonIndentation() {
        let messy = "def f(x):\n\tif x:   \n\t\treturn 1\n  \n\n\n\n\treturn 2\n\n"
        #expect(CodeFormatter.python(messy) == "def f(x):\n    if x:\n        return 1\n\n\n    return 2")
    }

    @Test func pythonLeavesStringsAndBrackets() {
        let code = "x = foo(1,\n     2)\ny = \"\"\"a  \n   b\"\"\"\nif y:\n  pass"
        let result = CodeFormatter.python(code)
        #expect(result.contains("x = foo(1,\n     2)"))
        #expect(result.contains("\"\"\"a  \n   b\"\"\""))
        #expect(result.hasSuffix("if y:\n    pass"))
    }

    @Test func pythonCommentsKeepTheirPlace() {
        let code = "if a:\n  b = 1\n# vor else\nelse:\n  b = 2"
        #expect(CodeFormatter.python(code) == "if a:\n    b = 1\n# vor else\nelse:\n    b = 2")
    }

    @Test func sqlSimple() {
        let result = CodeFormatter.sql("select a,b from t where x=1 and y>2 order by a")
        #expect(result == "SELECT\n    a,\n    b\nFROM t\nWHERE x = 1\n    AND y > 2\nORDER BY a")
    }

    @Test func sqlSingleItem() {
        #expect(CodeFormatter.sql("select * from t") == "SELECT *\nFROM t")
        #expect(CodeFormatter.sql("select count(*) from t") == "SELECT COUNT(*)\nFROM t")
    }

    @Test func sqlJoinsAndGroups() {
        let result = CodeFormatter.sql("select k.name, sum(b.betrag) as summe from kunden k left join bestellungen b on b.kunde_id = k.id group by k.name having sum(b.betrag) > 100;")
        #expect(result == """
        SELECT
            k.name,
            SUM(b.betrag) AS summe
        FROM kunden k
        LEFT JOIN bestellungen b ON b.kunde_id = k.id
        GROUP BY k.name
        HAVING SUM(b.betrag) > 100;
        """)
    }

    @Test func sqlSubqueryAndCommentsAndStrings() {
        let result = CodeFormatter.sql("-- Top\nselect a from (select a from t where n = 'x and y') s where a between 1 and 3 and b is not null")
        #expect(result == """
        -- Top
        SELECT a
        FROM (
            SELECT a
            FROM t
            WHERE n = 'x and y'
        ) s
        WHERE a BETWEEN 1 AND 3
            AND b IS NOT NULL
        """)
    }

    @Test func sqlInsertAndUpdate() {
        #expect(CodeFormatter.sql("insert into t (a, b) values (1, 'x');") == "INSERT INTO t (a, b)\nVALUES (1, 'x');")
        #expect(CodeFormatter.sql("update t set a=1, b=2 where id=3") == "UPDATE t\nSET\n    a = 1,\n    b = 2\nWHERE id = 3")
    }
}
