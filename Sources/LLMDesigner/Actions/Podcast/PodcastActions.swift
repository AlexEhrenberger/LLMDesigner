import Foundation
import LLMDProtocol

extension ActionRegistry {
    func registerPodcastActions() {
        register(PodcastListAction.self)
        register(PodcastCreateAction.self)
        register(PodcastReadAction.self)
        register(PodcastUpdateAction.self)
        register(PodcastDeleteAction.self)
        register(PodcastStatusAction.self)
        register(PodcastGenerateAction.self)
        register(PodcastStopAction.self)
        register(PodcastParticipantAddAction.self)
        register(PodcastParticipantUpdateAction.self)
        register(PodcastParticipantRemoveAction.self)
        register(PodcastParticipantsSuggestAction.self)
        register(PodcastReferenceAddAction.self)
        register(PodcastReferenceRemoveAction.self)
        register(PodcastLineUpdateAction.self)
        register(PodcastLineDeleteAction.self)
        register(PodcastSourceAddAction.self)
        register(PodcastSourceRemoveAction.self)
        register(PodcastToDocumentAction.self)
        register(PodcastVoicesListAction.self)
        register(PodcastExportAction.self)
        register(PodcastPlayAction.self)
        register(PodcastStudioOpenAction.self)
        register(PodcastStudioCloseAction.self)
    }
}

/// A podcast holds what the research found on the web and what the model wrote: reading one counts as foreign.
private let podcastRead = ActionSecurity.foreignRead

private let podcastProperty: JSONSchema = .string("Podcast (ID oder Titel)")
private let participantProperty: JSONSchema = .string("Teilnehmer:in (ID oder Name)")
private let lineProperty: JSONSchema = .string("Zeile des Skripts: ID oder Nummer ab 1")
private let minutesProperty: JSONSchema = .integer("Länge in Minuten: 5, 10 oder 15", minimum: 5, maximum: 15)
private let roleProperty: JSONSchema = .choice(["moderator", "diskutant"], "Rolle")
private let toneProperty: JSONSchema = .choice(PodcastTone.allCases.map(\.rawValue), "Ton: sachlich, lebhaft, kontrovers, polemisch oder hitzig (beschimpfen und beleidigen sich wie in Fernsehdebatten der 70er)")
private let thinkingProperty: JSONSchema = .boolean("Denkmodus des Modells (Vorgabe an)")
private let onlySourcesProperty: JSONSchema = .boolean("Nur aus den eigenen Quellen, ohne Web- und Wikipedia-Suche")
private let referenceProperties: [String: JSONSchema] = [
    "doc": .string("Writer-Dokument oder Präsentation (ID oder Titel)"),
    "chat": .string("Chat (ID oder Titel)"),
    "world": .string("Romanwelt (ID oder Titel)"),
    "part": .string("Teil der Romanwelt (ID oder Pfad wie Buch 1/Akt 2); ohne: die ganze Welt"),
]

// MARK: - Finding

extension AppModel {
    func actionPodcast(_ reference: String) throws -> Podcast {
        podcasts.loadIfNeeded()
        let reference = reference.trimmingCharacters(in: .whitespacesAndNewlines)
        if let id = UUID(uuidString: reference) {
            guard let podcast = podcasts.podcast(id) else { throw RPCError.notFound("Podcast \(reference) gibt es nicht.") }
            return podcast
        }
        let found = podcasts.podcasts.filter { $0.displayTitle.localizedCaseInsensitiveCompare(reference) == .orderedSame }
        if found.count == 1 { return found[0] }
        if found.isEmpty { throw RPCError.notFound("Podcast „\(reference)“ gibt es nicht.") }
        throw RPCError.ambiguous("Mehrere Podcasts heißen „\(reference)“. Bitte die ID verwenden.", candidates: found.map(\.id.uuidString))
    }

    /// The reference a call names: exactly one of a document, a chat, or a world (with or without a part).
    func actionPodcastReference(doc: String?, chat: String?, world: String?, part: String?) throws -> PodcastReference? {
        let named = [doc, chat, world].compactMap { $0 }.count
        guard named <= 1 else { throw RPCError.invalidParams("Nur eines angeben: doc, chat oder world (mit part).") }
        if let doc { return .document(try actionDocumentOrDeck(doc).id) }
        if let chat { return .chat(try actionChat(chat).id) }
        if let world {
            let found = try actionWorld(world)
            return .story(world: found.id, part: try part.map { try found.actionPart($0).id })
        }
        if part != nil { throw RPCError.invalidParams("Für part bitte auch world angeben.") }
        return nil
    }

    /// Whether answering a chat that is referenced touches private data (a persona's files or memory).
    func podcastReadsSensitive(_ podcast: Podcast) -> Bool {
        podcast.references.contains { reference in
            guard case .chat(let id) = reference, let chat = chat(id) else { return false }
            return chatPreflight(chat).readsSensitive
        }
    }
}

extension Podcast {
    func actionParticipant(_ reference: String) throws -> PodcastParticipant {
        let reference = reference.trimmingCharacters(in: .whitespacesAndNewlines)
        if let id = UUID(uuidString: reference), let person = participant(id) { return person }
        let found = participants.filter { $0.displayName.localizedCaseInsensitiveCompare(reference) == .orderedSame }
        if found.count == 1 { return found[0] }
        if found.isEmpty { throw RPCError.notFound("Teilnehmer:in „\(reference)“ gibt es nicht.") }
        throw RPCError.ambiguous("Mehrere heißen „\(reference)“.", candidates: found.map(\.id.uuidString))
    }

    func actionLine(_ reference: String) throws -> PodcastLine {
        let reference = reference.trimmingCharacters(in: .whitespacesAndNewlines)
        if let id = UUID(uuidString: reference), let line = script.first(where: { $0.id == id }) { return line }
        if let number = Int(reference) {
            guard script.indices.contains(number - 1) else { throw RPCError.notFound("Zeile \(number) gibt es nicht; das Skript hat \(script.count).") }
            return script[number - 1]
        }
        throw RPCError.notFound("Zeile „\(reference)“ gibt es nicht.")
    }
}

extension ActionContext {
    /// A change to a podcast with an undo step, as one call.
    @discardableResult
    func changePodcast(_ id: UUID, label: String, _ change: (inout Podcast) throws -> Void) throws -> Podcast {
        let library = app.podcasts
        guard let before = library.podcast(id) else { throw RPCError.notFound("Den Podcast gibt es nicht mehr.") }
        guard !before.phase.isRunning else { throw RPCError.invalidTarget("Der Podcast wird gerade erzeugt. Erst anhalten (podcast.stop).") }
        var podcast = before
        try change(&podcast)
        let wanted = podcast
        library.update(id) { $0 = wanted }
        let after = library.podcast(id) ?? wanted
        undoGroup.add(UndoStep(label: label, undo: { [weak library] in library?.update(id) { $0 = before } }, redo: { [weak library] in library?.update(id) { $0 = after } }))
        registry.eventSink?(ActionEvent(kind: PodcastEvents.changed, action: undoGroup.label, channel: channel.rawValue, run: run.id, target: id.uuidString))
        return after
    }
}

