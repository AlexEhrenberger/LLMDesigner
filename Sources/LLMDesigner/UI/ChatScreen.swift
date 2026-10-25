import SwiftUI
import UniformTypeIdentifiers

struct ChatScreen: View {
    @Environment(AppModel.self) private var app
    @State private var isDropTarget = false

    var body: some View {
        VStack(spacing: 0) {
            TopBar()
            if let chat = app.selectedChat, !chat.messages.isEmpty {
                MessageList(
                    chat: chat,
                    streamingID: app.streamingMessageIDs[chat.id],
                    exportingIDs: app.exportingIDs,
                    scrollRequest: app.scrollRequest,
                    highlight: app.highlightedTarget
                )
                    .id(chat.id)
                ComposerArea()
            } else {
                EmptyChatView()
            }
        }
        .background(Theme.background)
        .onDrop(of: [.fileURL, .image], isTargeted: $isDropTarget, perform: dropImages)
        .overlay {
            if isDropTarget { DropHint() }
        }
        .animation(.easeOut(duration: 0.15), value: isDropTarget)
    }

    /// Pictures dropped anywhere on the chat go into the composer.
    private func dropImages(_ providers: [NSItemProvider]) -> Bool {
        guard !providers.isEmpty else { return false }
        Task {
            var sources: [AttachmentStore.Source] = []
            for provider in providers {
                if let source = await Self.source(from: provider) { sources.append(source) }
            }
            if !sources.isEmpty { app.attachImages(sources) }
        }
        return true
    }

    private static func source(from provider: NSItemProvider) async -> AttachmentStore.Source? {
        if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
            let url: URL? = await withCheckedContinuation { continuation in
                _ = provider.loadObject(ofClass: URL.self) { url, _ in continuation.resume(returning: url) }
            }
            return url.map { .file($0) }
        }
        if provider.hasItemConformingToTypeIdentifier(UTType.image.identifier) {
            let data: Data? = await withCheckedContinuation { continuation in
                _ = provider.loadDataRepresentation(forTypeIdentifier: UTType.image.identifier) { data, _ in
                    continuation.resume(returning: data)
                }
            }
            return data.map { .data($0) }
        }
        return nil
    }
}

private struct DropHint: View {
    var body: some View {
        RoundedRectangle(cornerRadius: 18, style: .continuous)
            .fill(Theme.accent.opacity(0.06))
            .overlay(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .strokeBorder(Theme.accent.opacity(0.7), style: StrokeStyle(lineWidth: 1.5, dash: [8, 6]))
            )
            .overlay {
                Label("Bilder hier ablegen", systemImage: "photo.on.rectangle.angled")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Theme.accent)
            }
            .padding(14)
            .allowsHitTesting(false)
            .transition(.opacity)
    }
}

private struct TopBar: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        HStack(spacing: 2) {
            if !app.isSidebarDocked {
                SidebarToggleButton()
                IconButton(systemName: "square.and.pencil", help: "Neuer Chat (⌘N)", frameSize: Theme.titleBarControlSize) { app.newChat() }
                    .padding(.trailing, 6)
            }
            Spacer(minLength: 0)
            if let chat = app.selectedChat, !chat.messages.isEmpty {
                ChatExportControls(chat: chat)
                if !app.isOutlinePanelShown && app.showsSidePanel(for: chat) {
                    IconButton(systemName: "sidebar.right", help: "Inhaltsverzeichnis einblenden", frameSize: Theme.titleBarControlSize) {
                        app.toggleOutlinePanel()
                    }
                    .padding(.leading, 4)
                }
            }
        }
        .padding(.leading, app.isSidebarDocked ? 14 : Theme.trafficLightInset)
        .padding(.trailing, 14)
        .frame(height: Theme.titleBarHeight)
        .padding(.bottom, Theme.topBarBottomPadding)
        .background(WindowDragArea())
    }
}

/// Always-visible actions for the whole chat: copy as text and export as PDF, with or without table of contents.
private struct ChatExportControls: View {
    @Environment(AppModel.self) private var app
    let chat: Chat
    @State private var hovering = false

