import Foundation

/// A Mermaid diagram of the content analysis, with the places in the document its nodes stand for.
struct MermaidDiagram: Identifiable, Hashable, Sendable {
    let id: String
    let title: String
    let caption: String?
    let code: String
    /// Node IDs → places in the document; a click on such a node jumps there.
    let links: [String: DocumentAnchor]
}

/// The colours of the diagrams on the dark sheet and on white paper. Mermaid takes CSS colours as text.
struct MermaidPalette: Hashable, Sendable {
    let isLight: Bool
    let text: String
    let secondaryText: String
    let line: String
    let node: String
    let nodeBorder: String
    let accentFill: String
    let accent: String
    let accentText: String
    let quietFill: String
    let dangerFill: String
    let danger: String
    let successFill: String
    let success: String
    let warningFill: String
    let warning: String
    let cluster: String
    let clusterBorder: String
    let edgeLabelBackground: String
    /// Branch colours of the mind map.
    let branches: [String]

    static let dark = MermaidPalette(
        isLight: false,
        text: "#EDEDEF", secondaryText: "#A1A1A9", line: "#76767F",
        node: "#1E1E23", nodeBorder: "#3A3A42",
        accentFill: "#2A2442", accent: "#A996FF", accentText: "#F3F0FF",
        quietFill: "#17171B",
        dangerFill: "#2C1A1D", danger: "#FF6B6B",
        successFill: "#152920", success: "#3FD68F",
        warningFill: "#2E2414", warning: "#F2B14C",
        cluster: "#1A1A1F", clusterBorder: "#2C2C33",
        edgeLabelBackground: "#141417",
        branches: ["#2A2442", "#1B2A3B", "#1A2E25", "#33281A", "#3A1F2D", "#1C3033", "#2F2A1A", "#2A1F3A"]
    )

    static let light = MermaidPalette(
        isLight: true,
        text: "#1C1C1F", secondaryText: "#55555D", line: "#9A9AA3",
        node: "#F6F5FA", nodeBorder: "#D6D4DE",
        accentFill: "#EEEAFE", accent: "#6A54E0", accentText: "#2B1F73",
        quietFill: "#FFFFFF",
        dangerFill: "#FDEDED", danger: "#D64545",
        successFill: "#E8F7EF", success: "#1E9E61",
        warningFill: "#FDF3E1", warning: "#C27C0E",
        cluster: "#FAFAFC", clusterBorder: "#E4E2EA",
        edgeLabelBackground: "#FFFFFF",
        branches: ["#EEEAFE", "#E3EEFB", "#E3F5EC", "#FCF0DE", "#FBE6EF", "#E0F3F4", "#F6F1DC", "#EFE6FA"]
    )

    /// Mermaid's theme variables for the `base` theme.
    var themeVariables: [String: String] {
        var variables = [
            "darkMode": isLight ? "false" : "true",
            "background": "transparent",
            "fontFamily": "-apple-system, BlinkMacSystemFont, \"SF Pro Text\", \"Helvetica Neue\", sans-serif",
            "fontSize": "14px",
            "primaryColor": node,
            "primaryTextColor": text,
            "primaryBorderColor": nodeBorder,
            "secondaryColor": cluster,
            "tertiaryColor": cluster,
            "lineColor": line,
            "textColor": text,
            "titleColor": secondaryText,
            "mainBkg": node,
            "nodeBorder": nodeBorder,
            "nodeTextColor": text,
            "clusterBkg": cluster,
            "clusterBorder": clusterBorder,
            "edgeLabelBackground": edgeLabelBackground,
        ]
        for (index, color) in branches.enumerated() {
            variables["cScale\(index)"] = color
            variables["cScaleLabel\(index)"] = text
            variables["cScalePeer\(index)"] = nodeBorder
        }
        for index in branches.count..<12 {
            variables["cScale\(index)"] = branches[index % branches.count]
            variables["cScaleLabel\(index)"] = text
        }
        return variables
    }

