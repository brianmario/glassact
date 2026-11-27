import CoreGraphics
import CoreText
import Foundation
import GlassActCore
import GlassActHybridVideo
import GlassActTransport
import GlassActWire

// `glassact-testhost`: a Host with a synthetic screen, for developing a
// Viewer without sharing a real one. It speaks the real protocol (QUIC,
// HELLO, tiles, HEVC/AV1 video, cursor metadata, geometry) through the real
// HostEngine, and draws what the viewer sends: clicks as dots, drags as
// trails, keys, scrolls and clipboard text in a status panel. A bouncing box
// keeps a video region busy (`--still` turns it off).
//
// It shows no real pixels and injects no input, so by default it admits any
// viewer key. To exercise a viewer's other ways in: `--sign-in-password P`
// makes new keys sign in (user `test`), and `--ask-after S` asks for them as
// a Host's user would, printing the code both screens show, then approves
// each key S seconds after its first refused dial. Mac only.

struct Options {
    var port: UInt16 = 4533
    var width = 1600, height = 1000
    var video = true
    /// The AV1 encoder, as the Host's (`HostController.av1Encoder`); `--libaom` switches.
    var av1: HostVideoEncoders.AV1 = .glassAct
    var motion = true
    var signInPassword: String?
    /// Ask for new keys, approving each this long after its first dial.
    var askAfter: Double?
    /// Every input but plain moves as a timed stdout line, and what the viewer still
    /// held when its session ended.
    var inputLog = false
    /// `--displays`: the host's displays (display choice, §4.10), side by side, the first the
    /// main one. Empty: one screen and no display list, as before.
    var displays: [(width: Int, height: Int)] = []

    static func parse(_ args: [String]) -> Options {
        var o = Options()
        var i = 1
        func next() -> String? { i += 1; return i < args.count ? args[i] : nil }
        while i < args.count {
            switch args[i] {
            case "--port": o.port = next().flatMap(UInt16.init) ?? o.port
            case "--size":
                let parts = (next() ?? "").split(separator: "x").compactMap { Int($0) }
                if parts.count == 2 { (o.width, o.height) = (parts[0], parts[1]) }
            case "--tiles-only": o.video = false
            case "--libaom": o.av1 = .libaom
            case "--still": o.motion = false
            case "--sign-in-password": o.signInPassword = next()
            case "--ask-after": o.askAfter = next().flatMap(Double.init)
            case "--input-log": o.inputLog = true
            case "--displays":
                o.displays = (next() ?? "").split(separator: ",").compactMap { size in
                    let wh = size.split(separator: "x").compactMap { Int($0) }
                    guard wh.count == 2, (320...4096).contains(wh[0]), (240...4096).contains(wh[1]) else { return nil }
                    return (wh[0], wh[1])
                }
                guard o.displays.count >= 2 else {
                    FileHandle.standardError.write(Data("--displays wants two or more sizes, e.g. 1600x1000,1280x800\n".utf8))
                    exit(2)
                }
                (o.width, o.height) = o.displays[0]
            case "-h", "--help":
                print("""
                    usage: glassact-testhost [--port 4533] [--size 1600x1000] [--tiles-only] [--libaom] [--still]
                                             [--sign-in-password P | --ask-after SECONDS] [--input-log]
                                             [--displays WxH,WxH[,…]]
                    A Glass Act host with a synthetic screen, for developing viewers. Its AV1 is
                    Glass Act's encoder, as the Host's (macOS 27, Apple-silicon GPU); --libaom
                    runs libaom's instead, as older releases did. --input-log prints every input
                    but plain moves with the time, and what the viewer still held down when its
                    session ended (a viewer should release everything before it leaves).
                    --displays makes it a host with several displays (display choice): the viewer
                    can list them and pick one, as from a Mac with more than one. Picks are
                    refused ("not now") under Virtual Display and Client Resolution, as the Host
                    does; Scale fits the picked display into the viewer's size, Native shows it.
                    """)
                exit(0)
            default:
                FileHandle.standardError.write(Data("unknown option \(args[i])\n".utf8))
                exit(2)
            }
            i += 1
        }
        return o
    }
}

/// The synthetic screen, and what the viewer has done to it. `queue`-confined.
final class Scene {
    private(set) var width: Int, height: Int
    private(set) var pixels: [UInt8]
    private let motion: Bool
    private var dots: [(x: Int, y: Int, button: Int)] = []
    private var trail: [(x: Int, y: Int)] = []
    private var dragging = false
    private(set) var pointer: (x: Int, y: Int)
    private var lines: [String] = ["Waiting for input…"]
    private var typed = ""
    private var scrollTotal = (x: 0, y: 0)
    private var startUS = MonotonicClock.nowUS
    /// `--input-log`: timed stdout lines for input.
    var logInput = false
    /// What the viewer holds down: key codes, and buttons as bits.
    private var keysDown: Set<Int> = []
    private var buttonsDown = 0
    private var dragMoves = 0
    /// `--displays`: which display this is, in the header, and its own background.
    var displayLabel: String?
    var tint: (r: CGFloat, g: CGFloat, b: CGFloat) = (0.12, 0.16, 0.20)

