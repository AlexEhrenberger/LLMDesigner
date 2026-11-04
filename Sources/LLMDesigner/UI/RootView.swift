import SwiftUI

struct RootView: View {
    @Environment(AppModel.self) private var app
    @Environment(LibrarySession.self) private var session
    @State private var workspaceWidth: CGFloat = 0

    var body: some View {
        Group {
            if let session = app.conversation {
                ConversationView(session: session)
                    .frame(minWidth: MainWindow.conversationMinSize.width, minHeight: MainWindow.conversationMinSize.height)
            } else {
                workspace
                    .frame(minWidth: 760, minHeight: 520)
            }
        }
        .background(Theme.background)
        .overlay(alignment: .top) { ActionFlashBadge() }
        .ignoresSafeArea()
        .background(WindowConfigurator())
        .tint(Theme.accent)
        .onAppear { MessageContextMenu.install(app: app) }
        .alert("Diktat nicht möglich", isPresented: dictationErrorBinding) {
            Button("OK") {}
        } message: {
            Text(app.dictationError ?? "")
        }
        .alert("Bibliothek", isPresented: libraryMessageBinding) {
            Button("OK") {}
        } message: {
            Text(session.message ?? "")
        }
        .sheet(item: Binding(get: { app.deckSourceRequest }, set: { app.deckSourceRequest = $0 })) { request in
            DeckFromDocumentSheet(request: request)
                .environment(app)
        }
        .alert("PDF-Export fehlgeschlagen", isPresented: exportErrorBinding) {
            Button("OK") {}
        } message: {
            Text(app.exportError ?? "")
        }
    }

    private var workspace: some View {
        HStack(spacing: 0) {
            if app.isSidebarDocked {
                SidebarView()
                    .frame(width: Theme.sidebarWidth)
                    .transition(.move(edge: .leading))
            }
            ZStack {
                switch app.sidebarMode {
                case .chats:
                    if app.citationStudioOpen {
                        CitationStudioScreen()
                            .transition(.opacity)
                    } else if app.storiesStudioOpen {
                        StoriesStudioScreen()
                            .transition(.opacity)
                    } else if app.selectedPresentation != nil {
                        PresenterScreen()
                            .transition(.asymmetric(insertion: .opacity, removal: .opacity))
                    } else if app.selectedDocumentID != nil {
                        WriterScreen()
                            .transition(.asymmetric(insertion: .identity, removal: .opacity))
                    } else {
                        ChatScreen()
                            .transition(.asymmetric(
                                insertion: .opacity,
                                removal: .modifier(active: DissolveEffect(amount: 1), identity: DissolveEffect(amount: 0))
                            ))
                    }
                case .skills: SkillLibraryScreen()
                case .personas: PersonaLibraryScreen()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .animation(.easeInOut(duration: 0.4), value: app.selectedDocumentID == nil)
            .animation(.easeInOut(duration: 0.25), value: app.citationStudioOpen)
            .animation(.easeInOut(duration: 0.25), value: app.storiesStudioOpen)
            if showsChatPower, app.isPanelDocked {
                PowerPanel()
                    .frame(width: Theme.powerWidth)
                    .transition(.move(edge: .trailing))
            } else if showsChatOutline, app.isPanelDocked, let chat = app.selectedChat {
                OutlinePanel(chat: chat)
                    .frame(width: Theme.outlineWidth)
                    .transition(.move(edge: .trailing))
            }
        }
        // In a narrow window the chat's outline and the sidebar lie over the content (the studios lay out their own panel).
        .overlay {
            FloatingPanel(isShown: (showsChatOutline || showsChatPower) && app.panelCollapsed && app.panelOverlay, edge: .trailing,
                          width: showsChatPower ? Theme.powerWidth : Theme.outlineWidth) {
                if showsChatPower {
                    PowerPanel()
                } else if let chat = app.selectedChat {
                    OutlinePanel(chat: chat)
                }
            }
        }
        .overlay {
            FloatingPanel(isShown: app.sidebarCollapsed && app.sidebarOverlay, edge: .leading, width: Theme.sidebarWidth) {
                SidebarView()
            }
        }
        .clipped()
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { workspaceWidth = $0 }
        .onChange(of: foldingKey) { _, _ in foldSidebars() }
        // Whatever is opened from the sidebar gets the room: the sidebar over it closes.
        .onChange(of: openedKey) { _, _ in app.closeOverlays() }
    }

    private var showsChatOutline: Bool {
        app.sidebarMode == .chats && app.selectedDocumentID == nil && !app.citationStudioOpen && !app.storiesStudioOpen && app.isOutlinePanelShown && app.selectedChat != nil
    }

    /// The power access stands beside the chat even when the chat has no contents yet.
    private var showsChatPower: Bool {
        app.sidebarMode == .chats && app.selectedDocumentID == nil && !app.citationStudioOpen && !app.storiesStudioOpen && app.isPanelShown && app.power.isOn
    }

    /// What decides whether the sidebars fit: the width and the screen, whose content needs more or less room.
    private var foldingKey: [Double] {
        [Double(workspaceWidth), contentMinimum, app.sidebarVisible ? 1 : 0, app.power.isOn ? 1 : 0]
    }

    private var openedKey: String {
        "\(app.selectedChatID?.uuidString ?? "")|\(app.selectedDocumentID?.uuidString ?? "")|\(app.sidebarMode)|\(app.citationStudioOpen)|\(app.storiesStudioOpen)"
    }

    /// The room the content needs before a sidebar may stand beside it: the studios have a sheet and a toolbar to show.
    private var contentMinimum: CGFloat {
        app.sidebarMode == .chats && (app.selectedDocumentID != nil || app.citationStudioOpen || app.storiesStudioOpen) ? (app.storiesStudioOpen ? 980 : 880) : 620
    }

    /// The sidebar folds away when the content would get too narrow beside it; the panel on the right before it.
    private func foldSidebars() {
        guard workspaceWidth > 0 else { return }
        let sidebar = workspaceWidth - Theme.sidebarWidth < contentMinimum
        let besideSidebar = app.sidebarVisible && !sidebar ? Theme.sidebarWidth : 0
        let panel = workspaceWidth - besideSidebar - app.rightPanelWidth < contentMinimum
        if app.sidebarCollapsed != sidebar {
            app.sidebarCollapsed = sidebar
            app.sidebarOverlay = false
        }
        if app.panelCollapsed != panel {
            app.panelCollapsed = panel
            app.panelOverlay = false
        }
    }

    private var dictationErrorBinding: Binding<Bool> {
        Binding(get: { app.dictationError != nil }, set: { if !$0 { app.dictationError = nil } })
    }

    private var libraryMessageBinding: Binding<Bool> {
        Binding(get: { session.message != nil }, set: { if !$0 { session.message = nil } })
    }

    private var exportErrorBinding: Binding<Bool> {
        Binding(get: { app.exportError != nil }, set: { if !$0 { app.exportError = nil } })
    }
}

/// The chat fading out, going soft and sinking back a little when Writer Studio opens.
private struct DissolveEffect: ViewModifier {
    let amount: CGFloat

    func body(content: Content) -> some View {
        content
            .opacity(1 - amount)
            .blur(radius: 14 * amount)
            .scaleEffect(1 - 0.04 * amount)
    }
}