    var body: some View {
        let isExporting = app.exportingIDs.contains(chat.id)
        HStack(spacing: 4) {
            CopyButton(help: "Ganzen Chat als Text kopieren", size: 13, frameSize: Theme.titleBarControlSize) {
                app.transcript(of: chat)
            }
            Menu {
                Button("Chat exportieren …", systemImage: "doc.text") {
                    app.exportChat(withOutline: false)
                }
                Button("Chat mit Inhaltsverzeichnis exportieren …", systemImage: "list.bullet.rectangle") {
                    app.exportChat(withOutline: true)
                }
            } label: {
                HStack(spacing: 6) {
                    if isExporting {
                        ProgressView().controlSize(.mini)
                    } else {
                        Image(systemName: "square.and.arrow.up")
                            .font(.system(size: 12.5, weight: .medium))
                    }
                    Text(progressText ?? "Chat exportieren")
                        .font(.system(size: 12.5, weight: .medium))
                    if !isExporting {
                        Image(systemName: "chevron.down")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundStyle(Theme.textTertiary)
                    }
                }
                .foregroundStyle(hovering ? Theme.textPrimary : Theme.textSecondary)
                .padding(.horizontal, 10)
                .frame(height: Theme.titleBarControlSize)
                .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(hovering ? Theme.hover : Color.white.opacity(0.04)))
                .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Theme.border))
                .contentShape(Rectangle())
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
            .fixedSize()
            .onHover { hovering = $0 }
            .disabled(isExporting || app.isGenerating)
            .help(app.isGenerating ? "Warte, bis die Antwort fertig ist" : "Ganzen Chat als PDF exportieren")
        }
    }

    private var progressText: String? {
        guard app.exportingIDs.contains(chat.id) else { return nil }
        return app.outlineGeneratingIDs.contains(chat.id) ? "Erstelle Inhaltsverzeichnis …" : "Erstelle PDF …"
    }
}

private struct MessageList: View {
    @Environment(AppModel.self) private var app
    let chat: Chat
    let streamingID: ChatMessage.ID?
    let exportingIDs: Set<UUID>
    let scrollRequest: ScrollRequest?
    let highlight: OutlineTarget?

    @State private var position = ScrollPosition(edge: .bottom)
    @State private var following = true

    var body: some View {
        ScrollViewReader { proxy in
            messages
                .onChange(of: scrollRequest) { _, request in
                    guard let request, chat.messages.contains(where: { $0.id == request.target.messageID }) else { return }
                    following = false
                    withAnimation(.smooth(duration: 0.45)) {
                        proxy.scrollTo(request.target.viewID, anchor: .top)
                    }
                }
        }
    }

