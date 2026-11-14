import Foundation
import LLMDProtocol

/// The commands of `llmd`. It parses by itself: the commands are made from the action schemas at run time, which a
/// fixed declaration of arguments can't express, and no dependency has to be downloaded.
enum LLMDCommandLine {
    struct Globals {
        var json = false
        var quiet = false
        var launch = true
        var run: String?
        var stdin = false
        var stdinTo: String?
        var rest: [String] = []
    }

    static let help = """
    llmd – LLM Designer aus dem Terminal

    Befehle:
      llmd status                     Version, Bibliothek, Modell
      llmd actions [--module NAME]    alle Actions
      llmd describe ID                eine Action mit Schema und Beispiel
      llmd call ID [--name wert …]    eine Action nach ID (auch --args '{…}')
      llmd <modul> <…> [--name wert]  dasselbe als Wörter: llmd writer format bold --doc X --match Wort
      llmd batch [DATEI]              JSONL ({"id":…,"args":{…}}) als eine Undo-Gruppe, Abbruch beim ersten Fehler
      llmd watch                      Ereignisse der App anzeigen
      llmd completion zsh             Tab-Vervollständigung ausgeben
      llmd mcp [--profile NAME]       MCP-Server über stdio

    Optionen: --json  --quiet  --stdin  --stdin-to NAME  --no-launch  --run ID
    """

    /// Global options may stand anywhere.
    static func parseGlobals(_ arguments: [String], environment: [String: String] = ProcessInfo.processInfo.environment) throws -> Globals {
        var globals = Globals()
        globals.run = environment["LLMD_RUN"]
        var index = 0
        while index < arguments.count {
            let argument = arguments[index]
            switch argument {
            case "--json": globals.json = true
            case "--quiet": globals.quiet = true
            case "--no-launch": globals.launch = false
            case "--stdin": globals.stdin = true
            case "--run", "--stdin-to":
                index += 1
                guard index < arguments.count else { throw UsageError(message: "\(argument) braucht einen Wert.") }
                if argument == "--run" { globals.run = arguments[index] } else {
                    globals.stdin = true
                    globals.stdinTo = arguments[index]
                }
            default:
                globals.rest.append(argument)
            }
            index += 1
        }
        return globals
    }

    static func main(arguments: [String]) async -> Int32 {
        // git's merge driver works on files only and must not need the app (a merge in the Terminal, a clone).
        if arguments.count >= 2, arguments[0] == "git", arguments[1] == "merge-file" {
            return MergeDriver.run(Array(arguments.dropFirst(2)))
        }
        do {
            let globals = try parseGlobals(arguments)
            return try await execute(globals)
        } catch {
            FileHandle.standardError.write(Data("Fehler: \(error.localizedDescription)\n".utf8))
            return ExitCode.of(error)
        }
    }

    private static func print(_ value: JSONValue, globals: Globals) {
        guard !globals.quiet else { return }
        let text = globals.json ? value.prettyJSON() : Output.human(value)
        if !text.isEmpty { Swift.print(text) }
    }

    private static func execute(_ globals: Globals) async throws -> Int32 {
        guard let command = globals.rest.first, command != "help", command != "--help", command != "-h" else {
            Swift.print(help)
            return ExitCode.success
        }
        let rest = Array(globals.rest.dropFirst())
        switch command {
        case "status":
            print(try LLMDClient(launch: globals.launch).run("app.status", run: globals.run), globals: globals)
        case "actions":
            let (options, _) = try DynamicCommand.options(rest, schema: nil)
            let result = try LLMDClient(launch: globals.launch).run("actions.list", args: .object(options), run: globals.run)
            if globals.json {
                print(result, globals: globals)
            } else if !globals.quiet {
                for action in (try? result["actions"]?.decoded(as: [ActionDescriptor].self)) ?? [] {
                    Swift.print("\(action.id)\t[\(action.kind.label)]\t\(action.summary)")
                }
            }
        case "describe":
            guard let id = rest.first else { throw UsageError(message: "Welche Action? Beispiel: llmd describe writer.doc.read") }
            let result = try LLMDClient(launch: globals.launch).run("actions.describe", args: ["id": .string(id)], run: globals.run)
            print(result, globals: globals.json || globals.quiet ? globals : withJSON(globals))
        case "call":
            guard let id = rest.first else { throw UsageError(message: "Welche Action? Beispiel: llmd call writer.doc.list --json") }
            let client = try LLMDClient(launch: globals.launch)
            let descriptor = try SchemaCache.descriptor(id, client: client)
            let args = try DynamicCommand.arguments(Array(rest.dropFirst()), descriptor: descriptor, globals: globals)
            print(try client.run(id, args: args, run: globals.run), globals: globals)
        case "batch":
            return try runBatch(rest, globals: globals)
        case "watch":
            let client = try LLMDClient(launch: globals.launch)
            _ = try client.request(RPCMethod.subscribe)
            client.listen { event in
                let value = (try? JSONValue.encoding(event)) ?? .null
                Swift.print(globals.json ? value.jsonLine() : Self.line(for: event))
                fflush(stdout)
            }
        case "completion":
            guard rest.first == "zsh" else { throw UsageError(message: "Bisher gibt es nur: llmd completion zsh") }
            let client = try LLMDClient(launch: globals.launch)
            Swift.print(Completion.zsh(actions: try SchemaCache.descriptors(client: client)))
        case "mcp":
            let (options, _) = try DynamicCommand.options(rest, schema: nil)
            let profile = options["profile"]?.stringValue ?? "core"
            guard MCPProfile.names.contains(profile) else {
                throw UsageError(message: "Unbekanntes Profil „\(profile)“. Es gibt: \(MCPProfile.names.joined(separator: ", ")).")
            }
            let client = try LLMDClient(channel: "mcp", launch: globals.launch)
            MCPServer(client: client, profile: profile, launch: globals.launch).serve()
        default:
            let client = try LLMDClient(launch: globals.launch)
            let actions = try SchemaCache.descriptors(client: client)
            guard let (descriptor, remaining) = DynamicCommand.resolve(words: globals.rest, actions: actions) else {
                throw UsageError(message: "Unbekannter Befehl „\(globals.rest.prefix { !$0.hasPrefix("-") }.joined(separator: " "))“. `llmd actions` listet alle.")
            }
            let args = try DynamicCommand.arguments(remaining, descriptor: descriptor, globals: globals)
            print(try client.run(descriptor.id, args: args, run: globals.run), globals: globals)
        }
        return ExitCode.success
    }

    private static func withJSON(_ globals: Globals) -> Globals {
        var copy = globals
        copy.json = true
        return copy
    }

    private static func line(for event: ActionEvent) -> String {
        let time = event.time.formatted(date: .omitted, time: .standard)
        return [time, event.kind, event.action, event.channel, event.target].compactMap { $0 }.joined(separator: "\t")
    }

    private static func runBatch(_ rest: [String], globals: Globals) throws -> Int32 {
        let data: Data
        if let path = rest.first {
            data = try Data(contentsOf: URL(fileURLWithPath: path))
        } else {
            data = FileHandle.standardInput.readDataToEndOfFile()
        }
        let steps = try DynamicCommand.batchSteps(from: String(decoding: data, as: UTF8.self))
        var params: [String: JSONValue] = ["steps": .array(steps)]
        if let run = globals.run { params["run"] = .string(run) }
        print(try LLMDClient(launch: globals.launch).request(RPCMethod.batch, params: .object(params)), globals: withJSON(globals))
        return ExitCode.success
    }
}
