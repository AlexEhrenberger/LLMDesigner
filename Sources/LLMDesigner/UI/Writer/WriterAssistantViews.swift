import SwiftUI

/// The assistant at the bottom of the sheet: answer and proposal cards, the line with the AI cursor or the
/// selection and quick actions, and the slim instruction bar.
struct WriterAssistantDock: View {
    @Environment(AppModel.self) private var app
    let assistant: WriterAssistant
    let state: WriterTextView.State

    var body: some View {
        VStack(spacing: 8) {
            if let error = assistant.error {
                ErrorStrip(text: error) { assistant.error = nil }
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
            if let proposal = assistant.proposal {
                ProposalCard(assistant: assistant, proposal: proposal)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            } else if let answer = assistant.answer {
                AnswerCard(assistant: assistant, answer: answer)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
            ContextLine(assistant: assistant, state: state)
            InstructionBar(assistant: assistant, state: state)
        }
        .frame(maxWidth: 760)
        .padding(.horizontal, 24)
        .animation(.spring(response: 0.35, dampingFraction: 0.86), value: assistant.proposal?.id)
        .animation(.spring(response: 0.35, dampingFraction: 0.86), value: assistant.answer?.id)
        .animation(.easeOut(duration: 0.2), value: assistant.error)
    }
}

// MARK: Bar

private struct InstructionBar: View {
    @Environment(AppModel.self) private var app
    let assistant: WriterAssistant
    let state: WriterTextView.State
    @FocusState private var focused: Bool

    var body: some View {
        @Bindable var app = app
        let mode = assistant.mode(for: app.writerInstruction)
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .bottom, spacing: 8) {
                Image(systemName: "sparkles")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Theme.accent)
                    .symbolEffect(.pulse, isActive: assistant.isBusy)
                    .frame(height: 30)
                TextField("", text: $app.writerInstruction, prompt: Text(placeholder(mode)).foregroundStyle(Theme.textTertiary), axis: .vertical)
                    .textFieldStyle(.plain)
                    .font(.system(size: 14))
                    .foregroundStyle(Theme.textPrimary)
                    .lineLimit(1...5)
                    .focused($focused)
                    .onSubmit { assistant.send() }
                    .onExitCommand { assistant.textView.map { $0.window?.makeFirstResponder($0) } }
                    .padding(.vertical, 6)
                ModeMenu(assistant: assistant, mode: mode, hasSelection: state.selectionLength > 0)
                    .frame(height: 30)
                microphone
                sendButton
            }
            if app.dictationIntoInstruction {
                Text(app.dictationPreview.isEmpty ? dictationStatus : app.dictationPreview)
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.textTertiary)
                    .lineLimit(2)
                    .padding(.leading, 30)
                    .padding(.bottom, 4)
            }
        }
        .padding(.leading, 14)
        .padding(.trailing, 7)
        .padding(.vertical, 5)
        .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(Theme.elevated))
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(focused || assistant.isBusy ? Theme.accent.opacity(0.55) : Theme.strongBorder, lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.45), radius: 18, y: 6)
        .onChange(of: assistant.focusRequest) { _, _ in focused = true }
        .onChange(of: focused) { _, isFocused in app.isWriterInstructionFocused = isFocused }
    }

    private func placeholder(_ mode: WriterPrompts.Mode) -> String {
        if let intent = assistant.forcedPresentationIntent {
            switch intent.kind {
            case .createDeck: return "Worüber soll die Präsentation gehen? z. B. „Predictive Coding, 8 Folien“"
            case .speakerNotes: return "Wünsche an die Moderatorenkarten (optional), dann ⏎"
            case .present: return "⏎ startet den Vortrag"
            }
        }
        if assistant.isPresentation, mode == .write {
            return "Anweisung an die KI, z. B. „Erstelle eine Präsentation über Predictive Coding“ oder „Schreib Moderatorenkarten“ (⌘J)"
        }
        switch mode {
        case .write: return "Anweisung an die KI, z. B. „Schreib einen Absatz über die Gründung von Paris“ (⌘J)"
        case .rewrite: return "Was soll mit der Markierung passieren? z. B. „Mach daraus eine Liste“"
        case .answer: return state.selectionLength > 0 ? "Frage zur Markierung, z. B. „Stimmt das so?“" : "Frage zum Dokument"
        }
    }

    private var dictationStatus: String {
        switch app.dictationStatus {
        case .preparing: "Mikrofon wird vorbereitet …"
        case .finishing: "Letzte Worte …"
        default: "Ich höre zu – sprich deine Anweisung"
        }
    }

    private var microphone: some View {
        Button { app.toggleDictation(intoInstruction: true) } label: {
            Image(systemName: app.dictationIntoInstruction ? "mic.fill" : "mic")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(app.dictationIntoInstruction ? Theme.danger : Theme.textSecondary)
                .frame(width: 30, height: 30)
                .background(Circle().fill(app.dictationIntoInstruction ? Theme.danger.opacity(0.15) : .clear))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .disabled(!app.isDictationAvailable)
        .help(app.dictationIntoInstruction ? "Diktat beenden" : "Anweisung einsprechen")
    }

    @ViewBuilder
    private var sendButton: some View {
        if assistant.isBusy {
            HStack(spacing: 6) {
                Text(activityText)
                    .font(.system(size: 11.5, weight: .medium).monospacedDigit())
                    .foregroundStyle(Theme.textTertiary)
                    .fixedSize()
                Button { assistant.stop() } label: {
                    Image(systemName: "stop.fill")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(Theme.background)
                        .frame(width: 30, height: 30)
                        .background(Circle().fill(Theme.textPrimary))
                }
                .buttonStyle(.plain)
                .help("Stoppen")
            }
        } else {
            let canSend = !app.writerInstruction.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                || (assistant.forcedPresentationIntent != nil && assistant.forcedPresentationIntent?.kind != .createDeck)
            Button { assistant.send() } label: {
                Image(systemName: "arrow.up")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(canSend ? Theme.background : Theme.textTertiary)
                    .frame(width: 30, height: 30)
                    .background(Circle().fill(canSend ? Theme.accent : Color.white.opacity(0.08)))
            }
            .buttonStyle(.plain)
            .disabled(!canSend)
            .help("Senden (⏎)")
        }
    }

    private var activityText: String {
        switch assistant.activity {
        case .thinking: "denkt nach …"
        case .writing: "schreibt …"
        case .rewriting: "formuliert …"
        case .answering: "antwortet …"
        case .checking(let done, let total): "prüft \(min(done + 1, total)) / \(total)"
        case .idle: ""
        }
    }
}

