import SwiftUI
import UniformTypeIdentifiers

/// The course's facts (credit points, exam form, exam day) and its lessons, to add, rename, order and describe by hand.
struct CourseSettingsSheet: View {
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    let courseID: UUID
    @Bindable var model: LearningStudioModel

    static let examForms = ["Klausur", "Hausarbeit", "Mündliche Prüfung", "Fallstudie", "Portfolio", "Projektbericht", "Präsentation", "Advanced Workbook", "Online-Test"]

    var body: some View {
        if let course = app.learning.course(courseID) {
            VStack(alignment: .leading, spacing: 0) {
                HStack {
                    Text("Kurseinstellungen").font(.system(size: 16, weight: .semibold))
                    Spacer()
                    Button("Fertig") { dismiss() }.keyboardShortcut(.defaultAction)
                }
                .padding(20)
                Divider()
                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 10) {
                            GridRow {
                                Text("Name")
                                StudioField(placeholder: "z. B. Statistik – Wahrscheinlichkeit und deskriptive Statistik", text: binding(\.name))
                            }
                            GridRow {
                                Text("Credit Points")
                                HStack {
                                    TextField("", value: Binding(get: { course.creditPoints }, set: { value in update { $0.creditPoints = value.map { max(0, min(60, $0)) } } }), format: .number)
                                        .textFieldStyle(.roundedBorder)
                                        .frame(width: 60)
                                    Text("CP (ECTS)").foregroundStyle(Theme.textTertiary)
                                }
                            }
                            GridRow {
                                Text("Prüfungsform")
                                HStack {
                                    StudioField(placeholder: "z. B. Klausur", text: binding(\.examForm))
                                        .frame(width: 220)
                                    Menu("Auswahl") {
                                        ForEach(Self.examForms, id: \.self) { form in Button(form) { update { $0.examForm = form } } }
                                    }
                                    .fixedSize()
                                }
                            }
                            GridRow {
                                Text("Prüfungstermin")
                                HStack {
                                    if let exam = course.examDate {
                                        DatePicker("", selection: Binding(get: { exam }, set: { date in update { $0.examDate = date } }), displayedComponents: .date)
                                            .labelsHidden()
                                            .fixedSize()
                                        Button("Entfernen") { update { $0.examDate = nil } }.buttonStyle(.borderless)
                                    } else {
                                        Button("Festlegen …") { update { $0.examDate = Calendar.current.date(byAdding: .month, value: 2, to: Date()) } }
                                    }
                                }
                            }
                        }
                        .font(.system(size: 12.5))
                        Text("Im Kurs steht dann: „\(course.titleWithFacts)“").font(.system(size: 11.5)).foregroundStyle(Theme.textTertiary)

                        HStack {
                            StudioSectionHeader(title: "Lektionen", symbol: "list.number", count: course.lessons.count)
                            Spacer()
                            Button("Aus PDF erstellen …", systemImage: "doc.richtext") {
                                dismiss()
                                model.showsBuild = true
                            }
                            Button("Lektion hinzufügen", systemImage: "plus") {
                                if let lesson = app.addLesson(to: courseID) { model.expandedLesson = lesson.id }
                            }
                        }
                        .font(.system(size: 12))
                        if course.lessons.isEmpty {
                            Text("Noch keine Lektionen. Lege sie von Hand an, oder lass sie aus der Gliederung eines Skripts (PDF) entstehen.")
                                .font(.system(size: 12.5)).foregroundStyle(Theme.textTertiary)
                        }
                        ForEach(Array(course.lessons.enumerated()), id: \.element.id) { index, lesson in
                            lessonEditor(lesson, number: index + 1, count: course.lessons.count)
                        }
                    }
                    .padding(20)
                }
            }
            .frame(width: 680, height: 640)
            .environment(\.locale, Locale(identifier: "de_DE"))
        }
    }

    private func lessonEditor(_ lesson: LearningLesson, number: Int, count: Int) -> some View {
        let open = model.expandedLesson == lesson.id
        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text("\(number)").font(.system(size: 12, weight: .bold).monospacedDigit()).foregroundStyle(Theme.textTertiary).frame(width: 20)
                StudioField(placeholder: "Titel der Lektion", text: lessonBinding(lesson.id, \.title))
                if let pages = lesson.pageLabel { Text(pages).font(.system(size: 11).monospacedDigit()).foregroundStyle(Theme.textTertiary).fixedSize() }
                IconButton(systemName: "chevron.up", help: "Nach oben", size: 10, frameSize: 20) { app.moveLesson(lesson.id, in: courseID, by: -1) }
                    .disabled(number == 1)
                IconButton(systemName: "chevron.down", help: "Nach unten", size: 10, frameSize: 20) { app.moveLesson(lesson.id, in: courseID, by: 1) }
                    .disabled(number == count)
                IconButton(systemName: open ? "chevron.up.chevron.down" : "text.alignleft", help: "Abstract bearbeiten", size: 11, frameSize: 20) {
                    model.expandedLesson = open ? nil : lesson.id
                }
                IconButton(systemName: "trash", help: "Lektion entfernen (Karten und Material bleiben im Kurs)", size: 11, frameSize: 20) {
                    app.deleteLesson(lesson.id, from: courseID)
                }
            }
            if open {
                Text("Abstract").font(.system(size: 11, weight: .semibold)).foregroundStyle(Theme.textTertiary).padding(.leading, 28)
                StoryTextEditor(placeholder: "Worum es in der Lektion geht", text: lessonBinding(lesson.id, \.abstract), minLines: 3)
                    .padding(6)
                    .background(RoundedRectangle(cornerRadius: 7).fill(Theme.ink.opacity(0.05)))
                    .padding(.leading, 28)
                if !lesson.goals.isEmpty {
                    Text("Lernziele aus dem Skript: " + lesson.goals.joined(separator: " "))
                        .font(.system(size: 11)).foregroundStyle(Theme.textTertiary).padding(.leading, 28)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(Theme.ink.opacity(0.04)))
    }

    private func update(_ change: (inout LearningCourse) -> Void) {
        app.learning.courses.update(courseID, change)
    }

    private func binding(_ keyPath: WritableKeyPath<LearningCourse, String>) -> Binding<String> {
        Binding(get: { app.learning.course(courseID)?[keyPath: keyPath] ?? "" }, set: { value in update { $0[keyPath: keyPath] = value } })
    }

    private func lessonBinding(_ lessonID: UUID, _ keyPath: WritableKeyPath<LearningLesson, String>) -> Binding<String> {
        Binding(get: { app.learning.course(courseID)?.lesson(lessonID)?[keyPath: keyPath] ?? "" },
                set: { value in update { $0.updateLesson(lessonID) { $0[keyPath: keyPath] = value } } })
    }
}

