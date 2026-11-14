import AppKit
import SwiftUI

struct SidebarView: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        @Bindable var app = app

        VStack(spacing: 0) {
            HStack(spacing: 2) {
                SidebarToggleButton()
                Spacer()
                if app.sidebarMode != .personas {
                    IconButton(systemName: "folder.badge.plus", help: "Neuer Ordner (⇧⌘N)", size: 14, frameSize: Theme.titleBarControlSize) {
                        app.createFolder(for: app.sidebarMode)
                    }
                }
                switch app.sidebarMode {
                case .chats:
                    IconMenu(systemName: StudioApplication.writer.symbol, help: "Neues Dokument oder neue Präsentation", size: 13.5, frameSize: Theme.titleBarControlSize) {
                        Button("Neues Dokument", systemImage: StudioApplication.writer.symbol) { app.newDocument() }
                        Button("Neue Präsentation", systemImage: StudioApplication.presenter.symbol) { app.newPresentation() }
                        Divider()
                        Button("Präsentation aus Dokument …", systemImage: "doc.text.below.ecg") { app.showDeckFromDocument() }
                    }
                    NewItemMenu()
                case .skills:
                    IconButton(systemName: "plus", help: "Neuer Skill (⌥⌘N)", frameSize: Theme.titleBarControlSize) { app.createSkill() }
                case .personas:
                    IconButton(systemName: "plus", help: "Neue Persona (⌥⇧⌘N)", frameSize: Theme.titleBarControlSize) { app.createPersona() }
                }
            }
            .padding(.leading, Theme.trafficLightInset)
            .padding(.trailing, 10)
            .frame(height: Theme.titleBarHeight)
            .padding(.bottom, Theme.topBarBottomPadding)
            .background(WindowDragArea())

            SidebarModePicker()
                .padding(.horizontal, 10)
                .padding(.bottom, 8)

            switch app.sidebarMode {
            case .chats:
                HStack(spacing: 4) {
                    SearchField(text: $app.searchText, prompt: "Chats durchsuchen")
                    ArrangementMenu()
                }
                .padding(.leading, 10)
                .padding(.trailing, 6)
                .padding(.bottom, 6)
                ChatList()
            case .skills:
                SearchField(text: $app.skillSearchText, prompt: "Skills durchsuchen")
                    .padding(.horizontal, 10)
                    .padding(.bottom, 6)
                SkillList()
            case .personas:
                SearchField(text: $app.personaSearchText, prompt: "Personas durchsuchen")
                    .padding(.horizontal, 10)
                    .padding(.bottom, 6)
                PersonaList()
            }

            SidebarFooter()
        }
        .background(Theme.sidebar)
        .overlay(alignment: .trailing) {
            Rectangle().fill(Theme.border).frame(width: 1)
        }
    }
}

/// Switches the sidebar between the chats, the skill library and the personas.
private struct SidebarModePicker: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        HStack(spacing: 2) {
            segment("Chats", symbol: "bubble.left.and.bubble.right", mode: .chats, count: nil, shortcut: "⌘1")
            segment("Skills", symbol: Skill.defaultSymbol, mode: .skills, count: nil, shortcut: "⌘2")
            segment("Personas", symbol: Persona.symbol, mode: .personas, count: nil, shortcut: "⌘3")
        }
        .padding(2)
        .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(Theme.ink.opacity(0.04)))
        .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).strokeBorder(Theme.border))
    }

    private func segment(_ title: String, symbol: String, mode: SidebarMode, count: Int?, shortcut: String) -> some View {
        ModeSegment(title: title, symbol: symbol, count: count, isSelected: app.sidebarMode == mode, help: "\(title) (\(shortcut))") {
            switch mode {
            case .chats: app.showChats()
            case .skills: app.showSkills()
            case .personas: app.showPersonas()
            }
        }
    }
}

private struct ModeSegment: View {
    let title: String
    let symbol: String
    let count: Int?
    let isSelected: Bool
    let help: String
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: symbol)
                    .font(.system(size: 11, weight: .medium))
                Text(title)
                    .font(.system(size: 12, weight: .semibold))
                    .lineLimit(1)
                if let count, count > 0 {
                    Text("\(count)")
                        .font(.system(size: 10.5, weight: .semibold).monospacedDigit())
                        .foregroundStyle(isSelected ? Theme.accent : Theme.textTertiary)
                }
            }
            .foregroundStyle(isSelected ? Theme.textPrimary : (hovering ? Theme.textSecondary : Theme.textTertiary))
            .frame(maxWidth: .infinity)
            .frame(height: 26)
            .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(isSelected ? Theme.selection : (hovering ? Theme.hover : .clear)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(help)
    }
}

// MARK: Chats

private struct ChatList: View {
    @Environment(AppModel.self) private var app
    @Environment(\.openWindow) private var openWindow
    @State private var pendingDelete: Chat?
    @State private var pendingDocumentDelete: WriterDocument?
    @State private var pendingPodcastDelete: Podcast?
    @State private var pendingFolderDelete: Folder?
    @State private var pendingProjectDelete: Project?
    @Environment(\.undoManager) private var undoManager

