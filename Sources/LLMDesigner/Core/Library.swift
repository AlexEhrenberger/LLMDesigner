import Foundation

/// A folder in the sidebar. Chats and skills each have their own folders; folders don't nest.
struct Folder: Identifiable, Codable, Hashable, Sendable {
    var id = UUID()
    var name: String
    var createdAt = Date()
    var isCollapsed: Bool?

    static func sorted(_ folders: [Folder]) -> [Folder] {
        folders.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }
}

/// A building block for the system prompt: a role, a writing style, formatting rules … A chat can combine
/// any number of skills; their instructions are appended to the system prompt in the order they were switched on.
struct Skill: Identifiable, Codable, Hashable, Sendable {
    var id = UUID()
    var name: String
    /// One line for the library, e.g. "Antwortet in zwei, drei Sätzen".
    var summary: String
    /// The text that goes into the system prompt.
    var instructions: String
    /// SF Symbol shown next to the name.
    var symbol: String?
    var folderID: Folder.ID?
    var createdAt = Date()
    var updatedAt = Date()

    static let defaultSymbol = "puzzlepiece.extension"

    var displayName: String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "Unbenannter Skill" : trimmed
    }

    var isEmpty: Bool {
        name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && summary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && instructions.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    func matches(_ query: String) -> Bool {
        query.isEmpty || name.localizedStandardContains(query) || summary.localizedStandardContains(query)
            || instructions.localizedStandardContains(query)
    }

    static func sorted(_ skills: [Skill]) -> [Skill] {
        skills.sorted { $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending }
    }
}

enum SkillPrompt {
    /// The system prompt of a chat: the general one from the settings, then the instructions of every active skill.
    static func compose(base: String, skills: [Skill]) -> String {
        ([base] + skills.map(\.instructions))
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: "\n\n")
    }

    /// Rough token count (German text runs at about 3–4 characters per token).
    static func estimatedTokens(_ text: String) -> Int {
        Int((Double(text.count) / 3.5).rounded(.up))
    }

    /// Skills offered on an empty library, to show what a skill can be.
    static func examples() -> (folders: [Folder], skills: [Skill]) {
        let roles = Folder(name: "Rollen")
        let style = Folder(name: "Schreibstil")
        let format = Folder(name: "Formatierung")
        let skills = [
            Skill(
                name: "Finanzberater",
                summary: "Erklärt Geldthemen wie ein erfahrener Berater",
                instructions: """
                Du nimmst die Rolle eines erfahrenen, unabhängigen Finanzberaters ein. Erkläre Begriffe verständlich, \
                rechne Beispiele konkret vor und nenne Chancen und Risiken gleichermaßen. Frage nach, wenn für eine \
                sinnvolle Einschätzung Angaben fehlen (Ziel, Zeithorizont, Risikobereitschaft). Weise bei konkreten \
                Anlageentscheidungen darauf hin, dass du keine persönliche, lizenzierte Beratung ersetzt.
                """,
                symbol: "eurosign.circle",
                folderID: roles.id
            ),
            Skill(
                name: "Einfühlsamer Zuhörer",
                summary: "Hört zu und stellt behutsame Fragen",
                instructions: """
                Du bist ein einfühlsamer Gesprächspartner. Hör aufmerksam zu, fasse in eigenen Worten zusammen, was du \
                verstanden hast, und stelle behutsame, offene Fragen. Urteile nicht und gib nur Ratschläge, wenn danach \
                gefragt wird. Du bist kein Ersatz für eine Therapie: Wirkt die Lage ernst oder geht es um eine Krise, \
                empfiehl freundlich professionelle Hilfe (z. B. Telefonseelsorge 0800 111 0 111).
                """,
                symbol: "heart.text.square",
                folderID: roles.id
            ),
            Skill(
                name: "Kurz halten",
                summary: "Antwortet in zwei, drei Sätzen",
                instructions: "Antworte so kurz wie möglich, in höchstens zwei bis drei Sätzen. Keine Einleitung, keine Wiederholung der Frage, keine Zusammenfassung am Ende.",
                symbol: "scissors",
                folderID: style.id
            ),
            Skill(
                name: "Gedichte",
                summary: "Antwortet in gereimten Versen",
                instructions: "Formuliere deine Antworten als Gedicht mit Reimen und gleichmäßigem Rhythmus. Der Inhalt soll trotzdem stimmen und die Frage beantworten.",
                symbol: "text.quote",
                folderID: style.id
            ),
            Skill(
                name: "Für PDF gesetzt",
                summary: "Gegliedert wie ein Dokument zum Exportieren",
                instructions: """
                Schreibe Antworten wie ein Dokument, das als PDF exportiert wird: Gliedere mit Markdown-Überschriften \
                (##, ###), nutze vollständige Absätze statt loser Stichpunkte, setze Formeln in LaTeX ($…$ bzw. $$…$$) \
                und verzichte auf Emojis.
                """,
                symbol: "doc.richtext",
                folderID: format.id
            ),
        ]
        return ([roles, style, format], skills)
    }
}

/// Saves the chat folders, skills and skill folders next to the chats in Application Support.
struct LibraryStore {
    struct SkillLibrary: Codable {
        var skills: [Skill] = []
        var folders: [Folder] = []
    }

    private let directory: URL
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    init() {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        directory = base.appendingPathComponent("LLMDesigner", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
    }

    private var chatFoldersURL: URL { directory.appendingPathComponent("ChatFolders.json") }
    private var skillsURL: URL { directory.appendingPathComponent("Skills.json") }

    func loadChatFolders() -> [Folder] {
        load([Folder].self, from: chatFoldersURL) ?? []
    }

    func saveChatFolders(_ folders: [Folder]) {
        save(folders, to: chatFoldersURL)
    }

    func loadSkills() -> SkillLibrary {
        load(SkillLibrary.self, from: skillsURL) ?? SkillLibrary()
    }

    func saveSkills(_ library: SkillLibrary) {
        save(library, to: skillsURL)
    }

    private func load<T: Decodable>(_ type: T.Type, from url: URL) -> T? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        do {
            return try decoder.decode(type, from: Data(contentsOf: url))
        } catch {
            // Keep the unreadable file, so the next save doesn't overwrite what is in it.
            let backup = url.deletingPathExtension().appendingPathExtension("unreadable-\(Int(Date().timeIntervalSince1970)).json")
            try? FileManager.default.moveItem(at: url, to: backup)
            print("LLMDesigner: \(url.lastPathComponent) konnte nicht gelesen werden, liegt jetzt unter \(backup.lastPathComponent): \(error)")
            return nil
        }
    }

    private func save<T: Encodable>(_ value: T, to url: URL) {
        do {
            try encoder.encode(value).write(to: url, options: .atomic)
        } catch {
            print("LLMDesigner: \(url.lastPathComponent) konnte nicht gespeichert werden: \(error)")
        }
    }
}
