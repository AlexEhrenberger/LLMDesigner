import AppKit
import LLMDProtocol

extension ActionRegistry {
    func registerWriterAIActions() {
        register(WriterAIWriteAction.self)
        register(WriterAIRewriteAction.self)
        register(WriterAIExpandAction.self)
        register(WriterAIAnswerAction.self)
        register(WriterAICheckAction.self)
        register(WriterAICommentAction.self)
        register(WriterAICancelAction.self)
        register(WriterAIStatusAction.self)
    }
}

/// What agents asked the loaded model to do in documents. The action waits for the model; meanwhile another call can
/// ask what is running or stop it. The editor's assistant is separate: it belongs to the open editor and its selection.
@MainActor
final class WriterAIJobs {
    struct Job: Encodable, Sendable {
        var id: String
        var kind: String
        var doc: String
        var started: Date
    }

    struct Finished: Encodable, Sendable {
        var kind: String
        var doc: String
        var finished: Date
        var error: String?
    }

    private var running: [UUID: (job: Job, task: Task<Void, Never>)] = [:]
    private(set) var finished: [Finished] = []

    var jobs: [Job] { running.values.map(\.job).sorted { $0.started < $1.started } }

    func run<T: Sendable>(kind: String, doc: UUID, _ body: @escaping @MainActor () async throws -> T) async throws -> T {
        let id = UUID()
        var result: Result<T, Error>?
        let task = Task { @MainActor in
            do {
                result = .success(try await body())
            } catch {
                result = .failure(error)
            }
        }
        running[id] = (Job(id: id.uuidString, kind: kind, doc: doc.uuidString, started: Date()), task)
        await withTaskCancellationHandler { await task.value } onCancel: { task.cancel() }
        running[id] = nil
        func note(_ error: String?) {
            finished.append(Finished(kind: kind, doc: doc.uuidString, finished: Date(), error: error))
            if finished.count > 20 { finished.removeFirst(finished.count - 20) }
        }
        // A stopped stream may just end, with a result that is only a part.
        guard !task.isCancelled, let result else {
            note("Abgebrochen.")
            throw RPCError.unavailable("Die Aufgabe wurde abgebrochen.")
        }
        switch result {
        case .success(let value):
            note(nil)
            return value
        case .failure(let error):
            note(error.localizedDescription)
            throw error
        }
    }

    /// Stops what runs for a document, or everything. Says how many.
    func cancel(doc: UUID?) -> Int {
        let hits = running.values.filter { doc == nil || $0.job.doc == doc?.uuidString }
        for hit in hits { hit.task.cancel() }
        return hits.count
    }
}

struct WriterAIArgs: Decodable, Sendable {
    var target: WriterTargetArgs
    var address: WriterAddress
    var position: String?
    var instruction: String?
    var preset: String?
    var question: String?
    var kind: String?
    var apply: Bool?

    init(from decoder: Decoder) throws {
        target = try WriterTargetArgs(from: decoder)
        address = try WriterAddress(from: decoder)
        let c = try decoder.container(keyedBy: Keys.self)
        position = try c.decodeIfPresent(String.self, forKey: .position)
        instruction = try c.decodeIfPresent(String.self, forKey: .instruction)
        preset = try c.decodeIfPresent(String.self, forKey: .preset)
        question = try c.decodeIfPresent(String.self, forKey: .question)
        kind = try c.decodeIfPresent(String.self, forKey: .kind)
        apply = try c.decodeIfPresent(Bool.self, forKey: .apply)
    }

    enum Keys: String, CodingKey { case position, instruction, preset, question, kind, apply }

    static func properties(_ extra: [String: JSONSchema]) -> [String: JSONSchema] {
        WriterTargetArgs.schemaProperties.merging(WriterAddress.schemaProperties) { _, new in new }.merging(extra) { _, new in new }
    }
}

/// The text, the model and how much of the text fits.
@MainActor
private struct WriterAIRequest {
    let target: WriterTarget
    let client: LLMClient
    let model: String
    let limit: Int

    init(_ args: WriterAIArgs, context: ActionContext) throws {
        target = try WriterTarget(args.target, app: context.app)
        guard let client = context.app.client, let model = context.app.currentModelId else {
            throw RPCError.unavailable("Kein Sprachmodell gewählt.")
        }
        self.client = client
        self.model = model
        // About 3 characters per token; half the context for the document, as the editor's assistant has it.
        limit = max(2_000, Int(Double(context.app.currentModel?.workingContextLength ?? 8_192) * 3 * 0.5))
    }

