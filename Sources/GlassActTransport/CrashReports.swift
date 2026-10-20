import CryptoKit
public import Foundation

// Crash and hang reports (DESIGN §13, "Crash reports"). Both apps subscribe
// to MetricKit; macOS hands them a diagnostic payload (JSON) on the launch
// after a crash or hang. Everything here is the part `swift test` can reach:
// reading that JSON, keeping the newest 20 on disk, remembering which ones
// the person has already been told about, and building the GitHub issue
// they may choose to open. Nothing here touches the network: a report
// leaves the Mac only when its owner opens the issue and attaches the file.

/// What one MetricKit diagnostic is about. Raw values appear in report file
/// names, so keep them stable.
public enum DiagnosticKind: String, Sendable, CaseIterable {
    case crash
    case hang
    case cpuException = "cpu"
    case diskWriteException = "diskwrite"
    case other = "diagnostic"

    /// Payload keys, in the order a report's headline diagnostic is chosen.
    static let payloadKeys: [(String, DiagnosticKind)] = [
        ("crashDiagnostics", .crash),
        ("hangDiagnostics", .hang),
        ("cpuExceptionDiagnostics", .cpuException),
        ("diskWriteExceptionDiagnostics", .diskWriteException),
        ("appLaunchDiagnostics", .other),
    ]
}

/// One frame of a MetricKit call stack. MetricKit stacks are unsymbolicated:
/// a binary, its UUID, and an offset into its __TEXT segment
/// (`scripts/symbolicate-crash` turns them into function names).
public struct CrashFrame: Sendable, Equatable {
    public var binaryName: String
    public var binaryUUID: String
    public var offset: UInt64

    public init(binaryName: String, binaryUUID: String, offset: UInt64) {
        self.binaryName = binaryName
        self.binaryUUID = binaryUUID
        self.offset = offset
    }

    /// "Glass Act Host + 0x1f2e4".
    public var display: String { "\(binaryName) + 0x\(String(offset, radix: 16))" }
}

/// One diagnostic out of a payload, reduced to what a person (or an issue)
/// needs. Only fields MetricKit put in the payload; nothing is added.
public struct CrashDiagnostic: Sendable, Equatable {
    public var kind: DiagnosticKind
    public var appVersion: String?
    public var appBuild: String?
    public var osVersion: String?
    public var architecture: String?
    /// Mach exception type (EXC_*), its first code, and the signal.
    public var exceptionType: Int?
    public var exceptionCode: Int?
    public var signal: Int?
    /// The system's one-line termination reason, if it gave one.
    public var terminationReason: String?
    /// An uncaught Objective-C exception's name (not its message, which can
    /// carry anything the app had in hand).
    public var objcExceptionName: String?
    /// As MetricKit wrote it, e.g. "5 sec".
    public var hangDuration: String?
    /// The crashing (or hung) thread, innermost frame first.
    public var frames: [CrashFrame]

    public init(kind: DiagnosticKind, appVersion: String? = nil, appBuild: String? = nil, osVersion: String? = nil,
                architecture: String? = nil, exceptionType: Int? = nil, exceptionCode: Int? = nil,
                signal: Int? = nil, terminationReason: String? = nil, objcExceptionName: String? = nil,
                hangDuration: String? = nil, frames: [CrashFrame] = []) {
        self.kind = kind
        self.appVersion = appVersion
        self.appBuild = appBuild
        self.osVersion = osVersion
        self.architecture = architecture
        self.exceptionType = exceptionType
        self.exceptionCode = exceptionCode
        self.signal = signal
        self.terminationReason = terminationReason
        self.objcExceptionName = objcExceptionName
        self.hangDuration = hangDuration
        self.frames = frames
    }

    /// "1.0 (202610131845)", or nil when the payload didn't say.
    public var versionString: String? {
        switch (appVersion, appBuild) {
        case let (v?, b?): "\(v) (\(b))"
        case let (v?, nil): v
        case let (nil, b?): "build \(b)"
        case (nil, nil): nil
        }
    }

