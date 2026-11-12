import AppKit
import CoreText
import Testing
@testable import LLMDesigner

/// Neutral test documents, made on the spot.
enum TestDocuments {
    /// Page 1: text, a bar chart drawn as shapes with a caption under it. Page 2: a "scan", text only as a picture.
    static func pdf() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("Testbericht-\(UUID().uuidString.prefix(6)).pdf")
        var box = CGRect(x: 0, y: 0, width: 595, height: 842)
        let context = try #require(CGContext(url as CFURL, mediaBox: &box, nil))

        context.beginPDFPage(nil)
        draw("Erster Absatz über Leuchttürme an der Küste.", at: CGPoint(x: 60, y: 760), size: 14, in: context)
        draw("Zweiter Absatz mit weiteren Angaben zur Messreihe.", at: CGPoint(x: 60, y: 740), size: 14, in: context)
        context.setFillColor(CGColor(gray: 0.3, alpha: 1))
        for bar in 0..<5 {
            context.fill(CGRect(x: 100 + CGFloat(bar) * 60, y: 450, width: 40, height: 40 + CGFloat(bar) * 40))
        }
        context.setStrokeColor(CGColor(gray: 0, alpha: 1))
        context.setLineWidth(1.5)
        context.strokeLineSegments(between: [CGPoint(x: 90, y: 446), CGPoint(x: 420, y: 446), CGPoint(x: 90, y: 446), CGPoint(x: 90, y: 660)])
        draw("Abb. 1: Testbalken der Messreihe", at: CGPoint(x: 100, y: 422), size: 12, in: context)
        draw("Text unter der Abbildung.", at: CGPoint(x: 60, y: 380), size: 14, in: context)
        context.endPDFPage()

        context.beginPDFPage(nil)
        let scan = try #require(picture(of: "Gescannter Bericht vom Leuchtturm", width: 1240, height: 400))
        context.draw(scan, in: CGRect(x: 0, y: 500, width: 595, height: 192))
        context.endPDFPage()
        context.closePDF()
        return url
    }

    static func text(_ content: String, name: String = "Notiz") throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(name)-\(UUID().uuidString.prefix(6)).txt")
        try content.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    private static func draw(_ text: String, at point: CGPoint, size: CGFloat, in context: CGContext) {
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: [
            .font: NSFont.systemFont(ofSize: size), .foregroundColor: NSColor.black,
        ]))
        context.textPosition = point
        CTLineDraw(line, context)
    }

    private static func picture(of text: String, width: Int, height: Int) -> CGImage? {
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return nil }
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        draw(text, at: CGPoint(x: 40, y: 170), size: 64, in: context)
        return context.makeImage()
    }
}

@MainActor
@Suite struct DocumentAttachmentTests {
    init() { _ = TestApp.model() }

    @Test func pdfGivesTextScanAndFigure() async throws {
        let url = try TestDocuments.pdf()
        defer { try? FileManager.default.removeItem(at: url) }
        let document = try await DocumentStore.importDocument(url)

        #expect(document.pageCount == 2)
        #expect(document.recognizedPages == [2])
        let text = DocumentStore.text(of: document)
        #expect(text.hasPrefix("[Seite 1]\n"))
        #expect(text.contains("Leuchttürme an der Küste"))
        #expect(text.contains("[Seite 2]"))
        #expect(text.contains("Leuchtturm"), "Die Texterkennung liest die gescannte Seite")

        let figures = try #require(document.figures)
        #expect(figures.count == 1)
        let figure = try #require(figures.first)
        #expect(figure.page == 1)
        #expect(figure.caption == "Abb. 1: Testbalken der Messreihe")
        #expect(FileManager.default.fileExists(atPath: DocumentStore.figureURL(figure).path))
        #expect(figure.width > 300 && figure.height > 200)
        #expect(FileManager.default.fileExists(atPath: DocumentStore.originalURL(of: document).path))
    }

