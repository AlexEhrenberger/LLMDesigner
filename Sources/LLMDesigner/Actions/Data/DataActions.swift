import Foundation
import LLMDProtocol

extension ActionRegistry {
    func registerDataActions() {
        register(DataBlockListAction.self)
        register(DataBlockReadAction.self)
        register(DataBlockCreateAction.self)
        register(DataBlockUpdateAction.self)
        register(DataBlockDeleteAction.self)
        register(DataFieldSetAction.self)
        register(DataFieldRemoveAction.self)
        register(DataResolveAction.self)
        register(DataUsagesAction.self)
        register(DataStructureListAction.self)
        register(DataTemplateListAction.self)
        register(DataTemplateReadAction.self)
        register(DataTemplateCreateAction.self)
        register(DataTemplateUpdateAction.self)
        register(DataTemplateDeleteAction.self)
        register(DataTemplateUseAction.self)
        register(DataTemplateFromDocumentAction.self)
        register(DataMasterApplyAction.self)
        register(DataStudioOpenAction.self)
        register(DataStudioCloseAction.self)
    }
}

/// The values of data blocks are the person's own data (addresses, birthdays, bank details): reading them counts as
/// private. Their names and keys alone do not.
let dataValuesRead = ActionSecurity.sensitiveRead
let dataBlockProperty: JSONSchema = .string("Datenblock (ID, Kürzel oder Name)")
let dataTemplateProperty: JSONSchema = .string("Vorlage (ID oder Name)")

extension AppModel {
    func actionDataBlock(_ reference: String) throws -> DataBlock {
        dataStudio.loadIfNeeded()
        let reference = reference.trimmingCharacters(in: .whitespacesAndNewlines).trimmingCharacters(in: CharacterSet(charactersIn: "{}"))
        if let id = UUID(uuidString: reference) {
            guard let block = dataStudio.block(id) else { throw RPCError.notFound("Datenblock \(reference) gibt es nicht.") }
            return block
        }
        if let block = dataStudio.block(key: reference) { return block }
        let found = dataStudio.blocks.records.filter { $0.displayName.localizedCaseInsensitiveCompare(reference) == .orderedSame }
        if found.count == 1 { return found[0] }
        if found.isEmpty { throw RPCError.notFound("Datenblock „\(reference)“ gibt es nicht.") }
        throw RPCError.ambiguous("Mehrere Datenblöcke heißen „\(reference)“. Bitte das Kürzel verwenden.", candidates: found.map(\.key))
    }

    func actionTemplate(_ reference: String) throws -> DataTemplate {
        dataStudio.loadIfNeeded()
        let reference = reference.trimmingCharacters(in: .whitespacesAndNewlines)
        if let id = UUID(uuidString: reference) {
            guard let template = dataStudio.template(id) else { throw RPCError.notFound("Vorlage \(reference) gibt es nicht.") }
            return template
        }
        let all = dataStudio.allTemplates
        if let builtIn = all.first(where: { $0.builtIn == reference }) { return builtIn }
        let found = all.filter { $0.displayName.localizedCaseInsensitiveCompare(reference) == .orderedSame }
        if found.count == 1 { return found[0] }
        let partial = all.filter { $0.displayName.localizedCaseInsensitiveContains(reference) }
        if found.isEmpty, partial.count == 1 { return partial[0] }
        if found.isEmpty, partial.isEmpty { throw RPCError.notFound("Vorlage „\(reference)“ gibt es nicht.") }
        throw RPCError.ambiguous("Mehrere Vorlagen passen zu „\(reference)“. Bitte die ID verwenden.", candidates: (found.isEmpty ? partial : found).map(\.id.uuidString))
    }
}

extension DataBlock {
    func actionField(_ reference: String) throws -> DataField {
        let reference = reference.trimmingCharacters(in: .whitespacesAndNewlines)
        if let id = UUID(uuidString: reference), let field = fields.first(where: { $0.id == id }) { return field }
        if let field = field(reference) { return field }
        let found = fields.filter { $0.name.localizedCaseInsensitiveCompare(reference) == .orderedSame }
        if found.count == 1 { return found[0] }
        if let number = Int(reference), number >= 1, number <= fields.count { return fields[number - 1] }
        throw RPCError.notFound("Feld „\(reference)“ gibt es in „\(displayName)“ nicht.")
    }
}

extension ActionContext {
    /// A change to a data block with an undo step, as one call.
    @discardableResult
    func changeDataBlock(_ id: UUID, label: String, _ change: (inout DataBlock) throws -> Void) throws -> DataBlock {
        let library = app.dataStudio.blocks
        guard let before = library.record(id) else { throw RPCError.notFound("Den Datenblock gibt es nicht mehr.") }
        var block = before
        try change(&block)
        let wanted = block
        library.update(id) { $0 = wanted }
        let after = library.record(id) ?? wanted
        undoGroup.add(UndoStep(label: label, undo: { [weak library] in library?.restore(before) }, redo: { [weak library] in library?.restore(after) }))
        registry.eventSink?(ActionEvent(kind: "data.changed", action: undoGroup.label, channel: channel.rawValue, run: run.id, target: id.uuidString))
        return after
    }

