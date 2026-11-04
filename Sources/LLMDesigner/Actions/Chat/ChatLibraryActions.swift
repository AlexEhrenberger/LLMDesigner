import AppKit
import LLMDProtocol

extension ActionRegistry {
    func registerChatLibraryActions() {
        register(SkillUpdateAction.self)
        register(SkillDuplicateAction.self)
        register(SkillMoveAction.self)
        register(SkillImportAction.self)
        register(SkillExportAction.self)
        register(SkillDeleteAction.self)
        register(PersonaReadAction.self)
        register(PersonaCreateAction.self)
        register(PersonaUpdateAction.self)
        register(PersonaAvatarSetAction.self)
        register(PersonaAvatarRemoveAction.self)
        register(PersonaFilesAddAction.self)
        register(PersonaFilesRemoveAction.self)
        register(PersonaVoicePreviewAction.self)
        register(PersonaStartChatAction.self)
        register(PersonaDeleteAction.self)
        register(MemoryConsolidateAction.self)
        register(MemoryConsolidateCancelAction.self)
        register(MemoryDeleteAction.self)
        register(MemoryDeleteAllAction.self)
    }
}

// MARK: Skills

/// Skills as Markdown files with a small head: what other tools understand as well.
enum SkillFile {
    static func markdown(of skill: Skill) -> String {
        var head = ["---", "name: " + skill.name.replacingOccurrences(of: "\n", with: " ")]
        if !skill.summary.isEmpty { head.append("summary: " + skill.summary.replacingOccurrences(of: "\n", with: " ")) }
        if let symbol = skill.symbol { head.append("symbol: " + symbol) }
        head.append("---")
        return head.joined(separator: "\n") + "\n\n" + skill.instructions + "\n"
    }

    /// A skill from a file; without a head the file's name is the skill's name. It counts as foreign: nobody here wrote it.
    static func skill(from text: String, fallbackName: String) -> Skill {
        var name = fallbackName, summary = "", symbol: String?
        var body = text
        let lines = text.components(separatedBy: "\n")
        if lines.first?.trimmingCharacters(in: .whitespaces) == "---", let end = lines.dropFirst().firstIndex(where: { $0.trimmingCharacters(in: .whitespaces) == "---" }) {
            for line in lines[1..<end] {
                guard let colon = line.firstIndex(of: ":") else { continue }
                let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
                switch line[..<colon].trimmingCharacters(in: .whitespaces).lowercased() {
                case "name": name = value
                case "summary", "description": summary = value
                case "symbol": symbol = value
                default: break
                }
            }
            body = lines[(end + 1)...].joined(separator: "\n")
        }
        var skill = Skill(name: name, summary: summary, instructions: body.trimmingCharacters(in: .whitespacesAndNewlines))
        skill.symbol = symbol
        skill.provenance = .foreign
        return skill
    }
}

struct SkillArgs: Decodable, Sendable {
    var skill: String?
    var name: String?
    var summary: String?
    var instructions: String?
    var symbol: String?
    var folder: String?
    var file: String?
    var path: String?
    var overwrite: Bool?
}

private let skillReference: JSONSchema = .string("Skill (ID oder Name)")

/// A skill's change with its way back. The origin of the run carries over: a marked run makes the skill foreign.
@MainActor
private func changeSkill(_ reference: String?, context: ActionContext, label: String, _ change: (inout Skill) -> Void) throws -> OKOutput {
    let app = context.app
    let before = try app.actionSkill(reference ?? "")
    let id = before.id
    app.updateSkill(id) {
        change(&$0)
        $0.provenance = context.mergedProvenance($0.provenance)
    }
    if let after = app.skill(id) {
        context.undoGroup.add(UndoStep(label: label, undo: { app.updateSkill(id, touch: false) { $0 = before } }, redo: { app.updateSkill(id, touch: false) { $0 = after } }))
    }
    return OKOutput(id: id.uuidString)
}

struct SkillUpdateAction: LLMDAction {
    typealias Args = SkillArgs
    typealias Output = OKOutput
    static let descriptor = ActionDescriptor(
        id: "skill.update", summary: "Ändert einen Skill", kind: .write, security: .localWrite,
        input: .object(["skill": skillReference, "name": .string("Name"), "summary": .string("Eine Zeile für die Liste"), "instructions": .string("Anweisungen"), "symbol": .string("SF-Symbol")], required: ["skill"]), output: .freeObject()
    )
    static func run(_ args: Args, context: ActionContext) async throws -> Output {
        try changeSkill(args.skill, context: context, label: "Skill ändern") { skill in
            if let name = args.name { skill.name = name }
            if let summary = args.summary { skill.summary = summary }
            if let instructions = args.instructions { skill.instructions = instructions }
            if let symbol = args.symbol { skill.symbol = symbol }
        }
    }
}