    init(width: Int, height: Int, motion: Bool) {
        self.width = width
        self.height = height
        self.motion = motion
        pixels = [UInt8](repeating: 0, count: width * height * 4)
        pointer = (width / 2, height / 2)
    }

    func resize(width: Int, height: Int) {
        self.width = width
        self.height = height
        pixels = [UInt8](repeating: 0, count: width * height * 4)
        dots.removeAll()
        trail.removeAll()
        pointer = (width / 2, height / 2)
        note("screen is now \(width)×\(height)")
    }

    /// The host moved the pointer (a display pick that places it).
    func placePointer(x: Int, y: Int) {
        pointer = (max(0, min(x, width - 1)), max(0, min(y, height - 1)))
    }

    private func note(_ line: String) {
        lines.append(line)
        if lines.count > 12 { lines.removeFirst(lines.count - 12) }
    }

    /// One stdout line with the wall-clock time, flushed (stdout may be a file).
    static func log(_ line: String) {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss.SSS"
        print("glassact-testhost: [\(f.string(from: Date()))] \(line)")
        fflush(stdout)
    }

    private static let buttonNames = ["left", "right", "middle"]

    /// `--input-log`: the line for one input, nil for a plain move.
    private func logLine(kind: Int, x: Int, y: Int, a: Int, b: Int) -> String? {
        switch kind {
        case 1:
            if buttonsDown != 0 { dragMoves += 1 }
            return nil
        case 2: return "\(Self.buttonNames[min(b, 2)]) down at \(x),\(y) click \(max(1, a))"
        case 3: return "\(Self.buttonNames[min(b, 2)]) up at \(x),\(y) after \(dragMoves) drag moves"
        case 4, 7: return "scroll \(a),\(b) (\(kind == 7 ? "points" : "lines"))"
        case 5, 6:
            return "key \(Self.keyName(x)) (0x\(String(x, radix: 16))) \(kind == 5 ? "down" : "up")"
                + " · flags 0x\(String(UInt32(truncatingIfNeeded: a), radix: 16))"
        default: return "input kind \(kind) \(x),\(y) \(a) \(b)"
        }
    }

    /// The session ended: let go of what the viewer still held, saying what that was.
    func releaseHeld() {
        let keys = keysDown.sorted().map { "key \(Self.keyName($0)) (0x\(String($0, radix: 16)))" }
        let buttons = (0..<3).filter { buttonsDown & (1 << $0) != 0 }.map { "\(Self.buttonNames[$0]) button" }
        let held = keys + buttons
        if !held.isEmpty { note("released at session end: \(held.joined(separator: ", "))") }
        if logInput {
            Self.log(held.isEmpty ? "session ended with nothing held" : "released at session end: \(held.joined(separator: ", "))")
        }
        keysDown.removeAll()
        buttonsDown = 0
        dragging = false
    }

    /// INPUT (kind, x, y, a, b) as `ControlMessage.input` defines it.
    func apply(kind: Int, x: Int, y: Int, a: Int, b: Int) {
        switch kind {
        case 2: buttonsDown |= 1 << min(b, 2); dragMoves = 0
        case 3: buttonsDown &= ~(1 << min(b, 2))
        case 5: keysDown.insert(x)
        case 6: keysDown.remove(x)
        default: break
        }
        if logInput, let line = logLine(kind: kind, x: x, y: y, a: a, b: b) { Self.log("input: \(line)") }
        switch kind {
        case 1:
            pointer = (x, y)
            if dragging { trail.append((x, y)); if trail.count > 4000 { trail.removeFirst(1000) } }
        case 2:
            pointer = (x, y)
            dots.append((x, y, b))
            if dots.count > 200 { dots.removeFirst() }
            if b == 0 { dragging = true; trail = [(x, y)] }
            note("\(["left", "right", "middle"][min(b, 2)]) down at \(x),\(y)" + (a > 1 ? " (click \(a))" : ""))
        case 3:
            pointer = (x, y)
            if b == 0 { dragging = false }
        case 4, 7:
            scrollTotal.x += a
            scrollTotal.y += b
            note("scroll \(a),\(b) (\(kind == 7 ? "pixels" : "lines")) · total \(scrollTotal.x),\(scrollTotal.y)")
        case 5, 6:
            let down = kind == 5
            let name = Self.keyName(x)
            if down, name.count == 1 {
                typed += (a & (1 << 17)) != 0 ? Self.shifted(name) : name
                if typed.count > 60 { typed.removeFirst(typed.count - 60) }
            }
            note("key \(name) (0x\(String(x, radix: 16))) \(down ? "down" : "up") · flags 0x\(String(UInt32(truncatingIfNeeded: a), radix: 16))")
        default:
            note("input kind \(kind) \(x),\(y) \(a) \(b)")
        }
    }

