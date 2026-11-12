import SwiftUI
import UniformTypeIdentifiers

/// What Data Studio shows.
@MainActor
@Observable
final class DataStudioModel {
    var tab: DataStudioTab = .blocks
    var blockID: UUID?
    var templateID: UUID?
    var query = ""
    /// The blocks of one group as a table, like a database.
    var showsTable = false
}

/// Data Studio: data blocks whose fields go into documents, presentations, notes and projects as `{{…}}`, and the
/// templates (letters, CVs, presentation masters) that use them.
struct DataStudioScreen: View {
    @Environment(AppModel.self) private var app
    @State private var model = DataStudioModel()

    var body: some View {
        let studio = app.dataStudio
        VStack(spacing: 0) {
            StudioTopBar(symbol: StudioApplication.data.symbol, title: "Data Studio", detail: detail, close: { app.closeDataStudio() }) {
                StudioTabPicker(tabs: DataStudioTab.allCases, selection: $model.tab, title: \.title, symbol: \.symbol) { tab in
                    tab == .blocks ? studio.blocks.records.count : studio.allTemplates.count
                }
            } trailing: {
                NewDataMenu(model: model)
                PowerButton()
            }
            switch model.tab {
            case .blocks: DataBlocksTab(model: model)
            case .templates: DataTemplatesTab(model: model)
            }
        }
        .background(Theme.background)
        .onAppear {
            studio.loadIfNeeded()
            if model.blockID == nil { model.blockID = studio.blocks.records.first?.id }
            if model.templateID == nil { model.templateID = studio.allTemplates.first?.id }
            take(app.dataStudioCommand)
        }
        .onChange(of: app.dataStudioCommand) { _, command in take(command) }
    }

    private var detail: String {
        let blocks = app.dataStudio.blocks.records
        let fields = blocks.reduce(0) { $0 + $1.fields.count }
        return "\(blocks.count) \(blocks.count == 1 ? "Datenblock" : "Datenblöcke") · \(fields) Felder · \(app.dataStudio.allTemplates.count) Vorlagen"
    }

    private func take(_ command: DataStudioCommand?) {
        guard let command else { return }
        if let tab = command.tab { model.tab = tab }
        if let block = command.block { model.blockID = block; model.tab = .blocks; model.showsTable = false }
        if let template = command.template { model.templateID = template; model.tab = .templates }
        app.dataStudioCommand = nil
    }
}

private struct NewDataMenu: View {
    @Environment(AppModel.self) private var app
    @Environment(\.undoManager) private var undoManager
    let model: DataStudioModel

    var body: some View {
        IconMenu(systemName: "plus", help: "Neuer Datenblock oder neue Vorlage", frameSize: Theme.titleBarControlSize) {
            Section("Neuer Datenblock") {
                ForEach(DataStructure.allCases) { structure in
                    Button(structure.label, systemImage: structure.symbol) {
                        model.query = ""
                        model.tab = .blocks
                        model.showsTable = false
                        model.blockID = app.newDataBlock(structure, undo: undoManager).id
                    }
                }
            }
            Section("Neue Vorlage") {
                Button("Dokumentvorlage (Writer)", systemImage: DataTemplate.Kind.writer.symbol) {
                    var template = DataTemplate(name: "Neue Dokumentvorlage", kind: .writer)
                    template.createdAt = Date()
                    template.markdown = "# Titel\n\nSehr geehrte/r {{empfaenger.nachname}},\n\n…\n"
                    template.slots = [TemplateSlot(key: "empfaenger", name: "Empfänger", structure: .person)]
                    model.tab = .templates
                    model.templateID = app.dataStudio.templates.add(template).id
                }
                Button("Masterfolie (Presenter)", systemImage: DataTemplate.Kind.presenter.symbol) {
                    var template = DataTemplate(name: "Neue Masterfolie", kind: .presenter)
                    template.createdAt = Date()
                    template.symbol = "rectangle.on.rectangle"
                    template.master.footer = "{{titel}}"
                    model.tab = .templates
                    model.templateID = app.dataStudio.templates.add(template).id
                }
                if let document = app.dataStudioSourceDocument {
                    Button("Aus „\(document.displayTitle)“", systemImage: "square.and.arrow.down.on.square") {
                        model.tab = .templates
                        model.templateID = app.saveAsTemplate(document.id)?.id
                    }
                }
            }
        }
    }
}