    var body: some View {
        let sections = app.chatFolderSections
        let stacked = app.sidebarArrangement == .stacks
        let groups = stacked ? [] : app.chatGroups
        let stacks = stacked ? app.sidebarStackList : []
        let searching = !app.chatSearchQuery.isEmpty

        ScrollView {
            LazyVStack(alignment: .leading, spacing: 1) {
                ProjectSidebarSection { pendingProjectDelete = $0 }
                if !sections.isEmpty {
                    SectionHeader(title: "Ordner")
                    ForEach(sections) { section in
                        folderBlock(section, searching: searching) {
                            ForEach(section.children) { child in
                                folderBlock(child, searching: searching) { EmptyView() }
                            }
                        }
                    }
                }
                if stacked {
                    if !stacks.isEmpty || app.isTidyingStacks {
                        StackHeader()
                    }
                    ForEach(stacks) { stack in
                        StackBlock(stack: stack, isExpanded: searching || app.isStackExpanded(stack.id)) {
                            ForEach(stack.entries) { entry in
                                row(for: entry, in: nil, indent: 18)
                            }
                        }
                    }
                }
                ForEach(groups) { group in
                    SectionHeader(title: group.id)
                    ForEach(group.entries) { entry in
                        row(for: entry, in: nil)
                    }
                }
            }
            .padding(.horizontal, 8)
            .padding(.bottom, 12)
        }
        .scrollIndicators(.automatic)
        // Dropped anywhere outside a folder, a chat or document leaves its folder.
        .dropDestination(for: String.self) { items, _ in
            let ids = SidebarDrag.ids(in: items, prefix: SidebarDrag.chat)
            ids.forEach { app.moveSidebarItem($0, to: nil) }
            // A subfolder dropped outside every folder goes to the top.
            let folders = SidebarDrag.ids(in: items, prefix: SidebarDrag.folder)
            folders.forEach { app.moveFolder($0, into: nil) }
            return !ids.isEmpty || !folders.isEmpty
        }
        .overlay {
            if sections.isEmpty && groups.isEmpty && stacks.isEmpty && app.projects.projects.isEmpty {
                Text(searching ? "Keine Treffer" : "Noch keine Chats")
                    .font(.system(size: 12.5))
                    .foregroundStyle(Theme.textTertiary)
                    .allowsHitTesting(false)
            }
        }
        .alert("Chat löschen?", isPresented: isPresent($pendingDelete), presenting: pendingDelete) { chat in
            Button("Löschen", role: .destructive) { app.deleteChat(chat.id) }
            Button("Abbrechen", role: .cancel) {}
        } message: { chat in
            Text("„\(chat.title)“ wird dauerhaft gelöscht.")
        }
        .alert(pendingDocumentDelete?.isPresentation == true ? "Präsentation löschen?" : "Dokument löschen?", isPresented: isPresent($pendingDocumentDelete), presenting: pendingDocumentDelete) { document in
            Button("Löschen", role: .destructive) { app.deleteDocument(document.id) }
            Button("Abbrechen", role: .cancel) {}
        } message: { document in
            Text("„\(document.displayTitle)“ wird dauerhaft gelöscht.")
        }
        .alert("Projekt löschen?", isPresented: isPresent($pendingProjectDelete), presenting: pendingProjectDelete) { project in
            Button("Löschen", role: .destructive) {
                if app.openProjectID == project.id { app.closeProject() }
                app.projects.deleteProject(project.id)
            }
            Button("Abbrechen", role: .cancel) {}
        } message: { project in
            Text("„\(project.displayTitle)“ kommt in den Papierkorb. Verknüpfte Chats, Dokumente, Notes und Romanwelten bleiben, wie sie sind.")
        }
        .alert("Podcast löschen?", isPresented: isPresent($pendingPodcastDelete), presenting: pendingPodcastDelete) { podcast in
            Button("Löschen", role: .destructive) { app.deletePodcast(podcast.id, undo: undoManager) }
            Button("Abbrechen", role: .cancel) {}
        } message: { podcast in
            Text("„\(podcast.displayTitle)“ kommt mit seiner Audiodatei in den Papierkorb.")
        }
        .confirmationDialog(
            "Ordner „\(pendingFolderDelete?.name ?? "")“ löschen?",
            isPresented: isPresent($pendingFolderDelete),
            presenting: pendingFolderDelete
        ) { folder in
            Button("Ordner löschen, Inhalt behalten") { app.deleteFolder(folder.id, includingContents: false) }
            Button("Ordner mit Inhalt löschen", role: .destructive) { app.deleteFolder(folder.id, includingContents: true) }
            Button("Abbrechen", role: .cancel) {}
        } message: { folder in
            let chats = app.chats.filter { $0.folderID == folder.id }.count
            let documents = app.documents.filter { $0.folderID == folder.id }.count
            let podcasts = app.podcasts.podcasts.filter { $0.folderID == folder.id }.count
            let subfolders = app.subfolders(of: folder.id).count
            let parts = [
                chats > 0 ? "\(chats) \(chats == 1 ? "Chat" : "Chats")" : nil,
                documents > 0 ? "\(documents) \(documents == 1 ? "Dokument" : "Dokumente")" : nil,
                podcasts > 0 ? "\(podcasts) \(podcasts == 1 ? "Podcast" : "Podcasts")" : nil,
                subfolders > 0 ? "\(subfolders) \(subfolders == 1 ? "Unterordner" : "Unterordner")" : nil,
            ].compactMap { $0 }
            let kept = folder.parentID != nil ? "Behaltenes kommt in den übergeordneten Ordner." : "Behaltenes erscheint wieder in der Liste, Unterordner werden zu Ordnern."
            Text(parts.isEmpty ? "Der Ordner ist leer." : "Er enthält \(parts.joined(separator: ", ")). \(kept)")
        }
    }

    /// A folder with its subfolders (`nested`) and then its chats and documents.
    private func folderBlock<Nested: View>(_ section: FolderSection<SidebarEntry>, searching: Bool, @ViewBuilder nested: () -> Nested) -> some View {
        let folder = section.folder
        let isSub = folder.parentID != nil
        return FolderBlock(
            folder: folder,
            count: section.totalCount,
            isEmpty: section.totalCount == 0 && section.children.isEmpty,
            isExpanded: searching || folder.isCollapsed != true,
            indent: isSub ? 18 : 0,
            dragPrefix: SidebarDrag.chat,
            onDrop: { app.moveSidebarItem($0, to: folder.id) },
            onFolderDrop: isSub ? nil : { app.moveFolder($0, into: folder.id) },
            emptyHint: "Leer – Chats oder Dokumente hierher ziehen",
            menu: {
                Button("Neuer Chat in diesem Ordner", systemImage: "square.and.pencil") {
                    app.newChat(inFolder: folder.id)
                }
                Button("Neues Dokument in diesem Ordner", systemImage: StudioApplication.writer.symbol) {
                    app.newDocument(inFolder: folder.id)
                }
                Button("Neue Präsentation in diesem Ordner", systemImage: StudioApplication.presenter.symbol) {
                    app.newPresentation(inFolder: folder.id)
                }
                if !isSub {
                    Button("Neuer Unterordner", systemImage: "folder.badge.plus") { app.createFolder(for: .chats, parent: folder.id) }
                }
                Divider()
                FolderColorMenu(folder: folder)
                Button("Umbenennen", systemImage: "pencil") { app.renamingID = folder.id }
                if isSub {
                    Button("Zum Ordner auf oberster Ebene machen", systemImage: "arrow.up.forward.square") { app.moveFolder(folder.id, into: nil) }
                } else if section.children.isEmpty {
                    let targets = app.chatFolders.filter { app.canMoveFolder(folder.id, into: $0.id) }
                    if !targets.isEmpty {
                        Menu("In Ordner verschieben", systemImage: "folder") {
                            ForEach(Folder.sorted(targets)) { target in
                                Button(target.name) { app.moveFolder(folder.id, into: target.id) }
                            }
                        }
                    }
                }
                Button("Ordner löschen …", systemImage: "trash", role: .destructive) { pendingFolderDelete = folder }
            }
        ) {
            nested()
            ForEach(section.items) { entry in
                row(for: entry, in: folder)
            }
        }
    }

    private func indent(in folder: Folder?) -> CGFloat {
        guard let folder else { return 0 }
        return folder.parentID == nil ? 18 : 36
    }

