import Testing
import AppKit
import LLMDProtocol
@testable import LLMDesigner

extension ActionSuites {
@MainActor
@Suite("Writer: Schrift, Struktur, Seite, Ton", .serialized)
struct WriterRestActionTests {
    let h = ActionHarness()

    private func document(_ id: String) -> WriterDocument { h.app.document(UUID(uuidString: id)!)! }

    private func editorForm(_ markdown: String) -> String {
        WriterMarkdown.markdown(from: WriterMarkdown.attributedString(from: markdown)).trimmingCharacters(in: .newlines)
    }

    // MARK: Passages

    @Test func fontSizeColorOfAPassage() async throws {
        let id = try await h.document("Ein Wort hier.")
        try await h.call("writer.format.font", ["doc": .string(id), "match": "Wort", "font": .string(WriterFont.georgia.rawValue)])
        #expect(h.text(id).contains("<span"))
        #expect(WriterMarkdown.attributedString(from: h.trimmed(id)).string.contains("Ein Wort hier."))
        try await h.call("writer.format.color", ["doc": .string(id), "match": "Wort", "color": "Blau"])
        #expect(h.text(id).contains("1F5FBF"))
        try await h.call("writer.format.fontSize", ["doc": .string(id), "match": "Wort", "size": 14])
        #expect(h.text(id).contains("14"))
        try await h.call("writer.format.color", ["doc": .string(id), "match": "Wort", "color": "none"])
        #expect(!h.text(id).contains("1F5FBF"))
        try await h.call("writer.format.font", ["doc": .string(id), "match": "Wort", "font": "none"])
        try await h.call("writer.format.fontSize", ["doc": .string(id), "match": "Wort", "size": 0])
        #expect(h.trimmed(id) == "Ein Wort hier.")
        #expect(await h.errorCode("writer.format.color", ["doc": .string(id), "match": "Wort", "color": "Quark"]) == RPCError.invalidParamsCode)
        #expect(await h.errorCode("writer.format.fontSize", ["doc": .string(id), "match": "Wort"]) == RPCError.invalidParamsCode)
    }

    @Test func fontSizeStepsFromWhatIsThere() async throws {
        let id = try await h.document("Ein Wort hier.")
        try await h.call("writer.format.fontSize", ["doc": .string(id), "match": "Wort", "size": 14])
        try await h.call("writer.format.fontSize", ["doc": .string(id), "match": "Wort", "step": 1])
        let text = WriterMarkdown.attributedString(from: h.trimmed(id))
        let place = (text.string as NSString).range(of: "Wort").location
        #expect(text.attribute(.writerFontSize, at: place, effectiveRange: nil) as? Double == 16)
    }

    @Test func links() async throws {
        let id = try await h.document("Ein Wort hier.")
        try await h.call("writer.link.set", ["doc": .string(id), "match": "Wort", "url": "https://example.org/a"])
        #expect(h.trimmed(id) == "Ein [Wort](https://example.org/a) hier.")
        try await h.call("writer.link.remove", ["doc": .string(id), "match": "Wort"])
        #expect(h.trimmed(id) == "Ein Wort hier.")
        #expect(await h.errorCode("writer.link.set", ["doc": .string(id), "match": "Wort", "url": "keine adresse"]) == RPCError.invalidParamsCode)
    }

    @Test func paragraphFormat() async throws {
        let id = try await h.document("Absatz eins.\n\nAbsatz zwei.")
        try await h.call("writer.paragraph.indent", ["doc": .string(id), "match": "eins", "left": 2, "firstLine": 1])
        let chunk = try #require(PowerText.chunks(of: h.text(id)).first?.markdown)
        #expect(chunk.hasPrefix(":::"))
        #expect(chunk.contains("indent=2") || chunk.contains("left"))
        #expect(h.trimmed(id) == editorForm(h.trimmed(id)))
        try await h.call("writer.paragraph.lineSpacing", ["doc": .string(id), "match": "eins", "value": .double(1.5)])
        #expect(h.text(id).contains("1.5"))
        try await h.call("writer.paragraph.indent", ["doc": .string(id), "match": "zwei", "step": 1])
        #expect(h.text(id).contains("1.25"))
        try await h.call("writer.paragraph.clearFormat", ["doc": .string(id), "all": true])
        #expect(h.trimmed(id) == "Absatz eins.\n\nAbsatz zwei.")
        #expect(await h.errorCode("writer.paragraph.indent", ["doc": .string(id), "all": true]) == RPCError.invalidParamsCode)
        let code = try await h.document("```\nx\n```")
        #expect(await h.errorCode("writer.paragraph.lineSpacing", ["doc": .string(code), "all": true, "value": 2]) == RPCError.invalidTargetCode)
    }

