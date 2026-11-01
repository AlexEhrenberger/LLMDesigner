import SwiftUI

/// Composer button for the skills of this chat; opens the library to search and combine them.
struct SkillsButton: View {
    @Environment(AppModel.self) private var app
    @State private var hovering = false

    var body: some View {
        @Bindable var app = app
        let active = app.activeSkills
        // A chat runs either with a persona or with skills.
        let blocked = app.activePersona != nil

        Button { app.isSkillPickerShown.toggle() } label: {
            HStack(spacing: 5) {
                Image(systemName: active.isEmpty ? Skill.defaultSymbol : Skill.defaultSymbol + ".fill")
                    .font(.system(size: 14, weight: .medium))
                if !active.isEmpty {
                    Text(label(for: active))
                        .font(.system(size: 12.5, weight: .medium))
                        .lineLimit(1)
                }
            }
            .foregroundStyle(blocked ? Theme.textTertiary.opacity(0.6) : (active.isEmpty ? (hovering || app.isSkillPickerShown ? Theme.textPrimary : Theme.textSecondary) : Theme.accent))
            .padding(.horizontal, active.isEmpty ? 0 : 11)
            .frame(minWidth: 32, minHeight: 32)
            .background(Capsule().fill(blocked ? .clear : background(active: !active.isEmpty)))
            .overlay(Capsule().strokeBorder(Theme.accent.opacity(active.isEmpty ? 0 : 0.35)))
            .contentShape(Capsule())
            .animation(.easeOut(duration: 0.15), value: active.isEmpty)
        }
        .buttonStyle(.plain)
        .disabled(blocked)
        .onHover { hovering = $0 }
        .help(blocked
              ? "Skills: In einem Chat mit einer Persona gibt es keine Skills"
              : (active.isEmpty ? "Skills einschalten (⇧⌘K)" : "Skills: " + active.map(\.displayName).joined(separator: ", ") + " (⇧⌘K)"))
        .popover(isPresented: $app.isSkillPickerShown, arrowEdge: .top) {
            SkillPickerPanel()
                .environment(app)
        }
    }

    private func label(for skills: [Skill]) -> String {
        guard let first = skills.first else { return "" }
        let name = first.displayName.count > 22 ? String(first.displayName.prefix(21)) + "…" : first.displayName
        return skills.count == 1 ? name : "\(name) +\(skills.count - 1)"
    }

    private func background(active: Bool) -> Color {
        if active { return Theme.accent.opacity(hovering ? 0.24 : 0.16) }
        return hovering || app.isSkillPickerShown ? Theme.hover : .clear
    }
}

/// Small library in a popover: search, tick any number of skills, see what the system prompt becomes.
private struct SkillPickerPanel: View {
    @Environment(AppModel.self) private var app
    @State private var query = ""
    @State private var highlighted: Skill.ID?
    @State private var showsPrompt = false
    @FocusState private var searchFocused: Bool

    var body: some View {
        let library = app.skillSections(matching: query)
        let visible = library.folders.flatMap(\.items) + library.unfiled
        let active = app.activeSkills

        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(app.selectedChat == nil ? "Skills für den neuen Chat" : "Skills für diesen Chat")
                    .font(.system(size: 13.5, weight: .semibold))
                    .foregroundStyle(Theme.textPrimary)
                Spacer()
                Button {
                    app.isSkillPickerShown = false
                    app.showSkills()
                } label: {
                    Label("Bibliothek", systemImage: "arrow.up.right.square")
                        .font(.system(size: 11.5, weight: .medium))
                        .foregroundStyle(Theme.textSecondary)
                }
                .buttonStyle(.plain)
                .help("Skills in der Seitenleiste verwalten (⌘2)")
            }
            .padding(.horizontal, 14)
            .padding(.top, 12)
            .padding(.bottom, 10)

            searchField(visible: visible)
                .padding(.horizontal, 12)

