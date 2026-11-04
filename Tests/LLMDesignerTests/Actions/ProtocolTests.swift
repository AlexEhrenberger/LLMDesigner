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
