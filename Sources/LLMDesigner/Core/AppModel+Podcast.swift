import AppKit
import PDFKit
import SwiftUI
import UniformTypeIdentifiers

/// Where a start of a podcast begins: from what is missing, or anew from a step.
enum PodcastStart: String, CaseIterable, Sendable {
    /// Whatever is missing: research, script, the lines not spoken yet.
    case resume = "fortsetzen"
    /// Everything anew, research included.
    case everything = "alles"
    /// The script anew on the research there is (and then the audio).
    case script = "skript"
    /// Only the audio: every line spoken anew.
    case audio = "audio"
}

/// How far a running podcast is, for the sidebar and the studio. Not stored: after a restart the phase says enough.
struct PodcastProgress: Equatable {
    var fraction: Double = 0
    var detail = ""
    /// What the research looked up, newest last.
    var lookups: [String] = []
}

/// PodcastStudio takes the main area like the other studios; every podcast is an entry of the sidebar.
extension AppModel {
    static let podcastLastKey = "podcastLast"

    // MARK: Opening

    func openPodcastStudio(showing id: UUID? = nil) {
        closeDocument()
        showChats()
        podcasts.loadIfNeeded()
        loadPodcastVoices()
        if let id, podcasts.podcast(id) != nil {
            selectedPodcastID = id
            noteSidebarActivity(id)
        } else if id == nil, selectedPodcastID == nil {
            selectedPodcastID = settings.string(forKey: Self.podcastLastKey).flatMap(UUID.init(uuidString:)).flatMap { podcasts.podcast($0)?.id }
        }
        podcastStudioOpen = true
    }

    /// From the sidebar: the podcast opens in the studio; a second click on it goes back to the chat.
    func selectPodcast(_ id: UUID) {
        guard !(podcastStudioOpen && selectedPodcastID == id) else { return showChats() }
        openPodcastStudio(showing: id)
    }

    func closePodcastStudio() {
        podcastPlayer.stop()
        podcasts.saveAll()
        if let selectedPodcastID { settings.set(selectedPodcastID.uuidString, forKey: Self.podcastLastKey) }
        podcastStudioOpen = false
    }

    /// The voices of the Qwen TTS service; the built-in list until it answers.
    func loadPodcastVoices() {
        guard !podcastVoicesLoaded else { return }
        podcastVoicesLoaded = true
        let server = podcastSpeechServer
        Task { [weak self] in
            if let voices = try? await QwenTTSClient(baseURL: server).voices(), !voices.isEmpty { self?.podcastVoices = voices }
        }
    }

    // MARK: Making and removing

    /// A new podcast with the standard cast, at the top of the sidebar (in the folder new chats go to).
    @discardableResult
    func newPodcast(question: String = "", title: String = "", references: [PodcastReference] = [], minutes: Int = PodcastLength.standard,
                    participants: [PodcastParticipant]? = nil, folderID: Folder.ID? = nil, open: Bool = true) -> Podcast {
        podcasts.loadIfNeeded()
        var podcast = Podcast(title: title, question: question)
        podcast.minutes = PodcastLength.choices.contains(minutes) ? minutes : PodcastLength.standard
        podcast.references = references
        podcast.participants = participants ?? PodcastParticipant.defaultCast()
        podcast.folderID = folderID ?? newChatFolderID
        podcasts.add(podcast)
        if let folder = podcast.folderID { expandFolder(folder) }
        if open { openPodcastStudio(showing: podcast.id) }
        return podcast
    }

    /// A podcast about a document, a presentation, a novel world or one of its parts, or a chat (the toolbars of the
    /// studios). The question is a start the person can change before it begins.
    @discardableResult
    func newPodcast(about reference: PodcastReference, open: Bool = true) -> Podcast {
        let title = podcastReferenceTitle(reference) ?? "Unbenannt"
        let question: String = switch reference {
        case .document(let id) where document(id)?.isPresentation == true:
            "Worum geht es in der Präsentation „\(title)“, und was ist davon zu halten?"
        case .document:
            "Worum geht es in „\(title)“, und was ist davon zu halten?"
        case .story(_, let part) where part != nil:
            "„\(title)“: Was passiert hier, und warum ist es für die Geschichte wichtig?"
        case .story:
            "Die Welt von „\(title)“: Worum geht es, und was macht die Geschichte spannend?"
        case .chat:
            "Worum ging es im Chat „\(title)“, und was folgt daraus?"
        }
        return newPodcast(question: question, title: "Podcast: \(podcastReferenceShortTitle(reference) ?? title)", references: [reference], open: open)
    }

    func renamePodcast(_ id: UUID, to title: String) {
        podcasts.update(id) { $0.title = title.trimmingCharacters(in: .whitespacesAndNewlines) }
    }

    func movePodcast(_ id: UUID, to folderID: Folder.ID?, reveal: Bool = true) {
        guard let podcast = podcasts.podcast(id), podcast.folderID != folderID else { return }
        podcasts.update(id, touch: false) { $0.folderID = folderID }
        if reveal, let folderID { expandFolder(folderID) }
    }

    func movePodcastToNewFolder(_ id: UUID) {
        movePodcast(id, to: createFolder(for: .chats))
    }

