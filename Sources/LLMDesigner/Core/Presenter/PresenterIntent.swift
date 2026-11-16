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
    /// `speakerNotes`: only the open slide's card ("für diese Folie").
    var thisSlide = false

    var label: String {
        switch kind {
        case .createDeck: withNotes ? "erstellt Folien und Karten" : "erstellt die Folien"
        case .speakerNotes: thisSlide ? "schreibt die Moderatorenkarte" : "schreibt alle Moderatorenkarten"
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

    /// Reads the instruction by whole words, so a sentence about the slide's own text ("wie in einer Präsentation
    /// über …", "präsentierbarer", "Planeten") doesn't make a presentation or start the full screen. When in doubt it
    /// says nil: the instruction then goes onto the slide, which is easy to take back.
    static func detect(_ instruction: String) -> PresenterIntent? {
        var text = " " + instruction.lowercased()
            .replacingOccurrences(of: "\n", with: " ")
            .folding(options: [.widthInsensitive], locale: Locale(identifier: "de_DE")) + " "
        func matches(_ pattern: String) -> Bool { text.range(of: pattern, options: .regularExpression) != nil }

        // Asking how something is done or what it means is answered, not carried out.
        let explains = matches(#"^\s*(bitte\s+)?((kannst|könntest|würdest)\s+du\s+(mir\s+)?)?(erklär\w*|beschreib\w*|wie|warum|weshalb|wieso|was|welche\w*)\b"#)
        if explains { return nil }
        // A presentation only mentioned, not asked for: "wie in einer Präsentation über …", "keine Präsentation".
        text = text.replacingOccurrences(
            of: #"\b(in|aus|von|wie|auf|bei|nach|an|mit)\s+(einer|der|dieser|meiner|deiner|unserer|eurer|ihrer)\s+(präsentation|vortrag\w*|vorführung)\b|\bkeine[nm]?\s+(präsentation|vortrag|folien|foliensatz)\b"#,
            with: " ", options: .regularExpression
        )

        let notes = matches(#"\b(moderatorenkarte|moderationskarte|moderatorkarte|sprechertext|sprechtext|redetext|vortragstext|sprechernotiz|speaker notes?\b)"#)
        let creates = matches(#"\b(erstell(e|en|st)?|mach(e|en|st)?|bau(e|en|st)?|generier(e|en|st)?|entwirf|entwerf(e|en)|entwick(e)?l(e|n|en)?|gestalt(e|en)|schreib(e|en|st)?|leg(e|en|st)?|anleg(e|en)|erzeug(e|en|st)?|plan(e|en|st)?|vorbereite(n)?|bereite(n|st)?|ergänz(e|en|st)?|füg(e|en|st)?|hinzufüg(e|en)|formulier(e|en|st)?|verfass(e|en|st)?|produzier(e|en)?|zusammenstell(e|en)|create|make|build|write|generate|prepare|draft)\b"#)
        let rewrites = matches(#"\b(neu|überarbeit\w*|nochmal|noch einmal|verbesser\w*)\b"#)
        let presents = matches(#"\bpräsentier(e)?\b"#)
            || matches(#"\btrag(e)?\b(\s+\S+){0,4}?\s+vor(?=\s*([.!?,;]|$|und\b))"#)
            || matches(#"\bführ(e)?\b(\s+\S+){0,4}?\s+vor(?=\s*([.!?,;]|$|und\b))"#)
            || matches(#"\b(halt|halte)\s+den\s+vortrag\b"#)
            || matches(#"\bstarte?\s+(den\s+vortrag|die\s+präsentation|die\s+vorführung)\b"#)
            || (matches(#"\b(vortragen|vorführen|präsentieren)\b"#) && matches(#"\b(kannst|könntest|würdest|bitte|jetzt|lass)\b"#))
        // A whole presentation, not text on this slide: "eine Präsentation über …", "zehn Folien zu …".
        let wholeDeck = matches(#"\b(eine|einen|neue[nm]?|ganze[nm]?|komplette[nm]?|kurze[nm]?|längere[nm]?|weitere[nm]?)\s+(präsentation|vortrag|vorführung|foliensatz)\b"#)
            || matches(#"\b(präsentation|vortrag|foliensatz)\s+(über|zu|zum|zur|mit|für|darüber)\b"#)
            || matches(#"\b(\d+|zwei|drei|vier|fünf|sechs|sieben|acht|neun|zehn|elf|zwölf|ein paar|einige|mehrere|neue|weitere|zusätzliche|mehr)\s+(neue\s+|weitere\s+)?folien\b"#)
            || matches(#"(?<!\bdie )(?<!\bden )(?<!\bdiese )(?<!\bdiesen )(?<!\bmeine )(?<!\bunsere )\bfolien\s+(über|zu|zum|zur|für)\b"#)
            || matches(#"\bfoliensätze\b|\bslide deck\b|\b(\d+|some|a few|new)\s+slides\b|\bslides?\s+(about|on)\b|\b(a|an)\s+presentation\b"#)

        if wholeDeck, creates {
            return PresenterIntent(kind: .createDeck, withNotes: notes, presents: presents)
        }
        // The cards: asked for in so many words ("Schreib …", "… neu", "… bitte"), or the instruction is nothing but
        // that ("Moderatorenkarten für alle Folien"); a remark about a card ("Die Karte ist zu lang") is not.
        let onlyCards = matches(#"^\s*(die\s+|alle\s+)?(moderatorenkarte\w*|moderationskarte\w*|sprechertext\w*|speaker notes)(\s+(für|zu)\s+(alle|allen|jede|jeder)\b[^.!?]*)?[.!]?\s*$"#)
        if notes, creates || rewrites || onlyCards || matches(#"\bbitte\b"#) {
            let thisSlide = matches(#"\b(diese|dieser|diesen|aktuelle[nr]?|offene[nr]?)\s+folie\b|\bhier\b"#)
            return PresenterIntent(kind: .speakerNotes, rewritesNotes: rewrites, presents: presents, thisSlide: thisSlide)
        }
        if presents {
            return PresenterIntent(kind: .present, presents: true)
        }
        return nil
    }
}
