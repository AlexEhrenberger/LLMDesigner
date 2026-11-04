import Foundation

/// Prompts of the Writer Studio assistant and the parsing of its answers.
enum WriterPrompts {
    /// Where the assistant writes, in the document text it gets.
    static let cursorMarker = "⟦KI⟧"
    static let selectionStart = "⟦MARKIERUNG⟧"
    static let selectionEnd = "⟦/MARKIERUNG⟧"

    /// What fits of a document into the prompt: the part around the cursor or the marked text.
    static func window(of markdown: String, limit: Int) -> String {
        guard markdown.count > limit else { return markdown }
        let anchor = markdown.range(of: cursorMarker) ?? markdown.range(of: selectionStart)
        let center = anchor.map { markdown.distance(from: markdown.startIndex, to: $0.lowerBound) } ?? markdown.count
        let before = Int(Double(limit) * 0.7)
        let start = max(0, min(center - before, markdown.count - limit))
        let lower = markdown.index(markdown.startIndex, offsetBy: start)
        let upper = markdown.index(lower, offsetBy: min(limit, markdown.count - start))
        return (start > 0 ? "[…]\n" : "") + markdown[lower..<upper] + (upper < markdown.endIndex ? "\n[…]" : "")
    }

    // MARK: Presets

    enum Rewrite: String, CaseIterable, Identifiable {
        case rephrase, shorter, longer, casual, formal, simpler

        var id: String { rawValue }

        var label: String {
            switch self {
            case .rephrase: "Umformulieren"
            case .shorter: "Kürzer"
            case .longer: "Länger"
            case .casual: "Lockerer"
            case .formal: "Formeller"
            case .simpler: "Einfacher"
            }
        }

        var instruction: String {
            switch self {
            case .rephrase: "Formuliere den markierten Text neu. Inhalt und Länge bleiben ungefähr gleich."
            case .shorter: "Formuliere den markierten Text kürzer und knapper. Das Wichtigste bleibt erhalten."
            case .longer: "Formuliere den markierten Text ausführlicher, mit mehr Erklärung und Beispielen, aber ohne neue Behauptungen zu erfinden."
            case .casual: "Formuliere den markierten Text lockerer und persönlicher, wie im Gespräch."
            case .formal: "Formuliere den markierten Text formeller und sachlicher, wie in einem offiziellen Schreiben."
            case .simpler: "Formuliere den markierten Text in einfacher, leicht verständlicher Sprache mit kurzen Sätzen."
            }
        }
    }

    static let expandInstruction = """
        Mach aus den markierten Stichpunkten einen zusammenhängenden, logisch aufgebauten Fließtext in ganzen Sätzen. \
        Ordne die Punkte so, dass der Text einen sinnvollen Ablauf hat. Behalte alle Informationen und erfinde keine neuen Fakten dazu.
        """

    // MARK: Kinds of requests

    /// What the assistant does with an instruction.
    enum Mode: String, CaseIterable, Identifiable {
        /// Writes new text at the AI cursor.
        case write
        /// Rewrites the selection; the result is a proposal.
        case rewrite
        /// Only answers, the document stays as it is.
        case answer

        var id: String { rawValue }
    }

    /// Questions ("Ist das plausibel?", "Was meint …") get an answer; everything else is writing.
    static func looksLikeQuestion(_ instruction: String) -> Bool {
        let text = instruction.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.hasSuffix("?") { return true }
        let first = text.split(whereSeparator: { $0.isWhitespace || $0 == "," }).first.map { $0.lowercased() } ?? ""
        let questionWords: Set<String> = [
            "ist", "sind", "stimmt", "stimmen", "was", "wie", "warum", "wieso", "weshalb", "wer", "wo", "wann",
            "welche", "welcher", "welches", "gibt", "kann", "können", "erkläre", "erklär", "prüfe", "prüf",
            "bewerte", "beurteile", "findest", "passt", "macht", "hältst",
        ]
        return questionWords.contains(first)
    }

    // MARK: Messages

