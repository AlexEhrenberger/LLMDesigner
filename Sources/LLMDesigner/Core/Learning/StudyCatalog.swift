import Foundation

/// What a university prescribes for a study program: its modules in the order of the curriculum, the elective areas
/// and, per module, the exam and the lessons of its script. It is built into the app (see `StudyCatalogIU.swift`); what
/// the person chose and planned lies in the library (`LearningStudy`).
struct StudyCatalog: Sendable {
    /// An elective area: `picks` modules of it are taken, in `semester` (nil: spread over the whole study).
    struct Area: Sendable, Identifiable {
        let id: String
        let title: String
        let semester: Int?
        let picks: Int
        let note: String
    }

    struct Lesson: Sendable {
        let title: String
        let sections: [String]

        init(_ title: String, _ sections: [String]) {
            self.title = title
            self.sections = sections
        }
    }

    enum Kind: String, Sendable {
        case theory, project, seminar, thesis, internship, open

        var symbol: String {
            switch self {
            case .theory: "book"
            case .project: "hammer"
            case .seminar: "text.book.closed"
            case .thesis: "graduationcap"
            case .internship: "briefcase"
            case .open: "sparkles"
            }
        }
    }

    struct Module: Sendable, Identifiable {
        /// The course code of the study plan (e.g. "DLBDSEAIS01-01_D"); the key in the library.
        let code: String
        let title: String
        let ects: Int
        let exam: StudyExam
        let kind: Kind
        /// The semester of the full-time model; electives of A, B and C take their area's.
        let semester: Int?
        /// nil: compulsory.
        let area: String?
        var english = false
        /// What it is about, in two sentences.
        let about: String
        var lessons: [Lesson] = []

        var id: String { code }
        var isCompulsory: Bool { area == nil }
        /// 150 hours per 5 ECTS, as everywhere at the IU.
        var hours: Int { ects * 30 }
    }

    let id: String
    let name: String
    let degree: String
    let university: String
    /// Where the data comes from, shown on the page.
    let source: String
    /// The name of the discipline the modules' courses live in.
    let shortName: String
    let ects: Int
    let semesters: Int
    let areas: [Area]
    let modules: [Module]

    var title: String { "\(name) (\(degree))" }

    func module(_ code: String) -> Module? { modules.first { $0.code == code } }

    func area(_ id: String?) -> Area? {
        guard let id else { return nil }
        return areas.first { $0.id == id }
    }

    var compulsory: [Module] { modules.filter(\.isCompulsory) }

    func options(of area: String) -> [Module] { modules.filter { $0.area == area } }

    /// The internship that replaces the modules of the area it belongs to.
    var internship: Module? { modules.first { $0.kind == .internship } }

    /// The catalogs the app knows.
    static let all: [StudyCatalog] = [.iuAppliedAI]

    static func named(_ id: String) -> StudyCatalog? { all.first { $0.id == id } }
}

/// How a module is examined, and what that means for the work.
enum StudyExam: String, Sendable {
    case klausur, workbook, portfolio, projektbericht, fallstudie, seminararbeit, fachpraesentation, projektpraesentation
    case hausarbeit, klausurOderHausarbeit, researchEssay, praxisreflexion, bachelorarbeit, offen

    /// Short, for the course's exam form ("Statistik (5 CP, Klausur)").
    var label: String {
        switch self {
        case .klausur: "Klausur"
        case .workbook: "Advanced Workbook"
        case .portfolio: "Portfolio"
        case .projektbericht: "Projektbericht"
        case .fallstudie: "Fallstudie"
        case .seminararbeit: "Seminararbeit"
        case .fachpraesentation: "Fachpräsentation"
        case .projektpraesentation: "Projektpräsentation"
        case .hausarbeit: "Hausarbeit"
        case .klausurOderHausarbeit: "Klausur oder Hausarbeit"
        case .researchEssay: "Research Essay"
        case .praxisreflexion: "Praxisreflexion"
        case .bachelorarbeit: "Bachelorarbeit und Kolloquium"
        case .offen: "je nach gewähltem Kurs"
        }
    }

    /// As the handbook states it.
    var detail: String {
        switch self {
        case .klausur: "Klausur, 90 Minuten"
        case .klausurOderHausarbeit: "Klausur (90 Minuten) oder Hausarbeit"
        case .praxisreflexion: "Praxisreflexion (bestanden / nicht bestanden)"
        case .bachelorarbeit: "Bachelorarbeit (9 ECTS) und Kolloquium (1 ECTS)"
        case .offen: "Prüfung des gewählten Kurses"
        default: label
        }
    }

