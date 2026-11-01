import SwiftUI

/// Colours of the two sides of an entry: the user's feelings and the AI's.
enum ThalamusColors {
    static let user = Theme.dynamic(dark: 0x6FD3FF, light: 0x0A8BC7)
    static let ai = Theme.dynamic(dark: 0xFF8FD6, light: 0xC9409A)
}

/// A feeling with its strength: the stronger, the more the chip glows.
struct EmotionChip: View {
    let emotion: ThalamusEmotion
    let color: Color

    var body: some View {
        HStack(spacing: 5) {
            Text(emotion.name)
                .font(.system(size: 11.5, weight: .medium))
            Text("\(emotion.intensity)")
                .font(.system(size: 10.5, weight: .bold).monospacedDigit())
                .opacity(0.8)
        }
        .foregroundStyle(color)
        .padding(.horizontal, 8)
        .frame(height: 21)
        .background(Capsule().fill(color.opacity(0.06 + 0.025 * Double(emotion.intensity))))
        .overlay(Capsule().strokeBorder(color.opacity(0.12 + 0.03 * Double(emotion.intensity))))
        .help("\(emotion.name), Stärke \(emotion.intensity) von 10")
    }
}

private struct KeywordChip: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.system(size: 11))
            .foregroundStyle(Theme.textSecondary)
            .padding(.horizontal, 7)
            .frame(height: 19)
            .background(RoundedRectangle(cornerRadius: 5, style: .continuous).fill(Theme.ink.opacity(0.06)))
    }
}

private struct CategoryChip: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(Theme.accent)
            .padding(.horizontal, 8)
            .frame(height: 20)
            .background(Capsule().fill(Theme.accent.opacity(0.14)))
    }
}

// MARK: Above an answer

/// How Thalamus sorted the question before this answer. Collapsed: category, feelings and how many moments the persona
/// remembered; expanded: the key, keywords, feelings and the remembered moments.
struct ThalamusTraceView: View {
    let trace: ThalamusTrace
    @State private var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Button {
                guard canExpand else { return }
                withAnimation(.snappy(duration: 0.2)) { expanded.toggle() }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "brain.head.profile")
                        .font(.system(size: 12))
                        .symbolEffect(.pulse, options: .repeating, isActive: trace.status == .running)
                    label
                        .lineLimit(1)
                        .truncationMode(.tail)
                    if canExpand {
                        Image(systemName: "chevron.right")
                            .font(.system(size: 9, weight: .bold))
                            .rotationEffect(.degrees(expanded ? 90 : 0))
                    }
                }
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(trace.status == .failed ? Theme.textTertiary : Theme.textSecondary)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(trace.status == .done ? "Thalamus: Einordnung und Erinnerungen anzeigen" : "")

            if expanded {
                details
                    .padding(.leading, 14)
                    .overlay(alignment: .leading) {
                        Rectangle().fill(Theme.strongBorder).frame(width: 2)
                    }
            }
        }
    }

    @ViewBuilder
    private var label: some View {
        switch trace.status {
        case .running:
            Text("Thalamus ordnet ein …")
                .phaseAnimator([false, true]) { content, phase in
                    content.opacity(phase ? 1 : 0.45)
                } animation: { _ in .easeInOut(duration: 0.9) }
        case .failed:
            Text("Thalamus: nicht eingeordnet" + (trace.error.map { " (\($0))" } ?? ""))
        case .done:
            Text(summary)
        }
    }

    private var canExpand: Bool {
        trace.status == .done && (trace.entry != nil || !(trace.memories ?? []).isEmpty || !(trace.recalled ?? []).isEmpty)
    }

    private var summary: String {
        var parts: [String] = []
        if let entry = trace.entry {
            parts.append(entry.category)
            if !entry.userEmotions.isEmpty { parts.append(entry.userEmotions.map(\.label).joined(separator: ", ")) }
            if !entry.aiEmotions.isEmpty { parts.append("KI: " + entry.aiEmotions.map(\.label).joined(separator: ", ")) }
        } else {
            parts.append("Thalamus")
        }
        if let memories = trace.memories, !memories.isEmpty {
            parts.append("erinnert sich an " + memories.map { "„\($0.title)“" }.joined(separator: ", "))
        } else if let recalled = trace.recalled?.count, recalled > 0 {
            parts.append(recalled == 1 ? "erinnert sich an 1 Moment" : "erinnert sich an \(recalled) Momente")
        }
        if trace.stored == false { parts.append("nicht gespeichert") }
        return parts.joined(separator: " · ")
    }

    private var details: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let entry = trace.entry {
                impression(entry)
            }
            if let memories = trace.memories, !memories.isEmpty {
                VStack(alignment: .leading, spacing: 10) {
                    Text("Erinnert sich an")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Theme.textTertiary)
                        .textCase(.uppercase)
                    ForEach(memories) { memory in
                        RecalledMemory(memory: memory)
                    }
                }
                .padding(.top, 2)
            }
        }
    }

    private func impression(_ entry: ThalamusEntry) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(entry.key)
                .font(.system(size: 12, design: .monospaced))
                .foregroundStyle(Theme.textPrimary)
                .textSelection(.enabled)
            Text(entry.summary)
                .font(.system(size: 13))
                .foregroundStyle(Theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            if !entry.keywords.isEmpty {
                FlowLayout(spacing: 5, lineSpacing: 5) {
                    ForEach(entry.keywords, id: \.self) { KeywordChip(text: $0) }
                }
            }
            EmotionRows(entry: entry)
            if trace.stored == false {
                Text("Smalltalk ohne Inhalt: eingeordnet, aber nicht im Gedächtnis gespeichert.")
                    .font(.system(size: 11.5))
                    .foregroundStyle(Theme.textTertiary)
            }
            if let recalled = trace.recalled, !recalled.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Erinnert sich an")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Theme.textTertiary)
                        .textCase(.uppercase)
                    ForEach(recalled) { memory in
                        RecalledMoment(entry: memory)
                    }
                }
                .padding(.top, 2)
            }
        }
    }
}

