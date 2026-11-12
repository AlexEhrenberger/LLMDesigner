import SwiftUI
import UniformTypeIdentifiers

// MARK: - Templates tab

struct DataTemplatesTab: View {
    @Environment(AppModel.self) private var app
    @Bindable var model: DataStudioModel

    var body: some View {
        let studio = app.dataStudio
        HStack(spacing: 0) {
            TemplateList(model: model)
                .frame(width: 270)
            Rectangle().fill(Theme.border).frame(width: 1)
            Group {
                if let id = model.templateID, let template = studio.template(id) {
                    if template.kind == .writer {
                        WriterTemplatePage(templateID: id, model: model).id(id)
                    } else {
                        MasterTemplatePage(templateID: id, model: model).id(id)
                    }
                } else {
                    Text("Wähle links eine Vorlage.")
                        .font(.system(size: 13))
                        .foregroundStyle(Theme.textTertiary)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

private struct TemplateList: View {
    @Environment(AppModel.self) private var app
    @Environment(\.undoManager) private var undoManager
    @Bindable var model: DataStudioModel

    var body: some View {
        let all = app.dataStudio.allTemplates.filter { $0.matches(model.query) }
        VStack(spacing: 0) {
            SearchField(text: $model.query, prompt: "Vorlagen durchsuchen")
                .padding(.horizontal, 10)
                .padding(.bottom, 6)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 1) {
                    ForEach(DataTemplate.Kind.allCases) { kind in
                        let members = all.filter { $0.kind == kind }
                        StudioSectionHeader(title: kind.plural, symbol: kind.symbol, count: members.count)
                        ForEach(members) { template in
                            StudioListRow(symbol: template.symbol, title: template.displayName,
                                          subtitle: template.isBuiltIn ? "Mitgeliefert" : template.slots.map(\.name).joined(separator: ", "),
                                          trailing: template.isBuiltIn ? "🔒" : nil, isSelected: model.templateID == template.id) {
                                model.templateID = template.id
                            }
                            .contextMenu {
                                Button(template.kind == .writer ? "Dokument erstellen …" : "Präsentation erstellen …", systemImage: "plus") {
                                    app.templateUseRequest = template.id
                                }
                                Button(template.isBuiltIn ? "Kopie zum Anpassen" : "Duplizieren", systemImage: "plus.square.on.square") {
                                    model.templateID = app.duplicateTemplate(template.id)?.id
                                }
                                if !template.isBuiltIn {
                                    Divider()
                                    Button("Löschen", systemImage: "trash", role: .destructive) {
                                        app.dataStudio.templates.delete(template.id, label: "Vorlage löschen", undo: undoManager)
                                        if model.templateID == template.id { model.templateID = app.dataStudio.allTemplates.first?.id }
                                    }
                                }
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
}

/// The head of a template page: name, description, what it is for, and its main buttons.
private struct TemplateHeader: View {
    @Environment(AppModel.self) private var app
    let templateID: UUID
    let model: DataStudioModel

    var body: some View {
        if let template = app.dataStudio.template(templateID) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .top, spacing: 14) {
                    Image(systemName: template.symbol)
                        .font(.system(size: 22, weight: .medium))
                        .foregroundStyle(Theme.accent)
                        .frame(width: 52, height: 52)
                        .background(RoundedRectangle(cornerRadius: 13, style: .continuous).fill(Theme.accent.opacity(0.14)))
                    VStack(alignment: .leading, spacing: 4) {
                        if template.isBuiltIn {
                            Text(template.displayName).font(.system(size: 22, weight: .semibold))
                        } else {
                            TextField("Name der Vorlage", text: templateBinding(\.name))
                                .textFieldStyle(.plain)
                                .font(.system(size: 22, weight: .semibold))
                        }
                        Text(template.kind.label + (template.isBuiltIn ? " · mitgeliefert, zum Ändern eine Kopie anlegen" : ""))
                            .font(.system(size: 12))
                            .foregroundStyle(Theme.textTertiary)
                    }
                    Spacer(minLength: 0)
                    VStack(alignment: .trailing, spacing: 6) {
                        Button {
                            app.templateUseRequest = templateID
                        } label: {
                            Label(template.kind == .writer ? "Dokument erstellen" : "Präsentation erstellen", systemImage: "plus")
                        }
                        .buttonStyle(.borderedProminent)
                        Button {
                            model.templateID = app.duplicateTemplate(templateID)?.id
                        } label: {
                            Label(template.isBuiltIn ? "Kopie zum Anpassen" : "Duplizieren", systemImage: "plus.square.on.square")
                                .font(.system(size: 12))
                        }
                        .buttonStyle(.borderless)
                    }
                }
                if template.isBuiltIn {
                    Text(template.summary).font(.system(size: 12.5)).foregroundStyle(Theme.textSecondary)
                } else {
                    StoryTextEditor(placeholder: "Wofür diese Vorlage gedacht ist …", text: templateBinding(\.summary), minLines: 1)
                }
            }
        }
    }

    private func templateBinding<T>(_ keyPath: WritableKeyPath<DataTemplate, T>) -> Binding<T> {
        Binding(get: { app.dataStudio.template(templateID)![keyPath: keyPath] },
                set: { value in app.dataStudio.templates.update(templateID) { $0[keyPath: keyPath] = value } })
    }
}

/// The roles a template's text names, each to be filled by a data block when it is used.
private struct TemplateSlotsCard: View {
    @Environment(AppModel.self) private var app
    let templateID: UUID

    var body: some View {
        if let template = app.dataStudio.template(templateID) {
            StudioCard(title: "Rollen", symbol: "person.2", trailing: template.isBuiltIn ? nil : AnyView(addButton)) {
                Text("Eine Rolle steht im Text als {{rolle.feld}}. Beim Erstellen wählst du für jede Rolle einen Datenblock – aus {{absender.strasse}} wird dann z. B. {{user1.strasse}}.")
                    .font(.system(size: 11.5))
                    .foregroundStyle(Theme.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
                ForEach(Array(template.slots.enumerated()), id: \.offset) { index, slot in
                    HStack(spacing: 10) {
                        Text("{{\(slot.key)}}")
                            .font(.system(size: 12, design: .monospaced))
                            .foregroundStyle(Theme.accent)
                            .frame(width: 150, alignment: .leading)
                        if template.isBuiltIn {
                            Text(slot.name).font(.system(size: 12.5))
                            Text(slot.structure.label).font(.system(size: 11.5)).foregroundStyle(Theme.textTertiary)
                        } else {
                            StudioField(placeholder: "Name", text: Binding(get: { slot.name }, set: { name in
                                app.dataStudio.templates.update(templateID) { if index < $0.slots.count { $0.slots[index].name = name } }
                            }))
                            .frame(width: 160)
                            Picker("", selection: Binding(get: { slot.structure }, set: { structure in
                                app.dataStudio.templates.update(templateID) { if index < $0.slots.count { $0.slots[index].structure = structure } }
                            })) {
                                ForEach(DataStructure.allCases) { Text($0.label).tag($0) }
                            }
                            .labelsHidden()
                            .frame(width: 160)
                            IconButton(systemName: "minus.circle", help: "Rolle entfernen", size: 11, frameSize: 22) {
                                app.dataStudio.templates.update(templateID) { if index < $0.slots.count { $0.slots.remove(at: index) } }
                            }
                        }
                        Spacer(minLength: 0)
                    }
                }
                let unknown = template.referencedKeys.filter { key in !template.slots.contains { $0.key == key } && !DataKey.reserved.contains(key) }
                if !unknown.isEmpty {
                    Text("Feste Datenblöcke im Text: " + unknown.map { "{{\($0)}}" }.joined(separator: ", "))
                        .font(.system(size: 11.5))
                        .foregroundStyle(Theme.textSecondary)
                }
            }
        }
    }

    private var addButton: some View {
        Button {
            app.dataStudio.templates.update(templateID) { template in
                let key = DataKey.unique("rolle", taken: Set(template.slots.map(\.key)))
                template.slots.append(TemplateSlot(key: key, name: "Rolle", structure: .person))
            }
        } label: {
            Label("Rolle", systemImage: "plus").font(.system(size: 12, weight: .medium))
        }
        .buttonStyle(.borderless)
    }
}

// MARK: - Writer template

private struct WriterTemplatePage: View {
    @Environment(AppModel.self) private var app
    let templateID: UUID
    let model: DataStudioModel

    var body: some View {
        if let template = app.dataStudio.template(templateID) {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    TemplateHeader(templateID: templateID, model: model)
                    TemplateSlotsCard(templateID: templateID)
                    StudioCard(title: "Seite", symbol: "doc") {
                        HStack(spacing: 14) {
                            Picker("Format", selection: binding(\.pageFormat, default: WriterPageFormat.standard.rawValue)) {
                                ForEach(WriterPageFormat.builtIn) { Text($0.label).tag($0.rawValue) }
                            }
                            .frame(width: 240)
                            .disabled(template.isBuiltIn)
                            Picker("Schrift", selection: binding(\.font, default: WriterFont.serif.rawValue)) {
                                ForEach(WriterFont.allCases) { Text($0.label).tag($0.rawValue) }
                            }
                            .frame(width: 240)
                            .disabled(template.isBuiltIn)
                        }
                    }
                    StudioCard(title: "Text der Vorlage", symbol: "text.alignleft", trailing: AnyView(insertMenu(template))) {
                        Text("Markdown wie in Writer Studio. Felder als {{rolle.feld}} oder {{kürzel.feld}}, {{heute}} für das Datum. Im erstellten Dokument erscheinen die Werte.")
                            .font(.system(size: 11.5))
                            .foregroundStyle(Theme.textTertiary)
                        if template.isBuiltIn {
                            Text(template.markdown)
                                .font(.system(size: 12, design: .monospaced))
                                .foregroundStyle(Theme.textSecondary)
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(10)
                                .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Theme.ink.opacity(0.04)))
                        } else {
                            StoryTextEditor(placeholder: "Text …", text: binding(\.markdown, default: ""), minLines: 12,
                                            font: .monospacedSystemFont(ofSize: 12, weight: .regular))
                                .padding(8)
                                .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Theme.ink.opacity(0.04)))
                        }
                    }
                }
                .padding(.horizontal, 28)
                .padding(.vertical, 18)
                .frame(maxWidth: 980, alignment: .leading)
                .frame(maxWidth: .infinity)
            }
        }
    }

    private func binding(_ keyPath: WritableKeyPath<DataTemplate, String?>, default fallback: String) -> Binding<String> {
        Binding(get: { app.dataStudio.template(templateID)?[keyPath: keyPath] ?? fallback },
                set: { value in app.dataStudio.templates.update(templateID) { $0[keyPath: keyPath] = value } })
    }

    private func binding(_ keyPath: WritableKeyPath<DataTemplate, String>, default fallback: String) -> Binding<String> {
        Binding(get: { app.dataStudio.template(templateID)?[keyPath: keyPath] ?? fallback },
                set: { value in app.dataStudio.templates.update(templateID) { $0[keyPath: keyPath] = value } })
    }

    @ViewBuilder private func insertMenu(_ template: DataTemplate) -> some View {
        if !template.isBuiltIn {
            DataTokenMenu { token in app.dataStudio.templates.update(templateID) { $0.markdown += token } }
        }
    }
}

/// A menu of placeholders: the template's roles, the blocks, today's date.
struct DataTokenMenu: View {
    @Environment(AppModel.self) private var app
    var extras: [(String, String)] = []
    let insert: (String) -> Void

    var body: some View {
        Menu {
            Button("Heutiges Datum {{heute}}") { insert("{{heute}}") }
            ForEach(extras, id: \.0) { extra in Button("\(extra.1) \(extra.0)") { insert(extra.0) } }
            Divider()
            ForEach(app.dataStudio.blocks.records) { block in
                Menu(block.displayName) {
                    Button("Ganzer Block {{\(block.key)}}") { insert(DataRef(block: block.key).token) }
                    Divider()
                    ForEach(block.fields) { field in
                        Button("\(field.name) {{\(block.key).\(field.key)}}") { insert(DataRef(block: block.key, field: field.key).token) }
                    }
                }
            }
        } label: {
            Label("Feld einfügen", systemImage: "curlybraces")
                .font(.system(size: 12, weight: .medium))
        }
        .menuStyle(.button)
        .buttonStyle(.borderless)
        .fixedSize()
    }
}

// MARK: - Master template

private struct MasterTemplatePage: View {
    @Environment(AppModel.self) private var app
    let templateID: UUID
    let model: DataStudioModel
    @State private var logoError: String?

    var body: some View {
        if let template = app.dataStudio.template(templateID) {
            let locked = template.isBuiltIn
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    TemplateHeader(templateID: templateID, model: model)
                    HStack(alignment: .top, spacing: 16) {
                        VStack(alignment: .leading, spacing: 16) {
                            StudioCard(title: "Logo", symbol: "seal") {
                                HStack(spacing: 10) {
                                    if let url = app.dataStudio.logoURL(of: template), let image = NSImage(contentsOf: url) {
                                        Image(nsImage: image).resizable().scaledToFit().frame(width: 90, height: 50)
                                            .background(RoundedRectangle(cornerRadius: 6).fill(Theme.ink.opacity(0.05)))
                                        Button("Entfernen") { app.removeTemplateLogo(templateID) }.disabled(locked)
                                    }
                                    Button(template.master.logo == nil ? "Logo wählen …" : "Anderes Logo …") { chooseLogo() }
                                        .disabled(locked)
                                }
                                if let logoError { Text(logoError).font(.system(size: 11.5)).foregroundStyle(Theme.danger) }
                                Picker("Ecke", selection: masterBinding(\.logoCorner)) {
                                    ForEach(SlideMaster.Corner.allCases) { Text($0.label).tag($0) }
                                }
                                .disabled(locked)
                                HStack {
                                    Text("Größe").font(.system(size: 12))
                                    Slider(value: masterBinding(\.logoSize), in: 0.05...0.3)
                                        .disabled(locked)
                                    Text("\(Int(template.master.logoSize * 100)) %").font(.system(size: 11).monospacedDigit()).foregroundStyle(Theme.textTertiary)
                                }
                            }
                            StudioCard(title: "Kopf- und Fußzeile", symbol: "text.line.first.and.arrowtriangle.forward",
                                       trailing: locked ? nil : AnyView(DataTokenMenu(extras: [("{{titel}}", "Titel der Präsentation"), ("{{folie}}", "Foliennummer"), ("{{folien}}", "Folienzahl")]) { token in
                                           app.dataStudio.templates.update(templateID) { $0.master.footer += token }
                                       })) {
                                VStack(alignment: .leading, spacing: 6) {
                                    Text("Kopfzeile").font(.system(size: 11.5)).foregroundStyle(Theme.textTertiary)
                                    StudioField(placeholder: "z. B. {{firma.firma}}", text: masterBinding(\.header)).disabled(locked)
                                    Text("Fußzeile").font(.system(size: 11.5)).foregroundStyle(Theme.textTertiary)
                                    StudioField(placeholder: "z. B. {{titel}} · {{heute.kurz}}", text: masterBinding(\.footer)).disabled(locked)
                                }
                                Toggle("Seitenzahlen", isOn: masterBinding(\.pageNumbers)).disabled(locked)
                                Toggle("Linie über der Fußzeile", isOn: masterBinding(\.rule)).disabled(locked)
                                Toggle("Auch auf der Titelfolie", isOn: masterBinding(\.onTitle)).disabled(locked)
                            }
                            StudioCard(title: "Design", symbol: "paintpalette") {
                                Text(template.backgrounds == nil ? "Die Präsentation behält ihr eigenes Design." : "Neue Präsentationen bekommen das Design der Vorlage.")
                                    .font(.system(size: 12)).foregroundStyle(Theme.textSecondary)
                                Menu("Design aus einer Präsentation übernehmen") {
                                    ForEach(app.documents.filter(\.isPresentation).prefix(30)) { document in
                                        Button(document.displayTitle) {
                                            app.dataStudio.templates.update(templateID) { $0.backgrounds = document.deck?.backgrounds }
                                        }
                                    }
                                }
                                .disabled(locked)
                                if template.backgrounds != nil, !locked {
                                    Button("Design der Vorlage entfernen") { app.dataStudio.templates.update(templateID) { $0.backgrounds = nil } }
                                        .buttonStyle(.borderless)
                                }
                            }
                        }
                        .frame(width: 360)
                        VStack(alignment: .leading, spacing: 10) {
                            Text("VORSCHAU").font(.system(size: 10, weight: .semibold)).tracking(0.5).foregroundStyle(Theme.textTertiary)
                            MasterPreview(template: template, role: .title)
                            MasterPreview(template: template, role: .content)
                            if let document = app.dataStudioSourceDocument, document.isPresentation {
                                Button("Auf „\(document.displayTitle)“ anwenden") { app.applyMaster(templateID, to: document.id, design: template.backgrounds != nil) }
                            }
                        }
                        .frame(maxWidth: .infinity)
                    }
                }
                .padding(.horizontal, 28)
                .padding(.vertical, 18)
                .frame(maxWidth: 1100, alignment: .leading)
                .frame(maxWidth: .infinity)
            }
        }
    }

