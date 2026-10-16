import Foundation

/// What a handout made from a presentation contains.
struct HandoutOptions: Equatable {
    /// A table of contents after the title, from the headings (numbered as in the export). An agenda slide makes
    /// way for it.
    var tableOfContents = true
    /// The speaker notes as text below each slide's points.
    var speakerNotes = true
    /// A picture of each slide above its section.
    var slidePictures = false
    /// The model writes the points out as continuous text, like an essay.
    var expand = false
    var length: HandoutLength = .medium
}

/// How much the model writes per slide.
enum HandoutLength: String, CaseIterable, Identifiable {
    case short, medium, long

    var id: Self { self }

    var label: String {
        switch self {
        case .short: "Knapp"
        case .medium: "Ausführlich"
        case .long: "Sehr ausführlich"
        }
    }

    var paragraphs: String {
        switch self {
        case .short: "einen bis zwei Absätze (etwa 80 bis 150 Wörter)"
        case .medium: "zwei bis drei Absätze (etwa 180 bis 300 Wörter)"
        case .long: "vier bis fünf Absätze (etwa 350 bis 550 Wörter)"
        }
    }

    var maxTokens: Int {
        switch self {
        case .short: 900
        case .medium: 1600
        case .long: 2800
        }
    }
}

/// A slide's part of the handout whose points the model can write out.
struct HandoutSection: Equatable, Sendable {
    let slideID: PresentationSlide.ID
    /// The heading line in the handout (the section is found by it).
    let headingLine: String
    let title: String
    let chapter: String?
    /// The points exactly as they stand in the handout; they are replaced by the model's text.
    let points: String
    let notes: String
}

/// Turns a presentation into a Writer Studio document: the title slide becomes the title, chapter slides chapters,
/// each slide a section under its own heading with its points, pictures and (if wanted) its speaker notes.
enum HandoutBuilder {
    /// Slide titles that only list what comes; with a table of contents such a slide is left out.
    static let agendaTitles: Set<String> = ["agenda", "inhalt", "inhalte", "gliederung", "überblick", "übersicht", "inhaltsverzeichnis", "ablauf", "outline", "contents"]

    /// `slidePictures` holds the picture of each slide (its Markdown source) when they are wanted.
    static func build(deck: PresentationDeck, options: HandoutOptions, slidePictures: [PresentationSlide.ID: String] = [:]) -> (markdown: String, sections: [HandoutSection]) {
        var blocks: [String] = []
        var sections: [HandoutSection] = []
        var hasTitle = false
        var placedContents = !options.tableOfContents
        var chapter: String?
        let notesInText = options.speakerNotes && !options.expand

        func placeContents() {
            guard !placedContents else { return }
            blocks.append(WriterTOCAttachment.marker)
            placedContents = true
        }

        for (number, slide) in deck.slides.enumerated() {
            let parts = split(slide.markdown)
            let notes = slide.notes.trimmingCharacters(in: .whitespacesAndNewlines)
            let picture = slidePictures[slide.id].map { "![Folie \(number + 1)](\($0))" }
            let pictures = parts.images + slide.images.map(imageLine)

            if slide.role == .title && !hasTitle {
                // The title, not numbered: a strong line; what follows it (subtitle, names) stays as it is.
                hasTitle = true
                if let heading = parts.headingText, !heading.isEmpty { blocks.append("**" + heading + "**") }
                if let picture { blocks.append(picture) }
                if !parts.body.isEmpty { blocks.append(parts.body) }
                blocks += pictures
                if notesInText, !notes.isEmpty { blocks.append(notes) }
                placeContents()
                continue
            }
            if slide.role == .content, options.tableOfContents, isAgenda(slide) {
                placeContents()
                continue
            }
            placeContents()

            let title = parts.headingText ?? slide.title
            let headingLine: String?
            if slide.role == .content {
                headingLine = parts.headingLine ?? (title.isEmpty ? nil : "# " + title)
            } else {
                chapter = title
                headingLine = title.isEmpty ? nil : "# " + title + " {.chapter}"
            }
            if let headingLine { blocks.append(headingLine) }
            if let picture { blocks.append(picture) }
            if !parts.body.isEmpty {
                blocks.append(parts.body)
                if let headingLine {
                    sections.append(HandoutSection(
                        slideID: slide.id, headingLine: headingLine, title: title,
                        chapter: slide.role == .content ? chapter : nil, points: parts.body, notes: notes
                    ))
                }
            }
            blocks += pictures
            if notesInText, !notes.isEmpty { blocks.append(notes) }
        }
        placeContents()
        return (blocks.joined(separator: "\n\n") + "\n", sections)
    }

