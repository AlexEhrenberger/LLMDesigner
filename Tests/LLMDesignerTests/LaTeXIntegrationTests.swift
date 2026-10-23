import Testing
import Foundation
@testable import LLMDesigner

/// Sets documents with the real LaTeX engine (skipped where none is installed).
@Suite("LaTeX-Satz")
struct LaTeXIntegrationTests {
    private func typeset(_ markdown: String, typeface: WriterFont?) async throws -> Data? {
        guard let engine = LaTeXEngine.locate() else { return nil }
        var part = LaTeXWriter.Part(text: markdown)
        part.figures = [:]
        return try await engine.makePDF(parts: [part], paper: .a4, typeface: typeface)
    }

    @Test func coloursAndFontsCompile() async throws {
        let markdown = """
        # Farben und Schriften

        Normaler Text mit <span style="color:#C0392B">rotem</span>, <span style="color:#1F5FBF;font-family:'Georgia'">blauem Georgia</span> und <span style="font-family:'Futura'">**fettem** Futura</span>.

        - Liste mit <span style="color:#1E8449">grünem Wort</span>
        - <u>unterstrichen **fett** weiter</u>

        | Spalte | <span style="color:#7B3FC4">Violett</span> |
        | --- | --- |
        | a | b |

        """
        for typeface in [WriterFont.serif, .sans, .georgia, .mono] {
            guard let pdf = try await typeset(markdown, typeface: typeface) else { return }
            #expect(pdf.count > 5_000)
            if let directory = ProcessInfo.processInfo.environment["LLMD_PDF_OUT"] {
                try pdf.write(to: URL(fileURLWithPath: directory).appendingPathComponent("style-\(typeface.rawValue).pdf"))
            }
        }
    }
}