private struct EmotionRows: View {
    let entry: ThalamusEntry

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            row("Nutzer", entry.userEmotions, ThalamusColors.user)
            row("KI", entry.aiEmotions, ThalamusColors.ai)
        }
    }

    private func row(_ title: String, _ emotions: [ThalamusEmotion], _ color: Color) -> some View {
        HStack(alignment: .center, spacing: 8) {
            Text(title)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Theme.textTertiary)
                .frame(width: 44, alignment: .leading)
            if emotions.isEmpty {
                Text("keine erkennbaren Gefühle")
                    .font(.system(size: 11.5))
                    .foregroundStyle(Theme.textTertiary)
            } else {
                FlowLayout(spacing: 5, lineSpacing: 5) {
                    ForEach(emotions, id: \.name) { EmotionChip(emotion: $0, color: color) }
                }
            }
        }
    }
}

private struct RecalledMoment: View {
    let entry: ThalamusEntry

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                CategoryChip(text: entry.category)
                Text(entry.date.formatted(.relative(presentation: .named)))
                    .font(.system(size: 11.5))
                    .foregroundStyle(Theme.textTertiary)
            }
            Text(entry.summary)
                .font(.system(size: 12.5))
                .foregroundStyle(Theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            FlowLayout(spacing: 5, lineSpacing: 5) {
                ForEach(entry.userEmotions, id: \.name) { EmotionChip(emotion: $0, color: ThalamusColors.user) }
                ForEach(entry.aiEmotions, id: \.name) { EmotionChip(emotion: $0, color: ThalamusColors.ai) }
            }
        }
    }
}

/// A memory as it came back for an answer: title, when, the story and the course of the feelings.
private struct RecalledMemory: View {
    let memory: ThalamusMemory

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 6) {
                CategoryChip(text: memory.category)
                Text(memory.title)
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundStyle(Theme.textPrimary)
                Text("zuletzt " + memory.lastDate.formatted(.relative(presentation: .named)))
                    .font(.system(size: 11.5))
                    .foregroundStyle(Theme.textTertiary)
            }
            Text(memory.summary)
                .font(.system(size: 12.5))
                .foregroundStyle(Theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            FeelingCourse(points: memory.feelings, compact: true)
        }
    }
}