struct SkillDuplicateAction: LLMDAction {
    typealias Args = SkillArgs
    typealias Output = OKOutput
    static let descriptor = ActionDescriptor(
        id: "skill.duplicate", summary: "Kopiert einen Skill", kind: .write, security: .localWrite,
        input: .object(["skill": skillReference], required: ["skill"]), output: .freeObject()
    )
    static func run(_ args: Args, context: ActionContext) async throws -> Output {
        let app = context.app
        var copy = try app.actionSkill(args.skill ?? "")
        copy.id = UUID()
        copy.name = AppModel.uniqueName("\(copy.displayName) (Kopie)", among: app.skills.map(\.name))
        copy.createdAt = Date()
        copy.updatedAt = Date()
        copy.provenance = context.mergedProvenance(copy.provenance)
        app.skills.append(copy)
        app.saveSkillLibrary()
        let made = copy
        context.undoGroup.add(UndoStep(label: "Skill kopieren", undo: { app.deleteSkill(made.id) }, redo: {
            app.skills.append(made)
            app.saveSkillLibrary()
        }))
        return OKOutput(id: made.id.uuidString)
    }
}

struct SkillMoveAction: LLMDAction {
    typealias Args = SkillArgs
    typealias Output = OKOutput
    static let descriptor = ActionDescriptor(
        id: "skill.move", summary: "Legt einen Skill in einen Ordner; ohne folder ganz nach oben", kind: .write, security: .localWrite,
        input: .object(["skill": skillReference, "folder": .string("Ordner (ID oder Name)")], required: ["skill"]), output: .freeObject()
    )
    static func run(_ args: Args, context: ActionContext) async throws -> Output {
        let folder = try args.folder.map { reference -> UUID in
            guard let found = context.app.skillFolders.first(where: { $0.id.uuidString == reference || $0.name.localizedCaseInsensitiveCompare(reference) == .orderedSame }) else {
                throw RPCError.notFound("Ordner „\(reference)“ gibt es nicht.")
            }
            return found.id
        }
        return try changeSkill(args.skill, context: context, label: "Skill verschieben") { $0.folderID = folder }
    }
}

struct SkillImportAction: LLMDAction {
    typealias Args = SkillArgs
    typealias Output = OKOutput
    static let descriptor = ActionDescriptor(
        id: "skill.import", summary: "Liest einen Skill aus einer Markdown-Datei; er gilt als fremd, bis er bestätigt ist", kind: .write, security: .localWrite,
        input: .object(["file": .string("Pfad der .md-Datei")], required: ["file"]), output: .freeObject(), example: "llmd skill import --file ~/Skills/lektor.md"
    )
    static func preflight(_ args: Args, context: ActionContext) throws -> ActionPreflight {
        var check = ActionPreflight(readsUntrusted: true, target: args.file)
        if context.channel == .chat || context.channel == .mcp {
            check.needsConsent = "Eine Datei von dieser Stelle der Festplatte würde gelesen und ihr Inhalt für den Aufrufer sichtbar."
        }
        return check
    }
    static func run(_ args: Args, context: ActionContext) async throws -> Output {
        let app = context.app
        let url = ActionExportFolder.expanded(args.file ?? "")
        guard let data = try? Data(contentsOf: url), let text = String(data: data, encoding: .utf8) else { throw RPCError.notFound("Die Datei \(url.path) lässt sich nicht lesen.") }
        let skill = SkillFile.skill(from: text, fallbackName: url.deletingPathExtension().lastPathComponent)
        guard !skill.instructions.isEmpty else { throw RPCError.invalidTarget("In dieser Datei stehen keine Anweisungen.") }
        app.skills.insert(skill, at: 0)
        app.saveSkillLibrary()
        context.undoGroup.add(UndoStep(label: "Skill importieren", undo: { app.deleteSkill(skill.id) }, redo: {
            app.skills.insert(skill, at: 0)
            app.saveSkillLibrary()
        }))
        return OKOutput(id: skill.id.uuidString)
    }
}

