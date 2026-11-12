import SwiftUI

/// The blocks of a page on their grid. While the page is being arranged, each block has a grip to move it and a knob
/// to resize it; the others make room live, and the block snaps to the grid when let go.
struct ProjectGrid: View {
    @Environment(AppModel.self) private var app
    @Environment(\.undoManager) private var undoManager
    let projectID: UUID
    let width: CGFloat
    @State private var drag: Drag?

    struct Drag: Equatable {
        enum Mode { case move, resize }
        let id: UUID
        let mode: Mode
        var translation: CGSize
    }

    private var gap: CGFloat { ProjectLook.gap }
    private var rowHeight: CGFloat { ProjectLook.rowHeight }
    private var columnWidth: CGFloat { (width - CGFloat(ProjectGridFrame.columns - 1) * gap) / CGFloat(ProjectGridFrame.columns) }
    private var stacked: Bool { width < ProjectLook.stackedWidth }

    var body: some View {
        if let project = app.projects.project(projectID) {
            let editing = app.projectPageEditing
            if stacked {
                // Narrow: one column, in the page's order.
                VStack(spacing: gap) {
                    ForEach(project.blocks) { block in
                        card(block, project: project, editing: editing)
                            .frame(height: height(rows: block.frame.height))
                            .id(block.id)
                    }
                }
            } else {
                let shown = layout(project.blocks)
                let rows = max(ProjectLayout.rows(of: shown) + (editing ? 2 : 0), 1)
                ZStack(alignment: .topLeading) {
                    if editing { gridGuides(rows: rows) }
                    if let drag, let ghost = shown.first(where: { $0.id == drag.id }) {
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .fill(project.accent.color.opacity(0.10))
                            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(project.accent.color.opacity(0.55), style: StrokeStyle(lineWidth: 1.5, dash: [6, 4])))
                            .frame(width: rect(ghost.frame).width, height: rect(ghost.frame).height)
                            .offset(x: rect(ghost.frame).minX, y: rect(ghost.frame).minY)
                    }
                    ForEach(project.blocks) { block in
                        let frame = displayRect(block, shown: shown)
                        card(block, project: project, editing: editing)
                            .frame(width: frame.width, height: frame.height)
                            .offset(x: frame.minX, y: frame.minY)
                            .zIndex(drag?.id == block.id ? 2 : 0)
                            .shadow(color: drag?.id == block.id ? Theme.shade.opacity(0.35) : .clear, radius: 16, y: 8)
                            .id(block.id)
                    }
                }
                .frame(width: width, height: height(rows: rows), alignment: .topLeading)
                .animation(.snappy(duration: 0.22), value: shown.map(\.frame))
            }
        }
    }

    private func card(_ block: ProjectBlock, project: Project, editing: Bool) -> some View {
        ProjectBlockCard(projectID: projectID, block: block, project: project, editing: editing)
            .overlay(alignment: .top) {
                if editing { moveGrip(block) }
            }
            .overlay(alignment: .bottomTrailing) {
                if editing, !stacked { resizeKnob(block) }
            }
    }

    // MARK: Geometry

    private func height(rows: Int) -> CGFloat {
        CGFloat(rows) * rowHeight + CGFloat(max(rows - 1, 0)) * gap
    }

    private func rect(_ frame: ProjectGridFrame) -> CGRect {
        CGRect(x: CGFloat(frame.x) * (columnWidth + gap), y: CGFloat(frame.y) * (rowHeight + gap),
               width: CGFloat(frame.width) * columnWidth + CGFloat(frame.width - 1) * gap, height: height(rows: frame.height))
    }

    /// Where the blocks would land if the drag ended now.
    private func layout(_ blocks: [ProjectBlock]) -> [ProjectBlock] {
        guard let drag, let index = blocks.firstIndex(where: { $0.id == drag.id }) else { return blocks }
        var blocks = blocks
        blocks[index].frame = snapped(blocks[index].frame, drag)
        return ProjectLayout.place(blocks, moving: drag.id)
    }

    private func snapped(_ frame: ProjectGridFrame, _ drag: Drag) -> ProjectGridFrame {
        let stepX = columnWidth + gap
        let stepY = rowHeight + gap
        switch drag.mode {
        case .move:
            return ProjectGridFrame(x: frame.x + Int((drag.translation.width / stepX).rounded()), y: frame.y + Int((drag.translation.height / stepY).rounded()),
                                    width: frame.width, height: frame.height)
        case .resize:
            return ProjectGridFrame(x: frame.x, y: frame.y, width: frame.width + Int((drag.translation.width / stepX).rounded()),
                                    height: frame.height + Int((drag.translation.height / stepY).rounded()))
        }
    }

    /// The dragged block follows the mouse; the others stand where they would land.
    private func displayRect(_ block: ProjectBlock, shown: [ProjectBlock]) -> CGRect {
        guard let drag, drag.id == block.id else {
            return rect(shown.first { $0.id == block.id }?.frame ?? block.frame)
        }
        var base = rect(block.frame)
        switch drag.mode {
        case .move:
            base = base.offsetBy(dx: drag.translation.width, dy: drag.translation.height)
        case .resize:
            base.size.width = max(columnWidth, base.width + drag.translation.width)
            base.size.height = max(rowHeight, base.height + drag.translation.height)
        }
        return base
    }

    private func gridGuides(rows: Int) -> some View {
        Canvas { context, size in
            for column in 0..<ProjectGridFrame.columns {
                let x = CGFloat(column) * (columnWidth + gap)
                context.fill(Path(roundedRect: CGRect(x: x, y: 0, width: columnWidth, height: size.height), cornerRadius: 6), with: .color(Theme.ink.opacity(0.025)))
            }
        }
        .frame(width: width, height: height(rows: rows))
        .allowsHitTesting(false)
    }

    // MARK: Handles

    private func gesture(_ block: ProjectBlock, _ mode: Drag.Mode) -> some Gesture {
        DragGesture(minimumDistance: 2, coordinateSpace: .global)
            .onChanged { value in
                drag = Drag(id: block.id, mode: mode, translation: value.translation)
            }
            .onEnded { value in
                let final = snapped(block.frame, Drag(id: block.id, mode: mode, translation: value.translation))
                drag = nil
                guard final != block.frame else { return }
                app.projects.change(projectID, mode == .move ? "Baustein verschieben" : "Baustein vergrößern", undo: undoManager) { project in
                    project.updateBlock(block.id) { $0.frame = final }
                }
            }
    }

    private func moveGrip(_ block: ProjectBlock) -> some View {
        Capsule()
            .fill(Theme.ink.opacity(0.22))
            .frame(width: 34, height: 5)
            .padding(.vertical, 5)
            .padding(.horizontal, 30)
            .contentShape(Rectangle())
            .pointerStyle(.grabIdle)
            .gesture(stacked ? nil : gesture(block, .move))
            .help(stacked ? "Im schmalen Fenster stehen die Bausteine untereinander" : "Ziehen, um den Baustein zu verschieben")
    }

    private func resizeKnob(_ block: ProjectBlock) -> some View {
        Image(systemName: "arrow.down.right")
            .font(.system(size: 9, weight: .bold))
            .foregroundStyle(Theme.textSecondary)
            .frame(width: 18, height: 18)
            .background(Circle().fill(Theme.elevated))
            .overlay(Circle().strokeBorder(Theme.strongBorder))
            .padding(4)
            .contentShape(Rectangle())
            // On the corner itself, so it doesn't cover the block's own buttons.
            .offset(x: 9, y: 9)
            .pointerStyle(.frameResize(position: .bottomTrailing))
            .gesture(gesture(block, .resize))
            .help("Ziehen, um Breite und Höhe zu ändern")
    }
}

