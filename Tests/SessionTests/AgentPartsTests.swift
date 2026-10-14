import Foundation
import Testing
import GlassActSession

@Suite struct KeyMapTests {
    @Test func combosParseLikeAKeyboard() throws {
        #expect(try KeyMap.parse("Return") == .init(modifiers: [], keyCode: 36))
        #expect(try KeyMap.parse("cmd+c") == .init(modifiers: .command, keyCode: 8))
        #expect(try KeyMap.parse("ctrl+shift+Page_Down") == .init(modifiers: [.control, .shift], keyCode: 121))
        #expect(try KeyMap.parse("super+alt+left") == .init(modifiers: [.command, .option], keyCode: 123))
        #expect(try KeyMap.parse("BackSpace") == .init(modifiers: [], keyCode: 51))
        #expect(try KeyMap.parse("shift") == .init(modifiers: .shift, keyCode: nil))
        #expect(try KeyMap.parse("cmd++") == .init(modifiers: [.command, .shift], keyCode: 24)) // "+" is shift-=
        #expect(try KeyMap.parse("A") == .init(modifiers: .shift, keyCode: 0))
        #expect(try KeyMap.parse("F12") == .init(modifiers: [], keyCode: 111))
    }

    @Test func badCombosSayWhy() {
        #expect(throws: KeyMap.ParseError.unknownKey("hyper")) { try KeyMap.parse("hyper+x") }
        #expect(throws: KeyMap.ParseError.twoKeys("a+b")) { try KeyMap.parse("a+b") }
        #expect(throws: KeyMap.ParseError.empty) { try KeyMap.parse("") }
    }

    @Test func modifierFlagsAreCGEventFlags() {
        #expect(KeyMap.Modifier([.command, .shift]).eventFlags == 0x0012_0000)
        #expect(KeyMap.Modifier.control.keyCode == 59)
    }

    @Test func typingFallbackCoversUSAscii() {
        #expect(KeyMap.keystroke(for: "a")! == (0, false))
        #expect(KeyMap.keystroke(for: "A")! == (0, true))
        #expect(KeyMap.keystroke(for: "?")! == (44, true))
        #expect(KeyMap.keystroke(for: "\n")! == (36, false))
        #expect(KeyMap.keystroke(for: "é") == nil)
    }
}

@Suite struct AgentSocketTests {
    @Test func requestsAndErrorsRoundTrip() throws {
        let path = FileManager.default.temporaryDirectory
            .appendingPathComponent("s\(UInt32.random(in: 0...UInt32.max)).sock")
        let server = AgentSocketServer(path: path) { op, args in
            if op == "boom" { throw AgentSocketError("it broke") }
            return ["op": op, "echo": args["v"] ?? NSNull()]
        }
        try server.start()
        defer { server.stop() }
        let client = try AgentSocketClient(path: path, timeout: 5)
        let r = try client.call("ping", ["v": 42])
        #expect(r["op"] as? String == "ping")
        #expect((r["echo"] as? NSNumber)?.intValue == 42)
        #expect(throws: AgentSocketError.self) { _ = try client.call("boom") }
        // Answers stay in order across many requests on one connection.
        for i in 0..<50 {
            #expect((try client.call("n", ["v": i])["echo"] as? NSNumber)?.intValue == i)
        }
        // A second server can't take over a live socket.
        #expect(throws: AgentSocketError.self) { try AgentSocketServer(path: path) { _, _ in [:] }.start() }
    }

    @Test func sessionNamesStayInTheirLane() {
        #expect(AgentPaths.isValidName("default"))
        #expect(AgentPaths.isValidName("work-mac_2"))
        #expect(!AgentPaths.isValidName("viewer"))
        #expect(!AgentPaths.isValidName("../x"))
        #expect(!AgentPaths.isValidName(""))
    }
}

@Suite struct MCPServerTests {
    let server = MCPServer(executable: "/usr/bin/false", version: "test")

    @Test func handshakeAndToolList() throws {
        let initialized = try #require(server.handle(["jsonrpc": "2.0", "id": 1, "method": "initialize",
                                                      "params": ["protocolVersion": "2025-06-18"]]))
        let result = try #require(initialized["result"] as? [String: Any])
        #expect(result["protocolVersion"] as? String == "2025-06-18")
        #expect((result["serverInfo"] as? [String: Any])?["name"] as? String == "glassact")
        #expect(server.handle(["jsonrpc": "2.0", "method": "notifications/initialized"]) == nil)

        let listed = try #require(server.handle(["jsonrpc": "2.0", "id": 2, "method": "tools/list"]))
        let tools = try #require((listed["result"] as? [String: Any])?["tools"] as? [[String: Any]])
        let names = Set(tools.compactMap { $0["name"] as? String })
        for needed in ["connect", "attach_viewer", "screenshot", "click", "type", "key", "scroll", "drag", "ui_tree", "wait_for_settle"] {
            #expect(names.contains(needed), "missing tool \(needed)")
        }
        #expect(tools.allSatisfy { ($0["inputSchema"] as? [String: Any])?["type"] as? String == "object" })
        // Every listed tool is something the server can dispatch.
        let dispatchable = Set(["connect", "attach_viewer", "disconnect", "list_sessions"]).union(AgentDriverOps.all)
        #expect(names.isSubset(of: dispatchable))
    }

    @Test func unknownMethodsAndToolsAreErrors() throws {
        let unknown = try #require(server.handle(["jsonrpc": "2.0", "id": 3, "method": "resources/list"]))
        #expect((unknown["error"] as? [String: Any])?["code"] as? Int == -32601)
        let call = try #require(server.handle(["jsonrpc": "2.0", "id": 4, "method": "tools/call",
                                               "params": ["name": "teleport", "arguments": [:]]]))
        #expect((call["result"] as? [String: Any])?["isError"] as? Bool == true)
    }
}

enum AgentDriverOps {
    static var all: Set<String> { Set(AgentDriver.operations) }
}
