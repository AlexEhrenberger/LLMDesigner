import SwiftUI

/// Learning Studio in small: every course with what is due, and a learning session right in the panel next to the
/// document one is writing. Dropped text becomes cards (one per line, "Frage ; Antwort").
struct PowerLearning: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        let query = app.power.query
        if let id = app.power.courseID, app.learning.course(id) != nil, query.isEmpty {
            PowerCourseView(courseID: id)
        } else {
            PowerCourseList(query: query)
        }
    }
}

private struct PowerCourseList: View {
    @Environment(AppModel.self) private var app
    let query: String

    var body: some View {
        let library = app.learning
        let _ = library.loadIfNeeded()
        let courses = library.courses.records.filter { $0.matches(query) }
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 8) {
                    Image(systemName: "flame.fill").foregroundStyle(Color(hex: 0xF27A3D))
                    Text("\(library.streak()) Tage in Folge · \(courses.reduce(0) { $0 + library.queue($1.id).count }) Karten fällig")
                        .font(.system(size: 12, weight: .medium))
                    Spacer()
                }
                .padding(10)
                .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(Theme.ink.opacity(0.035)))
                .padding(.bottom, 6)
                ForEach(library.state.disciplines) { discipline in
                    let members = courses.filter { $0.discipline == discipline.id }
                    if !members.isEmpty {
                        StudioSectionHeader(title: discipline.displayName, symbol: "leaf", count: members.count)
                        ForEach(members) { row($0) }
                    }
                }
                let loose = courses.filter { library.discipline($0.discipline) == nil }
                if !loose.isEmpty {
                    StudioSectionHeader(title: "Ohne Disziplin", symbol: "tray", count: loose.count)
                    ForEach(loose) { row($0) }
                }
                if courses.isEmpty {
                    PowerEmpty(text: query.isEmpty ? "Noch keine Kurse. Lege im Learning Studio einen an." : "Kein Kurs passt zur Suche.")
                }
                Button {
                    app.openLearningStudio()
                } label: {
                    Label("Learning Studio", systemImage: "arrow.up.forward.app").font(.system(size: 12))
                }
                .buttonStyle(.borderless)
                .padding(10)
            }
            .padding(.horizontal, 10)
            .padding(.bottom, 12)
        }
    }

    private func row(_ course: LearningCourse) -> some View {
        let due = app.learning.queue(course.id).count
        return PowerListRow(title: course.displayName, subtitle: "\(course.cards.count) Karten" + (due > 0 ? " · \(due) fällig" : ""), symbol: course.symbol) {
            app.power.courseID = course.id
        }
    }
}

private struct PowerCourseView: View {
    @Environment(AppModel.self) private var app
    let courseID: UUID
    @State private var targeted = false

    var body: some View {
        let course = app.learning.course(courseID)
        VStack(spacing: 0) {
            PowerItemBar(title: course?.displayName ?? "", symbol: course?.symbol, openHelp: "Im Learning Studio öffnen") {
                app.power.closeItem()
            } onOpen: {
                app.openLearningStudio(LearningStudioCommand(course: courseID))
            }
            ReviewSessionView(courseID: courseID, compact: true)
                .frame(maxHeight: .infinity)
            PowerDropZone(title: "Text hierher ziehen: Karten (Frage ; Antwort je Zeile)", symbol: "rectangle.stack.badge.plus") { dropped in
                let cards = LearningCardText.parse(dropped.markdown).map { LearningCard(front: $0.front, back: $0.back) }
                guard !cards.isEmpty, let before = app.learning.course(courseID) else { return }
                app.learning.courses.update(courseID) { $0.cards += cards }
                app.power.lastChange = PowerAccess.Change(label: cards.count == 1 ? "1 Karte angelegt" : "\(cards.count) Karten angelegt") { [weak app] in
                    app?.learning.courses.restore(before)
                }
            }
            .padding(10)
        }
    }
}
