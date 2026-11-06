import AppKit
import SwiftUI

/// The symbol in the menu bar: the most frequent starts without looking for the app's window first.
/// Every entry brings the app to the front, because a menu bar click leaves another app active.
struct MenuBarMenu: View {
    @Environment(AppModel.self) private var app
    @Environment(\.openWindow) private var openWindow

    /// How many presentations "Präsentation öffnen" lists; more belong in the sidebar.
    private static let recentPresentationCount = 8

    var body: some View {
        Button("Neuer Chat") {
            showMain { app.newChat() }
        }
        Button("Neues Dokument") {
            showMain { app.newDocument() }
        }
        Menu("Präsentation öffnen") {
            Button("Neue Präsentation") { showMain { app.newPresentation() } }
            let recent = recentPresentations
            if !recent.isEmpty {
                Divider()
                ForEach(recent) { document in
                    Button(document.displayTitle) { showMain { app.selectDocument(document.id) } }
                }
            }
        }
        Button("Zitat erstellen …") {
            showMain {
                app.openCitationStudio()
                app.citationStudioCommand = .quickAdd
            }
        }
        Button("Stories Studio öffnen") {
            showMain { app.openStoriesStudio() }
        }
        Divider()
        Button("Mini-Chat öffnen") {
            openMiniChat()
        }
        Button(app.conversation == nil ? "Gespräch beginnen" : "Gespräch beenden") {
            // The conversation shrinks the main window, so it must be there first.
            showMain(delay: 0.3) { app.toggleConversation() }
        }
        .disabled(app.conversation == nil && !app.canStartConversation)
        Button("Bildschirmfoto in den Mini-Chat") {
            openMiniChat()
            // The menu and a freshly opened window need a moment; otherwise the menu is in the picture or the mini
            // chat doesn't count as open yet.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { app.glanceAtScreen() }
        }
        .disabled(app.miniChat.isGlancing)
        Divider()
        Button("LLM Designer zeigen") { showMain {} }
        Button("LLM Designer beenden") { NSApp.terminate(nil) }
    }

    private var recentPresentations: [WriterDocument] {
        Array(app.documents.filter(\.isPresentation).sorted { $0.updatedAt > $1.updatedAt }.prefix(Self.recentPresentationCount))
    }

    private func showMain(delay: TimeInterval = 0, _ action: @escaping () -> Void) {
        openWindow(id: "main")
        NSApp.activate()
        if delay > 0 {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: action)
        } else {
            action()
        }
    }

    /// Keeps the mini chat's chat; a new one only if it has none yet (as `OpenInMiniChat` decides).
    private func openMiniChat() {
        OpenInMiniChat(app: app, openWindow: openWindow)(app.miniChat.chatID)
        NSApp.activate()
    }
}
