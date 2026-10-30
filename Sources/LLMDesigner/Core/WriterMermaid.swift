import Foundation

/// Mermaid diagrams in Writer Studio: templates to start from, the look (stored in the code's own front matter, which
/// Mermaid reads: `---\nconfig:\n  theme: forest\n---`), and the model writing a diagram from a description.
enum WriterMermaid {
    enum DiagramType: String, CaseIterable, Identifiable, Sendable {
        case flowchart, sequence, mindmap, timeline, classDiagram, state, entity, gantt, pie, journey, quadrant

        var id: String { rawValue }

        var label: String {
            switch self {
            case .flowchart: "Ablaufdiagramm"
            case .sequence: "Sequenzdiagramm"
            case .mindmap: "Mindmap"
            case .timeline: "Zeitstrahl"
            case .classDiagram: "Klassendiagramm"
            case .state: "Zustandsdiagramm"
            case .entity: "ER-Diagramm"
            case .gantt: "Gantt-Plan"
            case .pie: "Kreisdiagramm"
            case .journey: "User Journey"
            case .quadrant: "Quadranten"
            }
        }

        var symbol: String {
            switch self {
            case .flowchart: "arrow.triangle.branch"
            case .sequence: "arrow.left.arrow.right"
            case .mindmap: "brain"
            case .timeline: "calendar.day.timeline.left"
            case .classDiagram: "square.stack.3d.up"
            case .state: "circle.grid.cross"
            case .entity: "cylinder.split.1x2"
            case .gantt: "chart.bar.doc.horizontal"
            case .pie: "chart.pie"
            case .journey: "figure.walk"
            case .quadrant: "square.grid.2x2"
            }
        }

        /// The first word of the code that says the type.
        var keyword: String {
            switch self {
            case .flowchart: "flowchart"
            case .sequence: "sequenceDiagram"
            case .mindmap: "mindmap"
            case .timeline: "timeline"
            case .classDiagram: "classDiagram"
            case .state: "stateDiagram-v2"
            case .entity: "erDiagram"
            case .gantt: "gantt"
            case .pie: "pie"
            case .journey: "journey"
            case .quadrant: "quadrantChart"
            }
        }
    }

    static func template(_ type: DiagramType) -> String {
        switch type {
        case .flowchart:
            return """
            flowchart TD
                A[Idee] --> B{Machbar?}
                B -- ja --> C[Planen]
                B -- nein --> D[Verwerfen]
                C --> E([Umsetzen])
            """
        case .sequence:
            return """
            sequenceDiagram
                participant N as Nutzerin
                participant A as App
                participant M as Modell
                N->>A: Frage stellen
                A->>M: Prompt mit Kontext
                M-->>A: Antwort
                A-->>N: Antwort anzeigen
            """
        case .mindmap:
            return """
            mindmap
              root((Thema))
                Ursachen
                  Erste
                  Zweite
                Folgen
                  Kurzfristig
                  Langfristig
                Lösungen
            """
        case .timeline:
            return """
            timeline
                title Geschichte
                1989 : Mauerfall
                1990 : Wiedervereinigung
                2002 : Euro als Bargeld
            """
        case .classDiagram:
            return """
            classDiagram
                class Dokument {
                    +String titel
                    +speichern()
                }
                class Kapitel
                Dokument "1" --> "*" Kapitel : enthält
            """
        case .state:
            return """
            stateDiagram-v2
                [*] --> Entwurf
                Entwurf --> Prüfung : einreichen
                Prüfung --> Entwurf : überarbeiten
                Prüfung --> Veröffentlicht : freigeben
                Veröffentlicht --> [*]
            """
        case .entity:
            return """
            erDiagram
                AUTOR ||--o{ BUCH : schreibt
                BUCH }o--|| VERLAG : erscheint_bei
                BUCH {
                    string titel
                    int jahr
                }
            """
        case .gantt:
            return """
            gantt
                title Projektplan
                dateFormat YYYY-MM-DD
                section Vorbereitung
                    Recherche      :a1, 2026-11-02, 10d
                    Gliederung     :after a1, 5d
                section Schreiben
                    Rohfassung     :b1, 2026-11-20, 20d
                    Überarbeitung  :after b1, 10d
            """
        case .pie:
            return """
            pie title Zeitaufwand
                "Recherche" : 40
                "Schreiben" : 35
                "Korrektur" : 25
            """
        case .journey:
            return """
            journey
                title Ein Arbeitstag
                section Morgen
                    Kaffee: 5: Ich
                    E-Mails: 2: Ich
                section Nachmittag
                    Schreiben: 4: Ich
            """
        case .quadrant:
            return """
            quadrantChart
                title Aufwand und Nutzen
                x-axis Wenig Aufwand --> Viel Aufwand
                y-axis Wenig Nutzen --> Viel Nutzen
                quadrant-1 Planen
                quadrant-2 Sofort tun
                quadrant-3 Lassen
                quadrant-4 Später
                Idee A: [0.3, 0.8]
                Idee B: [0.7, 0.6]
                Idee C: [0.2, 0.2]
            """
        }
    }

