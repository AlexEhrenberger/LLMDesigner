import Foundation
import NaturalLanguage

/// Conversation mode: the user speaks, the app notices the end of the turn and sends what it heard, reads the answer
/// aloud while the model is still writing it, and then listens again. The microphone is off while the answer plays,
/// so the voice can't hear itself.
@MainActor
@Observable
final class ConversationSession {
    enum Phase: Equatable {
        /// Microphone and speech model are being prepared; `progress` while the model downloads.
        case starting(progress: Double?)
        case listening
        /// The user switched the microphone off.
        case paused
        /// The turn is over; the answer is on its way.
        case waiting
        case speaking
        case failed(String)
    }

    /// Added to the system prompt for answers in conversation mode.
    static let systemHint = """
    Dies ist ein gesprochenes Gespräch: Die Nachrichten deines Gegenübers stammen aus einer Spracherkennung und können \
    Erkennungsfehler enthalten, deine Antworten werden vorgelesen. Antworte deshalb wie im Gespräch: natürlich und knapp, \
    meist in zwei bis vier Sätzen, außer dein Gegenüber möchte ausdrücklich mehr. Verwende kein Markdown, keine \
    Überschriften, Listen, Tabellen, Codeblöcke, Formeln oder Emojis, sondern ganze Sätze, die man gut hören kann. \
    Schreibe Zahlen, Einheiten und Abkürzungen so, wie man sie ausspricht. Antworte in der Sprache, in der dein Gegenüber spricht.
    """

    private(set) var phase: Phase = .starting(progress: nil)
    /// What the recogniser has understood in the current turn; stays visible until the answer starts.
    private(set) var transcript = ""
    private(set) var isMuted = false
    /// The model is thinking before it answers.
    private(set) var isThinking = false
    /// Short hint, e.g. when Qwen TTS is not reachable.
    private(set) var notice: String?
    /// The chat the conversation writes into; nil until the first turn of a new chat.
    private(set) var chatID: Chat.ID?
    private(set) var isEnding = false

    @ObservationIgnored let voice = ConversationVoice()
    @ObservationIgnored private weak var app: AppModel?
    /// `DictationEngine` on macOS 26.
    @ObservationIgnored private var recogniserEngine: AnyObject?
    @ObservationIgnored private var segmenter = SpokenAnswerSegmenter()
    @ObservationIgnored private var answerID: ChatMessage.ID?
    @ObservationIgnored private var language = "de"
    /// Text the recogniser has settled on, and text it may still change.
    @ObservationIgnored private var settled = ""
    @ObservationIgnored private var tentative = ""
    /// Last time the user was heard: louder than the room, or new words.
    @ObservationIgnored private var lastActivity = Date()
    /// Last time the recogniser came up with new words. Noise can keep the level up, words it can't.
    @ObservationIgnored private var lastWords = Date()
    @ObservationIgnored private var noiseFloor: Float = 0.15
    @ObservationIgnored private var turnWatcher: Task<Void, Never>?
    @ObservationIgnored private var noticeTask: Task<Void, Never>?
    /// Counts turns, so work for a turn that was cut short is dropped.
    @ObservationIgnored private var turn = 0

    init(app: AppModel, chatID: Chat.ID?) {
        self.app = app
        self.chatID = chatID
        voice.onStart = { [weak self] in
            guard let self, self.phase == .waiting else { return }
            self.phase = .speaking
            self.transcript = ""
        }
        voice.onFinish = { [weak self] in self?.answerPlayed() }
        voice.onNotice = { [weak self] message in self?.show(message) }
    }

    func start() {
        listen()
    }

    func end() {
        isEnding = true
        turn += 1
        turnWatcher?.cancel()
        noticeTask?.cancel()
        voice.shutDown()
        Task { await stopRecogniser() }
    }

    /// Click on the wave or the space bar: send now while listening, interrupt the answer, or switch the microphone back on.
    func primaryAction() {
        switch phase {
        case .listening: endTurn()
        case .waiting, .speaking: interrupt()
        case .paused: toggleMute()
        case .failed: listen()
        case .starting: break
        }
    }

    func toggleMute() {
        guard !isEnding else { return }
        isMuted.toggle()
        if isMuted, phase == .listening || phase.isStarting {
            // What was heard so far is dropped.
            turn += 1
            turnWatcher?.cancel()
            transcript = ""
            phase = .paused
            Task { await stopRecogniser() }
        } else if !isMuted, phase == .paused {
            listen()
        }
        // While an answer is coming, the switch takes effect afterwards.
    }

    /// Stops the answer (writing and speaking) and listens again.
    func interrupt() {
        guard phase == .waiting || phase == .speaking else { return }
        voice.stop()
        answerID = nil
        if let chatID, let app, app.isGenerating(chatID) { app.stopGeneration(in: chatID) }
        listen()
    }

    // MARK: Listening

