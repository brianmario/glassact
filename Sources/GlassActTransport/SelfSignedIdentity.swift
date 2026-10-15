import CommonCrypto
import CryptoKit
import Foundation
import Security

/// In-process generation of a self-signed TLS identity — a P-256 key
/// (CryptoKit) and an X.509 v3 certificate — packaged as PKCS#12 so the
/// Security framework can import it memory-only as a `SecIdentity`. (A
/// keychain-free SecIdentity can only be made by importing a PKCS#12
/// container; the direct constructor is SPI.) No /usr/bin/openssl
/// subprocess.
///
/// Only what TLS with fingerprint pinning needs: no chain, no extensions.
/// Peers trust the SHA-256 of the certificate DER, never the CA fields.
enum SelfSignedIdentity {
    /// PKCS#12 bytes for a fresh key + self-signed certificate. The key is
    /// in a PBES2-encrypted (PBKDF2-HMAC-SHA256 / AES-256-CBC) shrouded bag:
    /// with the published container passphrase that protects nothing (the
    /// file mode does), but SecPKCS12Import only pairs a key with its
    /// certificate into an identity from a shrouded bag — a plain key bag
    /// imports "successfully" with no identity (measured).
    static func makePKCS12(commonName: String, passphrase: String,
                           validFor days: Int = 3650, now: Date = Date()) throws -> Data {
        let key = P256.Signing.PrivateKey()
        let certificate = try makeCertificate(key: key, commonName: commonName, validFor: days, now: now)
        return try pkcs12(privateKeyPKCS8: key.derRepresentation, certificate: certificate,
                          friendlyName: commonName, passphrase: passphrase)
    }

    // MARK: - X.509

    static func makeCertificate(key: P256.Signing.PrivateKey, commonName: String,
                                validFor days: Int, now: Date) throws -> [UInt8] {
        var serial = [UInt8](repeating: 0, count: 16)
        for i in serial.indices { serial[i] = UInt8.random(in: 0...255) }
        serial[0] &= 0x7F // positive
        if serial[0] == 0 { serial[0] = 1 } // minimal encoding: no leading zero
        let name = DER.sequence([
            DER.set([DER.sequence([DER.oid(OID.commonName), DER.utf8String(commonName)])]),
        ])
        let signatureAlgorithm = DER.sequence([DER.oid(OID.ecdsaWithSHA256)])
        let spki = DER.sequence([
            DER.sequence([DER.oid(OID.ecPublicKey), DER.oid(OID.prime256v1)]),
            DER.bitString([UInt8](key.publicKey.x963Representation)),
        ])
        let notBefore = now.addingTimeInterval(-86_400) // tolerate clock skew
        let notAfter = now.addingTimeInterval(TimeInterval(days) * 86_400)
        let tbs = DER.sequence([
            DER.explicit(0, DER.integer([2])), // v3
            DER.integer(serial),
            signatureAlgorithm,
            name,
            DER.sequence([DER.time(notBefore), DER.time(notAfter)]),
            name,
            spki,
        ])
        let signature = try key.signature(for: Data(tbs)).derRepresentation
        return DER.sequence([tbs, signatureAlgorithm, DER.bitString([UInt8](signature))])
    }

    // MARK: - PKCS#12 (RFC 7292)

    static func pkcs12(privateKeyPKCS8: Data, certificate: [UInt8],
                       friendlyName: String, passphrase: String) throws -> Data {
        let localKeyID = [UInt8](SHA256.hash(data: Data(certificate)).prefix(20))
        let attributes = DER.set([
            DER.sequence([DER.oid(OID.friendlyName), DER.set([DER.bmpString(friendlyName)])]),
            DER.sequence([DER.oid(OID.localKeyID), DER.set([DER.octetString(localKeyID)])]),
        ])
        let keyBag = DER.sequence([
            DER.oid(OID.pkcs8ShroudedKeyBag),
            DER.explicit(0, try encryptPBES2(Array(privateKeyPKCS8), passphrase: passphrase)),
            attributes,
        ])
        let certBag = DER.sequence([
            DER.oid(OID.certBag),
            DER.explicit(0, DER.sequence([
                DER.oid(OID.x509Certificate),
                DER.explicit(0, DER.octetString(certificate)),
            ])),
            attributes,
        ])
        func dataContentInfo(_ content: [UInt8]) -> [UInt8] {
            DER.sequence([DER.oid(OID.pkcs7Data), DER.explicit(0, DER.octetString(content))])
        }
        let authenticatedSafe = DER.sequence([
            dataContentInfo(DER.sequence([certBag])),
            dataContentInfo(DER.sequence([keyBag])),
        ])
        var salt = [UInt8](repeating: 0, count: 16)
        guard SecRandomCopyBytes(kSecRandomDefault, salt.count, &salt) == errSecSuccess else {
            throw QUICError.identityImportFailed
        }
        let iterations = 2048
        let macKey = pkcs12KDF(password: passphrase, salt: salt, id: 3, iterations: iterations, length: 32)
        let mac = HMAC<SHA256>.authenticationCode(for: authenticatedSafe, using: SymmetricKey(data: macKey))
        let macData = DER.sequence([
            DER.sequence([
                DER.sequence([DER.oid(OID.sha256), DER.null()]),
                DER.octetString([UInt8](mac)),
            ]),
            DER.octetString(salt),
            DER.integer(minimal: iterations),
        ])
        return Data(DER.sequence([
            DER.integer([3]),
            dataContentInfo(authenticatedSafe),
            macData,
        ]))
    }

