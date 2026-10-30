public import Foundation
public import MetricKit

/// macOS 27's MetricKit (`MetricManager`, `DiagnosticReport`) delivers the
/// same diagnostics as the older `MXMetricManager` (still used before 27),
/// as Swift values instead of JSON. Each report is turned into the JSON
/// shape `MXDiagnosticPayload.jsonRepresentation()` writes, so everything
/// after delivery — the saved file, `CrashReportSummary.parse`, the issue
/// link, Send Logs and `scripts/symbolicate-crash` — reads one format.
@available(macOS 27, iOS 27, *)
public enum MetricKitReports {
    /// The payload JSON for `report`, and when it ended; nil for kinds Glass
    /// Act doesn't save.
    public static func payloadJSON(_ report: DiagnosticReport) -> (json: Data, end: Date)? {
        guard let (key, entry) = entry(report.result, environment: report.environment) else { return nil }
        let iso = ISO8601DateFormatter()
        let root: [String: Any] = [
            "timeStampBegin": iso.string(from: report.timeRange.start),
            "timeStampEnd": iso.string(from: report.timeRange.end),
            key: [entry],
        ]
        guard let json = try? JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys])
        else { return nil }
        return (json, report.timeRange.end)
    }

    private static func entry(_ result: DiagnosticResult,
                              environment: DiagnosticReport.Environment) -> (String, [String: Any])? {
        var meta = metaData(environment)
        let key: String
        let tree: CallStackTree
        switch result {
        case .crash(let crash):
            key = "crashDiagnostics"
            tree = crash.callStackTree
            meta["exceptionType"] = crash.exceptionType
            meta["exceptionCode"] = crash.exceptionCode
            meta["signal"] = crash.signal
            meta["terminationReason"] = crash.terminationReason?.rawValue
            meta["terminationCategory"] = crash.terminationCategory?.rawValue
            meta["virtualMemoryRegionInfo"] = crash.virtualMemoryRegionInfo
            if let reason = crash.exceptionReason {
                meta["exceptionReason"] = [
                    "composedMessage": reason.composedMessage,
                    "formatString": reason.formatString,
                    "arguments": reason.arguments,
                    "exceptionType": reason.exceptionType,
                    "className": reason.className,
                    "exceptionName": reason.exceptionName,
                ]
            }
        case .hang(let hang):
            key = "hangDiagnostics"
            tree = hang.callStackTree
            meta["hangDuration"] = seconds(hang.hangDuration)
        case .cpuException(let cpu):
            key = "cpuExceptionDiagnostics"
            tree = cpu.callStackTree
            meta["totalCPUTime"] = seconds(cpu.totalCPUTime)
            meta["totalSampledTime"] = seconds(cpu.totalSampledTime)
        case .diskWriteException(let disk):
            key = "diskWriteExceptionDiagnostics"
            tree = disk.callStackTree
            meta["writesCaused"] = "\(Int(disk.totalBytesWritten.converted(to: .bytes).value)) bytes"
        case .appLaunch(let launch):
            key = "appLaunchDiagnostics"
            tree = launch.callStackTree
            meta["launchDuration"] = seconds(launch.launchDuration)
        default:
            return nil // kinds macOS doesn't deliver, or ones added later
        }
        return (key, ["diagnosticMetaData": meta.compactMapValues { $0 }, "callStackTree": json(tree)])
    }

    private static func metaData(_ env: DiagnosticReport.Environment) -> [String: Any?] {
        [
            "appVersion": env.applicationVersion,
            "appBuildVersion": env.applicationBuildVersion,
            "osVersion": "\(env.osVersion.platform) \(env.osVersion.number) (\(env.osVersion.buildNumber))",
            "platformArchitecture": env.platformArchitecture,
            "deviceType": env.deviceType,
            "regionFormat": env.regionFormat,
            "bundleIdentifier": env.bundleIdentifier,
            "lowPowerModeEnabled": env.lowPowerModeEnabled,
            "isTestFlightApp": env.isTestFlightApp,
            "pid": env.pid.map { Int($0) },
        ]
    }

    /// "5.5 sec", as MXDiagnosticPayload writes durations.
    private static func seconds(_ m: Measurement<UnitDuration>) -> String {
        let s = m.converted(to: .seconds).value
        return s == s.rounded() ? "\(Int(s)) sec" : String(format: "%.2f sec", s)
    }

    private static func json(_ tree: CallStackTree) -> [String: Any] {
        [
            "callStackPerThread": tree.callStackPerThread,
            "callStacks": tree.callStackThreads.map { thread -> [String: Any] in
                [
                    "threadAttributed": thread.threadAttributed ?? false,
                    "callStackRootFrames": thread.rootFrames.map { json($0, in: tree) },
                ]
            },
        ]
    }

    private static func json(_ frame: CallStackFrame, in tree: CallStackTree) -> [String: Any] {
        var out: [String: Any] = [
            "binaryName": frame.binaryName(from: tree) ?? "???",
            "sampleCount": frame.sampleCount ?? 1,
            "subFrames": frame.subFrames.map { json($0, in: tree) },
        ]
        if let uuid = frame.binaryUUID { out["binaryUUID"] = uuid.uuidString }
        if let offset = frame.offsetIntoBinaryTextSegment { out["offsetIntoBinaryTextSegment"] = offset }
        if let address = frame.address { out["address"] = address }
        return out
    }
}
