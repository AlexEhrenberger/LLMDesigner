import AppKit

/// Colours the code blocks: every run of code paragraphs is one block, read as its language (the fence's, or a
/// guess when the code clearly is Python or SQL).
extension WriterStyler {
    /// The paragraphs of the code blocks that the range touches, coloured by their tokens. Called after the styling
    /// of the paragraphs, which gave the code its plain colour.
    static func highlightCode(_ storage: NSTextStorage, in range: NSRange, palette: WriterPalette) {
        let string = storage.string as NSString
        guard string.length > 0 else { return }
        let end = min(NSMaxRange(range), string.length)
        var position = string.paragraphRange(for: NSRange(location: min(range.location, string.length - 1), length: 0)).location
        var handled = Set<Int>()
        while position < end {
            let paragraph = string.paragraphRange(for: NSRange(location: position, length: 0))
            guard paragraph.length > 0 else { break }
            if block(in: storage, at: paragraph.location) == .code {
                let run = codeRun(around: paragraph, in: storage)
                if handled.insert(run.location).inserted { highlight(run, in: storage, palette: palette) }
                position = max(NSMaxRange(run), NSMaxRange(paragraph))
            } else {
                position = NSMaxRange(paragraph)
            }
        }
    }

    /// All consecutive code paragraphs around this one. Two blocks that both name a language, and not the same,
    /// are two runs.
    static func codeRun(around paragraph: NSRange, in storage: NSAttributedString) -> NSRange {
        let string = storage.string as NSString
        func fence(at location: Int) -> String? {
            (storage.attribute(.writerCodeLanguage, at: location, effectiveRange: nil) as? String).flatMap { $0.isEmpty ? nil : $0 }
        }
        var run = paragraph
        var language = fence(at: paragraph.location)
        while run.location > 0 {
            let previous = string.paragraphRange(for: NSRange(location: run.location - 1, length: 0))
            guard block(in: storage, at: previous.location) == .code else { break }
            let other = fence(at: previous.location)
            if let language, let other, language != other { break }
            language = language ?? other
            run = NSUnionRange(run, previous)
        }
        while NSMaxRange(run) < string.length {
            let next = string.paragraphRange(for: NSRange(location: NSMaxRange(run), length: 0))
            guard block(in: storage, at: next.location) == .code else { break }
            let other = fence(at: next.location)
            if let language, let other, language != other { break }
            language = language ?? other
            run = NSUnionRange(run, next)
        }
        return run
    }

    /// The language a run of code is written in: the one its paragraphs carry (`fence` is what the fence says, also
    /// for a language that isn't known), else a guess.
    static func language(of run: NSRange, in storage: NSAttributedString) -> (language: CodeLanguage?, fence: String?) {
        var fence: String?
        storage.enumerateAttribute(.writerCodeLanguage, in: run) { value, _, stop in
            if let value = value as? String, !value.isEmpty { fence = value; stop.pointee = true }
        }
        if let fence { return (CodeLanguage(fence: fence), fence) }
        return (CodeLanguage.detect((storage.string as NSString).substring(with: run)), nil)
    }

    private static func highlight(_ run: NSRange, in storage: NSTextStorage, palette: WriterPalette) {
        let (language, fence) = language(of: run, in: storage)
        // A line added to the block takes the block's language along, so the Markdown fence keeps it.
        if let fence { storage.addAttribute(.writerCodeLanguage, value: fence, range: run) }
        // The plain colour first: tokens that changed back to plain must lose their colour.
        storage.addAttribute(.foregroundColor, value: palette.text, range: run)
        guard let language else { return }
        let code = (storage.string as NSString).substring(with: run)
        for token in CodeHighlighter.tokens(in: code, language: language) {
            guard let color = CodeTheme.color(token.kind, light: palette.isLight) else { continue }
            storage.addAttribute(.foregroundColor, value: color, range: NSRange(location: run.location + token.range.location, length: token.range.length))
        }
    }
}