    private var messages: some View {
        let persona = app.persona(of: chat)
        return ScrollView {
            // Deliberately not lazy: LazyVStack's height estimates fight the bottom scroll anchor
            // and send SwiftUI into an endless layout loop (beachball) once the user scrolls up.
            VStack(alignment: .leading, spacing: 28) {
                if let branch = chat.branch, branch.lastCopiedMessageID == nil {
                    BranchDivider(branch: branch)
                }
                ForEach(chat.messages) { message in
                    MessageRow(
                        message: message,
                        isStreaming: message.id == streamingID,
                        isLast: message.id == chat.messages.last?.id,
                        isExporting: exportingIDs.contains(message.id),
                        highlight: highlight?.messageID == message.id ? highlight : nil,
                        marks: marks(for: message.id),
                        speech: app.speakingMessageID == message.id ? app.speechState : nil,
                        isEditing: app.editingMessageID == message.id,
                        persona: persona
                    )
                    .equatable()
                    .scrollAnchor(OutlineTarget.viewID(message.id, nil))
                    .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { frame in
                        app.setMessageFrame(frame, for: message.id)
                    }
                    // Everything above was copied from the chat this one branched off.
                    if let branch = chat.branch, branch.lastCopiedMessageID == message.id {
                        BranchDivider(branch: branch)
                    }
                }
            }
            .frame(maxWidth: Theme.contentWidth)
            .padding(.horizontal, 28)
            .padding(.top, 12)
            .padding(.bottom, 28)
            .frame(maxWidth: .infinity)
        }
        .scrollPosition($position)
        .defaultScrollAnchor(.bottom)
        .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { frame in
            app.setMessageViewport(frame)
        }
        .onScrollPhaseChange { _, phase, context in
            // Only the user's own scrolling decides whether we keep following the stream.
            if phase == .idle {
                following = Self.isNearBottom(context.geometry)
            }
        }
        .onScrollGeometryChange(for: Bool.self, of: Self.isNearBottom) { _, nearBottom in
            if nearBottom { following = true }
        }
        .onChange(of: chat.messages.last?.content) { scrollIfFollowing() }
        .onChange(of: chat.messages.last?.reasoning) { scrollIfFollowing() }
        .onChange(of: chat.messages.last?.toolSteps) { scrollIfFollowing() }
        .onChange(of: chat.messages.count) {
            following = true
            position.scrollTo(edge: .bottom)
        }
        .overlay(alignment: .bottom) {
            if !following {
                Button {
                    following = true
                    withAnimation(.smooth) { position.scrollTo(edge: .bottom) }
                } label: {
                    Image(systemName: "arrow.down")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Theme.textPrimary)
                        .frame(width: 34, height: 34)
                        .background(Circle().fill(Theme.elevated))
                        .overlay(Circle().strokeBorder(Theme.strongBorder))
                        .shadow(color: .black.opacity(0.5), radius: 10, y: 4)
                }
                .buttonStyle(.plain)
                .padding(.bottom, 12)
                .transition(.opacity.combined(with: .scale(scale: 0.8)))
            }
        }
        .animation(.easeOut(duration: 0.15), value: following)
    }

    private func marks(for messageID: ChatMessage.ID) -> BookmarkMarks {
        var marks = BookmarkMarks()
        for bookmark in chat.bookmarks ?? [] where bookmark.target.messageID == messageID {
            if let block = bookmark.target.block { marks.blocks.insert(block) } else { marks.wholeMessage = true }
        }
        return marks
    }

    private func scrollIfFollowing() {
        if following { position.scrollTo(edge: .bottom) }
    }

    private static func isNearBottom(_ geometry: ScrollGeometry) -> Bool {
        geometry.contentOffset.y + geometry.containerSize.height >= geometry.contentSize.height - 60
    }
}

/// Line where a branched chat leaves the chat it was copied from; a click goes back there.
private struct BranchDivider: View {
    @Environment(AppModel.self) private var app
    let branch: ChatBranch
    @State private var hovering = false

    var body: some View {
        let sourceTitle = app.chatTitle(branch.sourceChatID)
        let isAvailable = sourceTitle != nil
        HStack(spacing: 12) {
            line
            Button { app.openBranchSource(branch) } label: {
                HStack(spacing: 6) {
                    Image(systemName: "arrow.triangle.branch")
                        .font(.system(size: 11, weight: .semibold))
                    Text(label(sourceTitle))
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(hovering && isAvailable ? Theme.accent : Theme.textTertiary)
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
                .background(Capsule().fill(hovering && isAvailable ? Theme.hover : .clear))
                .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .disabled(!isAvailable)
            .onHover { hovering = $0 }
            .help(isAvailable ? "Zur Stelle im ursprünglichen Chat springen" : "Der ursprüngliche Chat wurde gelöscht")
            .layoutPriority(1)
            line
        }
    }

    private var line: some View {
        Rectangle().fill(Theme.border).frame(height: 1)
    }

    private func label(_ sourceTitle: String?) -> String {
        var text = "Abgezweigt von „\(sourceTitle ?? branch.sourceTitle)“"
        if sourceTitle == nil { text += " (gelöscht)" }
        if branch.editedQuestion == true { text += " · Frage bearbeitet" }
        return text
    }
}

private struct ComposerArea: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        @Bindable var app = app

        VStack(spacing: 8) {
            ComposerView(
                text: $app.draft,
                placeholder: placeholder,
                isGenerating: app.isGenerating,
                canSend: app.canSend,
                focusToken: app.selectedChatID,
                onSend: app.send,
                onStop: app.stop
            )
            ComposerFootnote()
        }
        .frame(maxWidth: Theme.contentWidth + 16)
        .padding(.horizontal, 20)
        .padding(.bottom, 12)
        .frame(maxWidth: .infinity)
        .background(alignment: .top) {
            LinearGradient(colors: [Theme.background.opacity(0), Theme.background], startPoint: .top, endPoint: .bottom)
                .frame(height: 24)
                .offset(y: -24)
                .allowsHitTesting(false)
        }
    }