    @discardableResult
    func changeTemplate(_ id: UUID, label: String, _ change: (inout DataTemplate) throws -> Void) throws -> DataTemplate {
        let library = app.dataStudio.templates
        guard let before = library.record(id) else {
            if app.dataStudio.template(id)?.isBuiltIn == true { throw RPCError.invalidTarget("Mitgelieferte Vorlagen lassen sich nicht ändern. Lege mit data.template.create --from eine Kopie an.") }
            throw RPCError.notFound("Die Vorlage gibt es nicht mehr.")
        }
        var template = before
        try change(&template)
        let wanted = template
        library.update(id) { $0 = wanted }
        let after = library.record(id) ?? wanted
        undoGroup.add(UndoStep(label: label, undo: { [weak library] in library?.restore(before) }, redo: { [weak library] in library?.restore(after) }))
        return after
    }
}

// MARK: - Output

struct DataFieldOutput: Encodable, Sendable {
    var key: String
    var name: String
    var kind: String
    var value: String
    var placeholder: String
}

struct DataBlockSummaryOutput: Encodable, Sendable {
    var id: String
    var name: String
    var key: String
    var group: String
    var fields: [String]
    var placeholder: String
}

extension DataBlock {
    var actionSummary: DataBlockSummaryOutput {
        DataBlockSummaryOutput(id: id.uuidString, name: displayName, key: key, group: group, fields: fields.map(\.key), placeholder: DataRef(block: key).token)
    }

    var actionFields: [DataFieldOutput] {
        fields.map { DataFieldOutput(key: $0.key, name: $0.name, kind: $0.kind.rawValue, value: $0.value, placeholder: DataRef(block: key, field: $0.key).token) }
    }
}

struct DataTemplateSummaryOutput: Encodable, Sendable {
    var id: String
    var name: String
    var kind: String
    var builtIn: Bool
    var roles: [String]
    var summary: String
}

extension DataTemplate {
    var actionSummary: DataTemplateSummaryOutput {
        DataTemplateSummaryOutput(id: id.uuidString, name: displayName, kind: kind.rawValue, builtIn: isBuiltIn, roles: slots.map(\.key), summary: summary)
    }
}

/// `[{"name": "Straße", "value": "…", "kind": "text", "key": "strasse"}]`
struct DataFieldInput: Decodable, Sendable {
    var name: String
    var value: String?
    var kind: String?
    var key: String?
}

private let fieldInputSchema: JSONSchema = .array(of: .object(["name": .string("Feldname"), "value": .string("Wert"), "kind": .choice(DataFieldKind.allCases.map(\.rawValue), "Art"),
                                                               "key": .string("Kürzel (sonst aus dem Namen)")], required: ["name"]), "Felder")

private func fieldKind(_ text: String?) throws -> DataFieldKind? {
    guard let text else { return nil }
    guard let kind = DataFieldKind(rawValue: text) else {
        throw RPCError.invalidParams("Art „\(text)“ gibt es nicht. Möglich: \(DataFieldKind.allCases.map(\.rawValue).joined(separator: ", ")).")
    }
    return kind
}

/// A date given as „12.11.2026“ is kept as 2026-11-12.
private func storedValue(_ value: String, kind: DataFieldKind) -> String {
    guard kind == .datum, let date = DataDay.date(value) else { return value }
    return DataDay.string(date)
}

// MARK: - Blocks

struct DataBlockListAction: LLMDAction {
    struct Args: Decodable, Sendable {
        var query: String?
        var group: String?
    }
    struct Output: Encodable, Sendable {
        var blocks: [DataBlockSummaryOutput]
        var groups: [String]
    }
    static let descriptor = ActionDescriptor(
        id: "data.block.list", summary: "Listet die Datenblöcke mit Kürzel, Gruppe und Feldnamen (ohne Werte)", kind: .read, security: .plainRead,
        input: .object(["query": .string("Suche in Namen, Kürzeln und Feldnamen"), "group": .string("Nur diese Gruppe")]),
        output: .freeObject(), example: "llmd data block list --group Personen", groups: ["data.core"]
    )
    static func run(_ args: Args, context: ActionContext) async throws -> Output {
        let studio = context.app.dataStudio
        studio.loadIfNeeded()
        let query = args.query?.trimmingCharacters(in: .whitespaces) ?? ""
        let shown = studio.blocks.records.filter { block in
            (args.group == nil || block.group.localizedCaseInsensitiveCompare(args.group!) == .orderedSame)
                && (query.isEmpty || ([block.name, block.key, block.group] + block.fields.map(\.name)).contains { $0.localizedCaseInsensitiveContains(query) })
        }
        return Output(blocks: shown.map(\.actionSummary), groups: studio.groups)
    }
}

struct DataBlockReadAction: LLMDAction {
    struct Args: Decodable, Sendable {
        var block: String
    }
    struct Output: Encodable, Sendable {
        var block: DataBlockSummaryOutput
        var fields: [DataFieldOutput]
        var display: String
        var composed: String
        var note: String?
    }
    static let descriptor = ActionDescriptor(
        id: "data.block.read", summary: "Liest einen Datenblock mit allen Werten und seinem Platzhalter {{kürzel.feld}} je Feld (private Daten)",
        kind: .read, security: dataValuesRead,
        input: .object(["block": dataBlockProperty], required: ["block"]), output: .freeObject(), example: "llmd data block read --block absender", groups: ["data.core"]
    )
    static func preflight(_ args: Args, context: ActionContext) throws -> ActionPreflight {
        ActionPreflight(target: try context.app.actionDataBlock(args.block).displayName)
    }
    static func run(_ args: Args, context: ActionContext) async throws -> Output {
        let block = try context.app.actionDataBlock(args.block)
        return Output(block: block.actionSummary, fields: block.actionFields, display: block.display, composed: block.composed, note: block.note.isEmpty ? nil : block.note)
    }
}

