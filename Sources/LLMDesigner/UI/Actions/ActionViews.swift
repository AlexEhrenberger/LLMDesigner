import SwiftUI
import LLMDProtocol

enum ActivityWindow {
    static let id = "activity"
}

/// A short sign over the open document when the terminal or an agent changed it.
struct ActionFlashBadge: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        if let flash = app.actionFlash, flash.document == app.selectedDocumentID {
            Label("Geändert über \(flash.channel.label)", systemImage: "sparkles")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Theme.accent)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(.regularMaterial, in: Capsule())
                .overlay(Capsule().strokeBorder(Theme.accent.opacity(0.6)))
                .padding(.top, 34)
                .transition(.opacity)
                .allowsHitTesting(false)
                .id(flash.id)
        }
    }
}

/// The protocol: time, channel, run, action, what the run had seen, what the rule decided and how it ended.
struct ActivityView: View {
    @State private var channel: ActionChannel?

    private var log: ActionLog? { ActionHub.shared?.registry.log }

    private var entries: [ActionLogEntry] {
        (log?.entries ?? []).filter { channel == nil || $0.channel == channel }.reversed()
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Picker("Kanal", selection: $channel) {
                    Text("Alle").tag(ActionChannel?.none)
                    ForEach(ActionChannel.allCases, id: \.self) { channel in
                        Text(channel.label).tag(ActionChannel?.some(channel))
                    }
                }
                .frame(maxWidth: 220)
                Spacer()
                Text("Nur diese Sitzung. Es werden keine Inhalte protokolliert.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                Button("Leeren") { log?.clear() }
            }
            .padding(12)
            Table(entries) {
                TableColumn("Zeit") { Text($0.time.formatted(date: .omitted, time: .standard)) }.width(58)
                TableColumn("Kanal") { Text($0.channel.label) }.width(62)
                TableColumn("Lauf") { Text($0.run.prefix(8)).font(.system(size: 11, design: .monospaced)) }.width(62)
                TableColumn("Action") { Text($0.action).font(.system(size: 11, design: .monospaced)) }.width(min: 120, ideal: 170)
                TableColumn("Ziel") { Text($0.target ?? "").lineLimit(1) }.width(min: 60, ideal: 100)
                TableColumn("Herkunft") { entry in
                    Text(Self.origin(entry)).foregroundStyle(entry.hadUntrusted || entry.hadSensitive ? Color.orange : Color.secondary)
                }.width(58)
                TableColumn("Regel") { Text($0.decision) }.width(70)
                TableColumn("Ergebnis") { entry in
                    Text(entry.error ?? "ok").foregroundStyle(entry.error == nil ? Color.secondary : Color.red).lineLimit(1).help(entry.error ?? "")
                }.width(min: 60, ideal: 110)
            }
        }
        .frame(minWidth: 640, minHeight: 300)
    }

    /// A: the run had read something foreign. B: something private.
    private static func origin(_ entry: ActionLogEntry) -> String {
        [entry.hadUntrusted ? "A" : nil, entry.hadSensitive ? "B" : nil].compactMap { $0 }.joined(separator: "+").ifEmpty("–")
    }
}

private extension String {
    func ifEmpty(_ other: String) -> String { isEmpty ? other : self }
}

/// Settings: how much the terminal, MCP clients and the chat may do on their own; where they may export; the tool.
struct ActionSettings: View {
    @Environment(AppModel.self) private var app
    @Environment(\.openWindow) private var openWindow
    @State private var installMessage: String?
    @State private var revision = 0

    private static let levelWidth: CGFloat = 112

    private var approval: ActionApproval? { ActionHub.shared?.registry.approval }

