import SwiftUI
import UniformTypeIdentifiers

// MARK: - Learning session

/// The due cards one after another: the question, Space shows the answer, 1 to 4 rate it. The buttons say when the
/// card would come back.
struct ReviewSessionView: View {
    @Environment(AppModel.self) private var app
    let courseID: UUID
    var compact = false
    @State private var showsAnswer = false
    @State private var answered = 0
    @State private var currentID: UUID?
    @State private var lastRating: CardRating?

    var body: some View {
        let library = app.learning
        let queue = library.queue(courseID)
        let card = currentID.flatMap { id in queue.first { $0.id == id } } ?? queue.first
        VStack(spacing: compact ? 10 : 18) {
            if let course = library.course(courseID), let pause = library.activePause(for: course) {
                StudioEmptyState(symbol: "beach.umbrella", title: "Lernpause", text: "Seit \(pause.start.formatted(date: .abbreviated, time: .omitted)) ruht dieser Kurs. Nichts staut sich: Beim Ende rücken die Karten weiter.",
                                 actionTitle: "Pause beenden") { library.endPause(pause.id) }
            } else if let card {
                progress(queue.count)
                cardView(card)
                if showsAnswer {
                    ratingButtons(card)
                } else {
                    Button {
                        withAnimation(.snappy(duration: 0.2)) { showsAnswer = true }
                    } label: {
                        Text("Antwort zeigen").frame(width: compact ? 200 : 260)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(compact ? .regular : .large)
                    .keyboardShortcut(.space, modifiers: [])
                }
            } else {
                finished
            }
        }
        .padding(compact ? 10 : 28)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear { currentID = queue.first?.id }
    }

    private func progress(_ remaining: Int) -> some View {
        HStack(spacing: 10) {
            Text("Noch \(remaining)").font(.system(size: 12, weight: .medium).monospacedDigit()).foregroundStyle(Theme.textSecondary)
            if answered > 0 {
                Text("· \(answered) beantwortet").font(.system(size: 12).monospacedDigit()).foregroundStyle(Theme.textTertiary)
            }
            if let lastRating {
                Text("· zuletzt „\(lastRating.label)“").font(.system(size: 12)).foregroundStyle(Theme.textTertiary)
            }
        }
    }

    private func cardView(_ card: LearningCard) -> some View {
        VStack(spacing: 0) {
            Text(card.front)
                .font(.system(size: compact ? 15 : 22, weight: .medium))
                .multilineTextAlignment(.center)
                .foregroundStyle(Theme.textPrimary)
                .frame(maxWidth: .infinity)
                .padding(compact ? 14 : 30)
                .textSelection(.enabled)
            if showsAnswer {
                Divider()
                Text(card.back)
                    .font(.system(size: compact ? 13.5 : 18))
                    .multilineTextAlignment(.center)
                    .foregroundStyle(Theme.textSecondary)
                    .frame(maxWidth: .infinity)
                    .padding(compact ? 14 : 30)
                    .textSelection(.enabled)
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .frame(maxWidth: compact ? .infinity : 720)
        .background(RoundedRectangle(cornerRadius: 18, style: .continuous).fill(Theme.elevated))
        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(Theme.border))
        .shadow(color: Theme.shade.opacity(0.25), radius: 18, y: 8)
        .overlay(alignment: .topTrailing) {
            Text(card.state.label)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(Theme.textTertiary)
                .padding(10)
        }
    }

    private func ratingButtons(_ card: LearningCard) -> some View {
        let preview = app.learning.scheduler.preview(card)
        return HStack(spacing: compact ? 6 : 12) {
            ForEach(CardRating.allCases) { rating in
                Button {
                    rate(card, rating)
                } label: {
                    VStack(spacing: 2) {
                        Text(rating.label).font(.system(size: compact ? 12 : 14, weight: .semibold))
                        Text(LearningScheduler.label(preview[rating] ?? 0)).font(.system(size: 10.5).monospacedDigit()).opacity(0.75)
                    }
                    .frame(width: compact ? 70 : 110, height: compact ? 40 : 52)
                    .foregroundStyle(.white)
                    .background(RoundedRectangle(cornerRadius: 11, style: .continuous).fill(tint(rating)))
                }
                .buttonStyle(.plain)
                .keyboardShortcut(KeyEquivalent(Character(String(rating.rawValue))), modifiers: [])
                .help("\(rating.label) (Taste \(rating.rawValue))")
            }
        }
    }

    private func tint(_ rating: CardRating) -> Color {
        switch rating {
        case .again: Color(hex: 0xD9534F)
        case .hard: Color(hex: 0xE69A2E)
        case .good: Color(hex: 0x3BA55C)
        case .easy: Color(hex: 0x3D84D6)
        }
    }

    private func rate(_ card: LearningCard, _ rating: CardRating) {
        app.learning.answer(card.id, in: courseID, rating)
        answered += 1
        lastRating = rating
        showsAnswer = false
        currentID = app.learning.queue(courseID).first?.id
    }

    private var finished: some View {
        let waiting = app.learning.waitingSteps(courseID)
        let next = app.learning.course(courseID)?.cards.filter { !$0.suspended && $0.state != .new }.map(\.due).min()
        return VStack(spacing: 12) {
            Image(systemName: answered > 0 ? "checkmark.seal.fill" : "leaf.fill")
                .font(.system(size: compact ? 30 : 46))
                .foregroundStyle(Theme.success)
            Text(answered > 0 ? "Geschafft – \(answered) Karten!" : "Gerade ist nichts fällig")
                .font(.system(size: compact ? 15 : 20, weight: .semibold))
            if !waiting.isEmpty {
                Text("\(waiting.count) Karten in Lernschritten kommen in wenigen Minuten wieder.")
                    .font(.system(size: 12.5)).foregroundStyle(Theme.textSecondary)
            } else if let next {
                Text("Nächste Wiederholung: \(next.formatted(date: .abbreviated, time: .shortened))")
                    .font(.system(size: 12.5)).foregroundStyle(Theme.textSecondary)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Material

struct CourseMaterialTab: View {
    @Environment(AppModel.self) private var app
    let courseID: UUID
    let model: LearningStudioModel
    @State private var link = ""
    @State private var addingText = false
    @State private var textTitle = ""
    @State private var textBody = ""
    @State private var running: [UUID: String] = [:]
    @State private var errors: [UUID: String] = [:]
    @State private var cardCount = 12

    var body: some View {
        if let course = app.learning.course(courseID) {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    HStack(spacing: 10) {
                        Button("PDF …", systemImage: "doc.richtext") { choosePDF(kind: .pdf) }
                        Button("Probeklausur …", systemImage: "checkmark.seal") { choosePDF(kind: .probeklausur) }
                        Button("Text …", systemImage: "text.alignleft") { addingText = true }
                        Menu {
                            ForEach(app.citations.sources.prefix(60)) { source in
                                Button(source.title) { app.addCourseSource(source.id, to: courseID) }
                            }
                            if app.citations.sources.isEmpty { Text("Citation Studio hat noch keine Quellen") }
                        } label: {
                            Label("Quelle", systemImage: "quote.bubble")
                        }
                        .fixedSize()
                        Spacer()
                    }
                    HStack(spacing: 8) {
                        Image(systemName: "link").foregroundStyle(Theme.textTertiary)
                        StudioField(placeholder: "Link oder YouTube-Adresse einfügen und Return", text: $link)
                            .onSubmit {
                                app.addCourseLink(link, to: courseID)
                                link = ""
                            }
                    }
                    StudioCard(title: "Mit dem ganzen Kurs", symbol: "sparkles") {
                        aiButtons(material: nil, label: "Kurs")
                    }
                    if course.materials.isEmpty {
                        Text("Hinterlege Skripte, Folien als PDF, eine Probeklausur, Links, YouTube-Videos oder Quellen aus Citation Studio. Das Modell kann daraus Lernzettel und Karten machen und dich abfragen.")
                            .font(.system(size: 12.5)).foregroundStyle(Theme.textTertiary)
                    }
                    ForEach(course.materials) { material in
                        materialRow(material)
                    }
                }
                .padding(24)
                .frame(maxWidth: 1000, alignment: .leading)
                .frame(maxWidth: .infinity)
            }
            .sheet(isPresented: $addingText) {
                VStack(alignment: .leading, spacing: 10) {
                    Text("Text als Material").font(.system(size: 15, weight: .semibold))
                    StudioField(placeholder: "Titel", text: $textTitle)
                    TextEditor(text: $textBody).font(.system(size: 12.5)).frame(height: 260)
                    HStack {
                        Spacer()
                        Button("Abbrechen") { addingText = false }
                        Button("Hinzufügen") {
                            let material = LearningMaterial(kind: .text, title: textTitle, text: textBody)
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

    private func materialRow(_ material: LearningMaterial) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Image(systemName: material.kind.symbol)
                    .foregroundStyle(material.kind == .youtube ? Color(hex: 0xE53935) : Theme.accent)
                    .frame(width: 22)
                VStack(alignment: .leading, spacing: 2) {
                    Text(material.displayTitle).font(.system(size: 13, weight: .medium)).lineLimit(1)
                    Text([material.kind.label, material.url].compactMap { $0 }.joined(separator: " · "))
                        .font(.system(size: 11.5)).foregroundStyle(Theme.textTertiary).lineLimit(1)
                }
                Spacer()
                Button("Öffnen") { app.openCourseMaterial(material, in: courseID) }.buttonStyle(.borderless)
                IconButton(systemName: "trash", help: "Material entfernen", size: 11, frameSize: 22) { app.removeCourseMaterial(material.id, from: courseID) }
            }
            if material.kind != .link && material.kind != .youtube || !material.text.isEmpty {
                aiButtons(material: material.id, label: material.displayTitle)
            } else {
                Text("Für Lernzettel und Karten braucht das Modell den Inhalt: lade das Transkript oder die Seite als Text oder PDF hoch.")
                    .font(.system(size: 11.5)).foregroundStyle(Theme.textTertiary)
            }
            if let error = errors[material.id] {
                Text(error).font(.system(size: 11.5)).foregroundStyle(Theme.danger)
            }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Theme.ink.opacity(0.04)))
    }

    private func aiButtons(material: UUID?, label: String) -> some View {
        let key = material ?? courseID
        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Button("Lernzettel", systemImage: "doc.text.magnifyingglass") {
                    run(key, "Lernzettel wird geschrieben …") { try await app.makeStudySheet(courseID: courseID, material: material) }
                }
                Button("\(cardCount) Karten", systemImage: "rectangle.stack.badge.plus") {
                    run(key, "Karten entstehen …") { _ = try await app.makeCards(courseID: courseID, material: material, count: cardCount) }
                }
                Stepper("", value: $cardCount, in: 4...40, step: 4).labelsHidden()
                Button("Abfragen", systemImage: "questionmark.bubble") {
                    let session = app.startQuiz(courseID: courseID, material: material)
                    model.tab = .quiz
                    Task { _ = try? await app.nextQuizQuestion(courseID: courseID, session: session) }
                }
                if let status = running[key] {
                    ProgressView().controlSize(.small)
                    Text(status).font(.system(size: 11.5)).foregroundStyle(Theme.textSecondary)
                }
            }
            .disabled(running[key] != nil)
            .font(.system(size: 12))
            if material == nil, let error = errors[key] {
                Text(error).font(.system(size: 11.5)).foregroundStyle(Theme.danger)
            }
        }
    }

    private func run(_ key: UUID, _ status: String, _ work: @escaping () async throws -> Void) {
        running[key] = status
        errors[key] = nil
        Task {
            do {
                try await work()
            } catch {
                errors[key] = error.localizedDescription
            }
            running[key] = nil
        }
    }

    private func choosePDF(kind: LearningMaterial.Kind) {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.pdf]
        panel.allowsMultipleSelection = true
        panel.message = kind == .probeklausur ? "Probeklausur als PDF" : "Lernmaterial als PDF"
        guard panel.runModal() == .OK else { return }
        for url in panel.urls { _ = try? app.addCourseMaterial(file: url, to: courseID, kind: kind) }
    }
}

// MARK: - Quiz

struct CourseQuizTab: View {
    @Environment(AppModel.self) private var app
    let courseID: UUID
    @State private var answer = ""
    @State private var busy = false
    @State private var error: String?
    @State private var sessionID: UUID?

    var body: some View {
        if let course = app.learning.course(courseID) {
            let session = sessionID.flatMap { id in course.quizzes.first { $0.id == id } } ?? course.quizzes.last
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    HStack {
                        Menu {
                            Button("Über den ganzen Kurs") { start(material: nil) }
                            ForEach(course.materials) { material in Button(material.displayTitle) { start(material: material.id) } }
                        } label: {
                            Label("Neue Abfrage", systemImage: "plus")
                        }
                        .fixedSize()
                        if let score = session?.score {
                            Text("Diese Abfrage: \(Int(score * 100)) %").font(.system(size: 12.5, weight: .medium)).foregroundStyle(Theme.textSecondary)
                        }
                        Spacer()
                        if course.quizzes.count > 1 {
                            Picker("Frühere", selection: Binding(get: { session?.id }, set: { sessionID = $0 })) {
                                ForEach(course.quizzes.reversed()) { quiz in
                                    Text(quiz.date.formatted(date: .abbreviated, time: .shortened) + (quiz.score.map { " · \(Int($0 * 100)) %" } ?? "")).tag(Optional(quiz.id))
                                }
                            }
                            .frame(width: 260)
                        }
                    }
                    if let session {
                        ForEach(session.items) { item in
                            quizItem(item, session: session.id, isLast: item.id == session.items.last?.id)
                        }
                        if busy {
                            HStack { ProgressView().controlSize(.small); Text("Das Modell denkt …").font(.system(size: 12)).foregroundStyle(Theme.textSecondary) }
                        } else if session.items.last?.verdict != nil || session.items.isEmpty {
                            Button("Nächste Frage", systemImage: "arrow.right.circle") { next(session.id) }
                                .buttonStyle(.borderedProminent)
                        }
                    } else {
                        StudioEmptyState(symbol: "questionmark.bubble", title: "Lass dich abfragen",
                                         text: "Das Modell stellt Fragen zum Material und zu deinen Karten, prüft deine Antworten und erklärt, was fehlt. Eine Probeklausur im Material nimmt es als Vorbild.",
                                         actionTitle: "Abfrage starten") { start(material: nil) }
                    }
                    if let error { Text(error).font(.system(size: 12)).foregroundStyle(Theme.danger) }
                }
                .padding(24)
                .frame(maxWidth: 900, alignment: .leading)
                .frame(maxWidth: .infinity)
            }
        }
    }

    private func quizItem(_ item: QuizItem, session: UUID, isLast: Bool) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(item.question, systemImage: "questionmark.circle")
                .font(.system(size: 14, weight: .medium))
                .textSelection(.enabled)
            if let verdict = item.verdict {
                Text(item.answer.isEmpty ? "(keine Antwort)" : item.answer).font(.system(size: 12.5)).foregroundStyle(Theme.textSecondary)
                HStack(alignment: .top, spacing: 8) {
                    Text(verdict.label)
                        .font(.system(size: 11, weight: .bold))
                        .padding(.horizontal, 8).padding(.vertical, 3)
                        .background(Capsule().fill(verdict == .richtig ? Theme.success : verdict == .teilweise ? Theme.warning : Theme.danger))
                        .foregroundStyle(.white)
                    Text(item.feedback).font(.system(size: 12.5)).textSelection(.enabled)
                }
                if !item.solution.isEmpty {
                    DisclosureGroup("Musterantwort") {
                        Text(item.solution).font(.system(size: 12.5)).foregroundStyle(Theme.textSecondary).textSelection(.enabled)
                    }
                    .font(.system(size: 12))
                }
            } else if isLast {
                TextEditor(text: $answer)
                    .font(.system(size: 13))
                    .frame(minHeight: 90)
                    .padding(6)
                    .background(RoundedRectangle(cornerRadius: 8).fill(Theme.ink.opacity(0.05)))
                HStack {
                    Button("Antwort prüfen") { grade(session, item.id) }
                        .buttonStyle(.borderedProminent)
                        .disabled(busy)
                        .keyboardShortcut(.return, modifiers: .command)
                    Button("Weiß ich nicht") { answer = ""; grade(session, item.id) }.disabled(busy)
                }
            }
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Theme.ink.opacity(0.04)))
    }

    private func start(material: UUID?) {
        let id = app.startQuiz(courseID: courseID, material: material)
        sessionID = id
        next(id)
    }

    private func next(_ session: UUID) {
        busy = true
        error = nil
        Task {
            do { _ = try await app.nextQuizQuestion(courseID: courseID, session: session) } catch { self.error = error.localizedDescription }
            busy = false
        }
    }

    private func grade(_ session: UUID, _ item: UUID) {
        busy = true
        error = nil
        let text = answer
        Task {
            do {
                try await app.gradeQuizAnswer(courseID: courseID, session: session, item: item, answer: text)
                answer = ""
            } catch {
                self.error = error.localizedDescription
            }
            busy = false
        }
    }
}
