import AppKit
import SwiftUI

/// What Git Studio shows.
@MainActor
@Observable
final class GitStudioModel {
    var commits: [GitCommit] = []
    var rows: [GitGraphRow] = []
    var refs: [GitRef] = []
    var stashes: [GitStash] = []
    var selectedCommitID: String?
    var selectedItems: [GitChangeGroup] = []
    var query = ""
    var isLoading = false
    var canLoadMore = false
    var error: String?
    var info: String?
    var working: String?
    var showsBranches = true

    static let page = 500

    var current: GitRef? { refs.first { $0.isCurrent } }
    var selectedCommit: GitCommit? { commits.first { $0.id == selectedCommitID } }
}

/// Git Studio: the tree of all commits with branches, merges and tags; per commit what changed, by title; and the
/// handgrips for branches. Everything the Terminal can do stays possible there; this is the overview.
struct GitStudioScreen: View {
    @Environment(AppModel.self) private var app
    @State private var model = GitStudioModel()
    @State private var newBranch: NewBranchRequest?
    @State private var newTag: String?
    @State private var pendingDelete: GitRef?
    @State private var width: CGFloat = 1200

    struct NewBranchRequest: Identifiable {
        let id = UUID()
        var name = ""
        var at: String?
    }

    var body: some View {
        let git = app.git
        VStack(spacing: 0) {
            StudioTopBar(symbol: StudioApplication.git.symbol, title: "Git Studio", detail: detail, close: { app.gitStudioOpen = false }) {
                if git.isEnabled { branchMenu }
            } trailing: {
                if git.isEnabled { toolbar }
            }
            if !git.isEnabled {
                setup
            } else {
                if let message = model.error ?? model.info {
                    Text(message)
                        .font(.system(size: 12))
                        .foregroundStyle(model.error == nil ? Theme.success : Theme.danger)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 16)
                        .padding(.bottom, 6)
                        .textSelection(.enabled)
                }
                if git.isMerging || git.status?.hasConflicts == true {
                    mergeBar
                }
                HStack(spacing: 0) {
                    if model.showsBranches && width >= 760 {
                        GitStudioSidebar(model: model, onSwitch: { ref in switchTo(ref) }, onMerge: { ref in merge(ref.name) },
                                         onDelete: { pendingDelete = $0 }, onStash: { stash in applyStash(stash) })
                            .frame(width: 230)
                        Divider()
                    }
                    GitCommitList(model: model) { await load(more: true) }
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    if width >= 980, model.selectedCommit != nil {
                        Divider()
                        GitCommitDetail(model: model, onBranch: { newBranch = NewBranchRequest(at: $0) }, onTag: { newTag = $0 },
                                        onRevert: { revert($0) })
                            .frame(width: 330)
                    }
                }
            }
        }
        .background(Theme.background)
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
        .task(id: git.status?.head ?? "") { await load(more: false) }
        .onChange(of: model.selectedCommitID) { _, _ in Task { await loadSelection() } }
        .sheet(item: $newBranch) { request in
            GitNameSheet(title: request.at == nil ? "Neuer Branch" : "Neuer Branch an diesem Commit", prompt: "Name, z. B. experiment",
                         action: "Anlegen und wechseln") { name in
                await run("Branch …") {
                    try await git.createBranch(name, at: request.at, switchTo: true)
                    model.info = "Branch „\(name)“ angelegt; die Bibliothek ist jetzt dort."
                }
            }
        }
        .sheet(item: Binding(get: { newTag.map { TagRequest(commit: $0) } }, set: { newTag = $0?.commit })) { request in
            GitNameSheet(title: "Tag setzen", prompt: "Name, z. B. Abgabe-Hausarbeit", action: "Setzen") { name in
                await run("Tag …") {
                    try await git.tag(name, at: request.commit)
                    model.info = "Tag „\(name)“ gesetzt."
                }
            }
        }
        .confirmationDialog("Branch „\(pendingDelete?.name ?? "")“ löschen?", isPresented: Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } })) {
            if let ref = pendingDelete {
                Button(ref.isMerged ? "Löschen" : "Trotzdem löschen", role: .destructive) {
                    Task { await run("Löschen …") { try await git.deleteBranch(ref.name, force: !ref.isMerged) } }
                }
            }
        } message: {
            Text(pendingDelete?.isMerged == true
                 ? "Alles aus diesem Branch ist schon zusammengeführt; es geht nichts verloren."
                 : "Dieser Branch ist noch nicht zusammengeführt. Seine Commits sind danach nur noch über das Terminal (git reflog) zu finden.")
        }
    }

    struct TagRequest: Identifiable {
        var commit: String
        var id: String { commit }
    }

    private var detail: String? {
        guard app.git.isEnabled else { return nil }
        let count = model.commits.count
        return count == 0 ? nil : "\(count)\(model.canLoadMore ? "+" : "") Commits · \(model.refs.filter { $0.kind == .local }.count) Branches"
    }

    // MARK: Bars

    private var branchMenu: some View {
        Menu {
            ForEach(model.refs.filter { $0.kind == .local }) { ref in
                Button {
                    switchTo(ref)
                } label: {
                    if ref.isCurrent { Label(ref.name, systemImage: "checkmark") } else { Text(ref.name) }
                }
            }
            Divider()
            Button("Neuer Branch …", systemImage: "plus") { newBranch = NewBranchRequest() }
        } label: {
            Label(app.git.branch ?? "losgelöst", systemImage: "arrow.triangle.branch")
                .font(.system(size: 12.5, weight: .medium))
        }
        .menuStyle(.button)
        .fixedSize()
        .help("Branch wechseln")
    }

    private var toolbar: some View {
        HStack(spacing: 4) {
            if let working = model.working {
                ProgressView().controlSize(.mini)
                Text(working).font(.system(size: 11)).foregroundStyle(Theme.textTertiary)
            }
            if width >= 900 {
                SearchField(text: $model.query, prompt: "Verlauf durchsuchen")
                    .frame(width: 190)
            }
            Menu {
                let others = model.refs.filter { !$0.isCurrent && $0.kind != .tag }
                if others.isEmpty { Text("Kein anderer Branch") }
                ForEach(others) { ref in
                    Button("„\(ref.name)“ hierher\(ref.isMerged ? " (schon enthalten)" : "")") { merge(ref.name) }
                }
            } label: {
                Image(systemName: "arrow.triangle.merge")
                    .font(.system(size: 13, weight: .medium))
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("Einen Branch in „\(app.git.branch ?? "HEAD")“ zusammenführen")
            IconButton(systemName: "arrow.down.circle", help: "Pull: neue Commits vom Remote holen", size: 13.5, frameSize: Theme.titleBarControlSize) {
                Task {
                    await run("Pull …") {
                        do {
                            try await app.git.pull()
                        } catch let failure as GitError where failure == .diverged {
                            let outcome = try await app.git.pullMerging()
                            model.info = outcome.message
                        }
                    }
                }
            }
            IconButton(systemName: "arrow.up.circle", help: "Push: Commits zum Remote schicken", size: 13.5, frameSize: Theme.titleBarControlSize) {
                Task { await run("Push …") { try await app.git.push(); model.info = "Gepusht." } }
            }
            IconButton(systemName: "sidebar.left", help: "Branches ein- oder ausblenden", size: 13, frameSize: Theme.titleBarControlSize) {
                model.showsBranches.toggle()
            }
            IconButton(systemName: "bolt", help: "Änderungen und Commit im Power-Zugriff", size: 13, frameSize: Theme.titleBarControlSize) {
                app.showGit()
            }
        }
    }

    private var mergeBar: some View {
        HStack(spacing: 8) {
            Image(systemName: "arrow.triangle.merge").foregroundStyle(Theme.warning)
            Text("Ein Zusammenführen läuft.").font(.system(size: 12.5, weight: .medium))
            Spacer()
            Button("Konflikte lösen") { app.mergeViewOpen = true }
                .buttonStyle(.borderedProminent)
        }
        .controlSize(.small)
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(Theme.warning.opacity(0.08))
    }

    private var setup: some View {
        VStack(spacing: 14) {
            Image(systemName: "arrow.triangle.branch").font(.system(size: 34)).foregroundStyle(Theme.accent)
            Text("Für diese Bibliothek ist Git noch nicht eingeschaltet.").font(.system(size: 14, weight: .medium))
            Text("Im Power-Zugriff unter „Git“ schaltest du es ein. Danach siehst du hier den Baum der Commits und die Branches.")
                .font(.system(size: 12.5))
                .foregroundStyle(Theme.textSecondary)
                .multilineTextAlignment(.center)
            Button("Git im Power-Zugriff öffnen") { app.showGit() }
                .buttonStyle(.borderedProminent)
        }
        .frame(maxWidth: 460, maxHeight: .infinity)
    }

    // MARK: Loading and acting

    private func load(more: Bool) async {
        let git = app.git
        guard git.isEnabled else { return }
        model.isLoading = true
        defer { model.isLoading = false }
        do {
            let skip = more ? model.commits.count : 0
            let page = try await git.log(limit: GitStudioModel.page, all: true, skip: skip)
            model.commits = more ? model.commits + page : page
            model.canLoadMore = page.count == GitStudioModel.page
            model.rows = GitGraph.rows(for: model.commits)
            model.refs = try await git.refs()
            model.stashes = try await git.stashes()
            if model.selectedCommitID == nil || !model.commits.contains(where: { $0.id == model.selectedCommitID }) {
                model.selectedCommitID = model.commits.first?.id
            }
        } catch {
            model.error = error.localizedDescription
        }
    }

    private func loadSelection() async {
        guard let commit = model.selectedCommit else { return model.selectedItems = [] }
        model.selectedItems = (try? await app.git.changedItems(in: commit)) ?? []
    }

    private func run(_ label: String, _ body: () async throws -> Void) async {
        model.working = label
        model.error = nil
        model.info = nil
        defer { model.working = nil }
        do {
            try await body()
            await load(more: false)
        } catch {
            model.error = error.localizedDescription
        }
    }

    private func switchTo(_ ref: GitRef) {
        guard !ref.isCurrent else { return }
        Task { await run("Wechseln …") { try await app.git.switchBranch(ref.name) } }
    }

    private func merge(_ name: String) {
        Task {
            await run("Zusammenführen …") {
                let outcome = try await app.git.merge(name)
                model.info = outcome.message
            }
        }
    }

    private func revert(_ commit: GitCommit) {
        Task {
            await run("Rückgängig …") {
                try await app.git.revert(commit.id)
                model.info = "„\(commit.subject)“ ist mit einem neuen Commit zurückgenommen."
            }
        }
    }

    private func applyStash(_ stash: GitStash) {
        Task { await run("Hervorholen …") { try await app.git.applyStash(stash.ref) } }
    }
}