    /// `folder`: the folder the row is shown in; its colour tints the symbol.
    /// `indent`: set for rows in a stack, which has no folder.
    @ViewBuilder
    private func row(for entry: SidebarEntry, in folder: Folder?, indent: CGFloat? = nil) -> some View {
        switch entry {
        case .chat(let chat): row(for: chat, in: folder, indent: indent ?? self.indent(in: folder))
        case .document(let document): row(for: document, in: folder, indent: indent ?? self.indent(in: folder))
        case .podcast(let podcast): row(for: podcast, in: folder, indent: indent ?? self.indent(in: folder))
        }
    }

    private func row(for podcast: Podcast, in folder: Folder?, indent: CGFloat) -> some View {
        SidebarRow(
            id: podcast.id,
            title: podcast.displayTitle,
            isSelected: app.podcastStudioOpen && app.selectedPodcastID == podcast.id,
            indent: indent,
            dragPayload: SidebarDrag.payload(SidebarDrag.chat, podcast.id),
            onSelect: { app.selectPodcast(podcast.id) },
            onRename: { app.renamePodcast(podcast.id, to: $0) },
            leading: {
                Image(systemName: StudioApplication.podcast.symbol)
                    .font(.system(size: 11.5))
                    .foregroundStyle(folder?.color?.color ?? Theme.accent.opacity(0.85))
                    .frame(width: 18)
                    .help("Podcast (PodcastStudio)")
            },
            trailing: { PodcastStatusBadge(podcast: podcast, progress: app.podcastProgress[podcast.id]) },
            menu: {
                if podcast.phase.isRunning {
                    Button("Anhalten", systemImage: "stop.circle") { app.stopPodcast(podcast.id) }
                } else if podcast.startProblem == nil, !app.isPodcastAudioCurrent(podcast) {
                    Button(podcast.script.isEmpty ? "Erzeugen" : "Fortsetzen", systemImage: "play.circle") { app.startPodcast(podcast.id) }
                }
                if app.podcastAudioURL(podcast.id) != nil {
                    Button("Audio exportieren …", systemImage: "square.and.arrow.up") { app.exportPodcastWithPanel(podcast.id) }
                }
                if !podcast.script.isEmpty {
                    Button("Als Writer-Dokument", systemImage: StudioApplication.writer.symbol) { app.openPodcastAsDocument(podcast.id) }
                }
                Divider()
                Button("Umbenennen", systemImage: "pencil") { app.renamingID = podcast.id }
                MoveToFolderMenu(
                    folders: app.chatFolders,
                    current: podcast.folderID,
                    onMove: { app.movePodcast(podcast.id, to: $0) },
                    onNewFolder: { app.movePodcastToNewFolder(podcast.id) }
                )
                Divider()
                Button("Löschen", systemImage: "trash", role: .destructive) { pendingPodcastDelete = podcast }
            }
        )
    }

    private func row(for document: WriterDocument, in folder: Folder?, indent: CGFloat) -> some View {
        SidebarRow(
            id: document.id,
            title: document.displayTitle,
            isSelected: app.selectedDocumentID == document.id,
            indent: indent,
            dragPayload: SidebarDrag.payload(SidebarDrag.chat, document.id),
            onSelect: { app.selectDocument(document.id) },
            onRename: { app.renameDocument(document.id, to: $0) },
            leading: {
                Image(systemName: document.isPresentation ? StudioApplication.presenter.symbol : StudioApplication.writer.symbol)
                    .font(.system(size: 12))
                    .foregroundStyle(folder?.color?.color ?? Theme.accent.opacity(0.85))
                    .frame(width: 18)
                    .help(document.isPresentation ? "Präsentation (Presenter Studio)" : "Dokument (Writer Studio)")
            },
            trailing: { EmptyView() },
            menu: {
                Button("Umbenennen", systemImage: "pencil") { app.renamingID = document.id }
                if document.hasCustomTitle {
                    Button("Automatischen Titel verwenden", systemImage: "wand.and.sparkles") { app.useAutomaticDocumentTitle(document.id) }
                }
                MoveToFolderMenu(
                    folders: app.chatFolders,
                    current: document.folderID,
                    onMove: { app.moveDocument(document.id, to: $0) },
                    onNewFolder: { app.moveDocumentToNewFolder(document.id) }
                )
                Divider()
                Button("Löschen", systemImage: "trash", role: .destructive) { pendingDocumentDelete = document }
            }
        )
    }

    private func row(for chat: Chat, in folder: Folder?, indent: CGFloat) -> some View {
        SidebarRow(
            id: chat.id,
            title: chat.title,
            isSelected: app.selectedChatID == chat.id && app.selectedDocumentID == nil,
            indent: indent,
            dragPayload: SidebarDrag.payload(SidebarDrag.chat, chat.id),
            onSelect: { app.selectChat(chat.id) },
            onRename: { app.renameChat(chat.id, to: $0) },
            leading: {
                // A persona's picture keeps its own colours; the bubble takes on the folder's.
                if let persona = app.persona(of: chat) {
                    PersonaAvatar(persona: persona, size: 18)
                        .help("Chat mit \(persona.displayName)")
                } else {
                    Image(systemName: "bubble.left")
                        .font(.system(size: 12))
                        .foregroundStyle(folder?.color?.color ?? Theme.textTertiary)
                        .frame(width: 18)
                        .help("Chat")
                }
                if chat.branch != nil {
                    Image(systemName: "arrow.triangle.branch")
                        .font(.system(size: 10.5, weight: .semibold))
                        .foregroundStyle(folder?.color?.color.opacity(0.8) ?? Theme.textTertiary)
                        .help("Abgezweigter Chat")
                }
            },
            trailing: {
                if app.isGenerating(chat.id) {
                    PulsingDot(size: 6, color: Theme.accent)
                }
            },
            menu: {
                Button("Im Mini-Chat öffnen", systemImage: "pip.enter") { OpenInMiniChat(app: app, openWindow: openWindow)(chat.id) }
                Button("Podcast daraus erzeugen", systemImage: StudioApplication.podcast.symbol) { app.newPodcast(about: .chat(chat.id)) }
                Divider()
                Button("Umbenennen", systemImage: "pencil") { app.renamingID = chat.id }
                if chat.isTitleCustom {
                    Button("Automatischen Titel verwenden", systemImage: "wand.and.sparkles") { app.useAutomaticTitle(chat.id) }
                }
                MoveToFolderMenu(
                    folders: app.chatFolders,
                    current: chat.folderID,
                    onMove: { app.moveChat(chat.id, to: $0) },
                    onNewFolder: { app.moveChatToNewFolder(chat.id) }
                )
                Divider()
                Button("Löschen", systemImage: "trash", role: .destructive) { pendingDelete = chat }
            }
        )
    }
}

