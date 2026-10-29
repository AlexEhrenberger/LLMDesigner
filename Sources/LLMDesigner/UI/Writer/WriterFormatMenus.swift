import SwiftUI

/// The font of the selection, or of the whole document. The list shows each font in itself.
struct FontMenu: View {
    @Environment(AppModel.self) private var app
    let controller: WriterEditorController
    let document: WriterDocument
    @State private var showsPopover = false
    @State private var hovering = false
    @State private var scope: Scope = .document

    enum Scope: String, CaseIterable, Identifiable {
        case selection = "Auswahl"
        case document = "Ganzes Dokument"

        var id: String { rawValue }
    }

    var body: some View {
        Button {
            scope = controller.state.hasSelection ? .selection : .document
            showsPopover.toggle()
        } label: {
            MenuLabel(symbol: "textformat", title: (controller.state.passageFont ?? document.textFont).shortLabel, hovering: hovering || showsPopover)
        }
        .buttonStyle(.plain)
        .focusable(false)
        .fixedSize()
        .onHover { hovering = $0 }
        .popover(isPresented: $showsPopover, arrowEdge: .bottom) {
            FontPicker(controller: controller, document: document, scope: $scope) { showsPopover = false }
        }
        .help("Schrift – der Auswahl oder des ganzen Dokuments. Im LaTeX-Druck erscheint dieselbe Schrift.")
    }
}

private struct FontPicker: View {
    @Environment(AppModel.self) private var app
    let controller: WriterEditorController
    let document: WriterDocument
    @Binding var scope: FontMenu.Scope
    let close: () -> Void

    var body: some View {
        let state = controller.state
        let current: WriterFont? = scope == .document ? document.font : state.passageFont
        VStack(alignment: .leading, spacing: 10) {
            Picker("", selection: $scope) {
                ForEach(FontMenu.Scope.allCases) { scope in Text(scope.rawValue).tag(scope) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    if scope == .selection {
                        FontRow(title: "Wie das Dokument", detail: document.font.label, font: nil, isCurrent: current == nil) {
                            controller.setTextFont(nil)
                            close()
                        }
                    }
                    ForEach(WriterFont.Group.allCases) { group in
                        let fonts = WriterFont.available(in: group)
                        if !fonts.isEmpty {
                            Text(group.rawValue)
                                .font(.system(size: 10.5, weight: .semibold))
                                .foregroundStyle(Theme.textTertiary)
                                .padding(.horizontal, 8)
                                .padding(.top, 8)
                            ForEach(fonts) { font in
                                FontRow(title: font.label, detail: font.printNote, font: font, isCurrent: current == font) {
                                    if scope == .document { app.setDocumentFont(document.id, font) } else { controller.setTextFont(font) }
                                    close()
                                }
                            }
                        }
                    }
                }
            }
            .frame(height: 360)

            Text(scope == .document
                 ? (document.pageFormat == .manuscript
                    ? "Die Normseite ist in Courier gesetzt. Die Schrift hier gilt wieder in den anderen Seitenformaten."
                    : "Die Schrift für alles, was keine eigene hat.")
                 : (state.hasSelection ? "Nur die markierte Stelle." : "Der Text, der ab dem Cursor getippt wird."))
                .font(.system(size: 10.5))
                .foregroundStyle(Theme.textTertiary)
        }
        .padding(12)
        .frame(width: 290)
    }
}

private struct FontRow: View {
    let title: String
    let detail: String?
    let font: WriterFont?
    let isCurrent: Bool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: "checkmark")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(Theme.accent)
                    .opacity(isCurrent ? 1 : 0)
                    .frame(width: 12)
                Text(title)
                    .font(sample)
                    .foregroundStyle(hovering ? Theme.textPrimary : Theme.textSecondary)
                    .lineLimit(1)
                Spacer(minLength: 4)
                if let detail {
                    Text(detail)
                        .font(.system(size: 10))
                        .foregroundStyle(Theme.textTertiary)
                        .lineLimit(1)
                }
            }
            .padding(.horizontal, 8)
            .frame(height: 28)
            .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(hovering ? Theme.hover : .clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .focusable(false)
        .onHover { hovering = $0 }
    }

    private var sample: Font {
        guard let font else { return .system(size: 13) }
        return Font(WriterStyler.font(font, size: 14))
    }
}

