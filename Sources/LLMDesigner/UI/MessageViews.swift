import SwiftUI

/// Where the user's bookmarks sit in one message.
struct BookmarkMarks: Equatable {
    var blocks: Set<Int> = []
    var wholeMessage = false
}

struct MessageRow: View, Equatable {
    let message: ChatMessage
    let isStreaming: Bool
    let isLast: Bool
    let isExporting: Bool
    /// Table-of-contents target inside this message that was just jumped to.
    let highlight: OutlineTarget?
    let marks: BookmarkMarks
    /// Read-aloud state if this message is being read.
    let speech: SpeechReader.State?
    /// The user is editing this question.
    let isEditing: Bool
    /// The persona that answers in this chat; its picture and name stand above each answer.
    var persona: Persona? = nil

    @Environment(AppModel.self) private var app

    static func == (lhs: MessageRow, rhs: MessageRow) -> Bool {
        lhs.message == rhs.message && lhs.isStreaming == rhs.isStreaming && lhs.isLast == rhs.isLast
            && lhs.isExporting == rhs.isExporting && lhs.highlight == rhs.highlight && lhs.marks == rhs.marks
            && lhs.speech == rhs.speech && lhs.isEditing == rhs.isEditing && lhs.persona == rhs.persona
    }

    var body: some View {
        switch message.role {
        case .user:
            UserMessageView(
                message: message,
                isHighlighted: highlight != nil,
                isBookmarked: marks.wholeMessage,
                isEditing: isEditing,
                onEdit: { app.startEditing(message.id) }
            )
        case .assistant:
            AssistantMessageView(
                message: message,
                persona: persona,
                isStreaming: isStreaming,
                isLast: isLast,
                isExporting: isExporting,
                highlight: highlight,
                marks: marks,
                speech: speech,
                onRegenerate: { app.regenerate() },
                onSpeak: { app.toggleSpeaking(message.id) },
                onExport: { app.exportAnswer(message.id) },
                onBranch: { app.branchChat(at: message.id) },
                onFollowUp: { app.sendFollowUp($0) }
            )
        case .system:
            EmptyView()
        }
    }
}

private struct UserMessageView: View {
    let message: ChatMessage
    let isHighlighted: Bool
    let isBookmarked: Bool
    let isEditing: Bool
    let onEdit: () -> Void
    @State private var hovering = false

    var body: some View {
        VStack(alignment: .trailing, spacing: 6) {
            if isEditing {
                MessageEditor(message: message)
            } else {
                if let images = message.images, !images.isEmpty {
                    MessageImageGallery(images: images)
                }
                if !message.content.isEmpty {
                    bubble
                }
                // Always there, faint until hovered: buttons hidden completely did not reliably take clicks.
                HStack(spacing: 0) {
                    if !message.content.isEmpty {
                        CopyButton(text: message.content, help: "Nachricht kopieren")
                    }
                    IconButton(systemName: "pencil", help: "Bearbeiten und als neuen Chat abzweigen", size: 12.5, action: onEdit)
                }
                .opacity(hovering ? 1 : 0.35)
                .animation(.easeOut(duration: 0.12), value: hovering)
            }
        }
        .frame(maxWidth: .infinity, alignment: .trailing)
        .padding(.leading, isEditing ? 0 : 90)
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
    }

    private var bubble: some View {
        Text(message.content)
            .font(.system(size: 15))
            .lineSpacing(3)
            .foregroundStyle(Theme.textPrimary)
            .textSelection(.enabled)
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(RoundedRectangle(cornerRadius: 20, style: .continuous).fill(Theme.userBubble))
            .overlay(
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .strokeBorder(Theme.accent.opacity(isHighlighted ? 0.8 : 0), lineWidth: 1.5)
            )
            .animation(.easeOut(duration: 0.5), value: isHighlighted)
            .overlay(alignment: .topLeading) {
                if isBookmarked { BookmarkGlyph().offset(x: -18, y: 12) }
            }
    }
}

/// Edits a sent question in place. Sending asks it again in a new chat that branches off here;
/// the original chat stays as it is.
private struct MessageEditor: View {
    @Environment(AppModel.self) private var app
    let message: ChatMessage
    @State private var text: String
    @State private var images: [ImageAttachment]
    @State private var importing = 0
    @State private var height: CGFloat = 20

