import Testing
import AppKit
import LLMDProtocol
@testable import LLMDesigner

/// T2 and T3: where an action lands, and whether text survives the way through Markdown.
extension ActionSuites {
@MainActor
@Suite("Writer-Adressen und Markdown (T2/T3)", .serialized)
struct WriterAddressingTests {
    let h = ActionHarness()

    private func blocks(_ id: String) async throws -> [JSONValue] {
        try #require(try await h.call("writer.blocks.list", ["doc": .string(id)])["blocks"]?.arrayValue)
    }

    private func plain(_ id: String) async throws -> String {
        try #require(try await h.call("writer.doc.read", ["doc": .string(id), "format": "plain"])["text"]?.stringValue)
    }

    // MARK: T3 – text that looks like Markdown

    /// Texts a person types that look like Markdown. Each must come back as typed, as one paragraph.
    static let lookalikes = [
        "[1] Müller, Quelle", "[Anmerkung] Text dazu", "# kein Titel", "1. kein Listenpunkt", "- kein Punkt", "+ kein Punkt",
        "> kein Zitat", "::: kein Kasten", "$$ keine Formel", "Preis $5 und $6", "| a | b |", "Pfad C:\\Programme\\Neu",
        "<span id=\"x\">kein Lesezeichen</span>", "```kein Code", "~~~ auch kein Code", "*Sternchen* und _Unterstrich_",
        "Fußnote^[nicht]", "[@schluessel] ist kein Beleg", "---", "***", "\\[ x \\]", "{.chapter}", "![kein Bild](x.png)",
        "<!-- kein Kommentar -->", "&amp; Entität", "Emoji 👍🏽 und e\u{301}", "Ende mit Backslash \\",
    ]

    /// Through the editor's own conversion: what the person typed, saved as Markdown, read again.
    @Test(arguments: lookalikes)
    func typedTextSurvivesTheEditorRoundTrip(text: String) {
        let markdown = WriterMarkdown.markdown(from: NSAttributedString(string: text))
        let back = WriterMarkdown.attributedString(from: markdown).string.trimmingCharacters(in: .newlines)
        #expect(back == text, "gespeichert als \(markdown.debugDescription)")
        #expect(PowerText.chunks(of: markdown + "\n\nDanach").count == 2, "\(markdown.debugDescription) frisst den nächsten Block")
        // Also after a space and on the second line of a paragraph.
        let indented = WriterMarkdown.markdown(from: NSAttributedString(string: "Zeile\u{2028}  " + text))
        #expect(WriterMarkdown.attributedString(from: indented).string.contains(text), "eingerückt gespeichert als \(indented.debugDescription)")
    }

    /// What earlier versions saved for "[1] Müller" opens as text again.
    @Test(arguments: ["\\[1\\] Müller, Quelle", "\\[Anmerkung\\] Text dazu", "\\[@schluessel\\] ist kein Beleg"])
    func anOldEscapedBracketOpensAsText(markdown: String) {
        let text = WriterMarkdown.attributedString(from: markdown).string.trimmingCharacters(in: .newlines)
        #expect(text == markdown.replacingOccurrences(of: "\\", with: ""))
        #expect(PowerText.chunks(of: markdown + "\n\nDanach").count == 2)
    }

    @Test func displayMathStillWorks() {
        for markdown in ["\\[ x^2 \\]", "\\[\nx^2\n\\]", "$$\nx^2\n$$", "$$x^2$$"] {
            let chunks = PowerText.chunks(of: markdown + "\n\nDanach")
            #expect(chunks.count == 2 && chunks.first?.kind == .math, "\(markdown.debugDescription) → \(chunks.map(\.kind))")
            #expect(WriterMarkdown.attributedString(from: markdown).string.contains("\u{FFFC}"), "\(markdown.debugDescription) ist keine Formel")
        }
        // A model's answer in the chat uses the same parser.
        #expect(MarkdownParser.parse("Davor\n\n\\[ E = mc^2 \\]\n\nDanach").contains { if case .math = $0 { true } else { false } })
    }

    @Test func aBracketAtTheStartIsNeitherCitationNorContents() {
        for text in ["[@schluessel] ist kein Beleg", "[TOC]", "[TOC]{.dynamic}", "[x](https://example.org) kein Verweis"] {
            let markdown = WriterMarkdown.markdown(from: NSAttributedString(string: text))
            #expect(WriterTOCAttachment.kind(in: markdown) == nil, "\(markdown.debugDescription)")
            let back = WriterMarkdown.attributedString(from: markdown)
            #expect(back.string.trimmingCharacters(in: .newlines) == text, "\(markdown.debugDescription)")
            var link = false
            back.enumerateAttribute(.link, in: NSRange(location: 0, length: back.length)) { value, _, _ in if value != nil { link = true } }
            #expect(!link, "\(markdown.debugDescription) wurde ein Verweis")
        }
    }

