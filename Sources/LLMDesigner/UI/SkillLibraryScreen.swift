import SwiftUI

/// Main area while the sidebar shows the skills: the editor of the selected skill.
struct SkillLibraryScreen: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 2) {
                if !app.isSidebarDocked {
                    SidebarToggleButton()
                    IconButton(systemName: "plus", help: "Neuer Skill (⌥⌘N)", frameSize: Theme.titleBarControlSize) { app.createSkill() }
                        .padding(.trailing, 6)
                }
                Text("Skills")
                    .font(.system(size: 14.5, weight: .semibold))
                    .foregroundStyle(Theme.textPrimary)
                    .padding(.horizontal, 10)
                Spacer(minLength: 0)
            }
            .padding(.leading, app.isSidebarDocked ? 14 : Theme.trafficLightInset)
            .padding(.trailing, 14)
            .frame(height: Theme.titleBarHeight)
            .padding(.bottom, Theme.topBarBottomPadding)
            .background(WindowDragArea())

            if let skill = app.selectedSkill {
                SkillEditor(skill: skill)
                    .id(skill.id)
            } else {
                SkillLibraryIntro()
            }
        }
        .background(Theme.background)
    }
}

private struct SkillEditor: View {
    @Environment(AppModel.self) private var app
    let skill: Skill
    @State private var pendingDelete = false
    @State private var choosingSymbol = false
    @FocusState private var nameFocused: Bool

    var body: some View {
        let tokens = SkillPrompt.estimatedTokens(skill.instructions)
        let usage = app.chatCount(using: skill.id)

        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top, spacing: 14) {
                Button { choosingSymbol.toggle() } label: {
                    Image(systemName: skill.symbol ?? Skill.defaultSymbol)
                        .font(.system(size: 20, weight: .medium))
                        .foregroundStyle(Theme.accent)
                        .frame(width: 48, height: 48)
                        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Theme.accent.opacity(0.12)))
                        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Theme.accent.opacity(0.25)))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Symbol wählen")
                .popover(isPresented: $choosingSymbol, arrowEdge: .bottom) {
                    SymbolGrid(selected: skill.symbol ?? Skill.defaultSymbol) { symbol in
                        app.updateSkill(skill.id) { $0.symbol = symbol }
                        choosingSymbol = false
                    }
                }

                VStack(alignment: .leading, spacing: 4) {
                    TextField("", text: text(\.name), prompt: Text("Name des Skills").foregroundStyle(Theme.textTertiary))
                        .textFieldStyle(.plain)
                        .font(.system(size: 24, weight: .semibold))
                        .foregroundStyle(Theme.textPrimary)
                        .focused($nameFocused)
                    TextField("", text: text(\.summary), prompt: Text("Kurzbeschreibung für die Bibliothek (optional)").foregroundStyle(Theme.textTertiary))
                        .textFieldStyle(.plain)
                        .font(.system(size: 14))
                        .foregroundStyle(Theme.textSecondary)
                }
            }
            .padding(.bottom, 16)

            HStack(spacing: 8) {
                FolderMenu(skill: skill)
                if usage > 0 {
                    Tag(text: "In \(usage) \(usage == 1 ? "Chat" : "Chats") eingeschaltet")
                }
                Spacer(minLength: 0)
            }
            .padding(.bottom, 22)

            HStack(alignment: .firstTextBaseline) {
                Text("Anweisungen für das Modell")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Theme.textSecondary)
                Spacer()
                Text("\(skill.instructions.count) Zeichen · ≈ \(tokens) Tokens")
                    .font(.system(size: 11.5).monospacedDigit())
                    .foregroundStyle(Theme.textTertiary)
            }
            .padding(.bottom, 8)

            InstructionsEditor(text: text(\.instructions))
                .frame(minHeight: 180, maxHeight: .infinity)

            Text("Wird an den System-Prompt jedes Chats angehängt, in dem der Skill eingeschaltet ist. Mehrere Skills kommen in der Reihenfolge hinzu, in der du sie im Chat einschaltest. Änderungen gelten ab der nächsten Nachricht.")
                .font(.system(size: 11.5))
                .foregroundStyle(Theme.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 8)

            HStack(spacing: 8) {
                ActionPill(title: "In neuem Chat verwenden", symbol: "square.and.pencil", isProminent: true) {
                    app.startChat(with: skill.id)
                }
                if let chat = app.selectedChat, app.persona(of: chat) == nil {
                    let isOn = app.skills(of: chat).contains { $0.id == skill.id }
                    ActionPill(
                        title: isOn ? "Eingeschaltet in „\(chat.title)“" : "In „\(chat.title)“ einschalten",
                        symbol: isOn ? "checkmark.circle.fill" : "circle",
                        isProminent: false
                    ) {
                        app.toggleSkill(skill.id)
                    }
                    .help(isOn ? "Für den zuletzt geöffneten Chat ausschalten" : "Für den zuletzt geöffneten Chat einschalten")
                }
                Spacer(minLength: 12)
                IconButton(systemName: "plus.square.on.square", help: "Duplizieren", size: 13.5) { app.duplicateSkill(skill.id) }
                IconButton(systemName: "trash", help: "Skill löschen", size: 13.5) { pendingDelete = true }
            }
            .padding(.top, 18)
        }
        .frame(maxWidth: 760)
        .padding(.horizontal, 32)
        .padding(.top, 18)
        .padding(.bottom, 24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .task {
            guard app.newSkillID == skill.id else { return }
            app.newSkillID = nil
            try? await Task.sleep(for: .milliseconds(80))
            nameFocused = true
        }
        .alert("Skill löschen?", isPresented: $pendingDelete) {
            Button("Löschen", role: .destructive) { app.deleteSkill(skill.id) }
            Button("Abbrechen", role: .cancel) {}
        } message: {
            Text("„\(skill.displayName)“ wird dauerhaft gelöscht" + (usage == 0 ? "." : " und in \(usage) \(usage == 1 ? "Chat" : "Chats") abgeschaltet."))
        }
    }

    private func text(_ field: WritableKeyPath<Skill, String>) -> Binding<String> {
        let id = skill.id
        return Binding(
            get: { app.skill(id)?[keyPath: field] ?? "" },
            set: { value in app.updateSkill(id) { $0[keyPath: field] = value } }
        )
    }
}

