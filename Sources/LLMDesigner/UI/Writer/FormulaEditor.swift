import SwiftUI
import AppKit

/// The visual formula editor: a palette of structures and symbols, the formula drawn large with a caret that
/// moves through it, the LaTeX source for those who want it, and, for a display formula, a plot drawn with
/// Python and matplotlib that follows the formula.
@MainActor
@Observable
final class FormulaEditorModel {
    let editing: MathEditingState
    /// Bumped after every change; the canvas draws anew.
    private(set) var version = 0
    var display: Bool
    let isExisting: Bool
    /// The LaTeX field. While the user types in it, it is the source of the formula.
    var source: String
    var isEditingSource = false
    /// Letters typed after "\\" until they become a command.
    var commandBuffer: String?
    var message: String?

    // Plot
    var plotEnabled: Bool
    var plot: PlotSpec
    var plotCaption: String
    var plotWidth: Int?
    /// What the formula means as a plot; nil while it can't be drawn.
    private(set) var program: PlotProgram?
    var parameters: [String] { program?.parameters ?? [] }
    private(set) var plotPreview: NSImage?
    private(set) var plotError: String?
    private(set) var isRendering = false
    private var output: (key: String, value: PlotRenderer.Output)?
    private var plotTask: Task<Void, Never>?
    private var isQuickRendering = false
    private var quickPending = false
    private let initialLatex: String
    private let initialPlot: WriterImageReference?

    static let canvasFontSize: CGFloat = 30
    private var caretBoxes: (version: Int, boxes: [(cursor: MathCursor, rect: CGRect)])?

    init(request: WriterFormulaRequest) {
        editing = MathEditingState(latex: request.latex)
        display = request.display
        isExisting = request.isExisting
        source = request.latex
        initialLatex = request.latex
        initialPlot = request.plot
        plotEnabled = request.plot != nil
        plot = request.plot?.plot ?? PlotSpec()
        plotCaption = request.plot?.caption ?? ""
        plotWidth = request.plot?.width ?? 70
        updatePlotProgram()
        if plotEnabled { schedulePlot(immediately: true) }
    }

    var latex: String { editing.latex }

    /// The formula with the caret, as the canvas draws it.
    var canvasLaTeX: String {
        _ = version
        return MathLaTeXWriter(caret: editing.cursor, placeholders: true).formula(editing.formula)
    }

    func changed(sourceToo: Bool = true) {
        version += 1
        message = nil
        if sourceToo, !isEditingSource { source = editing.latex }
        updatePlotProgram()
        if plotEnabled { schedulePlot() }
    }

    // MARK: Input from the canvas

    func type(_ text: String) {
        for character in text {
            if commandBuffer != nil {
                if character.isLetter, character.isASCII {
                    commandBuffer! += String(character)
                    version += 1
                    continue
                }
                resolveCommand()
                if character == " " { continue }
            }
            if character == "\\" {
                commandBuffer = ""
                version += 1
                continue
            }
            editing.type(character)
        }
        changed()
    }

    func resolveCommand() {
        guard let name = commandBuffer else { return }
        commandBuffer = nil
        guard !name.isEmpty else { return changed() }
        if !editing.insertCommand(name) { message = "„\\\(name)“ kennt der Editor nicht." }
        changed()
    }

    func cancelCommand() {
        commandBuffer = nil
        version += 1
    }

    func perform(_ action: (MathEditingState) -> Void) {
        if commandBuffer != nil { resolveCommand() }
        action(editing)
        changed()
    }

    func deleteBackward() {
        if let buffer = commandBuffer {
            commandBuffer = buffer.isEmpty ? nil : String(buffer.dropLast())
            version += 1
            return
        }
        editing.deleteBackward()
        changed()
    }

    func move(_ action: (MathEditingState) -> Void) {
        if commandBuffer != nil { resolveCommand() }
        action(editing)
        version += 1
    }

    // MARK: Palette

    func apply(_ action: MathPaletteAction) {
        if commandBuffer != nil { resolveCommand() }
        switch action {
        case .template(let latex): editing.insert(latex: latex)
        case .superscript: editing.snapshot(); editing.enterScript(superscript: true)
        case .subscript: editing.snapshot(); editing.enterScript(superscript: false)
        case .fraction: editing.snapshot(); editing.makeFraction()
        case .command(let name): editing.insertCommand(name)
        }
        changed()
    }

    // MARK: Source field

    func sourceEdited(_ text: String) {
        source = text
        editing.replace(with: text)
        version += 1
        updatePlotProgram()
        if plotEnabled { schedulePlot() }
    }

    // MARK: Clicks

    /// The caret position closest to a click, found by drawing the caret at every position once and looking
    /// where it lands. `point` is relative to the centre of the drawn formula.
    func placeCaret(near point: CGPoint) {
        if caretBoxes?.version != version {
            var boxes: [(MathCursor, CGRect)] = []
            for position in editing.formula.positions {
                let latex = MathLaTeXWriter(caret: position, placeholders: true, caretColor: "FF00FF").formula(editing.formula)
                guard let rendered = MathRenderer.render(latex, fontSize: Self.canvasFontSize, display: true, color: .white),
                      let box = Self.markerBox(in: rendered.image) else { continue }
                boxes.append((position, box.offsetBy(dx: -rendered.image.size.width / 2, dy: -rendered.image.size.height / 2)))
            }
            caretBoxes = (version, boxes)
        }
        guard let boxes = caretBoxes?.boxes, !boxes.isEmpty else { return }
        let best = boxes.min { score($0.rect, point) < score($1.rect, point) }
        if let best {
            if commandBuffer != nil { resolveCommand() }
            editing.cursor = best.cursor
            version += 1
            caretBoxes = (version, boxes)
        }
    }

    private func score(_ rect: CGRect, _ point: CGPoint) -> CGFloat {
        let dx = abs(rect.midX - point.x)
        let dy = point.y < rect.minY ? rect.minY - point.y : point.y > rect.maxY ? point.y - rect.maxY : 0
        return dx + dy * 3
    }