/// Shows what the instruction will do and lets the user choose it.
private struct ModeMenu: View {
    @Environment(AppModel.self) private var app
    let assistant: WriterAssistant
    let mode: WriterPrompts.Mode
    let hasSelection: Bool
    @State private var hovering = false

    var body: some View {
        @Bindable var app = app
        Menu {
            Section("Was passiert mit der Anweisung?") {
                choice(nil, "Automatisch", "wand.and.stars")
                choice(.write, assistant.isPresentation ? "Auf die Folie schreiben" : "Am KI-Cursor schreiben", "character.cursor.ibeam")
                choice(.rewrite, "Markierung überarbeiten", "arrow.triangle.2.circlepath")
                choice(.answer, "Nur antworten", "bubble.left")
            }
            if assistant.isPresentation {
                Section("Ganze Präsentation") {
                    presentationChoice(PresenterIntent(kind: .createDeck), "Präsentation erstellen – Folien zum Thema")
                    presentationChoice(PresenterIntent(kind: .speakerNotes), "Moderatorenkarten für alle Folien")
                    presentationChoice(PresenterIntent(kind: .present, presents: true), "KI präsentiert")
                }
            }
            Section {
                Toggle("Antworten vorlesen", isOn: $app.writerReadsAnswers)
            }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: symbol)
                    .font(.system(size: 10.5, weight: .semibold))
                Text(label)
                    .font(.system(size: 11.5, weight: .medium))
                    .lineLimit(1)
                Image(systemName: "chevron.down")
                    .font(.system(size: 7, weight: .bold))
                    .foregroundStyle(Theme.textTertiary)
            }
            .foregroundStyle(assistant.forcedMode == nil && assistant.forcedPresentationIntent == nil ? (hovering ? Theme.textPrimary : Theme.textSecondary) : Theme.accent)
            .padding(.horizontal, 8)
            .frame(height: 24)
            .background(Capsule().fill(Color.white.opacity(hovering ? 0.08 : 0.04)))
            .contentShape(Capsule())
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .onHover { hovering = $0 }
        .help("Wie die KI die Anweisung umsetzt")
    }

    private var intent: PresenterIntent? {
        assistant.presentationIntent(for: app.writerInstruction)
    }

    private var label: String {
        if let intent { return intent.label }
        switch mode {
        case .write: return assistant.isPresentation ? "schreibt auf die Folie" : "schreibt am KI-Cursor"
        case .rewrite: return "überarbeitet Markierung"
        case .answer: return "antwortet"
        }
    }

    private var symbol: String {
        if let intent { return intent.symbol }
        switch mode {
        case .write: return "character.cursor.ibeam"
        case .rewrite: return "arrow.triangle.2.circlepath"
        case .answer: return "bubble.left"
        }
    }

    private func choice(_ value: WriterPrompts.Mode?, _ title: String, _ symbol: String) -> some View {
        Button {
            assistant.forcedMode = value
            if value == nil { assistant.forcedPresentationIntent = nil }
        } label: {
            let isOn = assistant.forcedMode == value && (value != nil || assistant.forcedPresentationIntent == nil)
            if isOn { Label(title, systemImage: "checkmark") } else { Label(title, systemImage: symbol) }
        }
        .disabled(value == .rewrite && !hasSelection)
    }

    private func presentationChoice(_ intent: PresenterIntent, _ title: String) -> some View {
        Button {
            assistant.forcedPresentationIntent = intent
            assistant.requestFocus()
        } label: {
            if assistant.forcedPresentationIntent?.kind == intent.kind { Label(title, systemImage: "checkmark") } else { Label(title, systemImage: intent.symbol) }
        }
    }
}

