import Testing
import AppKit
import LLMDProtocol
@testable import LLMDesigner

extension ActionSuites {
@MainActor
@Suite("Citation: Schlagworte, Ordner, Zusammenführen, BibTeX", .serialized)
struct CitationMoreActionTests {
    let h = ActionHarness()

    private func source(_ title: String = "Titel \(UUID().uuidString)", extra: [String: JSONValue] = [:]) async throws -> String {
        var args: [String: JSONValue] = ["type": "article", "title": .string(title), "authors": ["Muster, Erika"], "year": 2020, "allowDuplicate": true]
        args.merge(extra) { $1 }
        return try #require(try await h.call("citation.source.create", .object(args))["citekey"]?.stringValue)
    }

    private func quote(_ key: String, _ text: String = "Ein Satz.") async throws -> String {
        try #require(try await h.call("citation.quote.add", ["source": .string(key), "exactText": .string(text)])["id"]?.stringValue)
    }

    private var library: CitationLibrary { h.app.citations }

    @Test func tagsOfSourcesAndQuotes() async throws {
        let tag = "thema\(UUID().uuidString.prefix(6))"
        let key = try await source()
        try await h.call("citation.source.tag", ["source": .string(key), "add": .array([.string(tag), "weg"])])
        try await h.call("citation.source.tag", ["source": .string(key), "remove": ["weg"]])
        #expect(library.source(citekey: key)?.tags == [tag])
        let id = try await quote(key)
        try await h.call("citation.quote.tag", ["quote": .string(id), "add": .array([.string(tag)])])

        let counted = try await h.call("citation.tags.list")
        #expect(counted["tags"]?.arrayValue?.first { $0["tag"] == .string(tag) }?["count"] == 2)
        let quotes = try await h.call("citation.tags.list", ["shelf": "quotes"])
        #expect(quotes["tags"]?.arrayValue?.first { $0["tag"] == .string(tag) }?["count"] == 1)

        try await h.call("writer.edit.undo")
        #expect(library.quote(UUID(uuidString: id)!)?.tags == [])
    }

    @Test func linksBetweenQuotes() async throws {
        let key = try await source()
        let first = try await quote(key, "Eins"), second = try await quote(key, "Zwei")
        try await h.call("citation.quote.link", ["quote": .string(first), "with": .string(second)])
        let linked = try await h.call("citation.quote.linked", ["quote": .string(first)], run: "verknuepft")
        #expect(linked["quotes"]?.arrayValue?.first?["exactText"] == "Zwei")
        #expect(h.registry.runState(id: "verknuepft", channel: .cli).hasReadUntrusted)
        #expect(await h.errorCode("citation.quote.link", ["quote": .string(first), "with": .string(first)]) == RPCError.invalidParamsCode)
        try await h.call("citation.quote.unlink", ["quote": .string(first), "from": .string(second)])
        #expect((try await h.call("citation.quote.linked", ["quote": .string(first)]))["quotes"] == [])
    }

