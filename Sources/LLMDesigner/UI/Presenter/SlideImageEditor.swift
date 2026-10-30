import SwiftUI

/// The free pictures and text fields of the open slide, over the editor: a click selects one, dragging moves it (it
/// snaps to the slide's middle and margins), the corners resize it (⇧ frees a picture's shape, keeps a text field's).
/// The bar above it sets how the text runs around it. A double click on a text field opens it for writing: the
/// editor moves into it. Pictures behind the text are reached with ⌘-click, so clicks on the text still go to the
/// text. In the text-area mode the slide's own text shows its frame, to be moved and resized the same way.
struct SlideImageEditor: View {
    @Environment(AppModel.self) private var app
    let document: WriterDocument
    let slide: PresentationSlide
    let controller: WriterEditorController
    /// The pictures while one is being dragged: the text flows around them live, the slide only changes at the end.
    @Binding var dragImages: [SlideImage]?
    /// The slide's text area while it is dragged.
    @Binding var dragTextFrame: CGRect?
    let onRegenerate: (SlideImage) -> Void

    @State private var commandHeld = false
    @State private var monitor: Any?
    @State private var dragStart: SlideImage?
    @State private var areaStart: CGRect?
    @State private var guides: Guides = []

    struct Guides: OptionSet {
        let rawValue: Int
        static let centerX = Guides(rawValue: 1)
        static let centerY = Guides(rawValue: 2)
        static let marginLeft = Guides(rawValue: 4)
        static let marginRight = Guides(rawValue: 8)
        static let marginTop = Guides(rawValue: 16)
        static let marginBottom = Guides(rawValue: 32)
    }

    private static let space = "slideImageCanvas"
    private var canvas: CGSize { SlideImage.canvas }
    private var margin: CGSize { WriterTextView.SlideLayout.margin }

    var body: some View {
        let images = dragImages ?? slide.images
        GeometryReader { geometry in
            let scale = geometry.size.width / canvas.width
            ZStack(alignment: .topLeading) {
                ForEach(images) { image in
                    imageView(image, scale: scale)
                }
                if app.editingSlideTextArea {
                    textArea(scale: scale, size: geometry.size)
                }
                guideLines(scale: scale)
                if !app.editingSlideTextArea, let selected = images.first(where: { $0.id == app.selectedSlideImageID }) {
                    handles(selected, scale: scale)
                    bar(selected, scale: scale, size: geometry.size)
                }
            }
            .frame(width: geometry.size.width, height: geometry.size.height, alignment: .topLeading)
            // Drags are measured on the slide, not on the picture that moves under the pointer.
            .coordinateSpace(name: Self.space)
        }
        .onAppear(perform: installMonitor)
        .onDisappear(perform: removeMonitor)
        .onChange(of: slide.id) { _, _ in
            dragImages = nil
            dragStart = nil
            dragTextFrame = nil
            areaStart = nil
        }
    }

    // MARK: Pictures