    /// "EXC_BAD_ACCESS (code 1), SIGSEGV" for a crash, "unresponsive for
    /// 5 sec" for a hang.
    public var whatHappened: String {
        switch kind {
        case .crash:
            var parts: [String] = []
            if let objcExceptionName { parts.append("uncaught \(objcExceptionName)") }
            if let exceptionType {
                let name = Self.exceptionNames[exceptionType] ?? "exception type \(exceptionType)"
                parts.append(exceptionCode.map { "\(name) (code \($0))" } ?? name)
            }
            if let signal { parts.append(Self.signalNames[signal] ?? "signal \(signal)") }
            return parts.isEmpty ? "crash" : parts.joined(separator: ", ")
        case .hang:
            return hangDuration.map { "unresponsive for \($0)" } ?? "unresponsive"
        case .cpuException: return "CPU use over the system's limit"
        case .diskWriteException: return "disk writes over the system's limit"
        case .other: return "diagnostic"
        }
    }

    /// <mach/exception_types.h>.
    static let exceptionNames: [Int: String] = [
        1: "EXC_BAD_ACCESS", 2: "EXC_BAD_INSTRUCTION", 3: "EXC_ARITHMETIC", 4: "EXC_EMULATION",
        5: "EXC_SOFTWARE", 6: "EXC_BREAKPOINT", 7: "EXC_SYSCALL", 8: "EXC_MACH_SYSCALL", 9: "EXC_RPC_ALERT",
        10: "EXC_CRASH", 11: "EXC_RESOURCE", 12: "EXC_GUARD", 13: "EXC_CORPSE_NOTIFY",
    ]
    /// <sys/signal.h>.
    static let signalNames: [Int: String] = [
        1: "SIGHUP", 2: "SIGINT", 3: "SIGQUIT", 4: "SIGILL", 5: "SIGTRAP", 6: "SIGABRT", 7: "SIGEMT",
        8: "SIGFPE", 9: "SIGKILL", 10: "SIGBUS", 11: "SIGSEGV", 12: "SIGSYS", 13: "SIGPIPE", 14: "SIGALRM",
        15: "SIGTERM",
    ]
}

/// A MetricKit diagnostic payload (`MXDiagnosticPayload.jsonRepresentation()`),
/// read.
public struct CrashReportSummary: Sendable, Equatable {
    public var diagnostics: [CrashDiagnostic]

    public init(diagnostics: [CrashDiagnostic]) { self.diagnostics = diagnostics }

    /// The one to lead with: the first crash, else the first hang, else
    /// whatever came first.
    public var primary: CrashDiagnostic? {
        diagnostics.first { $0.kind == .crash } ?? diagnostics.first { $0.kind == .hang } ?? diagnostics.first
    }

    public var kind: DiagnosticKind { primary?.kind ?? .other }

    /// Parses Apple's documented shape: top-level `crashDiagnostics`,
    /// `hangDiagnostics`, … arrays; each entry has `diagnosticMetaData` and a
    /// `callStackTree` whose `callStacks[]` (one per thread for crashes) hold
    /// `callStackRootFrames[]` with `binaryName`, `binaryUUID`,
    /// `offsetIntoBinaryTextSegment` and nested `subFrames`. nil if `json`
    /// isn't a JSON object; unknown or missing fields are just absent.
    public static func parse(_ json: Data) -> CrashReportSummary? {
        guard let root = (try? JSONSerialization.jsonObject(with: json)) as? [String: Any] else { return nil }
        var diagnostics: [CrashDiagnostic] = []
        for (key, kind) in DiagnosticKind.payloadKeys {
            for entry in root[key] as? [[String: Any]] ?? [] {
                diagnostics.append(diagnostic(entry, kind: kind))
            }
        }
        return CrashReportSummary(diagnostics: diagnostics)
    }