            // Active skills in the order they go into the prompt. The row stays when empty, so the popover keeps its size.
            Group {
                if active.isEmpty {
                    Text("Noch kein Skill eingeschaltet")
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.textTertiary)
                        .frame(height: 24)
                } else {
                    FlowLayout(spacing: 6, lineSpacing: 6) {
                        ForEach(active) { skill in
                            ActiveSkillChip(skill: skill) { app.toggleSkill(skill.id) }
                        }
                    }
                }
            }
            .padding(.horizontal, 12)
            .padding(.top, 10)

            Divider().overlay(Theme.border).padding(.top, 10)

            Group {
                if showsPrompt && !app.activeSystemPrompt.isEmpty {
                    promptPreview
                } else if app.skills.isEmpty {
                    emptyLibrary
                } else if visible.isEmpty {
                    Text("Keine Skills zu „\(query)“")
                        .font(.system(size: 12.5))
                        .foregroundStyle(Theme.textTertiary)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    list(library)
                }
            }
            .frame(height: 300)

            Divider().overlay(Theme.border)
            footer(active: active)
        }
        .frame(width: 400)
        .background(Theme.elevated)
        .task {
            try? await Task.sleep(for: .milliseconds(60))
            searchFocused = true
        }
    }

    private func list(_ library: (folders: [FolderSection<Skill>], unfiled: [Skill])) -> some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 1) {
                    ForEach(library.folders) { section in
                        groupHeader(section.folder.name)
                        ForEach(section.items) { skill in
                            row(skill)
                        }
                    }
                    if !library.unfiled.isEmpty {
                        if !library.folders.isEmpty { groupHeader("Ohne Ordner") }
                        ForEach(library.unfiled) { skill in
                            row(skill)
                        }
                    }
                }
                .padding(.horizontal, 6)
                .padding(.vertical, 6)
            }
            .onChange(of: highlighted) { _, id in
                if let id { proxy.scrollTo(id) }
            }
        }
    }

    private func searchField(visible: [Skill]) -> some View {
        HStack(spacing: 7) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 12))
                .foregroundStyle(Theme.textTertiary)
            TextField("", text: $query, prompt: Text("Skills durchsuchen").foregroundStyle(Theme.textTertiary))
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                .foregroundStyle(Theme.textPrimary)
                .focused($searchFocused)
                .onSubmit {
                    // Return switches the highlighted skill, or the only hit.
                    if let id = highlighted ?? (visible.count == 1 ? visible.first?.id : nil) { app.toggleSkill(id) }
                }
                .onKeyPress(.downArrow) {
                    moveHighlight(by: 1, in: visible)
                    return .handled
                }
                .onKeyPress(.upArrow) {
                    moveHighlight(by: -1, in: visible)
                    return .handled
                }
                .onChange(of: query) {
                    highlighted = nil
                    showsPrompt = false
                }
        }
        .padding(.horizontal, 10)
        .frame(height: 30)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Theme.ink.opacity(0.05)))
        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Theme.border))
    }

    private func moveHighlight(by step: Int, in visible: [Skill]) {
        guard !visible.isEmpty else { return }
        guard let current = highlighted, let position = visible.firstIndex(where: { $0.id == current }) else {
            highlighted = step > 0 ? visible.first?.id : visible.last?.id
            return
        }
        highlighted = visible[(position + step + visible.count) % visible.count].id
    }

    private func groupHeader(_ title: String) -> some View {
        Text(title.uppercased())
            .font(.system(size: 10.5, weight: .semibold))
            .tracking(0.4)
            .foregroundStyle(Theme.textTertiary)
            .padding(.horizontal, 8)
            .padding(.top, 8)
            .padding(.bottom, 3)
    }

    private func row(_ skill: Skill) -> some View {
        SkillPickerRow(
            skill: skill,
            isOn: app.isSkillActive(skill.id),
            isHighlighted: highlighted == skill.id,
            onToggle: {
                highlighted = skill.id
                app.toggleSkill(skill.id)
            },
            onEdit: { app.editSkill(skill.id) }
        )
        .id(skill.id)
    }

    private var emptyLibrary: some View {
        VStack(spacing: 8) {
            Text("Noch keine Skills")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Theme.textPrimary)
            Text("Ein Skill ist ein Baustein für den System-Prompt, z. B. eine Rolle oder ein Schreibstil.")
                .font(.system(size: 12))
                .foregroundStyle(Theme.textSecondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 14) {
                Button("Ersten Skill anlegen") {
                    app.isSkillPickerShown = false
                    app.createSkill()
                }
                Button("Beispiele anlegen") { app.addExampleSkills() }
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

    private func footer(active: [Skill]) -> some View {
        let tokens = SkillPrompt.estimatedTokens(app.activeSystemPrompt)
        let context = app.currentModel?.workingContextLength
        let isLarge = context.map { tokens * 4 > $0 } ?? false
        return HStack(spacing: 10) {
            Button {
                app.isSkillPickerShown = false
                app.createSkill()
            } label: {
                Label("Neuer Skill", systemImage: "plus")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Theme.textSecondary)
            }
            .buttonStyle(.plain)
            Spacer()
            if tokens > 0 {
                Button {
                    withAnimation(.snappy(duration: 0.2)) { showsPrompt.toggle() }
                } label: {
                    HStack(spacing: 5) {
                        if isLarge {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .font(.system(size: 10))
                        }
                        Text("System-Prompt ≈ \(tokens) Tokens")
                            .font(.system(size: 11.5, weight: .medium).monospacedDigit())
                        Image(systemName: "chevron.down")
                            .font(.system(size: 8.5, weight: .bold))
                            .rotationEffect(.degrees(showsPrompt ? 180 : 0))
                    }
                    .foregroundStyle(isLarge ? Theme.warning : Theme.textTertiary)
                }
                .buttonStyle(.plain)
                .help(isLarge
                      ? "Der System-Prompt belegt mehr als ein Viertel des geladenen Kontexts (\(LMModel.formatTokens(context ?? 0)))."
                      : "Zusammengesetzten System-Prompt anzeigen")
            }
        }
        .padding(.horizontal, 14)
        .frame(height: 38)
    }

    /// The system prompt the chat sends, in place of the list.
    private var promptPreview: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Zusammengesetzter System-Prompt")
                .font(.system(size: 10.5, weight: .semibold))
                .tracking(0.4)
                .textCase(.uppercase)
                .foregroundStyle(Theme.textTertiary)
            ScrollView {
                Text(app.activeSystemPrompt)
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.textSecondary)
                    .lineSpacing(2)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(10)
            }
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Theme.shade.opacity(0.25)))
        }
        .padding(12)
    }
}

