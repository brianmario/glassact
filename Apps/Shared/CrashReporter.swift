import AppKit
import GlassActTransport
import MetricKit
import SwiftUI

/// Crash and hang reports (§13), the app side, shared by both apps.
///
/// MetricKit hands each app a diagnostic payload on the launch after it
/// crashed or hung. Every payload is saved, as MetricKit wrote it, to the
/// app's CrashReports folder (the newest 20 are kept) and summed up in one
/// log line. A crash or hang the person hasn't answered yet becomes a
/// notice: **Report…** opens a prefilled GitHub issue in their browser and
/// shows the file in Finder to attach; **Dismiss** forgets it. Nothing is
/// sent anywhere by the app itself.
@MainActor
final class CrashReporter {
    let appName: String
    let store: CrashReportStore
    /// The notice to show changed; nil means none.
    var onNotice: ((CrashNotice?) -> Void)?
    private(set) var notice: CrashNotice?
    private let log: (String) -> Void
    private var subscriber: DiagnosticSubscriber?

    /// `prefix` names this app's report files ("host", "viewer").
    init(appName: String, prefix: String, log: @escaping (String) -> Void) {
        self.appName = appName
        self.store = .forApp(prefix: prefix)
        self.log = log
    }

    /// At launch: subscribe, take any payloads MetricKit already has, and
    /// bring up a notice left unanswered last time.
    func start() {
        let subscriber = DiagnosticSubscriber { [weak self] payloads in
            DispatchQueue.main.async { self?.ingest(payloads) }
        }
        MXMetricManager.shared.add(subscriber)
        self.subscriber = subscriber
        // Delivered before this launch subscribed (or again): saving
        // dedupes by content, so these never show twice.
        ingest(MXMetricManager.shared.pastDiagnosticPayloads.map(DiagnosticSubscriber.extract))
        refresh()
    }

    private func ingest(_ payloads: [(json: Data, end: Date)]) {
        var saved = false
        for payload in payloads {
            guard let report = store.save(payload.json, timestamp: payload.end) else { continue }
            log("crash report: \(report.summary.logLine) → \(report.url.lastPathComponent)")
            saved = true
        }
        if saved { refresh() }
    }

    private func refresh() {
        notice = store.notice(appName: appName)
        onNotice?(notice)
    }

    /// Report…: the issue form in the browser, the file in Finder to attach.
    func report() {
        guard let notice else { return }
        NSWorkspace.shared.open(notice.issueURL)
        NSWorkspace.shared.activateFileViewerSelecting([notice.report])
        log("crash report: opened a GitHub issue form for \(notice.report.lastPathComponent)")
        answer(notice)
    }

    func dismiss() {
        guard let notice else { return }
        answer(notice)
    }

    private func answer(_ notice: CrashNotice) {
        store.markAnswered(notice.unanswered)
        refresh()
    }

    /// Show Crash Reports in Finder: the newest selected, else the folder.
    func revealReports() {
        try? FileManager.default.createDirectory(at: store.directory, withIntermediateDirectories: true,
                                                 attributes: [.posixPermissions: 0o700])
        if let newest = store.reports().first {
            NSWorkspace.shared.activateFileViewerSelecting([newest])
        } else {
            NSWorkspace.shared.open(store.directory)
        }
    }
}

/// MetricKit's callback object. Its queue is MetricKit's, so it only copies
/// the payloads out and hands them on.
private final class DiagnosticSubscriber: NSObject, MXMetricManagerSubscriber, Sendable {
    let handler: @Sendable ([(json: Data, end: Date)]) -> Void

    init(handler: @escaping @Sendable ([(json: Data, end: Date)]) -> Void) {
        self.handler = handler
    }

    func didReceive(_ payloads: [MXDiagnosticPayload]) {
        handler(payloads.map(Self.extract))
    }

    static func extract(_ payload: MXDiagnosticPayload) -> (json: Data, end: Date) {
        (payload.jsonRepresentation(), payload.timeStampEnd)
    }
}

/// The notice's content: what happened, and the two answers. The Host puts
/// it in a small window of its own, the Viewer in its connect window.
struct CrashNoticeContent: View {
    let notice: CrashNotice
    let onReport: () -> Void
    let onDismiss: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 8) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(notice.title)
                        .fontWeight(.medium)
                    Text(notice.detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                HStack {
                    Spacer()
                    Button("Dismiss", action: onDismiss)
                    Button("Report…", action: onReport)
                        .help("Opens a new GitHub issue in your browser, filled in from the report, "
                              + "and shows the report file in Finder so you can attach it")
                }
            }
        }
        .accessibilityElement(children: .contain)
    }
}
