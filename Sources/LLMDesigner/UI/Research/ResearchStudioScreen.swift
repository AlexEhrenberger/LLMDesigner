import SwiftUI

@MainActor
@Observable
final class ResearchStudioModel {
    var selectedID: UUID?
    var query = ""
    var tab: ResearchTab = .tree
}

/// Rechercherista: a research assignment for the local model, step by step to a report.
struct ResearchStudioScreen: View {
    @Environment(AppModel.self) private var app
    @State private var model = ResearchStudioModel()

    var body: some View {
        let library = app.research
        VStack(spacing: 0) {
            StudioTopBar(symbol: StudioApplication.research.symbol, title: "Rechercherista", detail: detail, close: { app.closeResearchStudio() }) {
                if let id = model.selectedID, let item = library.research(id), !item.nodes.isEmpty || !item.report.isEmpty {
                    StudioTabPicker(tabs: ResearchTab.allCases, selection: $model.tab, title: \.title, symbol: \.symbol) { tab in
                        tab == .sources ? item.sources.count : nil
                    }
                }
            } trailing: {
                IconButton(systemName: "plus", help: "Neue Recherche", size: 13, frameSize: Theme.titleBarControlSize) {
                    model.selectedID = app.newResearch(open: false).id
                    model.tab = .tree
                }
                PowerButton()
            }
            if library.records.records.isEmpty {
                StudioEmptyState(symbol: "binoculars", title: "Rechercherista",
                                 text: "Gib deinem lokalen Modell einen Forschungsauftrag. Es klärt die Begriffe bei Wikipedia, fragt nach, wenn etwas mehrdeutig ist, zerlegt den Auftrag in Teilfragen, sucht in Wikipedia, im Web, auf arXiv und in OpenAlex, schließt Lücken und schreibt einen Bericht mit Quellen.",
                                 actionTitle: "Recherche anlegen") { model.selectedID = app.newResearch(open: false).id }
            } else {
                HStack(spacing: 0) {
                    ResearchList(model: model)
                        .frame(width: 270)
                    Rectangle().fill(Theme.border).frame(width: 1)
                    Group {
                        if let id = model.selectedID, library.research(id) != nil {
                            ResearchPage(researchID: id, model: model).id(id)
                        } else {
                            Text("Wähle links eine Recherche.").font(.system(size: 13)).foregroundStyle(Theme.textTertiary)
                                .frame(maxWidth: .infinity, maxHeight: .infinity)
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
        }
        .background(Theme.background)
        .onAppear {
            library.loadIfNeeded()
            if model.selectedID == nil { model.selectedID = library.records.records.first?.id }
            take(app.researchStudioCommand)
        }
        .onChange(of: app.researchStudioCommand) { _, command in take(command) }
    }

    private var detail: String {
        let records = app.research.records.records
        let running = records.filter(\.phase.isRunning).count
        return "\(records.count) Recherchen" + (running > 0 ? " · \(running) läuft" : "")
    }

    private func take(_ command: ResearchStudioCommand?) {
        guard let command else { return }
        if let id = command.research { model.selectedID = id }
        if let tab = command.tab { model.tab = tab }
        app.researchStudioCommand = nil
    }
}

private struct ResearchList: View {
    @Environment(AppModel.self) private var app
    @Environment(\.undoManager) private var undoManager
    @Bindable var model: ResearchStudioModel

    var body: some View {
        let shown = app.research.records.records.filter { $0.matches(model.query) }
        VStack(spacing: 0) {
            SearchField(text: $model.query, prompt: "Recherchen durchsuchen")
                .padding(.horizontal, 10)
                .padding(.bottom, 6)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 1) {
                    ForEach(shown) { item in
                        StudioListRow(symbol: symbol(item), color: color(item), title: item.displayTitle,
                                      subtitle: subtitle(item), isSelected: model.selectedID == item.id) {
                            model.selectedID = item.id
                        }
                        .contextMenu {
                            Button("Löschen", systemImage: "trash", role: .destructive) {
                                app.stopResearch(item.id)
                                app.research.records.delete(item.id, label: "Recherche löschen", undo: undoManager)
                                if model.selectedID == item.id { model.selectedID = app.research.records.records.first?.id }
                            }
                        }
                    }
                }
                .padding(.horizontal, 6)
                .padding(.bottom, 12)
            }
        }
        .background(Theme.sidebar.opacity(0.5))
    }

    private func symbol(_ item: Research) -> String {
        switch item.phase {
        case .fertig: "checkmark.seal"
        case .rueckfrage: "questionmark.bubble"
        case .fehler: "exclamationmark.triangle"
        case .entwurf: "square.and.pencil"
        case .gestoppt: "pause.circle"
        default: "binoculars"
        }
    }

    private func color(_ item: Research) -> Color {
        switch item.phase {
        case .fertig: Theme.success
        case .rueckfrage: Theme.warning
        case .fehler: Theme.danger
        default: Theme.accent
        }
    }

    private func subtitle(_ item: Research) -> String {
        if let progress = app.research.progress[item.id] { return "\(Int(progress.fraction * 100)) % · \(progress.detail)" }
        return item.phase.label + (item.sources.isEmpty ? "" : " · \(item.sources.count) Quellen")
    }
}

/// One research: the assignment, its state, the tree, the sources and the report.
private struct ResearchPage: View {
    @Environment(AppModel.self) private var app
    let researchID: UUID
    @Bindable var model: ResearchStudioModel
    @State private var notice: String?

    var body: some View {
        if let item = app.research.research(researchID) {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if item.phase == .entwurf && item.nodes.isEmpty {
                        ResearchDraft(researchID: researchID)
                    } else {
                        header(item)
                    }
                    if let progress = app.research.progress[researchID] {
                        runningCard(progress, item: item)
                    }
                    if item.phase == .rueckfrage, let clarification = item.clarification {
                        ClarificationCard(researchID: researchID, clarification: clarification)
                    }
                    if let error = item.error {
                        Label(error, systemImage: "exclamationmark.triangle").font(.system(size: 12.5)).foregroundStyle(Theme.danger)
                    }
                    if !item.nodes.isEmpty || !item.report.isEmpty {
                        switch model.tab {
                        case .tree: ResearchTreeView(item: item)
                        case .sources: ResearchSourcesView(researchID: researchID)
                        case .report: reportView(item)
                        }
                    }
                }
                .padding(24)
                .frame(maxWidth: 1000, alignment: .leading)
                .frame(maxWidth: .infinity)
            }
        }
    }