/// Chooses how the chats and documents outside folders are shown: by date, or in stacks of one of three kinds.
private struct ArrangementMenu: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        IconMenu(systemName: app.sidebarArrangement == .stacks ? "square.stack.3d.up.fill" : "square.stack.3d.up",
                 help: "Ordnung der Liste: nach Datum oder automatisch gestapelt", size: 13, frameSize: 30) {
            Toggle(isOn: choice(.date, nil)) { Label("Nach Datum", systemImage: "calendar") }
            Section("Automatisch stapeln") {
                ForEach(StackMode.allCases) { mode in
                    Toggle(isOn: choice(.stacks, mode)) {
                        Label { Text(mode.label); Text(mode.hint) } icon: { Image(systemName: mode.symbol) }
                    }
                }
            }
            if app.sidebarArrangement == .stacks && app.stackMode == .topics {
                Divider()
                Button("Jetzt aufräumen", systemImage: "wand.and.sparkles") { app.tidySidebarStacks(everything: false) }
                    .disabled(app.isTidyingStacks)
                Button("Alle Themen neu bilden", systemImage: "arrow.triangle.2.circlepath") { app.tidySidebarStacks(everything: true) }
                    .disabled(app.isTidyingStacks)
            }
        }
    }

    private func choice(_ arrangement: SidebarArrangement, _ mode: StackMode?) -> Binding<Bool> {
        Binding(get: { app.sidebarArrangement == arrangement && (mode == nil || app.stackMode == mode) },
                set: { _ in app.setSidebarArrangement(arrangement, mode: mode) })
    }
}

/// "Stapel", with what the model is doing when it sorts by topic.
private struct StackHeader: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        HStack(spacing: 6) {
            Text("Stapel · \(app.stackMode.label)")
                .font(.system(size: 11.5, weight: .semibold))
                .foregroundStyle(Theme.textTertiary)
            Spacer(minLength: 0)
            if app.isTidyingStacks {
                ProgressView().controlSize(.mini)
                Text("sortiert …")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.textTertiary)
            } else if let error = app.stackTidyError {
                Image(systemName: "exclamationmark.triangle")
                    .font(.system(size: 10.5))
                    .foregroundStyle(Theme.warning)
                    .help(error)
            }
        }
        .padding(.horizontal, 10)
        .padding(.top, 14)
        .padding(.bottom, 4)
    }
}

/// A stack: like a folder it opens and closes, but it is made by the app, so nothing can be dropped on it and it has
/// a symbol of its own.
private struct StackBlock<Rows: View>: View {
    @Environment(AppModel.self) private var app
    let stack: SidebarStack
    let isExpanded: Bool
    @ViewBuilder let rows: Rows

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            SidebarRow(
                id: UUID(uuidString: stack.id) ?? Self.fixedID(stack.id),
                title: stack.title,
                isSelected: false,
                indent: 0,
                dragPayload: nil,
                onSelect: { withAnimation(.snappy(duration: 0.2)) { app.toggleStack(stack.id) } },
                onRename: { app.renameTopicStack(stack.id, to: $0) },
                leading: {
                    HStack(spacing: 5) {
                        Image(systemName: "chevron.right")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundStyle(Theme.textTertiary)
                            .rotationEffect(.degrees(isExpanded ? 90 : 0))
                            .frame(width: 10)
                        Image(systemName: stack.symbol)
                            .font(.system(size: 12))
                            .foregroundStyle(Theme.accent.opacity(0.8))
                            .frame(width: 18)
                    }
                },
                trailing: {
                    Text("\(stack.entries.count)")
                        .font(.system(size: 11, weight: .medium).monospacedDigit())
                        .foregroundStyle(Theme.textTertiary)
                },
                menu: {
                    Button(isExpanded ? "Zuklappen" : "Aufklappen", systemImage: "chevron.down") { app.toggleStack(stack.id) }
                    Button("Als Ordner anlegen", systemImage: "folder.badge.plus") { app.makeFolder(fromStack: stack.id) }
                    if stack.isTopic {
                        Button("Umbenennen", systemImage: "pencil") { app.renamingID = UUID(uuidString: stack.id) }
                    }
                }
            )
            if isExpanded { rows }
        }
    }

    /// The fixed stacks (types, relevance) have no UUID of their own; one from the key keeps the row's identity stable.
    static func fixedID(_ key: String) -> UUID {
        var bytes = [UInt8](repeating: 0, count: 16)
        for (index, byte) in key.utf8.enumerated() { bytes[index % 16] = bytes[index % 16] &+ byte &* UInt8(truncatingIfNeeded: index + 1) }
        return UUID(uuid: (bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7],
                           bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]))
    }
}

// MARK: Skills

private struct SkillList: View {
    @Environment(AppModel.self) private var app
    @State private var pendingDelete: Skill?
    @State private var pendingFolderDelete: Folder?

    var body: some View {
        let library = app.skillSections(matching: app.skillSearchText)
        let searching = !app.skillSearchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty

        ScrollView {
            LazyVStack(alignment: .leading, spacing: 1) {
                ForEach(library.folders) { section in
                    FolderBlock(
                        folder: section.folder,
                        count: section.items.count,
                        isEmpty: section.items.isEmpty,
                        isExpanded: searching || section.folder.isCollapsed != true,
                        indent: 0,
                        dragPrefix: SidebarDrag.skill,
                        onDrop: { app.moveSkill($0, to: section.folder.id, reveal: false) },
                        onFolderDrop: nil,
                        emptyHint: "Leer – Skills hierher ziehen",
                        menu: {
                            Button("Neuer Skill in diesem Ordner", systemImage: "plus") { app.createSkill(inFolder: section.folder.id) }
                            Divider()
                            FolderColorMenu(folder: section.folder)
                            Button("Umbenennen", systemImage: "pencil") { app.renamingID = section.folder.id }
                            Button("Ordner löschen …", systemImage: "trash", role: .destructive) { pendingFolderDelete = section.folder }
                        }
                    ) {
                        ForEach(section.items) { skill in
                            row(for: skill, in: section.folder)
                        }
                    }
                }
                if !library.unfiled.isEmpty && !library.folders.isEmpty {
                    SectionHeader(title: "Ohne Ordner")
                }
                ForEach(library.unfiled) { skill in
                    row(for: skill, in: nil)
                }
            }
            .padding(.horizontal, 8)
            .padding(.top, 6)
            .padding(.bottom, 12)
        }
        .scrollIndicators(.automatic)
        // Dropped anywhere outside a folder, a skill leaves its folder.
        .dropDestination(for: String.self) { items, _ in
            let ids = SidebarDrag.ids(in: items, prefix: SidebarDrag.skill)
            ids.forEach { app.moveSkill($0, to: nil) }
            return !ids.isEmpty
        }
        .overlay {
            if library.folders.isEmpty && library.unfiled.isEmpty {
                VStack(spacing: 6) {
                    Text(searching ? "Keine Treffer" : "Noch keine Skills")
                        .font(.system(size: 12.5))
                        .foregroundStyle(Theme.textTertiary)
                    if !searching {
                        Button("Skill anlegen") { app.createSkill() }
                            .buttonStyle(.plain)
                            .font(.system(size: 12.5, weight: .medium))
                            .foregroundStyle(Theme.accent)
                    }
                }
            }
        }
        .alert("Skill löschen?", isPresented: isPresent($pendingDelete), presenting: pendingDelete) { skill in
            Button("Löschen", role: .destructive) { app.deleteSkill(skill.id) }
            Button("Abbrechen", role: .cancel) {}
        } message: { skill in
            let count = app.chatCount(using: skill.id)
            Text("„\(skill.displayName)“ wird dauerhaft gelöscht" + (count == 0 ? "." : " und in \(count) \(count == 1 ? "Chat" : "Chats") abgeschaltet."))
        }
        .confirmationDialog(
            "Ordner „\(pendingFolderDelete?.name ?? "")“ löschen?",
            isPresented: isPresent($pendingFolderDelete),
            presenting: pendingFolderDelete
        ) { folder in
            Button("Ordner löschen, Skills behalten") { app.deleteFolder(folder.id, includingContents: false) }
            Button("Ordner und Skills löschen", role: .destructive) { app.deleteFolder(folder.id, includingContents: true) }
            Button("Abbrechen", role: .cancel) {}
        } message: { folder in
            let count = app.skills.filter { $0.folderID == folder.id }.count
            Text(count == 0 ? "Der Ordner ist leer." : "Er enthält \(count) \(count == 1 ? "Skill" : "Skills"). Behaltene Skills stehen danach unter „Ohne Ordner“.")
        }
    }

