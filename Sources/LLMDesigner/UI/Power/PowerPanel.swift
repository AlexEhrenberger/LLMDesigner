import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// The power access in the right-hand panel: a small version of each application (chats, documents, presentations,
/// sources and quotes, novel worlds) next to what is open in the main area. Everything here is text to drag out, into
/// the document, a slide or the chat; text dragged in becomes blocks, slides, quotes or story elements.
struct PowerPanel: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        @Bindable var power = app.power
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                Image(systemName: "bolt.fill")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Theme.accent)
                Text("Power-Zugriff")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Theme.textPrimary)
                Spacer(minLength: 0)
                IconButton(systemName: "list.bullet.indent", help: "Zurück zum Inhaltsverzeichnis", size: 13, frameSize: Theme.titleBarControlSize) {
                    app.togglePower()
                }
                IconButton(systemName: "sidebar.right", help: "Seitenleiste ausblenden (⌥⌘I)", frameSize: Theme.titleBarControlSize) {
                    app.toggleOutlinePanel()
                }
            }
            .padding(.horizontal, 12)
            .frame(height: Theme.titleBarHeight)
            .padding(.bottom, Theme.topBarBottomPadding)
            .background(WindowDragArea())

            PowerModulePicker()
                .padding(.horizontal, 10)
                .padding(.bottom, 8)
            SearchField(text: $power.query, prompt: searchPrompt)
                .padding(.horizontal, 10)
                .padding(.bottom, 8)

            Group {
                switch power.module {
                case .chats: PowerChats()
                case .writer: PowerDocuments()
                case .presenter: PowerPresentations()
                case .citation: PowerCitations()
                case .stories: PowerStories()
                case .notes: PowerNotes()
                case .podcasts: PowerPodcasts()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)

            if let change = power.lastChange {
                PowerUndoBar(change: change)
            }
        }
        .background(Theme.sidebar)
        .overlay(alignment: .leading) {
            Rectangle().fill(Theme.border).frame(width: 1)
        }
        .onChange(of: power.module) { _, _ in power.query = "" }
    }

    private var searchPrompt: String {
        let power = app.power
        if power.hasOpenItem {
            switch power.module {
            case .citation: return "In den Zitaten suchen"
            case .stories: return "In der Romanwelt suchen"
            case .notes: return "Alle Notes durchsuchen"
            case .podcasts: return "Im Skript suchen"
            case .presenter: return "In den Folien suchen"
            default: return "Im Text suchen"
            }
        }
        switch power.module {
        case .chats: return "Chats durchsuchen"
        case .writer: return "Dokumente durchsuchen"
        case .presenter: return "Präsentationen durchsuchen"
        case .citation: return "Quellen und Zitate durchsuchen"
        case .stories: return "Romanwelten durchsuchen"
        case .notes: return "Alle Notes durchsuchen"
        case .podcasts: return "Podcasts durchsuchen"
        }
    }
}

/// Chats, Writer, Presenter, Citation, Stories, Notes, Podcasts.
private struct PowerModulePicker: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        HStack(spacing: 2) {
            ForEach(PowerModule.allCases) { module in
                let isSelected = app.power.module == module
                Button {
                    app.power.module = module
                } label: {
                    VStack(spacing: 2) {
                        Image(systemName: module.symbol)
                            .font(.system(size: 12, weight: .medium))
                        Text(module.title)
                            .font(.system(size: 10, weight: isSelected ? .semibold : .medium))
                            .lineLimit(1)
                    }
                    .foregroundStyle(isSelected ? Theme.textPrimary : Theme.textTertiary)
                    .frame(maxWidth: .infinity)
                    .frame(height: 38)
                    .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(isSelected ? Theme.ink.opacity(0.08) : .clear))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(module.title)
            }
        }
        .padding(3)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Theme.ink.opacity(0.03)))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Theme.border))
    }
}