    private func header(_ item: Research) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(item.displayTitle).font(.system(size: 21, weight: .semibold)).textSelection(.enabled)
            // A research without its own title shows its question as the title already.
            if !item.title.trimmingCharacters(in: .whitespaces).isEmpty, item.title != item.question {
                Text(item.question).font(.system(size: 13)).foregroundStyle(Theme.textSecondary).textSelection(.enabled)
            }
            HStack(spacing: 8) {
                if let focus = item.focus {
                    Label(focus, systemImage: "scope").font(.system(size: 12)).foregroundStyle(Theme.accent)
                }
                ForEach(item.allowedKinds) { kind in
                    Label(kind.label, systemImage: kind.symbol).font(.system(size: 11)).foregroundStyle(Theme.textTertiary)
                }
                Text(item.depth.label).font(.system(size: 11)).foregroundStyle(Theme.textTertiary)
                if item.restricted {
                    Label("nur Wikipedia (Chat mit privaten Dateien)", systemImage: "lock").font(.system(size: 11)).foregroundStyle(Theme.warning)
                }
                Spacer()
                if item.phase.isRunning {
                    Button("Anhalten", systemImage: "stop.fill") { app.stopResearch(researchID) }
                } else if item.phase != .fertig && item.phase != .rueckfrage {
                    Button(item.nodes.isEmpty ? "Starten" : "Fortsetzen", systemImage: "play.fill") { start() }
                        .buttonStyle(.borderedProminent)
                }
                Menu {
                    Button("Bericht neu schreiben", systemImage: "arrow.clockwise") {
                        app.research.records.update(researchID) { $0.report = ""; $0.phase = .gestoppt }
                        start()
                    }
                    .disabled(item.nodes.isEmpty || item.phase.isRunning)
                    Button("Von vorn (Fokus behalten)", systemImage: "arrow.counterclockwise") { app.restartResearch(researchID) }
                    Button("Von vorn mit neuer Rückfrage", systemImage: "questionmark.circle") { app.restartResearch(researchID, keepFocus: false) }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .menuStyle(.button)
                .buttonStyle(.plain)
                .fixedSize()
            }
            if let notice { Text(notice).font(.system(size: 12)).foregroundStyle(Theme.textSecondary) }
        }
    }

    private func start() {
        notice = app.startResearch(researchID)
    }

    private func runningCard(_ progress: ResearchProgress, item: Research) -> some View {
        StudioCard(title: item.phase.label, symbol: "binoculars") {
            ProgressView(value: progress.fraction)
            Text(progress.detail).font(.system(size: 12.5)).foregroundStyle(Theme.textSecondary).lineLimit(2)
            VStack(alignment: .leading, spacing: 2) {
                ForEach(Array(item.log.suffix(6).enumerated()), id: \.offset) { _, line in
                    Text(line).font(.system(size: 11, design: .monospaced)).foregroundStyle(Theme.textTertiary).lineLimit(1)
                }
            }
        }
    }

    private func reportView(_ item: Research) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            if item.report.isEmpty {
                Text(item.phase.isRunning ? "Der Bericht entsteht am Ende." : "Noch kein Bericht.").font(.system(size: 13)).foregroundStyle(Theme.textTertiary)
            } else {
                HStack(spacing: 10) {
                    Button("Als Dokument", systemImage: StudioApplication.writer.symbol) { app.researchDocument(researchID) }
                    Button("Präsentation", systemImage: StudioApplication.presenter.symbol) { app.researchPresentation(researchID) }
                    Button("Podcast", systemImage: StudioApplication.podcast.symbol) { app.researchPodcast(researchID) }
                    Button("Quellen nach Citation Studio", systemImage: "quote.bubble") {
                        Task {
                            let count = await app.importResearchSources(researchID)
                            notice = count == 0 ? "Keine neuen Fachquellen mit DOI oder arXiv-Nummer." : "\(count) Quellen in Citation Studio übernommen."
                        }
                    }
                    Spacer()
                    CopyButton(text: item.report, help: "Bericht als Markdown kopieren")
                }
                .font(.system(size: 12))
                MarkdownView(text: item.report)
                    .textSelection(.enabled)
                    .padding(20)
                    .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Theme.ink.opacity(0.03)))
            }
        }
    }
}

