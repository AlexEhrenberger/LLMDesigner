import SwiftUI

/// The AI inside Writer Studio. It writes at its own cursor, rewrites a selection as a proposal, answers
/// questions about the document and checks it. Everything uses the model chosen at the top of the window.
@MainActor
@Observable
final class WriterAssistant {
    enum Activity: Equatable {
        case idle
        /// Waiting for the first words (or the model is thinking).
        case thinking
        case writing
        case rewriting
        case answering
        case checking(done: Int, total: Int)
    }

    /// How the next instruction is used; `nil` decides by the instruction and the selection.
    var forcedMode: WriterPrompts.Mode?
    private(set) var activity: Activity = .idle
    var answer: Answer?
    var proposal: Proposal?
    var findings: [Finding] = []
    var check: CheckRun?
    var isPanelShown = false
    var error: String?
    /// Asks the bar to take the keyboard focus.
    private(set) var focusRequest = 0

    struct Answer: Identifiable {
        let id = UUID()
        let question: String
        let aboutSelection: Bool
        var text = ""
        var isComplete = false
    }

    struct Proposal: Identifiable {
        let id = UUID()
        let title: String
        let instruction: String
        let original: String
        var text = ""
        var isComplete = false
    }

    struct Finding: Identifiable {
        let id = UUID()
        let check: WriterPrompts.Check
        let kind: String
        let original: String
        let correction: String
        let explanation: String
        var key: String { "finding-\(id.uuidString)" }
    }

    struct CheckRun {
        let check: WriterPrompts.Check
        let aboutSelection: Bool
        var isComplete = false
        var failedPieces = 0
        /// Findings the user applied; the panel says so instead of "no mistakes" once the list is empty.
        var applied = 0
    }

    @ObservationIgnored weak var app: AppModel?
    @ObservationIgnored weak var textView: WriterTextView?
    @ObservationIgnored private var task: Task<Void, Never>?

    var isBusy: Bool { activity != .idle }

    // MARK: Instructions from the bar

    /// What the bar's instruction would do right now.
    func mode(for instruction: String) -> WriterPrompts.Mode {
        let hasSelection = textView?.hasTextSelection ?? false
        if let forcedMode {
            if forcedMode == .rewrite && !hasSelection { return .write }
            return forcedMode
        }
        if WriterPrompts.looksLikeQuestion(instruction) { return .answer }
        return hasSelection ? .rewrite : .write
    }

    func send() {
        guard let app, !isBusy else { return }
        // Sending while dictating waits for the last words.
        if app.dictationIntoInstruction {
            Task {
                await app.stopDictation()
                self.send()
            }
            return
        }
        let instruction = app.writerInstruction.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !instruction.isEmpty else { return }
        app.writerInstruction = ""
        switch mode(for: instruction) {
        case .write: write(instruction)
        case .rewrite: rewrite(title: "Überarbeitung", instruction: instruction)
        case .answer: ask(instruction)
        }
    }

    func stop() {
        task?.cancel()
    }

    func requestFocus() { focusRequest += 1 }

    // MARK: Writing at the AI cursor

    func write(_ instruction: String) {
        guard let textView, let request = prepare() else { return }
        error = nil
        answer = nil
        let document = textView.assistantDocument(cursor: textView.aiCursorLocation, selection: nil, limit: request.limit)
        textView.beginAIWriting()
        activity = .thinking
        let messages = WriterPrompts.write(document: document, instruction: instruction)

        task = Task { [weak self] in
            var raw = ""
            do {
                for try await event in request.client.streamChat(model: request.model, messages: messages, temperature: 0.7) {
                    guard case .content(let piece) = event else { continue }
                    raw += piece
                    let text = WriterPrompts.cleanPartial(raw)
                    guard let self, !text.isEmpty else { continue }
                    self.activity = .writing
                    self.textView?.updateAIWriting(text)
                }
            } catch is CancellationError {
            } catch {
                if !Task.isCancelled { self?.error = Self.describe(error) }
            }
            guard let self else { return }
            self.textView?.finishAIWriting(WriterPrompts.clean(raw))
            if WriterPrompts.clean(raw).isEmpty, self.error == nil, !Task.isCancelled {
                self.error = "Das Modell hat nichts geschrieben."
            }
            self.activity = .idle
            self.task = nil
        }
    }

    // MARK: Rewriting the selection