// MARK: Context line

/// Where the AI writes (or what is selected), with the quick actions that fit.
private struct ContextLine: View {
    let assistant: WriterAssistant
    let state: WriterTextView.State

    var body: some View {
        HStack(spacing: 6) {
            if state.selectionLength > 0 {
                Chip(symbol: "selection.pin.in.out", text: "Markierung: „\(state.selectionExcerpt)“", accent: true)
                    .help("Die Markierung gehört zur nächsten Anweisung (\(state.selectionLength) Zeichen)")
                Spacer(minLength: 8)
                Menu {
                    ForEach(WriterPrompts.Rewrite.allCases) { preset in
                        Button(preset.label) { assistant.rewrite(preset) }
                    }
                } label: {
                    QuickLabel(symbol: "arrow.triangle.2.circlepath", title: "Umformulieren", chevron: true)
                }
                .quickMenu()
                QuickButton(symbol: "text.append", title: "Ausformulieren") { assistant.expand() }
                    .help("Stichpunkte zu Fließtext")
                checkMenu(title: "Prüfen")
            } else {
                CursorChip(assistant: assistant, state: state)
                Spacer(minLength: 8)
                QuickButton(symbol: "sparkles", title: "Weiterschreiben") {
                    assistant.write("Schreib sinnvoll weiter, im Stil des Dokuments.")
                }
                .help("Die KI schreibt am KI-Cursor weiter")
                checkMenu(title: "Dokument prüfen")
            }
        }
        .disabled(assistant.isBusy)
        .padding(.horizontal, 4)
    }

    private func checkMenu(title: String) -> some View {
        Menu {
            ForEach(WriterPrompts.Check.allCases) { check in
                Button(check.title) { assistant.run(check) }
            }
        } label: {
            QuickLabel(symbol: "checkmark.seal", title: title, chevron: true)
        }
        .quickMenu()
    }
}

/// Where the AI cursor is; its menu moves it.
private struct CursorChip: View {
    let assistant: WriterAssistant
    let state: WriterTextView.State

    var body: some View {
        Menu {
            Button("An meinen Cursor setzen", systemImage: "character.cursor.ibeam") {
                guard let textView = assistant.textView else { return }
                textView.placeAICursor(at: textView.selectedRange().location)
                textView.onStateChange?()
            }
            Button("Ans Dokumentende", systemImage: "arrow.down.to.line") {
                guard let textView = assistant.textView else { return }
                textView.placeAICursor(at: textView.textStorage?.length ?? 0)
                textView.onStateChange?()
            }
            Button("Zum KI-Cursor scrollen", systemImage: "scope") {
                guard let textView = assistant.textView else { return }
                textView.scrollRangeToVisible(NSRange(location: textView.aiCursorLocation, length: 0))
            }
        } label: {
            Chip(symbol: "character.cursor.ibeam", text: text, accent: false)
        }
        .quickMenu()
        .help("Hier schreibt die KI. Rechtsklick im Text: „KI-Cursor hierher setzen“")
    }

