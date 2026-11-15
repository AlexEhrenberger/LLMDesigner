import Foundation
import PDFKit

/// A lesson found in a PDF, before it becomes part of a course. The sheet shows these for checking: the person can
/// rename them, leave some out and change their pages.
struct DetectedLesson: Identifiable, Hashable, Sendable {
    struct Section: Hashable, Sendable {
        var title: String
        var firstPage: Int
        var lastPage: Int
    }

    var id = UUID()
    var title: String
    var firstPage: Int
    var lastPage: Int
    var sections: [Section] = []
    /// Front and back matter (table of contents, introduction, appendix) is found but left out at first.
    var included = true

    var pageCount: Int { max(0, lastPage - firstPage + 1) }
}

/// The structure of a course in a PDF, found without the model where possible: the PDF's bookmarks first (course
/// books have "Lektion → 1.1, 1.2 …"), then headings like "LEKTION 2" at the top of a page with "2.1 …" below.
/// Deterministic structure is what makes the rest reliable for a small model: it only ever reads one part.
enum CourseOutline {
    /// A bookmark of the PDF: its title, its page (from 1) and what lies below it.
    struct Entry: Hashable, Sendable {
        var title: String
        var page: Int
        var children: [Entry] = []
    }

    enum Source: String, Sendable {
        case bookmarks, headings
    }

    // MARK: Reading the PDF

    static func detect(in document: PDFDocument) -> (lessons: [DetectedLesson], source: Source)? {
        let pageCount = document.pageCount
        if let root = document.outlineRoot {
            let lessons = lessons(fromBookmarks: entries(of: root, in: document), pageCount: pageCount)
            if lessons.filter(\.included).count >= 2 { return (lessons, .bookmarks) }
        }
        let pages = (0..<pageCount).map { document.page(at: $0)?.string ?? "" }
        let lessons = lessons(fromPages: pages)
        return lessons.count >= 2 ? (lessons, .headings) : nil
    }

    private static func entries(of outline: PDFOutline, in document: PDFDocument) -> [Entry] {
        (0..<outline.numberOfChildren).compactMap { index in
            guard let child = outline.child(at: index) else { return nil }
            let page = child.destination?.page.map { document.index(for: $0) + 1 } ?? 0
            return Entry(title: (child.label ?? "").trimmingCharacters(in: .whitespacesAndNewlines), page: page, children: entries(of: child, in: document))
        }
    }

    /// The title of the PDF: its metadata, else the first lines of its first page.
    static func title(of document: PDFDocument) -> String? {
        if let title = document.documentAttributes?[PDFDocumentAttribute.titleAttribute] as? String {
            let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
            // Generators often put the file name or a code there.
            if trimmed.count >= 6, !trimmed.lowercased().hasSuffix(".pdf"), trimmed.contains(" ") { return trimmed }
        }
        let corpus = (0..<min(30, document.pageCount)).map { document.page(at: $0)?.string ?? "" }.joined(separator: "\n")
        for index in 0..<min(4, document.pageCount) {
            let lines = (document.page(at: index)?.string ?? "").components(separatedBy: .newlines)
                .map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
            // The title is the run of lines before a line that looks like a code ("DLBDSSPDS01_D") or a number.
            let run = lines.prefix { line in
                let code = !line.contains(" ") && line.rangeOfCharacter(from: .decimalDigits) != nil
                return line.count > 2 && !line.contains("_") && !code
            }
            let title = run.prefix(3).joined(separator: " ").replacingOccurrences(of: "  ", with: " ")
            if title.count >= 6 { return properCase(title, in: corpus) }
        }
        return nil
    }

    // MARK: Bookmarks

    static func lessons(fromBookmarks entries: [Entry], pageCount: Int) -> [DetectedLesson] {
        var level = entries.filter { $0.page > 0 }
        // A single bookmark above everything is the book's title: its children are the lessons.
        while level.count == 1, let only = level.first, only.children.count >= 2 {
            level = only.children.filter { $0.page > 0 }
        }
        level.sort { $0.page < $1.page }
        var lessons: [DetectedLesson] = []
        for (index, entry) in level.enumerated() {
            let next = index + 1 < level.count ? level[index + 1].page : pageCount + 1
            let last = max(entry.page, min(pageCount, next - 1))
            let children = entry.children.filter { $0.page >= entry.page && $0.page <= last }.sorted { $0.page < $1.page }
            var sections: [DetectedLesson.Section] = []
            for (number, child) in children.enumerated() {
                let end = number + 1 < children.count ? max(child.page, children[number + 1].page - 1) : last
                sections.append(DetectedLesson.Section(title: cleanTitle(child.title), firstPage: child.page, lastPage: end))
            }
            lessons.append(DetectedLesson(title: cleanTitle(entry.title), firstPage: entry.page, lastPage: last, sections: sections,
                                          included: !isFrontOrBackMatter(entry.title)))
        }
        return lessons
    }

