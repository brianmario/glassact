import Darwin
import GlassActTransport
public import Foundation

/// Where agent sessions live: one Unix socket per session under
/// `~/Library/Application Support/Glass Act/agent` (directory 0700, sockets 0600, peers checked to be this
/// same user). The Viewer app's live session is `viewer.sock`; a headless
/// session is `<name>.sock`, with its log beside it.
public enum AgentPaths {
    public static var directory: URL { AppPaths.dataDirectory.appendingPathComponent("agent") }
    public static var dataDirectory: URL { AppPaths.dataDirectory }
    public static var viewerSocket: URL { directory.appendingPathComponent("viewer.sock") }
    public static func headlessSocket(_ name: String) -> URL { directory.appendingPathComponent("\(name).sock") }
    public static func headlessLog(_ name: String) -> URL { directory.appendingPathComponent("\(name).log") }
    /// Headless agents dial with their own identity, named so the host can
    /// tell its user an agent is asking ("glassact-agent" common name).
    public static let agentIdentityName = "agent-identity"
    public static let agentCommonName = "glassact-agent"

    public static func ensureDirectory() throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
    }

    /// Valid session names: what fits in a file name and a socket path.
    public static func isValidName(_ name: String) -> Bool {
        (1...32).contains(name.count) && name != "viewer"
            && name.allSatisfy { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" }
    }
}

public struct AgentSocketError: Error, CustomStringConvertible {
    public let description: String
    public init(_ description: String) { self.description = description }
}

/// Newline-delimited JSON over a Unix socket. Request:
/// `{"id": 1, "op": "click", "args": {"x": 10, "y": 20}}`; response:
/// `{"id": 1, "ok": true, "result": {…}}` or `{"id": 1, "ok": false, "error": "…"}`.
/// Each client is served in order on its own queue.
public final class AgentSocketServer: @unchecked Sendable {
    public typealias Handler = @Sendable (_ op: String, _ args: [String: Any]) throws -> [String: Any]

    public let path: String
    /// Main: the number of connected clients changed.
    public var onClientCountChanged: (@Sendable (Int) -> Void)?
    private let handler: Handler
    private var listenFD: Int32 = -1
    private var acceptSource: (any DispatchSourceRead)?
    private let acceptQueue = DispatchQueue(label: "glassact.agent.socket.accept")
    private var clients: [ObjectIdentifier: Client] = [:] // acceptQueue

    public init(path: URL, handler: @escaping Handler) {
        self.path = path.path
        self.handler = handler
    }

