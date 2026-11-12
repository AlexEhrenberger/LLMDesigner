import SwiftUI

/// One podcast: what it is about and who speaks, how far it is, and once spoken the player with the script that
/// follows along.
struct PodcastPage: View {
    @Environment(AppModel.self) private var app
    let podcastID: UUID

    var body: some View {
        if let podcast = app.podcasts.podcast(podcastID) {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    PodcastHeader(podcast: podcast)
                    PodcastProduction(podcast: podcast)
                    if app.podcastAudioURL(podcast.id) != nil {
                        PodcastPlayerCard(podcast: podcast)
                    }
                    PodcastCastCard(podcast: podcast)
                    PodcastSourcesCard(podcast: podcast)
                    PodcastReferencesCard(podcast: podcast)
                    if !podcast.research.isEmpty {
                        PodcastResearchCard(podcast: podcast)
                    }
                    if !podcast.script.isEmpty {
                        PodcastScriptCard(podcast: podcast)
                    }
                }
                .padding(.horizontal, 24)
                .padding(.top, 6)
                .padding(.bottom, 40)
                .frame(maxWidth: 860)
                .frame(maxWidth: .infinity)
            }
        }
    }
}

// MARK: - Header

private struct PodcastHeader: View {
    @Environment(AppModel.self) private var app
    let podcast: Podcast

    var body: some View {
        let locked = podcast.phase.isRunning
        VStack(alignment: .leading, spacing: 12) {
            PodcastField(prompt: "Titel (sonst aus der Frage)", value: podcast.title, font: .system(size: 22, weight: .semibold)) { title in
                app.podcasts.update(podcast.id) { $0.title = title }
            }
            VStack(alignment: .leading, spacing: 5) {
                Text("Frage oder Thema")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Theme.textTertiary)
                PodcastField(prompt: "z. B. Was ist Predictive Coding, und ist das ein zeitgemäßes Paradigma?", value: podcast.question, axis: .vertical,
                             font: .system(size: 14)) { question in
                    app.podcasts.update(podcast.id) { $0.question = question }
                }
                .lineLimit(1...5)
                .padding(10)
                .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(Theme.well))
                .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).strokeBorder(Theme.border))
                .disabled(locked)
            }
            HStack(spacing: 16) {
                HStack(spacing: 8) {
                    Text("Länge")
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.textSecondary)
                    Picker("Länge", selection: Binding(get: { podcast.minutes }, set: { minutes in app.podcasts.update(podcast.id) { $0.minutes = minutes } })) {
                        ForEach(PodcastLength.choices, id: \.self) { Text("\($0) Min").tag($0) }
                    }
                    .labelsHidden()
                    .pickerStyle(.segmented)
                    .fixedSize()
                }
                HStack(spacing: 8) {
                    Text("Stimme")
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.textSecondary)
                    Picker("Sprachmodell", selection: Binding(get: { podcast.speechModel }, set: { model in app.podcasts.update(podcast.id) { $0.speechModel = model } })) {
                        ForEach(PodcastSpeechModel.allCases) { Text($0.label).tag($0) }
                    }
                    .labelsHidden()
                    .fixedSize()
                    .help("Das kleine Modell klingt stabiler; das große ist natürlicher, erzeugte aber gelegentlich Rauschen.")
                }
                HStack(spacing: 8) {
                    Text("Sprache")
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.textSecondary)
                    Picker("Sprache", selection: Binding(get: { podcast.language }, set: { language in app.podcasts.update(podcast.id) { $0.language = language } })) {
                        Text("Deutsch").tag("de")
                        Text("Englisch").tag("en")
                    }
                    .labelsHidden()
                    .fixedSize()
                }
                Spacer(minLength: 0)
            }
            .disabled(locked)
            HStack(spacing: 16) {
                Toggle("Denkmodus", isOn: Binding(get: { podcast.thinking }, set: { on in app.podcasts.update(podcast.id) { $0.thinking = on } }))
                    .toggleStyle(.switch)
                    .controlSize(.mini)
                    .font(.system(size: 12))
                    .help("Das Modell denkt vor Recherche, Gliederung und Skript nach: gründlicher, aber langsamer. Qwen in LM Studio denkt immer.")
                PodcastToneSlider(podcast: podcast)
                Spacer(minLength: 0)
            }
            .disabled(locked)
            Text("Etwa \(podcast.targetWords) gesprochene Wörter in \(PodcastLength.sectionCount(minutes: podcast.minutes)) Abschnitten.")
                .font(.system(size: 11))
                .foregroundStyle(Theme.textTertiary)
        }
    }
}

