import AppKit
import SwiftUI

// Pieces the project page, the board, the sidebar and the other studios share: fonts and colours of a page, the
// tiles of linked things and the picker that finds them.

// MARK: - Look

extension FolderColor {
    /// A soft fill for a block or a card in this colour.
    var wash: Color { color.opacity(0.12) }
}

enum ProjectLook {
    static let rowHeight: CGFloat = 44
    static let gap: CGFloat = 14
    /// Below this width the page stacks its blocks.
    static let stackedWidth: CGFloat = 640

    /// The font of a block's text: the block's own style over the page's typeface.
    static func font(_ style: ProjectTextStyle, page: ProjectDesign, size: CGFloat, weight: NSFont.Weight = .regular) -> NSFont {
        let family = style.font ?? page.font
        let size = style.size.map { CGFloat($0) } ?? size
        let weight = style.bold ? max(weight, .bold) : weight
        return WriterStyler.font(family, size: size, weight: weight, italic: style.italic)
    }

    static func color(_ style: ProjectTextStyle) -> Color {
        style.color?.color ?? Theme.textPrimary
    }

    static func alignment(_ style: ProjectTextStyle) -> NSTextAlignment {
        switch style.alignment {
        case .leading: .natural
        case .center: .center
        case .trailing: .right
        }
    }

    static func horizontal(_ style: ProjectTextStyle) -> HorizontalAlignment {
        switch style.alignment {
        case .leading: .leading
        case .center: .center
        case .trailing: .trailing
        }
    }

    /// The handwriting of sticky notes, when the note has no font of its own.
    static func stickyFont(_ style: ProjectTextStyle, page: ProjectDesign) -> NSFont {
        if style.font == nil, let font = NSFont(name: style.bold ? "Noteworthy-Bold" : "Noteworthy-Light", size: CGFloat(style.size ?? 15)) { return font }
        return font(style, page: page, size: 15)
    }
}

extension NSFont.Weight: @retroactive Comparable {
    public static func < (lhs: NSFont.Weight, rhs: NSFont.Weight) -> Bool { lhs.rawValue < rhs.rawValue }
}

/// The page's background behind the blocks.
struct ProjectPageBackground: View {
    let design: ProjectDesign
    let accent: Color

    var body: some View {
        switch design.background {
        case .plain:
            Theme.background
        case .paper:
            Theme.dynamic(dark: 0x15130F, light: 0xFBF7EE)
        case .gradient:
            LinearGradient(colors: [accent.opacity(0.16), Theme.background, accent.opacity(0.06)], startPoint: .topLeading, endPoint: .bottomTrailing)
                .background(Theme.background)
        case .dots:
            Canvas { context, size in
                let step: CGFloat = 18
                for x in stride(from: step / 2, through: size.width, by: step) {
                    for y in stride(from: step / 2, through: size.height, by: step) {
                        context.fill(Path(ellipseIn: CGRect(x: x - 0.9, y: y - 0.9, width: 1.8, height: 1.8)), with: .color(Theme.ink.opacity(0.13)))
                    }
                }
            }
            .background(Theme.background)
        case .blueprint:
            Canvas { context, size in
                let step: CGFloat = 24
                var grid = Path()
                for x in stride(from: 0, through: size.width, by: step) { grid.move(to: CGPoint(x: x, y: 0)); grid.addLine(to: CGPoint(x: x, y: size.height)) }
                for y in stride(from: 0, through: size.height, by: step) { grid.move(to: CGPoint(x: 0, y: y)); grid.addLine(to: CGPoint(x: size.width, y: y)) }
                context.stroke(grid, with: .color(accent.opacity(0.13)), lineWidth: 0.6)
            }
            .background(LinearGradient(colors: [accent.opacity(0.10), Theme.background], startPoint: .top, endPoint: .bottom))
            .background(Theme.background)
        }
    }
}

