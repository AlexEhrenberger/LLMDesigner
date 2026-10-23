import AppKit
import UniformTypeIdentifiers

/// A document as the material of a presentation: its title and its text as Markdown. It comes from a document of
/// Writer Studio or from a file (Markdown, text, Word, RTF, PDF, HTML).
struct DeckMaterial: Sendable {
    var title: String
    var markdown: String
    /// Where it comes from, for the sheet ("Aufsatz.docx").
    var sourceName: String
}

/// The slides a document gives, as far as its headings say it: chapters, slides, and for each slide the passage of
/// the document it is about.
struct DeckPlan: Sendable {
    struct Slide: Identifiable, Sendable {
        let id = UUID()
        var title: String
        /// The Markdown of the document this slide is made from.
        var passage: String
        /// One sentence on what the slide shows (from the model's outline); empty when the headings gave it.
        var hint = ""
    }

    struct Chapter: Sendable {
        /// nil: slides before the first chapter, or without any.
        var title: String?
        var introduction = ""
        var slides: [Slide]
    }

    var title: String
    var subtitle = ""
    var chapters: [Chapter]

    var slideCount: Int { chapters.reduce(0) { $0 + $1.slides.count } }
    var chapterCount: Int { chapters.filter { $0.title != nil }.count }
}

/// Pictures, formulas, code and tables in a passage: they go onto the slide as they are, since a summary would only
/// spoil them.
struct DeckObjects: Sendable {
    var math: [String] = []
    var code: [String] = []
    var tables: [String] = []
    var images: [WriterImageReference] = []

    var isEmpty: Bool { math.isEmpty && code.isEmpty && tables.isEmpty && images.isEmpty }

    /// The first formula, code block and table of a passage, whole (code only up to 14 lines, tables up to 6 rows).
    static func extract(from markdown: String) -> DeckObjects {
        var found = DeckObjects()
        let lines = markdown.components(separatedBy: "\n")
        var index = 0
        while index < lines.count {
            let trimmed = lines[index].trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") {
                let fence = String(trimmed.prefix(3))
                var block = [lines[index]]
                var scan = index + 1
                while scan < lines.count {
                    block.append(lines[scan])
                    if lines[scan].trimmingCharacters(in: .whitespaces).hasPrefix(fence) { break }
                    scan += 1
                }
                if block.count <= 16, block.last?.trimmingCharacters(in: .whitespaces).hasPrefix(fence) == true, found.code.isEmpty {
                    found.code.append(block.joined(separator: "\n"))
                }
                index = scan + 1
                continue
            }
            if trimmed.hasPrefix("$$") {
                var block = [lines[index]]
                var scan = index
                // One line `$$ … $$`, or until the closing line.
                if !(trimmed.count > 2 && trimmed.hasSuffix("$$")) {
                    scan = index + 1
                    while scan < lines.count {
                        block.append(lines[scan])
                        if lines[scan].trimmingCharacters(in: .whitespaces).hasSuffix("$$") { break }
                        scan += 1
                    }
                }
                if found.math.isEmpty { found.math.append(block.joined(separator: "\n")) }
                index = scan + 1
                continue
            }
            if trimmed.hasPrefix("|") {
                var block = [lines[index]]
                var scan = index + 1
                while scan < lines.count, lines[scan].trimmingCharacters(in: .whitespaces).hasPrefix("|") {
                    block.append(lines[scan])
                    scan += 1
                }
                if block.count >= 2, block.count <= 7, found.tables.isEmpty { found.tables.append(block.joined(separator: "\n")) }
                index = scan
                continue
            }
            if let image = WriterImageReference.parse(trimmed), !image.generated || !image.isPlaceholder { found.images.append(image) }
            index += 1
        }
        return found
    }

    /// A point of a slide without the notes `textForModel` puts in for objects ("[Formel]", "[Code-Block]", …), which
    /// models sometimes copy; nil when nothing is left of it.
    static func removingNotes(from point: String) -> String? {
        let cleaned = point
            .replacingOccurrences(of: #"\[\s*(Formel|Code-?Block|Code|Tabelle|Bild)\b[^\]]*\]"#, with: "", options: [.regularExpression, .caseInsensitive])
            .replacingOccurrences(of: #"\(\s*(Formel|Code-?Block|Tabelle|Bild)\s*\)"#, with: "", options: [.regularExpression, .caseInsensitive])
            .split(whereSeparator: { $0 == " " }).joined(separator: " ")
            .trimmingCharacters(in: CharacterSet(charactersIn: " :–-,;"))
        return cleaned.count >= 3 ? cleaned : nil
    }

    /// The passage's text for the model: the formulas, code blocks, tables and pictures are replaced by short notes.
    static func textForModel(_ markdown: String, limit: Int) -> String {
        var result: [String] = []
        var inFence = false
        var inMath = false
        for line in markdown.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") {
                if !inFence { result.append("[Code-Block]") }
                inFence.toggle()
                continue
            }
            if inFence { continue }
            if trimmed.hasPrefix("$$") {
                let closesAtOnce = trimmed.count > 2 && trimmed.hasSuffix("$$")
                if !inMath { result.append("[Formel]") }
                if !closesAtOnce { inMath.toggle() }
                continue
            }
            if inMath {
                if trimmed.hasSuffix("$$") { inMath = false }
                continue
            }
            if trimmed.hasPrefix("|") {
                if result.last != "[Tabelle]" { result.append("[Tabelle]") }
                continue
            }
            if let image = WriterImageReference.parse(trimmed) {
                result.append(image.caption.isEmpty ? "[Bild]" : "[Bild: \(image.caption)]")
                continue
            }
            result.append(WriterBookmark.strip(line))
        }
        let text = result.joined(separator: "\n").replacingOccurrences(of: #"\n{3,}"#, with: "\n\n", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return text.count > limit ? String(text.prefix(limit)) + " …" : text
    }
}

