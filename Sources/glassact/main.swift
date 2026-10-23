// `glassact` — drive a remote Mac from a shell or an MCP client.
//
//   glassact connect my-mac.local            headless session of the agent's own
//   glassact screenshot -o screen.png        look (waits until the screen settles)
//   glassact click 640 400                   act (screen coordinates from status)
//   glassact mcp                             serve the same as MCP tools on stdio
//
// Every command talks to an agent session over a local socket: a headless
// one (`glassact connect`), or the Viewer app's live session (`--session viewer`).
import Foundation
import GlassActSession
import GlassActTransport

let version = "26.10.4" // = GLASSACT_VERSION in Apps/Version.xcconfig (scripts/check-version)
/// The commit a release was built from: Apps/ci-release.sh links it into the
/// binary's embedded Info.plist. A build from source has none.
let commit = Bundle.main.object(forInfoDictionaryKey: "GlassActCommit") as? String

struct Usage: Error, CustomStringConvertible {
    let description: String
    init(_ d: String) { description = d }
}

/// Positional arguments plus `--flag value` / `--switch` options.
struct Parsed {
    var positional: [String] = []
    var options: [String: String] = [:]
    var switches: Set<String> = []

    static let switchNames: Set<String> = ["json", "no-settle", "help", "wait"]

    init(_ args: ArraySlice<String>) throws {
        var it = args.makeIterator()
        while let a = it.next() {
            if a == "-o" {
                guard let v = it.next() else { throw Usage("-o needs a file") }
                options["o"] = v
            } else if a.hasPrefix("--") {
                let name = String(a.dropFirst(2))
                if let eq = name.firstIndex(of: "=") {
                    options[String(name[..<eq])] = String(name[name.index(after: eq)...])
                } else if Self.switchNames.contains(name) {
                    switches.insert(name)
                } else {
                    guard let v = it.next() else { throw Usage("--\(name) needs a value") }
                    options[name] = v
                }
            } else {
                positional.append(a)
            }
        }
    }

    func number(_ i: Int, _ what: String) throws -> Double {
        guard i < positional.count, let v = Double(positional[i]) else { throw Usage("expected \(what)") }
        return v
    }

    func rect(_ text: String) throws -> [Double] {
        let parts = text.split(separator: ",").compactMap { Double($0.trimmingCharacters(in: .whitespaces)) }
        guard parts.count == 4 else { throw Usage("a region is x,y,width,height") }
        return parts
    }
}

let usage = """
    glassact \(version) — drive a remote Mac through Glass Act

    Sessions
      glassact connect HOST [--port 4433] [--fingerprint KEY] [--size WxH] [--label NAME] [--name SESSION]
                                       start a headless agent session (the host's user approves it once);
                                       KEY pins the host's key, as Copy Host Key gives it (ga1…) or hex
      glassact disconnect                 end the headless session
      glassact sessions                   list running sessions
      glassact status                     connection, screen size, whether input is accepted
      glassact forget HOST[:PORT]         forget a remembered host key
      Use --session viewer to drive Glass Act Viewer's live session (enable it in Viewer › Settings).

    Look
      glassact screenshot [-o FILE] [--region x,y,w,h] [--no-settle]
      glassact zoom x,y,w,h [-o FILE]
      glassact wait-settle [--timeout S]  glassact wait-change [--region x,y,w,h] [--timeout S]
      glassact ui-tree [--window ID] [--max-nodes N]
      glassact windows                    glassact cursor

    Act (coordinates are in the screen space `status` reports)
      glassact click X Y [--button left|right|middle] [--count N] [--modifiers shift]
      glassact double-click X Y           glassact right-click X Y
      glassact move X Y                   glassact drag X1 Y1 X2 Y2
      glassact scroll X Y up|down|left|right [AMOUNT]
      glassact key COMBO [--repeat N]     e.g. return, cmd+c, cmd+shift+t, page_down
      glassact type TEXT                  glassact clipboard [get | set TEXT]
      glassact share-window ID            (0 = whole display)

    Agents
      glassact mcp                        Model Context Protocol server on stdio
                                       (claude mcp add glassact -- \(CommandLine.arguments[0]) mcp)

    Add --json for raw replies.
    """