    // MARK: Table of contents

    @Test func tableOfContents() async throws {
        let id = try await h.document("# Eins\n\nText\n\n## Zwei\n\nMehr")
        try await h.call("writer.toc.insert", ["doc": .string(id), "all": true, "position": "before"])
        #expect(h.trimmed(id).hasPrefix("[TOC]\n\n# Eins"))
        try await h.call("writer.toc.setMode", ["doc": .string(id), "mode": "dynamic"])
        #expect(h.trimmed(id).hasPrefix("[TOC]{.dynamic}"))
        #expect(document(id).tocMode == .dynamic)
        try await h.call("writer.toc.setMode", ["doc": .string(id), "mode": "formal"])
        #expect(document(id).tocMode == .headings)
        try await h.call("writer.toc.expand", ["doc": .string(id)])
        #expect(h.text(id).contains("](#eins)"))
        #expect(!h.text(id).contains("[TOC]"))
        #expect(await h.errorCode("writer.toc.remove", ["doc": .string(id)]) == RPCError.notFoundCode)

        let other = try await h.document("# Titel")
        try await h.call("writer.toc.insert", ["doc": .string(other)])
        try await h.call("writer.toc.remove", ["doc": .string(other)])
        #expect(h.trimmed(other) == "# Titel")
        #expect(await h.errorCode("writer.toc.expand", ["doc": .string(other)]) == RPCError.notFoundCode)
    }

    // MARK: Bookmarks

    @Test func bookmarks() async throws {
        let id = try await h.document("# Kapitel\n\nEin Wort hier.")
        let made = try await h.call("writer.bookmark.add", ["doc": .string(id), "match": "Wort", "name": "Merker"])
        let bookmark = try #require(made["id"]?.stringValue)
        var list = try await h.call("writer.bookmarks.list", ["doc": .string(id)])
        #expect(list["bookmarks"]?.arrayValue?.first?["title"] == "Merker")
        #expect(list["bookmarks"]?.arrayValue?.first?["excerpt"] == "Wort")
        #expect(list["bookmarks"]?.arrayValue?.first?["section"] == "Kapitel")

        try await h.call("writer.bookmark.rename", ["doc": .string(id), "bookmark": "Merker", "name": "Stelle"])
        list = try await h.call("writer.bookmarks.list", ["doc": .string(id)])
        #expect(list["bookmarks"]?.arrayValue?.first?["title"] == "Stelle")
        #expect(list["bookmarks"]?.arrayValue?.first?["id"] == .string(bookmark))

        try await h.call("writer.bookmark.remove", ["doc": .string(id), "bookmark": .string(bookmark)])
        #expect(h.trimmed(id) == "# Kapitel\n\nEin Wort hier.")
        #expect(await h.errorCode("writer.bookmark.remove", ["doc": .string(id), "bookmark": "Stelle"]) == RPCError.notFoundCode)
    }

    // MARK: Comments