// MARK: - Sidebar

private struct GitStudioSidebar: View {
    @Environment(AppModel.self) private var app
    let model: GitStudioModel
    let onSwitch: (GitRef) -> Void
    let onMerge: (GitRef) -> Void
    let onDelete: (GitRef) -> Void
    let onStash: (GitStash) -> Void
    @State private var stashMessage = ""

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 4) {
                section("BRANCHES", refs: model.refs.filter { $0.kind == .local })
                let remotes = model.refs.filter { $0.kind == .remote }
                if !remotes.isEmpty { section("REMOTE", refs: remotes) }
                let tags = model.refs.filter { $0.kind == .tag }
                if !tags.isEmpty { section("TAGS", refs: tags) }
                Text("ZURÜCKGELEGT (\(model.stashes.count))")
                    .font(.system(size: 10.5, weight: .semibold))
                    .foregroundStyle(Theme.textTertiary)
                    .padding(.top, 10)
                ForEach(model.stashes) { stash in
                    HStack {
                        Image(systemName: "tray").font(.system(size: 11)).foregroundStyle(Theme.textTertiary)
                        Text(stash.message).font(.system(size: 12)).lineLimit(1)
                        Spacer()
                    }
                    .contentShape(Rectangle())
                    .contextMenu {
                        Button("Hervorholen", systemImage: "tray.and.arrow.up") { onStash(stash) }
                        Button("Verwerfen", systemImage: "trash", role: .destructive) {
                            Task { try? await app.git.dropStash(stash.ref) }
                        }
                    }
                    .help("\(stash.date.formatted(date: .abbreviated, time: .shortened)) · Rechtsklick: hervorholen")
                }
                if !app.git.changes.isEmpty {
                    HStack(spacing: 4) {
                        TextField("Notiz", text: $stashMessage).textFieldStyle(.roundedBorder).controlSize(.small)
                        Button("Zurücklegen") {
                            let message = stashMessage
                            Task {
                                try? await app.git.stash(message)
                                stashMessage = ""
                            }
                        }
                        .controlSize(.small)
                        .help("Die Änderungen, die noch nicht committet sind, beiseitelegen, etwa um den Branch zu wechseln")
                    }
                }
            }
            .padding(12)
        }
        .background(Theme.sidebar)
    }

    private func section(_ title: String, refs: [GitRef]) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.system(size: 10.5, weight: .semibold))
                .foregroundStyle(Theme.textTertiary)
                .padding(.top, 6)
            ForEach(refs) { ref in
                Button {
                    if let commit = model.commits.first(where: { $0.refNames.contains(ref.name) }) {
                        model.selectedCommitID = commit.id
                    }
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: ref.kind == .tag ? "tag" : ref.isCurrent ? "circle.inset.filled" : "circle")
                            .font(.system(size: 10))
                            .foregroundStyle(ref.isCurrent ? Theme.accent : Theme.textTertiary)
                        Text(ref.name)
                            .font(.system(size: 12.5, weight: ref.isCurrent ? .semibold : .regular))
                            .foregroundStyle(Theme.textPrimary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Spacer(minLength: 0)
                        if ref.ahead + ref.behind > 0 {
                            Text("↑\(ref.ahead) ↓\(ref.behind)").font(.system(size: 10, design: .monospaced)).foregroundStyle(Theme.textTertiary)
                        }
                        if ref.isMerged {
                            Image(systemName: "checkmark").font(.system(size: 9.5, weight: .bold)).foregroundStyle(Theme.success)
                                .help("Schon zusammengeführt")
                        }
                    }
                    .padding(.vertical, 3)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("\(ref.subject) · \(ref.date.formatted(date: .abbreviated, time: .shortened))")
                .contextMenu {
                    if ref.kind != .tag && !ref.isCurrent {
                        Button("Hierhin wechseln", systemImage: "arrow.right.circle") { onSwitch(ref) }
                        Button("In „\(app.git.branch ?? "HEAD")“ zusammenführen", systemImage: "arrow.triangle.merge") { onMerge(ref) }
                        Button("Mit „\(app.git.branch ?? "HEAD")“ vergleichen …", systemImage: "arrow.left.arrow.right") {
                            app.compareBranches(ref.name)
                        }
                    }
                    if ref.kind == .local && !ref.isCurrent {
                        Divider()
                        Button("Löschen", systemImage: "trash", role: .destructive) { onDelete(ref) }
                    }
                }
            }
        }
    }
}