/// The course of a memory's feelings: one row per chat, the user's feelings and the AI's side by side.
private struct FeelingCourse: View {
    let points: [ThalamusFeelingPoint]
    var compact = false

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            ForEach(Array((compact ? Array(points.suffix(3)) : points).enumerated()), id: \.offset) { _, point in
                HStack(alignment: .center, spacing: 6) {
                    Text(point.date.formatted(.dateTime.day().month(.abbreviated)))
                        .font(.system(size: 11).monospacedDigit())
                        .foregroundStyle(Theme.textTertiary)
                        .frame(width: 48, alignment: .leading)
                    FlowLayout(spacing: 5, lineSpacing: 5) {
                        ForEach(point.user, id: \.name) { EmotionChip(emotion: $0, color: ThalamusColors.user) }
                        ForEach(point.ai, id: \.name) { EmotionChip(emotion: $0, color: ThalamusColors.ai) }
                    }
                }
            }
        }
    }
}

// MARK: Persona editor

/// The persona's Thalamus: profile, memories (the most important first) and the impressions waiting for consolidation.
/// Search, filter by category, consolidate now, delete one item or everything.
struct ThalamusEntriesSection: View {
    @Environment(AppModel.self) private var app
    let persona: Persona
    @State private var query = ""
    @State private var category: String?
    @State private var shown = 20
    @State private var showsImpressions = false
    @State private var confirmingDeleteAll = false