    private var text: String {
        if state.aiCursorContext.isEmpty { return "KI schreibt am Anfang" }
        if state.isAICursorAtEnd { return "KI schreibt am Ende" }
        return "KI schreibt nach „\(state.aiCursorContext)“"
    }
}

private struct Chip: View {
    let symbol: String
    let text: String
    let accent: Bool

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: symbol)
                .font(.system(size: 10.5, weight: .semibold))
            Text(text)
                .font(.system(size: 11.5, weight: .medium))
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .foregroundStyle(accent ? Theme.accent : Theme.textSecondary)
        .padding(.horizontal, 9)
        .frame(height: 24)
        // Opaque, so the chip reads the same over light and dark pages.
        .background(Capsule().fill(accent ? Theme.accent.opacity(0.14) : .clear))
        .background(Capsule().fill(Theme.elevated))
        .overlay(Capsule().strokeBorder(accent ? Theme.accent.opacity(0.35) : Theme.strongBorder))
    }
}

private struct QuickButton: View {
    let symbol: String
    let title: String
    let action: () -> Void

    var body: some View {
        Button(action: action) { QuickLabel(symbol: symbol, title: title, chevron: false) }
            .buttonStyle(.plain)
    }
}

private struct QuickLabel: View {
    let symbol: String
    let title: String
    let chevron: Bool
    @State private var hovering = false
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: symbol)
                .font(.system(size: 10.5, weight: .semibold))
            Text(title)
                .font(.system(size: 11.5, weight: .medium))
            if chevron {
                Image(systemName: "chevron.down")
                    .font(.system(size: 7, weight: .bold))
                    .foregroundStyle(Theme.textTertiary)
            }
        }
        .foregroundStyle(!isEnabled ? Theme.textTertiary : hovering ? Theme.textPrimary : Theme.textSecondary)
        .padding(.horizontal, 9)
        .frame(height: 24)
        .background(Capsule().fill(hovering && isEnabled ? Theme.hover : .clear))
        .background(Capsule().fill(Theme.elevated))
        .overlay(Capsule().strokeBorder(Theme.strongBorder))
        .contentShape(Capsule())
        .onHover { hovering = $0 }
    }
}

private extension View {
    func quickMenu() -> some View {
        menuStyle(.button)
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
            .fixedSize()
    }
}

// MARK: Cards

private struct AnswerCard: View {
    @Environment(AppModel.self) private var app
    let assistant: WriterAssistant
    let answer: WriterAssistant.Answer

    var body: some View {
        Card {
            HStack(spacing: 6) {
                Image(systemName: "bubble.left.fill")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.accent)
                Text(answer.aboutSelection ? "Antwort zur Markierung" : "Antwort")
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundStyle(Theme.textPrimary)
                Text(answer.question)
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.textTertiary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: 6)
                if !answer.isComplete { PulsingDot(size: 6, color: Theme.accent) }
                CardIcon(symbol: "xmark", help: "Schließen") { assistant.dismissAnswer() }
            }
        } content: {
            ScrollView {
                MarkdownView(text: answer.text.isEmpty ? "…" : answer.text)
                    .textSelection(.enabled)
                    .padding(.trailing, 6)
            }
            .frame(maxHeight: 230)
            .fixedSize(horizontal: false, vertical: true)
        } actions: {
            let speaking = app.speakingMessageID == answer.id
            CardButton(symbol: speaking ? "stop.fill" : "speaker.wave.2", title: speaking ? "Stopp" : "Vorlesen") {
                app.toggleReading(answer.text, id: answer.id)
            }
            CardButton(symbol: "doc.on.doc", title: "Kopieren") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(answer.text, forType: .string)
            }
            Spacer(minLength: 6)
            CardButton(symbol: "text.insert", title: "Am KI-Cursor einfügen", primary: true) { assistant.insertAnswer() }
        }
        .disabled(!answer.isComplete)
    }
}

private struct ProposalCard: View {
    @Environment(AppModel.self) private var app
    let assistant: WriterAssistant
    let proposal: WriterAssistant.Proposal

