import CryptoKit
import Foundation
import Security
import Testing
@testable import GlassActTransport

/// Key IDs are public-key (SPKI) hashes, with a short checksummed string
/// form (§13). And the keychain identity, as far as an unsigned test run
/// can reach it: not at all, so it must fall back to the file cleanly.
@Suite struct KeyIdentityTests {
    // MARK: - Key strings

    /// Vectors from the BIP-173 reference implementation (Python), hrp "ga".
    @Test(arguments: [
        (String(repeating: "00", count: 32), "ga1qqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqq0n2kjg"),
        ((0..<32).map { String(format: "%02x", $0) }.joined(),
         "ga1qqqsyqcyq5rqwzqfpg9scrgwpugpzysnzs23v9ccrydpk8qarc0sx8p5j3"),
        ("e6c92d22cb33" + String(repeating: "ab", count: 26),
         "ga1umyj6gktxw46h2at4w46h2at4w46h2at4w46h2at4w46h2at4w4s02gprj"),
    ])
    func keyStringMatchesTheReference(hex: String, key: String) {
        #expect(QUICIdentity.keyString(hex) == key)
        #expect(QUICIdentity.normalize(key) == hex)
        #expect(QUICIdentity.normalize(key.uppercased()) == hex, "case-insensitive")
        #expect(QUICIdentity.normalize("  \(key)\n") == hex, "pasted with whitespace")
    }

    @Test func anyOneCharacterTypoFailsTheChecksum() {
        let key = "ga1umyj6gktxw46h2at4w46h2at4w46h2at4w46h2at4w46h2at4w4s02gprj"
        let charset = Array("qpzry9x8gf2tvdw0s3jn54khce6mua7l")
        var chars = Array(key)
        for i in 3..<chars.count {
            let original = chars[i]
            for c in charset where c != original {
                chars[i] = c
                #expect(KeyString.decode(String(chars)) == nil, "typo at \(i) must not name another key")
            }
            chars[i] = original
        }
        #expect(KeyString.decode(key) != nil)
        #expect(KeyString.decode(String(key.dropLast())) == nil, "truncated")
        #expect(KeyString.decode("gb1" + key.dropFirst(3)) == nil, "another prefix")
    }

    @Test func hexStillWorksEverywhere() throws {
        let hex = (0..<32).map { String(format: "%02x", ($0 * 7) & 0xff) }.joined()
        let colons = stride(from: 0, to: 64, by: 2).map { i -> String in
            let lo = hex.index(hex.startIndex, offsetBy: i)
            return String(hex[lo..<hex.index(lo, offsetBy: 2)])
        }.joined(separator: ":").uppercased()
        #expect(QUICIdentity.normalize(colons) == hex)
        #expect(QUICIdentity.keyString(colons) == QUICIdentity.keyString(hex))
        #expect(QUICIdentity.keyString("not a key") == "not a key", "non-keys pass through")
        #expect(QUICIdentity.abbreviatedKeyString(hex).hasPrefix("ga1"))
    }

    @Test func approvalsAcceptKeyStrings() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let hex = String(repeating: "5a", count: 32)
        let list = AuthorizedViewers(url: dir.appendingPathComponent(IdentityFiles.approvedViewers))
        try list.add(QUICIdentity.keyString(hex))
        #expect(list.contains(hex))
        #expect(list.contains(QUICIdentity.keyString(hex)))
        #expect(list.all.map(\.fingerprint) == [hex], "stored as hex")
    }

    // MARK: - SPKI key IDs

    @Test func keyIDIsTheSPKIHashNotTheCertificateHash() throws {
        let key = P256.Signing.PrivateKey()
        let der = try SelfSignedIdentity.makeCertificate(key: key, commonName: "t", validFor: 30, now: Date())
        let cert = try #require(SecCertificateCreateWithData(nil, Data(der) as CFData))
        let spki = SHA256.hash(data: key.publicKey.derRepresentation).map { String(format: "%02x", $0) }.joined()
        let whole = SHA256.hash(data: Data(der)).map { String(format: "%02x", $0) }.joined()
        #expect(QUICIdentity.fingerprint(of: cert) == spki, "the standard SPKI pin")
        #expect(QUICIdentity.fingerprint(of: cert) != whole)
        #expect(QUICIdentity.fingerprint(p256PublicKey: key.publicKey.x963Representation) == spki)
    }

    @Test func aReissuedCertificateKeepsTheKeyID() throws {
        let key = P256.Signing.PrivateKey()
        let first = try SelfSignedIdentity.makeCertificate(key: key, commonName: "a", validFor: 30, now: Date())
        let second = try SelfSignedIdentity.makeCertificate(key: key, commonName: "b", validFor: 3650,
                                                            now: Date().addingTimeInterval(86_400))
        #expect(first != second, "different certificates")
        let c1 = try #require(SecCertificateCreateWithData(nil, Data(first) as CFData))
        let c2 = try #require(SecCertificateCreateWithData(nil, Data(second) as CFData))
        #expect(QUICIdentity.fingerprint(of: c1) == QUICIdentity.fingerprint(of: c2), "same device")
        let other = try SelfSignedIdentity.makeCertificate(key: P256.Signing.PrivateKey(), commonName: "a",
                                                           validFor: 30, now: Date())
        let c3 = try #require(SecCertificateCreateWithData(nil, Data(other) as CFData))
        #expect(QUICIdentity.fingerprint(of: c3) != QUICIdentity.fingerprint(of: c1))
    }

    @Test func certificatesSignedThroughAClosureVerify() throws {
        // The keychain path signs with a key it can't hold: same certificate shape.
        let key = P256.Signing.PrivateKey()
        let der = try SelfSignedIdentity.makeCertificate(publicKey: key.publicKey.x963Representation,
                                                         commonName: "closure", validFor: 30, now: Date()) {
            try key.signature(for: Data($0)).derRepresentation
        }
        let cert = try #require(SecCertificateCreateWithData(nil, Data(der) as CFData))
        let trust = try #require({ () -> SecTrust? in
            var t: SecTrust?
            SecTrustCreateWithCertificates(cert, SecPolicyCreateBasicX509(), &t)
            return t
        }())
        SecTrustSetAnchorCertificates(trust, [cert] as CFArray)
        #expect(SecTrustEvaluateWithError(trust, nil), "self-signature verifies")
    }

    // MARK: - Keychain identity (unentitled here)

    @Test func anUnentitledBuildFallsBackToTheFile() throws {
        #expect(KeychainIdentity.appAccessGroup == nil, "the test runner has no keychain entitlement")
        #expect(throws: KeychainIdentity.Failure.unavailable) {
            _ = try KeychainIdentity.loadOrCreate(accessGroup: "ABCDE12345.app.glassact.test", name: "test",
                                                  commonName: "test")
        }
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let (identity, source) = try QUICIdentity.loadForApp(directory: dir, name: "app-identity", commonName: "t")
        guard case .file = source else {
            Issue.record("expected the file fallback, got \(source)")
            return
        }
        let again = try QUICIdentity.loadForApp(directory: dir, name: "app-identity", commonName: "t")
        #expect(try QUICIdentity.fingerprint(of: again.identity) == QUICIdentity.fingerprint(of: identity),
                "the same file key next launch")
    }
}