    func clipboard(_ text: String) { note("clipboard from viewer: \(text.prefix(80))") }
    func text(_ text: String) {
        typed += text
        if typed.count > 60 { typed.removeFirst(typed.count - 60) }
        note("text input: \(text.prefix(60))")
    }

    /// What a key types with shift on a US layout.
    static func shifted(_ key: String) -> String {
        let pairs: [String: String] = ["1": "!", "2": "@", "3": "#", "4": "$", "5": "%", "6": "^", "7": "&", "8": "*",
                                       "9": "(", "0": ")", ",": "<", ".": ">", "/": "?", ";": ":", "'": "\"",
                                       "[": "{", "]": "}", "\\": "|", "-": "_", "=": "+", "`": "~"]
        return pairs[key] ?? key.uppercased()
    }

    /// macOS virtual key codes (kVK_*) for the keys worth naming.
    static func keyName(_ code: Int) -> String {
        let letters: [Int: String] = [
            0x00: "a", 0x0B: "b", 0x08: "c", 0x02: "d", 0x0E: "e", 0x03: "f", 0x05: "g", 0x04: "h", 0x22: "i",
            0x26: "j", 0x28: "k", 0x25: "l", 0x2E: "m", 0x2D: "n", 0x1F: "o", 0x23: "p", 0x0C: "q", 0x0F: "r",
            0x01: "s", 0x11: "t", 0x20: "u", 0x09: "v", 0x0D: "w", 0x07: "x", 0x10: "y", 0x06: "z",
            0x1D: "0", 0x12: "1", 0x13: "2", 0x14: "3", 0x15: "4", 0x17: "5", 0x16: "6", 0x1A: "7", 0x1C: "8",
            0x19: "9", 0x31: " ", 0x2B: ",", 0x2F: ".", 0x2C: "/", 0x29: ";", 0x27: "'", 0x21: "[", 0x1E: "]",
            0x2A: "\\", 0x1B: "-", 0x18: "=", 0x32: "`",
            0x24: "return", 0x30: "tab", 0x33: "delete", 0x35: "escape", 0x37: "command", 0x38: "shift",
            0x3A: "option", 0x3B: "control", 0x39: "caps lock", 0x7B: "left", 0x7C: "right", 0x7D: "down",
            0x7E: "up", 0x36: "right command", 0x3C: "right shift", 0x3D: "right option", 0x3E: "right control",
            0x3F: "fn",
        ]
        return letters[code] ?? "?"
    }

    /// Draws the frame for `nowUS` into `pixels` (BGRA, top-left origin).
    func render(nowUS: UInt64) {
        let w = width, h = height
        pixels.withUnsafeMutableBytes { buf in
            guard let ctx = CGContext(data: buf.baseAddress, width: w, height: h, bitsPerComponent: 8,
                                      bytesPerRow: w * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
                                        | CGBitmapInfo.byteOrder32Little.rawValue) else { return }
            ctx.translateBy(x: 0, y: CGFloat(h))
            ctx.scaleBy(x: 1, y: -1)
            draw(in: ctx, nowUS: nowUS)
        }
    }