/// The last change made in the panel, to take back.
private struct PowerUndoBar: View {
    @Environment(AppModel.self) private var app
    let change: PowerAccess.Change

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(Theme.accent)
            Text(change.label)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Theme.textSecondary)
            Spacer(minLength: 0)
            Button("Rückgängig") {
                change.undo()
                app.power.lastChange = nil
            }
            .buttonStyle(.plain)
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(Theme.accent)
            IconButton(systemName: "xmark", help: "Schließen", size: 10, frameSize: 22) { app.power.lastChange = nil }
        }
        .padding(.horizontal, 12)
        .frame(height: 36)
        .background(Theme.elevated)
        .overlay(alignment: .top) { Rectangle().fill(Theme.border).frame(height: 1) }
        .task(id: change.id) {
            try? await Task.sleep(for: .seconds(12))
            if app.power.lastChange?.id == change.id { app.power.lastChange = nil }
        }
    }
}

// MARK: - Dragging

/// Text going out of the panel and coming in: Writer Studio's Markdown (the editor keeps its formatting, a citation
/// becomes a pill) next to plain text for every other place; blocks moved within the panel carry where they came from.
enum PowerDrag {
    static let markdownType = UTType(importedAs: NSPasteboard.PasteboardType.writerMarkdown.rawValue, conformingTo: .data)
    static let blockType = UTType(importedAs: "app.llmdesigner.power-block", conformingTo: .data)
    static let accepted: [UTType] = [markdownType, blockType, .utf8PlainText, .plainText]

    static func provider(markdown: String, plain: String, block: String? = nil) -> NSItemProvider {
        let provider = NSItemProvider(object: plain as NSString)
        provider.registerDataRepresentation(forTypeIdentifier: markdownType.identifier, visibility: .all) { completion in
            completion(Data(markdown.utf8), nil)
            return nil
        }
        if let block {
            provider.registerDataRepresentation(forTypeIdentifier: blockType.identifier, visibility: .all) { completion in
                completion(Data(block.utf8), nil)
                return nil
            }
        }
        return provider
    }

    /// What was dropped: Markdown if there is some, else plain text; and the block it is, when it came from the panel.
    struct Dropped {
        var markdown: String
        var block: String?
    }

    static func load(_ providers: [NSItemProvider], _ done: @escaping @MainActor (Dropped) -> Void) -> Bool {
        guard let provider = providers.first else { return false }
        func string(_ type: UTType, _ next: @escaping (String?) -> Void) {
            guard provider.hasItemConformingToTypeIdentifier(type.identifier) else { return next(nil) }
            provider.loadDataRepresentation(forTypeIdentifier: type.identifier) { data, _ in
                next(data.flatMap { String(data: $0, encoding: .utf8) })
            }
        }
        string(blockType) { block in
            string(markdownType) { markdown in
                if let markdown, !markdown.isEmpty {
                    DispatchQueue.main.async { MainActor.assumeIsolated { done(Dropped(markdown: markdown, block: block)) } }
                    return
                }
                string(.utf8PlainText) { plain in
                    if let plain, !plain.isEmpty {
                        DispatchQueue.main.async { MainActor.assumeIsolated { done(Dropped(markdown: PowerText.markdown(fromPlain: plain), block: block)) } }
                        return
                    }
                    string(.plainText) { plain in
                        guard let plain, !plain.isEmpty else { return }
                        DispatchQueue.main.async { MainActor.assumeIsolated { done(Dropped(markdown: PowerText.markdown(fromPlain: plain), block: block)) } }
                    }
                }
            }
        }
        return true
    }
}

// MARK: - Shared pieces

/// The bar over an open item: back to the list, its name, opening it in the main area.
struct PowerItemBar: View {
    let title: String
    var symbol: String?
    var openHelp: String?
    let onBack: () -> Void
    var onOpen: (() -> Void)?

    var body: some View {
        HStack(spacing: 4) {
            IconButton(systemName: "chevron.left", help: "Zurück zur Liste", size: 12, frameSize: 26, action: onBack)
            if let symbol {
                Image(systemName: symbol)
                    .font(.system(size: 11.5))
                    .foregroundStyle(Theme.textTertiary)
            }
            Text(title)
                .font(.system(size: 12.5, weight: .semibold))
                .foregroundStyle(Theme.textPrimary)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 0)
            if let onOpen {
                IconButton(systemName: "arrow.up.left.and.arrow.down.right", help: openHelp ?? "Groß öffnen", size: 11.5, frameSize: 26, action: onOpen)
            }
        }
        .padding(.horizontal, 8)
        .padding(.bottom, 6)
    }
}

