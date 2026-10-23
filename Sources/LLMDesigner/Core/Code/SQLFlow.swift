import Foundation

/// Flow charts of SQL: one per statement, as the database works it through. A query reads its tables, joins them,
/// filters, groups, picks columns, sorts and cuts; common table expressions and subqueries sit in boxes of their
/// own; INSERT, UPDATE and DELETE show what happens to the table.
enum SQLFlow {
    typealias Atom = CodeFormatter.Atom

    static func graphs(for code: String) -> [FlowGraph] {
        let atoms = CodeFormatter.sqlAtoms(of: code).filter { $0.kind != .lineComment && $0.kind != .blockComment }
        var statements: [[Atom]] = [[]]
        var depth = 0
        for atom in atoms {
            if atom.text == "(" { depth += 1 }
            if atom.text == ")" { depth = max(0, depth - 1) }
            if atom.text == ";", depth == 0 {
                statements.append([])
            } else {
                statements[statements.count - 1].append(atom)
            }
        }
        return statements.filter { !$0.isEmpty }.compactMap { statement in
            var builder = Builder(title: title(of: statement))
            guard builder.build(statement) else { return nil }
            return builder.graph
        }
    }

    private static func title(of statement: [Atom]) -> String {
        let text = join(Array(statement.prefix(14)))
        return FlowGraph.label(text, limit: 56)
    }

    // MARK: Text

    /// Atoms as one line of SQL.
    static func join(_ atoms: [Atom]) -> String {
        var text = ""
        var previous: Atom?
        for atom in atoms {
            if let previous {
                let noSpace = [",", ")", ".", ";"].contains(atom.text) || previous.text == "(" || previous.text == "."
                    || (atom.text == "(" && previous.isWord && !CodeHighlighter.sqlKeywords.contains(previous.upper))
                    || atom.text == "::" || previous.text == "::"
                if !noSpace { text += " " }
            }
            text += atom.text
            previous = atom
        }
        return text
    }

    // MARK: Clauses

    struct Clause {
        var keyword: String
        var atoms: [Atom]
    }

    private static let clauseKeywords: Set<String> = [
        "WITH", "SELECT", "FROM", "WHERE", "HAVING", "LIMIT", "OFFSET", "UNION", "INTERSECT", "EXCEPT", "MINUS", "INSERT", "VALUES",
        "UPDATE", "SET", "DELETE", "RETURNING", "CREATE", "DROP", "ALTER", "TRUNCATE",
    ]
    private static let setOperators: Set<String> = ["UNION", "INTERSECT", "EXCEPT", "MINUS"]

    /// The statement cut at its clause keywords (outside brackets).
    static func clauses(of atoms: [Atom]) -> [Clause] {
        var result: [Clause] = []
        var depth = 0
        var index = 0
        func start(_ keyword: String) { result.append(Clause(keyword: keyword, atoms: [])) }
        while index < atoms.count {
            let atom = atoms[index]
            if atom.text == "(" { depth += 1 }
            if atom.text == ")" { depth -= 1 }
            let upper = atom.upper
            if depth == 0, atom.isWord {
                if clauseKeywords.contains(upper), !(upper == "SET" && result.last?.keyword == "ON") {
                    // `DELETE FROM`, `INSERT INTO`: the second word belongs to the first clause.
                    if upper == "FROM", result.last?.keyword == "DELETE", result.last?.atoms.isEmpty == true {
                        start("FROM")
                    } else {
                        start(upper)
                    }
                    index += 1
                    continue
                }
                if (upper == "GROUP" || upper == "ORDER"), index + 1 < atoms.count, atoms[index + 1].upper == "BY" {
                    start(upper + " BY")
                    index += 2
                    continue
                }
            }
            if result.isEmpty { start("") }
            result[result.count - 1].atoms.append(atom)
            index += 1
        }
        return result
    }

    /// The atoms of a clause at the top level, split at commas.
    static func items(_ atoms: [Atom]) -> [[Atom]] {
        var parts: [[Atom]] = [[]]
        var depth = 0
        for atom in atoms {
            if atom.text == "(" { depth += 1 }
            if atom.text == ")" { depth -= 1 }
            if atom.text == ",", depth == 0 { parts.append([]) } else { parts[parts.count - 1].append(atom) }
        }
        return parts.filter { !$0.isEmpty }
    }