// MARK: - Commit tree

private let laneColors: [Color] = [
    Theme.accent, Color(hex: 0x3FB6D6), Theme.success, Theme.warning, Color(hex: 0xE26DB6), Color(hex: 0xF08A4B), Theme.danger, Color(hex: 0x7A8CFF),
]

private struct GitCommitList: View {
    @Environment(AppModel.self) private var app
    let model: GitStudioModel
    let loadMore: () async -> Void

    static let rowHeight: CGFloat = 28
    static let laneWidth: CGFloat = 14

    var body: some View {
        let query = model.query.trimmingCharacters(in: .whitespaces)
        let width = CGFloat(min(model.rows.map(\.width).max() ?? 1, 12)) * Self.laneWidth + 10
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(Array(model.commits.enumerated()), id: \.element.id) { index, commit in
                    if query.isEmpty || matches(commit, query) {
                        row(commit, graph: index < model.rows.count ? model.rows[index] : nil, graphWidth: width, dimmed: false)
                    }
                }
                if model.canLoadMore {
                    Button("Ältere Commits laden") { Task { await loadMore() } }
                        .buttonStyle(.plain)
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.accent)
                        .padding(12)
                }
                if model.commits.isEmpty && !model.isLoading {
                    Text("Noch keine Commits.").foregroundStyle(Theme.textTertiary).padding(20)
                }
            }
        }
    }

    private func matches(_ commit: GitCommit, _ query: String) -> Bool {
        commit.subject.localizedCaseInsensitiveContains(query) || commit.body.localizedCaseInsensitiveContains(query)
            || commit.author.localizedCaseInsensitiveContains(query) || commit.id.hasPrefix(query.lowercased())
    }

    private func row(_ commit: GitCommit, graph: GitGraphRow?, graphWidth: CGFloat, dimmed: Bool) -> some View {
        let isSelected = model.selectedCommitID == commit.id
        let isAgent = commit.trailer("Auftrag") != nil
        return HStack(spacing: 8) {
            if let graph {
                GitGraphCell(row: graph, isMerge: commit.isMerge)
                    .frame(width: graphWidth, height: Self.rowHeight)
            }
            if isAgent {
                Image(systemName: "cpu")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.accent)
                    .help("Commit eines Agenten (Auftrag \(commit.trailer("Auftrag") ?? ""))")
            }
            Text(commit.subject)
                .font(.system(size: 12.5, weight: commit.isMerge ? .medium : .regular))
                .foregroundStyle(Theme.textPrimary)
                .lineLimit(1)
                .truncationMode(.tail)
            ForEach(commit.refs.prefix(3), id: \.self) { ref in
                RefBadge(ref: ref)
            }
            Spacer(minLength: 8)
            Text(commit.author)
                .font(.system(size: 11.5))
                .foregroundStyle(Theme.textTertiary)
                .lineLimit(1)
                .frame(maxWidth: 120, alignment: .trailing)
            Text(commit.date.formatted(date: .abbreviated, time: .shortened))
                .font(.system(size: 11.5).monospacedDigit())
                .foregroundStyle(Theme.textTertiary)
                .lineLimit(1)
                .fixedSize()
        }
        .padding(.horizontal, 10)
        .frame(height: Self.rowHeight)
        .background(isSelected ? Theme.accent.opacity(0.14) : .clear)
        .contentShape(Rectangle())
        .onTapGesture { model.selectedCommitID = commit.id }
    }
}

