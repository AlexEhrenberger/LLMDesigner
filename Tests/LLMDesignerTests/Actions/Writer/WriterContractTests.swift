import Testing
import AppKit
import LLMDProtocol
@testable import LLMDesigner

/// Rules every `writer.*` action keeps, checked against the registry itself, so a new action is checked without a
/// line here. The arguments are made from the action's schema (plus a few hints to reach the path that does
/// something); what is checked holds whatever the outcome:
/// - a read changes no document, a refused call changes nothing,
/// - a change is one undo step that takes it back byte for byte and brings it again,
/// - a stale `ifVersion` changes nothing, an unknown or a missing parameter is `invalidParams`,
/// - arguments the schema accepts never fail as "don't fit" or as an internal error,
/// - over MCP the changed document becomes foreign.
extension ActionSuites {
@MainActor
@Suite("Writer-Verträge (T1)", .serialized)
struct WriterContractTests {
    let h = ActionHarness()

    init() {
        // Bundled with the app only; a test finds mermaid.js in the repository.
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        setenv("LLMD_MERMAID_JS", root.appendingPathComponent("Resources/Mermaid/mermaid.min.js").path, 1)
    }

    /// Not run here: they act outside the app or need a model or Draw Things. Each has its own tests.
    static let skipped: [String: String] = [
        "writer.print": "Druckdialog",
        "writer.speech.read": "spricht laut",
        "writer.dictation.start": "Mikrofon",
        "writer.image.generate": "Draw Things",
        "writer.image.regenerate": "Draw Things",
        "writer.ai.write": "Sprachmodell", "writer.ai.rewrite": "Sprachmodell", "writer.ai.expand": "Sprachmodell",
        "writer.ai.answer": "Sprachmodell", "writer.ai.check": "Sprachmodell", "writer.ai.comment": "Sprachmodell",
        "writer.toc.expand": "Sprachmodell", "writer.analysis.run": "Sprachmodell",
        // They act on the undo stack itself; every other action checks them.
        "writer.edit.undo": "Rückgängig selbst", "writer.edit.redo": "Rückgängig selbst",
    ]

    /// Values for parameters by name, so a call aims at something the fixture has.
    static func value(for name: String, picture: String) -> JSONValue? {
        let values: [String: JSONValue] = [
            "match": "Wasserkreislauf", "heading": "Einleitung", "text": "Neuer Text", "markdown": "Neuer **Absatz**.",
            "url": "https://example.org/neu", "color": "Blau", "font": "sans", "title": "Neuer Titel", "name": "Neuer Name",
            "latex": "y = 2x", "expression": "f(x) = x^2", "code": "print(2)", "language": "python", "file": .string(picture),
            "find": "Thema", "replace": "Gegenstand", "query": "Merkwort", "caption": "Unterschrift", "bookmark": "Merker",
            "prompt": "a lighthouse", "instruction": "Schreib etwas", "question": "Worum geht es?", "newFolder": "Neuer Ordner",
        ]
        return values[name]
    }