/// A new research: the question, what it should search, how thorough.
private struct ResearchDraft: View {
    @Environment(AppModel.self) private var app
    let researchID: UUID
    @State private var focus = ""
    @State private var problem: String?

    var body: some View {
        if let item = app.research.research(researchID) {
            VStack(alignment: .leading, spacing: 14) {
                Text("Forschungsauftrag").font(.system(size: 21, weight: .semibold))
                StoryTextEditor(placeholder: "Was willst du wissen? Zum Beispiel: Predictive Coding – was ist das, was spricht dafür und was dagegen?",
                                text: Binding(get: { item.question }, set: { text in app.research.records.update(researchID) { $0.question = text } }), minLines: 3,
                                font: .systemFont(ofSize: 15))
                    .padding(10)
                    .background(RoundedRectangle(cornerRadius: 10).fill(Theme.ink.opacity(0.05)))
                VStack(alignment: .leading, spacing: 4) {
                    Text("Gemeint ist (optional – sonst fragt Rechercherista bei Mehrdeutigkeit nach)").font(.system(size: 11.5)).foregroundStyle(Theme.textTertiary)
                    StudioField(placeholder: "z. B. im Sinne der Kognitionswissenschaft", text: $focus)
                }
                Text("Quellen").font(.system(size: 12, weight: .semibold)).foregroundStyle(Theme.textSecondary)
                HStack(spacing: 10) {
                    ForEach(ResearchSourceKind.allCases) { kind in
                        let on = item.sourceKinds.contains(kind)
                        Button {
                            app.research.records.update(researchID) { item in
                                if on { item.sourceKinds.removeAll { $0 == kind } } else { item.sourceKinds.append(kind) }
                            }
                        } label: {
                            VStack(alignment: .leading, spacing: 3) {
                                Label(kind.label, systemImage: kind.symbol).font(.system(size: 12.5, weight: .semibold))
                                Text(kind.summary).font(.system(size: 10.5)).foregroundStyle(Theme.textTertiary).lineLimit(2).multilineTextAlignment(.leading)
                            }
                            .padding(10)
                            .frame(width: 170, height: 64, alignment: .topLeading)
                            .background(RoundedRectangle(cornerRadius: 10).fill(on ? Theme.accent.opacity(0.14) : Theme.ink.opacity(0.04)))
                            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(on ? Theme.accent : Theme.border))
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .disabled(item.restricted && kind != .wikipedia)
                    }
                }
                HStack(spacing: 16) {
                    Picker("Tiefe", selection: Binding(get: { item.depth }, set: { depth in app.research.records.update(researchID) { $0.depth = depth } })) {
                        ForEach(ResearchDepth.allCases) { Text($0.label).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .frame(width: 320)
                    Picker("Sprache", selection: Binding(get: { item.language }, set: { language in app.research.records.update(researchID) { $0.language = language } })) {
                        Text("Deutsch").tag("de")
                        Text("Englisch").tag("en")
                    }
                    .frame(width: 170)
                    Toggle("Denkmodus", isOn: Binding(get: { item.thinking }, set: { on in app.research.records.update(researchID) { $0.thinking = on } }))
                        .help("Das Modell denkt vor dem Schreiben der Zusammenfassungen und des Berichts nach – gründlicher, aber langsamer")
                }
                .font(.system(size: 12.5))
                Text("\(item.depth.subQuestions) Teilfragen" + (item.depth.followUps > 0 ? ", danach bis zu \(item.depth.followUps) Folgefragen für Lücken" : "") + ". Mit Qwen 3.5 9B dauert eine gründliche Recherche etwa 10 bis 25 Minuten; sie läuft im Hintergrund weiter.")
                    .font(.system(size: 11.5)).foregroundStyle(Theme.textTertiary)
                HStack {
                    Button {
                        let trimmed = focus.trimmingCharacters(in: .whitespacesAndNewlines)
                        if !trimmed.isEmpty {
                            app.research.records.update(researchID) { $0.clarification = ResearchClarification(question: "", options: [], answer: trimmed) }
                        }
                        problem = app.startResearch(researchID)
                    } label: {
                        Label("Recherche starten", systemImage: "play.fill").padding(.horizontal, 8)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .disabled(item.question.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    if let problem { Text(problem).font(.system(size: 12)).foregroundStyle(Theme.danger) }
                }
            }
        }
    }
}

/// "Was meinst du eigentlich?": the meanings Wikipedia showed, as buttons, and a field for an own answer.
private struct ClarificationCard: View {
    @Environment(AppModel.self) private var app
    let researchID: UUID
    let clarification: ResearchClarification
    @State private var own = ""

    var body: some View {
        StudioCard(title: "Rückfrage", symbol: "questionmark.bubble") {
            Text(clarification.question).font(.system(size: 14, weight: .medium))
            ForEach(clarification.options, id: \.self) { option in
                Button {
                    app.answerResearch(researchID, option)
                } label: {
                    HStack {
                        Image(systemName: "arrow.right.circle")
                        Text(option).multilineTextAlignment(.leading)
                        Spacer()
                    }
                    .padding(10)
                    .background(RoundedRectangle(cornerRadius: 9).fill(Theme.accent.opacity(0.1)))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            HStack {
                StudioField(placeholder: "Oder in eigenen Worten …", text: $own)
                    .onSubmit { if !own.isEmpty { app.answerResearch(researchID, own) } }
                Button("Weiter") { app.answerResearch(researchID, own) }.disabled(own.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Theme.warning.opacity(0.6), lineWidth: 1.5))
    }
}

/// The tree: the assignment at the top, its sub-questions, their follow-ups indented with lines.
private struct ResearchTreeView: View {
    let item: Research

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let root = item.root {
                HStack(spacing: 8) {
                    Image(systemName: "target").foregroundStyle(Theme.accent)
                    Text(root.question).font(.system(size: 14, weight: .semibold))
                }
                .padding(.bottom, 10)
                ForEach(Array(item.children(of: root.id).enumerated()), id: \.element.id) { index, node in
                    ResearchNodeView(item: item, node: node, number: "\(index + 1)", level: 0)
                }
            }
            if !item.orientation.isEmpty {
                DisclosureGroup("Orientierung bei Wikipedia") {
                    Text(item.orientation).font(.system(size: 12)).foregroundStyle(Theme.textSecondary).textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .font(.system(size: 12))
                .padding(.top, 14)
            }
            if !item.log.isEmpty {
                DisclosureGroup("Protokoll (\(item.log.count) Schritte)") {
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(Array(item.log.enumerated()), id: \.offset) { _, line in
                            Text(line).font(.system(size: 11, design: .monospaced)).foregroundStyle(Theme.textTertiary)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .font(.system(size: 12))
            }
        }
    }
}

private struct ResearchNodeView: View {
    let item: Research
    let node: ResearchNode
    let number: String
    let level: Int
    @State private var open = false

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            // The line down from the parent.
            Rectangle().fill(Theme.border).frame(width: 1.5).padding(.leading, 9)
            VStack(alignment: .leading, spacing: 6) {
                Button {
                    withAnimation(.snappy(duration: 0.2)) { open.toggle() }
                } label: {
                    HStack(alignment: .top, spacing: 8) {
                        Rectangle().fill(Theme.border).frame(width: 12, height: 1.5).padding(.top, 9)
                        statusIcon
                        Text(number).font(.system(size: 11, weight: .bold).monospacedDigit()).foregroundStyle(Theme.textTertiary).padding(.top, 2)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(node.question).font(.system(size: 13, weight: .medium)).foregroundStyle(Theme.textPrimary).multilineTextAlignment(.leading)
                            if !node.reason.isEmpty {
                                Text("Folgefrage: \(node.reason)").font(.system(size: 11)).foregroundStyle(Theme.textTertiary)
                            }
                            if !open, !node.summary.isEmpty {
                                Text(node.summary).font(.system(size: 12)).foregroundStyle(Theme.textSecondary).lineLimit(2)
                            }
                        }
                        Spacer(minLength: 0)
                        if !node.sources.isEmpty {
                            Text("\(node.sources.count) Quellen").font(.system(size: 10.5)).foregroundStyle(Theme.textTertiary)
                        }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                if open {
                    VStack(alignment: .leading, spacing: 8) {
                        if !node.summary.isEmpty {
                            MarkdownView(text: node.summary).textSelection(.enabled)
                        }
                        if !node.queries.isEmpty {
                            Text(node.queries.joined(separator: " · ")).font(.system(size: 10.5, design: .monospaced)).foregroundStyle(Theme.textTertiary)
                        }
                        FlowSources(item: item, ids: node.sources)
                    }
                    .padding(12)
                    .background(RoundedRectangle(cornerRadius: 10).fill(Theme.ink.opacity(0.035)))
                    .padding(.leading, 40)
                }
                ForEach(Array(item.children(of: node.id).enumerated()), id: \.element.id) { index, child in
                    ResearchNodeView(item: item, node: child, number: "\(number).\(index + 1)", level: level + 1)
                        .padding(.leading, 26)
                }
            }
            .padding(.bottom, 8)
        }
    }

    @ViewBuilder private var statusIcon: some View {
        switch node.status {
        case .fertig: Image(systemName: "checkmark.circle.fill").foregroundStyle(Theme.success)
        case .laeuft: ProgressView().controlSize(.mini).frame(width: 16)
        case .offen: Image(systemName: "circle").foregroundStyle(Theme.textTertiary)
        case .uebersprungen: Image(systemName: "minus.circle").foregroundStyle(Theme.textTertiary)
        }
    }
}

/// The sources of a question as small chips with their numbers.
private struct FlowSources: View {
    let item: Research
    let ids: [UUID]

    var body: some View {
        let sources = ids.compactMap { item.source($0) }
        if !sources.isEmpty {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 220), spacing: 6, alignment: .leading)], alignment: .leading, spacing: 6) {
                ForEach(sources) { source in
                    Link(destination: URL(string: source.url) ?? URL(string: "https://example.invalid")!) {
                        HStack(spacing: 5) {
                            Text("[\(source.number)]").font(.system(size: 10.5, weight: .bold).monospacedDigit())
                            Image(systemName: source.kind.symbol).font(.system(size: 10))
                            Text(source.title).font(.system(size: 11)).lineLimit(1)
                        }
                        .padding(.horizontal, 7).padding(.vertical, 4)
                        .background(Capsule().fill(Theme.ink.opacity(0.06)))
                        .opacity(source.isUsed ? 1 : 0.45)
                    }
                    .buttonStyle(.plain)
                    .help(source.url)
                }
            }
        }
    }
}

/// Every source with its excerpt; the person keeps or throws out each one before the report is written.
private struct ResearchSourcesView: View {
    @Environment(AppModel.self) private var app
    let researchID: UUID

    var body: some View {
        if let item = app.research.research(researchID) {
            VStack(alignment: .leading, spacing: 8) {
                Text("Wirf Quellen hinaus, die nicht passen – der Bericht nutzt nur die übrigen. Danach „Bericht neu schreiben“.")
                    .font(.system(size: 12)).foregroundStyle(Theme.textTertiary)
                ForEach(ResearchSourceKind.allCases) { kind in
                    let sources = item.sources.filter { $0.kind == kind }.sorted { $0.number < $1.number }
                    if !sources.isEmpty {
                        StudioSectionHeader(title: kind.label, symbol: kind.symbol, count: sources.count)
                        ForEach(sources) { source in row(source) }
                    }
                }
            }
        }
    }

    private func row(_ source: ResearchSource) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Text("[\(source.number)]").font(.system(size: 11.5, weight: .bold).monospacedDigit()).foregroundStyle(Theme.textTertiary).frame(width: 34, alignment: .trailing)
            VStack(alignment: .leading, spacing: 3) {
                Link(source.title, destination: URL(string: source.url) ?? URL(string: "https://example.invalid")!)
                    .font(.system(size: 13, weight: .medium))
                Text([source.byline, source.host, source.citations.map { "\($0) Zitationen" }].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · "))
                    .font(.system(size: 11)).foregroundStyle(Theme.textTertiary)
                Text(source.excerpt).font(.system(size: 11.5)).foregroundStyle(Theme.textSecondary).lineLimit(3)
            }
            Spacer()
            Picker("", selection: Binding(get: { source.accepted }, set: { value in
                app.research.records.update(researchID) { item in
                    if let index = item.sources.firstIndex(where: { $0.id == source.id }) { item.sources[index].accepted = value }
                }
            })) {
                Text("Offen").tag(Bool?.none)
                Text("Annehmen").tag(Bool?.some(true))
                Text("Verwerfen").tag(Bool?.some(false))
            }
            .labelsHidden()
            .frame(width: 120)
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 9).fill(source.accepted == false ? Theme.danger.opacity(0.05) : Theme.ink.opacity(0.035)))
        .opacity(source.accepted == false ? 0.6 : 1)
    }
}
