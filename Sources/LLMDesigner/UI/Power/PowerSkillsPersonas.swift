import SwiftUI

// MARK: - Skills

/// The skill library in small: every skill by folder; an open one shows its instructions to drag into a text and
/// switches it on for the chat. Nothing is made from dropped text here: a skill is a system prompt, and text dragged
/// in may come from a web page or a foreign document.
struct PowerSkills: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        let query = app.power.query
        if let id = app.power.skillID, app.skill(id) != nil, query.isEmpty {
            PowerSkillView(skillID: id)
        } else {
            PowerSkillList(query: query)
        }
    }
}

private struct PowerSkillList: View {
    @Environment(AppModel.self) private var app
    let query: String

    var body: some View {
        let sections = app.skillSections(matching: query)
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 1) {
                ForEach(sections.folders) { section in
                    PowerSectionLabel(title: section.folder.name)
                    ForEach(section.items) { skill in row(skill) }
                }
                if !sections.unfiled.isEmpty, !sections.folders.isEmpty {
                    PowerSectionLabel(title: "Ohne Ordner")
                }
                ForEach(sections.unfiled) { skill in row(skill) }
                if sections.folders.allSatisfy(\.items.isEmpty) && sections.unfiled.isEmpty {
                    PowerEmpty(text: query.isEmpty ? "Noch keine Skills." : "Kein Skill passt zur Suche.")
                }
            }
            .padding(.horizontal, 10)
            .padding(.bottom, 12)
        }
    }

    private func row(_ skill: Skill) -> some View {
        PowerListRow(title: skill.displayName, subtitle: skill.summary,
                     symbol: skill.symbol ?? Skill.defaultSymbol, isCurrent: app.isSkillActive(skill.id)) {
            app.power.skillID = skill.id
        }
    }
}

private struct PowerSkillView: View {
    @Environment(AppModel.self) private var app
    let skillID: Skill.ID

    var body: some View {
        let skill = app.skill(skillID)
        VStack(spacing: 0) {
            PowerItemBar(title: skill?.displayName ?? "", symbol: skill?.symbol ?? Skill.defaultSymbol, openHelp: "In Skills öffnen") {
                app.power.closeItem()
            } onOpen: {
                app.selectSkill(skillID)
            }
            if let skill {
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        if !skill.summary.isEmpty {
                            Text(skill.summary)
                                .font(.system(size: 12))
                                .foregroundStyle(Theme.textSecondary)
                        }
                        HStack(spacing: 8) {
                            if app.activePersona == nil {
                                let active = app.isSkillActive(skillID)
                                Button(active ? "Im Chat ausschalten" : "Im Chat einschalten",
                                       systemImage: active ? "checkmark.circle.fill" : "plus.circle") {
                                    app.toggleSkill(skillID)
                                }
                                .help(app.selectedChat == nil ? "Für den neuen Chat" : "Für den offenen Chat")
                            }
                            Button("Neuer Chat", systemImage: "square.and.pencil") { app.startChat(with: skillID) }
                                .help("Neuen Chat mit diesem Skill beginnen")
                        }
                        .controlSize(.small)
                        PowerTextCard(title: "Anweisungen", text: skill.instructions, empty: "Dieser Skill hat noch keine Anweisungen.")
                    }
                    .padding(.horizontal, 12)
                    .padding(.bottom, 14)
                }
            }
        }
    }
}

// MARK: - Personas

/// The personas in small: picture, name and the first lines; an open one shows life story and manner to drag out and
/// starts a chat with them.
struct PowerPersonas: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        let query = app.power.query
        if let id = app.power.personaID, app.persona(id) != nil, query.isEmpty {
            PowerPersonaView(personaID: id)
        } else {
            PowerPersonaList(query: query)
        }
    }
}

private struct PowerPersonaList: View {
    @Environment(AppModel.self) private var app
    let query: String

    var body: some View {
        let personas = app.personas(matching: query)
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 1) {
                ForEach(personas) { persona in
                    PowerPersonaRow(persona: persona, isCurrent: app.activePersona?.id == persona.id) {
                        app.power.personaID = persona.id
                    }
                }
                if personas.isEmpty {
                    PowerEmpty(text: query.isEmpty ? "Noch keine Personas." : "Keine Persona passt zur Suche.")
                }
            }
            .padding(.horizontal, 10)
            .padding(.bottom, 12)
        }
    }
}

private struct PowerPersonaRow: View {
    let persona: Persona
    let isCurrent: Bool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 9) {
                PersonaAvatar(persona: persona, size: 26)
                VStack(alignment: .leading, spacing: 2) {
                    Text(persona.displayName)
                        .font(.system(size: 12.5, weight: isCurrent ? .semibold : .medium))
                        .foregroundStyle(isCurrent ? Theme.accent : Theme.textPrimary)
                        .lineLimit(1)
                    let line = (persona.biography.isEmpty ? persona.behavior : persona.biography)
                        .split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
                    if !line.isEmpty {
                        Text(line)
                            .font(.system(size: 11))
                            .foregroundStyle(Theme.textTertiary)
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(hovering ? Theme.hover : .clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

private struct PowerPersonaView: View {
    @Environment(AppModel.self) private var app
    let personaID: Persona.ID

    var body: some View {
        let persona = app.persona(personaID)
        VStack(spacing: 0) {
            PowerItemBar(title: persona?.displayName ?? "", symbol: Persona.symbol, openHelp: "In Personas öffnen") {
                app.power.closeItem()
            } onOpen: {
                app.selectPersona(personaID)
            }
            if let persona {
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        HStack(spacing: 12) {
                            PersonaAvatar(persona: persona, size: 52)
                            VStack(alignment: .leading, spacing: 6) {
                                Text(persona.displayName)
                                    .font(.system(size: 14, weight: .semibold))
                                    .foregroundStyle(Theme.textPrimary)
                                Button("Mit \(persona.displayName) chatten", systemImage: "bubble.left.and.bubble.right") {
                                    app.startChat(withPersona: personaID)
                                }
                                .controlSize(.small)
                            }
                            Spacer(minLength: 0)
                        }
                        PowerTextCard(title: "Biografie", text: persona.biography, empty: "Noch keine Biografie.")
                        PowerTextCard(title: "Verhalten", text: persona.behavior, empty: "Noch keine Beschreibung des Verhaltens.")
                    }
                    .padding(.horizontal, 12)
                    .padding(.bottom, 14)
                }
            }
        }
    }
}

// MARK: - Shared

/// A folder's name above its rows.
private struct PowerSectionLabel: View {
    let title: String

    var body: some View {
        Text(title)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(Theme.textTertiary)
            .padding(.horizontal, 8)
            .padding(.top, 10)
            .padding(.bottom, 3)
    }
}

/// A titled piece of text that can be dragged into a document, a slide or the chat as a whole.
private struct PowerTextCard: View {
    let title: String
    let text: String
    let empty: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Text(title)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Theme.textTertiary)
                Spacer(minLength: 0)
                if !text.isEmpty {
                    Image(systemName: "hand.draw")
                        .font(.system(size: 10))
                        .foregroundStyle(Theme.textTertiary)
                        .help("In ein Dokument, eine Folie oder den Chat ziehen")
                }
            }
            if text.isEmpty {
                Text(empty)
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.textTertiary)
            } else {
                Text(text)
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.textPrimary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(9)
                    .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Theme.ink.opacity(0.03)))
                    .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Theme.border))
                    .powerDrag(markdown: text, plain: text)
            }
        }
    }
}
