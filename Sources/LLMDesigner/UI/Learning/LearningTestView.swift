import SwiftUI

/// "Test und Einschätzung durch KI": many questions over the whole lesson, one after another as in an exam; the model
/// grades in the background, and at the end comes a grade from A to F with the model's assessment.
struct LessonTestTab: View {
    @Environment(AppModel.self) private var app
    let courseID: UUID
    let lessonID: UUID
    @Bindable var model: LearningStudioModel
    @State private var count = AppModel.lessonTestDefaultCount
    @State private var shownID: UUID?
    @State private var starting = false
    @State private var error: String?

    var body: some View {
        if let course = app.learning.course(courseID) {
            let tests = course.tests(of: lessonID)
            let session = shownID.flatMap { id in tests.first { $0.id == id } } ?? tests.last { $0.finishedAt == nil }
            Group {
                if let session, session.finishedAt == nil {
                    // Kept, so the result shows when the test ends.
                    TestRunView(courseID: courseID, sessionID: session.id)
                        .onAppear { shownID = session.id }
                } else if let session {
                    TestResultView(courseID: courseID, sessionID: session.id, model: model) { shownID = nil }
                } else {
                    start(tests: tests)
                }
            }
        }
    }

    private func start(tests: [QuizSession]) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                StudioCard(title: "Wo stehst du in dieser Lektion?", symbol: "checkmark.seal") {
                    Text("Der Test fragt dich intensiv ab: Fragen über alle Abschnitte der Lektion, etwa zwei Drittel offen (Wissen, Verständnis, Anwendung mit kleinen Rechen- oder Fallaufgaben) und ein Drittel mit Auswahl. Wie in einer Prüfung siehst du erst am Ende, was richtig war: Die KI bewertet deine Antworten im Hintergrund und gibt dir eine Note von A bis F mit ihrer Einschätzung.")
                        .font(.system(size: 12.5))
                        .foregroundStyle(Theme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                    HStack(spacing: 14) {
                        Stepper("\(count) Fragen", value: $count, in: AppModel.lessonTestCounts, step: 5)
                            .fixedSize()
                        Text("etwa \(count * 2)–\(count * 3) Minuten").font(.system(size: 11.5)).foregroundStyle(Theme.textTertiary)
                        Spacer()
                        if starting { ProgressView().controlSize(.small) }
                        Button("Test starten", systemImage: "play.fill") { start() }
                            .buttonStyle(.borderedProminent)
                            .disabled(starting)
                    }
                    .font(.system(size: 12.5))
                    Text("Notenskala: A ab 90 %, B ab 80 %, C ab 70 %, D ab 60 %, E ab 50 % (bestanden), F darunter. Teilweise richtige Antworten zählen halb.")
                        .font(.system(size: 11)).foregroundStyle(Theme.textTertiary)
                    if let error { Text(error).font(.system(size: 12)).foregroundStyle(Theme.danger).fixedSize(horizontal: false, vertical: true) }
                }
                let finished = tests.filter { $0.finishedAt != nil }
                if !finished.isEmpty {
                    StudioSectionHeader(title: "Frühere Tests", symbol: "clock.arrow.circlepath", count: finished.count)
                    ForEach(finished.reversed()) { test in
                        Button {
                            shownID = test.id
                        } label: {
                            HStack(spacing: 10) {
                                if let grade = test.grade { GradeBadge(grade: grade, size: 26) }
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(test.date.formatted(date: .abbreviated, time: .shortened)).font(.system(size: 13, weight: .medium))
                                    Text("\(test.score.map { "\(Int(($0 * 100).rounded())) %" } ?? "–") · \(test.answeredCount) Fragen beantwortet")
                                        .font(.system(size: 11.5)).foregroundStyle(Theme.textTertiary)
                                }
                                Spacer()
                                Image(systemName: "chevron.right").foregroundStyle(Theme.textTertiary)
                            }
                            .padding(10)
                            .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(Theme.ink.opacity(0.04)))
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .padding(24)
            .frame(maxWidth: 860, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .environment(\.locale, Locale(identifier: "de_DE"))
    }

    private func start() {
        starting = true
        error = nil
        Task {
            do {
                shownID = try await app.startLessonTest(courseID: courseID, lessonID: lessonID, count: count)
            } catch {
                self.error = error.localizedDescription
            }
            starting = false
        }
    }
}

/// One question after another; the answers go to the model in the background.
struct TestRunView: View {
    @Environment(AppModel.self) private var app
    let courseID: UUID
    let sessionID: UUID
    @State private var answer = ""
    @State private var choice: Int?
    @State private var finishing = false
    @State private var error: String?
    @State private var confirmEnd = false

    var body: some View {
        if let session = app.learning.course(courseID)?.quizzes.first(where: { $0.id == sessionID }) {
            let tests = app.lessonTests
            let current = session.items.first { !$0.isAnswered }
            let answered = session.answeredCount
            let total = max(session.planned, session.items.count)
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    HStack(spacing: 12) {
                        Text("Frage \(min(answered + 1, total)) von \(total)").font(.system(size: 13, weight: .semibold).monospacedDigit())
                        ProgressView(value: Double(answered), total: Double(max(1, total))).frame(maxWidth: 260)
                        let grading = session.items.filter { $0.isAnswered && $0.verdict == nil }.count
                        if grading > 0 {
                            Label("KI bewertet \(grading)", systemImage: "hourglass").font(.system(size: 11)).foregroundStyle(Theme.textTertiary)
                        }
                        Spacer()
                        Button("Test beenden") { confirmEnd = true }
                            .buttonStyle(.borderless)
                            .disabled(answered == 0 || finishing)
                    }
                    if finishing || (current == nil && session.items.count >= session.planned && !tests.generating.contains(sessionID)) {
                        evaluating(session)
                    } else if let current {
                        question(current)
                    } else {
                        HStack(spacing: 10) {
                            ProgressView().controlSize(.small)
                            Text(session.items.isEmpty ? "Die KI stellt die ersten Fragen zusammen …" : "Die nächste Frage entsteht …")
                                .font(.system(size: 13)).foregroundStyle(Theme.textSecondary)
                        }
                        .padding(.vertical, 30)
                    }
                    if let message = error ?? tests.errors[sessionID] {
                        HStack(alignment: .top, spacing: 8) {
                            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Theme.warning)
                            Text(message).font(.system(size: 12)).foregroundStyle(Theme.textSecondary).fixedSize(horizontal: false, vertical: true)
                            Button("Erneut versuchen") {
                                error = nil
                                tests.errors[sessionID] = nil
                                app.continueLessonTest(courseID: courseID, sessionID: sessionID)
                            }
                            .buttonStyle(.borderless)
                        }
                    }
                }
                .padding(28)
                .frame(maxWidth: 820, alignment: .leading)
                .frame(maxWidth: .infinity)
            }
            .onAppear { app.continueLessonTest(courseID: courseID, sessionID: sessionID) }
            .confirmationDialog("Test jetzt beenden?", isPresented: $confirmEnd) {
                Button("Beenden und auswerten") { finish() }
            } message: {
                Text("Nur die \(answered) beantworteten Fragen zählen für die Note.")
            }
        }
    }

    private func question(_ item: QuizItem) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 6) {
                chip(item.kind == .choice ? "Auswahl" : "Offen")
                if !item.level.isEmpty { chip(item.level) }
                if !item.section.isEmpty { chip(item.section) }
            }
            Text(item.question)
                .font(.system(size: 18, weight: .medium))
                .foregroundStyle(Theme.textPrimary)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
            if item.kind == .choice {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(Array(item.options.enumerated()), id: \.offset) { index, option in
                        Button {
                            choice = index
                        } label: {
                            HStack(alignment: .top, spacing: 10) {
                                Image(systemName: choice == index ? "largecircle.fill.circle" : "circle")
                                    .foregroundStyle(choice == index ? Theme.accent : Theme.textTertiary)
                                Text(option).font(.system(size: 14)).foregroundStyle(Theme.textPrimary).multilineTextAlignment(.leading)
                                    .fixedSize(horizontal: false, vertical: true)
                                Spacer(minLength: 0)
                            }
                            .padding(12)
                            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(choice == index ? Theme.accent.opacity(0.12) : Theme.ink.opacity(0.04)))
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .keyboardShortcut(KeyEquivalent(Character(String(index + 1))), modifiers: [])
                    }
                }
            } else {
                TextEditor(text: $answer)
                    .font(.system(size: 14))
                    .scrollContentBackground(.hidden)
                    .frame(minHeight: 140)
                    .padding(8)
                    .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Theme.ink.opacity(0.05)))
            }
            HStack {
                Button("Weiß ich nicht") { submit(item, skip: true) }
                Spacer()
                Button("Weiter", systemImage: "arrow.right") { submit(item, skip: false) }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.return, modifiers: .command)
                    .disabled(item.kind == .choice ? choice == nil : answer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            Text(item.kind == .choice ? "Taste 1–\(item.options.count) wählt, ⌘↩ geht weiter." : "⌘↩ geht weiter. Formeln darfst du in Worten oder wie in LaTeX schreiben.")
                .font(.system(size: 11)).foregroundStyle(Theme.textTertiary)
        }
        .padding(22)
        .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(Theme.elevated))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(Theme.border))
    }

    private func evaluating(_ session: QuizSession) -> some View {
        let waiting = session.items.filter { $0.isAnswered && $0.verdict == nil }.count
        return VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                ProgressView().controlSize(.small)
                Text(waiting > 0 ? "Die KI bewertet die letzten \(waiting) Antworten …" : "Die KI schreibt ihre Einschätzung …")
                    .font(.system(size: 14, weight: .medium))
            }
            Text("Gleich siehst du deine Note, was du schon sicher kannst und was du wiederholen solltest.")
                .font(.system(size: 12.5)).foregroundStyle(Theme.textSecondary)
        }
        .padding(.vertical, 24)
        .task(id: session.answeredCount) {
            if !finishing, session.items.allSatisfy(\.isAnswered), session.items.count >= session.planned { finish() }
        }
    }

    private func chip(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 10.5, weight: .semibold))
            .foregroundStyle(Theme.textSecondary)
            .padding(.horizontal, 7).padding(.vertical, 3)
            .background(Capsule().fill(Theme.ink.opacity(0.07)))
            .lineLimit(1)
    }

    private func submit(_ item: QuizItem, skip: Bool) {
        app.answerTestItem(courseID: courseID, sessionID: sessionID, itemID: item.id, answer: skip ? "" : answer, choice: skip ? nil : choice)
        answer = ""
        choice = nil
    }

    private func finish() {
        guard !finishing else { return }
        finishing = true
        error = nil
        Task {
            do {
                try await app.finishLessonTest(courseID: courseID, sessionID: sessionID)
            } catch {
                self.error = error.localizedDescription
            }
            finishing = false
        }
    }
}