    /// The document as the model reads it: without bookmarks and the fences of divs, the part around the marks.
    func document(_ markdown: String) -> String {
        var text = WriterMarkdown.removingDivFences(WriterBookmark.strip(markdown)).trimmingCharacters(in: .whitespacesAndNewlines)
        if text.isEmpty { text = WriterPrompts.cursorMarker }
        return WriterPrompts.window(of: text, limit: limit)
    }

    func stream(_ messages: [ChatPayloadMessage], temperature: Double) async throws -> String {
        var raw = ""
        for try await event in client.streamChat(model: model, messages: messages, temperature: temperature) {
            if case .content(let piece) = event { raw += piece }
        }
        return raw
    }
}

/// The addressed passage: its Markdown, and the text with the passage's marks for the model.
@MainActor
private func markedPassage(_ address: WriterAddress, in markdown: String) throws -> (selection: String, marked: String) {
    func marked(_ block: String, _ range: NSRange?) -> (selection: String, marked: String) {
        let text = WriterMarkdown.attributedString(from: block)
        let part = range ?? BlockEditor.fullRange(of: text)
        let selection = WriterMarkdown.inlineMarkdown(text.attributedSubstring(from: part))
        let paragraph = text.length > 0 ? text.attributes(at: min(part.location, text.length - 1), effectiveRange: nil).filter { WriterMarkdown.paragraphKeys.contains($0.key) } : [:]
        text.insert(NSAttributedString(string: WriterPrompts.selectionEnd, attributes: paragraph), at: NSMaxRange(part))
        text.insert(NSAttributedString(string: WriterPrompts.selectionStart, attributes: paragraph), at: part.location)
        return (selection, WriterMarkdown.markdown(from: text).trimmingCharacters(in: .newlines))
    }
    guard !address.isEmpty else { throw RPCError.invalidParams("Bitte angeben, welche Stelle: range, block, heading, match oder all.") }
    var blocks = PowerText.chunks(of: markdown).map(\.markdown)
    let index: Int
    let range: NSRange?
    switch try WriterAddressing.resolve(address, in: markdown) {
    case .whole:
        return (markdown, WriterPrompts.selectionStart + "\n\n" + markdown + "\n\n" + WriterPrompts.selectionEnd)
    case .blocks(let found):
        // Whole blocks of any kind stay as they are written.
        let start = found.lowerBound
        let selection = blocks[found].joined(separator: "\n\n")
        blocks[start] = WriterPrompts.selectionStart + "\n\n" + selection + "\n\n" + WriterPrompts.selectionEnd
        blocks.removeSubrange((start + 1)..<found.upperBound)
        return (selection, PowerText.join(blocks))
    case .text(let block, let found):
        (index, range) = (block, found)
    case .source(let found):
        let stretch = try WriterAddressing.textStretch(for: found, in: markdown)
        (index, range) = (stretch.block, stretch.range)
    }
    let (selection, text) = marked(blocks[index], range)
    blocks[index] = text
    return (selection, PowerText.join(blocks))
}

/// A model's work on a text: it may change the document, so the rule looks at what is read and written.
@MainActor
private func aiPreflight(_ args: WriterAIArgs, context: ActionContext) throws -> ActionPreflight {
    let target = try WriterTarget(args.target, app: context.app)
    try target.checkVersion(args.target.ifVersion)
    return target.readPreflight
}

struct WriterAIResult: Encodable, Sendable {
    var doc: String
    var version: String
    var text: String
    var block: String?
    var applied: Bool
}

struct WriterAIWriteAction: LLMDAction {
    typealias Args = WriterAIArgs
    typealias Output = WriterAIResult
    static let descriptor = ActionDescriptor(
        id: "writer.ai.write", summary: "Das geladene Modell schreibt an einer Stelle des Texts; ohne Adresse ans Ende", kind: .write, security: .localWrite,
        input: .object(Args.properties([
            "instruction": .string("Was das Modell schreiben soll"),
            "position": .choice(["before", "after"], "Vor oder nach der Adresse; Standard: after"),
        ]), required: ["instruction"]),
        output: .freeObject(), example: "llmd writer ai write --doc X --instruction 'Schreib eine Einleitung'"
    )
    static func preflight(_ args: Args, context: ActionContext) throws -> ActionPreflight { try aiPreflight(args, context: context) }

