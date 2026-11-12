import Foundation

/// A paper a scholarly search found.
struct ScholarHit: Sendable, Equatable {
    var title: String
    var url: String
    var authors: [String]
    var year: Int?
    var doi: String?
    var abstract: String
    var citations: Int?
}

/// arXiv's open API: only the search words leave the Mac.
enum ArxivSearch {
    static func search(_ query: String, limit: Int) async throws -> [ScholarHit] {
        var components = URLComponents(string: "https://export.arxiv.org/api/query")!
        components.queryItems = [
            URLQueryItem(name: "search_query", value: "all:" + query),
            URLQueryItem(name: "start", value: "0"),
            URLQueryItem(name: "max_results", value: String(max(1, min(10, limit)))),
            URLQueryItem(name: "sortBy", value: "relevance"),
        ]
        guard let url = components.url else { return [] }
        var request = URLRequest(url: url, timeoutInterval: 20)
        request.setValue("LLMDesigner/1.0 (macOS research app)", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await URLSession.shared.data(for: request)
        if let status = (response as? HTTPURLResponse)?.statusCode, !(200..<300).contains(status) {
            throw LLMError.server("arXiv antwortet mit \(status).")
        }
        return parse(data)
    }

    /// The entries of arXiv's Atom feed.
    static func parse(_ data: Data) -> [ScholarHit] {
        let delegate = AtomEntries()
        let parser = XMLParser(data: data)
        parser.delegate = delegate
        parser.parse()
        return delegate.entries.compactMap { entry in
            let title = clean(entry["title"]?.first ?? "")
            guard !title.isEmpty else { return nil }
            let id = entry["id"]?.first?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let year = entry["published"]?.first.flatMap { Int($0.prefix(4)) }
            return ScholarHit(title: title, url: id.replacingOccurrences(of: "http://", with: "https://"), authors: (entry["name"] ?? []).map(clean),
                              year: year, doi: entry["arxiv:doi"]?.first, abstract: clean(entry["summary"]?.first ?? ""), citations: nil)
        }
    }

    private static func clean(_ text: String) -> String {
        text.components(separatedBy: .whitespacesAndNewlines).filter { !$0.isEmpty }.joined(separator: " ")
    }

    private final class AtomEntries: NSObject, XMLParserDelegate {
        var entries: [[String: [String]]] = []
        private var current: [String: [String]]?
        private var element = ""
        private var text = ""

        func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?, attributes: [String: String] = [:]) {
            if name == "entry" { current = [:] }
            element = name
            text = ""
        }

        func parser(_ parser: XMLParser, foundCharacters string: String) { text += string }

        func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
            if name == "entry", let current {
                entries.append(current)
                self.current = nil
            } else if current != nil, ["title", "summary", "published", "name", "id", "arxiv:doi"].contains(name) {
                current?[name, default: []].append(text)
            }
            text = ""
        }
    }
}

/// OpenAlex: works of all disciplines with abstracts and citation counts; no key, only the search words leave the Mac.
enum OpenAlexSearch {
    static func search(_ query: String, limit: Int) async throws -> [ScholarHit] {
        var components = URLComponents(string: "https://api.openalex.org/works")!
        components.queryItems = [
            URLQueryItem(name: "search", value: query),
            URLQueryItem(name: "per-page", value: String(max(1, min(10, limit)))),
            URLQueryItem(name: "select", value: "id,doi,title,publication_year,authorships,abstract_inverted_index,cited_by_count,primary_location"),
        ]
        guard let url = components.url else { return [] }
        var request = URLRequest(url: url, timeoutInterval: 20)
        request.setValue("LLMDesigner/1.0 (macOS research app)", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await URLSession.shared.data(for: request)
        if let status = (response as? HTTPURLResponse)?.statusCode, !(200..<300).contains(status) {
            throw LLMError.server("OpenAlex antwortet mit \(status).")
        }
        return parse(data)
    }

    static func parse(_ data: Data) -> [ScholarHit] {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any], let results = object["results"] as? [[String: Any]] else { return [] }
        return results.compactMap { work in
            guard let title = work["title"] as? String, !title.isEmpty else { return nil }
            let doi = (work["doi"] as? String)?.replacingOccurrences(of: "https://doi.org/", with: "")
            let landing = ((work["primary_location"] as? [String: Any])?["landing_page_url"] as? String)
            let url = landing ?? (doi.map { "https://doi.org/\($0)" }) ?? (work["id"] as? String ?? "")
            let authors = (work["authorships"] as? [[String: Any]] ?? []).compactMap { ($0["author"] as? [String: Any])?["display_name"] as? String }
            let abstract = (work["abstract_inverted_index"] as? [String: [Int]]).map(abstractText) ?? ""
            return ScholarHit(title: title, url: url, authors: authors, year: work["publication_year"] as? Int, doi: doi,
                              abstract: abstract, citations: work["cited_by_count"] as? Int)
        }
    }

    /// OpenAlex keeps abstracts as word → positions.
    static func abstractText(_ index: [String: [Int]]) -> String {
        var words: [(Int, String)] = []
        for (word, positions) in index { for position in positions { words.append((position, word)) } }
        return words.sorted { $0.0 < $1.0 }.map(\.1).joined(separator: " ")
    }
}
