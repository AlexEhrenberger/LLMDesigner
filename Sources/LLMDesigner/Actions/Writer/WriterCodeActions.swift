import AppKit
import LLMDProtocol

extension ActionRegistry {
    func registerWriterCodeActions() {
        register(WriterCodeInsertAction.self)
        register(WriterCodeSetLanguageAction.self)
        register(WriterCodeFormatAction.self)
        register(WriterCodeFlowchartAction.self)
    }
}

struct WriterCodeArgs: Decodable, Sendable {
    var target: WriterTargetArgs
    var address: WriterAddress
    var position: String?
    var language: String?
    var code: String?
    var codeBlock: String?

    init(from decoder: Decoder) throws {
        target = try WriterTargetArgs(from: decoder)
        address = try WriterAddress(from: decoder)
        let c = try decoder.container(keyedBy: Keys.self)
        position = try c.decodeIfPresent(String.self, forKey: .position)
        language = try c.decodeIfPresent(String.self, forKey: .language)
        code = try c.decodeIfPresent(String.self, forKey: .code)
        codeBlock = try c.decodeIfPresent(String.self, forKey: .codeBlock)
    }

    enum Keys: String, CodingKey { case position, language, code, codeBlock }

    static let reference: [String: JSONSchema] = WriterTargetArgs.schemaProperties.merging([
        "codeBlock": .string("Code-Block: Nummer im Text ab 1 oder Block-ID; ohne Angabe der einzige"),
    ]) { _, new in new }

    /// The code block as a chunk.
    @MainActor
    func chunk(in markdown: String) throws -> PowerChunk {
        let blocks = PowerText.chunks(of: markdown).filter { $0.kind == .code }
        return try WriterReference.pick(codeBlock, from: blocks, label: "Code-Block", markdown: markdown) { $0.markdown == $1 }
    }
}

/// The code of a fenced block, and the words on its fence.
private func fenced(_ markdown: String) -> (fence: String, language: String, code: String)? {
    var lines = markdown.components(separatedBy: "\n")
    guard lines.count >= 2, let first = lines.first, first.trimmingCharacters(in: .whitespaces).hasPrefix("```") || first.trimmingCharacters(in: .whitespaces).hasPrefix("~~~") else { return nil }
    let opening = first.trimmingCharacters(in: .whitespaces)
    lines.removeFirst()
    if lines.last?.trimmingCharacters(in: .whitespaces).hasPrefix(String(opening.prefix(3))) == true { lines.removeLast() }
    return (String(opening.prefix(3)), opening.dropFirst(3).trimmingCharacters(in: .whitespaces), lines.joined(separator: "\n"))
}

struct WriterCodeInsertAction: WriterTargetedAction {
    typealias Args = WriterCodeArgs
    typealias Output = WriterWriteResult
    static let descriptor = ActionDescriptor(
        id: "writer.code.insert", summary: "Fügt einen Code-Block ein", kind: .write, security: .localWrite,
        input: .object(WriterTargetArgs.schemaProperties.merging(WriterPlacement.properties) { _, new in new }.merging([
            "language": .string("Sprache, z. B. python oder sql"), "code": .string("Der Code"),
        ]) { _, new in new }, required: ["code"]),
        output: .freeObject(), example: "llmd writer code insert --doc X --language python --code 'print(1)'"
    )
    static func target(of args: Args) -> WriterTargetArgs { args.target }
    static func change(_ args: Args, markdown: String, target: WriterTarget, context: ActionContext) async throws -> (text: String, block: Int?) {
        let code = args.code ?? ""
        // A fence inside the code would end the block.
        guard !code.components(separatedBy: "\n").contains(where: { $0.trimmingCharacters(in: .whitespaces).hasPrefix("```") }) else {
            throw RPCError.invalidParams("Der Code enthält selbst eine Zeile mit ```.")
        }
        let index = try WriterPlacement.index(args.address, position: args.position, in: markdown)
        return (PowerText.inserting("```\(args.language ?? "")\n\(code)\n```", at: index, into: markdown), index)
    }
}

