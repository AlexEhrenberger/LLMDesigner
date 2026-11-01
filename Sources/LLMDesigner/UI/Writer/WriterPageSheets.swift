import SwiftUI

/// The sheets of Writer Studio for the pages: the user's own format, and the head and foot lines.
enum WriterPageSheet: String, Identifiable {
    case pageSetup, runningHeads

    var id: String { rawValue }
}

// MARK: Page setup

/// Paper, margins, text size and line spacing of a document; a format can be kept in the library as a template.
struct PageSetupSheet: View {
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    let document: WriterDocument
    @State private var setup: WriterPageSetup
    @State private var sameMargins: Bool

    init(document: WriterDocument, paper: PaperSize) {
        self.document = document
        let start = WriterPageSetup.starting(from: document.pageFormat, paper: paper, current: document.pageSetup)
        _setup = State(initialValue: start)
        _sameMargins = State(initialValue: Set([start.top, start.bottom, start.left, start.right]).count == 1)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            header(symbol: "doc.badge.gearshape", title: "Seite einrichten",
                   detail: "Papier, Ränder, Schriftgröße und Zeilenabstand. Der Editor zeigt die Seiten, Export und Druck folgen.")
            HStack(alignment: .top, spacing: 22) {
                VStack(alignment: .leading, spacing: 14) {
                    paperSection
                    marginSection
                    textSection
                }
                .frame(width: 420, alignment: .leading)
                VStack(spacing: 10) {
                    PagePreview(setup: setup)
                        .frame(width: 150, height: 190)
                    Text(setup.summary)
                        .font(.system(size: 10.5))
                        .foregroundStyle(Theme.textTertiary)
                        .multilineTextAlignment(.center)
                        .frame(width: 160)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            templateSection
            HStack {
                Spacer()
                Button("Abbrechen") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Übernehmen") {
                    app.setPageSetup(document.id, setup)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(22)
        .frame(width: 660)
    }

    private var paperSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionTitle("Papier")
            HStack(spacing: 8) {
                Picker("", selection: Binding(
                    get: { setup.paper?.name ?? "" },
                    set: { name in
                        guard let paper = WriterPageSetup.papers.first(where: { $0.name == name }) else { return }
                        let landscape = setup.isLandscape
                        setup.paperWidth = landscape ? paper.height : paper.width
                        setup.paperHeight = landscape ? paper.width : paper.height
                    }
                )) {
                    ForEach(WriterPageSetup.papers) { paper in
                        Text("\(paper.name)  ·  \(WriterPageSetup.mm(paper.width)) × \(WriterPageSetup.mm(paper.height)) mm").tag(paper.name)
                    }
                    if setup.paper == nil { Text("Eigene Größe").tag("") }
                }
                .labelsHidden()
                Picker("", selection: Binding(
                    get: { setup.isLandscape },
                    set: { landscape in
                        guard landscape != setup.isLandscape else { return }
                        (setup.paperWidth, setup.paperHeight) = (setup.paperHeight, setup.paperWidth)
                    }
                )) {
                    Image(systemName: "rectangle.portrait").tag(false).help("Hochformat")
                    Image(systemName: "rectangle").tag(true).help("Querformat")
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 84)
            }
            HStack(spacing: 10) {
                MillimetreField(label: "Breite", value: $setup.paperWidth, range: WriterPageSetup.paperRange)
                MillimetreField(label: "Höhe", value: $setup.paperHeight, range: WriterPageSetup.paperRange)
            }
        }
    }

    private var marginSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                sectionTitle("Ränder")
                Spacer()
                Toggle("Alle gleich", isOn: $sameMargins)
                    .toggleStyle(.checkbox)
                    .font(.system(size: 12))
                    .onChange(of: sameMargins) { _, same in
                        if same { setMargins(setup.top) }
                    }
            }
            if sameMargins {
                MillimetreField(label: "Rand", value: Binding(get: { setup.top }, set: { setMargins($0) }), range: WriterPageSetup.marginRange)
            } else {
                Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 6) {
                    GridRow {
                        MillimetreField(label: "Oben", value: $setup.top, range: WriterPageSetup.marginRange)
                        MillimetreField(label: "Unten", value: $setup.bottom, range: WriterPageSetup.marginRange)
                    }
                    GridRow {
                        MillimetreField(label: "Links", value: $setup.left, range: WriterPageSetup.marginRange)
                        MillimetreField(label: "Rechts", value: $setup.right, range: WriterPageSetup.marginRange)
                    }
                }
            }
            Text("Kopf- und Fußzeile stehen in den Rändern oben und unten.")
                .font(.system(size: 10.5))
                .foregroundStyle(Theme.textTertiary)
        }
    }

    private var textSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionTitle("Text")
            HStack(spacing: 8) {
                Text("Größe")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.textSecondary)
                    .fixedSize()
                Picker("", selection: $setup.fontSize) {
                    ForEach([9.0, 10, 10.5, 11, 12, 13, 14], id: \.self) { size in
                        Text("\(WriterSpanStyle.format(size).replacingOccurrences(of: ".", with: ",")) pt").tag(size)
                    }
                }
                .labelsHidden()
                .fixedSize()
                Spacer(minLength: 16)
                Text("Zeilenabstand")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.textSecondary)
                    .fixedSize()
                Picker("", selection: $setup.lineSpacing) {
                    ForEach(WriterParagraphFormat.lineSpacingSteps.prefix(4), id: \.value) { step in
                        Text(step.label).tag(step.value)
                    }
                }
                .labelsHidden()
                .fixedSize()
            }
        }
    }

    private var templateSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionTitle("Vorlage")
            HStack(spacing: 8) {
                TextField("Name des Formats", text: $setup.name)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 220)
                Button("In der Bibliothek sichern") { app.savePageTemplate(setup) }
                    .help("Das Format steht dann im Seitenformat-Menü jedes Dokuments dieser Bibliothek.")
                    .disabled(setup.name.trimmingCharacters(in: .whitespaces).isEmpty)
                Spacer()
                if !app.writerPageTemplates.isEmpty {
                    Menu("Laden") {
                        ForEach(app.writerPageTemplates) { template in
                            Button(template.name + "  ·  " + template.summary) {
                                setup = template
                                sameMargins = Set([template.top, template.bottom, template.left, template.right]).count == 1
                            }
                        }
                        Divider()
                        Menu("Vorlage löschen") {
                            ForEach(app.writerPageTemplates) { template in
                                Button(template.name) { app.deletePageTemplate(template.id) }
                            }
                        }
                    }
                    .fixedSize()
                }
            }
        }
    }

    private func setMargins(_ value: Double) {
        setup.top = value
        setup.bottom = value
        setup.left = value
        setup.right = value
    }
}