    private func draw(in ctx: CGContext, nowUS: UInt64) {
        let w = CGFloat(width), h = CGFloat(height)
        ctx.setFillColor(red: tint.r, green: tint.g, blue: tint.b, alpha: 1)
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        // A 64 px grid: one line per tile edge.
        ctx.setStrokeColor(red: 1, green: 1, blue: 1, alpha: 0.06)
        ctx.setLineWidth(1)
        for x in stride(from: 0, to: w, by: 64) { ctx.stroke(CGRect(x: x + 0.5, y: 0, width: 0, height: h)) }
        for y in stride(from: 0, to: h, by: 64) { ctx.stroke(CGRect(x: 0, y: y + 0.5, width: w, height: 0)) }

        // Header: what this is, the size and a clock (one tile row a second).
        ctx.setFillColor(red: 0.05, green: 0.08, blue: 0.10, alpha: 1)
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: 44))
        let clock = DateFormatter.localizedString(from: Date(), dateStyle: .none, timeStyle: .medium)
        let label = displayLabel.map { "\($0) · " } ?? ""
        text(ctx, "Glass Act test host · \(label)\(width)×\(height) · \(clock)", x: 16, y: 30, size: 20, bold: true)

        // Fine text to judge sharpness.
        let panel = CGRect(x: 24, y: 68, width: min(760, w - 48), height: min(330, h - 100))
        ctx.setFillColor(red: 0.96, green: 0.96, blue: 0.94, alpha: 1)
        ctx.fill(panel)
        let sample = [
            "The quick brown fox jumps over the lazy dog. 0123456789",
            "Static content travels as lossless tiles; motion as video.",
            "Pinch to zoom, two fingers to scroll, two-finger tap to right-click.",
            "ABCDEFGHIJKLMNOPQRSTUVWXYZ abcdefghijklmnopqrstuvwxyz",
            "{ } [ ] ( ) < > ! @ # $ % ^ & * - _ = + ; : ' \" , . / ? \\ |",
        ]
        for (i, line) in sample.enumerated() {
            text(ctx, line, x: panel.minX + 16, y: panel.minY + 32 + CGFloat(i) * 26, size: 15, dark: true)
        }
        for (i, line) in sample.enumerated() {
            text(ctx, line, x: panel.minX + 16, y: panel.minY + 172 + CGFloat(i) * 15, size: 10, dark: true)
        }

        // The status panel: the viewer's last inputs.
        let status = CGRect(x: 24, y: panel.maxY + 24, width: min(760, w - 48),
                            height: max(0, min(330, h - panel.maxY - 48)))
        ctx.setFillColor(red: 0, green: 0, blue: 0, alpha: 0.35)
        ctx.fill(status)
        text(ctx, "typed: \(typed)", x: status.minX + 12, y: status.minY + 24, size: 15, bold: true)
        for (i, line) in lines.enumerated() where status.minY + 50 + CGFloat(i) * 21 < status.maxY {
            text(ctx, line, x: status.minX + 12, y: status.minY + 50 + CGFloat(i) * 21, size: 14)
        }

        // Motion: a bouncing, colour-cycling box (a video region).
        if motion {
            let t = Double(nowUS &- startUS) / 1_000_000
            let box = CGSize(width: min(320, w / 4), height: min(220, h / 4))
            let left = min(w - box.width, panel.maxX + 40)
            let span = (x: max(1, w - left - box.width), y: max(1, h - 60 - box.height))
            func bounce(_ v: Double, _ span: CGFloat) -> CGFloat {
                let p = (v.truncatingRemainder(dividingBy: 2 * Double(span)))
                return CGFloat(p < Double(span) ? p : 2 * Double(span) - p)
            }
            let origin = CGPoint(x: left + bounce(t * 180, span.x), y: 52 + bounce(t * 130, span.y))
            let hue = t.truncatingRemainder(dividingBy: 6) / 6
            ctx.setFillColor(red: 0.5 + 0.5 * sin(hue * 2 * .pi), green: 0.5 + 0.5 * sin(hue * 2 * .pi + 2.1),
                             blue: 0.5 + 0.5 * sin(hue * 2 * .pi + 4.2), alpha: 1)
            ctx.fill(CGRect(origin: origin, size: box))
            text(ctx, String(format: "%.1f s", t), x: origin.x + 16, y: origin.y + 36, size: 24, bold: true, dark: true)
        }

        // Input: the drag trail and click dots.
        if trail.count > 1 {
            ctx.setStrokeColor(red: 1, green: 0.8, blue: 0.2, alpha: 1)
            ctx.setLineWidth(3)
            ctx.beginPath()
            ctx.move(to: CGPoint(x: trail[0].x, y: trail[0].y))
            for p in trail.dropFirst() { ctx.addLine(to: CGPoint(x: p.x, y: p.y)) }
            ctx.strokePath()
        }
        for d in dots {
            switch d.button {
            case 0: ctx.setFillColor(red: 0.2, green: 0.6, blue: 1, alpha: 1)
            case 1: ctx.setFillColor(red: 1, green: 0.3, blue: 0.3, alpha: 1)
            default: ctx.setFillColor(red: 0.3, green: 0.9, blue: 0.4, alpha: 1)
            }
            ctx.fillEllipse(in: CGRect(x: d.x - 7, y: d.y - 7, width: 14, height: 14))
        }
    }

    private func text(_ ctx: CGContext, _ string: String, x: CGFloat, y: CGFloat, size: CGFloat,
                      bold: Bool = false, dark: Bool = false) {
        let font = CTFontCreateWithName((bold ? "Menlo-Bold" : "Menlo-Regular") as CFString, size, nil)
        let color = dark ? CGColor(red: 0.1, green: 0.1, blue: 0.1, alpha: 1) : CGColor(red: 0.92, green: 0.94, blue: 0.96, alpha: 1)
        let attributed = NSAttributedString(string: string, attributes: [
            NSAttributedString.Key(kCTFontAttributeName as String): font,
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): color,
        ])
        let line = CTLineCreateWithAttributedString(attributed)
        ctx.saveGState()
        // Text draws bottom-up: undo the flip around its baseline.
        ctx.textMatrix = CGAffineTransform(scaleX: 1, y: -1)
        ctx.textPosition = CGPoint(x: x, y: y)
        CTLineDraw(line, ctx)
        ctx.restoreGState()
    }

    /// A plain arrow, for cursor metadata (32×32, hotspot at the tip).
    static func arrow() -> [UInt8] {
        let size = 32
        var bgra = [UInt8](repeating: 0, count: size * size * 4)
        bgra.withUnsafeMutableBytes { buf in
            guard let ctx = CGContext(data: buf.baseAddress, width: size, height: size, bitsPerComponent: 8,
                                      bytesPerRow: size * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
                                        | CGBitmapInfo.byteOrder32Little.rawValue) else { return }
            ctx.translateBy(x: 0, y: CGFloat(size))
            ctx.scaleBy(x: 1, y: -1)
            let path = CGMutablePath()
            path.addLines(between: [CGPoint(x: 1, y: 1), CGPoint(x: 1, y: 24), CGPoint(x: 7, y: 18),
                                    CGPoint(x: 11, y: 28), CGPoint(x: 15, y: 26), CGPoint(x: 11, y: 17),
                                    CGPoint(x: 19, y: 17)])
            path.closeSubpath()
            ctx.addPath(path)
            ctx.setFillColor(gray: 0, alpha: 1)
            ctx.setStrokeColor(gray: 1, alpha: 1)
            ctx.setLineWidth(1.5)
            ctx.drawPath(using: .fillStroke)
        }
        return bgra
    }
}

