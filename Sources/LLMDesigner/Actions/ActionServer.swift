import Foundation
import LLMDProtocol

/// The socket `llmd` talks to: one JSON-RPC message per line. It is a Unix socket in a folder only this user can
/// enter, not a network port; each connection is also checked for the user behind it and has to show the token that
/// is written anew at each start. The plan named Network.framework, but `NWConnection` doesn't expose the file
/// descriptor that `getpeereid` needs, so this uses plain BSD sockets.
final class ActionServer: @unchecked Sendable {
    /// Handles a line's message; the answer goes back on the same connection.
    typealias Handler = @Sendable (RPCMessage, ActionConnection) async -> RPCMessage?

    let paths: SocketPaths
    private let handler: Handler
    private var listener: Int32 = -1
    private let lock = NSLock()
    private var connections: [ObjectIdentifier: ActionConnection] = [:]
    private(set) var token = ""

    init(paths: SocketPaths = SocketPaths(), handler: @escaping Handler) {
        self.paths = paths
        self.handler = handler
    }

    func start() throws {
        let manager = FileManager.default
        try manager.createDirectory(at: paths.directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        chmod(paths.directory.path, 0o700)

        // A socket left by a crash blocks `bind`. It is replaced; so is one of a running instance, whose clients then
        // reach the newer app.
        unlink(paths.socket.path)

        let descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor >= 0 else { throw UnixSocket.Failure.system("socket", errno) }
        // Between bind and chmod the socket must not be open to anyone else.
        let oldMask = umask(0o177)
        defer { umask(oldMask) }
        let bound = try UnixSocket.withAddress(paths.socket.path) { Darwin.bind(descriptor, $0, $1) }
        guard bound == 0 else {
            let code = errno
            close(descriptor)
            throw UnixSocket.Failure.system("bind", code)
        }
        chmod(paths.socket.path, 0o600)
        guard listen(descriptor, 16) == 0 else {
            let code = errno
            close(descriptor)
            throw UnixSocket.Failure.system("listen", code)
        }

        token = Self.makeToken()
        try Data(token.utf8).write(to: paths.token, options: [.atomic])
        chmod(paths.token.path, 0o600)

        lock.withLock { listener = descriptor }
        let thread = Thread { [weak self] in self?.acceptLoop(descriptor) }
        thread.name = "llmd.accept"
        thread.start()
    }

    func stop() {
        let descriptor = lock.withLock {
            let current = listener
            listener = -1
            return current
        }
        if descriptor >= 0 {
            shutdown(descriptor, SHUT_RDWR)
            close(descriptor)
        }
        unlink(paths.socket.path)
        unlink(paths.token.path)
        let open = lock.withLock {
            let all = Array(connections.values)
            connections = [:]
            return all
        }
        open.forEach { $0.close() }
    }

    /// Sends an event to everyone who subscribed.
    func broadcast(_ event: ActionEvent) {
        guard let params = try? JSONValue.encoding(event),
              let line = try? RPCMessage(id: nil, method: RPCMethod.event, params: params).line() else { return }
        let subscribers = lock.withLock { connections.values.filter(\.isSubscribed) }
        subscribers.forEach { $0.send(line) }
    }

    private func acceptLoop(_ descriptor: Int32) {
        while true {
            let client = accept(descriptor, nil, nil)
            if client < 0 {
                if errno == EINTR { continue }
                return
            }
            var noSignal: Int32 = 1
            setsockopt(client, SOL_SOCKET, SO_NOSIGPIPE, &noSignal, socklen_t(MemoryLayout<Int32>.size))
            guard Self.isSameUser(client) else {
                close(client)
                continue
            }
            let connection = ActionConnection(descriptor: client, expectedToken: token)
            lock.withLock { connections[ObjectIdentifier(connection)] = connection }
            let thread = Thread { [weak self] in self?.serve(connection) }
            thread.name = "llmd.client"
            thread.start()
        }
    }

    /// The other end runs under this user. The folder's rights already say so; this is the second lock.
    static func isSameUser(_ descriptor: Int32) -> Bool {
        var user: uid_t = 0
        var group: gid_t = 0
        guard getpeereid(descriptor, &user, &group) == 0 else { return false }
        return user == getuid()
    }

    private func serve(_ connection: ActionConnection) {
        var reader = LineReader(descriptor: connection.descriptor)
        while let line = reader.next() {
            guard !line.isEmpty else { continue }
            guard let message = try? JSONDecoder().decode(RPCMessage.self, from: line) else {
                connection.send(RPCMessage(id: nil, error: RPCError(code: RPCError.parseErrorCode, message: "Kein gültiges JSON.")))
                continue
            }
            // Long actions must not hold up the next line (a client may send `stop`), so each runs for itself.
            let handler = handler
            Task {
                if let answer = await handler(message, connection) { connection.send(answer) }
            }
        }
        lock.withLock { _ = connections.removeValue(forKey: ObjectIdentifier(connection)) }
        connection.close()
    }

    private static func makeToken() -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        return bytes.map { String(format: "%02x", $0) }.joined()
    }
}

/// One client. Its state changes on the main actor only; writing is serial.
final class ActionConnection: @unchecked Sendable {
    let descriptor: Int32
    let expectedToken: String
    private let queue = DispatchQueue(label: "llmd.connection.write")
    private let lock = NSLock()
    private var isOpen = true
    private var authenticatedChannel: ActionChannel?
    private var subscribed = false
    /// The run of a connection without its own run id, e.g. an MCP session.
    let sessionRun = UUID().uuidString

    init(descriptor: Int32, expectedToken: String) {
        self.descriptor = descriptor
        self.expectedToken = expectedToken
    }

    var channel: ActionChannel? { lock.withLock { authenticatedChannel } }
    var isSubscribed: Bool { lock.withLock { subscribed } }

    func authenticate(token: String, channel: ActionChannel) -> Bool {
        guard Self.constantTimeEqual(token, expectedToken) else { return false }
        lock.withLock { authenticatedChannel = channel }
        return true
    }

    func subscribe() {
        lock.withLock { subscribed = true }
    }

    func send(_ message: RPCMessage) {
        if let line = try? message.line() { send(line) }
    }

    func send(_ line: Data) {
        queue.async { [self] in
            let open = lock.withLock { isOpen }
            if open { _ = UnixSocket.writeAll(line, to: descriptor) }
        }
    }

    func close() {
        // Through the queue, so a final answer still goes out before the descriptor closes.
        queue.async { [self] in
            let wasOpen = lock.withLock {
                let was = isOpen
                isOpen = false
                return was
            }
            if wasOpen { Darwin.close(descriptor) }
        }
    }

    static func constantTimeEqual(_ first: String, _ second: String) -> Bool {
        let (a, b) = (Array(first.utf8), Array(second.utf8))
        guard a.count == b.count else { return false }
        return zip(a, b).reduce(UInt8(0)) { $0 | ($1.0 ^ $1.1) } == 0
    }
}
