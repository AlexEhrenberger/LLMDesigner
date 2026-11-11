import SwiftUI

/// The Notes studio in small: ALL notes of the library, whatever they belong to. The bolt in the head and the banner
/// "Alle Notes" set it apart from the notes of the open document, which its own panel shows with a pin. Text dropped
/// here becomes a note (every line a to-do); a note drags out as a Markdown task list.
struct PowerNotes: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        let query = app.power.query
        if let id = app.power.noteID, app.notes.note(id) != nil, query.isEmpty {
            PowerNoteView(noteID: id)
        } else {
            PowerNoteList(query: query)
        }
    }
}

private struct PowerNoteList: View {
    @Environment(AppModel.self) private var app
    let query: String

    var body: some View {
        let notes = app.notes.notes.filter { $0.matches(query) }
        let open = app.selectedDocument
        let ofOpen = open.map { document in notes.filter { $0.belongs(to: .document(document.id)) } } ?? []
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 8) {
                    Image(systemName: "bolt.fill")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Theme.accent)
                    VStack(alignment: .leading, spacing: 1) {
                        Text("Alle Notes")
                            .font(.system(size: 12.5, weight: .semibold))
                            .foregroundStyle(Theme.textPrimary)
                        Text("Jedes Note der Bibliothek – allgemein oder zu einem Dokument, einer Präsentation, einer Romanwelt.")
                            .font(.system(size: 11))
                            .foregroundStyle(Theme.textTertiary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 0)
                }
                .padding(10)
                .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(Theme.ink.opacity(0.035)))
                .padding(.bottom, 8)

                if let open, !ofOpen.isEmpty {
                    section(title: open.isPresentation ? "Zu dieser Präsentation" : "Zu diesem Dokument", symbol: "pin.fill", count: ofOpen.count)
                    ForEach(ofOpen) { note in row(note) }
                }
                ForEach(NoteGroup.allCases, id: \.self) { group in
                    let members = notes.filter { NoteGroup.of($0) == group && !ofOpen.contains($0) }
                    if !members.isEmpty {
                        section(title: group.title, symbol: group.symbol, count: members.count)
                        ForEach(members) { note in row(note) }
                    }
                }
                if notes.isEmpty {
                    PowerEmpty(text: query.isEmpty ? "Noch keine Notes. Text hierher ziehen oder ein Note anlegen." : "Kein Note passt zur Suche.")
                }
                HStack(spacing: 6) {
                    Button {
                        let note = app.newNote()
                        app.power.noteID = note.id
                    } label: {
                        Label("Neues Note", systemImage: "plus")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(Theme.accent)
                            .frame(height: 34)
                            .padding(.horizontal, 10)
                    }
                    .buttonStyle(.plain)
                    PowerDropZone(title: "Text hierher ziehen: neues Note", symbol: "checklist") { dropped in
                        app.powerAddNote(fromText: dropped.markdown)
                    }
                }
                .padding(.top, 10)
            }
            .padding(.horizontal, 10)
            .padding(.bottom, 12)
        }
    }

    private func section(title: String, symbol: String, count: Int) -> some View {
        HStack(spacing: 6) {
            Image(systemName: symbol)
                .font(.system(size: 9.5, weight: .semibold))
            Text(title.uppercased())
                .font(.system(size: 10.5, weight: .semibold))
                .tracking(0.4)
            Spacer(minLength: 0)
            Text("\(count)")
                .font(.system(size: 10.5, weight: .medium).monospacedDigit())
        }
        .foregroundStyle(Theme.textTertiary)
        .padding(.horizontal, 8)
        .padding(.top, 10)
        .padding(.bottom, 3)
    }

    private func row(_ note: Note) -> some View {
        HStack(spacing: 0) {
            NoteListRow(note: note) { app.power.noteID = note.id }
            Image(systemName: "line.3.horizontal")
                .font(.system(size: 11))
                .foregroundStyle(Theme.textTertiary)
                .frame(width: 22, height: 30)
                .contentShape(Rectangle())
                .powerDrag(markdown: note.markdown, plain: note.markdown)
                .help("Ziehen: das Note als Aufgabenliste in ein Dokument oder den Chat")
        }
    }
}

private struct PowerNoteView: View {
    @Environment(AppModel.self) private var app
    let noteID: UUID
    @State private var targeted = false

    var body: some View {
        let note = app.notes.note(noteID)
        VStack(spacing: 0) {
            PowerItemBar(title: note?.displayTitle ?? "", symbol: StudioApplication.notes.symbol, openHelp: "Im Notes-Studio öffnen") {
                app.power.closeItem()
            } onOpen: {
                app.openNotesStudio(showing: noteID)
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    NoteEditor(noteID: noteID, compact: true, showsOwners: true)
                    HStack(spacing: 6) {
                        Image(systemName: "hand.draw")
                            .font(.system(size: 11))
                        Text("Ziehen: das Note als Aufgabenliste in ein Dokument oder den Chat")
                            .font(.system(size: 11))
                    }
                    .foregroundStyle(Theme.textTertiary)
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Theme.border, style: StrokeStyle(lineWidth: 1, dash: [4, 3])))
                    .powerDrag(markdown: note?.markdown ?? "", plain: note?.markdown ?? "")
                }
                .padding(.horizontal, 12)
                .padding(.bottom, 14)
            }
            .background(RoundedRectangle(cornerRadius: 8).fill(targeted ? Theme.accent.opacity(0.08) : .clear))
            .onDrop(of: PowerDrag.accepted, isTargeted: $targeted) { providers in
                PowerDrag.load(providers) { dropped in app.powerAppendTodos(dropped.markdown, to: noteID) }
            }
        }
    }
}

extension AppModel {
    /// A note from dropped text: a heading becomes its title, every other line a to-do. Undone from the panel.
    @discardableResult
    func powerAddNote(fromText text: String) -> UUID? {
        let todos = Note.todos(fromText: text)
        let heading = text.components(separatedBy: .newlines).first { $0.hasPrefix("#") }?
            .drop { $0 == "#" }.trimmingCharacters(in: .whitespaces)
        guard !todos.isEmpty || heading != nil else { return nil }
        let note = newNote(title: heading ?? "", todos: todos)
        power.noteID = note.id
        power.lastChange = PowerAccess.Change(label: "Note angelegt") { [weak self] in
            self?.notes.deleteNote(note.id)
            if self?.power.noteID == note.id { self?.power.noteID = nil }
        }
        return note.id
    }

    /// Dropped lines go to the end of a note as to-dos.
    func powerAppendTodos(_ text: String, to noteID: UUID) {
        let todos = Note.todos(fromText: text)
        guard !todos.isEmpty, let before = notes.note(noteID) else { return }
        notes.update(noteID) { note in note.todos += todos }
        power.lastChange = PowerAccess.Change(label: todos.count == 1 ? "1 ToDo angefügt" : "\(todos.count) ToDos angefügt") { [weak self] in
            self?.notes.update(noteID) { $0.todos = before.todos }
        }
    }
}