func executablePath() -> String {
    let arg0 = CommandLine.arguments[0]
    if arg0.contains("/") { return URL(fileURLWithPath: arg0).standardizedFileURL.path }
    for dir in (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":") {
        let candidate = "\(dir)/\(arg0)"
        if FileManager.default.isExecutableFile(atPath: candidate) { return candidate }
    }
    return arg0
}

func emit(_ result: [String: Any], json: Bool, human: () -> String) {
    if json {
        var r = result
        if r["png_base64"] != nil { r["png_base64"] = "<omitted>" }
        let data = (try? JSONSerialization.data(withJSONObject: r, options: [.prettyPrinted, .sortedKeys])) ?? Data()
        print(String(decoding: data, as: UTF8.self))
    } else {
        let text = human()
        if !text.isEmpty { print(text) }
    }
}

func describeStatus(_ s: [String: Any]) -> String {
    var lines: [String] = []
    if (s["connected"] as? Bool) == true {
        lines.append("connected: \(s["host"] ?? s["target"] ?? "?")")
        if let screen = s["screen"] as? [String: Any] {
            lines.append("screen: \(screen["width"] ?? "?")×\(screen["height"] ?? "?") (agent coordinates)")
        }
        if (s["agent_support"] as? Bool) == false { lines.append("note: this host is too old for agents (update Glass Act Host)") }
        if (s["control"] as? Bool) == false { lines.append("input: off — \(s["control_reason"] ?? "view only")") }
    } else if let code = s["verification_code"] as? String {
        lines.append("waiting for approval on the host — its user should see the code \(code)")
    } else if let error = s["error"] {
        lines.append("not connected: \(error)")
    } else {
        lines.append("connecting…")
    }
    return lines.joined(separator: "\n")
}

func client(_ p: Parsed) throws -> AgentSocketClient {
    try AgentSocketClient(path: try AgentLauncher.socket(for: p.options["session"]), timeout: 120)
}

func runDaemon(_ p: Parsed) throws -> Never {
    guard let host = p.options["host"] else { throw Usage("daemon needs --host") }
    var config = HeadlessAgent.Config(host: host)
    config.port = UInt16(p.options["port"] ?? "") ?? 4433
    config.fingerprint = p.options["fingerprint"] ?? ""
    config.label = p.options["label"] ?? "agent"
    if let edge = p.options["max-edge"].flatMap(Int.init) { config.maxEdge = edge }
    if let size = p.options["size"] {
        let wh = size.lowercased().split(separator: "x").compactMap { Int($0) }
        guard wh.count == 2, wh.allSatisfy({ (320...8192).contains($0) }) else { throw Usage("--size is WxH, e.g. 1440x900") }
        config.size = (wh[0], wh[1])
    }
    let name = p.options["name"] ?? "default"
    guard AgentPaths.isValidName(name) else { throw Usage("“\(name)” isn't a session name") }
    signal(SIGPIPE, SIG_IGN)
    MainActor.assumeIsolated {
        do {
            let agent = try HeadlessAgent(config: config)
            func stamp() -> String { ISO8601DateFormatter().string(from: Date()) }
            agent.onStatus = { print("\(stamp()) \($0)"); fflush(stdout) }
            agent.onStatus("agent key \(QUICIdentity.abbreviatedKeyString(agent.agentFingerprint)) dialing \(host):\(config.port)")
            let inner = agent.handler
            let server = AgentSocketServer(path: AgentPaths.headlessSocket(name)) { op, args in
                if op == "disconnect" {
                    DispatchQueue.main.async {
                        MainActor.assumeIsolated { agent.stop("disconnected by request") }
                    }
                    return ["disconnected": true]
                }
                return try inner(op, args)
            }
            agent.onFinished = { reason in
                print("\(stamp()) session over: \(reason)")
                server.stop()
                exit(0)
            }
            try server.start()
            for sig in [SIGTERM, SIGINT] {
                signal(sig, SIG_IGN)
                let source = DispatchSource.makeSignalSource(signal: sig, queue: .main)
                source.setEventHandler { MainActor.assumeIsolated { agent.stop("signal \(sig)") } }
                source.resume()
                Signals.keep.append(source)
            }
            agent.start()
            Signals.agent = agent
        } catch {
            print("glassact daemon: \(error)")
            exit(1)
        }
    }
    // A run loop, not dispatchMain(): the session's timers (status poll,
    // redial) are run-loop timers on main.
    RunLoop.main.run()
    exit(0)
}

