public import Foundation

/// Finding and starting agent sessions — shared by the CLI and the MCP server.
public enum AgentLauncher {
    /// Which session to talk to: "viewer" (the Viewer app's live session), a
    /// headless session's name, or nil = the default headless one if it's
    /// running, else the Viewer app's.
    public static func socket(for session: String?) throws -> URL {
        if let session {
            guard session == "viewer" || AgentPaths.isValidName(session) else {
                throw AgentSocketError("“\(session)” isn't a session name")
            }
            let url = session == "viewer" ? AgentPaths.viewerSocket : AgentPaths.headlessSocket(session)
            guard isAlive(url) else { throw AgentSocketError(notRunning(session)) }
            return url
        }
        if isAlive(AgentPaths.headlessSocket("default")) { return AgentPaths.headlessSocket("default") }
        if isAlive(AgentPaths.viewerSocket) { return AgentPaths.viewerSocket }
        throw AgentSocketError("no agent session — run `glassact connect <host>` for a headless one, or open Glass Act Viewer, "
                               + "connect, and turn on Settings › Agents › Allow Agents to Use This Session")
    }

    static func notRunning(_ session: String) -> String {
        session == "viewer"
            ? "Glass Act Viewer isn't sharing its session — connect in the Viewer and turn on Settings › Agents › Allow Agents to Use This Session"
            : "no headless session “\(session)” — start it with `glassact connect <host>\(session == "default" ? "" : " --name \(session)")`"
    }

    public static func isAlive(_ url: URL) -> Bool {
        (try? AgentSocketClient(path: url, timeout: 2).call("status")) != nil
    }

    /// Every session answering on its socket: (name, status).
    public static func sessions() -> [(name: String, status: [String: Any])] {
        let files = (try? FileManager.default.contentsOfDirectory(atPath: AgentPaths.directory.path)) ?? []
        return files.filter { $0.hasSuffix(".sock") }.sorted().compactMap { file in
            let name = String(file.dropLast(5))
            let url = AgentPaths.directory.appendingPathComponent(file)
            guard let status = try? AgentSocketClient(path: url, timeout: 2).call("status") else { return nil }
            return (name, status)
        }
    }

    public struct ConnectOptions: Sendable {
        public var host: String
        public var port: UInt16 = 4433
        public var fingerprint = ""
        public var size: String?
        public var label = "agent"
        public var name = "default"
        public var maxEdge: Int?
        public init(host: String) { self.host = host }
    }

    /// Start a headless session (`glassact daemon …` in the background, logging
    /// beside its socket), or reuse one already connected to the same host.
    /// Returns once it's connected or waiting on the host's user, with its
    /// status. `executable` is the `glassact` binary.
    public static func connect(_ options: ConnectOptions, executable: String,
                               timeout: Double = 20) throws -> [String: Any] {
        guard AgentPaths.isValidName(options.name) else { throw AgentSocketError("“\(options.name)” isn't a session name") }
        let socket = AgentPaths.headlessSocket(options.name)
        if let status = try? AgentSocketClient(path: socket, timeout: 2).call("status") {
            if (status["host"] as? String) == "\(options.host):\(options.port)" { return status }
            throw AgentSocketError("session “\(options.name)” is already connected to \(status["host"] ?? "another host") — "
                                   + "disconnect it first, or use --name")
        }
        try AgentPaths.ensureDirectory()
        var args = ["daemon", "--host", options.host, "--port", String(options.port),
                    "--name", options.name, "--label", options.label]
        if !options.fingerprint.isEmpty { args += ["--fingerprint", options.fingerprint] }
        if let size = options.size { args += ["--size", size] }
        if let maxEdge = options.maxEdge { args += ["--max-edge", String(maxEdge)] }
        let log = AgentPaths.headlessLog(options.name)
        FileManager.default.createFile(atPath: log.path, contents: nil, attributes: [.posixPermissions: 0o600])
        let handle = try FileHandle(forWritingTo: log)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = args
        process.standardOutput = handle
        process.standardError = handle
        process.standardInput = FileHandle.nullDevice
        try process.run()
        // Wait for it to answer, then until it's past dialing.
        let deadline = Date().addingTimeInterval(timeout)
        var last: [String: Any]?
        while Date() < deadline {
            if !process.isRunning {
                throw AgentSocketError("the session exited: \(lastLines(of: log))")
            }
            if let status = try? AgentSocketClient(path: socket, timeout: 2).call("status") {
                last = status
                let phase = status["phase"] as? String
                if phase == "connected" || phase == "awaiting_approval" || phase == "failed" { return status }
            }
            Thread.sleep(forTimeInterval: 0.2)
        }
        if let last { return last }
        throw AgentSocketError("the session didn't start within \(Int(timeout)) s: \(lastLines(of: log))")
    }

    static func lastLines(of url: URL, count: Int = 3) -> String {
        let text = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        return text.split(separator: "\n").suffix(count).joined(separator: " / ")
    }
}