/// The server, one session at a time, all on `queue`.
final class TestHost: @unchecked Sendable {
    let queue = DispatchQueue(label: "glassact.testhost", qos: .userInteractive)
    let options: Options
    let scene: Scene
    var engine: HostEngine?
    var transport: QUICTransport?
    var server: QUICServer?
    /// Keys that signed in (`--sign-in-password`) or were approved
    /// (`--ask-after`). `queue`.
    var approved = Set<String>()
    /// `--ask-after`: when each key was first refused. `queue`.
    var asked: [String: Date] = [:]
    var geometrySettled = false
    var lastPointer: (x: Int, y: Int) = (-1, -1)
    /// `--displays` (display choice, §4.10), `queue`: the display shown, the viewer's last
    /// RESIZE (mode and pixels), whether it asked for the list (it gets it again after a
    /// switch), and a pick's answer held until the rebuilt session runs.
    var shownDisplay = 0
    var geometryMode = 0
    var requestedPixels: (width: Int, height: Int)?
    var viewerWantsDisplayList = false
    var pendingDisplayAnswer: WireDisplaySelection?

    init(options: Options) {
        self.options = options
        scene = Scene(width: options.width, height: options.height, motion: options.motion)
        scene.logInput = options.inputLog
        if !options.displays.isEmpty { showDisplay(0) }
    }

    /// `--ask-after`: refuse `fp` until `wait` seconds after its first dial,
    /// as a Host does while its user decides. `queue`.
    func ask(_ fp: String, approvingAfter wait: Double, host: String) -> Bool {
        guard let first = asked[fp] else {
            asked[fp] = Date()
            let code = QUICIdentity.verificationCode(hostFingerprint: host, viewerFingerprint: fp)
            print("glassact-testhost: asking for \(fp.prefix(16))… — code \(code)")
            return false
        }
        guard Date().timeIntervalSince(first) >= wait else { return false }
        approved.insert(fp)
        print("glassact-testhost: approved \(fp.prefix(16))…")
        return true
    }

