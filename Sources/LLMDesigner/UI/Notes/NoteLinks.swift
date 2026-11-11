import SwiftUI

// Where notes meet the other studios. A document, a presentation, a novel world or one of its parts shows the notes
// that belong to IT, with a pin and its own name in the head ("Notes dieses Dokuments"). The power access shows ALL
// notes of the library with the bolt ("Alle Notes"). The two look different on purpose, so it is always clear
// whether a list is about the thing that is open or about everything.

extension AppModel {
    /// The open document's notes are in the right-hand panel instead of its contents.
    var showsDocumentNotes: Bool {
        selectedDocumentID != nil && !power.isOn && documentPanelTab == .notes && isPanelShown
    }

    /// The bolt off, the panel on, the notes tab chosen; again: back to the contents.
    func toggleDocumentNotes() {
        notes.loadIfNeeded()
        if showsDocumentNotes {
            documentPanelTab = .contents
            return
        }
        withAnimation(.smooth(duration: 0.28)) {
            if power.isOn { power.isOn = false }
            documentPanelTab = .notes
        }
        if !isPanelShown { toggleOutlinePanel() }
        revealRightPanelAfterFolding()
    }

    /// Opens the power access on its notes module: every note, not just the document's.
    func showAllNotesInPower() {
        notes.loadIfNeeded()
        power.module = .notes
        power.noteID = nil
        if !power.isOn { togglePower() }
        if !isPanelShown { toggleOutlinePanel() }
        revealRightPanelAfterFolding()
    }

    /// A wider panel may not fit beside the document any more: the window folds it away a moment later. It then lies
    /// over the document instead, because the person asked to see it.
    private func revealRightPanelAfterFolding() {
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(60))
            guard let self, !self.isPanelShown else { return }
            self.toggleOutlinePanel()
        }
    }
}

/// The checklist in the title bars of Writer and Presenter: the notes of this document in the right-hand panel.
struct DocumentNotesButton: View {
    @Environment(AppModel.self) private var app
    let document: WriterDocument
    @State private var hovering = false

    var body: some View {
        let notes = app.notes.notes(for: .document(document.id))
        let isOn = app.showsDocumentNotes
        let progress = NoteProgress(done: notes.reduce(0) { $0 + $1.progress.done }, total: notes.reduce(0) { $0 + $1.progress.total })
        Button {
            app.toggleDocumentNotes()
        } label: {
            ZStack(alignment: .bottomTrailing) {
                Image(systemName: "checklist")
                    .font(.system(size: 13.5, weight: .medium))
                    .foregroundStyle(isOn ? Theme.accent : (hovering ? Theme.textPrimary : Theme.textSecondary))
                    .frame(width: Theme.titleBarControlSize, height: Theme.titleBarControlSize)
                if !notes.isEmpty {
                    NoteMiniRing(progress: progress, size: 10)
                        .background(Circle().fill(Theme.background).padding(-1.5))
                        .offset(x: -3, y: -3)
                }
            }
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(isOn ? Theme.accent.opacity(0.14) : (hovering ? Theme.hover : .clear)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(notes.isEmpty
              ? "Notes dieses \(document.isPresentation ? "Vortrags" : "Dokuments"): ToDos und Fortschritt, die zu „\(document.displayTitle)“ gehören"
              : "Notes dieses \(document.isPresentation ? "Vortrags" : "Dokuments"): \(progress.label)")
    }
}

/// The head that says whose notes these are: a pin and the owner's name, tinted, so it can't be mistaken for the
/// power access with all notes.
struct NoteOwnerBanner: View {
    @Environment(AppModel.self) private var app
    let owner: NoteOwner
    let count: Int

    var body: some View {
        HStack(spacing: 9) {
            ZStack {
                RoundedRectangle(cornerRadius: 7, style: .continuous).fill(Theme.accent.opacity(0.16))
                Image(systemName: app.noteOwnerSymbol(owner))
                    .font(.system(size: 12.5, weight: .medium))
                    .foregroundStyle(Theme.accent)
            }
            .frame(width: 28, height: 28)
            .overlay(alignment: .topTrailing) {
                Image(systemName: "pin.fill")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(Theme.accent)
                    .rotationEffect(.degrees(35))
                    .offset(x: 4, y: -4)
            }
            VStack(alignment: .leading, spacing: 1) {
                Text("Gehört zu \(article) \(app.noteOwnerKind(owner))")
                    .font(.system(size: 10.5, weight: .medium))
                    .foregroundStyle(Theme.textTertiary)
                Text(app.noteOwnerShortTitle(owner) ?? "–")
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundStyle(Theme.textPrimary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: 0)
            Text(count == 1 ? "1 Note" : "\(count) Notes")
                .font(.system(size: 11, weight: .medium).monospacedDigit())
                .foregroundStyle(Theme.textTertiary)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Theme.accent.opacity(0.07)))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Theme.accent.opacity(0.22)))
    }

