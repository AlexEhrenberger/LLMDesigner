import Foundation

/// A flow chart of a piece of code: what happens, in which order, under which conditions. Made from the code by
/// `PythonFlow` and `SQLFlow`; `mermaid(palette:)` writes it for the diagram renderer, so the syntax is always valid.
struct FlowGraph: Identifiable, Hashable, Sendable {
    enum Shape: Hashable, Sendable {
        /// Start, end and result: a rounded bar.
        case terminal
        case process
        case decision
        case loop
        /// Input and output.
        case inputOutput
        /// A table or another source of data.
        case data
        /// A filter or a condition that lets rows pass.
        case filter
        case error
    }

    struct Node: Hashable, Sendable {
        let id: String
        var text: String
        var shape: Shape
    }

    struct Edge: Hashable, Sendable {
        var from: String
        var to: String
        var label: String?
        var isDashed = false
    }

    /// A box around nodes (the body of `try`, a subquery, a common table expression).
    struct Group: Hashable, Sendable {
        let id: String
        var title: String
        var nodes: [String]
    }

    let id = UUID()
    var title: String
    var language: CodeLanguage
    var nodes: [Node] = []
    var edges: [Edge] = []
    var groups: [Group] = []
    /// `TD` (top down) or `LR`.
    var direction = "TD"

    var isEmpty: Bool { nodes.count <= 2 }

    // MARK: Building

    private var counter = 0

    init(title: String, language: CodeLanguage) {
        self.title = title
        self.language = language
    }

    mutating func addNode(_ text: String, _ shape: Shape, id: String? = nil) -> String {
        counter += 1
        let nodeID = id ?? "n\(counter)"
        nodes.append(Node(id: nodeID, text: text, shape: shape))
        return nodeID
    }

    mutating func connect(_ from: String, _ to: String, label: String? = nil, dashed: Bool = false) {
        edges.append(Edge(from: from, to: to, label: label, isDashed: dashed))
    }

    mutating func addGroup(_ title: String, nodes ids: [String]) -> String {
        counter += 1
        let id = "g\(counter)"
        groups.append(Group(id: id, title: title, nodes: ids))
        return id
    }

    /// Hashable/Equatable follow the content, not the identity, so a diagram that stays the same is not drawn anew.
    static func == (lhs: FlowGraph, rhs: FlowGraph) -> Bool {
        lhs.title == rhs.title && lhs.nodes == rhs.nodes && lhs.edges == rhs.edges && lhs.groups == rhs.groups && lhs.direction == rhs.direction
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(title)
        hasher.combine(nodes)
        hasher.combine(edges)
    }

    // MARK: Mermaid

    /// Text for a node: one line per line of code, no longer than `limit` characters each.
    static func label(_ text: String, limit: Int = 80) -> String {
        text.components(separatedBy: "\n").prefix(6).map { line -> String in
            let collapsed = line.split(whereSeparator: { $0 == " " || $0 == "\t" }).joined(separator: " ")
            return collapsed.count > limit ? String(collapsed.prefix(limit - 1)) + "…" : collapsed
        }.joined(separator: "\n")
    }

    /// Mermaid reads `#quot;` and the like inside quoted text.
    private static func escaped(_ text: String) -> String {
        var result = ""
        for character in text {
            switch character {
            case "\"": result += "#quot;"
            case "<": result += "#lt;"
            case ">": result += "#gt;"
            case "&": result += "#amp;"
            case "\n": result += "<br/>"
            case "`": result += "#96;"
            case "#": result += "#35;"
            default: result.append(character)
            }
        }
        return result
    }

    private func definition(_ node: Node) -> String {
        let text = Self.escaped(node.text)
        switch node.shape {
        case .terminal: return "\(node.id)([\"\(text)\"]):::cfTerminal"
        case .process: return "\(node.id)[\"\(text)\"]:::cfProcess"
        case .decision: return "\(node.id){\"\(text)\"}:::cfDecision"
        case .loop: return "\(node.id){{\"\(text)\"}}:::cfLoop"
        case .inputOutput: return "\(node.id)[/\"\(text)\"/]:::cfIO"
        case .data: return "\(node.id)[(\"\(text)\")]:::cfData"
        case .filter: return "\(node.id)[\"\(text)\"]:::cfFilter"
        case .error: return "\(node.id)[\"\(text)\"]:::cfError"
        }
    }