    /// Into the Trash with its audio; ⌘Z brings it back.
    func deletePodcast(_ id: UUID, undo undoManager: UndoManager? = nil) {
        stopPodcast(id)
        if podcastPlayer.podcastID == id { podcastPlayer.stop() }
        guard let (podcast, trashed) = podcasts.delete(id) else { return }
        if selectedPodcastID == id { selectedPodcastID = nil }
        guard let undoManager else { return }
        undoManager.registerUndo(withTarget: podcasts) { library in
            MainActor.assumeIsolated { library.restore(podcast, from: trashed) }
        }
        undoManager.setActionName("Podcast löschen")
    }

    // MARK: References

    func podcastReferenceTitle(_ reference: PodcastReference) -> String? {
        switch reference {
        case .chat(let id): chat(id)?.title
        case .document(let id): noteOwnerTitle(.document(id))
        case .story(let world, let part): noteOwnerTitle(.story(world: world, part: part))
        }
    }

    func podcastReferenceShortTitle(_ reference: PodcastReference) -> String? {
        switch reference {
        case .chat(let id): chat(id)?.title
        case .document(let id): noteOwnerShortTitle(.document(id))
        case .story(let world, let part): noteOwnerShortTitle(.story(world: world, part: part))
        }
    }

    func podcastReferenceSymbol(_ reference: PodcastReference) -> String {
        switch reference {
        case .chat: "bubble.left"
        case .document(let id): noteOwnerSymbol(.document(id))
        case .story(let world, let part): noteOwnerSymbol(.story(world: world, part: part))
        }
    }

    func podcastReferenceKind(_ reference: PodcastReference) -> String {
        switch reference {
        case .chat: "Chat"
        case .document(let id): noteOwnerKind(.document(id))
        case .story(let world, let part): noteOwnerKind(.story(world: world, part: part))
        }
    }

    func openPodcastReference(_ reference: PodcastReference) {
        switch reference {
        case .chat(let id):
            guard chat(id) != nil else { return }
            closeDocument()
            selectChat(id)
        case .document(let id):
            openNoteOwner(.document(id))
        case .story(let world, let part):
            openNoteOwner(.story(world: world, part: part))
        }
    }

    func addPodcastReference(_ reference: PodcastReference, to id: UUID) {
        podcasts.update(id) { podcast in
            if !podcast.references.contains(reference) { podcast.references.append(reference) }
        }
    }

    func removePodcastReference(_ reference: PodcastReference, from id: UUID) {
        podcasts.update(id) { $0.references.removeAll { $0 == reference } }
    }

    /// The material of the references as text for the model, each cut to its share of `limit` characters.
    func podcastReferenceText(_ references: [PodcastReference], limit: Int = 12_000) -> String {
        let texts = references.compactMap { reference -> String? in
            guard let text = podcastText(of: reference)?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { return nil }
            return "### \(podcastReferenceKind(reference)): \(podcastReferenceTitle(reference) ?? "")\n" + text
        }
        guard !texts.isEmpty else { return "" }
        let share = max(1_500, limit / texts.count)
        return texts.map { PodcastPrompts.shortened($0, to: share) }.joined(separator: "\n\n")
    }

    private func podcastText(of reference: PodcastReference) -> String? {
        switch reference {
        case .chat(let id):
            return chat(id).map(transcript(of:))
        case .document(let id):
            guard let document = document(id) else { return nil }
            if let deck = document.deck {
                return deck.slides.map { slide in
                    let notes = slide.notes.trimmingCharacters(in: .whitespacesAndNewlines)
                    return slide.markdown + (notes.isEmpty ? "" : "\n(Sprechernotiz: \(notes))")
                }.joined(separator: "\n\n")
            }
            return document.markdown
        case .story(let worldID, let partID):
            stories.loadIfNeeded()
            guard let world = stories.world(worldID) else { return nil }
            var lines: [String] = []
            func add(_ label: String, _ text: String) {
                let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
                if !text.isEmpty { lines.append("\(label): \(text)") }
            }
            if let partID {
                guard let part = world.part(partID) else { return nil }
                add("Romanwelt", world.displayTitle)
                add(part.level.label, world.displayTitle(of: part))
                for kind in StoryElementKind.allCases { add(kind.question, part.focus.text(kind)) }
                add("Notizen", part.notes)
                if !part.children.isEmpty { add("Enthält", part.children.map { world.displayTitle(of: $0) }.joined(separator: ", ")) }
                if let manuscript = part.manuscriptID.flatMap({ document($0) }) { add("Text", manuscript.markdown) }
            } else {
                add("Romanwelt", world.displayTitle)
                add("Genre", world.genre)
                add("Prämisse", world.logline)
                add("Überblick", world.overview)
                add("Regeln der Welt", world.rules)
                add("Themen", world.themes)
                add("Bücher", world.books.map { world.displayTitle(of: $0) }.joined(separator: ", "))
                for kind in StoryElementKind.allCases {
                    let items = world.summaries(of: kind).prefix(12).map { $0.subtitle.isEmpty ? $0.name : "\($0.name) (\($0.subtitle))" }
                    add(kind.title, items.joined(separator: "; "))
                }
            }
            return lines.joined(separator: "\n")
        }
    }