enum PodcastEvents {
    static let changed = "podcast.changed"
}

// MARK: - Output

struct PodcastParticipantOutput: Encodable, Sendable {
    var id: String
    var role: String
    var name: String
    var description: String
    var voice: String
    var position: String

    init(_ person: PodcastParticipant) {
        id = person.id.uuidString
        role = person.role.stored
        name = person.name
        description = person.description
        voice = person.voice
        position = person.position
    }
}

struct PodcastReferenceOutput: Encodable, Sendable {
    var kind: String
    var id: String
    var world: String?
    var part: String?
    var title: String?
}

struct PodcastLineOutput: Encodable, Sendable {
    var number: Int
    var id: String
    var speaker: String
    var text: String
    var seconds: Double?
}

@MainActor
extension AppModel {
    func actionReferenceOutput(_ reference: PodcastReference) -> PodcastReferenceOutput {
        switch reference {
        case .chat(let id):
            PodcastReferenceOutput(kind: "chat", id: id.uuidString, title: podcastReferenceTitle(reference))
        case .document(let id):
            PodcastReferenceOutput(kind: document(id)?.isPresentation == true ? "praesentation" : "dokument", id: id.uuidString, title: podcastReferenceTitle(reference))
        case .story(let world, let part):
            PodcastReferenceOutput(kind: "romanwelt", id: (part ?? world).uuidString, world: world.uuidString, part: part?.uuidString, title: podcastReferenceTitle(reference))
        }
    }

    func actionPodcastStatus(_ podcast: Podcast) -> PodcastStatusOutput {
        let progress = podcastProgress[podcast.id]
        let queued = podcastQueue.firstIndex(of: podcast.id).map { $0 + 1 }
        return PodcastStatusOutput(
            id: podcast.id.uuidString, phase: podcast.phase.rawValue, label: podcast.phase.label,
            percent: progress.map { Int(($0.fraction * 100).rounded()) } ?? (podcast.phase == .finished ? 100 : nil),
            detail: progress?.detail, error: podcast.error, queuePosition: queued,
            audio: podcastAudioURL(podcast.id) != nil, audioCurrent: isPodcastAudioCurrent(podcast), seconds: podcast.duration,
            words: podcast.scriptWords, targetWords: podcast.targetWords, lines: podcast.script.count
        )
    }
}

struct PodcastStatusOutput: Encodable, Sendable {
    var id: String
    var phase: String
    var label: String
    var percent: Int?
    var detail: String?
    var error: String?
    var queuePosition: Int?
    var audio: Bool
    var audioCurrent: Bool
    var seconds: Double?
    var words: Int
    var targetWords: Int
    var lines: Int
}

/// Participants an agent hands over: `[{"role": "moderator", "name": "Lena", "description": "…", "voice": "serena", "position": "…"}]`.
struct PodcastParticipantInput: Decodable, Sendable {
    var role: String?
    var name: String
    var description: String?
    var voice: String?
    var position: String?
}

private func parseMinutes(_ value: Int?) throws -> Int? {
    guard let value else { return nil }
    guard PodcastLength.choices.contains(value) else { throw RPCError.invalidParams("Länge \(value) gibt es nicht. Möglich: 5, 10 oder 15 Minuten.") }
    return value
}

private func parseRole(_ value: String?) throws -> PodcastRole? {
    guard let value else { return nil }
    guard let role = PodcastRole(stored: value) else { throw RPCError.invalidParams("Rolle „\(value)“ gibt es nicht: moderator oder diskutant.") }
    return role
}

private func parseTone(_ value: String?) throws -> PodcastTone? {
    guard let value else { return nil }
    guard let tone = PodcastTone(rawValue: value) else {
        throw RPCError.invalidParams("Ton „\(value)“ gibt es nicht: \(PodcastTone.allCases.map(\.rawValue).joined(separator: ", ")).")
    }
    return tone
}

private func parseSpeechModel(_ value: String?) throws -> PodcastSpeechModel? {
    guard let value else { return nil }
    guard let model = PodcastSpeechModel(rawValue: value) else { throw RPCError.invalidParams("Sprachmodell „\(value)“ gibt es nicht: klein oder gross.") }
    return model
}

@MainActor
private func participants(from input: [PodcastParticipantInput], app: AppModel) throws -> [PodcastParticipant] {
    var made: [PodcastParticipant] = []
    for person in input {
        let role = try parseRole(person.role) ?? (made.isEmpty ? .moderator : .discussant)
        let voice = person.voice ?? PodcastParticipant.freeVoice(female: nil, taken: made.map(\.voice), available: app.podcastVoices.map(\.id))
        made.append(PodcastParticipant(role: role, name: person.name.trimmingCharacters(in: .whitespaces), description: person.description ?? "",
                                       voice: voice, position: person.position ?? ""))
    }
    guard made.filter({ $0.role == .moderator }).count <= 1 else { throw RPCError.invalidParams("Es gibt nur eine Moderation.") }
    return made
}

// MARK: - Podcasts

struct PodcastListAction: LLMDAction {
    struct Args: Decodable, Sendable {
        var query: String?
    }
    struct Item: Encodable, Sendable {
        var id: String
        var title: String
        var question: String
        var minutes: Int
        var phase: String
        var seconds: Double?
        var participants: [String]
        var updated: String
    }
    struct Output: Encodable, Sendable {
        var podcasts: [Item]
    }
    static let descriptor = ActionDescriptor(
        id: "podcast.list", summary: "Listet die Podcasts mit Frage, Länge und Stand", kind: .read, security: podcastRead,
        input: .object(["query": .string("Suche in Titel, Frage, Namen und Skript")]),
        output: .freeObject(), example: "llmd podcast list", groups: ["podcast.core"]
    )
    static func run(_ args: Args, context: ActionContext) async throws -> Output {
        let library = context.app.podcasts
        library.loadIfNeeded()
        return Output(podcasts: library.podcasts.filter { $0.matches(args.query ?? "") }.map { podcast in
            Item(id: podcast.id.uuidString, title: podcast.displayTitle, question: podcast.question, minutes: podcast.minutes, phase: podcast.phase.rawValue,
                 seconds: podcast.duration, participants: podcast.participants.map(\.displayName), updated: podcast.updatedAt.formatted(.iso8601))
        })
    }
}