/// The grade, how each section went, the model's assessment and every question with its model answer.
struct TestResultView: View {
    @Environment(AppModel.self) private var app
    let courseID: UUID
    let sessionID: UUID
    @Bindable var model: LearningStudioModel
    let close: () -> Void
    @State private var madeCards: Int?
    @State private var retrying = false

    var body: some View {
        if let course = app.learning.course(courseID), let session = course.quizzes.first(where: { $0.id == sessionID }) {
            let graded = session.items.filter { $0.verdict != nil }
            let sections = AppModel.sectionScores(graded)
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    HStack(alignment: .center, spacing: 20) {
                        if let grade = session.grade {
                            GradeBadge(grade: grade, size: 86)
                            VStack(alignment: .leading, spacing: 4) {
                                Text("Note \(grade.rawValue) – \(grade.label)").font(.system(size: 22, weight: .bold))
                                Text("\(session.score.map { "\(Int(($0 * 100).rounded())) %" } ?? "–") · \(graded.filter { $0.verdict == .richtig }.count) richtig, \(graded.filter { $0.verdict == .teilweise }.count) teilweise, \(graded.filter { $0.verdict == .falsch }.count) falsch von \(graded.count)")
                                    .font(.system(size: 13)).foregroundStyle(Theme.textSecondary)
                                Text(session.date.formatted(date: .abbreviated, time: .shortened)).font(.system(size: 11.5)).foregroundStyle(Theme.textTertiary)
                            }
                        }
                        Spacer()
                        VStack(alignment: .trailing, spacing: 8) {
                            Button("Neuer Test", systemImage: "arrow.counterclockwise", action: close)
                            let mistakes = graded.filter { $0.verdict != .richtig }.count
                            if mistakes > 0 {
                                Button(madeCards.map { "\($0) Karten angelegt" } ?? "Lücken als Karteikarten", systemImage: "rectangle.stack.badge.plus") {
                                    madeCards = app.cardsFromTestMistakes(courseID: courseID, sessionID: sessionID)
                                }
                                .disabled(madeCards != nil)
                                .help("Die \(mistakes) nicht ganz richtigen Fragen werden Karten dieser Lektion")
                            }
                        }
                    }
                    if !sections.isEmpty {
                        StudioCard(title: "Je Abschnitt", symbol: "chart.bar") {
                            VStack(alignment: .leading, spacing: 8) {
                                ForEach(sections, id: \.title) { section in
                                    HStack(spacing: 10) {
                                        Text(section.title).font(.system(size: 12)).lineLimit(1).frame(width: 300, alignment: .leading)
                                        GeometryReader { proxy in
                                            ZStack(alignment: .leading) {
                                                Capsule().fill(Theme.ink.opacity(0.07))
                                                Capsule().fill(GradeBadge.color(LessonGrade(score: section.score)))
                                                    .frame(width: max(4, proxy.size.width * section.score))
                                            }
                                        }
                                        .frame(height: 8)
                                        Text("\(Int((section.score * 100).rounded())) %").font(.system(size: 11.5).monospacedDigit()).frame(width: 44, alignment: .trailing)
                                    }
                                }
                            }
                        }
                    }
                    StudioCard(title: "Einschätzung der KI", symbol: "text.bubble") {
                        if session.assessment.isEmpty, app.lessonTests.finishing.contains(sessionID) {
                            HStack(spacing: 8) {
                                ProgressView().controlSize(.small)
                                Text("Die KI schreibt ihre Einschätzung …").font(.system(size: 12.5)).foregroundStyle(Theme.textSecondary)
                            }
                        } else if session.assessment.isEmpty {
                            HStack {
                                Text("Die Einschätzung fehlt noch.").font(.system(size: 12.5)).foregroundStyle(Theme.textTertiary)
                                if retrying { ProgressView().controlSize(.small) }
                                Button("Schreiben lassen") {
                                    retrying = true
                                    Task {
                                        try? await app.finishLessonTest(courseID: courseID, sessionID: sessionID)
                                        retrying = false
                                    }
                                }
                                .disabled(retrying)
                            }
                        } else {
                            Text(session.assessment)
                                .font(.system(size: 14))
                                .lineSpacing(3)
                                .textSelection(.enabled)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    StudioSectionHeader(title: "Alle Fragen", symbol: "list.bullet", count: session.items.count)
                    ForEach(Array(session.items.enumerated()), id: \.element.id) { index, item in
                        resultRow(item, number: index + 1)
                    }
                }
                .padding(24)
                .frame(maxWidth: 900, alignment: .leading)
                .frame(maxWidth: .infinity)
            }
        }
    }