// MARK: - Blocks

private struct DataBlocksTab: View {
    @Environment(AppModel.self) private var app
    @Environment(\.undoManager) private var undoManager
    @Bindable var model: DataStudioModel

    var body: some View {
        let studio = app.dataStudio
        if studio.blocks.records.isEmpty {
            StudioEmptyState(symbol: "tablecells", title: "Noch keine Datenblöcke",
                             text: "Ein Datenblock sammelt Angaben unter einem Namen, den du wählst – etwa „Absender“ mit deiner Anschrift oder „User 1“. In Writer, Presenter, Notes und Projekten setzt du seine Felder mit ⌥⌘D oder „/daten“ ein. Ändert sich etwas, änderst du es nur hier: Jedes Dokument zeigt sofort den neuen Wert.",
                             actionTitle: "Person anlegen") {
                model.blockID = app.newDataBlock(.person, undo: undoManager).id
            }
        } else {
            HStack(spacing: 0) {
                DataBlockList(model: model)
                    .frame(width: 270)
                Rectangle().fill(Theme.border).frame(width: 1)
                Group {
                    if model.showsTable {
                        DataTableView(model: model)
                    } else if let id = model.blockID, studio.block(id) != nil {
                        DataBlockPage(blockID: id, model: model)
                            .id(id)
                    } else {
                        Text("Wähle links einen Datenblock.")
                            .font(.system(size: 13))
                            .foregroundStyle(Theme.textTertiary)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }
}

private struct DataBlockList: View {
    @Environment(AppModel.self) private var app
    @Environment(\.undoManager) private var undoManager
    @Bindable var model: DataStudioModel

    var body: some View {
        let studio = app.dataStudio
        let shown = studio.blocks.records.filter { $0.matches(model.query) }
        VStack(spacing: 0) {
            SearchField(text: $model.query, prompt: "Datenblöcke und Werte durchsuchen")
                .padding(.horizontal, 10)
                .padding(.bottom, 6)
            HStack(spacing: 2) {
                modeButton("Einzeln", symbol: "rectangle.portrait", table: false)
                modeButton("Tabelle", symbol: "tablecells", table: true)
            }
            .padding(2)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Theme.ink.opacity(0.04)))
            .padding(.horizontal, 10)
            .padding(.bottom, 4)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 1) {
                    ForEach(studio.groups, id: \.self) { group in
                        let members = shown.filter { $0.group == group }
                        if !members.isEmpty {
                            StudioSectionHeader(title: group.isEmpty ? "Ohne Gruppe" : group, symbol: "folder", count: members.count)
                            ForEach(members) { block in
                                StudioListRow(symbol: block.symbol, color: Color(hex: block.color.hex), title: block.displayName,
                                              subtitle: "{{\(block.key)}} · " + block.composed.replacingOccurrences(of: "\n", with: ", "),
                                              isSelected: model.blockID == block.id && !model.showsTable) {
                                    model.blockID = block.id
                                    model.showsTable = false
                                }
                                .contextMenu {
                                    Button("Duplizieren", systemImage: "plus.square.on.square") { model.blockID = app.duplicateDataBlock(block.id)?.id }
                                    Button("Als Tabelle der Gruppe zeigen", systemImage: "tablecells") {
                                        model.blockID = block.id
                                        model.showsTable = true
                                    }
                                    Divider()
                                    Button("Löschen", systemImage: "trash", role: .destructive) {
                                        app.dataStudio.blocks.delete(block.id, label: "Datenblock löschen", undo: undoManager)
                                        if model.blockID == block.id { model.blockID = app.dataStudio.blocks.records.first?.id }
                                    }
                                }
                                .draggable(DataRef(block: block.key).token)
                            }
                        }
                    }
                    if shown.isEmpty {
                        Text("Nichts passt zur Suche.")
                            .font(.system(size: 12))
                            .foregroundStyle(Theme.textTertiary)
                            .padding(12)
                    }
                }
                .padding(.horizontal, 6)
                .padding(.bottom, 12)
            }
        }
        .background(Theme.sidebar.opacity(0.5))
    }

