import SwiftUI
import AppKit

/// The state of the drawing editor: the drawing, the tool and its colours, what is selected, and the steps to undo.
@MainActor
@Observable
final class DrawingEditorModel {
    enum Tool: String, CaseIterable, Identifiable {
        case select, pen, highlighter, line, arrow, doubleArrow, rectangle, roundedRectangle, ellipse, diamond, text, eraser

        var id: String { rawValue }

        var label: String {
            switch self {
            case .select: "Auswählen und verschieben (V)"
            case .pen: "Stift (P)"
            case .highlighter: "Textmarker (M)"
            case .line: "Linie (L)"
            case .arrow: "Pfeil (A)"
            case .doubleArrow: "Doppelpfeil"
            case .rectangle: "Rechteck (R)"
            case .roundedRectangle: "Abgerundetes Rechteck"
            case .ellipse: "Ellipse (O)"
            case .diamond: "Raute"
            case .text: "Text (T)"
            case .eraser: "Radierer (E) – löscht, was er berührt"
            }
        }

        var symbol: String {
            switch self {
            case .select: "cursorarrow"
            case .pen: "pencil.tip"
            case .highlighter: "highlighter"
            case .line: "line.diagonal"
            case .arrow: "arrow.up.right"
            case .doubleArrow: "arrow.up.left.and.arrow.down.right"
            case .rectangle: "rectangle"
            case .roundedRectangle: "app"
            case .ellipse: "circle"
            case .diamond: "diamond"
            case .text: "textformat"
            case .eraser: "eraser"
            }
        }

        var kind: WriterDrawing.Kind? {
            switch self {
            case .select, .eraser: nil
            case .pen: .pen
            case .highlighter: .highlighter
            case .line: .line
            case .arrow: .arrow
            case .doubleArrow: .doubleArrow
            case .rectangle: .rectangle
            case .roundedRectangle: .roundedRectangle
            case .ellipse: .ellipse
            case .diamond: .diamond
            case .text: .text
            }
        }

        var key: Character? {
            switch self {
            case .select: "v"
            case .pen: "p"
            case .highlighter: "m"
            case .line: "l"
            case .arrow: "a"
            case .rectangle: "r"
            case .ellipse: "o"
            case .text: "t"
            case .eraser: "e"
            default: nil
            }
        }
    }

    var drawing: WriterDrawing
    var tool: Tool = .pen
    var stroke = "1C1C1F"
    var fill: String?
    var width: CGFloat = 3
    var dashed = false
    var fontSize: CGFloat = 24
    var selection = Set<UUID>()
    var previewDark = false
    var caption: String
    let isExisting: Bool
    private var undoStack: [WriterDrawing] = []
    private var redoStack: [WriterDrawing] = []
    /// Bumped whenever the canvas must be drawn again.
    private(set) var revision = 0

    static let widths: [CGFloat] = [1.5, 3, 5, 9, 16]

    init(request: WriterFigureRequest) {
        drawing = request.drawing
        caption = request.reference?.caption ?? ""
        isExisting = request.isExisting
    }

    var canUndo: Bool { !undoStack.isEmpty }
    var canRedo: Bool { !redoStack.isEmpty }

    /// Call before a change, so it can be undone.
    func remember() {
        undoStack.append(drawing)
        if undoStack.count > 200 { undoStack.removeFirst() }
        redoStack.removeAll()
    }

    func undo() {
        guard let last = undoStack.popLast() else { return }
        redoStack.append(drawing)
        drawing = last
        selection = selection.filter { id in drawing.shapes.contains { $0.id == id } }
        changed()
    }

    func redo() {
        guard let next = redoStack.popLast() else { return }
        undoStack.append(drawing)
        drawing = next
        changed()
    }

    func changed() { revision += 1 }

    var selectedShapes: [WriterDrawing.Shape] { drawing.shapes.filter { selection.contains($0.id) } }

    /// A colour, width or line chosen while shapes are selected changes them too.
    func applyToSelection(_ change: (inout WriterDrawing.Shape) -> Void) {
        guard !selection.isEmpty else { return }
        remember()
        for index in drawing.shapes.indices where selection.contains(drawing.shapes[index].id) { change(&drawing.shapes[index]) }
        changed()
    }