struct DataBlockCreateAction: LLMDAction {
    struct Args: Decodable, Sendable {
        var name: String?
        var structure: String?
        var key: String?
        var group: String?
        var fields: [DataFieldInput]?
        var values: [String: String]?
        var display: String?
        var open: Bool?
    }
    struct Output: Encodable, Sendable {
        var id: String
        var key: String
        var placeholder: String
        var fields: [String]
    }
    static let descriptor = ActionDescriptor(
        id: "data.block.create",
        summary: "Legt einen Datenblock an: aus einer Struktur (person, organisation, anschrift, kontakt, bank, frei) mit values {feld: wert} und/oder eigenen Feldern",
        kind: .write, security: .localWrite,
        input: .object([
            "name": .string("Name, z. B. Absender oder User 1"), "structure": .choice(DataStructure.allCases.map(\.rawValue), "Felder einer Struktur (Vorgabe frei)"),
            "key": .string("Kürzel für die Platzhalter (sonst aus dem Namen)"), "group": .string("Gruppe in der Liste"), "fields": fieldInputSchema,
            "values": .freeObject("Werte nach Feldkürzel, z. B. {\"vorname\": \"Mara\", \"ort\": \"Berlin\"}"),
            "display": .string("Wie {{kürzel}} den ganzen Block zeigt: {vorname} {nachname}\\n{strasse}"), "open": .boolean("In Data Studio zeigen"),
        ]),
        output: .freeObject(), example: "llmd data block create --name Absender --structure person --values '{\"vorname\":\"Mara\"}'", groups: ["data.core"]
    )
    static func run(_ args: Args, context: ActionContext) async throws -> Output {
        let app = context.app
        app.dataStudio.loadIfNeeded()
        let structure = try ProjectArgs.choice(args.structure, DataStructure.allCases, raw: \.rawValue, "Struktur") ?? .frei
        let name = args.name?.trimmingCharacters(in: .whitespaces).nonEmpty ?? (structure == .frei ? "Neuer Datenblock" : structure.label)
        var block = DataBlock(name: name, group: args.group ?? structure.group, symbol: structure.symbol,
                              color: FolderColor.allCases[app.dataStudio.blocks.records.count % FolderColor.allCases.count],
                              fields: structure == .frei && (args.fields?.isEmpty == false || args.values?.isEmpty == false) ? [] : structure.fields,
                              display: args.display ?? structure.display)
        if let key = args.key {
            guard DataKey.isValid(DataKey.make(from: key, fallback: "")) else { throw RPCError.invalidParams("Das Kürzel braucht Buchstaben oder Ziffern.") }
            block.key = app.dataStudio.freeKey(for: key)
        } else {
            block.key = app.dataStudio.freeKey(for: name)
        }
        for input in args.fields ?? [] {
            let kind = try fieldKind(input.kind) ?? .text
            let key = input.key.map { block.freeFieldKey(for: $0) } ?? block.freeFieldKey(for: input.name)
            if let index = block.fields.firstIndex(where: { $0.key == (input.key ?? DataKey.make(from: input.name, fallback: "")) || $0.name == input.name }) {
                block.fields[index].value = storedValue(input.value ?? "", kind: block.fields[index].kind)
            } else {
                block.fields.append(DataField(key: key, name: input.name, kind: kind, value: storedValue(input.value ?? "", kind: kind)))
            }
        }
        for (key, value) in args.values ?? [:] {
            if let index = block.fields.firstIndex(where: { $0.key.caseInsensitiveCompare(key) == .orderedSame || $0.name.caseInsensitiveCompare(key) == .orderedSame }) {
                block.fields[index].value = storedValue(value, kind: block.fields[index].kind)
            } else {
                block.fields.append(DataField(key: block.freeFieldKey(for: key), name: key, value: value))
            }
        }
        block.createdAt = Date()
        let made = app.dataStudio.blocks.add(block)
        let library = app.dataStudio.blocks
        context.undoGroup.add(UndoStep(label: "Datenblock anlegen", undo: { [weak library] in library?.remove(made.id) }, redo: { [weak library] in library?.restore(made) }))
        if args.open == true { app.openDataStudio(DataStudioCommand(tab: .blocks, block: made.id)) }
        return Output(id: made.id.uuidString, key: made.key, placeholder: DataRef(block: made.key).token, fields: made.fields.map(\.key))
    }
}