    func start() throws {
        let dir = AppPaths.dataDirectory.appendingPathComponent("testhost", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let identity = try QUICIdentity.loadOrCreate(directory: dir, name: "testhost-identity",
                                                     commonName: "glassact-testhost")
        let fingerprint = try QUICIdentity.fingerprint(of: identity)
        var gate: SignInGate?
        if options.askAfter != nil {
            gate = SignInGate(
                verifier: FixedAccount(password: UUID().uuidString), policy: { .ask },
                isApproved: { [weak self] fp in self?.queue.sync { self?.approved.contains(fp) ?? false } ?? false },
                approve: { _ in false })
        } else if let password = options.signInPassword {
            gate = SignInGate(
                verifier: FixedAccount(password: password),
                policy: { .signIn },
                isApproved: { [weak self] fp in self?.queue.sync { self?.approved.contains(fp) ?? false } ?? false },
                approve: { [weak self] approval in
                    self?.queue.async { self?.approved.insert(approval.fingerprint) }
                    print("signed in: \(approval.device) (\(approval.fingerprint.prefix(16))…)")
                    return true
                })
        }
        var signIn: QUICServer.SignInHandler?
        if let gate {
            signIn = { request, peer, address, reply in
                gate.handle(request, peer: peer, address: address, reply: reply)
            }
        }
        let server = try QUICServer(
            port: options.port, identity: identity, queue: queue,
            authorizeViewer: { [weak self] fp in
                guard let self else { return false }
                // Called on `queue` (the server's own).
                if self.approved.contains(fp) { return true }
                if let wait = self.options.askAfter { return self.ask(fp, approvingAfter: wait, host: fingerprint) }
                return self.options.signInPassword == nil
            },
            signIn: signIn)
        server.onReady = { [options] in
            print("glassact-testhost: listening on \(options.port) · key \(QUICIdentity.keyString(fingerprint))")
            if let password = options.signInPassword {
                print("glassact-testhost: new viewers sign in as \"test\" with password \"\(password)\"")
            } else if let wait = options.askAfter {
                print("glassact-testhost: new viewers are asked for, and approved after \(wait) s")
            }
        }
        server.onFailed = { reason in
            print("glassact-testhost: \(reason)")
            exit(1)
        }
        server.onTransport = { [weak self] transport in self?.adopt(transport) }
        server.start()
        self.server = server

        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now(), repeating: .milliseconds(16))
        timer.setEventHandler { [weak self] in self?.tick() }
        timer.resume()
        self.timer = timer
    }
    private var timer: (any DispatchSourceTimer)?

    private func adopt(_ transport: QUICTransport) {
        print("glassact-testhost: viewer connected")
        if self.transport != nil { scene.releaseHeld() } // a superseded session lets go too
        self.transport?.cancel()
        self.transport = transport
        geometrySettled = false
        viewerWantsDisplayList = false
        pendingDisplayAnswer = nil
        transport.onControl = { [weak self] data in self?.engine?.handleControl(data, nowUS: MonotonicClock.nowUS) }
        transport.onState = { [weak self, weak transport] state in
            guard let self, let transport, self.transport === transport else { return }
            if case .failed = state { self.endSession() }
            if case .cancelled = state { self.endSession() }
        }
        transport.start()
        makeEngine(startFrameSeq: 1)
    }

    private func endSession() {
        print("glassact-testhost: viewer left")
        scene.releaseHeld()
        engine = nil
        transport = nil
    }

    private func makeEngine(startFrameSeq: UInt32) {
        guard let transport else { return }
        let encoders = HostVideoEncoders(choice: options.av1, callbackQueue: queue)
        let engine = HostEngine(
            width: scene.width, height: scene.height, transport: transport,
            videoEncoderFactory: options.video ? { encoders.encoder(forCodec: $0) } : nil,
            videoCodecPreference: encoders.preference,
            videoAV1FromGlassAct: encoders.av1FromGlassAct,
            startFrameSeq: startFrameSeq,
            clock: { MonotonicClock.nowUS })
        engine.extraHelloCaps = (geometrySettled ? WireCaps.geometryFinal : 0) | WireCaps.virtualDisplay
            | (options.displays.isEmpty ? 0 : WireCaps.displayList)
        engine.onDisplaySelect = { [weak self] id, place, x, y in
            self?.selectDisplay(id, pointer: place ? (Double(x), Double(y)) : nil)
        }
        engine.onInput = { [weak self] kind, x, y, a, b in self?.scene.apply(kind: kind, x: x, y: y, a: a, b: b) }
        engine.onTextInput = { [weak self] text in self?.scene.text(text) }
        engine.onClipboard = { [weak self] format, data in
            guard format == 1, let text = String(bytes: data, encoding: .utf8) else { return }
            self?.scene.clipboard(text)
        }
        engine.onViewerInfo = { name in print("glassact-testhost: viewer is \"\(name)\"") }
        engine.onViewerBye = { reason in print("glassact-testhost: viewer said goodbye (\(reason))") }
        engine.onVideoCodecChanged = { codec in
            print("glassact-testhost: video \(codec.map(VideoCodec.name) ?? "off")")
        }
        engine.onResizeRequested = { [weak self] mode, w, h, scale in self?.resize(mode: mode, w: w, h: h, scale: scale) }
        engine.onFailed = { reason in print("glassact-testhost: session failed — \(reason)") }
        self.engine?.onFailed = nil
        self.engine = engine
        engine.start(nowUS: MonotonicClock.nowUS)
        lastPointer = (-1, -1)
    }

