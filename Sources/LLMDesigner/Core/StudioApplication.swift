import Foundation

/// Applications next to the chat where the model helps with a piece of work. Only the menu exists so far;
/// Writer Studio comes first. Coding Studio follows later.
enum StudioApplication: String, CaseIterable, Identifiable {
    case writer, citation, presenter, stories, notes

    var id: String { rawValue }

    var title: String {
        switch self {
        case .writer: "Writer Studio"
        case .citation: "Citation Studio"
        case .presenter: "Presenter Studio"
        case .stories: "Stories Studio"
        case .notes: "Notes"
        }
    }

    var symbol: String {
        switch self {
        case .writer: "doc.richtext"
        case .citation: "quote.bubble"
        case .presenter: "play.rectangle"
        case .stories: "books.vertical"
        case .notes: "note.text"
        }
    }

    /// Notes is not built yet.
    var isAvailable: Bool { self != .notes }

    var summary: String {
        switch self {
        case .writer: "Texte schreiben und überarbeiten"
        case .citation: "Quellen und Zitate sammeln"
        case .presenter: "Präsentationen entwerfen"
        case .stories: "Romane strukturieren und entwerfen"
        case .notes: "Notizen sammeln und ordnen"
        }
    }
}
