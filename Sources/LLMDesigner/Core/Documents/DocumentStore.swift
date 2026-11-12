import AppKit
import PDFKit
import UniformTypeIdentifiers

enum DocumentError: LocalizedError {
    case unsupported(String)
    case noText(String)
    case tooLarge(String)
    case writeFailed(String)

    var errorDescription: String? {
        switch self {
        case .unsupported(let name): "„\(name)“ kann die App nicht lesen."
        case .noText(let name): "In „\(name)“ steht kein Text, den die App erkennen kann."
        case .tooLarge(let name): "„\(name)“ hat mehr als \(DocumentStore.maxPages) Seiten."
        case .writeFailed(let name): "„\(name)“ konnte nicht gespeichert werden."
        }
    }
}

/// Documents attached to chat messages. They live next to the pictures in the library's attachments folder: the
/// original, the text the model reads, and the figures cut out of a PDF.
enum DocumentStore {
    static let maxPages = 600
    /// Figures beyond this are left out; a catalogue of pictures doesn't need each one described.
    static let maxFigures = 60

    /// What the composer takes besides pictures.
    static let contentTypes: [UTType] = [
        .pdf, .rtf, .rtfd, .flatRTFD, .html, .plainText, .text, .commaSeparatedText, .json, .xml, .sourceCode,
        UTType("net.daringfireball.markdown"), UTType("org.openxmlformats.wordprocessingml.document"),
        UTType("com.microsoft.word.doc"), UTType("org.oasis-open.opendocument.text"),
    ].compactMap { $0 }

    static var directory: URL { AttachmentStore.directory }

    static func url(_ fileName: String) -> URL { directory.appendingPathComponent(fileName) }
    static func originalURL(of document: DocumentAttachment) -> URL { url(document.fileName) }
    static func figureURL(_ figure: DocumentFigure) -> URL { url(figure.imageFileName) }

    /// Whether a file is a document the composer takes (and not a picture).
    static func accepts(_ url: URL) -> Bool {
        guard let type = (try? url.resourceValues(forKeys: [.contentTypeKey]).contentType) ?? UTType(filenameExtension: url.pathExtension) else { return false }
        return !type.conforms(to: .image) && contentTypes.contains { type.conforms(to: $0) }
    }

    /// Every file a document keeps, for clearing the attachments folder.
    static func fileNames(of document: DocumentAttachment) -> [String] {
        [document.fileName, document.textFileName] + (document.figures ?? []).map(\.imageFileName)
    }

    // MARK: Text

    nonisolated(unsafe) private static var cache: [String: String] = [:]
    private static let cacheLock = NSLock()

    /// The document's text with page marks. Kept in memory: the context gauge asks for it with every redraw.
    static func text(of document: DocumentAttachment) -> String {
        cacheLock.lock()
        defer { cacheLock.unlock() }
        if let text = cache[document.textFileName] { return text }
        let text = (try? String(contentsOf: url(document.textFileName), encoding: .utf8)) ?? ""
        cache[document.textFileName] = text
        return text
    }

    // MARK: Import

    /// What the import is doing, for the chip in the composer.
    typealias Progress = @Sendable (String) -> Void

    /// Copies the file into the library and reads its text: a PDF page by page (recognising pages that are only a
    /// picture), with its figures cut out; other formats as a whole.
    static func importDocument(_ source: URL, progress: @escaping Progress = { _ in }) async throws -> DocumentAttachment {
        try await Task.detached(priority: .userInitiated) {
            try read(source, progress: progress)
        }.value
    }

    private static func read(_ source: URL, progress: Progress) throws -> DocumentAttachment {
        let name = source.lastPathComponent
        let id = UUID()
        let ext = source.pathExtension.isEmpty ? "" : "." + source.pathExtension.lowercased()
        var document = DocumentAttachment(id: id, name: name, fileName: id.uuidString + ext, textFileName: id.uuidString + ".txt", characterCount: 0)

        let text: String
        let type = (try? source.resourceValues(forKeys: [.contentTypeKey]).contentType) ?? UTType(filenameExtension: source.pathExtension)
        if type?.conforms(to: .pdf) == true {
            guard let pdf = PDFDocument(url: source) else { throw DocumentError.unsupported(name) }
            guard pdf.pageCount <= maxPages else { throw DocumentError.tooLarge(name) }
            let result = PDFReader.read(pdf, documentID: id, progress: progress)
            text = result.text
            document.pageCount = pdf.pageCount
            document.recognizedPages = result.recognizedPages.isEmpty ? nil : result.recognizedPages
            document.figures = result.figures.isEmpty ? nil : result.figures
        } else {
            progress("Text wird gelesen …")
            do {
                text = try DocumentText.extract(from: source)
            } catch {
                throw DocumentError.unsupported(name)
            }
        }
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || document.figures != nil else {
            throw DocumentError.noText(name)
        }
        document.characterCount = text.count

        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try FileManager.default.copyItem(at: source, to: originalURL(of: document))
            try text.write(to: url(document.textFileName), atomically: true, encoding: .utf8)
        } catch {
            for file in fileNames(of: document) { try? FileManager.default.removeItem(at: url(file)) }
            throw DocumentError.writeFailed(name)
        }
        cacheLock.lock()
        cache[document.textFileName] = text
        cacheLock.unlock()
        return document
    }
}
