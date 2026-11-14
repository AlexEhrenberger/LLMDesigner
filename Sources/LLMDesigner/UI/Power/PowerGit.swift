import SwiftUI

/// Git in the power access: what changed (by title), a message, commit and push, and the history of what is open.
struct PowerGit: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        let git = app.git
        if git.isEnabled {
            PowerGitWorkspace()
        } else {
            PowerGitSetup()
        }
    }
}

// MARK: - Turning on

private struct PowerGitSetup: View {
    @Environment(AppModel.self) private var app
    @State private var needsIdentity = false
    @State private var name = ""
    @State private var email = ""
    @State private var working = false
    @State private var error: String?
    @State private var skipped: [String] = []

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                Label("Versionen mit Git", systemImage: "arrow.triangle.branch")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Theme.textPrimary)
                Text("Diese Bibliothek wird ein eigenes Git-Repository. Du siehst dann, was sich geändert hat, schreibst Commits, vergleichst Fassungen und kannst alles auch im Terminal mit den üblichen Git-Werkzeugen tun.")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                Text("Nicht in Git kommen: Einstellungen (mit den API-Schlüsseln), Chats mit ihren Anhängen, Personas und Dateien über 50 MB.")
                    .font(.system(size: 11.5))
                    .foregroundStyle(Theme.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
                if app.git.tool == nil {
                    PowerGitMessage(text: GitError.notInstalled.localizedDescription, isError: true)
                }
                if needsIdentity {
                    Text("Wer committet? (steht nur in dieser Bibliothek)")
                        .font(.system(size: 11.5, weight: .medium))
                        .foregroundStyle(Theme.textSecondary)
                    TextField("Name", text: $name).textFieldStyle(.roundedBorder)
                    TextField("E-Mail", text: $email).textFieldStyle(.roundedBorder)
                }
                HStack {
                    Button {
                        Task { await enable() }
                    } label: {
                        if working { ProgressView().controlSize(.small) } else { Text("Git einschalten") }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(working || app.git.tool == nil || (needsIdentity && (name.isEmpty || !email.contains("@"))))
                    Spacer()
                }
                if let error { PowerGitMessage(text: error, isError: true) }
                if let problem = app.git.problem { PowerGitMessage(text: problem, isError: true) }
            }
            .padding(14)
        }
        .task { needsIdentity = !(await app.git.hasIdentity()) && app.git.tool != nil }
    }

    private func enable() async {
        working = true
        defer { working = false }
        error = nil
        do {
            skipped = try await app.git.enable(identity: needsIdentity ? (name.trimmingCharacters(in: .whitespaces), email.trimmingCharacters(in: .whitespaces)) : nil)
            if !skipped.isEmpty { app.notice = "Git ist an. \(skipped.count) große Datei(en) bleiben außerhalb des Verlaufs." }
        } catch GitError.noIdentity {
            needsIdentity = true
        } catch {
            self.error = error.localizedDescription
        }
    }
}

// MARK: - Working

private struct PowerGitWorkspace: View {
    @Environment(AppModel.self) private var app
    @State private var excluded: Set<String> = []
    @State private var message = ""
    @State private var working: String?
    @State private var error: String?
    @State private var info: String?
    @State private var suggesting = false
    @State private var showsRemote = false
    @State private var diverged = false

