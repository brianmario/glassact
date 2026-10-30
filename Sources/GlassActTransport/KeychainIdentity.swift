import CryptoKit
public import Foundation
public import Security

/// The Host's and Viewer's TLS identities in the data protection keychain
/// (§13), in the app's own keychain access group:
///
/// - The private key is made in the **Secure Enclave** when the Mac has one
///   (every Apple silicon Mac, Intel Macs with a T2). It never exists outside
///   it: it can't be exported or copied to another Mac, even by code running
///   as the user. Elsewhere it's a software key in the keychain.
/// - **Device-bound:** `…ThisDeviceOnly`, never synchronized. Each Mac has its
///   own identity, so one can be revoked without the others.
/// - **No prompts:** the access group (`keychain-access-groups`, from the
///   team's provisioning profile) admits every build signed by the team,
///   Debug and Release alike, so rebuilding never asks for permission.
///
/// A build without the entitlement (no signing team, or signed ad hoc) can't
/// reach this keychain: `loadOrCreate` throws `.unavailable` and the app
/// falls back to the file identity (`QUICIdentity.loadOrCreate`). The CLI
/// always uses the file identity: a bare executable can't carry a
/// provisioning profile.
public enum KeychainIdentity {
    public enum Storage: String, Sendable {
        case secureEnclave = "Secure Enclave"
        case keychain = "keychain"
    }

    public enum Failure: Error, Equatable {
        /// This build isn't entitled to the data protection keychain.
        case unavailable
        /// The keychain refused an operation (OSStatus).
        case keychain(OSStatus)
        case certificate
    }

    /// The app's keychain access group: the first entry of its
    /// `keychain-access-groups` entitlement, or nil when it has none.
    public static var appAccessGroup: String? {
        #if os(macOS)
        guard let task = SecTaskCreateFromSelf(nil),
              let value = SecTaskCopyValueForEntitlement(task, "keychain-access-groups" as CFString, nil),
              let groups = value as? [String] else { return nil }
        return groups.first
        #else
        defaultAccessGroup
        #endif
    }