    private static func diagnostic(_ entry: [String: Any], kind: DiagnosticKind) -> CrashDiagnostic {
        let meta = entry["diagnosticMetaData"] as? [String: Any] ?? [:]
        let reason = meta["exceptionReason"] as? [String: Any]
        // Hang duration sits in the metadata; tolerate it beside it too.
        let hang = meta["hangDuration"] ?? entry["hangDuration"]
        return CrashDiagnostic(
            kind: kind,
            appVersion: string(meta["appVersion"]),
            appBuild: string(meta["appBuildVersion"]),
            osVersion: string(meta["osVersion"]),
            architecture: string(meta["platformArchitecture"]),
            exceptionType: int(meta["exceptionType"]),
            exceptionCode: int(meta["exceptionCode"]),
            signal: int(meta["signal"]),
            terminationReason: string(meta["terminationReason"]).map { clip($0, 200) },
            objcExceptionName: string(reason?["exceptionName"]) ?? string(reason?["className"]),
            hangDuration: hang.flatMap { value in
                if let s = value as? String { return s }
                return double(value).map { $0 == $0.rounded() ? "\(Int($0)) sec" : String(format: "%.2f sec", $0) }
            },
            frames: frames(entry["callStackTree"] as? [String: Any]))
    }

    /// The attributed thread's stack (the crashing or hung one; else the
    /// first), innermost frame first: each frame's caller is its first
    /// sub-frame — the most-sampled one where a hang's tree branches.
    static func frames(_ tree: [String: Any]?, limit: Int = 64) -> [CrashFrame] {
        let stacks = tree?["callStacks"] as? [[String: Any]] ?? []
        guard let stack = stacks.first(where: { ($0["threadAttributed"] as? Bool) == true }) ?? stacks.first
        else { return [] }
        var out: [CrashFrame] = []
        var level = stack["callStackRootFrames"] as? [[String: Any]] ?? []
        while out.count < limit, let frame = heaviest(level) {
            out.append(CrashFrame(binaryName: string(frame["binaryName"]) ?? "???",
                                  binaryUUID: string(frame["binaryUUID"]) ?? "",
                                  offset: UInt64(clamping: int(frame["offsetIntoBinaryTextSegment"]) ?? 0)))
            level = frame["subFrames"] as? [[String: Any]] ?? []
        }
        return out
    }

    private static func heaviest(_ frames: [[String: Any]]) -> [String: Any]? {
        frames.max { (int($0["sampleCount"]) ?? 0) < (int($1["sampleCount"]) ?? 0) }
    }

    private static func string(_ v: Any?) -> String? {
        switch v {
        case let s as String: s.isEmpty ? nil : s
        case let n as NSNumber: n.stringValue
        default: nil
        }
    }

    private static func int(_ v: Any?) -> Int? {
        switch v {
        case let n as NSNumber: n.intValue
        case let s as String: Int(s) ?? (s.hasPrefix("0x") ? Int(s.dropFirst(2), radix: 16) : nil)
        default: nil
        }
    }

    private static func double(_ v: Any?) -> Double? {
        (v as? NSNumber)?.doubleValue
    }

    static func clip(_ s: String, _ max: Int) -> String {
        s.count <= max ? s : String(s.prefix(max - 1)) + "…"
    }

    /// One line for the app's log: "crash EXC_BAD_ACCESS (code 1), SIGSEGV ·
    /// app 1.0 (7) · macOS 15.5 (24F74) · at Glass Act Host + 0x1f2e4".
    public var logLine: String {
        guard let d = primary else { return "empty diagnostic payload" }
        var parts = ["\(d.kind.rawValue) \(d.whatHappened)"]
        if let v = d.versionString { parts.append("app \(v)") }
        if let os = d.osVersion { parts.append(os) }
        if let top = d.frames.first { parts.append("at \(top.display)") }
        if diagnostics.count > 1 { parts.append("+\(diagnostics.count - 1) more diagnostic(s)") }
        return parts.joined(separator: " · ")
    }
}

// MARK: - The GitHub issue

/// The prefilled "new issue" link behind Report…. Opening it only fills in
/// a form in the person's browser; they read it, attach the report file and
/// submit it themselves — or don't.
public enum CrashIssue {
    public static let newIssueURL = "https://github.com/brianmario/glassact/issues/new"
    /// GitHub turns very long prefilled links away (414). Stay well under
    /// its ~8 KB limit, browsers' too.
    public static let defaultMaxURLLength = 6000
    /// Frames to try first; fewer if the link would run long.
    public static let maxFrames = 30

