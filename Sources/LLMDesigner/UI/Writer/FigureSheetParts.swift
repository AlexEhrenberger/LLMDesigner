import SwiftUI
import WebKit

/// Pieces the figure editors (chart, Mermaid, drawing) share.
struct FigureSheetHeader<Trailing: View>: View {
    let symbol: String
    let title: String
    @ViewBuilder var trailing: () -> Trailing

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: symbol)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(Theme.accent)
            Text(title)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(Theme.textPrimary)
            Spacer()
            trailing()
        }
    }
}

struct FigureSectionTitle: View {
    let title: String
    var detail: String?

    init(_ title: String, detail: String? = nil) {
        self.title = title
        self.detail = detail
    }

    var body: some View {
        HStack(spacing: 6) {
            Text(title).font(.system(size: 12.5, weight: .semibold)).foregroundStyle(Theme.textPrimary)
            if let detail {
                Text(detail).font(.system(size: 11.5)).foregroundStyle(Theme.textTertiary).lineLimit(1)
            }
        }
    }
}

/// A choice among a few, as a capsule (with an optional symbol).
struct FigureChip: View {
    let title: String
    var symbol: String?
    let isSelected: Bool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                if let symbol { Image(systemName: symbol).font(.system(size: 11, weight: .medium)) }
                Text(title).lineLimit(1)
            }
            .font(.system(size: 11.5, weight: isSelected ? .semibold : .regular))
            .foregroundStyle(isSelected ? Theme.accent : Theme.textSecondary)
            .padding(.horizontal, 9)
            .frame(maxWidth: .infinity)
            .frame(height: 26)
            .background(Capsule().fill(isSelected ? Theme.accent.opacity(0.18) : Theme.ink.opacity(hovering ? 0.08 : 0.04)))
            .overlay(Capsule().strokeBorder(isSelected ? Theme.accent.opacity(0.5) : Color.clear))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .focusable(false)
        .onHover { hovering = $0 }
    }
}

/// A colour to choose (six hex digits as printed); nil is "none".
struct FigureSwatch: View {
    let hex: String?
    var onDark = true
    var isFill = false
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            RoundedRectangle(cornerRadius: 5, style: .continuous)
                .fill(hex.map { Color(nsColor: WriterDrawing.color($0, dark: false, isFill: isFill)) } ?? Color.clear)
                .overlay {
                    if hex == nil { Image(systemName: "slash.circle").font(.system(size: 11)).foregroundStyle(Theme.textTertiary) }
                }
                .overlay(RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .strokeBorder(isSelected ? Theme.accent : Theme.ink.opacity(0.18), lineWidth: isSelected ? 2 : 1))
                .frame(width: 20, height: 20)
        }
        .buttonStyle(.plain)
        .focusable(false)
    }
}

/// A text field in the editors' look.
struct FigureField: View {
    let placeholder: String
    @Binding var text: String
    var monospaced = false

    var body: some View {
        TextField(placeholder, text: $text)
            .textFieldStyle(.plain)
            .font(.system(size: 12.5, design: monospaced ? .monospaced : .default))
            .padding(.horizontal, 9)
            .frame(height: 28)
            .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(Theme.ink.opacity(0.05)))
            .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous).strokeBorder(Theme.border))
    }
}

/// The footer of an editor: a hint, cancel and the main button.
struct FigureSheetFooter: View {
    let hint: String
    let commitTitle: String
    var isWorking = false
    var canCommit = true
    let onCancel: () -> Void
    let onCommit: () -> Void

    var body: some View {
        HStack {
            Text(hint)
                .font(.system(size: 11.5))
                .foregroundStyle(Theme.textTertiary)
                .lineLimit(2)
            Spacer()
            Button("Abbrechen", action: onCancel)
                .controlSize(.large)
                .keyboardShortcut(.cancelAction)
            Button(action: onCommit) {
                HStack(spacing: 6) {
                    if isWorking { ProgressView().controlSize(.small) }
                    Text(commitTitle)
                }
                .frame(minWidth: 100)
            }
            .controlSize(.large)
            .buttonStyle(.borderedProminent)
            .keyboardShortcut(.return, modifiers: .command)
            .disabled(!canCommit || isWorking)
        }
    }
}

/// An SVG shown fitted into its frame (the Mermaid editor's preview).
struct SVGPreview: NSViewRepresentable {
    let svg: String
    var background = "transparent"

    func makeNSView(context: Context) -> WKWebView {
        let view = WKWebView()
        view.setValue(false, forKey: "drawsBackground")
        return view
    }

    func updateNSView(_ view: WKWebView, context: Context) {
        guard context.coordinator.shown != svg + background else { return }
        context.coordinator.shown = svg + background
        let page = """
        <!doctype html><html><head><meta charset="utf-8"><style>
        html,body{margin:0;padding:0;height:100%;background:\(background);overflow:hidden}
        body{display:flex;align-items:center;justify-content:center}
        svg{max-width:96%;max-height:96%;width:auto;height:auto}
        </style></head><body>\(svg)</body></html>
        """
        view.loadHTMLString(page, baseURL: nil)
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator {
        var shown = ""
    }
}