    #if !os(macOS)
    /// iPadOS can't read its own entitlements, but every app has a keychain
    /// group of its own (team ID + bundle ID), where an item lands when it
    /// names none: add one and read back where it went.
    private static var defaultAccessGroup: String? {
        let probe: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: "Glass Act access group probe",
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ]
        SecItemDelete(probe as CFDictionary)
        var result: CFTypeRef?
        var add = probe
        add[kSecReturnAttributes as String] = true
        guard SecItemAdd(add as CFDictionary, &result) == errSecSuccess else { return nil }
        SecItemDelete(probe as CFDictionary)
        return (result as? [String: Any])?[kSecAttrAccessGroup as String] as? String
    }
    #endif

    /// This device's identity for `name` in `accessGroup`, made on first use.
    /// The key's storage tells where it ended up.
    public static func loadOrCreate(accessGroup: String, name: String,
                                    commonName: String) throws -> (identity: SecIdentity, storage: Storage) {
        let label = Self.label(name)
        if let existing = try find(accessGroup: accessGroup, label: label) { return existing }
        // A half-made identity (a key whose certificate never landed) would
        // shadow the new one: clear the label first.
        delete(accessGroup: accessGroup, name: name)
        let (key, storage) = try makeKey(accessGroup: accessGroup, label: label)
        guard let publicKey = SecKeyCopyPublicKey(key),
              let point = SecKeyCopyExternalRepresentation(publicKey, nil) as Data? else {
            throw Failure.certificate
        }
        let der = try SelfSignedIdentity.makeCertificate(publicKey: point, commonName: commonName,
                                                         validFor: 3650, now: Date()) { tbs in
            let digest = Data(SHA256.hash(data: Data(tbs)))
            var error: Unmanaged<CFError>?
            guard let signature = SecKeyCreateSignature(key, .ecdsaSignatureDigestX962SHA256,
                                                        digest as CFData, &error) as Data? else {
                throw error?.takeRetainedValue() ?? Failure.certificate
            }
            return signature
        }
        guard let certificate = SecCertificateCreateWithData(nil, Data(der) as CFData) else {
            throw Failure.certificate
        }
        let status = SecItemAdd([
            kSecClass as String: kSecClassCertificate,
            kSecValueRef as String: certificate,
            kSecAttrLabel as String: label,
            kSecAttrAccessGroup as String: accessGroup,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
            kSecUseDataProtectionKeychain as String: true,
        ] as CFDictionary, nil)
        guard status == errSecSuccess else { throw failure(status) }
        guard let made = try find(accessGroup: accessGroup, label: label) else { throw Failure.certificate }
        return (made.identity, storage)
    }

    /// Removes `name`'s key and certificate (Forget This Mac's Key, tests).
    public static func delete(accessGroup: String, name: String) {
        for itemClass in [kSecClassCertificate, kSecClassKey] {
            SecItemDelete([
                kSecClass as String: itemClass,
                kSecAttrLabel as String: label(name),
                kSecAttrAccessGroup as String: accessGroup,
                kSecUseDataProtectionKeychain as String: true,
            ] as CFDictionary)
        }
    }

    static func label(_ name: String) -> String { "Glass Act \(name) identity" }

    private static func find(accessGroup: String, label: String) throws -> (identity: SecIdentity, storage: Storage)? {
        var result: CFTypeRef?
        let status = SecItemCopyMatching([
            kSecClass as String: kSecClassIdentity,
            kSecAttrLabel as String: label,
            kSecAttrAccessGroup as String: accessGroup,
            kSecUseDataProtectionKeychain as String: true,
            kSecReturnRef as String: true,
        ] as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let result else { throw failure(status) }
        let identity = result as! SecIdentity // CF type: the cast cannot fail
        var key: SecKey?
        SecIdentityCopyPrivateKey(identity, &key)
        let token = key.flatMap { SecKeyCopyAttributes($0) as? [String: Any] }?[kSecAttrTokenID as String] as? String
        return (identity, token == (kSecAttrTokenIDSecureEnclave as String) ? .secureEnclave : .keychain)
    }

    /// A P-256 key: in the Secure Enclave if there is one, else in software.
    private static func makeKey(accessGroup: String, label: String) throws -> (SecKey, Storage) {
        func attributes(secureEnclave: Bool) -> [String: Any] {
            var attrs: [String: Any] = [
                kSecAttrKeyType as String: kSecAttrKeyTypeECSECPrimeRandom,
                kSecAttrKeySizeInBits as String: 256,
                kSecUseDataProtectionKeychain as String: true,
                kSecPrivateKeyAttrs as String: [
                    kSecAttrIsPermanent as String: true,
                    kSecAttrLabel as String: label,
                    kSecAttrAccessGroup as String: accessGroup,
                    kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
                ] as [String: Any],
            ]
            if secureEnclave { attrs[kSecAttrTokenID as String] = kSecAttrTokenIDSecureEnclave }
            return attrs
        }
        var error: Unmanaged<CFError>?
        if let key = SecKeyCreateRandomKey(attributes(secureEnclave: true) as CFDictionary, &error) {
            return (key, .secureEnclave)
        }
        let enclaveError = error?.takeRetainedValue()
        if let code = enclaveError.map({ CFErrorGetCode($0) }), code == Int(errSecMissingEntitlement) {
            throw Failure.unavailable
        }
        // No Secure Enclave here (an older Intel Mac, a VM).
        error = nil
        if let key = SecKeyCreateRandomKey(attributes(secureEnclave: false) as CFDictionary, &error) {
            return (key, .keychain)
        }
        let code = error.map { OSStatus(CFErrorGetCode($0.takeRetainedValue())) } ?? errSecInternalError
        throw failure(code)
    }

    private static func failure(_ status: OSStatus) -> Failure {
        status == errSecMissingEntitlement ? .unavailable : .keychain(status)
    }
}

extension QUICIdentity {
    /// Where an app's identity came from.
    public enum Source: Sendable, Equatable {
        case keychain(KeychainIdentity.Storage)
        /// A file in the data directory: a build without the keychain
        /// entitlement (no signing team).
        case file(reason: String)

        public var description: String {
            switch self {
            case .keychain(let storage): "key in the \(storage.rawValue)"
            case .file(let reason): "key in a file (\(reason))"
            }
        }
    }

    /// The Host's or Viewer's identity: in the keychain when this build can
    /// reach it, else the file `<directory>/<name>.p12`. Once the keychain
    /// holds the identity, a leftover file key is deleted: nothing should
    /// still read it, and a private key shouldn't sit on disk unused.
    public static func loadForApp(directory: URL, name: String, commonName: String) throws
        -> (identity: SecIdentity, source: Source) {
        let fileKey = directory.appendingPathComponent("\(name).p12")
        guard let group = KeychainIdentity.appAccessGroup else {
            return (try loadOrCreate(directory: directory, name: name, commonName: commonName),
                    .file(reason: "this build has no keychain entitlement"))
        }
        // Only "not entitled" falls back. Any other keychain failure is
        // thrown: quietly switching to a file key would change this Mac's
        // identity, and every peer would refuse it as a changed key.
        do {
            let (identity, storage) = try KeychainIdentity.loadOrCreate(accessGroup: group, name: name,
                                                                        commonName: commonName)
            try? FileManager.default.removeItem(at: fileKey)
            return (identity, .keychain(storage))
        } catch KeychainIdentity.Failure.unavailable {
            return (try loadOrCreate(directory: directory, name: name, commonName: commonName),
                    .file(reason: "this build can't reach the keychain"))
        }
    }
}
