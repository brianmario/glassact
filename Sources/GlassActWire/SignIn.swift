/// §3.9 — the sign-in exchange. It runs on its own QUIC connection under the
/// `glassact-signin` ALPN, never inside a session: the viewer opens one
/// stream, sends one request, finishes its side, and the host answers with
/// one response and closes. Unknown keys reach the host only this way (the
/// session ALPN refuses them during the TLS handshake), so the parser is
/// strict and every field is bounded (INV-6).
public enum SignInVersion {
    public static let current: UInt8 = 1
}

/// Viewer → host.
public struct SignInRequest: Equatable, Sendable {
    public enum Op: UInt8, Sendable {
        /// What does this host do with a new viewer? Carries no credentials.
        case query = 1
        /// Approve this connection's key if `user`/`password` are the
        /// host's account.
        case signIn = 2
    }

    public static let maxUserBytes = 255
    public static let maxPasswordBytes = 1024
    public static let maxDeviceBytes = 64
    /// The largest valid encoding — what a receiver reads at most.
    public static let maxEncodedBytes = 1 + 1 + (1 + maxUserBytes) + (2 + maxPasswordBytes) + (1 + maxDeviceBytes)

    public var op: Op
    public var user: String
    public var password: String
    /// The viewer machine's name, for the host's Approved Viewers list.
    public var device: String

    public init(op: Op, user: String = "", password: String = "", device: String = "") {
        self.op = op
        self.user = user
        self.password = password
        self.device = device
    }

    /// `ver u8 | op u8 | userLen u8, user | passwordLen u16, password | deviceLen u8, device`
    /// (UTF-8). Fields over their limits are truncated at a character boundary.
    public func encoded() -> [UInt8] {
        var w = ByteWriter(reserving: 64)
        w.writeU8(SignInVersion.current)
        w.writeU8(op.rawValue)
        let user = Array(user.utf8Prefix(Self.maxUserBytes).utf8)
        let password = Array(password.utf8Prefix(Self.maxPasswordBytes).utf8)
        let device = Array(device.utf8Prefix(Self.maxDeviceBytes).utf8)
        w.writeU8(UInt8(user.count))
        w.writeBytes(user)
        w.writeU16(UInt16(password.count))
        w.writeBytes(password)
        w.writeU8(UInt8(device.count))
        w.writeBytes(device)
        return w.bytes
    }

    /// Nil on anything malformed: wrong version, unknown op, a field out of
    /// bounds, invalid UTF-8, trailing bytes, or credentials on a query.
    public static func parse(_ bytes: [UInt8]) -> SignInRequest? {
        guard bytes.count <= maxEncodedBytes else { return nil }
        return bytes.withUnsafeBytes { buf -> SignInRequest? in
            var r = unsafe ByteReader(buf)
            guard r.readU8() == SignInVersion.current,
                  let rawOp = r.readU8(), let op = Op(rawValue: rawOp),
                  let userLen = r.readU8(),
                  let user = r.readString(length: Int(userLen), max: maxUserBytes),
                  let passwordLen = r.readU16(),
                  let password = r.readString(length: Int(passwordLen), max: maxPasswordBytes),
                  let deviceLen = r.readU8(),
                  let device = r.readString(length: Int(deviceLen), max: maxDeviceBytes),
                  r.remaining == 0 else { return nil }
            if op == .query, !user.isEmpty || !password.isEmpty { return nil }
            return SignInRequest(op: op, user: user, password: password, device: device)
        }
    }
}

/// Host → viewer.
public struct SignInResponse: Equatable, Sendable {
    public enum Status: UInt8, Sendable {
        /// (query) New viewers sign in with this Mac's account.
        case signInAvailable = 1
        /// (query) The host's user approves new viewers by hand: dial the
        /// session as usual and wait while they decide.
        case askOnHost = 2
        /// This host isn't taking new viewers.
        case closed = 3
        /// This connection's key is approved (just now, or already).
        case approved = 4
        case wrongCredentials = 5
        /// Too many failures: try again in `retryAfterSeconds`.
        case tooManyAttempts = 6
    }

    public static let encodedBytes = 4

    public var status: Status
    public var retryAfterSeconds: UInt16

    public init(_ status: Status, retryAfterSeconds: UInt16 = 0) {
        self.status = status
        self.retryAfterSeconds = retryAfterSeconds
    }

    /// `ver u8 | status u8 | retryAfterS u16`
    public func encoded() -> [UInt8] {
        var w = ByteWriter(reserving: Self.encodedBytes)
        w.writeU8(SignInVersion.current)
        w.writeU8(status.rawValue)
        w.writeU16(retryAfterSeconds)
        return w.bytes
    }

    public static func parse(_ bytes: [UInt8]) -> SignInResponse? {
        guard bytes.count == encodedBytes else { return nil }
        return bytes.withUnsafeBytes { buf -> SignInResponse? in
            var r = unsafe ByteReader(buf)
            guard r.readU8() == SignInVersion.current,
                  let raw = r.readU8(), let status = Status(rawValue: raw),
                  let retry = r.readU16() else { return nil }
            return SignInResponse(status, retryAfterSeconds: retry)
        }
    }
}

extension ByteReader {
    /// `length` bytes of valid UTF-8, nil if `length > max` or the bytes run out.
    fileprivate mutating func readString(length: Int, max: Int) -> String? {
        guard length <= max, let bytes = unsafe readBytes(length) else { return nil }
        return unsafe String(validating: bytes, as: UTF8.self)
    }
}
