import Testing
import Foundation
import LLMDProtocol
@testable import LLMDesigner

extension ActionSuites {
@MainActor
@Suite("Data Studio: Actions", .serialized)
struct DataActionTests {
    let h = ActionHarness()

    private func block(_ key: String) -> DataBlock? { h.app.dataStudio.block(key: key) }

    @Test func blocksAreCreatedReadChangedAndDeleted() async throws {
        let name = "Absender \(UUID().uuidString.prefix(6))"
        let made = try await h.call("data.block.create", ["name": .string(name), "structure": "person", "values": ["vorname": "Mara", "ort": "Neustadt", "geburtsdatum": "03.02.2001"]])
        let key = try #require(made["key"]?.stringValue)
        #expect(made["placeholder"]?.stringValue == "{{\(key)}}")
        #expect(block(key)?.field("geburtsdatum")?.value == "2001-02-03")

        let list = try await h.call("data.block.list", ["query": .string(name)])
        #expect(list["blocks"]?[0]?["key"]?.stringValue == key)
        #expect(list["blocks"]?[0]?["fields"]?.arrayValue?.contains("vorname") == true)

        let read = try await h.call("data.block.read", ["block": .string(key)])
        #expect(read["fields"]?.arrayValue?.first { $0["key"] == "ort" }?["value"] == "Neustadt")
        #expect(read["composed"]?.stringValue?.contains("Mara") == true)

        try await h.call("data.field.set", ["block": .string(key), "field": "ort", "value": "Altstadt"])
        #expect(block(key)?.field("ort")?.value == "Altstadt")
        let added = try await h.call("data.field.set", ["block": .string(key), "values": ["Lieblingsfarbe": "Grün"]])
        #expect(added["created"]?.arrayValue == ["lieblingsfarbe"])
        try await h.call("writer.edit.undo")
        #expect(block(key)?.field("lieblingsfarbe") == nil)

        let resolved = try await h.call("data.resolve", ["text": .string("{{\(key).vorname}} aus {{\(key).ort}}, {{gibts.nicht}}")])
        #expect(resolved["text"]?.stringValue == "Mara aus Altstadt, {{gibts.nicht}}")
        #expect(resolved["missing"]?.arrayValue == ["{{gibts.nicht}}"])

        #expect(await h.errorCode("data.field.set", ["block": .string(key)]) == RPCError.invalidParamsCode)
        #expect(await h.errorCode("data.block.read", ["block": "kein-solcher-block"]) == RPCError.notFoundCode)

        try await h.call("data.block.delete", ["block": .string(key)])
        #expect(block(key) == nil)
        try await h.call("writer.edit.undo")
        #expect(block(key)?.field("vorname")?.value == "Mara")
    }

    @Test func readingValuesCountsAsPrivate() {
        let read = h.registry.descriptor("data.block.read")
        #expect(read?.security.sensitive == true)
        #expect(h.registry.descriptor("data.block.list")?.security.sensitive == false)
        #expect(h.registry.descriptor("data.block.delete")?.kind == .destructive)
    }

    @Test func aRenamedKeyRewritesDocuments() async throws {
        let made = try await h.call("data.block.create", ["name": .string("Kunde \(UUID().uuidString.prefix(6))"), "structure": "organisation", "values": ["firma": "Beispiel GmbH"]])
        let key = try #require(made["key"]?.stringValue)
        let doc = try await h.document("An {{\(key).firma}} und {{\(key)}}\n")
        let uses = try await h.call("data.block.usages", ["block": .string(key)])
        #expect(uses["uses"]?.arrayValue?.contains { $0["id"]?.stringValue == doc } == true)
        let newKey = "kunde-\(UUID().uuidString.prefix(4).lowercased())"
        let renamed = try await h.call("data.block.update", ["block": .string(key), "key": .string(newKey)])
        #expect(renamed["key"]?.stringValue == newKey)
        #expect(renamed["rewritten"]?.intValue ?? 0 >= 1)
        #expect(h.text(doc).contains("{{\(newKey).firma}}"))
        #expect(h.text(doc).contains("{{\(newKey)}}"))
    }

    @Test func templatesMakeDocumentsAndPresentations() async throws {
        let list = try await h.call("data.template.list", ["kind": "writer"])
        #expect(list["templates"]?.arrayValue?.contains { $0["name"] == "Brief (DIN 5008)" } == true)
        let read = try await h.call("data.template.read", ["template": "brief-din5008"])
        #expect(read["roles"]?.arrayValue?.count == 2)

        let me = try await h.call("data.block.create", ["name": .string("Ich \(UUID().uuidString.prefix(6))"), "structure": "person", "values": ["vorname": "Mara"]])
        let myKey = try #require(me["key"]?.stringValue)
        let letter = try await h.call("data.template.use", ["template": "Brief (DIN 5008)", "blocks": ["absender": .string(myKey)], "title": "Brief an die Bank"])
        let letterID = try #require(letter["id"]?.stringValue)
        #expect(h.text(letterID).contains("{{\(myKey).vorname}}"))
        #expect(letter["kind"] == "dokument")
        #expect(await h.errorCode("data.template.use", ["template": "brief-din5008", "blocks": ["gibtsnicht": .string(myKey)]]) == RPCError.invalidParamsCode)
        // The export puts the values in.
        let document = try #require(h.app.document(UUID(uuidString: letterID)!))
        let input = await h.app.prepareExport(of: document)
        #expect(input.markdown.contains("**Mara"))

        let copy = try await h.call("data.template.create", ["name": .string("Master \(UUID().uuidString.prefix(6))"), "from": "master-klar"])
        let masterID = try #require(copy["id"]?.stringValue)
        try await h.call("data.template.update", ["template": .string(masterID), "footer": "{{titel}} – {{folie}}", "logoCorner": "untenLinks"])
        #expect(h.app.dataStudio.template(UUID(uuidString: masterID)!)?.master.logoCorner == .untenLinks)
        #expect(await h.errorCode("data.template.update", ["template": "master-klar", "footer": "x"]) == RPCError.invalidTargetCode)

        let deck = try await h.call("data.template.use", ["template": .string(masterID), "title": "Vortrag"])
        let deckID = try #require(deck["id"]?.stringValue)
        let presentation = try #require(h.app.document(UUID(uuidString: deckID)!)?.deck)
        #expect(presentation.masterID?.uuidString == masterID)
        // The master survives saving and loading.
        let saved = WriterDocumentStore.encode(h.app.document(UUID(uuidString: deckID)!)!)
        #expect(WriterDocumentStore.decode(saved, fallbackID: nil)?.deck?.masterID?.uuidString == masterID)
        try await h.call("data.master.apply", ["doc": .string(deckID)])
        #expect(h.app.document(UUID(uuidString: deckID)!)?.deck?.masterID == nil)
        try await h.call("writer.edit.undo")
        #expect(h.app.document(UUID(uuidString: deckID)!)?.deck?.masterID?.uuidString == masterID)
    }
}
}

/// `result["blocks"]?[0]?["key"]`.
private extension JSONValue {
    subscript(index: Int) -> JSONValue? {
        guard let array = arrayValue, array.indices.contains(index) else { return nil }
        return array[index]
    }
}
