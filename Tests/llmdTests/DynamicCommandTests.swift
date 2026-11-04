import Testing
import Foundation
import LLMDProtocol
@testable import llmd

@Suite("llmd: Befehle aus Schemas")
struct DynamicCommandTests {
    private let bold = ActionDescriptor(
        id: "writer.format.bold", summary: "Fett", kind: .write, security: ActionSecurity(readsUntrusted: false, sensitive: false, effect: .local),
        input: .object(["doc": .string(), "match": .string(), "state": .choice(["toggle", "on", "off"]), "occurrence": .integer(), "whole": .boolean()], required: ["doc"])
    )
    private let insert = ActionDescriptor(
        id: "writer.text.insertMarkdown", summary: "Markdown", kind: .write, security: ActionSecurity(readsUntrusted: false, sensitive: false, effect: .local),
        input: .object(["doc": .string(), "markdown": .string()], required: ["doc", "markdown"])
    )
    private let read = ActionDescriptor(
        id: "writer.doc.read", summary: "Lesen", kind: .read, security: ActionSecurity(readsUntrusted: false, sensitive: false, effect: .none),
        input: .object(["doc": .string()], required: ["doc"])
    )

    @Test func kebabAndCamelAreInverses() {
        #expect(DynamicCommand.kebab("insertMarkdown") == "insert-markdown")
        #expect(DynamicCommand.camel("insert-markdown") == "insertMarkdown")
        #expect(DynamicCommand.camel("doc") == "doc")
    }

    @Test func wordsFindTheAction() throws {
        let found = try #require(DynamicCommand.resolve(words: ["writer", "text", "insert-markdown", "--doc", "X"], actions: [bold, insert, read]))
        #expect(found.0.id == "writer.text.insertMarkdown")
        #expect(found.1 == ["--doc", "X"])
    }

    @Test func unknownWordsFindNothing() {
        #expect(DynamicCommand.resolve(words: ["writer", "gibtsnicht"], actions: [bold, insert, read]) == nil)
    }

    @Test func optionsAreTypedBySchema() throws {
        let args = try DynamicCommand.arguments(["--doc", "X", "--occurrence", "2", "--whole", "--state=on"], descriptor: bold, globals: .init())
        #expect(args == ["doc": "X", "occurrence": 2, "whole": true, "state": "on"])
    }

    @Test func requiredParametersMayBePositional() throws {
        let args = try DynamicCommand.arguments(["X", "# Titel"], descriptor: insert, globals: .init())
        #expect(args == ["doc": "X", "markdown": "# Titel"])
    }

    @Test func unknownOptionIsAUsageError() {
        #expect(throws: UsageError.self) { try DynamicCommand.arguments(["--dok", "X"], descriptor: bold, globals: .init()) }
    }

    @Test func extraWordIsAUsageError() {
        #expect(throws: UsageError.self) { try DynamicCommand.arguments(["X", "Y"], descriptor: read, globals: .init()) }
    }

    @Test func wrongNumberIsAUsageError() {
        #expect(throws: UsageError.self) { try DynamicCommand.arguments(["--occurrence", "zwei"], descriptor: bold, globals: .init()) }
    }

    @Test func stdinGoesIntoTheTextParameter() throws {
        var globals = LLMDCommandLine.Globals()
        globals.stdin = true
        let args = try DynamicCommand.arguments(["X"], descriptor: insert, globals: globals, readInput: { "aus stdin" })
        #expect(args == ["doc": "X", "markdown": "aus stdin"])
    }

    @Test func stdinWithoutTextParameterIsAUsageError() {
        var globals = LLMDCommandLine.Globals()
        globals.stdin = true
        #expect(throws: UsageError.self) { try DynamicCommand.arguments(["X"], descriptor: read, globals: globals, readInput: { "" }) }
    }

    @Test func argsObjectIsMerged() throws {
        let args = try DynamicCommand.arguments(["--args", #"{"doc":"X","occurrence":3}"#], descriptor: bold, globals: .init())
        #expect(args == ["doc": "X", "occurrence": 3])
    }

    @Test func globalsAreFoundAnywhere() throws {
        let globals = try LLMDCommandLine.parseGlobals(["writer", "--json", "doc", "read", "--run", "r1", "X", "--quiet"], environment: [:])
        #expect(globals.json && globals.quiet)
        #expect(globals.run == "r1")
        #expect(globals.rest == ["writer", "doc", "read", "X"])
    }

    @Test func runComesFromTheEnvironment() throws {
        #expect(try LLMDCommandLine.parseGlobals([], environment: ["LLMD_RUN": "r2"]).run == "r2")
    }

    @Test func batchLinesAreChecked() throws {
        #expect(try DynamicCommand.batchSteps(from: #"{"id":"a.b"}"# + "\n\n" + #"{"id":"c.d","args":{}}"#).count == 2)
        #expect(throws: UsageError.self) { try DynamicCommand.batchSteps(from: "kein json") }
        #expect(throws: UsageError.self) { try DynamicCommand.batchSteps(from: "") }
    }

    @Test func exitCodesFollowTheError() {
        #expect(ExitCode.of(RPCError.denied("nein")) == ExitCode.denied)
        #expect(ExitCode.of(RPCError.methodNotFound("x")) == ExitCode.usage)
        #expect(ExitCode.of(RPCError.notFound("x")) == ExitCode.notFound)
        #expect(ExitCode.of(RPCError.versionConflict(current: "a")) == ExitCode.conflict)
        #expect(ExitCode.of(LLMDClient.Failure.closed) == ExitCode.unreachable)
    }

    @Test func humanOutputShowsTextAndLists() {
        #expect(Output.human(["id": "1", "text": "Inhalt"]).hasSuffix("Inhalt"))
        #expect(Output.human(["documents": [["id": "1", "title": "A"], ["id": "2", "title": "B"]]]) == "1\tA\n2\tB")
    }

    @Test func zshCompletionNamesActionsAndOptions() {
        let script = Completion.zsh(actions: [bold])
        #expect(script.contains("#compdef llmd"))
        #expect(script.contains("writer format bold"))
        #expect(script.contains("--occurrence"))
    }
}