    /// `classDef` lines shared by all diagrams.
    var classDefinitions: String {
        """
          classDef thesis fill:\(accentFill),stroke:\(accent),stroke-width:2px,color:\(accentText)
          classDef conclusion fill:\(node),stroke:\(accent),stroke-width:1.5px,color:\(text)
          classDef premise fill:\(node),stroke:\(nodeBorder),color:\(text)
          classDef implicit fill:\(quietFill),stroke:\(line),stroke-dasharray:4 3,color:\(secondaryText)
          classDef objection fill:\(dangerFill),stroke:\(danger),color:\(text)
          classDef rebuttal fill:\(successFill),stroke:\(success),color:\(text)
          classDef protagonist fill:\(accentFill),stroke:\(accent),stroke-width:2px,color:\(accentText)
          classDef antagonist fill:\(dangerFill),stroke:\(danger),stroke-width:1.5px,color:\(text)
          classDef supporting fill:\(node),stroke:\(nodeBorder),color:\(text)
          classDef mentioned fill:\(quietFill),stroke:\(line),stroke-dasharray:4 3,color:\(secondaryText)
          classDef event fill:\(node),stroke:\(nodeBorder),color:\(text)
          classDef step fill:\(node),stroke:\(accent),color:\(text)
          classDef concept fill:\(node),stroke:\(nodeBorder),color:\(text)
          classDef subject fill:\(accentFill),stroke:\(accent),stroke-width:2px,color:\(accentText)
          classDef aspect fill:\(accentFill),stroke:\(accent),color:\(text)
          classDef point fill:\(node),stroke:\(nodeBorder),color:\(text),text-align:left
          classDef detail fill:\(quietFill),stroke:\(nodeBorder),color:\(secondaryText)
        """
    }
}

/// Turns the analysis into Mermaid code. The model only delivers the content; the syntax is made here, so it is
/// always valid whatever the model writes.
enum ContentAnalysisDiagrams {
    static func diagrams(for module: ContentAnalysisModule, in analysis: ContentAnalysis, palette: MermaidPalette) -> [MermaidDiagram] {
        switch module {
        case .overview, .code: return []
        case .argumentation:
            guard let argumentation = analysis.argumentation, !argumentation.arguments.isEmpty else { return [] }
            return [argumentMap(argumentation, palette: palette)]
        case .narrative:
            guard let narrative = analysis.narrative else { return [] }
            return [characterMap(narrative, palette: palette), plot(narrative, palette: palette)].compactMap { $0 }
        case .structure:
            guard let structure = analysis.structure else { return [] }
            return [outline(structure, palette: palette), process(structure, palette: palette), concepts(structure, palette: palette)].compactMap { $0 }
        }
    }

    // MARK: Argumentation

    /// Read from left to right: premises lead to their conclusion, conclusions to the main thesis (or to the
    /// argument they support); objections point at what they attack, the text's rebuttal sits next to them. The arguments
    /// stack, so the map grows downwards rather than out of the page.
    static func argumentMap(_ argumentation: ArgumentAnalysis, palette: MermaidPalette) -> MermaidDiagram {
        var lines = ["flowchart LR", palette.classDefinitions]
        var links: [String: DocumentAnchor] = [:]
        lines.append("  T[\"<b>Hauptthese</b><br/>\(label(argumentation.thesis, limit: 180))\"]:::thesis")
        links["T"] = argumentation.thesisAnchor

        for (index, argument) in argumentation.arguments.enumerated() {
            let number = index + 1
            lines.append("  subgraph G\(number)[\"\(number) · \(label(argument.title, limit: 60))\"]")
            for (premiseIndex, premise) in argument.premises.enumerated() {
                let id = "A\(number)P\(premiseIndex + 1)"
                if premise.isImplicit {
                    lines.append("    \(id)[\"<i>implizit:</i> \(label(premise.text))\"]:::implicit")
                } else {
                    lines.append("    \(id)[\"\(label(premise.text))\"]:::premise")
                }
                links[id] = premise.anchor ?? argument.anchor
            }
            lines.append("    A\(number)K[\"<b>∴</b> \(label(argument.conclusion))\"]:::conclusion")
            links["A\(number)K"] = argument.anchor
            lines.append("  end")
            for premiseIndex in argument.premises.indices {
                lines.append("  A\(number)P\(premiseIndex + 1) --> A\(number)K")
            }
            if let supported = argumentation.supportedArgument(of: index) {
                lines.append("  A\(number)K -->|\"stützt\"| A\(supported + 1)K")
            } else {
                lines.append("  A\(number)K ==> T")
            }
        }

        for (index, objection) in argumentation.objections.enumerated() {
            let number = index + 1
            let target = objection.target.flatMap { argumentation.arguments.indices.contains($0) ? "A\($0 + 1)K" : nil } ?? "T"
            lines.append("  E\(number)[\"<b>Einwand</b><br/>\(label(objection.text))\"]:::objection")
            lines.append("  E\(number) -. \"spricht dagegen\" .-x \(target)")
            links["E\(number)"] = objection.anchor
            if !objection.rebuttal.trimmingCharacters(in: .whitespaces).isEmpty {
                lines.append("  R\(number)[\"<b>Erwiderung</b><br/>\(label(objection.rebuttal))\"]:::rebuttal")
                // Placed right of the objection (not in front of it), so the map gets no extra column.
                lines.append("  E\(number) -.- R\(number)")
                links["R\(number)"] = objection.anchor
            }
        }
        return MermaidDiagram(
            id: "argumente",
            title: "Argumentkarte",
            caption: "Prämissen führen zur Konklusion (∴), Konklusionen zur Hauptthese. Gestrichelt: implizite Prämissen und Einwände.",
            code: lines.joined(separator: "\n"),
            links: links
        )
    }