    /// `reportPath` is shown, not opened: the person attaches the file.
    public static func url(appName: String, summary: CrashReportSummary, reportPath: String,
                           maxLength: Int = defaultMaxURLLength) -> URL {
        let title = self.title(appName: appName, summary: summary)
        let frameCount = summary.primary?.frames.count ?? 0
        var shown = min(frameCount, maxFrames)
        var body = self.body(appName: appName, summary: summary, reportPath: reportPath, frames: shown)
        var link = compose(title: title, body: body)
        while link.utf8.count > maxLength && shown > 0 {
            shown = shown > 10 ? shown - 5 : shown - 1
            body = self.body(appName: appName, summary: summary, reportPath: reportPath, frames: shown)
            link = compose(title: title, body: body)
        }
        // Still too long (a huge path or termination reason): cut the body.
        while link.utf8.count > maxLength && !body.isEmpty {
            body = String(body.prefix(body.count * 9 / 10)) + "…"
            if body.count <= 1 { body = "" }
            link = compose(title: title, body: body)
        }
        return URL(string: link) ?? URL(string: newIssueURL)!
    }

    /// "Glass Act Host 1.0 (7) crashed: EXC_BAD_ACCESS (code 1), SIGSEGV".
    public static func title(appName: String, summary: CrashReportSummary) -> String {
        guard let d = summary.primary else { return "\(appName) diagnostic report" }
        let who = [appName, d.versionString].compactMap { $0 }.joined(separator: " ")
        let what: String = switch d.kind {
        case .crash: "crashed: \(d.whatHappened)"
        case .hang: "was \(d.whatHappened)"
        default: "reported \(d.whatHappened)"
        }
        return CrashReportSummary.clip("\(who) \(what)", 120)
    }

    public static func body(appName: String, summary: CrashReportSummary, reportPath: String,
                            frames: Int = maxFrames) -> String {
        guard let d = summary.primary else {
            return "\(appName) saved a diagnostic report.\n\n**Please attach the report file:** `\(reportPath)`\n"
        }
        var lines: [String] = []
        lines.append("\(appName) saved this \(d.kind == .hang ? "hang" : d.kind == .crash ? "crash" : "diagnostic") "
                     + "report (MetricKit). Everything below comes from that report.")
        lines.append("")
        lines.append("- **App:** \(appName) \(d.versionString ?? "(version not in the report)")")
        if let os = d.osVersion {
            lines.append("- **macOS:** \(os)" + (d.architecture.map { ", \($0)" } ?? ""))
        }
        lines.append("- **What happened:** \(d.whatHappened)")
        if let reason = d.terminationReason { lines.append("- **Termination reason:** \(reason)") }
        if summary.diagnostics.count > 1 {
            lines.append("- **Also in the report:** \(summary.diagnostics.count - 1) more diagnostic(s)")
        }
        lines.append("")
        if !d.frames.isEmpty {
            let thread = d.kind == .hang ? "the thread that hung" : "the crashing thread"
            lines.append("**Top frames of \(thread)** (binary + offset; "
                         + "`scripts/symbolicate-crash` resolves them with the release's dSYMs):")
            lines.append("")
            lines.append("```")
            for (i, frame) in d.frames.prefix(frames).enumerated() {
                lines.append("\(i)  \(frame.display)")
            }
            if frames < d.frames.count { lines.append("…  \(d.frames.count - frames) more in the report file") }
            lines.append("```")
            lines.append("")
        }
        lines.append("**Please attach the report file:** `\(reportPath)`")
        lines.append("")
        lines.append("1. Reveal Report in Finder: Report… showed it there "
                     + "(or use Show Crash Reports in Finder in \(appName)’s menu).")
        lines.append("2. Drag the file into this issue.")
        lines.append("")
        lines.append("**What were you doing when it happened?** (optional)")
        lines.append("")
        return lines.joined(separator: "\n")
    }

    static func compose(title: String, body: String) -> String {
        "\(newIssueURL)?labels=bug&title=\(percentEncode(title))&body=\(percentEncode(body))"
    }

    /// RFC 3986 unreserved characters stay; everything else — `&`, `=`,
    /// `+`, `#`, spaces, newlines, non-ASCII — is percent-encoded as UTF-8.
    static func percentEncode(_ s: String) -> String {
        s.addingPercentEncoding(withAllowedCharacters: unreserved) ?? ""
    }