struct SkillExportAction: LLMDAction {
    typealias Args = SkillArgs
    typealias Output = WriterExportAction.Output
    static let descriptor = ActionDescriptor(
        id: "skill.export", summary: "Schreibt einen Skill in eine Markdown-Datei", kind: .destructive, security: .outbound,
        input: .object(["skill": skillReference, "path": .string("Zieldatei; ohne Angabe im Exportordner"), "overwrite": .boolean("Eine vorhandene Datei ersetzen")], required: ["skill"]), output: .freeObject()
    )
    static func preflight(_ args: Args, context: ActionContext) throws -> ActionPreflight {
        let skill = try context.app.actionSkill(args.skill ?? "")
        return context.exportPreflight(path: args.path, readsUntrusted: skill.provenance == .foreign, readsSensitive: false, detail: skill.displayName)
    }
    static func run(_ args: Args, context: ActionContext) async throws -> Output {
        let skill = try context.app.actionSkill(args.skill ?? "")
        let url = try context.exportURL(named: skill.displayName, extension: "md", path: args.path, overwrite: args.overwrite)
        let data = Data(SkillFile.markdown(of: skill).utf8)
        try data.write(to: url, options: .atomic)
        return Output(path: url.path, bytes: data.count)
    }
}

struct SkillDeleteAction: LLMDAction {
    typealias Args = SkillArgs
    typealias Output = OKOutput
    static let descriptor = ActionDescriptor(
        id: "skill.delete", summary: "Löscht einen Skill", kind: .destructive, security: .destructive,
        input: .object(["skill": skillReference], required: ["skill"]), output: .freeObject()
    )
    static func preflight(_ args: Args, context: ActionContext) throws -> ActionPreflight {
        ActionPreflight(target: try context.app.actionSkill(args.skill ?? "").displayName)
    }
    static func run(_ args: Args, context: ActionContext) async throws -> Output {
        let skill = try context.app.actionSkill(args.skill ?? "")
        context.app.deleteSkill(skill.id)
        return OKOutput(id: skill.id.uuidString)
    }
}

// MARK: Personas

struct PersonaArgs: Decodable, Sendable {
    var persona: String?
    var name: String?
    var biography: String?
    var behavior: String?
    var voice: String?
    var voiceStyle: String?
    var file: String?
    var files: [String]?
    var title: String?
}

private let personaReference: JSONSchema = .string("Persona (ID oder Name)")

struct PersonaReadAction: LLMDAction {
    typealias Args = PersonaArgs
    struct Output: Encodable, Sendable {
        var id: String
        var name: String
        var biography: String
        var behavior: String
        var voice: String?
        var voiceStyle: String?
        var files: [String]
        var chats: Int
    }
    static let descriptor = ActionDescriptor(
        id: "persona.read", summary: "Liest eine Persona ohne den Inhalt ihrer Dateien", kind: .read, security: .plainRead,
        input: .object(["persona": personaReference], required: ["persona"]), output: .freeObject()
    )
    static func run(_ args: Args, context: ActionContext) async throws -> Output {
        let persona = try context.app.actionPersona(args.persona ?? "")
        return Output(id: persona.id.uuidString, name: persona.displayName, biography: persona.biography, behavior: persona.behavior, voice: persona.voice, voiceStyle: persona.voiceStyle,
                      files: (persona.files ?? []).map(\.name), chats: context.app.chatCount(withPersona: persona.id))
    }
}

struct PersonaCreateAction: LLMDAction {
    typealias Args = PersonaArgs
    typealias Output = OKOutput
    static let descriptor = ActionDescriptor(
        id: "persona.create", summary: "Legt eine Persona an", kind: .write, security: .localWrite,
        input: .object(["name": .string("Name"), "biography": .string("Biografie"), "behavior": .string("Verhalten"), "voice": .string("Stimme"), "voiceStyle": .string("Art zu sprechen")], required: ["name"]), output: .freeObject()
    )
    static func run(_ args: Args, context: ActionContext) async throws -> Output {
        let app = context.app
        var persona = Persona(name: args.name ?? "", biography: args.biography ?? "", behavior: args.behavior ?? "")
        persona.voice = args.voice
        persona.voiceStyle = args.voiceStyle
        app.personas.insert(persona, at: 0)
        app.savePersona(persona.id)
        let made = persona
        context.undoGroup.add(UndoStep(label: "Persona anlegen", undo: { app.deletePersona(made.id) }, redo: {
            app.personas.insert(made, at: 0)
            app.savePersona(made.id)
        }))
        return OKOutput(id: made.id.uuidString)
    }
}