/// One row of the tree: lines passing by, lines into the dot from the children above, lines out to the parents.
private struct GitGraphCell: View {
    let row: GitGraphRow
    let isMerge: Bool

    var body: some View {
        Canvas { context, size in
            let lane = GitCommitList.laneWidth
            func x(_ index: Int) -> CGFloat { CGFloat(index) * lane + lane / 2 + 4 }
            let mid = size.height / 2
            func stroke(_ path: Path, _ index: Int) {
                context.stroke(path, with: .color(laneColors[index % laneColors.count]), style: StrokeStyle(lineWidth: 1.8, lineCap: .round))
            }
            for index in row.passing {
                var path = Path()
                path.move(to: CGPoint(x: x(index), y: 0))
                path.addLine(to: CGPoint(x: x(index), y: size.height))
                stroke(path, index)
            }
            for index in row.incoming {
                var path = Path()
                path.move(to: CGPoint(x: x(index), y: 0))
                path.addCurve(to: CGPoint(x: x(row.lane), y: mid), control1: CGPoint(x: x(index), y: mid * 0.7), control2: CGPoint(x: x(row.lane), y: mid * 0.4))
                stroke(path, index)
            }
            for index in row.outgoing {
                var path = Path()
                path.move(to: CGPoint(x: x(row.lane), y: mid))
                path.addCurve(to: CGPoint(x: x(index), y: size.height), control1: CGPoint(x: x(row.lane), y: mid + mid * 0.6), control2: CGPoint(x: x(index), y: mid + mid * 0.3))
                stroke(path, index)
            }
            let radius: CGFloat = isMerge ? 3.5 : 4.5
            let dot = Path(ellipseIn: CGRect(x: x(row.lane) - radius, y: mid - radius, width: radius * 2, height: radius * 2))
            let color = laneColors[row.lane % laneColors.count]
            if isMerge {
                context.stroke(dot, with: .color(color), lineWidth: 2)
            } else {
                context.fill(dot, with: .color(color))
            }
        }
    }
}

