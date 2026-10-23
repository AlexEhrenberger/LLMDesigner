import Testing
import Foundation
@testable import LLMDesigner

@Suite("Flussdiagramme aus Code")
struct FlowTests {
    private func texts(_ graph: FlowGraph) -> [String] { graph.nodes.map(\.text) }

    private func edge(_ graph: FlowGraph, _ from: String, _ to: String) -> FlowGraph.Edge? {
        guard let a = graph.nodes.first(where: { $0.text == from })?.id, let b = graph.nodes.first(where: { $0.text == to })?.id else { return nil }
        return graph.edges.first { $0.from == a && $0.to == b }
    }

    @Test func pythonFunction() {
        let graphs = PythonFlow.graphs(for: """
        import math

        def klassifiziere(x):
            \"\"\"Docstring\"\"\"
            if x < 0:
                return "negativ"
            elif x == 0:
                return "null"
            else:
                y = math.sqrt(x)
                return "positiv"
        """)
        #expect(graphs.count == 1)
        let graph = graphs[0]
        #expect(graph.title == "def klassifiziere(x)")
        #expect(texts(graph).contains("x < 0 ?"))
        #expect(texts(graph).contains("x == 0 ?"))
        #expect(texts(graph).contains("Rückgabe: \"negativ\""))
        #expect(texts(graph).contains("y = math.sqrt(x)"))
        #expect(edge(graph, "x < 0 ?", "Rückgabe: \"negativ\"")?.label == "ja")
        #expect(edge(graph, "x < 0 ?", "x == 0 ?")?.label == "nein")
        #expect(!texts(graph).contains("Docstring"))
        // Every path ends: nothing is open.
        let code = graph.mermaid(palette: .light)
        #expect(code.hasPrefix("flowchart TD"))
        #expect(code.contains("nEnd(["))
    }

    @Test func pythonLoopsAndTry() {
        let graphs = PythonFlow.graphs(for: """
        total = 0
        for zahl in range(10):
            if zahl % 2 == 0:
                continue
            total += zahl
            if total > 20:
                break
        print(total)
        try:
            wert = int(input("Zahl: "))
        except ValueError:
            print("Keine Zahl")
        """)
        #expect(graphs.count == 1)
        let graph = graphs[0]
        #expect(graph.title == "Programmablauf")
        #expect(texts(graph).contains("für jedes zahl in range(10)"))
        #expect(texts(graph).contains("Ausgabe: total"))
        #expect(texts(graph).contains("Eingabe → wert"))
        #expect(graph.groups.first?.title == "try")
        #expect(graph.edges.contains { $0.label == "Fehler: ValueError" })
        // The loop comes back to its head, and "fertig" leaves it.
        let head = graph.nodes.first { $0.shape == .loop }?.id
        #expect(graph.edges.contains { $0.to == head && $0.label == nil })
        #expect(graph.edges.contains { $0.from == head && $0.label == "fertig" })
    }

    @Test func pythonClassAndMain() {
        let graphs = PythonFlow.graphs(for: """
        class Konto:
            def __init__(self, stand=0):
                self.stand = stand

            def abheben(self, betrag):
                if betrag > self.stand:
                    raise ValueError("zu wenig")
                self.stand -= betrag

        konto = Konto(100)
        konto.abheben(30)
        """)
        #expect(graphs.map(\.title) == ["Programmablauf", "def Konto.__init__(self, stand=0)", "def Konto.abheben(self, betrag)"])
        #expect(texts(graphs[2]).contains("Fehler: ValueError(\"zu wenig\")"))
    }

    @Test func pythonMultilineAndInline() {
        let graphs = PythonFlow.graphs(for: "def f(a,\n      b):\n    if a: return b\n    x = [1,\n         2]\n    return x\n")
        #expect(graphs.count == 1)
        #expect(graphs[0].title == "def f(a, b)")
        #expect(texts(graphs[0]).contains("Rückgabe: b"))
        #expect(texts(graphs[0]).contains("x = [1, 2]"))
    }

    @Test func sqlQuery() {
        let graphs = SQLFlow.graphs(for: "SELECT k.name, SUM(b.betrag) AS summe FROM kunden k LEFT JOIN bestellungen b ON b.kunde_id = k.id WHERE k.aktiv = 1 GROUP BY k.name HAVING SUM(b.betrag) > 100 ORDER BY summe DESC LIMIT 10;")
        #expect(graphs.count == 1)
        let graph = graphs[0]
        let all = texts(graph)
        #expect(all.contains("kunden k"))
        #expect(all.contains("bestellungen b"))
        #expect(all.contains("LEFT JOIN über b.kunde_id = k.id"))
        #expect(all.contains("Filter: k.aktiv = 1"))
        #expect(all.contains("Gruppieren nach: k.name"))
        #expect(all.contains("Gruppen filtern: SUM(b.betrag) > 100"))
        #expect(all.contains("Spalten: k.name, SUM(b.betrag) AS summe"))
        #expect(all.contains("Sortieren: summe DESC"))
        #expect(all.contains("Begrenzen: erste 10"))
        #expect(all.last == "Ergebnis")
    }

    @Test func sqlCTEAndSubquery() {
        let graphs = SQLFlow.graphs(for: """
        WITH aktive AS (SELECT id FROM kunden WHERE aktiv = 1)
        SELECT a.id, t.n FROM aktive a JOIN (SELECT kunde_id, COUNT(*) AS n FROM bestellungen GROUP BY kunde_id) t ON t.kunde_id = a.id
        """)
        #expect(graphs.count == 1)
        let graph = graphs[0]
        #expect(graph.groups.map(\.title).contains("WITH aktive"))
        #expect(graph.groups.contains { $0.title.hasPrefix("Unterabfrage") })
        let code = graph.mermaid(palette: .dark)
        #expect(code.contains("subgraph"))
    }

    @Test func sqlStatements() {
        let graphs = SQLFlow.graphs(for: "INSERT INTO t (a, b) VALUES (1, 2); UPDATE t SET a = 5, b = 6 WHERE id = 1; DELETE FROM t WHERE a > 3; CREATE TABLE u (id INT, name TEXT);")
        #expect(graphs.count == 4)
        #expect(texts(graphs[0]).contains("Einfügen in t (a, b)"))
        #expect(texts(graphs[1]).contains { $0.hasPrefix("Setze:") })
        #expect(texts(graphs[2]).contains("Zeilen löschen"))
        #expect(texts(graphs[3]).contains { $0.hasPrefix("CREATE TABLE u") && $0.contains("id INT") })
    }

    @Test func sqlUnion() {
        let graphs = SQLFlow.graphs(for: "SELECT a FROM x UNION ALL SELECT a FROM y ORDER BY a")
        #expect(graphs.count == 1)
        #expect(texts(graphs[0]).contains("UNION ALL"))
        #expect(texts(graphs[0]).contains("Sortieren: a"))
    }

    @Test func snippetsFromMarkdown() {
        let markdown = "Text\n\n```python\nx = 1\n```\n\n```\nSELECT a FROM b WHERE c = 1\n```\n\n```swift\nlet x = 1\n```\n"
        let snippets = CodeSnippet.snippets(in: markdown)
        #expect(snippets.map(\.language) == [.python, .sql])
    }

    @Test func mermaidEscaping() {
        var graph = FlowGraph(title: "t", language: .python)
        _ = graph.addNode("a < b and \"c\" # x", .process)
        let code = graph.mermaid(palette: .light)
        #expect(code.contains("a #lt; b and #quot;c#quot; #35; x"))
    }
}