    init(message: ChatMessage) {
        self.message = message
        _text = State(initialValue: message.content)
        _images = State(initialValue: message.images ?? [])
    }

    private var canSend: Bool {
        (!text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !images.isEmpty) && importing == 0
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if !images.isEmpty || importing > 0 {
                AttachmentStrip(images: images, importing: importing) { id in
                    images.removeAll { $0.id == id }
                }
            }
            ComposerTextView(
                text: $text,
                height: $height,
                focusToken: message.id,
                onSubmit: submit,
                onImages: addImages,
                onCancel: app.cancelEditing
            )
            .frame(height: min(max(height, 20), 320))

            HStack(spacing: 8) {
                Label("Wird als neuer Chat abgezweigt", systemImage: "arrow.triangle.branch")
                    .font(.system(size: 11.5))
                    .foregroundStyle(Theme.textTertiary)
                Spacer(minLength: 0)
                Button("Abbrechen", action: app.cancelEditing)
                    .buttonStyle(PillButtonStyle(prominent: false))
                    .help("Abbrechen (esc)")
                Button("Senden", action: submit)
                    .buttonStyle(PillButtonStyle(prominent: true))
                    .disabled(!canSend)
                    .help("Senden (⏎)")
            }
        }
        .padding(.top, 14)
        .padding(.horizontal, 16)
        .padding(.bottom, 12)
        .background(RoundedRectangle(cornerRadius: 20, style: .continuous).fill(Theme.userBubble))
        .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous).strokeBorder(Theme.accent.opacity(0.45)))
    }

    private func submit() {
        guard canSend else { return }
        app.submitEdit(of: message.id, text: text, images: images)
    }

    private func addImages(_ sources: [AttachmentStore.Source]) {
        importing += sources.count
        Task {
            let added = await app.importImages(sources)
            importing -= sources.count
            images += added
        }
    }
}

private struct PillButtonStyle: ButtonStyle {
    let prominent: Bool
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12.5, weight: .medium))
            .foregroundStyle(prominent ? Color.black : Theme.textPrimary)
            .padding(.horizontal, 13)
            .padding(.vertical, 6)
            .background(Capsule().fill(prominent ? Theme.textPrimary : Theme.elevated))
            .overlay(Capsule().strokeBorder(prominent ? Color.clear : Theme.strongBorder))
            .opacity(isEnabled ? (configuration.isPressed ? 0.75 : 1) : 0.4)
            .contentShape(Capsule())
    }
}

private struct AssistantMessageView: View {
    let message: ChatMessage
    let persona: Persona?
    let isStreaming: Bool
    let isLast: Bool
    let isExporting: Bool
    let highlight: OutlineTarget?
    let marks: BookmarkMarks
    let speech: SpeechReader.State?
    let onRegenerate: () -> Void
    let onSpeak: () -> Void
    let onExport: () -> Void
    let onBranch: () -> Void
    let onFollowUp: (String) -> Void
    @State private var hovering = false

