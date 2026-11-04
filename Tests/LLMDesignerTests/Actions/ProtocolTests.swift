import Testing
import Foundation
import LLMDProtocol
@testable import LLMDesigner

@Suite("Protokoll: JSON, Schema, Nachrichten")
struct ProtocolTests {
    @Test func jsonValueRoundTrips() throws {
        let value: JSONValue = ["a": 1, "b": [true, nil, "x"], "c": .double(1.5), "d": ["e": "f"]]
        #expect(try JSONValue.parse(value.jsonLine()) == value)
    }

    @Test func keysAreSorted() {
        let value: JSONValue = ["b": 1, "a": 2]
        #expect(value.jsonLine() == #"{"a":2,"b":1}"#)
    }

    @Test func schemaEncodesAsJSONSchema() throws {
        let schema = JSONSchema.object(["state": .choice(["on", "off"], "Zustand"), "tags": .array(of: .string())], required: ["state"])
        let value = try JSONValue.encoding(schema)
        #expect(value["type"] == "object")
        #expect(value["additionalProperties"] == false)
        #expect(value["properties"]?["state"]?["enum"] == ["on", "off"])
        #expect(value["properties"]?["tags"]?["items"]?["type"] == "string")
        #expect(schema.document["$schema"] == "https://json-schema.org/draft/2020-12/schema")
        #expect(try value.decoded(as: JSONSchema.self) == schema)
    }

    @Test func schemaFindsProblems() {
        let schema = JSONSchema.object(["n": .integer(minimum: 1, maximum: 3), "s": .choice(["a"]), "l": .array(of: .integer())], required: ["s"])
        #expect(schema.problems(with: ["s": "a", "n": 2, "l": [1, 2]]).isEmpty)
        #expect(schema.problems(with: ["n": 2]).contains { $0.contains("Pflichtparameter „s“") })
        #expect(schema.problems(with: ["s": "b"]).count == 1)
        #expect(schema.problems(with: ["s": "a", "n": 9]).count == 1)
        #expect(schema.problems(with: ["s": "a", "x": 1]).contains { $0.contains("Unbekannter Parameter „x“") })
        #expect(schema.problems(with: ["s": "a", "l": ["z"]]).count == 1)
        #expect(!schema.problems(with: 3).isEmpty)
    }

    @Test func messageRoundTrips() throws {
        let message = RPCMessage(id: .int(7), method: "action.run", params: ["id": "app.status"])
        let line = try message.line()
        #expect(line.last == 0x0A)
        #expect(try JSONDecoder().decode(RPCMessage.self, from: line) == message)
        let failure = RPCMessage(id: .string("a"), error: .notFound("weg"))
        #expect(try JSONDecoder().decode(RPCMessage.self, from: failure.line()).error?.code == RPCError.notFoundCode)
    }

    @Test func inconsistentDescriptorsAreFound() {
        let local = ActionSecurity(readsUntrusted: false, sensitive: false, effect: .local)
        #expect(ActionDescriptor(id: "a.b", summary: "x", kind: .read, security: local).inconsistency != nil)
        let outbound = ActionSecurity(readsUntrusted: false, sensitive: false, effect: .outbound)
        #expect(ActionDescriptor(id: "a.b", summary: "x", kind: .write, security: outbound).inconsistency != nil)
        #expect(ActionDescriptor(id: "kein", summary: "x", kind: .write, security: local).inconsistency != nil)
        #expect(ActionDescriptor(id: "a.b", summary: "", kind: .write, security: local).inconsistency != nil)
        #expect(ActionDescriptor(id: "a.b", summary: "x", kind: .write, security: local).inconsistency == nil)
    }
}

/// There is no validator package here, so this checks each published schema against the rules of JSON Schema 2020-12
/// that matter for what the builder can produce. A real validator ran once by hand (see the plan's progress notes).
@MainActor
@Suite("Schemas aller Actions")
struct AllSchemasTests {
    private static let keywords: Set<String> = ["type", "description", "properties", "required", "enum", "minimum", "maximum", "additionalProperties", "items", "$schema"]
    private static let types: Set<String> = ["string", "boolean", "integer", "number", "array", "object"]

    private func problems(_ schema: JSONValue, at path: String) -> [String] {
        guard let object = schema.objectValue else { return ["\(path): kein Objekt"] }
        var found: [String] = []
        for key in object.keys where !Self.keywords.contains(key) { found.append("\(path): unbekanntes Schlüsselwort \(key)") }
        if let type = object["type"]?.stringValue, !Self.types.contains(type) { found.append("\(path): Typ \(type)") }
        if let values = object["enum"]?.arrayValue, values.isEmpty || Set(values).count != values.count { found.append("\(path): enum") }
        if object["type"]?.stringValue == "array", object["items"] == nil { found.append("\(path): Liste ohne items") }
        if let required = object["required"]?.arrayValue {
            if Set(required).count != required.count { found.append("\(path): required doppelt") }
            for name in required.compactMap(\.stringValue) where object["properties"]?[name] == nil {
                found.append("\(path): required \(name) fehlt in properties")
            }
        }
        for (name, property) in object["properties"]?.objectValue ?? [:] { found += problems(property, at: "\(path).\(name)") }
        if let items = object["items"] { found += problems(items, at: "\(path)[]") }
        return found
    }

    @Test func everySchemaIsValid() {
        let registry = ActionRegistry.standard()
        #expect(registry.descriptors.count > 100)
        for descriptor in registry.descriptors {
            #expect(descriptor.input.type == "object", "\(descriptor.id)")
            #expect(descriptor.input.document["$schema"] == "https://json-schema.org/draft/2020-12/schema")
            #expect(problems(descriptor.input.document, at: descriptor.id).isEmpty, "\(problems(descriptor.input.document, at: descriptor.id))")
            if let output = descriptor.output {
                #expect(problems(output.document, at: "\(descriptor.id)→").isEmpty)
                #expect(output.type == "object", "\(descriptor.id): structuredContent ist ein Objekt")
            }
        }
    }

    /// Tool names on MCP may only hold letters, digits, `_`, `-` and `.`.
    @Test func everyIdMakesAValidToolName() {
        for descriptor in ActionRegistry.standard().descriptors {
            let name = descriptor.id.replacingOccurrences(of: ".", with: "_")
            #expect(name.range(of: #"^[A-Za-z0-9_-]{1,128}$"#, options: .regularExpression) != nil, "\(name)")
        }
    }

    @Test func toolNamesAreUnique() {
        let names = ActionRegistry.standard().descriptors.map { $0.id.replacingOccurrences(of: ".", with: "_") }
        #expect(Set(names).count == names.count)
    }

    @Test func privateActionsAreMarked() {
        let registry = ActionRegistry.standard()
        for id in ["memory.list", "memory.profile.get", "persona.files.search"] {
            #expect(registry.descriptor(id)?.security.sensitive == true, "\(id)")
        }
    }

    @Test func destructiveThingsAreKindD() {
        for descriptor in ActionRegistry.standard().descriptors where descriptor.security.effect == .destructive || descriptor.security.effect == .outbound {
            #expect(descriptor.kind == .destructive, "\(descriptor.id)")
        }
    }
}
