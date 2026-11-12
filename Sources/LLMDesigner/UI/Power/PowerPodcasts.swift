import SwiftUI

/// PodcastStudio in small: every podcast with its state; one of them with its player and the script, whose lines
/// drag out as text. Text dropped here becomes the question of a new podcast; the open document can get one too.
struct PowerPodcasts: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        if let id = app.power.podcastID, app.podcasts.podcast(id) != nil {
            PowerPodcastView(podcastID: id)
        } else {
            PowerPodcastList()
        }
    }
}

private struct PowerPodcastList: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        let query = app.power.query
        let shown = app.podcasts.podcasts.filter { $0.matches(query) }
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 6) {
                    PowerDropZone(title: "Text hierher ziehen: Podcast dazu", symbol: StudioApplication.podcast.symbol) { dropped in
                        app.powerNewPodcast(fromText: dropped.markdown)
                    }
                    if let document = app.selectedDocument {
                        Button {
                            let podcast = app.newPodcast(about: .document(document.id), open: false)
                            app.power.podcastID = podcast.id
                        } label: {
                            Label(document.isPresentation ? "Zur Präsentation" : "Zum Dokument", systemImage: "plus")
                                .font(.system(size: 12, weight: .medium))
                                .foregroundStyle(Theme.accent)
                                .frame(height: 34)
                                .padding(.horizontal, 6)
                        }
                        .buttonStyle(.plain)
                        .help("Neuer Podcast über „\(document.displayTitle)“")
                    }
                }
                .padding(.bottom, 6)
                ForEach(shown) { podcast in
                    HStack(spacing: 0) {
                        PowerListRow(
                            title: podcast.displayTitle,
                            subtitle: subtitle(podcast),
                            snippet: query.isEmpty ? nil : PowerText.snippet(of: podcast.scriptText.isEmpty ? podcast.question : podcast.scriptText, around: query),
                            symbol: StudioApplication.podcast.symbol,
                            isCurrent: app.podcastStudioOpen && app.selectedPodcastID == podcast.id
                        ) {
                            app.power.podcastID = podcast.id
                        }
                        PodcastStatusBadge(podcast: podcast, progress: app.podcastProgress[podcast.id])
                            .padding(.trailing, 8)
                    }
                }
                if shown.isEmpty {
                    PowerEmpty(text: query.isEmpty ? "Noch keine Podcasts. Text hierher ziehen oder im PodcastStudio einen anlegen." : "Kein Podcast passt zur Suche.")
                }
            }
            .padding(.horizontal, 8)
            .padding(.bottom, 12)
        }
    }

    private func subtitle(_ podcast: Podcast) -> String {
        if podcast.phase.isRunning, let progress = app.podcastProgress[podcast.id] {
            return "\(podcast.phase.label) · \(Int((progress.fraction * 100).rounded())) %"
        }
        if let duration = podcast.duration, podcast.phase == .finished { return "\(PodcastLength.clock(duration)) Min · \(podcast.participants.count) Stimmen" }
        return "\(podcast.minutes) Min · \(podcast.phase.label)"
    }
}

private struct PowerPodcastView: View {
    @Environment(AppModel.self) private var app
    let podcastID: UUID