struct WriterCodeSetLanguageAction: WriterTargetedAction {
    typealias Args = WriterCodeArgs
    typealias Output = WriterWriteResult
    static let descriptor = ActionDescriptor(
        id: "writer.code.setLanguage", summary: "Setzt die Sprache eines Code-Blocks; none lässt die App raten", kind: .write, security: .localWrite,
        input: .object(Args.reference.merging(["language": .string("Sprache oder none")]) { _, new in new }, required: ["language"]),
        output: .freeObject()
    )
    static func target(of args: Args) -> WriterTargetArgs { args.target }
    static func change(_ args: Args, markdown: String, target: WriterTarget, context: ActionContext) async throws -> (text: String, block: Int?) {
        let chunk = try args.chunk(in: markdown)
        guard let block = fenced(chunk.markdown) else { throw RPCError.invalidTarget("Dieser Block ist kein Code.") }
        let language = args.language == "none" ? "" : args.language ?? ""
        let new = "\(block.fence)\(language)\n\(block.code)\n\(block.fence)"
        return (PowerText.replacing(chunk.id, with: new, in: markdown), chunk.id)
    }
}

struct WriterCodeFormatAction: WriterTargetedAction {
    typealias Args = WriterCodeArgs
    typealias Output = WriterWriteResult
    static let descriptor = ActionDescriptor(
        id: "writer.code.format", summary: "Formatiert einen Code-Block in Python oder SQL", kind: .write, security: .localWrite,
        input: .object(Args.reference), output: .freeObject()
    )
    static func target(of args: Args) -> WriterTargetArgs { args.target }
    static func change(_ args: Args, markdown: String, target: WriterTarget, context: ActionContext) async throws -> (text: String, block: Int?) {
        let chunk = try args.chunk(in: markdown)
        guard let block = fenced(chunk.markdown), let language = CodeLanguage(fence: block.language) ?? CodeSnippet.snippets(in: chunk.markdown).first?.language else {
            throw RPCError.invalidTarget("Für diesen Code ist keine Sprache gewählt. Python und SQL lassen sich formatieren.")
        }
        let formatted = CodeFormatter.format(block.code, language: language)
        return (PowerText.replacing(chunk.id, with: "\(block.fence)\(block.language)\n\(formatted)\n\(block.fence)", in: markdown), chunk.id)
    }
}

struct WriterCodeFlowchartAction: WriterTargetedAction {
    typealias Args = WriterCodeArgs
    typealias Output = WriterWriteResult
    static let descriptor = ActionDescriptor(
        id: "writer.code.flowchart", summary: "Setzt Flussdiagramme zu einem Code-Block in Python oder SQL darunter", kind: .write, security: .localWrite,
        input: .object(Args.reference), output: .freeObject()
    )
    static func target(of args: Args) -> WriterTargetArgs { args.target }
    static func change(_ args: Args, markdown: String, target: WriterTarget, context: ActionContext) async throws -> (text: String, block: Int?) {
        let chunk = try args.chunk(in: markdown)
        guard let snippet = CodeSnippet.snippets(in: chunk.markdown).first else {
            throw RPCError.invalidTarget("Flussdiagramme gibt es für Python und SQL. Bitte die Sprache setzen.")
        }
        let graphs = snippet.flowcharts()
        guard !graphs.isEmpty else { throw RPCError.invalidTarget("Aus diesem Code entsteht kein Flussdiagramm.") }
        var references: [WriterImageReference] = []
        for graph in graphs {
            do {
                let images = try await FlowImageRenderer.shared.images(for: graph)
                let source = try WriterImageStore.storeDiagram(light: images.light, dark: images.dark, pdf: images.pdf)
                let width = max(35, min(90, Int(images.size.width / WriterImageStore.referenceColumnWidth * 100 * 0.85)))
                references.append(WriterImageReference(source: source, caption: "Ablauf: " + graph.title, width: width, isDiagram: true))
            } catch {
                throw RPCError.internal("Das Flussdiagramm ließ sich nicht zeichnen: \(error.localizedDescription)")
            }
        }
        // The person may have typed while the charts were drawn; the same function places them as for the analysis.
        var text = target.markdown
        for reference in references {
            guard let result = FlowchartInsertion.insert(reference, below: snippet.code, in: text) else {
                throw RPCError.invalidTarget("Der Code-Block steht nicht mehr im Text.")
            }
            text = result.markdown
        }
        return (text, nil)
    }
}