/// The project's symbol on its colour, as in the sidebar and the head of the page.
struct ProjectBadge: View {
    let project: Project
    var size: CGFloat = 18

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: size * 0.3, style: .continuous)
                .fill(LinearGradient(colors: [project.color.color, project.color.color.opacity(0.7)], startPoint: .topLeading, endPoint: .bottomTrailing))
            Image(systemName: project.symbol)
                .font(.system(size: size * 0.52, weight: .semibold))
                .foregroundStyle(.white)
        }
        .frame(width: size, height: size)
    }
}

/// Colours to choose from, as a row of dots; `allowsNone` adds "Standard".
struct ProjectColorRow: View {
    let selection: FolderColor?
    var allowsNone = true
    let onPick: (FolderColor?) -> Void

    var body: some View {
        HStack(spacing: 6) {
            if allowsNone {
                swatch(nil)
            }
            ForEach(FolderColor.allCases, id: \.self) { swatch($0) }
        }
    }

    private func swatch(_ color: FolderColor?) -> some View {
        Button {
            onPick(color)
        } label: {
            Circle()
                .fill(color?.color ?? Theme.textPrimary)
                .frame(width: 16, height: 16)
                .overlay(Circle().strokeBorder(Theme.ink.opacity(0.2)))
                .overlay {
                    if selection == color {
                        Circle().strokeBorder(Theme.accent, lineWidth: 2).padding(-3)
                    }
                }
        }
        .buttonStyle(.plain)
        .help(color?.name ?? "Standard")
    }
}

/// A day chip that opens a calendar; with "Entfernen" when the day is optional.
struct ProjectDayButton: View {
    let date: Date?
    var placeholder = "Termin"
    var symbol = "calendar"
    var warnsWhenPast = true
    let onChange: (Date?) -> Void
    @State private var picking = false
    @State private var draft = Date()

    var body: some View {
        Button {
            draft = date ?? Date()
            picking = true
        } label: {
            HStack(spacing: 4) {
                Image(systemName: symbol)
                    .font(.system(size: 9.5, weight: .semibold))
                Text(date.map { ProjectDay.label($0, short: true) } ?? placeholder)
                    .font(.system(size: 11, weight: .medium).monospacedDigit())
            }
            .foregroundStyle(tint)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(Capsule().fill(tint.opacity(date == nil ? 0.0 : 0.12)))
            .overlay(Capsule().strokeBorder(date == nil ? Theme.border : .clear))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .help(date.map { "\(ProjectDay.label($0)) – \(ProjectDay.countdown($0))" } ?? "Termin wählen")
        .popover(isPresented: $picking, arrowEdge: .bottom) {
            VStack(alignment: .leading, spacing: 10) {
                DatePicker("", selection: $draft, displayedComponents: .date)
                    .datePickerStyle(.graphical)
                    .labelsHidden()
                HStack {
                    if date != nil {
                        Button("Entfernen", role: .destructive) {
                            onChange(nil)
                            picking = false
                        }
                    }
                    Spacer()
                    Button("Übernehmen") {
                        onChange(ProjectDay.normalized(draft))
                        picking = false
                    }
                    .keyboardShortcut(.defaultAction)
                }
            }
            .padding(12)
            .frame(width: 250)
        }
    }

    private var tint: Color {
        guard let date else { return Theme.textTertiary }
        let days = ProjectDay.days(until: date)
        if warnsWhenPast, days < 0 { return Theme.danger }
        if warnsWhenPast, days <= 2 { return Theme.warning }
        return Theme.textSecondary
    }
}

// MARK: - Linked things

/// A linked thing as a tile: symbol, title, kind and state; a deleted one says so and offers to remove the link.
struct ProjectRefTile: View {
    @Environment(AppModel.self) private var app
    let ref: ProjectRef
    var note: String?
    var compact = false
    var onRemove: (() -> Void)?
    @State private var hovering = false