/// One row of a list: a name, a line below it, maybe a piece of text where the search found it.
struct PowerListRow: View {
    let title: String
    var subtitle = ""
    var snippet: String?
    var symbol: String
    var isCurrent = false
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(alignment: .top, spacing: 9) {
                Image(systemName: symbol)
                    .font(.system(size: 12))
                    .foregroundStyle(isCurrent ? Theme.accent : Theme.textTertiary)
                    .frame(width: 16)
                    .padding(.top, 1)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.system(size: 12.5, weight: .medium))
                        .foregroundStyle(Theme.textPrimary)
                        .lineLimit(1)
                    if !subtitle.isEmpty {
                        Text(subtitle)
                            .font(.system(size: 11))
                            .foregroundStyle(Theme.textTertiary)
                            .lineLimit(1)
                    }
                    if let snippet {
                        Text(snippet)
                            .font(.system(size: 11))
                            .foregroundStyle(Theme.textSecondary)
                            .lineLimit(2)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(hovering ? Theme.hover : .clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

/// A place to drop text on, with a hint; it lights up while something is over it.
struct PowerDropZone: View {
    let title: String
    var symbol = "plus"
    let onDrop: (PowerDrag.Dropped) -> Void
    @State private var targeted = false

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: symbol)
                .font(.system(size: 11, weight: .semibold))
            Text(title)
                .font(.system(size: 11.5, weight: .medium))
        }
        .foregroundStyle(targeted ? Theme.textPrimary : Theme.textTertiary)
        .frame(maxWidth: .infinity)
        .frame(height: 34)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(targeted ? Theme.accent.opacity(0.18) : Theme.ink.opacity(0.02)))
        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(targeted ? Theme.accent : Theme.border, style: StrokeStyle(lineWidth: 1, dash: [4, 3])))
        .onDrop(of: PowerDrag.accepted, isTargeted: $targeted) { providers in
            PowerDrag.load(providers, onDrop)
        }
    }
}

/// Text with the search's places marked.
func powerHighlighted(_ text: String, _ query: String) -> AttributedString {
    var result = AttributedString(text)
    let query = query.trimmingCharacters(in: .whitespaces)
    guard !query.isEmpty else { return result }
    var searchRange = text.startIndex..<text.endIndex
    while let found = text.range(of: query, options: [.caseInsensitive, .diacriticInsensitive], range: searchRange) {
        if let lower = AttributedString.Index(found.lowerBound, within: result), let upper = AttributedString.Index(found.upperBound, within: result) {
            result[lower..<upper].backgroundColor = Theme.accent.opacity(0.45)
            result[lower..<upper].foregroundColor = .white
        }
        searchRange = found.upperBound..<text.endIndex
    }
    return result
}

/// The open document or slide in the main area, where "An der Schreibmarke einfügen" puts text.
@MainActor
func powerInsertAtCaret(_ markdown: String, app: AppModel) -> Bool {
    guard app.canFormatText, let textView = app.documentFind?.controller?.textView else { return false }
    textView.window?.makeFirstResponder(textView)
    textView.insertMarkdown(markdown)
    return true
}

func powerCopy(markdown: String, plain: String) {
    let pasteboard = NSPasteboard.general
    pasteboard.clearContents()
    pasteboard.declareTypes([.writerMarkdown, .string], owner: nil)
    pasteboard.setString(markdown, forType: .writerMarkdown)
    pasteboard.setString(plain, forType: .string)
}

