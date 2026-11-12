import SwiftUI

/// Rechercherista in small: every research with its state; an open one shows its report to drag into a document,
/// its sources, and the question back if it waits for an answer.
struct PowerResearch: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        let query = app.power.query
        if let id = app.power.researchID, app.research.research(id) != nil, query.isEmpty {
            PowerResearchView(researchID: id)
        } else {
            PowerResearchList(query: query)
        }
    }
}

private struct PowerResearchList: View {
    @Environment(AppModel.self) private var app
    let query: String

    var body: some View {
        let library = app.research
        let _ = library.loadIfNeeded()
        let shown = library.records.records.filter { $0.matches(query) }
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 1) {
                ForEach(shown) { item in
                    PowerListRow(title: item.displayTitle,
                                 subtitle: library.progress[item.id].map { "\(Int($0.fraction * 100)) % · \($0.detail)" } ?? item.phase.label,
                                 symbol: item.phase == .fertig ? "checkmark.seal" : StudioApplication.research.symbol) {
                        app.power.researchID = item.id
                    }
                }
                if shown.isEmpty {
                    PowerEmpty(text: query.isEmpty ? "Noch keine Recherchen." : "Keine Recherche passt zur Suche.")
                }
                PowerDropZone(title: "Text hierher ziehen: neue Recherche dazu", symbol: StudioApplication.research.symbol) { dropped in
                    let made = app.newResearch(question: String(dropped.markdown.prefix(600)), open: false)
                    app.power.researchID = made.id
                    app.power.lastChange = PowerAccess.Change(label: "Recherche angelegt") { [weak app] in
                        app?.research.records.remove(made.id)
                        if app?.power.researchID == made.id { app?.power.researchID = nil }
                    }
                }
                .padding(.top, 10)
            }
            .padding(.horizontal, 10)
            .padding(.bottom, 12)
        }
    }
}

private struct PowerResearchView: View {
    @Environment(AppModel.self) private var app
    let researchID: UUID

    var body: some View {
        let item = app.research.research(researchID)
        VStack(spacing: 0) {
            PowerItemBar(title: item?.displayTitle ?? "", symbol: StudioApplication.research.symbol, openHelp: "In Rechercherista öffnen") {
                app.power.closeItem()
            } onOpen: {
                app.openResearchStudio(showing: researchID)
            }
            if let item {
                ScrollView {
                    VStack(alignment: .leading, spacing: 10) {
                        if let progress = app.research.progress[researchID] {
                            ProgressView(value: progress.fraction)
                            Text(progress.detail).font(.system(size: 11.5)).foregroundStyle(Theme.textSecondary)
                        }
                        if item.phase == .rueckfrage, let clarification = item.clarification {
                            Text(clarification.question).font(.system(size: 12.5, weight: .medium))
                            ForEach(clarification.options, id: \.self) { option in
                                Button(option) { app.answerResearch(researchID, option) }.buttonStyle(.bordered).controlSize(.small)
                            }
                        }
                        if item.phase == .entwurf || item.phase == .gestoppt || item.phase == .fehler {
                            Button(item.nodes.isEmpty ? "Recherche starten" : "Fortsetzen", systemImage: "play.fill") { app.startResearch(researchID) }
                                .disabled(item.question.isEmpty)
                        }
                        if !item.report.isEmpty {
                            HStack {
                                Image(systemName: "hand.draw").font(.system(size: 11))
                                Text("Bericht in ein Dokument oder den Chat ziehen").font(.system(size: 11))
                            }
                            .foregroundStyle(Theme.textTertiary)
                            .padding(8)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(RoundedRectangle(cornerRadius: 8).strokeBorder(Theme.border, style: StrokeStyle(lineWidth: 1, dash: [4, 3])))
                            .powerDrag(markdown: item.report, plain: item.report)
                            MarkdownView(text: item.report).textSelection(.enabled)
                        } else {
                            ForEach(item.nodes.filter { $0.parent != nil }) { node in
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(node.question).font(.system(size: 12, weight: .medium))
                                    if !node.summary.isEmpty {
                                        Text(node.summary).font(.system(size: 11.5)).foregroundStyle(Theme.textSecondary).lineLimit(6)
                                            .powerDrag(markdown: node.summary, plain: node.summary)
                                    }
                                }
                            }
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.bottom, 14)
                }
            }
        }
    }
}
