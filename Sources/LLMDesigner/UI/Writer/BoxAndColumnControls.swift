import SwiftUI

/// The toolbar's box button: a new box of a kind, or, with the caret in a box, its look and place.
struct BoxButton: View {
    let controller: WriterEditorController
    @State private var showsPopover = false

    var body: some View {
        let style = controller.state.box
        ToolbarButton(symbol: style?.kind.symbol ?? "square.text.square",
                      help: style == nil ? "Kasten – für Definitionen, Merksätze, Beispiele; links, rechts, mittig oder vom Text umflossen" : "Kasten bearbeiten",
                      isActive: style != nil || showsPopover) {
            showsPopover.toggle()
        }
        .popover(isPresented: $showsPopover, arrowEdge: .bottom) {
            BoxPopover(controller: controller) { showsPopover = false }
        }
    }
}

private struct BoxPopover: View {
    let controller: WriterEditorController
    let close: () -> Void
    @State private var title = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let style = controller.state.box {
                settings(style)
            } else {
                Text(controller.state.hasSelection ? "Markierung in einen Kasten setzen" : "Kasten einfügen")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Theme.textSecondary)
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: 2), spacing: 6) {
                    ForEach(WriterBoxKind.allCases) { kind in
                        kindButton(kind, isSelected: false) {
                            controller.insertBox(kind)
                            close()
                        }
                    }
                }
                Text("Danach lassen sich Titel, Farbe, Rahmen und die Stellung im Text einstellen: links, rechts, mittig oder vom Text umflossen. ↩ in einer leeren letzten Zeile verlässt den Kasten.")
                    .font(.system(size: 10.5))
                    .foregroundStyle(Theme.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(12)
        .frame(width: 300)
    }

    @ViewBuilder
    private func settings(_ style: WriterBoxStyle) -> some View {
        Text("Kasten")
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(Theme.textSecondary)
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: 2), spacing: 6) {
            ForEach(WriterBoxKind.allCases) { kind in
                kindButton(kind, isSelected: style.kind == kind) {
                    var next = style
                    next.kind = kind
                    if next.title == style.kind.label { next.title = nil }
                    controller.setBoxStyle(next)
                }
            }
        }
        HStack(spacing: 6) {
            Text("Titel").font(.system(size: 12)).foregroundStyle(Theme.textTertiary)
            TextField(style.kind.label, text: $title)
                .textFieldStyle(.roundedBorder)
                .controlSize(.small)
                .onSubmit { applyTitle(style) }
                .onAppear { title = style.title ?? "" }
            Button {
                var next = style
                next.title = style.hasTitle ? "" : nil
                controller.setBoxStyle(next)
                title = next.title ?? ""
            } label: {
                Image(systemName: style.hasTitle ? "eye" : "eye.slash")
            }
            .buttonStyle(.plain)
            .foregroundStyle(Theme.textSecondary)
            .help(style.hasTitle ? "Ohne Titel" : "Mit Titel")
        }
        VStack(alignment: .leading, spacing: 6) {
            Text("Stellung").font(.system(size: 12)).foregroundStyle(Theme.textTertiary)
            HStack(spacing: 3) {
                ForEach(WriterBoxStyle.Position.allCases) { position in
                    ToolbarButton(symbol: position.symbol, help: position.label, isActive: style.position == position) {
                        var next = style
                        next.position = position
                        if position == .full || position == .center { next.wraps = false }
                        controller.setBoxStyle(next)
                    }
                }
                Spacer()
                Toggle("Umfließen", isOn: Binding(get: { style.floats }, set: { value in
                    var next = style
                    next.wraps = value
                    if value, next.position == .full || next.position == .center { next.position = .right }
                    controller.setBoxStyle(next)
                }))
                .toggleStyle(.checkbox)
                .font(.system(size: 12))
                .help("Der Text daneben fließt um den Kasten (links oder rechts)")
            }
            if style.position != .full {
                HStack(spacing: 4) {
                    Text("Breite").font(.system(size: 12)).foregroundStyle(Theme.textTertiary)
                    ForEach(WriterBoxStyle.widths, id: \.self) { width in
                        Button("\(width) %") {
                            var next = style
                            next.width = width
                            controller.setBoxStyle(next)
                        }
                        .buttonStyle(.plain)
                        .font(.system(size: 11, weight: style.width == width ? .semibold : .regular).monospacedDigit())
                        .foregroundStyle(style.width == width ? Theme.accent : Theme.textSecondary)
                        .padding(.horizontal, 4)
                    }
                }
            }
        }
        VStack(alignment: .leading, spacing: 6) {
            Text("Farbe und Rahmen").font(.system(size: 12)).foregroundStyle(Theme.textTertiary)
            HStack(spacing: 5) {
                ForEach(WriterColors.palette) { entry in
                    Button {
                        var next = style
                        next.color = entry.printHex == style.kind.color ? nil : entry.printHex
                        controller.setBoxStyle(next)
                    } label: {
                        Circle()
                            .fill(Color(nsColor: NSColor(hex: entry.dark)))
                            .frame(width: 16, height: 16)
                            .overlay(Circle().strokeBorder(style.printColor == entry.printHex ? Color.white : .clear, lineWidth: 2))
                    }
                    .buttonStyle(.plain)
                    .help(entry.name)
                }
            }
            Picker("", selection: Binding(get: { style.frame }, set: { frame in
                var next = style
                next.frame = frame
                controller.setBoxStyle(next)
            })) {
                ForEach(WriterBoxStyle.Frame.allCases) { Text($0.label).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
        }
        Divider()
        Button(role: .destructive) {
            controller.removeBox()
            close()
        } label: {
            Label("Kasten auflösen – der Text bleibt", systemImage: "square.slash")
                .font(.system(size: 12.5))
        }
        .buttonStyle(.plain)
        .foregroundStyle(Theme.danger)
    }

    private func applyTitle(_ style: WriterBoxStyle) {
        var next = style
        let trimmed = title.trimmingCharacters(in: .whitespaces)
        next.title = trimmed.isEmpty ? nil : trimmed
        controller.setBoxStyle(next)
    }

    private func kindButton(_ kind: WriterBoxKind, isSelected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 6) {
                RoundedRectangle(cornerRadius: 2).fill(Color(nsColor: WriterColors.display(kind.color, onDark: true) ?? .gray)).frame(width: 3, height: 16)
                Image(systemName: kind.symbol).font(.system(size: 11))
                Text(kind.label).font(.system(size: 12, weight: isSelected ? .semibold : .regular))
                Spacer(minLength: 0)
            }
            .foregroundStyle(isSelected ? Theme.accent : Theme.textSecondary)
            .padding(.horizontal, 7)
            .frame(height: 28)
            .background(RoundedRectangle(cornerRadius: 7).fill(isSelected ? Theme.accent.opacity(0.16) : Theme.ink.opacity(0.04)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// The toolbar's columns button: set the selection (or from the caret on) in two columns, or change the section's.
struct ColumnsButton: View {
    let controller: WriterEditorController
    @State private var showsPopover = false

    var body: some View {
        let style = controller.state.columns
        ToolbarButton(symbol: "rectangle.split.2x1", help: style == nil ? "Zwei Spalten – für die markierten Absätze oder ab hier" : "Spalten bearbeiten",
                      isActive: style != nil || showsPopover) {
            showsPopover.toggle()
        }
        .popover(isPresented: $showsPopover, arrowEdge: .bottom) {
            VStack(alignment: .leading, spacing: 10) {
                if let style {
                    Text("Abschnitt in \(style.count) Spalten")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Theme.textSecondary)
                    HStack {
                        Text("Abstand").font(.system(size: 12)).foregroundStyle(Theme.textTertiary)
                        Picker("", selection: Binding(get: { style.gap }, set: { gap in
                            var next = style
                            next.gap = gap
                            controller.setColumns(next)
                        })) {
                            ForEach(WriterColumnStyle.gaps, id: \.self) { Text(WriterParagraphFormat.label(cm: $0)).tag($0) }
                        }
                        .labelsHidden()
                        .fixedSize()
                    }
                    Toggle("Linie zwischen den Spalten", isOn: Binding(get: { style.rule }, set: { rule in
                        var next = style
                        next.rule = rule
                        controller.setColumns(next)
                    }))
                    .toggleStyle(.checkbox)
                    .font(.system(size: 12))
                    Divider()
                    row("Spaltenumbruch einfügen", "arrow.turn.down.right") { controller.insertColumnBreak() }
                    row("Ab hier eine Spalte", "rectangle") { controller.removeColumns(fromHere: true); showsPopover = false }
                    row("Ganzer Abschnitt eine Spalte", "rectangle.slash") { controller.removeColumns(); showsPopover = false }
                } else {
                    Text("Spalten")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Theme.textSecondary)
                    row(controller.state.hasSelection ? "Markierte Absätze in zwei Spalten" : "Ab diesem Absatz zwei Spalten", "rectangle.split.2x1") {
                        controller.setColumns(WriterColumnStyle())
                        showsPopover = false
                    }
                    Text("Der Text fließt von der linken in die rechte Spalte, beide gleich lang. Am Rand zeigt eine Klammer den Abschnitt; ein Spaltenumbruch beginnt die rechte Spalte früher. Im PDF und LaTeX: multicols.")
                        .font(.system(size: 10.5))
                        .foregroundStyle(Theme.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(12)
            .frame(width: 270)
        }
    }

    private func row(_ title: String, _ symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: symbol)
                .font(.system(size: 12.5))
                .foregroundStyle(Theme.textSecondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