// MARK: Colour

/// Colours the selected text: nine colours that stay readable on dark and on white paper, or any colour.
struct ColorMenu: View {
    let controller: WriterEditorController
    @State private var showsPopover = false
    @State private var hovering = false

    var body: some View {
        let hex = controller.state.passageColor
        Button { showsPopover.toggle() } label: {
            VStack(spacing: 1.5) {
                Text("A")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(hovering || showsPopover ? Theme.textPrimary : Theme.textSecondary)
                RoundedRectangle(cornerRadius: 1.5, style: .continuous)
                    .fill(hex.map { Color(WriterColors.swatch($0)) } ?? Theme.textTertiary)
                    .frame(width: 14, height: 3)
            }
            .frame(width: 30, height: 28)
            .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(hovering || showsPopover ? Theme.hover : .clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .focusable(false)
        .onHover { hovering = $0 }
        .popover(isPresented: $showsPopover, arrowEdge: .bottom) {
            ColorPickerPanel(controller: controller) { showsPopover = false }
        }
        .help("Schriftfarbe – der Auswahl, sonst des Textes ab dem Cursor. Im Druck erscheint dieselbe Farbe.")
    }
}

private struct ColorPickerPanel: View {
    let controller: WriterEditorController
    let close: () -> Void
    @State private var custom = Color.white

    var body: some View {
        let current = controller.state.passageColor
        VStack(alignment: .leading, spacing: 12) {
            Text("Schriftfarbe")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Theme.textSecondary)
            LazyVGrid(columns: Array(repeating: GridItem(.fixed(30), spacing: 8), count: 5), spacing: 8) {
                ForEach(WriterColors.palette) { entry in
                    Button {
                        controller.setTextColor(entry.printHex)
                        close()
                    } label: {
                        Circle()
                            .fill(Color(hex: entry.dark))
                            .frame(width: 26, height: 26)
                            .overlay(Circle().strokeBorder(Color.white.opacity(0.18)))
                            .overlay {
                                if current == entry.printHex {
                                    Image(systemName: "checkmark")
                                        .font(.system(size: 11, weight: .bold))
                                        .foregroundStyle(Color.black.opacity(0.75))
                                }
                            }
                    }
                    .buttonStyle(.plain)
                    .focusable(false)
                    .help(entry.name)
                }
            }
            Divider()
            PopoverActionRow(title: "Standardfarbe", symbol: "arrow.uturn.backward", isDisabled: current == nil) {
                controller.setTextColor(nil)
                close()
            }
            HStack {
                Image(systemName: "eyedropper.halffull")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Theme.textSecondary)
                    .frame(width: 18)
                Text("Eigene Farbe")
                    .font(.system(size: 12.5))
                    .foregroundStyle(Theme.textSecondary)
                Spacer()
                ColorPicker("", selection: $custom, supportsOpacity: false)
                    .labelsHidden()
                    .onChange(of: custom) { _, color in
                        if let hex = WriterColors.hex(of: NSColor(color)) { controller.setTextColor(hex) }
                    }
            }
            .padding(.horizontal, 8)
            Text("Die Farben passen sich dem Blatt an: auf dunklem Papier heller, im Druck so kräftig wie gewählt.")
                .font(.system(size: 10.5))
                .foregroundStyle(Theme.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(12)
        .frame(width: 214)
    }
}

/// A row of a popover, with an icon.
struct PopoverActionRow: View {
    let title: String
    let symbol: String
    var isDisabled = false
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 9) {
                Image(systemName: symbol)
                    .font(.system(size: 12, weight: .medium))
                    .frame(width: 18)
                Text(title)
                    .font(.system(size: 12.5))
                Spacer(minLength: 0)
            }
            .foregroundStyle(isDisabled ? Theme.textTertiary.opacity(0.6) : (hovering ? Theme.textPrimary : Theme.textSecondary))
            .padding(.horizontal, 8)
            .frame(height: 27)
            .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(hovering && !isDisabled ? Theme.hover : .clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .focusable(false)
        .disabled(isDisabled)
        .onHover { hovering = $0 }
    }
}

// MARK: Code

/// With the caret in a code block: its language, and tidying the code.
struct CodeLanguageMenu: View {
    let controller: WriterEditorController
    let state: WriterTextView.State
    @State private var hovering = false