struct DataBlockUpdateAction: LLMDAction {
    struct Args: Decodable, Sendable {
        var block: String
        var name: String?
        var group: String?
        var display: String?
        var note: String?
        var key: String?
        var rewrite: Bool?
    }
    struct Output: Encodable, Sendable {
        var id: String
        var key: String
        var rewritten: Int
    }
    static let descriptor = ActionDescriptor(
        id: "data.block.update", summary: "Ändert Name, Gruppe, Darstellung oder Notiz eines Datenblocks; key ändert das Kürzel und mit rewrite alle Texte, die es nutzen",
        kind: .write, security: .localWrite,
        input: .object(["block": dataBlockProperty, "name": .string("Name"), "group": .string("Gruppe"), "display": .string("Darstellung des ganzen Blocks"),
                        "note": .string("Notiz"), "key": .string("Neues Kürzel"), "rewrite": .boolean("Dokumente, Notes, Projekte und Vorlagen mit umschreiben (Vorgabe true)")],
                        required: ["block"]),
        output: .freeObject(), example: "llmd data block update --block absender --key ich", groups: ["data.core"]
    )
    static func run(_ args: Args, context: ActionContext) async throws -> Output {
        let app = context.app
        let block = try app.actionDataBlock(args.block)
        guard args.name != nil || args.group != nil || args.display != nil || args.note != nil || args.key != nil else {
            throw RPCError.invalidParams("Nichts zu ändern: name, group, display, note oder key angeben.")
        }
        try context.changeDataBlock(block.id, label: "Datenblock ändern") { block in
            if let name = args.name { block.name = name }
            if let group = args.group { block.group = group }
            if let display = args.display { block.display = display }
            if let note = args.note { block.note = note }
        }
        var rewritten = 0
        if let key = args.key {
            rewritten = app.renameDataKey(block.id, to: key, rewrite: args.rewrite ?? true)
        }
        let after = app.dataStudio.block(block.id) ?? block
        return Output(id: after.id.uuidString, key: after.key, rewritten: rewritten)
    }
}

struct DataBlockDeleteAction: LLMDAction {
    struct Args: Decodable, Sendable {
        var block: String
    }
    static let descriptor = ActionDescriptor(
        id: "data.block.delete", summary: "Legt einen Datenblock in den Papierkorb; Texte, die ihn nutzen, zeigen dann ihren Platzhalter",
        kind: .destructive, security: .destructive,
        input: .object(["block": dataBlockProperty], required: ["block"]), output: .freeObject()
    )
    static func preflight(_ args: Args, context: ActionContext) throws -> ActionPreflight {
        let block = try context.app.actionDataBlock(args.block)
        let uses = context.app.dataBlockUsages(block.key).count
        return ActionPreflight(target: block.displayName, detail: uses == 0 ? nil : "Wird in \(uses) Texten verwendet.")
    }
    static func run(_ args: Args, context: ActionContext) async throws -> OKOutput {
        let block = try context.app.actionDataBlock(args.block)
        let library = context.app.dataStudio.blocks
        library.remove(block.id)
        context.undoGroup.add(UndoStep(label: "Datenblock löschen", undo: { [weak library] in library?.restore(block) }, redo: { [weak library] in library?.remove(block.id) }))
        return OKOutput(id: block.id.uuidString)
    }
}

struct DataFieldSetAction: LLMDAction {
    struct Args: Decodable, Sendable {
        var block: String
        var field: String?
        var values: [String: String]?
        var value: String?
        var name: String?
        var kind: String?
        var key: String?
    }
    struct Output: Encodable, Sendable {
        var fields: [String]
        var created: [String]
    }
    static let descriptor = ActionDescriptor(
        id: "data.field.set", summary: "Setzt Werte eines Datenblocks: field + value (und name, kind, key) für ein Feld oder values {feld: wert} für mehrere; fehlende Felder entstehen",
        kind: .write, security: .localWrite,
        input: .object(["block": dataBlockProperty, "field": .string("Feld (Kürzel, Name oder Nummer)"), "value": .string("Neuer Wert"),
                        "values": .freeObject("Mehrere Werte nach Feldkürzel"), "name": .string("Neuer Feldname"), "kind": .choice(DataFieldKind.allCases.map(\.rawValue), "Art"),
                        "key": .string("Neues Feldkürzel (Texte werden umgeschrieben)")], required: ["block"]),
        output: .freeObject(), example: "llmd data field set --block absender --field strasse --value \"Neue Straße 5\"", groups: ["data.core"]
    )
    static func run(_ args: Args, context: ActionContext) async throws -> Output {
        let app = context.app
        let block = try app.actionDataBlock(args.block)
        guard args.field != nil || args.values?.isEmpty == false else { throw RPCError.invalidParams("field oder values angeben.") }
        let kind = try fieldKind(args.kind)
        var changed: [String] = []
        var created: [String] = []
        var renameTo: (UUID, String)?
        try context.changeDataBlock(block.id, label: "Datenfeld ändern") { block in
            if let reference = args.field {
                let index: Int
                if let found = try? block.actionField(reference), let at = block.fields.firstIndex(where: { $0.id == found.id }) {
                    index = at
                } else {
                    let name = args.name ?? reference
                    block.fields.append(DataField(key: block.freeFieldKey(for: args.key ?? name), name: name, kind: kind ?? .text))
                    index = block.fields.count - 1
                    created.append(block.fields[index].key)
                }
                if let name = args.name { block.fields[index].name = name }
                if let kind { block.fields[index].kind = kind }
                if let value = args.value { block.fields[index].value = storedValue(value, kind: block.fields[index].kind) }
                if let key = args.key, !created.contains(block.fields[index].key) { renameTo = (block.fields[index].id, key) }
                changed.append(block.fields[index].key)
            }
            for (key, value) in args.values ?? [:] {
                if let index = block.fields.firstIndex(where: { $0.key.caseInsensitiveCompare(key) == .orderedSame || $0.name.caseInsensitiveCompare(key) == .orderedSame }) {
                    block.fields[index].value = storedValue(value, kind: block.fields[index].kind)
                    changed.append(block.fields[index].key)
                } else {
                    block.fields.append(DataField(key: block.freeFieldKey(for: key), name: key, value: value))
                    created.append(block.fields.last!.key)
                }
            }
        }
        if let (fieldID, key) = renameTo { app.renameDataFieldKey(block.id, field: fieldID, to: key, rewrite: true) }
        return Output(fields: changed, created: created)
    }
}

