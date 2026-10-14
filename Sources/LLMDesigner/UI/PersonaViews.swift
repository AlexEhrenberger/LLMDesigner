import AppKit
import SwiftUI

extension Persona {
    /// The colour of the picture, or the app's violet.
    var tintColor: Color { tint.map { Color(hex: $0) } ?? Theme.accent }
}

/// Profile pictures read from disk once; a new picture has a new file name and so a new entry.
@MainActor
enum PersonaAvatarCache {
    private static var images: [String: NSImage] = [:]

    static func image(for persona: Persona) -> NSImage? {
        guard let url = PersonaStore.avatarURL(of: persona) else { return nil }
        let key = url.path
        if let cached = images[key] { return cached }
        guard let image = NSImage(contentsOf: url) else { return nil }
        images[key] = image
        return image
    }
}

/// A persona's round profile picture; without a picture its initials on a gradient in its colour.
struct PersonaAvatar: View {
    let persona: Persona?
    var size: CGFloat = 28

    var body: some View {
        Group {
            if let persona, let image = PersonaAvatarCache.image(for: persona) {
                Image(nsImage: image)
                    .resizable()
                    .interpolation(.high)
                    .aspectRatio(contentMode: .fill)
            } else {
                let tint = persona?.tintColor ?? Theme.accent
                ZStack {
                    Circle().fill(LinearGradient(colors: [tint.opacity(0.6), tint.opacity(0.16)], startPoint: .topLeading, endPoint: .bottomTrailing))
                    if let persona, !persona.name.trimmingCharacters(in: .whitespaces).isEmpty {
                        Text(persona.initials)
                            .font(.system(size: size * 0.38, weight: .semibold, design: .rounded))
                            .foregroundStyle(Color.white.opacity(0.92))
                    } else {
                        Image(systemName: "person.fill")
                            .font(.system(size: size * 0.42))
                            .foregroundStyle(Color.white.opacity(0.7))
                    }
                }
            }
        }
        .frame(width: size, height: size)
        .clipShape(Circle())
        .overlay(Circle().strokeBorder(Color.white.opacity(0.1)))
    }
}

/// The empty chat with a persona: picture, name and the start of the life story instead of the logo.
struct PersonaWelcome<Summary: View>: View {
    let persona: Persona
    @ViewBuilder let summary: Summary

    var body: some View {
        VStack(spacing: 12) {
            PersonaAvatar(persona: persona, size: 96)
                .background(Circle().fill(persona.tintColor.opacity(0.32)).blur(radius: 26))
                .padding(.bottom, 4)
            Text(persona.displayName)
                .font(.system(size: 28, weight: .semibold))
                .foregroundStyle(Theme.textPrimary)
            if let tagline = persona.tagline {
                Text(tagline)
                    .font(.system(size: 13.5))
                    .foregroundStyle(Theme.textSecondary)
                    .multilineTextAlignment(.center)
                    .lineLimit(3)
                    .frame(maxWidth: 480)
            }
            summary
                .padding(.top, 2)
        }
    }
}

// MARK: Composer

/// Composer button for the persona of the chat. Shows the persona's picture and name once one is chosen.
struct PersonaButton: View {
    @Environment(AppModel.self) private var app
    @State private var hovering = false

