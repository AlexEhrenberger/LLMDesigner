import SwiftUI

struct RootView: View {
    @Environment(AppModel.self) private var app
    @Environment(LibrarySession.self) private var session

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
        .ignoresSafeArea()
        .background(WindowConfigurator())
        .preferredColorScheme(.dark)
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
        .alert("PDF-Export fehlgeschlagen", isPresented: exportErrorBinding) {
            Button("OK") {}
        } message: {
            Text(app.exportError ?? "")
        }
    }

    private var workspace: some View {
        HStack(spacing: 0) {
            if app.sidebarVisible {
                SidebarView()
                    .frame(width: Theme.sidebarWidth)
                    .transition(.move(edge: .leading))
            }
            ZStack {
                switch app.sidebarMode {
                case .chats:
                    if app.selectedDocumentID != nil {
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
            if app.sidebarMode == .chats, app.selectedDocumentID == nil, app.isOutlinePanelShown, let chat = app.selectedChat {
                OutlinePanel(chat: chat)
                    .frame(width: Theme.outlineWidth)
                    .transition(.move(edge: .trailing))
            }
        }
        .clipped()
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