/// A block of a document in the panel: its text (selectable), a grip to drag it out, a line where something
/// dropped would go; a menu to copy, edit, insert or delete it.
struct PowerBlockRow: View {
    @Environment(AppModel.self) private var app
    let chunk: PowerChunk
    let query: String
    var isMatch = false
    /// Where the block comes from ("dokument-ID|Index"), so dragging it within the panel moves it.
    var origin: String?
    var onDrop: ((PowerDrag.Dropped) -> Void)?
    var onEdit: ((String) -> Void)?
    var onDelete: (() -> Void)?
    @State private var targeted = false
    @State private var editing: String?
    @State private var hovering = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Rectangle()
                .fill(Theme.accent)
                .frame(height: 2)
                .opacity(targeted ? 1 : 0)
                .padding(.bottom, 2)
            HStack(alignment: .top, spacing: 4) {
                Image(systemName: "line.3.horizontal")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(hovering ? Theme.textSecondary : Theme.textTertiary.opacity(0.6))
                    .frame(width: 16, height: 18)
                    .contentShape(Rectangle())
                    .powerDrag(markdown: chunk.markdown, plain: chunk.plain, block: origin)
                    .help("Ziehen: in das Dokument, auf eine Folie, in den Chat …")
                if let editing {
                    editor(editing)
                } else {
                    text
                }
            }
            .padding(.vertical, 4)
            .padding(.trailing, 6)
            .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(isMatch ? Theme.accent.opacity(0.08) : (hovering ? Theme.hover : .clear)))
        }
        .onHover { hovering = $0 }
        .onDrop(of: PowerDrag.accepted, isTargeted: $targeted) { providers in
            guard let onDrop else { return false }
            return PowerDrag.load(providers, onDrop)
        }
        .contextMenu { menu }
    }

    @ViewBuilder
    private var text: some View {
        let plain = chunk.plain
        let base = Text(powerHighlighted(plain, query))
        switch chunk.kind {
        case .heading(let level):
            base.font(.system(size: max(12.5, 16 - CGFloat(level)), weight: .semibold))
                .foregroundStyle(Theme.textPrimary)
                .padding(.top, 4)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        case .code, .table, .math:
            base.font(.system(size: 11, design: .monospaced))
                .foregroundStyle(Theme.textSecondary)
                .padding(6)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 5, style: .continuous).fill(Theme.ink.opacity(0.04)))
                .textSelection(.enabled)
        case .quote, .box:
            base.font(.system(size: 12.5))
                .italic(chunk.kind == .quote)
                .foregroundStyle(Theme.textSecondary)
                .padding(.leading, 8)
                .overlay(alignment: .leading) { Rectangle().fill(Theme.accent.opacity(0.6)).frame(width: 2) }
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        default:
            base.font(.system(size: 12.5))
                .foregroundStyle(Theme.textPrimary.opacity(0.92))
                .lineSpacing(1.5)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func editor(_ value: String) -> some View {
        VStack(alignment: .trailing, spacing: 4) {
            TextEditor(text: Binding(get: { editing ?? "" }, set: { editing = $0 }))
                .font(.system(size: 12, design: .monospaced))
                .scrollContentBackground(.hidden)
                .frame(minHeight: 60, maxHeight: 220)
                .padding(4)
                .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(Theme.ink.opacity(0.05)))
            HStack(spacing: 10) {
                Button("Abbrechen") { editing = nil }
                    .buttonStyle(.plain)
                    .foregroundStyle(Theme.textSecondary)
                Button("Übernehmen") {
                    if let text = editing { onEdit?(text) }
                    editing = nil
                }
                .buttonStyle(.plain)
                .foregroundStyle(Theme.accent)
            }
            .font(.system(size: 11.5, weight: .semibold))
        }
        .frame(maxWidth: .infinity)
    }

    @ViewBuilder
    private var menu: some View {
        Button("Kopieren", systemImage: "doc.on.doc") { powerCopy(markdown: chunk.markdown, plain: chunk.plain) }
        Button("An der Schreibmarke einfügen", systemImage: "text.insert") { _ = powerInsertAtCaret(chunk.markdown, app: app) }
            .disabled(!app.canFormatText)
        if onEdit != nil {
            Divider()
            Button("Bearbeiten (Markdown)", systemImage: "pencil") { editing = chunk.markdown }
        }
        if let onDelete {
            Button("Löschen", systemImage: "trash", role: .destructive, action: onDelete)
        }
    }
}

/// Scrolls through a long list of blocks to the places the search finds, with a count and arrows.
struct PowerMatchBar: View {
    let count: Int
    @Binding var current: Int

