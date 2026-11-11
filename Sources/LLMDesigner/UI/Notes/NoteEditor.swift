import SwiftUI
import AppKit

/// Which line of a note editor takes the keyboard next.
@MainActor
@Observable
final class NoteEditorState {
    var focus: UUID?
    var caretAtEnd = true
    var focusTitle = false

    func focus(_ id: UUID?, atEnd: Bool = true) {
        caretAtEnd = atEnd
        focus = id
    }
}

/// A note in full: title and progress at the top, the to-dos, the free text. The same view stands in the Notes studio,
/// in the panel of a document, in Stories Studio and in the power access; `compact` makes it fit a panel.
struct NoteEditor: View {
    @Environment(AppModel.self) private var app
    @Environment(\.undoManager) private var undoManager
    let noteID: UUID
    var compact = false
    /// Shows to whom the note belongs, with a way to link it to more (the studio; panels say it in their head).
    var showsOwners = false
    var focusTodo: UUID?
    @State private var state = NoteEditorState()

    var body: some View {
        let library = app.notes
        if let note = library.note(noteID) {
            VStack(alignment: .leading, spacing: compact ? 12 : 18) {
                NoteHeader(note: note, compact: compact, showsOwners: showsOwners, state: state)
                NoteTodoList(note: note, compact: compact, state: state)
                VStack(alignment: .leading, spacing: 6) {
                    StoryLabel(title: "Notizen", hint: "Gedanken, Links und Stichpunkte zu diesem Note. Sie zählen nicht zum Fortschritt.", symbol: "text.alignleft", color: Theme.accent)
                    StoryTextEditor(placeholder: "Gedanken, offene Fragen, Links …", text: library.textBinding(noteID), minLines: compact ? 2 : 3,
                                    font: .systemFont(ofSize: compact ? 12.5 : 13))
                        .storyField()
                }
            }
            .onAppear {
                if let focusTodo { state.focus(focusTodo) }
                // A new note starts in its title, a new list in its first line.
                else if note.title.isEmpty, note.todos.isEmpty, !compact { state.focusTitle = true }
            }
        }
    }
}

// MARK: - Head

private struct NoteHeader: View {
    @Environment(AppModel.self) private var app
    @Environment(\.undoManager) private var undoManager
    let note: Note
    let compact: Bool
    let showsOwners: Bool
    let state: NoteEditorState
    @State private var pickingStyle = false
    /// The picture opens the picker too, in a popover of its own: two popovers on one switch fight over it.
    @State private var pickingStyleFromArt = false
    @State private var celebration: Date?