struct PersonaUpdateAction: LLMDAction {
    typealias Args = PersonaArgs
    typealias Output = OKOutput
    static let descriptor = ActionDescriptor(
        id: "persona.update", summary: "Ändert eine Persona", kind: .write, security: .localWrite,
        input: .object(["persona": personaReference, "name": .string("Name"), "biography": .string("Biografie"), "behavior": .string("Verhalten"), "voice": .string("Stimme"), "voiceStyle": .string("Art zu sprechen")], required: ["persona"]), output: .freeObject()
    )
    static func run(_ args: Args, context: ActionContext) async throws -> Output {
        let app = context.app
        let before = try app.actionPersona(args.persona ?? "")
        let id = before.id
        app.updatePersona(id, saveAfter: nil) { persona in
            if let name = args.name { persona.name = name }
            if let biography = args.biography { persona.biography = biography }
            if let behavior = args.behavior { persona.behavior = behavior }
            if let voice = args.voice { persona.voice = voice }
            if let style = args.voiceStyle { persona.voiceStyle = style }
        }
        if let after = app.persona(id) {
            context.undoGroup.add(UndoStep(label: "Persona ändern", undo: { app.updatePersona(id, saveAfter: nil) { $0 = before } }, redo: { app.updatePersona(id, saveAfter: nil) { $0 = after } }))
        }
        return OKOutput(id: id.uuidString)
    }
}

struct PersonaAvatarSetAction: LLMDAction {
    typealias Args = PersonaArgs
    typealias Output = OKOutput
    static let descriptor = ActionDescriptor(
        id: "persona.avatar.set", summary: "Gibt einer Persona ein Bild", kind: .write, security: .localWrite,
        input: .object(["persona": personaReference, "file": .string("Pfad der Bilddatei")], required: ["persona", "file"]), output: .freeObject()
    )
    static func preflight(_ args: Args, context: ActionContext) throws -> ActionPreflight {
        var check = ActionPreflight(target: args.file)
        if context.channel == .chat || context.channel == .mcp {
            check.needsConsent = "Ein Bild von dieser Stelle der Festplatte käme in die Bibliothek und wäre danach für den Aufrufer sichtbar."
        }
        return check
    }
    static func run(_ args: Args, context: ActionContext) async throws -> Output {
        let app = context.app
        let persona = try app.actionPersona(args.persona ?? "")
        let url = ActionExportFolder.expanded(args.file ?? "")
        guard FileManager.default.fileExists(atPath: url.path) else { throw RPCError.notFound("Die Datei \(url.path) gibt es nicht.") }
        do {
            let result = try PersonaStore.importAvatar(.file(url), for: persona.id)
            app.updatePersona(persona.id, saveAfter: nil) {
                $0.avatarFileName = result.fileName
                $0.tint = result.tint
            }
        } catch {
            throw RPCError.invalidTarget(error.localizedDescription)
        }
        return OKOutput(id: persona.id.uuidString)
    }
}

struct PersonaAvatarRemoveAction: LLMDAction {
    typealias Args = PersonaArgs
    typealias Output = OKOutput
    static let descriptor = ActionDescriptor(
        id: "persona.avatar.remove", summary: "Nimmt einer Persona ihr Bild", kind: .write, security: .localWrite,
        input: .object(["persona": personaReference], required: ["persona"]), output: .freeObject()
    )
    static func run(_ args: Args, context: ActionContext) async throws -> Output {
        let persona = try context.app.actionPersona(args.persona ?? "")
        context.app.removeAvatar(of: persona.id)
        return OKOutput(id: persona.id.uuidString)
    }
}

/// A persona's files are private: nothing outside the app gets at them or adds to them (the rule refuses MCP).
private let personaFileSecurity = ActionSecurity(readsUntrusted: false, sensitive: true, effect: .local)