    // MARK: Headings on the pages

    /// "LEKTION 2", "Kapitel 3", "Chapter 4", "Unit 5" among the first lines of a page starts a lesson; "2.1 Titel"
    /// lines below start its sections. Pages of the table of contents (dot leaders) don't count.
    static func lessons(fromPages pages: [String]) -> [DetectedLesson] {
        struct Start { var number: Int; var title: String; var page: Int }
        var candidates: [Start] = []
        var sections: [Int: [(title: String, page: Int, key: String)]] = [:]
        for (index, text) in pages.enumerated() {
            let lines = text.components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
            guard !isContentsPage(lines) else { continue }
            for (position, line) in lines.prefix(3).enumerated() {
                guard let match = lessonHeading(line) else { continue }
                var title = match.rest
                if title.isEmpty, position + 1 < lines.count { title = lines[position + 1] }
                // A reading list ("Lektion 5 – Henze, N. (2019). Stochastik …") names lessons too.
                guard looksLikeTitle(title) else { break }
                candidates.append(Start(number: match.number, title: title, page: index + 1))
                break
            }
            for (position, line) in lines.enumerated() {
                guard var section = sectionHeading(line), !(sections[section.major]?.contains { $0.key == section.key } ?? false) else { continue }
                // "2.2 Verteilungsfunktionen und" goes on in the next line.
                if position + 1 < lines.count, let last = section.title.split(separator: " ").last?.first, last.isLowercase {
                    let next = lines[position + 1]
                    if next.count <= 60, let first = next.first, first.isUppercase, !".:;,".contains(next.last ?? " "), sectionHeading(next) == nil {
                        section.title += " " + next
                    }
                }
                sections[section.major, default: []].append((section.title, index + 1, section.key))
            }
        }
        // Lessons follow one another: each number is taken at its first page after the lesson before it.
        var starts: [Start] = []
        for number in Set(candidates.map(\.number)).sorted() {
            let after = starts.last?.page ?? 0
            if let start = candidates.filter({ $0.number == number && $0.page > after }).min(by: { $0.page < $1.page }) { starts.append(start) }
        }
        let corpus = pages.joined(separator: "\n")
        for index in starts.indices { starts[index].title = properCase(starts[index].title, in: corpus) }
        var lessons: [DetectedLesson] = []
        for (index, start) in starts.enumerated() {
            let last = index + 1 < starts.count ? starts[index + 1].page - 1 : pages.count
            let found = (sections[start.number] ?? []).filter { $0.page >= start.page && $0.page <= last }
            var parts: [DetectedLesson.Section] = []
            for (number, section) in found.enumerated() {
                let end = number + 1 < found.count ? max(section.page, found[number + 1].page - 1) : last
                parts.append(DetectedLesson.Section(title: section.title, firstPage: section.page, lastPage: end))
            }
            lessons.append(DetectedLesson(title: start.title.isEmpty ? "Lektion \(start.number)" : start.title, firstPage: start.page, lastPage: max(start.page, last), sections: parts))
        }
        return lessons
    }

    /// A heading's title is short and no sentence or reference: no year in brackets, no full stop at the end.
    private static func looksLikeTitle(_ text: String) -> Bool {
        guard !text.isEmpty else { return true }
        guard text.count <= 90, !text.hasSuffix(".") else { return false }
        return text.range(of: #"\((19|20)\d\d\)"#, options: .regularExpression) == nil
    }

    private static let lessonWords = ["lektion", "kapitel", "chapter", "unit", "lesson", "modul", "module", "teil", "part"]

    static func lessonHeading(_ line: String) -> (number: Int, rest: String)? {
        let words = line.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: true).map(String.init)
        guard words.count >= 2, lessonWords.contains(words[0].lowercased()) else { return nil }
        let numberText = words[1].trimmingCharacters(in: CharacterSet(charactersIn: ".:"))
        guard let number = Int(numberText), number > 0, number < 100 else { return nil }
        let rest = words.count > 2 ? words[2].trimmingCharacters(in: CharacterSet(charactersIn: ":–- ")) : ""
        // "Kapitel 3 behandelt …" in running text is no heading.
        if let first = rest.first, first.isLowercase { return nil }
        return (number, rest)
    }