    // MARK: Narrative

    static func characterMap(_ narrative: NarrativeAnalysis, palette: MermaidPalette) -> MermaidDiagram? {
        guard !narrative.characters.isEmpty else { return nil }
        var lines = ["flowchart LR", palette.classDefinitions]
        var links: [String: DocumentAnchor] = [:]
        var ids: [String: String] = [:]
        for (index, character) in narrative.characters.enumerated() {
            let id = "C\(index + 1)"
            ids[character.name] = id
            let role = character.role == .supporting ? "" : "<br/><small>\(label(character.role.label))</small>"
            lines.append("  \(id)([\"<b>\(label(character.name, limit: 40))</b>\(role)\"]):::\(roleClass(character.role))")
            links[id] = character.anchor
        }
        var extra = 0
        func node(for name: String) -> String {
            if let id = matchingName(name, in: narrative.characters.map(\.name)).flatMap({ ids[$0] }) ?? ids[name] { return id }
            extra += 1
            let id = "X\(extra)"
            ids[name] = id
            lines.append("  \(id)([\"\(label(name, limit: 40))\"]):::mentioned")
            return id
        }
        var seen = Set<String>()
        for relation in narrative.relations {
            let kind = shortRelation(relation.kind)
            for from in splitNames(relation.from) {
                for to in splitNames(relation.to) {
                    let a = node(for: from), b = node(for: to)
                    guard a != b, seen.insert([a, b].sorted().joined(separator: "|") + kind.lowercased()).inserted else { continue }
                    lines.append(kind.isEmpty ? "  \(a) --- \(b)" : "  \(a) -->|\"\(label(kind, limit: 40))\"| \(b)")
                }
            }
        }
        return MermaidDiagram(
            id: "figuren",
            title: "Figurenkonstellation",
            caption: "Hauptfiguren hervorgehoben, Gegenspieler rot, nur erwähnte Figuren gestrichelt.",
            code: lines.joined(separator: "\n"),
            links: links
        )
    }

    /// The events in the order of the text; events that follow each other at the same place form a scene.
    static func plot(_ narrative: NarrativeAnalysis, palette: MermaidPalette) -> MermaidDiagram? {
        guard narrative.events.count >= 2 else { return nil }
        var scenes: [(place: String, events: [Int])] = []
        for (index, event) in narrative.events.enumerated() {
            let place = placeName(event.place, places: narrative.places.map(\.name))
            if let last = scenes.last, last.place.lowercased() == place.lowercased() {
                scenes[scenes.count - 1].events.append(index)
            } else {
                scenes.append((place, [index]))
            }
        }
        var lines = ["flowchart TD", palette.classDefinitions]
        var links: [String: DocumentAnchor] = [:]
        for (sceneIndex, scene) in scenes.enumerated() {
            let title = scene.place.isEmpty ? "Szene \(sceneIndex + 1)" : label(scene.place, limit: 50)
            lines.append("  subgraph S\(sceneIndex + 1)[\"\(title)\"]")
            lines.append("    direction TB")
            for index in scene.events {
                let event = narrative.events[index]
                let who = event.characters.isEmpty ? "" : "<br/><small>\(label(event.characters.joined(separator: " · "), limit: 60))</small>"
                lines.append("    H\(index + 1)(\"\(label(event.text))\(who)\"):::event")
                links["H\(index + 1)"] = event.anchor
            }
            if scene.events.count > 1 {
                lines.append("    " + scene.events.map { "H\($0 + 1)" }.joined(separator: " --> "))
            }
            lines.append("  end")
        }
        // Scene to scene: the arrow ends at the scene's frame, above its title.
        if scenes.count > 1 {
            lines.append("  " + scenes.indices.map { "S\($0 + 1)" }.joined(separator: " --> "))
        }
        return MermaidDiagram(
            id: "handlung",
            title: "Handlungsverlauf",
            caption: "Die Ereignisse in der Reihenfolge des Textes, nach Schauplätzen zu Szenen gruppiert.",
            code: lines.joined(separator: "\n"),
            links: links
        )
    }

