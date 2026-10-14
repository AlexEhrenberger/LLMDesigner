import AppKit
import SwiftUI

struct IconButton: View {
    let systemName: String
    let help: String
    var size: CGFloat = 15
    var frameSize: CGFloat = 32
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: size, weight: .regular))
                .foregroundStyle(hovering ? Theme.textPrimary : Theme.textSecondary)
                .frame(width: frameSize, height: frameSize)
                .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(hovering ? Theme.hover : .clear))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(help)
    }
}

struct SidebarToggleButton: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        IconButton(
            systemName: "sidebar.left",
            help: app.sidebarVisible ? "Seitenleiste ausblenden (⌃⌘S)" : "Seitenleiste einblenden (⌃⌘S)",
            frameSize: Theme.titleBarControlSize
        ) { app.toggleSidebar() }
    }
}

struct CopyButton: View {
    let text: () -> String
    var help = "Kopieren"
    var size: CGFloat = 12.5
    var frameSize: CGFloat = 32
    @State private var copied = false

    init(text: String, help: String = "Kopieren") {
        self.text = { text }
        self.help = help
    }

    init(help: String, size: CGFloat, frameSize: CGFloat, text: @escaping () -> String) {
        self.text = text
        self.help = help
        self.size = size
        self.frameSize = frameSize
    }

    var body: some View {
        IconButton(systemName: copied ? "checkmark" : "doc.on.doc", help: help, size: size, frameSize: frameSize) {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text(), forType: .string)
            copied = true
            Task {
                try? await Task.sleep(for: .seconds(1.5))
                copied = false
            }
        }
    }
}

struct StatusDot: View {
    let color: Color
    var size: CGFloat = 7

    var body: some View {
        Circle()
            .fill(color)
            .frame(width: size, height: size)
            .shadow(color: color.opacity(0.6), radius: 3)
    }
}

struct PulsingDot: View {
    var size: CGFloat = 11
    var color: Color = Theme.textPrimary

    var body: some View {
        Circle()
            .fill(color)
            .frame(width: size, height: size)
            .phaseAnimator([false, true]) { content, phase in
                content
                    .scaleEffect(phase ? 1 : 0.65)
                    .opacity(phase ? 1 : 0.5)
            } animation: { _ in .easeInOut(duration: 0.7) }
    }
}

struct Tag: View {
    let text: String
    var color: Color = Theme.textSecondary

    var body: some View {
        Text(text)
            .font(.system(size: 10.5, weight: .medium))
            .foregroundStyle(color)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(Capsule().fill(Color.white.opacity(0.06)))
    }
}

struct LogoMark: View {
    var size: CGFloat = 40

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: size * 0.28, style: .continuous)
                .fill(LinearGradient(colors: [Color(hex: 0x1F1B33), Color(hex: 0x0F0F12)], startPoint: .top, endPoint: .bottom))
                .overlay(
                    RoundedRectangle(cornerRadius: size * 0.28, style: .continuous)
                        .strokeBorder(Color.white.opacity(0.1))
                )
            Image(systemName: "sparkles")
                .font(.system(size: size * 0.46, weight: .medium))
                .foregroundStyle(
                    LinearGradient(colors: [Color(hex: 0xD6CCFF), Color(hex: 0x8B76FF)], startPoint: .topLeading, endPoint: .bottomTrailing)
                )
        }
        .frame(width: size, height: size)
    }
}

/// Empty area that moves the window when dragged and zooms it on double-click, like a title bar.
struct WindowDragArea: View {
    var body: some View {
        Color.clear
            .contentShape(Rectangle())
            .gesture(WindowDragGesture())
            .simultaneousGesture(TapGesture(count: 2).onEnded { NSApp.keyWindow?.zoom(nil) })
            .allowsWindowActivationEvents(true)
    }
}

/// Small marker in the left margin of a bookmarked passage.
struct BookmarkGlyph: View {
    var body: some View {
        Image(systemName: "bookmark.fill")
            .font(.system(size: 10))
            .foregroundStyle(Theme.accent)
            .help("Lesezeichen")
    }
}

extension View {
    /// Scroll target that sits a little above the view, so a jump leaves some room at the top.
    func scrollAnchor(_ id: String) -> some View {
        background(alignment: .top) {
            Color.clear
                .frame(height: 1)
                .offset(y: -18)
                .id(id)
        }
    }
}

extension ConnectionState {
    var color: Color {
        switch self {
        case .connecting: Theme.textTertiary
        case .connected: Theme.success
        case .failed: Theme.danger
        }
    }
}