    var body: some View {
        Menu {
            Section("Sprache des Codes") {
                Button {
                    controller.setCodeLanguage(nil)
                } label: {
                    if state.isCodeLanguageExplicit { Text("Automatisch erkennen") } else { Label("Automatisch erkennen", systemImage: "checkmark") }
                }
                ForEach(CodeLanguage.allCases) { language in
                    Button {
                        controller.setCodeLanguage(language)
                    } label: {
                        if state.isCodeLanguageExplicit && state.codeLanguage == language { Label(language.label, systemImage: "checkmark") } else { Text(language.label) }
                    }
                }
            }
            Button("Code formatieren (⌥⇧⌘F)", systemImage: "text.alignleft") { controller.formatCode() }
                .disabled(state.codeLanguage == nil)
        } label: {
            MenuLabel(symbol: "chevron.left.forwardslash.chevron.right", title: state.codeLanguage?.label ?? "Code", hovering: hovering)
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .onHover { hovering = $0 }
        .help("Sprache des Code-Blocks (Python, SQL) – der Code wird dafür eingefärbt, eingerückt und lässt sich formatieren")
    }
}

// MARK: Size

/// The size of the selection (or of the text typed from the caret on), in points as printed; on slides, points of the
/// slide. The button shows the size at the caret.
struct FontSizeMenu: View {
    let controller: WriterEditorController
    let document: WriterDocument
    @State private var showsPopover = false
    @State private var hovering = false

    var body: some View {
        let state = controller.state
        Button { showsPopover.toggle() } label: {
            HStack(spacing: 4) {
                Text(WriterSpanStyle.format(state.fontSize))
                    .font(.system(size: 12.5, weight: state.hasOwnFontSize ? .semibold : .medium).monospacedDigit())
                    .foregroundStyle(state.hasOwnFontSize ? Theme.textPrimary : (hovering || showsPopover ? Theme.textPrimary : Theme.textSecondary))
                    .frame(minWidth: 18)
                Image(systemName: "chevron.down")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(Theme.textTertiary)
            }
            .padding(.horizontal, 8)
            .frame(height: 28)
            .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(hovering || showsPopover ? Theme.hover : .clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .focusable(false)
        .fixedSize()
        .onHover { hovering = $0 }
        .popover(isPresented: $showsPopover, arrowEdge: .bottom) {
            FontSizePicker(controller: controller, isSlide: document.deck != nil) { showsPopover = false }
        }
        .help("Schriftgröße in Punkt – der Auswahl, sonst des Textes ab dem Cursor. ⌘+ und ⌘− vergrößern und verkleinern.")
    }
}

private struct FontSizePicker: View {
    let controller: WriterEditorController
    let isSlide: Bool
    let close: () -> Void
    @State private var text = ""
    @FocusState private var fieldFocused: Bool

    private var presets: [Double] {
        isSlide ? [12, 14, 16, 18, 20, 24, 28, 32, 36, 40, 44, 48, 54, 60, 72, 96] : [8, 9, 10, 11, 12, 14, 16, 18, 20, 24, 28, 32, 36, 48, 60, 72]
    }

    var body: some View {
        let state = controller.state
        VStack(alignment: .leading, spacing: 12) {
            Text("Schriftgröße")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Theme.textSecondary)
            HStack(spacing: 6) {
                ToolbarButton(symbol: "textformat.size.smaller", help: "Kleiner (⌘−)", isActive: false) { controller.changeFontSize(by: -1) }
                TextField("", text: $text)
                    .textFieldStyle(.roundedBorder)
                    .multilineTextAlignment(.center)
                    .frame(width: 58)
                    .focused($fieldFocused)
                    .onSubmit(applyTyped)
                Text("pt")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.textTertiary)
                ToolbarButton(symbol: "textformat.size.larger", help: "Größer (⌘+)", isActive: false) { controller.changeFontSize(by: 1) }
            }
            LazyVGrid(columns: Array(repeating: GridItem(.fixed(44), spacing: 6), count: 4), spacing: 6) {
                ForEach(presets, id: \.self) { size in
                    SizeChip(size: size, isCurrent: abs(state.fontSize - size) < 0.05) {
                        controller.setFontSize(size)
                        close()
                    }
                }
            }
            Divider()
            PopoverActionRow(title: "Standardgröße", symbol: "arrow.uturn.backward", isDisabled: !state.hasOwnFontSize) {
                controller.setFontSize(nil)
                close()
            }
            Text(state.hasSelection
                 ? "Nur die markierte Stelle. ⌘+ und ⌘− vergrößern jede Stelle für sich – Überschriften bleiben größer als der Text."
                 : "Der Text, der ab dem Cursor getippt wird. Mit ⌘A und ⌘+ wird alles größer, Überschriften bleiben größer als der Text.")
                .font(.system(size: 10.5))
                .foregroundStyle(Theme.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(12)
        .frame(width: 222)
        .onAppear { text = WriterSpanStyle.format(state.fontSize) }
        .onChange(of: state.fontSize) { _, size in
            if !fieldFocused { text = WriterSpanStyle.format(size) }
        }
    }

    /// A typed size; "10,5" counts like "10.5".
    private func applyTyped() {
        let value = Double(text.replacingOccurrences(of: ",", with: ".").trimmingCharacters(in: .whitespaces).replacingOccurrences(of: "pt", with: ""))
        guard let value, WriterSpanStyle.sizeRange.contains(value) else {
            text = WriterSpanStyle.format(controller.state.fontSize)
            return
        }
        controller.setFontSize((value * 10).rounded() / 10)
        close()
    }
}

private struct SizeChip: View {
    let size: Double
    let isCurrent: Bool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Text(WriterSpanStyle.format(size))
                .font(.system(size: 12, weight: isCurrent ? .semibold : .regular).monospacedDigit())
                .foregroundStyle(isCurrent ? Theme.accent : (hovering ? Theme.textPrimary : Theme.textSecondary))
                .frame(width: 44, height: 26)
                .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(isCurrent ? Theme.accent.opacity(0.16) : (hovering ? Theme.hover : Color.white.opacity(0.04))))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .focusable(false)
        .onHover { hovering = $0 }
    }
}

// MARK: Alignment

/// Left, centred, right, justified: the paragraphs of the selection, or the column of the table with the caret.
struct AlignmentButtons: View {
    let controller: WriterEditorController