    @ViewBuilder
    private func imageView(_ image: SlideImage, scale: CGFloat) -> some View {
        let frame = image.frame
        let isSelected = app.selectedSlideImageID == image.id
        let isEditing = app.editingSlideFieldID == image.id
        if isEditing {
            // The editor writes in the field; here only its outline and a grip to move it by.
            Rectangle()
                .strokeBorder(Theme.accent.opacity(0.8), style: StrokeStyle(lineWidth: 1, dash: [5, 3]))
                .frame(width: max(1, frame.width * scale), height: max(1, frame.height * scale))
                .allowsHitTesting(false)
                .position(x: frame.midX * scale, y: frame.midY * scale)
            grip(image, scale: scale)
        } else {
            Group {
                // A picture behind the text is drawn below the editor; here only its place to grab.
                if image.placement == .behind {
                    Color.clear
                } else {
                    SlideImageView(image: image)
                }
            }
            .frame(width: max(1, frame.width * scale), height: max(1, frame.height * scale))
            .overlay {
                if isSelected {
                    Rectangle().strokeBorder(Theme.accent, lineWidth: 1.5)
                } else if commandHeld {
                    Rectangle().strokeBorder(Theme.accent.opacity(0.55), style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
                } else if image.isText, image.box == nil {
                    // A plain text field shows where it is.
                    Rectangle().strokeBorder(Color.white.opacity(0.16), style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
                }
            }
            .overlay {
                if image.isText, (image.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    Text("Doppelklick zum Schreiben")
                        .font(.system(size: max(8, 11 * scale), weight: .medium))
                        .foregroundStyle(Color.white.opacity(0.45))
                }
            }
            .contentShape(Rectangle())
            .gesture(moveGesture(image, scale: scale))
            .simultaneousGesture(TapGesture(count: 2).onEnded {
                if image.isText { edit(image) }
            })
            .contextMenu { menu(image) }
            .allowsHitTesting(image.placement != .behind || isSelected || commandHeld)
            .help(help(for: image))
            .position(x: frame.midX * scale, y: frame.midY * scale)
        }
    }

    private func help(for image: SlideImage) -> String {
        if image.isText { return "Doppelklick zum Schreiben – ziehen zum Verschieben, an den Ecken die Größe ändern" }
        return image.placement == .behind ? "Bild hinter dem Text – ziehen zum Verschieben" : "Ziehen zum Verschieben, an den Ecken die Größe ändern"
    }

    /// While a text field is being written in, it moves by this grip above its top left corner.
    private func grip(_ image: SlideImage, scale: CGFloat) -> some View {
        let frame = image.frame
        return Image(systemName: "arrow.up.and.down.and.arrow.left.and.right")
            .font(.system(size: 9.5, weight: .bold))
            .foregroundStyle(Color.white)
            .frame(width: 20, height: 20)
            .background(Circle().fill(Theme.accent))
            .contentShape(Circle())
            .gesture(moveGesture(image, scale: scale))
            .help("Textfeld verschieben")
            .position(x: frame.minX * scale + 2, y: frame.minY * scale - 14)
    }

    /// Opens a text field for writing: the editor moves into it.
    private func edit(_ image: SlideImage) {
        app.selectedSlideImageID = image.id
        app.editingSlideTextArea = false
        if app.editingSlideFieldID != image.id {
            app.writerFlush?()
            app.editingSlideFieldID = image.id
        }
    }

    private func moveGesture(_ image: SlideImage, scale: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .named(Self.space))
            .onChanged { value in
                if dragStart?.id != image.id {
                    dragStart = image
                    if app.editingSlideFieldID != image.id { select(image.id) }
                }
                guard let start = dragStart, hypot(value.translation.width, value.translation.height) > 2 else { return }
                var frame = start.frame
                frame.origin.x += value.translation.width / scale
                frame.origin.y += value.translation.height / scale
                let (snapped, lines) = snap(frame, tolerance: 5 / scale)
                guides = lines
                change(image.id) { $0.frame = clamp(snapped) }
            }
            .onEnded { _ in
                dragStart = nil
                guides = []
                commit(image.isText ? "Textfeld verschieben" : "Bild verschieben")
            }
    }

    // MARK: Resizing

    private enum Corner: CaseIterable, Identifiable {
        case topLeft, topRight, bottomLeft, bottomRight
        var id: Self { self }
    }

    private func handles(_ image: SlideImage, scale: CGFloat) -> some View {
        let frame = image.frame
        return ForEach(Corner.allCases) { corner in
            let point: CGPoint = switch corner {
            case .topLeft: CGPoint(x: frame.minX, y: frame.minY)
            case .topRight: CGPoint(x: frame.maxX, y: frame.minY)
            case .bottomLeft: CGPoint(x: frame.minX, y: frame.maxY)
            case .bottomRight: CGPoint(x: frame.maxX, y: frame.maxY)
            }
            RoundedRectangle(cornerRadius: 2, style: .continuous)
                .fill(Color.white)
                .overlay(RoundedRectangle(cornerRadius: 2, style: .continuous).strokeBorder(Theme.accent, lineWidth: 1.5))
                .frame(width: 10, height: 10)
                .frame(width: 22, height: 22)
                .contentShape(Rectangle())
                .gesture(resizeGesture(image, corner: corner, scale: scale))
                .position(x: point.x * scale, y: point.y * scale)
                .help("Größe ändern – mit ⇧ ohne das Seitenverhältnis")
        }
    }

    private func resizeGesture(_ image: SlideImage, corner: Corner, scale: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 1, coordinateSpace: .named(Self.space))
            .onChanged { value in
                if dragStart?.id != image.id { dragStart = image }
                guard let start = dragStart?.frame else { return }
                let dx = value.translation.width / scale
                let dy = value.translation.height / scale
                let left = corner == .topLeft || corner == .bottomLeft
                let top = corner == .topLeft || corner == .topRight
                let minimum = canvas.width * SlideImage.minimumWidth
                var width = max(minimum, start.width + (left ? -dx : dx))
                var height = max(minimum, start.height + (top ? -dy : dy))
                // A picture keeps its shape unless ⇧ is held; a text field only with ⇧.
                if NSEvent.modifierFlags.contains(.shift) == image.isText {
                    // The picture keeps its shape: the larger change decides.
                    let aspect = start.width / max(1, start.height)
                    if abs(width - start.width) >= abs(height - start.height) * aspect {
                        height = max(minimum / aspect, width / aspect)
                    } else {
                        width = max(minimum, height * aspect)
                    }
                }
                let x = left ? start.maxX - width : start.minX
                let y = top ? start.maxY - height : start.minY
                change(image.id) { $0.frame = CGRect(x: x, y: y, width: width, height: height) }
            }
            .onEnded { _ in
                dragStart = nil
                commit(image.isText ? "Größe des Textfelds" : "Bildgröße ändern")
            }
    }