struct PersonaFilesAddAction: LLMDAction {
    typealias Args = PersonaArgs
    struct Output: Encodable, Sendable {
        var added: [String]
    }
    static let descriptor = ActionDescriptor(
        id: "persona.files.add", summary: "Gibt einer Persona Dateien, die sie lesen darf", kind: .write, security: personaFileSecurity,
        input: .object(["persona": personaReference, "files": .array(of: .string(), "Pfade der Dateien")], required: ["persona", "files"]), output: .freeObject()
    )
    static func preflight(_ args: Args, context: ActionContext) throws -> ActionPreflight {
        var check = ActionPreflight(target: try context.app.actionPersona(args.persona ?? "").displayName)
        if context.channel != .ui, context.channel != .cli { check.needsConsent = "Dateien von dieser Stelle der Festplatte kämen in die Bibliothek." }
        return check
    }
    static func run(_ args: Args, context: ActionContext) async throws -> Output {
        let app = context.app
        let persona = try app.actionPersona(args.persona ?? "")
        var added: [String] = []
        for path in args.files ?? [] {
            let url = ActionExportFolder.expanded(path)
            guard FileManager.default.fileExists(atPath: url.path) else { throw RPCError.notFound("Die Datei \(url.path) gibt es nicht.") }
            let taken = Set((app.persona(persona.id)?.files ?? []).map(\.name))
            do {
                let file = try PersonaStore.importFile(url, for: persona.id, takenNames: taken)
                app.updatePersona(persona.id, saveAfter: nil) { $0.files = ($0.files ?? []) + [file] }
                added.append(file.name)
            } catch {
                throw RPCError.invalidTarget(error.localizedDescription)
            }
        }
        return Output(added: added)
    }
}

struct PersonaFilesRemoveAction: LLMDAction {
    typealias Args = PersonaArgs
    typealias Output = OKOutput
    static let descriptor = ActionDescriptor(
        id: "persona.files.remove", summary: "Nimmt einer Persona Dateien", kind: .write, security: personaFileSecurity,
        input: .object(["persona": personaReference, "files": .array(of: .string(), "Namen der Dateien")], required: ["persona", "files"]), output: .freeObject()
    )
    static func run(_ args: Args, context: ActionContext) async throws -> Output {
        let persona = try context.app.actionPersona(args.persona ?? "")
        for name in args.files ?? [] {
            guard let file = persona.files?.first(where: { $0.name == name }) else { throw RPCError.notFound("Die Datei „\(name)“ gibt es bei dieser Persona nicht.") }
            context.app.removeFile(file.id, from: persona.id)
        }
        return OKOutput(id: persona.id.uuidString)
    }
}

struct PersonaVoicePreviewAction: LLMDAction {
    typealias Args = PersonaArgs
    typealias Output = OKOutput
    static let descriptor = ActionDescriptor(
        id: "persona.voice.preview", summary: "Lässt die Stimme einer Persona einen kurzen Satz sprechen", kind: .write, security: .localWrite,
        input: .object(["persona": personaReference], required: ["persona"]), output: .freeObject()
    )
    static func run(_ args: Args, context: ActionContext) async throws -> Output {
        let persona = try context.app.actionPersona(args.persona ?? "")
        context.app.previewVoice(of: persona.id)
        return OKOutput(id: persona.id.uuidString)
    }
}

struct PersonaStartChatAction: LLMDAction {
    typealias Args = PersonaArgs
    typealias Output = OKOutput
    static let descriptor = ActionDescriptor(
        id: "persona.startChat", summary: "Legt einen neuen Chat mit einer Persona an, ohne ihn zu öffnen", kind: .write, security: .localWrite,
        input: .object(["persona": personaReference, "title": .string("Titel")], required: ["persona"]), output: .freeObject()
    )
    static func run(_ args: Args, context: ActionContext) async throws -> Output {
        let app = context.app
        let persona = try app.actionPersona(args.persona ?? "")
        var chat = Chat(title: args.title ?? persona.displayName, modelId: app.currentModelId)
        chat.hasCustomTitle = args.title != nil
        chat.personaID = persona.id
        chat.contextLength = app.provider.loadsModels ? app.newChatContextLength : nil
        let made = chat
        app.addChatFromAction(made)
        context.undoGroup.add(UndoStep(label: "Chat anlegen", undo: { app.deleteChat(made.id) }, redo: { app.addChatFromAction(made) }))
        return OKOutput(id: made.id.uuidString)
    }
}

struct PersonaDeleteAction: LLMDAction {
    typealias Args = PersonaArgs
    typealias Output = OKOutput
    static let descriptor = ActionDescriptor(
        id: "persona.delete", summary: "Löscht eine Persona mit ihren Dateien und ihrem Gedächtnis", kind: .destructive, security: .destructive,
        input: .object(["persona": personaReference], required: ["persona"]), output: .freeObject()
    )
    static func preflight(_ args: Args, context: ActionContext) throws -> ActionPreflight {
        ActionPreflight(target: try context.app.actionPersona(args.persona ?? "").displayName)
    }
    static func run(_ args: Args, context: ActionContext) async throws -> Output {
        let persona = try context.app.actionPersona(args.persona ?? "")
        context.app.deletePersona(persona.id)
        return OKOutput(id: persona.id.uuidString)
    }
}