    /// The type a description asks for ("eine Mindmap über …", "Zeitstrahl der …"); nil when it names none.
    static func requestedType(in description: String) -> DiagramType? {
        let text = description.lowercased()
        let words: [(DiagramType, [String])] = [
            (.mindmap, ["mindmap", "mind map", "mind-map", "gedankenkarte"]),
            (.timeline, ["zeitstrahl", "zeitleiste", "timeline", "chronolog"]),
            (.sequence, ["sequenz", "sequence", "nachrichtenfluss"]),
            (.gantt, ["gantt", "projektplan", "zeitplan"]),
            (.pie, ["kreisdiagramm", "tortendiagramm", "pie", "anteile"]),
            (.classDiagram, ["klassendiagramm", "class diagram", "uml"]),
            (.state, ["zustand", "state"]),
            (.entity, ["er-diagramm", "entity", "datenbankmodell", "tabellenmodell"]),
            (.journey, ["journey", "kundenreise"]),
            (.quadrant, ["quadrant", "vier-felder", "vierfelder", "matrix"]),
            (.flowchart, ["ablauf", "flussdiagramm", "flowchart", "prozess", "entscheidung"]),
        ]
        return words.first { _, keys in keys.contains { text.contains($0) } }?.0
    }

    /// The type of a diagram, by its first word after the front matter.
    static func type(of code: String) -> DiagramType? {
        let body = splitFrontMatter(code).body
        guard let word = body.split(whereSeparator: \.isWhitespace).first.map(String.init) else { return nil }
        if word == "graph" { return .flowchart }
        if word == "stateDiagram" { return .state }
        return DiagramType.allCases.first { $0.keyword == word }
    }

    // MARK: Look

    /// How a diagram looks: Mermaid's theme and drawing style, and for flow charts the lines and the direction.
    struct Style: Equatable, Sendable {
        /// nil: the app's own colours (dark on the dark sheet, light in print).
        var theme: Theme?
        var handDrawn = false
        var curve: Curve?
        var font: String?

        enum Theme: String, CaseIterable, Identifiable, Sendable {
            case `default`, neutral, forest, base
            var id: String { rawValue }
            var label: String {
                switch self {
                case .default: "Mermaid"
                case .neutral: "Neutral"
                case .forest: "Wald"
                case .base: "Schlicht"
                }
            }
        }

        enum Curve: String, CaseIterable, Identifiable, Sendable {
            case basis, linear, step
            var id: String { rawValue }
            var label: String {
                switch self {
                case .basis: "Geschwungen"
                case .linear: "Gerade"
                case .step: "Eckig"
                }
            }
        }
    }