    var body: some View {
        @Bindable var app = app
        let persona = app.activePersona

        Button { app.isPersonaPickerShown.toggle() } label: {
            HStack(spacing: 6) {
                if let persona {
                    PersonaAvatar(persona: persona, size: 22)
                    Text(Self.shortName(persona))
                        .font(.system(size: 12.5, weight: .medium))
                        .lineLimit(1)
                } else {
                    Image(systemName: Persona.symbol)
                        .font(.system(size: 14.5, weight: .medium))
                }
            }
            .foregroundStyle(foreground(persona))
            .padding(.leading, persona == nil ? 0 : 5)
            .padding(.trailing, persona == nil ? 0 : 11)
            .frame(minWidth: 32, minHeight: 32)
            .background(Capsule().fill(background(persona)))
            .overlay(Capsule().strokeBorder((persona?.tintColor ?? Theme.accent).opacity(persona == nil ? 0 : 0.35)))
            .contentShape(Capsule())
            .animation(.easeOut(duration: 0.15), value: persona?.id)
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(persona.map { "Persona: \($0.displayName) (⇧⌘P)" } ?? "Mit einer Persona sprechen (⇧⌘P)")
        .popover(isPresented: $app.isPersonaPickerShown, arrowEdge: .top) {
            PersonaPickerPanel()
                .environment(app)
        }
    }

    private static func shortName(_ persona: Persona) -> String {
        let name = persona.displayName
        return name.count > 20 ? String(name.prefix(19)) + "…" : name
    }

    private func foreground(_ persona: Persona?) -> Color {
        if persona != nil { return Theme.textPrimary }
        return hovering || app.isPersonaPickerShown ? Theme.textPrimary : Theme.textSecondary
    }

    private func background(_ persona: Persona?) -> Color {
        if let persona { return persona.tintColor.opacity(hovering ? 0.22 : 0.14) }
        return hovering || app.isPersonaPickerShown ? Theme.hover : .clear
    }
}

/// The personas in a popover. In a new chat a click chooses the persona; in a running chat it starts a new chat with it.
private struct PersonaPickerPanel: View {
    @Environment(AppModel.self) private var app
    @State private var query = ""
    @FocusState private var searchFocused: Bool

    var body: some View {
        let visible = app.personas(matching: query)
        let active = app.activePersona
        let isNewChat = app.canChoosePersonaHere

        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(isNewChat ? "Mit wem möchtest du sprechen?" : "Persona")
                    .font(.system(size: 13.5, weight: .semibold))
                    .foregroundStyle(Theme.textPrimary)
                Spacer()
                Button {
                    app.isPersonaPickerShown = false
                    app.showPersonas()
                } label: {
                    Label("Bibliothek", systemImage: "arrow.up.right.square")
                        .font(.system(size: 11.5, weight: .medium))
                        .foregroundStyle(Theme.textSecondary)
                }
                .buttonStyle(.plain)
                .help("Personas in der Seitenleiste verwalten (⌘3)")
            }
            .padding(.horizontal, 14)
            .padding(.top, 12)
            .padding(.bottom, 8)

            if let note = note(isNewChat: isNewChat, active: active) {
                Text(note)
                    .font(.system(size: 11.5))
                    .foregroundStyle(Theme.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 14)
                    .padding(.bottom, 8)
            }

            if app.personas.count > 5 {
                searchField(visible: visible)
                    .padding(.horizontal, 12)
                    .padding(.bottom, 6)
            }

            Divider().overlay(Theme.border)

