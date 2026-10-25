import AppKit

/// A typeface of Writer Studio: the font of a whole document and, as a passage's own font, of a selection in it.
///
/// Markdown has no fonts. A passage's font is stored as an HTML span (`<span style="font-family:Georgia">`), which
/// other programs show or ignore, and the Markdown export can leave it out. The four system designs keep the raw
/// values documents were saved with before there were more.
///
/// LaTeX (XeTeX through fontspec) loads every font that is installed in macOS by its name, so a font printed is the
/// font on the screen. Only the system's own designs (New York, SF Pro, …) are variable fonts that XeTeX can't
/// load; they print in the closest installed face (`latexFamily`).
enum WriterFont: String, CaseIterable, Identifiable, Sendable {
    // The system's designs.
    case serif, sans, rounded, mono
    // Serifs.
    case georgia, palatino, charter, baskerville, hoefler, times, cochin, didot
    // Sans serifs.
    case arial, gill, optima, futura, verdana
    // Typewriter and code faces.
    case courier, typewriter, monaco

    var id: String { rawValue }

    enum Group: String, CaseIterable, Identifiable, Sendable {
        case serif = "Serifen"
        case sans = "Serifenlos"
        case rounded = "Rund"
        case mono = "Schreibmaschine und Code"

        var id: String { rawValue }
    }

    var group: Group {
        switch self {
        case .serif, .georgia, .palatino, .charter, .baskerville, .hoefler, .times, .cochin, .didot: .serif
        case .sans, .arial, .gill, .optima, .futura, .verdana: .sans
        case .rounded: .rounded
        case .mono, .courier, .typewriter, .monaco: .mono
        }
    }

    var label: String {
        switch self {
        case .serif: "New York"
        case .sans: "SF Pro"
        case .rounded: "SF Pro Rounded"
        case .mono: "SF Mono"
        case .georgia: "Georgia"
        case .palatino: "Palatino"
        case .charter: "Charter"
        case .baskerville: "Baskerville"
        case .hoefler: "Hoefler Text"
        case .times: "Times New Roman"
        case .cochin: "Cochin"
        case .didot: "Didot"
        case .arial: "Arial"
        case .gill: "Gill Sans"
        case .optima: "Optima"
        case .futura: "Futura"
        case .verdana: "Verdana"
        case .courier: "Courier New"
        case .typewriter: "American Typewriter"
        case .monaco: "Monaco"
        }
    }

    /// The name in the toolbar, short.
    var shortLabel: String {
        switch self {
        case .rounded: "Rounded"
        case .mono: "SF Mono"
        case .typewriter: "Typewriter"
        case .times: "Times"
        case .hoefler: "Hoefler"
        default: label
        }
    }

    /// The system's own designs have no family name AppKit finds by name; they are made from the system font.
    var isSystemDesign: Bool {
        switch self {
        case .serif, .sans, .rounded, .mono: true
        default: false
        }
    }

    /// The family AppKit looks up; nil for the system designs.
    var familyName: String? {
        isSystemDesign ? nil : label
    }

    var isMonospaced: Bool { group == .mono }

    /// The family LaTeX sets the text in. Installed fonts print as they are; the system designs print in the
    /// closest face that XeTeX can load.
    var latexFamily: String {
        switch self {
        case .serif: "Iowan Old Style"
        case .sans: "Helvetica Neue"
        case .rounded: "Avenir Next"
        case .mono: "Menlo"
        default: label
        }
    }

    /// fontspec options for families whose bold and italic faces it can't tell apart by itself (Helvetica Neue
    /// takes Bold Italic for Bold). Nil for all others.
    var latexOptions: String? {
        switch self {
        case .sans: "[BoldFont={Helvetica Neue Bold},ItalicFont={Helvetica Neue Italic},BoldItalicFont={Helvetica Neue Bold Italic}]"
        default: nil
        }
    }

    /// For the picker: what the print uses when it is not the font itself.
    var printNote: String? {
        isSystemDesign ? "im Druck: \(latexFamily)" : nil
    }

    /// The size of a document's text in print: LaTeX sets it at 11 pt (`LaTeXWriter`).
    static let printSize: CGFloat = 11

    /// Screen points per point of print: the editor shows the text larger than it is printed (`bodySize` for 11 pt).
    /// A slide's canvas is printed as it is.
    func screenScale(onSlide: Bool) -> CGFloat {
        onSlide ? 1 : bodySize / Self.printSize
    }

    /// Text size. Fonts with a small x-height are set a little larger, so every face reads about the same.
    var bodySize: CGFloat {
        switch self {
        case .mono, .courier, .monaco: 15
        case .times, .didot, .cochin, .baskerville: 18
        case .verdana: 16
        case .typewriter: 16
        default: 17
        }
    }

    // MARK: CSS

    /// The `font-family` in a span: the system designs are CSS's own generic families, the others their name.
    var cssFamily: String {
        switch self {
        case .serif: "ui-serif"
        case .sans: "system-ui"
        case .rounded: "ui-rounded"
        case .mono: "ui-monospace"
        default: "'\(label)'"
        }
    }

    /// The font a `font-family` value names (the first family of the list).
    static func fromCSS(_ value: String) -> WriterFont? {
        let first = value.split(separator: ",").first.map(String.init) ?? value
        let name = first.trimmingCharacters(in: CharacterSet(charactersIn: " \t'\"")).lowercased()
        guard !name.isEmpty else { return nil }
        switch name {
        case "ui-serif": return .serif
        case "system-ui", "-apple-system", "sans-serif": return .sans
        case "ui-rounded": return .rounded
        case "ui-monospace", "monospace": return .mono
        case "serif": return .serif
        default: return allCases.first { $0.label.lowercased() == name }
        }
    }

    // MARK: Installed

    private static let installedFamilies: Set<String> = Set(NSFontManager.shared.availableFontFamilies)

    /// Whether this Mac has the font. The system designs always exist.
    var isInstalled: Bool {
        guard let familyName else { return true }
        return Self.installedFamilies.contains(familyName)
    }

    /// The fonts the picker offers: those this Mac has.
    static var available: [WriterFont] { allCases.filter(\.isInstalled) }

    static func available(in group: Group) -> [WriterFont] {
        available.filter { $0.group == group }
    }
}