    /// "2.1 Zufallsvariablen" → section 1 of lesson 2. A line with dot leaders or a trailing page number is from a
    /// table of contents.
    static func sectionHeading(_ line: String) -> (major: Int, key: String, title: String)? {
        guard line.count <= 100, !line.contains(". . ."), !line.contains("....") else { return nil }
        let parts = line.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true)
        guard parts.count == 2 else { return nil }
        let numbers = parts[0].split(separator: ".", omittingEmptySubsequences: true)
        guard numbers.count == 2, let major = Int(numbers[0]), let minor = Int(numbers[1]), major > 0, minor > 0, major < 100, minor < 50 else { return nil }
        let title = String(parts[1]).trimmingCharacters(in: .whitespaces)
        guard let first = title.first, first.isUppercase, title.count >= 3, title.rangeOfCharacter(from: .lowercaseLetters) != nil else { return nil }
        // "1.1 Definitionen 12": a page number at the end belongs to a table of contents.
        if let last = title.split(separator: " ").last, Int(last) != nil { return nil }
        return (major, "\(major).\(minor)", "\(major).\(minor) \(title)")
    }

    private static func isContentsPage(_ lines: [String]) -> Bool {
        if lines.prefix(3).contains(where: { ["inhaltsverzeichnis", "inhalt", "contents", "table of contents"].contains($0.lowercased()) }) { return true }
        return lines.filter { $0.contains(". . .") || $0.contains("....") }.count >= 3
    }

    // MARK: Titles

    private static let frontAndBackMatter = [
        "inhaltsverzeichnis", "inhalt", "contents", "table of contents", "einleitung", "einführung in das skript", "vorwort", "preface",
        "impressum", "anhang", "appendix", "literaturverzeichnis", "literatur", "bibliography", "references", "quellenverzeichnis",
        "abbildungsverzeichnis", "tabellenverzeichnis", "abkürzungsverzeichnis", "stichwortverzeichnis", "index", "register", "glossar",
        "glossary", "danksagung", "acknowledgements", "über den autor", "über die autorin", "about the author", "lösungen", "wegweiser",
    ]

    static func isFrontOrBackMatter(_ title: String) -> Bool {
        let plain = cleanTitle(title).lowercased()
        return frontAndBackMatter.contains { plain == $0 || plain.hasPrefix($0 + " ") }
    }

    /// "Lektion 1: Wahrscheinlichkeitsrechnung" → "Wahrscheinlichkeitsrechnung"; "1.1 Definitionen" keeps its number.
    static func cleanTitle(_ title: String) -> String {
        var text = title.trimmingCharacters(in: .whitespacesAndNewlines)
        if let heading = lessonHeading(text), !heading.rest.isEmpty { text = heading.rest }
        return softCase(text)
    }

    /// An all-caps title as it is written elsewhere in the text (the table of contents, the introduction): German nouns
    /// keep their capitals that way. Found nowhere, it gets `softCase`.
    static func properCase(_ title: String, in corpus: String) -> String {
        let letters = title.unicodeScalars.filter { CharacterSet.letters.contains($0) }
        guard letters.count >= 4, !letters.contains(where: { CharacterSet.lowercaseLetters.contains($0) }) else { return title }
        let words = title.split(whereSeparator: \.isWhitespace).map(String.init)
        // The words in order, with any whitespace (also a line break) between them.
        let pattern = words.map(NSRegularExpression.escapedPattern(for:)).joined(separator: "\\s+")
        if let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) {
            let range = NSRange(corpus.startIndex..., in: corpus)
            for match in regex.matches(in: corpus, range: range) {
                guard let found = Range(match.range, in: corpus) else { continue }
                let text = String(corpus[found])
                if text.rangeOfCharacter(from: .lowercaseLetters) != nil {
                    return text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
                }
            }
        }
        return softCase(title)
    }

    /// An all-caps title gets ordinary case: only the first letter stays capital. German nouns lose their capital, so
    /// this is only used where nothing better is known (the person can rename the lesson).
    static func softCase(_ text: String) -> String {
        let letters = text.unicodeScalars.filter { CharacterSet.letters.contains($0) }
        guard letters.count >= 4, !letters.contains(where: { CharacterSet.lowercaseLetters.contains($0) }) else { return text }
        let lower = text.lowercased()
        return lower.prefix(1).uppercased() + lower.dropFirst()
    }

    // MARK: Learning goals

    /// The bullet points under "Lernziele" (or "Learning objectives") on a lesson's first pages.
    static func goals(in text: String) -> [String] {
        let lines = text.components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespaces) }
        guard let start = lines.firstIndex(where: { ["lernziele", "learning objectives", "learning goals", "lernergebnisse"].contains($0.lowercased()) }) else { return [] }
        var goals: [String] = []
        var current: String?
        for line in lines[(start + 1)...] {
            if line.isEmpty { continue }
            let bullet = ["–", "-", "•", "▪", "◦", "*"].first { line.hasPrefix($0 + " ") || line == $0 }
            if let bullet {
                if let current { goals.append(current) }
                current = String(line.dropFirst(bullet.count)).trimmingCharacters(in: .whitespaces)
            } else if var text = current {
                // A goal that ended its sentence, or a heading, ends the list: what follows is the lesson's text.
                if text.hasSuffix(".") || text.hasSuffix("!") || text.hasSuffix("?") { break }
                if line.count > 2, line == line.uppercased(), line.rangeOfCharacter(from: .letters) != nil { break }
                if sectionHeading(line) != nil || lessonHeading(line) != nil { break }
                text = LessonText.joinLines(text, line)
                current = text
            } else if goals.isEmpty, line.hasSuffix("…") || line.hasSuffix("...") || line.hasSuffix(":") {
                continue
            } else {
                break
            }
            if goals.count >= 15 { break }
        }
        if let current { goals.append(current) }
        return goals.map { $0.trimmingCharacters(in: CharacterSet(charactersIn: " .")) + "." }.filter { $0.count > 3 }
    }
}