    /// The atoms inside the bracket that opens at `start`, and the position of its closing bracket.
    static func bracketed(_ atoms: [Atom], from start: Int) -> (inner: [Atom], close: Int)? {
        guard start < atoms.count, atoms[start].text == "(" else { return nil }
        var depth = 0
        for index in start..<atoms.count {
            if atoms[index].text == "(" { depth += 1 }
            if atoms[index].text == ")" {
                depth -= 1
                if depth == 0 { return (Array(atoms[(start + 1)..<index]), index) }
            }
        }
        return nil
    }

    // MARK: Builder

    private struct Builder {
        var graph: FlowGraph
        /// Common table expressions: their name and the node that delivers their rows.
        var tables: [String: String] = [:]

        init(title: String) {
            graph = FlowGraph(title: title, language: .sql)
        }

        mutating func build(_ atoms: [Atom]) -> Bool {
            let parts = SQLFlow.clauses(of: atoms)
            guard let first = parts.first else { return false }
            switch first.keyword {
            case "INSERT": return insert(parts)
            case "UPDATE": return update(parts)
            case "DELETE": return delete(parts)
            case "CREATE", "DROP", "ALTER", "TRUNCATE": return definition(atoms)
            default:
                guard let exit = query(parts) else { return false }
                let result = graph.addNode("Ergebnis", .terminal)
                graph.connect(exit, result)
                return true
            }
        }

        // MARK: Queries

        /// A query (with its common table expressions and set operations); returns the node that delivers its rows.
        private mutating func query(_ parts: [Clause]) -> String? {
            var parts = parts
            // WITH name AS (…), …
            if let with = parts.first, with.keyword == "WITH" {
                parts.removeFirst()
                for item in SQLFlow.items(with.atoms) {
                    var words = item
                    if words.first?.upper == "RECURSIVE" { words.removeFirst() }
                    guard let name = words.first?.text, let asIndex = words.firstIndex(where: { $0.upper == "AS" }),
                          let (inner, _) = SQLFlow.bracketed(words, from: asIndex + 1) else { continue }
                    let before = graph.nodes.count
                    if let exit = query(SQLFlow.clauses(of: inner)) {
                        let ids = graph.nodes[before...].map(\.id)
                        _ = graph.addGroup("WITH \(name)", nodes: ids)
                        tables[name.lowercased()] = exit
                    }
                }
            }
            // Set operations: the queries are made one by one and flow into one node.
            var queries: [[Clause]] = [[]]
            var operators: [String] = []
            for part in parts {
                if SQLFlow.setOperators.contains(part.keyword) {
                    let all = part.atoms.first?.upper == "ALL" ? " ALL" : (part.atoms.first?.upper == "DISTINCT" ? " DISTINCT" : "")
                    operators.append(part.keyword + all)
                    queries.append([])
                    // What follows UNION in the same clause is the next query's start (rare: `UNION (SELECT …)`).
                    continue
                }
                queries[queries.count - 1].append(part)
            }
            guard queries.count > 1 else { return select(queries[0]) }
            // ORDER BY and LIMIT at the end belong to the combined rows.
            var tail: [Clause] = []
            while let last = queries[queries.count - 1].last, ["ORDER BY", "LIMIT", "OFFSET"].contains(last.keyword) {
                tail.insert(last, at: 0)
                queries[queries.count - 1].removeLast()
            }
            let exits = queries.compactMap { select($0) }
            guard !exits.isEmpty else { return nil }
            let combined = graph.addNode(operators.first ?? "UNION", .process)
            for exit in exits { graph.connect(exit, combined) }
            return finish(from: combined, clauses: tail)
        }

        /// ORDER BY, LIMIT and OFFSET after the rows.
        private mutating func finish(from start: String, clauses: [Clause]) -> String {
            var current = start
            if let order = clauses.first(where: { $0.keyword == "ORDER BY" }) {
                current = step("Sortieren: " + SQLFlow.join(order.atoms), .process, after: [current])
            }
            let limit = clauses.first { $0.keyword == "LIMIT" }
            let offset = clauses.first { $0.keyword == "OFFSET" }
            if limit != nil || offset != nil {
                var text = "Begrenzen:"
                if let limit { text += " erste " + SQLFlow.join(limit.atoms) }
                if let offset { text += " ab Zeile " + SQLFlow.join(offset.atoms) }
                current = step(text, .process, after: [current])
            }
            return current
        }

        private mutating func step(_ text: String, _ shape: FlowGraph.Shape, after previous: [String]) -> String {
            let id = graph.addNode(FlowGraph.label(text), shape)
            for node in previous { graph.connect(node, id) }
            return id
        }