    /// Through the actions: the text is one block, and the paragraph after it can still be found.
    @Test(arguments: lookalikes)
    func insertedTextStaysOneBlock(text: String) async throws {
        let id = try await h.document("Vorher")
        try await h.call("writer.text.insert", ["doc": .string(id), "text": .string(text)])
        try await h.call("writer.text.insert", ["doc": .string(id), "text": "Nachher"])
        let count = try await blocks(id).count
        let read = try await plain(id)
        #expect(count == 3, "Text: \(text.debugDescription) → \(h.text(id).debugDescription)")
        // Still addressable after it.
        #expect(await h.errorCode("writer.format.bold", ["doc": .string(id), "match": "Nachher", "state": "on"]) == nil)
        #expect(read.contains(text), "Text: \(text.debugDescription) → gelesen \(read.debugDescription)")
    }

    @Test func aLongFenceHoldsAShortOne() async throws {
        let id = try await h.document("````markdown\n```swift\nlet a = 1\n```\n````\n\nDanach")
        let count = try await blocks(id).count
        #expect(count == 2, "\(h.text(id).debugDescription)")
        #expect(await h.errorCode("writer.format.bold", ["doc": .string(id), "match": "Danach", "state": "on"]) == nil)
    }

    @Test func aChangeLeavesTheRestAsWritten() async throws {
        let original = "Eins\n\n\n\nZwei  \nmit Umbruch\n\n* Stern\n* Liste\n\nDrei"
        let id = try await h.document(original)
        try await h.call("writer.format.bold", ["doc": .string(id), "match": "Drei", "state": "on"])
        // Runs of blank lines become one, which reads the same; nothing else may change.
        let expected = original.replacingOccurrences(of: "Drei", with: "**Drei**").replacingOccurrences(of: "\n\n\n\n", with: "\n\n")
        #expect(h.trimmed(id) == expected, "→ \(h.text(id).debugDescription)")
    }

    @Test func objectsInColumnsAndBoxesCanBeReached() async throws {
        let code = "```python\nx=1\n```"
        let inColumns = try await h.document("::: {.columns count=2}\n\(code)\n:::\n\nDanach")
        #expect(await h.errorCode("writer.code.format", ["doc": .string(inColumns)]) == nil, "Code in Spalten nicht gefunden")
        let inBox = try await h.document("::: {.box kind=hinweis}\n\(code)\n:::\n\nDanach")
        #expect(await h.errorCode("writer.code.format", ["doc": .string(inBox)]) == nil, "Code im Kasten nicht gefunden")
    }

    // MARK: T2 – addresses

    @Test func aMatchRunsThroughMarks() async throws {
        let id = try await h.document("Der Wasser**kreis**lauf.")
        try await h.call("writer.format.italic", ["doc": .string(id), "match": "Wasserkreislauf", "state": "on"])
        #expect(try await plain(id).contains("Wasserkreislauf"))
        #expect(h.text(id).contains("*"))
    }

    @Test func occurrencesAreCheckedNotGuessed() async throws {
        let id = try await h.document("Wort und Wort.\n\nNoch ein Wort.")
        #expect(await h.errorCode("writer.format.bold", ["doc": .string(id), "match": "Wort", "state": "on"]) == RPCError.ambiguousCode)
        #expect(await h.errorCode("writer.format.bold", ["doc": .string(id), "match": "Wort", "occurrence": 4, "state": "on"]) == RPCError.notFoundCode)
        try await h.call("writer.format.bold", ["doc": .string(id), "match": "Wort", "occurrence": 3, "state": "on"])
        #expect(h.trimmed(id) == "Wort und Wort.\n\nNoch ein **Wort**.")
        #expect(await h.errorCode("writer.format.bold", ["doc": .string(id), "match": "Wort", "block": "b0-x", "state": "on"]) == RPCError.invalidParamsCode)
        #expect(await h.errorCode("writer.format.bold", ["doc": .string(id), "match": "", "state": "on"]) == RPCError.invalidParamsCode)
    }