    private func row(for skill: Skill, in folder: Folder?) -> some View {
        SidebarRow(
            id: skill.id,
            title: skill.displayName,
            isSelected: app.selectedSkillID == skill.id,
            indent: folder != nil ? 18 : 0,
            dragPayload: SidebarDrag.payload(SidebarDrag.skill, skill.id),
            onSelect: { app.selectSkill(skill.id) },
            onRename: { app.renameSkill(skill.id, to: $0) },
            leading: {
                Image(systemName: skill.symbol ?? Skill.defaultSymbol)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(folder?.color?.color ?? Theme.accent.opacity(0.85))
                    .frame(width: 18)
            },
            trailing: {
                if app.isSkillActive(skill.id) {
                    Image(systemName: "checkmark")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(Theme.textTertiary)
                        .help("Im geöffneten Chat eingeschaltet")
                }
            },
            menu: {
                Button("Umbenennen", systemImage: "pencil") { app.renamingID = skill.id }
                Button("Duplizieren", systemImage: "plus.square.on.square") { app.duplicateSkill(skill.id) }
                Button("In neuem Chat verwenden", systemImage: "square.and.pencil") { app.startChat(with: skill.id) }
                MoveToFolderMenu(
                    folders: app.skillFolders,
                    current: skill.folderID,
                    onMove: { app.moveSkill(skill.id, to: $0) },
                    onNewFolder: { app.moveSkillToNewFolder(skill.id) }
                )
                Divider()
                Button("Löschen", systemImage: "trash", role: .destructive) { pendingDelete = skill }
            }
        )
    }
}

// MARK: Personas

private struct PersonaList: View {
    @Environment(AppModel.self) private var app
    @State private var pendingDelete: Persona?

    var body: some View {
        let personas = app.personas(matching: app.personaSearchText)
        let searching = !app.personaSearchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty

        ScrollView {
            LazyVStack(alignment: .leading, spacing: 1) {
                ForEach(personas) { persona in
                    row(for: persona)
                }
            }
            .padding(.horizontal, 8)
            .padding(.top, 6)
            .padding(.bottom, 12)
        }
        .scrollIndicators(.automatic)
        .overlay {
            if personas.isEmpty {
                VStack(spacing: 6) {
                    Text(searching ? "Keine Treffer" : "Noch keine Personas")
                        .font(.system(size: 12.5))
                        .foregroundStyle(Theme.textTertiary)
                    if !searching {
                        Button("Persona anlegen") { app.createPersona() }
                            .buttonStyle(.plain)
                            .font(.system(size: 12.5, weight: .medium))
                            .foregroundStyle(Theme.accent)
                    }
                }
            }
        }
        .alert("Persona löschen?", isPresented: isPresent($pendingDelete), presenting: pendingDelete) { persona in
            Button("Löschen", role: .destructive) { app.deletePersona(persona.id) }
            Button("Abbrechen", role: .cancel) {}
        } message: { persona in
            Text(PersonaDeleteText.message(for: persona, chats: app.chatCount(withPersona: persona.id)))
        }
    }

    private func row(for persona: Persona) -> some View {
        SidebarRow(
            id: persona.id,
            title: persona.displayName,
            isSelected: app.selectedPersonaID == persona.id,
            indent: 0,
            dragPayload: nil,
            onSelect: { app.selectPersona(persona.id) },
            onRename: { app.renamePersona(persona.id, to: $0) },
            leading: {
                PersonaAvatar(persona: persona, size: 22)
            },
            trailing: {
                if app.activePersona?.id == persona.id {
                    Image(systemName: "checkmark")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(Theme.textTertiary)
                        .help("Im geöffneten Chat")
                }
            },
            menu: {
                Button("Chat starten", systemImage: "square.and.pencil") { app.startChat(withPersona: persona.id) }
                Button("Umbenennen", systemImage: "pencil") { app.renamingID = persona.id }
                Divider()
                Button("Löschen", systemImage: "trash", role: .destructive) { pendingDelete = persona }
            }
        )
    }
}

/// What deleting a persona takes with it.
enum PersonaDeleteText {
    static func message(for persona: Persona, chats: Int) -> String {
        var text = "„\(persona.displayName)“ wird mit Bild und Dateien dauerhaft gelöscht."
        if chats == 1 { text += " Der Chat mit ihr bleibt erhalten und läuft ohne Persona weiter." }
        if chats > 1 { text += " Die \(chats) Chats mit ihr bleiben erhalten und laufen ohne Persona weiter." }
        return text
    }
}

// MARK: Shared pieces

/// Drag payloads for moving chats and skills between folders: a prefix plus the ID.
private enum SidebarDrag {
    static let chat = "llmdesigner-chat:"
    static let skill = "llmdesigner-skill:"
    static let folder = "llmdesigner-folder:"

    static func payload(_ prefix: String, _ id: UUID) -> String { prefix + id.uuidString }

    static func ids(in items: [String], prefix: String) -> [UUID] {
        items.compactMap { item in
            guard item.hasPrefix(prefix) else { return nil }
            return UUID(uuidString: String(item.dropFirst(prefix.count)))
        }
    }
}

private struct SectionHeader: View {
    let title: String