    /// RESIZE: anything but Native gets a screen of the asked-for size, as a
    /// virtual display would; Native keeps this one. With `--displays`, Scale
    /// fits the shown display into the asked-for size and Native shows it as it is.
    private func resize(mode: Int, w: Int, h: Int, scale: Int) {
        print("glassact-testhost: geometry requested: mode \(mode) \(w)×\(h) @\(scale)x")
        geometryMode = mode
        if w > 0, h > 0 {
            let s = max(1, min(scale, 3))
            requestedPixels = (max(320, min(w * s, 4096)), max(240, min(h * s, 4096)))
        }
        if !options.displays.isEmpty, mode == Int(GeometryMode.native) || mode == Int(GeometryMode.scale) {
            geometrySettled = true
            let size = displayScreenSize(shownDisplay)
            if !rebuild(width: size.width, height: size.height) { engine?.reofferHelloFinal(nowUS: MonotonicClock.nowUS) }
            return
        }
        guard mode != Int(GeometryMode.native), let size = requestedPixels else {
            engine?.reofferHelloFinal(nowUS: MonotonicClock.nowUS)
            return
        }
        geometrySettled = true
        if !rebuild(width: size.width, height: size.height) { engine?.reofferHelloFinal(nowUS: MonotonicClock.nowUS) }
    }

    /// A screen of this size, in session (re-HELLO, no reconnect). False if it's the size already.
    private func rebuild(width: Int, height: Int) -> Bool {
        guard width != scene.width || height != scene.height else { return false }
        scene.resize(width: width, height: height)
        let seed = engine?.currentFrameSeq ?? 1
        if let old = engine { old.onFailed = nil }
        let previous = engine
        makeEngine(startFrameSeq: seed)
        if let previous { engine?.continueSession(from: previous) }
        return true
    }

    // MARK: - Display choice (`--displays`, §4.10)

    private static let firstDisplayID: UInt32 = 0x4A10 // not 1, 2…: IDs aren't indices
    private static let tints: [(CGFloat, CGFloat, CGFloat)] = [
        (0.12, 0.16, 0.20), (0.20, 0.13, 0.22), (0.10, 0.20, 0.15), (0.22, 0.16, 0.10),
    ]

    private func displayID(_ index: Int) -> UInt32 { Self.firstDisplayID + UInt32(index) }

    /// Display `index` in global points: side by side, left to right, tops aligned.
    private func displayRect(_ index: Int) -> DisplayChoice.Rect {
        let x = options.displays[..<index].reduce(0) { $0 + $1.width }
        let d = options.displays[index]
        return DisplayChoice.Rect(x: Double(x), y: 0, width: Double(d.width), height: Double(d.height))
    }

    /// The screen to draw for display `index`: Scale fits it into the viewer's size
    /// (never larger), anything else shows it at its own.
    private func displayScreenSize(_ index: Int) -> (width: Int, height: Int) {
        let d = options.displays[index]
        guard geometryMode == Int(GeometryMode.scale), let r = requestedPixels else { return d }
        let f = min(1, min(Double(r.width) / Double(d.width), Double(r.height) / Double(d.height)))
        return (max(320, Int(Double(d.width) * f) & ~1), max(240, Int(Double(d.height) * f) & ~1))
    }

    private func showDisplay(_ index: Int) {
        shownDisplay = index
        scene.displayLabel = "Display \(index + 1) of \(options.displays.count)"
        let t = Self.tints[index % Self.tints.count]
        scene.tint = (t.0, t.1, t.2)
    }

    private func displayList() -> [WireDisplay] {
        options.displays.indices.map { i in
            let r = displayRect(i)
            return WireDisplay(displayID: displayID(i), name: i == 0 ? "Test Display" : "Test Display \(i + 1)",
                               x: Int32(r.x), y: Int32(r.y), width: UInt16(r.width), height: UInt16(r.height),
                               isMain: i == 0, isShown: i == shownDisplay)
        }
    }

    private func answer(_ requested: UInt32, _ status: WireDisplaySelection.Status,
                        pointer: (x: Double, y: Double)? = nil) -> WireDisplaySelection {
        let r = displayRect(shownDisplay)
        return WireDisplaySelection(requestedID: requested, status: status, displayID: displayID(shownDisplay),
                                    x: Int32(r.x), y: Int32(r.y), width: UInt16(r.width), height: UInt16(r.height),
                                    pictureWidth: UInt16(scene.width), pictureHeight: UInt16(scene.height),
                                    pointerPlaced: pointer != nil,
                                    pointerX: Int32(pointer?.x ?? 0), pointerY: Int32(pointer?.y ?? 0))
    }