    func setStroke(_ hex: String) {
        stroke = hex
        applyToSelection { $0.stroke = hex }
    }

    func setFill(_ hex: String?) {
        fill = hex
        applyToSelection { shape in if shape.kind.canFill || shape.kind == .text { shape.fill = hex } }
    }

    func setWidth(_ value: CGFloat) {
        width = value
        applyToSelection { if $0.kind != .text { $0.width = value } }
    }

    func setDashed(_ value: Bool) {
        dashed = value
        applyToSelection { $0.dashed = value }
    }

    func deleteSelection() {
        guard !selection.isEmpty else { return }
        remember()
        drawing.shapes.removeAll { selection.contains($0.id) }
        selection = []
        changed()
    }

    func bringToFront() {
        guard !selection.isEmpty else { return }
        remember()
        let selected = drawing.shapes.filter { selection.contains($0.id) }
        drawing.shapes.removeAll { selection.contains($0.id) }
        drawing.shapes += selected
        changed()
    }

    func clear() {
        guard !drawing.shapes.isEmpty else { return }
        remember()
        drawing.shapes = []
        selection = []
        changed()
    }

    func setSize(_ size: CGSize) {
        guard size != drawing.size else { return }
        remember()
        drawing.size = size
        changed()
    }

    func setBackground(_ background: WriterDrawing.Background) {
        guard background != drawing.background else { return }
        remember()
        drawing.background = background
        changed()
    }
}

/// The canvas of the drawing editor: draws the drawing scaled to fit and turns the mouse into strokes and shapes.
final class DrawingCanvasView: NSView, NSTextFieldDelegate {
    var model: DrawingEditorModel?
    private var current: WriterDrawing.Shape?
    private var dragStart: CGPoint?
    private var movedSelection = false
    private var lastPoint: CGPoint?
    private var textField: NSTextField?
    /// The text shape the field edits (nil: a new one at `textOrigin`).
    private var editedText: UUID?
    private var textOrigin: CGPoint = .zero
    private var resizing: (id: UUID, original: WriterDrawing.Shape)?

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    /// A stroke starts with the first click, also when the window wasn't active.
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    private var drawing: WriterDrawing { model?.drawing ?? WriterDrawing() }

    /// Screen points per point of the drawing; the drawing sits centred.
    private var scale: CGFloat {
        let size = drawing.size
        guard size.width > 0, size.height > 0 else { return 1 }
        return min(bounds.width / size.width, bounds.height / size.height)
    }

    private var offset: CGPoint {
        let size = drawing.size
        return CGPoint(x: (bounds.width - size.width * scale) / 2, y: (bounds.height - size.height * scale) / 2)
    }

    private func toDrawing(_ point: NSPoint) -> CGPoint {
        CGPoint(x: (point.x - offset.x) / scale, y: (point.y - offset.y) / scale)
    }

    private func toView(_ point: CGPoint) -> NSPoint {
        NSPoint(x: point.x * scale + offset.x, y: point.y * scale + offset.y)
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext, let model else { return }
        let dark = model.previewDark
        let page = CGRect(origin: offset, size: CGSize(width: drawing.size.width * scale, height: drawing.size.height * scale))
        (dark ? WriterPalette.dark.page : NSColor.white).setFill()
        NSBezierPath(roundedRect: page, xRadius: 4, yRadius: 4).fill()
        NSColor(Theme.border).setStroke()
        NSBezierPath(roundedRect: page.insetBy(dx: -0.5, dy: -0.5), xRadius: 4, yRadius: 4).stroke()
        context.saveGState()
        context.clip(to: page)
        context.translateBy(x: offset.x, y: offset.y)
        context.scaleBy(x: scale, y: scale)
        drawing.draw(in: context, dark: dark)
        if let current { WriterDrawing.draw(current, in: context, dark: dark) }
        // What is selected: a dashed frame and a handle to resize a single shape.
        for shape in model.selectedShapes {
            let frame = shape.bounds.insetBy(dx: -6 - shape.width / 2, dy: -6 - shape.width / 2)
            context.setStrokeColor(NSColor(hex: 0x6A54E0).cgColor)
            context.setLineWidth(1.2 / scale)
            context.setLineDash(phase: 0, lengths: [5 / scale, 3 / scale])
            context.stroke(frame)
            context.setLineDash(phase: 0, lengths: [])
            if model.selection.count == 1 {
                context.setFillColor(NSColor(hex: 0x6A54E0).cgColor)
                context.fillEllipse(in: handleRect(for: shape))
            }
        }
        context.restoreGState()
    }

