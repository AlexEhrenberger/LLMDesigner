import SwiftUI

/// The state of a podcast in a few pixels: a ring while it is made, a clock while it waits, its length when done.
struct PodcastStatusBadge: View {
    let podcast: Podcast
    let progress: PodcastProgress?

    var body: some View {
        switch podcast.phase {
        case .researching, .scripting, .speaking:
            PodcastProgressRing(fraction: progress?.fraction ?? 0, size: 15)
                .help("\(podcast.phase.label): \(Int(((progress?.fraction ?? 0) * 100).rounded())) %" + (progress.map { " – \($0.detail)" } ?? ""))
        case .queued:
            Image(systemName: "clock")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(Theme.textTertiary)
                .help("Wartet, bis der laufende Podcast fertig ist")
        case .failed:
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 11))
                .foregroundStyle(Theme.warning)
                .help(podcast.error ?? "Fehler")
        case .stopped:
            Image(systemName: "pause.circle")
                .font(.system(size: 12))
                .foregroundStyle(Theme.textTertiary)
                .help("Angehalten – kann fortgesetzt werden")
        case .finished:
            if let duration = podcast.duration {
                Text(PodcastLength.clock(duration))
                    .font(.system(size: 10.5, weight: .medium).monospacedDigit())
                    .foregroundStyle(Theme.textTertiary)
            }
        case .draft:
            EmptyView()
        }
    }
}

/// A ring that fills as the podcast is made, with the accent colour turning slowly so it reads as busy.
struct PodcastProgressRing: View {
    let fraction: Double
    var size: CGFloat = 16
    var lineWidth: CGFloat = 2.2

    var body: some View {
        ZStack {
            Circle().stroke(Theme.ink.opacity(0.12), lineWidth: lineWidth)
            Circle()
                .trim(from: 0, to: max(0.03, min(1, fraction)))
                .stroke(Theme.accent, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .animation(.easeInOut(duration: 0.4), value: fraction)
        }
        .frame(width: size, height: size)
    }
}

/// A text field that keeps what is typed to itself and hands it over after a short pause, on Return and when it
/// loses the keyboard: each change of a podcast draws the page and the sidebar again, too much for every keystroke.
struct PodcastField: View {
    let prompt: String
    let value: String
    var axis: Axis = .horizontal
    var font: Font = .system(size: 13)
    let commit: (String) -> Void

    @State private var text = ""
    @State private var pending: Task<Void, Never>?
    @FocusState private var focused: Bool

    var body: some View {
        TextField(prompt, text: $text, axis: axis)
            .textFieldStyle(.plain)
            .font(font)
            .focused($focused)
            .onAppear { text = value }
            .onChange(of: value) { _, new in if !focused { text = new } }
            .onChange(of: text) { _, new in
                pending?.cancel()
                guard new != value else { return }
                pending = Task {
                    try? await Task.sleep(for: .milliseconds(600))
                    guard !Task.isCancelled else { return }
                    commit(new)
                }
            }
            .onSubmit { flush() }
            .onChange(of: focused) { _, isFocused in if !isFocused { flush() } }
            .onDisappear { flush() }
    }

    private func flush() {
        pending?.cancel()
        pending = nil
        if text != value { commit(text) }
    }
}

/// A card of the podcast page with a small heading.
struct PodcastCard<Content: View, Accessory: View>: View {
    let title: String
    let symbol: String
    @ViewBuilder let accessory: Accessory
    @ViewBuilder let content: Content

    init(_ title: String, symbol: String, @ViewBuilder accessory: () -> Accessory = { EmptyView() }, @ViewBuilder content: () -> Content) {
        self.title = title
        self.symbol = symbol
        self.accessory = accessory()
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 7) {
                Image(systemName: symbol)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Theme.accent)
                Text(title.uppercased())
                    .font(.system(size: 11, weight: .semibold))
                    .tracking(0.5)
                    .foregroundStyle(Theme.textTertiary)
                Spacer(minLength: 0)
                accessory
            }
            content
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Theme.surface))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Theme.border))
    }
}

/// Colours that tell the speakers apart in the script: the moderator in the accent, the others in their own.
enum PodcastSpeakerColor {
    private static let palette: [Color] = [
        Theme.accent,
        Color(red: 0.25, green: 0.72, blue: 0.62),
        Color(red: 0.93, green: 0.55, blue: 0.30),
        Color(red: 0.36, green: 0.60, blue: 0.95),
        Color(red: 0.86, green: 0.42, blue: 0.62),
    ]

    static func color(of id: UUID, in podcast: Podcast) -> Color {
        let index = podcast.participants.firstIndex { $0.id == id } ?? 0
        return palette[index % palette.count]
    }
}

/// The menu that adds a reference: a chat, a document, a presentation, a novel world or one of its parts.
struct PodcastReferenceMenu<Label: View>: View {
    @Environment(AppModel.self) private var app
    let existing: [PodcastReference]
    let add: (PodcastReference) -> Void
    @ViewBuilder let label: Label

    var body: some View {
        Menu {
            let documents = app.documents.filter { !$0.isPresentation && !$0.isEmpty }.prefix(25)
            let decks = app.documents.filter(\.isPresentation).prefix(25)
            let chats = app.chats.filter { !$0.messages.isEmpty }.sorted { $0.updatedAt > $1.updatedAt }.prefix(25)
            Menu("Dokument") {
                ForEach(Array(documents)) { document in item(.document(document.id), document.displayTitle) }
            }
            .disabled(documents.isEmpty)
            Menu("Präsentation") {
                ForEach(Array(decks)) { document in item(.document(document.id), document.displayTitle) }
            }
            .disabled(decks.isEmpty)
            Menu("Chat") {
                ForEach(Array(chats)) { chat in item(.chat(chat.id), chat.title) }
            }
            .disabled(chats.isEmpty)
            Menu("Romanwelt") {
                ForEach(app.stories.worlds) { world in
                    Menu(world.displayTitle) {
                        item(.story(world: world.id, part: nil), "Ganze Welt")
                        let parts = world.allParts
                        if !parts.isEmpty { Divider() }
                        ForEach(parts) { entry in
                            item(.story(world: world.id, part: entry.part.id), String(repeating: "   ", count: entry.depth) + world.displayTitle(of: entry.part))
                        }
                    }
                }
            }
            .disabled(app.stories.worlds.isEmpty)
        } label: {
            label
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .onAppear { app.stories.loadIfNeeded() }
    }

    @ViewBuilder
    private func item(_ reference: PodcastReference, _ title: String) -> some View {
        Button(existing.contains(reference) ? "✓ " + title : title) { add(reference) }
            .disabled(existing.contains(reference))
    }
}

/// The toolbar button of Writer, Presenter and Stories: a new podcast about what is open.
struct PodcastFromButton: View {
    @Environment(AppModel.self) private var app
    let reference: PodcastReference
    var help = "Podcast daraus erzeugen"

    var body: some View {
        IconButton(systemName: StudioApplication.podcast.symbol, help: help, size: 13, frameSize: Theme.titleBarControlSize) {
            app.newPodcast(about: reference)
        }
    }
}