/// Five steps from factual to heated; the hint below says what the step means.
private struct PodcastToneSlider: View {
    @Environment(AppModel.self) private var app
    let podcast: Podcast
    @State private var level: Double?

    var body: some View {
        let tone = level.map { PodcastTone.at(Int($0.rounded())) } ?? podcast.tone
        HStack(spacing: 8) {
            Text("Ton")
                .font(.system(size: 12))
                .foregroundStyle(Theme.textSecondary)
            Text("sachlich")
                .font(.system(size: 10.5))
                .foregroundStyle(Theme.textTertiary)
            Slider(value: Binding(get: { level ?? Double(podcast.tone.level) }, set: { level = $0 }),
                   in: 0...Double(PodcastTone.allCases.count - 1), step: 1) { editing in
                guard !editing, let level else { return }
                let chosen = PodcastTone.at(Int(level.rounded()))
                app.podcasts.update(podcast.id) { $0.tone = chosen }
                self.level = nil
            }
            .frame(width: 150)
            .tint(tone.level >= PodcastTone.polemic.level ? Theme.danger : Theme.accent)
            Text("hitzig")
                .font(.system(size: 10.5))
                .foregroundStyle(Theme.textTertiary)
            Text(tone.label)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(tone.level >= PodcastTone.polemic.level ? Theme.danger : Theme.textPrimary)
                .frame(width: 80, alignment: .leading)
        }
        .help(tone.hint)
    }
}

// MARK: - Production

private struct PodcastProduction: View {
    @Environment(AppModel.self) private var app
    let podcast: Podcast
    @State private var message: String?