    /// DISPLAY_SELECT, on `queue`: 0 sends the list; a pick switches in session and is
    /// answered once the rebuilt session runs (`tick`), or refused at once.
    private func selectDisplay(_ id: UInt32, pointer asked: (x: Double, y: Double)?) {
        guard !options.displays.isEmpty else { return }
        if id == 0 {
            viewerWantsDisplayList = true
            engine?.sendDisplayList(displayList())
            print("glassact-testhost: sent the display list (\(options.displays.count) displays)")
            return
        }
        func refuse(_ status: WireDisplaySelection.Status, _ why: String) {
            print("glassact-testhost: display pick \(id) refused: \(why)")
            engine?.sendDisplaySelected(answer(id, status))
        }
        if pendingDisplayAnswer != nil { return refuse(.notNow, "another switch is under way") }
        if geometryMode == Int(GeometryMode.virtualDisplay) || geometryMode == Int(GeometryMode.clientResolution) {
            return refuse(.notNow, geometryMode == Int(GeometryMode.virtualDisplay)
                ? "a virtual display mirrors every display into one" : "Client Resolution has switched the display's mode")
        }
        guard let index = options.displays.indices.first(where: { displayID($0) == id }) else {
            return refuse(.notOffered, "no display \(id)")
        }
        let placed = DisplayChoice.pointerPlacement(asked: asked, on: displayRect(index))
        let origin = displayRect(index)
        let local = (x: Int(placed.x - origin.x), y: Int(placed.y - origin.y))
        if index == shownDisplay { // already shown: only the pointer moves
            if asked != nil { scene.placePointer(x: local.x * scene.width / Int(origin.width),
                                                 y: local.y * scene.height / Int(origin.height)) }
            engine?.sendDisplaySelected(answer(id, .ok, pointer: asked != nil ? placed : nil))
            return
        }
        showDisplay(index)
        let size = displayScreenSize(index)
        if !rebuild(width: size.width, height: size.height) { scene.resize(width: size.width, height: size.height) }
        scene.placePointer(x: local.x * scene.width / Int(origin.width), y: local.y * scene.height / Int(origin.height))
        pendingDisplayAnswer = answer(id, .ok, pointer: placed)
        print("glassact-testhost: switching to display \(index + 1) (\(size.width)×\(size.height))")
    }

    private func tick() {
        guard let engine else { return }
        let now = MonotonicClock.nowUS
        if engine.state == .running, let answer = pendingDisplayAnswer {
            // A pick's answer, then the list, once the rebuilt session runs (sent earlier, the
            // new engine would drop them), as the Host does.
            pendingDisplayAnswer = nil
            engine.sendDisplaySelected(answer)
            if viewerWantsDisplayList { engine.sendDisplayList(displayList()) }
        }
        if engine.state == .running {
            scene.render(nowUS: now)
            scene.pixels.withUnsafeBytes { raw in
                engine.encodeTick(frame: raw, bytesPerRow: scene.width * 4, dirtyRects: nil,
                                  captureTimestampUS: now, nowUS: now)
            }
            if engine.cursorNegotiated, lastPointer.x != scene.pointer.x || lastPointer.y != scene.pointer.y {
                if lastPointer.x < 0 {
                    engine.publishCursorImage(width: 32, height: 32, hotspotX: 1, hotspotY: 1, scale: 1,
                                              bgra: Scene.arrow())
                }
                lastPointer = scene.pointer
                engine.publishCursor(x: scene.pointer.x, y: scene.pointer.y, visible: true)
            }
        }
        engine.tick(nowUS: now)
    }
}

/// The one account `--sign-in-password` admits: `test`.
struct FixedAccount: PasswordVerifier {
    let password: String
    func verify(user: String, password: String) -> Bool {
        user.trimmingCharacters(in: .whitespaces) == "test" && password == self.password
    }
}

setvbuf(stdout, nil, _IOLBF, 0) // a line at a time, even into a pipe or a file
let options = Options.parse(CommandLine.arguments)
if options.video {
    HostVideoEncoders.prepare(options.av1) { ready in
        print("glassact-testhost: AV1 " + (ready ? "(Glass Act's encoder) ready" : "unavailable: Glass Act's encoder didn't start"))
    }
}
let host = TestHost(options: options)
do {
    try host.start()
} catch {
    print("glassact-testhost: \(error)")
    exit(1)
}
dispatchMain()