/// The text of a lesson's pages, cleaned for the model and cut into pieces it reads reliably.
enum LessonText {
    /// The pages' text with "[Seite n]" marks, lone page numbers dropped and words split at a line end joined again.
    static func clean(_ pages: [(page: Int, text: String)]) -> String {
        var parts: [String] = []
        for (page, text) in pages {
            var lines: [String] = []
            for raw in text.components(separatedBy: .newlines) {
                let line = raw.trimmingCharacters(in: .whitespaces)
                // The printed page number at the top or bottom.
                if line.count <= 3, Int(line) != nil { continue }
                if line.isEmpty, lines.last?.isEmpty ?? true { continue }
                if let last = lines.last, last.hasSuffix("-"), last.count > 1, let first = line.first, first.isLetter {
                    lines[lines.count - 1] = joinLines(last, line)
                } else {
                    lines.append(line)
                }
            }
            let body = lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            if !body.isEmpty { parts.append("[Seite \(page)]\n" + body) }
        }
        return parts.joined(separator: "\n\n")
    }

    /// Two lines of one paragraph: "Wahrschein-" + "lichkeit" is one word, "Corona-" + "Schnelltest" keeps its hyphen.
    static func joinLines(_ first: String, _ second: String) -> String {
        guard first.hasSuffix("-"), let next = second.first, next.isLetter else { return first + " " + second }
        let stem = first.dropLast()
        guard let before = stem.last, before.isLetter else { return first + second }
        return next.isLowercase ? stem + second : first + second
    }

    /// Pieces of at most `limit` characters, cut at page marks, else at paragraphs, else at sentences. A small model
    /// writes good notes about 7,000 characters at a time; far more and it skips things.
    static func pieces(_ text: String, limit: Int = 7_000) -> [String] {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count > limit else { return trimmed.isEmpty ? [] : [trimmed] }
        var result: [String] = []
        var current = ""
        func flush() {
            let piece = current.trimmingCharacters(in: .whitespacesAndNewlines)
            if !piece.isEmpty { result.append(piece) }
            current = ""
        }
        for block in blocks(of: trimmed, limit: limit) {
            if !current.isEmpty, current.count + block.count + 2 > limit { flush() }
            current += (current.isEmpty ? "" : "\n\n") + block
        }
        flush()
        // A short last piece goes with the one before, unless that gets far too long.
        if result.count >= 2, let last = result.last, last.count < limit / 4, result[result.count - 2].count + last.count <= limit * 5 / 4 {
            result[result.count - 2] += "\n\n" + last
            result.removeLast()
        }
        return result
    }

    /// Paragraphs, with any longer than `limit` cut at sentence ends.
    private static func blocks(of text: String, limit: Int) -> [String] {
        text.components(separatedBy: "\n\n").flatMap { paragraph -> [String] in
            guard paragraph.count > limit else { return [paragraph] }
            var pieces: [String] = []
            var current = ""
            paragraph.enumerateSubstrings(in: paragraph.startIndex..., options: .bySentences) { sentence, _, _, _ in
                guard let sentence else { return }
                if current.count + sentence.count > limit, !current.isEmpty {
                    pieces.append(current)
                    current = ""
                }
                current += sentence
            }
            if !current.isEmpty { pieces.append(current) }
            // Text without sentence ends (a long table): cut hard.
            return pieces.flatMap { piece in
                stride(from: 0, to: piece.count, by: limit).map { start in
                    let from = piece.index(piece.startIndex, offsetBy: start)
                    let to = piece.index(from, offsetBy: min(limit, piece.count - start))
                    return String(piece[from..<to])
                }
            }
        }
    }

    /// The text of pages `first...last` (from 1) of a PDF, read off the main thread.
    static func pages(of url: URL, first: Int, last: Int) async -> [(page: Int, text: String)] {
        await Task.detached(priority: .utility) {
            guard let document = PDFDocument(url: url) else { return [] }
            let low = max(1, first), high = min(document.pageCount, last)
            guard low <= high else { return [] }
            return (low...high).map { ($0, document.page(at: $0 - 1)?.string ?? "") }
        }.value
    }
}