            Group {
                if app.personas.isEmpty {
                    emptyLibrary
                } else if visible.isEmpty {
                    Text("Keine Persona zu „\(query)“")
                        .font(.system(size: 12.5))
                        .foregroundStyle(Theme.textTertiary)
                        .frame(maxWidth: .infinity, minHeight: 80)
                } else {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 1) {
                            if isNewChat && query.isEmpty {
                                NoPersonaRow(isOn: active == nil) { app.choosePersona(nil) }
                            }
                            ForEach(visible) { persona in
                                PersonaPickerRow(
                                    persona: persona,
                                    isOn: active?.id == persona.id,
                                    actionHint: isNewChat ? nil : "Neuer Chat",
                                    onChoose: { app.choosePersona(persona.id) },
                                    onEdit: { app.editPersona(persona.id) }
                                )
                            }
                        }
                        .padding(6)
                    }
                    .frame(maxHeight: 320)
                    .fixedSize(horizontal: false, vertical: true)
                }
            }

            Divider().overlay(Theme.border)
            HStack {
                Button {
                    app.isPersonaPickerShown = false
                    app.createPersona()
                } label: {
                    Label("Neue Persona", systemImage: "plus")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(Theme.textSecondary)
                }
                .buttonStyle(.plain)
                Spacer()
            }
            .padding(.horizontal, 14)
            .frame(height: 38)
        }
        .frame(width: 360)
        .background(Theme.elevated)
        .task {
            try? await Task.sleep(for: .milliseconds(60))
            searchFocused = true
        }
    }

    private func note(isNewChat: Bool, active: Persona?) -> String? {
        if !isNewChat {
            let current = active.map { "Dieser Chat läuft mit \($0.displayName). " } ?? ""
            return current + "Die Persona legst du beim Start eines Chats fest; ein Klick beginnt einen neuen Chat."
        }
        if !app.newChatSkillIDs.isEmpty { return "Mit einer Persona gibt es keine Skills; die gewählten Skills werden abgeschaltet." }
        return nil
    }

    private func searchField(visible: [Persona]) -> some View {
        HStack(spacing: 7) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 12))
                .foregroundStyle(Theme.textTertiary)
            TextField("", text: $query, prompt: Text("Personas durchsuchen").foregroundStyle(Theme.textTertiary))
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                .foregroundStyle(Theme.textPrimary)
                .focused($searchFocused)
                .onSubmit {
                    if visible.count == 1, let only = visible.first { app.choosePersona(only.id) }
                }
        }
        .padding(.horizontal, 10)
        .frame(height: 30)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.white.opacity(0.05)))
        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Theme.border))
    }

    private var emptyLibrary: some View {
        VStack(spacing: 8) {
            Text("Noch keine Personas")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Theme.textPrimary)
            Text("Eine Persona ist ein Charakter mit Bild, Lebensgeschichte und eigener Art, mit dem du chattest wie mit einem Menschen.")
                .font(.system(size: 12))
                .foregroundStyle(Theme.textSecondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            Button("Erste Persona anlegen") {
                app.isPersonaPickerShown = false
                app.createPersona()
            }
            .buttonStyle(.plain)
            .font(.system(size: 12.5, weight: .medium))
            .foregroundStyle(Theme.accent)
            .padding(.top, 2)
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 22)
        .frame(maxWidth: .infinity)
    }
}

private struct NoPersonaRow: View {
    let isOn: Bool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "circle.slash")
                .font(.system(size: 14))
                .foregroundStyle(Theme.textTertiary)
                .frame(width: 32, height: 32)
            VStack(alignment: .leading, spacing: 2) {
                Text("Ohne Persona")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(Theme.textPrimary)
                Text("Das Modell selbst, wahlweise mit Skills")
                    .font(.system(size: 11.5))
                    .foregroundStyle(Theme.textTertiary)
            }
            Spacer(minLength: 4)
            if isOn {
                Image(systemName: "checkmark")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(Theme.accent)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(hovering ? Theme.hover : .clear))
        .contentShape(Rectangle())
        .onTapGesture(perform: action)
        .onHover { hovering = $0 }
    }
}

private struct PersonaPickerRow: View {
    let persona: Persona
    let isOn: Bool
    /// Shown on hover when a click does more than choose, e.g. "Neuer Chat".
    let actionHint: String?
    let onChoose: () -> Void
    let onEdit: () -> Void
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 10) {
            PersonaAvatar(persona: persona, size: 32)
            VStack(alignment: .leading, spacing: 2) {
                Text(persona.displayName)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(Theme.textPrimary)
                    .lineLimit(1)
                if let tagline = persona.tagline {
                    Text(tagline)
                        .font(.system(size: 11.5))
                        .foregroundStyle(Theme.textTertiary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
            }
            Spacer(minLength: 4)
            if hovering, let actionHint {
                Text(actionHint)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Theme.accent)
            }
            Button(action: onEdit) {
                Image(systemName: "pencil")
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(Theme.textSecondary)
                    .frame(width: 24, height: 24)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .opacity(hovering ? 1 : 0)
            .help("Persona bearbeiten")
            if isOn {
                Image(systemName: "checkmark")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(Theme.accent)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(hovering ? Theme.hover : .clear))
        .contentShape(Rectangle())
        .onTapGesture(perform: onChoose)
        .onHover { hovering = $0 }
        .contextMenu {
            Button(actionHint == nil ? "Wählen" : "Neuer Chat mit \(persona.displayName)", action: onChoose)
            Button("Bearbeiten …", systemImage: "pencil", action: onEdit)
        }
    }
}
