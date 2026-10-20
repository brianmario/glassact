import Foundation
import Testing
@testable import GlassActTransport

/// Crash and hang reports (§13): reading MetricKit's diagnostic JSON, the
/// GitHub issue link built from it, and the CrashReports folder (keep the
/// newest 20, remember which ones were answered).
@Suite struct CrashReportTests {
    // MARK: - Fixtures, in Apple's documented MXDiagnosticPayload JSON shape

    static let appUUID = "5D7F3A1C-8E2B-3C4D-9A6F-0B1C2D3E4F50"
    static let kernelUUID = "70B89F27-1634-3580-A695-57CDB41D7743"

    /// A per-thread crash stack: one root frame, each caller its only
    /// sub-frame, innermost first.
    static func chain(_ frames: [(String, String, Int)]) -> [[String: Any]] {
        var node: [String: Any]?
        for (i, (name, uuid, offset)) in frames.enumerated().reversed() {
            var frame: [String: Any] = [
                "binaryName": name, "binaryUUID": uuid, "offsetIntoBinaryTextSegment": offset,
                "sampleCount": 1, "address": 0x1_0000_0000 + offset + i,
            ]
            if let node { frame["subFrames"] = [node] }
            node = frame
        }
        return node.map { [$0] } ?? []
    }

    static func crashPayload(frames: Int = 6, objcException: Bool = false) -> Data {
        var stack: [(String, String, Int)] = [
            ("libsystem_kernel.dylib", kernelUUID, 0x9A5C),
            ("libsystem_pthread.dylib", "8D5E4B2A-1111-3222-8333-944455556666", 0x6F0C),
        ]
        for i in 0..<max(0, frames - 2) { stack.append(("Glass Act Host", appUUID, 0x1F2E4 + i * 0x40)) }
        var meta: [String: Any] = [
            "appBuildVersion": "202610131845",
            "appVersion": "1.0",
            "regionFormat": "US",
            "exceptionType": 1,
            "exceptionCode": 1,
            "signal": 11,
            "osVersion": "macOS 15.5 (24F74)",
            "deviceType": "Mac15,6",
            "platformArchitecture": "arm64e",
            "bundleIdentifier": "app.glassact.host",
            "terminationReason": "Namespace SIGNAL, Code 11 Segmentation fault: 11",
            "virtualMemoryRegionInfo": "0 is not in any region.",
            "pid": 4242,
            "isTestFlightApp": false,
            "lowPowerModeEnabled": false,
        ]
        if objcException {
            meta["exceptionReason"] = [
                "composedMessage": "*** -[__NSArrayM objectAtIndex:]: index 3 beyond bounds [0 .. 1]",
                "formatString": "*** -[__NSArrayM objectAtIndex:]: index %lu beyond bounds [0 .. %lu]",
                "arguments": ["3", "1"],
                "exceptionType": "NSRangeException",
                "className": "NSException",
                "exceptionName": "NSRangeException",
            ]
            meta["exceptionType"] = 10
            meta["signal"] = 6
        }
        let otherThread: [String: Any] = [
            "threadAttributed": false,
            "callStackRootFrames": chain([("libsystem_kernel.dylib", kernelUUID, 0x1234)]),
        ]
        let crashed: [String: Any] = ["threadAttributed": true, "callStackRootFrames": chain(stack)]
        return json([
            "timeStampBegin": "2026-10-19 09:59:00",
            "timeStampEnd": "2026-10-19 09:59:00",
            "crashDiagnostics": [[
                "version": "1.0.0",
                "diagnosticMetaData": meta,
                "callStackTree": ["callStackPerThread": true, "callStacks": [otherThread, crashed]],
            ]],
        ])
    }

    /// A hang: the main thread's samples as a tree that branches; the
    /// caller chain follows the most-sampled branch.
    static func hangPayload() -> Data {
        let hot: [String: Any] = [
            "binaryName": "Glass Act Viewer", "binaryUUID": appUUID, "offsetIntoBinaryTextSegment": 0x4400,
            "sampleCount": 18,
        ]
        let cold: [String: Any] = [
            "binaryName": "AppKit", "binaryUUID": "11111111-2222-3333-4444-555555555555",
            "offsetIntoBinaryTextSegment": 0x9900, "sampleCount": 2,
        ]
        let root: [String: Any] = [
            "binaryName": "libsystem_kernel.dylib", "binaryUUID": kernelUUID,
            "offsetIntoBinaryTextSegment": 0x1000, "sampleCount": 20, "subFrames": [cold, hot],
        ]
        return json([
            "timeStampBegin": "2026-10-18 00:00:00",
            "timeStampEnd": "2026-10-18 23:59:00",
            "hangDiagnostics": [[
                "version": "1.0.0",
                "diagnosticMetaData": [
                    "appBuildVersion": "202610131845", "appVersion": "1.0",
                    "osVersion": "macOS 26.1 (25B78)", "platformArchitecture": "x86_64",
                    "hangDuration": "5.5 sec",
                ],
                "callStackTree": ["callStackPerThread": false, "callStacks": [
                    ["threadAttributed": true, "callStackRootFrames": [root]],
                ]],
            ]],
        ])
    }