    /// Where the magenta caret is in a rendered image, in points from the top left.
    private static func markerBox(in image: NSImage) -> CGRect? {
        let scale: CGFloat = 2
        let width = Int(ceil(image.size.width * scale)), height = Int(ceil(image.size.height * scale))
        guard width > 0, height > 0,
              let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                      space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
              let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))
        guard let data = context.data?.assumingMemoryBound(to: UInt8.self) else { return nil }
        var minX = Int.max, maxX = -1, minY = Int.max, maxY = -1
        for y in 0..<height {
            for x in 0..<width {
                let offset = (y * width + x) * 4
                let red = Int(data[offset]), green = Int(data[offset + 1]), blue = Int(data[offset + 2]), alpha = Int(data[offset + 3])
                guard alpha > 90, red > green + 90, blue > green + 90 else { continue }
                minX = min(minX, x); maxX = max(maxX, x); minY = min(minY, y); maxY = max(maxY, y)
            }
        }
        guard maxX >= 0 else { return nil }
        // The bitmap's rows run from the top down.
        return CGRect(x: CGFloat(minX) / scale, y: CGFloat(minY) / scale, width: CGFloat(maxX - minX + 1) / scale, height: CGFloat(maxY - minY + 1) / scale)
    }

    // MARK: Plot

    private func updatePlotProgram() {
        guard display else { program = nil; return }
        do {
            let program = try PlotTranslator.program(for: editing.latex)
            if program != self.program { self.program = program }
            if plotEnabled { plotError = nil }
        } catch {
            program = nil
            if plotEnabled { plotError = error.localizedDescription }
        }
    }

    var isThreeD: Bool { program?.isThreeD(style: plot.style) ?? false }

    /// Turning the view: while dragging only a small dark preview is drawn, one at a time; the full plot follows
    /// when the drag ends.
    func setView(elevation: Double, azimuth: Double, live: Bool) {
        plot.elevation = max(-90, min(90, elevation.rounded()))
        var turned = azimuth.rounded().truncatingRemainder(dividingBy: 360)
        if turned > 180 { turned -= 360 }
        if turned < -180 { turned += 360 }
        plot.azimuth = turned
        guard plotEnabled else { return }
        if live {
            plotTask?.cancel()
            requestQuickPreview()
        } else {
            schedulePlot(immediately: true)
        }
    }

    private func requestQuickPreview() {
        if isQuickRendering {
            quickPending = true
            return
        }
        isQuickRendering = true
        Task { [weak self] in
            guard let self else { return }
            repeat {
                self.quickPending = false
                if let program = try? PlotTranslator.program(for: self.editing.latex),
                   let result = try? await PlotRenderer.shared.render(program, spec: self.plot, quick: true) {
                    self.plotPreview = NSImage(contentsOf: result.dark)
                    try? FileManager.default.removeItem(at: result.directory)
                }
            } while self.quickPending
            self.isQuickRendering = false
        }
    }

    func plotSettingsChanged() {
        if plotEnabled { schedulePlot() }
    }

    func setPlotEnabled(_ enabled: Bool) {
        plotEnabled = enabled
        plotError = nil
        updatePlotProgram()
        if enabled { schedulePlot(immediately: true) } else { plotTask?.cancel() }
    }

    private var plotKey: String {
        var spec = plot
        spec.parameters = spec.parameters.filter { parameters.contains($0.key) }
        return editing.latex + "|" + spec.markdownAttributes.joined(separator: " ")
    }

    private func schedulePlot(immediately: Bool = false) {
        plotTask?.cancel()
        let key = plotKey
        guard output?.key != key else { return }
        plotTask = Task { [weak self] in
            if !immediately { try? await Task.sleep(for: .milliseconds(550)) }
            guard !Task.isCancelled else { return }
            await self?.renderPlot(key: key)
        }
    }

    private func renderPlot(key: String) async {
        let program: PlotProgram
        do {
            program = try PlotTranslator.program(for: editing.latex)
        } catch {
            plotError = error.localizedDescription
            return
        }
        isRendering = true
        defer { isRendering = false }
        do {
            let result = try await PlotRenderer.shared.render(program, spec: plot)
            guard !Task.isCancelled, key == plotKey else { return }
            output = (key, result)
            plotPreview = NSImage(contentsOf: result.dark)
            plotError = nil
        } catch {
            guard !Task.isCancelled else { return }
            plotError = error.localizedDescription
        }
    }

    /// The plot for the document: the old one when nothing changed, else freshly drawn and stored.
    func finalPlot() async throws -> WriterImageReference? {
        guard display, plotEnabled else { return nil }
        var spec = plot
        spec.parameters = spec.parameters.filter { parameters.contains($0.key) }
        for name in parameters where spec.parameters[name] == nil { spec.parameters[name] = 1 }
        if let initialPlot, initialPlot.plot == spec, editing.latex == initialLatex {
            return WriterImageReference(source: initialPlot.source, caption: plotCaption, width: plotWidth, plot: spec)
        }
        let key = plotKey
        if output?.key != key {
            plotTask?.cancel()
            await renderPlot(key: key)
        }
        guard let output, output.key == key else { throw PlotError.failed(plotError ?? "") }
        let source = try WriterImageStore.storePlot(output.value)
        return WriterImageReference(source: source, caption: plotCaption.trimmingCharacters(in: .whitespacesAndNewlines), width: plotWidth, plot: spec)
    }
}

// MARK: - Palette

enum MathPaletteAction {
    case template(String)
    case superscript, `subscript`, fraction
    case command(String)
}

struct MathPaletteItem: Identifiable {
    let id = UUID()
    /// LaTeX of the button's picture.
    let label: String
    let help: String
    let action: MathPaletteAction
}

struct MathPaletteCategory: Identifiable {
    let id: String
    let items: [MathPaletteItem]

