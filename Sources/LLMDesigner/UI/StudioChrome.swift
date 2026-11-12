import SwiftUI

// Parts the newer studios (Data Studio, Rechercherista, Learning Studio) share: the title bar, the tab switch,
// section heads, cards and the empty state.

/// The studio's title bar: its symbol and name, a line about its contents, something in the middle (tabs) and
/// buttons on the right, with the cross that goes back to the chat.
struct StudioTopBar<Center: View, Trailing: View>: View {
    @Environment(AppModel.self) private var app
    let symbol: String
    let title: String
    var detail: String?
    let close: () -> Void
    @ViewBuilder var center: Center
    @ViewBuilder var trailing: Trailing
    @State private var width: CGFloat = 1200

    var body: some View {
        HStack(spacing: 10) {
            if !app.isSidebarDocked {
                SidebarToggleButton()
                NewItemMenu()
                    .padding(.trailing, 4)
            }
            Image(systemName: symbol)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(Theme.accent)
            Text(title)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Theme.textPrimary)
                .lineLimit(1)
                .fixedSize()
            if width >= 820, let detail, !detail.isEmpty {
                Text(detail)
                    .font(.system(size: 12).monospacedDigit())
                    .foregroundStyle(Theme.textTertiary)
                    .lineLimit(1)
                    .fixedSize()
            }
            Spacer(minLength: 12)
            center
            Spacer(minLength: 12)
            trailing
            IconButton(systemName: "xmark", help: "\(title) schließen und zurück zum Chat", size: 12.5, frameSize: Theme.titleBarControlSize) {
                withAnimation(.easeInOut(duration: 0.25)) { close() }
            }
        }
        .padding(.leading, app.isSidebarDocked ? 16 : Theme.trafficLightInset)
        .padding(.trailing, 12)
        .frame(height: Theme.titleBarHeight)
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
        .padding(.bottom, Theme.topBarBottomPadding + 4)
        .background(WindowDragArea())
    }
}

/// Tabs as a small segmented switch.
struct StudioTabPicker<Tab: Hashable & Identifiable>: View {
    let tabs: [Tab]
    @Binding var selection: Tab
    let title: (Tab) -> String
    let symbol: (Tab) -> String
    var badge: (Tab) -> Int? = { _ in nil }

    var body: some View {
        HStack(spacing: 2) {
            ForEach(tabs) { tab in
                let selected = selection == tab
                Button {
                    withAnimation(.snappy(duration: 0.2)) { selection = tab }
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: symbol(tab))
                            .font(.system(size: 11, weight: .medium))
                        Text(title(tab))
                            .font(.system(size: 12, weight: .semibold))
                            .lineLimit(1)
                        if let count = badge(tab), count > 0 {
                            Text("\(count)")
                                .font(.system(size: 10, weight: .bold).monospacedDigit())
                                .foregroundStyle(selected ? Theme.accent : Theme.textTertiary)
                        }
                    }
                    .foregroundStyle(selected ? Theme.textPrimary : Theme.textTertiary)
                    .padding(.horizontal, 10)
                    .frame(height: 24)
                    .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(selected ? Theme.selection : .clear))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(2)
        .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(Theme.ink.opacity(0.04)))
        .fixedSize()
    }
}

/// A small capital head over a group of rows.
struct StudioSectionHeader: View {
    let title: String
    var symbol: String?
    var count: Int?

    var body: some View {
        HStack(spacing: 6) {
            if let symbol {
                Image(systemName: symbol)
                    .font(.system(size: 9.5, weight: .semibold))
            }
            Text(title.uppercased())
                .font(.system(size: 10.5, weight: .semibold))
                .tracking(0.4)
                .lineLimit(1)
            Spacer(minLength: 0)
            if let count {
                Text("\(count)")
                    .font(.system(size: 10.5, weight: .medium).monospacedDigit())
            }
        }
        .foregroundStyle(Theme.textTertiary)
        .padding(.horizontal, 10)
        .padding(.top, 12)
        .padding(.bottom, 4)
    }
}

/// A rounded, faintly filled box for a group of controls.
struct StudioCard<Content: View>: View {
    var title: String?
    var symbol: String?
    var trailing: AnyView?
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let title {
                HStack(spacing: 7) {
                    if let symbol {
                        Image(systemName: symbol)
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(Theme.accent)
                    }
                    Text(title)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Theme.textPrimary)
                    Spacer(minLength: 0)
                    trailing
                }
            }
            content
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Theme.ink.opacity(0.035)))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Theme.border))
    }
}

/// A row in a studio's list on the left.
struct StudioListRow: View {
    let symbol: String
    var color: Color = Theme.accent
    let title: String
    var subtitle: String?
    var trailing: String?
    let isSelected: Bool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 9) {
                Image(systemName: symbol)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(color)
                    .frame(width: 22, height: 22)
                    .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(color.opacity(0.14)))
                VStack(alignment: .leading, spacing: 1) {
                    Text(title)
                        .font(.system(size: 12.5, weight: .medium))
                        .foregroundStyle(Theme.textPrimary)
                        .lineLimit(1)
                    if let subtitle, !subtitle.isEmpty {
                        Text(subtitle)
                            .font(.system(size: 11))
                            .foregroundStyle(Theme.textTertiary)
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: 0)
                if let trailing {
                    Text(trailing)
                        .font(.system(size: 10.5, weight: .medium).monospacedDigit())
                        .foregroundStyle(Theme.textTertiary)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(isSelected ? Theme.selection : hovering ? Theme.hover : .clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

/// What a studio shows before there is anything in it.
struct StudioEmptyState: View {
    let symbol: String
    let title: String
    let text: String
    var actionTitle: String?
    var action: (() -> Void)?

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: symbol)
                .font(.system(size: 36, weight: .light))
                .foregroundStyle(Theme.accent)
            Text(title)
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(Theme.textPrimary)
            Text(text)
                .font(.system(size: 12.5))
                .foregroundStyle(Theme.textSecondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 480)
            if let actionTitle, let action {
                Button(action: action) {
                    Label(actionTitle, systemImage: "plus")
                }
                .buttonStyle(.borderedProminent)
                .padding(.top, 4)
            }
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// A plain text field in the studios' look.
struct StudioField: View {
    let placeholder: String
    @Binding var text: String
    var font: Font = .system(size: 13)
    var monospaced = false

    var body: some View {
        TextField(placeholder, text: $text)
            .textFieldStyle(.plain)
            .font(monospaced ? .system(size: 12, design: .monospaced) : font)
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(Theme.ink.opacity(0.05)))
            .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).strokeBorder(Theme.border))
    }
}
