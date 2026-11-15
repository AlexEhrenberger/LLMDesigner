import SwiftUI

// MARK: - The course's structure on its overview

/// The top of a course's overview: its title with credit points and exam form, where the person stands, and one row
/// per lesson with its cards ("3/14": three come up now, fourteen in all). A row opens to the lesson's abstract and
/// four buttons that lead to its content analysis, documents, resources and test.
struct CourseStructureSection: View {
    @Environment(AppModel.self) private var app
    let courseID: UUID
    @Bindable var model: LearningStudioModel

    var body: some View {
        if let course = app.learning.course(courseID) {
            let tint = Color(hex: course.color.hex)
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .firstTextBaseline, spacing: 12) {
                    Text(course.titleWithFacts)
                        .font(.system(size: 26, weight: .bold))
                        .foregroundStyle(Theme.textPrimary)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 8)
                    Button {
                        model.showsCourseSettings = true
                    } label: {
                        Label("Kurseinstellungen", systemImage: "gearshape")
                    }
                    .buttonStyle(.borderless)
                    .font(.system(size: 12))
                }
                if let standing = app.learning.standing(courseID) {
                    HStack(spacing: 8) {
                        GradeBadge(grade: standing.grade, size: 22)
                        Text("Dein Stand im Kurs: \(standing.grade.rawValue) (\(standing.grade.label)) · \(standing.tested) von \(standing.lessons) Lektionen getestet")
                            .font(.system(size: 12.5))
                            .foregroundStyle(Theme.textSecondary)
                    }
                }
                CourseBuildBanner(courseID: courseID)
                if course.lessons.isEmpty {
                    emptyStructure
                } else {
                    VStack(spacing: 12) {
                        ForEach(course.lessons) { lesson in
                            LessonRow(courseID: courseID, lesson: lesson, tint: tint, model: model)
                        }
                    }
                    HStack(spacing: 14) {
                        Button("Lektion hinzufügen", systemImage: "plus") {
                            if let lesson = app.addLesson(to: courseID) { model.expandedLesson = lesson.id; model.showsCourseSettings = true }
                        }
                        Button("Aus PDF erstellen …", systemImage: "doc.richtext") { model.showsBuild = true }
                    }
                    .buttonStyle(.borderless)
                    .font(.system(size: 12))
                }
            }
        }
    }

    private var emptyStructure: some View {
        StudioCard(title: "Struktur des Kurses", symbol: "list.number") {
            Text("Ein Kurs besteht aus Lektionen. Am einfachsten entstehen sie aus dem Skript: Die App liest die Gliederung der PDF, das lokale Modell schreibt je Lektion eine ausführliche Zusammenfassung, Karteikarten, eine Inhaltsanalyse und eine Präsentation mit Moderatorenkarten. Du kannst Lektionen auch von Hand anlegen.")
                .font(.system(size: 12.5))
                .foregroundStyle(Theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 10) {
                Button("Aus PDF erstellen …", systemImage: "doc.richtext") { model.showsBuild = true }
                    .buttonStyle(.borderedProminent)
                Button("Lektion von Hand anlegen", systemImage: "plus") {
                    if let lesson = app.addLesson(to: courseID) { model.expandedLesson = lesson.id; model.showsCourseSettings = true }
                }
            }
        }
    }
}

/// A lesson in the overview: closed, its title and cards; open, its abstract and the four ways into it.
private struct LessonRow: View {
    @Environment(AppModel.self) private var app
    let courseID: UUID
    let lesson: LearningLesson
    let tint: Color
    @Bindable var model: LearningStudioModel
    @State private var hovering = false