/// The skill's instructions: a plain text editor with a hint while it is empty.
private struct InstructionsEditor: View {
    @Binding var text: String

    var body: some View {
        TextEditor(text: $text)
            .font(.system(size: 14))
            .lineSpacing(3)
            .foregroundStyle(Theme.textPrimary)
            .scrollContentBackground(.hidden)
            .padding(.horizontal, 10)
            .padding(.vertical, 12)
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Theme.surface))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Theme.strongBorder))
            .overlay(alignment: .topLeading) {
                if text.isEmpty {
                    Text("Was soll das Modell tun? Zum Beispiel:\n„Du bist ein erfahrener Finanzberater …“\n„Antworte in höchstens drei Sätzen.“\n„Gliedere jede Antwort mit Überschriften und schließe mit einer Tabelle.“")
                        .font(.system(size: 14))
                        .lineSpacing(3)
                        .foregroundStyle(Theme.textTertiary)
                        .padding(.horizontal, 15)
                        .padding(.vertical, 12)
                        .allowsHitTesting(false)
                }
            }
    }
}

/// Folder of the skill, as a small menu.
private struct FolderMenu: View {
    @Environment(AppModel.self) private var app
    let skill: Skill
    @State private var hovering = false

    var body: some View {
        Menu {
            Button("Ohne Ordner") { app.moveSkill(skill.id, to: nil) }
                .disabled(skill.folderID == nil)
            if !app.skillFolders.isEmpty { Divider() }
            ForEach(Folder.sorted(app.skillFolders)) { folder in
                Button(folder.name) { app.moveSkill(skill.id, to: folder.id) }
                    .disabled(folder.id == skill.folderID)
            }
            Divider()
            Button("Neuer Ordner …", systemImage: "folder.badge.plus") { app.moveSkillToNewFolder(skill.id) }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "folder")
                    .font(.system(size: 11.5, weight: .medium))
                Text(app.folderName(skill.folderID) ?? "Ohne Ordner")
                    .font(.system(size: 12.5, weight: .medium))
                Image(systemName: "chevron.down")
                    .font(.system(size: 8.5, weight: .bold))
                    .foregroundStyle(Theme.textTertiary)
            }
            .foregroundStyle(hovering ? Theme.textPrimary : Theme.textSecondary)
            .padding(.horizontal, 10)
            .frame(height: 26)
            .background(Capsule().fill(hovering ? Theme.hover : Theme.ink.opacity(0.04)))
            .overlay(Capsule().strokeBorder(Theme.border))
            .contentShape(Capsule())
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .onHover { hovering = $0 }
        .help("Ordner in der Bibliothek")
    }
}