    // MARK: Participants

    /// The model proposes a cast for the question: a moderator and discussants with differing positions, each with
    /// a voice of its own.
    func suggestPodcastParticipants(_ id: UUID, count: Int = 3) async throws {
        guard let podcast = podcasts.podcast(id) else { return }
        guard let client, let model = preferredModelId ?? currentModelId else { throw LLMError.server("Kein Modell gewählt. Wähle eines unten links in der Seitenleiste.") }
        let question = podcast.question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !question.isEmpty || !podcast.references.isEmpty else { throw LLMError.server("Gib zuerst eine Frage oder ein Thema ein.") }
        podcastSuggesting.insert(id)
        defer { podcastSuggesting.remove(id) }
        let answer = try await client.complete(
            model: model,
            messages: PodcastPrompts.castMessages(question: question.isEmpty ? podcast.displayTitle : question,
                                                  references: podcastReferenceText(podcast.references, limit: 3_000),
                                                  research: podcast.research.notes, tone: podcast.tone, language: podcast.language, count: min(4, max(2, count))),
            temperature: 0.7, maxTokens: 1_500, orderedSchema: ("besetzung", PodcastPrompts.castSchema)
        )
        let cast = try JSONDecoder().decode(PodcastPrompts.Cast.self, from: Data(ContentAnalysisBuilder.jsonObject(in: answer).utf8))
        let people = PodcastPrompts.participants(from: cast, voices: podcastVoices.map(\.id))
        guard people.count >= 2 else { throw LLMError.server("Das Modell hat keine brauchbare Besetzung geliefert.") }
        podcasts.update(id) { $0.participants = people }
    }

    func addPodcastParticipant(to id: UUID, role: PodcastRole = .discussant) -> PodcastParticipant? {
        guard let podcast = podcasts.podcast(id) else { return nil }
        let voice = PodcastParticipant.freeVoice(female: nil, taken: podcast.participants.map(\.voice), available: podcastVoices.map(\.id))
        let person = PodcastParticipant(role: role, name: "", voice: voice)
        podcasts.update(id) { $0.participants.append(person) }
        return person
    }

    // MARK: Running

    /// Starts making a podcast in the background; with another one running it waits. Returns why it can't start.
    @discardableResult
    func startPodcast(_ id: UUID, from start: PodcastStart = .resume) -> String? {
        guard let podcast = podcasts.podcast(id) else { return "Den Podcast gibt es nicht mehr." }
        guard !podcast.phase.isRunning else { return nil }
        if let problem = podcast.startProblem { return problem }
        guard client != nil, preferredModelId ?? currentModelId != nil else { return "Kein Modell gewählt. Wähle eines unten links in der Seitenleiste." }
        podcasts.update(id) { podcast in
            podcast.phase = .queued
            podcast.error = nil
        }
        podcastStarts[id] = start
        podcastProgress[id] = PodcastProgress(fraction: 0, detail: "Wartet auf den Start")
        if !podcastQueue.contains(id) { podcastQueue.append(id) }
        runNextPodcast()
        return nil
    }

    func stopPodcast(_ id: UUID) {
        if runningPodcastID == id {
            podcastTask?.cancel()
        } else if podcastQueue.contains(id) {
            podcastQueue.removeAll { $0 == id }
            podcastProgress[id] = nil
            podcasts.update(id, touch: false) { $0.phase = .stopped }
        }
    }

    func stopAllPodcasts() {
        for id in podcastQueue { podcasts.update(id, touch: false) { $0.phase = .stopped } }
        podcastQueue = []
        podcastTask?.cancel()
    }

    /// One podcast at a time: the model and the voice run on this Mac, and two at once would only take twice as long.
    private func runNextPodcast() {
        guard runningPodcastID == nil, let id = podcastQueue.first else { return }
        podcastQueue.removeFirst()
        guard podcasts.podcast(id) != nil else { return runNextPodcast() }
        runningPodcastID = id
        let start = podcastStarts.removeValue(forKey: id) ?? .resume
        podcastTask = Task { [weak self] in
            await self?.producePodcast(id, from: start)
            guard let self else { return }
            self.runningPodcastID = nil
            self.podcastTask = nil
            self.runNextPodcast()
        }
    }

    private func setPodcastProgress(_ id: UUID, _ fraction: Double, _ detail: String) {
        var progress = podcastProgress[id] ?? PodcastProgress()
        progress.fraction = min(1, max(0, fraction))
        progress.detail = detail
        podcastProgress[id] = progress
    }

