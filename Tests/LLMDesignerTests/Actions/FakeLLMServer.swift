import Foundation
import LLMDProtocol
@testable import LLMDesigner

/// An LM Studio that isn't one: it answers scripted turns, so tests run the real chat loop with tool calls and without
/// a model. Only in tests does anything here open a port, and only on 127.0.0.1.
final class FakeLLMServer: @unchecked Sendable {
    enum Turn: Sendable {
        case text(String)
        /// Tool calls: name and arguments as JSON text.
        case tools([(name: String, arguments: String)])
    }

    private let lock = NSLock()
    private var script: [Turn]
    private var seen: [JSONValue] = []
    private let listener: Int32
    let port: UInt16
    var fallback = "Fertig."
    /// What any other address answers, as a web page.
    var page = "<html><body>Nichts.</body></html>"
    /// A placeholder in scripted tool arguments and what it stands for, for things only known once the server runs.
    var substitute: (String, String)?

    init(script: [Turn] = []) throws {
        self.script = script
        let listener = socket(AF_INET, SOCK_STREAM, 0)
        self.listener = listener
        var yes: Int32 = 1
        setsockopt(listener, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))
        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        address.sin_port = 0
        var size = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(listener, $0, size) } }
        listen(listener, 16)
        _ = withUnsafeMutablePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(listener, $0, &size) } }
        port = UInt16(bigEndian: address.sin_port)
        Thread.detachNewThread { [weak self] in
            while true {
                let client = accept(listener, nil, nil)
                if client < 0 { return }
                guard let self else { close(client); return }
                DispatchQueue.global().async { self.serve(client) }
            }
        }
    }

    var endpoint: String { "http://127.0.0.1:\(port)" }

    /// The bodies of the chat requests that streamed, oldest first.
    var requests: [JSONValue] { lock.withLock { seen } }

    func stop() {
        shutdown(listener, SHUT_RDWR)
        close(listener)
    }

    private func nextTurn() -> Turn {
        lock.withLock { script.isEmpty ? .text(fallback) : script.removeFirst() }
    }

    private func serve(_ client: Int32) {
        defer { close(client) }
        var data = Data()
        var chunk = [UInt8](repeating: 0, count: 65536)
        var body = Data()
        var head = ""
        while true {
            let count = read(client, &chunk, chunk.count)
            guard count > 0 else { return }
            data.append(contentsOf: chunk[0..<count])
            guard let range = data.range(of: Data("\r\n\r\n".utf8)) else { continue }
            head = String(decoding: data[..<range.lowerBound], as: UTF8.self)
            let length = head.components(separatedBy: "\r\n").first { $0.lowercased().hasPrefix("content-length:") }
                .flatMap { Int($0.split(separator: ":")[1].trimmingCharacters(in: .whitespaces)) } ?? 0
            body = data[range.upperBound...]
            if body.count >= length { break }
        }
        let path = head.split(separator: " ").dropFirst().first.map(String.init) ?? ""
        let reply: (type: String, text: String)
        if path.hasPrefix("/artikel") {
            reply = ("text/html; charset=utf-8", page)
        } else if path.contains("models/load") {
            reply = ("application/json", "{}")
        } else if path.contains("models") {
            reply = ("application/json", #"{"data":[{"id":"fake","object":"model","type":"llm","state":"loaded","loaded_context_length":16384,"max_context_length":32768,"capabilities":["tool_use"]}]}"#)
        } else {
            let request = (try? JSONDecoder().decode(JSONValue.self, from: body)) ?? .null
            if request["stream"] == true {
                lock.withLock { seen.append(request) }
                reply = ("text/event-stream", Self.stream(nextTurn(), substitute: substitute))
            } else {
                reply = ("application/json", #"{"choices":[{"message":{"role":"assistant","content":"{}"}}]}"#)
            }
        }
        let response = "HTTP/1.1 200 OK\r\nContent-Type: \(reply.type)\r\nContent-Length: \(reply.text.utf8.count)\r\nConnection: close\r\n\r\n\(reply.text)"
        _ = UnixSocket.writeAll(Data(response.utf8), to: client)
    }

    private static func stream(_ turn: Turn, substitute: (String, String)?) -> String {
        func event(_ delta: JSONValue, finish: JSONValue = nil) -> String {
            let value: JSONValue = ["model": "fake", "choices": [["index": 0, "delta": delta, "finish_reason": finish]]]
            return "data: \(value.jsonLine())\n\n"
        }
        var text = ""
        switch turn {
        case .text(let content):
            text += event(["content": .string(content)])
            text += event([:], finish: "stop")
        case .tools(let calls):
            let list: [JSONValue] = calls.enumerated().map { index, call in
                ["index": .int(index), "id": .string("call_\(index)"), "type": "function", "function": ["name": .string(call.name), "arguments": .string(substitute.map { call.arguments.replacingOccurrences(of: $0.0, with: $0.1) } ?? call.arguments)]]
            }
            text += event(["tool_calls": .array(list)])
            text += event([:], finish: "tool_calls")
        }
        return text + "data: [DONE]\n\n"
    }
}
