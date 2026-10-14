import Foundation

/// `glassact mcp`: a Model Context Protocol server on stdin/stdout (newline-
/// delimited JSON-RPC 2.0) exposing a remote Mac as tools. Each tool call
/// goes to an agent session over its socket — the Viewer app's live one, or
/// a headless one this server starts with `connect` — so the session
/// outlives the MCP client.
public final class MCPServer {
    public static let protocolVersion = "2025-06-18"
    private let executable: String
    private let version: String
    /// Which session tool calls go to (nil = resolve on each call).
    private var selected: String?

    public init(executable: String, version: String) {
        self.executable = executable
        self.version = version
    }

    /// Serve until stdin closes.
    public func run() {
        while let line = readLine(strippingNewline: true) {
            guard !line.isEmpty,
                  let message = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any] else { continue }
            if let reply = handle(message) { write(reply) }
        }
    }

    /// One JSON-RPC message → its reply (nil for notifications).
    public func handle(_ message: [String: Any]) -> [String: Any]? {
        guard let method = message["method"] as? String else { return nil }
        let id = message["id"]
        guard let id, !(id is NSNull) else { return nil } // notification
        let params = message["params"] as? [String: Any] ?? [:]
        switch method {
        case "initialize":
            let asked = params["protocolVersion"] as? String
            return result(id, [
                "protocolVersion": asked ?? Self.protocolVersion,
                "capabilities": ["tools": ["listChanged": false]],
                "serverInfo": ["name": "glassact", "version": version],
                "instructions": Self.instructions,
            ])
        case "ping":
            return result(id, [:])
        case "tools/list":
            return result(id, ["tools": Self.tools])
        case "tools/call":
            guard let name = params["name"] as? String else { return error(id, -32602, "tools/call needs a name") }
            return result(id, call(name, params["arguments"] as? [String: Any] ?? [:]))
        default:
            return error(id, -32601, "unknown method \(method)")
        }
    }

    // MARK: Tools

    private func call(_ name: String, _ args: [String: Any]) -> [String: Any] {
        do {
            switch name {
            case "connect":
                guard let host = args["host"] as? String, !host.isEmpty else { return failure("connect needs a host") }
                var options = AgentLauncher.ConnectOptions(host: host)
                if let port = (args["port"] as? NSNumber)?.intValue { options.port = UInt16(clamping: port) }
                if let fp = args["fingerprint"] as? String { options.fingerprint = fp }
                if let size = args["size"] as? String { options.size = size }
                if let label = args["label"] as? String { options.label = label }
                if let session = args["session"] as? String { options.name = session }
                let status = try AgentLauncher.connect(options, executable: executable)
                selected = options.name
                return text(describe(status))
            case "attach_viewer":
                let status = try AgentSocketClient(path: try AgentLauncher.socket(for: "viewer")).call("status")
                selected = "viewer"
                return text("Attached to Glass Act Viewer's live session.\n" + describe(status))
            case "disconnect":
                let session = selected
                selected = nil
                if session == "viewer" { return text("Detached from Glass Act Viewer's session (it stays connected).") }
                _ = try client().call("disconnect")
                return text("Disconnected.")
            case "list_sessions":
                let all = AgentLauncher.sessions()
                return text(all.isEmpty ? "No agent sessions are running."
                            : all.map { "\($0.name): \(describe($0.status))" }.joined(separator: "\n"))
            case "screenshot", "zoom":
                let r = try client().call(name, args)
                return image(r)
            default:
                guard Self.toolNames.contains(name) else { return failure("unknown tool \(name)") }
                var opArgs = args
                let wantShot = (opArgs.removeValue(forKey: "screenshot") as? Bool) ?? false
                let c = try client()
                let r = try c.call(name, opArgs)
                let summary = r.isEmpty ? "ok" : jsonText(r)
                guard wantShot else { return text(summary) }
                var shot = image(try c.call("screenshot", [:]))
                if var content = shot["content"] as? [[String: Any]] {
                    content.insert(["type": "text", "text": summary], at: 0)
                    shot["content"] = content
                }
                return shot
            }
        } catch {
            return failure("\(error)")
        }
    }

    private func client() throws -> AgentSocketClient {
        try AgentSocketClient(path: try AgentLauncher.socket(for: selected), timeout: 120)
    }

    private func describe(_ status: [String: Any]) -> String {
        if (status["connected"] as? Bool) == true {
            let screen = status["screen"] as? [String: Any]
            var line = "Connected to \(status["host"] ?? status["target"] ?? "the host")"
            if let w = screen?["width"], let h = screen?["height"] { line += " — screen \(w)×\(h) (use these coordinates)" }
            if (status["control"] as? Bool) == false {
                line += ". Agent input is off: \(status["control_reason"] ?? "view only")"
            }
            return line + "."
        }
        if let code = status["verification_code"] as? String {
            return "Waiting for the host's user to approve this agent. They should see the code \(code) — "
                + "ask them to check it matches and click Allow, then call status."
        }
        if let error = status["error"] { return "Not connected: \(error)" }
        return "Connecting…"
    }

    private func image(_ r: [String: Any]) -> [String: Any] {
        guard let data = r["png_base64"] as? String else { return failure("no image in the reply") }
        var info = "Screenshot \(r["width"] ?? "?")×\(r["height"] ?? "?")"
        if let region = r["region"] { info += " of region \(region)" }
        if (r["settled"] as? Bool) == false { info += " (still changing — may be mid-update)" }
        return ["content": [["type": "image", "data": data, "mimeType": "image/png"], ["type": "text", "text": info]]]
    }

    private func text(_ s: String) -> [String: Any] { ["content": [["type": "text", "text": s]]] }
    private func failure(_ s: String) -> [String: Any] { ["content": [["type": "text", "text": s]], "isError": true] }

    private func jsonText(_ object: [String: Any]) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]) else { return "ok" }
        return String(decoding: data, as: UTF8.self)
    }

    private func result(_ id: Any, _ result: [String: Any]) -> [String: Any] {
        ["jsonrpc": "2.0", "id": id, "result": result]
    }

    private func error(_ id: Any, _ code: Int, _ message: String) -> [String: Any] {
        ["jsonrpc": "2.0", "id": id, "error": ["code": code, "message": message]]
    }

    private func write(_ object: [String: Any]) {
        guard var data = try? JSONSerialization.data(withJSONObject: object) else { return }
        data.append(0x0A)
        FileHandle.standardOutput.write(data)
    }

    // MARK: Tool definitions

    static let instructions = """
        Drives a remote Mac through Glass Act. Start with `connect` (a headless session of your own — the \
        host's user approves it once) or `attach_viewer` (the session the person already has open in \
        Glass Act Viewer). Then: `screenshot` to look, act with `click`/`type`/`key`/`scroll`/`drag`, and \
        `wait_for_settle` before judging the result. Coordinates are in the screenshot's pixel space \
        (status reports it). Screenshots are exact once settled. `ui_tree` lists the focused window's \
        controls with frames — often easier than reading pixels. If an input call says the person is \
        using it, wait: people at either end always win.
        """

    static let toolNames: Set<String> = Set(AgentDriver.operations).union(["disconnect"])

    private static func schema(_ properties: [String: Any], required: [String] = []) -> [String: Any] {
        ["type": "object", "properties": properties, "required": required]
    }
    private static var num: [String: Any] { ["type": "number"] }
    private static var int: [String: Any] { ["type": "integer"] }
    private static var str: [String: Any] { ["type": "string"] }
    private static var rect: [String: Any] {
        ["type": "array", "items": ["type": "number"], "minItems": 4, "maxItems": 4,
         "description": "[x, y, width, height] in screen coordinates"]
    }
    private static var shot: [String: Any] { ["type": "boolean", "description": "also return a screenshot after acting"] }
    private static var button: [String: Any] { ["type": "string", "enum": ["left", "right", "middle"]] }

    static var tools: [[String: Any]] { [
        ["name": "connect", "description": "Connect a headless agent session to a Mac running Glass Act Host. The first time, the host's user must approve it (a verification code is shown).",
         "inputSchema": schema(["host": ["type": "string", "description": "host name or address, e.g. my-mac.local"],
                                "port": int, "fingerprint": ["type": "string", "description": "host key to pin (optional)"],
                                "size": ["type": "string", "description": "ask for a virtual display of WxH points, e.g. 1440x900 (optional)"],
                                "label": ["type": "string", "description": "how the host names this agent"],
                                "session": ["type": "string", "description": "session name (default: default)"]],
                               required: ["host"])],
        ["name": "attach_viewer", "description": "Use the session the person has open in Glass Act Viewer (they must allow agents in its Settings).",
         "inputSchema": schema([:])],
        ["name": "disconnect", "description": "End the headless session (or detach from Glass Act Viewer's).", "inputSchema": schema([:])],
        ["name": "list_sessions", "description": "List running agent sessions.", "inputSchema": schema([:])],
        ["name": "status", "description": "Connection state, screen size in agent coordinates, and whether input is accepted.", "inputSchema": schema([:])],
        ["name": "screenshot", "description": "Capture the remote screen (waits until it settles, so text is exact).",
         "inputSchema": schema(["settled": ["type": "boolean", "description": "wait for the screen to stop changing (default true)"],
                                "region": rect])],
        ["name": "zoom", "description": "Capture a region at higher resolution.", "inputSchema": schema(["region": rect], required: ["region"])],
        ["name": "click", "description": "Click at a point.",
         "inputSchema": schema(["x": num, "y": num, "button": button,
                                "count": ["type": "integer", "minimum": 1, "maximum": 3, "description": "2 = double-click"],
                                "modifiers": ["type": "string", "description": "held during the click, e.g. shift or cmd+shift"],
                                "screenshot": shot], required: ["x", "y"])],
        ["name": "move", "description": "Move the pointer.", "inputSchema": schema(["x": num, "y": num, "screenshot": shot], required: ["x", "y"])],
        ["name": "mouse_down", "description": "Press a mouse button (at x, y if given).", "inputSchema": schema(["x": num, "y": num, "button": button])],
        ["name": "mouse_up", "description": "Release a mouse button (at x, y if given).", "inputSchema": schema(["x": num, "y": num, "button": button])],
        ["name": "drag", "description": "Drag from one point to another (or along a path).",
         "inputSchema": schema(["from": ["type": "array", "items": num], "to": ["type": "array", "items": num],
                                "path": ["type": "array", "items": ["type": "array", "items": num]],
                                "button": button, "screenshot": shot])],
        ["name": "scroll", "description": "Scroll at a point.",
         "inputSchema": schema(["x": num, "y": num, "direction": ["type": "string", "enum": ["up", "down", "left", "right"]],
                                "amount": ["type": "integer", "description": "lines (default 3)"], "screenshot": shot],
                               required: ["direction"])],
        ["name": "key", "description": "Press a key or shortcut, e.g. return, cmd+c, cmd+shift+t, page_down.",
         "inputSchema": schema(["key": str, "repeat": int, "action": ["type": "string", "enum": ["press", "down", "up"]],
                                "screenshot": shot], required: ["key"])],
        ["name": "hold_key", "description": "Hold a key for some seconds.", "inputSchema": schema(["key": str, "seconds": num], required: ["key"])],
        ["name": "type", "description": "Type text (any language; independent of keyboard layout).",
         "inputSchema": schema(["text": str, "screenshot": shot], required: ["text"])],
        ["name": "wait", "description": "Wait some seconds.", "inputSchema": schema(["seconds": num])],
        ["name": "wait_for_settle", "description": "Wait until the screen stops changing.", "inputSchema": schema(["timeout": num])],
        ["name": "wait_for_change", "description": "Wait until the screen (or a region) changes.",
         "inputSchema": schema(["region": rect, "timeout": num])],
        ["name": "cursor_position", "description": "Where the agent last put the pointer.", "inputSchema": schema([:])],
        ["name": "list_windows", "description": "The host's on-screen windows (id, app, title).", "inputSchema": schema([:])],
        ["name": "share_window", "description": "Share only one window (its id), or 0 for the whole display.",
         "inputSchema": schema(["id": int], required: ["id"])],
        ["name": "clipboard_get", "description": "The host's clipboard text.", "inputSchema": schema([:])],
        ["name": "clipboard_set", "description": "Set the host's clipboard text.", "inputSchema": schema(["text": str], required: ["text"])],
        ["name": "ui_tree", "description": "Accessibility tree of the focused window (or window_id): roles, titles, values and frames in screen coordinates.",
         "inputSchema": schema(["window_id": int, "max_nodes": int])],
    ] }
}