/// A number of millimetres with a label and arrows, shown in centimetres when that reads better.
private struct MillimetreField: View {
    let label: String
    @Binding var value: Double
    let range: ClosedRange<Double>

    var body: some View {
        HStack(spacing: 6) {
            Text(label)
                .font(.system(size: 12))
                .foregroundStyle(Theme.textSecondary)
                .frame(width: 46, alignment: .leading)
                .fixedSize()
            TextField("", value: Binding(get: { value }, set: { value = min(max($0, range.lowerBound), range.upperBound) }),
                      format: .number.precision(.fractionLength(0...1)).locale(Locale(identifier: "de_DE")))
                .textFieldStyle(.roundedBorder)
                .multilineTextAlignment(.trailing)
                .frame(width: 62)
            Stepper("", value: $value, in: range, step: 1)
                .labelsHidden()
            Text("mm")
                .font(.system(size: 11))
                .foregroundStyle(Theme.textTertiary)
                .fixedSize()
        }
    }
}

/// A sheet in its proportions with the text block inside its margins.
private struct PagePreview: View {
    let setup: WriterPageSetup

    var body: some View {
        Canvas { context, size in
            let scale = min(size.width / setup.paperWidth, size.height / setup.paperHeight)
            let sheet = CGRect(x: (size.width - setup.paperWidth * scale) / 2, y: (size.height - setup.paperHeight * scale) / 2,
                               width: setup.paperWidth * scale, height: setup.paperHeight * scale)
            context.fill(Path(roundedRect: sheet, cornerRadius: 2), with: .color(.white))
            let text = CGRect(x: sheet.minX + setup.left * scale, y: sheet.minY + setup.top * scale,
                              width: max(4, (setup.paperWidth - setup.left - setup.right) * scale),
                              height: max(4, (setup.paperHeight - setup.top - setup.bottom) * scale))
            // Lines of text at the size and spacing chosen.
            let distance = max(2.2, setup.fontSize * 1.2 * setup.lineSpacing * 0.3528 * scale)
            var y = text.minY + distance * 0.7
            var line = 0
            while y < text.maxY {
                let width = line % 7 == 6 ? text.width * 0.55 : text.width
                context.fill(Path(CGRect(x: text.minX, y: y, width: width, height: max(0.8, distance * 0.32))), with: .color(.black.opacity(0.22)))
                y += distance
                line += 1
            }
            context.stroke(Path(text), with: .color(Theme.accent.opacity(0.7)), style: StrokeStyle(lineWidth: 0.8, dash: [3, 2]))
        }
        .shadow(color: Theme.shade.opacity(0.35), radius: 6, y: 2)
    }
}

// MARK: Head and foot

/// The lines at the top and the bottom of the printed pages, each in three places, with placeholders for the page
/// number, the number of pages, the title, the chapter and the date.
struct RunningHeadsSheet: View {
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    let document: WriterDocument
    @State private var heads: WriterRunningHeads
    @FocusState private var focus: Place?

