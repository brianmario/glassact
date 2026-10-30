public import Foundation

/// Where Glass Act keeps things on this Mac (on an iPad, the same paths
/// inside the app's container):
/// - data in `~/Library/Application Support/Glass Act`: identities,
///   approvals, known hosts, traces, the agent sockets and the audit log;
/// - logs in `~/Library/Logs/Glass Act`.
/// Both are created (0700) on first use.
public enum AppPaths {
    public static let dataDirectory: URL = ensure(
        URL.applicationSupportDirectory.appendingPathComponent("Glass Act", isDirectory: true))

    public static let logsDirectory: URL = ensure(
        URL.libraryDirectory.appendingPathComponent("Logs/Glass Act", isDirectory: true))

    private static func ensure(_ url: URL) -> URL {
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true,
                                                 attributes: [.posixPermissions: 0o700])
        return url
    }
}
