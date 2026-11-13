import Testing
import AppKit
import LLMDProtocol
@testable import LLMDesigner

/// Picture sources in Markdown name files. Whoever writes the Markdown (an agent, a model, an imported page) must not
/// reach files outside the picture folder that way: not to show them, not to copy them out, not to delete them.
/// All files here are decoys made by the test, in the throwaway library or the temporary folder.
extension ActionSuites {
@MainActor
@Suite("Writer-Bildpfade (S1)", .serialized)
struct WriterImagePathTests {
    let h = ActionHarness()

    /// The tests delete documents; they may only ever run on a library in the temporary folder.
    private func requireThrowawayLibrary() throws {
        let library = try #require(AppLibrary.current).url.resolvingSymlinksInPath().path
        let temporary = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().path
        try #require(library.hasPrefix(temporary), "Bibliothek liegt nicht im Temp-Ordner: \(library)")
    }

    /// A folder with a file beside the documents folder, in the library: a stand-in for anything else on the Mac.
    private func decoy() throws -> (name: String, folder: URL, file: URL) {
        try requireThrowawayLibrary()
        _ = WriterImageStore.directory
        let name = "Koeder-\(UUID().uuidString.prefix(8))"
        let folder = try #require(AppLibrary.current).url.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let file = folder.appendingPathComponent("geheim.txt")
        try Data("Köder".utf8).write(to: file)
        return (name, folder, file)
    }

    /// A neutral picture outside the library.
    private func outsidePicture() throws -> URL {
        let image = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 8, pixelsHigh: 8, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                     isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("Aussenbild-\(UUID().uuidString).png")
        try image.representation(using: .png, properties: [:])!.write(to: url)
        return url
    }

    private static func inside(_ url: URL, _ folder: URL) -> Bool {
        let path = url.standardizedFileURL.resolvingSymlinksInPath().path
        let root = folder.standardizedFileURL.resolvingSymlinksInPath().path
        return path.hasPrefix(root + "/")
    }

    /// The sources of a document that lead to a file outside the picture folder.
    private func outsideSources(_ id: String) -> [String] {
        WriterImageStore.sources(in: h.text(id)).filter { source in
            guard let url = WriterImageStore.url(for: source) else { return false }
            return !Self.inside(url, WriterImageStore.directory)
        }
    }

    // MARK: Resolving

    @Test(arguments: ["Bilder/../../%@/geheim.txt", "Bilder/%%2E%%2E/%%2E%%2E/%@/geheim.txt", "../%@/geheim.txt", "Bilder/../../%@", "%@/geheim.txt"])
    func aRelativeSourceStaysInThePictureFolder(pattern: String) throws {
        let decoy = try decoy()
        let source = String(format: pattern, decoy.name)
        #expect(WriterImageStore.url(for: source) == nil, "„\(source)“ führt zu \(WriterImageStore.url(for: source)?.path ?? "")")
        #expect(WriterImageStore.targetURL(for: source) == nil, "„\(source)“ wäre ein Schreibziel")
    }

    @Test func absolutePathsAndFileURLsHaveNoFile() throws {
        let picture = try outsidePicture()
        for source in [picture.path, picture.absoluteString, "file://" + picture.path, "https://example.org/bild.png"] {
            #expect(WriterImageStore.url(for: source) == nil, "\(source)")
            #expect(WriterImageStore.targetURL(for: source) == nil, "\(source)")
        }
        // What the app makes still has its place.
        let own = try #require(WriterImageStore.targetURL(for: "Bilder/eigen.png"))
        #expect(Self.inside(own, WriterImageStore.directory))
        #expect(WriterImageStore.targetURL(for: "Bilder/mein%20Bild.png")?.lastPathComponent == "mein Bild.png")
    }

    @Test func aLinkInThePictureFolderDoesNotLeadOut() throws {
        let decoy = try decoy()
        let name = "Verweis-\(UUID().uuidString.prefix(8)).png"
        let link = WriterImageStore.directory.appendingPathComponent(name)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: decoy.file)
        defer { try? FileManager.default.removeItem(at: link) }
        #expect(WriterImageStore.url(for: "Bilder/" + name) == nil)
    }

    @Test func aFigureIsNeverWrittenOutsideThePictureFolder() throws {
        let decoy = try decoy()
        let images = WriterFigureImages(light: Data("hell".utf8), dark: Data("dunkel".utf8), pdf: Data("pdf".utf8))
        #expect(throws: (any Error).self) { try WriterImageStore.write(images, to: "Bilder/../../\(decoy.name)/bild.png") }
        #expect(try FileManager.default.contentsOfDirectory(atPath: decoy.folder.path) == ["geheim.txt"])
    }