    static func write(document: String, instruction: String) -> [ChatPayloadMessage] {
        let system = """
            Du bist der Schreibassistent in einer Textverarbeitung. Der Nutzer schreibt ein Dokument und gibt dir Anweisungen. \
            Dein Text wird an der Stelle \(cursorMarker) in das Dokument eingefügt.

            So antwortest du:
            - Nur der Text, der eingefügt wird. Keine Einleitung wie „Hier ist …“, keine Rückfrage, kein Kommentar danach.
            - Er schließt an das an, was vor \(cursorMarker) steht, und wiederholt nichts, was schon im Dokument steht.
            - Sprache und Stil wie im Dokument; ist das Dokument leer, auf Deutsch.
            - Formatierung als Markdown: Absätze durch eine Leerzeile, **fett**, *kursiv*, Listen mit „- “. Überschriften (## …) nur, wenn die Anweisung danach verlangt.
            - Verlangt die Anweisung ein Diagramm (Ablauf, Mindmap, Zeitstrahl, Sequenz, Gantt, Kreisdiagramm …), schreibe es als Mermaid-Codeblock \
            (```mermaid … ```); die Textverarbeitung zeichnet daraus das Bild. Knoten-IDs ohne Leerzeichen, Text mit Klammern oder Doppelpunkt in "…".
            """
        let user = """
            Dokument (\(cursorMarker) ist die Stelle, an der dein Text eingefügt wird):
            \"\"\"
            \(document)
            \"\"\"

            Anweisung: \(instruction)
            """
        return [ChatPayloadMessage(role: "system", content: system), ChatPayloadMessage(role: "user", content: user)]
    }

    static func rewrite(document: String, selection: String, instruction: String) -> [ChatPayloadMessage] {
        let system = """
            Du bist der Schreibassistent in einer Textverarbeitung. Der Nutzer hat eine Stelle im Dokument markiert \
            (\(selectionStart) … \(selectionEnd)) und möchte sie überarbeitet haben.

            So antwortest du:
            - Nur der neue Text, der die Markierung ersetzt. Keine Einleitung, keine Erklärung, keine Anführungszeichen drumherum.
            - Er passt nahtlos zum Text davor und danach.
            - Sprache wie im markierten Text.
            - Formatierung als Markdown, so wie im markierten Text (Listen bleiben Listen, außer die Anweisung sagt etwas anderes).
            """
        let user = """
            Dokument:
            \"\"\"
            \(document)
            \"\"\"

            Markierter Text:
            \"\"\"
            \(selection)
            \"\"\"

            Anweisung: \(instruction)
            """
        return [ChatPayloadMessage(role: "system", content: system), ChatPayloadMessage(role: "user", content: user)]
    }

    static func answer(document: String, selection: String?, question: String) -> [ChatPayloadMessage] {
        let system = """
            Du hilfst einem Nutzer beim Schreiben eines Dokuments und beantwortest seine Fragen dazu. \
            Antworte knapp, sachlich und ehrlich, in der Sprache der Frage. Wenn du dir bei Fakten nicht sicher bist, sag das. \
            \(selection == nil ? "" : "Die Frage bezieht sich auf den markierten Text.")
            """
        var user = """
            Dokument:
            \"\"\"
            \(document)
            \"\"\"

            """
        if let selection {
            user += """
                Markierter Text:
                \"\"\"
                \(selection)
                \"\"\"

                """
        }
        user += "Frage: \(question)"
        return [ChatPayloadMessage(role: "system", content: system), ChatPayloadMessage(role: "user", content: user)]
    }

    // MARK: Checks

    enum Check: String, CaseIterable, Identifiable {
        /// Spelling, grammar, punctuation, sentence structure.
        case language
        /// Facts, contradictions, logic.
        case plausibility

        var id: String { rawValue }

        var title: String {
            switch self {
            case .language: "Rechtschreibung & Grammatik"
            case .plausibility: "Plausibilität"
            }
        }
    }

    static let checkSchemaName = "pruefung"

    static func checkSchema(_ check: Check) -> [String: Any] {
        let kinds: [String] = check == .language
            ? ["Rechtschreibung", "Grammatik", "Zeichensetzung", "Satzbau"]
            : ["Falsch", "Fragwürdig", "Widerspruch", "Unlogisch"]
        return [
            "type": "object",
            "properties": [
                "probleme": [
                    "type": "array",
                    "items": [
                        "type": "object",
                        "properties": [
                            "art": ["type": "string", "enum": kinds],
                            "original": ["type": "string"],
                            "korrektur": ["type": "string"],
                            "erklaerung": ["type": "string"],
                        ],
                        "required": ["art", "original", "korrektur", "erklaerung"],
                        "additionalProperties": false,
                    ],
                ],
            ],
            "required": ["probleme"],
            "additionalProperties": false,
        ]
    }