    func mermaid(palette: MermaidPalette) -> String {
        var lines = ["flowchart \(direction)"]
        let grouped = Set(groups.flatMap(\.nodes))
        for node in nodes where !grouped.contains(node.id) { lines.append("  " + definition(node)) }
        // Groups can hold groups: a group inside another one lists its nodes in both, the inner one is drawn inside.
        let inner = Set(groups.flatMap { group in groups.filter { $0.id != group.id && Set($0.nodes).isSubset(of: group.nodes) && $0.nodes.count < group.nodes.count }.map(\.id) })
        func draw(_ group: Group, depth: Int) {
            let pad = String(repeating: "  ", count: depth + 1)
            lines.append("\(pad)subgraph \(group.id)[\"\(Self.escaped(group.title))\"]")
            let children = groups.filter { $0.id != group.id && Set($0.nodes).isSubset(of: group.nodes) && $0.nodes.count < group.nodes.count && inner.contains($0.id) }
            let nested = Set(children.flatMap(\.nodes))
            for node in nodes where group.nodes.contains(node.id) && !nested.contains(node.id) { lines.append(pad + "  " + definition(node)) }
            for child in children { draw(child, depth: depth + 1) }
            lines.append("\(pad)end")
        }
        for group in groups where !inner.contains(group.id) { draw(group, depth: 0) }
        for edge in edges {
            let arrow = edge.isDashed ? "-.->" : "-->"
            if let label = edge.label, !label.isEmpty {
                lines.append("  \(edge.from) \(edge.isDashed ? "-. " : "-- ")\"\(Self.escaped(label))\"\(edge.isDashed ? " .-> " : " --> ")\(edge.to)")
            } else {
                lines.append("  \(edge.from) \(arrow) \(edge.to)")
            }
        }
        lines.append(Self.classDefinitions(palette))
        return lines.joined(separator: "\n")
    }

    private static func classDefinitions(_ palette: MermaidPalette) -> String {
        """
          classDef cfTerminal fill:\(palette.accentFill),stroke:\(palette.accent),stroke-width:2px,color:\(palette.accentText)
          classDef cfProcess fill:\(palette.node),stroke:\(palette.nodeBorder),color:\(palette.text)
          classDef cfDecision fill:\(palette.warningFill),stroke:\(palette.warning),color:\(palette.text)
          classDef cfLoop fill:\(palette.accentFill),stroke:\(palette.accent),color:\(palette.text)
          classDef cfIO fill:\(palette.successFill),stroke:\(palette.success),color:\(palette.text)
          classDef cfData fill:\(palette.node),stroke:\(palette.accent),stroke-width:1.5px,color:\(palette.text)
          classDef cfFilter fill:\(palette.warningFill),stroke:\(palette.warning),color:\(palette.text)
          classDef cfError fill:\(palette.dangerFill),stroke:\(palette.danger),color:\(palette.text)
        """
    }
}

/// A piece of code in a document.
struct CodeSnippet: Identifiable, Hashable, Sendable {
    let id: Int
    let language: CodeLanguage
    let code: String
    /// The Markdown block number (as `DocumentOutlineBuilder.blocks` counts them), for jumping there.
    let block: Int
    /// The lines of the block's code, to name it.
    var firstLine: String { code.split(separator: "\n").first.map(String.init) ?? "" }

    /// The code blocks of a document that are Python or SQL (the fence says it, or it clearly is).
    static func snippets(in markdown: String) -> [CodeSnippet] {
        var result: [CodeSnippet] = []
        for (index, block) in MarkdownParser.parse(WriterBookmark.strip(markdown)).enumerated() {
            guard case .code(let fence, let code) = block, !code.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }
            let language = CodeLanguage(fence: fence) ?? (fence.isEmpty ? CodeLanguage.detect(code) : nil)
            guard let language else { continue }
            result.append(CodeSnippet(id: result.count, language: language, code: code, block: index))
        }
        return result
    }

    var anchor: DocumentAnchor { DocumentAnchor(block: block, key: DocumentOutlineBuilder.searchKey("[Code]")) }

    /// The flow charts of this code: one per function, plus the main program, or one per SQL statement.
    func flowcharts() -> [FlowGraph] {
        switch language {
        case .python: PythonFlow.graphs(for: code)
        case .sql: SQLFlow.graphs(for: code)
        }
    }
}
