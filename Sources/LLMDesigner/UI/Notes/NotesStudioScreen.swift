import SwiftUI

/// What the Notes studio shows.
@MainActor
@Observable
final class NotesStudioModel {
    var selectedID: UUID?
    var query = ""
    var focusTodo: UUID?
}

/// The groups of the list: notes of their own first, then those that belong to documents or novel worlds.
enum NoteGroup: CaseIterable {
    case general, documents, stories

    var title: String {
        switch self {
        case .general: "Allgemein"
        case .documents: "Zu Dokumenten"
        case .stories: "Zu Romanwelten"
        }
    }

    var symbol: String {
        switch self {
        case .general: "tray"
        case .documents: StudioApplication.writer.symbol
        case .stories: StudioApplication.stories.symbol
        }
    }

    static func of(_ note: Note) -> NoteGroup {
        if note.owners.contains(where: { $0.documentID != nil }) { return .documents }
        if !note.owners.isEmpty { return .stories }
        return .general
    }
}

/// Notes: to-do lists with a picture of their progress. The list on the left has every note of the library; those
/// that belong to a document or a novel world say so, and appear in that document's panel as well.
struct NotesStudioScreen: View {
    @Environment(AppModel.self) private var app
    @State private var model = NotesStudioModel()

    var body: some View {
        let library = app.notes
        VStack(spacing: 0) {
            NotesTopBar(model: model)
            if library.notes.isEmpty {
                emptyState
            } else {
                HStack(spacing: 0) {
                    NotesList(model: model)
                        .frame(width: 270)
                    Rectangle().fill(Theme.border).frame(width: 1)
                    Group {
                        if let id = model.selectedID, library.note(id) != nil {
                            NotesPage(noteID: id, model: model)
                                .id(id)
                        } else {
                            Text("Wähle links ein Note.")
                                .font(.system(size: 13))
                                .foregroundStyle(Theme.textTertiary)
                                .frame(maxWidth: .infinity, maxHeight: .infinity)
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
        }
        .background(Theme.background)
        .onAppear {
            library.loadIfNeeded()
            let last = app.settings.string(forKey: AppModel.notesLastNoteKey).flatMap(UUID.init(uuidString:))
            model.selectedID = last.flatMap { library.note($0)?.id } ?? library.notes.first?.id
            take(app.notesStudioCommand)
        }
        .onChange(of: model.selectedID) { _, id in app.settings.set(id?.uuidString, forKey: AppModel.notesLastNoteKey) }
        .onChange(of: app.notesStudioCommand) { _, command in take(command) }
    }

    private func take(_ command: NotesStudioCommand?) {
        guard let command else { return }
        if let note = command.note { model.selectedID = note }
        model.focusTodo = command.focusTodo
        app.notesStudioCommand = nil
    }

    private var emptyState: some View {
        VStack(spacing: 14) {
            Image(systemName: "checklist")
                .font(.system(size: 36, weight: .light))
                .foregroundStyle(Theme.accent)
            Text("Noch kein Note")
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(Theme.textPrimary)
            Text("Ein Note ist eine ToDo-Liste mit Unter-ToDos und einer Anzeige, wie weit du bist – als Balken, Glas, Pflanze, Rakete …\nNotes können auch zu einem Dokument, einer Präsentation oder einem Kapitel deiner Romanwelt gehören.")
                .font(.system(size: 12.5))
                .foregroundStyle(Theme.textSecondary)
                .multilineTextAlignment(.center)
            Button {
                model.selectedID = app.newNote().id
            } label: {
                Label("Note anlegen", systemImage: "plus")
            }
            .buttonStyle(.borderedProminent)
            .padding(.top, 4)
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Top bar

private struct NotesTopBar: View {
    @Environment(AppModel.self) private var app
    let model: NotesStudioModel
    @State private var width: CGFloat = 1200

    var body: some View {
        let notes = app.notes.notes
        let open = notes.reduce(0) { $0 + $1.progress.open }
        HStack(spacing: 10) {
            if !app.isSidebarDocked {
                SidebarToggleButton()
                NewItemMenu()
                    .padding(.trailing, 4)
            }
            Image(systemName: StudioApplication.notes.symbol)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(Theme.accent)
            Text("Notes")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Theme.textPrimary)
                .lineLimit(1)
                .fixedSize()
            if width >= 700, !notes.isEmpty {
                Text("\(notes.count) \(notes.count == 1 ? "Note" : "Notes") · \(open) \(open == 1 ? "offenes ToDo" : "offene ToDos")")
                    .font(.system(size: 12).monospacedDigit())
                    .foregroundStyle(Theme.textTertiary)
                    .lineLimit(1)
                    .fixedSize()
            }
            Spacer(minLength: 16)
            if let id = model.selectedID, app.notes.note(id) != nil {
                ProjectMembershipButton(ref: .note(id), label: "dieses Note")
            }
            IconButton(systemName: "plus", help: "Neues Note", size: 13, frameSize: Theme.titleBarControlSize) {
                model.query = ""
                model.selectedID = app.newNote().id
            }
            PowerButton()
            IconButton(systemName: "xmark", help: "Notes schließen und zurück zum Chat", size: 12.5, frameSize: Theme.titleBarControlSize) {
                withAnimation(.easeInOut(duration: 0.25)) { app.closeNotesStudio() }
            }
        }
        .padding(.leading, app.isSidebarDocked ? 16 : Theme.trafficLightInset)
        .padding(.trailing, 12)
        .frame(height: Theme.titleBarHeight)
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
        .padding(.bottom, Theme.topBarBottomPadding + 4)
        .background(WindowDragArea())
    }
}

// MARK: - List

private struct NotesList: View {
    @Environment(AppModel.self) private var app
    @Environment(\.undoManager) private var undoManager
    @Bindable var model: NotesStudioModel

    var body: some View {
        let shown = app.notes.notes.filter { $0.matches(model.query) }
        VStack(spacing: 0) {
            SearchField(text: $model.query, prompt: "Notes und ToDos durchsuchen")
                .padding(.horizontal, 10)
                .padding(.bottom, 8)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 1) {
                    ForEach(NoteGroup.allCases, id: \.self) { group in
                        let notes = shown.filter { NoteGroup.of($0) == group }
                        if !notes.isEmpty {
                            HStack(spacing: 6) {
                                Image(systemName: group.symbol)
                                    .font(.system(size: 10, weight: .semibold))
                                Text(group.title.uppercased())
                                    .font(.system(size: 10.5, weight: .semibold))
                                    .tracking(0.4)
                                Spacer(minLength: 0)
                                Text("\(notes.count)")
                                    .font(.system(size: 10.5, weight: .medium).monospacedDigit())
                            }
                            .foregroundStyle(Theme.textTertiary)
                            .padding(.horizontal, 10)
                            .padding(.top, group == .general ? 2 : 12)
                            .padding(.bottom, 4)
                            ForEach(notes) { note in
                                NoteListRow(note: note, isSelected: model.selectedID == note.id) {
                                    model.selectedID = note.id
                                }
                                .contextMenu {
                                    Button("Note löschen", systemImage: "trash", role: .destructive) {
                                        if model.selectedID == note.id { model.selectedID = nil }
                                        app.notes.delete(note.id, undo: undoManager)
                                        if model.selectedID == nil { model.selectedID = app.notes.notes.first?.id }
                                    }
                                }
                            }
                        }
                    }
                    if shown.isEmpty {
                        Text("Kein Note passt zur Suche.")
                            .font(.system(size: 12))
                            .foregroundStyle(Theme.textTertiary)
                            .padding(12)
                    }
                }
                .padding(.horizontal, 8)
                .padding(.bottom, 14)
            }
        }
        .background(Theme.sidebar.opacity(0.5))
    }
}

/// One note in a list: its ring, its title, how far it is and to what it belongs.
struct NoteListRow: View {
    @Environment(AppModel.self) private var app
    let note: Note
    var isSelected = false
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                NoteMiniRing(progress: note.progress, size: 20)
                VStack(alignment: .leading, spacing: 2) {
                    Text(note.displayTitle)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(note.title.isEmpty ? Theme.textTertiary : Theme.textPrimary)
                        .lineLimit(1)
                    HStack(spacing: 4) {
                        if let owner = note.owners.first {
                            Image(systemName: app.noteOwnerSymbol(owner))
                                .font(.system(size: 9.5))
                        }
                        Text(app.noteSubtitle(note))
                            .lineLimit(1)
                    }
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.textTertiary)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 9)
            .padding(.vertical, 7)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(isSelected ? Theme.selection : (hovering ? Theme.hover : .clear)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

// MARK: - Page

private struct NotesPage: View {
    @Environment(AppModel.self) private var app
    @Environment(\.undoManager) private var undoManager
    let noteID: UUID
    let model: NotesStudioModel
    @State private var confirmsDelete = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                NoteEditor(noteID: noteID, showsOwners: true, focusTodo: model.focusTodo)
                if let note = app.notes.note(noteID) {
                    HStack(spacing: 10) {
                        Text("Angelegt \(note.createdAt.formatted(date: .abbreviated, time: .shortened)) · geändert \(note.updatedAt.formatted(date: .abbreviated, time: .shortened))")
                            .font(.system(size: 11))
                            .foregroundStyle(Theme.textTertiary)
                        Spacer(minLength: 0)
                        Button(role: .destructive) {
                            confirmsDelete = true
                        } label: {
                            Label("Note löschen", systemImage: "trash")
                                .font(.system(size: 11.5))
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(Theme.textTertiary)
                    }
                    .padding(.top, 26)
                }
            }
            .padding(.horizontal, 36)
            .padding(.vertical, 26)
            .frame(maxWidth: 780, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .onAppear { DispatchQueue.main.async { model.focusTodo = nil } }
        .confirmationDialog("„\(app.notes.note(noteID)?.displayTitle ?? "")“ löschen?", isPresented: $confirmsDelete) {
            Button("Note löschen", role: .destructive) {
                app.notes.delete(noteID, undo: undoManager)
                model.selectedID = app.notes.notes.first?.id
            }
        } message: {
            Text("Das Note kommt in den Papierkorb; ⌘Z holt es zurück. Dokumente, zu denen es gehört, bleiben, wie sie sind.")
        }
    }
}