    @Test func headingPathsWalkTheLevels() async throws {
        let id = try await h.document("# Teil A\n\n## Einleitung\n\nA\n\n# Teil B\n\n## Einleitung\n\nB")
        #expect(await h.errorCode("writer.format.bold", ["doc": .string(id), "heading": "Einleitung", "state": "on"]) == RPCError.ambiguousCode)
        try await h.call("writer.text.insert", ["doc": .string(id), "heading": "teil b/einleitung", "text": " (zwei)"])
        #expect(h.text(id).contains("## Einleitung (zwei)\n\nB"))
        #expect(await h.errorCode("writer.format.bold", ["doc": .string(id), "heading": "Teil C", "state": "on"]) == RPCError.notFoundCode)
        #expect(await h.errorCode("writer.format.bold", ["doc": .string(id), "heading": " / ", "state": "on"]) != nil)
    }

    @Test func aStaleBlockIsAConflictNotAnotherPlace() async throws {
        let id = try await h.document("Eins\n\nZwei\n\nDrei")
        let third = try #require(try await blocks(id)[2]["id"]?.stringValue)
        try await h.call("writer.text.insertMarkdown", ["doc": .string(id), "markdown": "Null", "block": .string(try #require(try await blocks(id)[0]["id"]?.stringValue)), "position": "before"])
        #expect(try await blocks(id).count == 4)
        #expect(await h.errorCode("writer.format.bold", ["doc": .string(id), "block": .string(third), "state": "on"]) == RPCError.versionConflictCode)
    }

    /// Two equal blocks have the same fingerprint; after a block before them goes, the id of the first fits the second.
    @Test func anOldIdOfEqualBlocksDoesNotSlideOnToTheNext() async throws {
        let id = try await h.document("Weg\n\nGleich\n\nGleich\n\nEnde")
        let all = try await blocks(id)
        let first = try #require(all[1]["id"]?.stringValue)
        try await h.call("writer.text.delete", ["doc": .string(id), "block": .string(try #require(all[0]["id"]?.stringValue))])
        let code = await h.errorCode("writer.format.bold", ["doc": .string(id), "block": .string(first), "state": "on"])
        #expect(code == RPCError.versionConflictCode, "Alte ID traf: \(h.trimmed(id).debugDescription)")
    }

    @Test func rangesCountCharactersAsSwiftDoes() async throws {
        let id = try await h.document("A👍🏽B Ziel C")
        let text = h.text(id)
        let characters = text.distance(from: text.startIndex, to: text.range(of: "Ziel")!.lowerBound)
        try await h.call("writer.format.bold", ["doc": .string(id), "range": .string("\(characters):4"), "state": "on"])
        #expect(h.trimmed(id) == "A👍🏽B **Ziel** C")
        // A client that counts UTF-16 (JavaScript) or code points (Python) lands elsewhere; the schema has to say which.
        let description = WriterAddress.schemaProperties["range"]?.description ?? ""
        #expect(description.localizedCaseInsensitiveContains("Zeichen"), "Einheit nicht beschrieben: \(description)")
    }

    @Test func badRangesAreRefused() async throws {
        let id = try await h.document("Kurz")
        for range in ["5:10", "-1:2", "a:b", "1", "1:2:3", "99999999999999999999:1"] {
            #expect(await h.errorCode("writer.format.bold", ["doc": .string(id), "range": .string(range), "state": "on"]) == RPCError.invalidParamsCode, "\(range)")
        }
        let two = try await h.document("Eins\n\nZwei")
        #expect(await h.errorCode("writer.format.bold", ["doc": .string(two), "range": "0:9", "state": "on"]) == RPCError.invalidTargetCode)
    }

    @Test func anEmptyDocumentTakesTextButHasNoPlaces() async throws {
        let id = try await h.document("")
        #expect(await h.errorCode("writer.format.bold", ["doc": .string(id), "match": "x", "state": "on"]) == RPCError.notFoundCode)
        try await h.call("writer.text.insert", ["doc": .string(id), "text": "Jetzt"])
        #expect(h.trimmed(id) == "Jetzt")
    }

    // MARK: S3 – replace all

    @Test func replaceAllLeavesMarkupAlone() async throws {
        let picture = try WriterFixture.picture().path
        let id = try await h.document("Bilder sind schön. Ein [Verweis](https://example.org/Bilder).\n\n```\nBilder im Code\n```")
        try await h.call("writer.image.insert", ["doc": .string(id), "file": .string(picture)])
        let source = try #require(WriterImageStore.sources(in: h.text(id)).first)
        try await h.call("writer.text.replaceAll", ["doc": .string(id), "find": "Bilder", "replace": "Fotos"])
        #expect(WriterImageStore.sources(in: h.text(id)).first == source, "Bildpfad geändert: \(h.text(id))")
        #expect(h.text(id).contains("https://example.org/Bilder"), "URL geändert")
    }

    @Test func replaceAllFindsWhatTheReaderSees() async throws {
        let id = try await h.document("Der Wasser**kreis**lauf.")
        #expect(await h.errorCode("writer.text.replaceAll", ["doc": .string(id), "find": "Wasserkreislauf", "replace": "Kreislauf"]) == nil)
    }

    @Test func replaceAllCountsAndCanIgnoreCase() async throws {
        let id = try await h.document("Wort und wort.\n\n```\nWort im Code\n```\n\n$$\nWort\n$$")
        let exact = try await h.call("writer.text.replaceAll", ["doc": .string(id), "find": "Wort", "replace": "Begriff"])
        #expect(exact["count"]?.intValue == 1)
        try await h.call("writer.edit.undo", ["doc": .string(id)])
        let loose = try await h.call("writer.text.replaceAll", ["doc": .string(id), "find": "wort", "replace": "Begriff", "caseSensitive": false])
        #expect(loose["count"]?.intValue == 2)
        #expect(h.text(id).contains("Wort im Code") && h.text(id).contains("$$\nWort\n$$"), "Code oder Formel geändert: \(h.text(id))")
        #expect(await h.errorCode("writer.text.replaceAll", ["doc": .string(id), "find": "fehlt", "replace": "x"]) == RPCError.notFoundCode)
    }

    @Test func codeWithAFenceInItGetsALongerOne() async throws {
        let id = try await h.document("Davor")
        let code = "Ein Beispiel:\n```swift\nlet a = 1\n```"
        try await h.call("writer.code.insert", ["doc": .string(id), "language": "markdown", "code": .string(code)])
        #expect(try await blocks(id).count == 2)
        // The editor writes it the same way when the person types it.
        let edited = WriterReference.editorForm(h.text(id))
        #expect(PowerText.chunks(of: edited).count == 2, "\(edited.debugDescription)")
        #expect(edited.contains(code))
    }

    @Test func plainReadingShowsTextAsItReads() async throws {
        let id = try await h.document("| a | b |\n|---|---|\n| 1 | 2 |\n\n```\nlet x = a\\*b\n```\n\nPreis \\$5, \\*Stern\\*.")
        let read = try await plain(id)
        #expect(read.contains("a  ·  b"), "Tabelle: \(read)")
        #expect(read.contains("let x = a\\*b"), "Code verlor seinen Backslash: \(read)")
        #expect(read.contains("Preis $5, *Stern*."), "\(read)")
    }

    /// An agent takes a hit of writer.find and names it with match and occurrence: it has to land on that hit.
    @Test func aHitOfFindIsAnAddressForMatch() async throws {
        let original = "```\nWort im Code\n```\n\nEin wort klein.\n\nDas Wort hier, noch ein Wort."
        let id = try await h.document(original)
        let hits = try #require(try await h.call("writer.find", ["doc": .string(id), "query": "Wort"])["hits"]?.arrayValue)
        #expect(hits.count == 4)
        // In code there is no match address, only the block.
        #expect(hits[0]["match"] == nil && hits[0]["occurrence"] == nil && hits[0]["block"]?.stringValue?.hasPrefix("b0-") == true)
        let expected = ["Ein **wort** klein.", "Das **Wort** hier, noch ein Wort.", "Das Wort hier, noch ein **Wort**."]
        for (hit, result) in zip(hits.dropFirst(), expected) {
            let match = try #require(hit["match"])
            let occurrence = try #require(hit["occurrence"])
            try await h.call("writer.format.bold", ["doc": .string(id), "match": match, "occurrence": occurrence, "state": "on"])
            #expect(h.text(id).contains(result), "\(match) \(occurrence) → \(h.text(id).debugDescription)")
            try await h.call("writer.edit.undo", ["doc": .string(id)])
        }
        #expect(h.trimmed(id) == original)
    }

    @Test func uniqueBlocksKeepTheirIds() async throws {
        let id = try await h.document("Eins\n\nZwei")
        let ids = try await blocks(id).compactMap { $0["id"]?.stringValue }
        #expect(ids == ["b0-" + ActionVersion.of("Eins").prefix(6), "b1-" + ActionVersion.of("Zwei").prefix(6)])
    }

    @Test func replaceAllWritesTextNotMarkdown() async throws {
        let id = try await h.document("Ein Wort.")
        try await h.call("writer.text.replaceAll", ["doc": .string(id), "find": "Wort", "replace": "*Stern*"])
        let read = try await plain(id)
        #expect(read.contains("*Stern*"), "→ \(h.text(id))")
    }
}
}
