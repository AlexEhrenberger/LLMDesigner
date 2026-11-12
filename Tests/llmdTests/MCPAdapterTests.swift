import Testing
import Foundation
import LLMDProtocol
@testable import llmd

/// A stand-in for the app with fixed answers.
final class FakeBackend: MCPBackend {
    var calls: [(String, JSONValue)] = []
    var actions: [ActionDescriptor] = FakeBackend.defaultActions
    var failure: RPCError?
    var results: [String: JSONValue] = [:]

    static let local = ActionSecurity(readsUntrusted: false, sensitive: false, effect: .local)
    static let read = ActionSecurity(readsUntrusted: false, sensitive: false, effect: .none)
    static let defaultActions = [
        ActionDescriptor(id: "writer.format.bold", summary: "Fett", kind: .write, security: local,
                         input: .object(["doc": .string("Dokument"), "state": .choice(["on", "off"])], required: ["doc"]), output: .freeObject(), groups: ["core", "writer.core"]),
        ActionDescriptor(id: "writer.doc.delete", summary: "Löschen", kind: .destructive, security: ActionSecurity(readsUntrusted: false, sensitive: false, effect: .destructive), input: .object(), groups: []),
        ActionDescriptor(id: "writer.export", summary: "Export", kind: .destructive, security: ActionSecurity(readsUntrusted: false, sensitive: false, effect: .outbound), input: .object(), groups: ["core"]),
        ActionDescriptor(id: "presenter.slide.add", summary: "Folie", kind: .write, security: local, input: .object(), groups: ["presenter.core"]),
        ActionDescriptor(id: "memory.list", summary: "Gedächtnis", kind: .destructive, security: ActionSecurity(readsUntrusted: false, sensitive: true, effect: .none), input: .object(), groups: ["chat.private"]),
        ActionDescriptor(id: "actions.list", summary: "Liste", kind: .read, security: read, input: .object(), groups: []),
        ActionDescriptor(id: "app.status", summary: "Status", kind: .read, security: read, input: .object(), groups: ["core"]),
        ActionDescriptor(id: "persona.list", summary: "Personas", kind: .read, security: read, input: .object(), groups: ["core", "chat.core"]),
    ]

    func run(_ action: String, args: JSONValue) throws -> JSONValue {
        calls.append((action, args))
        if action == "actions.list" { return ["actions": try JSONValue.encoding(actions)] }
        if let failure { throw failure }
        return results[action] ?? ["ok": true]
    }
}

@Suite("MCP: Übersetzung")
struct MCPAdapterTests {
    private let modernMeta: JSONValue = ["io.modelcontextprotocol/protocolVersion": "2026-07-28", "io.modelcontextprotocol/clientCapabilities": [:]]

    private func request(_ method: String, _ params: [String: JSONValue] = [:], id: Int = 1) -> RPCMessage {
        var params = params
        params["_meta"] = modernMeta
        return RPCMessage(id: .int(id), method: method, params: .object(params))
    }

    /// As it arrives on stdin.
    private func recorded(_ line: String) throws -> RPCMessage {
        try JSONDecoder().decode(RPCMessage.self, from: Data(line.utf8))
    }

    // Both ways of opening a session.

    @Test func discoverAnswersAsTheSpecificationShows() throws {
        let adapter = MCPAdapter(backend: FakeBackend(), profile: "core", serverVersion: "1.2")
        let line = #"{"jsonrpc":"2.0","id":"discover-1","method":"server/discover","params":{"_meta":{"io.modelcontextprotocol/protocolVersion":"2026-07-28","io.modelcontextprotocol/clientInfo":{"name":"ExampleClient","version":"1.0.0"},"io.modelcontextprotocol/clientCapabilities":{}}}}"#
        let answer = try #require(adapter.handle(try recorded(line)).first)
        #expect(answer.id == .string("discover-1"))
        let result = try #require(answer.result)
        #expect(result["resultType"] == "complete")
        #expect(result["supportedVersions"]?.arrayValue?.contains("2026-07-28") == true)
        #expect(result["capabilities"]?["tools"] != nil)
        #expect(result["_meta"]?["io.modelcontextprotocol/serverInfo"]?["version"] == "1.2")
        #expect(result["cacheScope"] == "public")
        #expect(result["ttlMs"]?.intValue != nil)
    }

    @Test func discoverWorksWithoutAVersion() throws {
        let adapter = MCPAdapter(backend: FakeBackend(), profile: "core")
        let answer = adapter.handle(RPCMessage(id: .int(1), method: "server/discover"))
        #expect(answer.first?.result?["supportedVersions"] != nil)
    }

