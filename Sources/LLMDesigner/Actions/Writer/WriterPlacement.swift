import AppKit
import LLMDProtocol

/// Where a new block goes: next to the block an address names, at the end without one.
@MainActor
enum WriterPlacement {
    static let properties: [String: JSONSchema] = WriterAddress.schemaProperties.merging(
        ["position": .choice(["before", "after"], "Vor oder nach der Adresse; Standard: after; ohne Adresse ans Ende")]
    ) { _, new in new }

    /// The block index the new block takes.
    static func index(_ address: WriterAddress, position: String?, in markdown: String) throws -> Int {
        let count = PowerText.chunks(of: markdown).count
        guard !address.isEmpty else { return count }
        let before = position == "before"
        switch try WriterAddressing.resolve(address, in: markdown) {
        case .whole:
            return before ? 0 : count
        case .blocks(let range):
            return before ? range.lowerBound : range.upperBound
        case .text(let block, _):
            return before ? block : block + 1
        case .source(let range):
            let block = try WriterAddressing.textStretch(for: range, in: markdown).block
            return before ? block : block + 1
        }
    }
}

extension WriterTarget {
    /// Puts blocks into the text as one undoable step and says which block the first of them is.
    func insertBlocks(_ new: String, at address: WriterAddress, position: String?, ifVersion: String?, context: ActionContext) throws -> WriterWriteResult {
        let text = markdown
        let index = try WriterPlacement.index(address, position: position, in: text)
        return try replaceBlocks(with: PowerText.inserting(new, at: index, into: text), block: index, ifVersion: ifVersion, context: context)
    }

    /// The new text, and the id of the block the change is about.
    func replaceBlocks(with text: String, block: Int?, ifVersion: String?, context: ActionContext) throws -> WriterWriteResult {
        var result = try replaceText(with: text, ifVersion: ifVersion, context: context)
        let chunks = PowerText.chunks(of: text)
        if let block, chunks.indices.contains(block) {
            result.block = WriterBlockInfo.id(index: block, markdown: chunks[block].markdown)
        }
        return result
    }

    var writePreflight: ActionPreflight { ActionPreflight(target: document?.displayTitle) }
}

/// Whether a value is a colour, in the forms Writer knows: six hex digits with or without `#`, or a name.
@MainActor
func actionColor(_ value: String) throws -> String {
    let text = value.trimmingCharacters(in: .whitespaces)
    if let entry = WriterColors.palette.first(where: { $0.name.localizedCaseInsensitiveCompare(text) == .orderedSame }) { return entry.printHex }
    if let color = WriterColors.parse(text) ?? WriterColors.parse("#" + text) { return color }
    throw RPCError.invalidParams("„\(value)“ ist keine Farbe. Bitte sechs Hex-Ziffern oder einen Namen wie \(WriterColors.palette[0].name) angeben.")
}
