import Foundation

/// The running build, from the bundle's Info.plist (RELEASING.md "Versions"):
/// the version (`26.10.0`), the build number (a UTC timestamp, which update
/// checks order by) and the commit it was built from. Release builds stamp
/// the commit (`GLASSACT_COMMIT`); a build from Xcode has none.
enum BuildInfo {
    static let version = info("CFBundleShortVersionString") ?? "?"
    static let build = info("CFBundleVersion") ?? "?"
    static let commit = info("GlassActCommit")

    /// "26.10.0 (202610222020, a1b2c3d)", for logs and reports.
    static let stamp = "\(version) (\(aboutVersion))"

    /// What the About panel shows in parentheses after the version:
    /// "202610222020, a1b2c3d".
    static let aboutVersion = [build, commit].compactMap { $0 }.joined(separator: ", ")

    private static func info(_ key: String) -> String? {
        guard let value = Bundle.main.object(forInfoDictionaryKey: key) as? String, !value.isEmpty
        else { return nil }
        return value
    }
}