    var body: some View {
        Text(title)
            .font(.system(size: 11.5, weight: .semibold))
            .foregroundStyle(Theme.textTertiary)
            .padding(.horizontal, 10)
            .padding(.top, 14)
            .padding(.bottom, 4)
    }
}

/// "In Ordner verschieben" submenu for a chat or a skill. A folder with subfolders becomes a submenu of its own.
private struct MoveToFolderMenu: View {
    let folders: [Folder]
    let current: Folder.ID?
    let onMove: (Folder.ID?) -> Void
    let onNewFolder: () -> Void

    var body: some View {
        Menu("In Ordner verschieben", systemImage: "folder") {
            ForEach(Folder.sorted(folders.filter { $0.parentID == nil || !folders.map(\.id).contains($0.parentID!) })) { folder in
                let children = Folder.sorted(folders.filter { $0.parentID == folder.id })
                if children.isEmpty {
                    target(folder)
                } else {
                    Menu(folder.name) {
                        target(folder)
                        Divider()
                        ForEach(children) { target($0) }
                    }
                }
            }
            if !folders.isEmpty { Divider() }
            Button("Neuer Ordner …", systemImage: "folder.badge.plus", action: onNewFolder)
            if current != nil {
                Button("Aus dem Ordner nehmen", systemImage: "arrow.up.forward.square") { onMove(nil) }
            }
        }
    }

    @ViewBuilder
    private func target(_ folder: Folder) -> some View {
        if folder.id == current {
            Button(folder.name, systemImage: "checkmark") {}
                .disabled(true)
        } else {
            Button(folder.name) { onMove(folder.id) }
        }
    }
}

extension FolderColor {
    var color: Color { Color(hex: hex) }

    /// A filled dot for the menu; menus draw SF Symbols in one colour, so it is a non-template image.
    var swatch: NSImage {
        let image = NSImage(size: NSSize(width: 12, height: 12), flipped: false) { rect in
            NSColor(color).setFill()
            NSBezierPath(ovalIn: rect.insetBy(dx: 1, dy: 1)).fill()
            return true
        }
        image.isTemplate = false
        return image
    }
}

/// "Farbe" submenu of a folder: its colour also tints the symbols of what lies in it.
private struct FolderColorMenu: View {
    @Environment(AppModel.self) private var app
    let folder: Folder

    var body: some View {
        Menu("Farbe", systemImage: "paintpalette") {
            ForEach(FolderColor.allCases, id: \.self) { color in
                Toggle(isOn: choice(color)) {
                    Label { Text(color.name) } icon: { Image(nsImage: color.swatch) }
                }
            }
            Divider()
            Toggle("Keine Farbe", isOn: choice(nil))
        }
    }

    /// Menus show a toggle that is on with a checkmark: the folder's current colour.
    private func choice(_ color: FolderColor?) -> Binding<Bool> {
        Binding(get: { folder.color == color }, set: { _ in app.setFolderColor(folder.id, to: color) })
    }
}

/// A folder row that opens and closes, with its chats or skills below. Chats or skills dropped on it move in; a
/// top-level chat folder also takes a dropped folder as its subfolder.
private struct FolderBlock<Rows: View, MenuItems: View>: View {
    @Environment(AppModel.self) private var app
    let folder: Folder
    let count: Int
    let isEmpty: Bool
    let isExpanded: Bool
    let indent: CGFloat
    let dragPrefix: String
    let onDrop: (UUID) -> Void
    let onFolderDrop: ((UUID) -> Void)?
    let emptyHint: String
    @ViewBuilder let menu: MenuItems
    @ViewBuilder let rows: Rows
    @State private var isTargeted = false
    /// Counts up with every drop, so the folder icon gives a little gulp.
    @State private var swallowed = 0

    private var tint: Color { folder.color?.color ?? Theme.accent }

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            SidebarRow(
                id: folder.id,
                title: folder.name,
                isSelected: false,
                indent: indent,
                // Chat folders can be dragged into another folder; skill folders don't nest.
                dragPayload: dragPrefix == SidebarDrag.chat ? SidebarDrag.payload(SidebarDrag.folder, folder.id) : nil,
                onSelect: { withAnimation(.snappy(duration: 0.2)) { app.toggleFolderCollapsed(folder.id) } },
                onRename: { app.renameFolder(folder.id, to: $0) },
                leading: {
                    HStack(spacing: 5) {
                        Image(systemName: "chevron.right")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundStyle(Theme.textTertiary)
                            .rotationEffect(.degrees(isExpanded ? 90 : 0))
                            .frame(width: 10)
                        Image(systemName: isExpanded ? "folder" : "folder.fill")
                            .font(.system(size: 12.5))
                            .foregroundStyle(folder.color?.color ?? (isTargeted ? Theme.accent : Theme.textSecondary))
                            .symbolEffect(.bounce, value: swallowed)
                            .frame(width: 18)
                    }
                },
                trailing: {
                    if count > 0 {
                        Text("\(count)")
                            .font(.system(size: 11, weight: .medium).monospacedDigit())
                            .foregroundStyle(Theme.textTertiary)
                    }
                },
                menu: { menu }
            )
            if isExpanded {
                if isEmpty {
                    Text(emptyHint)
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.textTertiary)
                        .padding(.leading, 43 + indent)
                        .frame(height: 28)
                }
                rows
            }
        }
        .background(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(tint.opacity(isTargeted ? 0.08 : 0))
                .strokeBorder(tint.opacity(isTargeted ? 0.7 : 0), lineWidth: 1.5)
        )
        .dropDestination(for: String.self) { items, _ in
            let ids = SidebarDrag.ids(in: items, prefix: dragPrefix)
            ids.forEach(onDrop)
            var folders: [UUID] = []
            if let onFolderDrop {
                folders = SidebarDrag.ids(in: items, prefix: SidebarDrag.folder).filter { app.canMoveFolder($0, into: folder.id) }
                folders.forEach(onFolderDrop)
            }
            if !ids.isEmpty || !folders.isEmpty { swallowed += 1 }
            return !ids.isEmpty || !folders.isEmpty
        } isTargeted: { targeted in
            withAnimation(.easeOut(duration: 0.12)) { isTargeted = targeted }
        }
    }
}

/// A line in the sidebar (chat, skill or folder): click to open, "…" on hover or right-click for its menu.
private struct SidebarRow<Leading: View, Trailing: View, MenuItems: View>: View {
    @Environment(AppModel.self) private var app
    let id: UUID
    let title: String
    let isSelected: Bool
    let indent: CGFloat
    /// Set for rows that can be dragged into a folder.
    let dragPayload: String?
    let onSelect: () -> Void
    let onRename: (String) -> Void
    @ViewBuilder let leading: Leading
    @ViewBuilder let trailing: Trailing
    @ViewBuilder let menu: MenuItems

    @State private var hovering = false
    @State private var renameText = ""
    @FocusState private var renameFocused: Bool

