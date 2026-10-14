import AppKit
import Network
import Observation
import dnssd

/// A Glass Act Host announcing itself on the local network (see the host's
/// HostPresence). Where to dial comes from its TXT record — the service name
/// is the computer's name, not an address.
struct NearbyHost: Identifiable, Hashable, Sendable {
    var id: String { name }
    let name: String  // "Alex’s Mac mini"
    let host: String  // "Alexs-Mac-mini.local"
    let port: UInt16
    let isLaptop: Bool

    var symbol: String { isLaptop ? "laptopcomputer" : "desktopcomputer" }
}

/// Bonjour browse for `_glassact._udp`, main thread. Listing a host is a
/// convenience, not trust: the dial still pins (or trusts on first use) the
/// host's key, and the host still asks its user to approve this viewer.
@MainActor @Observable
final class NearbyHosts {
    static let serviceType = "_glassact._udp"

    private(set) var hosts: [NearbyHost] = []
    /// macOS isn't letting this app use the local network (Privacy &
    /// Security › Local Network) — or the user hasn't answered yet. Nearby
    /// can't list anything, and dialing a LAN address will fail.
    private(set) var isBlocked = false
    @ObservationIgnored private var browser: NWBrowser?

    func start() {
        guard browser == nil else { return }
        let browser = NWBrowser(for: .bonjourWithTXTRecord(type: Self.serviceType, domain: "local."),
                                using: NWParameters())
        browser.stateUpdateHandler = { [weak self] state in
            let blocked: Bool
            switch state {
            case .ready:
                blocked = false
            case let .waiting(error), let .failed(error):
                guard case let .dns(code) = error else { return }
                blocked = code == DNSServiceErrorType(kDNSServiceErr_PolicyDenied)
            default:
                return
            }
            MainActor.assumeIsolated { // started on .main
                guard let self, self.isBlocked != blocked else { return }
                self.isBlocked = blocked
            }
        }
        browser.browseResultsChangedHandler = { [weak self] results, _ in
            let found = results.compactMap(Self.host(from:))
            MainActor.assumeIsolated { self?.update(found) } // started on .main
        }
        browser.start(queue: .main)
        self.browser = browser
    }

    /// Privacy & Security (Local Network has no deep link of its own).
    static func openPrivacySettings(_ anchor: String? = nil) {
        let query = anchor.map { "?\($0)" } ?? "?Privacy"
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security\(query)") {
            NSWorkspace.shared.open(url)
        }
    }

    func stop() {
        browser?.cancel()
        browser = nil
    }

    private func update(_ found: [NearbyHost]) {
        // One row per Mac, however many interfaces it answers on.
        var seen = Set<String>()
        let unique = found.filter { seen.insert($0.name).inserted }
        let sorted = unique.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        if sorted != hosts { hosts = sorted }
    }

    private nonisolated static func host(from result: NWBrowser.Result) -> NearbyHost? {
        guard case let .service(name, _, _, _) = result.endpoint,
              case let .bonjour(txt) = result.metadata,
              let host = txt["host"], !host.isEmpty,
              let port = txt["port"].flatMap(UInt16.init) else { return nil }
        return NearbyHost(name: name, host: host, port: port, isLaptop: txt["kind"] == "laptop")
    }
}