    var body: some View {
        let state = controller.state
        HStack(spacing: 2) {
            ForEach(WriterAlignment.allCases, id: \.self) { alignment in
                ToolbarButton(symbol: alignment.symbol, help: help(alignment, inTable: state.table != nil), isActive: state.alignment == alignment) {
                    controller.setAlignment(alignment)
                }
                .disabled(state.alignment == nil || (state.table != nil && alignment == .justify))
            }
        }
    }

    private func help(_ alignment: WriterAlignment, inTable: Bool) -> String {
        if inTable { return alignment == .justify ? "Blocksatz gibt es in Tabellen nicht" : "Spalte: \(alignment.label.lowercased())" }
        return "\(alignment.label) – die markierten Absätze, sonst der Absatz mit dem Cursor"
    }
}

// MARK: Paragraph

/// Line spacing and indents of the selected paragraphs (the one with the caret).
struct ParagraphFormatButton: View {
    let controller: WriterEditorController
    let state: WriterTextView.State
    @State private var showsPopover = false

    var body: some View {
        let format = state.paragraphFormat
        let isSet = format.map { $0.lineSpacing != nil || $0.indent != nil || $0.rightIndent != nil || $0.firstLine != nil } ?? false
        ToolbarButton(symbol: "text.line.first.and.arrowtriangle.forward",
                      help: "Absatz: Zeilenabstand, Einrückung und Einzug der ersten Zeile", isActive: isSet || showsPopover) {
            showsPopover.toggle()
        }
        .disabled(format == nil)
        .popover(isPresented: $showsPopover, arrowEdge: .bottom) {
            ParagraphFormatPopover(controller: controller)
        }
    }
}

private struct ParagraphFormatPopover: View {
    let controller: WriterEditorController

    /// How the first line starts.
    private enum FirstLine: String, CaseIterable, Identifiable {
        case none = "Ohne", indent = "Erste Zeile", hanging = "Hängend"
        var id: String { rawValue }
    }