    var body: some View {
        let progress = note.progress
        VStack(alignment: .leading, spacing: compact ? 8 : 10) {
            HStack(alignment: .top, spacing: 14) {
                VStack(alignment: .leading, spacing: compact ? 5 : 8) {
                    NoteLineEditor(placeholder: "Titel des Notes", text: app.notes.titleBinding(note.id),
                                   font: .systemFont(ofSize: compact ? 17 : 26, weight: .semibold),
                                   wantsFocus: state.focusTitle, onFocused: { state.focusTitle = false },
                                   actions: NoteLineActions(onReturn: { _, _ in focusFirstTodo() }, onDown: { focusFirstTodo() }))
                    HStack(spacing: 8) {
                        Text(progress.label)
                            .font(.system(size: compact ? 11.5 : 12.5, weight: .medium).monospacedDigit())
                            .foregroundStyle(progress.isComplete ? Theme.success : Theme.textSecondary)
                            .contentTransition(.numericText())
                        styleButton
                    }
                    if showsOwners { NoteOwnerChips(note: note) }
                }
                Spacer(minLength: 0)
                if !note.style.isWide { art(progress) }
            }
            if note.style.isWide { art(progress) }
        }
        .onChange(of: progress.isComplete) { was, now in
            guard now, !was else { return }
            celebration = Date()
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(NoteConfetti.duration + 0.1))
                celebration = nil
            }
        }
    }

    private func art(_ progress: NoteProgress) -> some View {
        NoteProgressArt(style: note.style, progress: progress, groups: note.groups.map(\.progress.fraction), compact: compact)
            .overlay {
                if let celebration {
                    NoteConfetti(start: celebration)
                        .frame(width: 260, height: 200)
                }
            }
            .contentShape(Rectangle())
            .onTapGesture { pickingStyleFromArt = true }
            .help("\(note.style.title): \(progress.percent) % – klicken, um die Anzeige zu wechseln")
            .popover(isPresented: $pickingStyleFromArt, arrowEdge: .bottom) { picker }
    }

    private var styleButton: some View {
        Button {
            pickingStyle = true
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "paintpalette")
                    .font(.system(size: 10, weight: .semibold))
                Text(note.style.title)
                    .font(.system(size: 11, weight: .medium))
                Image(systemName: "chevron.down")
                    .font(.system(size: 7, weight: .bold))
            }
            .foregroundStyle(Theme.textSecondary)
            .padding(.horizontal, 8)
            .frame(height: 21)
            .background(Capsule().fill(Theme.ink.opacity(0.05)))
            .overlay(Capsule().strokeBorder(Theme.border))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .help("Fortschrittsanzeige wählen: Balken, Ringe, Glas, Pflanze, Rakete …")
        .popover(isPresented: $pickingStyle, arrowEdge: .bottom) { picker }
    }

    private var picker: some View {
        NoteStylePicker(selection: note.style) { style in
            app.notes.change(note.id, "Anzeige wechseln", undo: undoManager) { $0.style = style }
            app.defaultNoteStyle = style
        }
    }

    private func focusFirstTodo() {
        if let first = note.todos.first {
            state.focus(first.id)
        } else {
            var made: UUID?
            app.notes.change(note.id, "ToDo anlegen", undo: undoManager) { made = $0.addTodo() }
            state.focus(made)
        }
    }
}

/// "Gehört zu": the documents and parts a note belongs to; a click opens one, the cross lets go of it.
struct NoteOwnerChips: View {
    @Environment(AppModel.self) private var app
    @Environment(\.undoManager) private var undoManager
    let note: Note
    @State private var picking = false

    var body: some View {
        FlowLayout(spacing: 6, lineSpacing: 6) {
            Label(note.owners.isEmpty ? "Allgemeines Note" : "Gehört zu", systemImage: note.owners.isEmpty ? "tray" : "pin.fill")
                .font(.system(size: 11.5, weight: .medium))
                .foregroundStyle(Theme.textTertiary)
                .frame(height: 24)
            ForEach(note.owners, id: \.self) { owner in
                NoteChip(title: app.noteOwnerTitle(owner) ?? "\(app.noteOwnerKind(owner)) gelöscht", symbol: app.noteOwnerSymbol(owner),
                         tint: Theme.accent, isMissing: app.noteOwnerTitle(owner) == nil,
                         openHelp: "\(app.noteOwnerKind(owner)) öffnen", removeHelp: "Zuordnung lösen; das Note bleibt") {
                    app.openNoteOwner(owner)
                } onRemove: {
                    app.detachNote(note.id, from: owner, undo: undoManager)
                }
            }
            Button {
                picking = true
            } label: {
                Label("Dokument zuordnen", systemImage: "plus")
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(Theme.accent)
                    .frame(height: 24)
            }
            .buttonStyle(.plain)
            .help("Das Note einem Writer-Dokument oder einer Präsentation zuordnen. Romanwelten und ihre Teile verknüpfst du im Stories Studio.")
            .popover(isPresented: $picking, arrowEdge: .bottom) {
                NoteDocumentPicker(excluded: Set(note.owners.compactMap(\.documentID)), createTitle: nil) { id in
                    app.attachNote(note.id, to: .document(id), undo: undoManager)
                }
                .environment(app)
            }
        }
    }
}

// MARK: - List

private struct NoteTodoList: View {
    @Environment(AppModel.self) private var app
    @Environment(\.undoManager) private var undoManager
    let note: Note
    let compact: Bool
    let state: NoteEditorState

