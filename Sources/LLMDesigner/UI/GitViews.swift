import SwiftUI

/// Under the library's name: the branch and how much has changed. A click opens Git in the power access.
struct GitStatusLine: View {
    @Environment(AppModel.self) private var app
    @State private var hovering = false

    var body: some View {
        let git = app.git
        if git.isEnabled {
            Button {
                app.showGit()
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "arrow.triangle.branch")
                        .font(.system(size: 10.5, weight: .semibold))
                        .foregroundStyle(git.problem == nil ? Theme.textTertiary : Theme.danger)
                        .frame(width: 16)
                    Text(git.branch ?? "–")
                        .font(.system(size: 11.5, weight: .medium))
                        .foregroundStyle(Theme.textSecondary)
                        .lineLimit(1)
                    if git.changeCount > 0 {
                        Text("· \(git.changeCount) \(git.changeCount == 1 ? "Änderung" : "Änderungen")")
                            .font(.system(size: 11.5))
                            .foregroundStyle(Theme.textTertiary)
                            .lineLimit(1)
                    }
                    Spacer(minLength: 0)
                    if let status = git.status, status.upstream != nil, status.ahead + status.behind > 0 {
                        Text(status.behind > 0 ? "↑\(status.ahead) ↓\(status.behind)" : "↑\(status.ahead)")
                            .font(.system(size: 10.5, design: .monospaced))
                            .foregroundStyle(Theme.textTertiary)
                    }
                }
                .padding(.horizontal, 8)
                .frame(height: 22)
                .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(hovering ? Theme.hover : .clear))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .onHover { hovering = $0 }
            .help(git.problem ?? "Git: Änderungen ansehen und committen")
        }
    }
}

/// A change from outside that met unsaved work, or that waits for running work to finish.
struct GitNoticeBar: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        if let notice = app.git.notice {
            HStack(spacing: 10) {
                Image(systemName: "arrow.triangle.2.circlepath")
                    .foregroundStyle(Theme.warning)
                Text(notice.message)
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 8)
                switch notice.kind {
                case .conflict(let items):
                    if let first = items.first {
                        Button("Vergleichen") {
                            app.compare(CompareRequest(item: first, left: .workingTree, right: .memory, allowsTakingOver: false))
                        }
                    }
                    Button("Meine behalten") { app.git.keepVersionHere() }
                    Button("Neu laden") { app.git.takeVersionFromDisk() }
                        .buttonStyle(.borderedProminent)
                case .deferred:
                    Button("Später") { app.git.notice = nil }
                    Button("Jetzt neu laden") {
                        app.git.notice = nil
                        app.requestLibraryReload()
                    }
                    .buttonStyle(.borderedProminent)
                }
            }
            .controlSize(.small)
            .padding(.horizontal, 14)
            .padding(.vertical, 9)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Theme.sidebar))
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Theme.warning.opacity(0.5)))
            .shadow(color: .black.opacity(0.18), radius: 10, y: 3)
            .frame(maxWidth: 720)
            .padding(.top, 44)
            .padding(.horizontal, 20)
            .transition(.move(edge: .top).combined(with: .opacity))
        }
    }
}

extension AppModel {
    /// Opens Git in the power access.
    func showGit() {
        power.module = .git
        if !power.isOn { togglePower() } else if !isPanelShown { toggleOutlinePanel() }
    }
}

/// Versions of a document in its context menu: Fassungen, and with Git the history.
struct DocumentVersionMenu: View {
    @Environment(AppModel.self) private var app
    let document: WriterDocument

    var body: some View {
        Menu("Versionen", systemImage: "clock.arrow.circlepath") {
            Button("Neue Fassung", systemImage: "doc.on.doc") { app.newVariant(of: document.id) }
            if let main = app.mainVersion(of: document) {
                Button("Mit Hauptfassung vergleichen", systemImage: "arrow.left.arrow.right") {
                    app.compare(CompareRequest(item: nil, left: .document(document.id), right: .document(main.id)))
                }
            }
            let variants = app.variants(of: document.id)
            if !variants.isEmpty {
                Menu("Fassung vergleichen") {
                    ForEach(variants) { variant in
                        Button(variant.displayTitle) {
                            app.compare(CompareRequest(item: nil, left: .document(variant.id), right: .document(document.id)))
                        }
                    }
                }
            }
            if app.git.isEnabled, let item = app.git.item(forRecord: document.id) {
                Divider()
                Button("Mit letztem Commit vergleichen", systemImage: "arrow.triangle.branch") {
                    app.compare(CompareRequest(item: item, left: .commit("HEAD"), right: .workingTree))
                }
                Button("Verlauf zeigen", systemImage: "clock") {
                    app.selectDocument(document.id)
                    app.showGit()
                }
            }
        }
    }
}