    static let all: [MathPaletteCategory] = [
        MathPaletteCategory(id: "Grundlagen", items: [
            .init(label: "\\frac{a}{b}", help: "Bruch (/) – macht aus dem Davorstehenden den Zähler", action: .fraction),
            .init(label: "x^{n}", help: "Hochzahl (^)", action: .superscript),
            .init(label: "x_{i}", help: "Index (_)", action: .subscript),
            .init(label: "\\sqrt{x}", help: "Wurzel (sqrt)", action: .template("\\sqrt{}")),
            .init(label: "\\sqrt[n]{x}", help: "n-te Wurzel", action: .template("\\sqrt[]{}")),
            .init(label: "\\left(x\\right)", help: "Runde Klammern ( )", action: .template("\\left( \\right)")),
            .init(label: "\\left[x\\right]", help: "Eckige Klammern [ ]", action: .template("\\left[ \\right]")),
            .init(label: "\\left\\{x\\right\\}", help: "Geschweifte Klammern { }", action: .template("\\left\\{ \\right\\}")),
            .init(label: "\\left|x\\right|", help: "Betrag | |", action: .template("\\left| \\right|")),
            .init(label: "\\left\\|x\\right\\|", help: "Norm", action: .template("\\left\\| \\right\\|")),
            .init(label: "\\binom{n}{k}", help: "Binomialkoeffizient", action: .template("\\binom{}{}")),
            .init(label: "\\pm", help: "Plus-minus", action: .template("\\pm")),
            .init(label: "\\cdot", help: "Mal (*)", action: .template("\\cdot")),
            .init(label: "\\times", help: "Kreuz", action: .template("\\times")),
            .init(label: "\\div", help: "Geteilt", action: .template("\\div")),
            .init(label: "\\infty", help: "Unendlich", action: .template("\\infty")),
            .init(label: "x^{\\circ}", help: "Grad", action: .template("^{\\circ}")),
            .init(label: "\\%", help: "Prozent", action: .template("\\%")),
            .init(label: "\\text{Text}", help: "Text in der Formel", action: .command("text")),
        ]),
        MathPaletteCategory(id: "Analysis", items: [
            .init(label: "\\sum_{i=1}^{n}", help: "Summe (sum)", action: .template("\\sum_{}^{}")),
            .init(label: "\\prod_{i=1}^{n}", help: "Produkt (prod)", action: .template("\\prod_{}^{}")),
            .init(label: "\\int f", help: "Integral (int)", action: .template("\\int")),
            .init(label: "\\int_{a}^{b}", help: "Bestimmtes Integral", action: .template("\\int_{}^{}")),
            .init(label: "\\iint", help: "Doppelintegral", action: .template("\\iint")),
            .init(label: "\\oint", help: "Kurvenintegral", action: .template("\\oint")),
            .init(label: "\\lim_{x\\to a}", help: "Grenzwert (lim)", action: .template("\\lim_{}")),
            .init(label: "\\frac{d}{dx}", help: "Ableitung", action: .template("\\frac{d}{dx}")),
            .init(label: "\\frac{\\partial}{\\partial x}", help: "Partielle Ableitung", action: .template("\\frac{\\partial}{\\partial x}")),
            .init(label: "f'", help: "Strich (Ableitung)", action: .template("'")),
            .init(label: "\\partial", help: "Partiell", action: .template("\\partial")),
            .init(label: "\\nabla", help: "Nabla", action: .template("\\nabla")),
            .init(label: "\\Delta", help: "Delta", action: .template("\\Delta")),
            .init(label: "e^{x}", help: "e hoch", action: .template("e^{}")),
            .init(label: "\\to", help: "Gegen / Pfeil", action: .template("\\to")),
            .init(label: "\\mapsto", help: "Wird abgebildet auf", action: .template("\\mapsto")),
        ]),
        MathPaletteCategory(id: "Funktionen", items: ["sin", "cos", "tan", "cot", "arcsin", "arccos", "arctan", "sinh", "cosh", "tanh", "ln", "log", "exp", "max", "min", "det"].map {
            MathPaletteItem(label: "\\\($0)", help: "\\\($0)", action: .command($0))
        } + [MathPaletteItem(label: "\\log_{b}", help: "Logarithmus zur Basis b", action: .template("\\log_{}"))]),
        MathPaletteCategory(id: "Griechisch", items: [
            "alpha", "beta", "gamma", "delta", "epsilon", "varepsilon", "zeta", "eta", "theta", "vartheta", "kappa", "lambda", "mu", "nu",
            "xi", "pi", "rho", "sigma", "tau", "phi", "varphi", "chi", "psi", "omega",
            "Gamma", "Delta", "Theta", "Lambda", "Xi", "Pi", "Sigma", "Phi", "Psi", "Omega",
        ].map { MathPaletteItem(label: "\\\($0)", help: "\\\($0)", action: .template("\\\($0)")) }),
        MathPaletteCategory(id: "Relationen", items: [
            ("=", "="), ("\\neq", "Ungleich"), ("\\approx", "Ungefähr"), ("\\equiv", "Identisch"), ("<", "Kleiner"), (">", "Größer"),
            ("\\leq", "Kleiner gleich"), ("\\geq", "Größer gleich"), ("\\ll", "Viel kleiner"), ("\\gg", "Viel größer"), ("\\propto", "Proportional"),
            ("\\sim", "Ähnlich"), ("\\Rightarrow", "Folgt"), ("\\Leftarrow", "Folgt aus"), ("\\Leftrightarrow", "Äquivalent"), ("\\rightarrow", "Pfeil"),
            ("\\leftarrow", "Pfeil links"), ("\\leftrightarrow", "Doppelpfeil"), ("\\in", "Element von"), ("\\notin", "Kein Element von"),
            ("\\subset", "Teilmenge"), ("\\subseteq", "Teilmenge oder gleich"), ("\\supset", "Obermenge"), ("\\cup", "Vereinigung"),
            ("\\cap", "Schnitt"), ("\\setminus", "Ohne"), ("\\emptyset", "Leere Menge"), ("\\forall", "Für alle"), ("\\exists", "Es gibt"),
            ("\\neg", "Nicht"), ("\\wedge", "Und"), ("\\vee", "Oder"), ("\\perp", "Senkrecht"), ("\\parallel", "Parallel"), ("\\angle", "Winkel"),
        ].map { MathPaletteItem(label: $0.0, help: $0.1, action: .template($0.0)) }),
        MathPaletteCategory(id: "Mengen & Matrizen", items: [
            .init(label: "\\mathbb{N}", help: "Natürliche Zahlen", action: .template("\\mathbb{N}")),
            .init(label: "\\mathbb{Z}", help: "Ganze Zahlen", action: .template("\\mathbb{Z}")),
            .init(label: "\\mathbb{Q}", help: "Rationale Zahlen", action: .template("\\mathbb{Q}")),
            .init(label: "\\mathbb{R}", help: "Reelle Zahlen", action: .template("\\mathbb{R}")),
            .init(label: "\\mathbb{C}", help: "Komplexe Zahlen", action: .template("\\mathbb{C}")),
            .init(label: "\\begin{pmatrix}a&b\\\\c&d\\end{pmatrix}", help: "Matrix 2 × 2", action: .template("\\begin{pmatrix} {} & {} \\\\ {} & {} \\end{pmatrix}")),
            .init(label: "\\begin{pmatrix}a&b&c\\\\d&e&f\\\\g&h&i\\end{pmatrix}", help: "Matrix 3 × 3", action: .template("\\begin{pmatrix} {} & {} & {} \\\\ {} & {} & {} \\\\ {} & {} & {} \\end{pmatrix}")),
            .init(label: "\\begin{pmatrix}x\\\\y\\end{pmatrix}", help: "Vektor (2)", action: .template("\\begin{pmatrix} {} \\\\ {} \\end{pmatrix}")),
            .init(label: "\\begin{pmatrix}x\\\\y\\\\z\\end{pmatrix}", help: "Vektor (3)", action: .template("\\begin{pmatrix} {} \\\\ {} \\\\ {} \\end{pmatrix}")),
            .init(label: "\\begin{bmatrix}a&b\\\\c&d\\end{bmatrix}", help: "Matrix mit eckigen Klammern", action: .template("\\begin{bmatrix} {} & {} \\\\ {} & {} \\end{bmatrix}")),
            .init(label: "\\begin{vmatrix}a&b\\\\c&d\\end{vmatrix}", help: "Determinante", action: .template("\\begin{vmatrix} {} & {} \\\\ {} & {} \\end{vmatrix}")),
            .init(label: "\\begin{cases}a&x>0\\\\b&x\\leq0\\end{cases}", help: "Fallunterscheidung", action: .template("\\begin{cases} {} & {} \\\\ {} & {} \\end{cases}")),
            .init(label: "\\vec{a}", help: "Vektorpfeil", action: .template("\\vec{}")),
            .init(label: "\\hat{a}", help: "Dach", action: .template("\\hat{}")),
            .init(label: "\\bar{a}", help: "Strich", action: .template("\\bar{}")),
            .init(label: "\\dot{a}", help: "Punkt", action: .template("\\dot{}")),
            .init(label: "\\ddot{a}", help: "Zwei Punkte", action: .template("\\ddot{}")),
            .init(label: "\\tilde{a}", help: "Tilde", action: .template("\\tilde{}")),
            .init(label: "\\overline{AB}", help: "Überstrich", action: .template("\\overline{}")),
        ]),
    ]
}