    /// Rewrites the selection; the result waits as a proposal until it is applied or dismissed.
    func rewrite(title: String, instruction: String) {
        guard let textView, let request = prepare() else { return }
        let range = textView.selectedRange()
        guard range.length > 0, let selection = textView.selectedMarkdown() else {
            error = "Markiere zuerst den Text, der überarbeitet werden soll."
            return
        }
        error = nil
        answer = nil
        let document = textView.assistantDocument(cursor: nil, selection: range, limit: request.limit)
        textView.trackedRanges[WriterTextView.proposalKey] = range
        textView.markPassage(range)
        proposal = Proposal(title: title, instruction: instruction, original: selection)
        activity = .thinking
        let messages = WriterPrompts.rewrite(document: document, selection: selection, instruction: instruction)

        task = Task { [weak self] in
            var raw = ""
            do {
                for try await event in request.client.streamChat(model: request.model, messages: messages, temperature: 0.6) {
                    guard case .content(let piece) = event else { continue }
                    raw += piece
                    let text = WriterPrompts.cleanPartial(raw)
                    guard let self, !text.isEmpty else { continue }
                    self.activity = .rewriting
                    self.proposal?.text = text
                }
            } catch is CancellationError {
            } catch {
                if !Task.isCancelled { self?.error = Self.describe(error) }
            }
            guard let self else { return }
            self.proposal?.text = WriterPrompts.clean(raw)
            self.proposal?.isComplete = true
            if self.proposal?.text.isEmpty == true { self.dismissProposal() }
            self.activity = .idle
            self.task = nil
        }
    }

    func rewrite(_ preset: WriterPrompts.Rewrite) {
        rewrite(title: preset.label, instruction: preset.instruction)
    }

    func expand() {
        rewrite(title: "Ausformuliert", instruction: WriterPrompts.expandInstruction)
    }

    /// Puts the proposal in place of the original passage.
    func applyProposal() {
        guard let proposal, let textView, let range = textView.trackedRanges[WriterTextView.proposalKey] else { return }
        textView.replacePassage(range, withMarkdown: proposal.text)
        textView.placeAICursor(at: textView.selectedRange().location)
        dismissProposal()
    }

    /// Keeps the original and puts the proposal below it.
    func insertProposalBelow() {
        guard let proposal, let textView, let range = textView.trackedRanges[WriterTextView.proposalKey] else { return }
        textView.insertBelowParagraph(at: max(range.location, NSMaxRange(range) - 1), markdown: proposal.text)
        dismissProposal()
    }

    /// The same instruction again.
    func retryProposal() {
        guard let proposal, let textView, let range = textView.trackedRanges[WriterTextView.proposalKey] else { return }
        let title = proposal.title
        let instruction = proposal.instruction
        dismissProposal()
        textView.setSelectedRange(range)
        rewrite(title: title, instruction: instruction)
    }

    func dismissProposal() {
        if proposal != nil, activity == .rewriting || activity == .thinking { task?.cancel() }
        proposal = nil
        textView?.trackedRanges[WriterTextView.proposalKey] = nil
        textView?.markPassage(nil)
    }

    // MARK: Answers

    func ask(_ question: String) {
        guard let textView, let request = prepare() else { return }
        error = nil
        let range = textView.selectedRange()
        let selection = textView.selectedMarkdown()
        let document = textView.assistantDocument(cursor: nil, selection: selection == nil ? nil : range, limit: request.limit)
        answer = Answer(question: question, aboutSelection: selection != nil)
        activity = .thinking
        let messages = WriterPrompts.answer(document: document, selection: selection, question: question)

        task = Task { [weak self] in
            var raw = ""
            do {
                for try await event in request.client.streamChat(model: request.model, messages: messages, temperature: 0.4) {
                    guard case .content(let piece) = event else { continue }
                    raw += piece
                    let text = ThinkingSplitter.split(raw).content
                    guard let self, !text.isEmpty else { continue }
                    self.activity = .answering
                    self.answer?.text = text
                }
            } catch is CancellationError {
            } catch {
                if !Task.isCancelled { self?.error = Self.describe(error) }
            }
            guard let self else { return }
            let text = ThinkingSplitter.split(raw).content.trimmingCharacters(in: .whitespacesAndNewlines)
            self.answer?.text = text
            self.answer?.isComplete = true
            self.activity = .idle
            self.task = nil
            if text.isEmpty {
                self.answer = nil
            } else if let app = self.app, app.writerReadsAnswers, !Task.isCancelled, let answer = self.answer {
                app.toggleReading(answer.text, id: answer.id)
            }
        }
    }

    /// Puts the answer into the document at the AI cursor.
    func insertAnswer() {
        guard let answer, let textView else { return }
        textView.beginAIWriting()
        textView.finishAIWriting(answer.text)
        self.answer = nil
    }

    func dismissAnswer() {
        if let answer, app?.speakingMessageID == answer.id { app?.speechReader.stop() }
        if answer != nil, activity == .answering || activity == .thinking { task?.cancel() }
        answer = nil
    }

    // MARK: Checks

