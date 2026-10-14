import Foundation
import Security
import Synchronization
import Testing
import GlassActTestSupport
@testable import GlassActTransport

/// Mutual TLS: a host that authorizes viewers admits only approved viewer
/// fingerprints — on both tunnels, before any application data flows.
@Suite(.serialized, .tags(.quic), .notInFastLane) struct ViewerAuthTests {
    final class Seen: Sendable {
        let fingerprints = Mutex<[String]>([])
    }

    @Test func approvedViewerConnects() throws {
        let (hostID, hostFP) = try QUICLoopbackTests.makeTestIdentity()
        let (viewerID, viewerFP) = try QUICLoopbackTests.makeTestIdentity()
        let session = try QUICLoopbackTests.makeSession(
            fingerprint: hostFP, identity: hostID, clientIdentity: viewerID,
            authorizeViewer: { $0 == viewerFP },
            configureHost: { _ in }, configureClient: { _ in })
        #expect(session != nil, "an approved viewer must connect")
        session?.client.cancel()
        session?.server.cancel()
    }

    /// The host's transport names its peer: the viewer certificate's
    /// fingerprint and common name ("glassact-agent" marks an agent), read
    /// from the established connection — what scopes are enforced against.
    @Test func hostTransportReportsThePeerCertificate() throws {
        let (hostID, hostFP) = try QUICLoopbackTests.makeTestIdentity()
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("glassact-agent-id-\(UInt64.random(in: 0...UInt64.max))")
        defer { try? FileManager.default.removeItem(at: dir) }
        let agentID = try QUICIdentity.loadOrCreate(directory: dir, name: "agent", commonName: "glassact-agent")
        let agentFP = try QUICIdentity.fingerprint(of: agentID)
        let session = try QUICLoopbackTests.makeSession(
            fingerprint: hostFP, identity: hostID, clientIdentity: agentID,
            authorizeViewer: { $0 == agentFP },
            configureHost: { _ in }, configureClient: { _ in })
        let peer = try #require(session?.host.peerCertificate)
        #expect(peer.fingerprint == agentFP)
        #expect(peer.commonName == "glassact-agent")
        session?.client.cancel()
        session?.server.cancel()
    }

    /// The fingerprint the host sees is the viewer's own — what the host
    /// user is asked to approve.
    @Test func unapprovedViewerIsRefusedAndReported() throws {
        let (hostID, hostFP) = try QUICLoopbackTests.makeTestIdentity()
        let (viewerID, viewerFP) = try QUICLoopbackTests.makeTestIdentity()
        let seen = Seen()
        let session = try QUICLoopbackTests.makeSession(
            fingerprint: hostFP, identity: hostID, clientIdentity: viewerID,
            authorizeViewer: { fp in seen.fingerprints.withLock { $0.append(fp) }; return false },
            configureHost: { _ in }, configureClient: { _ in })
        #expect(session == nil, "an unapproved viewer must never become ready")
        #expect(seen.fingerprints.withLock { $0.contains(viewerFP) },
                "the host must learn the refused viewer's fingerprint")
    }

    @Test func viewerWithoutCertificateIsRefused() throws {
        let (hostID, hostFP) = try QUICLoopbackTests.makeTestIdentity()
        let session = try QUICLoopbackTests.makeSession(
            fingerprint: hostFP, identity: hostID, clientIdentity: nil,
            authorizeViewer: { _ in true },
            configureHost: { _ in }, configureClient: { _ in })
        #expect(session == nil, "no client certificate, no session")
    }

    @Test func identityFilesAreOwnerOnly() throws {
        let fm = FileManager.default
        let dir = fm.temporaryDirectory.appendingPathComponent("glassact-id-\(UInt64.random(in: 0...UInt64.max))")
        defer { try? fm.removeItem(at: dir) }
        let first = try QUICIdentity.loadOrCreate(directory: dir, name: "identity", commonName: "t")
        // Loosened permissions are tightened again on the next load.
        try fm.setAttributes([.posixPermissions: 0o644],
                             ofItemAtPath: dir.appendingPathComponent("identity.p12").path)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: dir.path)

        let again = try QUICIdentity.loadOrCreate(directory: dir, name: "identity", commonName: "t")
        #expect(try QUICIdentity.fingerprint(of: again) == QUICIdentity.fingerprint(of: first),
                "an existing identity is reused, not regenerated")
        let p12Perms = try fm.attributesOfItem(atPath: dir.appendingPathComponent("identity.p12").path)[.posixPermissions] as? Int
        let dirPerms = try fm.attributesOfItem(atPath: dir.path)[.posixPermissions] as? Int
        #expect(p12Perms == 0o600)
        #expect(dirPerms == 0o700)
    }

    /// An identity file that can't be imported — sealed with another
    /// passphrase or just corrupt — must not
    /// brick the app: it is replaced by a fresh identity, owner-only, and
    /// the replacement is what later loads return.
    @Test(arguments: ["old passphrase", "garbage"])
    func undecryptableIdentityIsReplaced(kind: String) throws {
        let fm = FileManager.default
        let dir = fm.temporaryDirectory.appendingPathComponent("glassact-id-\(UInt64.random(in: 0...UInt64.max))")
        defer { try? fm.removeItem(at: dir) }
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        let p12 = dir.appendingPathComponent("identity.p12")
        let unreadable = kind == "garbage"
            ? Data("not a PKCS#12 container".utf8)
            : try SelfSignedIdentity.makePKCS12(commonName: "t", passphrase: "not-glassact")
        try unreadable.write(to: p12)
        try fm.setAttributes([.posixPermissions: 0o644], ofItemAtPath: p12.path)
        #expect(throws: QUICError.self) { try QUICIdentity.load(p12URL: p12) }

        let fresh = try QUICIdentity.loadOrCreate(directory: dir, name: "identity", commonName: "t")
        let freshFP = try QUICIdentity.fingerprint(of: fresh)
        if kind != "garbage" {
            #expect(throws: QUICError.self, "the old file is gone") {
                try QUICIdentity.load(p12URL: p12, passphrase: "not-glassact")
            }
        }
        #expect(try QUICIdentity.fingerprint(of: QUICIdentity.load(p12URL: p12)) == freshFP,
                "the replacement is on disk, sealed with the current passphrase")
        let perms = try fm.attributesOfItem(atPath: p12.path)[.posixPermissions] as? Int
        #expect(perms == 0o600)
        #expect(try fm.contentsOfDirectory(atPath: dir.path) == ["identity.p12"], "no staging files left behind")
        let again = try QUICIdentity.loadOrCreate(directory: dir, name: "identity", commonName: "t")
        #expect(try QUICIdentity.fingerprint(of: again) == freshFP, "replaced once, then reused")
    }

    @Test func allowlistPersists() throws {
        let fm = FileManager.default
        let url = fm.temporaryDirectory.appendingPathComponent("glassact-allow-\(UInt64.random(in: 0...UInt64.max))")
        defer { try? fm.removeItem(at: url) }
        let fp = String(repeating: "ab", count: 32)
        let list = AuthorizedViewers(url: url)
        #expect(!list.contains(fp))
        try list.add("AB:" + String(repeating: "ab", count: 30) + "AB") // normalized on the way in
        #expect(throws: QUICError.self) { try list.add("not-a-fingerprint") }
        #expect(list.contains(fp))
        #expect(AuthorizedViewers(url: url).contains(fp), "approvals survive a relaunch")
        #expect(try fm.attributesOfItem(atPath: url.path)[.posixPermissions] as? Int == 0o600)
        try list.removeAll()
        #expect(!AuthorizedViewers(url: url).contains(fp))
    }

    /// In-process generation (no openssl): the container imports memory-only
    /// as an identity whose key is P-256 and whose certificate is valid for
    /// ~10 years. (Import itself proves the PKCS#12 MAC and PBES2 layers.)
    /// View-only approvals (offered for agents) survive a restart, and an
    /// upgrade to control replaces them.
    @Test func viewOnlyApprovalsPersist() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("av-\(UInt64.random(in: 0...UInt64.max))")
        defer { try? FileManager.default.removeItem(at: url) }
        let watcher = String(repeating: "ab", count: 32), driver = String(repeating: "cd", count: 32)
        let list = AuthorizedViewers(url: url)
        try list.add(watcher, viewOnly: true)
        try list.add(driver)
        let reloaded = AuthorizedViewers(url: url)
        #expect(reloaded.contains(watcher) && reloaded.isViewOnly(watcher))
        #expect(reloaded.contains(driver) && !reloaded.isViewOnly(driver))
        try reloaded.add(watcher, viewOnly: false)
        #expect(!AuthorizedViewers(url: url).isViewOnly(watcher))
        // What it is, its name and where it came from survive a restart;
        // forgetting one leaves the rest.
        try reloaded.add(driver, kind: .agent)
        reloaded.noteSeen(driver, kind: .agent, address: "100.64.0.7")
        reloaded.noteLabel(driver, label: "claude test/1")
        reloaded.noteSeen(watcher, kind: .viewer, address: "::1")
        let again = AuthorizedViewers(url: url)
        let agent = try #require(again.all.first { $0.fingerprint == driver })
        #expect(agent.kind == .agent && agent.label == "claude test/1" && agent.address == "100.64.0.7")
        #expect(agent.lastSeenAt != nil && agent.approvedAt != nil)
        #expect(again.all.first { $0.fingerprint == watcher }?.kind == .viewer)
        again.noteDevice(watcher, device: "Alex’s MacBook Air")
        try again.rename(watcher, to: "  Laptop  ")
        try again.setViewOnly(driver, true)
        let named = AuthorizedViewers(url: url)
        #expect(named.all.first { $0.fingerprint == watcher }.map { ($0.device, $0.name) }! == ("Alex’s MacBook Air", "Laptop"))
        #expect(named.isViewOnly(driver))
        #expect(try again.remove(driver))
        #expect(!(try again.remove(driver)))
        #expect(AuthorizedViewers(url: url).all.map(\.fingerprint) == [watcher])
        // Files written before scopes existed (one fingerprint per line) still mean control.
        try Data("\(driver)\n".utf8).write(to: url)
        #expect(AuthorizedViewers(url: url).contains(driver) && !AuthorizedViewers(url: url).isViewOnly(driver))
    }

    @Test func generatedIdentityIsP256() throws {
        let fm = FileManager.default
        let dir = fm.temporaryDirectory.appendingPathComponent("glassact-p256-\(UInt64.random(in: 0...UInt64.max))")
        defer { try? fm.removeItem(at: dir) }
        let identity = try QUICIdentity.loadOrCreate(directory: dir, name: "id", commonName: "glassact-test")
        var key: SecKey?
        #expect(SecIdentityCopyPrivateKey(identity, &key) == errSecSuccess)
        let attrs = key.flatMap { SecKeyCopyAttributes($0) as? [String: Any] } ?? [:]
        #expect(attrs[kSecAttrKeyType as String] as? String == kSecAttrKeyTypeECSECPrimeRandom as String)
        #expect(attrs[kSecAttrKeySizeInBits as String] as? Int == 256)
        var cert: SecCertificate?
        #expect(SecIdentityCopyCertificate(identity, &cert) == errSecSuccess)
        let summary = cert.flatMap { SecCertificateCopySubjectSummary($0) as String? }
        #expect(summary == "glassact-test")
        let notAfter = cert.flatMap { SecCertificateCopyNotValidAfterDate($0) as Date? }
        #expect(notAfter.map { $0.timeIntervalSinceNow > 9 * 365 * 86_400 } == true)
    }

    @Test func verificationCodeIsShortStableAndPairSpecific() {
        let h = String(repeating: "a1", count: 32)
        let v = String(repeating: "b2", count: 32)
        let w = String(repeating: "c3", count: 32)
        let code = QUICIdentity.verificationCode(hostFingerprint: h, viewerFingerprint: v)
        #expect(code.count == 19 && code.split(separator: "-").count == 4, "XXXX-XXXX-XXXX-XXXX")
        #expect(code.allSatisfy { $0 == "-" || "0123456789ABCDEFGHJKMNPQRSTVWXYZ".contains($0) })
        #expect(QUICIdentity.verificationCode(hostFingerprint: h.uppercased(), viewerFingerprint: v) == code,
                "fingerprint case/colons don't matter")
        #expect(QUICIdentity.verificationCode(hostFingerprint: h, viewerFingerprint: w) != code)
        #expect(QUICIdentity.verificationCode(hostFingerprint: v, viewerFingerprint: h) != code,
                "roles are part of the code")
    }

    @Test func knownHostsPersist() throws {
        let fm = FileManager.default
        let url = fm.temporaryDirectory.appendingPathComponent("glassact-known-\(UInt64.random(in: 0...UInt64.max))")
        defer { try? fm.removeItem(at: url) }
        let fp = String(repeating: "cd", count: 32)
        let hosts = KnownHosts(url: url)
        #expect(hosts.fingerprint(host: "Mac.local", port: 4433) == nil)
        try hosts.remember(host: "Mac.local", port: 4433, fingerprint: fp)
        #expect(KnownHosts(url: url).fingerprint(host: "mac.local", port: 4433) == fp)
        #expect(KnownHosts(url: url).fingerprint(host: "mac.local", port: 4434) == nil, "per host:port")
        #expect(try fm.attributesOfItem(atPath: url.path)[.posixPermissions] as? Int == 0o600)
        try hosts.forget(host: "mac.local", port: 4433)
        #expect(KnownHosts(url: url).fingerprint(host: "mac.local", port: 4433) == nil)
    }

    @Test func knownHostsListAndForgetByKey() throws {
        let fm = FileManager.default
        let url = fm.temporaryDirectory.appendingPathComponent("glassact-known-\(UInt64.random(in: 0...UInt64.max))")
        defer { try? fm.removeItem(at: url) }
        let hosts = KnownHosts(url: url)
        try hosts.remember(host: "b.local", port: 4433, fingerprint: String(repeating: "ab", count: 32))
        try hosts.remember(host: "A.local", port: 4433, fingerprint: String(repeating: "cd", count: 32))
        #expect(hosts.all.map(\.key) == ["a.local:4433", "b.local:4433"], "sorted, lowercased keys")
        try hosts.forget(key: "a.local:4433")
        #expect(KnownHosts(url: url).all.map(\.key) == ["b.local:4433"])
    }

    /// Trust on first use: no pin → the dial succeeds and reports the key the
    /// host presented, for the caller to remember.
    @Test func unpinnedDialTrustsOnFirstUseAndReportsTheKey() throws {
        let (hostID, hostFP) = try QUICLoopbackTests.makeTestIdentity()
        var clientRef: QUICTransport?
        let session = try QUICLoopbackTests.makeSession(
            fingerprint: "", identity: hostID,
            configureHost: { _ in }, configureClient: { clientRef = $0 })
        #expect(session != nil, "an unpinned dial must connect")
        #expect(clientRef?.observedHostFingerprint == hostFP)
        session?.client.cancel()
        session?.server.cancel()
    }

    /// A pinned host presenting another key is refused — and the key it
    /// presented is reported, so the app can say "host key changed" instead
    /// of retrying forever.
    @Test func changedHostKeyIsRefusedAndReported() throws {
        let (hostID, hostFP) = try QUICLoopbackTests.makeTestIdentity()
        var clientRef: QUICTransport?
        let stale = String(repeating: "ee", count: 32)
        let session = try QUICLoopbackTests.makeSession(
            fingerprint: stale, identity: hostID,
            configureHost: { _ in }, configureClient: { clientRef = $0 })
        #expect(session == nil)
        #expect(clientRef?.observedHostFingerprint == hostFP)
    }
}