    // MARK: Bar and menu

    private func bar(_ image: SlideImage, scale: CGFloat, size: CGSize) -> some View {
        let frame = image.frame
        let above = frame.minY * scale > 44
        let y = above ? frame.minY * scale - 24 : min(size.height - 20, frame.maxY * scale + 24)
        let x = min(max(frame.midX * scale, 150), size.width - 150)
        return HStack(spacing: 2) {
            Menu {
                ForEach(SlideImage.Placement.allCases, id: \.self) { placement in
                    Button { setPlacement(placement, of: image) } label: {
                        if placement == image.placement { Label(placement.label, systemImage: "checkmark") } else { Text(placement.label) }
                    }
                }
            } label: {
                Label(image.placement.label, systemImage: image.placement.symbol)
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(Theme.textPrimary)
                    .padding(.horizontal, 7)
                    .frame(height: 24)
                    .contentShape(Rectangle())
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("Wie Bild und Text die Folie teilen")
            separator
            if image.isText {
                if app.editingSlideFieldID == image.id {
                    IconButton(systemName: "checkmark", help: "Fertig – zurück zum Text der Folie (esc)", size: 11.5, frameSize: 24) { finishEditing(image) }
                } else {
                    IconButton(systemName: "pencil", help: "Text bearbeiten (Doppelklick)", size: 11.5, frameSize: 24) { edit(image) }
                }
                boxMenu(image)
                separator
            }
            IconButton(systemName: "square.3.layers.3d.top.filled", help: "Ganz nach vorn", size: 11.5, frameSize: 24) { reorder(image, toFront: true) }
            IconButton(systemName: "square.3.layers.3d.bottom.filled", help: "Ganz nach hinten", size: 11.5, frameSize: 24) { reorder(image, toFront: false) }
            if !image.isText {
                IconButton(systemName: "aspectratio", help: "Ursprüngliches Seitenverhältnis", size: 11.5, frameSize: 24) { restoreAspect(image) }
            }
            if image.generated {
                IconButton(systemName: "wand.and.stars", help: "Mit Draw Things neu generieren …", size: 11.5, frameSize: 24) { onRegenerate(image) }
            }
            separator
            IconButton(systemName: "trash", help: image.isText ? "Textfeld entfernen (⌫)" : "Bild entfernen (⌫)", size: 11.5, frameSize: 24) { delete(image.id) }
        }
        .padding(.horizontal, 4)
        .background(Capsule().fill(Theme.elevated))
        .overlay(Capsule().strokeBorder(Theme.strongBorder))
        .shadow(color: .black.opacity(0.35), radius: 8, y: 3)
        .fixedSize()
        .position(x: x, y: y)
    }

    /// Plain text or a box of some kind, and how the box is drawn.
    private func boxMenu(_ image: SlideImage) -> some View {
        Menu {
            boxItems(image)
        } label: {
            Image(systemName: image.box?.symbol ?? "textformat")
                .font(.system(size: 11.5, weight: .medium))
                .foregroundStyle(image.box == nil ? Theme.textSecondary : Theme.textPrimary)
                .frame(width: 24, height: 24)
                .contentShape(Rectangle())
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Kasten: Art und Rahmen")
    }

    @ViewBuilder
    private func boxItems(_ image: SlideImage) -> some View {
        Button { setBox(nil, of: image) } label: {
            if image.box == nil { Label("Nur Text", systemImage: "checkmark") } else { Text("Nur Text") }
        }
        Section("Kasten") {
            ForEach(WriterBoxKind.allCases) { kind in
                Button { setBox(kind, of: image) } label: {
                    if image.box == kind { Label(kind.label, systemImage: "checkmark") } else { Label(kind.label, systemImage: kind.symbol) }
                }
            }
        }
        if image.box != nil {
            Section("Rahmen") {
                ForEach(WriterBoxStyle.Frame.allCases) { frame in
                    Button { setBoxFrame(frame, of: image) } label: {
                        if image.boxFrame == frame { Label(frame.label, systemImage: "checkmark") } else { Text(frame.label) }
                    }
                }
            }
        }
    }

    private var separator: some View {
        Rectangle().fill(Theme.border).frame(width: 1, height: 14).padding(.horizontal, 3)
    }

    @ViewBuilder
    private func menu(_ image: SlideImage) -> some View {
        if image.isText {
            Button("Text bearbeiten", systemImage: "pencil") { edit(image) }
            Menu("Kasten") { boxItems(image) }
            Divider()
        }
        Section("Lage zum Text") {
            ForEach(SlideImage.Placement.allCases, id: \.self) { placement in
                Button { setPlacement(placement, of: image) } label: {
                    if placement == image.placement { Label(placement.label, systemImage: "checkmark") } else { Text(placement.label) }
                }
            }
        }
        Divider()
        Button("Ganz nach vorn", systemImage: "square.3.layers.3d.top.filled") { reorder(image, toFront: true) }
        Button("Ganz nach hinten", systemImage: "square.3.layers.3d.bottom.filled") { reorder(image, toFront: false) }
        if !image.isText {
            Button("Ursprüngliches Seitenverhältnis", systemImage: "aspectratio") { restoreAspect(image) }
        }
        Button("Auf der Folie zentrieren", systemImage: "align.horizontal.center") {
            update(image.id, "Bild zentrieren") { images, index in
                var frame = images[index].frame
                frame.origin = CGPoint(x: (canvas.width - frame.width) / 2, y: (canvas.height - frame.height) / 2)
                images[index].frame = frame
            }
        }
        if image.generated {
            Button("Mit Draw Things neu generieren …", systemImage: "wand.and.stars") { onRegenerate(image) }
        }
        if !image.isText {
            Button("Im Finder zeigen", systemImage: "folder") {
                if let url = WriterImageStore.url(for: image.source) { NSWorkspace.shared.activateFileViewerSelecting([url]) }
            }
            .disabled(WriterImageStore.url(for: image.source) == nil)
        }
        Divider()
        Button(image.isText ? "Textfeld entfernen" : "Bild entfernen", systemImage: "trash", role: .destructive) { delete(image.id) }
    }

    // MARK: Changes

    private func select(_ id: SlideImage.ID) {
        if app.selectedSlideImageID != id { app.selectedSlideImageID = id }
        // The keys (⌫, arrows) act on the picture, not the text.
        if let window = controller.textView?.window, window.firstResponder is NSTextView { window.makeFirstResponder(nil) }
    }

    /// Changes a picture on the live copy; `commit` puts it into the presentation.
    private func change(_ id: SlideImage.ID, _ update: (inout SlideImage) -> Void) {
        var images = dragImages ?? slide.images
        guard let index = images.firstIndex(where: { $0.id == id }) else { return }
        update(&images[index])
        dragImages = images
    }

    private func commit(_ actionName: String) {
        guard let images = dragImages else { return }
        apply(images, actionName)
        dragImages = nil
    }

    /// The open slide as the app has it now (the key monitor outlives this view's copy of it).
    private var current: (id: WriterDocument.ID, slide: PresentationSlide)? {
        guard let document = app.selectedPresentation, let slideID = app.currentSlideID(in: document),
              let slide = document.deck?.slide(slideID) else { return nil }
        return (document.id, slide)
    }

    private func apply(_ images: [SlideImage], _ actionName: String) {
        guard let current else { return }
        app.setSlideImages(current.id, current.slide.id, images, undoManager: undoManager, actionName: actionName)
    }

    /// Changes one picture of the open slide as one step.
    private func update(_ id: SlideImage.ID, _ actionName: String, _ change: (inout [SlideImage], Int) -> Void) {
        guard var images = current?.slide.images, let index = images.firstIndex(where: { $0.id == id }) else { return }
        change(&images, index)
        apply(images, actionName)
    }

    private var undoManager: UndoManager? {
        controller.textView?.undoManager ?? NSApp.keyWindow?.undoManager
    }

    private func setPlacement(_ placement: SlideImage.Placement, of image: SlideImage) {
        update(image.id, "Lage des Bildes") { images, index in images[index].placement = placement }
    }

    private func reorder(_ image: SlideImage, toFront: Bool) {
        update(image.id, toFront ? "Nach vorn" : "Nach hinten") { images, index in
            let picture = images.remove(at: index)
            if toFront { images.append(picture) } else { images.insert(picture, at: 0) }
        }
    }

    private func restoreAspect(_ image: SlideImage) {
        guard let url = WriterImageStore.url(for: image.source), let size = WriterImageStore.naturalSize(of: url), size.height > 0 else { return }
        update(image.id, "Seitenverhältnis") { images, index in
            var frame = images[index].frame
            let middle = frame.midY
            frame.size.height = frame.width * size.height / size.width
            frame.origin.y = middle - frame.height / 2
            images[index].frame = clamp(frame)
        }
    }

    private func delete(_ id: SlideImage.ID) {
        if app.selectedSlideImageID == id { app.selectedSlideImageID = nil }
        if app.editingSlideFieldID == id { app.endSlideFieldEditing() }
        let isText = current?.slide.images.first { $0.id == id }?.isText == true
        update(id, isText ? "Textfeld entfernen" : "Bild entfernen") { images, index in images.remove(at: index) }
    }

    private func setBox(_ kind: WriterBoxKind?, of image: SlideImage) {
        update(image.id, "Kasten") { images, index in images[index].box = kind }
    }

    private func setBoxFrame(_ frame: WriterBoxStyle.Frame, of image: SlideImage) {
        update(image.id, "Rahmen des Kastens") { images, index in images[index].boxFrame = frame }
    }

    /// Back to the slide's own text; the field stays selected.
    private func finishEditing(_ image: SlideImage) {
        app.endSlideFieldEditing()
        app.selectedSlideImageID = image.id
        if let window = controller.textView?.window { window.makeFirstResponder(nil) }
    }

    private func nudge(by offset: CGSize) {
        if app.editingSlideTextArea, let current {
            var frame = current.slide.textFrame
            frame.origin.x += offset.width
            frame.origin.y += offset.height
            app.setSlideTextArea(current.id, current.slide.id, SlideArea(frame: clampArea(frame)), undoManager: undoManager)
            return
        }
        guard let id = app.selectedSlideImageID else { return }
        update(id, "Verschieben") { images, index in
            var frame = images[index].frame
            frame.origin.x += offset.width
            frame.origin.y += offset.height
            images[index].frame = clamp(frame)
        }
    }

    // MARK: The slide's text area

    /// The frame of the slide's own text, with a grip area and corners; the bar puts it back or ends the mode.
    private func textArea(scale: CGFloat, size: CGSize) -> some View {
        let frame = dragTextFrame ?? slide.textFrame
        return ZStack(alignment: .topLeading) {
            Rectangle()
                .fill(Theme.accent.opacity(0.06))
                .overlay(Rectangle().strokeBorder(Theme.accent, style: StrokeStyle(lineWidth: 1.5, dash: [6, 3])))
                .frame(width: frame.width * scale, height: frame.height * scale)
                .contentShape(Rectangle())
                .gesture(areaMoveGesture(scale: scale))
                .help("Textbereich der Folie – ziehen zum Verschieben, an den Ecken die Größe ändern")
                .position(x: frame.midX * scale, y: frame.midY * scale)
            ForEach(Corner.allCases) { corner in
                let point: CGPoint = switch corner {
                case .topLeft: CGPoint(x: frame.minX, y: frame.minY)
                case .topRight: CGPoint(x: frame.maxX, y: frame.minY)
                case .bottomLeft: CGPoint(x: frame.minX, y: frame.maxY)
                case .bottomRight: CGPoint(x: frame.maxX, y: frame.maxY)
                }
                RoundedRectangle(cornerRadius: 2, style: .continuous)
                    .fill(Color.white)
                    .overlay(RoundedRectangle(cornerRadius: 2, style: .continuous).strokeBorder(Theme.accent, lineWidth: 1.5))
                    .frame(width: 10, height: 10)
                    .frame(width: 22, height: 22)
                    .contentShape(Rectangle())
                    .gesture(areaResizeGesture(corner: corner, scale: scale))
                    .position(x: point.x * scale, y: point.y * scale)
            }
            HStack(spacing: 2) {
                Label("Textbereich", systemImage: "character.textbox")
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(Theme.textPrimary)
                    .padding(.horizontal, 7)
                separator
                IconButton(systemName: "arrow.uturn.backward", help: "Zurück in die Standardränder", size: 11.5, frameSize: 24) {
                    guard let current else { return }
                    app.setSlideTextArea(current.id, current.slide.id, nil, undoManager: undoManager)
                }
                .disabled(slide.textArea == nil)
                IconButton(systemName: "checkmark", help: "Fertig (esc)", size: 11.5, frameSize: 24) {
                    app.editingSlideTextArea = false
                    controller.focus()
                }
            }
            .padding(.horizontal, 4)
            .background(Capsule().fill(Theme.elevated))
            .overlay(Capsule().strokeBorder(Theme.strongBorder))
            .shadow(color: .black.opacity(0.35), radius: 8, y: 3)
            .fixedSize()
            .position(
                x: min(max(frame.midX * scale, 150), size.width - 150),
                y: frame.minY * scale > 44 ? frame.minY * scale - 24 : min(size.height - 20, frame.maxY * scale + 24)
            )
        }
    }

    private func areaMoveGesture(scale: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 2, coordinateSpace: .named(Self.space))
            .onChanged { value in
                if areaStart == nil { areaStart = slide.textFrame }
                guard var frame = areaStart else { return }
                frame.origin.x += value.translation.width / scale
                frame.origin.y += value.translation.height / scale
                let (snapped, lines) = snap(frame, tolerance: 5 / scale)
                guides = lines
                dragTextFrame = clampArea(snapped)
            }
            .onEnded { _ in commitArea() }
    }

    private func areaResizeGesture(corner: Corner, scale: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 1, coordinateSpace: .named(Self.space))
            .onChanged { value in
                if areaStart == nil { areaStart = slide.textFrame }
                guard let start = areaStart else { return }
                let dx = value.translation.width / scale
                let dy = value.translation.height / scale
                let left = corner == .topLeft || corner == .bottomLeft
                let top = corner == .topLeft || corner == .topRight
                let width = max(80, start.width + (left ? -dx : dx))
                let height = max(40, start.height + (top ? -dy : dy))
                dragTextFrame = CGRect(x: left ? start.maxX - width : start.minX, y: top ? start.maxY - height : start.minY, width: width, height: height)
            }
            .onEnded { _ in commitArea() }
    }

