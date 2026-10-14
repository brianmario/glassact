import CryptoKit
public import Foundation
public import Security
import Synchronization

/// TLS identities for both ends. Each side has a self-signed certificate;
/// the peer is authenticated by the SHA-256 fingerprint of its leaf DER:
///
///   - the viewer pins the host's fingerprint (typed in / passed by flag);
///   - the host admits only viewer fingerprints its user approved
///     (`AuthorizedViewers`) — mutual TLS on both tunnels, so an unapproved
///     viewer never receives a pixel or injects an event.
///
/// Identities (P-256, self-signed) are generated in-process on first use —
/// CryptoKit key, hand-encoded certificate and PKCS#12 (SelfSignedIdentity)
/// — and kept in `~/Library/Application Support/Glass Act` (directory 0700, PKCS#12 file 0600). They are
/// imported memory-only: nothing touches a keychain, so rebuilds never
/// prompt. (Issue #13 tracks keeping them in the Keychain instead.)
public enum QUICIdentity {
    /// The PKCS#12 container needs *a* passphrase; the file's secrecy comes
    /// from its permissions (0600 in a 0700 directory), not from this.
    public static let containerPassphrase = "glassact"

    public static func load(p12URL: URL, passphrase: String = containerPassphrase) throws -> SecIdentity {
        try importPKCS12(Data(contentsOf: p12URL), passphrase: passphrase)
    }

    static func importPKCS12(_ data: Data, passphrase: String = containerPassphrase) throws -> SecIdentity {
        let options: [String: Any] = [
            kSecImportExportPassphrase as String: passphrase,
            kSecImportToMemoryOnly as String: true,
        ]
        var items: CFArray?
        guard SecPKCS12Import(data as CFData, options as CFDictionary, &items) == errSecSuccess,
              let array = items as? [[String: Any]], let first = array.first,
              let identity = first[kSecImportItemIdentity as String]
        else { throw QUICError.identityImportFailed }
        return identity as! SecIdentity // CF type: the cast cannot fail
    }

    /// Loads `<directory>/<name>.p12`, generating it first if missing, and
    /// (re)asserts owner-only permissions.
    ///
    /// A file that can be read but not imported (sealed with another
    /// passphrase, say the project's earlier one, or corrupt) is replaced
    /// with a fresh identity rather than failing: an app that can't load its
    /// key can't do anything, and the old key is unusable either way. Peers
    /// then see a new key — the host's viewers get the changed-key refusal,
    /// and a viewer or agent is approved again like a new one.
    public static func loadOrCreate(directory: URL, name: String, commonName: String) throws -> SecIdentity {
        let fm = FileManager.default
        try fm.createDirectory(at: directory, withIntermediateDirectories: true,
                               attributes: [.posixPermissions: 0o700])
        try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        let p12 = directory.appendingPathComponent("\(name).p12")
        if !fm.fileExists(atPath: p12.path) {
            try writeFresh(to: p12, name: name, commonName: commonName, replacing: false)
        }
        try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: p12.path)
        let data = try Data(contentsOf: p12) // an I/O error is not a bad key: throw
        if let identity = try? importPKCS12(data) { return identity }
        try writeFresh(to: p12, name: name, commonName: commonName, replacing: true)
        return try load(p12URL: p12)
    }

    /// A new identity at `p12`: staged 0600 from the first byte, then renamed
    /// into place (atomically replacing an unusable one when `replacing`).
    private static func writeFresh(to p12: URL, name: String, commonName: String, replacing: Bool) throws {
        let fm = FileManager.default
        let pkcs12 = try SelfSignedIdentity.makePKCS12(commonName: commonName,
                                                       passphrase: containerPassphrase)
        let staged = p12.deletingLastPathComponent().appendingPathComponent(".\(name)-\(UUID().uuidString).p12")
        guard fm.createFile(atPath: staged.path, contents: pkcs12,
                            attributes: [.posixPermissions: 0o600]) else {
            throw QUICError.identityImportFailed
        }
        do {
            if replacing {
                guard rename(staged.path, p12.path) == 0 else {
                    throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: p12.path])
                }
            } else {
                try fm.moveItem(at: staged, to: p12)
            }
        } catch {
            try? fm.removeItem(at: staged)
            throw error
        }
    }

    public static func fingerprint(of identity: SecIdentity) throws -> String {
        var cert: SecCertificate?
        guard SecIdentityCopyCertificate(identity, &cert) == errSecSuccess, let cert else {
            throw QUICError.identityImportFailed
        }
        return fingerprint(of: cert)
    }

    /// SHA-256 of the certificate DER, lowercase hex.
    public static func fingerprint(of certificate: SecCertificate) -> String {
        let der = SecCertificateCopyData(certificate) as Data
        return SHA256.hash(data: der).map { String(format: "%02x", $0) }.joined()
    }

    /// Fingerprint of the leaf certificate a TLS peer presented, if any.
    static func leafFingerprint(of trust: sec_trust_t) -> String? {
        leafPeer(of: trust)?.fingerprint
    }

    /// The presented leaf certificate: its fingerprint and common name.
    static func leafPeer(of trust: sec_trust_t) -> QUICTransport.PeerCertificate? {
        let secTrust = sec_trust_copy_ref(trust).takeRetainedValue()
        guard let chain = SecTrustCopyCertificateChain(secTrust) as? [SecCertificate],
              let leaf = chain.first else { return nil }
        var cn: CFString?
        SecCertificateCopyCommonName(leaf, &cn)
        return .init(fingerprint: fingerprint(of: leaf), commonName: (cn as String?) ?? "")
    }

    public static func normalize(_ fingerprint: String) -> String {
        fingerprint.lowercased().replacingOccurrences(of: ":", with: "")
    }
}