    @Test func aLegacyClientGetsItsHandshake() throws {
        let adapter = MCPAdapter(backend: FakeBackend(), profile: "core")
        let open = #"{"jsonrpc":"2.0","id":0,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"claude-code","version":"2.0.0"}}}"#
        let answer = try #require(adapter.handle(try recorded(open)).first?.result)
        #expect(answer["protocolVersion"] == "2025-06-18")
        #expect(answer["serverInfo"]?["name"] == "llmd")
        #expect(answer["capabilities"]?["tools"] != nil)
        #expect(adapter.handle(try recorded(#"{"jsonrpc":"2.0","method":"notifications/initialized"}"#)).isEmpty)
        let list = try #require(adapter.handle(try recorded(#"{"jsonrpc":"2.0","id":1,"method":"tools/list"}"#)).first?.result)
        #expect(list["tools"]?.arrayValue?.isEmpty == false)
        // No fields of the new revision in an old session.
        #expect(list["resultType"] == nil)
        #expect(list["ttlMs"] == nil)
        #expect(adapter.handle(try recorded(#"{"jsonrpc":"2.0","id":2,"method":"ping"}"#)).first?.result == .object([:]))
    }

    @Test func anUnknownLegacyVersionGetsTheNewestLegacyOne() throws {
        let adapter = MCPAdapter(backend: FakeBackend(), profile: "core")
        let answer = adapter.handle(RPCMessage(id: .int(0), method: "initialize", params: ["protocolVersion": "1999-01-01"]))
        #expect(answer.first?.result?["protocolVersion"] == "2025-11-25")
    }

    @Test func anUnknownVersionIsRefusedWithTheList() {
        let adapter = MCPAdapter(backend: FakeBackend(), profile: "core")
        let answer = adapter.handle(RPCMessage(id: .int(1), method: "tools/list", params: ["_meta": ["io.modelcontextprotocol/protocolVersion": "1900-01-01"]]))
        #expect(answer.first?.error?.code == -32022)
        #expect(answer.first?.error?.data?["requested"] == "1900-01-01")
        #expect(answer.first?.error?.data?["supported"]?.arrayValue?.contains("2026-07-28") == true)
    }

    @Test func aModernRequestWithoutMetaIsRefused() {
        let adapter = MCPAdapter(backend: FakeBackend(), profile: "core")
        #expect(adapter.handle(RPCMessage(id: .int(1), method: "tools/list")).first?.error?.code == RPCError.invalidParamsCode)
    }

    @Test func unknownMethod() {
        let adapter = MCPAdapter(backend: FakeBackend(), profile: "core")
        #expect(adapter.handle(request("gibt/es/nicht")).first?.error?.code == RPCError.methodNotFoundCode)
    }

    // Tools.

    @Test func toolListFollowsTheSpecification() throws {
        let adapter = MCPAdapter(backend: FakeBackend(), profile: "full")
        let result = try #require(adapter.handle(request("tools/list")).first?.result)
        #expect(result["resultType"] == "complete")
        #expect(result["ttlMs"]?.intValue == MCPAdapter.toolListTTL)
        #expect(result["cacheScope"] == "public")
        let tools = try #require(result["tools"]?.arrayValue)
        let names = tools.compactMap { $0["name"]?.stringValue }
        #expect(Array(names.prefix(2)) == ["llmd_search_actions", "llmd_run_action"])
        #expect(names.dropFirst(2).elementsEqual(names.dropFirst(2).sorted()))
        let bold = try #require(tools.first { $0["name"] == "writer_format_bold" })
        #expect(bold["inputSchema"]?["$schema"] == "https://json-schema.org/draft/2020-12/schema")
        #expect(bold["inputSchema"]?["additionalProperties"] == false)
        #expect(bold["outputSchema"]?["type"] == "object")
        #expect(bold["annotations"]?["readOnlyHint"] == false)
        #expect(bold["annotations"]?["destructiveHint"] == false)
        let export = try #require(tools.first { $0["name"] == "writer_export" })
        #expect(export["annotations"]?["destructiveHint"] == true)
        #expect(export["annotations"]?["openWorldHint"] == true)
    }

    @Test func theOrderIsTheSameEveryTime() throws {
        let adapter = MCPAdapter(backend: FakeBackend(), profile: "full")
        #expect(try adapter.tools() == (try adapter.tools()))
    }

    @Test(arguments: [
        ("core", ["app_status", "persona_list", "writer_export", "writer_format_bold"]),
        ("writer", ["writer_doc_delete", "writer_export", "writer_format_bold"]),
        ("presenter", ["presenter_slide_add"]),
        ("chat", ["persona_list"]),
        ("full", ["app_status", "persona_list", "presenter_slide_add", "writer_doc_delete", "writer_export", "writer_format_bold"]),
    ])
    func profilesChooseTools(_ profile: String, _ expected: [String]) throws {
        let adapter = MCPAdapter(backend: FakeBackend(), profile: profile)
        let names = try adapter.tools().compactMap { $0["name"]?.stringValue }
        #expect(names == ["llmd_search_actions", "llmd_run_action"] + expected)
    }