    var body: some View {
        let memories = app.thalamusMemories(of: persona.id)
        let profile = app.thalamusProfile(of: persona.id)
        let impressions = app.thalamusImpressions(of: persona.id)
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let visibleMemories = memories.filter { (category == nil || $0.category == category) && $0.matches(trimmed) }
        let visibleFacts = profile.filter { trimmed.isEmpty || $0.text.localizedStandardContains(trimmed) }
        let visibleImpressions = impressions.filter { $0.matches(trimmed) }
        let categories = Array(Set(memories.map(\.category))).sorted()
        let isEmpty = memories.isEmpty && profile.isEmpty && impressions.isEmpty
        let running = app.thalamusConsolidation?.personaID == persona.id ? app.thalamusConsolidation : nil

        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Text("Thalamus")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Theme.textPrimary)
                if !memories.isEmpty { Tag(text: memories.count == 1 ? "1 Erinnerung" : "\(memories.count) Erinnerungen") }
                Spacer(minLength: 8)
                if !isEmpty {
                    SmallSearchField(text: $query, prompt: "Thalamus durchsuchen")
                        .frame(width: 180)
                }
                Button {
                    app.consolidateAllThalamus(of: persona.id)
                } label: {
                    Label("Jetzt verdichten", systemImage: "arrow.triangle.merge")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(impressions.isEmpty || running != nil ? Theme.textTertiary : Theme.accent)
                }
                .buttonStyle(.plain)
                .disabled(impressions.isEmpty || running != nil)
                .help(impressions.isEmpty ? "Keine frischen Eindrücke zum Verdichten" : "Die frischen Eindrücke jetzt zu Erinnerungen verdichten")
                if !isEmpty {
                    Button("Alle löschen …") { confirmingDeleteAll = true }
                        .buttonStyle(.plain)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(Theme.danger.opacity(0.9))
                        .help("Profil, Erinnerungen und Eindrücke von \(persona.displayName) löschen")
                }
            }

            if let running {
                HStack(spacing: 7) {
                    ProgressView().controlSize(.mini)
                    Text("Verdichtet … \(min(running.done + 1, running.total)) von \(running.total) Chats")
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.textSecondary)
                }
            } else if let note = app.thalamusNotes[persona.id] {
                Text(note)
                    .font(.system(size: 12))
                    .foregroundStyle(note.hasPrefix("Verdichtet:") ? Theme.textSecondary : Theme.warning)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if isEmpty {
                Text("Noch nichts im Gedächtnis.")
                    .font(.system(size: 12.5))
                    .foregroundStyle(Theme.textTertiary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(14)
                    .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Theme.surface))
                    .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Theme.strongBorder))
            }

            if !visibleFacts.isEmpty {
                subheading("Profil", count: profile.count)
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(visibleFacts) { fact in
                        FactRow(fact: fact) { app.deleteThalamusFact(fact.id, of: persona.id) }
                    }
                }
                .padding(.vertical, 4)
                .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Theme.surface))
                .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Theme.strongBorder))
            }

            if !memories.isEmpty {
                subheading("Erinnerungen", count: memories.count)
                if categories.count > 1 {
                    FlowLayout(spacing: 6, lineSpacing: 6) {
                        FilterChip(title: "Alle", count: memories.count, isOn: category == nil) { category = nil }
                        ForEach(categories, id: \.self) { name in
                            FilterChip(title: name, count: memories.filter { $0.category == name }.count, isOn: category == name) {
                                category = category == name ? nil : name
                            }
                        }
                    }
                }
                if visibleMemories.isEmpty {
                    Text("Keine Erinnerung passt.")
                        .font(.system(size: 12.5))
                        .foregroundStyle(Theme.textTertiary)
                } else {
                    VStack(spacing: 8) {
                        ForEach(visibleMemories.prefix(shown)) { memory in
                            MemoryCard(
                                memory: memory,
                                lastChatTitle: memory.chatIDs.last.flatMap { app.chat($0)?.title },
                                onOpenChat: { if let last = memory.chatIDs.last { app.selectChat(last) } },
                                onDelete: { app.deleteThalamusMemory(memory.id, of: persona.id) }
                            )
                        }
                        if visibleMemories.count > shown {
                            Button("Weitere \(min(20, visibleMemories.count - shown)) anzeigen") { shown += 20 }
                                .buttonStyle(.plain)
                                .font(.system(size: 12, weight: .medium))
                                .foregroundStyle(Theme.accent)
                        }
                    }
                }
            }

            if !impressions.isEmpty {
                Button {
                    withAnimation(.snappy(duration: 0.2)) { showsImpressions.toggle() }
                } label: {
                    HStack(spacing: 6) {
                        Text("Frische Eindrücke, noch nicht verdichtet")
                            .font(.system(size: 12, weight: .semibold))
                        Text("\(impressions.count)")
                            .font(.system(size: 11, weight: .semibold).monospacedDigit())
                            .foregroundStyle(Theme.textTertiary)
                        Image(systemName: "chevron.right")
                            .font(.system(size: 8.5, weight: .bold))
                            .rotationEffect(.degrees(showsImpressions || !trimmed.isEmpty ? 90 : 0))
                    }
                    .foregroundStyle(Theme.textSecondary)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .padding(.top, 4)
                if showsImpressions || !trimmed.isEmpty {
                    VStack(spacing: 8) {
                        ForEach(visibleImpressions) { entry in
                            ThalamusEntryCard(
                                entry: entry,
                                chatTitle: app.chat(entry.chatID)?.title,
                                onOpenChat: {
                                    app.selectChat(entry.chatID)
                                    app.jump(to: OutlineTarget(messageID: entry.messageID, block: nil))
                                },
                                onDelete: { app.deleteThalamusImpression(entry.id, of: persona.id) }
                            )
                        }
                    }
                }
            }

            Text("In Chats mit \(persona.displayName) und „Gedächtnis: ein“ wird jede deiner Nachrichten vor der Antwort mit einem neutralen Prompt eingeordnet: Kategorie, Inhalt, Schlagworte, deine Gefühle und die der KI. Das ist zunächst ein frischer Eindruck. Wird der Chat still (du verlässt ihn oder 30 Minuten kommt nichts), verdichtet das Modell die Eindrücke: Was zu einem bekannten Thema gehört, ergänzt dessen Erinnerung samt Gefühlsverlauf, Neues wird ein neues Thema, feste Fakten über dich wandern ins Profil, Belangloses wird vergessen. Profil und die Erinnerungen der letzten drei Chats hat \(persona.displayName) immer im Kontext; ältere kommen zurück, sobald ein Wort deiner Nachricht eines ihrer Schlagworte trifft. Nichts verschwindet von selbst: Unwichtiges rutscht mit der Zeit nach hinten, löschen kannst nur du.")
                .font(.system(size: 11.5))
                .foregroundStyle(Theme.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.bottom, 26)
        .onChange(of: query) { shown = 20 }
        .onChange(of: category) { shown = 20 }
        .alert("Thalamus komplett löschen?", isPresented: $confirmingDeleteAll) {
            Button("Alles löschen", role: .destructive) { app.deleteAllThalamus(of: persona.id) }
            Button("Abbrechen", role: .cancel) {}
        } message: {
            Text("\(persona.displayName) vergisst das Profil, alle Erinnerungen und die frischen Eindrücke. Die Nachrichten dazu werden nicht noch einmal eingeordnet.")
        }
    }

    private func subheading(_ title: String, count: Int) -> some View {
        HStack(spacing: 6) {
            Text(title)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Theme.textSecondary)
            Text("\(count)")
                .font(.system(size: 11, weight: .semibold).monospacedDigit())
                .foregroundStyle(Theme.textTertiary)
        }
        .padding(.top, 4)
    }
}