    private func producePodcast(_ id: UUID, from start: PodcastStart) async {
        do {
            guard let client, let modelID = preferredModelId ?? currentModelId else { throw LLMError.server("Kein Modell gewählt.") }
            let model = models.first { $0.id == modelID } ?? LMModel(id: modelID)
            guard var podcast = podcasts.podcast(id) else { return }

            if start == .everything || (start == .resume && podcast.research.isEmpty) {
                podcasts.update(id, touch: false) { $0.phase = .researching }
                let research = try await researchPodcast(podcast, client: client, model: model)
                podcasts.update(id, touch: false) { $0.research = research }
            }
            podcast = podcasts.podcast(id) ?? podcast
            try Task.checkCancellation()

            if start == .everything || start == .script || (start == .resume && podcast.script.isEmpty) {
                podcasts.update(id, touch: false) { podcast in
                    podcast.phase = .scripting
                    podcast.script = []
                    podcast.outline = []
                    podcast.duration = nil
                }
                try await writePodcastScript(id, client: client, model: model)
            }
            try Task.checkCancellation()

            podcasts.update(id, touch: false) { podcast in
                podcast.phase = .speaking
                if start == .audio { for index in podcast.script.indices { podcast.script[index].duration = nil } }
            }
            try await speakPodcast(id, anew: start == .audio)
            podcasts.update(id) { podcast in
                podcast.phase = .finished
                podcast.error = nil
            }
            podcastProgress[id] = nil
        } catch {
            let cancelled = Task.isCancelled || error is CancellationError || (error as? URLError)?.code == .cancelled
            podcasts.update(id, touch: false) { podcast in
                podcast.phase = cancelled ? .stopped : .failed
                podcast.error = cancelled ? nil : error.localizedDescription
            }
            podcastProgress[id] = nil
        }
        podcasts.saveNow(id)
    }

    // MARK: Research

    private struct PodcastRound {
        var content: String
        var calls: [ToolCall]
    }

    /// One answer of the model, with thinking on where it can be switched; the thinking itself is dropped.
    /// `thinking` switches it where the server allows (Kapitsa); Qwen in LM Studio thinks regardless.
    private func podcastRound(_ client: LLMClient, model: String, messages: [ChatPayloadMessage], tools: [ToolDefinition]?, temperature: Double, thinking: Bool) async throws -> PodcastRound {
        var raw = ""
        var calls: [ToolCall] = []
        for try await event in client.streamChat(model: model, messages: messages, temperature: temperature, tools: tools, thinking: thinking) {
            switch event {
            case .content(let text): raw += text
            case .toolCalls(let requested): calls = requested
            default: break
            }
            try Task.checkCancellation()
        }
        var content = ThinkingSplitter.split(raw).content
        if let leaked = WebTools.leakedCallStart(in: content) { content = String(content[..<leaked]) }
        return PodcastRound(content: content.trimmingCharacters(in: .whitespacesAndNewlines), calls: calls)
    }

    /// Gemma 4 thinks only with its token at the start of the system prompt.
    private func withThinking(_ messages: [ChatPayloadMessage], client: LLMClient, model: LMModel, thinking: Bool) -> [ChatPayloadMessage] {
        guard thinking, !client.provider.switchesThinking, model.thinksOnThinkToken, let first = messages.first, first.role == "system" else { return messages }
        var messages = messages
        messages[0].content = "<|think|>" + first.content
        return messages
    }

