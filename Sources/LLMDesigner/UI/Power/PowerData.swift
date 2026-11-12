import SwiftUI

/// Data Studio in small: every data block of the library. A field drags into a document, a slide, a note or the chat
/// as its placeholder (the text then shows the value and follows changes). Values can be changed right here, and the
/// open document shows the change at once.
struct PowerData: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        let query = app.power.query
        if let id = app.power.dataBlockID, app.dataStudio.block(id) != nil, query.isEmpty {
            PowerDataBlockView(blockID: id)
        } else {
            PowerDataList(query: query)
        }
    }
}

private struct PowerDataList: View {
    @Environment(AppModel.self) private var app
    let query: String

    var body: some View {
        let studio = app.dataStudio
        let blocks = studio.blocks.records.filter { $0.matches(query) }
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 8) {
                    Image(systemName: "curlybraces")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Theme.accent)
                    Text("Felder in einen Text ziehen: Er zeigt den Wert und ändert sich mit, wenn du den Datenblock änderst.")
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(10)
                .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(Theme.ink.opacity(0.035)))
                .padding(.bottom, 6)
                ForEach(studio.groups, id: \.self) { group in
                    let members = blocks.filter { $0.group == group }
                    if !members.isEmpty {
                        StudioSectionHeader(title: group.isEmpty ? "Ohne Gruppe" : group, symbol: "folder", count: members.count)
                        ForEach(members) { block in
                            HStack(spacing: 0) {
                                PowerListRow(title: block.displayName, subtitle: "{{\(block.key)}} · " + block.composed.replacingOccurrences(of: "\n", with: ", "),
                                             symbol: block.symbol) { app.power.dataBlockID = block.id }
                                Image(systemName: "line.3.horizontal")
                                    .font(.system(size: 11))
                                    .foregroundStyle(Theme.textTertiary)
                                    .frame(width: 22, height: 30)
                                    .contentShape(Rectangle())
                                    .powerDrag(markdown: DataRef(block: block.key).token, plain: block.composed)
                                    .help("Ziehen: den ganzen Datenblock als Feld in einen Text")
                            }
                        }
                    }
                }
                if blocks.isEmpty {
                    PowerEmpty(text: query.isEmpty ? "Noch keine Datenblöcke." : "Kein Datenblock passt zur Suche.")
                }
                HStack(spacing: 10) {
                    Menu {
                        ForEach(DataStructure.allCases) { structure in
                            Button(structure.label, systemImage: structure.symbol) { app.power.dataBlockID = app.newDataBlock(structure).id }
                        }
                    } label: {
                        Label("Neuer Datenblock", systemImage: "plus").font(.system(size: 12, weight: .medium))
                    }
                    .menuStyle(.button)
                    .buttonStyle(.borderless)
                    .fixedSize()
                    Button {
                        app.openDataStudio()
                    } label: {
                        Label("Data Studio", systemImage: "arrow.up.forward.app").font(.system(size: 12))
                    }
                    .buttonStyle(.borderless)
                }
                .padding(.top, 10)
                .padding(.horizontal, 8)
            }
            .padding(.horizontal, 10)
            .padding(.bottom, 12)
        }
    }
}

private struct PowerDataBlockView: View {
    @Environment(AppModel.self) private var app
    let blockID: UUID

    var body: some View {
        let block = app.dataStudio.block(blockID)
        VStack(spacing: 0) {
            PowerItemBar(title: block?.displayName ?? "", symbol: block?.symbol, openHelp: "In Data Studio öffnen") {
                app.power.closeItem()
            } onOpen: {
                app.openDataStudio(DataStudioCommand(tab: .blocks, block: blockID))
            }
            if let block {
                ScrollView {
                    VStack(alignment: .leading, spacing: 6) {
                        wholeBlock(token: DataRef(block: block.key).token, value: block.composed)
                        Divider().padding(.vertical, 2)
                        ForEach(block.fields) { field in
                            VStack(alignment: .leading, spacing: 3) {
                                HStack(spacing: 6) {
                                    Text(field.name)
                                        .font(.system(size: 11.5, weight: .semibold))
                                        .foregroundStyle(Theme.textSecondary)
                                    Spacer(minLength: 0)
                                    Text(DataRef(block: block.key, field: field.key).token)
                                        .font(.system(size: 10, design: .monospaced))
                                        .foregroundStyle(Theme.textTertiary)
                                        .lineLimit(1)
                                    Image(systemName: "line.3.horizontal")
                                        .font(.system(size: 11))
                                        .foregroundStyle(Theme.textTertiary)
                                        .frame(width: 20, height: 20)
                                        .contentShape(Rectangle())
                                        .powerDrag(markdown: DataRef(block: block.key, field: field.key).token, plain: field.output)
                                        .help("Ziehen: das Feld in einen Text")
                                }
                                StudioField(placeholder: field.kind == .datum ? "2026-11-12" : "Wert", text: Binding(
                                    get: { app.dataStudio.block(blockID)?.fields.first { $0.id == field.id }?.value ?? "" },
                                    set: { value in
                                        app.dataStudio.blocks.update(blockID) { block in
                                            if let index = block.fields.firstIndex(where: { $0.id == field.id }) { block.fields[index].value = value }
                                        }
                                    }))
                            }
                            .padding(.vertical, 3)
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.bottom, 14)
                }
            }
        }
    }

    private func wholeBlock(token: String, value: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            VStack(alignment: .leading, spacing: 3) {
                Text("Ganzer Block").font(.system(size: 11.5, weight: .semibold)).foregroundStyle(Theme.textSecondary)
                Text(value.isEmpty ? "–" : value)
                    .font(.system(size: 12.5))
                    .foregroundStyle(Theme.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
            Image(systemName: "line.3.horizontal")
                .font(.system(size: 11))
                .foregroundStyle(Theme.textTertiary)
                .frame(width: 20, height: 20)
                .contentShape(Rectangle())
                .powerDrag(markdown: token, plain: value)
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Theme.border, style: StrokeStyle(lineWidth: 1, dash: [4, 3])))
    }
}