    private static let unreserved = CharacterSet(
        charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
}

// MARK: - On disk

/// What the app shows after a crash or hang: one notice for the newest
/// report not yet answered (Report… or Dismiss answers all of them).
public struct CrashNotice: Sendable, Equatable {
    /// The newest unanswered crash or hang report.
    public let report: URL
    public let summary: CrashReportSummary
    /// "Glass Act Host quit unexpectedly last time".
    public let title: String
    /// What happened, in which version, and that the report stays here.
    public let detail: String
    public let issueURL: URL
    /// Every unanswered crash and hang report, newest first.
    public let unanswered: [URL]
}

/// The CrashReports folder: MetricKit payloads as JSON, named
/// `<prefix>-<kind>-<yyyyMMdd-HHmmss UTC>-<hash>.json`, at most `keep`
/// of them (the newest), plus `.seen`: the hashes of reports the person has
/// already answered. All state is on disk, so the store is a value.
public struct CrashReportStore: Sendable {
    public let directory: URL
    /// "host" or "viewer": no dashes.
    public let prefix: String
    public let keep: Int

    public static let defaultKeep = 20
    static let seenFile = ".seen"
    static let seenLimit = 200

    public init(directory: URL, prefix: String, keep: Int = defaultKeep) {
        precondition(!prefix.contains("-") && !prefix.isEmpty, "prefix must be a bare word")
        self.directory = directory
        self.prefix = prefix
        self.keep = keep
    }

    /// `<logs>/CrashReports`: ~/Library/Logs/Glass Act/CrashReports for the
    /// Host, the same path inside the sandboxed Viewer's container.
    public static func forApp(prefix: String) -> CrashReportStore {
        CrashReportStore(directory: AppPaths.logsDirectory.appendingPathComponent("CrashReports", isDirectory: true),
                         prefix: prefix)
    }

    public struct Saved: Sendable, Equatable {
        public let url: URL
        public let summary: CrashReportSummary
    }

