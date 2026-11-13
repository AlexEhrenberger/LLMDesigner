import Testing
import AppKit
import LLMDProtocol
@testable import LLMDesigner

/// A document with every kind of block, made once per run through the actions themselves, so each object is exactly
/// as the app makes it. Tests work on copies of it.
@MainActor
enum WriterFixture {
    static let base = """
    # Einleitung

    Der Wasserkreislauf ist ein Thema. Hier steht **fett** und *kursiv* und ein [Verweis](https://example.org).

    ## Abschnitt Zwei

    - Punkt eins
    - Punkt zwei

    1. Erstens
    2. Zweitens

    > Ein Zitat steht hier.

    ```python
    print("hallo")
    ```

    $$
    E = mc^2
    $$

    | Name | Wert |
    |---|---|
    | A | 1 |
    | B | 2 |

    Ein Satz mit Fußnote.^[Die Fußnote.]

    # Schluss

    Letzter Absatz mit dem Merkwort.
    """

    private static var master: String?
    /// Steps of the build that failed: the fixture then lacks that object, and the report says so.
    private(set) static var missing: [String] = []
    private(set) static var pictureFile: URL?

    /// A neutral picture made for the test.
    static func picture() throws -> URL {
        if let pictureFile { return pictureFile }
        let image = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 40, pixelsHigh: 20, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                     isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("Fixturbild-\(UUID().uuidString).png")
        try image.representation(using: .png, properties: [:])!.write(to: url)
        pictureFile = url
        return url
    }

    /// The id of the master document.
    static func masterID(_ h: ActionHarness) async throws -> String {
        if let master { return master }
        let id = try await h.document(base)
        let doc = JSONValue.string(id)
        let steps: [(String, String, JSONValue)] = [
            ("toc", "writer.toc.insert", ["doc": doc, "all": true, "position": "before", "mode": "formal"]),
            ("bookmark", "writer.bookmark.add", ["doc": doc, "match": "Merkwort", "name": "Merker"]),
            ("comment", "writer.comment.add", ["doc": doc, "match": "Thema", "text": "Stimmt das?"]),
            ("image", "writer.image.insert", ["doc": doc, "file": .string(try picture().path), "heading": "Schluss", "caption": "Ein Bild"]),
            ("box", "writer.box.insert", ["doc": doc, "match": "Ein Zitat steht hier.", "kind": "merksatz", "title": "Merke", "markdown": "Im Kasten."]),
            ("chart", "writer.chart.insert", ["doc": doc, "heading": "Schluss", "kind": "line", "categories": ["A", "B"], "series": [["name": "X", "values": [1, 2]]]]),
            ("mermaid", "writer.mermaid.insert", ["doc": doc, "heading": "Schluss", "code": "flowchart TD\n  A-->B"]),
            ("drawing", "writer.drawing.insert", ["doc": doc, "heading": "Schluss", "elements": [["kind": "rectangle", "points": [[10, 10], [60, 40]]]]]),
            ("inline formula", "writer.formula.insert", ["doc": doc, "latex": "a+b", "display": "inline", "match": "Satz mit"]),
            ("columns", "writer.columns.set", ["doc": doc, "match": "Letzter Absatz", "columns": 2]),
        ]
        for (name, action, args) in steps {
            do {
                try await h.call(action, args)
            } catch {
                missing.append("\(name): \((error as? RPCError)?.message ?? error.localizedDescription)")
            }
        }
        do {
            let source = try await h.call("citation.source.create", ["type": "article", "title": .string("Fixturquelle \(UUID().uuidString)"),
                                                                    "authors": ["Muster, Erika"], "year": 2020])
            let key = try #require(source["citekey"]?.stringValue)
            citekey = key
            try await h.call("writer.citation.insert", ["doc": doc, "key": .string(key), "match": "Merkwort"])
        } catch {
            missing.append("citation: \((error as? RPCError)?.message ?? error.localizedDescription)")
        }
        master = id
        return id
    }

    /// The key of the fixture's source in Citation Studio.
    private(set) static var citekey: String?

    /// A copy of the master, made without an action, so it adds no undo step.
    static func copy(_ h: ActionHarness) async throws -> String {
        let master = try #require(h.app.document(UUID(uuidString: try await masterID(h))!))
        let copy = h.app.createDocumentForAction(title: "Kopie \(UUID().uuidString)", folderID: nil, markdown: master.markdown, provenance: nil)
        return copy.id.uuidString
    }

    /// Takes a copy away again; its pictures stay, the master still shows them.
    static func drop(_ id: String, _ h: ActionHarness) {
        guard let uuid = UUID(uuidString: id), h.app.document(uuid) != nil else { return }
        h.app.deleteDocument(uuid)
    }
}