/// The host's allowlist of viewer certificate fingerprints, persisted one per
/// line (file 0600): `<fingerprint>` then optional space-separated fields —
/// `view` (approved to watch only; offered for agents), `kind=agent|viewer`,
/// `label=…` (an agent's name), `device=…` (the computer it said it runs
/// on), `name=…` (what the host's user called it), `addr=…` (where it last
/// connected from),
/// `approved=…` / `seen=…` (Unix seconds). Values are percent-encoded;
/// unknown fields are ignored, and a bare fingerprint (files from before
/// any of this) means full control. Thread-safe: the TLS verify block
/// consults it on the listener queue while the app edits it on main.
public final class AuthorizedViewers: Sendable {
    public struct Entry: Sendable, Equatable {
        public enum Kind: String, Sendable { case viewer, agent, unknown }
        public var fingerprint: String
        public var viewOnly = false
        public var kind = Kind.unknown
        public var label = ""
        /// The computer it runs on, as it reported (VIEWER_INFO).
        public var device = ""
        /// What the host's user named it; wins over everything else.
        public var name = ""
        public var address = ""
        public var approvedAt: Date?
        public var lastSeenAt: Date?

        public init(fingerprint: String) { self.fingerprint = fingerprint }

        var line: String {
            var fields = [fingerprint]
            if viewOnly { fields.append("view") }
            if kind != .unknown { fields.append("kind=\(kind.rawValue)") }
            if !label.isEmpty { fields.append("label=\(Self.encode(label))") }
            if !device.isEmpty { fields.append("device=\(Self.encode(device))") }
            if !name.isEmpty { fields.append("name=\(Self.encode(name))") }
            if !address.isEmpty { fields.append("addr=\(Self.encode(address))") }
            if let approvedAt { fields.append("approved=\(Int(approvedAt.timeIntervalSince1970))") }
            if let lastSeenAt { fields.append("seen=\(Int(lastSeenAt.timeIntervalSince1970))") }
            return fields.joined(separator: " ")
        }

        init?(line: Substring) {
            let fields = line.split(separator: " ", omittingEmptySubsequences: true)
            guard let first = fields.first else { return nil }
            let fp = QUICIdentity.normalize(String(first))
            guard fp.count == 64, fp.allSatisfy(\.isHexDigit) else { return nil }
            fingerprint = fp
            for field in fields.dropFirst() {
                if field == "view" { viewOnly = true; continue }
                guard let eq = field.firstIndex(of: "=") else { continue }
                let key = field[..<eq], value = String(field[field.index(after: eq)...])
                switch key {
                case "kind": kind = Kind(rawValue: value) ?? .unknown
                case "label": label = Self.decode(value)
                case "device": device = Self.decode(value)
                case "name": name = Self.decode(value)
                case "addr": address = Self.decode(value)
                case "approved": approvedAt = Double(value).map { Date(timeIntervalSince1970: $0) }
                case "seen": lastSeenAt = Double(value).map { Date(timeIntervalSince1970: $0) }
                default: break
                }
            }
        }