    var body: some View {
        let progress = app.podcastProgress[podcast.id]
        PodcastCard("Erzeugen", symbol: "wand.and.sparkles") {
            if podcast.phase.isRunning {
                Button("Anhalten", systemImage: "stop.fill") { app.stopPodcast(podcast.id) }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
            }
        } content: {
            VStack(alignment: .leading, spacing: 10) {
                if podcast.phase.isRunning {
                    HStack(spacing: 10) {
                        PodcastProgressRing(fraction: progress?.fraction ?? 0, size: 22, lineWidth: 3)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("\(podcast.phase.label) · \(Int(((progress?.fraction ?? 0) * 100).rounded())) %")
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundStyle(Theme.textPrimary)
                            Text(progress?.detail ?? "")
                                .font(.system(size: 12))
                                .foregroundStyle(Theme.textSecondary)
                                .lineLimit(2)
                        }
                    }
                    ProgressView(value: progress?.fraction ?? 0)
                        .tint(Theme.accent)
                    if let lookups = progress?.lookups, !lookups.isEmpty {
                        VStack(alignment: .leading, spacing: 3) {
                            ForEach(Array(lookups.suffix(6).enumerated()), id: \.offset) { _, lookup in
                                Label(lookup, systemImage: lookup.hasPrefix("Wikipedia") ? "w.square" : "globe")
                                    .font(.system(size: 11.5))
                                    .foregroundStyle(Theme.textTertiary)
                                    .lineLimit(1)
                            }
                        }
                    }
                    Text("Läuft im Hintergrund weiter – du kannst in der App weiterarbeiten. Der Fortschritt steht auch in der Seitenleiste.")
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.textTertiary)
                } else {
                    status
                    HStack(spacing: 8) {
                        if let problem = podcast.startProblem {
                            Label(problem, systemImage: "info.circle")
                                .font(.system(size: 12))
                                .foregroundStyle(Theme.textSecondary)
                        } else {
                            if !app.isPodcastAudioCurrent(podcast) {
                                Button {
                                    message = app.startPodcast(podcast.id)
                                } label: {
                                    Label(primaryTitle, systemImage: "play.fill")
                                }
                                .buttonStyle(.borderedProminent)
                            }
                            if !podcast.research.isEmpty || !podcast.script.isEmpty {
                                Menu("Neu erzeugen") {
                                    Button("Alles neu, mit neuer Recherche") { message = app.startPodcast(podcast.id, from: .everything) }
                                    Button("Neues Skript auf dieser Recherche") { message = app.startPodcast(podcast.id, from: .script) }
                                        .disabled(podcast.research.isEmpty)
                                    Button("Alle Zeilen neu sprechen") { message = app.startPodcast(podcast.id, from: .audio) }
                                        .disabled(podcast.script.isEmpty)
                                }
                                .fixedSize()
                            }
                        }
                        Spacer(minLength: 0)
                    }
                    if let message {
                        Text(message)
                            .font(.system(size: 12))
                            .foregroundStyle(Theme.warning)
                    }
                }
            }
        }
    }

    private var primaryTitle: String {
        if podcast.script.isEmpty && podcast.research.isEmpty { return "Podcast erzeugen" }
        return podcast.phase == .finished ? "Audio aktualisieren" : "Fortsetzen"
    }

    @ViewBuilder
    private var status: some View {
        switch podcast.phase {
        case .failed:
            Label(podcast.error ?? "Es ist ein Fehler aufgetreten.", systemImage: "exclamationmark.triangle.fill")
                .font(.system(size: 12.5))
                .foregroundStyle(Theme.warning)
        case .stopped:
            Label("Angehalten. „Fortsetzen“ macht dort weiter, wo es aufgehört hat.", systemImage: "pause.circle")
                .font(.system(size: 12.5))
                .foregroundStyle(Theme.textSecondary)
        case .finished:
            let current = app.isPodcastAudioCurrent(podcast)
            Label(current ? "Fertig: \(PodcastLength.clock(podcast.duration ?? 0)) Min, \(podcast.script.count) Beiträge, \(podcast.scriptWords) Wörter."
                          : "Das Skript wurde geändert: Geänderte Zeilen werden beim Aktualisieren neu gesprochen.",
                  systemImage: current ? "checkmark.circle.fill" : "arrow.triangle.2.circlepath")
                .font(.system(size: 12.5))
                .foregroundStyle(current ? Theme.success : Theme.textSecondary)
        default:
            Text("Das Modell recherchiert zuerst mehrmals in Wikipedia und im Web (mit Denkmodus, wenn es einen hat), schreibt dann das Gespräch passend zur Länge, und Qwen TTS spricht jede Zeile mit der Stimme ihrer Person.")
                .font(.system(size: 12))
                .foregroundStyle(Theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

// MARK: - Player

private struct PodcastPlayerCard: View {
    @Environment(AppModel.self) private var app
    let podcast: Podcast

    var body: some View {
        let player = app.podcastPlayer
        let loaded = player.podcastID == podcast.id
        PodcastCard("Anhören", symbol: "headphones") {
            Button("Exportieren …", systemImage: "square.and.arrow.up") { app.exportPodcastWithPanel(podcast.id) }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .help("Die Audiodatei (M4A) speichern")
        } content: {
            HStack(spacing: 12) {
                IconButton(systemName: "gobackward.15", help: "15 Sekunden zurück", size: 15, frameSize: 30) { load(); player.skip(by: -15) }
                Button {
                    load()
                    player.toggle()
                } label: {
                    Image(systemName: loaded && player.isPlaying ? "pause.fill" : "play.fill")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(width: 38, height: 38)
                        .background(Circle().fill(Theme.accent))
                }
                .buttonStyle(.plain)
                .help(loaded && player.isPlaying ? "Pause" : "Abspielen")
                IconButton(systemName: "goforward.15", help: "15 Sekunden vor", size: 15, frameSize: 30) { load(); player.skip(by: 15) }
                PodcastPlayhead(podcastID: podcast.id, fallbackDuration: podcast.duration ?? 0)
                Menu(String(format: "%.2g×", player.rate)) {
                    ForEach([0.8, 1.0, 1.25, 1.5], id: \.self) { rate in
                        Button(String(format: "%.2g×", rate)) { player.rate = Float(rate) }
                    }
                }
                .fixedSize()
                .help("Tempo")
            }
        }
        .onAppear { load() }
    }

    private func load() {
        app.loadPodcastPlayer(podcast.id)
    }
}

/// Time and slider: the only views that read the position at every tick. While the slider is dragged it shows where
/// the hand is, and the player jumps there when it is let go; before, the slider and the ticking position fought.
private struct PodcastPlayhead: View {
    @Environment(AppModel.self) private var app
    let podcastID: UUID
    let fallbackDuration: Double
    @State private var dragged: Double?

    var body: some View {
        let player = app.podcastPlayer
        let loaded = player.podcastID == podcastID
        let duration = loaded ? player.duration : fallbackDuration
        let position = dragged ?? (loaded ? player.currentTime : 0)
        Text(PodcastLength.clock(position))
            .font(.system(size: 11.5).monospacedDigit())
            .foregroundStyle(Theme.textSecondary)
        Slider(value: Binding(get: { position }, set: { dragged = $0 }), in: 0...max(1, duration)) { editing in
            guard !editing, let target = dragged else { return }
            if app.loadPodcastPlayer(podcastID) { app.podcastPlayer.seek(to: target) }
            dragged = nil
        }
        .tint(Theme.accent)
        Text(PodcastLength.clock(duration))
            .font(.system(size: 11.5).monospacedDigit())
            .foregroundStyle(Theme.textSecondary)
    }
}

// MARK: - Cast

private struct PodcastCastCard: View {
    @Environment(AppModel.self) private var app
    let podcast: Podcast
    @State private var suggestionError: String?

    var body: some View {
        let suggesting = app.podcastSuggesting.contains(podcast.id)
        let locked = podcast.phase.isRunning
        PodcastCard("Teilnehmer", symbol: "person.3.fill") {
            HStack(spacing: 6) {
                Button {
                    suggestionError = nil
                    Task {
                        do { try await app.suggestPodcastParticipants(podcast.id) } catch { suggestionError = error.localizedDescription }
                    }
                } label: {
                    if suggesting {
                        HStack(spacing: 5) {
                            ProgressView().controlSize(.mini)
                            Text("Besetzt die Runde …")
                        }
                    } else {
                        Label("KI schlägt vor", systemImage: "sparkles")
                    }
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(suggesting || locked)
                .help("Das Modell leitet aus der Frage eine Moderation und Diskutant:innen mit unterschiedlichen Standpunkten ab")
                Menu {
                    Button("Diskutant:in") { _ = app.addPodcastParticipant(to: podcast.id) }
                    Button("Moderation") { _ = app.addPodcastParticipant(to: podcast.id, role: .moderator) }
                        .disabled(podcast.moderator != nil)
                } label: {
                    Label("Hinzufügen", systemImage: "plus")
                }
                .fixedSize()
                .controlSize(.small)
                .disabled(locked || podcast.participants.count >= 5)
            }
        } content: {
            VStack(spacing: 10) {
                ForEach(podcast.participants) { person in
                    PodcastParticipantRow(podcast: podcast, person: person)
                }
                if let suggestionError {
                    Text(suggestionError)
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.warning)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .disabled(locked)
        }
    }
}

private struct PodcastParticipantRow: View {
    @Environment(AppModel.self) private var app
    let podcast: Podcast
    let person: PodcastParticipant

    var body: some View {
        let color = PodcastSpeakerColor.color(of: person.id, in: podcast)
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: person.role.symbol)
                .font(.system(size: 14))
                .foregroundStyle(color)
                .frame(width: 32, height: 32)
                .background(Circle().fill(color.opacity(0.14)))
            VStack(alignment: .leading, spacing: 7) {
                HStack(spacing: 8) {
                    PodcastField(prompt: "Name", value: person.name, font: .system(size: 14, weight: .semibold)) { name in
                        change { $0.name = name.trimmingCharacters(in: .whitespaces) }
                    }
                    .frame(maxWidth: 180)
                    Picker("Rolle", selection: Binding(get: { person.role }, set: { role in setRole(role) })) {
                        ForEach(PodcastRole.allCases) { Text($0.label).tag($0) }
                    }
                    .labelsHidden()
                    .fixedSize()
                    Picker("Stimme", selection: Binding(get: { person.voice }, set: { voice in change { $0.voice = voice } })) {
                        ForEach(voices, id: \.id) { voice in
                            Text("\(voice.name) · \(voice.gender == "female" ? "weiblich" : "männlich")").tag(voice.id)
                        }
                    }
                    .labelsHidden()
                    .fixedSize()
                    .help("Stimme von Qwen TTS")
                    Spacer(minLength: 0)
                    IconButton(systemName: "trash", help: "Entfernen", size: 11.5, frameSize: 24) {
                        app.podcasts.update(podcast.id) { $0.participants.removeAll { $0.id == person.id } }
                    }
                }
                PodcastField(prompt: "Wer ist das? z. B. Biologin, Physiker, Taxifahrer", value: person.description, font: .system(size: 12.5)) { text in
                    change { $0.description = text }
                }
                PodcastField(prompt: "Standpunkt im Gespräch", value: person.position, axis: .vertical, font: .system(size: 12.5)) { text in
                    change { $0.position = text }
                }
                .lineLimit(1...3)
                .foregroundStyle(Theme.textSecondary)
            }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Theme.elevated))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Theme.border))
    }

    /// The service's voices, and the one set here even if the service doesn't list it (yet).
    private var voices: [QwenTTSClient.Voice] {
        let known = app.podcastVoices
        guard !known.contains(where: { $0.id == person.voice }) else { return known }
        return known + [QwenTTSClient.Voice(id: person.voice, name: person.voice, gender: "", native: "")]
    }

    private func change(_ edit: @escaping (inout PodcastParticipant) -> Void) {
        app.podcasts.update(podcast.id) { podcast in
            guard let index = podcast.participants.firstIndex(where: { $0.id == person.id }) else { return }
            edit(&podcast.participants[index])
        }
    }

    /// One moderator: making someone the moderator makes the former one a discussant.
    private func setRole(_ role: PodcastRole) {
        app.podcasts.update(podcast.id) { podcast in
            for index in podcast.participants.indices {
                if podcast.participants[index].id == person.id {
                    podcast.participants[index].role = role
                } else if role == .moderator, podcast.participants[index].role == .moderator {
                    podcast.participants[index].role = .discussant
                }
            }
        }
    }
}