    var body: some View {
        if let podcast = app.podcasts.podcast(podcastID) {
            let query = app.power.query
            let lines = podcast.script.filter { query.isEmpty || $0.text.localizedStandardContains(query) }
            let player = app.podcastPlayer
            let loaded = player.podcastID == podcast.id
            VStack(spacing: 0) {
                PowerItemBar(title: podcast.displayTitle, symbol: StudioApplication.podcast.symbol, openHelp: "Im PodcastStudio öffnen") {
                    app.power.closeItem()
                } onOpen: {
                    app.openPodcastStudio(showing: podcast.id)
                }
                VStack(alignment: .leading, spacing: 8) {
                    if podcast.phase.isRunning {
                        let progress = app.podcastProgress[podcast.id]
                        HStack(spacing: 8) {
                            PodcastProgressRing(fraction: progress?.fraction ?? 0, size: 16)
                            Text(progress?.detail ?? podcast.phase.label)
                                .font(.system(size: 11.5))
                                .foregroundStyle(Theme.textSecondary)
                                .lineLimit(2)
                            Spacer(minLength: 0)
                            IconButton(systemName: "stop.fill", help: "Anhalten", size: 11, frameSize: 24) { app.stopPodcast(podcast.id) }
                        }
                    } else if app.podcastAudioURL(podcast.id) != nil {
                        HStack(spacing: 8) {
                            IconButton(systemName: loaded && player.isPlaying ? "pause.fill" : "play.fill", help: "Abspielen oder anhalten", size: 13, frameSize: 28) {
                                app.loadPodcastPlayer(podcast.id)
                                player.toggle()
                            }
                            Text("\(PodcastLength.clock(loaded ? player.currentTime : 0)) / \(PodcastLength.clock(podcast.duration ?? 0))")
                                .font(.system(size: 11.5).monospacedDigit())
                                .foregroundStyle(Theme.textSecondary)
                            Spacer(minLength: 0)
                            IconButton(systemName: "square.and.arrow.up", help: "Audio exportieren", size: 12, frameSize: 26) { app.exportPodcastWithPanel(podcast.id) }
                        }
                    } else {
                        HStack(spacing: 8) {
                            Text(podcast.startProblem ?? podcast.phase.label)
                                .font(.system(size: 11.5))
                                .foregroundStyle(Theme.textSecondary)
                                .lineLimit(2)
                            Spacer(minLength: 0)
                            if podcast.startProblem == nil {
                                Button(podcast.script.isEmpty ? "Erzeugen" : "Fortsetzen") { app.startPodcast(podcast.id) }
                                    .controlSize(.small)
                            }
                        }
                    }
                }
                .padding(.horizontal, 12)
                .padding(.bottom, 8)
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 4) {
                        if podcast.script.isEmpty {
                            Text(podcast.question)
                                .font(.system(size: 12))
                                .foregroundStyle(Theme.textSecondary)
                                .padding(8)
                        }
                        ForEach(lines) { line in
                            let name = podcast.participant(line.speaker)?.displayName ?? "?"
                            VStack(alignment: .leading, spacing: 2) {
                                Text(name)
                                    .font(.system(size: 11, weight: .semibold))
                                    .foregroundStyle(PodcastSpeakerColor.color(of: line.speaker, in: podcast))
                                Text(line.text)
                                    .font(.system(size: 12))
                                    .foregroundStyle(Theme.textPrimary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            .padding(7)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(Theme.ink.opacity(0.03)))
                            .powerDrag(markdown: "**\(name):** \(line.text)", plain: "\(name): \(line.text)")
                        }
                        if !podcast.script.isEmpty {
                            HStack(spacing: 6) {
                                Image(systemName: "hand.draw")
                                    .font(.system(size: 11))
                                Text("Ziehen: das ganze Skript in ein Dokument oder den Chat")
                                    .font(.system(size: 11))
                            }
                            .foregroundStyle(Theme.textTertiary)
                            .padding(8)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Theme.border, style: StrokeStyle(lineWidth: 1, dash: [4, 3])))
                            .powerDrag(markdown: podcast.scriptMarkdown, plain: podcast.scriptText)
                            .padding(.top, 6)
                        }
                    }
                    .padding(.horizontal, 10)
                    .padding(.bottom, 14)
                }
            }
        }
    }
}

extension Podcast {
    /// The script as Markdown, a heading and every line with its speaker in bold.
    var scriptMarkdown: String {
        "# \(displayTitle)\n\n" + script.map { "**\(participant($0.speaker)?.displayName ?? "?"):** \($0.text)" }.joined(separator: "\n\n")
    }
}

extension AppModel {
    /// A podcast about dropped text: a short text is the question, a long one is its heading or first sentence. It
    /// opens in the power access; "Rückgängig" removes it again.
    @discardableResult
    func powerNewPodcast(fromText text: String) -> UUID? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let plain = PowerText.plain(trimmed).trimmingCharacters(in: .whitespacesAndNewlines)
        let heading = trimmed.components(separatedBy: .newlines).first { $0.hasPrefix("#") }?.drop { $0 == "#" }.trimmingCharacters(in: .whitespaces)
        let question: String
        if plain.count <= 300 {
            question = plain
        } else if let heading, !heading.isEmpty {
            question = heading
        } else {
            question = String(plain.prefix { $0 != "\n" }.prefix(300))
        }
        let podcast = newPodcast(question: question, open: false)
        power.podcastID = podcast.id
        power.lastChange = PowerAccess.Change(label: "Podcast angelegt") { [weak self] in
            _ = self?.podcasts.delete(podcast.id)
            if self?.power.podcastID == podcast.id { self?.power.podcastID = nil }
        }
        return podcast.id
    }
}