    static func run(_ args: Args, context: ActionContext) async throws -> Output {
        let request = try WriterAIRequest(args, context: context)
        let target = request.target
        let markdown = target.markdown
        let index = try WriterPlacement.index(args.address, position: args.position, in: markdown)
        let marked = PowerText.inserting(WriterPrompts.cursorMarker, at: index, into: markdown)
        let messages = WriterPrompts.write(document: request.document(marked), instruction: args.instruction ?? "")
        let raw = try await context.app.writerAIJobs.run(kind: "write", doc: target.documentID) {
            try await request.stream(messages, temperature: 0.7)
        }
        let text = WriterPrompts.clean(raw)
        guard !text.isEmpty else { throw RPCError.internal("Das Modell hat nichts geschrieben.") }
        // The person may have typed while the model wrote: the place is taken over into the text as it is now.
        let address: WriterAddress
        do {
            address = try WriterAddressing.rebase(args.address, from: markdown, to: target.markdown)
        } catch let error as RPCError {
            var data = error.data?.objectValue ?? [:]
            data["text"] = .string(text)
            throw RPCError(code: error.code, message: error.message + " Der Text des Modells steht in data.text.", data: .object(data))
        }
        let result = try target.insertBlocks(text, at: address, position: args.position, ifVersion: args.target.ifVersion, context: context)
        return WriterAIResult(doc: result.doc, version: result.version, text: text, block: result.block, applied: true)
    }
}

/// Rewriting a passage: the model's text replaces it, or with `apply: false` only comes back.
@MainActor
private func rewritePassage(_ args: WriterAIArgs, instruction: String, kind: String, context: ActionContext) async throws -> WriterAIResult {
    let request = try WriterAIRequest(args, context: context)
    let target = request.target
    let original = target.markdown
    let passage = try markedPassage(args.address, in: original)
    guard !passage.selection.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw RPCError.invalidTarget("Die Stelle enthält keinen Text.") }
    let messages = WriterPrompts.rewrite(document: request.document(passage.marked), selection: passage.selection, instruction: instruction)
    let raw = try await context.app.writerAIJobs.run(kind: kind, doc: target.documentID) {
        try await request.stream(messages, temperature: 0.6)
    }
    let text = WriterPrompts.clean(raw)
    guard !text.isEmpty else { throw RPCError.internal("Das Modell hat nichts geschrieben.") }
    guard args.apply != false else {
        return WriterAIResult(doc: target.documentID.uuidString, version: target.version, text: text, block: nil, applied: false)
    }
    // The person may have typed while the model wrote. The passage is looked for again in the text as it is now; if it
    // isn't there as the model read it, this is a conflict instead of overwriting what the person wrote. The model's
    // text comes back with it, so the work isn't lost.
    let current = target.markdown
    let address: WriterAddress
    do {
        address = try WriterAddressing.rebase(args.address, from: original, to: current)
        if current != original, try markedPassage(address, in: current).selection != passage.selection {
            throw RPCError.versionConflict(current: ActionVersion.of(current))
        }
    } catch let error as RPCError {
        var data = error.data?.objectValue ?? [:]
        data["text"] = .string(text)
        throw RPCError(code: RPCError.versionConflictCode, message: "Die Stelle hat sich geändert, während das Modell schrieb. Sein Text steht in data.text.",
                       data: .object(data))
    }
    let new = try WriterTextInsertMarkdownAction.place(text, at: address, position: "replace", in: current)
    let result = try target.replaceText(with: new, ifVersion: args.target.ifVersion, context: context)
    return WriterAIResult(doc: result.doc, version: result.version, text: text, block: nil, applied: true)
}