    var body: some View {
        let steps = message.toolSteps ?? []
        let isLookingUp = isStreaming && steps.contains { $0.status == .running }
        VStack(alignment: .leading, spacing: 12) {
            if let persona {
                HStack(spacing: 9) {
                    PersonaAvatar(persona: persona, size: 26)
                    Text(persona.displayName)
                        .font(.system(size: 13.5, weight: .semibold))
                        .foregroundStyle(Theme.textPrimary)
                }
                .padding(.bottom, -2)
            }

            if let thalamus = message.thalamus {
                ThalamusTraceView(trace: thalamus)
            }

            if let reasoning = message.reasoning, !reasoning.isEmpty {
                ThinkingView(
                    text: reasoning,
                    isThinking: isStreaming && message.content.isEmpty && !isLookingUp,
                    seconds: message.stats?.reasoningSeconds,
                    startedAt: message.createdAt
                )
            }

            if !steps.isEmpty {
                ToolStepsView(steps: steps, isStreaming: isStreaming)
            }

            if !message.content.isEmpty {
                MarkdownView(
                    text: message.content,
                    anchorMessageID: message.id,
                    highlightedBlock: highlight?.block,
                    bookmarkedBlocks: marks.blocks
                )
            } else if isStreaming && !isLookingUp && (message.reasoning ?? "").isEmpty && message.thalamus?.status != .running {
                PulsingDot()
                    .padding(.vertical, 4)
            }

            if let error = message.error {
                ErrorBanner(text: error, onRetry: isLast ? onRegenerate : nil)
            }

            if !isStreaming {
                footer
                    .opacity(isLast || hovering || isExporting ? 1 : 0)
            }

            // Suggestions only make sense under the latest answer.
            if isLast && !isStreaming, let followUps = message.followUps, !followUps.isEmpty {
                FollowUpList(questions: followUps, onSelect: onFollowUp)
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay(alignment: .topLeading) {
            if marks.wholeMessage { BookmarkGlyph().offset(x: -20, y: 4) }
        }
        .background {
            // Jump target from the table of contents: the whole answer lights up briefly.
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Theme.accent.opacity(highlight != nil && highlight?.block == nil ? 0.1 : 0))
                .padding(-10)
                .animation(.easeOut(duration: 0.5), value: highlight)
        }
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
    }

    private var footer: some View {
        HStack(spacing: 0) {
            if !message.content.isEmpty {
                CopyButton(text: message.content, help: "Antwort kopieren")
                if isExporting {
                    ProgressView()
                        .controlSize(.small)
                        .frame(width: 32, height: 32)
                        .help("PDF wird mit LaTeX gesetzt …")
                } else {
                    IconButton(systemName: "arrow.down.doc", help: "Antwort als PDF exportieren", size: 12.5, action: onExport)
                }
                SpeakButton(state: speech, action: onSpeak)
                IconButton(systemName: "arrow.triangle.branch", help: "Ab hier in neuem Chat abzweigen", size: 12.5, action: onBranch)
            }
            if isLast {
                IconButton(systemName: "arrow.clockwise", help: "Neu generieren (⇧⌘R)", size: 12.5, action: onRegenerate)
            }
            Text(statsLine)
                .font(.system(size: 11.5))
                .foregroundStyle(Theme.textTertiary)
                .lineLimit(1)
                .padding(.leading, 6)
        }
        .padding(.leading, -8)
    }

    private var statsLine: String {
        var parts: [String] = []
        if let model = message.model {
            parts.append(model.split(separator: "/").last.map(String.init) ?? model)
        }
        if let stats = message.stats {
            if let speed = stats.tokensPerSecond {
                parts.append("\(speed.formatted(.number.precision(.fractionLength(1)))) tok/s")
            }
            if let tokens = stats.completionTokens {
                parts.append("\(tokens) Tokens")
            }
            if let ttft = stats.timeToFirstToken {
                parts.append("\(ttft.formatted(.number.precision(.fractionLength(2)))) s bis zum ersten Token")
            }
        }
        if message.stopped == true { parts.append("gestoppt") }
        return parts.joined(separator: "  ·  ")
    }
}

/// The web, Wikipedia and file lookups behind an answer. Collapsed it says what is happening right now
/// or what was looked up; expanded it lists every step with its sources as links.
private struct ToolStepsView: View {
    let steps: [ToolStep]
    let isStreaming: Bool
    @State private var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Button {
                withAnimation(.snappy(duration: 0.2)) { expanded.toggle() }
            } label: {
                HStack(spacing: 6) {
                    if steps.allSatisfy(\.kind.isFile) {
                        Image(systemName: "doc.text.magnifyingglass")
                            .font(.system(size: 12))
                    } else if isWikipediaOnly {
                        Text("W").font(.system(size: 13, weight: .semibold, design: .serif))
                    } else {
                        Image(systemName: "globe")
                            .font(.system(size: 12))
                    }
                    label
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Image(systemName: "chevron.right")
                        .font(.system(size: 9, weight: .bold))
                        .rotationEffect(.degrees(expanded ? 90 : 0))
                }
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(Theme.textSecondary)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if expanded {
                VStack(alignment: .leading, spacing: 12) {
                    ForEach(steps) { step in
                        ToolStepRow(step: step)
                    }
                }
                .padding(.leading, 14)
                .overlay(alignment: .leading) {
                    Rectangle().fill(Theme.strongBorder).frame(width: 2)
                }
            }
        }
    }

