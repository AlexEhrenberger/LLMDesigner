import AppKit

/// SwiftUI's selectable text answers right-clicks with its own text menu, so a `.contextMenu` on a
/// message never appears. Instead, right-clicks (and control-clicks) on a message open this menu.
@MainActor
enum MessageContextMenu {
    private static var monitor: Any?
    /// The model of the open library; it changes when another library is opened.
    private static weak var currentApp: AppModel?

    static func install(app: AppModel) {
        currentApp = app
        guard monitor == nil else { return }
        // Local monitors are called on the main thread.
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.rightMouseDown, .leftMouseDown]) { event in
            let isContextClick = event.type == .rightMouseDown || event.modifierFlags.contains(.control)
            // Only the main window shows messages; sheets, popovers and the presentation window have their own menus.
            guard isContextClick, let app = currentApp, let window = event.window, window === MainWindow.window,
                  let view = window.contentView else { return event }
            // AppKit measures from the bottom left, SwiftUI's global space from the top left.
            let point = CGPoint(x: event.locationInWindow.x, y: view.bounds.height - event.locationInWindow.y)
            guard let messageID = app.messageID(at: point), let message = app.message(messageID),
                  !(message.role == .assistant && app.isGenerating && message.id == app.selectedChat?.messages.last?.id),
                  app.editingMessageID != messageID else {
                return event
            }

            let selection = app.selection(SelectedText.read(), in: messageID)
            let menu = NSMenu()
            menu.addItem(ActionMenuItem(selection == nil ? "Lesezeichen für diese Nachricht anlegen" : "Lesezeichen anlegen", symbol: "bookmark") {
                app.addBookmark(selectedText: selection, near: messageID)
            })
            menu.addItem(.separator())
            if message.role == .assistant {
                menu.addItem(ActionMenuItem("Antwort kopieren", symbol: "doc.on.doc") { app.copyAnswer(messageID) })
                menu.addItem(ActionMenuItem("Antwort als PDF exportieren …", symbol: "arrow.down.doc") { app.exportAnswer(messageID) })
                let isReading = app.speakingMessageID == messageID
                menu.addItem(ActionMenuItem(isReading ? "Vorlesen beenden" : "Antwort vorlesen", symbol: isReading ? "stop.fill" : "speaker.wave.2") {
                    app.toggleSpeaking(messageID)
                })
                menu.addItem(.separator())
                menu.addItem(ActionMenuItem("Ab hier in neuem Chat abzweigen", symbol: "arrow.triangle.branch") {
                    app.branchChat(at: messageID)
                })
            } else {
                if !message.content.isEmpty {
                    menu.addItem(ActionMenuItem("Nachricht kopieren", symbol: "doc.on.doc") { app.copyToPasteboard(message.content) })
                }
                menu.addItem(ActionMenuItem("Bearbeiten und abzweigen …", symbol: "pencil") { app.startEditing(messageID) })
            }
            // The chat turns into a research: Rechercherista takes the question (the marked text or the message).
            let topic = (selection ?? (message.role == .user ? message.content : "")).trimmingCharacters(in: .whitespacesAndNewlines)
            menu.addItem(.separator())
            menu.addItem(ActionMenuItem(topic.isEmpty ? "Recherche zu diesem Chat starten …" : "Recherche dazu starten …", symbol: StudioApplication.research.symbol) {
                let question = topic.isEmpty ? (app.selectedChat?.title ?? "") : String(topic.prefix(600))
                app.newResearch(question: question, fromChat: app.selectedChatID)
            })
            if selection != nil {
                menu.addItem(.separator())
                menu.addItem(ActionMenuItem("Markierten Text kopieren", symbol: "text.cursor") {
                    NSApp.sendAction(#selector(NSText.copy(_:)), to: nil, from: nil)
                })
            }
            NSMenu.popUpContextMenu(menu, with: event, for: view)
            return nil
        }
    }
}

/// Reads the text the user marked in the chat, without touching the clipboard. SwiftUI's selectable
/// `Text` is backed by a field editor (an `NSTextView`), which holds the selection while it is first responder.
@MainActor
enum SelectedText {
    static func read() -> String? {
        // Only read-only text counts: the composer and the search field are editable and not part of the chat.
        guard let textView = (NSApp.keyWindow ?? NSApp.mainWindow)?.firstResponder as? NSTextView,
              !textView.isEditable else { return nil }
        let range = textView.selectedRange()
        let content = textView.string as NSString
        guard range.length > 0, NSMaxRange(range) <= content.length else { return nil }
        let text = content.substring(with: range).trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : text
    }
}

private final class ActionMenuItem: NSMenuItem {
    private let handler: () -> Void

    init(_ title: String, symbol: String, handler: @escaping () -> Void) {
        self.handler = handler
        super.init(title: title, action: #selector(invoke), keyEquivalent: "")
        target = self
        image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
    }

    required init(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    @objc private func invoke() {
        handler()
    }
}