    /// Bind and listen. Throws if another live server owns the path.
    public func start() throws {
        // Its own folder only — not AgentPaths.directory, which would set up
        // the data directory for a socket placed elsewhere.
        let folder = URL(fileURLWithPath: path).deletingLastPathComponent()
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        if (try? AgentSocketClient(path: URL(fileURLWithPath: path), timeout: 1)) != nil {
            throw AgentSocketError("another session is already serving \(path)")
        }
        unlink(path)
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw AgentSocketError("socket: \(String(cString: strerror(errno)))") }
        var addr = try Self.address(path)
        let bound = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard bound == 0 else {
            close(fd)
            throw AgentSocketError("bind \(path): \(String(cString: strerror(errno)))")
        }
        chmod(path, 0o600)
        guard listen(fd, 8) == 0 else {
            close(fd)
            throw AgentSocketError("listen: \(String(cString: strerror(errno)))")
        }
        _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
        listenFD = fd
        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: acceptQueue)
        source.setEventHandler { [weak self] in self?.acceptPending() }
        source.setCancelHandler { close(fd) }
        source.resume()
        acceptSource = source
    }

    public func stop() {
        acceptQueue.sync {
            acceptSource?.cancel()
            acceptSource = nil
            for client in clients.values { client.close() }
            clients.removeAll()
        }
        unlink(path)
    }

    private func acceptPending() {
        while true {
            let fd = accept(listenFD, nil, nil)
            guard fd >= 0 else { return }
            var uid: uid_t = 0, gid: gid_t = 0
            guard getpeereid(fd, &uid, &gid) == 0, uid == getuid() else {
                close(fd) // only this user's own processes
                continue
            }
            _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) & ~O_NONBLOCK)
            var on: Int32 = 1
            setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
            let client = Client(fd: fd, handler: handler) { [weak self] gone in
                self?.acceptQueue.async { self?.remove(gone) }
            }
            clients[ObjectIdentifier(client)] = client
            notifyCount()
            client.start()
        }
    }

    private func remove(_ client: Client) {
        guard clients.removeValue(forKey: ObjectIdentifier(client)) != nil else { return }
        notifyCount()
    }

    private func notifyCount() {
        let n = clients.count
        let callback = onClientCountChanged
        DispatchQueue.main.async { callback?(n) }
    }

    static func address(_ path: String) throws -> sockaddr_un {
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8)
        let capacity = MemoryLayout.size(ofValue: addr.sun_path)
        guard bytes.count < capacity else { throw AgentSocketError("socket path too long: \(path)") }
        withUnsafeMutableBytes(of: &addr.sun_path) { raw in
            raw.copyBytes(from: bytes)
            raw[bytes.count] = 0
        }
        return addr
    }

    /// One connection: read lines, answer each in order.
    private final class Client: @unchecked Sendable {
        let fd: Int32
        let handler: Handler
        let onGone: (Client) -> Void
        let queue = DispatchQueue(label: "glassact.agent.socket.client")
        var source: (any DispatchSourceRead)?
        var buffer = [UInt8]()
        var closed = false

        init(fd: Int32, handler: @escaping Handler, onGone: @escaping (Client) -> Void) {
            self.fd = fd
            self.handler = handler
            self.onGone = onGone
        }

        func start() {
            let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
            source.setEventHandler { [weak self] in self?.readAvailable() }
            source.setCancelHandler { [fd] in Darwin.close(fd) }
            source.resume()
            self.source = source
        }

        func close() {
            queue.async { [self] in finish() }
        }

        private func finish() {
            guard !closed else { return }
            closed = true
            source?.cancel()
            source = nil
            onGone(self)
        }

        private func readAvailable() {
            var chunk = [UInt8](repeating: 0, count: 64 << 10)
            let n = chunk.withUnsafeMutableBytes { read(fd, $0.baseAddress, $0.count) }
            guard n > 0 else { finish(); return }
            buffer.append(contentsOf: chunk[0..<n])
            guard buffer.count <= 8 << 20 else { finish(); return } // a request is never this big
            while let nl = buffer.firstIndex(of: 0x0A) {
                let line = Array(buffer[..<nl])
                buffer.removeSubrange(...nl)
                guard !line.isEmpty else { continue }
                respond(to: line)
                if closed { return }
            }
        }

        private func respond(to line: [UInt8]) {
            var reply: [String: Any] = ["ok": false]
            if let request = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any] {
                reply["id"] = request["id"] ?? NSNull()
                if let op = request["op"] as? String {
                    do {
                        reply["result"] = try handler(op, request["args"] as? [String: Any] ?? [:])
                        reply["ok"] = true
                    } catch {
                        reply["error"] = "\(error)"
                    }
                } else {
                    reply["error"] = "request needs “op”"
                }
            } else {
                reply["error"] = "not a JSON object"
            }
            guard var data = try? JSONSerialization.data(withJSONObject: reply) else { return }
            data.append(0x0A)
            let ok = data.withUnsafeBytes { raw -> Bool in
                var sent = 0
                while sent < raw.count {
                    let n = write(fd, raw.baseAddress!.advanced(by: sent), raw.count - sent)
                    if n <= 0 { return false }
                    sent += n
                }
                return true
            }
            if !ok { finish() }
        }
    }
}

/// A blocking client for one agent session socket.
public final class AgentSocketClient {
    private let fd: Int32
    private var buffer = [UInt8]()
    private var nextID = 1

    public init(path: URL, timeout: Double = 30) throws {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw AgentSocketError("socket: \(String(cString: strerror(errno)))") }
        var addr = try AgentSocketServer.address(path.path)
        let connected = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard connected == 0 else {
            close(fd)
            throw AgentSocketError("no session at \(path.path)")
        }
        var on: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
        var tv = timeval(tv_sec: Int(timeout), tv_usec: Int32((timeout - timeout.rounded(.down)) * 1_000_000))
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        self.fd = fd
    }

    deinit { close(fd) }

    /// Send one request and wait for its answer. Throws the session's error.
    public func call(_ op: String, _ args: [String: Any] = [:]) throws -> [String: Any] {
        let id = nextID
        nextID += 1
        var data = try JSONSerialization.data(withJSONObject: ["id": id, "op": op, "args": args])
        data.append(0x0A)
        try data.withUnsafeBytes { raw in
            var sent = 0
            while sent < raw.count {
                let n = write(fd, raw.baseAddress!.advanced(by: sent), raw.count - sent)
                guard n > 0 else { throw AgentSocketError("the session went away") }
                sent += n
            }
        }
        while true {
            if let nl = buffer.firstIndex(of: 0x0A) {
                let line = Data(buffer[..<nl])
                buffer.removeSubrange(...nl)
                guard let reply = try JSONSerialization.jsonObject(with: line) as? [String: Any] else {
                    throw AgentSocketError("unreadable reply")
                }
                if (reply["ok"] as? Bool) == true { return reply["result"] as? [String: Any] ?? [:] }
                throw AgentSocketError(reply["error"] as? String ?? "failed")
            }
            var chunk = [UInt8](repeating: 0, count: 256 << 10)
            let n = chunk.withUnsafeMutableBytes { read(fd, $0.baseAddress, $0.count) }
            guard n > 0 else {
                throw AgentSocketError(n == 0 ? "the session went away" : "timed out waiting for the session")
            }
            buffer.append(contentsOf: chunk[0..<n])
        }
    }
}