struct PodcastCreateAction: LLMDAction {
    struct Args: Decodable, Sendable {
        var question: String?
        var title: String?
        var minutes: Int?
        var speechModel: String?
        var participants: [PodcastParticipantInput]?
        var doc: String?
        var chat: String?
        var world: String?
        var part: String?
        var thinking: Bool?
        var tone: String?
        var urls: [String]?
        var onlySources: Bool?
        var open: Bool?
    }
    struct Output: Encodable, Sendable {
        var id: String
        var title: String
        var participants: [PodcastParticipantOutput]
    }
    static let descriptor = ActionDescriptor(
        id: "podcast.create",
        summary: "Legt einen Podcast an: Frage, Länge, Teilnehmer (sonst Moderation und zwei Diskutant:innen), auf Wunsch zu einem Dokument, Chat oder einer Romanwelt",
        kind: .write, security: .localWrite,
        input: .object(referenceProperties.merging([
            "question": .string("Frage oder Thema des Gesprächs"), "title": .string("Titel; ohne: aus der Frage"), "minutes": minutesProperty,
            "speechModel": .choice(["klein", "gross"], "Qwen-TTS-Modell; Vorgabe klein"),
            "participants": .array(of: .freeObject("{role, name, description, voice, position}"), "Teilnehmer; die erste Person ohne Rolle moderiert"),
            "thinking": thinkingProperty, "tone": toneProperty,
            "urls": .array(of: .string(), "Eigene Quellen: Webadressen, die zuerst gelesen werden"), "onlySources": onlySourcesProperty,
            "open": .boolean("Im PodcastStudio öffnen"),
        ]) { _, new in new }),
        output: .freeObject(), example: "llmd podcast create --question \"Was ist Predictive Coding?\" --minutes 10", groups: ["podcast.core"]
    )
    static func run(_ args: Args, context: ActionContext) async throws -> Output {
        let app = context.app
        let reference = try app.actionPodcastReference(doc: args.doc, chat: args.chat, world: args.world, part: args.part)
        let minutes = try parseMinutes(args.minutes) ?? PodcastLength.standard
        let speechModel = try parseSpeechModel(args.speechModel)
        let cast = try args.participants.map { try participants(from: $0, app: app) }
        let tone = try parseTone(args.tone)
        let addresses = try (args.urls ?? []).map { text -> String in
            var address = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if !address.contains("://") { address = "https://" + address }
            guard let url = URL(string: address), ["http", "https"].contains(url.scheme ?? ""), url.host != nil else {
                throw RPCError.invalidParams("„\(text)“ ist keine Webadresse.")
            }
            return address
        }
        if args.onlySources == true, addresses.isEmpty { throw RPCError.invalidParams("onlySources braucht urls (PDFs kommen mit podcast.source.add dazu).") }
        let question = args.question?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !question.isEmpty || reference != nil || !addresses.isEmpty else { throw RPCError.invalidParams("question, urls oder eine Referenz (doc, chat, world) angeben.") }
        var podcast: Podcast
        if let reference, question.isEmpty {
            podcast = app.newPodcast(about: reference, open: false)
        } else {
            podcast = app.newPodcast(question: question, title: args.title ?? "", references: reference.map { [$0] } ?? [], minutes: minutes, participants: cast, open: false)
        }
        let library = app.podcasts
        library.update(podcast.id) { made in
            made.minutes = minutes
            if let title = args.title { made.title = title }
            if let cast { made.participants = cast }
            if let speechModel { made.speechModel = speechModel }
            if let thinking = args.thinking { made.thinking = thinking }
            if let tone { made.tone = tone }
            made.ownSources.entries += addresses.map(PodcastOwnSources.Entry.url)
            if let only = args.onlySources { made.ownSources.onlyThese = only }
        }
        podcast = library.podcast(podcast.id) ?? podcast
        let made = podcast
        context.undoGroup.add(UndoStep(label: "Podcast anlegen", undo: { [weak library] in _ = library?.delete(made.id) }, redo: { [weak library] in library?.restore(made, from: nil) }))
        if args.open == true { app.openPodcastStudio(showing: made.id) }
        return Output(id: made.id.uuidString, title: made.displayTitle, participants: made.participants.map(PodcastParticipantOutput.init))
    }
}

struct PodcastArgs: Decodable, Sendable {
    var podcast: String
}

struct PodcastReadAction: LLMDAction {
    struct Args: Decodable, Sendable {
        var podcast: String
        var research: Bool?
        var script: Bool?
        var format: String?
    }
    struct Output: Encodable, Sendable {
        var id: String
        var title: String
        var question: String
        var minutes: Int
        var language: String
        var speechModel: String
        var thinking: Bool
        var tone: String
        var ownSources: [String]?
        var onlySources: Bool?
        var status: PodcastStatusOutput
        var participants: [PodcastParticipantOutput]
        var references: [PodcastReferenceOutput]
        var outline: [String]?
        var research: String?
        var sources: [PodcastSourceOutput]?
        var script: [PodcastLineOutput]?
        var text: String?
    }
    static let descriptor = ActionDescriptor(
        id: "podcast.read", summary: "Liest einen Podcast: Frage, Teilnehmer, Referenzen, Stand, auf Wunsch Faktenblatt und Skript",
        kind: .read, security: podcastRead,
        input: .object([
            "podcast": podcastProperty, "research": .boolean("Faktenblatt und Quellen mitliefern"), "script": .boolean("Skript mitliefern (Vorgabe: ja)"),
            "format": .choice(["json", "text"], "Skript als Zeilenliste (json) oder als Text „Name: Satz“"),
        ], required: ["podcast"]),
        output: .freeObject(), example: "llmd podcast read --podcast \"Predictive Coding\" --research", groups: ["podcast.core"]
    )
    static func preflight(_ args: Args, context: ActionContext) throws -> ActionPreflight {
        ActionPreflight(target: try context.app.actionPodcast(args.podcast).displayTitle)
    }
    static func run(_ args: Args, context: ActionContext) async throws -> Output {
        let app = context.app
        let podcast = try app.actionPodcast(args.podcast)
        let withScript = args.script ?? true
        let asText = args.format == "text"
        return Output(
            id: podcast.id.uuidString, title: podcast.displayTitle, question: podcast.question, minutes: podcast.minutes, language: podcast.language,
            speechModel: podcast.speechModel.rawValue, thinking: podcast.thinking, tone: podcast.tone.rawValue,
            ownSources: podcast.ownSources.entries.isEmpty ? nil : podcast.ownSources.entries.map(\.label),
            onlySources: podcast.ownSources.onlyThese ? true : nil, status: app.actionPodcastStatus(podcast),
            participants: podcast.participants.map(PodcastParticipantOutput.init), references: podcast.references.map { app.actionReferenceOutput($0) },
            outline: podcast.outline.isEmpty ? nil : podcast.outline.map(\.title),
            research: args.research == true && !podcast.research.isEmpty ? podcast.research.notes : nil,
            sources: args.research == true && !podcast.research.sources.isEmpty ? podcast.research.sources.map { PodcastSourceOutput(title: $0.title, url: $0.url) } : nil,
            script: withScript && !asText && !podcast.script.isEmpty ? podcast.script.enumerated().map { index, line in
                PodcastLineOutput(number: index + 1, id: line.id.uuidString, speaker: podcast.participant(line.speaker)?.displayName ?? "?", text: line.text, seconds: line.duration)
            } : nil,
            text: withScript && asText && !podcast.script.isEmpty ? podcast.scriptText : nil
        )
    }
}