    private func handleRect(for shape: WriterDrawing.Shape) -> CGRect {
        let frame = shape.bounds.insetBy(dx: -6 - shape.width / 2, dy: -6 - shape.width / 2)
        let size = 10 / scale
        return CGRect(x: frame.maxX - size / 2, y: frame.maxY - size / 2, width: size, height: size)
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        commitText()
        guard let model else { return }
        let point = toDrawing(convert(event.locationInWindow, from: nil))
        dragStart = point
        lastPoint = point
        movedSelection = false
        switch model.tool {
        case .select:
            if model.selection.count == 1, let shape = model.selectedShapes.first, handleRect(for: shape).insetBy(dx: -4 / scale, dy: -4 / scale).contains(point) {
                model.remember()
                resizing = (shape.id, shape)
                return
            }
            if let hit = drawing.shapes.last(where: { $0.hit(point, tolerance: 6 / scale) }) {
                if event.modifierFlags.contains(.shift) {
                    if model.selection.contains(hit.id) { model.selection.remove(hit.id) } else { model.selection.insert(hit.id) }
                } else if !model.selection.contains(hit.id) {
                    model.selection = [hit.id]
                }
                if event.clickCount >= 2, hit.kind == .text { beginText(at: hit.points.first ?? point, editing: hit) }
            } else {
                model.selection = []
            }
            model.changed()
        case .eraser:
            model.remember()
            erase(at: point)
        case .text:
            if let hit = drawing.shapes.last(where: { $0.kind == .text && $0.hit(point, tolerance: 4) }) {
                beginText(at: hit.points.first ?? point, editing: hit)
            } else {
                beginText(at: point, editing: nil)
            }
        default:
            guard let kind = model.tool.kind else { return }
            model.selection = []
            current = WriterDrawing.Shape(kind: kind, points: kind.isTwoPoint ? [point, point] : [point], stroke: model.stroke,
                                          fill: kind.canFill ? model.fill : nil,
                                          width: kind == .highlighter ? max(12, model.width * 3) : model.width, dashed: model.dashed)
        }
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        guard let model, let start = dragStart else { return }
        var point = toDrawing(convert(event.locationInWindow, from: nil))
        switch model.tool {
        case .select:
            if let resizing, let index = model.drawing.shapes.firstIndex(where: { $0.id == resizing.id }) {
                let origin = resizing.original.bounds.origin
                let rect = CGRect(x: origin.x, y: origin.y, width: max(4, point.x - origin.x), height: max(4, point.y - origin.y))
                model.drawing.shapes[index] = resizing.original.fitted(into: rect)
                model.changed()
            } else if !model.selection.isEmpty, let last = lastPoint {
                if !movedSelection {
                    model.remember()
                    movedSelection = true
                }
                let delta = CGSize(width: point.x - last.x, height: point.y - last.y)
                for index in model.drawing.shapes.indices where model.selection.contains(model.drawing.shapes[index].id) {
                    model.drawing.shapes[index] = model.drawing.shapes[index].moved(by: delta)
                }
                model.changed()
            }
        case .eraser:
            erase(at: point)
        default:
            guard var shape = current else { return }
            if shape.kind.isTwoPoint {
                if event.modifierFlags.contains(.shift) { point = constrained(point, from: start, kind: shape.kind) }
                shape.points[1] = point
            } else if let last = shape.points.last, hypot(point.x - last.x, point.y - last.y) >= 1.2 / scale {
                shape.points.append(point)
            }
            current = shape
        }
        lastPoint = point
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        defer {
            current = nil
            dragStart = nil
            resizing = nil
            needsDisplay = true
        }
        guard let model, let shape = current else { return }
        let size = shape.bounds.size
        if shape.kind.isTwoPoint, max(size.width, size.height) < 3 { return }
        model.remember()
        model.drawing.shapes.append(shape)
        model.changed()
    }