    var body: some View {
        let open = model.expandedLesson == lesson.id
        VStack(alignment: .leading, spacing: 0) {
            titleLine(open: open)
            if open {
                Rectangle().fill(Theme.textPrimary.opacity(0.85)).frame(height: 1.5)
                    .padding(.top, 6)
                    .padding(.bottom, 18)
                content
                    .transition(.opacity)
            }
        }
        .padding(.horizontal, 24)
        .padding(.vertical, open ? 20 : 15)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Theme.ink.opacity(hovering && !open ? 0.085 : 0.06)))
        .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .onHover { hovering = $0 }
        .onTapGesture {
            withAnimation(.snappy(duration: 0.22)) { model.expandedLesson = open ? nil : lesson.id }
        }
    }

    private func titleLine(open: Bool) -> some View {
        let counts = app.learning.lessonCounts(courseID, lesson: lesson.id)
        let test = app.learning.course(courseID)?.latestGrade(of: lesson.id)
        return HStack(alignment: .center, spacing: 10) {
            Text(lesson.displayTitle)
                .font(.system(size: open ? 21 : 19, weight: .bold))
                .foregroundStyle(Theme.textPrimary)
                .lineLimit(2)
            if let grade = test?.grade {
                GradeBadge(grade: grade, size: 20)
                    .help("Letzter Test: \(grade.rawValue) (\(grade.label))" + (test?.score.map { ", \(Int(($0 * 100).rounded())) %" } ?? ""))
            }
            LessonBuildStatus(courseID: courseID, lessonID: lesson.id, compact: true)
            Spacer(minLength: 8)
            Button {
                model.learn(lesson: lesson.id)
            } label: {
                HStack(spacing: 6) {
                    Text("\(counts.due)/\(counts.total)")
                        .font(.system(size: 15, weight: .bold).monospacedDigit())
                    Image(systemName: "note.text")
                        .font(.system(size: 24, weight: .regular))
                }
                .foregroundStyle(counts.total == 0 ? tint.opacity(0.45) : tint)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(counts.total == 0 ? "Noch keine Karteikarten in dieser Lektion" : "\(counts.due) von \(counts.total) Karten jetzt abzufragen – lernen")
        }
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Abstract")
                .font(.system(size: 17, weight: .bold).italic())
                .foregroundStyle(Theme.textPrimary)
            Group {
                if lesson.abstract.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    Text("Noch keine Zusammenfassung. Sie entsteht bei der Erstellung aus der PDF, oder du schreibst sie in den Kurseinstellungen.")
                        .foregroundStyle(Theme.textTertiary)
                } else {
                    Text(lesson.abstract).foregroundStyle(Theme.textPrimary)
                }
            }
            .font(.system(size: 14))
            .lineSpacing(3)
            .textSelection(.enabled)
            .fixedSize(horizontal: false, vertical: true)
            LessonBuildStatus(courseID: courseID, lessonID: lesson.id, compact: false)
            VStack(alignment: .leading, spacing: 10) {
                ForEach(LessonTab.allCases) { tab in
                    Button {
                        withAnimation(.snappy(duration: 0.2)) { model.openLesson(lesson.id, tab) }
                    } label: {
                        Text(tab.buttonTitle)
                            .font(.system(size: 14.5, weight: .semibold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 14)
                            .frame(maxWidth: 420, minHeight: 34, alignment: .leading)
                            .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(tint.mix(with: .black, by: 0.38)))
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.top, 6)
            Text(facts)
                .font(.system(size: 11.5))
                .foregroundStyle(Theme.textTertiary)
                .padding(.top, 4)
        }
    }

    private var facts: String {
        var parts: [String] = []
        if let pages = lesson.pageLabel { parts.append(pages) }
        if !lesson.sections.isEmpty { parts.append("\(lesson.sections.count) Abschnitte") }
        let cards = app.learning.course(courseID)?.cards(of: lesson.id).count ?? 0
        parts.append("\(cards) Karten")
        if lesson.summaryDocument != nil { parts.append("Zusammenfassung") }
        if lesson.presentation != nil { parts.append("Präsentation") }
        return parts.joined(separator: " · ")
    }
}

/// A grade A–F in a coloured circle.
struct GradeBadge: View {
    let grade: LessonGrade
    var size: CGFloat = 24

    var body: some View {
        Text(grade.rawValue)
            .font(.system(size: size * 0.55, weight: .heavy, design: .rounded))
            .foregroundStyle(.white)
            .frame(width: size, height: size)
            .background(Circle().fill(Self.color(grade)))
    }