        private mutating func select(_ parts: [Clause]) -> String? {
            guard let selectClause = parts.first(where: { $0.keyword == "SELECT" }) else {
                // `VALUES (…)` or something that is no query
                guard let values = parts.first(where: { $0.keyword == "VALUES" }) else { return nil }
                return step("Werte: " + SQLFlow.join(values.atoms), .process, after: [])
            }
            var current: String?
            if let from = parts.first(where: { $0.keyword == "FROM" }) {
                current = fromClause(from.atoms)
            }
            if let condition = parts.first(where: { $0.keyword == "WHERE" }) {
                current = step("Filter: " + SQLFlow.join(condition.atoms), .filter, after: current.map { [$0] } ?? [])
            }
            if let group = parts.first(where: { $0.keyword == "GROUP BY" }) {
                current = step("Gruppieren nach: " + SQLFlow.join(group.atoms), .process, after: current.map { [$0] } ?? [])
            }
            if let having = parts.first(where: { $0.keyword == "HAVING" }) {
                current = step("Gruppen filtern: " + SQLFlow.join(having.atoms), .filter, after: current.map { [$0] } ?? [])
            }
            var columns = selectClause.atoms
            let isDistinct = columns.first?.upper == "DISTINCT"
            if isDistinct { columns.removeFirst() }
            let list = SQLFlow.items(columns).map { SQLFlow.join($0) }
            let text = list.count > 6 ? list.prefix(6).joined(separator: ", ") + ", … (\(list.count) Spalten)" : list.joined(separator: ", ")
            current = step("Spalten: " + (text.isEmpty ? "*" : text), .process, after: current.map { [$0] } ?? [])
            if isDistinct { current = step("Doppelte Zeilen entfernen", .process, after: [current!]) }
            return finish(from: current!, clauses: parts)
        }

        /// The tables of FROM and their joins: one node for the rows that come out.
        private mutating func fromClause(_ atoms: [Atom]) -> String? {
            struct Item {
                var join: String?
                var source: [Atom] = []
                var condition: [Atom] = []
            }
            var items: [Item] = []
            var depth = 0
            var phase = "source"      // source, join (the words before JOIN), condition
            var pendingJoin: [Atom] = []
            for atom in atoms {
                if atom.text == "(" { depth += 1 }
                if atom.text == ")" { depth -= 1 }
                if depth == 0 {
                    let upper = atom.upper
                    if atom.isWord, ["INNER", "LEFT", "RIGHT", "FULL", "CROSS", "NATURAL", "OUTER"].contains(upper) {
                        if phase != "join" { pendingJoin = [] }
                        phase = "join"
                        pendingJoin.append(atom)
                        continue
                    }
                    if atom.isWord, upper == "JOIN" {
                        pendingJoin.append(atom)
                        items.append(Item(join: SQLFlow.join(pendingJoin)))
                        pendingJoin = []
                        phase = "source"
                        continue
                    }
                    if atom.text == "," {
                        items.append(Item(join: "CROSS JOIN"))
                        phase = "source"
                        continue
                    }
                    if atom.isWord, upper == "ON" || upper == "USING", phase == "source" {
                        phase = "condition"
                        if upper == "USING" { items[items.count - 1].condition.append(atom) }
                        continue
                    }
                }
                if items.isEmpty { items.append(Item()) }
                if phase == "condition" { items[items.count - 1].condition.append(atom) } else if phase == "source" { items[items.count - 1].source.append(atom) }
            }
            var current: String?
            for item in items {
                guard let source = sourceNode(item.source) else { continue }
                if let existing = current, let join = item.join {
                    // `LEFT JOIN über b.kunde_id = a.id`; with USING the columns follow.
                    var text = join
                    if !item.condition.isEmpty {
                        text += item.condition.first?.upper == "USING" ? " " + SQLFlow.join(Array(item.condition.dropFirst())) : " über " + SQLFlow.join(item.condition)
                    }
                    current = step(text, .process, after: [existing, source])
                } else {
                    current = source
                }
            }
            return current
        }