    private func masterBinding<T>(_ keyPath: WritableKeyPath<SlideMaster, T>) -> Binding<T> {
        Binding(get: { app.dataStudio.template(templateID)!.master[keyPath: keyPath] },
                set: { value in app.dataStudio.templates.update(templateID) { $0.master[keyPath: keyPath] = value } })
    }

    private func chooseLogo() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.png, .jpeg, .tiff, .heic, .image]
        panel.allowsMultipleSelection = false
        panel.message = "Logo für die Masterfolie"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try app.setTemplateLogo(templateID, from: url)
            logoError = nil
        } catch {
            logoError = error.localizedDescription
        }
    }
}

/// A sample slide with the master on it.
private struct MasterPreview: View {
    @Environment(AppModel.self) private var app
    let template: DataTemplate
    let role: SlideRole

    var body: some View {
        var deck = PresentationDeck(slides: [PresentationSlide(role: .title, markdown: "# Titel der Präsentation"),
                                             PresentationSlide(role: .content, markdown: "## Eine Inhaltsfolie\n\n- Erster Punkt\n- Zweiter Punkt")])
        if let backgrounds = template.backgrounds { deck.backgrounds = backgrounds }
        deck.masterID = template.id
        let slide = deck.slides[role == .title ? 0 : 1]
        let _ = app.dataStudio.templates.revision
        return ZStack {
            SlideBackgroundView(background: deck.background(of: slide), role: slide.role)
            SlideTextView(markdown: slide.markdown, family: .sans, palette: SlideLook.palette(deck.background(of: slide), role: slide.role),
                          layout: WriterTextView.SlideLayout(slide: slide), citations: nil)
            SlideMasterLayer(deck: deck, slide: slide, title: "Titel der Präsentation")
        }
        .aspectRatio(16 / 9, contentMode: .fit)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Theme.border))
        .overlay(alignment: .topLeading) {
            Text(role == .title ? (template.master.onTitle ? "Titelfolie" : "Titelfolie (ohne Master)") : "Inhaltsfolie")
                .font(.system(size: 10, weight: .semibold))
                .padding(.horizontal, 6).padding(.vertical, 2)
                .background(Capsule().fill(.black.opacity(0.55)))
                .foregroundStyle(.white)
                .padding(6)
        }
    }
}

