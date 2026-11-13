import AppKit
import LLMDProtocol

/// Finding what stands in a text by its lines: a box or a picture may stand inside a box or a section in columns, where
/// the blocks of `PowerText` end. Lines in code fences don't count.
@MainActor
enum WriterLines {
    struct Div {
        let classes: [String]
        let attributes: [String: String]
        let open: Int
        let close: Int
    }

    /// The divs in the order they open.
    static func divs(in lines: [String]) -> [Div] {
        var found: [(Div?, index: Int)] = []
        var stack: [(line: Int, slot: Int)] = []
        forEachLineOutsideCode(lines) { index, trimmed in
            if MarkdownParser.divOpening(trimmed) != nil {
                stack.append((index, found.count))
                found.append((nil, index))
            } else if !stack.isEmpty, MarkdownParser.isDivClosing(trimmed) {
                let open = stack.removeLast()
                let opening = lines[open.line].trimmingCharacters(in: .whitespaces)
                found[open.slot].0 = Div(classes: MarkdownParser.divOpening(opening) ?? [], attributes: MarkdownParser.divAttributes(opening), open: open.line, close: index)
            }
        }
        return found.compactMap(\.0)
    }

    /// The pictures: line number and reference.
    static func images(in lines: [String]) -> [(line: Int, reference: WriterImageReference)] {
        var images: [(line: Int, reference: WriterImageReference)] = []
        forEachLineOutsideCode(lines) { index, trimmed in
            if let reference = WriterImageReference.parse(trimmed) { images.append((index, reference)) }
        }
        return images
    }

    private static func forEachLineOutsideCode(_ lines: [String], _ body: (Int, String) -> Void) {
        var fence: String?
        for (index, line) in lines.enumerated() {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if let open = fence {
                if MarkdownParser.closesFence(trimmed, open) { fence = nil }
                continue
            }
            if let open = MarkdownParser.fenceOpening(trimmed) {
                fence = open
                continue
            }
            body(index, trimmed)
        }
    }

    /// A text with lines taken out or changed, with the blocks set apart again.
    static func normalized(_ lines: [String]) -> String {
        PowerText.join(PowerText.chunks(of: lines.joined(separator: "\n")).map(\.markdown))
    }
}

/// Which of several things is meant: a number from 1, or a block id. Without a reference, the only one there is.
@MainActor
enum WriterReference {
    /// `candidates`: what's there; `chunkText` tells for a block id whether a candidate is that block.
    static func pick<T>(_ reference: String?, from candidates: [T], label: String, markdown: String, matches: (T, String) -> Bool) throws -> T {
        guard let reference else {
            guard let first = candidates.first else { throw RPCError.notFound("\(label): In diesem Text steht nichts davon.") }
            guard candidates.count == 1 else {
                throw RPCError.ambiguous("\(label): Hier stehen \(candidates.count). Bitte die Nummer ab 1 oder die Block-ID angeben.",
                                         candidates: candidates.indices.map { String($0 + 1) })
            }
            return first
        }
        if let number = Int(reference) {
            guard candidates.indices.contains(number - 1) else { throw RPCError.notFound("\(label) \(number) gibt es nicht (\(candidates.count) vorhanden).") }
            return candidates[number - 1]
        }
        guard case .blocks(let range) = try WriterAddressing.resolve(WriterAddress(block: reference), in: markdown) else {
            throw RPCError.invalidParams("„\(reference)“ ist weder Nummer noch Block-ID.")
        }
        let chunk = PowerText.chunks(of: markdown)[range.lowerBound].markdown
        guard let hit = candidates.first(where: { matches($0, chunk) }) else { throw RPCError.invalidTarget("Block \(reference): \(label) gibt es dort nicht.") }
        return hit
    }

    /// The blocks an address means when something goes around them. A heading stands for its section.
    static func blockRange(_ address: WriterAddress, count: Int?, in markdown: String) throws -> Range<Int> {
        guard !address.isEmpty else { throw RPCError.invalidParams("Bitte angeben, um welche Blöcke es geht: block, heading, match, range oder all.") }
        let total = PowerText.chunks(of: markdown).count
        if let heading = address.heading { return try WriterAddressing.section(ofHeading: heading, in: markdown) }
        let first: Int
        switch try WriterAddressing.resolve(address, in: markdown) {
        case .whole: return 0..<total
        case .blocks(let range): first = range.lowerBound
        case .text(let block, _): first = block
        case .source(let range): first = try WriterAddressing.textStretch(for: range, in: markdown).block
        }
        return first..<min(total, first + max(1, count ?? 1))
    }

    /// The Markdown the editor writes for this Markdown.
    static func editorForm(_ markdown: String) -> String {
        WriterMarkdown.markdown(from: WriterMarkdown.attributedString(from: markdown)).trimmingCharacters(in: .newlines)
    }
}

/// A write on the text of a target with the checks every one needs first.
@MainActor
protocol WriterTargetedAction: LLMDAction where Output == WriterWriteResult {
    static func target(of args: Args) -> WriterTargetArgs
    /// The new text, and the block the result should name. What takes long comes first and reads the text after it
    /// from `target`: the person may have typed meanwhile.
    static func change(_ args: Args, markdown: String, target: WriterTarget, context: ActionContext) async throws -> (text: String, block: Int?)
}

@MainActor
extension WriterTargetedAction {
    static func preflight(_ args: Args, context: ActionContext) throws -> ActionPreflight {
        let target = try WriterTarget(self.target(of: args), app: context.app)
        try target.checkVersion(self.target(of: args).ifVersion)
        return target.writePreflight
    }

    static func run(_ args: Args, context: ActionContext) async throws -> WriterWriteResult {
        let target = try WriterTarget(self.target(of: args), app: context.app)
        let change = try await change(args, markdown: target.markdown, target: target, context: context)
        return try target.replaceBlocks(with: change.text, block: change.block, ifVersion: self.target(of: args).ifVersion, context: context)
    }
}
