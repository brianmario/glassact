import Foundation
import IOKit.ps
import ServiceManagement
import SystemConfiguration
import dnssd

/// How this Mac introduces itself: its names, and (optionally) a Bonjour
/// announcement so viewers on the local network can list it instead of being
/// told an address. The announcement is a convenience, never trust — viewers
/// still pin the host key on first use, and the user here still approves
/// each viewer by its verification code.
enum HostPresence {
    /// Bonjour service type both apps agree on (also in each app's
    /// NSBonjourServices, for local network privacy).
    static let serviceType = "_glassact._udp"

    /// "Alex's MacBook Pro" — what people call this Mac.
    static var computerName: String {
        (SCDynamicStoreCopyComputerName(nil, nil) as String?) ?? Host.current().localizedName ?? "This Mac"
    }

    /// "Alexs-MacBook-Pro.local" — the address a viewer dials.
    static var localAddress: String {
        if let name = SCDynamicStoreCopyLocalHostName(nil) as String?, !name.isEmpty {
            return "\(name).local"
        }
        return ProcessInfo.processInfo.hostName
    }

    /// Laptops have an internal battery; viewers pick the matching symbol.
    static var isLaptop: Bool {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let list = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef] else { return false }
        return list.contains { source in
            let desc = IOPSGetPowerSourceDescription(info, source)?.takeUnretainedValue() as? [String: Any]
            return desc?[kIOPSTypeKey] as? String == kIOPSInternalBatteryType
        }
    }

    static let visibleKey = "glassact.host.visibleNearby"

    /// Persisted; default on — finding the host is the first thing a new
    /// user has to do.
    static var visibleNearby: Bool {
        get { UserDefaults.standard.object(forKey: visibleKey) as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: visibleKey) }
    }
}

/// Registers `_glassact._udp` for the control port (main thread). Separate from
/// the QUIC listener on purpose: advertising never touches the transport.
final class NearbyAdvertiser {
    private var ref: DNSServiceRef?

    var isAdvertising: Bool { ref != nil }

    func start(port: UInt16) {
        guard ref == nil else { return }
        // TXT: where to dial (the service name is the computer name, which
        // isn't an address) and what kind of Mac to draw.
        var txt: [UInt8] = []
        for entry in ["host=\(HostPresence.localAddress)", "port=\(port)",
                      "kind=\(HostPresence.isLaptop ? "laptop" : "desktop")", "v=1"] {
            let bytes = Array(entry.utf8.prefix(255))
            txt.append(UInt8(bytes.count))
            txt += bytes
        }
        var newRef: DNSServiceRef?
        let err = txt.withUnsafeBytes { buf in
            DNSServiceRegister(&newRef, 0, 0, nil, HostPresence.serviceType, nil, nil,
                               port.bigEndian, UInt16(buf.count), buf.baseAddress, nil, nil)
        }
        guard err == kDNSServiceErr_NoError, let newRef else { return }
        DNSServiceSetDispatchQueue(newRef, .main)
        ref = newRef
    }

    func stop() {
        if let ref { DNSServiceRefDeallocate(ref) }
        ref = nil
    }
}

/// Open at Login, so a Mac that restarts is reachable again once someone
/// logs in. System Settings › General › Login Items is the source of truth:
/// the user can switch it off there and the menu follows. It defaults to
/// on: the first launch from /Applications registers it once. A Debug build
/// elsewhere never registers itself, because a login item pointing at a
/// build folder is how stale copies end up holding privacy grants.
@MainActor enum OpenAtLogin {
    private static let defaultAppliedKey = "glassact.host.openAtLoginDefaultApplied"

    static var isEnabled: Bool { SMAppService.mainApp.status == .enabled }
    /// Registered, but switched off (or not yet allowed) in Login Items.
    static var needsApproval: Bool { SMAppService.mainApp.status == .requiresApproval }

    /// The default-on step. Returns an error to report, if registering failed.
    static func applyDefault() -> String? {
        guard !UserDefaults.standard.bool(forKey: defaultAppliedKey),
              Bundle.main.bundleURL.path.hasPrefix("/Applications/") else { return nil }
        UserDefaults.standard.set(true, forKey: defaultAppliedKey)
        return set(true)
    }

    /// Returns an error to report, if the change failed.
    static func set(_ on: Bool) -> String? {
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            return nil
        } catch {
            return "open at login: couldn’t \(on ? "register" : "unregister") (\(error.localizedDescription))"
        }
    }

    static func openLoginItemsSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }
}