/// A block's card: its frame, heading and content; while arranging, the buttons to style, copy and remove it.
struct ProjectBlockCard: View {
    @Environment(AppModel.self) private var app
    @Environment(\.undoManager) private var undoManager
    let projectID: UUID
    let block: ProjectBlock
    let project: Project
    let editing: Bool
    @State private var inspecting = false
    @State private var hovering = false

    var body: some View {
        let sticky = block.kind == .sticky
        let tint = block.tint?.color
        VStack(alignment: .leading, spacing: 8) {
            if !block.headline.isEmpty {
                HStack(spacing: 6) {
                    Image(systemName: block.kind == .chart ? (block.chart?.kind.symbol ?? block.kind.symbol) : block.kind.symbol)
                        .font(.system(size: 10.5, weight: .semibold))
                        .foregroundStyle(tint ?? project.accent.color)
                    Text(block.headline)
                        .font(Font(WriterStyler.font(project.design.font, size: 12.5, weight: .semibold)))
                        .foregroundStyle(Theme.textSecondary)
                        .lineLimit(1)
                    Spacer(minLength: 0)
                }
            }
            ProjectBlockContent(projectID: projectID, block: block, project: project)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .padding(.horizontal, block.kind == .text ? 6 : 14)
        .padding(.vertical, block.kind == .text ? 4 : 12)
        // Text and sticky notes have no heading: while arranging, their tools need a line of their own.
        .padding(.top, editing && block.headline.isEmpty ? 24 : 0)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background {
            if sticky {
                StickyPaper(color: block.tint ?? .yellow)
            } else if block.kind != .text {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(Theme.surface.opacity(0.92))
                    .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(tint?.opacity(0.07) ?? .clear))
            } else if editing {
                RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Theme.ink.opacity(0.025))
            }
        }
        .overlay {
            if !sticky && (block.kind != .text || editing) {
                RoundedRectangle(cornerRadius: block.kind == .text ? 10 : 14, style: .continuous)
                    .strokeBorder(editing && hovering ? project.accent.color.opacity(0.6) : (tint?.opacity(0.35) ?? Theme.border), lineWidth: editing && hovering ? 1.5 : 1)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(alignment: .topTrailing) {
            if editing { tools.padding(6) }
        }
        .onHover { hovering = $0 }
        .contextMenu {
            Button("Gestalten …", systemImage: "slider.horizontal.3") { inspecting = true }
            Button("Duplizieren", systemImage: "plus.square.on.square") { duplicate() }
            Divider()
            Button("Baustein entfernen", systemImage: "trash", role: .destructive) { remove() }
        }
        .popover(isPresented: $inspecting, arrowEdge: .trailing) {
            ProjectBlockInspector(projectID: projectID, blockID: block.id)
                .environment(app)
        }
    }

    private var tools: some View {
        HStack(spacing: 2) {
            IconButton(systemName: "slider.horizontal.3", help: "Baustein gestalten: Titel, Schrift, Farbe, Inhalt", size: 11, frameSize: 22) { inspecting = true }
            IconButton(systemName: "plus.square.on.square", help: "Duplizieren", size: 11, frameSize: 22) { duplicate() }
            IconButton(systemName: "trash", help: "Baustein entfernen (⌘Z holt ihn zurück)", size: 11, frameSize: 22) { remove() }
        }
        .padding(2)
        .background(Capsule().fill(Theme.elevated))
        .overlay(Capsule().strokeBorder(Theme.border))
        .opacity(hovering || inspecting ? 1 : 0.55)
    }

    private func duplicate() {
        app.projects.change(projectID, "Baustein duplizieren", undo: undoManager) { project in
            var copy = block
            copy.id = UUID()
            copy.frame = ProjectLayout.freeFrame(width: block.frame.width, height: block.frame.height, in: project.blocks)
            project.blocks.append(copy)
            project.blocks = ProjectLayout.place(project.blocks, moving: copy.id)
        }
    }

    private func remove() {
        app.projects.change(projectID, "Baustein entfernen", undo: undoManager) { $0.blocks.removeAll { $0.id == block.id } }
    }
}

/// A sticky note's paper: a little curled at the corner, with a soft shadow.
private struct StickyPaper: View {
    let color: FolderColor

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            Rectangle()
                .fill(LinearGradient(colors: [color.color.opacity(0.55), color.color.opacity(0.38)], startPoint: .top, endPoint: .bottom))
            LinearGradient(colors: [.clear, Theme.shade.opacity(0.18)], startPoint: .topLeading, endPoint: .bottomTrailing)
                .frame(width: 26, height: 26)
                .clipShape(Triangle())
        }
        .background(Theme.surface)
    }

    private struct Triangle: Shape {
        func path(in rect: CGRect) -> Path {
            Path { path in
                path.move(to: CGPoint(x: rect.maxX, y: rect.minY))
                path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
                path.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
                path.closeSubpath()
            }
        }
    }
}