    var body: some View {
        let rows = note.rows()
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                StoryLabel(title: "ToDos", hint: "Return: nächstes ToDo · Tab: einrücken (Unter-ToDo) · ⇧Tab: ausrücken · ⌫ in leerer Zeile: löschen. Mehrere Zeilen einfügen legt mehrere ToDos an.",
                           symbol: "checklist", color: Theme.accent)
                Spacer(minLength: 0)
                listMenu
            }
            .padding(.bottom, 4)
            ForEach(rows) { row in
                NoteTodoRow(note: note, row: row, compact: compact, state: state, actions: actions(for: row, in: rows))
            }
            Button {
                add()
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "plus.circle.fill")
                        .font(.system(size: compact ? 15 : 16))
                        .foregroundStyle(Theme.accent)
                    Text(note.todos.isEmpty ? "Erstes ToDo anlegen" : "ToDo hinzufügen")
                        .font(.system(size: compact ? 12.5 : 13, weight: .medium))
                        .foregroundStyle(Theme.textSecondary)
                }
                .padding(.vertical, 6)
                .padding(.leading, 20)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .padding(.top, 2)
        }
    }

    private var listMenu: some View {
        IconMenu(systemName: "ellipsis.circle", help: "Weitere Befehle für die Liste", size: 13, frameSize: 24) {
            Button("Alle aufklappen", systemImage: "chevron.down") { setCollapsed(false) }
            Button("Alle zuklappen", systemImage: "chevron.right") { setCollapsed(true) }
            Divider()
            Button("Als Markdown kopieren", systemImage: "doc.on.doc") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(note.markdown, forType: .string)
            }
            Divider()
            Button("Erledigte entfernen", systemImage: "checkmark.circle.badge.xmark", role: .destructive) {
                app.notes.change(note.id, "Erledigte entfernen", undo: undoManager) { $0.removeDone() }
            }
            .disabled(note.progress.done == 0)
        }
    }

    private func setCollapsed(_ collapsed: Bool) {
        app.notes.change(note.id, collapsed ? "Alle zuklappen" : "Alle aufklappen", undo: undoManager) { note in
            for todo in note.allTodos where !todo.children.isEmpty { note.updateTodo(todo.id) { $0.isCollapsed = collapsed } }
        }
    }

    private func add() {
        var made: UUID?
        app.notes.change(note.id, "ToDo anlegen", undo: undoManager) { made = $0.addTodo() }
        state.focus(made)
    }

    /// The keys of one line, worked out on the note as it is when the key is pressed.
    private func actions(for row: NoteRow, in rows: [NoteRow]) -> NoteLineActions {
        let library = app.notes
        let noteID = note.id
        let id = row.id
        let undo = undoManager
        let state = state
        func neighbour(_ offset: Int) -> UUID? {
            let current = library.note(noteID)?.rows() ?? []
            guard let index = current.firstIndex(where: { $0.id == id }) else { return nil }
            let target = index + offset
            return current.indices.contains(target) ? current[target].id : nil
        }
        return NoteLineActions(
            onReturn: { before, after in
                guard let current = library.note(noteID)?.todo(id) else { return }
                let isEmpty = before.trimmingCharacters(in: .whitespaces).isEmpty && after.isEmpty
                // An empty to-do under another one moves out, as in an outliner; at the top it ends the list.
                if isEmpty {
                    if library.note(noteID)?.location(of: id)?.parent != nil {
                        library.change(noteID, "Ausrücken", undo: undo) { $0.outdent(id) }
                        state.focus(id)
                    } else {
                        NSApp.keyWindow?.makeFirstResponder(nil)
                    }
                    return
                }
                var made: UUID?
                library.change(noteID, "ToDo anlegen", undo: undo) { note in
                    note.updateTodo(id) { $0.text = before }
                    // An open to-do with to-dos of its own gets the new one as its first.
                    if !current.children.isEmpty, !current.isCollapsed {
                        var todo = NoteTodo(text: after)
                        todo.isDone = false
                        if note.insert(todo, parent: id, at: 0) { made = todo.id }
                    } else {
                        made = note.addTodo(after, after: id)
                    }
                }
                state.focus(made, atEnd: false)
            },
            onTab: {
                library.change(noteID, "Einrücken", undo: undo) { $0.indent(id) }
                state.focus(id)
            },
            onBacktab: {
                library.change(noteID, "Ausrücken", undo: undo) { $0.outdent(id) }
                state.focus(id)
            },
            onDeleteEmpty: {
                guard library.note(noteID)?.todo(id)?.children.isEmpty == true else { return }
                let previous = neighbour(-1) ?? neighbour(1)
                library.change(noteID, "ToDo löschen", undo: undo) { $0.removeTodo(id) }
                state.focus(previous)
            },
            onUp: { if let previous = neighbour(-1) { state.focus(previous) } },
            onDown: { if let next = neighbour(1) { state.focus(next) } },
            onPasteLines: { lines in
                let todos = Note.todos(fromText: lines.joined(separator: "\n"))
                guard !todos.isEmpty else { return }
                library.change(noteID, "ToDos einfügen", undo: undo) { note in
                    guard let place = note.location(of: id) else { return }
                    for (offset, todo) in todos.enumerated() { note.insert(todo, parent: place.parent, at: place.index + 1 + offset) }
                }
                state.focus(todos.last?.id)
            }
        )
    }
}

