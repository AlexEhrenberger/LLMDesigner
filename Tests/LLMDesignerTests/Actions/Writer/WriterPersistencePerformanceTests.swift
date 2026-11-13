import Testing
import Foundation
import LLMDProtocol
@testable import LLMDesigner

/// T6: what is stored comes back. T7: how long the actions take on long texts (only with `LLMD_PERF=1`, so the usual
/// run stays short; the numbers go to `LLMD_TEST_REPORT` if set).
extension ActionSuites {
@MainActor
@Suite("Writer-Speichern und Tempo (T6/T7)", .serialized)
struct WriterPersistencePerformanceTests {
    let h = ActionHarness()

    /// The dates are written to the second; everything else must be exact.
    private func comparable(_ document: WriterDocument) -> WriterDocument {
        var copy = document
        copy.createdAt = Date(timeIntervalSince1970: 0)
        copy.updatedAt = Date(timeIntervalSince1970: 0)
        return copy
    }

    private func reloaded(_ id: String) throws -> WriterDocument {
        h.app.savePendingDocuments()
        let file = WriterDocumentStore.defaultDirectory.appendingPathComponent("\(id).md")
        return try #require(WriterDocumentStore.decode(try String(contentsOf: file, encoding: .utf8), fallbackID: nil))
    }

    // MARK: T6

    @Test func everyStoredFieldComesBack() async throws {
        let id = try await WriterFixture.copy(h)
        let picture = try WriterFixture.picture().path
        for action in ["writer.page.format", "writer.page.setup", "writer.page.runningHeads", "writer.doc.font", "writer.toc.setMode", "writer.doc.move"] {
            guard let descriptor = h.registry.descriptor(action) else { continue }
            _ = try? await h.call(action, .object(WriterContractTests.arguments(for: descriptor, doc: id, picture: picture)))
        }
        try await h.call("writer.text.insert", ["doc": .string(id), "text": "Von außen."], channel: .mcp)
        let memory = try #require(h.app.document(UUID(uuidString: id)!))
        #expect(memory.provenance == .foreign)
        #expect(comparable(try reloaded(id)) == comparable(memory))
    }

    static let titles = ["Titel: mit Doppelpunkt", "---", " Leer am Rand ", "Emoji 👍🏽", "id: 00000000-0000-0000-0000-000000000000",
                         "herkunft: eigen", "a\r\nherkunft: eigen", "Zeile\u{2028}Trenner"]

    @Test(arguments: titles)
    func aTitleCannotChangeTheHeader(title: String) async throws {
        let id = try await h.document("Inhalt")
        try await h.call("writer.text.insert", ["doc": .string(id), "text": "Fremd."], channel: .mcp)
        try await h.call("writer.doc.rename", ["doc": .string(id), "title": .string(title)])
        let memory = try #require(h.app.document(UUID(uuidString: id)!))
        let back = try reloaded(id)
        #expect(back.id == memory.id)
        #expect(back.provenance == .foreign, "Titel \(title.debugDescription) hat die Herkunft geändert")
        #expect(back.title == memory.title, "\(back.title.debugDescription) statt \(memory.title.debugDescription)")
    }

    @Test func aBodyThatLooksLikeAHeaderStaysBody() async throws {
        let body = "---\nid: 00000000-0000-0000-0000-000000000000\nherkunft: eigen\n---\n\nText"
        let id = try await h.document(body)
        try await h.call("writer.text.insert", ["doc": .string(id), "text": "Fremd."], channel: .mcp)
        let back = try reloaded(id)
        #expect(back.id.uuidString == id)
        #expect(back.provenance == .foreign)
        #expect(back.markdown.hasPrefix("---\nid: 0000"))
    }

    /// S5: a document that can't be written says so, and an agent's change isn't reported as done.
    @Test func aFailedSaveIsShownAndTheActionTakenBack() async throws {
        let id = try await h.document("Eins")
        let uuid = try #require(UUID(uuidString: id))
        h.app.savePendingDocuments()
        let file = WriterDocumentStore.defaultDirectory.appendingPathComponent("\(id).md")
        // A folder where the file belongs: this one file can't be written, nothing else is touched.
        try FileManager.default.removeItem(at: file)
        try FileManager.default.createDirectory(at: file, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: file) }

        #expect(await h.errorCode("writer.text.insert", ["doc": .string(id), "text": "Zwei"]) == RPCError.unavailableCode)
        #expect(h.trimmed(id) == "Eins")
        #expect(h.app.documentSaveErrors[uuid]?.contains("konnte nicht gespeichert werden") == true)
        // Typing in the editor saves after a pause; that failure shows as well.
        h.app.updateDocument(uuid, markdown: "Eins getippt\n")
        h.app.saveDocument(uuid)
        #expect(h.app.documentSaveErrors[uuid] != nil)

        // Once it can be written again, the next save goes through and the notice goes.
        try FileManager.default.removeItem(at: file)
        try await h.call("writer.text.insert", ["doc": .string(id), "text": "Zwei"])
        #expect(h.app.documentSaveErrors[uuid] == nil)
        #expect(try String(contentsOf: file, encoding: .utf8).contains("Zwei"))
    }

    // MARK: T7