struct WriterAIRewriteAction: LLMDAction {
    typealias Args = WriterAIArgs
    typealias Output = WriterAIResult
    static let descriptor = ActionDescriptor(
        id: "writer.ai.rewrite", summary: "Das geladene Modell überarbeitet eine Stelle nach Vorgabe oder Anweisung", kind: .write, security: .localWrite,
        input: .object(Args.properties([
            "preset": .choice(WriterPrompts.Rewrite.allCases.map(\.rawValue), "Fertige Vorgabe"),
            "instruction": .string("Eigene Anweisung"),
            "apply": .boolean("Den Text gleich einsetzen; Standard: true, false liefert ihn nur als Vorschlag"),
        ])),
        output: .freeObject(), example: "llmd writer ai rewrite --doc X --heading Einleitung --preset shorter"
    )
    static func preflight(_ args: Args, context: ActionContext) throws -> ActionPreflight { try aiPreflight(args, context: context) }
    static func run(_ args: Args, context: ActionContext) async throws -> Output {
        guard let instruction = args.instruction ?? args.preset.flatMap(WriterPrompts.Rewrite.init(rawValue:))?.instruction else {
            throw RPCError.invalidParams("Bitte preset oder instruction angeben.")
        }
        return try await rewritePassage(args, instruction: instruction, kind: "rewrite", context: context)
    }
}

struct WriterAIExpandAction: LLMDAction {
    typealias Args = WriterAIArgs
    typealias Output = WriterAIResult
    static let descriptor = ActionDescriptor(
        id: "writer.ai.expand", summary: "Das geladene Modell macht aus Stichpunkten zusammenhängenden Text", kind: .write, security: .localWrite,
        input: .object(Args.properties(["apply": .boolean("Den Text gleich einsetzen; Standard: true")])), output: .freeObject()
    )
    static func preflight(_ args: Args, context: ActionContext) throws -> ActionPreflight { try aiPreflight(args, context: context) }
    static func run(_ args: Args, context: ActionContext) async throws -> Output {
        try await rewritePassage(args, instruction: WriterPrompts.expandInstruction, kind: "expand", context: context)
    }
}

struct WriterAIAnswerAction: LLMDAction {
    typealias Args = WriterAIArgs
    struct Output: Encodable, Sendable {
        var answer: String
    }
    static let descriptor = ActionDescriptor(
        id: "writer.ai.answer", summary: "Das geladene Modell beantwortet eine Frage zum Text oder zu einer Stelle", kind: .read, security: .plainRead,
        input: .object(Args.properties(["question": .string("Die Frage")]), required: ["question"]), output: .freeObject()
    )
    static func preflight(_ args: Args, context: ActionContext) throws -> ActionPreflight {
        try WriterTarget(args.target, app: context.app).readPreflight(ifVersion: args.target.ifVersion)
    }
    static func run(_ args: Args, context: ActionContext) async throws -> Output {
        let request = try WriterAIRequest(args, context: context)
        let markdown = request.target.markdown
        let passage = args.address.isEmpty ? nil : try markedPassage(args.address, in: markdown)
        let messages = WriterPrompts.answer(document: request.document(passage?.marked ?? markdown), selection: passage?.selection, question: args.question ?? "")
        let raw = try await context.app.writerAIJobs.run(kind: "answer", doc: request.target.documentID) {
            try await request.stream(messages, temperature: 0.4)
        }
        let answer = ThinkingSplitter.split(raw).content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !answer.isEmpty else { throw RPCError.internal("Das Modell hat nicht geantwortet.") }
        return Output(answer: answer)
    }
}

/// The running text of the addressed blocks, in pieces of about this size, with the block each paragraph stands in.
@MainActor
private func textPieces(_ address: WriterAddress, in markdown: String, limit: Int) throws -> [(text: String, blocks: [Int])] {
    let chunks = PowerText.chunks(of: markdown)
    var scope = Array(chunks.indices)
    var only: NSRange?
    if !address.isEmpty {
        switch try WriterAddressing.resolve(address, in: markdown) {
        case .whole: break
        case .blocks(let range): scope = Array(range)
        case .text(let block, let range):
            scope = [block]
            only = range
        case .source(let range):
            let stretch = try WriterAddressing.textStretch(for: range, in: markdown)
            scope = [stretch.block]
            only = stretch.range
        }
    }
    var pieces: [(text: String, blocks: [Int])] = []
    var text = ""
    var blocks: [Int] = []
    for index in scope where BlockEditor.holdsText(chunks[index].kind) {
        let attributed = WriterMarkdown.attributedString(from: chunks[index].markdown)
        let whole = NSRange(location: 0, length: attributed.length)
        for paragraph in WriterMarkdown.paragraphs(of: attributed, in: only ?? whole) {
            guard ![.code, .raw, .rule].contains(paragraph.block), !paragraph.block.isEmbed else { continue }
            let part = NSIntersectionRange(paragraph.contentRange, only ?? whole)
            guard part.length > 0 else { continue }
            let piece = (attributed.string as NSString).substring(with: part)
            guard piece.contains(where: { $0.isLetter }) else { continue }
            if !text.isEmpty, text.count + piece.count > limit {
                pieces.append((text, blocks))
                text = ""
                blocks = []
            }
            text += (text.isEmpty ? "" : "\n\n") + piece
            if blocks.last != index { blocks.append(index) }
        }
    }
    if !text.isEmpty { pieces.append((text, blocks)) }
    return pieces
}