        private static let safe = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-._~:"))
        static func encode(_ s: String) -> String {
            String(s.prefix(64)).addingPercentEncoding(withAllowedCharacters: safe) ?? ""
        }
        static func decode(_ s: String) -> String { s.removingPercentEncoding ?? s }
    }

    private let url: URL
    private let entries: Mutex<[String: Entry]>

    public init(url: URL) {
        self.url = url
        let text = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        var loaded: [String: Entry] = [:]
        for line in text.split(whereSeparator: \.isNewline) {
            if let entry = Entry(line: line) { loaded[entry.fingerprint] = entry }
        }
        entries = Mutex(loaded)
    }

    public func contains(_ fingerprint: String) -> Bool {
        entries.withLock { $0[QUICIdentity.normalize(fingerprint)] != nil }
    }

    /// Approved to watch only (no input, clipboard or window changes).
    public func isViewOnly(_ fingerprint: String) -> Bool {
        entries.withLock { $0[QUICIdentity.normalize(fingerprint)]?.viewOnly ?? false }
    }

    public var count: Int { entries.withLock { $0.count } }

    /// Every approval, most recently seen (else approved) first.
    public var all: [Entry] {
        entries.withLock { Array($0.values) }.sorted {
            ($0.lastSeenAt ?? $0.approvedAt ?? .distantPast) > ($1.lastSeenAt ?? $1.approvedAt ?? .distantPast)
        }
    }

    /// Throws `QUICError.invalidFingerprint` unless it's 64 hex digits
    /// (colons and case ignored). Re-adding keeps what was known about it.
    public func add(_ fingerprint: String, viewOnly: Bool = false, kind: Entry.Kind = .unknown) throws {
        let normalized = QUICIdentity.normalize(fingerprint)
        guard normalized.count == 64, normalized.allSatisfy(\.isHexDigit) else {
            throw QUICError.invalidFingerprint
        }
        try update(normalized, create: true) { e in
            e.viewOnly = viewOnly
            if kind != .unknown { e.kind = kind }
            e.approvedAt = Date()
        }
    }

    /// A session with this key went live: remember what it is and where it
    /// came from. No-op for keys not on the list.
    public func noteSeen(_ fingerprint: String, kind: Entry.Kind, address: String) {
        try? update(QUICIdentity.normalize(fingerprint), create: false) { e in
            if kind != .unknown { e.kind = kind }
            if !address.isEmpty { e.address = address }
            e.lastSeenAt = Date()
        }
    }

    /// An agent named itself.
    public func noteLabel(_ fingerprint: String, label: String) {
        guard !label.isEmpty else { return }
        try? update(QUICIdentity.normalize(fingerprint), create: false) { e in e.label = label }
    }

    /// The computer it runs on, as reported.
    public func noteDevice(_ fingerprint: String, device: String) {
        guard !device.isEmpty else { return }
        try? update(QUICIdentity.normalize(fingerprint), create: false) { e in e.device = device }
    }

