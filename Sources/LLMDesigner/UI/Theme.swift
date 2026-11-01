import SwiftUI

/// The app's colours. Each has a dark and a light value and follows the appearance chosen in the settings
/// (`AppAppearance`); SwiftUI views and AppKit views (through `NSColor(Theme.…)`) both resolve the right one.
enum Theme {
    static let background = dynamic(dark: 0x0C0C0E, light: 0xFFFFFF)
    static let sidebar = dynamic(dark: 0x08080A, light: 0xF5F5F7)
    static let surface = dynamic(dark: 0x161619, light: 0xF3F3F5)
    static let elevated = dynamic(dark: 0x1E1E22, light: 0xFFFFFF)
    static let userBubble = dynamic(dark: 0x1D1D21, light: 0xF0F0F3)
    static let codeBackground = dynamic(dark: 0x111113, light: 0xF7F7F9)
    static let codeHeader = dynamic(dark: 0x18181B, light: 0xEEEEF1)
    /// A sunken field for previews and canvases.
    static let well = dynamic(dark: 0x141417, light: 0xF0F0F3)
    /// Around Writer Studio's sheet: the app's background in the dark theme, a soft grey desk in the light one.
    static let desk = dynamic(dark: 0x0C0C0E, light: 0xEDEDF0)

    /// White in the dark theme, black in the light one: the subtle fills and lines are mixed from it.
    static let ink = dynamic(dark: .white, light: .black)
    /// Black for shadows and sunken wells, softer in the light theme.
    static let shade = dynamic(dark: .black, light: NSColor.black.withAlphaComponent(0.3))

    static let hover = dynamic(dark: NSColor.white.withAlphaComponent(0.055), light: NSColor.black.withAlphaComponent(0.045))
    static let selection = dynamic(dark: NSColor.white.withAlphaComponent(0.09), light: NSColor.black.withAlphaComponent(0.07))
    static let border = dynamic(dark: NSColor.white.withAlphaComponent(0.08), light: NSColor.black.withAlphaComponent(0.1))
    static let strongBorder = dynamic(dark: NSColor.white.withAlphaComponent(0.12), light: NSColor.black.withAlphaComponent(0.16))

    static let textPrimary = dynamic(dark: 0xEDEDEF, light: 0x1C1C1F)
    static let textSecondary = dynamic(dark: 0xA1A1A9, light: 0x55555D)
    static let textTertiary = dynamic(dark: 0x6E6E77, light: 0x8A8A92)

    static let accent = dynamic(dark: 0xA996FF, light: 0x6A54E0)
    static let success = dynamic(dark: 0x3FD68F, light: 0x1E9E61)
    static let warning = dynamic(dark: 0xF2B14C, light: 0xC27C0E)
    static let danger = dynamic(dark: 0xFF6B6B, light: 0xD64545)

    static let inlineCodeBackground = dynamic(dark: NSColor.white.withAlphaComponent(0.08), light: NSColor(hex: 0xEEEBFA))
    static let inlineCodeText = dynamic(dark: 0xE4DAFF, light: 0x5B43D6)

    /// Height of the native title bar; its traffic lights are vertically centered in it.
    static let titleBarHeight: CGFloat = 32
    static let titleBarControlSize: CGFloat = 28
    static let topBarBottomPadding: CGFloat = 8
    static let trafficLightInset: CGFloat = 78
    static let sidebarWidth: CGFloat = 264
    static let outlineWidth: CGFloat = 280
    /// The right-hand panel with the power access.
    static let powerWidth: CGFloat = 400
    static let contentWidth: CGFloat = 768

    /// Whether an appearance is a light one (`NSView.effectiveAppearance`, `NSAppearance.current`).
    static func isLight(_ appearance: NSAppearance) -> Bool {
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .aqua
    }

    /// A colour of its own with a value for each design, e.g. a category's: pastel on dark, deeper on white.
    static func dynamic(dark: UInt32, light: UInt32) -> Color {
        dynamic(dark: NSColor(hex: dark), light: NSColor(hex: light))
    }

    private static func dynamic(dark: NSColor, light: NSColor) -> Color {
        Color(nsColor: NSColor(name: nil) { isLight($0) ? light : dark })
    }
}

/// How the app looks: like the system, or always light or dark. Kept in the library's settings.
enum AppAppearance: String, CaseIterable, Identifiable {
    case system, light, dark

    var id: String { rawValue }

    var label: String {
        switch self {
        case .system: "Wie das System"
        case .light: "Hell"
        case .dark: "Dunkel"
        }
    }

    /// For `NSApp.appearance`; nil follows the system.
    var nsAppearance: NSAppearance? {
        switch self {
        case .system: nil
        case .light: NSAppearance(named: .aqua)
        case .dark: NSAppearance(named: .darkAqua)
        }
    }

    /// Every window follows `NSApp.appearance`; before the app has started there is nothing to set yet.
    @MainActor func apply() {
        NSApp?.appearance = nsAppearance
    }
}

extension NSColor {
    /// A colour of the design as it looks in an appearance; pictures that are drawn once (formulas) need a fixed one.
    func resolved(in appearance: NSAppearance?) -> NSColor {
        guard let appearance else { return self }
        var resolved = self
        appearance.performAsCurrentDrawingAppearance { resolved = self.usingColorSpace(.sRGB) ?? self }
        return resolved
    }
}

extension Color {
    init(hex: UInt32, opacity: Double = 1) {
        self.init(
            .sRGB,
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255,
            opacity: opacity
        )
    }
}