struct ActionPill: View {
    let title: String
    let symbol: String
    let isProminent: Bool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: symbol)
                    .font(.system(size: 12, weight: .medium))
                Text(title)
                    .font(.system(size: 12.5, weight: .medium))
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .foregroundStyle(isProminent ? Theme.accent : (hovering ? Theme.textPrimary : Theme.textSecondary))
            .padding(.horizontal, 12)
            .frame(height: 30)
            .background(Capsule().fill(isProminent ? Theme.accent.opacity(hovering ? 0.24 : 0.16) : (hovering ? Theme.hover : Theme.ink.opacity(0.04))))
            .overlay(Capsule().strokeBorder(isProminent ? Theme.accent.opacity(0.35) : Theme.border))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

/// Symbols to tell skills apart in the sidebar and the library.
private struct SymbolGrid: View {
    let selected: String
    let onSelect: (String) -> Void

    static let symbols = [
        Skill.defaultSymbol, "sparkles", "person.fill", "briefcase", "eurosign.circle", "chart.line.uptrend.xyaxis",
        "heart.text.square", "stethoscope", "graduationcap", "brain.head.profile", "lightbulb", "theatermasks",
        "text.quote", "pencil.line", "scissors", "textformat", "list.bullet", "tablecells",
        "doc.richtext", "book", "globe", "music.note", "paintbrush", "chevron.left.forwardslash.chevron.right",
        "hammer", "magnifyingglass", "bubble.left.and.text.bubble.right", "face.smiling", "leaf", "flag",
    ]

    var body: some View {
        LazyVGrid(columns: Array(repeating: GridItem(.fixed(34), spacing: 6), count: 6), spacing: 6) {
            ForEach(Self.symbols, id: \.self) { symbol in
                SymbolCell(symbol: symbol, isSelected: symbol == selected) { onSelect(symbol) }
            }
        }
        .padding(12)
        .background(Theme.elevated)
    }
}

private struct SymbolCell: View {
    let symbol: String
    let isSelected: Bool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(isSelected ? Theme.accent : Theme.textPrimary)
                .frame(width: 34, height: 34)
                .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(isSelected ? Theme.accent.opacity(0.16) : (hovering ? Theme.hover : .clear)))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

/// Shown when no skill is selected: what skills are and how to start.
private struct SkillLibraryIntro: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: Skill.defaultSymbol)
                .font(.system(size: 30, weight: .medium))
                .foregroundStyle(Theme.accent)
                .frame(width: 64, height: 64)
                .background(RoundedRectangle(cornerRadius: 18, style: .continuous).fill(Theme.accent.opacity(0.12)))
            Text("Skills")
                .font(.system(size: 26, weight: .semibold))
                .foregroundStyle(Theme.textPrimary)
            Text("Bausteine für den System-Prompt: eine Rolle, ein Schreibstil, Formatierungsregeln … Im Chat schaltest du über \(Image(systemName: Skill.defaultSymbol)) im Eingabefeld beliebig viele davon ein und kombinierst sie.")
                .font(.system(size: 13.5))
                .foregroundStyle(Theme.textSecondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 440)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 10) {
                ActionPill(title: "Neuer Skill", symbol: "plus", isProminent: true) { app.createSkill() }
                if app.skills.isEmpty {
                    ActionPill(title: "Beispiele anlegen", symbol: "wand.and.stars", isProminent: false) { app.addExampleSkills() }
                        .help("Legt fünf Beispiel-Skills in den Ordnern Rollen, Schreibstil und Formatierung an")
                }
            }
            .padding(.top, 6)
            if !app.skills.isEmpty {
                Text("Oder wähle links einen Skill zum Bearbeiten.")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.textTertiary)
            }
        }
        .padding(28)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