private struct RefBadge: View {
    let ref: String

    var body: some View {
        let isHead = ref.hasPrefix("HEAD -> ")
        let isTag = ref.hasPrefix("tag: ")
        let name = isHead ? String(ref.dropFirst(8)) : isTag ? String(ref.dropFirst(5)) : ref
        let isRemote = !isHead && !isTag && name.contains("/")
        let tint = isTag ? Theme.warning : isRemote ? Theme.textTertiary : Theme.accent
        return HStack(spacing: 3) {
            if isTag { Image(systemName: "tag.fill").font(.system(size: 8.5)) }
            Text(name).font(.system(size: 10.5, weight: isHead ? .bold : .medium)).lineLimit(1)
        }
        .foregroundStyle(tint)
        .padding(.horizontal, 6)
        .padding(.vertical, 1.5)
        .background(Capsule().fill(tint.opacity(0.13)))
        .overlay(Capsule().strokeBorder(isHead ? tint.opacity(0.7) : .clear))
        .fixedSize()
    }
}

// MARK: - Detail

private struct GitCommitDetail: View {
    @Environment(AppModel.self) private var app
    let model: GitStudioModel
    let onBranch: (String) -> Void
    let onTag: (String) -> Void
    let onRevert: (GitCommit) -> Void
    @State private var confirmsRevert = false