    // MARK: Structure

    /// The subject in the middle, its areas around it, their points and details further out.
    static func outline(_ structure: StructureAnalysis, palette: MermaidPalette) -> MermaidDiagram? {
        guard !structure.aspects.isEmpty else { return nil }
        var lines = ["flowchart LR", palette.classDefinitions]
        var links: [String: DocumentAnchor] = [:]
        lines.append("  R([\"<b>\(label(structure.subject.isEmpty ? "Gegenstand" : structure.subject, limit: 60))</b>\"]):::subject")
        for (aspectIndex, aspect) in structure.aspects.enumerated() {
            let aspectID = "B\(aspectIndex + 1)"
            lines.append("  \(aspectID)(\"<b>\(label(aspect.title, limit: 60))</b>\"):::aspect")
            lines.append("  R --- \(aspectID)")
            links[aspectID] = aspect.anchor
            for (pointIndex, point) in aspect.points.enumerated() {
                let pointID = "\(aspectID)P\(pointIndex + 1)"
                // Enumerations go into the point's box as a list: one level less keeps the tree narrow.
                let details = point.details.prefix(8).map { "<br/>· " + label($0, limit: 70) }.joined()
                lines.append("  \(pointID)(\"\(details.isEmpty ? "" : "<b>")\(label(point.text, limit: 80))\(details.isEmpty ? "" : "</b>")\(details)\"):::point")
                lines.append("  \(aspectID) --- \(pointID)")
                links[pointID] = aspect.anchor
            }
        }
        return MermaidDiagram(
            id: "gliederung",
            title: "Gliederung",
            caption: "Der Gegenstand mit seinen Bereichen, ihren Punkten und Aufzählungen.",
            code: lines.joined(separator: "\n"),
            links: links
        )
    }

    static func process(_ structure: StructureAnalysis, palette: MermaidPalette) -> MermaidDiagram? {
        guard structure.steps.count >= 2 else { return nil }
        let isShort = structure.steps.count <= 4 && structure.steps.allSatisfy { $0.text.count <= 70 }
        var lines = [isShort ? "flowchart LR" : "flowchart TD", palette.classDefinitions]
        var links: [String: DocumentAnchor] = [:]
        for (index, step) in structure.steps.enumerated() {
            lines.append("  S\(index + 1)([\"<b>\(index + 1)</b>  \(label(step.text))\"]):::step")
            links["S\(index + 1)"] = step.anchor
        }
        lines.append("  " + structure.steps.indices.map { "S\($0 + 1)" }.joined(separator: " --> "))
        return MermaidDiagram(
            id: "ablauf",
            title: "Ablauf",
            caption: "Die Schritte in der Reihenfolge, die der Text beschreibt.",
            code: lines.joined(separator: "\n"),
            links: links
        )
    }