    var body: some View {
        Card {
            HStack(spacing: 6) {
                Image(systemName: "arrow.triangle.2.circlepath")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Theme.accent)
                Text("Vorschlag: \(proposal.title)")
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundStyle(Theme.textPrimary)
                Text("ersetzt die markierte Stelle")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.textTertiary)
                Spacer(minLength: 6)
                if !proposal.isComplete { PulsingDot(size: 6, color: Theme.accent) }
                CardIcon(symbol: "xmark", help: "Verwerfen") { assistant.dismissProposal() }
            }
        } content: {
            ScrollView {
                MarkdownView(text: proposal.text.isEmpty ? "…" : proposal.text)
                    .textSelection(.enabled)
                    .padding(.trailing, 6)
            }
            .frame(maxHeight: 260)
            .fixedSize(horizontal: false, vertical: true)
        } actions: {
            let speaking = app.speakingMessageID == proposal.id
            CardButton(symbol: speaking ? "stop.fill" : "speaker.wave.2", title: speaking ? "Stopp" : "Vorlesen") {
                app.toggleReading(proposal.text, id: proposal.id)
            }
            CardButton(symbol: "arrow.clockwise", title: "Nochmal") { assistant.retryProposal() }
            Spacer(minLength: 6)
            CardButton(symbol: "text.insert", title: "Darunter einfügen") { assistant.insertProposalBelow() }
            CardButton(symbol: "checkmark", title: "Ersetzen", primary: true) { assistant.applyProposal() }
        }
        .disabled(!proposal.isComplete)
    }
}

private struct Card<Header: View, Content: View, Actions: View>: View {
    @ViewBuilder let header: Header
    @ViewBuilder let content: Content
    @ViewBuilder let actions: Actions

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            content
            HStack(spacing: 6) { actions }
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Theme.elevated))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Theme.accent.opacity(0.35)))
        .shadow(color: .black.opacity(0.5), radius: 20, y: 8)
    }
}

private struct CardButton: View {
    let symbol: String
    let title: String
    var primary = false
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: symbol)
                    .font(.system(size: 11, weight: .semibold))
                Text(title)
                    .font(.system(size: 12, weight: .medium))
            }
            .foregroundStyle(primary ? Theme.background : (hovering ? Theme.textPrimary : Theme.textSecondary))
            .padding(.horizontal, 10)
            .frame(height: 28)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(primary ? Theme.accent : Color.white.opacity(hovering ? 0.1 : 0.05)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

/// Stays clickable while the rest of the card waits for the stream.
private struct CardIcon: View {
    let symbol: String
    let help: String
    let action: () -> Void

    var body: some View {
        IconButton(systemName: symbol, help: help, size: 11, frameSize: 22, action: action)
            .environment(\.isEnabled, true)
    }
}

private struct ErrorStrip: View {
    let text: String
    let dismiss: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 11))
                .foregroundStyle(Theme.warning)
            Text(text)
                .font(.system(size: 12))
                .foregroundStyle(Theme.textSecondary)
                .lineLimit(2)
            Spacer(minLength: 4)
            IconButton(systemName: "xmark", help: "Ausblenden", size: 10, frameSize: 20, action: dismiss)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Theme.elevated))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Theme.warning.opacity(0.35)))
    }
}

// MARK: Check panel

