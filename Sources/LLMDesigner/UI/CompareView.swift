import AppKit
import SwiftUI

/// Two versions side by side, in the form of their studio: text by paragraphs and words, slides one by one, records
/// as sentences, pictures to blend. Changes can be taken over into the right side when it is a document.
struct CompareView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    @State private var session: CompareSession
    @State private var sideBySide = true
    @State private var showsUnchanged = false
    @State private var current = 0

    init(request: CompareRequest, app: AppModel) {
        _session = State(initialValue: CompareSession(request: request, app: app))
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(minWidth: 820, idealWidth: 1060, minHeight: 540, idealHeight: 740)
        .background(Theme.background)
        .task { await session.load() }
    }

    // MARK: Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Image(systemName: "arrow.left.arrow.right")
                    .foregroundStyle(Theme.accent)
                Text("Vergleichen: \(session.title)")
                    .font(.system(size: 15, weight: .semibold))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 8)
                if session.isLoading { ProgressView().controlSize(.small) }
                if let comparison = session.comparison {
                    Text(comparison.changeCount == 0 ? "keine Unterschiede" : "\(comparison.changeCount) Änderung\(comparison.changeCount == 1 ? "" : "en")")
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.textTertiary)
                    if isText(comparison) {
                        Picker("", selection: $sideBySide) {
                            Text("nebeneinander").tag(true)
                            Text("ineinander").tag(false)
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()
                        .frame(width: 210)
                        Toggle("Unverändertes", isOn: $showsUnchanged)
                            .toggleStyle(.checkbox)
                            .font(.system(size: 12))
                    }
                }
                if session.canUndo {
                    Button("Rückgängig") { Task { await session.undo() } }
                }
                if session.canTakeOver, let comparison = session.comparison, isText(comparison), comparison.changeCount > 0 {
                    Button("Alles übernehmen") { Task { await session.takeOverAll() } }
                        .help("Die linke Fassung ersetzt den Text rechts; Titel und Einstellungen bleiben")
                }
                Button("Fertig") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
            HStack(spacing: 0) {
                sideLabel(session.leftLabel, tint: Theme.danger)
                Image(systemName: "arrow.right")
                    .font(.system(size: 10))
                    .foregroundStyle(Theme.textTertiary)
                    .padding(.horizontal, 8)
                sideLabel(session.rightLabel + (session.canTakeOver ? "  ·  hierhin übernehmen" : ""), tint: Theme.success)
            }
            if let error = session.error {
                Text(error).font(.system(size: 12)).foregroundStyle(Theme.danger)
            }
        }
        .controlSize(.small)
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
    }

    private func sideLabel(_ text: String, tint: Color) -> some View {
        HStack(spacing: 6) {
            RoundedRectangle(cornerRadius: 2).fill(tint.opacity(0.8)).frame(width: 8, height: 8)
            Text(text)
                .font(.system(size: 12))
                .foregroundStyle(Theme.textSecondary)
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func isText(_ comparison: Comparison) -> Bool {
        if case .document = comparison { return true }
        return false
    }

    // MARK: Content

    @ViewBuilder
    private var content: some View {
        switch session.comparison {
        case nil:
            ProgressView()
        case .document(let header, let blocks):
            documentView(header: header, blocks: blocks)
        case .slides(let header, let slides):
            slidesView(header: header, slides: slides)
        case .record(let sentences):
            sentencesView(sentences)
        case .images(let left, let right):
            CompareImagesView(left: left, right: right)
        case .binary(let text):
            Text(text).font(.system(size: 13)).foregroundStyle(Theme.textSecondary)
        }
    }

    private func documentView(header: [String], blocks: [BlockDiff]) -> some View {
        let rows = visibleRows(blocks)
        return ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 6) {
                    if !header.isEmpty { headerBox(header) }
                    if blocks.allSatisfy({ !$0.isChange }) && header.isEmpty {
                        Text("Beide Fassungen sind gleich.").foregroundStyle(Theme.textTertiary).padding(20)
                    }
                    ForEach(rows, id: \.id) { row in
                        switch row {
                        case .block(let block):
                            blockRow(block).id(block.id)
                        case .hidden(let count, let id):
                            Text("… \(count) unveränderte Absätze …")
                                .font(.system(size: 11.5))
                                .foregroundStyle(Theme.textTertiary)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 2)
                                .id(id)
                        }
                    }
                }
                .padding(18)
            }
            .overlay(alignment: .bottomTrailing) {
                changeNavigator(blocks.filter(\.isChange).map(\.id), proxy: proxy)
            }
        }
    }

    private enum Row: Identifiable {
        case block(BlockDiff)
        case hidden(Int, Int)
        var id: Int {
            switch self {
            case .block(let block): block.id
            case .hidden(_, let id): -1 - id
            }
        }
    }

    /// Unchanged paragraphs fold into one line, except one before and after each change for orientation.
    private func visibleRows(_ blocks: [BlockDiff]) -> [Row] {
        guard !showsUnchanged else { return blocks.map(Row.block) }
        var keep = Set<Int>()
        for (index, block) in blocks.enumerated() where block.isChange {
            keep.formUnion([index - 1, index, index + 1])
        }
        var rows: [Row] = []
        var hidden = 0
        for (index, block) in blocks.enumerated() {
            if keep.contains(index) {
                if hidden > 0 { rows.append(.hidden(hidden, index)) }
                hidden = 0
                rows.append(.block(block))
            } else {
                hidden += 1
            }
        }
        if hidden > 0 { rows.append(.hidden(hidden, blocks.count)) }
        return rows
    }

    private func changeNavigator(_ ids: [Int], proxy: ScrollViewProxy) -> some View {
        Group {
            if ids.count > 1 {
                HStack(spacing: 2) {
                    IconButton(systemName: "chevron.up", help: "Vorige Änderung", size: 11, frameSize: 24) {
                        current = (current - 1 + ids.count) % ids.count
                        withAnimation { proxy.scrollTo(ids[current], anchor: .center) }
                    }
                    Text("\(min(current + 1, ids.count))/\(ids.count)")
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(Theme.textTertiary)
                    IconButton(systemName: "chevron.down", help: "Nächste Änderung", size: 11, frameSize: 24) {
                        current = (current + 1) % ids.count
                        withAnimation { proxy.scrollTo(ids[current], anchor: .center) }
                    }
                }
                .padding(4)
                .background(Capsule().fill(Theme.sidebar))
                .overlay(Capsule().strokeBorder(Theme.border))
                .padding(14)
            }
        }
    }

    private func headerBox(_ sentences: [String]) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text("Kopf").font(.system(size: 10.5, weight: .semibold)).foregroundStyle(Theme.textTertiary)
            ForEach(sentences, id: \.self) { Text("• " + $0).font(.system(size: 12)).foregroundStyle(Theme.textSecondary) }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 8).fill(Theme.ink.opacity(0.04)))
    }

    @ViewBuilder
    private func blockRow(_ block: BlockDiff) -> some View {
        if sideBySide {
            HStack(alignment: .top, spacing: 12) {
                cell(left(block), kind: block.kind, side: .left)
                takeOverButton(block)
                cell(right(block), kind: block.kind, side: .right)
            }
        } else {
            HStack(alignment: .top, spacing: 8) {
                cell(inline(block), kind: block.kind, side: .both)
                takeOverButton(block)
            }
        }
    }

    private enum Side { case left, right, both }

    private func left(_ block: BlockDiff) -> AttributedString? {
        switch block.kind {
        case .same: return block.left.map { AttributedString($0) }
        case .changed: return attributed(block.segments.filter { $0.kind != .added })
        case .removed, .moved: return block.left.map { attributed([DiffSegment(text: $0, kind: .removed)]) }
        case .added: return nil
        }
    }

    private func right(_ block: BlockDiff) -> AttributedString? {
        switch block.kind {
        case .same: return block.right.map { AttributedString($0) }
        case .changed: return attributed(block.segments.filter { $0.kind != .removed })
        case .added, .moved: return block.right.map { attributed([DiffSegment(text: $0, kind: .added)]) }
        case .removed: return nil
        }
    }

    private func inline(_ block: BlockDiff) -> AttributedString? {
        switch block.kind {
        case .same: return block.right.map { AttributedString($0) }
        case .changed: return attributed(block.segments)
        case .removed: return block.left.map { attributed([DiffSegment(text: $0, kind: .removed)]) }
        case .added: return block.right.map { attributed([DiffSegment(text: $0, kind: .added)]) }
        case .moved: return (block.right ?? block.left).map { attributed([DiffSegment(text: $0, kind: block.right == nil ? .removed : .added)]) }
        }
    }

    private func attributed(_ segments: [DiffSegment]) -> AttributedString {
        var result = AttributedString()
        for segment in segments {
            var piece = AttributedString(segment.text)
            switch segment.kind {
            case .same: break
            case .removed:
                piece.backgroundColor = Theme.danger.opacity(0.22)
                piece.strikethroughStyle = .single
            case .added:
                piece.backgroundColor = Theme.success.opacity(0.22)
            }
            result += piece
        }
        return result
    }

    private func cell(_ text: AttributedString?, kind: BlockDiff.Kind, side: Side) -> some View {
        let tint: Color? = switch (kind, side) {
        case (.same, _): nil
        case (.moved, _): Theme.accent
        case (.removed, .left), (.removed, .both): Theme.danger
        case (.added, .right), (.added, .both): Theme.success
        case (.changed, _): Theme.warning
        default: nil
        }
        return Group {
            if let text {
                Text(text)
                    .font(.system(size: 13))
                    .foregroundStyle(kind == .same ? Theme.textTertiary : Theme.textPrimary)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                Color.clear.frame(maxWidth: .infinity, minHeight: 18)
            }
        }
        .padding(.vertical, 6)
        .padding(.horizontal, 10)
        .background(RoundedRectangle(cornerRadius: 6).fill((tint ?? .clear).opacity(text == nil ? 0.03 : 0.07)))
        .overlay(alignment: .leading) {
            if let tint, text != nil { Rectangle().fill(tint.opacity(0.7)).frame(width: 3) }
        }
    }

    @ViewBuilder
    private func takeOverButton(_ block: BlockDiff) -> some View {
        if session.canTakeOver && block.isChange && !(block.kind == .moved && block.left != nil && block.right != nil) {
            let help = switch block.kind {
            case .removed: "Diesen Absatz rechts einfügen"
            case .added: "Diesen Absatz rechts entfernen (links gibt es ihn nicht)"
            case .moved: block.right == nil ? "Rechts an dieser Stelle einfügen" : "Rechts an dieser Stelle entfernen"
            default: "Die linke Fassung rechts übernehmen"
            }
            IconButton(systemName: block.kind == .added || (block.kind == .moved && block.right != nil) ? "minus.circle" : "arrow.right.circle",
                       help: help, size: 14, frameSize: 26) {
                Task { await session.takeOver(block) }
            }
        } else if sideBySide {
            Color.clear.frame(width: 26, height: 1)
        }
    }

    // MARK: Slides

    private func slidesView(header: [String], slides: [BlockDiff]) -> some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 10) {
                if !header.isEmpty { headerBox(header) }
                ForEach(slides) { slide in
                    if slide.isChange || showsUnchanged {
                        slideRow(slide)
                    }
                }
                let unchanged = slides.filter { !$0.isChange }.count
                if unchanged > 0 && !showsUnchanged {
                    Button("\(unchanged) unveränderte Folie\(unchanged == 1 ? "" : "n") zeigen") { showsUnchanged = true }
                        .buttonStyle(.plain)
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.accent)
                }
            }
            .padding(18)
        }
    }

    private func slideRow(_ slide: BlockDiff) -> some View {
        let (status, tint): (String, Color) = switch slide.kind {
        case .same: ("unverändert", Theme.textTertiary)
        case .added: ("neu", Theme.success)
        case .removed: ("entfernt", Theme.danger)
        case .changed: ("geändert", Theme.warning)
        case .moved: ("verschoben", Theme.accent)
        }
        return HStack(alignment: .top, spacing: 10) {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    Image(systemName: "rectangle.on.rectangle").foregroundStyle(tint)
                    Text(slide.label ?? "Folie").font(.system(size: 13, weight: .semibold))
                    Text(status)
                        .font(.system(size: 10.5, weight: .medium))
                        .padding(.horizontal, 6).padding(.vertical, 1)
                        .background(Capsule().fill(tint.opacity(0.15)))
                        .foregroundStyle(tint)
                }
                ForEach(slide.details, id: \.self) {
                    Text("• " + $0).font(.system(size: 12)).foregroundStyle(Theme.textSecondary)
                }
                if !slide.segments.isEmpty {
                    Text(attributed(slide.segments)).font(.system(size: 12.5)).textSelection(.enabled)
                }
                if !slide.noteSegments.isEmpty {
                    Text("Moderatorenkarte").font(.system(size: 10.5, weight: .semibold)).foregroundStyle(Theme.textTertiary)
                    Text(attributed(slide.noteSegments)).font(.system(size: 12)).textSelection(.enabled)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            takeOverButton(slide)
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 8).fill(Theme.ink.opacity(0.035)))
        .overlay(alignment: .leading) { Rectangle().fill(tint.opacity(0.6)).frame(width: 3) }
    }

    // MARK: Records

    private func sentencesView(_ sentences: [String]) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 5) {
                if sentences.isEmpty {
                    Text("Keine Unterschiede im Inhalt.").foregroundStyle(Theme.textTertiary)
                }
                ForEach(Array(sentences.enumerated()), id: \.offset) { _, sentence in
                    HStack(alignment: .top, spacing: 6) {
                        Text("•").foregroundStyle(Theme.accent)
                        Text(sentence).font(.system(size: 13)).textSelection(.enabled)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(18)
        }
    }
}

/// Two pictures, side by side or blended over each other with a slider.
private struct CompareImagesView: View {
    let left: Data?
    let right: Data?
    @State private var blend = 0.5
    @State private var overlay = false

    var body: some View {
        VStack(spacing: 10) {
            Picker("", selection: $overlay) {
                Text("nebeneinander").tag(false)
                Text("überblenden").tag(true)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 240)
            if overlay {
                ZStack {
                    image(left)
                    image(right).opacity(blend)
                }
                Slider(value: $blend, in: 0...1).frame(width: 260)
            } else {
                HStack(spacing: 16) {
                    image(left)
                    image(right)
                }
            }
        }
        .padding(18)
    }

    @ViewBuilder
    private func image(_ data: Data?) -> some View {
        if let data, let image = NSImage(data: data) {
            Image(nsImage: image).resizable().scaledToFit()
        } else {
            Text("nicht vorhanden").foregroundStyle(Theme.textTertiary).frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}