// MARK: - Sheet

struct FormulaEditorSheet: View {
    @State private var model: FormulaEditorModel
    @State private var category = MathPaletteCategory.all[0].id
    @State private var showsSource = false
    @State private var isCommitting = false
    @FocusState private var sourceFocused: Bool
    let onCommit: (_ latex: String, _ display: Bool, _ plot: WriterImageReference?) -> Void
    let onCancel: () -> Void

    init(request: WriterFormulaRequest, onCommit: @escaping (String, Bool, WriterImageReference?) -> Void, onCancel: @escaping () -> Void) {
        _model = State(initialValue: FormulaEditorModel(request: request))
        self.onCommit = onCommit
        self.onCancel = onCancel
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            palette
            MathCanvas(model: model, latex: model.canvasLaTeX, command: model.commandBuffer, onCommit: commit, onCancel: onCancel)
                .frame(minHeight: 150)
                .frame(maxHeight: 260)
            hints
            sourceSection
            if model.display { plotSection }
            footer
        }
        .padding(20)
        .frame(width: 720)
        .background(Theme.surface)
        .environment(\.colorScheme, .dark)
    }

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: "x.squareroot")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(Theme.accent)
            Text(model.isExisting ? "Formel bearbeiten" : "Neue Formel")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(Theme.textPrimary)
            Spacer()
            Picker("", selection: Binding(get: { model.display }, set: { model.display = $0; model.changed(sourceToo: false) })) {
                Text("Eigene Zeile").tag(true)
                Text("Im Text").tag(false)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 210)
            .help("Abgesetzte Formel (zentriert, mit Plot möglich) oder Formel im Fließtext")
        }
    }

    private var palette: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 2) {
                ForEach(MathPaletteCategory.all) { item in
                    PaletteTab(title: item.id, isSelected: category == item.id) { category = item.id }
                }
            }
            let items = MathPaletteCategory.all.first { $0.id == category }?.items ?? []
            LazyVGrid(columns: Array(repeating: GridItem(.fixed(52), spacing: 4), count: 12), alignment: .leading, spacing: 4) {
                ForEach(items) { item in
                    PaletteButton(item: item) { model.apply(item.action) }
                }
            }
            .frame(minHeight: 96, alignment: .top)
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.white.opacity(0.035)))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Theme.border))
    }

    private var hints: some View {
        HStack(spacing: 6) {
            if let message = model.message {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Theme.warning)
                Text(message).foregroundStyle(Theme.textSecondary)
            } else if let command = model.commandBuffer {
                Image(systemName: "chevron.left.forwardslash.chevron.right").foregroundStyle(Theme.accent)
                Text("Befehl: \\\(command)  – Leertaste oder ↩ übernimmt, ⌫ löscht")
                    .foregroundStyle(Theme.textSecondary)
            } else {
                Text("/ Bruch · ^ Hochzahl · _ Index · ( Klammer · \\ Befehl · sqrt, pi, sin … · ⇥ nächstes Feld · ⇧↩ neue Zeile · ↩ fertig")
                    .foregroundStyle(Theme.textTertiary)
            }
        }
        .font(.system(size: 11.5))
        .lineLimit(1)
    }

    private var sourceSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button {
                withAnimation(.easeInOut(duration: 0.2)) { showsSource.toggle() }
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: showsSource ? "chevron.down" : "chevron.right")
                        .font(.system(size: 9, weight: .bold))
                    Text("LaTeX")
                        .font(.system(size: 12, weight: .semibold))
                    if !showsSource {
                        Text(model.source.isEmpty ? "—" : model.source)
                            .font(.system(size: 11.5, design: .monospaced))
                            .foregroundStyle(Theme.textTertiary)
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }
                }
                .foregroundStyle(Theme.textSecondary)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .focusable(false)
            if showsSource {
                TextField("z. B. f(x) = \\frac{1}{2}x^2", text: Binding(get: { model.source }, set: { model.sourceEdited($0) }), axis: .vertical)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12.5, design: .monospaced))
                    .lineLimit(1...4)
                    .padding(8)
                    .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.black.opacity(0.25)))
                    .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(sourceFocused ? Theme.accent.opacity(0.6) : Theme.border))
                    .focused($sourceFocused)
                    .onChange(of: sourceFocused) { _, focused in model.isEditingSource = focused }
                    .onSubmit(commit)
            }
        }
    }

    private var plotSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Toggle(isOn: Binding(get: { model.plotEnabled }, set: { model.setPlotEnabled($0) })) {
                HStack(spacing: 6) {
                    Image(systemName: "chart.xyaxis.line").foregroundStyle(Theme.accent)
                    Text("Plot unter der Formel").font(.system(size: 12.5, weight: .semibold))
                    Text("– gezeichnet mit Python/matplotlib, folgt jeder Änderung")
                        .font(.system(size: 11.5))
                        .foregroundStyle(Theme.textTertiary)
                }
            }
            .toggleStyle(.switch)
            .controlSize(.small)
            if model.plotEnabled {
                HStack(alignment: .top, spacing: 16) {
                    plotSettings
                        .frame(width: 300, alignment: .leading)
                    plotPreview
                        .frame(maxWidth: .infinity)
                }
            }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.white.opacity(0.035)))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Theme.border))
    }

    private var plotSettings: some View {
        let program = model.program
        let x = program?.curveVariable ?? program?.planeVariables?.first ?? "x"
        let y = program?.planeVariables?.dropFirst().first ?? "y"
        let z = program?.spaceVariables?.last ?? "z"
        return ScrollView {
            VStack(alignment: .leading, spacing: 8) {
                if program == nil || program?.curveVariable != nil || program?.planeVariables != nil {
                    rangeRow(PlotProgram.displayName(x), value: Binding(get: { model.plot.x }, set: { model.plot.x = $0; model.plotSettingsChanged() }))
                }
                if let program, program.hasCurves || program.planeVariables != nil {
                    let isValueAxis = program.hasCurves
                    optionalRangeRow(
                        isValueAxis ? "y automatisch" : "\(PlotProgram.displayName(y)) wie \(PlotProgram.displayName(x))",
                        name: isValueAxis ? "y" : PlotProgram.displayName(y),
                        value: Binding(get: { model.plot.y }, set: { model.plot.y = $0; model.plotSettingsChanged() }),
                        fallback: isValueAxis ? PlotRange(-5, 5) : model.plot.x
                    )
                }
                if let program, program.hasSurfaces || program.spaceVariables != nil {
                    let isValueAxis = program.spaceVariables == nil
                    optionalRangeRow(
                        isValueAxis ? "z automatisch" : "\(PlotProgram.displayName(z)) wie \(PlotProgram.displayName(x))",
                        name: isValueAxis ? "z" : PlotProgram.displayName(z),
                        value: Binding(get: { model.plot.z }, set: { model.plot.z = $0; model.plotSettingsChanged() }),
                        fallback: isValueAxis ? PlotRange(-5, 5) : model.plot.x
                    )
                }
                if let parameter = program?.parameterVariable {
                    rangeRow(PlotProgram.displayName(parameter), value: Binding(
                        get: { model.plot.t ?? .fullTurn }, set: { model.plot.t = $0; model.plotSettingsChanged() }
                    ))
                }
                if let parameters = program?.surfaceParameters, parameters.count == 2 {
                    rangeRow(PlotProgram.displayName(parameters[0]), value: Binding(
                        get: { model.plot.u ?? .fullTurn }, set: { model.plot.u = $0; model.plotSettingsChanged() }
                    ))
                    rangeRow(PlotProgram.displayName(parameters[1]), value: Binding(
                        get: { model.plot.v ?? .fullTurn }, set: { model.plot.v = $0; model.plotSettingsChanged() }
                    ))
                }
                if let program, program.hasSurfaces || program.hasVectorField {
                    let styles = program.hasSurfaces ? PlotStyle.surfaceStyles : PlotStyle.vectorStyles
                    Picker("", selection: Binding(
                        get: { model.plot.style.flatMap { styles.contains($0) ? $0 : nil } ?? styles[0] },
                        set: { model.plot.style = $0 == styles[0] ? nil : $0; model.plotSettingsChanged() }
                    )) {
                        ForEach(styles, id: \.self) { Text($0.label).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .controlSize(.small)
                }
                if model.isThreeD {
                    viewRow("Neigung", value: model.plot.elevation, range: -90...90) { model.setView(elevation: $0, azimuth: model.plot.azimuth, live: false) }
                    viewRow("Drehung", value: model.plot.azimuth, range: -180...180) { model.setView(elevation: model.plot.elevation, azimuth: $0, live: false) }
                }
                HStack(spacing: 12) {
                    Toggle("Gitter", isOn: Binding(get: { model.plot.grid }, set: { model.plot.grid = $0; model.plotSettingsChanged() }))
                    if program?.hasCurves == true {
                        Toggle("Nullstellen & Extrema", isOn: Binding(get: { model.plot.marks }, set: { model.plot.marks = $0; model.plotSettingsChanged() }))
                            .help("Markiert Nullstellen, Hoch- und Tiefpunkte mit ihren Koordinaten")
                    }
                }
                .toggleStyle(.checkbox)
                .font(.system(size: 12))
                if !model.parameters.isEmpty {
                    Text("Parameter")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Theme.textTertiary)
                        .padding(.top, 2)
                    ForEach(model.parameters, id: \.self) { name in
                        ParameterRow(name: name, value: Binding(
                            get: { model.plot.parameters[name] ?? 1 },
                            set: { model.plot.parameters[name] = $0; model.plotSettingsChanged() }
                        ))
                    }
                }
                HStack(spacing: 8) {
                    Text("Breite").font(.system(size: 12)).foregroundStyle(Theme.textSecondary)
                    Picker("", selection: Binding(get: { model.plotWidth ?? 70 }, set: { model.plotWidth = $0 })) {
                        ForEach([50, 70, 85, 100], id: \.self) { Text("\($0) %").tag($0) }
                    }
                    .labelsHidden()
                    .frame(width: 90)
                }
                TextField("Bildunterschrift (optional)", text: Binding(get: { model.plotCaption }, set: { model.plotCaption = $0 }))
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 12))
            }
            .padding(.trailing, 8)
        }
        .scrollIndicators(.automatic)
        .frame(height: 262)
    }

    private func rangeRow(_ name: String, value: Binding<PlotRange>) -> some View {
        HStack(spacing: 6) {
            Text("\(name) von").font(.system(size: 12)).foregroundStyle(Theme.textSecondary).frame(width: 46, alignment: .leading)
            NumberField(value: Binding(get: { value.wrappedValue.low }, set: { low in
                if low < value.wrappedValue.high { value.wrappedValue = PlotRange(low, value.wrappedValue.high) }
            }))
            Text("bis").font(.system(size: 12)).foregroundStyle(Theme.textSecondary)
            NumberField(value: Binding(get: { value.wrappedValue.high }, set: { high in
                if high > value.wrappedValue.low { value.wrappedValue = PlotRange(value.wrappedValue.low, high) }
            }))
        }
    }

    /// A range that is chosen automatically (or follows x) until it is switched off.
    @ViewBuilder
    private func optionalRangeRow(_ title: String, name: String, value: Binding<PlotRange?>, fallback: PlotRange) -> some View {
        Toggle(title, isOn: Binding(get: { value.wrappedValue == nil }, set: { automatic in
            value.wrappedValue = automatic ? nil : fallback
        }))
        .toggleStyle(.checkbox)
        .font(.system(size: 12))
        if value.wrappedValue != nil {
            rangeRow(name, value: Binding(get: { value.wrappedValue ?? fallback }, set: { value.wrappedValue = $0 }))
        }
    }

    private func viewRow(_ title: String, value: Double, range: ClosedRange<Double>, set: @escaping (Double) -> Void) -> some View {
        HStack(spacing: 8) {
            Text(title).font(.system(size: 12)).foregroundStyle(Theme.textSecondary).frame(width: 52, alignment: .leading)
            Slider(value: Binding(get: { value }, set: { set($0) }), in: range)
                .controlSize(.small)
            Text("\(Int(value))°")
                .font(.system(size: 11.5).monospacedDigit())
                .foregroundStyle(Theme.textTertiary)
                .frame(width: 38, alignment: .trailing)
        }
    }

    @State private var dragStart: (elevation: Double, azimuth: Double)?

    private var plotPreview: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color(hex: 0x141417))
            if let image = model.plotPreview {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .padding(4)
                    .opacity(model.isRendering ? 0.45 : 1)
            }
            if model.isRendering {
                ProgressView().controlSize(.small)
            } else if let error = model.plotError {
                VStack(spacing: 6) {
                    Image(systemName: "exclamationmark.triangle").foregroundStyle(Theme.warning)
                    Text(error)
                        .font(.system(size: 11.5))
                        .foregroundStyle(Theme.textSecondary)
                        .multilineTextAlignment(.center)
                }
                .padding(12)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color(hex: 0x141417).opacity(model.plotPreview == nil ? 0 : 0.85))
            } else if model.plotPreview == nil {
                Text("Vorschau erscheint gleich …")
                    .font(.system(size: 11.5))
                    .foregroundStyle(Theme.textTertiary)
            }
            if model.isThreeD, model.plotError == nil {
                Label("Ziehen dreht die Ansicht", systemImage: "rotate.3d")
                    .font(.system(size: 10.5))
                    .foregroundStyle(Theme.textTertiary)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .background(Capsule().fill(Color.black.opacity(0.45)))
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
                    .padding(8)
                    .allowsHitTesting(false)
            }
        }
        .frame(height: 262)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Theme.border))
        .contentShape(Rectangle())
        .gesture(
            DragGesture(minimumDistance: 3)
                .onChanged { drag in
                    guard model.isThreeD else { return }
                    let start = dragStart ?? (model.plot.elevation, model.plot.azimuth)
                    if dragStart == nil { dragStart = start }
                    model.setView(elevation: start.elevation + drag.translation.height * 0.4,
                                  azimuth: start.azimuth - drag.translation.width * 0.5, live: true)
                }
                .onEnded { _ in
                    guard model.isThreeD, dragStart != nil else { return }
                    dragStart = nil
                    model.setView(elevation: model.plot.elevation, azimuth: model.plot.azimuth, live: false)
                }
        )
        .onHover { inside in
            guard model.isThreeD else { return }
            if inside { NSCursor.openHand.push() } else { NSCursor.pop() }
        }
    }

    private var footer: some View {
        HStack {
            if model.isExisting {
                Button("Formel entfernen", role: .destructive) { model.editing.clear(); commit() }
                    .buttonStyle(.plain)
                    .font(.system(size: 12.5))
                    .foregroundStyle(Theme.danger)
            }
            Spacer()
            Button("Abbrechen", action: onCancel)
                .controlSize(.large)
            Button {
                commit()
            } label: {
                HStack(spacing: 6) {
                    if isCommitting { ProgressView().controlSize(.small) }
                    Text(model.isExisting ? "Übernehmen" : "Einfügen")
                }
                .frame(minWidth: 90)
            }
            .controlSize(.large)
            .buttonStyle(.borderedProminent)
            .disabled(isCommitting || (model.editing.formula.isEmpty && !model.isExisting))
        }
    }

    private func commit() {
        guard !isCommitting else { return }
        if model.commandBuffer != nil { model.resolveCommand() }
        isCommitting = true
        Task {
            do {
                let plot = model.latex.isEmpty ? nil : try await model.finalPlot()
                onCommit(model.latex, model.display, plot)
            } catch {
                model.message = "Der Plot fehlt noch: " + (error.localizedDescription)
            }
            isCommitting = false
        }
    }
}