    private func commitArea() {
        guides = []
        areaStart = nil
        guard let frame = dragTextFrame, let current else { return }
        app.setSlideTextArea(current.id, current.slide.id, SlideArea(frame: frame), undoManager: undoManager)
        dragTextFrame = nil
    }

    /// The text area stays on the slide.
    private func clampArea(_ frame: CGRect) -> CGRect {
        var frame = frame
        frame.size.width = min(frame.width, canvas.width)
        frame.size.height = min(frame.height, canvas.height)
        frame.origin.x = min(max(0, frame.minX), canvas.width - frame.width)
        frame.origin.y = min(max(0, frame.minY), canvas.height - frame.height)
        return frame
    }

    // MARK: Snapping

    /// A picture may hang over the edge, but a fifth of it stays on the slide.
    private func clamp(_ frame: CGRect) -> CGRect {
        var frame = frame
        frame.origin.x = min(max(frame.minX, -frame.width * 0.8), canvas.width - frame.width * 0.2)
        frame.origin.y = min(max(frame.minY, -frame.height * 0.8), canvas.height - frame.height * 0.2)
        return frame
    }

    /// Pulls the frame to the slide's middle and to the text margins when it comes close.
    private func snap(_ frame: CGRect, tolerance: CGFloat) -> (CGRect, Guides) {
        var frame = frame
        var lines: Guides = []
        let xs: [(CGFloat, CGFloat, Guides)] = [
            (frame.midX, canvas.width / 2, .centerX),
            (frame.minX, margin.width, .marginLeft),
            (frame.maxX, canvas.width - margin.width, .marginRight),
        ]
        if let hit = xs.min(by: { abs($0.0 - $0.1) < abs($1.0 - $1.1) }), abs(hit.0 - hit.1) <= tolerance {
            frame.origin.x += hit.1 - hit.0
            lines.insert(hit.2)
        }
        let ys: [(CGFloat, CGFloat, Guides)] = [
            (frame.midY, canvas.height / 2, .centerY),
            (frame.minY, margin.height, .marginTop),
            (frame.maxY, canvas.height - margin.height, .marginBottom),
        ]
        if let hit = ys.min(by: { abs($0.0 - $0.1) < abs($1.0 - $1.1) }), abs(hit.0 - hit.1) <= tolerance {
            frame.origin.y += hit.1 - hit.0
            lines.insert(hit.2)
        }
        return (frame, lines)
    }

