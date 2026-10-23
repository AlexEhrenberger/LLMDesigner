import Foundation

/// Finding a word or passage in a text the way the reader means it: upper and lower case alike unless asked,
/// typographic quotes, apostrophes and dashes the same as the plain keys (the editor replaces those while typing),
/// and optionally whole words only.
enum TextSearch {
    struct Options: Equatable, Sendable {
        var matchesCase = false
        var wholeWords = false
    }

    /// More are not shown; a single letter in a book would otherwise slow every keystroke.
    static let limit = 5000

    /// Where the query occurs in the text, in order, as UTF-16 ranges of the text.
    static func ranges(of query: String, in text: String, options: Options = Options()) -> [NSRange] {
        guard !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, !text.isEmpty else { return [] }
        let haystack = folded(text)
        let needle = folded(query) as String
        let first = needle.unicodeScalars.first.map(isWordCharacter) ?? false
        let last = needle.unicodeScalars.last.map(isWordCharacter) ?? false
        let compare: NSString.CompareOptions = options.matchesCase ? [] : [.caseInsensitive]
        var result: [NSRange] = []
        var start = 0
        while start < haystack.length, result.count < limit {
            let found = haystack.range(of: needle, options: compare, range: NSRange(location: start, length: haystack.length - start))
            guard found.location != NSNotFound, found.length > 0 else { break }
            start = found.location + 1
            if options.wholeWords {
                if first, found.location > 0, isWordCharacter(at: found.location - 1, in: haystack) { continue }
                if last, NSMaxRange(found) < haystack.length, isWordCharacter(at: NSMaxRange(found), in: haystack) { continue }
            }
            result.append(found)
            // Matches don't overlap: "aa" in "aaaa" is found twice.
            start = NSMaxRange(found)
        }
        return result
    }

    /// The text with every typographic variant replaced by its plain key, one UTF-16 unit for one, so ranges in
    /// the folded text are ranges in the original.
    static func folded(_ text: String) -> NSString {
        var units = Array(text.utf16)
        var changed = false
        for index in units.indices {
            if let plain = plainKeys[units[index]] {
                units[index] = plain
                changed = true
            }
        }
        return changed ? NSString(characters: units, length: units.count) : text as NSString
    }

    private static let plainKeys: [UInt16: UInt16] = {
        var keys: [UInt16: UInt16] = [:]
        let quote = UInt16(UInt8(ascii: "\""))
        let apostrophe = UInt16(UInt8(ascii: "'"))
        let hyphen = UInt16(UInt8(ascii: "-"))
        let space = UInt16(UInt8(ascii: " "))
        for unit: UInt16 in [0x201E, 0x201C, 0x201D, 0x201F, 0x00AB, 0x00BB, 0x2033] { keys[unit] = quote }
        for unit: UInt16 in [0x201A, 0x2018, 0x2019, 0x201B, 0x2039, 0x203A, 0x2032, 0x00B4, 0x0060] { keys[unit] = apostrophe }
        for unit: UInt16 in [0x2010, 0x2011, 0x2012, 0x2013, 0x2014, 0x2015, 0x2212] { keys[unit] = hyphen }
        // Non-breaking and thin spaces, and the line break inside a paragraph (⇧↩).
        for unit: UInt16 in [0x00A0, 0x202F, 0x2009, 0x2007, 0x2028] { keys[unit] = space }
        return keys
    }()

    private static func isWordCharacter(_ scalar: Unicode.Scalar) -> Bool {
        CharacterSet.alphanumerics.contains(scalar) || scalar == "_"
    }

    private static func isWordCharacter(at index: Int, in text: NSString) -> Bool {
        let unit = text.character(at: index)
        // Half of a surrogate pair: an emoji or a rare letter; neither is part of a word here.
        guard let scalar = Unicode.Scalar(unit) else { return false }
        return isWordCharacter(scalar)
    }
}