private struct PaletteTab: View {
    let title: String
    let isSelected: Bool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(isSelected ? Theme.textPrimary : (hovering ? Theme.textSecondary : Theme.textTertiary))
                .padding(.horizontal, 9)
                .frame(height: 24)
                .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(isSelected ? Theme.selection : (hovering ? Theme.hover : .clear)))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .focusable(false)
        .onHover { hovering = $0 }
    }
}

private struct PaletteButton: View {
    let item: MathPaletteItem
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Group {
                if let rendered = MathRenderer.render(item.label, fontSize: 18, display: true, color: NSColor(Theme.textPrimary)) {
                    let image = rendered.image
                    let scale = min(1, 44 / max(image.size.width, 1), 32 / max(image.size.height, 1))
                    Image(nsImage: image)
                        .resizable()
                        .frame(width: image.size.width * scale, height: image.size.height * scale)
                } else {
                    Text(item.label).font(.system(size: 11, design: .monospaced))
                }
            }
            .frame(width: 52, height: 40)
            .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(hovering ? Theme.hover : Color.white.opacity(0.03)))
            .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous).strokeBorder(hovering ? Theme.strongBorder : .clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .focusable(false)
        .onHover { hovering = $0 }
        .help(item.help)
    }
}

/// A number; takes "1,5", "-2", "2π" or "pi/2" and shows multiples of π as such.
private struct NumberField: View {
    @Binding var value: Double
    @State private var text = ""