// MARK: - Own sources

private struct PodcastSourcesCard: View {
    @Environment(AppModel.self) private var app
    let podcast: Podcast
    @State private var address = ""
    @State private var problem: String?

    var body: some View {
        let locked = podcast.phase.isRunning
        PodcastCard("Eigene Quellen", symbol: "doc.richtext") {
            Button("PDF hinzufügen …", systemImage: "doc.badge.plus") {
                let failed = app.choosePodcastPDFs(for: podcast.id)
                problem = failed.isEmpty ? nil : failed.joined(separator: "\n")
            }
            .buttonStyle(.plain)
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(Theme.accent)
            .disabled(locked)
        } content: {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    Image(systemName: "link")
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.textTertiary)
                    TextField("Webadresse einfügen, z. B. https://…", text: $address)
                        .textFieldStyle(.plain)
                        .font(.system(size: 12.5))
                        .onSubmit(add)
                    Button("Hinzufügen", action: add)
                        .controlSize(.small)
                        .disabled(address.trimmingCharacters(in: .whitespaces).isEmpty)
                }
                .padding(8)
                .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Theme.well))
                .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Theme.border))
                ForEach(podcast.ownSources.entries, id: \.self) { entry in
                    HStack(spacing: 8) {
                        Image(systemName: isPDF(entry) ? "doc.text" : "globe")
                            .font(.system(size: 12))
                            .foregroundStyle(Theme.accent)
                            .frame(width: 18)
                        Text(entry.label)
                            .font(.system(size: 12.5))
                            .foregroundStyle(Theme.textPrimary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Text(isPDF(entry) ? "PDF" : "Webseite")
                            .font(.system(size: 11))
                            .foregroundStyle(Theme.textTertiary)
                        Spacer(minLength: 0)
                        IconButton(systemName: "xmark", help: "Quelle entfernen", size: 10, frameSize: 22) {
                            app.removePodcastSource(entry, from: podcast.id)
                        }
                    }
                }
                Toggle(isOn: Binding(get: { podcast.ownSources.onlyThese }, set: { on in app.podcasts.update(podcast.id) { $0.ownSources.onlyThese = on } })) {
                    VStack(alignment: .leading, spacing: 1) {
                        Text("Nur aus diesen Quellen")
                            .font(.system(size: 12.5, weight: .medium))
                        Text("Keine Web- und Wikipedia-Suche: Faktenblatt und Gespräch stützen sich allein auf die Seiten und PDFs oben.")
                            .font(.system(size: 11))
                            .foregroundStyle(Theme.textTertiary)
                    }
                }
                .toggleStyle(.checkbox)
                if podcast.ownSources.entries.isEmpty && !podcast.ownSources.onlyThese {
                    Text("Ohne eigene Quellen recherchiert das Modell selbst. Mitgegebene Seiten und PDFs liest es zuerst.")
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.textTertiary)
                }
                if let problem {
                    Text(problem)
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.warning)
                }
            }
            .disabled(locked)
        }
    }

    private func isPDF(_ entry: PodcastOwnSources.Entry) -> Bool {
        if case .pdf = entry { return true }
        return false
    }

    private func add() {
        problem = app.addPodcastSource(url: address, to: podcast.id)
        if problem == nil { address = "" }
    }
}