    var body: some View {
        Section {
            LabeledContent("Freigabe je Kanal") {
                HStack(spacing: 8) {
                    ForEach(ActionKind.allCases, id: \.self) { kind in
                        Text(kind.label.capitalized)
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(Theme.textSecondary)
                            .frame(width: Self.levelWidth, alignment: .leading)
                    }
                }
            }
            ForEach([ActionChannel.cli, .mcp, .chat], id: \.self) { channel in
                LabeledContent(channel.label) {
                    HStack(spacing: 8) {
                        ForEach(ActionKind.allCases, id: \.self) { kind in
                            Picker(kind.label, selection: level(channel, kind)) {
                                ForEach(ActionPolicy.Level.allCases, id: \.self) { Text($0.label).tag($0) }
                            }
                            .labelsHidden()
                            .frame(width: Self.levelWidth)
                        }
                    }
                }
            }
            LabeledContent("Exportordner") {
                HStack(spacing: 8) {
                    Text(ActionExportFolder.url(settings: app.settings).path)
                        .foregroundStyle(Theme.textSecondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Button("Ändern …") { chooseExportFolder() }
                }
                .id(revision)
            }
            LabeledContent("Terminal-Werkzeug") {
                HStack(spacing: 8) {
                    Text(installMessage ?? (CLIInstaller.isInstalled ? "llmd ist installiert" : "nicht installiert"))
                        .foregroundStyle(Theme.textSecondary)
                        .lineLimit(2)
                    Button("Kommandozeilenwerkzeug installieren") { install() }
                }
            }
            Button("Aktivität anzeigen …") { openWindow(id: ActivityWindow.id) }
            Button("Action-Katalog …") { openWindow(id: ActionCatalogWindow.id) }
        } header: {
            Text("Terminal und Agenten")
        } footer: {
            Text("Unabhängig von diesen Stufen fragt die App immer nach, wenn ein Lauf fremde Inhalte gelesen hat und danach private Daten lesen, etwas löschen oder etwas nach außen geben würde. In den Exportordner darf ohne Rückfrage geschrieben werden, solange der Lauf nichts Fremdes gelesen hat.")
                .foregroundStyle(Theme.textTertiary)
        }
    }

    private func level(_ channel: ActionChannel, _ kind: ActionKind) -> Binding<ActionPolicy.Level> {
        Binding(
            get: { _ = revision; return approval?.level(channel: channel, kind: kind, settings: app.settings) ?? ActionPolicy.defaultLevel(channel: channel, kind: kind) },
            set: { value in
                approval?.setLevel(value, channel: channel, kind: kind, settings: app.settings)
                revision += 1
            }
        )
    }

    private func chooseExportFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.prompt = "Wählen"
        panel.directoryURL = ActionExportFolder.url(settings: app.settings)
        guard panel.runModal() == .OK, let url = panel.url else { return }
        ActionExportFolder.set(url, settings: app.settings)
        revision += 1
    }

    private func install() {
        do {
            let link = try CLIInstaller.install()
            installMessage = CLIInstaller.isOnPath ? "Installiert: \(link.path)" : "Installiert: \(link.path). Bitte ~/.local/bin in den PATH aufnehmen."
        } catch {
            installMessage = error.localizedDescription
        }
    }
}

/// The link from `~/.local/bin/llmd` to the tool inside the app.
enum CLIInstaller {
    enum Failure: Error, LocalizedError {
        case noTool
        case occupied(String)

        var errorDescription: String? {
            switch self {
            case .noTool: "In dieser App fehlt das Werkzeug. Bitte mit scripts/build-app.sh bauen."
            case .occupied(let path): "Unter \(path) liegt schon eine andere Datei. Sie bleibt, wie sie ist."
            }
        }
    }

    static var defaultDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".local/bin", isDirectory: true)
    }

    static var helper: URL {
        Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/llmd")
    }

    static var isInstalled: Bool {
        let link = defaultDirectory.appendingPathComponent("llmd").path
        return (try? FileManager.default.destinationOfSymbolicLink(atPath: link)) == helper.path
    }

    static var isOnPath: Bool {
        (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":").contains { $0 == defaultDirectory.path }
    }

    /// Makes or renews the link. A link can be renewed because it only says where the app is; a real file isn't ours.
    @discardableResult
    static func install(helper: URL = helper, into directory: URL = defaultDirectory) throws -> URL {
        let manager = FileManager.default
        guard manager.isExecutableFile(atPath: helper.path) else { throw Failure.noTool }
        try manager.createDirectory(at: directory, withIntermediateDirectories: true)
        let link = directory.appendingPathComponent("llmd")
        if (try? manager.destinationOfSymbolicLink(atPath: link.path)) != nil {
            try manager.removeItem(at: link)
        } else if manager.fileExists(atPath: link.path) {
            throw Failure.occupied(link.path)
        }
        try manager.createSymbolicLink(at: link, withDestinationURL: helper)
        return link
    }
}