    private func listen() {
        guard !isEnding else { return }
        turn += 1
        settled = ""
        tentative = ""
        transcript = ""
        isThinking = false
        turnWatcher?.cancel()
        guard !isMuted else {
            phase = .paused
            return
        }
        guard #available(macOS 26.0, *), let app else {
            phase = .failed("Der Gesprächsmodus braucht macOS 26.")
            return
        }
        let recogniser = makeRecogniser()
        if !phase.isStarting { phase = .listening }
        lastActivity = Date()
        lastWords = Date()
        let mode = app.dictationMode
        Task { await recogniser.start(mode: mode) }
        watchForEndOfTurn()
    }

    @available(macOS 26.0, *)
    private func makeRecogniser() -> DictationEngine {
        if let engine = recogniserEngine as? DictationEngine { return engine }
        let engine = DictationEngine()
        engine.onStatus = { [weak self] status in self?.recogniserChanged(status) }
        engine.onVolatile = { [weak self] text in
            self?.tentative = text
            self?.updateTranscript()
        }
        engine.onFinal = { [weak self] text in
            guard let self else { return }
            self.settled = Self.joined(self.settled, text)
            self.updateTranscript()
        }
        engine.onLevel = { [weak self] level in self?.heard(level: level) }
        engine.onError = { [weak self] message in self?.fail(message) }
        recogniserEngine = engine
        return engine
    }

    private func stopRecogniser() async {
        guard #available(macOS 26.0, *), let engine = recogniserEngine as? DictationEngine else { return }
        await engine.stop()
    }

    private func recogniserChanged(_ status: DictationStatus) {
        switch status {
        case .preparing(let progress):
            // Only the very first start (or a model download) is worth showing.
            if phase.isStarting || (progress != nil && phase == .listening) { phase = .starting(progress: progress) }
        case .listening:
            if phase.isStarting {
                phase = .listening
                // The pause counts from the moment the microphone is open.
                lastActivity = Date()
                lastWords = Date()
            }
        case .finishing, .idle:
            break
        }
    }

    private func updateTranscript() {
        let text = Self.joined(settled, tentative)
        // New or changed words count as speaking; punctuation added afterwards doesn't, and neither does the
        // moment between clearing the tentative text and delivering it as final.
        let new = Self.words(text)
        if !Self.words(transcript).hasPrefix(new) {
            lastActivity = Date()
            lastWords = Date()
        }
        transcript = text
    }

    /// The wave doesn't follow the microphone; the level only tells whether the user is still speaking.
    private func heard(level: Float) {
        if level < noiseFloor {
            noiseFloor = noiseFloor * 0.8 + level * 0.2
        } else {
            noiseFloor += (level - noiseFloor) * 0.03
        }
        if level > max(0.3, noiseFloor + 0.2) { lastActivity = Date() }
    }

    /// Ends the turn once the user has said something and then stayed quiet for the pause from the settings.
    /// Background noise can keep the level up; without new words the turn ends 1.5 s after the pause anyway.
    private func watchForEndOfTurn() {
        let turn = self.turn
        turnWatcher = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(100))
                guard let self, self.turn == turn else { return }
                // The microphone may still be getting ready (first turn, model download); keep watching.
                if self.phase.isStarting { continue }
                guard self.phase == .listening else { return }
                let pause = self.app?.conversationPause ?? AppModel.defaultConversationPause
                let now = Date()
                let quiet = now.timeIntervalSince(self.lastActivity) >= pause
                let noNewWords = now.timeIntervalSince(self.lastWords) >= pause + 1.5
                if Self.hasWords(self.transcript), quiet || noNewWords {
                    self.endTurn()
                    return
                }
            }
        }
    }

    /// The user has finished speaking: collect the last words and send everything.
    private func endTurn() {
        guard phase == .listening, Self.hasWords(transcript) else { return }
        turn += 1
        let turn = self.turn
        turnWatcher?.cancel()
        phase = .waiting
        Task {
            await stopRecogniser()
            guard self.turn == turn, !isEnding else { return }
            let text = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
            guard Self.hasWords(text) else { return listen() }
            send(text)
        }
    }

    // MARK: Answer

    private func send(_ text: String) {
        guard let app else { return }
        // A shortcut such as ⌘N may have switched chats in the meantime.
        if let chatID, app.selectedChatID != chatID, app.chat(chatID) != nil { app.selectChat(chatID) }
        guard let sent = app.sendSpoken(text) else {
            fail("Die Nachricht konnte nicht gesendet werden. Ist in LM Studio ein Modell geladen?")
            return
        }
        chatID = sent.chat
        answerID = sent.answer
        language = SpeakableText.language(of: text)
        segmenter = SpokenAnswerSegmenter()
        voice.begin(voice: app.voice(for: app.chat(sent.chat)), rate: app.speechRate)
    }

    /// The answer as it streams in.
    func answerChanged(_ messageID: ChatMessage.ID, content: String, isThinking: Bool) {
        guard messageID == answerID else { return }
        if self.isThinking != isThinking { self.isThinking = isThinking }
        speak(segmenter.pieces(for: content, isComplete: false), answer: content)
    }

    func answerFinished(_ message: ChatMessage) {
        guard message.id == answerID else { return }
        answerID = nil
        isThinking = false
        if let error = message.error {
            voice.stop()
            fail(error)
        } else if message.stopped == true {
            // Stopped with ⌘. – silence, then listen again.
            voice.stop()
            listen()
        } else {
            speak(segmenter.pieces(for: message.content, isComplete: true), answer: message.content)
            voice.finish()
        }
    }

    private func speak(_ pieces: [String], answer: String) {
        guard !pieces.isEmpty else { return }
        // Short openings ("Ja, gern.") are easily misread as another language; the question decides until there is more.
        if answer.count >= 60 { language = SpeakableText.language(of: answer) }
        for piece in pieces { voice.enqueue(piece, language: language) }
    }

    private func answerPlayed() {
        let turn = self.turn
        Task {
            // A short pause, so the end of the voice doesn't reach the microphone.
            try? await Task.sleep(for: .milliseconds(250))
            guard self.turn == turn, phase == .speaking || phase == .waiting else { return }
            listen()
        }
    }

    private func fail(_ message: String) {
        guard !isEnding else { return }
        turn += 1
        turnWatcher?.cancel()
        phase = .failed(message)
        Task { await stopRecogniser() }
    }

    private func show(_ message: String) {
        notice = message
        noticeTask?.cancel()
        noticeTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(8))
            guard !Task.isCancelled else { return }
            self?.notice = nil
        }
    }

    // MARK: Text

    private nonisolated static func joined(_ first: String, _ second: String) -> String {
        let first = first.trimmingCharacters(in: .whitespaces)
        let second = second.trimmingCharacters(in: .whitespaces)
        if first.isEmpty { return second }
        if second.isEmpty { return first }
        return first + " " + second
    }

    private nonisolated static func words(_ text: String) -> String {
        String(text.lowercased().filter { $0.isLetter || $0.isNumber })
    }

    nonisolated static func hasWords(_ text: String) -> Bool {
        text.contains { $0.isLetter || $0.isNumber }
    }
}