    static func check(_ check: Check, text: String) -> [ChatPayloadMessage] {
        let system: String
        switch check {
        case .language:
            system = """
                Du bist ein sorgfältiger Lektor. Finde im Text Fehler in Rechtschreibung, Grammatik, Zeichensetzung und Satzbau. \
                Geh den Text Satz für Satz und Wort für Wort durch; achte auch auf falsch geschriebene Namen und darauf, \
                ob Subjekt und Verb zusammenpassen.
                Für jeden Fehler:
                - original: die fehlerhafte Stelle, wörtlich und Zeichen für Zeichen so, wie sie im Text steht (nur die betroffenen Wörter, höchstens ein Satz)
                - korrektur: genau diese Stelle, korrigiert
                - erklaerung: ein kurzer Satz, was falsch ist
                Melde nur echte Fehler, keine Geschmacksfragen. Ist der Text fehlerfrei, gib eine leere Liste zurück.
                """
        case .plausibility:
            system = """
                Du prüfst einen Text auf inhaltliche Plausibilität: falsche Fakten, Widersprüche, unlogische Schlüsse und fragwürdige Behauptungen.
                Für jede Stelle:
                - original: die betroffene Aussage, wörtlich und Zeichen für Zeichen so, wie sie im Text steht
                - korrektur: die Aussage richtiggestellt; wenn du die richtige Aussage nicht sicher kennst, ein leerer Text
                - erklaerung: ein bis zwei Sätze, warum die Aussage nicht stimmt oder fragwürdig ist
                Melde nur, was wirklich problematisch ist. Ist alles plausibel, gib eine leere Liste zurück.
                """
        }
        return [
            ChatPayloadMessage(role: "system", content: system),
            ChatPayloadMessage(role: "user", content: "Text:\n\"\"\"\n\(text)\n\"\"\""),
        ]
    }

    // MARK: Comments

    static let commentSchemaName = "kommentare"

    static let commentSchema: [String: Any] = [
        "type": "object",
        "properties": [
            "kommentare": [
                "type": "array",
                "items": [
                    "type": "object",
                    "properties": [
                        "zitat": ["type": "string"],
                        "kommentar": ["type": "string"],
                    ],
                    "required": ["zitat", "kommentar"],
                    "additionalProperties": false,
                ],
            ],
        ],
        "required": ["kommentare"],
        "additionalProperties": false,
    ]

    /// The model reads a piece of the document like an editor and leaves comments in the margin.
    static func comments(text: String) -> [ChatPayloadMessage] {
        let system = """
            Du bist eine aufmerksame Lektorin und schreibst Randkommentare zu einem Text, wie in einer Textverarbeitung.
            Kommentiere, was dem Text weiterhilft: unklare oder missverständliche Stellen, Behauptungen ohne Beleg, Widersprüche,             Lücken in der Argumentation, holprigen Aufbau, Stellen, die ein Beispiel brauchen, und Fragen an den Autor.
            Keine Rechtschreib- oder Kommafehler – dafür gibt es eine eigene Prüfung. Kein Lob ohne Hinweis.
            Für jeden Kommentar:
            - zitat: die Stelle, auf die er sich bezieht, wörtlich und Zeichen für Zeichen so, wie sie im Text steht (3 bis 12 Wörter)
            - kommentar: ein bis zwei kurze Sätze auf Deutsch, freundlich und konkret, in Du-Form
            Höchstens fünf Kommentare. Gibt es nichts zu sagen, eine leere Liste.
            """
        return [
            ChatPayloadMessage(role: "system", content: system),
            ChatPayloadMessage(role: "user", content: "Text:\n\"\"\"\n\(text)\n\"\"\"") ,
        ]
    }

    struct CommentReply: Decodable {
        let zitat: String
        let kommentar: String
    }