    private func guideLines(scale: CGFloat) -> some View {
        let vertical: [(Guides, CGFloat)] = [(.centerX, canvas.width / 2), (.marginLeft, margin.width), (.marginRight, canvas.width - margin.width)]
        let horizontal: [(Guides, CGFloat)] = [(.centerY, canvas.height / 2), (.marginTop, margin.height), (.marginBottom, canvas.height - margin.height)]
        return ZStack(alignment: .topLeading) {
            ForEach(vertical.filter { guides.contains($0.0) }, id: \.0.rawValue) { _, x in
                Rectangle().fill(Theme.accent.opacity(0.8)).frame(width: 1, height: canvas.height * scale).offset(x: x * scale)
            }
            ForEach(horizontal.filter { guides.contains($0.0) }, id: \.0.rawValue) { _, y in
                Rectangle().fill(Theme.accent.opacity(0.8)).frame(width: canvas.width * scale, height: 1).offset(y: y * scale)
            }
        }
        .allowsHitTesting(false)
    }

    // MARK: Keys

    private func installMonitor() {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .flagsChanged]) { event in
            if event.type == .flagsChanged {
                let held = event.modifierFlags.contains(.command)
                if held != commandHeld { commandHeld = held }
                return event
            }
            // esc ends the text-area mode, also while the slide's text has the keyboard.
            if event.keyCode == 53, app.editingSlideTextArea, app.writerTab == .document, event.window === controller.textView?.window {
                app.editingSlideTextArea = false
                return nil
            }
            // esc while writing in a text field: back to the slide's text, the field selected.
            if event.keyCode == 53, let id = app.editingSlideFieldID, app.writerTab == .document, app.speakingDocumentID == nil,
               let textView = controller.textView, event.window === textView.window, !textView.hasMarkedText(),
               let field = current?.slide.images.first(where: { $0.id == id }) {
                finishEditing(field)
                return nil
            }
            guard app.selectedSlideImageID != nil || app.editingSlideTextArea, let window = controller.textView?.window, event.window === window,
                  !(window.firstResponder is NSText), app.writerTab == .document else { return event }
            let step: CGFloat = event.modifierFlags.contains(.shift) ? 10 : 1
            switch event.keyCode {
            case 51, 117:
                if app.editingSlideTextArea { return event }
                if let id = app.selectedSlideImageID { delete(id) }
            case 123: nudge(by: CGSize(width: -step, height: 0))
            case 124: nudge(by: CGSize(width: step, height: 0))
            case 125: nudge(by: CGSize(width: 0, height: step))
            case 126: nudge(by: CGSize(width: 0, height: -step))
            case 53:
                app.selectedSlideImageID = nil
                app.editingSlideTextArea = false
                controller.focus()
            default:
                return event
            }
            return nil
        }
    }

    private func removeMonitor() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }
}