    @Test func commentThread() async throws {
        let id = try await h.document("Ein Satz.\n\nNoch einer.")
        let made = try await h.call("writer.comment.add", ["doc": .string(id), "match": "Satz", "text": "Stimmt das?"])
        let comment = try #require(made["id"]?.stringValue)
        #expect(WriterComment.strip(h.trimmed(id)) == "Ein Satz.\n\nNoch einer.")

        try await h.call("writer.comment.reply", ["doc": .string(id), "comment": .string(comment), "text": "Ja."])
        var list = try await h.call("writer.comments.list", ["doc": .string(id)])
        var item = try #require(list["comments"]?.arrayValue?.first)
        #expect(item["excerpt"] == "Satz")
        #expect(item["entries"]?.arrayValue?.count == 2)
        #expect(item["entries"]?.arrayValue?.first?["author"] == "Agent")

        try await h.call("writer.comment.edit", ["doc": .string(id), "comment": .string(comment), "text": "Nein."])
        try await h.call("writer.comment.edit", ["doc": .string(id), "comment": .string(comment), "entry": 1, "text": "Wirklich?"])
        try await h.call("writer.comment.resolve", ["doc": .string(id), "comment": .string(comment)])
        list = try await h.call("writer.comments.list", ["doc": .string(id)])
        item = try #require(list["comments"]?.arrayValue?.first)
        #expect(item["resolved"] == true)
        #expect(item["entries"]?.arrayValue?.map { $0["text"]?.stringValue } == ["Wirklich?", "Nein."])

        try await h.call("writer.comment.resolve", ["doc": .string(id), "comment": .string(comment), "resolved": false])
        #expect((try await h.call("writer.comments.list", ["doc": .string(id)]))["comments"]?.arrayValue?.first?["resolved"] == false)
        #expect(await h.errorCode("writer.comment.edit", ["doc": .string(id), "comment": .string(comment), "entry": 9, "text": "x"]) == RPCError.notFoundCode)

        try await h.call("writer.comment.delete", ["doc": .string(id), "comment": .string(comment)])
        #expect(h.trimmed(id) == "Ein Satz.\n\nNoch einer.")
        #expect(await h.errorCode("writer.comment.delete", ["doc": .string(id), "comment": .string(comment)]) == RPCError.notFoundCode)
        #expect(await h.errorCode("writer.comment.add", ["doc": .string(id), "match": "Satz", "text": "  "]) == RPCError.invalidParamsCode)
    }

    // MARK: Citations

    @Test func citationsListAndEdit() async throws {
        let source = try await h.call("citation.source.create", ["type": "book", "title": .string("Buch \(UUID().uuidString)"), "authors": ["Muster, Erika"], "year": 2019])
        let key = try #require(source["citekey"]?.stringValue)
        let id = try await h.document("Ein Satz [@\(key), S. 12] und noch einer [@\(key)] und [@unbekannt2000].")
        let list = try await h.call("writer.citations.list", ["doc": .string(id)])
        #expect(list["keys"]?.arrayValue?.count == 2)
        #expect(list["citations"]?.arrayValue?.count == 3)
        #expect(list["citations"]?.arrayValue?[0]["page"] == "S. 12")
        #expect(list["citations"]?.arrayValue?[2]["known"] == false)

        #expect(await h.errorCode("writer.citation.edit", ["doc": .string(id), "citation": .string(key), "page": "1"]) == RPCError.ambiguousCode)
        try await h.call("writer.citation.edit", ["doc": .string(id), "citation": "2", "page": "99"])
        #expect(h.text(id).contains("[@\(key), S. 99]"))
        try await h.call("writer.citation.edit", ["doc": .string(id), "citation": "1", "page": ""])
        #expect(h.text(id).contains("Ein Satz [@\(key)] und"))
        try await h.call("writer.citation.edit", ["doc": .string(id), "citation": "unbekannt2000", "page": "Kap. 2"])
        #expect(h.text(id).contains("[@unbekannt2000, Kap. 2]"))
        #expect(await h.errorCode("writer.citation.edit", ["doc": .string(id), "citation": "9", "page": "1"]) == RPCError.notFoundCode)
    }

    // MARK: Page

