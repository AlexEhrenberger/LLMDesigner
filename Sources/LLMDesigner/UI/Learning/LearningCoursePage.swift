import Charts
import SwiftUI

/// A course: its overview, cards, a learning session, material, the model's quiz and what belongs to it.
struct LearningCoursePage: View {
    @Environment(AppModel.self) private var app
    let courseID: UUID
    @Bindable var model: LearningStudioModel

    var body: some View {
        let library = app.learning
        if let course = library.course(courseID) {
            VStack(spacing: 0) {
                header(course)
                HStack {
                    StudioTabPicker(tabs: CourseTab.allCases, selection: $model.tab, title: \.title, symbol: \.symbol) { tab in
                        switch tab {
                        case .review: library.queue(courseID).count
                        case .cards: course.cards.count
                        case .material: course.materials.count
                        case .links: course.links.count + course.projects.count
                        default: nil
                        }
                    }
                    Spacer()
                }
                .padding(.horizontal, 24)
                .padding(.bottom, 10)
                Divider()
                Group {
                    switch model.tab {
                    case .overview: CourseOverview(courseID: courseID, model: model)
                    case .cards: CourseCardsTab(courseID: courseID)
                    case .review: ReviewSessionView(courseID: courseID)
                    case .material: CourseMaterialTab(courseID: courseID, model: model)
                    case .quiz: CourseQuizTab(courseID: courseID)
                    case .links: CourseLinksTab(courseID: courseID)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    private func header(_ course: LearningCourse) -> some View {
        HStack(alignment: .center, spacing: 14) {
            Menu {
                ForEach(["book", "brain", "function", "atom", "globe.europe.africa", "chart.xyaxis.line", "cpu", "music.note", "leaf", "building.columns", "stethoscope", "scalemass"], id: \.self) { symbol in
                    Button { app.learning.courses.update(courseID) { $0.symbol = symbol } } label: { Image(systemName: symbol) }
                }
                Divider()
                ForEach(FolderColor.allCases, id: \.self) { color in
                    Button(color.name) { app.learning.courses.update(courseID) { $0.color = color } }
                }
            } label: {
                Image(systemName: course.symbol)
                    .font(.system(size: 20, weight: .medium))
                    .foregroundStyle(Color(hex: course.color.hex))
                    .frame(width: 46, height: 46)
                    .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color(hex: course.color.hex).opacity(0.15)))
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
            .fixedSize()
            VStack(alignment: .leading, spacing: 4) {
                TextField("Name des Kurses, z. B. Statistik 2", text: Binding(get: { course.name }, set: { name in app.learning.courses.update(courseID) { $0.name = name } }))
                    .textFieldStyle(.plain)
                    .font(.system(size: 22, weight: .semibold))
                HStack(spacing: 12) {
                    Picker("", selection: Binding(get: { course.discipline }, set: { id in app.learning.courses.update(courseID) { $0.discipline = id } })) {
                        Text("Ohne Disziplin").tag(UUID?.none)
                        ForEach(app.learning.state.disciplines) { Text($0.displayName).tag(Optional($0.id)) }
                    }
                    .labelsHidden()
                    .frame(width: 200)
                    if let exam = course.examDate {
                        DatePicker("Prüfung", selection: Binding(get: { exam }, set: { date in app.learning.courses.update(courseID) { $0.examDate = date } }), displayedComponents: .date)
                            .frame(width: 210)
                        IconButton(systemName: "xmark.circle", help: "Prüfungstermin entfernen", size: 11, frameSize: 20) {
                            app.learning.courses.update(courseID) { $0.examDate = nil }
                        }
                    } else {
                        Button("Prüfungstermin …") {
                            app.learning.courses.update(courseID) { $0.examDate = Calendar.current.date(byAdding: .month, value: 2, to: Date()) }
                        }
                        .buttonStyle(.borderless)
                    }
                    Toggle("Abgeschlossen", isOn: Binding(get: { course.finished }, set: { done in app.learning.courses.update(courseID) { $0.finished = done } }))
                        .toggleStyle(.checkbox)
                        .help("Ein abgeschlossener Kurs trägt Früchte am Baum")
                }
                .font(.system(size: 12))
            }
            Spacer()
            Menu {
                Button("Kurs pausieren", systemImage: "pause.circle") { app.learning.startPause(scope: .course(courseID), reason: "Kurs pausiert") }
                Button("Mit Projekt verknüpfen …", systemImage: Project.sidebarSymbol) { model.tab = .links }
                Divider()
                Button("Kurs löschen", systemImage: "trash", role: .destructive) {
                    app.learning.courses.delete(courseID, label: "Kurs löschen", undo: nil)
                    model.courseID = nil
                }
            } label: {
                Image(systemName: "ellipsis.circle").font(.system(size: 15))
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .fixedSize()
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 12)
        .environment(\.locale, Locale(identifier: "de_DE"))
    }
}

// MARK: - Overview

private struct CourseOverview: View {
    @Environment(AppModel.self) private var app
    let courseID: UUID
    let model: LearningStudioModel

    var body: some View {
        let library = app.learning
        if let course = library.course(courseID) {
            let stats = library.stats(courseID)
            let paused = library.activePause(for: course)
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if let paused {
                        HStack {
                            Image(systemName: "beach.umbrella.fill").foregroundStyle(Theme.warning)
                            Text("Pausiert seit \(paused.start.formatted(date: .abbreviated, time: .omitted)) – die Karten ruhen.")
                            Spacer()
                            Button("Pause beenden") { library.endPause(paused.id) }
                        }
                        .font(.system(size: 12.5))
                        .padding(12)
                        .background(RoundedRectangle(cornerRadius: 10).fill(Theme.warning.opacity(0.1)))
                    }
                    HStack(alignment: .top, spacing: 14) {
                        VStack(spacing: 10) {
                            ProgressRing(value: stats.progress, color: Color(hex: course.color.hex), lineWidth: 9)
                                .frame(width: 120, height: 120)
                            Text("gelernt").font(.system(size: 11.5)).foregroundStyle(Theme.textTertiary)
                            Button {
                                model.tab = .review
                            } label: {
                                Label(stats.dueNow > 0 ? "Jetzt lernen (\(stats.dueNow))" : "Nichts fällig", systemImage: "play.fill")
                                    .frame(width: 150)
                            }
                            .buttonStyle(.borderedProminent)
                            .disabled(stats.dueNow == 0 || paused != nil)
                        }
                        .frame(width: 190)
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 120), spacing: 10)], spacing: 10) {
                            tile("Fällig", "\(stats.dueNow)", "clock", Theme.accent)
                            tile("Neu", "\(stats.new)", "sparkles", Color(hex: 0x5AA9FF))
                            tile("Am Lernen", "\(stats.learning)", "arrow.triangle.2.circlepath", Theme.warning)
                            tile("Jung", "\(stats.young)", "leaf", Color(hex: 0x8FCB78))
                            tile("Gefestigt", "\(stats.mature)", "tree", Theme.success)
                            tile("Behalten", stats.retention.map { "\(Int($0 * 100)) %" } ?? "–", "brain", Color(hex: 0xA996FF))
                            tile("Heute", "\(stats.reviewsToday)", "checkmark.circle", Color(hex: 0x3FC9C9))
                            tile("Abfragen", stats.quizScore.map { "\(Int($0 * 100)) %" } ?? "–", "questionmark.bubble", Color(hex: 0xF27AC0))
                        }
                    }
                    HStack(alignment: .top, spacing: 14) {
                        StudioCard(title: "Letzte 30 Tage", symbol: "chart.bar") {
                            Chart(Array(stats.history.enumerated()), id: \.offset) { index, count in
                                BarMark(x: .value("Tag", index - 29), y: .value("Antworten", count))
                                    .foregroundStyle(Color(hex: course.color.hex).gradient)
                            }
                            .chartXAxis { AxisMarks(values: [-29, -20, -10, 0]) { value in AxisValueLabel { Text(value.as(Int.self).map { $0 == 0 ? "heute" : "\($0)" } ?? "") } } }
                            .frame(height: 130)
                        }
                        StudioCard(title: "Nächste 14 Tage", symbol: "calendar") {
                            Chart(Array(stats.forecast.enumerated()), id: \.offset) { index, count in
                                BarMark(x: .value("Tag", index), y: .value("Fällig", count))
                                    .foregroundStyle(Theme.accent.gradient)
                            }
                            .chartXAxis { AxisMarks(values: [0, 7, 13]) { value in AxisValueLabel { Text(value.as(Int.self).map { $0 == 0 ? "heute" : "+\($0)" } ?? "") } } }
                            .frame(height: 130)
                        }
                    }
                    StudioCard(title: "Worum es geht", symbol: "text.alignleft") {
                        StoryTextEditor(placeholder: "Ziel des Kurses, Themen, Prüfungsform …", text: Binding(get: { course.summary }, set: { text in
                            app.learning.courses.update(courseID) { $0.summary = text }
                        }), minLines: 3)
                    }
                }
                .padding(24)
                .frame(maxWidth: 1100, alignment: .leading)
                .frame(maxWidth: .infinity)
            }
        }
    }

    private func tile(_ title: String, _ value: String, _ symbol: String, _ tint: Color) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Label(title, systemImage: symbol).font(.system(size: 11)).foregroundStyle(tint)
            Text(value).font(.system(size: 22, weight: .semibold).monospacedDigit()).foregroundStyle(Theme.textPrimary)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 11, style: .continuous).fill(tint.opacity(0.08)))
    }
}