private struct SkillPickerRow: View {
    let skill: Skill
    let isOn: Bool
    let isHighlighted: Bool
    let onToggle: () -> Void
    let onEdit: () -> Void
    @State private var hovering = false

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            ZStack {
                RoundedRectangle(cornerRadius: 4.5, style: .continuous)
                    .fill(isOn ? Theme.accent : .clear)
                RoundedRectangle(cornerRadius: 4.5, style: .continuous)
                    .strokeBorder(isOn ? Theme.accent : Theme.textTertiary, lineWidth: 1.2)
                if isOn {
                    Image(systemName: "checkmark")
                        .font(.system(size: 9, weight: .heavy))
                        .foregroundStyle(Theme.background)
                }
            }
            .frame(width: 16, height: 16)

            Image(systemName: skill.symbol ?? Skill.defaultSymbol)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(Theme.accent.opacity(isOn ? 1 : 0.7))
                .frame(width: 20)

            VStack(alignment: .leading, spacing: 2) {
                Text(skill.displayName)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(Theme.textPrimary)
                    .lineLimit(1)
                if let caption {
                    Text(caption)
                        .font(.system(size: 11.5))
                        .foregroundStyle(Theme.textTertiary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
            }
            Spacer(minLength: 4)
            Button(action: onEdit) {
                Image(systemName: "pencil")
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(Theme.textSecondary)
                    .frame(width: 24, height: 24)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .opacity(hovering ? 1 : 0)
            .help("Skill bearbeiten")
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(hovering || isHighlighted ? Theme.hover : .clear))
        .contentShape(Rectangle())
        .onTapGesture(perform: onToggle)
        .onHover { hovering = $0 }
        .contextMenu {
            Button(isOn ? "Ausschalten" : "Einschalten", action: onToggle)
            Button("Bearbeiten …", systemImage: "pencil", action: onEdit)
        }
    }

    /// The summary, or the start of the instructions when there is none.
    private var caption: String? {
        let summary = skill.summary.trimmingCharacters(in: .whitespacesAndNewlines)
        if !summary.isEmpty { return summary }
        let start = skill.instructions.split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
        return start.isEmpty ? nil : start
    }
}

private struct ActiveSkillChip: View {
    let skill: Skill
    let onRemove: () -> Void
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: skill.symbol ?? Skill.defaultSymbol)
                .font(.system(size: 10.5, weight: .medium))
            Text(skill.displayName)
                .font(.system(size: 12, weight: .medium))
                .lineLimit(1)
                .frame(maxWidth: 150, alignment: .leading)
            Button(action: onRemove) {
                Image(systemName: "xmark")
                    .font(.system(size: 8.5, weight: .bold))
                    .frame(width: 14, height: 14)
                    .background(Circle().fill(hovering ? Theme.accent.opacity(0.25) : .clear))
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .onHover { hovering = $0 }
            .help("Ausschalten")
        }
        .foregroundStyle(Theme.accent)
        .padding(.leading, 9)
        .padding(.trailing, 5)
        .frame(height: 24)
        .background(Capsule().fill(Theme.accent.opacity(0.14)))
        .overlay(Capsule().strokeBorder(Theme.accent.opacity(0.3)))
    }
}

/// Lays its children out in rows and wraps to the next row when one is full.
struct FlowLayout: Layout {
    var spacing: CGFloat = 6
    var lineSpacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = arrange(subviews, width: proposal.width ?? .infinity)
        let width = rows.map(\.width).max() ?? 0
        let height = rows.map(\.height).reduce(0, +) + lineSpacing * CGFloat(max(rows.count - 1, 0))
        return CGSize(width: width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var y = bounds.minY
        for row in arrange(subviews, width: bounds.width) {
            var x = bounds.minX
            for index in row.indices {
                let size = subviews[index].sizeThatFits(.unspecified)
                subviews[index].place(at: CGPoint(x: x, y: y + (row.height - size.height) / 2), proposal: ProposedViewSize(size))
                x += size.width + spacing
            }
            y += row.height + lineSpacing
        }
    }

    private func arrange(_ subviews: Subviews, width: CGFloat) -> [(indices: [Int], width: CGFloat, height: CGFloat)] {
        var rows: [(indices: [Int], width: CGFloat, height: CGFloat)] = []
        var current: (indices: [Int], width: CGFloat, height: CGFloat) = ([], 0, 0)
        for index in subviews.indices {
            let size = subviews[index].sizeThatFits(.unspecified)
            let needed = current.indices.isEmpty ? size.width : current.width + spacing + size.width
            if needed > width, !current.indices.isEmpty {
                rows.append(current)
                current = ([index], size.width, size.height)
            } else {
                current = (current.indices + [index], needed, max(current.height, size.height))
            }
        }
        if !current.indices.isEmpty { rows.append(current) }
        return rows
    }
}
