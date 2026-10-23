import Foundation

/// What the model is asked when a presentation is made from a document: the outline of a text without headings, and
/// the points of each slide from its passage.
extension PresenterPrompts {
    // MARK: Outline from the text

    struct DocumentOutline: Decodable {
        struct Chapter: Decodable {
            let titel: String
            let folien: [Slide]
        }

        struct Slide: Decodable {
            let titel: String
            /// The paragraphs of the text this slide is about, as numbered in the request.
            let von: Int
            let bis: Int
        }

        let titel: String
        let untertitel: String
        let kapitel: [Chapter]
    }

    static let documentOutlineSchema = ContentAnalysisBuilder.Schema.object([
        ("titel", .string),
        ("untertitel", .string),
        ("kapitel", .array(.object([
            ("titel", .string),
            ("folien", .array(.object([("titel", .string), ("von", .integer), ("bis", .integer)]), max: 6)),
        ]), max: 6)),
    ])

    static let documentOutlineSystemPrompt = """
    Du machst aus einem vorhandenen Text eine Präsentation. Du bekommst den Text mit nummerierten Absätzen, z. B. [3], \
    und gliederst ihn in Kapitel und Folien. Danach werden die Folien einzeln aus den Absätzen ausgearbeitet.

    Regeln:
    - Sprache: die des Textes (meist Deutsch).
    - „titel“: der Titel der Präsentation, kurz und klar (der Titel des Textes, wenn er einen hat). „untertitel“: eine Zeile, worum es geht.
    - Gliedere in 2 bis 4 Kapitel mit je 2 bis 4 Folien, zusammen 5 bis 12 Folien – bei kurzen Texten weniger.
    - Die Folien folgen der Reihenfolge des Textes. „von“ und „bis“ sind die Nummern des ersten und des letzten Absatzes, \
    aus denen die Folie entsteht; zwei Folien teilen sich keinen Absatz, kein Absatz mit Inhalt fehlt.
    - Kapiteltitel und Folientitel: höchstens 6 Wörter, ohne Nummern, ohne Doppelpunkt am Ende, so, dass man den Inhalt ahnt.
    - Bleib bei dem, was im Text steht. Erfinde nichts dazu.
    """

    static func documentOutlineMessages(source: ContentAnalysisBuilder.Source, title: String) -> [ChatPayloadMessage] {
        var lines: [String] = []
        if !title.isEmpty { lines.append("Titel des Textes: „\(title)“\n") }
        lines.append("TEXT\n")
        lines.append(source.text)
        return [
            ChatPayloadMessage(role: "system", content: documentOutlineSystemPrompt),
            ChatPayloadMessage(role: "user", content: lines.joined(separator: "\n")),
        ]
    }

    // MARK: Points of a slide

    static let slideFromTextSystemPrompt = """
    Du arbeitest eine Folie einer Präsentation aus einem vorhandenen Text aus. Auf die Folie kommen 3 bis 5 Stichpunkte; \
    das Erklären übernimmt später der Vortragende.

    Regeln:
    - Sprache: die des Textes (meist Deutsch).
    - Fasse die wichtigsten Aussagen des Textabschnitts zusammen, in der Reihenfolge des Textes. Nur, was im Abschnitt steht.
    - Jeder Stichpunkt höchstens 12 Wörter, ohne Punkt am Ende, ohne Aufzählungszeichen und ohne Nummer.
    - Konkret: Begriffe, Zusammenhänge, Beispiele, Zahlen aus dem Text. Keine Füllsätze wie „Wichtiges Thema“.
    - Im Abschnitt markieren „[Formel]“, „[Code-Block]“, „[Tabelle]“ und „[Bild]“ nur die Stellen, an denen ein Objekt \
    steht; es kommt unverändert auf die Folie. Schreibe diese Markierungen nie in einen Stichpunkt, und schreib nicht ab, \
    was darin steht; nenne in einem Stichpunkt höchstens, was es zeigt.
    - Höchstens zwei Begriffe der ganzen Folie dürfen **fett** sein, nur die wichtigsten.
    """

    static func slideFromTextMessages(presentationTitle: String, chapter: String?, slideTitles: [String], slideTitle: String,
                                      passage: String, hint: String, carriesObjects: Bool) -> [ChatPayloadMessage] {
        var lines = ["Präsentation: „\(presentationTitle)“", "", "Folien:"]
        for title in slideTitles { lines.append("– \(title)" + (title == slideTitle ? "   ← diese Folie" : "")) }
        lines.append("")
        if let chapter { lines.append("Kapitel: „\(chapter)“") }
        lines.append("Folie: „\(slideTitle)“")
        if !hint.isEmpty { lines.append("Was die Folie zeigen soll: \(hint)") }
        if carriesObjects { lines.append("Formeln, Code, Tabellen und Bilder des Abschnitts kommen unverändert auf die Folie.") }
        lines.append("")
        lines.append("TEXTABSCHNITT\n\"\"\"\n\(passage)\n\"\"\"")
        return [
            ChatPayloadMessage(role: "system", content: slideFromTextSystemPrompt),
            ChatPayloadMessage(role: "user", content: lines.joined(separator: "\n")),
        ]
    }

    /// A chapter slide has no points; its text only serves the speaker card.
    static let subtitleSystemPrompt = """
    Du schreibst den Untertitel einer Präsentation: eine Zeile (höchstens 12 Wörter), die sagt, worum es geht. \
    Sprache wie der Text. Nur die Zeile, ohne Anführungszeichen, ohne Punkt am Ende.
    """

    static func subtitleMessages(title: String, text: String) -> [ChatPayloadMessage] {
        [
            ChatPayloadMessage(role: "system", content: subtitleSystemPrompt),
            ChatPayloadMessage(role: "user", content: "Titel: „\(title)“\n\nText (Anfang):\n\"\"\"\n\(text)\n\"\"\""),
        ]
    }
}