extension ConversationSession.Phase {
    var isStarting: Bool {
        if case .starting = self { return true }
        return false
    }
}

/// Cuts an answer that is still streaming into pieces a voice can read: whole sentences only, never inside a code
/// block or display formula. The first piece goes out as soon as possible, so speaking starts early; later pieces
/// gather a few sentences, which sounds more natural and costs fewer TTS requests.
struct SpokenAnswerSegmenter {
    private static let firstPieceLength = 20
    private static let pieceLength = 100

    /// Characters of the answer that have been taken.
    private var consumed = 0
    /// Complete sentences that are not long enough for a piece yet.
    private var collected = ""
    private var handedOut = 0

    /// New pieces (plain text without Markdown) for the answer as it stands; `isComplete` hands out the rest.
    mutating func pieces(for answer: String, isComplete: Bool) -> [String] {
        guard answer.count >= consumed else { return [] }
        let rest = String(answer.dropFirst(consumed))
        let length = isComplete ? rest.count : Self.completeLength(of: rest, after: answer.prefix(consumed))
        consumed += length
        collected += rest.prefix(length)

        let minimum = handedOut == 0 ? Self.firstPieceLength : Self.pieceLength
        guard !collected.isEmpty, isComplete || collected.count >= minimum else { return [] }
        let text = SpeakableText.from(markdown: collected)
        collected = ""
        guard ConversationSession.hasWords(text) else { return [] }
        handedOut += 1
        return [text]
    }

    /// Length of the leading part of `rest` that ends with a complete sentence (0 if there is none yet).
    private static func completeLength(of rest: String, after taken: Substring) -> Int {
        var starts: [String.Index] = []
        let tokenizer = NLTokenizer(unit: .sentence)
        tokenizer.string = rest
        tokenizer.enumerateTokens(in: rest.startIndex..<rest.endIndex) { range, _ in
            starts.append(range.lowerBound)
            return true
        }
        // The last sentence may still be growing; everything before it is complete. A boundary only counts once some
        // text follows it: with just "Am 3." the tokenizer can't tell an ordinal from the end of a sentence yet.
        // German ordinals ("am 3. Oktober") look like sentence ends; joining two sentences there costs nothing.
        func endsWithNumber(_ index: String.Index) -> Bool {
            rest[..<index].trimmingCharacters(in: .whitespacesAndNewlines).range(of: #"\d\.$"#, options: .regularExpression) != nil
        }
        guard let last = starts.dropFirst().last(where: { rest.distance(from: $0, to: rest.endIndex) >= 12 && !endsWithNumber($0) })
        else { return 0 }
        let length = rest.distance(from: rest.startIndex, to: last)
        let text = taken + rest.prefix(length)
        // Not inside a code block or a display formula.
        func count(_ marker: String) -> Int { text.components(separatedBy: marker).count - 1 }
        guard count("```").isMultiple(of: 2), count("$$").isMultiple(of: 2), count("\\[") == count("\\]") else { return 0 }
        return length
    }
}