// MARK: - Row

private struct NoteTodoRow: View {
    @Environment(AppModel.self) private var app
    @Environment(\.undoManager) private var undoManager
    let note: Note
    let row: NoteRow
    let compact: Bool
    let state: NoteEditorState
    let actions: NoteLineActions
    @State private var hovering = false
    @State private var linking = false

    var body: some View {
        let todo = row.todo
        let hasChildren = !todo.children.isEmpty
        let indent = CGFloat(row.depth) * (compact ? 18 : 24)
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .top, spacing: 6) {
                Group {
                    if hasChildren {
                        Button {
                            app.notes.change(note.id, todo.isCollapsed ? "Aufklappen" : "Zuklappen", undo: undoManager) { $0.updateTodo(todo.id) { $0.isCollapsed.toggle() } }
                        } label: {
                            Image(systemName: "chevron.right")
                                .font(.system(size: 9, weight: .bold))
                                .foregroundStyle(Theme.textTertiary)
                                .rotationEffect(.degrees(todo.isCollapsed ? 0 : 90))
                                .frame(width: 14, height: 20)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .help(todo.isCollapsed ? "Unter-ToDos aufklappen" : "Unter-ToDos zuklappen")
                    } else {
                        Color.clear.frame(width: 14, height: 20)
                    }
                }
                NoteCheckButton(isDone: todo.isDone, partial: hasChildren ? todo.progress.fraction : nil, size: compact ? 17 : 19) {
                    withAnimation(.spring(response: 0.35, dampingFraction: 0.7)) {
                        app.notes.change(note.id, todo.isDone ? "ToDo öffnen" : "ToDo abhaken", undo: undoManager) { $0.setDone(todo.id, !todo.isDone) }
                    }
                }
                .padding(.top, compact ? 0 : 0.5)
                NoteLineEditor(placeholder: "ToDo", text: app.notes.todoBinding(note.id, todo.id), font: .systemFont(ofSize: compact ? 13 : 14, weight: row.depth == 0 && hasChildren ? .semibold : .regular),
                               isDone: todo.isDone, wantsFocus: state.focus == todo.id, caretAtEnd: state.caretAtEnd,
                               onFocused: { if state.focus == todo.id { state.focus = nil } }, actions: actions)
                    .padding(.top, 1.5)
                if hasChildren {
                    Text("\(todo.progress.done)/\(todo.progress.total)")
                        .font(.system(size: 10.5, weight: .semibold).monospacedDigit())
                        .foregroundStyle(todo.progress.isComplete ? Theme.success : Theme.textTertiary)
                        .padding(.horizontal, 6)
                        .frame(height: 18)
                        .background(Capsule().fill(Theme.ink.opacity(0.05)))
                        .padding(.top, 1.5)
                }
                rowButtons(todo)
            }
            if !todo.documents.isEmpty {
                FlowLayout(spacing: 5, lineSpacing: 5) {
                    ForEach(todo.documents, id: \.self) { id in
                        let document = app.document(id)
                        NoteChip(title: document?.displayTitle ?? "Dokument gelöscht",
                                 symbol: document?.isPresentation == true ? StudioApplication.presenter.symbol : StudioApplication.writer.symbol,
                                 tint: Theme.accent, isMissing: document == nil, small: true,
                                 openHelp: document?.isPresentation == true ? "Präsentation öffnen" : "Dokument öffnen", removeHelp: "Verknüpfung lösen; das Dokument bleibt") {
                            if document != nil { app.selectDocument(id) }
                        } onRemove: {
                            app.unlinkDocument(id, fromTodo: todo.id, in: note.id, undo: undoManager)
                        }
                    }
                }
                .padding(.leading, 14 + 6 + (compact ? 17 : 19) + 6)
            }
        }
        .padding(.leading, indent)
        .padding(.vertical, compact ? 3 : 4)
        .padding(.horizontal, 4)
        .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(hovering ? Theme.hover : .clear))
        .onHover { hovering = $0 }
        .contextMenu { menuItems(todo) }
        .popover(isPresented: $linking, arrowEdge: .bottom) {
            NoteDocumentPicker(excluded: Set(todo.documents), createTitle: todo.text) { id in
                app.linkDocument(id, toTodo: todo.id, in: note.id, undo: undoManager)
            } onCreate: { presentation in
                app.newDocument(forTodo: todo.id, in: note.id, presentation: presentation, undo: undoManager)
            }
            .environment(app)
        }
    }

    @ViewBuilder
    private func rowButtons(_ todo: NoteTodo) -> some View {
        HStack(spacing: 0) {
            if !compact {
                IconButton(systemName: "link", help: "Mit einem Dokument oder einer Präsentation verknüpfen", size: 11.5, frameSize: 22) { linking = true }
                IconButton(systemName: "plus", help: "Unter-ToDo anlegen", size: 11.5, frameSize: 22) { addChild(todo) }
                IconButton(systemName: "trash", help: "ToDo löschen (⌘Z holt es zurück)", size: 11, frameSize: 22) { delete(todo) }
            } else {
                IconMenu(systemName: "ellipsis", help: "ToDo bearbeiten", size: 11.5, frameSize: 22) { menuItems(todo) }
            }
        }
        .opacity(hovering ? 1 : 0)
        .animation(.easeOut(duration: 0.12), value: hovering)
    }

    @ViewBuilder
    private func menuItems(_ todo: NoteTodo) -> some View {
        Button(todo.isDone ? "Wieder öffnen" : "Abhaken", systemImage: todo.isDone ? "circle" : "checkmark.circle") {
            app.notes.change(note.id, "ToDo abhaken", undo: undoManager) { $0.setDone(todo.id, !todo.isDone) }
        }
        Button("Unter-ToDo anlegen", systemImage: "arrow.turn.down.right") { addChild(todo) }
        Button("Dokument verknüpfen …", systemImage: "link") { linking = true }
        Divider()
        Button("Einrücken (Tab)", systemImage: "increase.indent") {
            app.notes.change(note.id, "Einrücken", undo: undoManager) { $0.indent(todo.id) }
        }
        .disabled(note.location(of: todo.id)?.index ?? 0 == 0)
        Button("Ausrücken (⇧Tab)", systemImage: "decrease.indent") {
            app.notes.change(note.id, "Ausrücken", undo: undoManager) { $0.outdent(todo.id) }
        }
        .disabled(note.location(of: todo.id)?.parent == nil)
        Button("Nach oben", systemImage: "arrow.up") {
            app.notes.change(note.id, "Nach oben", undo: undoManager) { $0.move(todo.id, by: -1) }
        }
        Button("Nach unten", systemImage: "arrow.down") {
            app.notes.change(note.id, "Nach unten", undo: undoManager) { $0.move(todo.id, by: 1) }
        }
        Divider()
        Button(todo.children.isEmpty ? "ToDo löschen" : "ToDo mit Unter-ToDos löschen", systemImage: "trash", role: .destructive) { delete(todo) }
    }

    private func addChild(_ todo: NoteTodo) {
        var made: UUID?
        app.notes.change(note.id, "Unter-ToDo anlegen", undo: undoManager) { made = $0.addTodo(parent: todo.id) }
        state.focus(made)
    }

    private func delete(_ todo: NoteTodo) {
        withAnimation(.easeOut(duration: 0.18)) {
            app.notes.change(note.id, "ToDo löschen", undo: undoManager) { $0.removeTodo(todo.id) }
        }
    }
}

