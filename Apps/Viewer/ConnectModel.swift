import Foundation
import Observation

/// What the connect window shows and edits. The app delegate owns the
/// session and drives `phase`; the view only reads it and calls `connect` /
/// `cancel`. Main thread.
@MainActor @Observable
final class ConnectModel {
    enum ShareMode: Int { case display = 0, window = 1 }

    /// Raw values are persisted, so keep them stable; the RESIZE geometry
    /// mode is `rawValue + 1`.
    enum Resolution: Int, CaseIterable, Identifiable {
        case matchThisMac = 0, scaleToFit = 1, native = 2, fillWindow = 3
        var id: Int { rawValue }
        /// Picker order: most to least common.
        static let ordered: [Resolution] = [.matchThisMac, .fillWindow, .scaleToFit, .native]

        var title: String {
            switch self {
            case .matchThisMac: "Match This Mac"
            case .fillWindow: "Fit to Window"
            case .scaleToFit: "Scale Down"
            case .native: "Native"
            }
        }

        var explanation: String {
            switch self {
            case .matchThisMac: "The host switches to this display’s resolution, for a sharp, pixel-for-pixel picture."
            case .fillWindow: "The host adds a virtual display the size of your window, and follows it as you resize."
            case .scaleToFit: "The host’s display stays as it is; the picture is scaled to fit this one."
            case .native: "Every pixel at full size. Move the pointer to an edge to pan around."
            }
        }
    }

    enum Phase: Equatable {
        case idle
        case connecting
        /// The host is asking its user; both screens show `code`.
        case awaitingApproval(code: String)
        /// The host takes new viewers that sign in with its Mac's account.
        case signingIn
        case reconnecting(attempt: Int)
        case choosingWindow
        case inSession
    }

    struct Notice: Equatable {
        enum Kind { case info, problem }
        var kind: Kind
        var text: String
        /// The raw reason, for the curious (tooltip).
        var detail: String?
    }

    var host = "" {
        didSet { if host != oldValue, host != chosenNearby?.host { chosenNearby = nil } }
    }
    var port = "4433"
    var hostKey = ""
    var shareMode: ShareMode = .display
    var resolution: Resolution = .matchThisMac
    var showAdvanced = false
    /// The nearby Mac the address came from, for its name.
    private(set) var chosenNearby: NearbyHost?

    var phase: Phase = .idle
    var notice: Notice?
    /// Secondary line under "Connecting…" once a dial has failed quietly.
    var connectHint: String?
    private(set) var recents: [String] = []
    let nearby = NearbyHosts()

    // Sign in (phase .signingIn): the host Mac's account. The password is
    // cleared after every attempt.
    var signInUser = ""
    var signInPassword = ""
    var signInError: String?
    var signInBusy = false
    /// The host's key, shown on a first connection so it can be compared.
    var signInHostKey: String?

    var canSignIn: Bool {
        phase == .signingIn && !signInBusy
            && !signInUser.trimmingCharacters(in: .whitespaces).isEmpty && !signInPassword.isEmpty
    }

    @ObservationIgnored var onConnect: () -> Void = {}
    @ObservationIgnored var onCancel: () -> Void = {}
    @ObservationIgnored var onSignIn: () -> Void = {}

    var trimmedHost: String { host.trimmingCharacters(in: .whitespaces) }
    var canConnect: Bool { phase == .idle && !trimmedHost.isEmpty }
    /// "Alex’s Mac mini" when picked from the list, else the address.
    var displayName: String {
        let name = chosenNearby?.name ?? trimmedHost
        return name.isEmpty ? "the host" : name
    }

    func choose(_ nearbyHost: NearbyHost) {
        chosenNearby = nearbyHost
        host = nearbyHost.host
        port = String(nearbyHost.port)
        notice = nil
    }

    func isChosen(_ nearbyHost: NearbyHost) -> Bool {
        chosenNearby?.name == nearbyHost.name && trimmedHost == nearbyHost.host
    }

    // MARK: - Persistence (stored keys; keep them stable)

    private static let keys = (host: "glassact.viewer.host", port: "glassact.viewer.port",
                               fingerprint: "glassact.viewer.fingerprint",
                               displayMode: "glassact.viewer.displayMode",
                               singleWindow: "glassact.viewer.singleWindow",
                               hostName: "glassact.viewer.hostName",
                               recents: "glassact.viewer.recents")

    func restore() {
        let d = UserDefaults.standard, k = Self.keys
        if let v = d.string(forKey: k.host), !v.isEmpty { host = v }
        if let v = d.string(forKey: k.port), !v.isEmpty { port = v }
        if let v = d.string(forKey: k.fingerprint) { hostKey = v }
        resolution = Resolution(rawValue: d.integer(forKey: k.displayMode)) ?? .matchThisMac
        shareMode = d.bool(forKey: k.singleWindow) ? .window : .display
        if let name = d.string(forKey: k.hostName), !name.isEmpty, !host.isEmpty,
           let port = UInt16(port) {
            chosenNearby = NearbyHost(name: name, host: host, port: port, isLaptop: false)
        }
        recents = d.stringArray(forKey: k.recents) ?? []
        showAdvanced = !hostKey.isEmpty || port != "4433"
    }

    func save() {
        let d = UserDefaults.standard, k = Self.keys
        d.set(trimmedHost, forKey: k.host)
        d.set(port.trimmingCharacters(in: .whitespaces), forKey: k.port)
        d.set(hostKey.trimmingCharacters(in: .whitespaces), forKey: k.fingerprint)
        d.set(resolution.rawValue, forKey: k.displayMode)
        d.set(shareMode == .window, forKey: k.singleWindow)
        d.set(chosenNearby?.name ?? "", forKey: k.hostName)
    }

    /// A session came up: this address goes to the top of the suggestions.
    func noteConnected() {
        let address = trimmedHost
        guard !address.isEmpty else { return }
        recents = [address] + recents.filter { $0.caseInsensitiveCompare(address) != .orderedSame }
        recents = Array(recents.prefix(8))
        UserDefaults.standard.set(recents, forKey: Self.keys.recents)
    }
}

/// App-wide preferences (Settings window), read at each connect. The
/// stored keys must stay stable.
@MainActor @Observable
final class ViewerSettings {
    static let shared = ViewerSettings()

    private static let qualityKey = "glassact.viewer.qualityFloor"
    private static let sharpnessKey = "glassact.viewer.preferSharpness"

    /// 0 = automatic, 1…3 = keep quality high / medium / low.
    var qualityFloor: Int = UserDefaults.standard.integer(forKey: ViewerSettings.qualityKey) {
        didSet { UserDefaults.standard.set(qualityFloor, forKey: Self.qualityKey) }
    }
    var preferSharpness: Bool = UserDefaults.standard.bool(forKey: ViewerSettings.sharpnessKey) {
        didSet { UserDefaults.standard.set(preferSharpness, forKey: Self.sharpnessKey) }
    }

    private static let allowAgentsKey = "glassact.viewer.allowAgents"
    static let allowAgentsChanged = Notification.Name("glassact.viewer.allowAgentsChanged")
    /// Agents on this Mac (the `glassact` CLI, an MCP client) may drive the
    /// session open here. Off by default: any program running as you could
    /// otherwise use the remote Mac through it.
    var allowAgents: Bool = UserDefaults.standard.bool(forKey: ViewerSettings.allowAgentsKey) {
        didSet {
            UserDefaults.standard.set(allowAgents, forKey: Self.allowAgentsKey)
            NotificationCenter.default.post(name: Self.allowAgentsChanged, object: nil)
        }
    }
}
