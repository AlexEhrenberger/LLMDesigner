import Testing
import Foundation
@testable import LLMDesigner

@Suite("Rechercherista: Quellen lesen, Format, Bericht")
struct ResearchTests {
    @Test func arxivEntriesAreRead() {
        let atom = """
        <feed xmlns="http://www.w3.org/2005/Atom"><title>ArXiv Query</title>
        <entry><id>http://arxiv.org/abs/1234.5678v1</id><published>2021-03-04T00:00:00Z</published>
        <title>A Model of
          Something</title><summary>  We study
        things.</summary><author><name>Ada Muster</name></author><author><name>Ben Beispiel</name></author></entry>
        <entry><id>http://arxiv.org/abs/9999.0001v2</id><title>Second</title><summary>More.</summary></entry>
        </feed>
        """
        let hits = ArxivSearch.parse(Data(atom.utf8))
        #expect(hits.count == 2)
        #expect(hits[0].title == "A Model of Something")
        #expect(hits[0].abstract == "We study things.")
        #expect(hits[0].authors == ["Ada Muster", "Ben Beispiel"])
        #expect(hits[0].year == 2021)
        #expect(hits[0].url == "https://arxiv.org/abs/1234.5678v1")
    }

    @Test func openAlexAbstractsAreRebuilt() {
        let json = """
        {"results": [{"id": "https://openalex.org/W1", "doi": "https://doi.org/10.1/abc", "title": "Predictive coding",
          "publication_year": 2010, "cited_by_count": 42, "authorships": [{"author": {"display_name": "K. Friston"}}],
          "abstract_inverted_index": {"brain": [1], "The": [0], "predicts": [2]},
          "primary_location": {"landing_page_url": "https://example.org/paper"}}]}
        """
        let hits = OpenAlexSearch.parse(Data(json.utf8))
        #expect(hits.first?.abstract == "The brain predicts")
        #expect(hits.first?.doi == "10.1/abc")
        #expect(hits.first?.url == "https://example.org/paper")
        #expect(hits.first?.citations == 42)
    }

    @Test func aResearchKeepsGermanKeysAndStopsWhenReloaded() throws {
        var item = Research(question: "Was ist Predictive Coding?")
        item.phase = .recherchieren
        let root = ResearchNode(question: item.question)
        item.nodes = [root, ResearchNode(parent: root.id, question: "Woher kommt der Begriff?")]
        item.sources = [ResearchSource(number: 1, kind: .arxiv, title: "Paper", url: "https://arxiv.org/abs/1", authors: ["A", "B", "C"], year: 2020)]
        item.clarification = ResearchClarification(question: "Was meinst du?", options: ["Kognition", "Recht"], answer: "Kognition")
        let store = RecordStore<Research>(directory: FileManager.default.temporaryDirectory, root: "recherche", layout: .folder("recherche"))
        let json = try #require(String(data: try store.encode(item), encoding: .utf8))
        for key in ["\"recherche\"", "\"baum\"", "\"eltern\"", "\"quellen\"", "\"rueckfrage\"", "\"optionen\"", "\"tiefe\" : \"gruendlich\""] {
            #expect(json.contains(key), "\(key)")
        }
        let back = try store.decode(Data(json.utf8))
        #expect(back.phase == .gestoppt, "eine laufende Recherche ist nach dem Neustart angehalten")
        #expect(back.focus == "Kognition")
        #expect(back.children(of: root.id).count == 1)
        #expect(back.sources.first?.byline == "A u. a., 2020")
    }

    @Test func theBibliographyLeavesOutRejectedSources() {
        var item = Research(question: "Q")
        item.sources = [ResearchSource(number: 2, kind: .web, title: "Zwei", url: "https://b.de"),
                        ResearchSource(number: 1, kind: .wikipedia, title: "Eins", url: "https://a.de"),
                        ResearchSource(number: 3, kind: .web, title: "Drei", url: "https://c.de", accepted: false)]
        #expect(item.bibliography.components(separatedBy: "\n").count == 2)
        #expect(item.bibliography.hasPrefix("1. *Eins*"))
        #expect(AppModel.addressKey("https://www.Example.org/a/") == AppModel.addressKey("http://example.org/a"))
    }

    @Test func restrictedResearchesOnlyAskWikipedia() {
        var item = Research(question: "Q")
        item.restricted = true
        #expect(item.allowedKinds == [.wikipedia])
    }
}