    static func concepts(_ structure: StructureAnalysis, palette: MermaidPalette) -> MermaidDiagram? {
        let relations = structure.relations.filter { !$0.from.isEmpty && !$0.to.isEmpty }
        guard relations.count >= 2 else { return nil }
        var lines = ["flowchart LR", palette.classDefinitions]
        var ids: [String: String] = [:]
        func node(_ name: String) -> String {
            let key = name.lowercased()
            if let id = ids[key] { return id }
            let id = "K\(ids.count + 1)"
            ids[key] = id
            lines.append("  \(id)([\"\(label(name, limit: 50))\"]):::concept")
            return id
        }
        var seen = Set<String>()
        for relation in relations {
            let a = node(relation.from.trimmingCharacters(in: .whitespaces))
            let b = node(relation.to.trimmingCharacters(in: .whitespaces))
            let kind = shortRelation(relation.kind)
            guard a != b, seen.insert("\(a)|\(b)|\(kind.lowercased())").inserted else { continue }
            lines.append(kind.isEmpty ? "  \(a) --> \(b)" : "  \(a) -->|\"\(label(kind, limit: 40))\"| \(b)")
        }
        return MermaidDiagram(
            id: "zusammenhaenge",
            title: "Zusammenhänge",
            caption: "Wie die Begriffe des Textes miteinander zusammenhängen.",
            code: lines.joined(separator: "\n"),
            links: [:]
        )
    }

    // MARK: Text

    /// Text for a quoted Mermaid label: one line, Mermaid's entity codes for characters that would end or change
    /// the label, and cut short when it is long.
    static func label(_ text: String, limit: Int = 150) -> String {
        var plain = text.replacingOccurrences(of: "**", with: "")
            .split(whereSeparator: \.isWhitespace).joined(separator: " ")
        if plain.count > limit {
            plain = String(plain.prefix(limit - 1)).trimmingCharacters(in: .whitespaces) + "…"
        }
        var escaped = ""
        for character in plain {
            switch character {
            case "#": escaped += "#35;"
            case "\"": escaped += "#quot;"
            case "<": escaped += "#lt;"
            case ">": escaped += "#gt;"
            case "&": escaped += "#amp;"
            case "`": escaped += "'"
            default: escaped.append(character)
            }
        }
        return escaped
    }

    /// "Geschwister; haben gestritten …" → "Geschwister": edge labels stay short.
    static func shortRelation(_ kind: String) -> String {
        let first = kind.split(whereSeparator: { ";:(".contains($0) }).first.map(String.init) ?? kind
        let words = first.split(whereSeparator: \.isWhitespace)
        let short = words.prefix(5).joined(separator: " ")
        return short.trimmingCharacters(in: CharacterSet(charactersIn: " ,.-–"))
    }

    /// "Lena/Tom", "Lena und Tom" → both.
    static func splitNames(_ text: String) -> [String] {
        text.replacingOccurrences(of: " und ", with: "/").replacingOccurrences(of: " & ", with: "/")
            .split(whereSeparator: { "/,;".contains($0) })
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    /// A name as the model wrote it in a relation, matched to a character: equal, or one contains the other
    /// ("Berger" – "Frau Berger").
    static func matchingName(_ name: String, in names: [String]) -> String? {
        let wanted = name.lowercased()
        if let exact = names.first(where: { $0.lowercased() == wanted }) { return exact }
        let candidates = names.filter {
            let other = $0.lowercased()
            return other.split(separator: " ").contains { $0 == wanted } || wanted.split(separator: " ").contains { $0 == other }
                || (wanted.count >= 4 && other.contains(wanted)) || (other.count >= 4 && wanted.contains(other))
        }
        return candidates.count == 1 ? candidates[0] : nil
    }

    /// The model writes an event's place a little differently each time ("Küchentisch (im Haus)"): the named
    /// place it means, else the place without remarks in brackets.
    static func placeName(_ place: String, places: [String]) -> String {
        let plain = place.replacingOccurrences(of: #"\s*\(.*?\)"#, with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
        let wanted = plain.lowercased()
        guard !wanted.isEmpty else { return "" }
        if let exact = places.first(where: { $0.lowercased() == wanted }) { return exact }
        let containing = places.filter {
            let name = $0.lowercased()
            return (name.count >= 4 && wanted.contains(name)) || (wanted.count >= 4 && name.contains(wanted))
        }
        return containing.count == 1 ? containing[0] : plain
    }

    private static func roleClass(_ role: NarrativeAnalysis.Role) -> String {
        switch role {
        case .protagonist: "protagonist"
        case .antagonist: "antagonist"
        case .supporting: "supporting"
        case .mentioned: "mentioned"
        }
    }
}