    @Test func privateActionsAreInNoProfile() throws {
        for profile in MCPProfile.names {
            let names = try MCPAdapter(backend: FakeBackend(), profile: profile).tools().compactMap { $0["name"]?.stringValue }
            #expect(!names.contains("memory_list"))
        }
    }

    @Test func callGivesStructuredDataAndText() throws {
        let backend = FakeBackend()
        backend.results["writer.format.bold"] = ["doc": "d", "version": "v"]
        let adapter = MCPAdapter(backend: backend, profile: "core")
        let result = try #require(adapter.handle(request("tools/call", ["name": "writer_format_bold", "arguments": ["doc": "d"]])).first?.result)
        #expect(result["resultType"] == "complete")
        #expect(result["isError"] == false)
        #expect(result["structuredContent"]?["version"] == "v")
        #expect(result["content"]?.arrayValue?.first?["type"] == "text")
        #expect(backend.calls.last?.0 == "writer.format.bold")
        #expect(backend.calls.last?.1 == ["doc": "d"])
    }

    @Test func anActionErrorGoesToTheModelAsToolResult() throws {
        let backend = FakeBackend()
        backend.failure = .notFound("Dokument gibt es nicht.")
        let adapter = MCPAdapter(backend: backend, profile: "core")
        let result = try #require(adapter.handle(request("tools/call", ["name": "writer_format_bold", "arguments": [:]])).first?.result)
        #expect(result["isError"] == true)
        #expect(result["content"]?.arrayValue?.first?["text"] == "Dokument gibt es nicht.")
    }

    @Test func anUnknownToolIsAProtocolError() {
        let adapter = MCPAdapter(backend: FakeBackend(), profile: "core")
        #expect(adapter.handle(request("tools/call", ["name": "gibts_nicht"])).first?.error?.code == RPCError.invalidParamsCode)
    }

    @Test func aToolOutsideTheProfileIsUnknown() {
        let adapter = MCPAdapter(backend: FakeBackend(), profile: "presenter")
        #expect(adapter.handle(request("tools/call", ["name": "writer_export"])).first?.error?.code == RPCError.invalidParamsCode)
    }

    @Test func metaToolsFindAndRun() throws {
        let backend = FakeBackend()
        let adapter = MCPAdapter(backend: backend, profile: "core")
        let found = try #require(adapter.handle(request("tools/call", ["name": "llmd_search_actions", "arguments": ["query": "folie"]])).first?.result)
        #expect(found["structuredContent"]?["actions"]?.arrayValue?.map { $0["id"] } == ["presenter.slide.add"])
        let hidden = try #require(adapter.handle(request("tools/call", ["name": "llmd_search_actions", "arguments": ["query": "gedächtnis"]])).first?.result)
        #expect(hidden["structuredContent"]?["actions"]?.arrayValue?.isEmpty == true)
        let ran = try #require(adapter.handle(request("tools/call", ["name": "llmd_run_action", "arguments": ["id": "presenter.slide.add", "args": ["x": 1]]])).first?.result)
        #expect(ran["isError"] == false)
        #expect(backend.calls.last?.0 == "presenter.slide.add")
        let unknown = try #require(adapter.handle(request("tools/call", ["name": "llmd_run_action", "arguments": ["id": "gibt.es.nicht"]])).first?.result)
        #expect(unknown["isError"] == true)
    }

    @Test func aPictureGoesAsAPicture() {
        let result = MCPAdapter.success(["mimeType": "image/png", "width": 720, "imageBase64": "QUJD"])
        #expect(result["content"]?.arrayValue?.first?["type"] == "image")
        #expect(result["content"]?.arrayValue?.first?["data"] == "QUJD")
        #expect(result["structuredContent"]?["imageBase64"] == nil)
        #expect(!result["content"]!.arrayValue![1].jsonLine().contains("QUJD"))
    }

    // Resources and prompts.