    var body: some View {
        if let commit = model.selectedCommit {
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    Text(commit.subject)
                        .font(.system(size: 14, weight: .semibold))
                        .textSelection(.enabled)
                    HStack(spacing: 6) {
                        Text("\(commit.author) · \(commit.date.formatted(date: .abbreviated, time: .shortened))")
                            .font(.system(size: 11.5))
                            .foregroundStyle(Theme.textTertiary)
                        Spacer()
                        Button(commit.shortID) {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(commit.id, forType: .string)
                        }
                        .buttonStyle(.plain)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(Theme.accent)
                        .help("Hash kopieren")
                    }
                    if commit.isMerge {
                        Label("Merge-Commit: führt \(commit.parents.count) Linien zusammen", systemImage: "arrow.triangle.merge")
                            .font(.system(size: 11.5))
                            .foregroundStyle(Theme.textSecondary)
                    }
                    if let job = commit.trailer("Auftrag") {
                        Label("Von einem Agenten, Auftrag \(job)\(commit.trailer("Schritt").map { ", Schritt \($0)" } ?? "")", systemImage: "cpu")
                            .font(.system(size: 11.5))
                            .foregroundStyle(Theme.accent)
                    }
                    // The lines per item and the trailers are shown as the list below and the label above.
                    let body = commit.body.split(separator: "\n", omittingEmptySubsequences: false)
                        .filter { !$0.hasPrefix("- ") && !$0.hasPrefix("Auftrag:") && !$0.hasPrefix("Schritt:") }
                        .joined(separator: "\n")
                    if !body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, model.selectedItems.isEmpty {
                        Text(body).font(.system(size: 12)).foregroundStyle(Theme.textSecondary).textSelection(.enabled)
                    }
                    Text("GEÄNDERT (\(model.selectedItems.count))")
                        .font(.system(size: 10.5, weight: .semibold))
                        .foregroundStyle(Theme.textTertiary)
                        .padding(.top, 4)
                    ForEach(model.selectedItems) { group in
                        Button {
                            app.compare(CompareRequest(item: group.item, left: commit.parents.first.map { .commit($0) } ?? .commit("\(commit.id)^"),
                                                       right: .commit(commit.id), allowsTakingOver: false))
                        } label: {
                            HStack(spacing: 8) {
                                Image(systemName: group.item.kind.symbol)
                                    .font(.system(size: 11.5))
                                    .foregroundStyle(Theme.textSecondary)
                                    .frame(width: 16)
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(group.item.title).font(.system(size: 12.5, weight: .medium)).lineLimit(1)
                                    Text("\(group.item.kind.label) · \(group.paths.count) Datei\(group.paths.count == 1 ? "" : "en")")
                                        .font(.system(size: 10.5))
                                        .foregroundStyle(Theme.textTertiary)
                                }
                                Spacer(minLength: 0)
                                Image(systemName: "arrow.left.arrow.right").font(.system(size: 10.5)).foregroundStyle(Theme.textTertiary)
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .help("Vorher und nachher vergleichen")
                    }
                    Divider().padding(.vertical, 4)
                    VStack(alignment: .leading, spacing: 6) {
                        Button("Branch hier anlegen …", systemImage: "plus") { onBranch(commit.id) }
                        Button("Tag setzen …", systemImage: "tag") { onTag(commit.id) }
                        Button("Rückgängig machen …", systemImage: "arrow.uturn.backward") { confirmsRevert = true }
                    }
                    .buttonStyle(.plain)
                    .font(.system(size: 12.5))
                    .foregroundStyle(Theme.accent)
                }
                .padding(14)
            }
            .confirmationDialog("„\(commit.subject)“ rückgängig machen?", isPresented: $confirmsRevert) {
                Button("Rückgängig machen") { onRevert(commit) }
            } message: {
                Text("Ein neuer Commit nimmt die Änderungen dieses Commits zurück. Der Verlauf bleibt, wie er ist.")
            }
        }
    }
}