    /// Hints per action: extra parameters that lead to the path that does something.
    static let hints: [String: JSONValue] = [
        "writer.export": ["format": "markdown"],
        "writer.table.insert": ["rows": 2, "columns": 2],
        "writer.mermaid.insert": ["code": "flowchart TD\n  X-->Y"],
        "writer.chart.insert": ["kind": "bar", "categories": ["A", "B"], "series": [["name": "Y", "values": [3, 4]]]],
        "writer.drawing.insert": ["elements": [["kind": "rectangle", "points": [[0, 0], [20, 20]]]]],
        "writer.page.format": ["format": "taschenbuch"],
        "writer.block.set": ["match": "Wasserkreislauf", "type": "quote"],
        "writer.code.insert": ["language": "python", "code": "print(3)"],
        "writer.formula.insert": ["latex": "z^2"],
        "writer.block.move": ["block": "$blockB", "before": "$blockA"],
        "writer.comment.reply": ["comment": "$comment", "text": "Ja."],
        "writer.comment.edit": ["comment": "$comment", "text": "Geändert."],
        "writer.comment.resolve": ["comment": "$comment"],
        "writer.comment.delete": ["comment": "$comment"],
        "writer.citation.insert": ["key": "$citekey"],
        "writer.citation.edit": ["citation": "1", "page": "12"],
        "writer.box.insert": ["markdown": "Im neuen Kasten."],
        "writer.text.replace": ["text": "Ersatz"],
        "writer.format.fontSize": ["size": 14],
        "writer.paragraph.indent": ["step": 1],
        "writer.paragraph.new": ["text": "Ein neuer Absatz."],
        "writer.table.cell.set": ["cell": "B2", "text": "9"],
        "writer.table.cell.split": ["cell": "A1"],
        "writer.table.cells.merge": ["from": "A2", "to": "B2"],
        "writer.table.formula.set": ["cell": "B3", "formula": "=SUMME(B1:B2)"],
        "writer.table.style": ["lines": "grid"],
        "writer.image.setWidth": ["image": "1", "width": 50],
        "writer.image.caption": ["image": "1"],
        "writer.image.delete": ["image": "1"],
        "writer.figure.read": ["image": "1"],
        "writer.formula.edit": ["formula": "1", "latex": "E = m c^3"],
        "writer.plot.insert": ["formula": "1"],
        "writer.columns.break": ["section": "1"],
        "writer.columns.remove": ["section": "1"],
    ]

    /// Actions that work on the open document: it is opened first.
    static let needsOpen: Set<String> = [
        "writer.caret.set", "writer.find.next", "writer.find.previous", "writer.jump.bookmark", "writer.jump.comment",
        "writer.jump.heading", "writer.select", "writer.select.all", "writer.selection.get", "writer.view.highlight",
        "writer.view.panel", "writer.view.reveal", "writer.view.tab",
    ]

    /// Values that depend on the copy: its comment, two of its blocks, the fixture's source.
    private func dynamicValues(_ copy: String, open: Bool) async -> [String: JSONValue] {
        if open { _ = try? await h.call("writer.doc.open", ["doc": .string(copy)]) }
        var values: [String: JSONValue] = [:]
        if let comment = try? await h.call("writer.comments.list", ["doc": .string(copy)])["comments"]?.arrayValue?.first?["id"] {
            values["$comment"] = comment
        }
        let blocks = (try? await h.call("writer.blocks.list", ["doc": .string(copy)])["blocks"]?.arrayValue) ?? []
        let paragraphs = blocks.filter { $0["type"]?.stringValue == "paragraph" }
        if paragraphs.count >= 2 {
            values["$blockA"] = paragraphs[0]["id"]
            values["$blockB"] = paragraphs[1]["id"]
        }
        if let key = WriterFixture.citekey { values["$citekey"] = .string(key) }
        return values
    }

    /// Schema-made arguments: the document, every required parameter, and the hints.
    static func arguments(for descriptor: ActionDescriptor, doc: String, picture: String, dynamic: [String: JSONValue] = [:]) -> [String: JSONValue] {
        var args: [String: JSONValue] = [:]
        let properties = descriptor.input.properties ?? [:]
        if properties["doc"] != nil { args["doc"] = .string(doc) }
        // Most changes need a place; the fixture has this word once.
        if properties["match"] != nil, properties["all"] != nil, descriptor.kind == .write, !descriptor.id.hasPrefix("writer.table."),
           !descriptor.id.hasPrefix("writer.doc.") {
            args["match"] = "Wasserkreislauf"
        }
        for key in descriptor.input.required ?? [] where args[key] == nil {
            if let schema = properties[key] { args[key] = sample(key, schema, picture: picture) }
        }
        for (key, value) in hints[descriptor.id]?.objectValue ?? [:] where properties[key] != nil {
            if let name = value.stringValue, name.hasPrefix("$") {
                args[key] = dynamic[name]
            } else {
                args[key] = value
            }
        }
        return args
    }