    @Test func figurePlaceholderFollowsItsCaption() async throws {
        let url = try TestDocuments.pdf()
        defer { try? FileManager.default.removeItem(at: url) }
        var document = try await DocumentStore.importDocument(url)
        let lines = DocumentPrompt.fullText(of: document).components(separatedBy: "\n")
        let caption = try #require(lines.firstIndex(of: "Abb. 1: Testbalken der Messreihe"))
        #expect(lines[caption + 1] == "[Abbildung 1, Seite 1: „Abb. 1: Testbalken der Messreihe“] (Das Bild selbst ist nicht dabei.)")

        document.figures?[0].description = "Fünf graue Balken, nach rechts steigend."
        document.figures?[0].describedBy = "lmstudio/qwen-vl"
        let described = DocumentPrompt.fullText(of: document)
        #expect(described.contains("[Beschreibung von Abbildung 1, erstellt von qwen-vl, nicht geprüft: Fünf graue Balken, nach rechts steigend.]"))
        #expect(!described.contains("Das Bild selbst ist nicht dabei"))
    }

    @Test func longDocumentsComeWithTheirBeginning() async throws {
        let pages = (1...40).map { "[Seite \($0)]\n" + String(repeating: "Satz auf Seite \($0). ", count: 60) }.joined(separator: "\n\n")
        let url = try TestDocuments.text(pages, name: "Lang")
        defer { try? FileManager.default.removeItem(at: url) }
        let document = try await DocumentStore.importDocument(url)

        let budget = DocumentPrompt.budget(contextTokens: 8_192, documentCount: 1)
        let block = DocumentPrompt.block(for: document, budget: budget, toolsAvailable: true)
        #expect(block.isShortened)
        #expect(block.text.contains("Ab Seite") == false || block.text.contains("fehlt hier"))
        #expect(block.text.contains("read_file"))
        #expect(block.text.count < budget + 1_000)
        #expect(!DocumentPrompt.block(for: document, budget: budget, toolsAvailable: false).text.contains("read_file"))
        #expect(!DocumentPrompt.block(for: document, budget: 1_000_000, toolsAvailable: true).isShortened)

        // The rest is reachable with the same tools as a persona's files.
        let tools = try #require(PersonaFileTools(persona: nil, documents: [document]))
        #expect(tools.systemHint.contains(document.name))
        let (step, output) = await tools.execute(ToolStep(kind: .fileSearch, argument: "Seite 37"), limit: 8_000)
        #expect(step.status == .done)
        #expect(output.contains("Seite 37"))
    }

    @Test func frameStaysTheSameForTheSameDocument() async throws {
        let url = try TestDocuments.text("Kurzer Inhalt.")
        defer { try? FileManager.default.removeItem(at: url) }
        let document = try await DocumentStore.importDocument(url)
        let first = DocumentPrompt.block(for: document, budget: 10_000, toolsAvailable: false).text
        let second = DocumentPrompt.block(for: document, budget: 10_000, toolsAvailable: false).text
        #expect(first == second, "Sonst verdirbt jede Frage den Präfix-Cache")
        #expect(first.contains("----- Anfang der Datei „\(document.name)“ (Kennung ") && first.contains("Kurzer Inhalt.\n----- Ende der Datei"))
        #expect(first.contains("vollständiger Text"))
    }

    @Test func picturesAndUnknownFilesAreNotDocuments() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("Bild-\(UUID().uuidString.prefix(6)).png")
        try Data([0x89, 0x50, 0x4E, 0x47]).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        #expect(!DocumentStore.accepts(url))
        let pdf = try TestDocuments.pdf()
        defer { try? FileManager.default.removeItem(at: pdf) }
        #expect(DocumentStore.accepts(pdf))

        let empty = try TestDocuments.text("   \n  ")
        defer { try? FileManager.default.removeItem(at: empty) }
        await #expect(throws: DocumentError.self) { try await DocumentStore.importDocument(empty) }
    }

    @Test func documentsInAChatCountAsForeignAndPrivate() async throws {
        let url = try TestDocuments.text("Inhalt.")
        defer { try? FileManager.default.removeItem(at: url) }
        let document = try await DocumentStore.importDocument(url)
        let message = ChatMessage(role: .user, content: "Fass zusammen und vergleiche mit https://example.org/", documents: [document])

        let evidence = WebToolGuard.ChatEvidence(messages: [message])
        #expect(evidence.hasDocuments)
        guard case .needsConsent(let request) = WebToolGuard.verdict(for: ToolStep(kind: .openPage, argument: "https://example.org/"), evidence: evidence) else {
            Issue.record("Eine Seite öffnen muss in einem Chat mit Anhang fragen")
            return
        }
        #expect(request.reason.contains("hängen Dokumente"))
        #expect(message.hasContent)
    }
}
