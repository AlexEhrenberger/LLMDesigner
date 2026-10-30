import Foundation
import NaturalLanguage

/// Turns an answer (Markdown with LaTeX) into text a voice can read: no markup, no code, no emoji,
/// and formulas in words ("x hoch 2", "a durch b").
enum SpeakableText {
    static func from(markdown: String) -> String {
        let german = language(of: markdown) != "en"
        var parts: [String] = []
        for block in MarkdownParser.parse(markdown) {
            switch block {
            case .paragraph(let text), .quote(let text):
                parts.append(inline(text, german: german))
            case .heading(_, let text):
                parts.append(sentence(inline(text, german: german)))
            case .list(let items):
                parts.append(items.map { sentence(inline($0.text, german: german)) }.joined(separator: "\n"))
            case .table(let header, let rows, _, _):
                for row in rows {
                    let cells = zip(header, row).map { "\(inline($0, german: german)): \(inline($1, german: german))" }
                    parts.append(sentence(cells.joined(separator: ", ")))
                }
            case .math(let latex, _):
                parts.append(sentence(spokenMath(latex, german: german)))
            case .code, .rule, .pageBreak, .columnBreak:
                continue
            }
        }
        return parts.filter { !$0.isEmpty }.joined(separator: "\n\n")
    }

    /// The text as Qwen TTS should get it. Qwen spells abbreviations letter by letter ("vgl. Abb. 3" came out as
    /// "VGLE App 3") and stumbles over brackets and symbols, so they are written out; `language` is a two-letter code.
    static func forVoice(_ text: String, language: String) -> String {
        var text = text
        func replace(_ pattern: String, _ template: String) {
            text = text.replacingOccurrences(of: pattern, with: template, options: .regularExpression)
        }
        let abbreviations = language == "en" ? englishAbbreviations : language == "de" ? germanAbbreviations : []
        for (abbreviation, words) in abbreviations {
            let pattern = #"(?<![\p{L}\d])"# + abbreviation.split(separator: ".")
                .map { NSRegularExpression.escapedPattern(for: String($0)) }
                .joined(separator: #"\.\s?"#) + #"\."#
            // "… usw. Danach": the abbreviation ended the sentence, so its full stop stays.
            if sentenceEnds.contains(abbreviation) {
                replace(pattern + #"(?=\s*$|\s*\n|\s+\p{Lu})"#, words + ".")
            }
            replace(pattern, words)
        }
        let percent = language == "en" ? "percent" : "Prozent"
        replace(#"(?<=\d)\s?%|%"#, " " + percent)
        replace(#"(?<=\d)\s?€"#, " Euro")
        replace(#"€\s?(\d[\d.,]*)"#, "$1 Euro")
        replace(#"\s*&\s*"#, language == "en" ? " and " : " und ")
        if language == "de" {
            replace(#"(?<![\p{L}\d])S\.\s?(?=\d)"#, "Seite ")
            replace(#"§\s?"#, "Paragraf ")
            replace(#"°\s?C\b"#, " Grad Celsius")
            replace("°", " Grad")
            replace(#"\bkm/h\b"#, "Kilometer pro Stunde")
            replace(#"(?<=\d)\s?–\s?(?=\d)"#, " bis ")
        }
        // Brackets, arrows and dashes become pauses; quotation marks and bullets go.
        replace(#"\s*(?:→|⇒|->|=>)\s*"#, ", ")
        replace(#"\s+[–—-]\s+"#, ", ")
        replace(#"\s*[(\[]\s*"#, ", ")
        replace(#"\s*[)\]]"#, ",")
        replace(#"[„“”"«»•▪◦]"#, "")
        replace(#",\s*(?=[,.!?:;…]|$)"#, "")
        replace(#"(?m)^\s*,\s*"#, "")
        replace(#"[ \t]{2,}"#, " ")
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Written without spaces; "z. B." and "z.B." both match.
    private static let germanAbbreviations: [(String, String)] = [
        ("i.d.R.", "in der Regel"), ("u.v.m.", "und vieles mehr"), ("n.Chr.", "nach Christus"), ("v.Chr.", "vor Christus"),
        ("z.B.", "zum Beispiel"), ("d.h.", "das heißt"), ("u.a.", "unter anderem"), ("u.U.", "unter Umständen"),
        ("v.a.", "vor allem"), ("o.Ä.", "oder Ähnliches"), ("z.T.", "zum Teil"), ("s.o.", "siehe oben"), ("s.u.", "siehe unten"),
        ("bzw.", "beziehungsweise"), ("usw.", "und so weiter"), ("etc.", "et cetera"), ("ca.", "circa"), ("vgl.", "vergleiche"),
        ("Vgl.", "Vergleiche"), ("evtl.", "eventuell"), ("ggf.", "gegebenenfalls"), ("inkl.", "inklusive"), ("exkl.", "exklusive"),
        ("zzgl.", "zuzüglich"), ("bspw.", "beispielsweise"), ("sog.", "sogenannte"), ("bzgl.", "bezüglich"),
        ("insbes.", "insbesondere"), ("insb.", "insbesondere"), ("allg.", "allgemein"), ("gem.", "gemäß"), ("geb.", "geboren"),
        ("Nr.", "Nummer"), ("Abb.", "Abbildung"), ("Tab.", "Tabelle"), ("Kap.", "Kapitel"), ("Bd.", "Band"),
        ("Hrsg.", "Herausgeber"), ("Dr.", "Doktor"), ("Prof.", "Professor"), ("Mio.", "Millionen"), ("Mrd.", "Milliarden"),
        ("Tsd.", "Tausend"), ("Std.", "Stunden"), ("Min.", "Minuten"), ("Jhd.", "Jahrhundert"), ("Jh.", "Jahrhundert"),
        ("Str.", "Straße"), ("ff.", "folgende"),
    ]

    private static let englishAbbreviations: [(String, String)] = [
        ("e.g.", "for example"), ("i.e.", "that is"), ("etc.", "et cetera"), ("vs.", "versus"), ("approx.", "approximately"),
        ("Fig.", "Figure"),
    ]

    /// Abbreviations that often close a sentence. Others are usually followed by a capitalised noun ("z. B. Daten",
    /// "Dr. Müller"), which must not read as a new sentence.
    private static let sentenceEnds: Set<String> = ["usw.", "etc.", "u.v.m.", "ff."]

    /// Two-letter language code of the text ("de", "en", …), used for the voice.
    static func language(of text: String) -> String {
        let recognizer = NLLanguageRecognizer()
        recognizer.processString(String(text.prefix(1500)))
        return String((recognizer.dominantLanguage?.rawValue ?? "de").prefix(2))
    }

    private static func inline(_ source: String, german: Bool) -> String {
        var output = ""
        for segment in MathTokenizer.segments(source) {
            switch segment {
            case .text(let text):
                let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace,
                                                                      failurePolicy: .returnPartiallyParsedIfPossible)
                let plain = (try? AttributedString(markdown: text, options: options)).map { String($0.characters) } ?? text
                output += plain
            case .math(let latex):
                output += " " + spokenMath(latex, german: german) + " "
            }
        }
        let withoutEmoji = output.filter { character in
            !character.unicodeScalars.contains { $0.properties.isEmojiPresentation || (0x1F000...0x1FAFF).contains($0.value) }
        }
        return withoutEmoji.split(whereSeparator: { $0 == " " || $0 == "\t" }).joined(separator: " ")
    }

    private static func sentence(_ text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let last = trimmed.last, !".!?:;".contains(last) else { return trimmed }
        return trimmed + "."
    }

    // MARK: Formulas

    private static func spokenMath(_ latex: String, german: Bool) -> String {
        let words: [String: String] = german ? [
            "frac": "durch", "sqrt": "Wurzel aus", "pow": "hoch", "cdot": "mal", "times": "mal", "pm": "plus minus",
            "neq": "ungleich", "leq": "kleiner gleich", "geq": "größer gleich", "approx": "ungefähr", "infty": "unendlich",
            "to": "gegen", "sum": "Summe", "int": "Integral", "lim": "Grenzwert", "circ": "Grad", "=": "gleich",
            "+": "plus", "-": "minus", "<": "kleiner", ">": "größer", "/": "durch", "*": "mal",
        ] : [
            "frac": "over", "sqrt": "square root of", "pow": "to the power of", "cdot": "times", "times": "times", "pm": "plus or minus",
            "neq": "not equal to", "leq": "less than or equal to", "geq": "greater than or equal to", "approx": "approximately",
            "infty": "infinity", "to": "to", "sum": "sum", "int": "integral", "lim": "limit", "circ": "degrees", "=": "equals",
            "+": "plus", "-": "minus", "<": "less than", ">": "greater than", "/": "over", "*": "times",
        ]
        var text = MathRenderer.normalize(latex)
            .replacingOccurrences(of: #"\\begin\{[^}]*\}|\\end\{[^}]*\}|\\\\|&"#, with: " ", options: .regularExpression)
            .replacingOccurrences(of: #"\\(text|mathrm|mathbf|mathit|operatorname)\{([^{}]*)\}"#, with: " $2 ", options: .regularExpression)

        // Innermost first, so nested fractions and roots come out in reading order.
        for _ in 0..<4 {
            text = text.replacingOccurrences(of: #"\\frac\{([^{}]*)\}\{([^{}]*)\}"#, with: " $1 \(words["frac"]!) $2 ", options: .regularExpression)
            text = text.replacingOccurrences(of: #"\\sqrt\{([^{}]*)\}"#, with: " \(words["sqrt"]!) $1 ", options: .regularExpression)
            text = text.replacingOccurrences(of: #"\^\{([^{}]*)\}"#, with: " \(words["pow"]!) $1 ", options: .regularExpression)
        }
        text = text.replacingOccurrences(of: #"\^\\circ"#, with: " \(words["circ"]!) ", options: .regularExpression)
        text = text.replacingOccurrences(of: #"\^(\w)"#, with: " \(words["pow"]!) $1 ", options: .regularExpression)
        text = text.replacingOccurrences(of: #"_\{([^{}]*)\}|_(\w)"#, with: " $1$2 ", options: .regularExpression)

        for command in ["cdot", "times", "pm", "neq", "leq", "geq", "approx", "infty", "to", "sum", "int", "lim", "circ"] {
            text = text.replacingOccurrences(of: "\\\\\(command)(?![a-zA-Z])", with: " \(words[command]!) ", options: .regularExpression)
        }
        // Greek letters and other commands: read the name ("\\alpha" → "alpha").
        text = text.replacingOccurrences(of: #"\\([a-zA-Z]+)"#, with: " $1 ", options: .regularExpression)
        text = text.replacingOccurrences(of: #"[{}\\]"#, with: " ", options: .regularExpression)
        for symbol in ["=", "+", "<", ">", "/", "*"] {
            text = text.replacingOccurrences(of: symbol, with: " \(words[symbol]!) ")
        }
        text = text.replacingOccurrences(of: #"(?<=[\s(\w])-(?=[\s\w(])"#, with: " \(words["-"]!) ", options: .regularExpression)
        return text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }
}