    private var placeholder: String {
        if let persona = app.activePersona { return "Nachricht an \(persona.displayName)" }
        if let model = app.currentModel { return "Nachricht an \(model.displayName)" }
        return "Nachricht schreiben"
    }
}

/// Under the composer: memory and context of the chat, and on the right a short notice when there is one
/// (e.g. Qwen TTS not reachable) and the applications menu.
private struct ComposerFootnote: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        HStack(spacing: 12) {
            ChatSetupBar()
            Spacer(minLength: 0)
            if let notice = app.notice {
                Text(notice)
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.warning)
                    .lineLimit(2)
                    .multilineTextAlignment(.trailing)
            }
            ApplicationMenu()
        }
        .padding(.horizontal, 4)
    }
}

private struct EmptyChatView: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        @Bindable var app = app

        VStack(spacing: 0) {
            Spacer(minLength: 24)

            if let persona = app.activePersona {
                PersonaWelcome(persona: persona) { modelSummary }
                    .padding(.bottom, 26)
            } else {
                VStack(spacing: 14) {
                    LogoMark(size: 54)
                    Text("Was entwerfen wir heute?")
                        .font(.system(size: 30, weight: .semibold))
                        .foregroundStyle(Theme.textPrimary)
                    modelSummary
                }
                .padding(.bottom, 30)
            }

            if case .failed(let message) = app.connection {
                ConnectionHelpCard(message: message)
                    .padding(.bottom, 16)
            }

            ComposerView(
                text: $app.draft,
                placeholder: placeholder,
                isGenerating: false,
                canSend: app.canSend,
                focusToken: "new-chat",
                onSend: app.send,
                onStop: app.stop
            )
            ComposerFootnote()
                .padding(.top, 8)

            Spacer(minLength: 24)
            Spacer(minLength: 0)
        }
        .frame(maxWidth: 720)
        .padding(.horizontal, 28)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var placeholder: String {
        if let persona = app.activePersona { return "Nachricht an \(persona.displayName)" }
        return app.currentModel.map { "Nachricht an \($0.displayName)" } ?? "Nachricht schreiben"
    }

    @ViewBuilder
    private var modelSummary: some View {
        if let model = app.currentModel {
            HStack(spacing: 6) {
                StatusDot(color: model.isLoaded ? Theme.success : Theme.warning, size: 6)
                Text(summary(for: model))
            }
            .font(.system(size: 13))
            .foregroundStyle(Theme.textSecondary)
        } else if app.connection == .connected {
            Text("Lade ein Modell in LM Studio, um loszulegen.")
                .font(.system(size: 13))
                .foregroundStyle(Theme.textSecondary)
        }
    }

    private func summary(for model: LMModel) -> String {
        var parts = [model.displayName]
        if let quantization = model.quantization { parts.append(quantization) }
        if let context = model.loadedContextLength ?? model.maxContextLength {
            parts.append("\(LMModel.formatTokens(context)) Kontext")
        }
        if !model.isLoaded { parts.append("wird beim Senden geladen") }
        return parts.joined(separator: " · ")
    }
}

private struct ConnectionHelpCard: View {
    @Environment(AppModel.self) private var app
    let message: String

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "bolt.horizontal.circle")
                .font(.system(size: 18))
                .foregroundStyle(Theme.danger)
            VStack(alignment: .leading, spacing: 4) {
                Text("LM Studio ist unter \(app.hostDescription) nicht erreichbar")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Theme.textPrimary)
                Text("Starte in LM Studio den lokalen Server (Developer → Start Server) oder passe den Endpoint in den Einstellungen an.")
                    .font(.system(size: 12.5))
                    .foregroundStyle(Theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                Text(message)
                    .font(.system(size: 11.5))
                    .foregroundStyle(Theme.textTertiary)
            }
            Spacer(minLength: 0)
            Button("Erneut versuchen") { Task { await app.refreshModels() } }
                .buttonStyle(.plain)
                .font(.system(size: 12.5, weight: .medium))
                .foregroundStyle(Theme.textPrimary)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Theme.elevated))
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Theme.danger.opacity(0.07)))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Theme.danger.opacity(0.25)))
    }
}
