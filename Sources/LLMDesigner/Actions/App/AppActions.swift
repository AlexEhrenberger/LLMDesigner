import Foundation
import LLMDProtocol

extension ActionRegistry {
    func registerAppActions() {
        register(AppStatusAction.self)
        register(ActionsListAction.self)
        register(ActionsDescribeAction.self)
    }
}

/// Reads and changes nothing in the world beyond the result.
extension ActionSecurity {
    static let plainRead = ActionSecurity(readsUntrusted: false, sensitive: false, effect: .none)
    /// Reading content that may have been written by others: documents, web pages, imports.
    static let foreignRead = ActionSecurity(readsUntrusted: true, sensitive: false, effect: .none)
    static let sensitiveRead = ActionSecurity(readsUntrusted: false, sensitive: true, effect: .none)
    static let localWrite = ActionSecurity(readsUntrusted: false, sensitive: false, effect: .local)
    static let destructive = ActionSecurity(readsUntrusted: false, sensitive: false, effect: .destructive)
    static let outbound = ActionSecurity(readsUntrusted: false, sensitive: false, effect: .outbound)
}

struct AppStatusAction: LLMDAction {
    struct Output: Encodable, Sendable {
        var app: String
        var version: String
        var build: String?
        var library: String
        var provider: String
        var model: String?
        var actions: Int
    }

    static let descriptor = ActionDescriptor(
        id: "app.status", summary: "Zeigt Version, geöffnete Bibliothek und Modell", kind: .read, security: .plainRead,
        output: .freeObject(), example: "llmd status", groups: ["core"]
    )

    static func run(_ args: NoArgs, context: ActionContext) async throws -> Output {
        let info = Bundle.main.infoDictionary
        return Output(
            app: "LLM Designer",
            version: info?["CFBundleShortVersionString"] as? String ?? "dev",
            build: info?["CFBundleVersion"] as? String,
            library: AppLibrary.current.name,
            provider: context.app.provider.rawValue,
            model: context.app.currentModelId,
            actions: context.registry.descriptors.count
        )
    }
}

struct ActionsListAction: LLMDAction {
    struct Args: Decodable, Sendable {
        var module: String?
        var group: String?
    }
    struct Output: Encodable, Sendable {
        var version: String
        var actions: [ActionDescriptor]
    }

    static let descriptor = ActionDescriptor(
        id: "actions.list", summary: "Listet alle Actions mit Schema", kind: .read, security: .plainRead,
        input: .object(["module": .string("Nur dieses Modul, z. B. writer"), "group": .string("Nur diese Gruppe, z. B. writer.core")]),
        output: .freeObject(), example: "llmd actions --module writer"
    )

    static func run(_ args: Args, context: ActionContext) async throws -> Output {
        var actions = context.registry.descriptors
        if let module = args.module { actions = actions.filter { $0.module == module } }
        if let group = args.group { actions = actions.filter { $0.groups.contains(group) } }
        return Output(version: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev", actions: actions)
    }
}

struct ActionsDescribeAction: LLMDAction {
    struct Args: Decodable, Sendable {
        var id: String
    }

    static let descriptor = ActionDescriptor(
        id: "actions.describe", summary: "Beschreibt eine Action mit Schema und Beispiel", kind: .read, security: .plainRead,
        input: .object(["id": .string("ID der Action, z. B. writer.format.bold")], required: ["id"]),
        output: .freeObject(), example: "llmd describe writer.doc.read"
    )

    static func run(_ args: Args, context: ActionContext) async throws -> ActionDescriptor {
        guard let descriptor = context.registry.descriptor(args.id) else { throw RPCError.methodNotFound(args.id) }
        return descriptor
    }
}