/// Where a text the model quoted is in these blocks: exactly, else without regard to case and accents.
@MainActor
private func locate(_ quote: String, blocks: [Int], in chunks: [PowerChunk]) -> (block: Int, range: NSRange)? {
    for options: NSString.CompareOptions in [[], [.caseInsensitive, .diacriticInsensitive]] {
        for block in blocks where chunks.indices.contains(block) {
            let string = WriterMarkdown.attributedString(from: chunks[block].markdown).string as NSString
            let found = string.range(of: quote, options: options)
            if found.location != NSNotFound { return (block, found) }
        }
    }
    return nil
}

struct WriterAICheckAction: LLMDAction {
    typealias Args = WriterAIArgs
    struct Finding: Encodable, Sendable {
        var kind: String
        var original: String
        var correction: String
        var explanation: String
    }
    struct Output: Encodable, Sendable {
        var findings: [Finding]
        var failedPieces: Int
        var version: String
    }
    static let descriptor = ActionDescriptor(
        id: "writer.ai.check", summary: "Das geladene Modell prüft Sprache oder Plausibilität; es ändert nichts, sondern liefert Funde", kind: .read, security: .plainRead,
        input: .object(Args.properties(["kind": .choice(WriterPrompts.Check.allCases.map(\.rawValue), "Standard: language")])), output: .freeObject()
    )
    static func preflight(_ args: Args, context: ActionContext) throws -> ActionPreflight {
        try WriterTarget(args.target, app: context.app).readPreflight(ifVersion: args.target.ifVersion)
    }
    static func run(_ args: Args, context: ActionContext) async throws -> Output {
        let request = try WriterAIRequest(args, context: context)
        let check = args.kind.flatMap(WriterPrompts.Check.init(rawValue:)) ?? .language
        let markdown = request.target.markdown
        // Small models overlook more in long pieces; spelling goes in shorter ones.
        let pieces = try textPieces(args.address, in: markdown, limit: check == .language ? 900 : 1_600)
        guard !pieces.isEmpty else { throw RPCError.invalidTarget("Hier gibt es keinen Text zum Prüfen.") }
        let chunks = PowerText.chunks(of: markdown)
        return try await context.app.writerAIJobs.run(kind: "check", doc: request.target.documentID) {
            var findings: [Finding] = []
            var failed = 0
            for piece in pieces {
                try Task.checkCancellation()
                do {
                    let reply = try await request.client.complete(
                        model: request.model, messages: WriterPrompts.check(check, text: piece.text), temperature: 0.1, maxTokens: 1_800,
                        jsonSchema: (WriterPrompts.checkSchemaName, WriterPrompts.checkSchema(check))
                    )
                    for result in WriterPrompts.parseCheck(reply) {
                        let original = result.original.trimmingCharacters(in: .whitespacesAndNewlines)
                        let correction = result.korrektur.trimmingCharacters(in: .whitespacesAndNewlines)
                        // Findings the text doesn't contain, or "corrections" that change nothing, are dropped.
                        guard original.count >= 2, original != correction, locate(original, blocks: piece.blocks, in: chunks) != nil else { continue }
                        findings.append(Finding(kind: result.art, original: original, correction: correction,
                                                explanation: result.erklaerung.trimmingCharacters(in: .whitespacesAndNewlines)))
                    }
                } catch {
                    if Task.isCancelled { throw error }
                    failed += 1
                }
            }
            return Output(findings: findings, failedPieces: failed, version: request.target.version)
        }
    }
}