    static func color(_ grade: LessonGrade) -> Color {
        switch grade {
        case .a: Color(hex: 0x1E9E61)
        case .b: Color(hex: 0x3BA55C)
        case .c: Color(hex: 0x7CA83A)
        case .d: Color(hex: 0xC9A227)
        case .e: Color(hex: 0xE08A2E)
        case .f: Color(hex: 0xD64545)
        }
    }
}

// MARK: - Creation status

/// Above the lessons: the course is being made (and can be stopped), or its creation stopped and can go on.
struct CourseBuildBanner: View {
    @Environment(AppModel.self) private var app
    let courseID: UUID

    var body: some View {
        let build = app.courseBuild
        if let course = app.learning.course(courseID) {
            let unfinished = course.lessons.filter { lesson in
                lesson.material != nil && !(course.buildOptions ?? CourseBuildOptions()).steps.allSatisfy(lesson.built.contains)
            }
            if build.isBuilding(course: courseID) {
                let current = build.current.flatMap { course.lesson($0.lesson) }
                let position = current.flatMap { course.lessonNumber($0.id) }
                HStack(spacing: 10) {
                    ProgressView().controlSize(.small)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Der Kurs wird erstellt" + (position.map { " – Lektion \($0) von \(course.lessons.count)" } ?? ""))
                            .font(.system(size: 13, weight: .semibold))
                        Text("Das lokale Modell arbeitet im Hintergrund; du kannst die fertigen Lektionen schon nutzen. Jeder Schritt bleibt erhalten, auch wenn du anhältst.")
                            .font(.system(size: 11.5))
                            .foregroundStyle(Theme.textSecondary)
                    }
                    Spacer()
                    Button("Anhalten") { app.cancelCourseBuild(course: courseID) }
                }
                .padding(12)
                .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Theme.accent.opacity(0.1)))
            } else if !unfinished.isEmpty {
                HStack(spacing: 10) {
                    Image(systemName: build.stopped == nil ? "pause.circle" : "exclamationmark.triangle").foregroundStyle(Theme.warning)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("\(unfinished.count) Lektion\(unfinished.count == 1 ? " ist" : "en sind") noch nicht fertig erstellt")
                            .font(.system(size: 13, weight: .semibold))
                        if let stopped = build.stopped {
                            Text(stopped).font(.system(size: 11.5)).foregroundStyle(Theme.textSecondary)
                        }
                    }
                    Spacer()
                    Button("Fortsetzen") {
                        app.buildLessons(unfinished.map(\.id), in: courseID, options: course.buildOptions ?? CourseBuildOptions())
                    }
                    .buttonStyle(.borderedProminent)
                }
                .padding(12)
                .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Theme.warning.opacity(0.1)))
            }
        }
    }
}

/// What the creation does with one lesson: waiting, the step and its progress, or why it stopped.
struct LessonBuildStatus: View {
    @Environment(AppModel.self) private var app
    let courseID: UUID
    let lessonID: UUID
    let compact: Bool

    var body: some View {
        let build = app.courseBuild
        if build.current?.lesson == lessonID {
            if compact {
                HStack(spacing: 5) {
                    ProgressView().controlSize(.mini)
                    Text(build.step?.label ?? "Erstellt").font(.system(size: 11, weight: .medium)).foregroundStyle(Theme.textSecondary)
                }
            } else {
                VStack(alignment: .leading, spacing: 4) {
                    Text(build.detail.isEmpty ? (build.step?.label ?? "") : build.detail)
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.textSecondary)
                    ProgressView(value: build.fraction).frame(maxWidth: 420)
                }
            }
        } else if build.isWaiting(lessonID) {
            Label("wartet", systemImage: "clock").font(.system(size: 11)).foregroundStyle(Theme.textTertiary)
        } else if let error = build.errors[lessonID] {
            if compact {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Theme.warning).help(error)
            } else {
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Theme.warning)
                    Text(error).font(.system(size: 12)).foregroundStyle(Theme.textSecondary).fixedSize(horizontal: false, vertical: true)
                    Button("Erneut versuchen") {
                        let options = app.learning.course(courseID)?.buildOptions ?? CourseBuildOptions()
                        app.buildLessons([lessonID], in: courseID, options: options)
                    }
                    .buttonStyle(.borderless)
                }
            }
        }
    }
}