    static func isAgenda(_ slide: PresentationSlide) -> Bool {
        let title = slide.title.lowercased().trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters))
        return agendaTitles.contains(title)
    }

    /// A free picture as a paragraph, about as wide (of the column) as it was on the slide.
    static func imageLine(_ image: SlideImage) -> String {
        let width = Int((min(1, max(0.25, image.width * 1.4)) * 100 / 5).rounded()) * 5
        return WriterImageReference(source: image.source, caption: image.caption, width: width, generated: image.generated).markdown
    }

    /// The slide's first heading, its other text, and its pictures.
    private static func split(_ markdown: String) -> (headingLine: String?, headingText: String?, body: String, images: [String]) {
        var lines = markdown.trimmingCharacters(in: .whitespacesAndNewlines).components(separatedBy: "\n")
        var headingLine: String?
        var headingText: String?
        if let first = lines.firstIndex(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty }),
           lines[first].trimmingCharacters(in: .whitespaces).hasPrefix("#") {
            let line = lines[first].trimmingCharacters(in: .whitespaces)
            let hashes = line.prefix { $0 == "#" }
            // A chapter mark on a content slide's heading isn't kept: the slide's role decides.
            let rest = line.dropFirst(hashes.count).trimmingCharacters(in: .whitespaces)
            headingText = WriterMarkdown.headingAttributes(rest).text
            headingLine = hashes + " " + (headingText ?? "")
            lines.removeSubrange(...first)
        }
        var images: [String] = []
        var body: [String] = []
        for line in lines {
            if WriterImageReference.parse(line.trimmingCharacters(in: .whitespaces)) != nil {
                images.append(line.trimmingCharacters(in: .whitespaces))
            } else {
                body.append(line)
            }
        }
        let text = body.joined(separator: "\n")
            .replacingOccurrences(of: #"\n{3,}"#, with: "\n\n", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return (headingLine, headingText, text, images)
    }

    /// Puts the model's text in place of a section's points. The points are looked for after the section's
    /// heading; if the user changed them in the meantime, nothing is replaced.
    static func replacing(_ section: HandoutSection, with text: String, in markdown: String) -> String? {
        let start = markdown.range(of: "\n" + section.headingLine + "\n").map(\.upperBound)
            ?? (markdown.hasPrefix(section.headingLine + "\n") ? markdown.index(markdown.startIndex, offsetBy: section.headingLine.count + 1) : nil)
        guard let start, let range = markdown.range(of: section.points, range: start..<markdown.endIndex) else { return nil }
        return markdown.replacingCharacters(in: range, with: text)
    }
}

/// What the model is asked to write a slide out.
enum HandoutPrompts {
    static let systemPrompt = """
    Du machst aus den Folien einer Präsentation ein ausformuliertes Handout, das sich liest wie ein gut \
    geschriebener Essay. Du bekommst immer eine Folie: ihren Titel und ihre Stichpunkte.

    Regeln:
    - Schreibe in der Sprache der Folie (meist Deutsch), sachlich und gut lesbar, in ganzen Sätzen und Absätzen.
    - Führe jeden Stichpunkt aus: erkläre ihn, begründe, verbinde die Punkte zu einem Gedankengang und gib, wo es \
    passt, ein kurzes Beispiel.
    - Die Moderatorenkarte, wenn es eine gibt, ist Material dafür, was zur Folie gesagt wird. Übernimm ihren Inhalt, \
    aber nicht ihre gesprochene Sprache und keine Anrede des Publikums.
    - Schreibe nur über diese Folie. Keine Einleitung wie „In diesem Abschnitt“, keine Zusammenfassung am Ende, \
    keine Überleitung zur nächsten Folie.
    - Kein Titel, keine Überschrift, keine Aufzählung. Absätze trennst du mit einer Leerzeile. **Fett** darfst du \
    für einzelne Schlüsselbegriffe verwenden.
    - Belege wie [@schluessel] und Formeln zwischen $ übernimmst du unverändert an der passenden Stelle.
    - Erfinde keine Zahlen, Namen, Zitate oder Quellen, die nicht auf der Folie oder der Karte stehen.
    """

    static func messages(for section: HandoutSection, presentationTitle: String, previous: String?, next: String?, length: HandoutLength) -> [ChatPayloadMessage] {
        var lines: [String] = ["Präsentation: „\(presentationTitle)“"]
        if let chapter = section.chapter, !chapter.isEmpty { lines.append("Kapitel: „\(chapter)“") }
        lines.append("Folie: „\(section.title)“")
        lines.append("")
        lines.append("Stichpunkte der Folie:\n\"\"\"\n\(section.points)\n\"\"\"")
        if !section.notes.isEmpty {
            lines.append("\nModeratorenkarte (Material):\n\"\"\"\n\(section.notes)\n\"\"\"")
        }
        // Only titles of the neighbours: small models copy whole texts they are given.
        if let previous { lines.append("\nDavor im Handout: „\(previous)“ (wiederhole nichts davon)") }
        if let next { lines.append("Danach im Handout: „\(next)“ (nimm nichts davon vorweg)") }
        lines.append("\nSchreibe jetzt \(length.paragraphs) zu dieser Folie.")
        return [
            ChatPayloadMessage(role: "system", content: systemPrompt),
            ChatPayloadMessage(role: "user", content: lines.joined(separator: "\n")),
        ]
    }

    /// The model's answer as paragraphs: without reasoning, headings, list marks and a repeated title.
    static func clean(_ answer: String, title: String) -> String {
        var text = answer
        if let end = text.range(of: "</think>", options: .backwards) { text = String(text[end.upperBound...]) }
        if let end = text.range(of: "<channel|>", options: .backwards) { text = String(text[end.upperBound...]) }
        let plainTitle = title.lowercased().trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters))
        let lines = text.components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { line in
                guard !line.hasPrefix("#"), !line.hasPrefix("```") else { return false }
                let bare = line.replacingOccurrences(of: "*", with: "").lowercased().trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters))
                return bare != plainTitle || bare.isEmpty
            }
            .map { line -> String in
                for mark in ["- ", "* ", "• "] where line.hasPrefix(mark) { return String(line.dropFirst(mark.count)) }
                return line
            }
        return lines.joined(separator: "\n")
            .replacingOccurrences(of: #"(?<=\S)\n(?=\S)"#, with: "\n\n", options: .regularExpression)
            .replacingOccurrences(of: #"\n{3,}"#, with: "\n\n", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
