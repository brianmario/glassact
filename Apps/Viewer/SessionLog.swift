import AppKit
import CryptoKit
import GlassActCore
import GlassActTransport

/// One plain-text log per Viewer launch in ~/Library/Logs/Glass Act, written off
/// the main thread: a header (build, machine, displays, flags), timestamped
/// events, a `key=value` stats line every 5 s, and an end-of-session summary.
/// It's the file to share after a real-network test ("Show Logs" in the
/// connect window).
final class SessionLog: @unchecked Sendable {
    static let shared = SessionLog()

    let url: URL
    private let queue = DispatchQueue(label: "glassact.viewer.sessionlog", qos: .utility)
    private let handle: FileHandle?
    private let startUptimeUS = SurfacePresenter.uptimeUS()

    static var directory: URL { AppPaths.logsDirectory }

    private init() {
        let dir = Self.directory
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let stamp = DateFormatter()
        stamp.dateFormat = "yyyyMMdd-HHmmss"
        stamp.locale = Locale(identifier: "en_US_POSIX")
        url = dir.appendingPathComponent("viewer-\(stamp.string(from: Date())).log")
        FileManager.default.createFile(atPath: url.path, contents: nil)
        handle = try? FileHandle(forWritingTo: url)
    }

    /// `t=<s since launch> <kind> <fields>` — fields are `key=value`, or a
    /// quoted `text="…"` for free-form messages.
    func write(_ kind: String, _ fields: String = "") {
        let t = Double(SurfacePresenter.uptimeUS() - startUptimeUS) / 1_000_000
        let wall = ISO8601DateFormatter().string(from: Date())
        let line = String(format: "t=%.3f", t) + " wall=\(wall) \(kind)" + (fields.isEmpty ? "" : " \(fields)") + "\n"
        queue.async { [handle] in
            try? handle?.write(contentsOf: Data(line.utf8))
        }
    }

    /// Blocks until every queued line is on disk (app termination).
    func flush() {
        queue.sync { try? handle?.synchronize() }
    }

    func text(_ kind: String, _ message: String) {
        write(kind, "text=\"\(message.replacingOccurrences(of: "\"", with: "'"))\"")
    }

    /// Main thread, at launch.
    @MainActor func writeHeader(arguments: [String]) {
        var fields: [String] = []
        if let exe = Bundle.main.executableURL {
            let attrs = try? FileManager.default.attributesOfItem(atPath: exe.path)
            if let date = attrs?[.modificationDate] as? Date {
                fields.append("build_time=\(ISO8601DateFormatter().string(from: date))")
            }
            if let data = try? Data(contentsOf: exe, options: .mappedIfSafe) {
                fields.append("build_sha256=\(SHA256.hash(data: data).prefix(6).map { String(format: "%02x", $0) }.joined())")
            }
        }
        fields.append("model=\(Self.sysctl("hw.model"))")
        fields.append("os=\"\(ProcessInfo.processInfo.operatingSystemVersionString)\"")
        fields.append("cores=\(ProcessInfo.processInfo.activeProcessorCount)")
        fields.append("mem_gb=\(ProcessInfo.processInfo.physicalMemory >> 30)")
        let screens = NSScreen.screens.map { s in
            "\(Int(s.frame.width))x\(Int(s.frame.height))@\(Int(s.backingScaleFactor))x"
        }
        fields.append("displays=\(screens.joined(separator: ","))")
        fields.append("args=\"\(arguments.dropFirst().joined(separator: " "))\"")
        write("launch", fields.joined(separator: " "))
    }

    private static func sysctl(_ name: String) -> String {
        var size = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return "unknown" }
        var buf = [CChar](repeating: 0, count: size)
        guard sysctlbyname(name, &buf, &size, nil, 0) == 0 else { return "unknown" }
        return String(decoding: buf.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }
}