    private func modeButton(_ title: String, symbol: String, table: Bool) -> some View {
        let selected = model.showsTable == table
        return Button {
            model.showsTable = table
        } label: {
            Label(title, systemImage: symbol)
                .font(.system(size: 11.5, weight: .medium))
                .foregroundStyle(selected ? Theme.textPrimary : Theme.textTertiary)
                .frame(maxWidth: .infinity)
                .frame(height: 22)
                .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(selected ? Theme.selection : .clear))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// One block: its name and key, its fields with their values, how it shows as a whole, and where it is used.
private struct DataBlockPage: View {
    @Environment(AppModel.self) private var app
    @Environment(\.undoManager) private var undoManager
    let blockID: UUID
    let model: DataStudioModel
    @State private var renamingKey = false
    @State private var draggedField: UUID?

    var body: some View {
        let studio = app.dataStudio
        if let block = studio.block(blockID) {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    header(block)
                    StudioCard(title: "Felder", symbol: "list.bullet.rectangle", trailing: AnyView(addFieldMenu)) {
                        VStack(spacing: 0) {
                            HStack(spacing: 8) {
                                Text("Feld").frame(width: 170, alignment: .leading)
                                Text("Wert").frame(maxWidth: .infinity, alignment: .leading)
                                Text("Platzhalter").frame(width: 190, alignment: .leading)
                                Color.clear.frame(width: 48)
                            }
                            .font(.system(size: 10.5, weight: .semibold))
                            .foregroundStyle(Theme.textTertiary)
                            .padding(.bottom, 6)
                            ForEach(block.fields) { field in
                                DataFieldRow(blockID: blockID, field: field, blockKey: block.key)
                                    .onDrag {
                                        draggedField = field.id
                                        return NSItemProvider(object: DataRef(block: block.key, field: field.key).token as NSString)
                                    }
                                    .onDrop(of: [.text], delegate: FieldDropDelegate(target: field.id, dragged: $draggedField) { from, to in
                                        app.dataStudio.blocks.update(blockID) { block in
                                            guard let fromIndex = block.fields.firstIndex(where: { $0.id == from }),
                                                  let toIndex = block.fields.firstIndex(where: { $0.id == to }) else { return }
                                            let moved = block.fields.remove(at: fromIndex)
                                            block.fields.insert(moved, at: toIndex)
                                        }
                                    })
                                Divider().opacity(0.5)
                            }
                            if block.fields.isEmpty {
                                Text("Noch keine Felder. Füge oben rechts eines hinzu.")
                                    .font(.system(size: 12))
                                    .foregroundStyle(Theme.textTertiary)
                                    .padding(.vertical, 10)
                            }
                        }
                    }
                    displayCard(block)
                    usagesCard(block)
                    StudioCard(title: "Notiz", symbol: "text.alignleft") {
                        StoryTextEditor(placeholder: "Wofür dieser Datenblock gedacht ist …", text: binding(\.note), minLines: 2)
                    }
                }
                .padding(.horizontal, 28)
                .padding(.vertical, 18)
                .frame(maxWidth: 980, alignment: .leading)
                .frame(maxWidth: .infinity)
            }
        }
    }

    private func binding<T>(_ keyPath: WritableKeyPath<DataBlock, T>) -> Binding<T> {
        Binding(get: { app.dataStudio.block(blockID)![keyPath: keyPath] },
                set: { value in app.dataStudio.blocks.update(blockID) { $0[keyPath: keyPath] = value } })
    }