struct DataFieldRemoveAction: LLMDAction {
    struct Args: Decodable, Sendable {
        var block: String
        var field: String
    }
    static let descriptor = ActionDescriptor(
        id: "data.field.remove", summary: "Entfernt ein Feld aus einem Datenblock (rückgängig machbar)", kind: .write, security: .localWrite,
        input: .object(["block": dataBlockProperty, "field": .string("Feld (Kürzel, Name oder Nummer)")], required: ["block", "field"]), output: .freeObject(),
        groups: ["data.core"]
    )
    static func run(_ args: Args, context: ActionContext) async throws -> OKOutput {
        let block = try context.app.actionDataBlock(args.block)
        let field = try block.actionField(args.field)
        try context.changeDataBlock(block.id, label: "Datenfeld entfernen") { $0.fields.removeAll { $0.id == field.id } }
        return OKOutput(id: field.key)
    }
}

struct DataResolveAction: LLMDAction {
    struct Args: Decodable, Sendable {
        var text: String
    }
    struct Output: Encodable, Sendable {
        var text: String
        var missing: [String]
    }
    static let descriptor = ActionDescriptor(
        id: "data.resolve", summary: "Setzt in einen Text die Werte seiner Platzhalter {{kürzel.feld}} ein und nennt die, die es nicht gibt (private Daten)",
        kind: .read, security: dataValuesRead,
        input: .object(["text": .string("Text mit Platzhaltern")], required: ["text"]), output: .freeObject(),
        example: "llmd data resolve --text \"{{absender.ort}}, {{heute}}\"", groups: ["data.core"]
    )
    static func run(_ args: Args, context: ActionContext) async throws -> Output {
        let resolver = context.app.dataStudio.resolver
        let missing = DataTokens.find(in: args.text).map(\.ref).filter { resolver.value($0) == nil }.map(\.token)
        return Output(text: resolver.resolve(args.text), missing: Array(NSOrderedSet(array: missing)) as? [String] ?? missing)
    }
}

struct DataUsagesAction: LLMDAction {
    struct Args: Decodable, Sendable {
        var block: String
    }
    struct Output: Encodable, Sendable {
        var uses: [ProjectRefOutput]
    }
    static let descriptor = ActionDescriptor(
        id: "data.block.usages", summary: "Nennt die Dokumente, Präsentationen und Notes, die einen Datenblock verwenden", kind: .read, security: .plainRead,
        input: .object(["block": dataBlockProperty], required: ["block"]), output: .freeObject(), groups: ["data.core"]
    )
    static func run(_ args: Args, context: ActionContext) async throws -> Output {
        let app = context.app
        let block = try app.actionDataBlock(args.block)
        return Output(uses: app.dataBlockUsages(block.key).map { app.actionRefOutput($0) })
    }
}

struct DataStructureListAction: LLMDAction {
    struct Item: Encodable, Sendable {
        var id: String
        var name: String
        var fields: [String]
        var display: String
    }
    struct Output: Encodable, Sendable {
        var structures: [Item]
        var kinds: [String]
    }
    static let descriptor = ActionDescriptor(
        id: "data.structure.list", summary: "Listet die Strukturen für neue Datenblöcke mit ihren Feldkürzeln und die Feldarten", kind: .read, security: .plainRead,
        output: .freeObject(), groups: ["data.core"]
    )
    static func run(_ args: NoArgs, context: ActionContext) async throws -> Output {
        Output(structures: DataStructure.allCases.map { Item(id: $0.rawValue, name: $0.label, fields: $0.fields.map(\.key), display: $0.display) },
               kinds: DataFieldKind.allCases.map(\.rawValue))
    }
}

// MARK: - Templates

struct DataTemplateListAction: LLMDAction {
    struct Args: Decodable, Sendable {
        var kind: String?
    }
    struct Output: Encodable, Sendable {
        var templates: [DataTemplateSummaryOutput]
    }
    static let descriptor = ActionDescriptor(
        id: "data.template.list", summary: "Listet die Vorlagen: Dokumentvorlagen (writer, z. B. Brief DIN 5008, Lebenslauf) und Masterfolien (presenter)",
        kind: .read, security: .plainRead,
        input: .object(["kind": .choice(DataTemplate.Kind.allCases.map(\.rawValue), "Nur diese Art")]), output: .freeObject(),
        example: "llmd data template list --kind writer", groups: ["data.core"]
    )
    static func run(_ args: Args, context: ActionContext) async throws -> Output {
        let kind = try ProjectArgs.choice(args.kind, DataTemplate.Kind.allCases, raw: \.rawValue, "Art")
        return Output(templates: context.app.dataStudio.allTemplates.filter { kind == nil || $0.kind == kind }.map(\.actionSummary))
    }
}