/// Reads a document's headings and makes the slides from them: a chapter of the document is a chapter of the
/// presentation, a section a slide. Which level is which follows from the headings the text has.
enum DocumentDeckPlanner {
    struct Section {
        /// 0 chapter, 1 to 3 the heading levels.
        var level: Int
        var title: String
        var lines: [String]
    }

    /// The text before the first heading, and the sections after it.
    static func sections(in markdown: String) -> (introduction: [String], sections: [Section]) {
        var introduction: [String] = []
        var sections: [Section] = []
        var inFence = false
        var inMath = false
        for line in markdown.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") { inFence.toggle() }
            if !inFence, trimmed.hasPrefix("$$") {
                let closesAtOnce = trimmed.count > 2 && trimmed.hasSuffix("$$")
                if !closesAtOnce { inMath.toggle() }
            } else if !inFence, inMath, trimmed.hasSuffix("$$") {
                inMath = false
            }
            if !inFence, !inMath, let heading = parseHeading(line) {
                sections.append(Section(level: heading.level, title: heading.title, lines: []))
                continue
            }
            if sections.isEmpty { introduction.append(line) } else { sections[sections.count - 1].lines.append(line) }
        }
        return (introduction, sections)
    }

    private static func parseHeading(_ line: String) -> (level: Int, title: String)? {
        guard line.hasPrefix("#") else { return nil }
        let hashes = line.prefix { $0 == "#" }.count
        guard hashes <= 3, line.dropFirst(hashes).first == " " else { return nil }
        let (text, classes) = WriterMarkdown.headingAttributes(String(line.dropFirst(hashes + 1)))
        let title = WriterHeadings.plainTitle(WriterBookmark.strip(text))
        guard !title.isEmpty else { return nil }
        return (hashes == 1 && classes.contains("chapter") ? 0 : hashes, title)
    }

    static func joined(_ lines: [String]) -> String {
        lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// The plan from the headings; nil when the text has too few of them to make slides from.
    static func plan(for material: DeckMaterial) -> DeckPlan? {
        let (introduction, sections) = sections(in: material.markdown)
        guard !sections.isEmpty else { return nil }
        let levels = Set(sections.map(\.level))
        let count = { (level: Int) in sections.filter { $0.level == level }.count }

        var title = material.title
        var chapterLevel: Int?
        var slideLevel: Int
        if levels.contains(0) {
            chapterLevel = 0
            slideLevel = levels.contains(1) ? 1 : (levels.contains(2) ? 2 : 3)
        } else if count(1) >= 2, levels.contains(2) {
            chapterLevel = 1
            slideLevel = 2
        } else if count(1) == 1, levels.contains(2) {
            // The only first-level heading is the document's title.
            if title.isEmpty, let first = sections.first(where: { $0.level == 1 }) { title = first.title }
            if count(2) >= 2, count(3) >= count(2) { chapterLevel = 2; slideLevel = 3 } else { slideLevel = 2 }
        } else if levels.contains(1) {
            slideLevel = 1
        } else if levels.contains(2) {
            if count(2) >= 2, count(3) >= count(2) { chapterLevel = 2; slideLevel = 3 } else { slideLevel = 2 }
        } else {
            slideLevel = 3
        }

        var chapters: [DeckPlan.Chapter] = []
        func current() -> Int {
            if chapters.isEmpty { chapters.append(DeckPlan.Chapter(title: nil, slides: [])) }
            return chapters.count - 1
        }
        let intro = joined(introduction)
        // The text in front of the first heading is a slide of its own when there is enough of it.
        if intro.count >= 200 {
            chapters.append(DeckPlan.Chapter(title: nil, slides: [DeckPlan.Slide(title: "Einleitung", passage: intro)]))
        }

        var index = 0
        while index < sections.count {
            let section = sections[index]
            if let chapterLevel, section.level == chapterLevel {
                chapters.append(DeckPlan.Chapter(title: section.title, introduction: joined(section.lines), slides: []))
                index += 1
                continue
            }
            if section.level == slideLevel {
                // The section and everything deeper below it.
                var lines = section.lines
                var next = index + 1
                while next < sections.count, sections[next].level > slideLevel {
                    lines.append("")
                    lines.append("**\(sections[next].title)**")
                    lines += sections[next].lines
                    next += 1
                }
                let passage = joined(lines)
                if !passage.isEmpty {
                    let chapter = current()
                    chapters[chapter].slides.append(DeckPlan.Slide(title: section.title, passage: passage))
                }
                index = next
                continue
            }
            // A heading above the slides' level that is no chapter (the title): its text belongs to no slide.
            index += 1
        }
        chapters = chapters.filter { !$0.slides.isEmpty }
        let plan = DeckPlan(title: title, subtitle: subtitle(from: introduction), chapters: chapters)
        return plan.slideCount >= 2 ? plan : nil
    }

    /// The first short line of text before the headings, as the title slide's subtitle.
    private static func subtitle(from introduction: [String]) -> String {
        let line = introduction.map { $0.trimmingCharacters(in: .whitespaces) }.first { !$0.isEmpty }
        guard let line, line.count <= 110, !line.hasPrefix("|"), !line.hasPrefix("!"), !line.hasPrefix("```"), !line.hasPrefix("$$") else { return "" }
        return WriterHeadings.plainTitle(WriterBookmark.strip(line))
    }
}

