import Foundation

/// Persists every chat as its own JSON file in the library's `Chats` folder.
struct ChatStore {
    let directory: URL
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    init() {
        directory = AppLibrary.current.folder("Chats")

        encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
    }

    func loadAll() -> [Chat] {
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        return files
            .filter { $0.pathExtension == "json" }
            .compactMap { url -> Chat? in
                do {
                    return try decoder.decode(Chat.self, from: Data(contentsOf: url))
                } catch {
                    print("LLMDesigner: Chat \(url.lastPathComponent) konnte nicht gelesen werden: \(error)")
                    return nil
                }
            }
            .sorted { $0.updatedAt > $1.updatedAt }
    }

    func save(_ chat: Chat) {
        do {
            try encoder.encode(chat).write(to: url(for: chat.id), options: .atomic)
        } catch {
            print("LLMDesigner: Chat \(chat.id) konnte nicht gespeichert werden: \(error)")
        }
    }

    func delete(_ id: UUID) {
        try? FileManager.default.removeItem(at: url(for: id))
    }

    private func url(for id: UUID) -> URL {
        directory.appendingPathComponent("\(id.uuidString).json")
    }
}