// MARK: - References

private struct PodcastReferencesCard: View {
    @Environment(AppModel.self) private var app
    let podcast: Podcast

    var body: some View {
        PodcastCard("Referenzen", symbol: "link") {
            PodcastReferenceMenu(existing: podcast.references, add: { app.addPodcastReference($0, to: podcast.id) }) {
                Label("Hinzufügen", systemImage: "plus")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Theme.accent)
            }
            .disabled(podcast.phase.isRunning)
        } content: {
            if podcast.references.isEmpty {
                Text("Chats, Dokumente, Präsentationen oder Teile einer Romanwelt, auf die sich das Gespräch stützen soll.")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.textTertiary)
            } else {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(podcast.references, id: \.self) { reference in
                        HStack(spacing: 8) {
                            Image(systemName: app.podcastReferenceSymbol(reference))
                                .font(.system(size: 12))
                                .foregroundStyle(Theme.accent)
                                .frame(width: 18)
                            Button {
                                app.openPodcastReference(reference)
                            } label: {
                                Text(app.podcastReferenceTitle(reference) ?? "Nicht mehr vorhanden")
                                    .font(.system(size: 12.5))
                                    .foregroundStyle(app.podcastReferenceTitle(reference) == nil ? Theme.textTertiary : Theme.textPrimary)
                                    .lineLimit(1)
                            }
                            .buttonStyle(.plain)
                            .help("Öffnen")
                            Text(app.podcastReferenceKind(reference))
                                .font(.system(size: 11))
                                .foregroundStyle(Theme.textTertiary)
                            Spacer(minLength: 0)
                            IconButton(systemName: "xmark", help: "Referenz entfernen", size: 10, frameSize: 22) {
                                app.removePodcastReference(reference, from: podcast.id)
                            }
                            .disabled(podcast.phase.isRunning)
                        }
                    }
                }
            }
        }
    }
}