// MARK: - A lesson's page

/// A lesson with its content analysis, documents, resources and test.
struct LessonPage: View {
    @Environment(AppModel.self) private var app
    let courseID: UUID
    let lessonID: UUID
    @Bindable var model: LearningStudioModel

    var body: some View {
        if let course = app.learning.course(courseID), let lesson = course.lesson(lessonID) {
            VStack(spacing: 0) {
                HStack(alignment: .center, spacing: 12) {
                    Button {
                        withAnimation(.snappy(duration: 0.2)) { model.lessonID = nil }
                    } label: {
                        Image(systemName: "chevron.left").font(.system(size: 13, weight: .semibold)).frame(width: 26, height: 26)
                    }
                    .buttonStyle(.borderless)
                    .help("Zurück zur Übersicht")
                    VStack(alignment: .leading, spacing: 2) {
                        Text(course.lessonNumber(lessonID).map { "Lektion \($0)" } ?? "Lektion")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(Color(hex: course.color.hex))
                        Text(lesson.displayTitle).font(.system(size: 20, weight: .bold)).lineLimit(1)
                    }
                    Spacer()
                    let counts = app.learning.lessonCounts(courseID, lesson: lessonID)
                    Button {
                        model.learn(lesson: lessonID)
                    } label: {
                        Label("Karten lernen (\(counts.due)/\(counts.total))", systemImage: "note.text")
                    }
                    .disabled(counts.due == 0)
                }
                .padding(.horizontal, 24)
                .padding(.top, 14)
                HStack {
                    StudioTabPicker(tabs: LessonTab.allCases, selection: $model.lessonTab, title: \.title, symbol: \.symbol)
                    Spacer()
                }
                .padding(.horizontal, 24)
                .padding(.vertical, 10)
                Divider()
                Group {
                    switch model.lessonTab {
                    case .analysis: LessonAnalysisTab(courseID: courseID, lessonID: lessonID)
                    case .documents: LessonDocumentsTab(courseID: courseID, lessonID: lessonID)
                    case .resources: LessonResourcesTab(courseID: courseID, lessonID: lessonID)
                    case .test: LessonTestTab(courseID: courseID, lessonID: lessonID, model: model)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }
}

/// Starts the steps of the creation a lesson still lacks (from its PDF pages).
@MainActor
private func buildMissing(_ app: AppModel, _ courseID: UUID, _ lessonID: UUID, _ steps: Set<LessonBuildStep>) {
    var options = app.learning.course(courseID)?.buildOptions ?? CourseBuildOptions()
    options.summary = options.summary || steps.contains(.summary)
    options.analysis = options.analysis || steps.contains(.analysis)
    options.presentation = options.presentation || steps.contains(.presentation)
    app.buildLessons([lessonID], in: courseID, options: options)
}

/// The content analysis of the lesson's summary: its topics and how they connect (Writer Studio's analysis).
private struct LessonAnalysisTab: View {
    @Environment(AppModel.self) private var app
    @Environment(\.colorScheme) private var colorScheme
    let courseID: UUID
    let lessonID: UUID
    @State private var scrollTarget: ContentAnalysisModule?

    var body: some View {
        if let lesson = app.learning.course(courseID)?.lesson(lessonID) {
            if let document = lesson.summaryDocument.flatMap(app.document) {
                ContentAnalysisView(document: document, colors: AnalysisColors.make(lightPaper: colorScheme == .light), scrollTarget: $scrollTarget) { _ in
                    app.openProjectRef(.document(document.id))
                }
                .onAppear { app.loadAnalysisIfNeeded(document.id) }
            } else {
                ScrollView {
                    StudioEmptyState(
                        symbol: "chart.bar.doc.horizontal", title: "Noch keine Inhaltsanalyse",
                        text: lesson.material == nil
                            ? "Die Inhaltsanalyse entsteht aus der ausführlichen Zusammenfassung der Lektion. Erstelle den Kurs aus einer PDF oder verknüpfe unter „Dokumente“ eine Zusammenfassung."
                            : "Die Inhaltsanalyse zeigt die Themen der Lektion und wie sie zusammenhängen. Sie entsteht aus der Zusammenfassung, die das Modell aus den Seiten der PDF schreibt.",
                        actionTitle: lesson.material == nil ? nil : "Zusammenfassung und Analyse erstellen"
                    ) {
                        buildMissing(app, courseID, lessonID, [.summary, .analysis])
                    }
                    LessonBuildStatus(courseID: courseID, lessonID: lessonID, compact: false)
                        .padding(.horizontal, 24)
                }
            }
        }
    }
}

/// The summary, the presentation (which the model can present) and what else is linked to the lesson.
private struct LessonDocumentsTab: View {
    @Environment(AppModel.self) private var app
    let courseID: UUID
    let lessonID: UUID

    var body: some View {
        if let course = app.learning.course(courseID), let lesson = course.lesson(lessonID) {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    StudioSectionHeader(title: "Aus der Erstellung", symbol: "sparkles")
                    if let summary = lesson.summaryDocument.flatMap(app.document) {
                        row(symbol: StudioApplication.writer.symbol, title: summary.displayTitle,
                            detail: "Ausführliche Zusammenfassung · \(DocumentOutlineBuilder.wordCount(summary.markdown)) Wörter") {
                            Button("Öffnen") { app.openProjectRef(.document(summary.id)) }
                        }
                    } else {
                        missing("Ausführliche Zusammenfassung", lesson: lesson, step: .summary)
                    }
                    if let deck = lesson.presentation.flatMap(app.document), let slides = deck.deck?.slides {
                        let cards = slides.filter { !$0.notes.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }.count
                        row(symbol: "rectangle.on.rectangle.angled", title: deck.displayTitle, detail: "\(slides.count) Folien · \(cards) Moderatorenkarten") {
                            Button("Öffnen") { app.openProjectRef(.document(deck.id)) }
                            Button("KI präsentiert", systemImage: "play.fill") {
                                app.selectDocument(deck.id)
                                app.presentWithAI(deck.id)
                            }
                            .buttonStyle(.borderedProminent)
                            .help("Die Präsentation läuft im Vollbild; das Modell liest die Moderatorenkarten mit Qwen TTS vor")
                        }
                    } else {
                        missing("Präsentation mit Moderatorenkarten", lesson: lesson, step: .presentation)
                    }
                    HStack {
                        StudioSectionHeader(title: "Verknüpft", symbol: "link", count: lesson.links.count)
                        Spacer()
                        linkMenu(lesson)
                    }
                    .padding(.top, 8)
                    if lesson.links.isEmpty {
                        Text("Verknüpfe eigene Dokumente, Präsentationen, Notes und Chats mit dieser Lektion. Sie bleiben, wo sie sind; die Lektion zeigt nur auf sie.")
                            .font(.system(size: 12.5)).foregroundStyle(Theme.textTertiary)
                    }
                    ForEach(lesson.links, id: \.self) { ref in
                        row(symbol: app.projectRefSymbol(ref), title: app.projectRefTitle(ref) ?? "Gelöscht",
                            detail: [app.projectRefKind(ref), app.projectRefDetail(ref)].compactMap { $0 }.joined(separator: " · ")) {
                            Button("Öffnen") { app.openProjectRef(ref) }
                            IconButton(systemName: "link.badge.plus", help: "Verknüpfung lösen", size: 11, frameSize: 22) {
                                app.learning.courses.update(courseID) { $0.updateLesson(lessonID) { $0.links.removeAll { $0 == ref } } }
                            }
                        }
                    }
                }
                .padding(24)
                .frame(maxWidth: 1000, alignment: .leading)
                .frame(maxWidth: .infinity)
            }
        }
    }

    private func missing(_ title: String, lesson: LearningLesson, step: LessonBuildStep) -> some View {
        row(symbol: "circle.dashed", title: title, detail: lesson.material == nil ? "Entsteht bei der Erstellung aus einer PDF" : "Noch nicht erstellt") {
            if lesson.material != nil {
                Button("Erstellen") { buildMissing(app, courseID, lessonID, [step]) }
                    .disabled(app.courseBuild.current?.lesson == lessonID || app.courseBuild.isWaiting(lessonID))
            }
        }
    }

    private func linkMenu(_ lesson: LearningLesson) -> some View {
        Menu {
            Menu("Dokument") {
                ForEach(app.documents.filter { !$0.isPresentation }.prefix(40)) { document in
                    Button(document.displayTitle) { link(.document(document.id)) }
                }
            }
            Menu("Präsentation") {
                ForEach(app.documents.filter(\.isPresentation).prefix(40)) { document in
                    Button(document.displayTitle) { link(.document(document.id)) }
                }
            }
            Menu("Note") {
                ForEach(app.notes.notes.prefix(40)) { note in Button(note.displayTitle) { link(.note(note.id)) } }
            }
            Menu("Chat") {
                ForEach(app.chats.prefix(40)) { chat in Button(chat.title) { link(.chat(chat.id)) } }
            }
            Divider()
            Button("Neues Dokument zur Lektion", systemImage: StudioApplication.writer.symbol) {
                var document = WriterDocument()
                document.title = lesson.displayTitle
                document.hasCustomTitle = true
                document.markdown = "# \(lesson.displayTitle)\n\n"
                document.folderID = app.learning.course(courseID)?.documentFolder
                app.documents.insert(document, at: 0)
                app.saveDocument(document.id)
                link(.document(document.id))
                app.selectDocument(document.id)
            }
        } label: {
            Label("Verknüpfen", systemImage: "plus")
        }
        .menuStyle(.button)
        .fixedSize()
    }

    private func link(_ ref: ProjectRef) {
        app.learning.courses.update(courseID) { $0.updateLesson(lessonID) { if !$0.links.contains(ref) { $0.links.append(ref) } } }
    }

    private func row<Trailing: View>(symbol: String, title: String, detail: String, @ViewBuilder trailing: () -> Trailing) -> some View {
        HStack(spacing: 10) {
            Image(systemName: symbol).foregroundStyle(Theme.accent).frame(width: 22)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 13, weight: .medium)).lineLimit(1)
                Text(detail).font(.system(size: 11.5)).foregroundStyle(Theme.textTertiary).lineLimit(1)
            }
            Spacer()
            trailing()
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(Theme.ink.opacity(0.04)))
    }
}