    /// The steps of the work, in order.
    var steps: [String] {
        switch self {
        case .klausur:
            ["Skript Lektion für Lektion durcharbeiten (die Lektionen sind angelegt)",
             "Online-Tests der Lektionen bestehen – sie sind Voraussetzung für die Prüfung",
             "Musterklausur unter Zeitdruck (90 Minuten) üben",
             "Klausurtermin buchen und schreiben"]
        case .workbook:
            ["Skript durcharbeiten und die Online-Tests bestehen",
             "Aufgaben des Advanced Workbooks bearbeiten",
             "Workbook als schriftliche Ausarbeitung einreichen"]
        case .portfolio:
            ["Konzeptionsphase: Idee und Vorgehen festhalten und Feedback der Tutorin oder des Tutors einholen",
             "Erarbeitungs- und Reflexionsphase: umsetzen und den Zwischenstand abgeben",
             "Finalisierungsphase: Ergebnis mit Dokumentation fertigstellen und das Portfolio einreichen"]
        case .projektbericht:
            ["Aufgabenstellung aus der Themenliste wählen",
             "Lösung umsetzen (Code, Prototyp, Daten)",
             "Projektbericht schreiben: Ansatz begründen, Umsetzung und Ergebnisse beschreiben",
             "Bericht einreichen"]
        case .fallstudie:
            ["Skript durcharbeiten",
             "Thema der Fallstudie wählen",
             "Fallstudie ausarbeiten und einreichen"]
        case .seminararbeit:
            ["Thema aus der Themenliste wählen",
             "Literatur recherchieren und auswerten",
             "Seminararbeit schreiben und einreichen"]
        case .fachpraesentation:
            ["Skript durcharbeiten",
             "Thema der Fachpräsentation wählen",
             "Präsentation mit Folien ausarbeiten und einreichen"]
        case .projektpraesentation:
            ["Projektaufgabe wählen",
             "Projekt umsetzen",
             "Ergebnis als Projektpräsentation vorstellen"]
        case .hausarbeit:
            ["Skript durcharbeiten",
             "Thema wählen und Literatur recherchieren",
             "Hausarbeit schreiben und einreichen"]
        case .klausurOderHausarbeit:
            ["Skript Lektion für Lektion durcharbeiten",
             "Prüfungsform wählen: Klausur oder Hausarbeit",
             "Klausur schreiben oder Hausarbeit einreichen"]
        case .researchEssay:
            ["Thema wählen und den Stand der Forschung recherchieren",
             "Research Essay auf Englisch schreiben und einreichen"]
        case .praxisreflexion:
            ["Praktikumsstelle finden und anmelden",
             "Praktikum absolvieren und die Erfahrungen laufend festhalten",
             "Praxisreflexion schreiben und einreichen"]
        case .bachelorarbeit:
            ["Thema und Betreuung finden, Exposé schreiben",
             "Bachelorarbeit schreiben und einreichen",
             "Kolloquium: Ergebnisse präsentieren und Fragen der Gutachter beantworten"]
        case .offen:
            ["IU-Kurs außerhalb des eigenen Curriculums wählen",
             "Kurs belegen und seine Prüfung bestehen"]
        }
    }
}

extension StudyCatalog.Module {
    /// The text a new course gets as "Worum es geht": what the module is, how it is examined and what to do.
    func courseSummary(in catalog: StudyCatalog) -> String {
        var placement: String
        if let area = catalog.area(area) {
            placement = area.title + (kind == .internship ? " (statt der sechs Module)" : "")
            if let semester { placement += " · \(semester). Semester" } else if let semester = area.semester { placement += " · \(semester). Semester" }
        } else {
            placement = "Pflichtmodul · \(semester ?? 1). Semester"
        }
        var text = "\(code) · \(placement) · \(ects) ECTS · \(hours) Stunden\(english ? " · auf Englisch" : "")\n"
        text += "Prüfung: \(exam.detail)\n\n"
        text += about + "\n\nWas zu tun ist:\n"
        text += exam.steps.enumerated().map { "\($0.offset + 1). \($0.element)" }.joined(separator: "\n")
        if !lessons.isEmpty {
            text += "\n\nLektionen: " + lessons.map(\.title).joined(separator: " · ")
        }
        return text
    }
}