// MARK: - Research

private struct PodcastResearchCard: View {
    let podcast: Podcast
    @State private var expanded = false

    var body: some View {
        PodcastCard("Recherche", symbol: "magnifyingglass") {
            Button(expanded ? "Einklappen" : "Faktenblatt zeigen") { withAnimation(.easeInOut(duration: 0.2)) { expanded.toggle() } }
                .buttonStyle(.plain)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Theme.accent)
        } content: {
            VStack(alignment: .leading, spacing: 10) {
                if expanded {
                    MarkdownView(text: podcast.research.notes)
                        .textSelection(.enabled)
                } else {
                    Text(PodcastPrompts.shortened(podcast.research.notes.replacingOccurrences(of: "#", with: "").replacingOccurrences(of: "**", with: ""), to: 260))
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.textSecondary)
                        .lineLimit(4)
                }
                if !podcast.research.sources.isEmpty {
                    Text("Gelesene Quellen")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Theme.textTertiary)
                    ForEach(podcast.research.sources, id: \.url) { source in
                        if let url = URL(string: source.url) {
                            Link(destination: url) {
                                Label(source.title.isEmpty ? source.url : source.title, systemImage: source.url.contains("wikipedia.org") ? "w.square" : "globe")
                                    .font(.system(size: 12))
                                    .lineLimit(1)
                            }
                            .help(source.url)
                        }
                    }
                }
            }
        }
    }
}