    private func header(_ block: DataBlock) -> some View {
        HStack(alignment: .top, spacing: 14) {
            Menu {
                ForEach(DataStructure.allCases) { structure in
                    Button(structure.label, systemImage: structure.symbol) { app.dataStudio.blocks.update(blockID) { $0.symbol = structure.symbol } }
                }
                Divider()
                ForEach(FolderColor.allCases, id: \.self) { color in
                    Button(color.name) { app.dataStudio.blocks.update(blockID) { $0.color = color } }
                }
            } label: {
                Image(systemName: block.symbol)
                    .font(.system(size: 22, weight: .medium))
                    .foregroundStyle(Color(hex: block.color.hex))
                    .frame(width: 52, height: 52)
                    .background(RoundedRectangle(cornerRadius: 13, style: .continuous).fill(Color(hex: block.color.hex).opacity(0.15)))
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("Symbol und Farbe")
            VStack(alignment: .leading, spacing: 6) {
                TextField("Name des Datenblocks", text: binding(\.name))
                    .textFieldStyle(.plain)
                    .font(.system(size: 22, weight: .semibold))
                HStack(spacing: 10) {
                    Button {
                        renamingKey = true
                    } label: {
                        HStack(spacing: 4) {
                            Text("{{\(block.key)}}")
                                .font(.system(size: 12, design: .monospaced))
                            Image(systemName: "pencil")
                                .font(.system(size: 10))
                        }
                        .foregroundStyle(Theme.accent)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 3)
                        .background(Capsule().fill(Theme.accent.opacity(0.12)))
                    }
                    .buttonStyle(.plain)
                    .help("Das Kürzel, mit dem Texte diesen Datenblock nennen")
                    .popover(isPresented: $renamingKey) { KeyRenamePopover(blockID: blockID) }
                    HStack(spacing: 4) {
                        Image(systemName: "folder").font(.system(size: 11)).foregroundStyle(Theme.textTertiary)
                        TextField("Gruppe", text: binding(\.group))
                            .textFieldStyle(.plain)
                            .font(.system(size: 12.5))
                            .frame(width: 180)
                    }
                    Spacer(minLength: 0)
                    Button {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(block.composed, forType: .string)
                    } label: {
                        Label("Kopieren", systemImage: "doc.on.doc").font(.system(size: 12))
                    }
                    .buttonStyle(.borderless)
                    .help("Den ganzen Datenblock als Text kopieren")
                    Button {
                        model.blockID = app.duplicateDataBlock(blockID)?.id
                    } label: {
                        Label("Duplizieren", systemImage: "plus.square.on.square").font(.system(size: 12))
                    }
                    .buttonStyle(.borderless)
                }
            }
        }
    }

    private var addFieldMenu: some View {
        Menu {
            ForEach(DataFieldKind.allCases) { kind in
                Button(kind.label, systemImage: kind.symbol) {
                    app.dataStudio.blocks.update(blockID) { block in
                        let name = kind == .text ? "Neues Feld" : kind.label
                        block.fields.append(DataField(key: block.freeFieldKey(for: name), name: name, kind: kind))
                    }
                }
            }
        } label: {
            Label("Feld", systemImage: "plus")
                .font(.system(size: 12, weight: .medium))
        }
        .menuStyle(.button)
        .buttonStyle(.borderless)
        .fixedSize()
    }