struct PodcastSourceOutput: Encodable, Sendable {
    var title: String
    var url: String
}

struct PodcastUpdateAction: LLMDAction {
    struct Args: Decodable, Sendable {
        var podcast: String
        var title: String?
        var question: String?
        var minutes: Int?
        var speechModel: String?
        var language: String?
        var thinking: Bool?
        var tone: String?
        var onlySources: Bool?
    }
    static let descriptor = ActionDescriptor(
        id: "podcast.update", summary: "Ändert Titel, Frage, Länge, Sprache, Sprachmodell, Denkmodus, Ton oder „nur aus eigenen Quellen“ eines Podcasts",
        kind: .write, security: .localWrite,
        input: .object([
            "podcast": podcastProperty, "title": .string("Neuer Titel"), "question": .string("Neue Frage"), "minutes": minutesProperty,
            "speechModel": .choice(["klein", "gross"], "Qwen-TTS-Modell"), "language": .choice(["de", "en"], "Sprache des Gesprächs"),
            "thinking": thinkingProperty, "tone": toneProperty, "onlySources": onlySourcesProperty,
        ], required: ["podcast"]),
        output: .freeObject(), example: "llmd podcast update --podcast \"Predictive Coding\" --tone hitzig", groups: ["podcast.core"]
    )
    static func run(_ args: Args, context: ActionContext) async throws -> OKOutput {
        let podcast = try context.app.actionPodcast(args.podcast)
        let minutes = try parseMinutes(args.minutes)
        let model = try parseSpeechModel(args.speechModel)
        let tone = try parseTone(args.tone)
        if let language = args.language, !["de", "en"].contains(language) { throw RPCError.invalidParams("Sprache „\(language)“: de oder en.") }
        guard args.title != nil || args.question != nil || minutes != nil || model != nil || args.language != nil
            || args.thinking != nil || tone != nil || args.onlySources != nil else {
            throw RPCError.invalidParams("Nichts zu ändern: title, question, minutes, speechModel, language, thinking, tone oder onlySources angeben.")
        }
        try context.changePodcast(podcast.id, label: "Podcast ändern") { podcast in
            if let title = args.title { podcast.title = title }
            if let question = args.question { podcast.question = question }
            if let minutes { podcast.minutes = minutes }
            if let model { podcast.speechModel = model }
            if let language = args.language { podcast.language = language }
            if let thinking = args.thinking { podcast.thinking = thinking }
            if let tone { podcast.tone = tone }
            if let only = args.onlySources { podcast.ownSources.onlyThese = only }
        }
        return OKOutput(id: podcast.id.uuidString)
    }
}

struct PodcastDeleteAction: LLMDAction {
    static let descriptor = ActionDescriptor(
        id: "podcast.delete", summary: "Legt einen Podcast mit seiner Audiodatei in den Papierkorb", kind: .destructive, security: .destructive,
        input: .object(["podcast": podcastProperty], required: ["podcast"]), output: .freeObject()
    )
    static func preflight(_ args: PodcastArgs, context: ActionContext) throws -> ActionPreflight {
        ActionPreflight(target: try context.app.actionPodcast(args.podcast).displayTitle)
    }
    static func run(_ args: PodcastArgs, context: ActionContext) async throws -> OKOutput {
        let app = context.app
        let podcast = try app.actionPodcast(args.podcast)
        app.stopPodcast(podcast.id)
        if app.podcastPlayer.podcastID == podcast.id { app.podcastPlayer.stop() }
        guard let (removed, trashed) = app.podcasts.delete(podcast.id) else { throw RPCError.notFound("Den Podcast gibt es nicht mehr.") }
        if app.selectedPodcastID == podcast.id { app.selectedPodcastID = nil }
        let library = app.podcasts
        context.undoGroup.add(UndoStep(label: "Podcast löschen", undo: { [weak library] in library?.restore(removed, from: trashed) },
                                       redo: { [weak library] in _ = library?.delete(removed.id) }))
        return OKOutput(id: podcast.id.uuidString)
    }
}

// MARK: - Making

struct PodcastStatusAction: LLMDAction {
    static let descriptor = ActionDescriptor(
        id: "podcast.status", summary: "Zeigt, wie weit ein Podcast ist: Phase, Prozent, laufender Schritt, Fehler, Audio", kind: .read, security: .plainRead,
        input: .object(["podcast": podcastProperty], required: ["podcast"]), output: .freeObject(),
        example: "llmd podcast status --podcast \"Predictive Coding\"", groups: ["podcast.core"]
    )
    static func run(_ args: PodcastArgs, context: ActionContext) async throws -> PodcastStatusOutput {
        context.app.actionPodcastStatus(try context.app.actionPodcast(args.podcast))
    }
}