// MARK: - Files

extension DocumentText {
    /// The text of a file as Markdown: text and Markdown files as they are, Word and RTF files with their large or
    /// bold short lines as headings (the file's own styles are lost, their sizes tell).
    static func markdown(from url: URL) throws -> String {
        let type = (try? url.resourceValues(forKeys: [.contentTypeKey]).contentType) ?? UTType(filenameExtension: url.pathExtension)
        let richTypes: [UTType] = [.rtf, .rtfd, .flatRTFD, UTType("org.openxmlformats.wordprocessingml.document"),
                                   UTType("com.microsoft.word.doc"), UTType("org.oasis-open.opendocument.text")].compactMap { $0 }
        if let type, richTypes.contains(where: type.conforms(to:)),
           let document = try? NSAttributedString(url: url, options: [:], documentAttributes: nil) {
            return headingsMarkdown(from: document)
        }
        return try extract(from: url)
    }

    /// Paragraphs whose type is clearly larger than the text's (or bold and short) become `#`, `##`, `###`.
    static func headingsMarkdown(from document: NSAttributedString) -> String {
        let string = document.string as NSString
        struct Paragraph { var text: String; var size: CGFloat; var isBold: Bool }
        var paragraphs: [Paragraph] = []
        var sizes: [CGFloat: Int] = [:]
        var location = 0
        while location < string.length {
            let range = string.paragraphRange(for: NSRange(location: location, length: 0))
            let text = string.substring(with: range).trimmingCharacters(in: .whitespacesAndNewlines)
            location = NSMaxRange(range)
            guard !text.isEmpty else { continue }
            let font = document.attribute(.font, at: range.location, effectiveRange: nil) as? NSFont
            let size = (font?.pointSize ?? 12).rounded()
            let isBold = font?.fontDescriptor.symbolicTraits.contains(.bold) == true
            paragraphs.append(Paragraph(text: text, size: size, isBold: isBold))
            sizes[size, default: 0] += text.count
        }
        let body = sizes.max { $0.value < $1.value }?.key ?? 12
        func isHeading(_ paragraph: Paragraph) -> Bool {
            if paragraph.text.count > 120 || paragraph.text.hasSuffix(".") { return false }
            return paragraph.size >= body * 1.18 || (paragraph.isBold && paragraph.text.count <= 70 && paragraph.size >= body)
        }
        // The larger the type, the higher the heading.
        let headingSizes = Set(paragraphs.filter(isHeading).map { $0.isBold && $0.size < body * 1.18 ? body : $0.size }).sorted(by: >)
        var lines: [String] = []
        for paragraph in paragraphs {
            if isHeading(paragraph) {
                let key = paragraph.isBold && paragraph.size < body * 1.18 ? body : paragraph.size
                let level = min(3, (headingSizes.firstIndex(of: key) ?? 2) + 1)
                lines.append(String(repeating: "#", count: level) + " " + paragraph.text)
            } else {
                lines.append(paragraph.text)
            }
            lines.append("")
        }
        return lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
