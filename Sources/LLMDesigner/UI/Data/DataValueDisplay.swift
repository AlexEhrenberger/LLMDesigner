import AppKit

/// Shows the values of `{{…}}` fields in a plain text view (Notes, project pages, Stories) while it is not being
/// edited; a click into it brings back the fields as written, at the same place. The text itself never changes:
/// the binding always gets the text with its fields.
@MainActor
final class DataValueDisplay {
    weak var view: NSTextView?
    /// The text with its fields while the values are shown; nil while the view shows the text as it is.
    private(set) var raw: String?
    /// Where each piece of the shown text came from, to put the caret at the same place after a click.
    private var pieces: [(shown: NSRange, raw: NSRange)] = []
    /// After the shown text changed its length (the view's height may change).
    var onSwap: (() -> Void)?
    private var observer: NSObjectProtocol?

    init() {
        observer = NotificationCenter.default.addObserver(forName: DataFields.changed, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.dataChanged() }
        }
    }

    deinit {
        if let observer { NotificationCenter.default.removeObserver(observer) }
    }

    /// The text as the binding knows it.
    var text: String { raw ?? view?.string ?? "" }

    static func hasFields(_ text: String) -> Bool {
        text.contains("{{") && !DataTokens.find(in: text).isEmpty
    }

    /// Puts the binding's text in: with values while the view isn't being edited.
    func set(_ text: String) {
        guard let view else { return }
        if view.window?.firstResponder === view || !Self.hasFields(text) {
            raw = nil
            pieces = []
            if view.string != text { view.string = text }
        } else {
            raw = text
            show()
        }
    }

    private func show() {
        guard let view, let raw, let storage = view.textStorage else { return }
        let font = view.font ?? .systemFont(ofSize: 13)
        let color = view.textColor ?? .labelColor
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = view.alignment
        let base: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color, .paragraphStyle: paragraph]
        let tint = NSColor(hex: 0x3FB8B8)
        let result = NSMutableAttributedString()
        var mapping: [(NSRange, NSRange)] = []
        var last = raw.startIndex
        let resolver = DataFields.resolver
        func append(_ text: String, _ attributes: [NSAttributedString.Key: Any], raw range: Range<String.Index>) {
            let shown = NSRange(location: result.length, length: (text as NSString).length)
            result.append(NSAttributedString(string: text, attributes: attributes))
            mapping.append((shown, NSRange(range, in: raw)))
        }
        for (range, ref) in DataTokens.find(in: raw) {
            if last < range.lowerBound { append(String(raw[last..<range.lowerBound]), base, raw: last..<range.lowerBound) }
            if let value = resolver.value(ref) {
                var attributes = base
                attributes[.backgroundColor] = tint.withAlphaComponent(0.13)
                attributes[.underlineStyle] = NSUnderlineStyle.single.rawValue | NSUnderlineStyle.patternDot.rawValue
                attributes[.underlineColor] = tint.withAlphaComponent(0.8)
                attributes[.toolTip] = resolver.label(ref) + "  " + ref.token
                append(value, attributes, raw: range)
            } else {
                var attributes = base
                attributes[.foregroundColor] = NSColor(hex: 0xE0A040)
                append(String(raw[range]), attributes, raw: range)
            }
            last = range.upperBound
        }
        if last < raw.endIndex { append(String(raw[last...]), base, raw: last..<raw.endIndex) }
        pieces = mapping
        storage.setAttributedString(result)
        view.needsDisplay = true
        onSwap?()
    }

    /// Back to the text with its fields; the caret stays where the click put it.
    func beginEditing() {
        guard raw != nil else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self, let view = self.view, let raw = self.raw, view.window?.firstResponder === view else { return }
            let caret = view.selectedRange().location
            var target = (raw as NSString).length
            for (shown, original) in self.pieces where caret >= shown.location && caret <= NSMaxRange(shown) {
                // Inside a value the caret goes behind its field; in plain text to the same letter.
                target = shown.length == original.length ? original.location + (caret - shown.location) : NSMaxRange(original)
                break
            }
            self.raw = nil
            self.pieces = []
            view.string = raw
            view.setSelectedRange(NSRange(location: min(target, (raw as NSString).length), length: 0))
            self.onSwap?()
        }
    }

    func endEditing() {
        guard let view, raw == nil, Self.hasFields(view.string) else { return }
        raw = view.string
        show()
    }

    private func dataChanged() {
        if raw != nil { show() }
    }
}