struct PodcastGenerateAction: LLMDAction {
    struct Args: Decodable, Sendable {
        var podcast: String
        var from: String?
    }
    static let descriptor = ActionDescriptor(
        id: "podcast.generate",
        summary: "Erzeugt einen Podcast im Hintergrund: Recherche in Wikipedia und im Web, Skript passend zur Länge, Sprachaufnahme mit Qwen TTS. Den Stand liefert podcast.status",
        kind: .write, security: .localWrite,
        input: .object([
            "podcast": podcastProperty,
            "from": .choice(PodcastStart.allCases.map(\.rawValue), "fortsetzen (Vorgabe: was fehlt), alles (neu mit Recherche), skript (neues Skript), audio (alle Zeilen neu sprechen)"),
        ], required: ["podcast"]),
        output: .freeObject(), example: "llmd podcast generate --podcast \"Predictive Coding\"", groups: ["podcast.core"]
    )
    /// The research reads the web; a referenced chat may hold private data, which then only goes to Wikipedia.
    static func preflight(_ args: Args, context: ActionContext) throws -> ActionPreflight {
        let podcast = try context.app.actionPodcast(args.podcast)
        return ActionPreflight(readsUntrusted: true, readsSensitive: context.app.podcastReadsSensitive(podcast), target: podcast.displayTitle, detail: podcast.question)
    }
    static func run(_ args: Args, context: ActionContext) async throws -> PodcastStatusOutput {
        let app = context.app
        let podcast = try app.actionPodcast(args.podcast)
        let start = try args.from.map { value -> PodcastStart in
            guard let start = PodcastStart(rawValue: value) else { throw RPCError.invalidParams("from „\(value)“ gibt es nicht: fortsetzen, alles, skript oder audio.") }
            return start
        } ?? .resume
        if start == .script, podcast.research.isEmpty { throw RPCError.invalidTarget("Es gibt noch keine Recherche: from fortsetzen oder alles.") }
        if start == .audio, podcast.script.isEmpty { throw RPCError.invalidTarget("Es gibt noch kein Skript: from fortsetzen oder alles.") }
        guard !podcast.phase.isRunning else { throw RPCError.invalidTarget("Der Podcast wird schon erzeugt.") }
        if let problem = app.startPodcast(podcast.id, from: start) { throw RPCError.invalidTarget(problem) }
        context.registry.eventSink?(ActionEvent(kind: PodcastEvents.changed, action: descriptor.id, channel: context.channel.rawValue, run: context.run.id, target: podcast.id.uuidString))
        return app.actionPodcastStatus(app.podcasts.podcast(podcast.id) ?? podcast)
    }
}

struct PodcastStopAction: LLMDAction {
    static let descriptor = ActionDescriptor(
        id: "podcast.stop", summary: "Hält einen laufenden oder wartenden Podcast an; Fortsetzen macht dort weiter", kind: .write, security: .localWrite,
        input: .object(["podcast": podcastProperty], required: ["podcast"]), output: .freeObject(), groups: ["podcast.core"]
    )
    static func run(_ args: PodcastArgs, context: ActionContext) async throws -> OKOutput {
        let app = context.app
        let podcast = try app.actionPodcast(args.podcast)
        guard podcast.phase.isRunning else { return OKOutput(id: podcast.id.uuidString, message: "Er lief nicht.") }
        app.stopPodcast(podcast.id)
        return OKOutput(id: podcast.id.uuidString)
    }
}

// MARK: - Participants

struct PodcastParticipantAddAction: LLMDAction {
    struct Args: Decodable, Sendable {
        var podcast: String
        var name: String
        var role: String?
        var description: String?
        var voice: String?
        var position: String?
    }
    static let descriptor = ActionDescriptor(
        id: "podcast.participant.add", summary: "Fügt eine:n Teilnehmer:in hinzu: Rolle, Name, Beschreibung, Stimme, Standpunkt", kind: .write, security: .localWrite,
        input: .object([
            "podcast": podcastProperty, "name": .string("Name im Gespräch"), "role": roleProperty,
            "description": .string("Wer die Person ist, z. B. Biologin"), "voice": .string("Qwen-TTS-Stimme (podcast.voices.list); ohne: eine freie"),
            "position": .string("Standpunkt im Gespräch"),
        ], required: ["podcast", "name"]),
        output: .freeObject(), example: "llmd podcast participant add --podcast Predictive --name Tom --description Taxifahrer --position \"hält alles für Hype\"",
        groups: ["podcast.core"]
    )
    static func run(_ args: Args, context: ActionContext) async throws -> PodcastParticipantOutput {
        let app = context.app
        let podcast = try app.actionPodcast(args.podcast)
        let role = try parseRole(args.role) ?? .discussant
        if role == .moderator, podcast.moderator != nil { throw RPCError.invalidTarget("Es gibt schon eine Moderation.") }
        let name = args.name.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { throw RPCError.invalidParams("name darf nicht leer sein.") }
        guard !podcast.participants.contains(where: { $0.displayName.localizedCaseInsensitiveCompare(name) == .orderedSame }) else {
            throw RPCError.invalidTarget("„\(name)“ ist schon dabei.")
        }
        let voice = args.voice ?? PodcastParticipant.freeVoice(female: nil, taken: podcast.participants.map(\.voice), available: app.podcastVoices.map(\.id))
        let person = PodcastParticipant(role: role, name: name, description: args.description ?? "", voice: voice, position: args.position ?? "")
        try context.changePodcast(podcast.id, label: "Teilnehmer:in hinzufügen") { $0.participants.append(person) }
        return PodcastParticipantOutput(person)
    }
}

struct PodcastParticipantUpdateAction: LLMDAction {
    struct Args: Decodable, Sendable {
        var podcast: String
        var participant: String
        var name: String?
        var role: String?
        var description: String?
        var voice: String?
        var position: String?
    }
    static let descriptor = ActionDescriptor(
        id: "podcast.participant.update", summary: "Ändert Name, Rolle, Beschreibung, Stimme oder Standpunkt einer Person", kind: .write, security: .localWrite,
        input: .object([
            "podcast": podcastProperty, "participant": participantProperty, "name": .string("Neuer Name"), "role": roleProperty,
            "description": .string("Beschreibung"), "voice": .string("Qwen-TTS-Stimme"), "position": .string("Standpunkt"),
        ], required: ["podcast", "participant"]),
        output: .freeObject(), example: "llmd podcast participant update --podcast Predictive --participant Mira --voice ono_anna", groups: ["podcast.core"]
    )
    static func run(_ args: Args, context: ActionContext) async throws -> PodcastParticipantOutput {
        let podcast = try context.app.actionPodcast(args.podcast)
        let person = try podcast.actionParticipant(args.participant)
        let role = try parseRole(args.role)
        let after = try context.changePodcast(podcast.id, label: "Teilnehmer:in ändern") { podcast in
            for index in podcast.participants.indices {
                if podcast.participants[index].id == person.id {
                    if let name = args.name { podcast.participants[index].name = name.trimmingCharacters(in: .whitespaces) }
                    if let role { podcast.participants[index].role = role }
                    if let text = args.description { podcast.participants[index].description = text }
                    if let voice = args.voice { podcast.participants[index].voice = voice }
                    if let text = args.position { podcast.participants[index].position = text }
                } else if role == .moderator, podcast.participants[index].role == .moderator {
                    podcast.participants[index].role = .discussant
                }
            }
        }
        return PodcastParticipantOutput(after.participant(person.id) ?? person)
    }
}