    /// Writes one payload, then trims the folder to the newest `keep`.
    /// nil if it was already saved (MetricKit can hand the same payload over
    /// again) or already answered, or the write failed.
    public func save(_ json: Data, timestamp: Date) -> Saved? {
        let hash = Self.hash(json)
        if reports().contains(where: { Self.parseName($0.lastPathComponent)?.hash == hash })
            || seenHashes().contains(hash) {
            return nil
        }
        let summary = CrashReportSummary.parse(json) ?? CrashReportSummary(diagnostics: [])
        let name = "\(prefix)-\(summary.kind.rawValue)-\(Self.stamp(timestamp))-\(hash).json"
        let url = directory.appendingPathComponent(name)
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: 0o700])
            try json.write(to: url, options: .atomic)
        } catch {
            return nil
        }
        prune()
        // Pruned straight away: older than everything kept.
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return Saved(url: url, summary: summary)
    }

    /// This app's reports, newest first.
    public func reports() -> [URL] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        return names.compactMap { name -> (String, URL)? in
            guard let parsed = Self.parseName(name), parsed.prefix == prefix else { return nil }
            return (parsed.sortKey, directory.appendingPathComponent(name))
        }
        .sorted { $0.0 > $1.0 }
        .map(\.1)
    }

    /// Deletes all but the newest `keep` (other files are left alone).
    public func prune() {
        for url in reports().dropFirst(keep) {
            try? FileManager.default.removeItem(at: url)
        }
    }

    /// Crash and hang reports the person hasn't answered, newest first.
    public func unanswered() -> [URL] {
        let seen = seenHashes()
        return reports().filter { url in
            guard let parsed = Self.parseName(url.lastPathComponent) else { return false }
            return (parsed.kind == .crash || parsed.kind == .hang) && !seen.contains(parsed.hash)
        }
    }

    /// Report… or Dismiss: these won't be brought up again.
    public func markAnswered(_ urls: [URL]) {
        var seen = seenList()
        for url in urls {
            guard let hash = Self.parseName(url.lastPathComponent)?.hash, !seen.contains(hash) else { continue }
            seen.append(hash)
        }
        let kept = seen.suffix(Self.seenLimit)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                 attributes: [.posixPermissions: 0o700])
        try? Data((kept.joined(separator: "\n") + "\n").utf8)
            .write(to: directory.appendingPathComponent(Self.seenFile), options: .atomic)
    }

    /// The notice to show, if any report is waiting for an answer.
    public func notice(appName: String, maxURLLength: Int = CrashIssue.defaultMaxURLLength) -> CrashNotice? {
        let waiting = unanswered()
        guard let newest = waiting.first, let json = try? Data(contentsOf: newest) else { return nil }
        let summary = CrashReportSummary.parse(json) ?? CrashReportSummary(diagnostics: [])
        let d = summary.primary
        let title = d?.kind == .hang ? "\(appName) was unresponsive last time"
                                     : "\(appName) quit unexpectedly last time"
        // "Version 1.0 (7) crashed: EXC_BAD_ACCESS (code 1), SIGSEGV."
        let who = d?.versionString.map { "Version \($0)" } ?? "It"
        var detail = switch d?.kind {
        case .hang?: "\(who) was \(d?.whatHappened ?? "unresponsive")."
        case .crash?: "\(who) crashed: \(d?.whatHappened ?? "crash")."
        default: "It saved a diagnostic report."
        }
        detail += " The report stays on this Mac unless you choose to send it."
        if waiting.count > 1 {
            detail += " \(waiting.count - 1) earlier report\(waiting.count == 2 ? " is" : "s are") in the same folder."
        }
        let issue = CrashIssue.url(appName: appName, summary: summary, reportPath: Self.displayPath(newest),
                                   maxLength: maxURLLength)
        return CrashNotice(report: newest, summary: summary, title: title, detail: detail, issueURL: issue,
                           unanswered: waiting)
    }

    // MARK: Names, hashes, paths

    struct Name: Equatable {
        var prefix: String
        var kind: DiagnosticKind
        var hash: String
        /// "yyyyMMdd-HHmmss-hash": sorts by time across kinds.
        var sortKey: String
    }

    /// nil for anything that isn't a report this store wrote.
    static func parseName(_ name: String) -> Name? {
        guard name.hasSuffix(".json"), !name.hasPrefix(".") else { return nil }
        let parts = name.dropLast(5).split(separator: "-", omittingEmptySubsequences: false).map(String.init)
        guard parts.count == 5, let kind = DiagnosticKind(rawValue: parts[1]),
              parts[2].count == 8, parts[3].count == 6, parts[4].count == 8,
              (parts[2] + parts[3]).allSatisfy(\.isASCII), (parts[2] + parts[3]).allSatisfy(\.isNumber),
              parts[4].allSatisfy(\.isHexDigit) else { return nil }
        return Name(prefix: parts[0], kind: kind, hash: parts[4], sortKey: "\(parts[2])-\(parts[3])-\(parts[4])")
    }

    static func hash(_ data: Data) -> String {
        SHA256.hash(data: data).prefix(4).map { String(format: "%02x", $0) }.joined()
    }

    static func stamp(_ date: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyyMMdd-HHmmss"
        return f.string(from: date)
    }

    private func seenList() -> [String] {
        guard let text = try? String(contentsOf: directory.appendingPathComponent(Self.seenFile), encoding: .utf8)
        else { return [] }
        return text.split(whereSeparator: \.isNewline).map(String.init)
    }

    private func seenHashes() -> Set<String> { Set(seenList()) }

    /// The path with the real home folder as `~` — the user name stays out
    /// of an issue. (A sandboxed app's home is its container, so this asks
    /// the user database for the real one.)
    public static func displayPath(_ url: URL, home: String = realHome) -> String {
        let path = url.path
        let base = home.hasSuffix("/") ? String(home.dropLast()) : home
        guard !base.isEmpty, path == base || path.hasPrefix(base + "/") else { return path }
        return "~" + path.dropFirst(base.count)
    }

    public static var realHome: String {
        if let pw = getpwuid(getuid()), let dir = pw.pointee.pw_dir { return String(cString: dir) }
        return NSHomeDirectory()
    }
}