    static func parseComments(_ answer: String) -> [CommentReply] {
        let content = ThinkingSplitter.split(answer).content
        guard let start = content.firstIndex(of: "{"), let end = content.lastIndex(of: "}"),
              let data = String(content[start...end]).data(using: .utf8) else { return [] }
        struct Reply: Decodable { let kommentare: [CommentReply] }
        return (try? JSONDecoder().decode(Reply.self, from: data))?.kommentare ?? []
    }

    /// The model answers in a comment's thread, about the commented passage.
    static func commentAnswer(passage: String, context: String, thread: [WriterComment.Entry]) -> [ChatPayloadMessage] {
        let system = """
            Du antwortest in einem Kommentarfaden am Rand eines Dokuments. Der Kommentar bezieht sich auf eine markierte Stelle.
            Antworte kurz (höchstens vier Sätze), konkret und hilfreich auf Deutsch. Schlägst du eine Formulierung vor, gib sie wörtlich an. \
            Keine Einleitung, keine Wiederholung der Frage, kein Markdown außer *kursiv* für Vorschläge.
            """
        let lines = thread.map { "\($0.isAI ? "KI" : $0.author): \($0.text)" }.joined(separator: "\n")
        let user = """
            Markierte Stelle: „\(passage)“

            Umgebung im Dokument:
            \"\"\"
            \(String(context.prefix(3_000)))
            \"\"\"

            Kommentarfaden:
            \(lines.isEmpty ? "(noch leer – schreib einen hilfreichen ersten Kommentar zur Stelle)" : lines)
            """
        return [ChatPayloadMessage(role: "system", content: system), ChatPayloadMessage(role: "user", content: user)]
    }

    struct Finding: Decodable {
        let art: String
        let original: String
        let korrektur: String
        let erklaerung: String
    }

    static func parseCheck(_ answer: String) -> [Finding] {
        let content = ThinkingSplitter.split(answer).content
        guard let start = content.firstIndex(of: "{"), let end = content.lastIndex(of: "}"),
              let data = String(content[start...end]).data(using: .utf8) else { return [] }
        struct Reply: Decodable { let probleme: [Finding] }
        return (try? JSONDecoder().decode(Reply.self, from: data))?.probleme ?? []
    }

    // MARK: Cleaning the written text

    /// Removes what small models like to wrap around the text: an intro line, code fences, quotes, the markers.
    static func clean(_ text: String) -> String {
        var result = ThinkingSplitter.split(text).content
        for marker in [cursorMarker, selectionStart, selectionEnd] {
            result = result.replacingOccurrences(of: marker, with: "")
        }
        result = result.trimmingCharacters(in: .whitespacesAndNewlines)
        // "Hier ist der Absatz:" or "Gerne!" as a first line of its own.
        if let newline = result.firstIndex(of: "\n") {
            let first = result[..<newline].trimmingCharacters(in: .whitespaces).lowercased()
            let intros = ["hier ist", "hier sind", "hier der", "hier die", "hier ein", "gerne", "natürlich", "klar", "sicher", "here is", "here's"]
            if first.count < 80, intros.contains(where: { first.hasPrefix($0) }), [":", "!", "."].contains(where: { first.hasSuffix($0) }) {
                result = String(result[newline...]).trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }
        // A whole answer inside a code fence.
        if result.hasPrefix("```") {
            var lines = result.components(separatedBy: "\n")
            lines.removeFirst()
            if lines.last?.trimmingCharacters(in: .whitespaces).hasPrefix("```") == true { lines.removeLast() }
            result = lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        }
        // A whole answer in quotes.
        for (open, close) in [("\"", "\""), ("„", "“"), ("»", "«")] where result.hasPrefix(open) && result.hasSuffix(close) && result.count > 2 {
            let inner = result.dropFirst(open.count).dropLast(close.count)
            if !inner.contains(open) { result = String(inner) }
        }
        return result
    }

    /// While streaming: the text so far, with an unfinished intro or fence kept out of the document.
    static func cleanPartial(_ text: String) -> String {
        let content = ThinkingSplitter.split(text).content
        let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
        // Wait for the first line before deciding whether it is an intro.
        if !trimmed.contains("\n"), trimmed.count < 80,
           ["hier", "gerne", "natürlich", "klar", "sicher", "```"].contains(where: { trimmed.lowercased().hasPrefix($0) }) {
            return ""
        }
        return clean(content)
    }
}
