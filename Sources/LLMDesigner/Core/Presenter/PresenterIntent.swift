import Foundation

/// An instruction in Presenter Studio's assistant bar that is about the whole presentation rather than the open
/// slide: "Erstelle mir eine Präsentation über Predictive Coding", "Schreib Moderatorenkarten", "Trag sie vor".
/// Everything else is written on the slide as in Writer Studio.
struct PresenterIntent: Equatable {
    enum Kind: Equatable {
        /// The model makes the slides: an outline first, then each slide's content.
        case createDeck
        /// The model writes the speaker notes of every slide.
        case speakerNotes
        /// The model presents the slides in full screen.
        case present
    }

    var kind: Kind
    /// `createDeck`: speaker notes for the new slides afterwards.
    var withNotes = false
    /// `speakerNotes`: notes that are there are written anew.
    var rewritesNotes = false
    /// Afterwards the model presents.
    var presents = false

    var label: String {
        switch kind {
        case .createDeck: withNotes ? "erstellt Folien und Karten" : "erstellt die Folien"
        case .speakerNotes: "schreibt alle Moderatorenkarten"
        case .present: "präsentiert"
        }
    }

    var symbol: String {
        switch kind {
        case .createDeck: "rectangle.stack.badge.plus"
        case .speakerNotes: "text.bubble"
        case .present: "person.wave.2"
        }
    }

    static func detect(_ instruction: String) -> PresenterIntent? {
        let text = " " + instruction.lowercased()
            .replacingOccurrences(of: "\n", with: " ")
            .folding(options: [.widthInsensitive], locale: Locale(identifier: "de_DE")) + " "
        func has(_ words: [String]) -> Bool { words.contains { text.contains($0) } }

        let notes = has(["moderatorenkarte", "moderationskarte", "moderatorkarte", "sprechertext", "sprechtext", "redetext", "vortragstext", "sprechernotiz"])
        let creates = has(["erstell", "mach", "bau", "generier", "entw", "gestalt", "schreib", "leg ", "lege ", "anleg", "erzeug", "plan", "bereite", "ergänz", "füg", "formulier", "verfass"])
        let presents = has(["präsentier", " trag sie vor", " trag die ", " trag vor", "vortragen", "halte den vortrag", "halt den vortrag", "führ sie vor", "führ vor", "vorführen", "starte den vortrag", "starte die präsentation", "starte die vorführung"])
        // A whole presentation, not text on this slide: "eine Präsentation über …", "zehn Folien zu …".
        let wholeDeck = has([
            "präsentation über", "präsentation zu", "präsentation zum", "präsentation zur", "präsentation mit", "präsentation für",
            "präsentation darüber", "eine präsentation", "neue präsentation", "ganze präsentation", "vortrag über", "vortrag zu",
            "folien über", "folien zu", "folien zum", "folien zur", "folien für", "foliensatz", "slides", "neue folien", "weitere folien",
        ]) || text.range(of: #"\b\d+\s+folien"#, options: .regularExpression) != nil
            || has(["drei folien", "vier folien", "fünf folien", "sechs folien", "sieben folien", "acht folien", "neun folien", "zehn folien", "zwölf folien"])

        if wholeDeck, creates {
            return PresenterIntent(kind: .createDeck, withNotes: notes, presents: presents)
        }
        if notes, creates || !has(["?"]) {
            let anew = has([" neu ", " neu.", " neu,", "überarbeit", "nochmal", "noch einmal", "alle neu", "verbesser"])
            return PresenterIntent(kind: .speakerNotes, rewritesNotes: anew, presents: presents)
        }
        if presents {
            return PresenterIntent(kind: .present, presents: true)
        }
        return nil
    }
}