@MainActor enum Signals {
    static var keep: [any DispatchSourceSignal] = []
    static var agent: HeadlessAgent?
}

func run() throws {
    let args = CommandLine.arguments.dropFirst()
    guard let command = args.first else { print(usage); return }
    let p = try Parsed(args.dropFirst())
    let json = p.switches.contains("json")
    if p.switches.contains("help") || command == "help" || command == "--help" || command == "-h" {
        print(usage)
        return
    }
    func act(_ op: String, _ a: [String: Any]) throws {
        let r = try client(p).call(op, a)
        emit(r, json: json) { r.isEmpty ? "" : r.map { "\($0.key): \($0.value)" }.sorted().joined(separator: "\n") }
    }
    switch command {
    case "version", "--version":
        print("glassact \(version)" + (commit.map { " (\($0))" } ?? ""))
    case "daemon":
        try runDaemon(p)
    case "mcp":
        signal(SIGPIPE, SIG_IGN)
        MCPServer(executable: executablePath(), version: version).run()
    case "connect":
        guard let host = p.positional.first else { throw Usage("connect needs a host") }
        var options = AgentLauncher.ConnectOptions(host: host)
        if let port = p.options["port"] { guard let v = UInt16(port) else { throw Usage("bad port") }; options.port = v }
        options.fingerprint = p.options["fingerprint"] ?? ""
        options.size = p.options["size"]
        options.label = p.options["label"] ?? "agent"
        options.name = p.options["name"] ?? p.options["session"] ?? "default"
        options.maxEdge = p.options["max-edge"].flatMap(Int.init)
        var status = try AgentLauncher.connect(options, executable: executablePath())
        emit(status, json: json) { describeStatus(status) }
        // --wait: keep waiting through approval until connected (or failed).
        if p.switches.contains("wait") {
            let socket = AgentPaths.headlessSocket(options.name)
            while (status["phase"] as? String) == "awaiting_approval" || (status["phase"] as? String) == "dialing" {
                Thread.sleep(forTimeInterval: 1)
                guard let next = try? AgentSocketClient(path: socket, timeout: 5).call("status") else {
                    throw Usage("the session ended — see \(AgentPaths.headlessLog(options.name).path)")
                }
                status = next
            }
            emit(status, json: json) { describeStatus(status) }
        }
    case "disconnect":
        let name = p.options["session"] ?? "default"
        guard name != "viewer" else { throw Usage("the Viewer's session is the person's — close it in Glass Act Viewer") }
        _ = try AgentSocketClient(path: try AgentLauncher.socket(for: name)).call("disconnect")
        if !json { print("disconnected") }
    case "sessions":
        let all = AgentLauncher.sessions()
        if json {
            emit(["sessions": all.map { ["name": $0.name, "status": $0.status] as [String: Any] }], json: true) { "" }
        } else {
            print(all.isEmpty ? "no sessions" : all.map { "\($0.name)\t\(describeStatus($0.status).replacingOccurrences(of: "\n", with: "; "))" }
                .joined(separator: "\n"))
        }
    case "status":
        let r = try client(p).call("status")
        emit(r, json: json) { describeStatus(r) }
    case "forget":
        guard let target = p.positional.first else { throw Usage("forget needs HOST[:PORT]") }
        let parts = target.split(separator: ":")
        let port = parts.count > 1 ? UInt16(parts[1]) ?? 4433 : 4433
        let known = KnownHosts(url: AgentPaths.dataDirectory.appendingPathComponent(IdentityFiles.knownHosts))
        try known.forget(host: String(parts[0]), port: port)
        print("forgot \(parts[0]):\(port)")
    case "screenshot", "zoom":
        var a: [String: Any] = ["settled": !p.switches.contains("no-settle")]
        if command == "zoom" {
            guard let r = p.positional.first else { throw Usage("zoom needs x,y,width,height") }
            a["region"] = try p.rect(r)
        } else if let r = p.options["region"] {
            a["region"] = try p.rect(r)
        }
        let r = try client(p).call(command, a)
        guard let b64 = r["png_base64"] as? String, let png = Data(base64Encoded: b64) else { throw Usage("no image in the reply") }
        let out = p.options["o"] ?? "screenshot-\(Int(Date().timeIntervalSince1970)).png"
        try png.write(to: URL(fileURLWithPath: out))
        emit(r.merging(["file": out]) { $1 }, json: json) {
            "\(out) (\(r["width"] ?? "?")×\(r["height"] ?? "?")\((r["settled"] as? Bool) == false ? ", still changing" : ""))"
        }
    case "click", "double-click", "right-click":
        var a: [String: Any] = ["x": try p.number(0, "X"), "y": try p.number(1, "Y")]
        a["button"] = command == "right-click" ? "right" : (p.options["button"] ?? "left")
        a["count"] = command == "double-click" ? 2 : Int(p.options["count"] ?? "1") ?? 1
        if let m = p.options["modifiers"] { a["modifiers"] = m }
        try act("click", a)
    case "move":
        try act("move", ["x": try p.number(0, "X"), "y": try p.number(1, "Y")])
    case "mouse-down", "mouse-up":
        var a: [String: Any] = ["button": p.options["button"] ?? "left"]
        if p.positional.count >= 2 { a["x"] = try p.number(0, "X"); a["y"] = try p.number(1, "Y") }
        try act(command == "mouse-down" ? "mouse_down" : "mouse_up", a)
    case "drag":
        try act("drag", ["from": [try p.number(0, "X1"), try p.number(1, "Y1")],
                         "to": [try p.number(2, "X2"), try p.number(3, "Y2")],
                         "button": p.options["button"] ?? "left"])
    case "scroll":
        guard p.positional.count >= 3 else { throw Usage("scroll X Y up|down|left|right [AMOUNT]") }
        var a: [String: Any] = ["x": try p.number(0, "X"), "y": try p.number(1, "Y"), "direction": p.positional[2]]
        if p.positional.count > 3 { a["amount"] = Int(p.positional[3]) ?? 3 }
        try act("scroll", a)
    case "key":
        guard let combo = p.positional.first else { throw Usage("key needs a key, e.g. cmd+c") }
        try act("key", ["key": combo, "repeat": Int(p.options["repeat"] ?? "1") ?? 1])
    case "type":
        guard !p.positional.isEmpty else { throw Usage("type needs text") }
        try act("type", ["text": p.positional.joined(separator: " ")])
    case "wait-settle":
        try act("wait_for_settle", ["timeout": Double(p.options["timeout"] ?? "5") ?? 5])
    case "wait-change":
        var a: [String: Any] = ["timeout": Double(p.options["timeout"] ?? "10") ?? 10]
        if let r = p.options["region"] { a["region"] = try p.rect(r) }
        try act("wait_for_change", a)
    case "cursor":
        try act("cursor_position", [:])
    case "windows":
        let r = try client(p).call("list_windows")
        emit(r, json: json) {
            ((r["windows"] as? [[String: Any]]) ?? []).map { "\($0["id"] ?? "")\t\($0["app"] ?? "")\t\($0["title"] ?? "")" }
                .joined(separator: "\n")
        }
    case "share-window":
        try act("share_window", ["id": Int(p.positional.first ?? "") ?? 0])
    case "clipboard":
        if p.positional.first == "set" {
            try act("clipboard_set", ["text": p.positional.dropFirst().joined(separator: " ")])
        } else {
            let r = try client(p).call("clipboard_get")
            emit(r, json: json) { (r["text"] as? String) ?? "" }
        }
    case "ui-tree":
        var a: [String: Any] = [:]
        if let w = p.options["window"].flatMap(Int.init) { a["window_id"] = w }
        if let n = p.options["max-nodes"].flatMap(Int.init) { a["max_nodes"] = n }
        let r = try client(p).call("ui_tree", a)
        let data = (try? JSONSerialization.data(withJSONObject: r, options: [.prettyPrinted, .sortedKeys])) ?? Data()
        print(String(decoding: data, as: UTF8.self))
    default:
        throw Usage("unknown command “\(command)” — glassact help")
    }
}

do {
    try run()
} catch {
    FileHandle.standardError.write(Data("glassact: \(error)\n".utf8))
    exit(1)
}