private struct FactRow: View {
    let fact: ThalamusFact
    let onDelete: () -> Void
    @State private var hovering = false

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text("•")
                .foregroundStyle(Theme.textTertiary)
            Text(fact.text)
                .font(.system(size: 12.5))
                .foregroundStyle(Theme.textPrimary)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 8)
            Text(fact.since.formatted(.dateTime.day().month(.abbreviated).year()))
                .font(.system(size: 11))
                .foregroundStyle(Theme.textTertiary)
            Button(action: onDelete) {
                Image(systemName: "trash")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Theme.textSecondary)
                    .frame(width: 22, height: 20)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .opacity(hovering ? 1 : 0.35)
            .help("Fakt löschen")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 5)
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
    }
}

/// A memory in the editor: topic, dates, weight, story, course of the feelings and keywords.
private struct MemoryCard: View {
    let memory: ThalamusMemory
    let lastChatTitle: String?
    let onOpenChat: () -> Void
    let onDelete: () -> Void
    @State private var hovering = false

    var body: some View {
        let importance = memory.importance()
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .center, spacing: 8) {
                CategoryChip(text: memory.category)
                Text(memory.title)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Theme.textPrimary)
                    .lineLimit(1)
                ImportanceMeter(value: importance)
                Spacer(minLength: 8)
                HStack(spacing: 2) {
                    if let lastChatTitle {
                        Button(action: onOpenChat) {
                            Image(systemName: "arrow.up.right.square")
                                .font(.system(size: 12, weight: .medium))
                                .frame(width: 24, height: 22)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .help("Zum letzten Chat dazu: „\(lastChatTitle)“")
                    }
                    Button(action: onDelete) {
                        Image(systemName: "trash")
                            .font(.system(size: 11.5, weight: .medium))
                            .frame(width: 24, height: 22)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help("Erinnerung löschen")
                }
                .foregroundStyle(Theme.textSecondary)
                .opacity(hovering ? 1 : 0.35)
            }
            Text(dates)
                .font(.system(size: 11.5))
                .foregroundStyle(Theme.textTertiary)
            Text(memory.summary)
                .font(.system(size: 12.5))
                .foregroundStyle(Theme.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
            if !memory.feelings.isEmpty {
                FeelingCourse(points: memory.feelings)
            }
            if !memory.keywords.isEmpty {
                FlowLayout(spacing: 5, lineSpacing: 5) {
                    ForEach(memory.keywords, id: \.self) { KeywordChip(text: $0) }
                }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Theme.surface))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Theme.strongBorder))
        // Less important memories fade a little, as they move back.
        .opacity(0.65 + 0.35 * min(1, importance * 1.6))
        .onHover { hovering = $0 }
        .contextMenu {
            if lastChatTitle != nil { Button("Zum letzten Chat", systemImage: "arrow.up.right.square", action: onOpenChat) }
            Button("Erinnerung löschen", systemImage: "trash", role: .destructive, action: onDelete)
        }
    }

    private var dates: String {
        let format = Date.FormatStyle().day().month(.abbreviated).year()
        var parts = ["seit \(memory.firstDate.formatted(format))", "zuletzt \(memory.lastDate.formatted(.relative(presentation: .named)))"]
        parts.append(memory.mentions == 1 ? "1× erwähnt" : "\(memory.mentions)× erwähnt")
        if memory.chatIDs.count > 1 { parts.append("in \(memory.chatIDs.count) Chats") }
        return parts.joined(separator: " · ")
    }
}