    /// Shift: lines in steps of 45°, shapes square or round.
    private func constrained(_ point: CGPoint, from start: CGPoint, kind: WriterDrawing.Kind) -> CGPoint {
        let dx = point.x - start.x, dy = point.y - start.y
        if kind == .line || kind == .arrow || kind == .doubleArrow {
            let angle = (atan2(dy, dx) / (.pi / 4)).rounded() * (.pi / 4)
            let length = hypot(dx, dy)
            return CGPoint(x: start.x + length * cos(angle), y: start.y + length * sin(angle))
        }
        let side = max(abs(dx), abs(dy))
        return CGPoint(x: start.x + (dx < 0 ? -side : side), y: start.y + (dy < 0 ? -side : side))
    }

    private func erase(at point: CGPoint) {
        guard let model else { return }
        let before = model.drawing.shapes.count
        // The tolerance first: the scale reads the drawing, which mustn't be read while shapes are removed.
        let tolerance = 8 / scale
        model.drawing.shapes.removeAll { $0.hit(point, tolerance: tolerance) }
        if model.drawing.shapes.count != before { model.changed() }
    }

    // MARK: Text

    private func beginText(at point: CGPoint, editing shape: WriterDrawing.Shape?) {
        guard let model else { return }
        editedText = shape?.id
        textOrigin = point
        let size = (shape?.fontSize ?? model.fontSize) * scale
        let field = NSTextField(string: shape?.text ?? "")
        field.font = WriterDrawing.textFont(size: size)
        field.isBordered = false
        field.drawsBackground = true
        field.backgroundColor = NSColor(hex: 0x6A54E0).withAlphaComponent(0.12)
        field.textColor = WriterDrawing.color(shape?.stroke ?? model.stroke, dark: model.previewDark)
        field.focusRingType = .none
        field.delegate = self
        field.placeholderString = "Text"
        let origin = toView(point)
        field.frame = NSRect(x: origin.x - 2, y: origin.y - 1, width: max(160, min(bounds.width - origin.x, 420)), height: size * 1.35)
        addSubview(field)
        textField = field
        window?.makeFirstResponder(field)
        if shape != nil {
            model.selection = []
            // The shape is hidden while its text is edited.
            model.remember()
            model.drawing.shapes.removeAll { $0.id == shape?.id }
            model.changed()
        }
    }

    func controlTextDidEndEditing(_ notification: Notification) {
        commitText()
    }

    private func commitText() {
        guard let field = textField, let model else { return }
        textField = nil
        field.removeFromSuperview()
        let text = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        if editedText == nil { model.remember() }
        var shape = WriterDrawing.Shape(kind: .text, points: [textOrigin], stroke: model.stroke, fill: nil, width: 1, text: text, fontSize: model.fontSize)
        if let id = editedText { shape.id = id }
        model.drawing.shapes.append(shape)
        editedText = nil
        model.changed()
        window?.makeFirstResponder(self)
        needsDisplay = true
    }

    // MARK: Keys

    override func keyDown(with event: NSEvent) {
        guard let model else { return super.keyDown(with: event) }
        if event.keyCode == 51 || event.keyCode == 117 { return model.deleteSelection() }
        let nudges: [UInt16: CGSize] = [123: CGSize(width: -1, height: 0), 124: CGSize(width: 1, height: 0), 125: CGSize(width: 0, height: 1), 126: CGSize(width: 0, height: -1)]
        if var delta = nudges[event.keyCode], !model.selection.isEmpty {
            if event.modifierFlags.contains(.shift) { delta = CGSize(width: delta.width * 10, height: delta.height * 10) }
            model.applyToSelection { $0 = $0.moved(by: delta) }
            return
        }
        if event.modifierFlags.intersection([.command, .control, .option]).isEmpty, let character = event.charactersIgnoringModifiers?.lowercased().first,
           let tool = DrawingEditorModel.Tool.allCases.first(where: { $0.key == character }) {
            model.tool = tool
            return
        }
        super.keyDown(with: event)
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard let model, event.modifierFlags.contains(.command), window?.firstResponder === self else { return super.performKeyEquivalent(with: event) }
        switch event.charactersIgnoringModifiers?.lowercased() {
        case "z":
            if event.modifierFlags.contains(.shift) { model.redo() } else { model.undo() }
            return true
        case "a":
            model.selection = Set(model.drawing.shapes.map(\.id))
            model.tool = .select
            model.changed()
            return true
        case "d":
            guard !model.selection.isEmpty else { return false }
            model.remember()
            let copies = model.selectedShapes.map { shape -> WriterDrawing.Shape in
                var copy = shape.moved(by: CGSize(width: 16, height: 16))
                copy.id = UUID()
                return copy
            }
            model.drawing.shapes += copies
            model.selection = Set(copies.map(\.id))
            model.changed()
            return true
        default:
            return super.performKeyEquivalent(with: event)
        }
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: model?.tool == .select ? .arrow : model?.tool == .text ? .iBeam : .crosshair)
    }
}