    var body: some View {
        let git = app.git
        let query = app.power.query
        let shown = query.isEmpty ? git.changes : git.changes.filter { PowerText.matches($0.item.title, query) || PowerText.matches($0.item.kind.label, query) }
        let chosen = git.changes.filter { !excluded.contains($0.id) }
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                header
                if let problem = git.problem { PowerGitMessage(text: problem, isError: true) }
                if git.isMerging || git.status?.hasConflicts == true {
                    PowerGitMergeBanner()
                }
                if diverged {
                    VStack(alignment: .leading, spacing: 6) {
                        PowerGitMessage(text: GitError.diverged.localizedDescription, isError: true)
                        Button("Mit dem Remote zusammenführen") {
                            Task {
                                await run("Zusammenführen …") {
                                    let outcome = try await git.pullMerging()
                                    diverged = false
                                    info = outcome.message
                                }
                            }
                        }
                        .controlSize(.small)
                    }
                }

                PowerGitSectionTitle(title: git.changes.isEmpty ? "KEINE ÄNDERUNGEN" : "ÄNDERUNGEN (\(git.changes.count))") {
                    if !git.changes.isEmpty {
                        Button(excluded.isEmpty ? "keine" : "alle") {
                            excluded = excluded.isEmpty ? Set(git.changes.map(\.id)) : []
                        }
                        .buttonStyle(.plain)
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.accent)
                    }
                }
                if git.changes.isEmpty {
                    Text("Alles ist committet.")
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.textTertiary)
                }
                ForEach(shown) { group in
                    PowerGitChangeRow(group: group, isOn: Binding(
                        get: { !excluded.contains(group.id) },
                        set: { if $0 { excluded.remove(group.id) } else { excluded.insert(group.id) } }
                    ))
                }

                if !git.changes.isEmpty {
                    messageEditor
                    HStack(spacing: 6) {
                        Button {
                            Task { await suggest(chosen) }
                        } label: {
                            Label(suggesting ? "Schreibt …" : "Vorschlagen", systemImage: "sparkles")
                        }
                        .disabled(suggesting || chosen.isEmpty)
                        .help("Das Modell schlägt eine Nachricht aus den Änderungen vor")
                        Spacer(minLength: 0)
                        Button("Commit") { Task { await commit(chosen, push: false) } }
                            .disabled(!canCommit(chosen))
                        Button("Commit & Push") { Task { await commit(chosen, push: true) } }
                            .buttonStyle(.borderedProminent)
                            .disabled(!canCommit(chosen))
                    }
                    .controlSize(.small)
                }

                if let error { PowerGitMessage(text: error, isError: true) }
                if let info { PowerGitMessage(text: info, isError: false) }

                PowerGitHistory()
            }
            .padding(.horizontal, 12)
            .padding(.bottom, 14)
        }
        .task { await app.git.refresh() }
        .sheet(isPresented: $showsRemote) { PowerGitRemoteSheet() }
    }

    private var header: some View {
        let git = app.git
        let status = git.status
        return HStack(spacing: 6) {
            Image(systemName: "arrow.triangle.branch")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Theme.accent)
            Text(status?.branch ?? (status?.head.map { "losgelöst bei \($0.prefix(7))" } ?? "–"))
                .font(.system(size: 12.5, weight: .semibold))
                .foregroundStyle(Theme.textPrimary)
                .lineLimit(1)
            if let status, status.upstream != nil {
                Text("↑\(status.ahead) ↓\(status.behind)")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(Theme.textTertiary)
                    .help("\(status.ahead) Commits noch nicht gepusht, \(status.behind) Commits vom Remote noch nicht übernommen")
            }
            Spacer(minLength: 0)
            if let working {
                ProgressView().controlSize(.mini)
                Text(working).font(.system(size: 11)).foregroundStyle(Theme.textTertiary)
            }
            Menu {
                Button("Pull", systemImage: "arrow.down") {
                    Task {
                        await run("Pull …") {
                            do {
                                try await git.pull()
                            } catch let failure as GitError where failure == .diverged {
                                diverged = true
                            }
                        }
                    }
                }
                Button("Push", systemImage: "arrow.up") { Task { await run("Push …") { try await git.push() } } }
                Button("Neu vom Remote holen (Fetch)", systemImage: "arrow.clockwise") { Task { await run("Fetch …") { try await git.fetch() } } }
                Divider()
                Button("Mit GitHub oder GitLab verbinden …", systemImage: "link") { showsRemote = true }
                Button("Terminal-Commits mit neuestem Stand …", systemImage: "terminal") {
                    Task { await run("Hook …") { try await git.installFlushHook(); info = "Ein Commit im Terminal schreibt jetzt vorher, was in LLM Designer noch auf eine Tipp-Pause wartet." } }
                }
                Button("Im Finder zeigen", systemImage: "folder") { NSWorkspace.shared.activateFileViewerSelecting([git.root]) }
            } label: {
                Image(systemName: "ellipsis.circle")
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.textSecondary)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
        }
        .padding(.vertical, 4)
    }

    private var messageEditor: some View {
        ZStack(alignment: .topLeading) {
            TextEditor(text: $message)
                .font(.system(size: 12.5))
                .scrollContentBackground(.hidden)
                .padding(4)
                .frame(minHeight: 54, maxHeight: 110)
            if message.isEmpty {
                Text("Was hast du geändert?")
                    .font(.system(size: 12.5))
                    .foregroundStyle(Theme.textTertiary)
                    .padding(.horizontal, 9)
                    .padding(.vertical, 4)
                    .allowsHitTesting(false)
            }
        }
        .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(Theme.ink.opacity(0.04)))
        .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous).strokeBorder(Theme.border))
    }

    private func canCommit(_ chosen: [GitChangeGroup]) -> Bool {
        working == nil && !chosen.isEmpty && !message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func commit(_ chosen: [GitChangeGroup], push: Bool) async {
        let all = chosen.count == app.git.changes.count
        let text = message
        await run(push ? "Commit & Push …" : "Commit …") {
            let result = try await app.git.commit(all ? nil : chosen, message: text)
            message = ""
            excluded = []
            var parts = ["Commit \(result.commit.shortID): \(chosen.count) Ding(e)"]
            if !result.skipped.isEmpty { parts.append("\(result.skipped.count) große Datei(en) ausgelassen") }
            if push {
                try await app.git.push()
                parts.append("gepusht")
            }
            info = parts.joined(separator: " · ")
        }
    }

    private func run(_ label: String, _ body: () async throws -> Void) async {
        working = label
        error = nil
        info = nil
        defer { working = nil }
        do {
            try await body()
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func suggest(_ chosen: [GitChangeGroup]) async {
        suggesting = true
        defer { suggesting = false }
        let lines = chosen.prefix(30).map { "- \($0.item.kind.label) „\($0.item.title)“: \($0.summary)" }.joined(separator: "\n")
        do {
            let text = try await app.studioComplete(
                system: "Du schreibst Commit-Nachrichten auf Deutsch: eine Zeile, höchstens 60 Zeichen, sachlich, ohne Anführungszeichen und ohne Punkt am Ende, etwa „Kapitel 3 überarbeitet, Folie zu Regression“. Antworte nur mit der Nachricht.",
                user: "Geändert:\n\(lines)", temperature: 0.3, maxTokens: 200)
            let line = text.split(separator: "\n").first.map(String.init)?.trimmingCharacters(in: CharacterSet(charactersIn: "\"„“ ")) ?? ""
            if !line.isEmpty { message = line }
        } catch {
            self.error = error.localizedDescription
        }
    }
}

private struct PowerGitChangeRow: View {
    let group: GitChangeGroup
    @Binding var isOn: Bool

    var body: some View {
        HStack(spacing: 8) {
            Toggle("", isOn: $isOn)
                .toggleStyle(.checkbox)
                .labelsHidden()
            Image(systemName: group.item.kind.symbol)
                .font(.system(size: 11.5))
                .foregroundStyle(Theme.textSecondary)
                .frame(width: 16)
            VStack(alignment: .leading, spacing: 1) {
                Text(group.item.title)
                    .font(.system(size: 12.5, weight: .medium))
                    .foregroundStyle(Theme.textPrimary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text("\(group.item.kind.label) · \(group.summary)")
                    .font(.system(size: 10.5))
                    .foregroundStyle(group.summary == "Konflikt" ? Theme.danger : Theme.textTertiary)
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 3)
        .contentShape(Rectangle())
        .onTapGesture { isOn.toggle() }
        .help(group.paths.joined(separator: "\n"))
    }
}

// MARK: - History of what is open

private struct PowerGitHistory: View {
    @Environment(AppModel.self) private var app
    @State private var commits: [GitCommit] = []
    @State private var pendingRestore: GitCommit?
    @State private var error: String?

    /// The record the main area shows: a document, a presentation or a project.
    private var openID: UUID? { app.selectedDocumentID ?? app.openProjectID }

    var body: some View {
        if let id = openID, let item = app.git.item(forRecord: id) {
            VStack(alignment: .leading, spacing: 6) {
                PowerGitSectionTitle(title: "VERLAUF VON „\(item.title.uppercased())“") {}
                    .padding(.top, 8)
                if commits.isEmpty {
                    Text("Noch in keinem Commit.")
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.textTertiary)
                }
                ForEach(commits) { commit in
                    HStack(spacing: 6) {
                        Circle().fill(Theme.accent.opacity(0.7)).frame(width: 6, height: 6)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(commit.subject)
                                .font(.system(size: 12))
                                .foregroundStyle(Theme.textPrimary)
                                .lineLimit(1)
                            Text("\(commit.date.formatted(date: .abbreviated, time: .shortened)) · \(commit.author)")
                                .font(.system(size: 10.5))
                                .foregroundStyle(Theme.textTertiary)
                        }
                        Spacer(minLength: 0)
                        IconButton(systemName: "arrow.left.arrow.right", help: "Mit jetzt vergleichen", size: 11, frameSize: 22) {
                            app.compare(.init(item: item, left: .commit(commit.id), right: .workingTree))
                        }
                        IconButton(systemName: "arrow.uturn.backward", help: "Diese Fassung wiederherstellen", size: 11, frameSize: 22) {
                            pendingRestore = commit
                        }
                    }
                }
                if let error { PowerGitMessage(text: error, isError: true) }
            }
            .task(id: "\(id)-\(app.git.status?.head ?? "")") {
                commits = (try? await app.git.history(of: item, limit: 30)) ?? []
            }
            .confirmationDialog("„\(item.title)“ wiederherstellen?", isPresented: Binding(get: { pendingRestore != nil }, set: { if !$0 { pendingRestore = nil } })) {
                Button("Wiederherstellen") {
                    guard let commit = pendingRestore else { return }
                    Task {
                        do { try await app.git.restore(item, to: commit.id) } catch { self.error = error.localizedDescription }
                    }
                }
            } message: {
                Text("Der Stand vom \(pendingRestore?.date.formatted(date: .abbreviated, time: .shortened) ?? "") kommt zurück. Was jetzt da ist, wird vorher committet, damit nichts verloren geht.")
            }
        }
    }
}

// MARK: - Remote

private struct PowerGitRemoteSheet: View {
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    @State private var url = ""
    @State private var current: [LibraryGit.Remote] = []
    @State private var gitHubReady = false
    @State private var repositoryName = ""
    @State private var working = false
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Mit GitHub oder GitLab verbinden")
                .font(.system(size: 15, weight: .semibold))
            if let origin = current.first(where: { $0.name == "origin" }) {
                Text("Verbunden mit \(origin.url)")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.textSecondary)
                    .textSelection(.enabled)
            }
            Text("Lege dort ein leeres, privates Repository an und füge seine Adresse ein. Die Anmeldung übernimmt Git selbst (Schlüsselbund oder SSH-Schlüssel); LLM Designer sieht kein Passwort.")
                .font(.system(size: 12))
                .foregroundStyle(Theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            TextField("https://github.com/name/bibliothek.git oder git@gitlab.com:name/bibliothek.git", text: $url)
                .textFieldStyle(.roundedBorder)
            HStack {
                Spacer()
                Button("Abbrechen") { dismiss() }
                Button("Verbinden") { Task { await connect() } }
                    .buttonStyle(.borderedProminent)
                    .disabled(working || !LibraryGit.isValidRemoteURL(url))
            }
            if gitHubReady {
                Divider()
                Text("Oder gleich ein neues privates Repository auf GitHub anlegen (über gh):")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.textSecondary)
                HStack {
                    TextField("Name", text: $repositoryName).textFieldStyle(.roundedBorder)
                    Button("Anlegen und pushen") { Task { await createOnGitHub() } }
                        .disabled(working || repositoryName.isEmpty)
                }
            }
            if working { ProgressView().controlSize(.small) }
            if let error { PowerGitMessage(text: error, isError: true) }
        }
        .padding(20)
        .frame(width: 480)
        .task {
            current = (try? await app.git.remotes()) ?? []
            gitHubReady = await GitHubCLI.isSignedIn()
            repositoryName = AppLibrary.current.name.replacingOccurrences(of: " ", with: "-")
        }
    }

    private func connect() async {
        working = true
        defer { working = false }
        do {
            try await app.git.setRemote(url)
            try await app.git.push()
            dismiss()
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func createOnGitHub() async {
        working = true
        defer { working = false }
        do {
            app.saveEverythingForGit()
            try await GitHubCLI.createPrivateRepository(named: repositoryName, for: app.git.root)
            await app.git.refresh()
            dismiss()
        } catch {
            self.error = error.localizedDescription
        }
    }
}

// MARK: - Pieces

struct PowerGitSectionTitle<Trailing: View>: View {
    let title: String
    @ViewBuilder var trailing: () -> Trailing

    var body: some View {
        HStack {
            Text(title)
                .font(.system(size: 10.5, weight: .semibold))
                .foregroundStyle(Theme.textTertiary)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 0)
            trailing()
        }
    }
}

