import SwiftUI

/// PodcastStudio: the open podcast with its question, cast, references, research, script and player. Without one
/// open it shows all podcasts of the library; each also has its entry in the sidebar.
struct PodcastStudioScreen: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        VStack(spacing: 0) {
            PodcastTopBar()
            if let id = app.selectedPodcastID, app.podcasts.podcast(id) != nil {
                PodcastPage(podcastID: id)
                    .id(id)
            } else {
                PodcastOverview()
            }
        }
        .background(Theme.background)
        .onAppear {
            app.podcasts.loadIfNeeded()
            app.loadPodcastVoices()
        }
    }
}

private struct PodcastTopBar: View {
    @Environment(AppModel.self) private var app
    @State private var width: CGFloat = 1200

    var body: some View {
        let podcasts = app.podcasts.podcasts
        let running = podcasts.filter(\.phase.isRunning).count
        HStack(spacing: 10) {
            if !app.isSidebarDocked {
                SidebarToggleButton()
                NewItemMenu()
                    .padding(.trailing, 4)
            }
            if app.selectedPodcastID != nil {
                IconButton(systemName: "square.grid.2x2", help: "Alle Podcasts", size: 12.5, frameSize: Theme.titleBarControlSize) {
                    app.selectedPodcastID = nil
                }
            }
            Image(systemName: StudioApplication.podcast.symbol)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(Theme.accent)
            Text("PodcastStudio")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Theme.textPrimary)
                .lineLimit(1)
                .fixedSize()
            if width >= 700, !podcasts.isEmpty {
                Text("\(podcasts.count) \(podcasts.count == 1 ? "Podcast" : "Podcasts")" + (running > 0 ? " · \(running) in Arbeit" : ""))
                    .font(.system(size: 12).monospacedDigit())
                    .foregroundStyle(Theme.textTertiary)
                    .lineLimit(1)
                    .fixedSize()
            }
            Spacer(minLength: 16)
            IconButton(systemName: "plus", help: "Neuer Podcast", size: 13, frameSize: Theme.titleBarControlSize) {
                app.newPodcast()
            }
            IconButton(systemName: "xmark", help: "PodcastStudio schließen und zurück zum Chat", size: 12.5, frameSize: Theme.titleBarControlSize) {
                withAnimation(.easeInOut(duration: 0.25)) { app.closePodcastStudio() }
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

/// All podcasts as cards; the empty studio explains what a podcast is.
private struct PodcastOverview: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        let podcasts = app.podcasts.podcasts
        if podcasts.isEmpty {
            VStack(spacing: 14) {
                Image(systemName: StudioApplication.podcast.symbol)
                    .font(.system(size: 36, weight: .light))
                    .foregroundStyle(Theme.accent)
                Text("Noch kein Podcast")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(Theme.textPrimary)
                Text("Gib eine Frage vor, wähle die Länge und wer spricht – oder lass die KI die Runde besetzen.\nDas Modell recherchiert in Wikipedia und im Web, schreibt das Gespräch, und Qwen TTS spricht es im Hintergrund ein.")
                    .font(.system(size: 12.5))
                    .foregroundStyle(Theme.textSecondary)
                    .multilineTextAlignment(.center)
                Button {
                    app.newPodcast()
                } label: {
                    Label("Podcast anlegen", systemImage: "plus")
                }
                .buttonStyle(.borderedProminent)
                .padding(.top, 4)
            }
            .padding(40)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollView {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 260), spacing: 14)], spacing: 14) {
                    ForEach(podcasts) { podcast in
                        PodcastOverviewCard(podcast: podcast)
                    }
                }
                .padding(20)
                .frame(maxWidth: 1100)
                .frame(maxWidth: .infinity)
            }
        }
    }
}

private struct PodcastOverviewCard: View {
    @Environment(AppModel.self) private var app
    let podcast: Podcast
    @State private var hovering = false

    var body: some View {
        let progress = app.podcastProgress[podcast.id]
        Button {
            app.openPodcastStudio(showing: podcast.id)
        } label: {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    Image(systemName: StudioApplication.podcast.symbol)
                        .font(.system(size: 13))
                        .foregroundStyle(Theme.accent)
                    Text(podcast.displayTitle)
                        .font(.system(size: 13.5, weight: .semibold))
                        .foregroundStyle(Theme.textPrimary)
                        .lineLimit(2)
                    Spacer(minLength: 0)
                    PodcastStatusBadge(podcast: podcast, progress: progress)
                }
                if !podcast.question.isEmpty {
                    Text(podcast.question)
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.textSecondary)
                        .lineLimit(3)
                }
                Spacer(minLength: 0)
                HStack(spacing: 6) {
                    Text("\(podcast.minutes) Min")
                    Text("·")
                    Text(podcast.participants.map(\.displayName).joined(separator: ", "))
                        .lineLimit(1)
                    Spacer(minLength: 0)
                    Text(podcast.phase.isRunning ? (progress?.detail ?? podcast.phase.label) : podcast.phase.label)
                        .lineLimit(1)
                }
                .font(.system(size: 11))
                .foregroundStyle(Theme.textTertiary)
            }
            .padding(14)
            .frame(maxWidth: .infinity, minHeight: 120, alignment: .topLeading)
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(hovering ? Theme.hover : Theme.surface))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Theme.border))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}
