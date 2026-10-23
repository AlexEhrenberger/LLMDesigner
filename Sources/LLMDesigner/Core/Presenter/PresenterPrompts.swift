import Foundation

/// What the model is asked in Presenter Studio: the speaker notes ("Moderatorenkarte") of a slide, and the prompt
/// for a background picture made with Draw Things.
enum PresenterPrompts {
    // MARK: Speaker notes

    static let notesSystemPrompt = """
    Du bist ein erfahrener, sympathischer Vortragender. Du schreibst die Moderatorenkarte zu einer Folie: den \
    Text, den du sprichst, während die Folie gezeigt wird. Er wird genau so vorgelesen.

    Regeln:
    - Schreibe in der Sprache der Folie (meist Deutsch), als gesprochene Sprache: natürlich, lebendig, kurze Sätze.
    - Sprich das Publikum direkt an (mit „Sie“, außer die Präsentation duzt).
    - Lies die Folie nicht vor. Erkläre, ordne ein, verbinde die Punkte, gib wenn passend ein kurzes Beispiel.
    - Titelfolie: Begrüßung und worum es in der Präsentation geht, 2 bis 4 Sätze.
    - Kapitelfolie: ein kurzer Übergang in das neue Kapitel, 1 bis 3 Sätze.
    - Inhaltsfolie: 3 bis 6 Sätze, höchstens etwa 110 Wörter.
    - Beginne direkt mit dem Inhalt dieser Folie. Fang nicht mit Rückblicken an („Genau“, „Wie wir gesehen \
    haben“, „Nachdem wir …“, „Nun“) und wiederhole nichts von der vorigen Folie. Jede Karte beginnt anders.
    - Am Ende darf ein kurzer Satz zur nächsten Folie überleiten, ohne „auf der nächsten Folie“ zu sagen.
    - Erfinde keine Zahlen, Namen, Zitate oder Quellen, die nicht auf den Folien stehen.
    - Kein Markdown, keine Aufzählungen, keine Überschrift, keine Regieanweisungen in Klammern. Gib nur den \
    Sprechtext aus, ohne Anführungszeichen drumherum.
    """

    /// `source`: the passage of the document the slide was made from; the card then explains it instead of the bare points.
    static func notesMessages(deck: PresentationDeck, title: String, slideIndex: Int, source: String? = nil) -> [ChatPayloadMessage] {
        let slide = deck.slides[slideIndex]
        var lines: [String] = []
        lines.append("Präsentation: „\(title)“")
        lines.append("")
        lines.append("Gliederung:")
        for (index, other) in deck.slides.enumerated() {
            let name = other.title.isEmpty ? "(ohne Titel)" : other.title
            let marker = index == slideIndex ? "  ← diese Folie" : ""
            lines.append("\(index + 1). \(name) (\(other.role.label))\(marker)")
        }
        lines.append("")
        lines.append("Folie \(slideIndex + 1) von \(deck.slides.count) (\(slide.role.label)):")
        let text = plainText(of: slide)
        lines.append("\"\"\"\n\(text.isEmpty ? "(die Folie hat keinen Text)" : text)\n\"\"\"")
        if let source, !source.isEmpty {
            let excerpt = source.count > 2_000 ? String(source.prefix(2_000)) + " …" : source
            lines.append("\nVorlage – der Text des Dokuments, aus dem diese Folie entstand (daraus darfst du erklären, darüber hinaus erfindest du nichts):\n\"\"\"\n\(excerpt)\n\"\"\"")
        }
        if slideIndex > 0 {
            // Only the previous slide's title: given its card (even only its last sentence), small models copy it.
            let previous = deck.slides[slideIndex - 1]
            lines.append("\nVorige Folie: „\(previous.title.isEmpty ? "(ohne Titel)" : previous.title)“")
        }
        if slideIndex + 1 < deck.slides.count {
            let next = deck.slides[slideIndex + 1]
            lines.append("\nNächste Folie: „\(next.title.isEmpty ? "(ohne Titel)" : next.title)“ (\(next.role.label))")
        } else {
            lines.append("\nDas ist die letzte Folie: runde die Präsentation ab und bedanke dich kurz.")
        }
        lines.append("\nSchreibe jetzt die Moderatorenkarte für Folie \(slideIndex + 1).")
        return [
            ChatPayloadMessage(role: "system", content: notesSystemPrompt),
            ChatPayloadMessage(role: "user", content: lines.joined(separator: "\n")),
        ]
    }

    /// A slide's text without Markdown: its paragraphs, list items and the captions of its pictures.
    static func plainText(of slide: PresentationSlide) -> String {
        var lines = DocumentOutlineBuilder.blocks(of: slide.markdown).map(\.text)
        for line in slide.markdown.components(separatedBy: "\n") {
            if let image = WriterImageReference.parse(line.trimmingCharacters(in: .whitespaces)), !image.caption.isEmpty {
                lines.append("[Bild: \(image.caption)]")
            }
        }
        return lines.joined(separator: "\n")
    }

