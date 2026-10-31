import Foundation
import Network
public import Observation
import dnssd

/// A Glass Act Host announcing itself on the local network (see the host's
/// HostPresence). Where to dial comes from its TXT record — the service name
/// is the computer's name, not an address.
public struct NearbyHost: Identifiable, Hashable, Sendable {
    public var id: String { name }
    public let name: String  // "Alex’s Mac mini"
    public let host: String  // "Alexs-Mac-mini.local"
    public let port: UInt16
    public let isLaptop: Bool

    public init(name: String, host: String, port: UInt16, isLaptop: Bool) {
        self.name = name
        self.host = host
        self.port = port
        self.isLaptop = isLaptop
    }

    public var symbol: String { isLaptop ? "laptopcomputer" : "desktopcomputer" }
}

/// Bonjour browse for `_glassact._udp`, main thread (Mac and iPad Viewers). Listing a host is a
/// convenience, not trust: the dial still pins (or trusts on first use) the
/// host's key, and the host still asks its user to approve this viewer.
@MainActor @Observable
public final class NearbyHosts {
    public static let serviceType = "_glassact._udp"

    public private(set) var hosts: [NearbyHost] = []
    /// The OS isn't letting this app use the local network (Privacy &
    /// Security › Local Network) — or the user hasn't answered yet. Nearby
    /// can't list anything, and dialing a LAN address will fail.
    public private(set) var isBlocked = false
    @ObservationIgnored private var browser: NWBrowser?

    public init() {}

    public func start() {
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