// MARK: - Script

private struct PodcastScriptCard: View {
    @Environment(AppModel.self) private var app
    let podcast: Podcast
    /// The script scrolls along with the spoken line; scrolling by hand switches that off until it is switched on again.
    @State private var follows = true

    var body: some View {
        let player = app.podcastPlayer
        let starts = podcast.lineStarts
        let audioCurrent = app.isPodcastAudioCurrent(podcast)
        let playing = player.podcastID == podcast.id ? player.currentLine : nil
        PodcastCard("Skript", symbol: "text.bubble") {
            HStack(spacing: 10) {
                Text("\(podcast.scriptWords) von etwa \(podcast.targetWords) Wörtern")
                    .font(.system(size: 11).monospacedDigit())
                    .foregroundStyle(Theme.textTertiary)
                if audioCurrent {
                    Toggle("Mitlaufen", isOn: $follows)
                        .toggleStyle(.checkbox)
                        .font(.system(size: 11.5))
                        .help("Das Skript zeigt beim Abspielen die gesprochene Zeile")
                }
                Button("Kopieren", systemImage: "doc.on.doc") { app.copyToPasteboard(podcast.scriptText) }
                    .buttonStyle(.plain)
                    .font(.system(size: 11.5))
                    .foregroundStyle(Theme.accent)
                Button("Als Dokument", systemImage: StudioApplication.writer.symbol) { app.openPodcastAsDocument(podcast.id) }
                    .buttonStyle(.plain)
                    .font(.system(size: 11.5))
                    .foregroundStyle(Theme.accent)
                    .help("Ein Writer-Dokument mit Teilnehmern, Gespräch, Faktenblatt und Quellen anlegen")
            }
        } content: {
            ScrollViewReader { proxy in
                LazyVStack(alignment: .leading, spacing: 8) {
                    ForEach(podcast.script) { line in
                        let speaker = podcast.participant(line.speaker)
                        PodcastLineRow(
                            podcastID: podcast.id, line: line, speakerName: speaker?.displayName ?? "?",
                            color: PodcastSpeakerColor.color(of: line.speaker, in: podcast),
                            participants: podcast.participants, isPlaying: playing == line.id,
                            start: audioCurrent ? starts[line.id] : nil, locked: podcast.phase.isRunning
                        )
                        .equatable()
                        .id(line.id)
                    }
                }
                .onChange(of: playing) { _, id in
                    guard follows, let id, player.isPlaying else { return }
                    proxy.scrollTo(id, anchor: .center)
                }
            }
        }
    }
}