    @Test func resourcesAreListedAndRead() throws {
        let backend = FakeBackend()
        backend.results["writer.doc.list"] = ["documents": [["id": "D1", "title": "Bericht"]]]
        backend.results["presenter.deck.list"] = ["decks": [["id": "P1", "title": "Vortrag"]]]
        backend.results["citation.source.list"] = ["sources": [["citekey": "mueller2020", "title": "Buch"]]]
        backend.results["stories.world.list"] = ["worlds": [["id": "W1", "title": "Eisland"]]]
        backend.results["writer.doc.read"] = ["text": "# Titel"]
        backend.results["citation.source.read"] = ["source": ["citekey": "mueller2020"]]
        let adapter = MCPAdapter(backend: backend, profile: "core")
        let list = try #require(adapter.handle(request("resources/list")).first?.result)
        #expect(list["resources"]?.arrayValue?.compactMap { $0["uri"]?.stringValue } == ["llmd://writer/doc/D1", "llmd://presenter/deck/P1", "llmd://citation/source/mueller2020", "llmd://stories/world/W1"])
        #expect(list["cacheScope"] == "private")

        let read = try #require(adapter.handle(request("resources/read", ["uri": "llmd://writer/doc/D1"])).first?.result)
        #expect(read["contents"]?.arrayValue?.first?["text"] == "# Titel")
        #expect(read["contents"]?.arrayValue?.first?["mimeType"] == "text/markdown")
        #expect(read["cacheScope"] == "private")
        let source = try #require(adapter.handle(request("resources/read", ["uri": "llmd://citation/source/mueller2020"])).first?.result)
        #expect(source["contents"]?.arrayValue?.first?["text"]?.stringValue?.contains("mueller2020") == true)

        let templates = try #require(adapter.handle(request("resources/templates/list")).first?.result)
        #expect(templates["resourceTemplates"]?.arrayValue?.count == 6)
    }

    @Test func aMissingResourceUsesTheSpecifiedError() {
        let backend = FakeBackend()
        backend.failure = .notFound("weg")
        let adapter = MCPAdapter(backend: backend, profile: "core")
        let error = adapter.handle(request("resources/read", ["uri": "llmd://writer/doc/X"])).first?.error
        #expect(error?.code == -32602)
        #expect(error?.data?["uri"] == "llmd://writer/doc/X")
        #expect(adapter.handle(request("resources/read", ["uri": "file:///etc/passwd"])).first?.error?.code == -32602)
        #expect(adapter.handle(request("resources/read", ["uri": "llmd://writer/doc/"])).first?.error?.code == -32602)
    }

    @Test func promptsComeFromSkillsWithoutForeignOnes() throws {
        let backend = FakeBackend()
        backend.results["skill.list"] = ["skills": [["name": "Kurz", "summary": "Antwortet kurz"], ["name": "Import", "summary": "x", "herkunft": "fremd"]]]
        backend.results["skill.read"] = ["summary": "Antwortet kurz", "instructions": "Antworte in zwei Sätzen."]
        let adapter = MCPAdapter(backend: backend, profile: "core")
        let list = try #require(adapter.handle(request("prompts/list")).first?.result)
        #expect(list["prompts"]?.arrayValue?.map { $0["name"] } == ["Kurz"])
        let prompt = try #require(adapter.handle(request("prompts/get", ["name": "Kurz"])).first?.result)
        #expect(prompt["messages"]?.arrayValue?.first?["content"]?["text"] == "Antworte in zwei Sätzen.")
    }

    // Subscriptions.

    @Test func listenIsAcknowledgedAndDelivers() throws {
        let adapter = MCPAdapter(backend: FakeBackend(), profile: "core")
        #expect(!adapter.hasSubscriptions)
        let uri = "llmd://writer/doc/D1"
        let answer = adapter.handle(request("subscriptions/listen", ["notifications": ["toolsListChanged": true, "resourcesListChanged": true, "resourceSubscriptions": [.string(uri)]]], id: 7))
        #expect(adapter.hasSubscriptions)
        let ack = try #require(answer.first)
        #expect(ack.id == nil)
        #expect(ack.method == "notifications/subscriptions/acknowledged")
        #expect(ack.params?["_meta"]?["io.modelcontextprotocol/subscriptionId"] == 7)
        // Tools don't change while this runs, so that part isn't agreed to.
        #expect(ack.params?["notifications"]?["toolsListChanged"] == nil)
        #expect(ack.params?["notifications"]?["resourceSubscriptions"]?.arrayValue == [.string(uri)])

        let updated = adapter.notifications(for: ActionEvent(kind: ActionEvent.documentChanged, target: "D1"))
        #expect(updated.map(\.method) == ["notifications/resources/updated"])
        #expect(updated.first?.params?["uri"] == .string(uri))
        #expect(updated.first?.params?["_meta"]?["io.modelcontextprotocol/subscriptionId"] == 7)
        #expect(adapter.notifications(for: ActionEvent(kind: ActionEvent.documentChanged, target: "D2")).isEmpty)
        #expect(adapter.notifications(for: ActionEvent(kind: ActionEvent.actionExecuted, action: "writer.doc.create")).map(\.method) == ["notifications/resources/list_changed"])
        #expect(adapter.notifications(for: ActionEvent(kind: ActionEvent.actionExecuted, action: "writer.format.bold")).isEmpty)

        let closing = adapter.closingMessages()
        #expect(closing.first?.id == .int(7))
        #expect(closing.first?.result?["resultType"] == "complete")

        _ = adapter.handle(RPCMessage(id: nil, method: "notifications/cancelled", params: ["requestId": 7]))
        #expect(!adapter.hasSubscriptions)
    }
}
