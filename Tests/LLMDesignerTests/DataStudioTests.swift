import Testing
import Foundation
import AppKit
@testable import LLMDesigner

@Suite("Data Studio: Kürzel, Platzhalter, Vorlagen")
struct DataStudioTests {
    @Test func keysAreMadeFromNames() {
        #expect(DataKey.make(from: "Straße und Hausnummer", fallback: "x") == "strasse-und-hausnummer")
        #expect(DataKey.make(from: "User 1", fallback: "x") == "user1")
        #expect(DataKey.make(from: "Meine Adresse", fallback: "x") == "meine-adresse")
        #expect(DataKey.make(from: "Empfänger", fallback: "x") == "empfaenger")
        #expect(DataKey.make(from: "!!!", fallback: "x") == "x")
        #expect(DataKey.unique("absender", taken: ["absender", "absender2"]) == "absender3")
    }

    @Test func tokensAreFoundAndReplaced() {
        let text = "Von {{absender.vorname}} an {{empfaenger}} – {{ kaputt.}} {{heute}} {{x.y.z}}"
        let refs = DataTokens.find(in: text).map(\.ref)
        #expect(refs == [DataRef(block: "absender", field: "vorname"), DataRef(block: "empfaenger"), DataRef(block: "heute")])
        let replaced = DataTokens.replace(in: text) { $0.block == "absender" ? "Mara" : nil }
        #expect(replaced.hasPrefix("Von Mara an {{empfaenger}}"))
    }

    @Test func aBlockComposesItsDisplayWithoutEmptyLines() {
        var block = DataBlock(name: "Absender", key: "absender", fields: DataStructure.person.fields, display: DataStructure.person.display)
        func set(_ key: String, _ value: String) { block.fields[block.fields.firstIndex { $0.key == key }!].value = value }
        set("vorname", "Mara")
        set("nachname", "Feld")
        set("strasse", "Lindenweg 3")
        set("plz", "12345")
        set("ort", "Neustadt")
        #expect(block.composed == "Mara Feld\nLindenweg 3\n12345 Neustadt")
        set("geburtsdatum", "2001-02-03")
        let resolver = DataResolver(blocks: [block])
        #expect(resolver.value(DataRef(block: "ABSENDER", field: "Geburtsdatum")) == "03.02.2001")
        #expect(resolver.value(DataRef(block: "absender", field: "fehlt")) == nil)
        #expect(resolver.value(DataRef(block: "heute", field: "iso")) == DataDay.string(Date()))
        #expect(resolver.resolve("{{absender.ort}}, {{nix.da}}") == "Neustadt, {{nix.da}}")
        // A multi-line value stays in one paragraph and gets no Markdown meaning at line starts.
        set("titel", "# Dr.")
        #expect(DataResolver(blocks: [block]).resolveMarkdown("{{absender}}").contains("\\# Dr. Mara Feld\nLindenweg 3"))
    }

    @Test func blocksAndTemplatesKeepTheirGermanKeys() throws {
        var block = DataBlock(name: "Bank", key: "bank", fields: [DataField(key: "iban", name: "IBAN", value: "DE00 0000")])
        block.group = "Bank"
        // The file keeps whole seconds.
        block.createdAt = Date(timeIntervalSince1970: 1_800_000_000)
        block.updatedAt = block.createdAt
        let store = RecordStore<DataBlock>(directory: FileManager.default.temporaryDirectory, root: "datenblock")
        let json = try #require(String(data: try store.encode(block), encoding: .utf8))
        #expect(json.contains("\"datenblock\""))
        #expect(json.contains("\"kuerzel\" : \"bank\""))
        #expect(json.contains("\"wert\" : \"DE00 0000\""))
        #expect(try store.decode(Data(json.utf8)) == block)

        let templates = RecordStore<DataTemplate>(directory: FileManager.default.temporaryDirectory, root: "vorlage", layout: .folder("vorlage"))
        let letter = DataTemplate.letter
        let decoded = try templates.decode(try templates.encode(letter))
        #expect(decoded.slots.map(\.key) == ["absender", "empfaenger"])
        #expect(decoded.markdown == letter.markdown)
    }

    @Test func templatesFillTheirRoles() {
        let filled = DataTemplate.letter.markdown(filling: ["absender": "ich"])
        #expect(filled.contains("{{ich.strasse}}"))
        #expect(filled.contains("{{empfaenger}}"))
        #expect(filled.contains("{{heute}}"))
    }

    @MainActor
    @Test func writerReadsAndWritesDataFields() {
        let markdown = "Liebe Grüße aus {{absender.ort}} und **{{heute}}**."
        let text = WriterMarkdown.attributedString(from: markdown)
        var fields: [DataRef] = []
        text.enumerateAttribute(.attachment, in: NSRange(location: 0, length: text.length)) { value, _, _ in
            if let field = value as? WriterDataFieldAttachment { fields.append(field.ref) }
        }
        #expect(fields == [DataRef(block: "absender", field: "ort"), DataRef(block: "heute")])
        #expect(WriterMarkdown.markdown(from: text).trimmingCharacters(in: .whitespacesAndNewlines) == markdown)
    }
}