    var body: some View {
        TextField("", text: $text)
            .textFieldStyle(.roundedBorder)
            .font(.system(size: 12).monospacedDigit())
            .frame(width: 66)
            .onAppear { text = PlotSpec.display(value) }
            .onChange(of: value) { _, newValue in
                if PlotSpec.parseNumber(text) != newValue { text = PlotSpec.display(newValue) }
            }
            .onSubmit {
                apply()
                text = PlotSpec.display(value)
            }
            .onChange(of: text) { _, _ in apply() }
    }

    private func apply() {
        guard let number = PlotSpec.parseNumber(text), number != value else { return }
        value = number
    }
}

private struct ParameterRow: View {
    let name: String
    @Binding var value: Double

    var body: some View {
        HStack(spacing: 8) {
            Group {
                if let rendered = MathRenderer.render((MathSymbols.greek.contains("\\" + name) ? "\\" : "") + name.replacingOccurrences(of: "_", with: "_{") + (name.contains("_") ? "}" : "") + " =",
                                                      fontSize: 13, display: false, color: NSColor(Theme.textPrimary)) {
                    Image(nsImage: rendered.image)
                } else {
                    Text("\(name) =").font(.system(size: 12))
                }
            }
            .frame(width: 40, alignment: .leading)
            Slider(value: $value, in: -10...10)
                .controlSize(.small)
            NumberField(value: $value)
        }
    }
}

