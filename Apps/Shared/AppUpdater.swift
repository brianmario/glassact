import AppKit
import Sparkle

/// Updates through Sparkle (§13), shared by both apps.
///
/// Each app reads its own appcast (`SUFeedURL`) from the newest published
/// GitHub release, and installs only an update signed with the release key
/// (`SUPublicEDKey`) and code-signed by the same team. Sparkle asks the
/// person once whether to check automatically; **Check for Updates…** works
/// either way. A build without an update key (a fork, or before the key
/// exists) never checks.
///
/// `GLASSACT_UPDATE_FEED` overrides the feed, for trying an update from a
/// local server; an update still has to carry the release key's signature.
@MainActor
final class AppUpdater: NSObject, SPUUpdaterDelegate {
    private let log: (String) -> Void
    private var controller: SPUStandardUpdaterController?

    init(log: @escaping (String) -> Void) {
        self.log = log
    }

    var isEnabled: Bool { controller != nil }

    func start() {
        let key = Bundle.main.object(forInfoDictionaryKey: "SUPublicEDKey") as? String ?? ""
        guard !key.isEmpty else {
            log("updates: off (this build has no update key)")
            return
        }
        controller = SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: self,
                                                  userDriverDelegate: nil)
    }

    /// The Check for Updates… menu item's action.
    @objc func checkForUpdates(_ sender: Any?) {
        controller?.checkForUpdates(sender)
    }

    /// A menu item for both apps' menus, targeting this updater.
    func menuItem() -> NSMenuItem {
        let item = NSMenuItem(title: "Check for Updates…", action: #selector(checkForUpdates(_:)),
                              keyEquivalent: "")
        item.target = self
        return item
    }

    // MARK: - SPUUpdaterDelegate

    /// `GLASSACT_UPDATE_FEED`, for testing an update from a local server:
    /// Debug builds only. In a release, any process of this user could set
    /// it (`launchctl setenv`) and put its own release notes and links in
    /// the trusted update dialog, even though the archive still needs the
    /// release key's signature.
    nonisolated func feedURLString(for updater: SPUUpdater) -> String? {
        #if DEBUG
        ProcessInfo.processInfo.environment["GLASSACT_UPDATE_FEED"]
        #else
        nil
        #endif
    }

    /// Sparkle relaunches only when someone chose Install and Relaunch
    /// (automatic updates install when the app quits), so the choice goes
    /// ahead even with a viewer connected: often it's the viewer who chose,
    /// and holding it until they left made the button look dead. The
    /// Viewer reconnects once the Host is back.
    nonisolated func updaterWillRelaunchApplication(_ updater: SPUUpdater) {
        MainActor.assumeIsolated { log("updates: relaunching into the update") }
    }

    nonisolated func updater(_ updater: SPUUpdater, didAbortWithError error: any Error) {
        let message = error.localizedDescription
        MainActor.assumeIsolated { log("updates: \(message)") }
    }
}
