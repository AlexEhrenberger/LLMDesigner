import SwiftUI
import AppKit
import AVKit
import UniformTypeIdentifiers

// The bigger media of Stories Studio: a figure's character video cards, and the galleries of a world and of its
// books (pictures with a short description each).

// MARK: - Video cards

/// A figure's videos as cards: a still with its length; a click plays it in the card.
struct StoryVideoCards: View {
    let worldID: UUID
    let videos: [StoryVideo]
    let library: StoryLibrary
    let caption: (StoryVideo) -> Binding<String>
    let onChange: ([StoryVideo]) -> Void
    @State private var targeted = false

    var body: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 220, maximum: 320), spacing: 14, alignment: .top)], alignment: .leading, spacing: 14) {
            ForEach(videos, id: \.fileName) { video in
                StoryVideoCard(video: video, worldID: worldID, library: library, caption: caption(video)) {
                    onChange(videos.filter { $0 != video })
                    library.removeVideo(video, in: worldID)
                } onMove: { offset in
                    guard let index = videos.firstIndex(of: video), videos.indices.contains(index + offset) else { return }
                    var moved = videos
                    moved.swapAt(index, index + offset)
                    onChange(moved)
                }
            }
            Button(action: choose) {
                VStack(spacing: 8) {
                    Image(systemName: "video.badge.plus")
                        .font(.system(size: 24, weight: .light))
                    Text(videos.isEmpty ? "Videos hinzufügen" : "Weiteres Video")
                        .font(.system(size: 12))
                    Text("auswählen oder hierher ziehen")
                        .font(.system(size: 10.5))
                        .foregroundStyle(Theme.textTertiary)
                }
                .foregroundStyle(targeted ? Theme.accent : Theme.textSecondary)
                .frame(maxWidth: .infinity)
                .frame(height: 150)
                .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.white.opacity(0.03)))
                .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(targeted ? Theme.accent : Theme.border, style: StrokeStyle(lineWidth: 1, dash: [4, 3])))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Videos werden in die Bibliothek kopiert (Geschichten/Videos).")
        }
        .onDrop(of: [.fileURL], isTargeted: $targeted) { providers in
            for provider in providers {
                _ = provider.loadObject(ofClass: URL.self) { url, _ in
                    guard let url else { return }
                    Task { @MainActor in add([url]) }
                }
            }
            return true
        }
    }

    private func choose() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.movie]
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.prompt = "Hinzufügen"
        guard panel.runModal() == .OK else { return }
        add(panel.urls)
    }

    private func add(_ urls: [URL]) {
        let added = library.importVideos(urls, into: worldID)
        guard !added.isEmpty else { return }
        onChange(videos + added)
    }
}

private struct StoryVideoCard: View {
    let video: StoryVideo
    let worldID: UUID
    let library: StoryLibrary
    let caption: Binding<String>
    let onRemove: () -> Void
    let onMove: (Int) -> Void
    @State private var poster: NSImage?
    @State private var duration: Double?
    @State private var playing = false
    @State private var hovering = false

    private var url: URL { library.videoURL(video, in: worldID) }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ZStack {
                Color.black
                if playing {
                    StoryPlayerView(url: url)
                } else {
                    if let poster {
                        Image(nsImage: poster)
                            .resizable()
                            .scaledToFit()
                    } else {
                        Image(systemName: "film")
                            .font(.system(size: 26, weight: .light))
                            .foregroundStyle(Theme.textTertiary)
                    }
                    Image(systemName: "play.circle.fill")
                        .font(.system(size: 34))
                        .symbolRenderingMode(.palette)
                        .foregroundStyle(.white, .black.opacity(0.45))
                        .opacity(hovering ? 1 : 0.8)
                }
            }
            .frame(height: 150)
            .frame(maxWidth: .infinity)
            .overlay(alignment: .bottomTrailing) {
                if !playing, let duration, duration.isFinite, duration > 0 {
                    Text(Self.format(duration))
                        .font(.system(size: 10.5, weight: .semibold).monospacedDigit())
                        .foregroundStyle(.white)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Capsule().fill(.black.opacity(0.6)))
                        .padding(6)
                }
            }
            .overlay(alignment: .topTrailing) {
                if playing {
                    Button {
                        playing = false
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 16))
                            .symbolRenderingMode(.palette)
                            .foregroundStyle(.white, .black.opacity(0.5))
                    }
                    .buttonStyle(.plain)
                    .padding(6)
                    .help("Video schließen")
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .contentShape(Rectangle())
            .onTapGesture { if !playing { playing = true } }
            .onHover { hovering = $0 }
            .help(playing ? "" : "Klick spielt das Video ab")
            StoryTextEditor(placeholder: "Titel oder Beschreibung der Videocard", text: caption, font: .systemFont(ofSize: 12.5))
                .padding(.horizontal, 4)
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Theme.surface))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Theme.border))
        .contextMenu {
            Button("Abspielen", systemImage: "play") { playing = true }
            Button("Mit Standard-App öffnen", systemImage: "arrow.up.forward.app") { NSWorkspace.shared.open(url) }
            Button("Im Finder zeigen", systemImage: "folder") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
            Divider()
            Button("Nach vorne", systemImage: "arrow.left") { onMove(-1) }
            Button("Nach hinten", systemImage: "arrow.right") { onMove(1) }
            Divider()
            Button("Video entfernen", systemImage: "trash", role: .destructive, action: onRemove)
        }
        .task(id: video.fileName) {
            let result = await library.poster(video, in: worldID)
            poster = result.image
            duration = result.duration
        }
    }

    static func format(_ seconds: Double) -> String {
        let total = Int(seconds.rounded())
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}