    // MARK: Deleting

    @Test func deletingADocumentLeavesFilesOutsideThePictureFolder() async throws {
        let decoy = try decoy()
        let id = try await h.document("Text\n\n![a](Bilder/../../\(decoy.name)/geheim.txt)\n\n![b](Bilder/../../\(decoy.name))")
        try await h.call("writer.doc.delete", ["doc": .string(id)])
        #expect(FileManager.default.fileExists(atPath: decoy.file.path), "Die Köderdatei wurde mitgelöscht.")
        #expect(FileManager.default.fileExists(atPath: decoy.folder.path), "Der Köderordner wurde mitgelöscht.")
    }

    @Test func deletingADocumentStillRemovesItsOwnPictures() async throws {
        let id = try await h.document("Mit Bild")
        try await h.call("writer.image.insert", ["doc": .string(id), "file": .string(try outsidePicture().path)])
        let file = try #require(WriterImageStore.sources(in: h.text(id)).first.flatMap(WriterImageStore.url(for:)))
        try await h.call("writer.doc.delete", ["doc": .string(id)])
        #expect(!FileManager.default.fileExists(atPath: file.path))
    }

    // MARK: Writing

    /// The ways an agent writes Markdown into a document, each with the picture lines it brings.
    private func write(_ way: String, markdown: String, channel: ActionChannel) async throws -> String {
        let id = try await h.document("Platzhalter")
        switch way {
        case "doc.create":
            let made = try await h.call("writer.doc.create", ["title": .string("Test \(UUID().uuidString)"), "markdown": .string(markdown)], channel: channel)
            return try #require(made["id"]?.stringValue)
        case "text.insertMarkdown":
            try await h.call("writer.text.insertMarkdown", ["doc": .string(id), "markdown": .string(markdown)], channel: channel)
        case "text.replace":
            try await h.call("writer.text.replace", ["doc": .string(id), "match": "Platzhalter", "markdown": .string(markdown)], channel: channel)
        case "box.insert":
            try await h.call("writer.box.insert", ["doc": .string(id), "kind": "hinweis", "markdown": .string(markdown)], channel: channel)
        default:
            Issue.record("Unbekannter Weg \(way)")
        }
        return id
    }

    /// The Markdown may stay as it was written; what matters is that no file behind it is reached.
    @Test(arguments: [ActionChannel.mcp, .chat], ["doc.create", "text.insertMarkdown", "text.replace", "box.insert"])
    func anAgentCannotPointAPictureOutsideTheLibrary(channel: ActionChannel, way: String) async throws {
        let picture = try outsidePicture()
        let decoy = try decoy()
        let markdown = "Ein Absatz.\n\n![x](\(picture.path))\n\n![y](\(picture.absoluteString))\n\n![z](Bilder/../../\(decoy.name)/geheim.txt)"
        let id: String
        do {
            id = try await write(way, markdown: markdown, channel: channel)
        } catch is RPCError {
            return  // Refused: that is fine.
        }
        #expect(outsideSources(id).isEmpty, "\(way) über \(channel.rawValue) hat Bildquellen außerhalb geschrieben: \(outsideSources(id))")
    }

    // MARK: Exporting

    @Test func anExportCopiesNoFileFromOutsideThePictureFolder() async throws {
        let decoy = try decoy()
        let picture = try outsidePicture()
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("Export-\(UUID().uuidString)", isDirectory: true)
        ActionExportFolder.set(folder, settings: h.app.settings)
        defer { ActionExportFolder.set(nil, settings: h.app.settings) }
        let id = try await h.document("Text\n\n![z](Bilder/../../\(decoy.name)/geheim.txt)\n\n![a](\(picture.path))")
        let result = try await h.call("writer.export", ["doc": .string(id), "format": "markdown"])
        let exported = URL(fileURLWithPath: try #require(result["path"]?.stringValue))
        let copies = (FileManager.default.enumerator(at: exported.deletingLastPathComponent(), includingPropertiesForKeys: nil)?.allObjects as? [URL] ?? [])
            .filter { ["geheim.txt", picture.lastPathComponent].contains($0.lastPathComponent) }
        #expect(copies.isEmpty, "Der Export hat Dateien von draußen mitkopiert: \(copies.map(\.path))")
    }
}
}