    /// EncryptedPrivateKeyInfo, PBES2 (RFC 8018): PBKDF2-HMAC-SHA256 →
    /// AES-256-CBC. PKCS#12 feeds PBES2 the passphrase as UTF-8 bytes.
    static func encryptPBES2(_ plaintext: [UInt8], passphrase: String,
                             iterations: Int = 2048) throws -> [UInt8] {
        var salt = [UInt8](repeating: 0, count: 16)
        var iv = [UInt8](repeating: 0, count: 16)
        guard SecRandomCopyBytes(kSecRandomDefault, salt.count, &salt) == errSecSuccess,
              SecRandomCopyBytes(kSecRandomDefault, iv.count, &iv) == errSecSuccess else {
            throw QUICError.identityImportFailed
        }
        let password = Array(passphrase.utf8)
        var key = [UInt8](repeating: 0, count: kCCKeySizeAES256)
        let derived = password.withUnsafeBufferPointer { pw in
            CCKeyDerivationPBKDF(CCPBKDFAlgorithm(kCCPBKDF2),
                                 pw.baseAddress.map { UnsafeRawPointer($0).assumingMemoryBound(to: CChar.self) },
                                 pw.count, salt, salt.count,
                                 CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256), UInt32(iterations),
                                 &key, key.count)
        }
        guard derived == kCCSuccess else { throw QUICError.identityImportFailed }
        var ciphertext = [UInt8](repeating: 0, count: plaintext.count + kCCBlockSizeAES128)
        var written = 0
        let status = CCCrypt(CCOperation(kCCEncrypt), CCAlgorithm(kCCAlgorithmAES),
                             CCOptions(kCCOptionPKCS7Padding), key, key.count, iv,
                             plaintext, plaintext.count, &ciphertext, ciphertext.count, &written)
        guard status == kCCSuccess else { throw QUICError.identityImportFailed }
        let algorithm = DER.sequence([
            DER.oid(OID.pbes2),
            DER.sequence([
                DER.sequence([
                    DER.oid(OID.pbkdf2),
                    DER.sequence([
                        DER.octetString(salt),
                        DER.integer(minimal: iterations),
                        DER.sequence([DER.oid(OID.hmacWithSHA256), DER.null()]),
                    ]),
                ]),
                DER.sequence([DER.oid(OID.aes256CBC), DER.octetString(iv)]),
            ]),
        ])
        return DER.sequence([algorithm, DER.octetString(Array(ciphertext.prefix(written)))])
    }

    /// RFC 7292 Appendix B.2 key derivation, SHA-256 (u = 32, v = 64).
    static func pkcs12KDF(password: String, salt: [UInt8], id: UInt8,
                          iterations: Int, length: Int) -> [UInt8] {
        let u = 32, v = 64
        var pw: [UInt8] = []
        for unit in password.utf16 { pw.append(UInt8(unit >> 8)); pw.append(UInt8(unit & 0xFF)) }
        pw += [0, 0] // BMPString, NUL-terminated
        func stretch(_ bytes: [UInt8]) -> [UInt8] {
            guard !bytes.isEmpty else { return [] }
            let n = v * ((bytes.count + v - 1) / v)
            return (0..<n).map { bytes[$0 % bytes.count] }
        }
        let d = [UInt8](repeating: id, count: v)
        var i = stretch(salt) + stretch(pw)
        var out: [UInt8] = []
        while out.count < length {
            var a = [UInt8](SHA256.hash(data: Data(d + i)))
            for _ in 1..<iterations { a = [UInt8](SHA256.hash(data: Data(a))) }
            out += a
            guard out.count < length else { break }
            let b = (0..<v).map { a[$0 % u] }
            for block in stride(from: 0, to: i.count, by: v) { // I_j = (I_j + B + 1) mod 2^(8v)
                var carry = 1
                for k in stride(from: v - 1, through: 0, by: -1) {
                    let sum = Int(i[block + k]) + Int(b[k]) + carry
                    i[block + k] = UInt8(sum & 0xFF)
                    carry = sum >> 8
                }
            }
        }
        return Array(out.prefix(length))
    }
}