/// AppKit's player with its controls, started at once; it stops when the card closes it.
private struct StoryPlayerView: NSViewRepresentable {
    let url: URL

    func makeNSView(context: Context) -> AVPlayerView {
        let view = AVPlayerView()
        view.controlsStyle = .inline
        view.videoGravity = .resizeAspect
        view.player = AVPlayer(url: url)
        view.player?.play()
        return view
    }

    func updateNSView(_ view: AVPlayerView, context: Context) {}

    static func dismantleNSView(_ view: AVPlayerView, coordinator: ()) {
        view.player?.pause()
        view.player = nil
    }
}

// MARK: - Gallery

/// The gallery of a world or a book: pictures in a grid, each with a short description. A click shows a picture
/// large; new ones are copied into the library.
struct StoryGalleryView: View {
    let title: String
    let worldID: UUID
    let images: [StoryImage]
    let library: StoryLibrary
    let caption: (StoryImage) -> Binding<String>
    let onChange: ([StoryImage]) -> Void
    @State private var targeted = false
    /// The file name of the picture shown large.
    @State private var shown: String?

    var body: some View {
        ZStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    HStack(alignment: .firstTextBaseline) {
                        StorySectionTitle(title: title, symbol: "photo.on.rectangle.angled")
                        Text(images.isEmpty ? "" : "\(images.count) \(images.count == 1 ? "Bild" : "Bilder")")
                            .font(.system(size: 12).monospacedDigit())
                            .foregroundStyle(Theme.textTertiary)
                        Spacer()
                        Button(action: choose) {
                            Label("Bilder hinzufügen", systemImage: "plus")
                                .font(.system(size: 12, weight: .medium))
                                .foregroundStyle(Theme.accent)
                        }
                        .buttonStyle(.plain)
                    }
                    if images.isEmpty {
                        empty
                    } else {
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 210, maximum: 340), spacing: 14, alignment: .top)], alignment: .leading, spacing: 16) {
                            ForEach(images, id: \.fileName) { image in
                                card(image)
                            }
                        }
                    }
                }
                .padding(.horizontal, 30)
                .padding(.vertical, 22)
                .frame(maxWidth: 1100, alignment: .leading)
                .frame(maxWidth: .infinity)
            }
            .overlay {
                if targeted {
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .strokeBorder(Theme.accent, style: StrokeStyle(lineWidth: 2, dash: [6, 4]))
                        .padding(10)
                        .allowsHitTesting(false)
                }
            }
            .onDrop(of: [.fileURL], isTargeted: $targeted) { providers in
                for provider in providers {
                    _ = provider.loadObject(ofClass: URL.self) { url, _ in
                        guard let url else { return }
                        Task { @MainActor in add([url]) }
                    }
                }
                return true
            }
            if let shown, let index = images.firstIndex(where: { $0.fileName == shown }) {
                viewer(index)
            }
        }
    }

    private var empty: some View {
        Button(action: choose) {
            VStack(spacing: 10) {
                Image(systemName: "photo.badge.plus")
                    .font(.system(size: 30, weight: .light))
                Text("Noch keine Bilder")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Theme.textPrimary)
                Text("Karten, Stimmungsbilder, Figurenskizzen, Cover-Ideen – auswählen oder hierher ziehen.\nJedes Bild bekommt eine kurze Beschreibung.")
                    .font(.system(size: 12))
                    .multilineTextAlignment(.center)
            }
            .foregroundStyle(Theme.textSecondary)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 44)
            .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Color.white.opacity(0.03)))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Theme.border, style: StrokeStyle(lineWidth: 1, dash: [4, 3])))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func card(_ image: StoryImage) -> some View {
        let url = library.imageURL(image, in: worldID)
        return VStack(alignment: .leading, spacing: 8) {
            ZStack {
                Color.black.opacity(0.35)
                StoryThumbnail(image: image, worldID: worldID, library: library) {
                    Image(systemName: "photo")
                        .font(.system(size: 26))
                        .foregroundStyle(Theme.textTertiary)
                }
            }
            .frame(height: 170)
            .frame(maxWidth: .infinity)
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .contentShape(Rectangle())
            .onTapGesture(count: 2) { NSWorkspace.shared.open(url) }
            .onTapGesture { withAnimation(.easeOut(duration: 0.15)) { shown = image.fileName } }
            .help("Klick zeigt das Bild groß, Doppelklick öffnet es")
            StoryTextEditor(placeholder: "Kurze Beschreibung …", text: caption(image), font: .systemFont(ofSize: 12.5))
                .padding(.horizontal, 4)
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Theme.surface))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Theme.border))
        .contextMenu {
            Button("Groß zeigen", systemImage: "arrow.up.left.and.arrow.down.right") { shown = image.fileName }
            Button("Öffnen", systemImage: "arrow.up.forward.app") { NSWorkspace.shared.open(url) }
            Button("Im Finder zeigen", systemImage: "folder") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
            Divider()
            Button("Nach vorne", systemImage: "arrow.left") { move(image, by: -1) }
                .disabled(image == images.first)
            Button("Nach hinten", systemImage: "arrow.right") { move(image, by: 1) }
                .disabled(image == images.last)
            Divider()
            Button("Bild entfernen", systemImage: "trash", role: .destructive) {
                if shown == image.fileName { shown = nil }
                onChange(images.filter { $0 != image })
                library.removeImage(image, in: worldID)
            }
        }
    }

    /// The picture over the gallery, as large as it fits, with its description; arrows step through.
    private func viewer(_ index: Int) -> some View {
        let current = images[index]
        return ZStack {
            Color.black.opacity(0.88)
                .onTapGesture { shown = nil }
            VStack(spacing: 14) {
                if let full = NSImage(contentsOf: library.imageURL(current, in: worldID)) {
                    Image(nsImage: full)
                        .resizable()
                        .scaledToFit()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .onTapGesture { shown = nil }
                }
                if !current.caption.isEmpty {
                    Text(current.caption)
                        .font(.system(size: 14))
                        .foregroundStyle(Theme.textPrimary)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 700)
                }
            }
            .padding(40)
            HStack {
                viewerButton("chevron.left", help: "Voriges Bild", shortcut: KeyboardShortcut(.leftArrow, modifiers: []), disabled: index == 0) {
                    if index > 0 { shown = images[index - 1].fileName }
                }
                Spacer()
                viewerButton("chevron.right", help: "Nächstes Bild", shortcut: KeyboardShortcut(.rightArrow, modifiers: []), disabled: index >= images.count - 1) {
                    if index < images.count - 1 { shown = images[index + 1].fileName }
                }
            }
            .padding(.horizontal, 14)
            VStack {
                HStack {
                    Spacer()
                    viewerButton("xmark", help: "Schließen", shortcut: .cancelAction, disabled: false) { shown = nil }
                }
                Spacer()
            }
            .padding(14)
        }
        .transition(.opacity)
    }

    private func viewerButton(_ symbol: String, help: String, shortcut: KeyboardShortcut, disabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 38, height: 38)
                .background(Circle().fill(.white.opacity(0.12)))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .keyboardShortcut(shortcut)
        .opacity(disabled ? 0.25 : 1)
        .disabled(disabled)
        .help(help)
    }

    private func move(_ image: StoryImage, by offset: Int) {
        guard let index = images.firstIndex(of: image), images.indices.contains(index + offset) else { return }
        var moved = images
        moved.swapAt(index, index + offset)
        onChange(moved)
    }

    private func choose() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.prompt = "Hinzufügen"
        guard panel.runModal() == .OK else { return }
        add(panel.urls)
    }

    private func add(_ urls: [URL]) {
        let added = library.importImages(urls, into: worldID)
        guard !added.isEmpty else { return }
        onChange(images + added)
    }
}