    /// "diesem Dokument", "dieser Präsentation", "diesem Kapitel".
    private var article: String {
        switch app.noteOwnerKind(owner) {
        case "Präsentation", "Romanwelt": "dieser"
        default: "diesem"
        }
    }
}

// MARK: - The panel of a document

/// The right-hand panel of a document or presentation with its notes. The power access, one click away, has all.
struct DocumentNotesPanel: View {
    @Environment(AppModel.self) private var app
    @Environment(\.undoManager) private var undoManager
    let document: WriterDocument
    @State private var selectedID: UUID?
    @State private var linking = false

    var body: some View {
        let owner = NoteOwner.document(document.id)
        let notes = app.notes.notes(for: owner)
        let current = notes.first { $0.id == selectedID } ?? notes.first
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                Image(systemName: "pin.fill")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Theme.accent)
                    .rotationEffect(.degrees(35))
                Text(document.isPresentation ? "Notes dieser Präsentation" : "Notes dieses Dokuments")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Theme.textPrimary)
                    .lineLimit(1)
                Spacer(minLength: 0)
                IconButton(systemName: "list.bullet.indent", help: "Zurück zum Inhalt", size: 13, frameSize: Theme.titleBarControlSize) {
                    app.documentPanelTab = .contents
                }
                IconButton(systemName: "sidebar.right", help: "Seitenleiste ausblenden (⌥⌘I)", frameSize: Theme.titleBarControlSize) {
                    app.toggleOutlinePanel()
                }
            }
            .padding(.horizontal, 12)
            .frame(height: Theme.titleBarHeight)
            .padding(.bottom, Theme.topBarBottomPadding)
            .background(WindowDragArea())

            NoteOwnerBanner(owner: owner, count: notes.count)
                .padding(.horizontal, 10)
                .padding(.bottom, 8)

            if notes.count > 1 {
                ScrollView(.horizontal) {
                    HStack(spacing: 5) {
                        ForEach(notes) { note in
                            let isSelected = note.id == current?.id
                            Button { selectedID = note.id } label: {
                                HStack(spacing: 5) {
                                    NoteMiniRing(progress: note.progress, size: 12)
                                    Text(note.displayTitle)
                                        .font(.system(size: 11.5, weight: isSelected ? .semibold : .medium))
                                        .lineLimit(1)
                                }
                                .foregroundStyle(isSelected ? Theme.textPrimary : Theme.textSecondary)
                                .padding(.horizontal, 9)
                                .frame(height: 24)
                                .background(Capsule().fill(isSelected ? Theme.selection : Theme.ink.opacity(0.04)))
                                .contentShape(Capsule())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.horizontal, 10)
                }
                .scrollIndicators(.never)
                .padding(.bottom, 6)
            }

            if let current {
                ScrollView {
                    NoteEditor(noteID: current.id, compact: true)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .id(current.id)
                }
            } else {
                empty
            }

            footer(owner: owner, current: current)
        }
        .background(Theme.sidebar)
        .overlay(alignment: .leading) {
            Rectangle().fill(Theme.border).frame(width: 1)
        }
        .onAppear { app.notes.loadIfNeeded() }
    }

    private var empty: some View {
        VStack(spacing: 10) {
            Image(systemName: "checklist")
                .font(.system(size: 26, weight: .light))
                .foregroundStyle(Theme.accent)
            Text(document.isPresentation ? "Noch keine Notes für diese Präsentation" : "Noch keine Notes für dieses Dokument")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Theme.textPrimary)
                .multilineTextAlignment(.center)
            Text("Eine ToDo-Liste, die zu „\(document.displayTitle)“ gehört – etwa „Fortschritt Bachelorarbeit“ mit Kapiteln als ToDos.")
                .font(.system(size: 12))
                .foregroundStyle(Theme.textSecondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            Button {
                selectedID = app.newNote(for: .document(document.id)).id
            } label: {
                Label("Note anlegen", systemImage: "plus")
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
            .padding(.top, 2)
            Button("Vorhandenes Note verknüpfen …") { linking = true }
                .buttonStyle(.plain)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Theme.accent)
                .popover(isPresented: $linking, arrowEdge: .bottom) { picker }
        }
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var picker: some View {
        NotePicker(excluded: Set(app.notes.notes(for: .document(document.id)).map(\.id))) { id in
            app.attachNote(id, to: .document(document.id), undo: undoManager)
            selectedID = id
        }
        .environment(app)
    }

    private func footer(owner: NoteOwner, current: Note?) -> some View {
        VStack(spacing: 0) {
            Rectangle().fill(Theme.border).frame(height: 1)
            HStack(spacing: 2) {
                if current != nil {
                    IconMenu(systemName: "plus", help: "Neues Note oder vorhandenes verknüpfen", size: 12.5, frameSize: 26) {
                        Button("Neues Note für dieses Dokument", systemImage: "plus") { selectedID = app.newNote(for: owner).id }
                        Button("Vorhandenes Note verknüpfen …", systemImage: "link") { linking = true }
                    }
                    .popover(isPresented: $linking, arrowEdge: .top) { picker }
                    if let current {
                        IconButton(systemName: "arrow.up.left.and.arrow.down.right", help: "Im Notes-Studio öffnen", size: 11.5, frameSize: 26) {
                            app.openNotesStudio(showing: current.id)
                        }
                        IconButton(systemName: "pin.slash", help: "Note von diesem Dokument lösen; es bleibt in Notes", size: 11.5, frameSize: 26) {
                            app.detachNote(current.id, from: owner, undo: undoManager)
                            selectedID = nil
                        }
                    }
                }
                Spacer(minLength: 4)
                Button {
                    app.showAllNotesInPower()
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "bolt.fill").font(.system(size: 10, weight: .semibold))
                        Text("Alle Notes").font(.system(size: 11.5, weight: .medium))
                    }
                    .foregroundStyle(Theme.textSecondary)
                    .padding(.horizontal, 8)
                    .frame(height: 24)
                    .background(Capsule().strokeBorder(Theme.border))
                    .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .help("Power-Zugriff: alle Notes der Bibliothek, nicht nur die dieses Dokuments")
            }
            .padding(.horizontal, 8)
            .frame(height: 38)
        }
    }
}