    private func displayCard(_ block: DataBlock) -> some View {
        StudioCard(title: "Als Ganzes: {{\(block.key)}}", symbol: "text.below.photo") {
            Text("So erscheint der ganze Datenblock, etwa im Anschriftfeld eines Briefes. Felder in einfachen Klammern: {vorname} {nachname}. Leere Zeilen fallen weg.")
                .font(.system(size: 11.5))
                .foregroundStyle(Theme.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
            HStack(alignment: .top, spacing: 14) {
                StoryTextEditor(placeholder: "Leer: alle gefüllten Felder untereinander", text: binding(\.display), minLines: 3,
                                font: .monospacedSystemFont(ofSize: 12, weight: .regular))
                    .padding(6)
                    .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(Theme.ink.opacity(0.04)))
                VStack(alignment: .leading, spacing: 4) {
                    Text("VORSCHAU")
                        .font(.system(size: 9.5, weight: .semibold))
                        .tracking(0.5)
                        .foregroundStyle(Theme.textTertiary)
                    Text(block.composed.isEmpty ? "–" : block.composed)
                        .font(.system(size: 13))
                        .foregroundStyle(Theme.textPrimary)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(width: 240, alignment: .leading)
                .padding(10)
                .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Theme.elevated))
            }
            HStack(spacing: 6) {
                Text("Felder:").font(.system(size: 11)).foregroundStyle(Theme.textTertiary)
                ForEach(block.fields.prefix(10)) { field in
                    Button("{\(field.key)}") {
                        app.dataStudio.blocks.update(blockID) { $0.display += ($0.display.isEmpty || $0.display.hasSuffix("\n") || $0.display.hasSuffix(" ") ? "" : " ") + "{\(field.key)}" }
                    }
                    .buttonStyle(.borderless)
                    .font(.system(size: 11, design: .monospaced))
                }
            }
        }
    }

    private func usagesCard(_ block: DataBlock) -> some View {
        let usages = app.dataBlockUsages(block.key)
        return StudioCard(title: "Verwendet in", symbol: "link") {
            if usages.isEmpty {
                Text("Noch in keinem Dokument, keiner Präsentation und keinem Note. Ziehe ein Feld in einen Text oder setze es dort mit ⌥⌘D ein.")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.textTertiary)
            }
            ForEach(usages, id: \.self) { ref in
                Button {
                    app.openProjectRef(ref)
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: app.projectRefSymbol(ref)).foregroundStyle(Theme.accent).frame(width: 18)
                        Text(app.projectRefTitle(ref) ?? "–").foregroundStyle(Theme.textPrimary)
                        Text(app.projectRefKind(ref)).foregroundStyle(Theme.textTertiary)
                        Spacer()
                        Image(systemName: "arrow.up.forward").foregroundStyle(Theme.textTertiary)
                    }
                    .font(.system(size: 12.5))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
    }
}

private struct FieldDropDelegate: DropDelegate {
    let target: UUID
    @Binding var dragged: UUID?
    let move: (UUID, UUID) -> Void

    func dropEntered(info: DropInfo) {
        guard let dragged, dragged != target else { return }
        move(dragged, target)
    }

    func dropUpdated(info: DropInfo) -> DropProposal? { DropProposal(operation: .move) }

    func performDrop(info: DropInfo) -> Bool {
        dragged = nil
        return true
    }
}

/// One field: its name, its value in the input its kind wants, its placeholder to copy or drag, delete.
private struct DataFieldRow: View {
    @Environment(AppModel.self) private var app
    let blockID: UUID
    let field: DataField
    let blockKey: String
    @State private var editingKey = false

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            HStack(spacing: 5) {
                Menu {
                    ForEach(DataFieldKind.allCases) { kind in
                        Button(kind.label, systemImage: kind.symbol) { change { $0.kind = kind } }
                    }
                } label: {
                    Image(systemName: field.kind.symbol)
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.textTertiary)
                        .frame(width: 18)
                }
                .menuStyle(.button)
                .buttonStyle(.plain)
                .menuIndicator(.hidden)
                .fixedSize()
                .help("Art des Feldes: \(field.kind.label)")
                TextField("Feldname", text: Binding(get: { field.name }, set: { name in change { $0.name = name } }))
                    .textFieldStyle(.plain)
                    .font(.system(size: 12.5, weight: .medium))
            }
            .frame(width: 170, alignment: .leading)
            .padding(.top, 5)
            valueInput
                .frame(maxWidth: .infinity, alignment: .leading)
            Button {
                editingKey = true
            } label: {
                Text(DataRef(block: blockKey, field: field.key).token)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(Theme.textSecondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .buttonStyle(.plain)
            .frame(width: 190, alignment: .leading)
            .padding(.top, 6)
            .help("Kürzel des Feldes ändern; ziehen setzt das Feld in einen Text ein")
            .popover(isPresented: $editingKey) { FieldKeyPopover(blockID: blockID, field: field) }
            HStack(spacing: 2) {
                IconButton(systemName: "doc.on.doc", help: "Platzhalter kopieren", size: 11, frameSize: 22) {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(DataRef(block: blockKey, field: field.key).token, forType: .string)
                }
                IconButton(systemName: "minus.circle", help: "Feld löschen", size: 11, frameSize: 22) {
                    app.dataStudio.blocks.update(blockID) { $0.fields.removeAll { $0.id == field.id } }
                }
            }
            .frame(width: 48)
            .padding(.top, 2)
        }
        .padding(.vertical, 5)
    }

    @ViewBuilder private var valueInput: some View {
        switch field.kind {
        case .mehrzeilig:
            StoryTextEditor(placeholder: "Wert", text: valueBinding, minLines: 2)
                .padding(.horizontal, 6)
                .padding(.vertical, 4)
                .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(Theme.ink.opacity(0.05)))
        case .datum:
            HStack(spacing: 6) {
                DatePicker("", selection: Binding(get: { DataDay.date(field.value) ?? Date() }, set: { date in change { $0.value = DataDay.string(date) } }),
                           displayedComponents: .date)
                    .labelsHidden()
                    .datePickerStyle(.field)
                    .environment(\.locale, Locale(identifier: "de_DE"))
                    .opacity(field.value.isEmpty ? 0.5 : 1)
                if !field.value.isEmpty {
                    Text(field.output).font(.system(size: 11)).foregroundStyle(Theme.textTertiary)
                    IconButton(systemName: "xmark.circle", help: "Datum leeren", size: 10.5, frameSize: 20) { change { $0.value = "" } }
                } else {
                    Text("leer").font(.system(size: 11)).foregroundStyle(Theme.textTertiary)
                }
            }
        default:
            StudioField(placeholder: placeholder, text: valueBinding)
        }
    }

    private var placeholder: String {
        switch field.kind {
        case .email: "name@beispiel.de"
        case .telefon: "+49 …"
        case .link: "https://…"
        case .zahl: "0"
        default: "Wert"
        }
    }

    private var valueBinding: Binding<String> {
        Binding(get: { app.dataStudio.block(blockID)?.fields.first { $0.id == field.id }?.value ?? "" },
                set: { value in change { $0.value = value } })
    }

    private func change(_ edit: (inout DataField) -> Void) {
        app.dataStudio.blocks.update(blockID) { block in
            guard let index = block.fields.firstIndex(where: { $0.id == field.id }) else { return }
            edit(&block.fields[index])
        }
    }
}