// MARK: - Canvas

/// The formula drawn large with its caret. Keys build and walk the formula; a click puts the caret there.
private struct MathCanvas: NSViewRepresentable {
    let model: FormulaEditorModel
    /// Passed in so the canvas is updated whenever the formula or the command changes.
    let latex: String
    let command: String?
    let onCommit: () -> Void
    let onCancel: () -> Void

    func makeNSView(context: Context) -> MathCanvasView {
        let view = MathCanvasView()
        view.model = model
        view.onCommit = onCommit
        view.onCancel = onCancel
        DispatchQueue.main.async { view.window?.makeFirstResponder(view) }
        return view
    }

    func updateNSView(_ view: MathCanvasView, context: Context) {
        view.model = model
        view.onCommit = onCommit
        view.onCancel = onCancel
        view.render(latex)
        view.needsDisplay = true
    }
}

final class MathCanvasView: NSView, NSTextInputClient {
    var model: FormulaEditorModel?
    var onCommit: (() -> Void)?
    var onCancel: (() -> Void)?
    private var image: NSImage?
    private var failedSource: String?
    private var renderedLaTeX = ""
    private var markedText = ""

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }

    override func becomeFirstResponder() -> Bool {
        needsDisplay = true
        return true
    }

    override func resignFirstResponder() -> Bool {
        needsDisplay = true
        return true
    }

    func render(_ latex: String) {
        guard latex != renderedLaTeX else { return }
        renderedLaTeX = latex
        if let rendered = MathRenderer.render(latex, fontSize: FormulaEditorModel.canvasFontSize, display: true, color: NSColor(hex: 0xEDEDEF)) {
            image = rendered.image
            failedSource = nil
        } else {
            image = nil
            failedSource = model?.latex
        }
        needsDisplay = true
    }

    private var imageRect: NSRect? {
        guard let image else { return nil }
        var size = image.size
        let available = bounds.insetBy(dx: 16, dy: 12).size
        if size.width > available.width || size.height > available.height {
            let scale = min(available.width / size.width, available.height / size.height)
            size = NSSize(width: size.width * scale, height: size.height * scale)
        }
        return NSRect(x: bounds.midX - size.width / 2, y: bounds.midY - size.height / 2, width: size.width, height: size.height)
    }

    override func draw(_ dirtyRect: NSRect) {
        let box = NSBezierPath(roundedRect: bounds.insetBy(dx: 1, dy: 1), xRadius: 12, yRadius: 12)
        NSColor(hex: 0x111114).setFill()
        box.fill()
        let focused = window?.firstResponder === self
        (focused ? NSColor(hex: 0xA996FF).withAlphaComponent(0.7) : NSColor.white.withAlphaComponent(0.1)).setStroke()
        box.lineWidth = focused ? 1.5 : 1
        box.stroke()

        if let image, let rect = imageRect {
            image.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: [.interpolation: NSImageInterpolation.high.rawValue])
        } else {
            let text = failedSource.map { "Die Formel lässt sich so nicht darstellen:\n" + $0 } ?? ""
            let attributes: [NSAttributedString.Key: Any] = [.font: NSFont.monospacedSystemFont(ofSize: 12, weight: .regular), .foregroundColor: NSColor(hex: 0xF2B14C)]
            (text as NSString).draw(in: bounds.insetBy(dx: 18, dy: 16), withAttributes: attributes)
        }
        if let model, model.editing.formula.isEmpty, model.commandBuffer == nil {
            let hint = "Formel eingeben – z. B. f(x) = x^2/2 oder über die Palette"
            let attributes: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 13), .foregroundColor: NSColor(hex: 0x6E6E77)]
            let size = (hint as NSString).size(withAttributes: attributes)
            (hint as NSString).draw(at: NSPoint(x: bounds.midX - size.width / 2, y: bounds.maxY - size.height - 14), withAttributes: attributes)
        }
        if let command = model?.commandBuffer {
            let text = "\\" + command + markedText
            let attributes: [NSAttributedString.Key: Any] = [.font: NSFont.monospacedSystemFont(ofSize: 13, weight: .medium), .foregroundColor: NSColor(hex: 0xA996FF)]
            let size = (text as NSString).size(withAttributes: attributes)
            let pill = NSRect(x: 12, y: bounds.maxY - size.height - 18, width: size.width + 16, height: size.height + 8)
            NSColor(hex: 0xA996FF).withAlphaComponent(0.14).setFill()
            NSBezierPath(roundedRect: pill, xRadius: 6, yRadius: 6).fill()
            (text as NSString).draw(at: NSPoint(x: pill.minX + 8, y: pill.minY + 4), withAttributes: attributes)
        }
    }

    // MARK: Mouse

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        guard let model, let image, let rect = imageRect else { return }
        let point = convert(event.locationInWindow, from: nil)
        let scale = image.size.width / max(rect.width, 1)
        let relative = CGPoint(x: (point.x - rect.midX) * scale, y: (point.y - rect.midY) * scale)
        model.placeCaret(near: relative)
    }

    // MARK: Keys

    override func keyDown(with event: NSEvent) {
        guard let model else { return }
        let flags = event.modifierFlags.intersection([.command, .control, .option, .shift])
        switch event.keyCode {
        case 36, 76: // Return
            if model.commandBuffer != nil { model.resolveCommand() }
            else if flags.contains(.shift) { model.perform { $0.newLine() } }
            else { onCommit?() }
        case 53: // Escape
            if model.commandBuffer != nil { model.cancelCommand() } else { onCancel?() }
        case 51: model.deleteBackward()
        case 117: model.perform { $0.deleteForward() }
        case 123: model.move { $0.moveLeft() }
        case 124: model.move { $0.moveRight() }
        case 126: model.move { $0.moveVertically(up: true) }
        case 125: model.move { $0.moveVertically(up: false) }
        case 115: model.move { $0.moveToStart() }
        case 119: model.move { $0.moveToEnd() }
        case 48: // Tab
            if model.commandBuffer != nil { model.resolveCommand() } else { model.move { $0.moveToNextField(backwards: flags.contains(.shift)) } }
        default:
            if flags.contains(.command) || flags.contains(.control) { return super.keyDown(with: event) }
            // Through the input system, so dead keys like ^ on a German keyboard work.
            if inputContext?.handleEvent(event) != true { interpretKeyEvents([event]) }
        }
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard window?.firstResponder === self, let model else { return super.performKeyEquivalent(with: event) }
        let flags = event.modifierFlags.intersection([.command, .shift, .option, .control])
        let key = event.charactersIgnoringModifiers?.lowercased() ?? ""
        if flags == [.command] {
            switch key {
            case "z": model.perform { $0.undo() }; return true
            case "c": copyFormula(); return true
            case "v": pasteFormula(); return true
            case "x": copyFormula(); model.perform { $0.clear() }; return true
            default: break
            }
        }
        if flags == [.command, .shift], key == "z" { model.perform { $0.redo() }; return true }
        return super.performKeyEquivalent(with: event)
    }

    private func copyFormula() {
        guard let model else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(model.latex, forType: .string)
    }

    private func pasteFormula() {
        guard let model, let text = NSPasteboard.general.string(forType: .string)?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { return }
        var latex = text
        for (open, close) in [("$$", "$$"), ("$", "$"), ("\\[", "\\]"), ("\\(", "\\)")] where latex.hasPrefix(open) && latex.hasSuffix(close) && latex.count > open.count + close.count {
            latex = String(latex.dropFirst(open.count).dropLast(close.count))
            break
        }
        model.perform { $0.insert(latex: latex) }
    }

    // MARK: NSTextInputClient

    func insertText(_ string: Any, replacementRange: NSRange) {
        let text = (string as? String) ?? (string as? NSAttributedString)?.string ?? ""
        markedText = ""
        guard !text.isEmpty else { return }
        model?.type(text)
    }

    override func doCommand(by selector: Selector) {
        // Keys without text that weren't handled above (e.g. ctrl combinations) are ignored.
    }

    func setMarkedText(_ string: Any, selectedRange: NSRange, replacementRange: NSRange) {
        markedText = (string as? String) ?? (string as? NSAttributedString)?.string ?? ""
        needsDisplay = true
    }

    func unmarkText() {
        markedText = ""
        needsDisplay = true
    }

    func selectedRange() -> NSRange { NSRange(location: 0, length: 0) }

    func markedRange() -> NSRange {
        markedText.isEmpty ? NSRange(location: NSNotFound, length: 0) : NSRange(location: 0, length: (markedText as NSString).length)
    }

    func hasMarkedText() -> Bool { !markedText.isEmpty }

    func attributedSubstring(forProposedRange range: NSRange, actualRange: NSRangePointer?) -> NSAttributedString? { nil }

    func validAttributesForMarkedText() -> [NSAttributedString.Key] { [] }

    func firstRect(forCharacterRange range: NSRange, actualRange: NSRangePointer?) -> NSRect {
        guard let window else { return .zero }
        return window.convertToScreen(convert(NSRect(x: bounds.midX, y: bounds.midY, width: 1, height: 20), to: nil))
    }

    func characterIndex(for point: NSPoint) -> Int { 0 }
}