    var body: some View {
        let state = controller.state
        let format = state.paragraphFormat ?? WriterParagraphFormat()
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 6) {
                title("Zeilenabstand")
                HStack(spacing: 4) {
                    ForEach(WriterParagraphFormat.lineSpacingSteps.prefix(4), id: \.value) { step in
                        let isCurrent = abs((format.lineSpacing ?? 1) - step.value) < 0.001
                        Button(step.label) { controller.setLineSpacing(step.value) }
                            .buttonStyle(ChipStyle(isActive: isCurrent))
                    }
                }
                StepperRow(label: "Genau", value: format.lineSpacing ?? 1, step: 0.05, range: WriterParagraphFormat.lineSpacingRange,
                           text: { WriterParagraphFormat.number($0).replacingOccurrences(of: ".", with: ",") + " ×" }) {
                    controller.setLineSpacing($0)
                }
            }
            if state.takesIndent {
                Divider()
                VStack(alignment: .leading, spacing: 6) {
                    title("Einrückung")
                    StepperRow(label: "Links", value: format.indent ?? 0, step: 0.25, range: WriterParagraphFormat.indentRange,
                               text: WriterParagraphFormat.label(cm:)) { controller.setIndents(left: $0) }
                    StepperRow(label: "Rechts", value: format.rightIndent ?? 0, step: 0.25, range: WriterParagraphFormat.indentRange,
                               text: WriterParagraphFormat.label(cm:)) { controller.setIndents(right: $0) }
                }
                Divider()
                VStack(alignment: .leading, spacing: 6) {
                    title("Einzug")
                    let first = format.firstLine ?? 0
                    let kind: FirstLine = first > 0 ? .indent : first < 0 ? .hanging : .none
                    Picker("", selection: Binding(get: { kind }, set: { new in
                        let amount = abs(first) > 0 ? abs(first) : 1.25
                        switch new {
                        case .none: controller.setIndents(firstLine: 0)
                        case .indent: controller.setIndents(firstLine: amount)
                        case .hanging: controller.setIndents(firstLine: -amount)
                        }
                    })) {
                        ForEach(FirstLine.allCases) { Text($0.rawValue).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    if kind != .none {
                        StepperRow(label: "Um", value: abs(first), step: 0.25, range: 0.25...6, text: WriterParagraphFormat.label(cm:)) { amount in
                            controller.setIndents(firstLine: kind == .hanging ? -amount : amount)
                        }
                    }
                }
            }
            HStack {
                Text(state.takesIndent ? "Gilt für die markierten Absätze; im Druck ebenso." : "Listen und Überschriften: nur der Zeilenabstand.")
                    .font(.system(size: 10.5))
                    .foregroundStyle(Theme.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer()
                Button("Zurücksetzen") { controller.clearParagraphFormat() }
                    .controlSize(.small)
            }
        }
        .padding(14)
        .frame(width: 300)
    }

    private func title(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(Theme.textTertiary)
            .textCase(.uppercase)
    }
}

/// A value with its label, its value as text and arrows that step it.
private struct StepperRow: View {
    let label: String
    let value: Double
    let step: Double
    let range: ClosedRange<Double>
    let text: (Double) -> String
    let change: (Double) -> Void

    var body: some View {
        HStack(spacing: 8) {
            Text(label)
                .font(.system(size: 12))
                .foregroundStyle(Theme.textSecondary)
                .frame(width: 50, alignment: .leading)
            Spacer()
            Text(text(value))
                .font(.system(size: 12).monospacedDigit())
                .foregroundStyle(Theme.textPrimary)
            Stepper("", value: Binding(get: { value }, set: { change(min(max($0, range.lowerBound), range.upperBound)) }), in: range, step: step)
                .labelsHidden()
        }
    }
}

/// A small rounded button that shows whether it is the current choice.
private struct ChipStyle: ButtonStyle {
    let isActive: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 11.5, weight: isActive ? .semibold : .regular))
            .foregroundStyle(isActive ? Theme.textPrimary : Theme.textSecondary)
            .padding(.horizontal, 8)
            .frame(height: 24)
            .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(isActive ? Theme.accent.opacity(0.28) : Color.white.opacity(configuration.isPressed ? 0.12 : 0.06)))
    }
}