private struct KeyRenamePopover: View {
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    let blockID: UUID
    @State private var key = ""
    @State private var rewrite = true

    var body: some View {
        let block = app.dataStudio.block(blockID)
        let uses = block.map { app.dataBlockUsages($0.key).count } ?? 0
        VStack(alignment: .leading, spacing: 10) {
            Text("Kürzel des Datenblocks").font(.system(size: 13, weight: .semibold))
            Text("Texte nennen den Datenblock mit {{kürzel.feld}}. Kleinbuchstaben, Ziffern und Bindestriche.")
                .font(.system(size: 11.5)).foregroundStyle(Theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            StudioField(placeholder: "kuerzel", text: $key, monospaced: true)
            Toggle("Alle Texte mitändern (\(uses) \(uses == 1 ? "Stelle" : "Stellen"))", isOn: $rewrite)
                .font(.system(size: 12))
            HStack {
                Spacer()
                Button("Abbrechen") { dismiss() }
                Button("Ändern") {
                    app.renameDataKey(blockID, to: key, rewrite: rewrite)
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .disabled(DataKey.make(from: key, fallback: "").isEmpty)
            }
        }
        .padding(16)
        .frame(width: 320)
        .onAppear { key = block?.key ?? "" }
    }
}

private struct FieldKeyPopover: View {
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    let blockID: UUID
    let field: DataField
    @State private var key = ""
    @State private var rewrite = true

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Kürzel von „\(field.name)“").font(.system(size: 13, weight: .semibold))
            StudioField(placeholder: "feld", text: $key, monospaced: true)
            Toggle("Alle Texte mitändern", isOn: $rewrite).font(.system(size: 12))
            HStack {
                Button("Platzhalter kopieren") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(DataRef(block: app.dataStudio.block(blockID)?.key ?? "", field: field.key).token, forType: .string)
                    dismiss()
                }
                Spacer()
                Button("Ändern") {
                    app.renameDataFieldKey(blockID, field: field.id, to: key, rewrite: rewrite)
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(16)
        .frame(width: 300)
        .onAppear { key = field.key }
    }
}

/// The blocks of the selected block's group as rows, their fields as columns: for many alike blocks (contacts).
private struct DataTableView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.undoManager) private var undoManager
    @Bindable var model: DataStudioModel

