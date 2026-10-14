import Foundation

/// Applications next to the chat where the model helps with a piece of work. Only the menu exists so far;
/// Writer Studio comes first. Coding Studio follows later.
enum StudioApplication: String, CaseIterable, Identifiable {
    case writer, presenter, notes

    var id: String { rawValue }

    var title: String {
        switch self {
        case .writer: "Writer Studio"
        case .presenter: "Presenter Studio"
        case .notes: "Notes"
        }
    }

    var symbol: String {
        switch self {
        case .writer: "doc.richtext"
        case .presenter: "play.rectangle"
        case .notes: "note.text"
        }
    }

    /// Only Writer Studio is built so far.
    var isAvailable: Bool { self == .writer }

    var summary: String {
        switch self {
        case .writer: "Texte schreiben und überarbeiten"
        case .presenter: "Präsentationen entwerfen"
        case .notes: "Notizen sammeln und ordnen"
        }
    }
}