    @ViewBuilder
    private var label: some View {
        if isStreaming, let running = steps.last(where: { $0.status == .running }) {
            Text(Self.activity(running))
                .phaseAnimator([false, true]) { content, phase in
                    content.opacity(phase ? 1 : 0.45)
                } animation: { _ in .easeInOut(duration: 0.9) }
        } else {
            Text(summary)
        }
    }

    private var isWikipediaOnly: Bool { steps.allSatisfy(\.kind.isWikipedia) }

    private var summary: String {
        func count(_ kinds: Set<ToolStep.Kind>) -> Int {
            steps.filter { kinds.contains($0.kind) && $0.status == .done }.count
        }
        let searches = count([.search, .wikiSearch, .fileSearch])
        let pages = count([.openPage])
        let articles = count([.wikiArticle])
        let files = count([.fileRead])
        let failed = steps.filter { $0.status == .failed }.count
        let usesWeb = steps.contains { !$0.kind.isWikipedia && !$0.kind.isFile }
        let usesWikipedia = steps.contains(where: \.kind.isWikipedia)
        let usesFiles = steps.contains(where: \.kind.isFile)
        var places: [String] = []
        if usesFiles { places.append("Dateien") }
        if usesWeb { places.append(usesWikipedia || usesFiles ? "Web" : "Websuche") }
        if usesWikipedia { places.append("Wikipedia") }
        var parts = [places.joined(separator: " & ")]
        if searches > 0 { parts.append(searches == 1 ? "1 Suche" : "\(searches) Suchen") }
        if pages > 0 { parts.append(pages == 1 ? "1 Seite gelesen" : "\(pages) Seiten gelesen") }
        if articles > 0 { parts.append("\(articles) Artikel gelesen") }
        if files > 0 { parts.append(files == 1 ? "1 Datei gelesen" : "\(files) Dateien gelesen") }
        if failed > 0 { parts.append(failed == 1 ? "1 Fehler" : "\(failed) Fehler") }
        return parts.joined(separator: " · ")
    }

    private static func activity(_ step: ToolStep) -> String {
        switch step.kind {
        case .search: "Sucht: „\(step.argument)“ …"
        case .openPage: "Liest \(shortAddress(step.argument)) …"
        case .wikiSearch: "Sucht in Wikipedia: „\(step.argument)“ …"
        case .wikiArticle: "Liest in Wikipedia: \(articleName(step)) …"
        case .fileSearch: "Sucht in den Dateien: „\(step.argument)“ …"
        case .fileRead: "Liest „\(step.argument)“ …"
        }
    }

    static func articleName(_ step: ToolStep) -> String {
        step.section.map { "\(step.argument) › \($0)" } ?? step.argument
    }

    static func shortAddress(_ address: String) -> String {
        guard let url = URL(string: address), let host = url.host() else { return address }
        let name = host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
        return url.path.count > 1 ? name + url.path : name
    }
}

private struct ToolStepRow: View {
    let step: ToolStep

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 7) {
                Image(systemName: icon)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(step.status == .failed ? Theme.danger : Theme.textTertiary)
                    .frame(width: 14)
                title
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.textPrimary)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                if step.status == .running {
                    ProgressView().controlSize(.mini)
                }
            }
            if let error = step.error {
                Text(error)
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.danger.opacity(0.9))
                    .padding(.leading, 21)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if step.kind == .search || step.kind == .wikiSearch || step.kind == .fileSearch, let sources = step.sources, !sources.isEmpty {
                VStack(alignment: .leading, spacing: 5) {
                    ForEach(Array(sources.enumerated()), id: \.offset) { _, source in
                        SourceLink(source: source, showsHost: step.kind == .search)
                    }
                }
                .padding(.leading, 21)
            }
        }
    }

    private var icon: String {
        if step.status == .failed { return "exclamationmark.triangle.fill" }
        switch step.kind {
        case .search, .wikiSearch, .fileSearch: return "magnifyingglass"
        case .openPage, .fileRead: return "doc.text"
        case .wikiArticle: return "book.closed"
        }
    }

    @ViewBuilder
    private var title: some View {
        switch step.kind {
        case .search, .wikiSearch, .fileSearch:
            let count = step.sources?.count
            let place = step.kind == .wikiSearch ? "  ·  Wikipedia \(step.language ?? "")" : (step.kind == .fileSearch ? "  ·  Dateien" : "")
            Text("„\(step.argument)“").font(.system(size: 13, weight: .medium))
                + Text(place + (count.map { $0 == 1 ? "  ·  1 Treffer" : "  ·  \($0) Treffer" } ?? "")).foregroundColor(Theme.textTertiary)
        case .openPage, .wikiArticle:
            if let page = step.sources?.first, let url = URL(string: page.url) {
                Link(destination: url) {
                    Text(page.title).font(.system(size: 13, weight: .medium))
                        + Text("  ·  \(page.host)").foregroundColor(Theme.textTertiary)
                }
                .help(page.url)
            } else {
                Text(step.kind == .wikiArticle ? ToolStepsView.articleName(step) : ToolStepsView.shortAddress(step.argument))
            }
        case .fileRead:
            if let file = step.sources?.first, let url = URL(string: file.url) {
                Link(destination: url) {
                    Text(file.title).font(.system(size: 13, weight: .medium))
                }
                .help("Datei öffnen")
            } else {
                Text(step.argument)
            }
        }
    }
}

