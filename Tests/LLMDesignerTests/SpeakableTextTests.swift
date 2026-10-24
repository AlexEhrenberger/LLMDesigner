import Testing
import Foundation
@testable import LLMDesigner

@Suite("Sprechfassung für Qwen TTS")
struct SpeakableTextTests {
    private func spoken(_ text: String, _ language: String = "de") -> String {
        SpeakableText.forVoice(text, language: language)
    }

    @Test func writesOutGermanAbbreviations() {
        #expect(spoken("Daten schützen, z. B. durch Verschlüsselung.") == "Daten schützen, zum Beispiel durch Verschlüsselung.")
        #expect(spoken("Das geht z.B. so, d. h. schnell.") == "Das geht zum Beispiel so, das heißt schnell.")
        #expect(spoken("Es kostet ca. 20 Euro bzw. etwas mehr.") == "Es kostet circa 20 Euro beziehungsweise etwas mehr.")
        #expect(spoken("Dr. Müller liest S. 12 ff.") == "Doktor Müller liest Seite 12 folgende.")
    }

    @Test func keepsTheSentenceEndOfClosingAbbreviations() {
        #expect(spoken("Äpfel, Birnen usw. Danach Kaffee.") == "Äpfel, Birnen und so weiter. Danach Kaffee.")
        #expect(spoken("Äpfel, Birnen usw.") == "Äpfel, Birnen und so weiter.")
        // A capitalised noun after "z. B." is no new sentence.
        #expect(spoken("Viele Formate, z. B. Bilder.") == "Viele Formate, zum Beispiel Bilder.")
    }

    @Test func leavesWordsThatOnlyEndLikeAnAbbreviation() {
        #expect(spoken("Die Hauptstr. 5 und Mica.") == "Die Hauptstr. 5 und Mica.")
        #expect(spoken("Das gilt für Tabellen.") == "Das gilt für Tabellen.")
    }

    @Test func turnsBracketsAndSymbolsIntoSpeech() {
        #expect(spoken("Die Kosten sind um 12,5 % gestiegen (vgl. Abb. 3).")
            == "Die Kosten sind um 12,5 Prozent gestiegen, vergleiche Abbildung 3.")
        #expect(spoken("Forschung & Lehre → Praxis") == "Forschung und Lehre, Praxis")
        #expect(spoken("Von 1990–2000 bei 20 °C") == "Von 1990 bis 2000 bei 20 Grad Celsius")
        #expect(spoken("Er sagte „Hallo“ – und ging.") == "Er sagte Hallo, und ging.")
        #expect(spoken("(Hinweis) Das ist wichtig.") == "Hinweis, Das ist wichtig.")
    }

    @MainActor @Test func shortPiecesJoinTheirNeighbours() {
        let long = "Dieser Absatz ist so lang, dass er für sich allein in einer Anfrage an die Stimme gehen kann. "
        let text = "Einleitung.\n" + String(repeating: long, count: 3) + "\nViel Erfolg!"
        let chunks = SpeechReader.chunks(of: text)
        #expect(chunks.allSatisfy { $0.text.count >= SpeechReader.shortestPiece })
        #expect(chunks.first?.text.hasPrefix("Einleitung. Dieser Absatz") == true)
        #expect(chunks.last?.text.hasSuffix("Viel Erfolg!") == true)
        #expect(NSMaxRange(chunks.last!.range) == (text as NSString).length)
        // A short text stays one piece.
        #expect(SpeechReader.chunks(of: "Ja, genau.").map(\.text) == ["Ja, genau."])
    }

    @Test func englishGetsItsOwnWords() {
        #expect(spoken("Use tools, e.g. a hammer & nails.", "en") == "Use tools, for example a hammer and nails.")
        #expect(spoken("Es kostet 5 %.", "fr") == "Es kostet 5 Prozent.")
    }
}