struct PowerGitMessage: View {
    let text: String
    let isError: Bool

    var body: some View {
        Text(text)
            .font(.system(size: 11.5))
            .foregroundStyle(isError ? Theme.danger : Theme.success)
            .fixedSize(horizontal: false, vertical: true)
            .textSelection(.enabled)
    }
}

/// A merge under way: how many files still have conflicts, and the way to the conflict view or to finish.
private struct PowerGitMergeBanner: View {
    @Environment(AppModel.self) private var app
    @State private var error: String?

    var body: some View {
        let conflicted = Set((app.git.status?.entries ?? []).filter { $0.change == .conflicted }.map(\.path)).count
        VStack(alignment: .leading, spacing: 6) {
            Label(conflicted > 0 ? "Zusammenführen läuft: \(conflicted) Datei(en) mit Konflikten" : "Zusammenführen läuft: alle Konflikte gelöst",
                  systemImage: "arrow.triangle.merge")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(conflicted > 0 ? Theme.warning : Theme.success)
            HStack(spacing: 6) {
                Button(conflicted > 0 ? "Konflikte lösen" : "Ansehen") { app.mergeViewOpen = true }
                if conflicted == 0 {
                    Button("Abschließen") {
                        Task {
                            do { try await app.git.finishMerge() } catch { self.error = error.localizedDescription }
                        }
                    }
                    .buttonStyle(.borderedProminent)
                }
                Button("Abbrechen", role: .destructive) {
                    Task {
                        do { try await app.git.abortMerge() } catch { self.error = error.localizedDescription }
                    }
                }
            }
            .controlSize(.small)
            if let error { PowerGitMessage(text: error, isError: true) }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 8).fill(Theme.warning.opacity(0.08)))
    }
}