// MARK: - Using a template

/// Choosing a data block for each role, a title, then the document or presentation is made and opened.
struct TemplateUseSheet: View {
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    let templateID: UUID
    @State private var title = ""
    @State private var choices: [String: String] = [:]

    var body: some View {
        let studio = app.dataStudio
        if let template = studio.template(templateID) {
            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 10) {
                    Image(systemName: template.symbol).font(.system(size: 18)).foregroundStyle(Theme.accent)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(template.displayName).font(.system(size: 15, weight: .semibold))
                        Text(template.kind == .writer ? "Neues Dokument aus der Vorlage" : "Neue Präsentation mit diesem Master")
                            .font(.system(size: 12)).foregroundStyle(Theme.textTertiary)
                    }
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text("Titel").font(.system(size: 11.5)).foregroundStyle(Theme.textTertiary)
                    StudioField(placeholder: template.displayName, text: $title)
                }
                if !template.slots.isEmpty {
                    Text("Datenblöcke").font(.system(size: 11.5)).foregroundStyle(Theme.textTertiary)
                    ForEach(template.slots) { slot in
                        HStack(spacing: 10) {
                            Text(slot.name).font(.system(size: 13, weight: .medium)).frame(width: 110, alignment: .leading)
                            Picker("", selection: Binding(get: { choices[slot.key] ?? "" }, set: { choices[slot.key] = $0 })) {
                                Text("Offen lassen").tag("")
                                ForEach(studio.blocks.records) { block in
                                    Text("\(block.displayName)  {{\(block.key)}}").tag(block.key)
                                }
                            }
                            .labelsHidden()
                            Button {
                                let block = app.newDataBlock(slot.structure, name: slot.name)
                                choices[slot.key] = block.key
                            } label: {
                                Image(systemName: "plus")
                            }
                            .help("Neuen Datenblock „\(slot.name)“ (\(slot.structure.label)) anlegen; ausfüllen kannst du ihn danach in Data Studio")
                        }
                    }
                    Text("Die Felder bleiben verknüpft: Änderst du den Datenblock in Data Studio, ändert sich das Dokument mit.")
                        .font(.system(size: 11.5)).foregroundStyle(Theme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                HStack {
                    Spacer()
                    Button("Abbrechen") { dismiss() }
                        .keyboardShortcut(.cancelAction)
                    Button(template.kind == .writer ? "Dokument erstellen" : "Präsentation erstellen") {
                        let name = title.trimmingCharacters(in: .whitespaces)
                        let chosen = choices.filter { !$0.value.isEmpty }
                        dismiss()
                        if template.kind == .writer {
                            app.createDocument(from: templateID, choices: chosen, title: name.isEmpty ? nil : name)
                        } else {
                            app.createPresentation(from: templateID, choices: chosen, title: name.isEmpty ? nil : name)
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                }
            }
            .padding(20)
            .frame(width: 520)
            .onAppear {
                studio.loadIfNeeded()
                for slot in template.slots where choices[slot.key] == nil {
                    choices[slot.key] = app.suggestedBlock(for: slot)?.key ?? ""
                }
            }
        }
    }
}