    var body: some View {
        let studio = app.dataStudio
        let group = model.blockID.flatMap { studio.block($0)?.group } ?? studio.groups.first ?? ""
        let rows = studio.blocks.records.filter { $0.group == group && $0.matches(model.query) }
        // The columns: every field name that occurs, in the order they first appear.
        let columns: [(key: String, name: String)] = rows.reduce(into: []) { result, block in
            for field in block.fields where !result.contains(where: { $0.key == field.key }) { result.append((field.key, field.name)) }
        }
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Picker("Gruppe", selection: Binding(get: { group }, set: { newGroup in
                    model.blockID = studio.blocks.records.first { $0.group == newGroup }?.id
                })) {
                    ForEach(studio.groups, id: \.self) { group in Text(group.isEmpty ? "Ohne Gruppe" : group).tag(group) }
                }
                .frame(width: 260)
                Text("\(rows.count) Zeilen · \(columns.count) Spalten")
                    .font(.system(size: 12)).foregroundStyle(Theme.textTertiary)
                Spacer()
                Button {
                    var block = app.newDataBlock(DataStructure.allCases.first { $0.group == group } ?? .frei, name: "Neu", undo: undoManager)
                    block.group = group
                    let made = block
                    app.dataStudio.blocks.update(made.id) { $0.group = group }
                } label: {
                    Label("Zeile", systemImage: "plus")
                }
            }
            .padding(.horizontal, 20)
            .padding(.top, 12)
            ScrollView([.horizontal, .vertical]) {
                VStack(alignment: .leading, spacing: 0) {
                    HStack(spacing: 0) {
                        cell(Text("Name").font(.system(size: 11, weight: .semibold)), width: 180)
                        ForEach(columns, id: \.key) { column in
                            cell(Text(column.name).font(.system(size: 11, weight: .semibold)), width: 170)
                        }
                    }
                    .foregroundStyle(Theme.textSecondary)
                    .background(Theme.ink.opacity(0.05))
                    ForEach(rows) { block in
                        HStack(spacing: 0) {
                            cell(TextField("Name", text: Binding(get: { block.name }, set: { name in studio.blocks.update(block.id) { $0.name = name } }))
                                .textFieldStyle(.plain).font(.system(size: 12.5, weight: .medium)), width: 180)
                            ForEach(columns, id: \.key) { column in
                                cell(TextField("", text: Binding(
                                    get: { studio.block(block.id)?.field(column.key)?.value ?? "" },
                                    set: { value in
                                        studio.blocks.update(block.id) { block in
                                            if let index = block.fields.firstIndex(where: { $0.key == column.key }) {
                                                block.fields[index].value = value
                                            } else {
                                                block.fields.append(DataField(key: column.key, name: column.name, value: value))
                                            }
                                        }
                                    }))
                                    .textFieldStyle(.plain).font(.system(size: 12.5)), width: 170)
                            }
                        }
                        .background(model.blockID == block.id ? Theme.selection : .clear)
                        .contextMenu {
                            Button("Einzeln öffnen", systemImage: "rectangle.portrait") {
                                model.blockID = block.id
                                model.showsTable = false
                            }
                            Button("Löschen", systemImage: "trash", role: .destructive) {
                                studio.blocks.delete(block.id, label: "Datenblock löschen", undo: undoManager)
                            }
                        }
                    }
                }
                .overlay(Rectangle().strokeBorder(Theme.border))
                .padding(20)
            }
        }
    }

    private func cell(_ content: some View, width: CGFloat) -> some View {
        content
            .padding(.horizontal, 8)
            .frame(width: width, height: 30, alignment: .leading)
            .overlay(alignment: .trailing) { Rectangle().fill(Theme.border).frame(width: 1) }
            .overlay(alignment: .bottom) { Rectangle().fill(Theme.border).frame(height: 1) }
    }
}

extension AppModel {
    /// The document Data Studio can make a template from: the one open before the studio.
    var dataStudioSourceDocument: WriterDocument? {
        lastClosedDocumentID.flatMap { document($0) }
    }
}