    /// Checks the selection or the whole document, piece by piece; findings show in the side panel as they come.
    func run(_ check: WriterPrompts.Check) {
        guard let textView, let request = prepare() else { return }
        error = nil
        clearFindings()
        // Small models overlook more in long pieces; spelling goes in shorter ones.
        let pieces = textView.checkPieces(limit: check == .language ? 900 : 1_600)
        guard !pieces.isEmpty else {
            error = "Hier gibt es keinen Text zum Prüfen."
            return
        }
        self.check = CheckRun(check: check, aboutSelection: textView.hasTextSelection)
        isPanelShown = true
        activity = .checking(done: 0, total: pieces.count)

        task = Task { [weak self] in
            for (index, piece) in pieces.enumerated() {
                guard !Task.isCancelled else { break }
                do {
                    let reply = try await request.client.complete(
                        model: request.model,
                        messages: WriterPrompts.check(check, text: piece.text),
                        temperature: 0.1, maxTokens: 1_800,
                        jsonSchema: (WriterPrompts.checkSchemaName, WriterPrompts.checkSchema(check))
                    )
                    guard let self, !Task.isCancelled else { break }
                    self.add(WriterPrompts.parseCheck(reply), check: check, scope: piece.range)
                } catch {
                    guard let self, !Task.isCancelled else { break }
                    self.check?.failedPieces += 1
                    self.error = Self.describe(error)
                }
                self?.activity = .checking(done: index + 1, total: pieces.count)
            }
            guard let self else { return }
            self.check?.isComplete = true
            self.activity = .idle
            self.task = nil
        }
    }

    private func add(_ results: [WriterPrompts.Finding], check: WriterPrompts.Check, scope: NSRange) {
        guard let textView else { return }
        for result in results {
            let original = result.original.trimmingCharacters(in: .whitespacesAndNewlines)
            let correction = result.korrektur.trimmingCharacters(in: .whitespacesAndNewlines)
            // Findings the text doesn't contain, or "corrections" that change nothing, are dropped.
            guard original.count >= 2, original != correction, let range = textView.locate(original, in: scope) else { continue }
            guard !findings.contains(where: { textView.trackedRanges[$0.key] == range }) else { continue }
            let finding = Finding(
                check: check, kind: result.art, original: (textView.string as NSString).substring(with: range),
                correction: correction, explanation: result.erklaerung.trimmingCharacters(in: .whitespacesAndNewlines)
            )
            textView.trackedRanges[finding.key] = range
            findings.append(finding)
        }
    }

    func show(_ finding: Finding) {
        guard let textView, let range = textView.trackedRanges[finding.key] else { return }
        textView.markPassage(range)
    }

    func apply(_ finding: Finding) {
        guard let textView, let range = textView.trackedRanges[finding.key], !finding.correction.isEmpty else { return }
        if textView.applyCorrection(range, original: finding.original, correction: finding.correction) {
            check?.applied += 1
        } else {
            error = "Die Stelle „\(finding.original)“ steht so nicht mehr im Text."
        }
        remove(finding)
    }

    func applyAll() {
        // From the end, so earlier corrections don't move later ones.
        let ordered = findings.filter { !$0.correction.isEmpty }.sorted {
            (textView?.trackedRanges[$0.key]?.location ?? 0) > (textView?.trackedRanges[$1.key]?.location ?? 0)
        }
        for finding in ordered { apply(finding) }
    }

    func remove(_ finding: Finding) {
        findings.removeAll { $0.id == finding.id }
        textView?.trackedRanges[finding.key] = nil
        textView?.markPassage(nil)
    }

    func clearFindings() {
        for finding in findings { textView?.trackedRanges[finding.key] = nil }
        findings = []
        check = nil
        textView?.markPassage(nil)
    }

    func closePanel() {
        if case .checking = activity { task?.cancel() }
        clearFindings()
        isPanelShown = false
    }

    /// Another document was opened: everything of the old one goes.
    func reset() {
        task?.cancel()
        task = nil
        answer = nil
        proposal = nil
        findings = []
        check = nil
        isPanelShown = false
        error = nil
        forcedMode = nil
        activity = .idle
    }

    // MARK: Context menu

    func handle(_ command: WriterAssistantCommand) {
        guard let textView else { return }
        switch command {
        case .rewrite(let preset): rewrite(preset)
        case .expand: expand()
        case .check(let check): run(check)
        case .askAboutSelection:
            forcedMode = .answer
            requestFocus()
        case .placeCursorHere:
            textView.placeAICursor(at: textView.selectedRange().location)
        case .continueHere:
            textView.placeAICursor(at: textView.selectedRange().location)
            write("Schreib an dieser Stelle sinnvoll weiter.")
        case .focusBar:
            requestFocus()
        }
    }

    // MARK: Helpers

    private struct Request {
        let client: LMStudioClient
        let model: String
        /// How many characters of the document fit into the prompt.
        let limit: Int
    }

    private func prepare() -> Request? {
        guard let app else { return nil }
        guard let client = app.client, let model = app.currentModelId else {
            error = "Kein Modell gewählt. Wähle oben ein Modell aus LM Studio."
            return nil
        }
        guard !isBusy else { return nil }
        let context = app.currentModel?.loadedContextLength ?? 8_192
        // About 3 characters per token; half the context for the document, the rest for instructions and the answer.
        return Request(client: client, model: model, limit: max(2_000, Int(Double(context) * 3 * 0.5)))
    }

    private static func describe(_ error: Error) -> String {
        if let error = error as? LocalizedError, let description = error.errorDescription { return description }
        return error.localizedDescription
    }
}