    static func sample(_ name: String, _ schema: JSONSchema, picture: String) -> JSONValue {
        if let values = schema.enumValues, let first = values.first { return .string(first) }
        switch schema.type {
        case "string": return value(for: name, picture: picture) ?? "Neuer Text"
        case "integer": return .int(Int(Swift.max(schema.minimum ?? 1, Swift.min(1, schema.maximum ?? 1))))
        case "number": return .double(Swift.max(schema.minimum ?? 1, Swift.min(1, schema.maximum ?? 1)))
        case "boolean": return true
        case "array":
            switch schema.items?.type {
            case "string": return ["A", "B"]
            case "integer", "number": return [1, 2]
            default: return []
            }
        case "object": return [:]
        default: return "Neuer Text"
        }
    }

    private enum Outcome {
        case success(JSONValue)
        case failure(RPCError)
    }

    private func attempt(_ id: String, _ args: [String: JSONValue], channel: ActionChannel = .cli) async -> Outcome {
        do {
            return .success(try await h.call(id, .object(args), channel: channel))
        } catch let error as RPCError {
            return .failure(error)
        } catch {
            return .failure(RPCError.internal("Kein RPCError: \(error)"))
        }
    }

    private var snapshot: [WriterDocument] { h.app.documents }

    /// An error that only says the call was poorly made, or names what isn't there.
    private func checkCleanError(_ error: RPCError, _ id: String, _ note: String) {
        if error.code == RPCError.internalErrorCode {
            Issue.record("\(id) (\(note)): interner Fehler „\(error.message)“")
        }
        if error.message.contains("passen nicht") {
            Issue.record("\(id) (\(note)): Schema nimmt an, was die Action nicht lesen kann: „\(error.message)“")
        }
    }