struct DataTemplateReadAction: LLMDAction {
    struct Args: Decodable, Sendable {
        var template: String
    }
    struct Output: Encodable, Sendable {
        var template: DataTemplateSummaryOutput
        var roles: [TemplateSlot]
        var markdown: String?
        var master: SlideMaster?
        var pageFormat: String?
        var font: String?
    }
    static let descriptor = ActionDescriptor(
        id: "data.template.read", summary: "Liest eine Vorlage: Rollen, Text mit Platzhaltern oder Master (Logo, Kopf- und Fußzeile)", kind: .read, security: .plainRead,
        input: .object(["template": dataTemplateProperty], required: ["template"]), output: .freeObject(), groups: ["data.core"]
    )
    static func run(_ args: Args, context: ActionContext) async throws -> Output {
        let template = try context.app.actionTemplate(args.template)
        return Output(template: template.actionSummary, roles: template.slots, markdown: template.kind == .writer ? template.markdown : nil,
                      master: template.kind == .presenter ? template.master : nil, pageFormat: template.pageFormat, font: template.font)
    }
}

struct DataTemplateCreateAction: LLMDAction {
    struct Role: Decodable, Sendable {
        var key: String
        var name: String?
        var structure: String?
    }
    struct Args: Decodable, Sendable {
        var name: String
        var kind: String?
        var from: String?
        var markdown: String?
        var roles: [Role]?
        var header: String?
        var footer: String?
        var pageNumbers: Bool?
        var summary: String?
    }
    struct Output: Encodable, Sendable {
        var id: String
        var name: String
        var roles: [String]
    }
    static let descriptor = ActionDescriptor(
        id: "data.template.create", summary: "Legt eine Vorlage an: writer mit markdown und Rollen oder presenter mit Kopf-/Fußzeile; from kopiert eine bestehende (auch mitgelieferte)",
        kind: .write, security: .localWrite,
        input: .object([
            "name": .string("Name"), "kind": .choice(DataTemplate.Kind.allCases.map(\.rawValue), "Art (Vorgabe writer)"), "from": .string("Vorlage, die kopiert wird"),
            "markdown": .string("Text mit Platzhaltern {{rolle.feld}}"),
            "roles": .array(of: .object(["key": .string("Kürzel der Rolle"), "name": .string("Name"), "structure": .choice(DataStructure.allCases.map(\.rawValue), "Struktur")], required: ["key"]), "Rollen"),
            "header": .string("Kopfzeile (Master)"), "footer": .string("Fußzeile (Master)"), "pageNumbers": .boolean("Seitenzahlen (Master)"), "summary": .string("Beschreibung"),
        ], required: ["name"]),
        output: .freeObject(), example: "llmd data template create --name Kündigung --from brief-din5008", groups: ["data.core"]
    )
    static func run(_ args: Args, context: ActionContext) async throws -> Output {
        let app = context.app
        app.dataStudio.loadIfNeeded()
        var template: DataTemplate
        if let from = args.from {
            let original = try app.actionTemplate(from)
            guard let copy = app.duplicateTemplate(original.id) else { throw RPCError.notFound("Die Vorlage gibt es nicht.") }
            template = copy
        } else {
            let kind = try ProjectArgs.choice(args.kind, DataTemplate.Kind.allCases, raw: \.rawValue, "Art") ?? .writer
            template = DataTemplate(name: args.name, kind: kind)
            template.createdAt = Date()
            if kind == .presenter { template.symbol = "rectangle.on.rectangle" }
            template = app.dataStudio.templates.add(template)
        }
        let made = try context.changeTemplate(template.id, label: "Vorlage anlegen") { template in
            template.name = args.name
            if let markdown = args.markdown { template.markdown = markdown }
            if let summary = args.summary { template.summary = summary }
            if let header = args.header { template.master.header = header }
            if let footer = args.footer { template.master.footer = footer }
            if let pageNumbers = args.pageNumbers { template.master.pageNumbers = pageNumbers }
            if let roles = args.roles {
                template.slots = try roles.map { role in
                    TemplateSlot(key: DataKey.make(from: role.key, fallback: "rolle"), name: role.name ?? role.key,
                                 structure: try ProjectArgs.choice(role.structure, DataStructure.allCases, raw: \.rawValue, "Struktur") ?? .person)
                }
            }
        }
        let library = app.dataStudio.templates
        context.undoGroup.add(UndoStep(label: "Vorlage anlegen", undo: { [weak library] in library?.remove(made.id) }, redo: { [weak library] in library?.restore(made) }))
        return Output(id: made.id.uuidString, name: made.displayName, roles: made.slots.map(\.key))
    }
}

