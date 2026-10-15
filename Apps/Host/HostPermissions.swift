import AppKit
import ScreenCaptureKit
import ApplicationServices
import Network
import Observation
import dnssd

/// The macOS privacy permissions the Host depends on, checked live with the
/// system's own no-prompt APIs. Nothing here may fail silently: the setup
/// window lists whatever is missing, and the app reopens it when a
/// permission that was on gets turned off. Main thread.
@MainActor @Observable
final class HostPermissions {
    enum LocalNetwork: Equatable { case unknown, allowed, blocked }

    /// What System Settings › Privacy & Security calls each permission, so
    /// what we say matches what the user sees there. macOS 27 renamed
    /// Accessibility to "Device Control and Data Access" (same TCC service,
    /// same `Privacy_Accessibility` anchor).
    enum PaneName {
        static let screenRecording = "Screen & System Audio Recording"
        static let deviceControl = "Device Control and Data Access"
        static let localNetwork = "Local Network"
        static let clipboard = "Paste from Other Apps"
    }

    /// Required: without it there's no picture.
    private(set) var screenRecording = CGPreflightScreenCaptureAccess()
    /// Required for control: posting events and driving windows.
    private(set) var accessibility = AXIsProcessTrusted()
    /// Recommended: viewers on this network find (and reach) this Mac.
    private(set) var localNetwork: LocalNetwork = .unknown
    /// Recommended: clipboard sync reads the pasteboard programmatically,
    /// which macOS gates per app (Ask / Always Allow / Always Deny).
    private(set) var clipboard = NSPasteboard.general.accessBehavior
    /// Screen Recording is on but this process started without it, or the
    /// user went to turn it on: macOS applies it to a fresh launch only.
    var captureNeedsRelaunch = false
    /// Screen recording is allowed on this Mac at all (macOS 27). False when
    /// a device-management policy forbids it: no grant in System Settings
    /// can fix that, so setup says so instead of offering "Allow…" forever.
    private(set) var screenRecordingAvailable = SCContentSharingPicker.shared.isAvailable

    var requiredGranted: Bool { screenRecording && accessibility }

    @ObservationIgnored private var browser: NWBrowser?

    func refresh() {
        let screen = CGPreflightScreenCaptureAccess()
        if screen != screenRecording { screenRecording = screen }
        let available = SCContentSharingPicker.shared.isAvailable
        if available != screenRecordingAvailable { screenRecordingAvailable = available }
        let ax = AXIsProcessTrusted()
        if ax != accessibility { accessibility = ax }
        let paste = NSPasteboard.general.accessBehavior
        if paste != clipboard { clipboard = paste }
    }

    // MARK: - Requests: the system prompt the first time, Settings after

    private static let askedScreenKey = "glassact.host.askedScreenRecording"
    private static let askedAccessibilityKey = "glassact.host.askedAccessibility"

    func requestScreenRecording() {
        captureNeedsRelaunch = true // granting it only takes effect on relaunch
        // The system alert (with its own Open System Settings button) only
        // ever appears once per app; after that, Settings is the only way.
        if !UserDefaults.standard.bool(forKey: Self.askedScreenKey) {
            UserDefaults.standard.set(true, forKey: Self.askedScreenKey)
            if CGRequestScreenCaptureAccess() { refresh() }
            return
        }
        Self.openPrivacyPane("Privacy_ScreenCapture")
    }

    func requestAccessibility() {
        if !UserDefaults.standard.bool(forKey: Self.askedAccessibilityKey) {
            UserDefaults.standard.set(true, forKey: Self.askedAccessibilityKey)
            // Shows "would like to control this computer" and lists the app,
            // switched off, under Device Control and Data Access.
            let prompt = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
            if AXIsProcessTrustedWithOptions(prompt) { refresh() }
            return
        }
        Self.openPrivacyPane("Privacy_Accessibility")
    }

    func requestLocalNetwork() {
        if localNetwork == .blocked {
            // No deep link for Local Network; Privacy & Security lists it.
            Self.openPrivacyPane(nil)
        } else {
            startLocalNetworkCheck() // browsing is what makes macOS ask
        }
    }

    func requestClipboard() {
        if clipboard == .default {
            // macOS asks on an app's first programmatic read and lists it
            // under Paste from Other Apps; Always Allow is chosen there.
            _ = NSPasteboard.general.string(forType: .string)
            refresh()
        } else {
            Self.openPrivacyPane("Privacy_Pasteboard")
        }
    }

    /// Bonjour browse for our own service type: `.ready` means the app may
    /// use the local network; waiting with PolicyDenied means it may not
    /// (or the user hasn't answered yet). Browsing triggers the prompt.
    func startLocalNetworkCheck() {
        guard browser == nil else { return }
        let browser = NWBrowser(for: .bonjour(type: HostPresence.serviceType, domain: "local."),
                                using: NWParameters())
        browser.stateUpdateHandler = { [weak self] state in
            let status: LocalNetwork
            switch state {
            case .ready:
                status = .allowed
            case let .waiting(error), let .failed(error):
                if case let .dns(code) = error, code == DNSServiceErrorType(kDNSServiceErr_PolicyDenied) {
                    status = .blocked
                } else {
                    status = .unknown
                }
            default:
                return
            }
            MainActor.assumeIsolated { // started on .main
                guard let self, self.localNetwork != status else { return }
                self.localNetwork = status
            }
        }
        browser.browseResultsChangedHandler = { _, _ in }
        browser.start(queue: .main)
        self.browser = browser
    }

    static func openPrivacyPane(_ anchor: String?) {
        let query = anchor.map { "?\($0)" } ?? "?Privacy"
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security\(query)") {
            NSWorkspace.shared.open(url)
        }
    }

    /// Quit and open again once this process has exited (and released the
    /// port), so a new Screen Recording grant takes effect.
    static func relaunch() {
        let relauncher = Process()
        relauncher.executableURL = URL(fileURLWithPath: "/bin/sh")
        relauncher.arguments = ["-c", "while /bin/kill -0 \(getpid()) 2>/dev/null; do /bin/sleep 0.2; done; "
                                    + "/usr/bin/open \"$0\"", Bundle.main.bundlePath]
        try? relauncher.run()
        NSApp.terminate(nil)
    }
}