    /// A neutral long text: chapters, sections, paragraphs and lists, about 3 000 characters a page.
    static func longText(pages: Int) -> String {
        let words = ["Wasser", "Kreislauf", "Wolke", "Regen", "Fluss", "Meer", "Sonne", "Wärme", "Dampf", "Boden", "Quelle", "See",
                     "fließt", "steigt", "fällt", "verdunstet", "sammelt", "kühlt", "langsam", "schnell", "wieder", "dann"]
        var seed: UInt64 = 42
        func next() -> Int {
            seed = seed &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            return Int(seed >> 33)
        }
        func sentence() -> String {
            let count = 8 + next() % 10
            var parts = (0..<count).map { _ in words[next() % words.count] }
            parts[0] = parts[0].prefix(1).uppercased() + parts[0].dropFirst()
            return parts.joined(separator: " ") + "."
        }
        var blocks: [String] = []
        for page in 0..<pages {
            if page % 10 == 0 { blocks.append("# Kapitel \(page / 10 + 1)") }
            if page % 3 == 0 { blocks.append("## Abschnitt \(page + 1)") }
            for _ in 0..<4 { blocks.append((0..<5).map { _ in sentence() }.joined(separator: " ")) }
            if page % 5 == 0 { blocks.append("- \(sentence())\n- \(sentence())") }
        }
        blocks.append("Das Schlusswort steht am Ende.")
        return blocks.joined(separator: "\n\n")
    }

    private func measure(_ label: String, _ body: () async throws -> Void) async rethrows -> Double {
        let clock = ContinuousClock()
        let start = clock.now
        try await body()
        let elapsed = clock.now - start
        let ms = Double(elapsed.components.seconds) * 1000 + Double(elapsed.components.attoseconds) / 1e15
        return ms
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["LLMD_PERF"] == "1"), arguments: [10, 100, 400])
    func actionsOnLongTexts(pages: Int) async throws {
        let markdown = Self.longText(pages: pages)
        var rows: [String] = ["\(pages) Seiten, \(markdown.count) Zeichen"]
        var id = ""
        rows.append("doc.create | \(try await measure("") { id = try await h.document(markdown) })")
        let doc = JSONValue.string(id)
        var blocks: [JSONValue] = []
        rows.append("blocks.list | \(try await measure("") { blocks = try #require(try await h.call("writer.blocks.list", ["doc": doc])["blocks"]?.arrayValue) })")
        rows.append("doc.read | \(try await measure("") { try await h.call("writer.doc.read", ["doc": doc]) })")
        rows.append("doc.read plain | \(try await measure("") { try await h.call("writer.doc.read", ["doc": doc, "format": "plain"]) })")
        rows.append("find | \(try await measure("") { try await h.call("writer.find", ["doc": doc, "query": "Schlusswort"]) })")
        rows.append("format.bold match (Ende) | \(try await measure("") { try await h.call("writer.format.bold", ["doc": doc, "match": "Schlusswort", "state": "on"]) })")
        // The next call finds the unchanged blocks converted already.
        rows.append("format.bold match (2. Aufruf) | \(try await measure("") { try await h.call("writer.format.bold", ["doc": doc, "match": "Schlusswort", "state": "off"]) })")
        let last = try #require(try await h.call("writer.blocks.list", ["doc": doc])["blocks"]?.arrayValue?.last?["id"])
        _ = blocks
        rows.append("format.italic block | \(try await measure("") { try await h.call("writer.format.italic", ["doc": doc, "block": last, "state": "on"]) })")
        rows.append("insertMarkdown Mitte | \(try await measure("") { try await h.call("writer.text.insertMarkdown", ["doc": doc, "heading": .string("Abschnitt \(pages / 2 / 3 * 3 + 1)"), "markdown": "Neu **hier**."]) })")
        rows.append("replaceAll | \(try await measure("") { try await h.call("writer.text.replaceAll", ["doc": doc, "find": "Wolke", "replace": "Nebel"]) })")
        rows.append("edit.undo | \(try await measure("") { try await h.call("writer.edit.undo", ["doc": doc]) })")
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("Tempo-\(UUID().uuidString)", isDirectory: true)
        ActionExportFolder.set(folder, settings: h.app.settings)
        defer { ActionExportFolder.set(nil, settings: h.app.settings) }
        rows.append("export markdown | \(try await measure("") { try await h.call("writer.export", ["doc": doc, "format": "markdown"]) })")
        rows.append("speichern | \(try await measure("") { h.app.saveDocument(UUID(uuidString: id)!) })")

        // A table of 100 rows and 20 columns.
        let header = "| " + (1...20).map { "S\($0)" }.joined(separator: " | ") + " |\n|" + String(repeating: "---|", count: 20)
        let body = (1...100).map { row in "| " + (1...20).map { "\(row * $0)" }.joined(separator: " | ") + " |" }.joined(separator: "\n")
        let table = try await h.document(markdown + "\n\n" + header + "\n" + body)
        rows.append("table.cell.set | \(try await measure("") { try await h.call("writer.table.cell.set", ["doc": .string(table), "cell": "T100", "text": "0"]) })")
        rows.append("table.read | \(try await measure("") { try await h.call("writer.table.read", ["doc": .string(table)]) })")

        let report = rows.joined(separator: "\n")
        print("TEMPO\n" + report)
        if let path = ProcessInfo.processInfo.environment["LLMD_TEST_REPORT"] {
            let old = (try? String(contentsOfFile: path, encoding: .utf8)) ?? ""
            try (old + "\n\n" + report).write(toFile: path, atomically: true, encoding: .utf8)
        }
    }
}
}
