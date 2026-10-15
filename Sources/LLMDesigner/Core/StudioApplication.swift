import Foundation

/// Applications next to the chat where the model helps with a piece of work. Only the menu exists so far;
/// Writer Studio comes first. Coding Studio follows later.
enum StudioApplication: String, CaseIterable, Identifiable {
    case writer, citation, presenter, notes

    var id: String { rawValue }

    var title: String {
        switch self {
        case .writer: "Writer Studio"
        case .citation: "Citation Studio"
        case .presenter: "Presenter Studio"
        case .notes: "Notes"
        }
    }

    var symbol: String {
        switch self {
        case .writer: "doc.richtext"
        case .citation: "quote.bubble"
        case .presenter: "play.rectangle"
        case .notes: "note.text"
        }
    }

    /// Writer Studio and Citation Studio are built so far.
    var isAvailable: Bool { self == .writer || self == .citation }

    var summary: String {
        switch self {
        case .writer: "Texte schreiben und überarbeiten"
        case .citation: "Quellen und Zitate sammeln"
        case .presenter: "Präsentationen entwerfen"
        case .notes: "Notizen sammeln und ordnen"
        }
    }
}