    enum Place: Hashable {
        case header(Int), footer(Int)
    }

    init(document: WriterDocument) {
        self.document = document
        _heads = State(initialValue: document.runningHeads ?? WriterRunningHeads())
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            header(symbol: "rectangle.topthird.inset.filled", title: "Kopf- und Fußzeile",
                   detail: "Was oben und unten auf jeder gedruckten Seite steht. Platzhalter füllen sich beim Druck mit Seitenzahl, Titel, Kapitel und Datum.")
            HStack(spacing: 8) {
                Menu("Vorlagen") {
                    ForEach(WriterRunningHeads.presets, id: \.label) { preset in
                        Button(preset.label) { heads = preset.heads }
                    }
                }
                .fixedSize()
                Spacer()
                Text("Einfügen:")
                    .font(.system(size: 11.5))
                    .foregroundStyle(Theme.textTertiary)
                ForEach(WriterRunningHeads.placeholders, id: \.token) { placeholder in
                    Button(placeholder.label) { insert(placeholder.token) }
                        .controlSize(.small)
                        .help("\(placeholder.token) an der Stelle mit dem Cursor einfügen")
                }
            }
            lineEditor(title: "Kopfzeile", line: $heads.header, place: Place.header)
            lineEditor(title: "Fußzeile", line: $heads.footer, place: Place.footer)
            VStack(alignment: .leading, spacing: 6) {
                Toggle("Erste Seite ohne Kopf- und Fußzeile (Titelseite)", isOn: $heads.skipsFirstPage)
                Toggle("Dünne Linie unter der Kopfzeile und über der Fußzeile", isOn: $heads.hasRules)
            }
            .toggleStyle(.checkbox)
            .font(.system(size: 12.5))
            HStack {
                Button("Entfernen", role: .destructive) {
                    app.setRunningHeads(document.id, nil)
                    dismiss()
                }
                .disabled(document.runningHeads == nil)
                .help("Ohne eigene Kopf- und Fußzeile steht die Seitenzahl unten in der Mitte.")
                Spacer()
                Button("Abbrechen") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Übernehmen") {
                    app.setRunningHeads(document.id, heads)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(22)
        .frame(width: 600)
    }

    private func lineEditor(title: String, line: Binding<WriterRunningHeads.Line>, place: (Int) -> Place) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            sectionTitle(title)
            HStack(spacing: 8) {
                field("Links", line.left, place(0), alignment: .leading)
                field("Mitte", line.center, place(1), alignment: .center)
                field("Rechts", line.right, place(2), alignment: .trailing)
            }
            Text(preview(line.wrappedValue))
                .font(.system(size: 11))
                .foregroundStyle(Theme.textTertiary)
                .lineLimit(1)
        }
    }

    private func field(_ prompt: String, _ text: Binding<String>, _ place: Place, alignment: TextAlignment) -> some View {
        TextField(prompt, text: text)
            .textFieldStyle(.roundedBorder)
            .multilineTextAlignment(alignment)
            .focused($focus, equals: place)
    }

    /// How the line reads on the first page.
    private func preview(_ line: WriterRunningHeads.Line) -> String {
        guard !line.isEmpty else { return "Leer" }
        let parts = [line.left, line.center, line.right].map {
            WriterRunningHeads.resolve($0, page: 1, pages: 12, title: document.displayTitle, chapter: "Erstes Kapitel")
        }
        return "Seite 1 von 12: " + parts.map { $0.isEmpty ? "–" : $0 }.joined(separator: "   |   ")
    }

    /// Adds a placeholder to the field with the cursor (the centre of the foot when none has it).
    private func insert(_ token: String) {
        let place = focus ?? .footer(1)
        func add(_ text: inout String) { text += (text.isEmpty || text.hasSuffix(" ") ? "" : " ") + token }
        switch place {
        case .header(0): add(&heads.header.left)
        case .header(1): add(&heads.header.center)
        case .header(_): add(&heads.header.right)
        case .footer(0): add(&heads.footer.left)
        case .footer(1): add(&heads.footer.center)
        case .footer(_): add(&heads.footer.right)
        }
        focus = place
    }
}

// MARK: Shared

private func header(symbol: String, title: String, detail: String) -> some View {
    HStack(spacing: 10) {
        Image(systemName: symbol)
            .font(.system(size: 20, weight: .medium))
            .foregroundStyle(Theme.accent)
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(Theme.textPrimary)
            Text(detail)
                .font(.system(size: 12))
                .foregroundStyle(Theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

private func sectionTitle(_ text: String) -> some View {
    Text(text)
        .font(.system(size: 11, weight: .semibold))
        .foregroundStyle(Theme.textTertiary)
        .textCase(.uppercase)
}