struct DataTemplateUpdateAction: LLMDAction {
    struct Args: Decodable, Sendable {
        var template: String
        var name: String?
        var markdown: String?
        var header: String?
        var footer: String?
        var pageNumbers: Bool?
        var onTitle: Bool?
        var logoCorner: String?
        var logoSize: Double?
        var summary: String?
    }
    static let descriptor = ActionDescriptor(
        id: "data.template.update", summary: "Ändert eine eigene Vorlage: Name, Text, Kopf-/Fußzeile, Seitenzahlen, Logo-Ecke und -Größe", kind: .write, security: .localWrite,
        input: .object([
            "template": dataTemplateProperty, "name": .string("Name"), "markdown": .string("Text"), "header": .string("Kopfzeile"), "footer": .string("Fußzeile"),
            "pageNumbers": .boolean("Seitenzahlen"), "onTitle": .boolean("Auch auf der Titelfolie"),
            "logoCorner": .choice(SlideMaster.Corner.allCases.map(\.rawValue), "Ecke des Logos"), "logoSize": .number("Breite des Logos als Anteil der Folie", minimum: 0.04, maximum: 0.4),
            "summary": .string("Beschreibung"),
        ], required: ["template"]), output: .freeObject(), groups: ["data.core"]
    )
    static func run(_ args: Args, context: ActionContext) async throws -> OKOutput {
        let template = try context.app.actionTemplate(args.template)
        let corner = try ProjectArgs.choice(args.logoCorner, SlideMaster.Corner.allCases, raw: \.rawValue, "Ecke")
        try context.changeTemplate(template.id, label: "Vorlage ändern") { template in
            if let name = args.name { template.name = name }
            if let markdown = args.markdown { template.markdown = markdown }
            if let summary = args.summary { template.summary = summary }
            if let header = args.header { template.master.header = header }
            if let footer = args.footer { template.master.footer = footer }
            if let pageNumbers = args.pageNumbers { template.master.pageNumbers = pageNumbers }
            if let onTitle = args.onTitle { template.master.onTitle = onTitle }
            if let corner { template.master.logoCorner = corner }
            if let size = args.logoSize { template.master.logoSize = size }
        }
        return OKOutput(id: template.id.uuidString)
    }
}

struct DataTemplateDeleteAction: LLMDAction {
    struct Args: Decodable, Sendable {
        var template: String
    }
    static let descriptor = ActionDescriptor(
        id: "data.template.delete", summary: "Legt eine eigene Vorlage in den Papierkorb; Präsentationen mit diesem Master verlieren ihn",
        kind: .destructive, security: .destructive,
        input: .object(["template": dataTemplateProperty], required: ["template"]), output: .freeObject()
    )
    static func preflight(_ args: Args, context: ActionContext) throws -> ActionPreflight {
        ActionPreflight(target: try context.app.actionTemplate(args.template).displayName)
    }
    static func run(_ args: Args, context: ActionContext) async throws -> OKOutput {
        let template = try context.app.actionTemplate(args.template)
        guard !template.isBuiltIn else { throw RPCError.invalidTarget("Mitgelieferte Vorlagen lassen sich nicht löschen.") }
        let library = context.app.dataStudio.templates
        library.remove(template.id)
        context.undoGroup.add(UndoStep(label: "Vorlage löschen", undo: { [weak library] in library?.restore(template) }, redo: { [weak library] in library?.remove(template.id) }))
        return OKOutput(id: template.id.uuidString)
    }
}

struct DataTemplateUseAction: LLMDAction {
    struct Args: Decodable, Sendable {
        var template: String
        var blocks: [String: String]?
        var title: String?
        var open: Bool?
    }
    struct Output: Encodable, Sendable {
        var id: String
        var title: String
        var kind: String
        var roles: [String: String]
        var open: [String]
    }
    static let descriptor = ActionDescriptor(
        id: "data.template.use",
        summary: "Erstellt aus einer Vorlage ein Writer-Dokument oder eine Präsentation; blocks ordnet jeder Rolle einen Datenblock zu ({\"absender\": \"user1\"}). Die Felder bleiben verknüpft.",
        kind: .write, security: .localWrite,
        input: .object(["template": dataTemplateProperty, "blocks": .freeObject("Rolle → Datenblock (Kürzel oder Name)"), "title": .string("Titel"),
                        "open": .boolean("Gleich öffnen (Vorgabe nein)")], required: ["template"]),
        output: .freeObject(), example: "llmd data template use --template brief-din5008 --blocks '{\"absender\":\"ich\",\"empfaenger\":\"finanzamt\"}' --title \"Brief ans Finanzamt\"",
        groups: ["data.core"]
    )
    static func run(_ args: Args, context: ActionContext) async throws -> Output {
        let app = context.app
        let template = try app.actionTemplate(args.template)
        var choices: [String: String] = [:]
        for (role, reference) in args.blocks ?? [:] {
            guard template.slots.contains(where: { $0.key.caseInsensitiveCompare(role) == .orderedSame }) else {
                throw RPCError.invalidParams("Die Vorlage hat keine Rolle „\(role)“. Rollen: \(template.slots.map(\.key).joined(separator: ", ")).")
            }
            choices[role.lowercased()] = try app.actionDataBlock(reference).key
        }
        let made = template.kind == .writer
            ? app.createDocument(from: template.id, choices: choices, title: args.title, open: args.open == true)
            : app.createPresentation(from: template.id, choices: choices, title: args.title, open: args.open == true)
        guard let made else { throw RPCError.notFound("Die Vorlage ließ sich nicht verwenden.") }
        let id = made.id
        context.undoGroup.add(UndoStep(label: "Aus Vorlage erstellen", undo: { [weak app] in app?.deleteDocument(id) }, redo: {}))
        var filled: [String: String] = [:]
        for slot in template.slots { if let key = choices[slot.key.lowercased()] ?? app.suggestedBlock(for: slot)?.key { filled[slot.key] = key } }
        let open = template.slots.map(\.key).filter { filled[$0] == nil }
        return Output(id: id.uuidString, title: made.displayTitle, kind: template.kind == .writer ? "dokument" : "praesentation", roles: filled, open: open)
    }
}