// MARK: - Stories

/// "Notes" of a novel world or one of its parts in Stories Studio: the notes that belong to it, each folding open to
/// its to-dos right there.
struct StoryNotesCard: View {
    @Environment(AppModel.self) private var app
    @Environment(\.undoManager) private var undoManager
    let owner: NoteOwner
    /// "zu diesem Kapitel".
    let ownerLabel: String
    @State private var linking = false
    @State private var expanded: Set<UUID> = []

    var body: some View {
        let notes = app.notes.notes(for: owner)
        StoryCard(tint: notes.isEmpty ? nil : Theme.accent) {
            HStack(spacing: 10) {
                StoryLabel(title: "Notes", hint: "ToDo-Listen mit Fortschritt, die \(ownerLabel) gehören – Recherche, Überarbeitung, offene Fäden. Alle Notes findest du im Notes-Studio und im Power-Zugriff.",
                           symbol: "checklist", color: Theme.accent)
                Spacer()
                Button {
                    let note = app.newNote(for: owner)
                    expanded.insert(note.id)
                } label: {
                    Label("Neues Note", systemImage: "plus")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(Theme.accent)
                }
                .buttonStyle(.plain)
                Button {
                    linking = true
                } label: {
                    Label("Verknüpfen", systemImage: "link")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(Theme.accent)
                }
                .buttonStyle(.plain)
                .popover(isPresented: $linking, arrowEdge: .bottom) {
                    NotePicker(excluded: Set(notes.map(\.id))) { id in
                        app.attachNote(id, to: owner, undo: undoManager)
                        expanded.insert(id)
                    }
                    .environment(app)
                }
            }
            if notes.isEmpty {
                Text("Noch kein Note.")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.textTertiary)
            }
            ForEach(notes) { note in
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 9) {
                        Button {
                            if expanded.contains(note.id) { expanded.remove(note.id) } else { expanded.insert(note.id) }
                        } label: {
                            HStack(spacing: 9) {
                                Image(systemName: "chevron.right")
                                    .font(.system(size: 9, weight: .bold))
                                    .foregroundStyle(Theme.textTertiary)
                                    .rotationEffect(.degrees(expanded.contains(note.id) ? 90 : 0))
                                NoteMiniRing(progress: note.progress, size: 18)
                                Text(note.displayTitle)
                                    .font(.system(size: 13, weight: .medium))
                                    .foregroundStyle(Theme.textPrimary)
                                    .lineLimit(1)
                                Text(note.progress.label)
                                    .font(.system(size: 11.5).monospacedDigit())
                                    .foregroundStyle(Theme.textTertiary)
                                    .lineLimit(1)
                                Spacer(minLength: 0)
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        IconButton(systemName: "arrow.up.left.and.arrow.down.right", help: "Im Notes-Studio öffnen", size: 11, frameSize: 22) {
                            app.openNotesStudio(showing: note.id)
                        }
                        IconButton(systemName: "pin.slash", help: "Note lösen; es bleibt in Notes", size: 11, frameSize: 22) {
                            app.detachNote(note.id, from: owner, undo: undoManager)
                        }
                    }
                    if expanded.contains(note.id) {
                        NoteEditor(noteID: note.id, compact: true)
                            .padding(12)
                            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Theme.background.opacity(0.6)))
                            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Theme.border))
                    }
                }
            }
        }
        .onAppear { app.notes.loadIfNeeded() }
    }
}