    var body: some View {
        let title = app.projectRefTitle(ref)
        HStack(spacing: 9) {
            ZStack {
                RoundedRectangle(cornerRadius: 7, style: .continuous).fill((title == nil ? Theme.danger : Theme.accent).opacity(0.13))
                if let progress = app.projectRefProgress(ref), progress.total > 0 {
                    NoteMiniRing(progress: progress, size: compact ? 15 : 18)
                } else {
                    Image(systemName: title == nil ? "questionmark.square.dashed" : app.projectRefSymbol(ref))
                        .font(.system(size: compact ? 11 : 12.5, weight: .medium))
                        .foregroundStyle(title == nil ? Theme.danger : Theme.accent)
                }
            }
            .frame(width: compact ? 24 : 30, height: compact ? 24 : 30)
            VStack(alignment: .leading, spacing: 1) {
                Text(title ?? "Gelöscht")
                    .font(.system(size: compact ? 12 : 12.5, weight: .medium))
                    .foregroundStyle(title == nil ? Theme.textTertiary : Theme.textPrimary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(subtitle(exists: title != nil))
                    .font(.system(size: 10.5))
                    .foregroundStyle(Theme.textTertiary)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
            if let onRemove, hovering || title == nil {
                IconButton(systemName: "xmark", help: "Verknüpfung lösen; das Verknüpfte bleibt", size: 9.5, frameSize: 20) { onRemove() }
            }
        }
        .padding(.horizontal, 7)
        .padding(.vertical, compact ? 4 : 6)
        .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(hovering ? Theme.hover : Theme.ink.opacity(0.025)))
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture { app.openProjectRef(ref) }
        .help(title == nil ? "Das Verknüpfte gibt es nicht mehr." : "Öffnen: \(title ?? "")")
    }

    private func subtitle(exists: Bool) -> String {
        guard exists else { return "\(app.projectRefKind(ref)) wurde gelöscht" }
        let pieces = [app.projectRefKind(ref), app.projectRefDetail(ref), note].compactMap { $0 }
        return pieces.joined(separator: " · ")
    }
}

/// Finds a chat, document, presentation, note, novel world, part or story element to link.
struct ProjectRefPicker: View {
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    var excluded: Set<ProjectRef> = []
    let onPick: (ProjectRef) -> Void
    @State private var query = ""
    @State private var kind: Kind = .all

    enum Kind: String, CaseIterable, Identifiable {
        case all, chats, documents, presentations, notes, stories
        var id: String { rawValue }
        var title: String {
            switch self {
            case .all: "Alle"
            case .chats: "Chats"
            case .documents: "Dokumente"
            case .presentations: "Folien"
            case .notes: "Notes"
            case .stories: "Stories"
            }
        }
    }

    struct Item: Identifiable {
        let ref: ProjectRef
        let title: String
        let subtitle: String
        let symbol: String
        var id: String { "\(ref.art)|\(ref.targetID)" }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Verknüpfen")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Theme.textPrimary)
            SearchField(text: $query, prompt: "Chats, Dokumente, Notes, Romanwelten …")
            Picker("", selection: $kind) {
                ForEach(Kind.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 1) {
                    let items = self.items
                    ForEach(items) { item in
                        Button {
                            onPick(item.ref)
                            dismiss()
                        } label: {
                            HStack(spacing: 9) {
                                Image(systemName: item.symbol)
                                    .font(.system(size: 12))
                                    .foregroundStyle(Theme.accent)
                                    .frame(width: 18)
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(item.title)
                                        .font(.system(size: 12.5, weight: .medium))
                                        .foregroundStyle(Theme.textPrimary)
                                        .lineLimit(1)
                                    Text(item.subtitle)
                                        .font(.system(size: 10.5))
                                        .foregroundStyle(Theme.textTertiary)
                                        .lineLimit(1)
                                }
                                Spacer(minLength: 0)
                            }
                            .padding(.horizontal, 8)
                            .padding(.vertical, 5)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(StoryRowButtonStyle())
                    }
                    if items.isEmpty {
                        Text(query.isEmpty ? "Nichts zum Verknüpfen." : "Nichts passt zur Suche.")
                            .font(.system(size: 12))
                            .foregroundStyle(Theme.textTertiary)
                            .padding(10)
                    }
                }
            }
            .frame(height: 300)
        }
        .padding(14)
        .frame(width: 380)
        .onAppear {
            app.notes.loadIfNeeded()
            app.stories.loadIfNeeded()
        }
    }