// MARK: - Cards

private struct CourseCardsTab: View {
    @Environment(AppModel.self) private var app
    @Environment(\.undoManager) private var undoManager
    let courseID: UUID
    @State private var query = ""
    @State private var front = ""
    @State private var back = ""
    @State private var importing = false
    @State private var importText = ""
    @State private var editing: UUID?

    var body: some View {
        let library = app.learning
        if let course = library.course(courseID) {
            let cards = course.cards.filter { $0.matches(query) }
            VStack(spacing: 0) {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(alignment: .top, spacing: 10) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Vorderseite").font(.system(size: 11)).foregroundStyle(Theme.textTertiary)
                            StoryTextEditor(placeholder: "Frage", text: $front, minLines: 2)
                                .padding(6)
                                .background(RoundedRectangle(cornerRadius: 7).fill(Theme.ink.opacity(0.05)))
                        }
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Rückseite").font(.system(size: 11)).foregroundStyle(Theme.textTertiary)
                            StoryTextEditor(placeholder: "Antwort", text: $back, minLines: 2)
                                .padding(6)
                                .background(RoundedRectangle(cornerRadius: 7).fill(Theme.ink.opacity(0.05)))
                        }
                        VStack(spacing: 6) {
                            Button("Karte anlegen") { add() }
                                .buttonStyle(.borderedProminent)
                                .disabled(front.trimmingCharacters(in: .whitespaces).isEmpty)
                                .keyboardShortcut(.return, modifiers: .command)
                            Button("Aus Text …") { importing = true }
                                .buttonStyle(.borderless)
                                .help("Viele Karten auf einmal: eine Zeile je Karte, Frage ; Antwort")
                        }
                        .padding(.top, 16)
                    }
                    HStack {
                        SearchField(text: $query, prompt: "Karten durchsuchen")
                            .frame(width: 280)
                        Text("\(cards.count) von \(course.cards.count)").font(.system(size: 11.5)).foregroundStyle(Theme.textTertiary)
                        Spacer()
                    }
                }
                .padding(.horizontal, 24)
                .padding(.vertical, 12)
                Divider()
                ScrollView {
                    LazyVStack(spacing: 6) {
                        ForEach(cards) { card in
                            CardRow(courseID: courseID, card: card, isEditing: editing == card.id) {
                                editing = editing == card.id ? nil : card.id
                            }
                        }
                        if course.cards.isEmpty {
                            StudioEmptyState(symbol: "rectangle.stack", title: "Noch keine Karten",
                                             text: "Lege oben eine Karte an, füge viele auf einmal aus Text ein – oder lass das Modell unter „Material“ Karten aus einer PDF erstellen.")
                        }
                    }
                    .padding(.horizontal, 24)
                    .padding(.vertical, 12)
                }
            }
            .sheet(isPresented: $importing) {
                VStack(alignment: .leading, spacing: 10) {
                    Text("Karten aus Text").font(.system(size: 15, weight: .semibold))
                    Text("Eine Karte je Zeile: Frage ; Antwort (auch Tab, „–“ oder „F: … / A: …“).").font(.system(size: 12)).foregroundStyle(Theme.textSecondary)
                    TextEditor(text: $importText).font(.system(size: 12.5, design: .monospaced)).frame(height: 240)
                    let parsed = LearningCardText.parse(importText)
                    HStack {
                        Text("\(parsed.count) Karten erkannt").font(.system(size: 12)).foregroundStyle(Theme.textTertiary)
                        Spacer()
                        Button("Abbrechen") { importing = false }
                        Button("Anlegen") {
                            let cards = parsed.map { LearningCard(front: $0.front, back: $0.back) }
                            app.learning.courses.change(courseID, "Karten anlegen", undo: undoManager) { $0.cards += cards }
                            importText = ""
                            importing = false
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(parsed.isEmpty)
                    }
                }
                .padding(20)
                .frame(width: 560)
            }
        }
    }

    private func add() {
        let card = LearningCard(front: front.trimmingCharacters(in: .whitespacesAndNewlines), back: back.trimmingCharacters(in: .whitespacesAndNewlines))
        guard !card.front.isEmpty else { return }
        app.learning.courses.change(courseID, "Karte anlegen", undo: undoManager) { $0.cards.append(card) }
        front = ""
        back = ""
    }
}