    /// Drops sentences the model copied from the previous card.
    static func removingCopies(of previous: String, from notes: String) -> String {
        let previous = previous.trimmingCharacters(in: .whitespacesAndNewlines)
        guard previous.count > 40 else { return notes }
        if notes.contains(previous) {
            return notes.replacingOccurrences(of: previous, with: "").trimmingCharacters(in: .whitespacesAndNewlines)
        }
        var known = Set<String>()
        previous.enumerateSubstrings(in: previous.startIndex..., options: .bySentences) { sentence, _, _, _ in
            if let sentence, sentence.count > 30 { known.insert(sentence.trimmingCharacters(in: .whitespacesAndNewlines)) }
        }
        var kept: [String] = []
        notes.enumerateSubstrings(in: notes.startIndex..., options: .bySentences) { sentence, _, _, _ in
            guard let sentence else { return }
            let trimmed = sentence.trimmingCharacters(in: .whitespacesAndNewlines)
            if !known.contains(trimmed) { kept.append(trimmed) }
        }
        let result = kept.joined(separator: " ")
        return result.isEmpty ? notes : result
    }

    /// The model's answer as the text to speak: without reasoning, Markdown and surrounding quotes.
    static func cleanNotes(_ answer: String) -> String {
        var text = answer
        if let end = text.range(of: "</think>", options: .backwards) { text = String(text[end.upperBound...]) }
        if let end = text.range(of: "<channel|>", options: .backwards) { text = String(text[end.upperBound...]) }
        text = text.replacingOccurrences(of: "**", with: "")
            .replacingOccurrences(of: "__", with: "")
        let lines = text.components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.hasPrefix("#") && !$0.lowercased().hasPrefix("moderatorenkarte") }
            .map { line in line.hasPrefix("- ") || line.hasPrefix("* ") ? String(line.dropFirst(2)) : line }
        text = lines.joined(separator: "\n")
            .replacingOccurrences(of: #"\n{3,}"#, with: "\n\n", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let quotes = CharacterSet(charactersIn: "\"„“”»«")
        if let first = text.unicodeScalars.first, let last = text.unicodeScalars.last, quotes.contains(first), quotes.contains(last) {
            text = text.trimmingCharacters(in: quotes).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return text
    }

    // MARK: A whole presentation

    /// The outline the model makes first: the title, then chapters with their slides.
    struct Outline: Decodable {
        struct Chapter: Decodable {
            let titel: String
            let folien: [Slide]
        }

        struct Slide: Decodable {
            let titel: String
            let inhalt: String
        }

        let titel: String
        let untertitel: String
        let kapitel: [Chapter]
    }

    static let outlineSchema = ContentAnalysisBuilder.Schema.object([
        ("titel", .string),
        ("untertitel", .string),
        ("kapitel", .array(.object([
            ("titel", .string),
            ("folien", .array(.object([("titel", .string), ("inhalt", .string)]), max: 6)),
        ]), max: 6)),
    ])

    static let outlineSystemPrompt = """
    Du entwirfst die Gliederung einer Präsentation. Der Nutzer sagt in eigenen Worten, worüber sie gehen soll;     oft ist das diktiert und klingt locker. Danach werden die Folien einzeln ausgearbeitet.

    Regeln:
    - Sprache: die der Anweisung (meist Deutsch).
    - „titel“: der Titel der Präsentation, kurz und klar. „untertitel“: eine Zeile, worum es geht.
    - Gliedere in 2 bis 4 Kapitel mit je 2 bis 4 Folien, zusammen 6 bis 12 Folien – außer der Nutzer nennt eine     Zahl oder einen Umfang; dann halte dich daran.
    - Ein guter Aufbau: hinführen und Begriffe klären, das Thema Schritt für Schritt entwickeln, Beispiele oder     Anwendungen zeigen, mit Grenzen, offenen Fragen oder einem Fazit enden.
    - Kapiteltitel und Folientitel: höchstens 6 Wörter, ohne Nummern, ohne Doppelpunkt am Ende.
    - „inhalt“: ein Satz, was die Folie zeigen soll und was dort neu ist. Keine Folie wiederholt eine andere.
    - Bleib sachlich richtig. Erfinde keine Studien, Zahlen oder Namen.
    - Gibt es schon Folien, setze die Präsentation fort, ohne sie zu wiederholen.
    """

    static func outlineMessages(instruction: String, existing: [PresentationSlide], presentationTitle: String) -> [ChatPayloadMessage] {
        var lines = ["Anweisung des Nutzers: „\(instruction)“"]
        let titled = existing.filter { !$0.title.isEmpty }
        if !titled.isEmpty {
            lines.append("")
            lines.append("Die Präsentation „\(presentationTitle)“ hat schon diese Folien:")
            for slide in titled { lines.append("- \(slide.title) (\(slide.role.label))") }
        }
        return [
            ChatPayloadMessage(role: "system", content: outlineSystemPrompt),
            ChatPayloadMessage(role: "user", content: lines.joined(separator: "\n")),
        ]
    }

    /// The content of one slide: its points.
    struct SlideContent: Decodable {
        let punkte: [String]
    }

    static let slideSchema = ContentAnalysisBuilder.Schema.object([("punkte", .array(.string, max: 5))])

    static let slideSystemPrompt = """
    Du arbeitest eine Folie einer Präsentation aus. Auf die Folie kommen 3 bis 5 Stichpunkte; das Erklären     übernimmt später der Vortragende.

    Regeln:
    - Sprache: die der Präsentation (meist Deutsch).
    - Jeder Stichpunkt höchstens 12 Wörter, ohne Punkt am Ende, ohne Aufzählungszeichen und ohne Nummer.
    - Konkret und inhaltlich: Begriffe, Zusammenhänge, Beispiele. Keine Füllsätze wie „Wichtiges Thema“.
    - Nichts, was auf anderen Folien der Gliederung steht. Erfinde keine Studien, Zahlen oder Namen.
    - Höchstens zwei Begriffe der ganzen Folie dürfen **fett** sein, nur die wichtigsten.
    """

    static func slideMessages(outline: Outline, chapter: String, slide: Outline.Slide) -> [ChatPayloadMessage] {
        var lines = ["Präsentation: „\(outline.titel)“ – \(outline.untertitel)", "", "Gliederung:"]
        for part in outline.kapitel {
            lines.append("• \(part.titel)")
            for other in part.folien {
                lines.append("   – \(other.titel)" + (other.titel == slide.titel && part.titel == chapter ? "   ← diese Folie" : ""))
            }
        }
        lines.append("")
        lines.append("Kapitel: „\(chapter)“")
        lines.append("Folie: „\(slide.titel)“")
        lines.append("Was die Folie zeigen soll: \(slide.inhalt)")
        return [
            ChatPayloadMessage(role: "system", content: slideSystemPrompt),
            ChatPayloadMessage(role: "user", content: lines.joined(separator: "\n")),
        ]
    }

    // MARK: Background pictures

    static let backgroundSystemPrompt = """
    You write image prompts for the text-to-image model Qwen-Image. The picture is the background of a \
    presentation slide in 16:9; the slide's text will be set on top of it. The user describes the topic or \
    the look, usually in German.

    How Qwen-Image reads prompts:
    - It follows long, precise descriptions in natural English closely: subjects, colors, materials, positions \
    (left, right, top, bottom, foreground, background).
    - What comes first weighs most: begin with the medium or style and the overall look.
    - Describe only what is visible. Never write what should be absent (no "no", "without", "not").

    A good slide background:
    - Is atmospheric and calm, with one clear color palette, soft light and depth.
    - Leaves a large, smooth, uncluttered area where the text goes (described below as the calm area): \
    describe that area explicitly as empty soft gradient, smooth sky, plain wall, gentle bokeh or similar.
    - Puts its details and points of interest only where the description below allows.
    - Shows no writing of any kind: describe surfaces as plain and smooth.
    - Fits the requested brightness: "dark" means a deep, low-key image (the text will be white); "light" means \
    a bright, high-key, airy image with pale colors (the text will be black).

    Rules:
    - Keep the user's topic and style. Prefer abstract, atmospheric or scenic interpretations of the topic \
    over literal objects in the middle.
    - 60 to 140 words, one paragraph of flowing sentences, no lists, no line breaks.

    Answer in exactly this form, nothing before or after:
    PROMPT: <the English prompt>
    """

    static func backgroundMessages(description: String, presentationTitle: String, role: SlideRole, tone: SlideTone, style: ImageStyle) -> [ChatPayloadMessage] {
        var lines: [String] = []
        let idea = description.trimmingCharacters(in: .whitespacesAndNewlines)
        lines.append("Thema / Bildidee: " + (idea.isEmpty ? "passend zur Präsentation „\(presentationTitle)“" : idea))
        if !presentationTitle.isEmpty { lines.append("Präsentation: „\(presentationTitle)“") }
        lines.append("Stil: " + (style.instruction ?? "frei wählen, passend zum Thema"))
        lines.append("Helligkeit: " + (tone == .light ? "dark (white text on top)" : "light (black text on top)"))
        switch role {
        case .title:
            lines.append("Slide: the title slide. Striking, cinematic, the most expressive of the set. Calm area: a wide horizontal band across the middle for a centered title; details along the edges, the lower third and the corners.")
        case .chapter:
            lines.append("Slide: a chapter opening. Bold but simpler than a title slide. Calm area: the left 60 percent for a left-aligned heading; the visual interest sits in the right third.")
        case .content:
            lines.append("Slide: a content slide with a lot of text. Very subtle, low contrast, mostly empty: a soft gradient or gentle texture over nearly the whole picture. Calm area: everything except a narrow strip along the right and bottom edges, where faint details may appear.")
        }
        return [
            ChatPayloadMessage(role: "system", content: backgroundSystemPrompt),
            ChatPayloadMessage(role: "user", content: lines.joined(separator: "\n")),
        ]
    }
}