    /// The front matter (without its `---` lines) and the diagram's code after it.
    static func splitFrontMatter(_ code: String) -> (frontMatter: [String], body: String) {
        let lines = code.components(separatedBy: "\n")
        guard let first = lines.firstIndex(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty }),
              lines[first].trimmingCharacters(in: .whitespaces) == "---",
              let end = lines[(first + 1)...].firstIndex(where: { $0.trimmingCharacters(in: .whitespaces) == "---" }) else {
            return ([], code)
        }
        return (Array(lines[(first + 1)..<end]), lines[(end + 1)...].joined(separator: "\n"))
    }

    /// The look the code's front matter sets.
    static func style(of code: String) -> Style {
        var style = Style()
        for line in splitFrontMatter(code).frontMatter {
            let parts = line.split(separator: ":", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            guard parts.count == 2 else { continue }
            let value = parts[1].trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
            switch parts[0] {
            case "theme": style.theme = Style.Theme(rawValue: value)
            case "look": style.handDrawn = value == "handDrawn"
            case "curve": style.curve = Style.Curve(rawValue: value)
            case "fontFamily": style.font = value.isEmpty ? nil : value
            default: break
            }
        }
        return style
    }

    /// The code with this look in its front matter (other front matter lines, like a title, stay).
    static func applying(_ style: Style, to code: String) -> String {
        let (frontMatter, body) = splitFrontMatter(code)
        let ownKeys = ["config", "theme", "look", "curve", "fontFamily", "flowchart"]
        let kept = frontMatter.filter { line in
            let key = line.split(separator: ":", maxSplits: 1).first.map { $0.trimmingCharacters(in: .whitespaces) } ?? ""
            return !ownKeys.contains(key) && !line.hasPrefix("    ")
        }
        var config: [String] = []
        if let theme = style.theme { config.append("  theme: \(theme.rawValue)") }
        if style.handDrawn { config.append("  look: handDrawn") }
        if let font = style.font { config.append("  fontFamily: \"\(font)\"") }
        if let curve = style.curve { config += ["  flowchart:", "    curve: \(curve.rawValue)"] }
        let header = kept + (config.isEmpty ? [] : ["config:"] + config)
        let trimmedBody = body.trimmingCharacters(in: .newlines)
        guard !header.isEmpty else { return trimmedBody }
        return "---\n" + header.joined(separator: "\n") + "\n---\n" + trimmedBody
    }

    /// A flow chart's direction (`TD`, `LR`, …) and the code with another one.
    static func direction(of code: String) -> String? {
        let body = splitFrontMatter(code).body.trimmingCharacters(in: .whitespacesAndNewlines)
        let words = body.split(whereSeparator: \.isWhitespace).prefix(2).map(String.init)
        guard words.count == 2, words[0] == "flowchart" || words[0] == "graph" else { return nil }
        return ["TD", "TB", "LR", "RL", "BT"].contains(words[1]) ? words[1] : nil
    }

    static func setting(direction: String, in code: String) -> String {
        guard let current = Self.direction(of: code), let range = code.range(of: " " + current) else { return code }
        return code.replacingCharacters(in: range, with: " " + direction)
    }

    // MARK: The model writes

    static let systemPrompt = """
    Du erstellst Diagramme in der Sprache Mermaid (Version 11). Antworte nur mit dem Mermaid-Code, ohne Erklärung, \
    ohne ``` und ohne Front-Matter.
    Regeln, damit der Code gültig ist:
    - Beginne mit dem Diagrammtyp: flowchart TD (oder LR), sequenceDiagram, mindmap, timeline, classDiagram, \
    stateDiagram-v2, erDiagram, gantt, pie, journey oder quadrantChart.
    - Knoten-IDs nur aus Buchstaben und Ziffern (A, B1, schritt2), nie Leerzeichen; den Text in Klammern: A[Text], \
    B{Frage?}, C([Start]), D((Kreis)).
    - Text mit Klammern, Doppelpunkt, Komma, Anführungszeichen oder Umlauten in doppelte Anführungszeichen: A["Text (mit Klammer)"].
    - Keine Anführungszeichen im Text selbst; keine Semikolons am Zeilenende; "end" nie als ID.
    - Beschriftete Pfeile so: A -- Beschriftung --> B oder A -->|Beschriftung| B.
    - Kurze Beschriftungen (höchstens 6 Wörter), höchstens etwa 15 Knoten.
    - Schreibe die Beschriftungen auf Deutsch, außer der Nutzer will etwas anderes.
    """

    /// Messages for a diagram from a description (and the text it is about, when there is one).
    static func messages(description: String, type: DiagramType?, context: String, current: String?) -> [ChatPayloadMessage] {
        var task = ""
        let type = type ?? requestedType(in: description)
        // A description that asks for another kind of diagram starts anew.
        let keeps = current.map { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && (type == nil || Self.type(of: $0) == type) } ?? false
        if keeps, let current {
            task += "Das ist das bisherige Diagramm:\n\(splitFrontMatter(current).body)\n\nÄndere es so: \(description)"
        } else {
            task += "Erstelle ein Diagramm: \(description)"
        }
        if let type {
            // Small models mix up the languages of the kinds: an example of this one helps.
            task += "\nDiagrammtyp: \(type.label). So sieht die Sprache dieses Typs aus (nur als Muster für die Syntax, nicht für den Inhalt):\n\(template(type))"
            if type == .mindmap { task += "\nIn einer Mindmap gibt es keine Pfeile: die Ebenen entstehen nur durch Einrückung, und es gibt genau eine Wurzel." }
        }
        let excerpt = context.trimmingCharacters(in: .whitespacesAndNewlines)
        if !excerpt.isEmpty {
            task += "\n\nDer Text, um den es geht:\n\"\"\"\n\(String(excerpt.prefix(6_000)))\n\"\"\""
        }
        return [
            ChatPayloadMessage(role: "system", content: systemPrompt),
            ChatPayloadMessage(role: "user", content: task),
        ]
    }

    /// Messages that ask to repair code Mermaid couldn't read.
    static func repairMessages(code: String, error: String) -> [ChatPayloadMessage] {
        var task = "Dieser Mermaid-Code ist ungültig:\n\(code)\n\nFehlermeldung: \(error)"
        if let type = type(of: code) {
            task += "\n\nSo sieht die Sprache eines \(type.label)s aus (Muster für die Syntax):\n\(template(type))"
            if type == .mindmap { task += "\nEine Mindmap hat keine Pfeile, nur Einrückung, und genau eine Wurzel." }
        }
        task += "\n\nGib den korrigierten Code zurück, sonst nichts."
        return [ChatPayloadMessage(role: "system", content: systemPrompt), ChatPayloadMessage(role: "user", content: task)]
    }

    /// The code in a model's answer: without thinking, fences and talk around it.
    static func code(inAnswer answer: String) -> String {
        var text = ThinkingSplitter.split(answer).content.trimmingCharacters(in: .whitespacesAndNewlines)
        if let open = text.range(of: "```") {
            let afterOpen = text[open.upperBound...]
            let firstLineEnd = afterOpen.firstIndex(of: "\n") ?? afterOpen.endIndex
            let rest = afterOpen[firstLineEnd...]
            let close = rest.range(of: "```")?.lowerBound ?? rest.endIndex
            text = String(rest[..<close]).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        // Talk before the diagram's first word goes.
        let lines = text.components(separatedBy: "\n")
        if let start = lines.firstIndex(where: { line in
            let word = line.trimmingCharacters(in: .whitespaces).split(separator: " ").first.map(String.init) ?? ""
            return DiagramType.allCases.contains { $0.keyword == word } || word == "graph" || word == "---"
        }) {
            text = lines[start...].joined(separator: "\n")
        }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
