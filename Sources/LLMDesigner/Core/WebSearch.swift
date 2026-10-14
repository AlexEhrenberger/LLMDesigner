import Foundation
import PDFKit

enum WebSearchError: LocalizedError {
    case blocked
    case http(Int)
    case invalidURL(String)
    case unsupportedContent(String)
    case emptyPage

    var errorDescription: String? {
        switch self {
        case .blocked:
            return "DuckDuckGo blockiert gerade automatische Anfragen. Bitte etwas später erneut versuchen."
        case .http(let status):
            return "Der Server antwortet mit Status \(status)."
        case .invalidURL(let value):
            return "Ungültige Adresse: \(value)"
        case .unsupportedContent(let type):
            return "Dieser Inhalt lässt sich nicht als Text lesen (\(type))."
        case .emptyPage:
            return "Auf der Seite war kein lesbarer Text zu finden."
        }
    }
}

private let browserUserAgent =
    "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Safari/605.1.15"

/// Keyless web search through DuckDuckGo's HTML result pages, with the lite page as fallback.
/// DuckDuckGo has no official search API: the markup may change, and too many requests in a row
/// get answered with a bot check instead of results.
struct DuckDuckGoSearch: Sendable {
    var region = Self.defaultRegion

    func search(_ query: String, limit: Int) async throws -> [WebSource] {
        let results: [WebSource]
        do {
            results = try await fetch("https://html.duckduckgo.com/html/", query: query, parse: Self.parseHTML)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            results = try await fetch("https://lite.duckduckgo.com/lite/", query: query, parse: Self.parseLite)
        }
        return Array(results.prefix(limit))
    }

    /// DuckDuckGo region codes are country-language, e.g. "de-de", "ch-de", "us-en".
    static var defaultRegion: String {
        guard let language = Locale.current.language.languageCode?.identifier,
              var country = Locale.current.region?.identifier.lowercased() else { return "wt-wt" }
        if country == "gb" { country = "uk" }
        return "\(country)-\(language)"
    }