struct PodcastParticipantRemoveAction: LLMDAction {
    struct Args: Decodable, Sendable {
        var podcast: String
        var participant: String
    }
    static let descriptor = ActionDescriptor(
        id: "podcast.participant.remove", summary: "Nimmt eine Person aus dem Podcast; ihre Zeilen im Skript bleiben, bis es neu geschrieben wird", kind: .write, security: .localWrite,
        input: .object(["podcast": podcastProperty, "participant": participantProperty], required: ["podcast", "participant"]), output: .freeObject()
    )
    static func run(_ args: Args, context: ActionContext) async throws -> OKOutput {
        let podcast = try context.app.actionPodcast(args.podcast)
        let person = try podcast.actionParticipant(args.participant)
        if podcast.script.contains(where: { $0.speaker == person.id }) {
            throw RPCError.invalidTarget("\(person.displayName) spricht im Skript. Erst das Skript neu schreiben (podcast.generate --from skript) oder die Zeilen anderen geben.")
        }
        try context.changePodcast(podcast.id, label: "Teilnehmer:in entfernen") { $0.participants.removeAll { $0.id == person.id } }
        return OKOutput(id: person.id.uuidString)
    }
}

struct PodcastParticipantsSuggestAction: LLMDAction {
    struct Args: Decodable, Sendable {
        var podcast: String
        var count: Int?
    }
    struct Output: Encodable, Sendable {
        var participants: [PodcastParticipantOutput]
    }
    static let descriptor = ActionDescriptor(
        id: "podcast.participants.suggest", summary: "Lässt das Modell aus der Frage eine Besetzung ableiten: Moderation und Diskutant:innen mit eigenen Standpunkten und Stimmen",
        kind: .write, security: .localWrite,
        input: .object(["podcast": podcastProperty, "count": .integer("Personen insgesamt, 2 bis 4 (Vorgabe 3)", minimum: 2, maximum: 4)], required: ["podcast"]),
        output: .freeObject(), example: "llmd podcast participants suggest --podcast \"Predictive Coding\"", groups: ["podcast.core"]
    )
    static func preflight(_ args: Args, context: ActionContext) throws -> ActionPreflight {
        let podcast = try context.app.actionPodcast(args.podcast)
        return ActionPreflight(readsSensitive: context.app.podcastReadsSensitive(podcast), target: podcast.displayTitle)
    }
    static func run(_ args: Args, context: ActionContext) async throws -> Output {
        let app = context.app
        let podcast = try app.actionPodcast(args.podcast)
        guard !podcast.phase.isRunning else { throw RPCError.invalidTarget("Der Podcast wird gerade erzeugt.") }
        let before = podcast
        try await app.suggestPodcastParticipants(podcast.id, count: args.count ?? 3)
        let after = app.podcasts.podcast(podcast.id) ?? podcast
        let library = app.podcasts
        context.undoGroup.add(UndoStep(label: "Besetzung vorschlagen", undo: { [weak library] in library?.update(before.id) { $0.participants = before.participants } },
                                       redo: { [weak library] in library?.update(after.id) { $0.participants = after.participants } }))
        return Output(participants: after.participants.map(PodcastParticipantOutput.init))
    }
}

// MARK: - References

struct PodcastReferenceArgs: Decodable, Sendable {
    var podcast: String
    var doc: String?
    var chat: String?
    var world: String?
    var part: String?
}

private let referenceInput: JSONSchema = .object(referenceProperties.merging(["podcast": podcastProperty]) { _, new in new }, required: ["podcast"])

struct PodcastReferenceAddAction: LLMDAction {
    static let descriptor = ActionDescriptor(
        id: "podcast.reference.add", summary: "Gibt einem Podcast Material: ein Dokument, eine Präsentation, einen Chat, eine Romanwelt oder einen ihrer Teile",
        kind: .write, security: .localWrite, input: referenceInput, output: .freeObject(),
        example: "llmd podcast reference add --podcast Predictive --doc Bachelorarbeit", groups: ["podcast.core"]
    )
    static func run(_ args: PodcastReferenceArgs, context: ActionContext) async throws -> OKOutput {
        let app = context.app
        let podcast = try app.actionPodcast(args.podcast)
        guard let reference = try app.actionPodcastReference(doc: args.doc, chat: args.chat, world: args.world, part: args.part) else {
            throw RPCError.invalidParams("doc, chat oder world angeben.")
        }
        guard !podcast.references.contains(reference) else { return OKOutput(id: podcast.id.uuidString, message: "War schon dabei.") }
        try context.changePodcast(podcast.id, label: "Referenz hinzufügen") { $0.references.append(reference) }
        return OKOutput(id: podcast.id.uuidString)
    }
}

struct PodcastReferenceRemoveAction: LLMDAction {
    static let descriptor = ActionDescriptor(
        id: "podcast.reference.remove", summary: "Nimmt eine Referenz aus dem Podcast; das Dokument, der Chat oder die Welt bleibt", kind: .write, security: .localWrite,
        input: referenceInput, output: .freeObject()
    )
    static func run(_ args: PodcastReferenceArgs, context: ActionContext) async throws -> OKOutput {
        let app = context.app
        let podcast = try app.actionPodcast(args.podcast)
        // A deleted document or chat can still be removed by its id.
        let reference: PodcastReference?
        if let doc = args.doc, let id = UUID(uuidString: doc) { reference = .document(id) }
        else if let chat = args.chat, let id = UUID(uuidString: chat) { reference = .chat(id) }
        else { reference = try app.actionPodcastReference(doc: args.doc, chat: args.chat, world: args.world, part: args.part) }
        guard let reference else { throw RPCError.invalidParams("doc, chat oder world angeben.") }
        guard podcast.references.contains(reference) else { throw RPCError.invalidTarget("Diese Referenz hat der Podcast nicht.") }
        try context.changePodcast(podcast.id, label: "Referenz entfernen") { $0.references.removeAll { $0 == reference } }
        return OKOutput(id: podcast.id.uuidString)
    }
}

// MARK: - Script

struct PodcastLineUpdateAction: LLMDAction {
    struct Args: Decodable, Sendable {
        var podcast: String
        var line: String
        var text: String?
        var speaker: String?
    }
    static let descriptor = ActionDescriptor(
        id: "podcast.line.update", summary: "Ändert Text oder Sprecher:in einer Zeile des Skripts; die Zeile wird beim nächsten Erzeugen neu gesprochen",
        kind: .write, security: .localWrite,
        input: .object(["podcast": podcastProperty, "line": lineProperty, "text": .string("Neuer Text"), "speaker": participantProperty], required: ["podcast", "line"]),
        output: .freeObject(), example: "llmd podcast line update --podcast Predictive --line 3 --text \"…\"", groups: ["podcast.core"]
    )
    static func run(_ args: Args, context: ActionContext) async throws -> OKOutput {
        let podcast = try context.app.actionPodcast(args.podcast)
        let line = try podcast.actionLine(args.line)
        let speaker = try args.speaker.map { try podcast.actionParticipant($0).id }
        let text = args.text.map { PodcastPrompts.spoken($0) }
        guard text != nil || speaker != nil else { throw RPCError.invalidParams("text oder speaker angeben.") }
        if text?.isEmpty == true { throw RPCError.invalidParams("Der Text darf nicht leer sein; zum Entfernen podcast.line.delete.") }
        try context.changePodcast(podcast.id, label: "Zeile ändern") { podcast in
            guard let index = podcast.script.firstIndex(where: { $0.id == line.id }) else { return }
            if let text { podcast.script[index].text = text }
            if let speaker { podcast.script[index].speaker = speaker }
        }
        return OKOutput(id: line.id.uuidString)
    }
}