        /// A table (with its alias), a common table expression, or a subquery in a box of its own.
        private mutating func sourceNode(_ atoms: [Atom]) -> String? {
            guard let first = atoms.first else { return nil }
            if first.text == "(", let (inner, close) = SQLFlow.bracketed(atoms, from: 0) {
                let alias = atoms[(close + 1)...].filter { $0.upper != "AS" }.map(\.text).joined(separator: " ")
                let before = graph.nodes.count
                guard let exit = query(SQLFlow.clauses(of: inner)) else { return nil }
                let ids = graph.nodes[before...].map(\.id)
                _ = graph.addGroup("Unterabfrage" + (alias.isEmpty ? "" : " \(alias)"), nodes: ids)
                return exit
            }
            let name = SQLFlow.join(atoms.filter { $0.upper != "AS" })
            // The table's own name, possibly with a schema in front (`public.kunden`), without its alias.
            var table = first.text
            var position = 1
            while position + 1 < atoms.count, atoms[position].text == ".", atoms[position + 1].isWord {
                table += "." + atoms[position + 1].text
                position += 2
            }
            if let cte = tables[table.lowercased()] { return cte }
            return graph.addNode(FlowGraph.label(name), .data)
        }

        // MARK: Other statements

        private mutating func insert(_ parts: [Clause]) -> Bool {
            // `t (a, b)`: the column list stands apart from the table's name.
            let target = SQLFlow.join(parts.first?.atoms ?? []).replacingOccurrences(of: "INTO ", with: "", options: [.caseInsensitive, .anchored])
                .replacingOccurrences(of: #"(\w)\("#, with: "$1 (", options: .regularExpression)
            var source: String?
            if let values = parts.first(where: { $0.keyword == "VALUES" }) {
                source = step("Werte: " + SQLFlow.join(values.atoms), .process, after: [])
            } else if let from = parts.firstIndex(where: { $0.keyword == "SELECT" || $0.keyword == "WITH" }) {
                source = query(Array(parts[from...]))
            }
            let id = step("Einfügen in " + target, .process, after: source.map { [$0] } ?? [])
            let done = graph.addNode("Tabelle geändert", .terminal)
            graph.connect(id, done)
            return true
        }

        private mutating func update(_ parts: [Clause]) -> Bool {
            let table = SQLFlow.join(parts.first?.atoms ?? [])
            var current = graph.addNode(FlowGraph.label(table), .data)
            if let condition = parts.first(where: { $0.keyword == "WHERE" }) {
                current = step("Filter: " + SQLFlow.join(condition.atoms), .filter, after: [current])
            }
            if let set = parts.first(where: { $0.keyword == "SET" }) {
                let assignments = SQLFlow.items(set.atoms).map { SQLFlow.join($0) }
                current = step("Setze:\n" + assignments.prefix(5).joined(separator: "\n") + (assignments.count > 5 ? "\n…" : ""), .process, after: [current])
            }
            let done = graph.addNode("Tabelle geändert", .terminal)
            graph.connect(current, done)
            return true
        }

        private mutating func delete(_ parts: [Clause]) -> Bool {
            let table = SQLFlow.join(parts.first(where: { $0.keyword == "FROM" })?.atoms ?? parts.first?.atoms ?? [])
            var current = graph.addNode(FlowGraph.label(table), .data)
            if let condition = parts.first(where: { $0.keyword == "WHERE" }) {
                current = step("Filter: " + SQLFlow.join(condition.atoms), .filter, after: [current])
            }
            current = step("Zeilen löschen", .error, after: [current])
            let done = graph.addNode("Tabelle geändert", .terminal)
            graph.connect(current, done)
            return true
        }

        /// CREATE, DROP, ALTER, TRUNCATE: one step, with the columns of a new table.
        private mutating func definition(_ atoms: [Atom]) -> Bool {
            guard !atoms.isEmpty else { return false }
            var head = atoms
            var columns: [String] = []
            if let open = atoms.firstIndex(where: { $0.text == "(" }), let (inner, close) = SQLFlow.bracketed(atoms, from: open) {
                head = Array(atoms[..<open]) + Array(atoms[(close + 1)...])
                columns = SQLFlow.items(inner).map { SQLFlow.join($0) }
            }
            var text = SQLFlow.join(head)
            if !columns.isEmpty { text += "\n" + columns.prefix(8).joined(separator: "\n") + (columns.count > 8 ? "\n…" : "") }
            let isDrop = atoms[0].upper == "DROP" || atoms[0].upper == "TRUNCATE"
            let id = graph.addNode(FlowGraph.label(text), isDrop ? .error : .process)
            let done = graph.addNode("Datenbank geändert", .terminal)
            graph.connect(id, done)
            return true
        }
    }
}