    private func fetch(_ address: String, query: String, parse: (String) -> [WebSource]) async throws -> [WebSource] {
        var request = URLRequest(url: URL(string: address)!, timeoutInterval: 15)
        request.httpMethod = "POST"
        request.setValue(browserUserAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.setValue(Self.acceptLanguage, forHTTPHeaderField: "Accept-Language")
        request.httpBody = Data("q=\(Self.formEncode(query))&kl=\(region)".utf8)

        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 200
        let html = String(decoding: data, as: UTF8.self)
        let results = parse(html)
        // The bot check comes back as 202 or as a normal page with a challenge instead of results.
        if results.isEmpty && (status == 202 || html.contains("anomaly") || html.localizedCaseInsensitiveContains("captcha")) {
            throw WebSearchError.blocked
        }
        guard (200..<300).contains(status) else { throw WebSearchError.http(status) }
        return results
    }

    static func parseHTML(_ html: String) -> [WebSource] {
        parse(
            html,
            link: #"<a\b[^>]*class="result__a"[^>]*>(.*?)</a>"#,
            snippet: #"class="result__snippet"[^>]*>(.*?)</(?:a|div|td)>"#
        )
    }

    static func parseLite(_ html: String) -> [WebSource] {
        parse(
            html,
            link: #"<a\b[^>]*class=['"]result-link['"][^>]*>(.*?)</a>"#,
            snippet: #"class=['"]result-snippet['"][^>]*>(.*?)</td>"#
        )
    }

    /// Each result starts with its title link; snippet and date are looked up between it and the next link.
    private static func parse(_ html: String, link: String, snippet: String) -> [WebSource] {
        let links = HTMLText.matches(link, in: html)
        var results: [WebSource] = []
        var seen: Set<String> = []
        for (position, match) in links.enumerated() {
            let tag = match.full
            guard let href = HTMLText.firstMatch(#"href=['"]([^'"]+)['"]"#, in: tag)?.groups.first,
                  let url = resolve(HTMLText.decodeEntities(href)), seen.insert(url).inserted else { continue }

            let end = position + 1 < links.count ? links[position + 1].range.lowerBound : html.endIndex
            let rest = String(html[match.range.upperBound..<end])
            let text = HTMLText.firstMatch(snippet, in: rest)?.groups.first.map(HTMLText.plainText)
            let date = HTMLText.firstMatch(#"(\d{4}-\d{2}-\d{2})T\d{2}:\d{2}"#, in: rest)?.groups.first

            let title = HTMLText.plainText(match.groups.first ?? "")
            results.append(WebSource(
                title: title.isEmpty ? url : title,
                url: url,
                snippet: text?.isEmpty == false ? text : nil,
                date: date
            ))
        }
        return results
    }

    /// Unwraps DuckDuckGo's redirect links and drops its own pages (ads, settings).
    private static func resolve(_ href: String) -> String? {
        let absolute = href.hasPrefix("//") ? "https:" + href : href
        guard var components = URLComponents(string: absolute), let host = components.host else { return nil }
        if host.hasSuffix("duckduckgo.com") {
            guard components.path == "/l/",
                  let target = components.queryItems?.first(where: { $0.name == "uddg" })?.value,
                  let unwrapped = URLComponents(string: target), unwrapped.host?.hasSuffix("duckduckgo.com") == false else {
                return nil
            }
            components = unwrapped
        }
        guard components.scheme == "http" || components.scheme == "https" else { return nil }
        return components.string
    }

    private static func formEncode(_ text: String) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._* ")
        return (text.addingPercentEncoding(withAllowedCharacters: allowed) ?? text).replacingOccurrences(of: " ", with: "+")
    }

    static var acceptLanguage: String {
        let languages = Locale.preferredLanguages.prefix(3)
        return (languages + ["en;q=0.5"]).joined(separator: ", ")
    }
}

/// Reads a web page or PDF as plain text for the model.
struct PageReader: Sendable {
    struct Page: Sendable {
        var url: String
        var title: String?
        var text: String
    }

    /// When the page has (almost) no text without JavaScript, or refuses the request, read it via
    /// Jina Reader (r.jina.ai), which renders the page in a browser. Jina then sees the address.
    var useReaderFallback = true

    private static let maxHTMLBytes = 3_000_000
    private static let maxPDFBytes = 15_000_000
    /// Below this, a page probably needs JavaScript to show its content.
    private static let minUsefulCharacters = 400

    func read(_ address: String) async throws -> Page {
        var value = address.trimmingCharacters(in: .whitespacesAndNewlines)
        if !value.contains("://") { value = "https://" + value }
        guard let url = URL(string: value), let scheme = url.scheme, ["http", "https"].contains(scheme), url.host() != nil else {
            throw WebSearchError.invalidURL(address)
        }

        let page: Page
        do {
            page = try await readDirectly(url)
        } catch let error as WebSearchError {
            // Refused (often bot protection) or unreadable: a real browser may get further.
            guard useReaderFallback, case .http = error else { throw error }
            if let rendered = try? await readWithJina(url) { return rendered }
            throw error
        }
        if page.text.count >= Self.minUsefulCharacters || !useReaderFallback { return page }
        // Little text: probably a JavaScript app. Keep what we have if the reader doesn't do better.
        if let rendered = try? await readWithJina(url), rendered.text.count > page.text.count { return rendered }
        guard !page.text.isEmpty else { throw WebSearchError.emptyPage }
        return page
    }

    private func readDirectly(_ url: URL) async throws -> Page {
        var request = URLRequest(url: url, timeoutInterval: 20)
        request.setValue(browserUserAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("text/html,application/xhtml+xml,application/pdf;q=0.9,text/plain;q=0.8,*/*;q=0.5", forHTTPHeaderField: "Accept")
        request.setValue(DuckDuckGoSearch.acceptLanguage, forHTTPHeaderField: "Accept-Language")

        let (bytes, response) = try await URLSession.shared.bytes(for: request)
        let http = response as? HTTPURLResponse
        if let status = http?.statusCode, !(200..<300).contains(status) { throw WebSearchError.http(status) }

        let mime = (response.mimeType ?? "text/html").lowercased()
        let isPDF = mime == "application/pdf" || response.url?.pathExtension.lowercased() == "pdf"
        let isText = mime.hasPrefix("text/") || mime.contains("html") || mime.contains("xml") || mime.contains("json")
        guard isPDF || isText else { throw WebSearchError.unsupportedContent(mime) }

        let limit = isPDF ? Self.maxPDFBytes : Self.maxHTMLBytes
        var data = Data()
        if response.expectedContentLength > 0 { data.reserveCapacity(min(Int(response.expectedContentLength), limit)) }
        for try await byte in bytes {
            data.append(byte)
            if data.count >= limit { break }
        }
        let finalURL = response.url?.absoluteString ?? url.absoluteString

        if isPDF {
            guard let document = PDFDocument(data: data) else { throw WebSearchError.unsupportedContent("PDF") }
            let title = document.documentAttributes?[PDFDocumentAttribute.titleAttribute] as? String
            let text = HTMLText.tidyLines(document.string ?? "")
            guard !text.isEmpty else { throw WebSearchError.emptyPage }
            return Page(url: finalURL, title: title, text: text)
        }

        let text = Self.decode(data, encodingName: response.textEncodingName)
        if mime.contains("html") || mime.contains("xml") {
            let readable = HTMLText.readableText(fromHTML: text)
            return Page(url: finalURL, title: readable.title, text: readable.text)
        }
        return Page(url: finalURL, title: nil, text: HTMLText.tidyLines(text))
    }

    /// Jina Reader renders the page and returns Markdown, headed by "Title:" and "URL Source:" lines.
    private func readWithJina(_ url: URL) async throws -> Page {
        guard let reader = URL(string: "https://r.jina.ai/" + url.absoluteString) else { throw WebSearchError.invalidURL(url.absoluteString) }
        var request = URLRequest(url: reader, timeoutInterval: 40)
        request.setValue("text/plain", forHTTPHeaderField: "Accept")
        let (data, response) = try await URLSession.shared.data(for: request)
        if let status = (response as? HTTPURLResponse)?.statusCode, !(200..<300).contains(status) {
            throw WebSearchError.http(status)
        }

        var title: String?
        var body = String(decoding: data, as: UTF8.self)
        if let marker = body.range(of: "Markdown Content:") {
            let header = body[..<marker.lowerBound]
            title = header.split(separator: "\n").first { $0.hasPrefix("Title:") }
                .map { $0.dropFirst(6).trimmingCharacters(in: .whitespaces) }
            body = String(body[marker.upperBound...])
        }
        let text = HTMLText.tidyLines(body)
        guard !text.isEmpty else { throw WebSearchError.emptyPage }
        return Page(url: url.absoluteString, title: title, text: text)
    }

    private static func decode(_ data: Data, encodingName: String?) -> String {
        if let encodingName {
            let cfEncoding = CFStringConvertIANACharSetNameToEncoding(encodingName as CFString)
            if cfEncoding != kCFStringEncodingInvalidId,
               let text = String(data: data, encoding: String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(cfEncoding))) {
                return text
            }
        }
        return String(data: data, encoding: .utf8) ?? String(decoding: data, as: UTF8.self)
    }
}

/// Small regex helpers to turn HTML into readable text, without a browser engine.
enum HTMLText {
    struct Match {
        let range: Range<String.Index>
        let full: String
        let groups: [String]
    }

    static func matches(_ pattern: String, in text: String) -> [Match] {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive, .dotMatchesLineSeparators]) else { return [] }
        return regex.matches(in: text, range: NSRange(text.startIndex..., in: text)).compactMap { result in
            guard let range = Range(result.range, in: text) else { return nil }
            let groups = (1..<max(result.numberOfRanges, 1)).map { index in
                Range(result.range(at: index), in: text).map { String(text[$0]) } ?? ""
            }
            return Match(range: range, full: String(text[range]), groups: groups)
        }
    }