/// Asks for a name (branch, tag) and runs the action with it.
private struct GitNameSheet: View {
    @Environment(\.dismiss) private var dismiss
    let title: String
    let prompt: String
    let action: String
    let perform: (String) async -> Void
    @State private var name = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title).font(.system(size: 15, weight: .semibold))
            TextField(prompt, text: $name).textFieldStyle(.roundedBorder)
                .onSubmit { submit() }
            HStack {
                Spacer()
                Button("Abbrechen") { dismiss() }
                Button(action) { submit() }
                    .buttonStyle(.borderedProminent)
                    .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 380)
    }

    private func submit() {
        let value = name.trimmingCharacters(in: .whitespaces)
        guard !value.isEmpty else { return }
        dismiss()
        Task { await perform(value) }
    }
}

extension AppModel {
    /// Compares the open document (or else asks for nothing more): the current branch against another, for the
    /// item open in the main area; without an open item, Git Studio shows the other branch's commits.
    func compareBranches(_ other: String) {
        guard let id = selectedDocumentID ?? openProjectID, let item = git.item(forRecord: id) else {
            notice = "Öffne ein Dokument, eine Präsentation oder ein Projekt, um es zwischen den Branches zu vergleichen."
            return
        }
        compare(CompareRequest(item: item, left: .commit(other), right: .workingTree, allowsTakingOver: true))
    }
}