struct PodcastLineDeleteAction: LLMDAction {
    struct Args: Decodable, Sendable {
        var podcast: String
        var line: String
    }
    static let descriptor = ActionDescriptor(
        id: "podcast.line.delete", summary: "Entfernt eine Zeile aus dem Skript (mit Rückgängig)", kind: .write, security: .localWrite,
        input: .object(["podcast": podcastProperty, "line": lineProperty], required: ["podcast", "line"]), output: .freeObject()
    )
    static func run(_ args: Args, context: ActionContext) async throws -> OKOutput {
        let podcast = try context.app.actionPodcast(args.podcast)
        let line = try podcast.actionLine(args.line)
        try context.changePodcast(podcast.id, label: "Zeile löschen") { $0.script.removeAll { $0.id == line.id } }
        return OKOutput(id: line.id.uuidString)
    }
}

// MARK: - Voices, audio, studio

struct PodcastVoicesListAction: LLMDAction {
    struct Item: Encodable, Sendable {
        var id: String
        var name: String
        var gender: String
        var native: String
    }
    struct Output: Encodable, Sendable {
        var voices: [Item]
        var speechModels: [String]
    }
    static let descriptor = ActionDescriptor(
        id: "podcast.voices.list", summary: "Listet die Stimmen von Qwen TTS und die Sprachmodelle", kind: .read, security: .plainRead, output: .freeObject(), groups: ["podcast.core"]
    )
    static func run(_ args: NoArgs, context: ActionContext) async throws -> Output {
        let app = context.app
        app.loadPodcastVoices()
        return Output(voices: app.podcastVoices.map { Item(id: $0.id, name: $0.name, gender: $0.gender, native: $0.native) },
                      speechModels: PodcastSpeechModel.allCases.map(\.rawValue))
    }
}

struct PodcastExportAction: LLMDAction {
    struct Args: Decodable, Sendable {
        var podcast: String
        var path: String?
        var overwrite: Bool?
    }
    typealias Output = WriterExportAction.Output
    static let descriptor = ActionDescriptor(
        id: "podcast.export", summary: "Schreibt die Audiodatei eines fertigen Podcasts (M4A)", kind: .destructive, security: .outbound,
        input: .object([
            "podcast": podcastProperty, "path": .string("Zieldatei; ohne Angabe im Exportordner. Andere Orte brauchen eine Freigabe."),
            "overwrite": .boolean("Eine vorhandene Datei ersetzen"),
        ], required: ["podcast"]),
        output: .freeObject(), example: "llmd podcast export --podcast \"Predictive Coding\"", groups: ["podcast.core"]
    )
    static func preflight(_ args: Args, context: ActionContext) throws -> ActionPreflight {
        let podcast = try context.app.actionPodcast(args.podcast)
        // The audio speaks what the research found on the web.
        return context.exportPreflight(path: args.path, readsUntrusted: true, readsSensitive: context.app.podcastReadsSensitive(podcast), detail: podcast.displayTitle)
    }
    static func run(_ args: Args, context: ActionContext) async throws -> Output {
        let app = context.app
        let podcast = try app.actionPodcast(args.podcast)
        guard app.podcastAudioURL(podcast.id) != nil else { throw RPCError.invalidTarget("Der Podcast hat noch keine Audiodatei. Erst podcast.generate.") }
        let url = try context.exportURL(named: podcast.displayTitle, extension: "m4a", path: args.path, overwrite: args.overwrite)
        try app.exportPodcast(podcast.id, to: url)
        let bytes = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0
        return Output(path: url.path, bytes: bytes)
    }
}

struct PodcastPlayAction: LLMDAction {
    struct Args: Decodable, Sendable {
        var podcast: String
        var at: Double?
        var line: String?
        var pause: Bool?
    }
    static let descriptor = ActionDescriptor(
        id: "podcast.play", summary: "Spielt einen fertigen Podcast in der App ab, ab einer Sekunde oder Zeile, oder hält ihn an", kind: .read, security: .plainRead,
        input: .object([
            "podcast": podcastProperty, "at": .number("Ab dieser Sekunde", minimum: 0), "line": lineProperty, "pause": .boolean("Anhalten statt abspielen"),
        ], required: ["podcast"]),
        output: .freeObject(), groups: ["podcast.core"]
    )
    static func run(_ args: Args, context: ActionContext) async throws -> OKOutput {
        let app = context.app
        let podcast = try app.actionPodcast(args.podcast)
        let player = app.podcastPlayer
        if args.pause == true {
            if player.podcastID == podcast.id { player.pause() }
            return OKOutput(id: podcast.id.uuidString)
        }
        guard app.loadPodcastPlayer(podcast.id) else { throw RPCError.invalidTarget("Der Podcast hat noch keine Audiodatei.") }
        if let line = try args.line.map({ try podcast.actionLine($0) }), let start = podcast.lineStarts[line.id] {
            player.seek(to: start)
        } else if let at = args.at {
            player.seek(to: at)
        }
        player.play()
        return OKOutput(id: podcast.id.uuidString)
    }
}

struct PodcastStudioOpenAction: LLMDAction {
    struct Args: Decodable, Sendable {
        var podcast: String?
    }
    static let descriptor = ActionDescriptor(
        id: "podcast.studio.open", summary: "Öffnet das PodcastStudio, auf Wunsch bei einem Podcast", kind: .read, security: .plainRead,
        input: .object(["podcast": podcastProperty]), output: .freeObject()
    )
    static func run(_ args: Args, context: ActionContext) async throws -> OKOutput {
        let app = context.app
        let podcast = try args.podcast.map { try app.actionPodcast($0) }
        app.openPodcastStudio(showing: podcast?.id)
        if podcast == nil { app.selectedPodcastID = nil }
        return OKOutput(id: podcast?.id.uuidString)
    }
}

