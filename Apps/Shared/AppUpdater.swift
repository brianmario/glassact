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
/// With automatic checks on, each launch checks a few seconds in, and a
/// running app every hour (`SUScheduledCheckInterval`). Sparkle alone
/// checks at most once a day, so an app opened the day a release came out
/// could keep the old version until the next.
///
/// `GLASSACT_UPDATE_FEED` overrides the feed, for trying an update from a
/// local server; an update still has to carry the release key's signature.
@MainActor
final class AppUpdater: NSObject, SPUUpdaterDelegate {
    private let log: (String) -> Void
    private var controller: SPUStandardUpdaterController?
    private var postponedInstall: (() -> Void)?

    /// Whether relaunching into an update now is fine. The Host says no
    /// while a viewer is connected; the install then waits for
    /// `relaunchMayProceed()`.
    var mayRelaunch: () -> Bool = { true }

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
        let controller = SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: self,
                                                      userDriverDelegate: nil)
        self.controller = controller
        // Shortly after launch, once the app is up: no UI unless there's an
        // update. A check already under way (Sparkle's own scheduled one)
        // makes this a no-op.
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.launchCheckDelayS) {
            let updater = controller.updater
            guard updater.automaticallyChecksForUpdates, updater.canCheckForUpdates else { return }
            updater.checkForUpdatesInBackground()
        }
    }

    static let launchCheckDelayS = 3.0

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

    /// The moment `mayRelaunch` turns true again: install a held update.
    func relaunchMayProceed() {
        guard let install = postponedInstall else { return }
        postponedInstall = nil
        log("updates: installing the held update")
        install()
    }

    // MARK: - SPUUpdaterDelegate

    nonisolated func feedURLString(for updater: SPUUpdater) -> String? {
        ProcessInfo.processInfo.environment["GLASSACT_UPDATE_FEED"]
    }

    nonisolated func updater(_ updater: SPUUpdater, shouldPostponeRelaunchForUpdate item: SUAppcastItem,
                             untilInvokingBlock installHandler: @escaping () -> Void) -> Bool {
        let version = item.displayVersionString
        // Sparkle calls its delegate on the main thread, and so the handler.
        nonisolated(unsafe) let install = installHandler
        return MainActor.assumeIsolated {
            guard !mayRelaunch() else { return false }
            postponedInstall = install
            log("updates: \(version) is ready; it installs when the viewer leaves")
            return true
        }
    }

    nonisolated func updater(_ updater: SPUUpdater, didAbortWithError error: any Error) {
        let message = error.localizedDescription
        MainActor.assumeIsolated { log("updates: \(message)") }
    }
}
