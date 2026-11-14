import LibraryMerge
import SwiftUI

/// The conflicts of a merge in progress: per file the places both sides changed differently, with the common
/// version, this side's and the other side's next to each other. Each file is settled on its own; when none is
/// left, the merge is finished.
struct MergeView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    @State private var files: [GitConflictFile] = []
    @State private var selection: String?
    @State private var choices: [String: [Int: MergeChoice]] = [:]
    @State private var editing: [String: [Int: String]] = [:]
    @State private var working: String?
    @State private var error: String?
    @State private var loaded = false

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            HStack(spacing: 0) {
                fileList
                    .frame(width: 250)
                Divider()
                detail
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            Divider()
            footer
        }
        .frame(minWidth: 900, idealWidth: 1120, minHeight: 560, idealHeight: 760)
        .background(Theme.background)
        .task { await load() }
    }

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: "arrow.triangle.merge")
                .foregroundStyle(Theme.accent)
            VStack(alignment: .leading, spacing: 2) {
                Text("Zusammenführen: Konflikte lösen")
                    .font(.system(size: 15, weight: .semibold))
                Text("Beide Seiten haben dieselbe Stelle verschieden geändert. Bis du entscheidest, gilt deine Fassung; alles andere ist schon zusammengeführt.")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.textSecondary)
            }
            Spacer()
            if let working {
                ProgressView().controlSize(.small)
                Text(working).font(.system(size: 12)).foregroundStyle(Theme.textTertiary)
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
    }

    private var fileList: some View {
        List(selection: $selection) {
            Section(files.isEmpty && loaded ? "Keine Konflikte mehr" : "Dateien mit Konflikten (\(files.count))") {
                ForEach(files) { file in
                    HStack(spacing: 8) {
                        Image(systemName: file.item.kind.symbol)
                            .foregroundStyle(Theme.textSecondary)
                            .frame(width: 16)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(file.item.title).font(.system(size: 12.5, weight: .medium)).lineLimit(1)
                            Text(file.merge.map { "\($0.conflicts.count) Stelle(n)" } ?? "ganze Datei")
                                .font(.system(size: 10.5))
                                .foregroundStyle(Theme.textTertiary)
                        }
                    }
                    .tag(file.id)
                }
            }
        }
        .listStyle(.sidebar)
    }

    @ViewBuilder
    private var detail: some View {
        if let file = files.first(where: { $0.id == selection }) ?? files.first {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    HStack {
                        Text(file.item.title).font(.system(size: 14, weight: .semibold))
                        Text(file.item.kind.label).font(.system(size: 12)).foregroundStyle(Theme.textTertiary)
                        Spacer()
                        if file.isText {
                            Button("Alle: meine") { setAll(file, .ours) }
                            Button("Alle: andere") { setAll(file, .theirs) }
                            Button("Datei übernehmen") { Task { await resolve(file) } }
                                .buttonStyle(.borderedProminent)
                        } else {
                            Button("Meine behalten") { Task { await resolve(file, whole: .ours) } }
                            Button("Andere nehmen") { Task { await resolve(file, whole: .theirs) } }
                                .buttonStyle(.borderedProminent)
                        }
                    }
                    .controlSize(.small)
                    if let merge = file.merge {
                        ForEach(merge.conflicts) { conflict in
                            conflictCard(conflict, in: file)
                        }
                    } else {
                        Text("Diese Datei (Bild, Audio oder Ähnliches) lässt sich nicht stückweise zusammenführen. Wähle eine Seite als Ganzes.")
                            .font(.system(size: 12.5))
                            .foregroundStyle(Theme.textSecondary)
                    }
                }
                .padding(18)
            }
        } else if loaded {
            VStack(spacing: 10) {
                Image(systemName: "checkmark.circle").font(.system(size: 30)).foregroundStyle(Theme.success)
                Text("Alle Konflikte sind gelöst.").font(.system(size: 14, weight: .medium))
                Text("Schließe das Zusammenführen ab, dann entsteht der Merge-Commit.").font(.system(size: 12)).foregroundStyle(Theme.textSecondary)
            }
        } else {
            ProgressView()
        }
    }

    private func conflictCard(_ conflict: MergeConflict, in file: GitConflictFile) -> some View {
        let choice = choices[file.id]?[conflict.id]
        let isEditing = editing[file.id]?[conflict.id] != nil
        return VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(conflict.label).font(.system(size: 12.5, weight: .semibold)).lineLimit(2)
                Spacer()
                Group {
                    choiceButton("Meine", .ours, conflict, file)
                    choiceButton("Andere", .theirs, conflict, file)
                    if conflict.allowsBoth { choiceButton("Beide", .both, conflict, file) }
                    Button(isEditing ? "Fertig" : "Selbst bearbeiten") {
                        if isEditing {
                            let text = editing[file.id]?[conflict.id] ?? ""
                            choices[file.id, default: [:]][conflict.id] = .custom(text)
                            editing[file.id]?[conflict.id] = nil
                        } else {
                            editing[file.id, default: [:]][conflict.id] = conflict.ours ?? conflict.theirs ?? ""
                        }
                    }
                }
                .controlSize(.small)
            }
            if isEditing {
                TextEditor(text: Binding(get: { editing[file.id]?[conflict.id] ?? "" }, set: { editing[file.id, default: [:]][conflict.id] = $0 }))
                    .font(.system(size: 12.5))
                    .frame(minHeight: 90)
                    .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Theme.border))
            } else {
                HStack(alignment: .top, spacing: 10) {
                    version("GEMEINSAMER STAND", conflict.base, tint: Theme.textTertiary, chosen: false)
                    version("DEINE", conflict.ours, tint: Theme.accent, chosen: choice == nil || choice == .ours || choice == .both)
                    version("ANDERE", conflict.theirs, tint: Theme.warning, chosen: choice == .theirs || choice == .both)
                }
                if case .custom(let text) = choice {
                    version("EIGENE FASSUNG", text, tint: Theme.success, chosen: true)
                }
            }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 9).fill(Theme.ink.opacity(0.035)))
    }

    private func choiceButton(_ title: String, _ value: MergeChoice, _ conflict: MergeConflict, _ file: GitConflictFile) -> some View {
        let current = choices[file.id]?[conflict.id] ?? .ours
        return Button(title) { choices[file.id, default: [:]][conflict.id] = value }
            .buttonStyle(.bordered)
            .tint(current == value ? Theme.accent : nil)
    }

    private func version(_ title: String, _ text: String?, tint: Color, chosen: Bool) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.system(size: 10, weight: .semibold)).foregroundStyle(tint)
            Text(text ?? "– nicht vorhanden –")
                .font(.system(size: 12.5))
                .foregroundStyle(text == nil ? Theme.textTertiary : Theme.textPrimary)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .background(RoundedRectangle(cornerRadius: 6).fill(tint.opacity(chosen ? 0.12 : 0.04)))
        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(chosen ? tint.opacity(0.6) : .clear))
    }

    private var footer: some View {
        HStack {
            if let error { Text(error).font(.system(size: 12)).foregroundStyle(Theme.danger).lineLimit(2) }
            Spacer()
            Button("Später") { dismiss() }
            Button("Zusammenführen abbrechen", role: .destructive) {
                Task { await run("Abbrechen …") { try await app.git.abortMerge(); dismiss() } }
            }
            Button("Zusammenführen abschließen") {
                Task { await run("Abschließen …") { try await app.git.finishMerge(); dismiss() } }
            }
            .buttonStyle(.borderedProminent)
            .disabled(!files.isEmpty || working != nil)
        }
        .controlSize(.small)
        .padding(.horizontal, 18)
        .padding(.vertical, 10)
    }

    private func setAll(_ file: GitConflictFile, _ value: MergeChoice) {
        for conflict in file.merge?.conflicts ?? [] { choices[file.id, default: [:]][conflict.id] = value }
    }

    private func load() async {
        do {
            files = try await app.git.conflictFiles()
            if selection == nil || !files.contains(where: { $0.id == selection }) { selection = files.first?.id }
        } catch {
            self.error = error.localizedDescription
        }
        loaded = true
    }

    private func resolve(_ file: GitConflictFile, whole: MergeChoice? = nil) async {
        await run("Übernehmen …") {
            try await app.git.resolve(file, choices: choices[file.id] ?? [:], whole: whole)
            choices[file.id] = nil
            await load()
        }
    }

    private func run(_ label: String, _ body: () async throws -> Void) async {
        working = label
        error = nil
        defer { working = nil }
        do { try await body() } catch { self.error = error.localizedDescription }
    }
}