    var body: some View {
        HStack(spacing: 4) {
            Text(count == 0 ? "Keine Treffer" : "\(current + 1) von \(count) Treffern")
                .font(.system(size: 11, weight: .medium).monospacedDigit())
                .foregroundStyle(count == 0 ? Theme.warning : Theme.textSecondary)
            Spacer(minLength: 0)
            IconButton(systemName: "chevron.up", help: "Voriger Treffer", size: 10.5, frameSize: 22) {
                guard count > 0 else { return }
                current = (current - 1 + count) % count
            }
            IconButton(systemName: "chevron.down", help: "Nächster Treffer", size: 10.5, frameSize: 22) {
                guard count > 0 else { return }
                current = (current + 1) % count
            }
        }
        .padding(.horizontal, 12)
        .padding(.bottom, 4)
    }
}

// MARK: - The drag source

/// A transparent AppKit view over a grip or a picture that starts a real drag: the pasteboard then carries Writer
/// Studio's Markdown, plain text and the block's origin, which AppKit text views (the document, a slide, the chat's
/// input) take as well as SwiftUI's drop places. (SwiftUI's own `onDrag` reached only the latter.)
struct PowerDragSource: NSViewRepresentable {
    let markdown: () -> String
    let plain: () -> String
    var block: String?

    func makeNSView(context: Context) -> DragSourceView {
        let view = DragSourceView()
        view.source = self
        return view
    }

    func updateNSView(_ view: DragSourceView, context: Context) {
        view.source = self
    }

    final class DragSourceView: NSView, NSDraggingSource {
        var source: PowerDragSource?
        private var downPoint: NSPoint?

        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

        override func resetCursorRects() {
            addCursorRect(bounds, cursor: .openHand)
        }

        override func mouseDown(with event: NSEvent) {
            downPoint = convert(event.locationInWindow, from: nil)
        }

        override func mouseDragged(with event: NSEvent) {
            guard let start = downPoint, let source else { return }
            let point = convert(event.locationInWindow, from: nil)
            guard hypot(point.x - start.x, point.y - start.y) > 3 else { return }
            downPoint = nil
            let plain = source.plain()
            let item = NSPasteboardItem()
            item.setString(source.markdown(), forType: .writerMarkdown)
            item.setString(plain, forType: .string)
            if let block = source.block { item.setString(block, forType: NSPasteboard.PasteboardType(PowerDrag.blockType.identifier)) }
            let dragging = NSDraggingItem(pasteboardWriter: item)
            let image = Self.image(for: plain)
            dragging.setDraggingFrame(NSRect(origin: NSPoint(x: start.x - 10, y: start.y - image.size.height / 2), size: image.size), contents: image)
            beginDraggingSession(with: [dragging], event: event, source: self)
        }

        override func mouseUp(with event: NSEvent) {
            downPoint = nil
        }

        func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
            context == .withinApplication ? [.copy, .move, .generic] : .copy
        }

        /// A small card with the beginning of the text, as the picture under the pointer.
        private static func image(for text: String) -> NSImage {
            let line = text.replacingOccurrences(of: "\n", with: " ")
            let shown = line.count > 48 ? String(line.prefix(48)) + "…" : line
            let attributes: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 12, weight: .medium),
                .foregroundColor: NSColor.white,
            ]
            let size = (shown as NSString).size(withAttributes: attributes)
            let imageSize = NSSize(width: min(360, size.width) + 20, height: size.height + 12)
            return NSImage(size: imageSize, flipped: false) { rect in
                NSColor(calibratedRed: 0.36, green: 0.3, blue: 0.62, alpha: 0.92).setFill()
                NSBezierPath(roundedRect: rect, xRadius: 7, yRadius: 7).fill()
                (shown as NSString).draw(in: rect.insetBy(dx: 10, dy: 6), withAttributes: attributes)
                return true
            }
        }
    }
}

extension View {
    /// Dragging this view hands out the text (see `PowerDragSource`).
    func powerDrag(markdown: @autoclosure @escaping () -> String, plain: @autoclosure @escaping () -> String, block: String? = nil) -> some View {
        overlay(PowerDragSource(markdown: markdown, plain: plain, block: block))
    }
}