struct DrawingCanvas: NSViewRepresentable {
    let model: DrawingEditorModel

    func makeNSView(context: Context) -> DrawingCanvasView {
        let view = DrawingCanvasView()
        view.model = model
        DispatchQueue.main.async { view.window?.makeFirstResponder(view) }
        return view
    }

    func updateNSView(_ view: DrawingCanvasView, context: Context) {
        _ = model.revision
        _ = model.selection
        _ = model.previewDark
        _ = model.tool
        view.model = model
        view.needsDisplay = true
        view.window?.invalidateCursorRects(for: view)
    }
}

/// Draws: strokes with the pen and the marker, lines, arrows, shapes and text, in colours that work on white paper and
/// (brightened) on the dark sheet. The drawing goes into the document as a picture that opens here again.
struct DrawingEditorSheet: View {
    @State private var model: DrawingEditorModel
    let onCommit: (_ images: WriterFigureImages, _ recipe: Data, _ caption: String, _ width: Int?) -> Void
    let onCancel: () -> Void

    init(request: WriterFigureRequest, onCommit: @escaping (WriterFigureImages, Data, String, Int?) -> Void, onCancel: @escaping () -> Void) {
        _model = State(initialValue: DrawingEditorModel(request: request))
        self.onCommit = onCommit
        self.onCancel = onCancel
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            FigureSheetHeader(symbol: "pencil.and.scribble", title: model.isExisting ? "Zeichnung bearbeiten" : "Neue Zeichnung") {
                HStack(spacing: 8) {
                    Button { model.undo() } label: { Image(systemName: "arrow.uturn.backward") }
                        .disabled(!model.canUndo).help("Rückgängig (⌘Z)")
                    Button { model.redo() } label: { Image(systemName: "arrow.uturn.forward") }
                        .disabled(!model.canRedo).help("Wiederholen (⇧⌘Z)")
                    Picker("", selection: $model.previewDark) {
                        Text("Weißes Papier").tag(false)
                        Text("Dunkles Blatt").tag(true)
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .fixedSize()
                    .help("So sieht die Zeichnung auf weißem Papier (und im Druck) und auf dem dunklen Blatt aus")
                }
            }
            HStack(alignment: .top, spacing: 12) {
                tools
                VStack(spacing: 10) {
                    DrawingCanvas(model: model)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Theme.shade.opacity(0.25)))
                    properties
                }
            }
            FigureSheetFooter(
                hint: "⇧ beim Ziehen: gerade Linien, Quadrate, Kreise · ⌫ löscht die Auswahl · ⌘D dupliziert · Doppelklick auf Text ändert ihn",
                commitTitle: model.isExisting ? "Übernehmen" : "Einfügen",
                canCommit: !model.drawing.isEmpty,
                onCancel: onCancel,
                onCommit: commit
            )
        }
        .padding(20)
        .frame(width: 980, height: 700)
        .background(Theme.surface)
    }

    private var tools: some View {
        VStack(spacing: 3) {
            ForEach(DrawingEditorModel.Tool.allCases) { tool in
                ToolbarButton(symbol: tool.symbol, help: tool.label, isActive: model.tool == tool) {
                    model.tool = tool
                    if tool != .select { model.selection = [] }
                    model.changed()
                }
            }
            Spacer(minLength: 8)
            ToolbarButton(symbol: "square.3.layers.3d.top.filled", help: "Nach vorn holen", isActive: false) { model.bringToFront() }
                .disabled(model.selection.isEmpty)
            ToolbarButton(symbol: "trash", help: "Auswahl löschen (⌫)", isActive: false) { model.deleteSelection() }
                .disabled(model.selection.isEmpty)
        }
        .padding(4)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Theme.ink.opacity(0.04)))
    }

    private var properties: some View {
        HStack(alignment: .top, spacing: 22) {
            VStack(alignment: .leading, spacing: 6) {
                FigureSectionTitle("Farbe")
                HStack(spacing: 4) {
                    ForEach(WriterDrawing.inks, id: \.hex) { ink in
                        FigureSwatch(hex: ink.hex, isSelected: model.stroke == ink.hex) { model.setStroke(ink.hex) }.help(ink.name)
                    }
                }
                FigureSectionTitle("Füllung")
                HStack(spacing: 4) {
                    FigureSwatch(hex: nil, isSelected: model.fill == nil) { model.setFill(nil) }.help("Ohne Füllung")
                    ForEach(WriterDrawing.fills, id: \.hex) { fill in
                        FigureSwatch(hex: fill.hex, isFill: true, isSelected: model.fill == fill.hex) { model.setFill(fill.hex) }.help(fill.name)
                    }
                }
            }
            VStack(alignment: .leading, spacing: 6) {
                FigureSectionTitle("Strich")
                HStack(spacing: 4) {
                    ForEach(DrawingEditorModel.widths, id: \.self) { width in
                        Button { model.setWidth(width) } label: {
                            Capsule().fill(Theme.textPrimary).frame(width: 18, height: min(10, max(1.5, width * 0.7)))
                                .frame(width: 30, height: 24)
                                .background(RoundedRectangle(cornerRadius: 6).fill(model.width == width ? Theme.accent.opacity(0.22) : Theme.ink.opacity(0.04)))
                        }
                        .buttonStyle(.plain)
                    }
                }
                Toggle("Gestrichelt", isOn: Binding(get: { model.dashed }, set: { model.setDashed($0) }))
                    .toggleStyle(.checkbox)
                    .font(.system(size: 12))
                HStack(spacing: 6) {
                    Text("Textgröße").font(.system(size: 12)).foregroundStyle(Theme.textSecondary)
                    Picker("", selection: $model.fontSize) {
                        ForEach([14, 18, 24, 32, 44, 60] as [CGFloat], id: \.self) { Text("\(Int($0))").tag($0) }
                    }
                    .labelsHidden()
                    .fixedSize()
                }
            }
            VStack(alignment: .leading, spacing: 6) {
                FigureSectionTitle("Blatt")
                Picker("", selection: Binding(get: { WriterDrawing.formats.first { $0.size == model.drawing.size }?.label ?? "" },
                                              set: { label in if let format = WriterDrawing.formats.first(where: { $0.label == label }) { model.setSize(format.size) } })) {
                    ForEach(WriterDrawing.formats, id: \.label) { Text($0.label).tag($0.label) }
                }
                .labelsHidden()
                .fixedSize()
                Picker("", selection: Binding(get: { model.drawing.background }, set: { model.setBackground($0) })) {
                    ForEach(WriterDrawing.Background.allCases) { Text($0.label).tag($0) }
                }
                .labelsHidden()
                .fixedSize()
                Button("Alles löschen", role: .destructive) { model.clear() }
                    .controlSize(.small)
                    .disabled(model.drawing.isEmpty)
            }
            VStack(alignment: .leading, spacing: 6) {
                FigureSectionTitle("Bildunterschrift")
                FigureField(placeholder: "im PDF „Abbildung n: …“", text: $model.caption)
                    .frame(width: 200)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Theme.ink.opacity(0.03)))
    }

    private func commit() {
        guard let images = model.drawing.images() else { return }
        let width = min(100, max(25, Int((model.drawing.size.width / WriterImageStore.referenceColumnWidth * 100).rounded())))
        onCommit(images, model.drawing.json, model.caption.trimmingCharacters(in: .whitespacesAndNewlines), width)
    }
}