    private var items: [Item] {
        let query = query.trimmingCharacters(in: .whitespaces)
        func fits(_ text: String) -> Bool { query.isEmpty || text.localizedStandardContains(query) }
        var result: [Item] = []
        if kind == .all || kind == .chats {
            result += app.chats.filter { fits($0.title) }.prefix(query.isEmpty && kind == .all ? 6 : 200)
                .map { Item(ref: .chat($0.id), title: $0.title, subtitle: "Chat · \($0.updatedAt.formatted(date: .abbreviated, time: .omitted))", symbol: "bubble.left") }
        }
        if kind == .all || kind == .documents || kind == .presentations {
            let documents = app.documents.filter { document in
                (kind == .all || (kind == .presentations) == document.isPresentation) && fits(document.displayTitle)
            }
            result += documents.prefix(query.isEmpty && kind == .all ? 8 : 300).map { document in
                Item(ref: .document(document.id), title: document.displayTitle, subtitle: document.isPresentation ? "Präsentation" : "Dokument",
                     symbol: document.isPresentation ? StudioApplication.presenter.symbol : StudioApplication.writer.symbol)
            }
        }
        if kind == .all || kind == .notes {
            result += app.notes.notes.filter { fits($0.displayTitle) }.prefix(query.isEmpty && kind == .all ? 6 : 200)
                .map { Item(ref: .note($0.id), title: $0.displayTitle, subtitle: "Note · \($0.progress.label)", symbol: "checklist") }
        }
        if kind == .all || kind == .stories {
            for world in app.stories.worlds {
                if fits(world.displayTitle) {
                    result.append(Item(ref: .story(world: world.id, part: nil, element: nil), title: world.displayTitle, subtitle: "Romanwelt", symbol: StudioApplication.stories.symbol))
                }
                // Parts and elements show when searching, or when only novel worlds are listed.
                guard !query.isEmpty || kind == .stories else { continue }
                for entry in world.allParts where fits(entry.path) {
                    result.append(Item(ref: .story(world: world.id, part: entry.part.id, element: nil), title: entry.path,
                                       subtitle: "\(entry.part.level.label) in \(world.displayTitle)", symbol: entry.part.level.symbol))
                }
                for kind in StoryElementKind.listOrder {
                    for element in world.summaries(of: kind) where fits(element.name) {
                        result.append(Item(ref: .story(world: world.id, part: nil, element: StoryRef(kind: kind, id: element.id)), title: element.name,
                                           subtitle: "\(kind.singular) in \(world.displayTitle)", symbol: kind.symbol))
                    }
                }
            }
        }
        return result.filter { !excluded.contains($0.ref) }
    }
}

/// "+ Verknüpfen" with the picker in a popover.
struct ProjectLinkAddButton: View {
    var title = "Verknüpfen"
    var excluded: Set<ProjectRef> = []
    let onPick: (ProjectRef) -> Void
    @Environment(AppModel.self) private var app
    @State private var picking = false

    var body: some View {
        Button {
            picking = true
        } label: {
            Label(title, systemImage: "link")
                .font(.system(size: 11.5, weight: .medium))
                .foregroundStyle(Theme.accent)
        }
        .buttonStyle(.plain)
        .popover(isPresented: $picking, arrowEdge: .bottom) {
            ProjectRefPicker(excluded: excluded, onPick: onPick)
                .environment(app)
        }
    }
}

// MARK: - Drag payloads

/// What the board and the page drag: tasks and to-dos of a project, as text with a prefix (like the sidebar).
enum ProjectDrag {
    static let task = "llmd-projekt-aufgabe:"

    static func payload(_ id: UUID) -> String { task + id.uuidString }

    static func taskID(in items: [String]) -> UUID? {
        items.lazy.compactMap { item in item.hasPrefix(task) ? UUID(uuidString: String(item.dropFirst(task.count))) : nil }.first
    }
}