    /// The model looks things up in Wikipedia and on the web, several rounds, and writes a fact sheet. The same rules
    /// as in a chat hold: pages only from search results or the question, and found text is framed as foreign.
    private func researchPodcast(_ podcast: Podcast, client: LLMClient, model: LMModel) async throws -> PodcastResearch {
        let id = podcast.id
        let contextTokens = model.workingContextLength ?? 16_384
        // The person's own pages and PDFs first: with "nur diese" they are all there is.
        let own = await readOwnSources(podcast, limit: podcast.ownSources.onlyThese ? max(12_000, contextTokens * 2) : max(6_000, contextTokens / 2))
        if podcast.ownSources.onlyThese {
            return try await researchFromOwnSources(podcast, own: own, client: client, model: model)
        }
        let chats = podcast.references.compactMap { reference -> Chat? in
            if case .chat(let chatID) = reference { return chat(chatID) } else { return nil }
        }
        var evidence = WebToolGuard.ChatEvidence(messages: chats.flatMap(\.messages))
        evidence.trusted += Array(WebToolGuard.addresses(in: podcast.question))
        // The addresses the person gave may be opened again.
        evidence.trusted += podcast.ownSources.entries.compactMap { entry in
            if case .url(let address) = entry { return NormalizedAddress(address) } else { return nil }
        }
        // A referenced chat read a persona's files: search terms could carry them out, so only Wikipedia is asked.
        let sources: WebTools.Sources = evidence.hasReadPersonaFiles ? [.wikipedia] : [.web, .wikipedia]
        let tools = WebTools.definitions(for: sources)
        var references = podcastReferenceText(podcast.references)
        if !own.text.isEmpty { references += (references.isEmpty ? "" : "\n\n") + own.text }
        var messages = withThinking(ChatPayloadBuilder.messages(
            system: PodcastPrompts.researchSystem(language: podcast.language),
            hints: [WebTools.systemHint(for: sources), ForeignFrame.hint],
            thinkToken: false,
            history: [ChatPayloadMessage(role: "user", content: PodcastPrompts.researchRequest(podcast, references: references.isEmpty ? "" : ForeignFrame.wrap(references)))]
        ), client: client, model: model, thinking: podcast.thinking)

        let resultLimit = min(8_000, max(2_500, contextTokens / 2))
        var budget = max(6_000, contextTokens * 4 / 3)
        var found: [PodcastSource] = own.sources
        var lookups = 0
        var nudged = false
        var notes = ""
        setPodcastProgress(id, 0.02, "Recherche beginnt")

        for round in 0..<PodcastPrompts.researchRounds {
            let last = round == PodcastPrompts.researchRounds - 1 || budget < 1_500
            if last, round > 0 { messages.append(ChatPayloadMessage(role: "user", content: PodcastPrompts.researchFinish)) }
            let answer = try await podcastRound(client, model: model.id, messages: messages, tools: last ? nil : tools, temperature: 0.4, thinking: podcast.thinking)
            if answer.calls.isEmpty || last {
                if !last, lookups < PodcastPrompts.minimumLookups, !nudged {
                    nudged = true
                    messages.append(ChatPayloadMessage(role: "assistant", content: answer.content))
                    messages.append(ChatPayloadMessage(role: "user", content: PodcastPrompts.researchNudge))
                    continue
                }
                notes = answer.content
                break
            }
            messages.append(ChatPayloadMessage(role: "assistant", content: answer.content, toolCalls: answer.calls))
            for (position, call) in answer.calls.enumerated() {
                try Task.checkCancellation()
                var output: String
                if position >= WebTools.maxCallsPerRound {
                    output = WebTools.skippedOutput
                } else if budget < 800 {
                    output = WebTools.budgetExhaustedOutput
                } else if let step = WebTools.step(for: call, allowed: sources) {
                    let label = Self.podcastLookupLabel(step)
                    podcastProgress[id, default: PodcastProgress()].lookups.append(label)
                    setPodcastProgress(id, 0.03 + 0.17 * Double(round + 1) / Double(PodcastPrompts.researchRounds), label)
                    switch WebToolGuard.verdict(for: step, evidence: evidence) {
                    case .denied(let refusal):
                        output = refusal
                    case .needsConsent:
                        output = "Nicht ausgeführt: Das ist im Podcast nicht erlaubt. Recherchiere mit Wikipedia."
                    case .allowed:
                        let (finished, text) = await WebTools.execute(step, limit: min(resultLimit, budget), readerFallback: webReaderFallback)
                        if finished.status == .done {
                            lookups += 1
                            if step.kind == .search || step.kind.isWikipedia {
                                evidence.trusted += (finished.sources ?? []).compactMap { NormalizedAddress($0.url) }
                            }
                            if step.kind.readsPage {
                                for source in finished.sources ?? [] where !found.contains(where: { $0.url == source.url }) {
                                    found.append(PodcastSource(title: source.title, url: source.url))
                                }
                            }
                        }
                        output = finished.status == .done ? ForeignFrame.wrap(text) : text
                        budget -= output.count
                    }
                } else {
                    output = WebTools.unknownToolOutput(call, available: tools)
                }
                messages.append(ChatPayloadMessage(role: "tool", content: output, toolCallID: call.id))
            }
        }
        guard !notes.isEmpty else { throw LLMError.server("Die Recherche hat kein Faktenblatt ergeben.") }
        // Links in the fact sheet count as sources too, when the model read them.
        setPodcastProgress(id, 0.2, "Faktenblatt fertig")
        return PodcastResearch(notes: notes, sources: found)
    }