    @Test func groupsAndFolders() async throws {
        let suffix = UUID().uuidString.prefix(6)
        let group = try await h.call("citation.group.add", ["shelf": "sources", "name": .string("Gruppe \(suffix)")])
        let groupID = try #require(group["id"]?.stringValue)
        let folder = try await h.call("citation.folder.add", ["group": .string("Gruppe \(suffix)"), "name": .string("Ordner \(suffix)")])
        let folderID = try #require(folder["id"]?.stringValue)
        var list = try await h.call("citation.collections.list", ["shelf": "sources"])
        var entry = list["groups"]?.arrayValue?.first { $0["id"] == .string(groupID) }
        #expect(entry?["folders"]?.arrayValue?.first?["name"] == .string("Ordner \(suffix)"))

        try await h.call("citation.group.rename", ["group": .string(groupID), "name": .string("Neu \(suffix)")])
        try await h.call("citation.folder.rename", ["folder": .string(folderID), "name": .string("Fach \(suffix)")])
        let second = try await h.call("citation.group.add", ["shelf": "sources", "name": .string("Zweite \(suffix)")])
        try await h.call("citation.folder.move", ["folder": .string("Fach \(suffix)"), "group": .string(try #require(second["id"]?.stringValue))])
        list = try await h.call("citation.collections.list", ["shelf": "sources"])
        entry = list["groups"]?.arrayValue?.first { $0["id"] == second["id"] }
        #expect(entry?["folders"]?.arrayValue?.first?["name"] == .string("Fach \(suffix)"))
        #expect(await h.errorCode("citation.folder.move", ["folder": "Gibt es nicht", "group": .string(groupID)]) == RPCError.notFoundCode)

        let key = try await source()
        try await h.call("citation.source.move", ["source": .string(key), "folder": .string("Fach \(suffix)")])
        #expect(library.source(citekey: key)?.folderID?.uuidString == folderID)
        try await h.call("citation.source.move", ["source": .string(key)])
        #expect(library.source(citekey: key)?.folderID == nil)
        try await h.call("citation.source.move", ["source": .string(key), "folder": .string("Fach \(suffix)")])

        // Deleting a folder or a group keeps what was in them.
        try await h.call("citation.folder.delete", ["folder": .string(folderID)])
        #expect(library.source(citekey: key)?.folderID == nil)
        try await h.call("citation.group.delete", ["group": .string(groupID)])
        try await h.call("citation.group.delete", ["group": .string("Zweite \(suffix)")])
        #expect(await h.errorCode("citation.group.delete", ["group": .string(groupID)]) == RPCError.notFoundCode)

        let quoteGroup = try await h.call("citation.group.add", ["shelf": "quotes", "name": .string("Bausteine \(suffix)")])
        try await h.call("citation.folder.add", ["group": .string(try #require(quoteGroup["id"]?.stringValue)), "name": .string("Kiste \(suffix)")])
        let id = try await quote(key)
        try await h.call("citation.quote.move", ["quote": .string(id), "folder": .string("Kiste \(suffix)")])
        #expect(library.quote(UUID(uuidString: id)!)?.folderID != nil)
        try await h.call("citation.quote.move", ["quote": .string(id)])
        #expect(library.quote(UUID(uuidString: id)!)?.folderID == nil)
    }

    @Test func citekeys() async throws {
        let key = try await source()
        let suggested = try await h.call("citation.source.suggestCitekey", ["source": .string(key)])
        #expect(suggested["citekey"]?.stringValue?.isEmpty == false)
        let new = "neu\(UUID().uuidString.prefix(6).lowercased())"
        let id = try await h.document("Ein Satz [@\(key)].")
        let result = try await h.call("citation.source.setCitekey", ["source": .string(key), "key": .string(new)])
        #expect(result["citekey"] == .string(new))
        #expect(result["citedIn"] == 1)
        #expect(library.source(citekey: new) != nil)
        #expect(h.text(id).contains("[@\(key)]"))
        #expect(await h.errorCode("citation.source.setCitekey", ["source": .string(new), "key": "nicht gültig !"]) == RPCError.invalidParamsCode)
    }

    @Test func usagesAndDuplicates() async throws {
        let doi = "10.1234/\(UUID().uuidString.prefix(6).lowercased())"
        let key = try await source(extra: ["doi": .string(doi)])
        let id = try await h.document("Ein Satz [@\(key), S. 3] und [@\(key)].")
        let deck = try #require(try await h.call("presenter.deck.create", ["title": .string("Beleg \(UUID().uuidString)")])["id"]?.stringValue)
        try await h.call("presenter.slide.setText", ["deck": .string(deck), "slideIndex": 1, "markdown": .string("Folie [@\(key)]")])
        let usages = try await h.call("citation.usages", ["source": .string(key)])
        #expect(usages["usages"]?.arrayValue?.first { $0["id"] == .string(id) }?["citations"] == 2)
        #expect(usages["usages"]?.arrayValue?.first { $0["id"] == .string(deck) }?["isPresentation"] == true)

        let hits = try await h.call("citation.duplicates.check", ["identifier": .string(doi)])
        #expect(hits["duplicates"]?.arrayValue?.first?["citekey"] == .string(key))
        let none = try await h.call("citation.duplicates.check", ["identifier": "10.9999/gibtesnicht"])
        #expect(none["duplicates"] == [])
    }

    @Test func mergeMovesEverything() async throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("Anhang-\(UUID().uuidString).txt")
        try "Text".write(to: file, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: file) }
        let keep = try await source(extra: ["publisher": "Verlag A"])
        let gone = try await source(extra: ["publisher": "Verlag B", "pages": "1–9", "tags": ["alt"]])
        let quoteID = try await quote(gone)
        try await h.call("citation.attachment.add", ["source": .string(gone), "file": .string(file.path)])
        let id = try await h.document("Ein Satz [@\(gone), S. 3] und [siehe @\(keep); @\(gone)].")
        let deck = try #require(try await h.call("presenter.deck.create", ["title": .string("Zusammen \(UUID().uuidString)")])["id"]?.stringValue)
        try await h.call("presenter.notes.set", ["deck": .string(deck), "slideIndex": 1, "text": .string("Karte [@\(gone)]")])

        #expect(await h.errorCode("citation.source.merge", ["keep": .string(keep), "remove": .string(keep)]) == RPCError.invalidParamsCode)
        let result = try await h.call("citation.source.merge", ["keep": .string(keep), "remove": .string(gone)])
        #expect(result["movedQuotes"] == 1)
        #expect(result["changedTexts"] == 2)

        let kept = try #require(library.source(citekey: keep))
        #expect(kept.publisher == "Verlag A")
        #expect(kept.pages == "1–9")
        #expect(kept.tags == ["alt"])
        #expect(kept.attachments.count == 1)
        #expect(library.source(citekey: gone) == nil)
        #expect(library.quote(UUID(uuidString: quoteID)!)?.sourceID == kept.id)
        #expect(h.text(id) == "Ein Satz [@\(keep), S. 3] und [siehe @\(keep); @\(keep)].\n" || h.trimmed(id) == "Ein Satz [@\(keep), S. 3] und [siehe @\(keep); @\(keep)].")
        #expect(h.app.document(UUID(uuidString: deck)!)?.deck?.slides.first?.notes == "Karte [@\(keep)]")
        #expect(FileManager.default.fileExists(atPath: library.attachmentURL(try #require(kept.attachments.first), of: kept.id).path))
    }

    @Test func mergeAsksFirst() async throws {
        let keep = try await source(), gone = try await source()
        h.registry.approval.presenter = { _ in false }
        defer { h.registry.approval.presenter = { _ in true } }
        #expect(await h.errorCode("citation.source.merge", ["keep": .string(keep), "remove": .string(gone)], channel: .chat) == RPCError.deniedCode)
        #expect(library.source(citekey: gone) != nil)
    }

    // MARK: Exchange

    @Test func bibtexGoesThereAndBack() throws {
        var source = CitationSource()
        source.citekey = "muster2020"
        source.type = .article
        source.title = "Über {Wasser} und Land"
        source.authors = [PersonName(family: "Müller", given: "Anna"), PersonName(family: "Statistisches Amt", isInstitution: true), PersonName(family: "Goethe", given: "Johann", particle: "von")]
        source.year = 2020
        source.container = "Zeitschrift"
        source.pages = "12–34"
        source.doi = "10.1/x"
        let text = CitationBibTeX.export([source])
        #expect(text.contains("@article{muster2020,"))
        #expect(text.contains("journal = {Zeitschrift}"))
        #expect(text.contains("pages = {12--34}"))
        #expect(text.contains("{Statistisches Amt}"))

        let parsed = CitationBibTeX.parse("% Kommentar\n@comment{egal}\n" + text + "\n@misc{kaputt, year = 2000}\n")
        #expect(parsed.skipped.count == 1)
        let back = try #require(parsed.sources.first)
        #expect(back.citekey == "muster2020")
        #expect(back.type == .article)
        #expect(back.title == "Über Wasser und Land")
        #expect(back.authors.first?.family == "Müller")
        #expect(back.authors.first?.given == "Anna")
        #expect(back.authors[1].isInstitution)
        #expect(back.authors[2].family == "Goethe")
        #expect(back.authors[2].particle == "von")
        #expect(back.year == 2020)
        #expect(back.pages == "12–34")
        #expect(back.doi == "10.1/x")
    }

    @Test func aBraceInAValueCannotEndItsEntry() throws {
        var source = CitationSource()
        source.citekey = "a2020"
        source.title = "Text } @misc{b, title = {Eingeschleust}}"
        let parsed = CitationBibTeX.parse(CitationBibTeX.export([source]))
        #expect(parsed.sources.count == 1)
    }

    @Test func bibtexValuesInQuotesAndNumbers() {
        let parsed = CitationBibTeX.parse(#"@book{k1, title = "Ein Buch", year = 1999, author = {M{\"u}ller, Anna and Kaiser, Bo}, publisher = {Verlag}}"#)
        let source = parsed.sources.first
        #expect(source?.title == "Ein Buch")
        #expect(source?.year == 1999)
        #expect(source?.type == .book)
        #expect(source?.authors.count == 2)
        #expect(source?.authors.first?.family == "Müller")
    }

    @Test func exportAndImportFiles() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("Literatur-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        let key = try await source(extra: ["doi": .string("10.5/\(UUID().uuidString.prefix(6).lowercased())")])
        let bib = folder.appendingPathComponent("a.bib")
        let result = try await h.call("citation.export.bibtex", ["keys": .array([.string(key)]), "path": .string(bib.path)])
        #expect((result["bytes"]?.intValue ?? 0) > 0)
        #expect(try String(contentsOf: bib, encoding: .utf8).contains("@article{\(key),"))
        #expect(await h.errorCode("citation.export.bibtex", ["keys": .array([.string(key)]), "path": .string(bib.path)]) == RPCError.invalidTargetCode)
        #expect(await h.errorCode("citation.export.bibtex", [:]) == RPCError.invalidParamsCode)

        let json = folder.appendingPathComponent("a.json")
        try await h.call("citation.export.csl", ["keys": .array([.string(key)]), "path": .string(json.path)])
        let items = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: json)) as? [[String: Any]])
        #expect(items.first?["id"] as? String == key)
        #expect(items.first?["type"] as? String == "article-journal")
        #expect((items.first?["author"] as? [[String: String]])?.first?["family"] == "Muster")

        // The source is there already: it stays out.
        let again = try await h.call("citation.import.bibtex", ["file": .string(bib.path)])
        #expect(again["added"] == [])
        #expect(again["duplicates"]?.arrayValue?.first == .string(key))

        let new = folder.appendingPathComponent("b.bib")
        let title = "Frisch \(UUID().uuidString)"
        try "@book{frisch1999, title = {\(title)}, year = {1999}, author = {Kaiser, Bo}}".write(to: new, atomically: true, encoding: .utf8)
        let imported = try await h.call("citation.import.bibtex", ["file": .string(new.path)], run: "bibtex-lauf")
        let made = try #require(imported["added"]?.arrayValue?.first?.stringValue)
        #expect(library.source(citekey: made)?.title == title)
        #expect(h.registry.runState(id: "bibtex-lauf", channel: .cli).hasReadUntrusted)
        try await h.call("writer.edit.undo", run: "bibtex-lauf")
        #expect(library.source(citekey: made) == nil)
        #expect(await h.errorCode("citation.import.bibtex", ["file": "/gibt/es/nicht.bib"]) == RPCError.notFoundCode)
        let empty = folder.appendingPathComponent("leer.bib")
        try "Kein BibTeX".write(to: empty, atomically: true, encoding: .utf8)
        #expect(await h.errorCode("citation.import.bibtex", ["file": .string(empty.path)]) == RPCError.invalidTargetCode)
    }

    @Test func aModelNamingAFileNeedsConsent() async throws {
        h.registry.approval.presenter = { _ in false }
        defer { h.registry.approval.presenter = { _ in true } }
        #expect(await h.errorCode("citation.import.bibtex", ["file": "/etc/hosts"], channel: .chat) == RPCError.deniedCode)
    }
}
}