    private var isRenaming: Bool { app.renamingID == id }

    var body: some View {
        if let dragPayload, !isRenaming {
            row.draggable(dragPayload) {
                Text(title)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(Theme.textPrimary)
                    .lineLimit(1)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Theme.elevated))
            }
        } else {
            row
        }
    }

    private var row: some View {
        HStack(spacing: 6) {
            leading
            if isRenaming {
                TextField("", text: $renameText)
                    .textFieldStyle(.plain)
                    .focused($renameFocused)
                    .onSubmit(commitRename)
                    .onExitCommand { app.renamingID = nil }
                    .task {
                        renameText = title
                        // Focus only after the context menu that started renaming has closed.
                        try? await Task.sleep(for: .milliseconds(120))
                        renameFocused = true
                    }
                    .onChange(of: renameFocused) { _, focused in
                        if !focused { commitRename() }
                    }
            } else {
                Text(title)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: 0)
                // The "…" menu takes the place of the count or activity dot while the pointer is on the row.
                ZStack(alignment: .trailing) {
                    trailing
                        .opacity(hovering ? 0 : 1)
                    Menu { menu } label: {
                        Image(systemName: "ellipsis")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(Theme.textSecondary)
                            .frame(width: 22, height: 22)
                            .contentShape(Rectangle())
                    }
                    .menuStyle(.button)
                    .buttonStyle(.plain)
                    .menuIndicator(.hidden)
                    .fixedSize()
                    .opacity(hovering ? 1 : 0)
                }
            }
        }
        .font(.system(size: 13.5))
        .foregroundStyle(isSelected ? Theme.textPrimary : Theme.textSecondary)
        .padding(.leading, 10 + indent)
        .padding(.trailing, 6)
        .frame(height: 34)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(isSelected ? Theme.selection : (hovering ? Theme.hover : .clear))
        )
        .contentShape(Rectangle())
        .onTapGesture(perform: onSelect)
        .onHover { hovering = $0 }
        .contextMenu { menu }
    }

    private func commitRename() {
        guard app.renamingID == id else { return }
        onRename(renameText)
        app.renamingID = nil
    }
}

struct SearchField: View {
    @Binding var text: String
    let prompt: String

    var body: some View {
        HStack(spacing: 7) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 12))
                .foregroundStyle(Theme.textTertiary)
            TextField("", text: $text, prompt: Text(prompt).foregroundStyle(Theme.textTertiary))
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                .foregroundStyle(Theme.textPrimary)
            if !text.isEmpty {
                Button { text = "" } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.textTertiary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 10)
        .frame(height: 32)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Theme.ink.opacity(0.04)))
        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Theme.border))
    }
}

/// The open library, and a menu to switch to another, make a new one or open one from anywhere.
private struct LibraryMenu: View {
    @Environment(LibrarySession.self) private var session
    @State private var hovering = false

    var body: some View {
        Menu {
            Section("Bibliotheken") {
                ForEach(session.recent) { entry in
                    Button {
                        Task { await session.open(entry.url) }
                    } label: {
                        if session.library.isAt(entry.url) {
                            Label(entry.name, systemImage: "checkmark")
                        } else {
                            Text(entry.isAvailable ? entry.name : "\(entry.name) (nicht verfügbar)")
                        }
                    }
                    .disabled(!entry.isAvailable)
                }
            }
            Divider()
            Button("Neue Bibliothek …", systemImage: "plus") { session.createLibrary() }
            Button("Bibliothek öffnen …", systemImage: "folder") { session.chooseLibrary() }
            Divider()
            Button("„\(session.library.name)“ umbenennen …", systemImage: "pencil") { session.renameLibrary() }
            Button("Im Finder zeigen", systemImage: "magnifyingglass") { session.revealInFinder() }
            let others = session.recent.filter { !session.library.isAt($0.url) }
            if !others.isEmpty {
                Menu("Aus der Liste entfernen") {
                    ForEach(others) { entry in
                        Button(entry.name) { session.forget(entry) }
                    }
                }
            }
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "books.vertical.fill")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Theme.accent)
                    .frame(width: 16)
                Text(session.library.name)
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundStyle(Theme.textPrimary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 0)
                if session.isSwitching {
                    ProgressView().controlSize(.mini)
                } else {
                    Image(systemName: "chevron.up.chevron.down")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(Theme.textTertiary)
                }
            }
            .padding(.horizontal, 8)
            .frame(height: 30)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(hovering ? Theme.hover : Theme.ink.opacity(0.03)))
            .contentShape(Rectangle())
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .onHover { hovering = $0 }
        .onAppear { session.refreshRecent() }
        .help("Bibliothek: \(session.library.url.path)\nChats, Dokumente, Personas, Skills und Einstellungen liegen getrennt in jeder Bibliothek.")
    }
}

private func isPresent<T>(_ item: Binding<T?>) -> Binding<Bool> {
    Binding(get: { item.wrappedValue != nil }, set: { if !$0 { item.wrappedValue = nil } })
}

private struct SidebarFooter: View {
    @Environment(AppModel.self) private var app
    @State private var hoveringSettings = false
    @State private var hoveringConnection = false
    @State private var showsModels = false

    var body: some View {
        VStack(spacing: 0) {
            LibraryMenu()
                .padding(.horizontal, 8)
                .padding(.top, 6)
            connection
        }
        .overlay(alignment: .top) {
            Rectangle().fill(Theme.border).frame(height: 1)
        }
    }