private struct CardRow: View {
    @Environment(AppModel.self) private var app
    let courseID: UUID
    let card: LearningCard
    let isEditing: Bool
    let toggle: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .top, spacing: 10) {
                Circle().fill(color).frame(width: 8, height: 8).padding(.top, 5)
                    .help(card.state.label)
                if isEditing {
                    VStack(spacing: 6) {
                        StoryTextEditor(placeholder: "Frage", text: binding(\.front), minLines: 1)
                        Divider()
                        StoryTextEditor(placeholder: "Antwort", text: binding(\.back), minLines: 1)
                    }
                } else {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(card.front).font(.system(size: 13, weight: .medium)).foregroundStyle(Theme.textPrimary)
                        Text(card.back).font(.system(size: 12)).foregroundStyle(Theme.textSecondary).lineLimit(3)
                    }
                }
                Spacer(minLength: 8)
                VStack(alignment: .trailing, spacing: 2) {
                    Text(card.suspended ? "zurückgestellt" : card.state == .new ? "neu" : dueLabel)
                        .font(.system(size: 11).monospacedDigit()).foregroundStyle(Theme.textTertiary)
                    if card.lapses > 0 { Text("\(card.lapses)× vergessen").font(.system(size: 10.5)).foregroundStyle(Theme.warning) }
                }
                Menu {
                    Button(isEditing ? "Fertig" : "Bearbeiten", systemImage: "pencil", action: toggle)
                    Button(card.suspended ? "Wieder lernen" : "Zurückstellen", systemImage: card.suspended ? "play" : "pause") {
                        app.learning.courses.update(courseID) { $0.updateCard(card.id) { $0.suspended.toggle() } }
                    }
                    Button("Neu lernen (zurücksetzen)", systemImage: "arrow.counterclockwise") {
                        app.learning.courses.update(courseID) { course in
                            course.updateCard(card.id) { card in
                                card = LearningCard(front: card.front, back: card.back, tags: card.tags, material: card.material).with(id: card.id)
                            }
                        }
                    }
                    Divider()
                    Button("Löschen", systemImage: "trash", role: .destructive) {
                        app.learning.courses.update(courseID) { $0.cards.removeAll { $0.id == card.id } }
                    }
                } label: {
                    Image(systemName: "ellipsis").foregroundStyle(Theme.textTertiary).frame(width: 22, height: 22)
                }
                .menuStyle(.button)
                .buttonStyle(.plain)
                .menuIndicator(.hidden)
                .fixedSize()
            }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(Theme.ink.opacity(card.suspended ? 0.02 : 0.04)))
        .opacity(card.suspended ? 0.6 : 1)
        .onTapGesture(count: 2, perform: toggle)
    }

    private var color: Color {
        switch card.state {
        case .new: Color(hex: 0x5AA9FF)
        case .learning, .relearning: Theme.warning
        case .review: card.isMature ? Theme.success : Color(hex: 0x8FCB78)
        }
    }

    private var dueLabel: String {
        let seconds = card.due.timeIntervalSinceNow
        return seconds <= 0 ? "fällig" : "in " + LearningScheduler.label(seconds)
    }

    private func binding(_ keyPath: WritableKeyPath<LearningCard, String>) -> Binding<String> {
        Binding(get: { app.learning.course(courseID)?.card(card.id)?[keyPath: keyPath] ?? "" },
                set: { value in app.learning.courses.update(courseID) { $0.updateCard(card.id) { $0[keyPath: keyPath] = value } } })
    }
}