/// The circle to tick off. A to-do with to-dos of its own shows how far they are as a thin arc inside.
struct NoteCheckButton: View {
    let isDone: Bool
    var partial: Double?
    var size: CGFloat = 19
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            ZStack {
                Circle()
                    .strokeBorder(isDone ? Theme.success : (hovering ? Theme.accent : Theme.textTertiary), lineWidth: 1.6)
                if isDone {
                    Circle().fill(Theme.success)
                    Image(systemName: "checkmark")
                        .font(.system(size: size * 0.5, weight: .heavy))
                        .foregroundStyle(.white)
                        .symbolEffect(.bounce, value: isDone)
                        .transition(.scale.combined(with: .opacity))
                } else if let partial, partial > 0 {
                    Circle()
                        .trim(from: 0, to: partial)
                        .stroke(Theme.accent, style: StrokeStyle(lineWidth: 2, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                        .padding(4)
                } else if hovering {
                    Image(systemName: "checkmark")
                        .font(.system(size: size * 0.46, weight: .bold))
                        .foregroundStyle(Theme.accent.opacity(0.55))
                }
            }
            .frame(width: size, height: size)
            .scaleEffect(isDone ? 1 : (hovering ? 1.06 : 1))
            .animation(.spring(response: 0.3, dampingFraction: 0.6), value: isDone)
            .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(isDone ? "Wieder öffnen" : (partial != nil ? "Mit allen Unter-ToDos abhaken" : "Als erledigt abhaken"))
    }
}

/// A linked document, an owner: a capsule that opens it, with a cross to let go of it.
struct NoteChip: View {
    let title: String
    let symbol: String
    var tint: Color = Theme.accent
    var isMissing = false
    var small = false
    var openHelp = ""
    var removeHelp = ""
    let onOpen: () -> Void
    let onRemove: () -> Void
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 5) {
            Button(action: onOpen) {
                HStack(spacing: 5) {
                    Image(systemName: isMissing ? "exclamationmark.triangle" : symbol)
                        .font(.system(size: small ? 10 : 11))
                        .foregroundStyle(isMissing ? Theme.warning : tint)
                    Text(title)
                        .font(.system(size: small ? 11.5 : 12))
                        .foregroundStyle(isMissing ? Theme.textTertiary : Theme.textPrimary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            .buttonStyle(.plain)
            .disabled(isMissing)
            .help(isMissing ? "Gibt es nicht mehr" : openHelp)
            Button(action: onRemove) {
                Image(systemName: "xmark")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(Theme.textTertiary)
            }
            .buttonStyle(.plain)
            .opacity(hovering ? 1 : 0.35)
            .help(removeHelp)
        }
        .padding(.horizontal, small ? 8 : 9)
        .frame(height: small ? 22 : 24)
        .background(Capsule().fill(tint.opacity(hovering ? 0.14 : 0.08)))
        .overlay(Capsule().strokeBorder(tint.opacity(0.18)))
        .onHover { hovering = $0 }
    }
}

// MARK: - Pickers

/// Searches the documents and presentations of the library; on top, a new one named after the to-do.
struct NoteDocumentPicker: View {
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    let excluded: Set<UUID>
    /// Offers a new document and a new presentation with this name; nil offers none.
    let createTitle: String?
    let onPick: (UUID) -> Void
    var onCreate: ((_ presentation: Bool) -> Void)?
    @State private var query = ""

    var body: some View {
        let documents = app.documents
            .filter { !excluded.contains($0.id) && !$0.isEmpty && $0.matches(query.trimmingCharacters(in: .whitespaces)) }
            .sorted { $0.updatedAt > $1.updatedAt }
            .prefix(60)
        VStack(alignment: .leading, spacing: 8) {
            if let createTitle, let onCreate {
                let name = createTitle.trimmingCharacters(in: .whitespaces)
                VStack(alignment: .leading, spacing: 2) {
                    createRow(name.isEmpty ? "Neues Dokument" : "Neues Dokument „\(name)“", symbol: StudioApplication.writer.symbol) { onCreate(false) }
                    createRow(name.isEmpty ? "Neue Präsentation" : "Neue Präsentation „\(name)“", symbol: StudioApplication.presenter.symbol) { onCreate(true) }
                }
                Divider()
            }
            SearchField(text: $query, prompt: "Dokumente und Präsentationen")
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 1) {
                    ForEach(Array(documents)) { document in
                        Button {
                            onPick(document.id)
                            dismiss()
                        } label: {
                            HStack(spacing: 8) {
                                Image(systemName: document.isPresentation ? StudioApplication.presenter.symbol : StudioApplication.writer.symbol)
                                    .font(.system(size: 12))
                                    .foregroundStyle(Theme.accent)
                                    .frame(width: 18)
                                Text(document.displayTitle)
                                    .font(.system(size: 13))
                                    .foregroundStyle(Theme.textPrimary)
                                    .lineLimit(1)
                                Spacer(minLength: 6)
                                Text(document.updatedAt.formatted(date: .abbreviated, time: .omitted))
                                    .font(.system(size: 11))
                                    .foregroundStyle(Theme.textTertiary)
                            }
                            .padding(.horizontal, 8)
                            .frame(height: 30)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .frame(height: 260)
            .overlay {
                if documents.isEmpty {
                    Text(query.isEmpty ? "Keine Dokumente" : "Keine Treffer")
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.textTertiary)
                }
            }
        }
        .padding(12)
        .frame(width: 340)
    }

    private func createRow(_ title: String, symbol: String, _ action: @escaping () -> Void) -> some View {
        Button {
            action()
            dismiss()
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "plus")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Theme.accent)
                    .frame(width: 18)
                Image(systemName: symbol)
                    .font(.system(size: 11.5))
                    .foregroundStyle(Theme.textSecondary)
                Text(title)
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.textPrimary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 8)
            .frame(height: 28)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// Searches the notes of the library, to link one to a document or a part.
struct NotePicker: View {
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    let excluded: Set<UUID>
    let onPick: (UUID) -> Void
    @State private var query = ""

    var body: some View {
        let notes = app.notes.notes.filter { !excluded.contains($0.id) && $0.matches(query) }.prefix(80)
        VStack(alignment: .leading, spacing: 8) {
            SearchField(text: $query, prompt: "Notes durchsuchen")
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 1) {
                    ForEach(Array(notes)) { note in
                        Button {
                            onPick(note.id)
                            dismiss()
                        } label: {
                            HStack(spacing: 9) {
                                NoteMiniRing(progress: note.progress)
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(note.displayTitle)
                                        .font(.system(size: 13))
                                        .foregroundStyle(Theme.textPrimary)
                                        .lineLimit(1)
                                    Text(app.noteSubtitle(note))
                                        .font(.system(size: 11))
                                        .foregroundStyle(Theme.textTertiary)
                                        .lineLimit(1)
                                }
                                Spacer(minLength: 0)
                            }
                            .padding(.horizontal, 8)
                            .frame(height: 38)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .frame(height: 260)
            .overlay {
                if notes.isEmpty {
                    Text(query.isEmpty ? "Keine weiteren Notes" : "Keine Treffer")
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.textTertiary)
                }
            }
        }
        .padding(12)
        .frame(width: 340)
    }
}

extension AppModel {
    /// "3 von 7 erledigt · Bachelorarbeit": how far a note is and to what it belongs.
    func noteSubtitle(_ note: Note) -> String {
        var parts = [note.progress.label]
        if let owner = note.owners.first, let title = noteOwnerShortTitle(owner) {
            parts.append(note.owners.count > 1 ? "\(title) +\(note.owners.count - 1)" : title)
        }
        return parts.joined(separator: " · ")
    }
}