/// "Aus PDF erstellen": the PDF's structure for checking, what the model should make, and the start.
struct CourseBuildSheet: View {
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    let courseID: UUID
    @State private var materialID: UUID?
    @State private var detected: [DetectedLesson] = []
    @State private var source: CourseOutline.Source?
    @State private var pdfTitle: String?
    @State private var pageCount = 0
    @State private var detecting = false
    @State private var error: String?
    @State private var options = CourseBuildOptions()
    @State private var expanded: Set<UUID> = []

    var body: some View {
        if let course = app.learning.course(courseID) {
            let pdfs = course.materials.filter { $0.kind == .pdf }
            VStack(alignment: .leading, spacing: 0) {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Kurs aus PDF erstellen").font(.system(size: 16, weight: .semibold))
                        Text("Die Gliederung kommt aus der PDF selbst. Das lokale Modell liest danach jede Lektion in Stücken von wenigen Seiten.")
                            .font(.system(size: 11.5)).foregroundStyle(Theme.textTertiary)
                    }
                    Spacer()
                }
                .padding(20)
                Divider()
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        HStack(spacing: 10) {
                            Text("Skript").font(.system(size: 12.5, weight: .medium))
                            if !pdfs.isEmpty {
                                Picker("", selection: Binding(get: { materialID }, set: { id in materialID = id; detect() })) {
                                    Text("Bitte wählen").tag(UUID?.none)
                                    ForEach(pdfs) { Text($0.displayTitle).tag(Optional($0.id)) }
                                }
                                .labelsHidden()
                                .frame(maxWidth: 360)
                            }
                            Button(pdfs.isEmpty ? "PDF wählen …" : "Andere PDF …", systemImage: "doc.badge.plus") { choosePDF() }
                            if detecting { ProgressView().controlSize(.small) }
                        }
                        if let error {
                            Text(error).font(.system(size: 12)).foregroundStyle(Theme.danger).fixedSize(horizontal: false, vertical: true)
                        }
                        if materialID != nil, !detecting {
                            structure
                            optionsCard
                        }
                    }
                    .padding(20)
                }
                Divider()
                HStack {
                    if materialID != nil, !detected.isEmpty {
                        Text(estimate).font(.system(size: 11.5)).foregroundStyle(Theme.textTertiary)
                    }
                    Spacer()
                    Button("Abbrechen") { dismiss() }.keyboardShortcut(.cancelAction)
                    Button("Kurs erstellen") { start() }
                        .buttonStyle(.borderedProminent)
                        .keyboardShortcut(.defaultAction)
                        .disabled(materialID == nil || detected.filter(\.included).isEmpty || detecting)
                }
                .padding(16)
            }
            .frame(width: 720, height: 680)
            .onAppear {
                options = course.buildOptions ?? CourseBuildOptions()
                if materialID == nil, let first = pdfs.first {
                    materialID = first.id
                    detect()
                } else if pdfs.isEmpty {
                    choosePDF()
                }
            }
        }
    }

    private var structure: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                StudioSectionHeader(title: "Lektionen", symbol: "list.number", count: detected.filter(\.included).count)
                Spacer()
                if let source {
                    Text(source == .bookmarks ? "aus den Lesezeichen der PDF" : "aus den Überschriften der Seiten")
                        .font(.system(size: 11)).foregroundStyle(Theme.textTertiary)
                }
            }
            if detected.isEmpty {
                Text("In dieser PDF ließ sich keine Gliederung finden (keine Lesezeichen, keine Überschriften wie „Lektion 1“ oder „Kapitel 1“). Lege die Lektionen mit ihren Seiten hier an.")
                    .font(.system(size: 12.5)).foregroundStyle(Theme.textSecondary).fixedSize(horizontal: false, vertical: true)
            } else {
                Text("Abgewählte Teile (Inhaltsverzeichnis, Einleitung, Anhang) werden nicht erstellt. Titel und Seiten kannst du ändern.")
                    .font(.system(size: 11.5)).foregroundStyle(Theme.textTertiary)
            }
            ForEach($detected) { $lesson in
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 8) {
                        Toggle("", isOn: $lesson.included).labelsHidden().toggleStyle(.checkbox)
                        StudioField(placeholder: "Titel", text: $lesson.title)
                            .opacity(lesson.included ? 1 : 0.5)
                        Text("S.").font(.system(size: 11)).foregroundStyle(Theme.textTertiary)
                        TextField("", value: $lesson.firstPage, format: .number).frame(width: 44).textFieldStyle(.roundedBorder)
                        Text("–").foregroundStyle(Theme.textTertiary)
                        TextField("", value: $lesson.lastPage, format: .number).frame(width: 44).textFieldStyle(.roundedBorder)
                        if !lesson.sections.isEmpty {
                            Button {
                                if expanded.contains(lesson.id) { expanded.remove(lesson.id) } else { expanded.insert(lesson.id) }
                            } label: {
                                Text("\(lesson.sections.count) Abschnitte").font(.system(size: 11))
                            }
                            .buttonStyle(.borderless)
                        }
                        IconButton(systemName: "minus.circle", help: "Entfernen", size: 11, frameSize: 20) { detected.removeAll { $0.id == lesson.id } }
                    }
                    if expanded.contains(lesson.id) {
                        ForEach(lesson.sections, id: \.self) { section in
                            HStack {
                                Text(section.title)
                                Spacer()
                                Text("S. \(section.firstPage)–\(section.lastPage)").monospacedDigit()
                            }
                            .font(.system(size: 11.5))
                            .foregroundStyle(Theme.textSecondary)
                            .padding(.leading, 30)
                        }
                    }
                }
                .padding(8)
                .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Theme.ink.opacity(lesson.included ? 0.05 : 0.02)))
            }
            Button("Lektion hinzufügen", systemImage: "plus") {
                let last = detected.last?.lastPage ?? 0
                detected.append(DetectedLesson(title: "Lektion \(detected.count + 1)", firstPage: min(pageCount, last + 1), lastPage: max(min(pageCount, last + 20), 1)))
            }
            .buttonStyle(.borderless)
            .font(.system(size: 12))
        }
    }

    private var optionsCard: some View {
        StudioCard(title: "Was das Modell je Lektion macht", symbol: "sparkles") {
            VStack(alignment: .leading, spacing: 6) {
                Toggle("Ausführliche Zusammenfassung als Writer-Dokument (mit Abstract)", isOn: $options.summary)
                HStack {
                    Toggle("Karteikarten", isOn: $options.cards)
                    Stepper("\(options.cardsPerSection) je Abschnitt", value: $options.cardsPerSection, in: 2...12)
                        .disabled(!options.cards)
                        .fixedSize()
                }
                Toggle("Inhaltsanalyse: Themen und wie sie zusammenhängen", isOn: $options.analysis)
                Toggle("Präsentation aus der Zusammenfassung", isOn: $options.presentation)
                Toggle("mit Moderatorenkarten, damit die KI sie mit Qwen TTS vortragen kann", isOn: $options.speakerNotes)
                    .disabled(!options.presentation)
                    .padding(.leading, 20)
                Text("Inhaltsanalyse und Präsentation entstehen aus der Zusammenfassung; sie wird dafür auf jeden Fall geschrieben. Der KI-Test der Lektionen nutzt die Lernnotizen und braucht keine eigene Vorbereitung.")
                    .font(.system(size: 11)).foregroundStyle(Theme.textTertiary).fixedSize(horizontal: false, vertical: true)
            }
            .font(.system(size: 12.5))
            .toggleStyle(.checkbox)
        }
    }

    /// A rough time from what was measured with Qwen 3.5 9B on an M1 Pro: about 45 s to read 7,000 characters
    /// (two to three pages of a script), 45 s per section summary, 25 s per slide with its speaker card.
    private var estimate: String {
        let lessons = detected.filter(\.included)
        let pages = lessons.reduce(0) { $0 + $1.pageCount }
        let sections = lessons.reduce(0) { $0 + max(1, $1.sections.count) }
        var seconds = Double(pages) * 1_250 / 7_000 * 45
        if options.summary || options.analysis || options.presentation { seconds += Double(sections) * 45 + Double(lessons.count) * 15 }
        if options.cards { seconds += Double(sections) * 25 }
        if options.analysis { seconds += Double(lessons.count) * 90 }
        if options.presentation { seconds += Double(sections) * 4 * (options.speakerNotes ? 25 : 10) }
        let minutes = Int((seconds / 60).rounded())
        return "\(lessons.count) Lektionen, \(pages) Seiten · mit dem lokalen Modell etwa " + (minutes >= 90 ? "\(Int((Double(minutes) / 60).rounded())) Stunden" : "\(max(1, minutes)) Minuten") + " im Hintergrund"
    }

    private func choosePDF() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.pdf]
        panel.message = "Das Skript des Kurses als PDF"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let material = try app.addCourseMaterial(file: url, to: courseID, kind: .pdf)
            materialID = material.id
            detect()
        } catch {
            self.error = "Die PDF ließ sich nicht übernehmen: \(error.localizedDescription)"
        }
    }

    private func detect() {
        guard let materialID else { return }
        detecting = true
        error = nil
        Task {
            do {
                let result = try await app.detectLessons(material: materialID, in: courseID)
                detected = result.lessons
                source = result.lessons.isEmpty ? nil : result.source
                pdfTitle = result.title
                pageCount = result.pageCount
                expanded = []
            } catch {
                self.error = error.localizedDescription
                detected = []
            }
            detecting = false
        }
    }

    private func start() {
        guard let materialID else { return }
        let lessons = detected.map { lesson in
            var lesson = lesson
            lesson.firstPage = max(1, min(pageCount, lesson.firstPage))
            lesson.lastPage = max(lesson.firstPage, min(pageCount, lesson.lastPage))
            return lesson
        }
        let options = options
        Task {
            if let title = pdfTitle, app.learning.course(courseID)?.name.trimmingCharacters(in: .whitespaces).isEmpty == true {
                app.learning.courses.update(courseID) { $0.name = title }
            }
            let ids = await app.addDetectedLessons(lessons, material: materialID, to: courseID)
            app.buildLessons(ids, in: courseID, options: options)
        }
        dismiss()
    }
}
