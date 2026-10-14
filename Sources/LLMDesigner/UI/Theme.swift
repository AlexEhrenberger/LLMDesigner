import SwiftUI

enum Theme {
    static let background = Color(hex: 0x0C0C0E)
    static let sidebar = Color(hex: 0x08080A)
    static let surface = Color(hex: 0x161619)
    static let elevated = Color(hex: 0x1E1E22)
    static let userBubble = Color(hex: 0x1D1D21)
    static let codeBackground = Color(hex: 0x111113)
    static let codeHeader = Color(hex: 0x18181B)

    static let hover = Color.white.opacity(0.055)
    static let selection = Color.white.opacity(0.09)
    static let border = Color.white.opacity(0.08)
    static let strongBorder = Color.white.opacity(0.12)

    static let textPrimary = Color(hex: 0xEDEDEF)
    static let textSecondary = Color(hex: 0xA1A1A9)
    static let textTertiary = Color(hex: 0x6E6E77)

    static let accent = Color(hex: 0xA996FF)
    static let success = Color(hex: 0x3FD68F)
    static let warning = Color(hex: 0xF2B14C)
    static let danger = Color(hex: 0xFF6B6B)

    static let inlineCodeBackground = Color.white.opacity(0.08)
    static let inlineCodeText = Color(hex: 0xE4DAFF)

    /// Height of the native title bar; its traffic lights are vertically centered in it.
    static let titleBarHeight: CGFloat = 32
    static let titleBarControlSize: CGFloat = 28
    static let topBarBottomPadding: CGFloat = 8
    static let trafficLightInset: CGFloat = 78
    static let sidebarWidth: CGFloat = 264
    static let outlineWidth: CGFloat = 280
    static let contentWidth: CGFloat = 768
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
