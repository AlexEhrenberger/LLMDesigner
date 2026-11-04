import Foundation

/// Where the app and `llmd` find each other. These are files of the running app without any library data. They go
/// to Application Support because a library may sit on a shared or external drive, where a socket and a token don't
/// belong. `LLMD_HOME` moves them, for tests.
public struct SocketPaths: Sendable {
    public let directory: URL

    public init(directory: URL? = nil) {
        if let directory {
            self.directory = directory
        } else if let home = ProcessInfo.processInfo.environment["LLMD_HOME"], !home.isEmpty {
            self.directory = URL(fileURLWithPath: home, isDirectory: true)
        } else {
            let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            self.directory = support.appendingPathComponent("LLMDesigner", isDirectory: true)
        }
    }

    public var socket: URL { directory.appendingPathComponent("llmd.sock") }
    public var token: URL { directory.appendingPathComponent("llmd.token") }

    /// `sockaddr_un` holds 104 bytes on macOS.
    public static let maxSocketPathLength = 103
}

/// The few calls on a Unix socket that app and client share.
public enum UnixSocket {
    public enum Failure: Error, LocalizedError {
        case pathTooLong(String)
        case system(String, Int32)

        public var errorDescription: String? {
            switch self {
            case .pathTooLong(let path): "Der Socket-Pfad ist zu lang: \(path)"
            case .system(let call, let code): "\(call) ist fehlgeschlagen: \(String(cString: strerror(code)))"
            }
        }
    }

    public static func withAddress<T>(_ path: String, _ body: (UnsafePointer<sockaddr>, socklen_t) -> T) throws -> T {
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8)
        guard bytes.count <= SocketPaths.maxSocketPathLength else { throw Failure.pathTooLong(path) }
        withUnsafeMutableBytes(of: &address.sun_path) { buffer in
            buffer.copyBytes(from: bytes)
            buffer[bytes.count] = 0
        }
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        return withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { body($0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
    }

    /// A connected socket, or an error when nobody listens.
    public static func connect(path: String) throws -> Int32 {
        let descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor >= 0 else { throw Failure.system("socket", errno) }
        let result = try withAddress(path) { Darwin.connect(descriptor, $0, $1) }
        guard result == 0 else {
            let code = errno
            close(descriptor)
            throw Failure.system("connect", code)
        }
        var noSignal: Int32 = 1
        setsockopt(descriptor, SOL_SOCKET, SO_NOSIGPIPE, &noSignal, socklen_t(MemoryLayout<Int32>.size))
        return descriptor
    }

    public static func writeAll(_ data: Data, to descriptor: Int32) -> Bool {
        data.withUnsafeBytes { buffer in
            var offset = 0
            while offset < buffer.count {
                let written = write(descriptor, buffer.baseAddress! + offset, buffer.count - offset)
                if written < 0 {
                    if errno == EINTR { continue }
                    return false
                }
                offset += written
            }
            return true
        }
    }
}

/// Cuts a byte stream into lines.
public struct LineReader {
    public let descriptor: Int32
    private var buffer = Data()
    /// A request or result larger than this ends the connection instead of filling the memory.
    public static let maxLineLength = 128 * 1024 * 1024

    public init(descriptor: Int32) {
        self.descriptor = descriptor
    }

    /// The next line without its newline; nil at the end of the stream.
    public mutating func next() -> Data? {
        var chunk = [UInt8](repeating: 0, count: 64 * 1024)
        while true {
            if let newline = buffer.firstIndex(of: 0x0A) {
                let line = buffer[buffer.startIndex..<newline]
                buffer = Data(buffer[buffer.index(after: newline)...])
                return Data(line)
            }
            guard buffer.count <= Self.maxLineLength else { return nil }
            let count = read(descriptor, &chunk, chunk.count)
            if count < 0, errno == EINTR { continue }
            guard count > 0 else { return nil }
            buffer.append(contentsOf: chunk[0..<count])
        }
    }
}