    /// The text of the person's own sources, each cut to its share of `limit`, framed as foreign; and what was read.
    func readOwnSources(_ podcast: Podcast, limit: Int) async -> (text: String, sources: [PodcastSource], failures: [String]) {
        let entries = podcast.ownSources.entries
        guard !entries.isEmpty else { return ("", [], []) }
        let share = max(2_000, limit / entries.count)
        var parts: [String] = []
        var read: [PodcastSource] = []
        var failures: [String] = []
        for (number, entry) in entries.enumerated() {
            if Task.isCancelled { break }
            setPodcastProgress(podcast.id, 0.02 + 0.06 * Double(number) / Double(entries.count), "Quelle: \(entry.label)")
            podcastProgress[podcast.id, default: PodcastProgress()].lookups.append("Quelle: \(entry.label)")
            switch entry {
            case .url(let address):
                do {
                    let page = try await PageReader(useReaderFallback: webReaderFallback).read(address)
                    parts.append("### \(page.title ?? page.url)\n(\(page.url))\n" + PodcastPrompts.shortened(page.text, to: share))
                    read.append(PodcastSource(title: page.title ?? page.url, url: page.url))
                } catch {
                    failures.append("\(address): \(error.localizedDescription)")
                }
            case .pdf(let title, let file):
                guard let url = podcasts.store.sourceURL(of: podcast.id, file: file),
                      let text = await Task.detached(priority: .utility, operation: { PDFDocument(url: url)?.string }).value,
                      !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    failures.append("\(entry.label): kein lesbarer Text im PDF")
                    continue
                }
                parts.append("### \(entry.label)\n" + PodcastPrompts.shortened(text, to: share))
                read.append(PodcastSource(title: title.isEmpty ? entry.label : title, url: url.absoluteString))
            }
        }
        let text = parts.isEmpty ? "" : ForeignFrame.wrap(parts.joined(separator: "\n\n"))
        return (text, read, failures)
    }

    /// "Nur aus diesen Quellen": no search at all; the fact sheet holds what the given pages and PDFs say.
    private func researchFromOwnSources(_ podcast: Podcast, own: (text: String, sources: [PodcastSource], failures: [String]), client: LLMClient, model: LMModel) async throws -> PodcastResearch {
        guard !own.text.isEmpty else {
            throw LLMError.server("Keine der Quellen ließ sich lesen. " + own.failures.joined(separator: "; "))
        }
        setPodcastProgress(podcast.id, 0.1, "Faktenblatt aus den Quellen")
        let messages = withThinking([
            ChatPayloadMessage(role: "system", content: PodcastPrompts.ownSourcesSystem(language: podcast.language) + "\n\n" + ForeignFrame.hint),
            ChatPayloadMessage(role: "user", content: PodcastPrompts.ownSourcesRequest(podcast, sources: own.text, failures: own.failures)),
        ], client: client, model: model, thinking: podcast.thinking)
        let answer = try await podcastRound(client, model: model.id, messages: messages, tools: nil, temperature: 0.3, thinking: podcast.thinking)
        guard !answer.content.isEmpty else { throw LLMError.server("Aus den Quellen ist kein Faktenblatt entstanden.") }
        setPodcastProgress(podcast.id, 0.2, "Faktenblatt fertig")
        return PodcastResearch(notes: answer.content, sources: own.sources)
    }

    static func podcastLookupLabel(_ step: ToolStep) -> String {
        switch step.kind {
        case .wikiSearch: "Wikipedia-Suche: \(step.argument)"
        case .wikiArticle: "Wikipedia: \(step.argument)" + (step.section.map { " › \($0)" } ?? "")
        case .search: "Websuche: \(step.argument)"
        case .openPage: "Seite: \(step.argument)"
        default: step.argument
        }
    }

    // MARK: Script

    /// The plan first, then the conversation section by section, each to its share of the words. A section that came
    /// out much too short is continued once.
    private func writePodcastScript(_ id: UUID, client: LLMClient, model: LMModel) async throws {
        guard let podcast = podcasts.podcast(id) else { return }
        setPodcastProgress(id, 0.21, "Gliederung")
        let references = podcastReferenceText(podcast.references, limit: 3_000)
        let plan = try await podcastRound(client, model: model.id,
                                          messages: withThinking(PodcastPrompts.outlineMessages(podcast, references: references.isEmpty ? "" : ForeignFrame.wrap(references)), client: client, model: model, thinking: podcast.thinking),
                                          tools: nil, temperature: 0.6, thinking: podcast.thinking)
        var (title, sections) = PodcastPrompts.outline(from: plan.content)
        if sections.count < 2 { sections = PodcastPrompts.fallbackOutline(minutes: podcast.minutes) }
        let wanted = PodcastLength.sectionCount(minutes: podcast.minutes)
        if sections.count > wanted + 2 { sections = Array(sections.prefix(wanted + 1)) + [sections[sections.count - 1]] }
        let planned = sections
        podcasts.update(id, touch: false) { made in
            made.outline = planned
            if made.title.trimmingCharacters(in: .whitespaces).isEmpty, let title { made.title = title }
        }

        let budget = PodcastPrompts.wordBudget(podcast, sections: sections.count)
        for index in sections.indices {
            try Task.checkCancellation()
            guard let current = podcasts.podcast(id) else { return }
            setPodcastProgress(id, 0.22 + 0.28 * Double(index) / Double(sections.count), "Skript: Abschnitt \(index + 1) von \(sections.count) – \(sections[index].title)")
            var messages = withThinking(PodcastPrompts.sectionMessages(current, sections: sections, index: index, previous: current.script, budget: budget),
                                        client: client, model: model, thinking: current.thinking)
            let temperature = PodcastPrompts.scriptTemperature(current.tone)
            let answer = try await podcastRound(client, model: model.id, messages: messages, tools: nil, temperature: temperature, thinking: current.thinking)
            var lines = PodcastPrompts.lines(from: answer.content, participants: current.participants)
            let words = lines.reduce(0) { $0 + $1.wordCount }
            if words < budget * 6 / 10 {
                try Task.checkCancellation()
                messages.append(ChatPayloadMessage(role: "assistant", content: answer.content))
                messages.append(ChatPayloadMessage(role: "user", content: PodcastPrompts.continueRequest(missingWords: budget - words)))
                let more = try await podcastRound(client, model: model.id, messages: messages, tools: nil, temperature: temperature, thinking: current.thinking)
                lines = PodcastPrompts.mergingShortLines(lines + PodcastPrompts.lines(from: more.content, participants: current.participants))
            }
            guard !lines.isEmpty else { throw LLMError.server("Das Modell hat für „\(sections[index].title)“ kein Gespräch geschrieben.") }
            lines = PodcastPrompts.fitting(lines, budget: budget, isLast: index == sections.count - 1)
            let made = lines
            podcasts.update(id, touch: false) { $0.script += made }
        }
        setPodcastProgress(id, 0.5, "Skript fertig")
    }

    // MARK: Audio

    /// Speaks every line that has no snippet yet, then joins them into the podcast's audio file.
    private func speakPodcast(_ id: UUID, anew: Bool) async throws {
        guard let podcast = podcasts.podcast(id), !podcast.script.isEmpty else { throw PodcastAudio.Failure.noAudio }
        let store = podcasts.store
        let tts = QwenTTSClient(baseURL: podcastSpeechServer)
        setPodcastProgress(id, 0.5, "Verbinde mit Qwen TTS")
        guard await tts.isReachable() else { throw QwenTTSClient.Failure.unreachable(tts.baseURL.absoluteString) }
        let modelName = podcast.speechModel.engine.qwenModel ?? "qwen3-tts-small"
        let total = podcast.script.count
        for (number, line) in podcast.script.enumerated() {
            try Task.checkCancellation()
            // The line may have been changed or deleted meanwhile.
            guard let current = podcasts.podcast(id)?.script.first(where: { $0.id == line.id }) else { continue }
            let url = store.snippetURL(of: id, line: line.id)
            if !anew, current.duration != nil, store.hasSnippet(of: id, line: line.id) { continue }
            let speaker = podcasts.podcast(id)?.participant(current.speaker)
            setPodcastProgress(id, 0.5 + 0.47 * Double(number) / Double(total), "Sprachaufnahme: Zeile \(number + 1) von \(total)" + (speaker.map { " – \($0.displayName)" } ?? ""))
            let pieces = SpeechReader.chunks(of: current.text).map(\.text)
            var audio: [Data] = []
            for piece in pieces.isEmpty ? [current.text] : pieces {
                try Task.checkCancellation()
                audio.append(try await tts.speech(text: piece, model: modelName, voice: speaker?.voice ?? "serena", language: podcast.language))
            }
            let seconds = try await Task.detached(priority: .utility) { try PodcastAudio.writeSnippet(audio, to: url) }.value
            podcasts.update(id, touch: false) { podcast in
                guard let index = podcast.script.firstIndex(where: { $0.id == line.id }), podcast.script[index].text == current.text else { return }
                podcast.script[index].duration = seconds
            }
        }
        try Task.checkCancellation()
        setPodcastProgress(id, 0.97, "Audiodatei wird zusammengefügt")
        guard let finished = podcasts.podcast(id) else { return }
        let snippets = finished.script.compactMap { line -> (url: URL, speaker: UUID)? in
            store.hasSnippet(of: id, line: line.id) ? (store.snippetURL(of: id, line: line.id), line.speaker) : nil
        }
        let destination = store.audioURL(of: id)
        let seconds = try await Task.detached(priority: .utility) { try PodcastAudio.joinPodcast(snippets, to: destination) }.value
        store.removeSnippets(of: id, except: Set(finished.script.map(\.id)))
        podcasts.update(id, touch: false) { $0.duration = seconds }
        if podcastPlayer.podcastID == id {
            podcastPlayer.reload()
            loadPodcastPlayer(id)
        }
    }

    // MARK: Writer document

    /// The podcast as a Writer document: question, cast, the conversation line by line, fact sheet and sources.
    func podcastMarkdown(_ podcast: Podcast) -> String {
        func escaped(_ text: String) -> String { WriterMarkdown.escape(text, atLineStart: true) }
        var parts = ["# " + WriterMarkdown.escape(podcast.displayTitle, atLineStart: false)]
        var facts: [String] = []
        if !podcast.question.isEmpty { facts.append("*Frage:* " + WriterMarkdown.escape(podcast.question, atLineStart: false)) }
        var line = "*Länge:* " + (podcast.duration.map { PodcastLength.clock($0) + " Min" } ?? "\(podcast.minutes) Min (geplant)")
        line += " · *Ton:* " + podcast.tone.label
        if podcast.ownSources.onlyThese { line += " · nur aus den mitgelieferten Quellen" }
        facts.append(line)
        parts.append(facts.joined(separator: "\n\n"))
        if !podcast.participants.isEmpty {
            parts.append("## Teilnehmer")
            parts.append(podcast.participants.map { person in
                var item = "- **\(WriterMarkdown.escape(person.displayName, atLineStart: false))** (\(person.role.label))"
                if !person.description.isEmpty { item += " – " + WriterMarkdown.escape(person.description, atLineStart: false) }
                if !person.position.isEmpty { item += ". *Standpunkt:* " + WriterMarkdown.escape(person.position, atLineStart: false) }
                return item
            }.joined(separator: "\n"))
        }
        if !podcast.script.isEmpty {
            parts.append("## Gespräch")
            parts.append(podcast.script.map { line in
                "**\(WriterMarkdown.escape(podcast.participant(line.speaker)?.displayName ?? "?", atLineStart: false)):** " + WriterMarkdown.escape(line.text, atLineStart: false)
            }.joined(separator: "\n\n"))
        }
        if !podcast.research.isEmpty {
            // The fact sheet is Markdown already; its headings go one level down, under this one.
            let notes = podcast.research.notes.components(separatedBy: "\n").map { $0.hasPrefix("#") ? "##" + $0 : $0 }.joined(separator: "\n")
            parts.append("## Faktenblatt")
            parts.append(notes)
        }
        let sources = podcast.research.sources.filter { $0.url.hasPrefix("http") }
        if !sources.isEmpty {
            parts.append("## Quellen")
            parts.append(sources.map { "- [\(WriterMarkdown.escape($0.title.isEmpty ? $0.url : $0.title, atLineStart: false))](\($0.url))" }.joined(separator: "\n"))
        }
        return parts.joined(separator: "\n\n") + "\n"
    }

    /// A new Writer document made from the podcast, in the podcast's folder. What came from the web counts as foreign.
    @discardableResult
    func createDocument(fromPodcast id: UUID) -> WriterDocument? {
        guard let podcast = podcasts.podcast(id) else { return nil }
        let foreign = !podcast.research.sources.isEmpty || !podcast.ownSources.entries.isEmpty || !podcast.research.isEmpty
        return createDocumentForAction(title: podcast.displayTitle, folderID: podcast.folderID, markdown: podcastMarkdown(podcast),
                                       provenance: foreign ? .foreign : .internal)
    }

    func openPodcastAsDocument(_ id: UUID) {
        guard let document = createDocument(fromPodcast: id) else { return }
        selectDocument(document.id)
    }

    // MARK: Own sources

    /// Adds a web page as an own source. Returns why it can't, or nil.
    @discardableResult
    func addPodcastSource(url text: String, to id: UUID) -> String? {
        var address = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if !address.contains("://") { address = "https://" + address }
        guard let url = URL(string: address), let scheme = url.scheme, ["http", "https"].contains(scheme), url.host != nil else {
            return "„\(text)“ ist keine Webadresse."
        }
        podcasts.update(id) { podcast in
            if !podcast.ownSources.entries.contains(.url(address)) { podcast.ownSources.entries.append(.url(address)) }
        }
        return nil
    }

    /// Copies a PDF into the podcast's folder and adds it as an own source.
    func addPodcastSource(pdf file: URL, to id: UUID) throws {
        guard file.pathExtension.lowercased() == "pdf" else { throw LLMError.server("„\(file.lastPathComponent)“ ist kein PDF.") }
        let path = try podcasts.store.importPDF(file, into: id)
        let title = PDFDocument(url: file)?.documentAttributes?[PDFDocumentAttribute.titleAttribute] as? String
        podcasts.update(id) { $0.ownSources.entries.append(.pdf(title: title ?? file.deletingPathExtension().lastPathComponent, file: path)) }
    }

    /// Removes a source; a PDF's copy goes with it.
    func removePodcastSource(_ entry: PodcastOwnSources.Entry, from id: UUID) {
        if case .pdf(_, let file) = entry, let url = podcasts.store.sourceURL(of: id, file: file) {
            try? FileManager.default.removeItem(at: url)
        }
        podcasts.update(id) { $0.ownSources.entries.removeAll { $0 == entry } }
    }

    /// "PDF hinzufügen …"; returns what could not be added.
    func choosePodcastPDFs(for id: UUID) -> [String] {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.pdf]
        panel.allowsMultipleSelection = true
        guard panel.runModal() == .OK else { return [] }
        return panel.urls.compactMap { file in
            do {
                try addPodcastSource(pdf: file, to: id)
                return nil
            } catch {
                return "\(file.lastPathComponent): \(error.localizedDescription)"
            }
        }
    }

    // MARK: Audio file

    /// Loads the podcast into the player, with when each line begins. False when there is no audio yet.
    @discardableResult
    func loadPodcastPlayer(_ id: UUID) -> Bool {
        guard let podcast = podcasts.podcast(id), let url = podcastAudioURL(id) else { return false }
        podcastPlayer.load(id, url: url, lines: isPodcastAudioCurrent(podcast) ? podcast.lineStarts : [:])
        return true
    }

    /// The finished audio, if it is there.
    func podcastAudioURL(_ id: UUID) -> URL? {
        let url = podcasts.store.audioURL(of: id)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    /// Whether the audio file has every line as it is now: a changed line has lost its snippet and duration.
    func isPodcastAudioCurrent(_ podcast: Podcast) -> Bool {
        podcast.phase == .finished && podcastAudioURL(podcast.id) != nil && !podcast.script.isEmpty && podcast.script.allSatisfy { $0.duration != nil }
    }

    /// Copies the audio to where the person chooses.
    func exportPodcast(_ id: UUID, to url: URL) throws {
        guard let source = podcastAudioURL(id) else { throw PodcastAudio.Failure.noAudio }
        if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
        try FileManager.default.copyItem(at: source, to: url)
    }

    /// "Exportieren …": a save panel for the M4A file.
    func exportPodcastWithPanel(_ id: UUID) {
        guard let podcast = podcasts.podcast(id), podcastAudioURL(id) != nil else { return }
        Task { [weak self] in
            guard let self, let url = await self.askForDestination(fileName: podcast.displayTitle, type: .mpeg4Audio) else { return }
            do {
                try self.exportPodcast(id, to: url)
            } catch {
                self.exportError = error.localizedDescription
            }
        }
    }
}
