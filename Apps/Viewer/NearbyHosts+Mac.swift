import AppKit
import GlassActSession

extension NearbyHosts {
    /// Privacy & Security (Local Network has no deep link of its own).
    static func openPrivacySettings(_ anchor: String? = nil) {
        let query = anchor.map { "?\($0)" } ?? "?Privacy"
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security\(query)") {
            NSWorkspace.shared.open(url)
        }
    }
}
