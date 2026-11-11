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

    /// What the entry in the "Neu" menu does: Writer and Presenter start a new document, the others open.
    var menuTitle: String {
        switch self {
        case .writer: "Writer Studio – neues Dokument"
        case .presenter: "Presenter Studio – neue Präsentation"
        case .notes: "Notes – ToDos und Fortschritt"
        default: title
        }
    }

    /// Every application is built; the menus keep the check for the next one that is announced before it exists.
    var isAvailable: Bool { true }

    var summary: String {
        switch self {
        case .writer: "Texte schreiben und überarbeiten"
        case .citation: "Quellen und Zitate sammeln"
        case .presenter: "Präsentationen entwerfen"
        case .stories: "Romane strukturieren und entwerfen"
        case .notes: "ToDos abhaken und Fortschritt sehen"
        }
    }
}