    @Test func everyWriterActionKeepsTheRules() async throws {
        let picture = try WriterFixture.picture().path
        _ = try await WriterFixture.masterID(h)
        var report: [String] = []
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("Vertragsexport-\(UUID().uuidString)", isDirectory: true)
        ActionExportFolder.set(folder, settings: h.app.settings)
        defer { ActionExportFolder.set(nil, settings: h.app.settings) }

        for descriptor in h.registry.descriptors where descriptor.module == "writer" {
            let id = descriptor.id
            if let reason = Self.skipped[id] {
                report.append("\(id) | übersprungen | \(reason)")
                continue
            }
            let copy = try await WriterFixture.copy(h)
            defer { WriterFixture.drop(copy, h) }
            let dynamic = await dynamicValues(copy, open: Self.needsOpen.contains(id))
            let args = Self.arguments(for: descriptor, doc: copy, picture: picture, dynamic: dynamic)
            let before = snapshot
            let groupsBefore = h.registry.undoStack.done.count

            switch await attempt(id, args) {
            case .failure(let error):
                checkCleanError(error, id, "Grundaufruf")
                if snapshot != before { Issue.record("\(id): Fehler \(error.code), aber Dokumente geändert") }
                report.append("\(id) | Fehler \(error.code) | \(error.message.prefix(90)) | Schema: \((descriptor.input.properties ?? [:]).keys.sorted().joined(separator: ","))")
            case .success(let result):
                let after = snapshot
                let changed = after != before
                report.append("\(id) | ok | \(changed ? "geändert" : "unverändert")")
                if descriptor.kind == .read, changed { Issue.record("\(id): Lese-Action hat Dokumente geändert") }
                if descriptor.kind == .write, changed {
                    // The returned version is the text's.
                    if result["doc"]?.stringValue == copy, let version = result["version"]?.stringValue,
                       let document = h.app.document(UUID(uuidString: copy)!), !document.isPresentation {
                        #expect(version == ActionVersion.of(document.markdown), "\(id): version passt nicht zum Text")
                    }
                    if id == "writer.doc.confirmReviewed" {
                        // The person's word: an agent's undo must not take it back. Noted, not an error.
                        report.append("\(id) | Hinweis | ändert die Herkunft ohne Undo-Schritt")
                    } else if h.registry.undoStack.done.count != groupsBefore + 1 || h.registry.undoStack.done.last?.label != id {
                        Issue.record("\(id): Änderung ohne eigenen Undo-Schritt")
                    } else {
                        _ = try h.registry.undoStack.undo()
                        if snapshot != before { Issue.record("\(id): Undo stellt den alten Stand nicht wieder her") }
                        _ = try h.registry.undoStack.redo()
                        if snapshot != after { Issue.record("\(id): Redo stellt die Änderung nicht wieder her") }
                    }
                }
            }

            let properties = descriptor.input.properties ?? [:]

            // A stale version changes nothing.
            if properties["ifVersion"] != nil {
                let fresh = try await WriterFixture.copy(h)
                defer { WriterFixture.drop(fresh, h) }
                var stale = Self.arguments(for: descriptor, doc: fresh, picture: picture, dynamic: await dynamicValues(fresh, open: Self.needsOpen.contains(id)))
                stale["ifVersion"] = "0"
                let state = snapshot
                switch await attempt(id, stale) {
                case .success: Issue.record("\(id): lief trotz veraltetem ifVersion")
                case .failure(let error):
                    checkCleanError(error, id, "ifVersion")
                    if error.code != RPCError.versionConflictCode {
                        report.append("\(id) | ifVersion → \(error.code) statt Versionskonflikt | \(error.message.prefix(60))")
                    }
                }
                if snapshot != state { Issue.record("\(id): veraltetes ifVersion hat trotzdem geändert") }
            }

            // An unknown parameter is an error, not an ignored instruction.
            var unknown = args
            unknown["gibtsNicht"] = 1
            if case .failure(let error) = await attempt(id, unknown) {
                if error.code != RPCError.invalidParamsCode { Issue.record("\(id): unbekannter Parameter gab \(error.code)") }
            } else {
                Issue.record("\(id): unbekannter Parameter wurde angenommen")
            }

            // Every required parameter is required.
            for key in descriptor.input.required ?? [] {
                var without = args
                without[key] = nil
                if case .failure(let error) = await attempt(id, without) {
                    if error.code != RPCError.invalidParamsCode { Issue.record("\(id): ohne „\(key)“ kam \(error.code)") }
                } else {
                    Issue.record("\(id): lief ohne Pflichtparameter „\(key)“")
                }
            }

            // A document that isn't there.
            if properties["doc"] != nil {
                var missing = args
                missing["doc"] = "00000000-0000-0000-0000-000000000000"
                if case .failure(let error) = await attempt(id, missing) {
                    checkCleanError(error, id, "fehlendes Dokument")
                }
            }

            // Over MCP, what an agent changed is foreign.
            if descriptor.kind == .write {
                let other = try await WriterFixture.copy(h)
                defer { WriterFixture.drop(other, h) }
                let state = snapshot
                let otherArgs = Self.arguments(for: descriptor, doc: other, picture: picture, dynamic: await dynamicValues(other, open: Self.needsOpen.contains(id)))
                if case .success = await attempt(id, otherArgs, channel: .mcp),
                   snapshot != state {
                    let changed = h.app.documents.filter { document in
                        guard let old = state.first(where: { $0.id == document.id }) else { return true }
                        return old != document
                    }
                    for document in changed where document.provenance != .foreign {
                        Issue.record("\(id): über MCP geändertes Dokument hat Herkunft \(document.provenance?.rawValue ?? "keine")")
                    }
                }
            }
        }
        if !WriterFixture.missing.isEmpty { report.insert("Fixtur unvollständig: \(WriterFixture.missing.joined(separator: "; "))", at: 0) }
        if let path = ProcessInfo.processInfo.environment["LLMD_TEST_REPORT"] {
            try report.joined(separator: "\n").write(toFile: path, atomically: true, encoding: .utf8)
        }
    }
}
}