// MARK: - OIDs

private enum OID {
    static let commonName = "2.5.4.3"
    static let ecPublicKey = "1.2.840.10045.2.1"
    static let prime256v1 = "1.2.840.10045.3.1.7"
    static let ecdsaWithSHA256 = "1.2.840.10045.4.3.2"
    static let sha256 = "2.16.840.1.101.3.4.2.1"
    static let pkcs7Data = "1.2.840.113549.1.7.1"
    static let pkcs8ShroudedKeyBag = "1.2.840.113549.1.12.10.1.2"
    static let pbes2 = "1.2.840.113549.1.5.13"
    static let pbkdf2 = "1.2.840.113549.1.5.12"
    static let hmacWithSHA256 = "1.2.840.113549.2.9"
    static let aes256CBC = "2.16.840.1.101.3.4.1.42"
    static let certBag = "1.2.840.113549.1.12.10.1.3"
    static let x509Certificate = "1.2.840.113549.1.9.22.1"
    static let friendlyName = "1.2.840.113549.1.9.20"
    static let localKeyID = "1.2.840.113549.1.9.21"
}

// MARK: - Minimal DER encoder

enum DER {
    static func tlv(_ tag: UInt8, _ value: [UInt8]) -> [UInt8] {
        var out = [tag]
        let n = value.count
        if n < 0x80 {
            out.append(UInt8(n))
        } else {
            var len: [UInt8] = []
            var m = n
            while m > 0 { len.insert(UInt8(m & 0xFF), at: 0); m >>= 8 }
            out.append(0x80 | UInt8(len.count))
            out += len
        }
        return out + value
    }

    static func sequence(_ items: [[UInt8]]) -> [UInt8] { tlv(0x30, items.flatMap { $0 }) }
    static func set(_ items: [[UInt8]]) -> [UInt8] { tlv(0x31, items.flatMap { $0 }) }
    static func octetString(_ bytes: [UInt8]) -> [UInt8] { tlv(0x04, bytes) }
    static func bitString(_ bytes: [UInt8]) -> [UInt8] { tlv(0x03, [0] + bytes) }
    static func null() -> [UInt8] { [0x05, 0x00] }
    static func utf8String(_ s: String) -> [UInt8] { tlv(0x0C, Array(s.utf8)) }
    static func explicit(_ tag: UInt8, _ inner: [UInt8]) -> [UInt8] { tlv(0xA0 | tag, inner) }

    static func bmpString(_ s: String) -> [UInt8] {
        var bytes: [UInt8] = []
        for unit in s.utf16 { bytes.append(UInt8(unit >> 8)); bytes.append(UInt8(unit & 0xFF)) }
        return tlv(0x1E, bytes)
    }

    /// Big-endian magnitude, already minimal and positive.
    static func integer(_ magnitude: [UInt8]) -> [UInt8] {
        var v = magnitude
        while v.count > 1 && v[0] == 0 && v[1] & 0x80 == 0 { v.removeFirst() }
        if let first = v.first, first & 0x80 != 0 { v.insert(0, at: 0) }
        return tlv(0x02, v.isEmpty ? [0] : v)
    }

    static func integer(minimal value: Int) -> [UInt8] {
        var bytes: [UInt8] = []
        var m = value
        repeat { bytes.insert(UInt8(m & 0xFF), at: 0); m >>= 8 } while m > 0
        return integer(bytes)
    }

    static func oid(_ dotted: String) -> [UInt8] {
        let arcs = dotted.split(separator: ".").map { Int($0)! } // static tables only
        var body = [UInt8(arcs[0] * 40 + arcs[1])]
        for arc in arcs.dropFirst(2) {
            var chunk = [UInt8(arc & 0x7F)]
            var m = arc >> 7
            while m > 0 { chunk.insert(UInt8(0x80 | (m & 0x7F)), at: 0); m >>= 7 }
            body += chunk
        }
        return tlv(0x06, body)
    }

    /// UTCTime through 2049, GeneralizedTime from 2050 (RFC 5280 §4.1.2.5).
    static func time(_ date: Date) -> [UInt8] {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let c = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
        let year = c.year!
        let rest = String(format: "%02d%02d%02d%02d%02dZ", c.month!, c.day!, c.hour!, c.minute!, c.second!)
        return year < 2050
            ? tlv(0x17, Array((String(format: "%02d", year % 100) + rest).utf8))
            : tlv(0x18, Array((String(format: "%04d", year) + rest).utf8))
    }
}