    static func firstMatch(_ pattern: String, in text: String) -> Match? {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive, .dotMatchesLineSeparators]),
              let result = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let range = Range(result.range, in: text) else { return nil }
        let groups = (1..<max(result.numberOfRanges, 1)).map { index in
            Range(result.range(at: index), in: text).map { String(text[$0]) } ?? ""
        }
        return Match(range: range, full: String(text[range]), groups: groups)
    }

    static func replacing(_ pattern: String, in text: String, with template: String) -> String {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive, .dotMatchesLineSeparators]) else { return text }
        return regex.stringByReplacingMatches(in: text, range: NSRange(text.startIndex..., in: text), withTemplate: template)
    }

    /// One line of text from an HTML fragment: tags removed, entities decoded, whitespace collapsed.
    static func plainText(_ html: String) -> String {
        decodeEntities(replacing("<[^>]+>", in: html, with: ""))
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
    }

    /// The main text of a page. Prefers `<main>` or `<article>` and drops scripts, navigation and forms;
    /// headings and list items keep a Markdown marker so the model sees the structure.
    static func readableText(fromHTML html: String) -> (title: String?, text: String) {
        let title = firstMatch("<title[^>]*>(.*?)</title>", in: html)?.groups.first.map(plainText)

        var cleaned = replacing("<!--.*?-->", in: html, with: " ")
        cleaned = replacing(
            #"<(script|style|noscript|svg|template|iframe|canvas|head|button|select|dialog)\b[^>]*>.*?</\1\s*>"#,
            in: cleaned, with: " "
        )

        var region = cleaned
        var isWholeBody = true
        for tag in ["main", "article"] {
            let candidates = matches("<\(tag)\\b[^>]*>(.*?)</\(tag)\\s*>", in: cleaned).compactMap(\.groups.first)
            if let largest = candidates.max(by: { $0.count < $1.count }), plainText(largest).count >= 500 {
                region = largest
                isWholeBody = false
                break
            }
        }
        let noise = isWholeBody ? "nav|aside|form|footer|header" : "nav|aside|form|footer"
        region = replacing(#"<(\#(noise))\b[^>]*>.*?</\1\s*>"#, in: region, with: " ")
        // Language switchers (e.g. Wikipedia's list of 70 languages) are lists of links with `hreflang`.
        region = replacing(#"<li\b[^>]*>(?:(?!</li>).)*?hreflang=(?:(?!</li>).)*?</li>"#, in: region, with: "")

        region = replacing(#"<h[1-6]\b[^>]*>"#, in: region, with: "\n\n## ")
        region = replacing(#"<li\b[^>]*>"#, in: region, with: "\n- ")
        region = replacing(#"<(td|th)\b[^>]*>"#, in: region, with: " | ")
        region = replacing(
            #"</?(p|div|section|article|main|br|tr|ul|ol|table|blockquote|pre|dd|dt|dl|figure|figcaption|h[1-6])\b[^>]*>"#,
            in: region, with: "\n"
        )
        region = replacing("<[^>]+>", in: region, with: "")
        return (title?.isEmpty == false ? title : nil, tidyLines(decodeEntities(region)))
    }

    /// Collapses runs of spaces, trims every line and keeps at most one empty line in a row.
    static func tidyLines(_ text: String) -> String {
        var lines: [String] = []
        var previousEmpty = true
        for rawLine in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = rawLine.split(whereSeparator: { $0 == " " || $0 == "\t" || $0 == "\u{A0}" || $0 == "\r" })
                .joined(separator: " ")
            // Lines that only hold a marker (an empty heading or list item) carry no text.
            let isEmpty = line == "##" || line == "-" || line.allSatisfy { $0 == "|" || $0 == " " }
            if isEmpty {
                if !previousEmpty { lines.append("") }
                previousEmpty = true
            } else {
                lines.append(line)
                previousEmpty = false
            }
        }
        return lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static let namedEntities: [String: String] = [
        "amp": "&", "lt": "<", "gt": ">", "quot": "\"", "apos": "'", "nbsp": " ",
        "ndash": "–", "mdash": "—", "hellip": "…", "laquo": "«", "raquo": "»",
        "bdquo": "„", "ldquo": "“", "rdquo": "”", "lsquo": "‘", "rsquo": "’", "sbquo": "‚",
        "auml": "ä", "ouml": "ö", "uuml": "ü", "Auml": "Ä", "Ouml": "Ö", "Uuml": "Ü", "szlig": "ß",
        "eacute": "é", "egrave": "è", "aacute": "á", "agrave": "à", "ccedil": "ç",
        "copy": "©", "reg": "®", "trade": "™", "euro": "€", "deg": "°", "middot": "·", "bull": "•",
        "times": "×", "shy": "",
    ]

    static func decodeEntities(_ text: String) -> String {
        guard text.contains("&") else { return text }
        var result = ""
        result.reserveCapacity(text.count)
        var index = text.startIndex
        while index < text.endIndex {
            let character = text[index]
            guard character == "&",
                  let semicolon = text[index...].prefix(12).firstIndex(of: ";") else {
                result.append(character)
                index = text.index(after: index)
                continue
            }
            let name = text[text.index(after: index)..<semicolon]
            var replacement: String?
            if name.hasPrefix("#x") || name.hasPrefix("#X") {
                replacement = UInt32(name.dropFirst(2), radix: 16).flatMap(Unicode.Scalar.init).map { String(Character($0)) }
            } else if name.hasPrefix("#") {
                replacement = UInt32(name.dropFirst()).flatMap(Unicode.Scalar.init).map { String(Character($0)) }
            } else {
                replacement = namedEntities[String(name)]
            }
            if let replacement {
                result += replacement
                index = text.index(after: semicolon)
            } else {
                result.append(character)
                index = text.index(after: index)
            }
        }
        return result
    }
}