/// Findings of a check, beside the sheet. Clicking one marks it in the text.
struct WriterCheckPanel: View {
    let assistant: WriterAssistant

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider().overlay(Theme.border)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 10) {
                    if let check = assistant.check, check.check == .plausibility {
                        Text("Einschätzung des Modells, keine Quelle. Fakten bitte selbst nachprüfen.")
                            .font(.system(size: 11))
                            .foregroundStyle(Theme.textTertiary)
                    }
                    ForEach(assistant.findings) { finding in
                        FindingRow(assistant: assistant, finding: finding)
                    }
                    if assistant.check?.isComplete == true, assistant.findings.isEmpty {
                        VStack(spacing: 8) {
                            Image(systemName: "checkmark.circle.fill")
                                .font(.system(size: 26))
                                .foregroundStyle(Theme.success)
                            Text(emptyMessage)
                                .font(.system(size: 13, weight: .medium))
                                .foregroundStyle(Theme.textSecondary)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.top, 30)
                    }
                }
                .padding(14)
            }
        }
        .frame(maxHeight: .infinity, alignment: .top)
        .background(Theme.sidebar)
        .overlay(alignment: .leading) { Rectangle().fill(Theme.border).frame(width: 1) }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "checkmark.seal")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Theme.accent)
                Text(assistant.check?.check.title ?? "Prüfung")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Theme.textPrimary)
                Spacer(minLength: 4)
                IconButton(systemName: "xmark", help: "Panel schließen", size: 11, frameSize: 24) { assistant.closePanel() }
            }
            HStack(spacing: 6) {
                if case .checking(let done, let total) = assistant.activity {
                    ProgressView(value: Double(done), total: Double(max(total, 1)))
                        .progressViewStyle(.linear)
                        .tint(Theme.accent)
                        .frame(width: 80)
                    Text("Abschnitt \(min(done + 1, total)) von \(total)")
                } else {
                    Text(summary)
                }
                Spacer(minLength: 4)
                if assistant.findings.contains(where: { !$0.correction.isEmpty }), !assistant.isBusy {
                    Button("Alle übernehmen") { assistant.applyAll() }
                        .buttonStyle(.plain)
                        .font(.system(size: 11.5, weight: .semibold))
                        .foregroundStyle(Theme.accent)
                }
            }
            .font(.system(size: 11.5))
            .foregroundStyle(Theme.textTertiary)
        }
        .padding(.horizontal, 14)
        .padding(.top, 10)
        .padding(.bottom, 10)
    }

    private var emptyMessage: String {
        let applied = assistant.check?.applied ?? 0
        if applied > 0 { return applied == 1 ? "Korrektur übernommen." : "\(applied) Korrekturen übernommen." }
        return assistant.check?.check == .plausibility ? "Nichts Unplausibles gefunden." : "Keine Fehler gefunden."
    }

    private var summary: String {
        let scope = assistant.check?.aboutSelection == true ? "Markierung" : "ganzes Dokument"
        let count = assistant.findings.count
        let found = count == 1 ? "1 Stelle" : "\(count) Stellen"
        let failed = (assistant.check?.failedPieces ?? 0) > 0 ? " · \(assistant.check!.failedPieces) Abschnitt(e) fehlgeschlagen" : ""
        return "\(scope) · \(found)\(failed)"
    }
}

private struct FindingRow: View {
    let assistant: WriterAssistant
    let finding: WriterAssistant.Finding
    @State private var hovering = false

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(finding.kind)
                .font(.system(size: 10.5, weight: .semibold))
                .foregroundStyle(color)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(Capsule().fill(color.opacity(0.14)))
            VStack(alignment: .leading, spacing: 3) {
                Text(finding.original)
                    .strikethrough(!finding.correction.isEmpty, color: Theme.danger.opacity(0.8))
                    .foregroundStyle(finding.correction.isEmpty ? Theme.textPrimary : Theme.textSecondary)
                if !finding.correction.isEmpty {
                    HStack(alignment: .firstTextBaseline, spacing: 4) {
                        Image(systemName: "arrow.turn.down.right")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundStyle(Theme.textTertiary)
                        Text(finding.correction)
                            .foregroundStyle(Theme.success)
                    }
                }
            }
            .font(.system(size: 12.5))
            .textSelection(.enabled)
            if !finding.explanation.isEmpty {
                Text(finding.explanation)
                    .font(.system(size: 11.5))
                    .foregroundStyle(Theme.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: 6) {
                if !finding.correction.isEmpty {
                    Button("Übernehmen") { assistant.apply(finding) }
                        .buttonStyle(.plain)
                        .font(.system(size: 11.5, weight: .semibold))
                        .foregroundStyle(Theme.background)
                        .padding(.horizontal, 9)
                        .frame(height: 24)
                        .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(Theme.accent))
                }
                Button("Ignorieren") { assistant.remove(finding) }
                    .buttonStyle(.plain)
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(Theme.textSecondary)
                    .padding(.horizontal, 9)
                    .frame(height: 24)
                    .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(Color.white.opacity(0.06)))
            }
        }
        .padding(11)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Theme.elevated.opacity(hovering ? 1 : 0.7)))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(hovering ? Theme.accent.opacity(0.4) : Theme.border))
        .contentShape(Rectangle())
        .onHover { inside in
            hovering = inside
            if inside { assistant.show(finding) }
        }
        .onTapGesture { assistant.show(finding) }
    }

    private var color: Color {
        switch finding.kind {
        case "Rechtschreibung": Theme.danger
        case "Grammatik": Color(hex: 0xFF9F5A)
        case "Zeichensetzung": Theme.warning
        case "Satzbau": Color(hex: 0x6FD3FF)
        default: Theme.accent
        }
    }
}