    /// The host's user named it (empty = back to the reported name).
    public func rename(_ fingerprint: String, to name: String) throws {
        try update(QUICIdentity.normalize(fingerprint), create: false) { e in
            e.name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }

    /// Switch between control and watching only.
    public func setViewOnly(_ fingerprint: String, _ viewOnly: Bool) throws {
        try update(QUICIdentity.normalize(fingerprint), create: false) { e in e.viewOnly = viewOnly }
    }

    /// Forget one key. True if it was there.
    @discardableResult
    public func remove(_ fingerprint: String) throws -> Bool {
        let normalized = QUICIdentity.normalize(fingerprint)
        let (removed, snapshot) = entries.withLock { map -> (Bool, [String]) in
            let removed = map.removeValue(forKey: normalized) != nil
            return (removed, map.keys.sorted().map { map[$0]!.line })
        }
        if removed { try persist(snapshot) }
        return removed
    }

    public func removeAll() throws {
        entries.withLock { $0.removeAll() }
        try persist([])
    }

    private func update(_ fingerprint: String, create: Bool, _ change: (inout Entry) -> Void) throws {
        let snapshot = entries.withLock { map -> [String]? in
            guard var entry = map[fingerprint] ?? (create ? Entry(fingerprint: fingerprint) : nil) else { return nil }
            change(&entry)
            map[fingerprint] = entry
            return map.keys.sorted().map { map[$0]!.line }
        }
        if let snapshot { try persist(snapshot) }
    }

    private func persist(_ list: [String]) throws {
        let data = Data((list.joined(separator: "\n") + (list.isEmpty ? "" : "\n")).utf8)
        try data.write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
}

extension QUICIdentity {
    /// Short authentication string both screens show for a (host, viewer)
    /// pair: 80 bits of SHA-256 over the two fingerprints, as 16 Crockford
    /// base32 characters ("7K3M-Q9TD-X2HB-R5NW"). Matching codes mean both
    /// sides see the same two keys — no one in the middle.
    ///
    /// 80 bits because there is no commitment step: a first-contact MITM
    /// controls both of its keys and can search for a collision from both
    /// ends at once (~2^(bits/2) key generations per side). At 60 bits that
    /// is ~2^30 — hours; at 80 bits ~2^40 per side, which is not practical.
    public static func verificationCode(hostFingerprint: String, viewerFingerprint: String) -> String {
        // Domain separator: changing it changes every code both screens show.
        var input = Array("glassact-verification-code-v1\u{0}".utf8)
        input += hexBytes(normalize(hostFingerprint))
        input += hexBytes(normalize(viewerFingerprint))
        let digest = Array(SHA256.hash(data: Data(input)))
        let alphabet = Array("0123456789ABCDEFGHJKMNPQRSTVWXYZ") // Crockford: no I L O U
        var bits = 0, value = 0, chars: [Character] = []
        for byte in digest where chars.count < 16 {
            value = (value << 8) | Int(byte)
            bits += 8
            while bits >= 5 && chars.count < 16 {
                bits -= 5
                chars.append(alphabet[(value >> bits) & 31])
            }
        }
        return stride(from: 0, to: 16, by: 4).map { String(chars[$0..<$0 + 4]) }.joined(separator: "-")
    }

    private static func hexBytes(_ hex: String) -> [UInt8] {
        var out: [UInt8] = []
        var it = hex.makeIterator()
        while let hi = it.next(), let lo = it.next() {
            guard let byte = UInt8(String([hi, lo]), radix: 16) else { return Array(hex.utf8) }
            out.append(byte)
        }
        return out
    }
}

/// The viewer's remembered host keys (`host:port fingerprint` per line, file
/// 0600) — trust on first use, SSH "accept-new" semantics: an unknown host's
/// key is recorded after the first successful session; a known host that
/// presents a different key is refused, never silently re-trusted.
public final class KnownHosts: Sendable {
    private let url: URL
    private let entries: Mutex<[String: String]>

    public init(url: URL) {
        self.url = url
        var loaded: [String: String] = [:]
        let text = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        for line in text.split(whereSeparator: \.isNewline) {
            let parts = line.split(separator: " ", omittingEmptySubsequences: true)
            guard parts.count == 2 else { continue }
            let fp = QUICIdentity.normalize(String(parts[1]))
            guard fp.count == 64, fp.allSatisfy(\.isHexDigit) else { continue }
            loaded[String(parts[0])] = fp
        }
        entries = Mutex(loaded)
    }

    public static func key(host: String, port: UInt16) -> String {
        "\(host.lowercased()):\(port)"
    }

    public func fingerprint(host: String, port: UInt16) -> String? {
        entries.withLock { $0[Self.key(host: host, port: port)] }
    }

    public func remember(host: String, port: UInt16, fingerprint: String) throws {
        let fp = QUICIdentity.normalize(fingerprint)
        guard fp.count == 64, fp.allSatisfy(\.isHexDigit) else { throw QUICError.invalidFingerprint }
        let snapshot = entries.withLock { map -> [String: String] in
            map[Self.key(host: host, port: port)] = fp
            return map
        }
        try persist(snapshot)
    }

    public func forget(host: String, port: UInt16) throws {
        try forget(key: Self.key(host: host, port: port))
    }

    /// Forget by `key(host:port:)`, as listed by `all`.
    public func forget(key: String) throws {
        let snapshot = entries.withLock { map -> [String: String] in
            map[key] = nil
            return map
        }
        try persist(snapshot)
    }

    /// Every remembered host as (`host:port` key, fingerprint), sorted by key.
    public var all: [(key: String, fingerprint: String)] {
        entries.withLock { map in map.keys.sorted().map { ($0, map[$0]!) } }
    }

    private func persist(_ map: [String: String]) throws {
        let text = map.keys.sorted().map { "\($0) \(map[$0]!)\n" }.joined()
        try Data(text.utf8).write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
}