    @Test func pageFormatsAndHeads() async throws {
        let id = try await h.document("Text")
        try await h.call("writer.page.format", ["doc": .string(id), "format": "taschenbuch"])
        #expect(document(id).pageFormat == .paperback)
        #expect(await h.errorCode("writer.page.format", ["doc": .string(id), "format": "eigen"]) == RPCError.invalidTargetCode)
        #expect(await h.errorCode("writer.page.format", ["doc": .string(id)]) == RPCError.invalidParamsCode)

        try await h.call("writer.page.setup", ["doc": .string(id), "paperWidth": 148, "paperHeight": 210, "top": 30, "landscape": true, "fontSize": 12])
        let setup = try #require(document(id).pageSetup)
        #expect(document(id).pageFormat == .custom)
        #expect(setup.paperWidth == 210)
        #expect(setup.paperHeight == 148)
        #expect(setup.top == 30)

        try await h.call("writer.page.runningHeads", ["doc": .string(id), "header": ["left": "{Titel}"], "footer": ["center": "{Seite}"], "skipFirstPage": true, "rules": true])
        let heads = try #require(document(id).runningHeads)
        #expect(heads.header.left == "{Titel}")
        #expect(heads.footer.center == "{Seite}")
        #expect(heads.skipsFirstPage)
        #expect(heads.hasRules)
        try await h.call("writer.page.runningHeads", ["doc": .string(id), "clear": true])
        #expect(document(id).runningHeads == nil)

        try await h.call("writer.doc.font", ["doc": .string(id), "font": .string(WriterFont.georgia.rawValue)])
        #expect(document(id).font == .georgia)
        try await h.call("writer.edit.undo")
        #expect(document(id).font != .georgia)
    }

    @Test func pageTemplates() async throws {
        let name = "Vorlage \(UUID().uuidString)"
        let id = try await h.document("Text")
        try await h.call("writer.page.setup", ["doc": .string(id), "top": 40])
        try await h.call("writer.page.template.save", ["doc": .string(id), "name": .string(name), "bottom": 41])
        let template = try #require(h.app.writerPageTemplates.first { $0.name == name })
        #expect(template.top == 40)
        #expect(template.bottom == 41)

        let other = try await h.document("Mehr")
        try await h.call("writer.page.format", ["doc": .string(other), "template": .string(name)])
        #expect(document(other).pageFormat == .custom)
        #expect(document(other).pageSetup?.bottom == 41)
        #expect(await h.errorCode("writer.page.format", ["doc": .string(other), "template": "Fehlt"]) == RPCError.notFoundCode)

        try await h.call("writer.page.template.delete", ["name": .string(name)])
        #expect(!h.app.writerPageTemplates.contains { $0.name == name })
        try await h.call("writer.edit.undo")
        #expect(h.app.writerPageTemplates.contains { $0.name == name })
        try await h.call("writer.page.template.delete", ["name": .string(name)])
        #expect(await h.errorCode("writer.page.template.delete", ["name": .string(name)]) == RPCError.notFoundCode)
    }

    // MARK: Sound and print (these are not started for real: nothing should speak, record or print during tests)

    @Test func speechWithoutTextSaysSo() async throws {
        let id = try await h.document("```\nnur code\n```")
        let code = await h.errorCode("writer.speech.read", ["doc": .string(id), "match": "gibt es nicht"])
        #expect(code == RPCError.notFoundCode)
        let empty = try await h.document("")
        #expect(await h.errorCode("writer.speech.read", ["doc": .string(empty)]) == RPCError.invalidTargetCode)
        try await h.call("writer.speech.stop")
    }

    @Test func theMicrophoneAlwaysAsks() async throws {
        h.registry.approval.presenter = { _ in false }
        defer { h.registry.approval.presenter = { _ in true } }
        #expect(await h.errorCode("writer.dictation.start") == RPCError.deniedCode)
        #expect(await h.errorCode("writer.dictation.start", channel: .chat) == RPCError.deniedCode)
        try await h.call("writer.dictation.stop")
    }

    @Test func dictationNeedsAnOpenDocument() async throws {
        h.app.closeDocument()
        #expect(await h.errorCode("writer.dictation.start") == RPCError.invalidTargetCode)
    }

    @Test func printingAsksFirst() async throws {
        let id = try await h.document("Text")
        h.registry.approval.presenter = { _ in false }
        defer { h.registry.approval.presenter = { _ in true } }
        #expect(await h.errorCode("writer.print", ["doc": .string(id)]) == RPCError.deniedCode)
    }
}
}