/// One line of the script. Equatable, so a line is only drawn again when it or its highlight changes.
private struct PodcastLineRow: View, Equatable {
    @Environment(AppModel.self) private var app
    let podcastID: UUID
    let line: PodcastLine
    let speakerName: String
    let color: Color
    let participants: [PodcastParticipant]
    let isPlaying: Bool
    let start: Double?
    let locked: Bool
    @State private var editing = false
    @State private var hovering = false

    nonisolated static func == (a: Self, b: Self) -> Bool {
        a.podcastID == b.podcastID && a.line == b.line && a.speakerName == b.speakerName && a.color == b.color
            && a.participants == b.participants && a.isPlaying == b.isPlaying && a.start == b.start && a.locked == b.locked
    }

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            VStack(alignment: .trailing, spacing: 2) {
                Text(speakerName)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(color)
                    .lineLimit(1)
                if let start {
                    Button(PodcastLength.clock(start)) {
                        guard app.loadPodcastPlayer(podcastID) else { return }
                        app.podcastPlayer.seek(to: start)
                        app.podcastPlayer.play()
                    }
                    .buttonStyle(.plain)
                    .font(.system(size: 10.5).monospacedDigit())
                    .foregroundStyle(Theme.textTertiary)
                    .help("Ab hier abspielen")
                }
            }
            .frame(width: 92, alignment: .trailing)
            if editing {
                PodcastField(prompt: "Text", value: line.text, axis: .vertical, font: .system(size: 13)) { text in
                    let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !text.isEmpty else { return }
                    app.podcasts.update(podcastID) { podcast in
                        guard let index = podcast.script.firstIndex(where: { $0.id == line.id }) else { return }
                        podcast.script[index].text = text
                    }
                }
                .onSubmit { editing = false }
                .onExitCommand { editing = false }
            } else {
                // No text selection here: a selectable text per line made long scripts slow ("Kopieren" takes it all).
                Text(line.text)
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.textPrimary)
                    .lineSpacing(2)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                    .onTapGesture(count: 2) { if !locked { editing = true } }
            }
            Menu {
                Button(editing ? "Fertig" : "Bearbeiten", systemImage: "pencil") { editing.toggle() }
                Menu("Sprecher:in") {
                    ForEach(participants) { person in
                        Button(person.displayName) { setSpeaker(person.id) }
                    }
                }
                Divider()
                Button("Zeile löschen", systemImage: "trash", role: .destructive) {
                    app.podcasts.update(podcastID) { $0.script.removeAll { $0.id == line.id } }
                }
            } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Theme.textSecondary)
                    .frame(width: 20, height: 20)
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
            .fixedSize()
            .opacity(hovering && !locked ? 1 : 0)
            .disabled(locked)
        }
        .padding(.vertical, 6)
        .padding(.horizontal, 8)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(isPlaying ? color.opacity(0.12) : (hovering ? Theme.hover : .clear)))
        .overlay(alignment: .leading) {
            if isPlaying { RoundedRectangle(cornerRadius: 1.5).fill(color).frame(width: 3).padding(.vertical, 4) }
        }
        .onHover { hovering = $0 }
    }

    private func setSpeaker(_ id: UUID) {
        app.podcasts.update(podcastID) { podcast in
            guard let index = podcast.script.firstIndex(where: { $0.id == line.id }) else { return }
            podcast.script[index].speaker = id
        }
    }
}