    static func json(_ object: [String: Any]) -> Data {
        try! JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
    }

    // MARK: - Parsing

    @Test func crashSummaryReadsMetadataAndTheCrashingThread() throws {
        let summary = try #require(CrashReportSummary.parse(Self.crashPayload()))
        #expect(summary.kind == .crash)
        let d = try #require(summary.primary)
        #expect(d.appVersion == "1.0")
        #expect(d.appBuild == "202610131845")
        #expect(d.versionString == "1.0 (202610131845)")
        #expect(d.osVersion == "macOS 15.5 (24F74)")
        #expect(d.architecture == "arm64e")
        #expect(d.exceptionType == 1 && d.exceptionCode == 1 && d.signal == 11)
        #expect(d.whatHappened == "EXC_BAD_ACCESS (code 1), SIGSEGV")
        #expect(d.terminationReason == "Namespace SIGNAL, Code 11 Segmentation fault: 11")
        // The attributed thread, not the first one; innermost frame first.
        #expect(d.frames.count == 6)
        #expect(d.frames[0] == CrashFrame(binaryName: "libsystem_kernel.dylib", binaryUUID: Self.kernelUUID,
                                          offset: 0x9A5C))
        #expect(d.frames[2].display == "Glass Act Host + 0x1f2e4")
        #expect(summary.logLine
                == "crash EXC_BAD_ACCESS (code 1), SIGSEGV · app 1.0 (202610131845) · macOS 15.5 (24F74) · "
                + "at libsystem_kernel.dylib + 0x9a5c")
    }

    @Test func objcExceptionNamesTheExceptionButNotItsMessage() throws {
        let summary = try #require(CrashReportSummary.parse(Self.crashPayload(objcException: true)))
        let d = try #require(summary.primary)
        #expect(d.objcExceptionName == "NSRangeException")
        #expect(d.whatHappened == "uncaught NSRangeException, EXC_CRASH (code 1), SIGABRT")
        let body = CrashIssue.body(appName: "Glass Act Host", summary: summary, reportPath: "~/r.json")
        #expect(!body.contains("objectAtIndex"), "the exception's message stays out of the issue")
    }

    @Test func hangSummaryFollowsTheMostSampledBranch() throws {
        let summary = try #require(CrashReportSummary.parse(Self.hangPayload()))
        #expect(summary.kind == .hang)
        let d = try #require(summary.primary)
        #expect(d.hangDuration == "5.5 sec")
        #expect(d.whatHappened == "unresponsive for 5.5 sec")
        #expect(d.frames.map(\.binaryName) == ["libsystem_kernel.dylib", "Glass Act Viewer"])
        #expect(d.frames[1].offset == 0x4400)
    }

    @Test func numericHangDurationAndMissingFieldsAreTolerated() throws {
        let data = Self.json(["hangDiagnostics": [["diagnosticMetaData": ["hangDuration": 3]]]])
        let d = try #require(CrashReportSummary.parse(data)?.primary)
        #expect(d.whatHappened == "unresponsive for 3 sec")
        #expect(d.frames.isEmpty && d.versionString == nil)
        #expect(CrashReportSummary.parse(Data("not json".utf8)) == nil)
        #expect(CrashReportSummary.parse(Data("[]".utf8)) == nil)
        #expect(CrashReportSummary.parse(Data("{}".utf8))?.kind == .other)
    }

    @Test func aCrashLeadsEvenWhenAHangCameFirstInThePayload() throws {
        var payload = try #require(try JSONSerialization.jsonObject(with: Self.hangPayload()) as? [String: Any])
        let crash = try #require(try JSONSerialization.jsonObject(with: Self.crashPayload()) as? [String: Any])
        payload["crashDiagnostics"] = crash["crashDiagnostics"]
        let summary = try #require(CrashReportSummary.parse(Self.json(payload)))
        #expect(summary.diagnostics.count == 2)
        #expect(summary.kind == .crash)
        #expect(summary.logLine.hasSuffix("+1 more diagnostic(s)"))
    }

    // MARK: - The issue link

    static func query(_ url: URL) throws -> [String: String] {
        let items = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems)
        return Dictionary(uniqueKeysWithValues: items.map { ($0.name, $0.value ?? "") })
    }

    @Test func issueLinkCarriesTheSummaryAndThePath() throws {
        let summary = try #require(CrashReportSummary.parse(Self.crashPayload()))
        let path = "~/Library/Logs/Glass Act/CrashReports/host-crash-20261019-095900-0a1b2c3d.json"
        let url = CrashIssue.url(appName: "Glass Act Host", summary: summary, reportPath: path)
        #expect(url.absoluteString.hasPrefix("https://github.com/brianmario/glassact/issues/new?"))
        let q = try Self.query(url)
        #expect(q["title"] == "Glass Act Host 1.0 (202610131845) crashed: EXC_BAD_ACCESS (code 1), SIGSEGV")
        let body = try #require(q["body"])
        #expect(body.contains("- **App:** Glass Act Host 1.0 (202610131845)"))
        #expect(body.contains("- **macOS:** macOS 15.5 (24F74), arm64e"))
        #expect(body.contains("0  libsystem_kernel.dylib + 0x9a5c"))
        #expect(body.contains("5  Glass Act Host + 0x1f3a4"))
        #expect(body.contains("Please attach the report file:** `\(path)`"))
        #expect(body.contains("Reveal Report in Finder"))
        // Nothing beyond the payload: no device model, pid or memory map.
        #expect(!body.contains("Mac15,6") && !body.contains("4242") && !body.contains("region"))
    }

    @Test func issueLinkEncodesReservedAndNonASCIICharacters() throws {
        var d = CrashDiagnostic(kind: .crash, appVersion: "1.0 β", appBuild: "7", signal: 6,
                                terminationReason: "a&b=c+d#e?f/g%h")
        d.frames = [CrashFrame(binaryName: "Lib & Co+", binaryUUID: "", offset: 0x10)]
        let summary = CrashReportSummary(diagnostics: [d])
        let url = CrashIssue.url(appName: "Glass Act Viewer", summary: summary, reportPath: "~/a b/c.json")
        let raw = url.absoluteString
        let query = String(raw[raw.index(after: try #require(raw.firstIndex(of: "?")))...])
        // Only unreserved characters and percent escapes inside the values.
        let allowed = CharacterSet(charactersIn:
            "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~%&=")
        #expect(query.unicodeScalars.allSatisfy(allowed.contains))
        #expect(query.split(separator: "&").count == 3, "labels, title, body — no stray separators")
        let q = try Self.query(url)
        #expect(q["body"]?.contains("a&b=c+d#e?f/g%h") == true, "round-trips exactly")
        #expect(q["body"]?.contains("Lib & Co+ + 0x10") == true)
        #expect(q["title"] == "Glass Act Viewer 1.0 β (7) crashed: SIGABRT")
        #expect(q["labels"] == "bug")
    }

    @Test func longStacksAreCutToFitTheLinkLimit() throws {
        let summary = try #require(CrashReportSummary.parse(Self.crashPayload(frames: 64)))
        #expect(summary.primary?.frames.count == 64)
        let path = "~/Library/Logs/Glass Act/CrashReports/host-crash-20261019-095900-0a1b2c3d.json"
        let roomy = CrashIssue.url(appName: "Glass Act Host", summary: summary, reportPath: path)
        #expect(roomy.absoluteString.utf8.count <= CrashIssue.defaultMaxURLLength)
        let roomyBody = try #require(try Self.query(roomy)["body"])
        #expect(roomyBody.contains("29  Glass Act Host"), "up to 30 frames when they fit")
        #expect(roomyBody.contains("34 more in the report file"))

        for limit in [3000, 2000, 1500] {
            let url = CrashIssue.url(appName: "Glass Act Host", summary: summary, reportPath: path, maxLength: limit)
            #expect(url.absoluteString.utf8.count <= limit, "limit \(limit)")
            let body = try #require(try Self.query(url)["body"])
            #expect(body.contains("0  libsystem_kernel.dylib + 0x9a5c"), "the top frame survives at \(limit)")
            #expect(body.contains("more in the report file"))
        }
        // Absurdly small: still a valid link, body cut, never over.
        let tiny = CrashIssue.url(appName: "Glass Act Host", summary: summary, reportPath: path, maxLength: 400)
        #expect(tiny.absoluteString.utf8.count <= 400)
        #expect(tiny.absoluteString.hasPrefix(CrashIssue.newIssueURL))
    }

    @Test func hangIssueSaysUnresponsive() throws {
        let summary = try #require(CrashReportSummary.parse(Self.hangPayload()))
        let q = try Self.query(CrashIssue.url(appName: "Glass Act Viewer", summary: summary, reportPath: "~/h.json"))
        #expect(q["title"] == "Glass Act Viewer 1.0 (202610131845) was unresponsive for 5.5 sec")
        #expect(q["body"]?.contains("Top frames of the thread that hung") == true)
    }

    // MARK: - The folder

    static func tempStore(prefix: String = "host", keep: Int = CrashReportStore.defaultKeep) -> CrashReportStore {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("glassact-crash-\(UUID().uuidString)", isDirectory: true)
        return CrashReportStore(directory: dir, prefix: prefix, keep: keep)
    }

    /// A distinct crash payload per `n` (the hash names the file).
    static func distinctCrash(_ n: Int) -> Data {
        json(["crashDiagnostics": [["diagnosticMetaData": ["signal": 11, "pid": n, "appVersion": "1.0"]]]])
    }

    @Test func saveNamesTheFileByKindTimeAndHash() throws {
        let store = Self.tempStore()
        defer { try? FileManager.default.removeItem(at: store.directory) }
        let when = Date(timeIntervalSince1970: 1_792_403_940) // 2026-10-19 09:59:00 UTC
        let saved = try #require(store.save(Self.crashPayload(), timestamp: when))
        let name = saved.url.lastPathComponent
        #expect(name.hasPrefix("host-crash-20261019-095900-") && name.hasSuffix(".json"))
        #expect(name.utf8.count <= 64, "fits a Send Logs upload name")
        #expect(try Data(contentsOf: saved.url) == Self.crashPayload(), "the payload, byte for byte")
        #expect(saved.summary.kind == .crash)
        let hang = try #require(store.save(Self.hangPayload(), timestamp: when.addingTimeInterval(60)))
        #expect(hang.url.lastPathComponent.hasPrefix("host-hang-20261019-100000-"))
        // The same payload again (MetricKit can redeliver): not a new report.
        #expect(store.save(Self.crashPayload(), timestamp: when) == nil)
        #expect(store.reports() == [hang.url, saved.url], "newest first, across kinds")
    }

    @Test func keepsOnlyTheNewestTwenty() throws {
        let store = Self.tempStore()
        defer { try? FileManager.default.removeItem(at: store.directory) }
        let base = Date(timeIntervalSince1970: 1_790_000_000)
        // Saved out of order: retention goes by the report's time, not arrival.
        for n in (0..<25).reversed() {
            _ = store.save(Self.distinctCrash(n), timestamp: base.addingTimeInterval(Double(n) * 3600))
        }
        let kept = store.reports()
        #expect(kept.count == 20)
        let stamps = kept.map { String($0.lastPathComponent.split(separator: "-")[2...3].joined(separator: "-")) }
        #expect(stamps.first == CrashReportStore.stamp(base.addingTimeInterval(24 * 3600)))
        #expect(stamps.last == CrashReportStore.stamp(base.addingTimeInterval(5 * 3600)))
        // One older than everything kept is dropped straight away.
        #expect(store.save(Self.distinctCrash(99), timestamp: base.addingTimeInterval(-3600)) == nil)
        #expect(store.reports().count == 20)
        // Files the store didn't write are never touched.
        let foreign = store.directory.appendingPathComponent("notes.txt")
        try Data("mine".utf8).write(to: foreign)
        store.prune()
        #expect(FileManager.default.fileExists(atPath: foreign.path))
    }

    @Test func otherAppsReportsAreNotThisStores() throws {
        let host = Self.tempStore(prefix: "host", keep: 1)
        defer { try? FileManager.default.removeItem(at: host.directory) }
        let viewer = CrashReportStore(directory: host.directory, prefix: "viewer", keep: 1)
        let t = Date(timeIntervalSince1970: 1_790_000_000)
        _ = try #require(host.save(Self.distinctCrash(1), timestamp: t))
        _ = try #require(viewer.save(Self.distinctCrash(2), timestamp: t.addingTimeInterval(1)))
        #expect(host.reports().count == 1 && viewer.reports().count == 1)
    }

    @Test func noticeComesForUnansweredCrashesAndHangsOnly() throws {
        let store = Self.tempStore()
        defer { try? FileManager.default.removeItem(at: store.directory) }
        #expect(store.notice(appName: "Glass Act Host") == nil)
        let t = Date(timeIntervalSince1970: 1_790_000_000)
        // A CPU-exception payload is kept, but isn't worth interrupting for.
        let cpu = Self.json(["cpuExceptionDiagnostics": [["diagnosticMetaData": ["appVersion": "1.0"]]]])
        let saved = try #require(store.save(cpu, timestamp: t))
        #expect(saved.url.lastPathComponent.hasPrefix("host-cpu-"))
        #expect(store.notice(appName: "Glass Act Host") == nil)

        let crash = try #require(store.save(Self.crashPayload(), timestamp: t.addingTimeInterval(10)))
        let hang = try #require(store.save(Self.hangPayload(), timestamp: t.addingTimeInterval(20)))
        let notice = try #require(store.notice(appName: "Glass Act Host"))
        #expect(notice.report == hang.url, "the newest one leads")
        #expect(notice.title == "Glass Act Host was unresponsive last time")
        #expect(notice.detail == "Version 1.0 (202610131845) was unresponsive for 5.5 sec. "
                + "The report stays on this Mac unless you choose to send it. 1 earlier report is in the same folder.")
        #expect(notice.unanswered == [hang.url, crash.url])

        store.markAnswered(notice.unanswered)
        #expect(store.notice(appName: "Glass Act Host") == nil)
        #expect(store.unanswered().isEmpty)

        let next = try #require(store.save(Self.distinctCrash(7), timestamp: t.addingTimeInterval(30)))
        let again = try #require(store.notice(appName: "Glass Act Host"))
        #expect(again.title == "Glass Act Host quit unexpectedly last time")
        #expect(again.unanswered == [next.url])
        #expect(again.detail == "Version 1.0 crashed: SIGSEGV. The report stays on this Mac unless you choose to send it.")
    }

    @Test func answeredReportsStayAnsweredAfterPruning() throws {
        let store = Self.tempStore(keep: 1)
        defer { try? FileManager.default.removeItem(at: store.directory) }
        let t = Date(timeIntervalSince1970: 1_790_000_000)
        let first = try #require(store.save(Self.distinctCrash(1), timestamp: t))
        store.markAnswered([first.url])
        _ = try #require(store.save(Self.distinctCrash(2), timestamp: t.addingTimeInterval(60)))
        #expect(!FileManager.default.fileExists(atPath: first.url.path), "pruned")
        // MetricKit hands the first one over again: it's neither saved nor shown.
        #expect(store.save(Self.distinctCrash(1), timestamp: t) == nil)
        #expect(store.unanswered().count == 1)
    }

    @Test func displayPathHidesTheUserName() {
        let home = "/Users/alex"
        let host = URL(fileURLWithPath: "/Users/alex/Library/Logs/Glass Act/CrashReports/host-crash.json")
        #expect(CrashReportStore.displayPath(host, home: home) == "~/Library/Logs/Glass Act/CrashReports/host-crash.json")
        let viewer = URL(fileURLWithPath:
            "/Users/alex/Library/Containers/app.glassact.viewer/Data/Library/Logs/Glass Act/CrashReports/v.json")
        #expect(CrashReportStore.displayPath(viewer, home: home + "/")
                == "~/Library/Containers/app.glassact.viewer/Data/Library/Logs/Glass Act/CrashReports/v.json")
        let elsewhere = URL(fileURLWithPath: "/Users/alexandra/x.json")
        #expect(CrashReportStore.displayPath(elsewhere, home: home) == "/Users/alexandra/x.json")
    }

    @Test func reportNamesParseStrictly() {
        #expect(CrashReportStore.parseName("viewer-hang-20261019-095900-0a1b2c3d.json")
                == .init(prefix: "viewer", kind: .hang, hash: "0a1b2c3d", sortKey: "20261019-095900-0a1b2c3d"))
        for bad in ["viewer-hang-20261019-095900-0a1b2c3d.log", ".seen", "viewer-crash-2026-095900-0a1b2c3d.json",
                    "viewer-boom-20261019-095900-0a1b2c3d.json", "viewer-crash-20261019-095900-zzzzzzzz.json",
                    "viewer-20261019-095900-0a1b2c3d.json"] {
            #expect(CrashReportStore.parseName(bad) == nil, "\(bad)")
        }
    }
}