    private func resultRow(_ item: QuizItem, number: Int) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 8) {
                Text("\(number).").font(.system(size: 13, weight: .semibold).monospacedDigit()).foregroundStyle(Theme.textTertiary)
                Text(item.question).font(.system(size: 13.5, weight: .medium)).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 8)
                if let verdict = item.verdict {
                    Text(verdict.label)
                        .font(.system(size: 10.5, weight: .bold))
                        .padding(.horizontal, 8).padding(.vertical, 3)
                        .background(Capsule().fill(verdict == .richtig ? Theme.success : verdict == .teilweise ? Theme.warning : Theme.danger))
                        .foregroundStyle(.white)
                } else if !item.isAnswered {
                    Text("nicht beantwortet").font(.system(size: 10.5)).foregroundStyle(Theme.textTertiary)
                }
            }
            if item.isAnswered {
                Text("Deine Antwort: " + (item.answerText.isEmpty ? "(keine)" : item.answerText))
                    .font(.system(size: 12.5)).foregroundStyle(Theme.textSecondary).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
            }
            if !item.feedback.isEmpty {
                Text(item.feedback).font(.system(size: 12.5)).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
            }
            if !item.solution.isEmpty {
                DisclosureGroup("Musterantwort") {
                    Text(item.solution).font(.system(size: 12.5)).foregroundStyle(Theme.textSecondary).textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .font(.system(size: 12))
            }
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Theme.ink.opacity(0.04)))
    }
}