    private var connection: some View {
        HStack(spacing: 10) {
            // Opening the model list also checks the connection again.
            Button { showsModels.toggle() } label: {
                HStack(spacing: 10) {
                    StatusDot(color: app.connection.color)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(title)
                            .font(.system(size: 12.5, weight: .medium))
                            .foregroundStyle(Theme.textPrimary)
                        Text(subtitle)
                            .font(.system(size: 11))
                            .foregroundStyle(Theme.textTertiary)
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }
                }
                .padding(.horizontal, 6)
                .padding(.vertical, 4)
                .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(hoveringConnection || showsModels ? Theme.hover : .clear))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .onHover { hoveringConnection = $0 }
            .help(app.currentModel.map { "Modell: \($0.displayName) – klicken, um ein anderes zu wählen" } ?? "Modell wählen")
            .popover(isPresented: $showsModels, arrowEdge: .top) {
                ModelPickerPanel { showsModels = false }
                    .environment(app)
            }
            .onChange(of: showsModels) { _, open in
                if open { Task { await app.refreshModels() } }
            }

            Spacer(minLength: 0)

            SettingsLink {
                Image(systemName: "gearshape")
                    .font(.system(size: 14))
                    .foregroundStyle(hoveringSettings ? Theme.textPrimary : Theme.textSecondary)
                    .frame(width: 30, height: 30)
                    .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(hoveringSettings ? Theme.hover : .clear))
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .onHover { hoveringSettings = $0 }
            .help("Einstellungen (⌘,)")
        }
        .padding(.leading, 8)
        .padding(.trailing, 14)
        .frame(height: 52)
    }

    /// The model the chats and documents use; the green dot alone says the connection stands.
    private var title: String {
        switch app.connection {
        case .connecting: "Verbinde mit \(app.provider.label)…"
        case .failed: "\(app.provider.label) nicht erreichbar"
        case .connected:
            if let model = app.currentModel { model.displayName }
            else if let id = app.currentModelId { id }
            else { "Kein Modell geladen" }
        }
    }

    private var subtitle: String {
        switch app.connection {
        case .connected:
            guard let model = app.currentModel else { return "\(app.hostDescription) · Modell wählen" }
            var parts: [String] = []
            if let quantization = model.quantization { parts.append(quantization) }
            if let context = model.loadedContextLength ?? model.maxContextLength {
                parts.append("\(LMModel.formatTokens(context)) Kontext")
            }
            if !model.isLoaded { parts.append("nicht geladen") }
            let others = app.loadedModels.filter { $0.id != model.id }.count
            if others > 0 { parts.append("+\(others) geladen") }
            return parts.isEmpty ? app.hostDescription : parts.joined(separator: " · ")
        case .connecting:
            return app.hostDescription
        case .failed(let message):
            return message
        }
    }
}

// MARK: Projects

/// The category "Projekte" above the folders: every project page with its own symbol and colour. A chat or document
/// dragged onto a project is linked to it; it stays where it is in the list.
private struct ProjectSidebarSection: View {
    @Environment(AppModel.self) private var app
    /// The alert lives on the list: an alert hung on an EmptyView inside a LazyVStack is never rendered.
    let onDelete: (Project) -> Void

    var body: some View {
        let query = app.chatSearchQuery
        let projects = app.projects.projects.filter { $0.matches(query) }
        let collapsed = app.projectsSectionCollapsed && query.isEmpty
        if !app.projects.projects.isEmpty || query.isEmpty {
            HStack(spacing: 6) {
                Button {
                    withAnimation(.snappy(duration: 0.2)) { app.projectsSectionCollapsed.toggle() }
                } label: {
                    HStack(spacing: 5) {
                        Text("Projekte")
                            .font(.system(size: 11.5, weight: .semibold))
                        Image(systemName: "chevron.right")
                            .font(.system(size: 8.5, weight: .bold))
                            .rotationEffect(.degrees(collapsed ? 0 : 90))
                        if collapsed, !projects.isEmpty {
                            Text("\(projects.count)")
                                .font(.system(size: 10.5, weight: .semibold).monospacedDigit())
                        }
                    }
                    .foregroundStyle(Theme.textTertiary)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(collapsed ? "Projekte zeigen" : "Projekte einklappen")
                Spacer(minLength: 0)
                IconButton(systemName: "plus", help: "Neues Projekt", size: 11, frameSize: 20) {
                    app.searchText = ""
                    app.newProject()
                }
            }
            .padding(.leading, 10)
            .padding(.trailing, 4)
            .padding(.top, 8)
            .padding(.bottom, 2)
            if !collapsed {
                ForEach(projects) { project in
                    ProjectSidebarRow(project: project) { onDelete(project) }
                }
                if projects.isEmpty && query.isEmpty {
                    Button {
                        app.newProject()
                    } label: {
                        HStack(spacing: 8) {
                            Image(systemName: Project.sidebarSymbol)
                                .font(.system(size: 12))
                                .frame(width: 18)
                            Text("Neues Projekt anlegen")
                                .font(.system(size: 12.5))
                            Spacer(minLength: 0)
                        }
                        .foregroundStyle(Theme.textTertiary)
                        .padding(.horizontal, 10)
                        .frame(height: 30)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(StoryRowButtonStyle())
                }
            }
        }
    }
}

private struct ProjectSidebarRow: View {
    @Environment(AppModel.self) private var app
    @Environment(\.undoManager) private var undoManager
    let project: Project
    let onDelete: () -> Void
    @State private var targeted = false

    var body: some View {
        let progress = project.overallProgress
        SidebarRow(
            id: project.id,
            title: project.displayTitle,
            isSelected: app.openProjectID == project.id,
            indent: 0,
            dragPayload: nil,
            onSelect: { app.openProject(project.id) },
            onRename: { title in
                let title = title.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !title.isEmpty else { return }
                app.projects.change(project.id, "Projekt umbenennen", undo: undoManager) { $0.title = title }
            },
            leading: {
                ProjectBadge(project: project, size: 18)
                    .opacity(project.status == .done ? 0.55 : 1)
                    .help("Projekt (\(project.status.title))")
            },
            trailing: {
                if progress.total > 0 {
                    NoteMiniRing(progress: progress, size: 14)
                        .help("\(progress.percent) % – \(progress.label)")
                }
            },
            menu: {
                Button("Projektseite öffnen", systemImage: ProjectTab.page.symbol) { app.openProject(project.id, tab: .page) }
                Button("Aufgaben öffnen", systemImage: ProjectTab.board.symbol) { app.openProject(project.id, tab: .board) }
                Divider()
                Button("Umbenennen", systemImage: "pencil") { app.renamingID = project.id }
                Menu("Status", systemImage: project.status.symbol) {
                    ForEach(ProjectStatus.allCases) { status in
                        Button(status.title, systemImage: status.symbol) {
                            app.projects.change(project.id, "Status ändern", undo: undoManager) { $0.status = status }
                        }
                    }
                }
                Menu("Farbe", systemImage: "paintpalette") {
                    ForEach(FolderColor.allCases, id: \.self) { color in
                        Button { app.projects.change(project.id, "Farbe ändern", undo: undoManager) { $0.color = color } } label: {
                            Label { Text(color.name) } icon: { Image(nsImage: color.swatch) }
                        }
                    }
                }
                Divider()
                Button("Löschen …", systemImage: "trash", role: .destructive, action: onDelete)
            }
        )
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(targeted ? project.color.color : .clear, lineWidth: 1.5))
        .dropDestination(for: String.self) { items, _ in
            let ids = SidebarDrag.ids(in: items, prefix: SidebarDrag.chat)
            let refs: [ProjectRef] = ids.compactMap { id in
                if app.document(id) != nil { return .document(id) }
                if app.chat(id) != nil { return .chat(id) }
                return nil
            }
            guard !refs.isEmpty else { return false }
            app.projects.change(project.id, "Mit Projekt verknüpfen", undo: undoManager) { project in
                for ref in refs where !project.links.contains(ref) { project.links.append(ref) }
            }
            return true
        } isTargeted: { targeted = $0 }
        .help("Chats und Dokumente hierher ziehen, um sie mit dem Projekt zu verknüpfen")
    }
}