extension LearningCard {
    func with(id: UUID) -> LearningCard {
        var copy = self
        copy.id = id
        return copy
    }
}

// MARK: - Links

private struct CourseLinksTab: View {
    @Environment(AppModel.self) private var app
    let courseID: UUID

    var body: some View {
        if let course = app.learning.course(courseID) {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    HStack(spacing: 10) {
                        Menu("Dokument verknüpfen") {
                            ForEach(app.documents.filter { !$0.isPresentation }.prefix(40)) { document in
                                Button(document.displayTitle) { app.linkToCourse(.document(document.id), courseID: courseID) }
                            }
                        }
                        Menu("Präsentation verknüpfen") {
                            ForEach(app.documents.filter(\.isPresentation).prefix(40)) { document in
                                Button(document.displayTitle) { app.linkToCourse(.document(document.id), courseID: courseID) }
                            }
                        }
                        Menu("Note verknüpfen") {
                            ForEach(app.notes.notes.prefix(40)) { note in
                                Button(note.displayTitle) { app.linkToCourse(.note(note.id), courseID: courseID) }
                            }
                        }
                        Menu("Projekt verknüpfen") {
                            ForEach(app.projects.projects.prefix(40)) { project in
                                Button(project.displayTitle) { app.linkProjectToCourse(project.id, courseID: courseID) }
                            }
                        }
                        Menu("Chat verknüpfen") {
                            ForEach(app.chats.prefix(40)) { chat in
                                Button(chat.title) { app.linkToCourse(.chat(chat.id), courseID: courseID) }
                            }
                        }
                        Spacer()
                        Menu {
                            Button("Neues Dokument zum Kurs", systemImage: StudioApplication.writer.symbol) {
                                var document = WriterDocument()
                                document.title = course.displayName
                                document.hasCustomTitle = true
                                document.markdown = "# \(course.displayName)\n\n"
                                app.documents.insert(document, at: 0)
                                app.saveDocument(document.id)
                                app.linkToCourse(.document(document.id), courseID: courseID)
                                app.selectDocument(document.id)
                            }
                            Button("Neues Note zum Kurs", systemImage: "checklist") {
                                let note = app.newNote(title: "Lernplan \(course.displayName)")
                                app.linkToCourse(.note(note.id), courseID: courseID)
                                app.openNotesStudio(showing: note.id)
                            }
                            Button("Neues Projekt zum Kurs", systemImage: Project.sidebarSymbol) {
                                let project = app.newProject(title: course.displayName, open: false)
                                app.linkProjectToCourse(project.id, courseID: courseID)
                                app.openProject(project.id)
                            }
                        } label: {
                            Label("Neu", systemImage: "plus")
                        }
                        .fixedSize()
                    }
                    .menuStyle(.button)
                    if course.links.isEmpty && course.projects.isEmpty {
                        Text("Verknüpfe eigene Dokumente, Präsentationen, Notes, Projekte und Chats, die zu diesem Kurs gehören. Sie bleiben, wo sie sind; der Kurs zeigt nur auf sie.")
                            .font(.system(size: 12.5)).foregroundStyle(Theme.textTertiary)
                    }
                    ForEach(course.links, id: \.self) { ref in
                        linkRow(symbol: app.projectRefSymbol(ref), title: app.projectRefTitle(ref) ?? "Gelöscht", kind: app.projectRefKind(ref),
                                detail: app.projectRefDetail(ref)) {
                            app.openProjectRef(ref)
                        } remove: {
                            app.learning.courses.update(courseID) { $0.links.removeAll { $0 == ref } }
                        }
                    }
                    ForEach(course.projects, id: \.self) { id in
                        linkRow(symbol: app.projects.project(id)?.symbol ?? Project.sidebarSymbol, title: app.projects.project(id)?.displayTitle ?? "Gelöscht", kind: "Projekt",
                                detail: app.projects.project(id)?.overallProgress.label) {
                            app.openProject(id)
                        } remove: {
                            app.learning.courses.update(courseID) { $0.projects.removeAll { $0 == id } }
                        }
                    }
                }
                .padding(24)
                .frame(maxWidth: 1000, alignment: .leading)
                .frame(maxWidth: .infinity)
            }
        }
    }

    private func linkRow(symbol: String, title: String, kind: String, detail: String?, open: @escaping () -> Void, remove: @escaping () -> Void) -> some View {
        HStack(spacing: 10) {
            Image(systemName: symbol).foregroundStyle(Theme.accent).frame(width: 22)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 13, weight: .medium))
                Text([kind, detail].compactMap { $0 }.joined(separator: " · ")).font(.system(size: 11.5)).foregroundStyle(Theme.textTertiary)
            }
            Spacer()
            Button("Öffnen", action: open).buttonStyle(.borderless)
            IconButton(systemName: "link.badge.plus", help: "Verknüpfung lösen", size: 11, frameSize: 22, action: remove)
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(Theme.ink.opacity(0.04)))
    }
}
