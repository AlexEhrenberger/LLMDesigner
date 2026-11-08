import Foundation

/// Footnotes in Writer Studio are Pandoc's inline notes: `^[Text der Fußnote]`. The note's text is inline Markdown
/// (emphasis, links, formulas, citations) and stands where the number goes, so a note can't lose its place or its
/// number: the numbers are counted in document order wherever they are shown.
enum WriterFootnotes {
    /// The note that starts at `position` (at `^[`): its text and the position after its closing bracket.
    /// Brackets inside the note are counted, escaped ones skipped; a note doesn't run over a paragraph's end.
    static func note(in characters: [Character], at position: Int) -> (text: String, end: Int)? {
        guard position + 1 < characters.count, characters[position] == "^", characters[position + 1] == "[" else { return nil }
        var depth = 0
        var scan = position + 1
        while scan < characters.count {
            switch characters[scan] {
            case "\\": scan += 1
            case "\n": return nil
            case "[": depth += 1
            case "]":
                depth -= 1
                if depth == 0 {
                    let text = String(characters[(position + 2)..<scan])
                    return text.trimmingCharacters(in: .whitespaces).isEmpty ? nil : (text, scan + 1)
                }
            default: break
            }
            scan += 1
        }
        return nil
    }

    /// The Markdown of a note with this text. Line ends become spaces (a note is one paragraph); brackets that
    /// don't pair up are escaped, so the note ends where it should.
    static func markdown(_ text: String) -> String {
        let flat = text.replacingOccurrences(of: "\r\n", with: " ").replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: String(WriterMarkdown.lineSeparator), with: " ")
            .trimmingCharacters(in: .whitespaces)
        return "^[" + (isBalanced(flat) ? flat : escapeBrackets(flat)) + "]"
    }

    /// Replaces each note in `source` by a placeholder made of letters (`LLMDFOOTNOTE<n>X`), which passes
    /// Markdown parsing and escaping untouched; the notes' texts come back in order.
    static func extract(_ source: String) -> (text: String, notes: [String]) {
        guard source.contains("^[") else { return (source, []) }
        let characters = Array(source)
        var output = ""
        var notes: [String] = []
        var index = 0
        while index < characters.count {
            if characters[index] == "\\", index + 1 < characters.count {
                output.append(characters[index])
                output.append(characters[index + 1])
                index += 2
                continue
            }
            if characters[index] == "^", let (text, end) = note(in: characters, at: index) {
                output += placeholder(notes.count)
                notes.append(text)
                index = end
                continue
            }
            output.append(characters[index])
            index += 1
        }
        return (output, notes)
    }

    static func placeholder(_ index: Int) -> String { "LLMDFOOTNOTE\(index)X" }

    /// The texts of all notes of a document, in order.
    static func notes(in markdown: String) -> [String] {
        markdown.components(separatedBy: "\n").flatMap { extract($0).notes }
    }

    private static func isBalanced(_ text: String) -> Bool {
        var depth = 0
        var escaped = false
        for character in text {
            if escaped { escaped = false; continue }
            switch character {
            case "\\": escaped = true
            case "[": depth += 1
            case "]":
                depth -= 1
                if depth < 0 { return false }
            default: break
            }
        }
        return depth == 0 && !escaped
    }

    private static func escapeBrackets(_ text: String) -> String {
        var output = ""
        var escaped = false
        for character in text {
            if escaped {
                output.append(character)
                escaped = false
                continue
            }
            if character == "\\" { escaped = true }
            if character == "[" || character == "]" { output += "\\" }
            output.append(character)
        }
        return output
    }
}