// MARK: Memory

struct MemoryArgs: Decodable, Sendable {
    var persona: String?
    var item: String?
    var all: Bool?
}

struct MemoryConsolidateAction: LLMDAction {
    typealias Args = MemoryArgs
    typealias Output = OKOutput
    static let descriptor = ActionDescriptor(
        id: "memory.consolidate", summary: "Verdichtet das Gedächtnis einer Persona jetzt, oder alles Liegengebliebene; läuft im Hintergrund", kind: .write,
        security: ActionSecurity(readsUntrusted: false, sensitive: true, effect: .local),
        input: .object(["persona": personaReference, "all": .boolean("Alle Personas")]), output: .freeObject()
    )
    static func run(_ args: Args, context: ActionContext) async throws -> Output {
        if args.all == true {
            context.app.catchUpThalamus()
            return OKOutput(message: "Läuft.")
        }
        guard let reference = args.persona else { throw RPCError.invalidParams("Bitte persona oder all angeben.") }
        let persona = try context.app.actionPersona(reference)
        context.app.consolidateAllThalamus(of: persona.id)
        return OKOutput(id: persona.id.uuidString, message: "Läuft.")
    }
}

struct MemoryConsolidateCancelAction: LLMDAction {
    typealias Output = OKOutput
    static let descriptor = ActionDescriptor(
        id: "memory.consolidate.cancel", summary: "Bricht das Verdichten des Gedächtnisses ab", kind: .write,
        security: ActionSecurity(readsUntrusted: false, sensitive: true, effect: .local), output: .freeObject()
    )
    static func run(_ args: NoArgs, context: ActionContext) async throws -> Output {
        context.app.cancelThalamusConsolidation()
        return OKOutput()
    }
}

private let memoryDeleteSecurity = ActionSecurity(readsUntrusted: false, sensitive: true, effect: .destructive)

struct MemoryDeleteAction: LLMDAction {
    typealias Args = MemoryArgs
    typealias Output = OKOutput
    static let descriptor = ActionDescriptor(
        id: "memory.delete", summary: "Löscht einen Eindruck, eine Erinnerung oder einen Fakt", kind: .destructive, security: memoryDeleteSecurity,
        input: .object(["persona": personaReference, "item": .string("ID aus memory.list")], required: ["persona", "item"]), output: .freeObject()
    )
    static func preflight(_ args: Args, context: ActionContext) throws -> ActionPreflight {
        ActionPreflight(target: try context.app.actionPersona(args.persona ?? "").displayName)
    }
    static func run(_ args: Args, context: ActionContext) async throws -> Output {
        let app = context.app
        let persona = try app.actionPersona(args.persona ?? "")
        let library = app.thalamus[persona.id] ?? ThalamusLibrary()
        guard let id = args.item.flatMap(UUID.init(uuidString:)) else { throw RPCError.invalidParams("Das ist keine ID aus memory.list.") }
        if library.entries.contains(where: { $0.id == id }) {
            app.deleteThalamusImpression(id, of: persona.id)
        } else if library.memories?.contains(where: { $0.id == id }) == true {
            app.deleteThalamusMemory(id, of: persona.id)
        } else if library.profile?.contains(where: { $0.id == id }) == true {
            app.deleteThalamusFact(id, of: persona.id)
        } else {
            throw RPCError.notFound("Das gibt es im Gedächtnis dieser Persona nicht.")
        }
        return OKOutput(id: id.uuidString)
    }
}

struct MemoryDeleteAllAction: LLMDAction {
    typealias Args = MemoryArgs
    typealias Output = OKOutput
    static let descriptor = ActionDescriptor(
        id: "memory.deleteAll", summary: "Löscht das ganze Gedächtnis einer Persona", kind: .destructive, security: memoryDeleteSecurity,
        input: .object(["persona": personaReference], required: ["persona"]), output: .freeObject()
    )
    static func preflight(_ args: Args, context: ActionContext) throws -> ActionPreflight {
        ActionPreflight(target: try context.app.actionPersona(args.persona ?? "").displayName)
    }
    static func run(_ args: Args, context: ActionContext) async throws -> Output {
        let persona = try context.app.actionPersona(args.persona ?? "")
        context.app.deleteAllThalamus(of: persona.id)
        return OKOutput(id: persona.id.uuidString)
    }
}
