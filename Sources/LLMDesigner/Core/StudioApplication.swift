import Foundation

/// Applications next to the chat where the model helps with a piece of work. Only the menu exists so far;
/// Writer Studio comes first. Coding Studio follows later.
enum StudioApplication: String, CaseIterable, Identifiable {
    case writer, citation, presenter, stories, notes, projects, podcast, data, research, learning, git

    var id: String { rawValue }

    var title: String {
        switch self {
        case .writer: "Writer Studio"
        case .citation: "Citation Studio"
        case .presenter: "Presenter Studio"
        case .stories: "Stories Studio"
        case .notes: "Notes"
        case .projects: "Projekte"
        case .podcast: "PodcastStudio"
        case .data: "Data Studio"
        case .research: "Rechercherista"
        case .learning: "Learning Studio"
        case .git: "Git Studio"
        }
    }

    var symbol: String {
        switch self {
        case .writer: "doc.richtext"
        case .citation: "quote.bubble"
        case .presenter: "play.rectangle"
        case .stories: "books.vertical"
        case .notes: "note.text"
        case .projects: Project.sidebarSymbol
        case .podcast: "waveform.and.mic"
        case .data: "tablecells"
        case .research: "binoculars"
        case .learning: "leaf"
        case .git: "arrow.triangle.branch"
        }
    }

    /// What the entry in the "Neu" menu does: Writer and Presenter start a new document, the others open.
    var menuTitle: String {
        switch self {
        case .writer: "Writer Studio – neues Dokument"
        case .presenter: "Presenter Studio – neue Präsentation"
        case .notes: "Notes – ToDos und Fortschritt"
        case .projects: "Projekt – neue Projektseite"
        case .podcast: "PodcastStudio – neuer Podcast"
        case .data: "Data Studio – Datenblöcke und Vorlagen"
        case .research: "Rechercherista – neue Recherche"
        case .learning: "Learning Studio – Lernbäume und Karteikarten"
        case .git: "Git Studio – Versionen und Branches"
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
        case .projects: "Vorhaben planen, verknüpfen und verfolgen"
        case .podcast: "Gespräche recherchieren, schreiben und vertonen"
        case .data: "Datenblöcke für Platzhalter, Vorlagen und Masterfolien"
        case .research: "Gründlich recherchieren, Schritt für Schritt bis zum Bericht"
        case .learning: "Disziplinen, Kurse, Karteikarten und Lernfortschritt"
        case .git: "Commits, Branches und der Baum der Versionen"
        }
    }
}