/// Five small bars for how much a memory weighs; it sinks as time passes.
private struct ImportanceMeter: View {
    let value: Double

    var body: some View {
        let filled = max(1, Int((value * 5).rounded()))
        HStack(spacing: 2) {
            ForEach(0..<5, id: \.self) { index in
                Capsule()
                    .fill(index < filled ? Theme.accent.opacity(0.8) : Theme.ink.opacity(0.1))
                    .frame(width: 3, height: 9)
            }
        }
        .help("Gewicht \(Int((value * 100).rounded())) %: starke Gefühle, häufige Themen und Neues wiegen mehr. Mit der Zeit rutscht eine Erinnerung nach hinten.")
    }
}

private struct ThalamusEntryCard: View {
    let entry: ThalamusEntry
    let chatTitle: String?
    let onOpenChat: () -> Void
    let onDelete: () -> Void
    @State private var hovering = false

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(alignment: .center, spacing: 8) {
                CategoryChip(text: entry.category)
                Text(entry.date.formatted(.dateTime.day().month(.abbreviated).year().hour().minute()))
                    .font(.system(size: 11.5))
                    .foregroundStyle(Theme.textTertiary)
                Spacer(minLength: 8)
                HStack(spacing: 2) {
                    if let chatTitle {
                        Button(action: onOpenChat) {
                            Image(systemName: "arrow.up.right.square")
                                .font(.system(size: 12, weight: .medium))
                                .frame(width: 24, height: 22)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .help("Zur Nachricht im Chat „\(chatTitle)“")
                    }
                    Button(action: onDelete) {
                        Image(systemName: "trash")
                            .font(.system(size: 11.5, weight: .medium))
                            .frame(width: 24, height: 22)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help("Eintrag löschen")
                }
                .foregroundStyle(Theme.textSecondary)
                .opacity(hovering ? 1 : 0.35)
            }
            Text(entry.summary)
                .font(.system(size: 12.5))
                .foregroundStyle(Theme.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
                .help(entry.text)
            EmotionRows(entry: entry)
            if !entry.keywords.isEmpty {
                FlowLayout(spacing: 5, lineSpacing: 5) {
                    ForEach(entry.keywords, id: \.self) { KeywordChip(text: $0) }
                }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Theme.surface))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Theme.strongBorder))
        .onHover { hovering = $0 }
        .contextMenu {
            if chatTitle != nil { Button("Zur Nachricht", systemImage: "arrow.up.right.square", action: onOpenChat) }
            Button("Eintrag löschen", systemImage: "trash", role: .destructive, action: onDelete)
        }
    }
}

private struct FilterChip: View {
    let title: String
    let count: Int
    let isOn: Bool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Text(title)
                    .font(.system(size: 11.5, weight: .medium))
                Text("\(count)")
                    .font(.system(size: 10.5, weight: .semibold).monospacedDigit())
                    .opacity(0.7)
            }
            .foregroundStyle(isOn ? Theme.accent : (hovering ? Theme.textPrimary : Theme.textSecondary))
            .padding(.horizontal, 9)
            .frame(height: 22)
            .background(Capsule().fill(isOn ? Theme.accent.opacity(0.16) : (hovering ? Theme.hover : Theme.ink.opacity(0.04))))
            .overlay(Capsule().strokeBorder(isOn ? Theme.accent.opacity(0.35) : Theme.border))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

/// A compact search field for lists inside the persona editor.
struct SmallSearchField: View {
    @Binding var text: String
    let prompt: String

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 11))
                .foregroundStyle(Theme.textTertiary)
            TextField("", text: $text, prompt: Text(prompt).foregroundStyle(Theme.textTertiary))
                .textFieldStyle(.plain)
                .font(.system(size: 12))
                .foregroundStyle(Theme.textPrimary)
            if !text.isEmpty {
                Button { text = "" } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.textTertiary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 9)
        .frame(height: 26)
        .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(Theme.ink.opacity(0.04)))
        .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous).strokeBorder(Theme.border))
    }
}