/// The lesson's pages in the script, and links, videos, texts and sources that belong to it.
private struct LessonResourcesTab: View {
    @Environment(AppModel.self) private var app
    let courseID: UUID
    let lessonID: UUID
    @State private var link = ""
    @State private var addingText = false
    @State private var textTitle = ""
    @State private var textBody = ""

    var body: some View {
        if let course = app.learning.course(courseID), let lesson = course.lesson(lessonID) {
            let materials = course.materials.filter { $0.lesson == lessonID }
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    if let materialID = lesson.material, let script = course.material(materialID) {
                        StudioSectionHeader(title: "Skript", symbol: "doc.richtext")
                        resourceRow(script, detail: [lesson.pageLabel, lesson.sections.isEmpty ? nil : "\(lesson.sections.count) Abschnitte"].compactMap { $0 }.joined(separator: " · "), removable: false)
                        if !lesson.sections.isEmpty {
                            VStack(alignment: .leading, spacing: 3) {
                                ForEach(Array(lesson.sections.enumerated()), id: \.element.id) { index, section in
                                    HStack {
                                        Text(app.sectionLabel(section, index: index, lessonNumber: course.lessonNumber(lessonID)))
                                        Spacer()
                                        if let first = section.firstPage { Text("S. \(first)").monospacedDigit().foregroundStyle(Theme.textTertiary) }
                                    }
                                    .font(.system(size: 12))
                                }
                            }
                            .padding(.horizontal, 42)
                        }
                    }
                    StudioSectionHeader(title: "URLs und weitere Ressourcen", symbol: "link", count: materials.count)
                        .padding(.top, 6)
                    HStack(spacing: 8) {
                        Image(systemName: "link").foregroundStyle(Theme.textTertiary)
                        StudioField(placeholder: "Link oder YouTube-Adresse einfügen und Return", text: $link)
                            .onSubmit {
                                app.addCourseLink(link, to: courseID, lesson: lessonID)
                                link = ""
                            }
                    }
                    HStack(spacing: 10) {
                        Button("PDF …", systemImage: "doc.richtext") { choosePDF() }
                        Button("Text …", systemImage: "text.alignleft") { addingText = true }
                        Menu {
                            ForEach(app.citations.sources.prefix(60)) { source in
                                Button(source.title) { app.addCourseSource(source.id, to: courseID, lesson: lessonID) }
                            }
                            if app.citations.sources.isEmpty { Text("Citation Studio hat noch keine Quellen") }
                        } label: {
                            Label("Quelle", systemImage: "quote.bubble")
                        }
                        .fixedSize()
                        let loose = course.materials.filter { $0.lesson == nil && $0.id != lesson.material }
                        if !loose.isEmpty {
                            Menu {
                                ForEach(loose) { material in
                                    Button(material.displayTitle) {
                                        app.learning.courses.update(courseID) { course in
                                            if let index = course.materials.firstIndex(where: { $0.id == material.id }) { course.materials[index].lesson = lessonID }
                                        }
                                    }
                                }
                            } label: {
                                Label("Material des Kurses zuordnen", systemImage: "tray.and.arrow.down")
                            }
                            .fixedSize()
                        }
                        Spacer()
                    }
                    .font(.system(size: 12))
                    if materials.isEmpty {
                        Text("Hinterlege Links, YouTube-Videos, Texte, PDFs oder Quellen aus Citation Studio, die zu dieser Lektion gehören. Der KI-Test nutzt sie, wenn es keine Lernnotizen gibt.")
                            .font(.system(size: 12.5)).foregroundStyle(Theme.textTertiary)
                    }
                    ForEach(materials) { material in
                        resourceRow(material, detail: [material.kind.label, material.url].compactMap { $0 }.joined(separator: " · "), removable: true)
                    }
                }
                .padding(24)
                .frame(maxWidth: 1000, alignment: .leading)
                .frame(maxWidth: .infinity)
            }
            .sheet(isPresented: $addingText) {
                VStack(alignment: .leading, spacing: 10) {
                    Text("Text zur Lektion").font(.system(size: 15, weight: .semibold))
                    StudioField(placeholder: "Titel", text: $textTitle)
                    TextEditor(text: $textBody).font(.system(size: 12.5)).frame(height: 260)
                    HStack {
                        Spacer()
                        Button("Abbrechen") { addingText = false }
                        Button("Hinzufügen") {
                            var material = LearningMaterial(kind: .text, title: textTitle, text: textBody)
                            material.lesson = lessonID
                            app.learning.courses.update(courseID) { $0.materials.append(material) }
                            textTitle = ""
                            textBody = ""
                            addingText = false
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(textBody.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                }
                .padding(20)
                .frame(width: 560)
            }
        }
    }

    private func resourceRow(_ material: LearningMaterial, detail: String, removable: Bool) -> some View {
        HStack(spacing: 10) {
            Image(systemName: material.kind.symbol)
                .foregroundStyle(material.kind == .youtube ? Color(hex: 0xE53935) : Theme.accent)
                .frame(width: 22)
            VStack(alignment: .leading, spacing: 2) {
                Text(material.displayTitle).font(.system(size: 13, weight: .medium)).lineLimit(1)
                Text(detail).font(.system(size: 11.5)).foregroundStyle(Theme.textTertiary).lineLimit(1)
            }
            Spacer()
            Button("Öffnen") { app.openCourseMaterial(material, in: courseID) }.buttonStyle(.borderless)
            if removable {
                IconButton(systemName: "minus.circle", help: "Von der Lektion lösen (bleibt im Kurs)", size: 11, frameSize: 22) {
                    app.learning.courses.update(courseID) { course in
                        if let index = course.materials.firstIndex(where: { $0.id == material.id }) { course.materials[index].lesson = nil }
                    }
                }
            }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(Theme.ink.opacity(0.04)))
    }

    private func choosePDF() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.pdf]
        panel.allowsMultipleSelection = true
        panel.message = "PDF zur Lektion"
        guard panel.runModal() == .OK else { return }
        for url in panel.urls { _ = try? app.addCourseMaterial(file: url, to: courseID, kind: .pdf, lesson: lessonID) }
    }
}