struct DataTemplateFromDocumentAction: LLMDAction {
    struct Args: Decodable, Sendable {
        var doc: String
        var name: String?
    }
    struct Output: Encodable, Sendable {
        var id: String
        var name: String
        var roles: [String]
    }
    static let descriptor = ActionDescriptor(
        id: "data.template.fromDocument", summary: "Macht aus einem Dokument oder einer Präsentation eine Vorlage; die Datenblöcke im Text werden zu Rollen",
        kind: .write, security: .localWrite,
        input: .object(["doc": .string("Dokument oder Präsentation (ID oder Titel)"), "name": .string("Name der Vorlage")], required: ["doc"]), output: .freeObject(),
        groups: ["data.core"]
    )
    static func run(_ args: Args, context: ActionContext) async throws -> Output {
        let app = context.app
        let document = try app.actionDocumentOrDeck(args.doc)
        guard let made = app.saveAsTemplate(document.id, name: args.name) else { throw RPCError.notFound("Das Dokument gibt es nicht.") }
        let library = app.dataStudio.templates
        context.undoGroup.add(UndoStep(label: "Vorlage aus Dokument", undo: { [weak library] in library?.remove(made.id) }, redo: { [weak library] in library?.restore(made) }))
        return Output(id: made.id.uuidString, name: made.displayName, roles: made.slots.map(\.key))
    }
}

struct DataMasterApplyAction: LLMDAction {
    struct Args: Decodable, Sendable {
        var doc: String
        var template: String?
        var design: Bool?
    }
    static let descriptor = ActionDescriptor(
        id: "data.master.apply", summary: "Setzt einer Präsentation eine Masterfolie (Logo, Kopf-, Fußzeile auf jeder Folie); ohne template nimmt sie ihn ab. design übernimmt auch das Design.",
        kind: .write, security: .localWrite,
        input: .object(["doc": .string("Präsentation (ID oder Titel)"), "template": .string("Masterfolie (ID oder Name); leer: keinen"), "design": .boolean("Auch das Design übernehmen")],
                       required: ["doc"]), output: .freeObject(), groups: ["data.core"]
    )
    static func run(_ args: Args, context: ActionContext) async throws -> OKOutput {
        let app = context.app
        let document = try app.actionDocumentOrDeck(args.doc)
        guard let before = document.deck else { throw RPCError.invalidTarget("„\(document.displayTitle)“ ist keine Präsentation.") }
        var masterID: UUID?
        if let reference = args.template, !reference.isEmpty {
            let template = try app.actionTemplate(reference)
            guard template.kind == .presenter else { throw RPCError.invalidParams("„\(template.displayName)“ ist keine Masterfolie.") }
            masterID = template.id
        }
        app.applyMaster(masterID, to: document.id, design: args.design == true)
        let id = document.id
        context.undoGroup.add(UndoStep(label: "Masterfolie", undo: { [weak app] in app?.modifyDocument(id) { $0.deck = before } }, redo: { [weak app] in app?.applyMaster(masterID, to: id, design: args.design == true) }))
        return OKOutput(id: document.id.uuidString)
    }
}

struct DataStudioOpenAction: LLMDAction {
    struct Args: Decodable, Sendable {
        var block: String?
        var template: String?
    }
    static let descriptor = ActionDescriptor(
        id: "data.studio.open", summary: "Öffnet Data Studio, auf Wunsch bei einem Datenblock oder einer Vorlage", kind: .read, security: .plainRead,
        input: .object(["block": dataBlockProperty, "template": dataTemplateProperty]), output: .freeObject()
    )
    static func run(_ args: Args, context: ActionContext) async throws -> OKOutput {
        let app = context.app
        let block = try args.block.map { try app.actionDataBlock($0).id }
        let template = try args.template.map { try app.actionTemplate($0).id }
        app.openDataStudio(DataStudioCommand(tab: template != nil ? .templates : .blocks, block: block, template: template))
        return OKOutput(id: (block ?? template)?.uuidString ?? "")
    }
}

struct DataStudioCloseAction: LLMDAction {
    static let descriptor = ActionDescriptor(id: "data.studio.close", summary: "Schließt Data Studio", kind: .read, security: .plainRead, output: .freeObject())
    static func run(_ args: NoArgs, context: ActionContext) async throws -> OKOutput {
        context.app.closeDataStudio()
        return OKOutput(id: "")
    }
}

extension String {
    var nonEmpty: String? { isEmpty ? nil : self }
}