struct WriterAICommentAction: LLMDAction {
    typealias Args = WriterAIArgs
    struct Output: Encodable, Sendable {
        var doc: String
        var version: String
        var added: Int
        var failedPieces: Int
    }
    static let descriptor = ActionDescriptor(
        id: "writer.ai.comment", summary: "Das geladene Modell liest wie ein Lektor und setzt Kommentare an Textstellen", kind: .write, security: .localWrite,
        input: .object(Args.properties([:])), output: .freeObject()
    )
    static func preflight(_ args: Args, context: ActionContext) throws -> ActionPreflight { try aiPreflight(args, context: context) }
    static func run(_ args: Args, context: ActionContext) async throws -> Output {
        let request = try WriterAIRequest(args, context: context)
        let target = request.target
        let pieces = try textPieces(args.address, in: target.markdown, limit: 2_400)
        guard !pieces.isEmpty else { throw RPCError.invalidTarget("Hier gibt es keinen Text zum Kommentieren.") }
        let author = LaTeXWriter.speakerName(forModel: context.app.currentModelId)
        let results = try await context.app.writerAIJobs.run(kind: "comment", doc: target.documentID) {
            var replies: [(quote: String, text: String, blocks: [Int])] = []
            var failed = 0
            for piece in pieces {
                try Task.checkCancellation()
                do {
                    let reply = try await request.client.complete(
                        model: request.model, messages: WriterPrompts.comments(text: piece.text), temperature: 0.3, maxTokens: 1_800,
                        jsonSchema: (WriterPrompts.commentSchemaName, WriterPrompts.commentSchema)
                    )
                    for comment in WriterPrompts.parseComments(reply) {
                        let quote = comment.zitat.trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: "„“\"")))
                        let text = comment.kommentar.trimmingCharacters(in: .whitespacesAndNewlines)
                        guard quote.count >= 3, !text.isEmpty else { continue }
                        replies.append((quote, text, piece.blocks))
                    }
                } catch {
                    if Task.isCancelled { throw error }
                    failed += 1
                }
            }
            return (replies: replies, failed: failed)
        }
        // On the text as it is now: the person may have typed while the model read.
        var editor = BlockEditor(markdown: target.markdown)
        var added = 0
        for reply in results.replies {
            guard let found = locate(reply.quote, blocks: reply.blocks, in: PowerText.chunks(of: editor.markdown)) else { continue }
            editor.edit(found.block) { text in
                guard text.attribute(.writerComment, at: found.range.location, effectiveRange: nil) == nil else { return }
                let comment = WriterComment(entries: [WriterComment.Entry(author: author, isAI: true, date: Date(), text: reply.text)])
                text.addAttribute(.writerComment, value: comment, range: found.range)
                added += 1
            }
        }
        let result = try target.replaceText(with: editor.markdown, ifVersion: args.target.ifVersion, context: context)
        return Output(doc: result.doc, version: result.version, added: added, failedPieces: results.failed)
    }
}

struct WriterAICancelAction: LLMDAction {
    struct Args: Decodable, Sendable {
        var doc: String?
    }
    struct Output: Encodable, Sendable {
        var cancelled: Int
    }
    static let descriptor = ActionDescriptor(
        id: "writer.ai.cancel", summary: "Bricht ab, was das Modell für Agenten gerade schreibt; ohne doc alles", kind: .write, security: .localWrite,
        input: .object(["doc": .string("Dokument (ID oder Titel)")]), output: .freeObject()
    )
    static func run(_ args: Args, context: ActionContext) async throws -> Output {
        let id = try args.doc.map { try context.app.actionDocumentOrDeck($0).id }
        return Output(cancelled: context.app.writerAIJobs.cancel(doc: id))
    }
}

struct WriterAIStatusAction: LLMDAction {
    struct Output: Encodable, Sendable {
        var running: [WriterAIJobs.Job]
        var finished: [WriterAIJobs.Finished]
    }
    static let descriptor = ActionDescriptor(
        id: "writer.ai.status", summary: "Zeigt, was das Modell für Agenten gerade tut und zuletzt getan hat", kind: .read, security: .plainRead,
        output: .freeObject()
    )
    static func run(_ args: NoArgs, context: ActionContext) async throws -> Output {
        Output(running: context.app.writerAIJobs.jobs, finished: context.app.writerAIJobs.finished)
    }
}

extension AppModel {
    /// A document or a presentation by id or title.
    func actionDocumentOrDeck(_ reference: String) throws -> WriterDocument {
        do {
            return try actionDocument(reference)
        } catch let error as RPCError where error.code == RPCError.notFoundCode {
            do { return try actionDocument(reference, presentation: true) } catch { throw error }
        }
    }
}