struct PodcastStudioCloseAction: LLMDAction {
    static let descriptor = ActionDescriptor(
        id: "podcast.studio.close", summary: "Schließt das PodcastStudio", kind: .read, security: .plainRead, output: .freeObject()
    )
    static func run(_ args: NoArgs, context: ActionContext) async throws -> OKOutput {
        context.app.closePodcastStudio()
        return OKOutput()
    }
}

// MARK: - Own sources and Writer

struct PodcastSourceAddAction: LLMDAction {
    struct Args: Decodable, Sendable {
        var podcast: String
        var url: String?
        var pdf: String?
        var onlySources: Bool?
    }
    static let descriptor = ActionDescriptor(
        id: "podcast.source.add", summary: "Gibt einem Podcast eine eigene Quelle: eine Webadresse oder ein PDF (wird in den Podcast kopiert)",
        kind: .write, security: .localWrite,
        input: .object([
            "podcast": podcastProperty, "url": .string("Webadresse"), "pdf": .string("Pfad eines PDFs"), "onlySources": onlySourcesProperty,
        ], required: ["podcast"]),
        output: .freeObject(), example: "llmd podcast source add --podcast Predictive --pdf ~/Studie.pdf --only-sources", groups: ["podcast.core"]
    )
    static func preflight(_ args: Args, context: ActionContext) throws -> ActionPreflight {
        var check = ActionPreflight(target: args.pdf ?? args.url)
        // A model or a client names a path: once copied, the podcast would show any file of this Mac to the caller.
        if args.pdf != nil, context.channel == .chat || context.channel == .mcp {
            check.needsConsent = "Ein PDF von dieser Stelle der Festplatte käme in die Bibliothek und wäre danach für den Aufrufer lesbar."
        }
        return check
    }
    static func run(_ args: Args, context: ActionContext) async throws -> OKOutput {
        let app = context.app
        let podcast = try app.actionPodcast(args.podcast)
        guard (args.url == nil) != (args.pdf == nil) else { throw RPCError.invalidParams("Genau eines angeben: url oder pdf.") }
        guard !podcast.phase.isRunning else { throw RPCError.invalidTarget("Der Podcast wird gerade erzeugt. Erst anhalten (podcast.stop).") }
        let before = podcast
        if let url = args.url {
            if let problem = app.addPodcastSource(url: url, to: podcast.id) { throw RPCError.invalidParams(problem) }
        } else if let pdf = args.pdf {
            let file = ActionExportFolder.expanded(pdf)
            guard FileManager.default.fileExists(atPath: file.path) else { throw RPCError.notFound("Die Datei gibt es nicht: \(file.path)") }
            do { try app.addPodcastSource(pdf: file, to: podcast.id) } catch { throw RPCError.invalidParams(error.localizedDescription) }
        }
        if let only = args.onlySources { app.podcasts.update(podcast.id) { $0.ownSources.onlyThese = only } }
        let after = app.podcasts.podcast(podcast.id) ?? podcast
        let library = app.podcasts
        context.undoGroup.add(UndoStep(label: "Quelle hinzufügen", undo: { [weak library] in library?.update(before.id) { $0.ownSources = before.ownSources } },
                                       redo: { [weak library] in library?.update(after.id) { $0.ownSources = after.ownSources } }))
        return OKOutput(id: podcast.id.uuidString, message: "\(after.ownSources.entries.count) eigene Quellen")
    }
}

struct PodcastSourceRemoveAction: LLMDAction {
    struct Args: Decodable, Sendable {
        var podcast: String
        var source: String
    }
    static let descriptor = ActionDescriptor(
        id: "podcast.source.remove", summary: "Entfernt eine eigene Quelle (Nummer ab 1, Webadresse oder Titel des PDFs); eine PDF-Kopie wird gelöscht",
        kind: .destructive, security: .destructive,
        input: .object(["podcast": podcastProperty, "source": .string("Nummer ab 1, Webadresse oder Titel")], required: ["podcast", "source"]), output: .freeObject()
    )
    static func run(_ args: Args, context: ActionContext) async throws -> OKOutput {
        let app = context.app
        let podcast = try app.actionPodcast(args.podcast)
        let entries = podcast.ownSources.entries
        let reference = args.source.trimmingCharacters(in: .whitespacesAndNewlines)
        let entry: PodcastOwnSources.Entry
        if let number = Int(reference), entries.indices.contains(number - 1) {
            entry = entries[number - 1]
        } else if let found = entries.first(where: { $0.label.localizedCaseInsensitiveCompare(reference) == .orderedSame }) {
            entry = found
        } else {
            throw RPCError.notFound("Quelle „\(reference)“ gibt es nicht.")
        }
        guard !podcast.phase.isRunning else { throw RPCError.invalidTarget("Der Podcast wird gerade erzeugt. Erst anhalten (podcast.stop).") }
        app.removePodcastSource(entry, from: podcast.id)
        return OKOutput(id: podcast.id.uuidString)
    }
}

struct PodcastToDocumentAction: LLMDAction {
    struct Args: Decodable, Sendable {
        var podcast: String
        var open: Bool?
    }
    static let descriptor = ActionDescriptor(
        id: "podcast.toDocument", summary: "Macht aus einem Podcast ein Writer-Dokument: Frage, Teilnehmer, Gespräch, Faktenblatt und Quellen",
        kind: .write, security: .localWrite,
        input: .object(["podcast": podcastProperty, "open": .boolean("Das Dokument in Writer Studio öffnen")], required: ["podcast"]),
        output: .freeObject(), example: "llmd podcast toDocument --podcast \"Predictive Coding\" --open", groups: ["podcast.core"]
    )
    /// The script and fact sheet carry what the research found on the web.
    static func preflight(_ args: Args, context: ActionContext) throws -> ActionPreflight {
        ActionPreflight(readsUntrusted: true, target: try context.app.actionPodcast(args.podcast).displayTitle)
    }
    static func run(_ args: Args, context: ActionContext) async throws -> OKOutput {
        let app = context.app
        let podcast = try app.actionPodcast(args.podcast)
        guard !podcast.script.isEmpty || !podcast.research.isEmpty else { throw RPCError.invalidTarget("Der Podcast hat noch kein Skript und keine Recherche.") }
        guard let made = app.createDocument(fromPodcast: podcast.id) else { throw RPCError.notFound("Den Podcast gibt es nicht mehr.") }
        let id = made.id
        context.undoGroup.add(UndoStep(label: "Dokument anlegen", undo: { app.removeDocumentForActionUndo(id) }, redo: { app.reinsertDocumentForActionRedo(made) }))
        if args.open == true { app.selectDocument(id) }
        return OKOutput(id: id.uuidString, message: made.displayTitle)
    }
}