private struct SourceLink: View {
    let source: WebSource
    /// Off for Wikipedia hits and files, which all come from the same place.
    var showsHost = true
    @State private var hovering = false

    private var help: String {
        // A persona's file: the passage is more telling than the path in the app's folder.
        if source.url.hasPrefix("file:") { return source.snippet.map { "\($0) …" } ?? "Datei öffnen" }
        return source.snippet.map { "\(source.url)\n\n\($0)" } ?? source.url
    }

    var body: some View {
        if let url = URL(string: source.url) {
            Link(destination: url) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    if showsHost {
                        Text(source.host)
                            .font(.system(size: 11.5))
                            .foregroundStyle(Theme.textTertiary)
                            .lineLimit(1)
                            .frame(width: 130, alignment: .leading)
                    }
                    Text(source.title)
                        .font(.system(size: 12.5))
                        .foregroundStyle(hovering ? Theme.accent : Theme.textSecondary)
                        .underline(hovering)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    if let date = source.date {
                        Text(date)
                            .font(.system(size: 11))
                            .foregroundStyle(Theme.textTertiary)
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .onHover { hovering = $0 }
            .help(help)
        }
    }
}

private struct ErrorBanner: View {
    let text: String
    let onRetry: (() -> Void)?

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 13))
                .foregroundStyle(Theme.danger)
            Text(text)
                .font(.system(size: 13))
                .foregroundStyle(Theme.textPrimary)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            if let onRetry {
                Button("Erneut versuchen", action: onRetry)
                    .buttonStyle(.plain)
                    .font(.system(size: 12.5, weight: .medium))
                    .foregroundStyle(Theme.textPrimary)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(Theme.elevated))
            }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Theme.danger.opacity(0.08)))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Theme.danger.opacity(0.25)))
    }
}

/// Suggested next questions under the latest answer; a click sends the question.
private struct FollowUpList: View {
    let questions: [String]
    let onSelect: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(questions, id: \.self) { question in
                FollowUpButton(question: question) { onSelect(question) }
            }
        }
        .padding(.top, 2)
    }
}

private struct FollowUpButton: View {
    let question: String
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: "arrow.turn.down.right")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(hovering ? Theme.accent : Theme.textTertiary)
                Text(question)
                    .font(.system(size: 13.5))
                    .foregroundStyle(hovering ? Theme.textPrimary : Theme.textSecondary)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(hovering ? Theme.elevated : Theme.surface))
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(hovering ? Theme.strongBorder : Theme.border))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help("Diese Frage stellen")
    }
}

/// Read aloud / stop. While Qwen TTS generates the first sentences it shows a spinner (click cancels).
private struct SpeakButton: View {
    let state: SpeechReader.State?
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Group {
                if state == .preparing {
                    ProgressView().controlSize(.small)
                } else {
                    Image(systemName: state == .speaking ? "stop.fill" : "speaker.wave.2")
                        .font(.system(size: state == .speaking ? 11 : 12.5))
                        .foregroundStyle(state == .speaking ? Theme.accent : (hovering ? Theme.textPrimary : Theme.textSecondary))
                }
            }
            .frame(width: 32, height: 32)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(hovering ? Theme.hover : .clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(state == nil ? "Vorlesen" : "Vorlesen beenden")
    }
}
