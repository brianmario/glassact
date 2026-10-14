import Testing
import GlassActWire
import GlassActTestSupport

/// §3.9 — the sign-in exchange. Anyone can send these (the sign-in ALPN
/// admits any key), so the parser is held to INV-6 like the session's.
@Suite struct SignInWireTests {
    @Test func requestRoundTrips() {
        let requests = [
            SignInRequest(op: .query, device: "Alex’s MacBook Air"),
            SignInRequest(op: .signIn, user: "alex", password: "correct horse battery staple", device: "Air"),
            SignInRequest(op: .signIn, user: "Ålex Ünicode", password: "pässwörd 🔑", device: ""),
        ]
        for request in requests {
            #expect(SignInRequest.parse(request.encoded()) == request)
        }
    }

    @Test func responseRoundTrips() {
        for raw in UInt8(1)...6 {
            let response = SignInResponse(SignInResponse.Status(rawValue: raw)!, retryAfterSeconds: 300)
            #expect(SignInResponse.parse(response.encoded()) == response)
        }
    }

    @Test func longFieldsAreTruncatedAtCharacterBoundaries() {
        let request = SignInRequest(op: .signIn, user: String(repeating: "é", count: 200),
                                    password: String(repeating: "p", count: 5000),
                                    device: String(repeating: "🖥", count: 40))
        let bytes = request.encoded()
        #expect(bytes.count <= SignInRequest.maxEncodedBytes)
        let parsed = SignInRequest.parse(bytes)
        #expect(parsed?.user.utf8.count ?? 0 <= SignInRequest.maxUserBytes)
        #expect(parsed?.password.count == SignInRequest.maxPasswordBytes)
        #expect(parsed?.device.allSatisfy { $0 == "🖥" } == true)
    }

    @Test func malformedRequestsAreRejected() {
        let valid = SignInRequest(op: .signIn, user: "alex", password: "pw", device: "Air").encoded()
        #expect(SignInRequest.parse([]) == nil)
        #expect(SignInRequest.parse(valid + [0]) == nil, "trailing bytes")
        #expect(SignInRequest.parse(Array(valid.dropLast())) == nil, "truncated")
        var badVersion = valid; badVersion[0] = 2
        #expect(SignInRequest.parse(badVersion) == nil)
        var badOp = valid; badOp[1] = 9
        #expect(SignInRequest.parse(badOp) == nil)
        // A query never carries credentials.
        var query = valid; query[1] = SignInRequest.Op.query.rawValue
        #expect(SignInRequest.parse(query) == nil)
        // Invalid UTF-8 in the user name.
        var badUTF8 = valid; badUTF8[3] = 0xFF
        #expect(SignInRequest.parse(badUTF8) == nil)
        // A password length over the bound.
        var w = ByteWriter()
        w.writeU8(1); w.writeU8(2); w.writeU8(0)
        w.writeU16(UInt16(SignInRequest.maxPasswordBytes + 1))
        w.writeBytes([UInt8](repeating: 0x61, count: SignInRequest.maxPasswordBytes + 1))
        w.writeU8(0)
        #expect(SignInRequest.parse(w.bytes) == nil)
        #expect(SignInRequest.parse([UInt8](repeating: 0, count: SignInRequest.maxEncodedBytes + 1)) == nil)
    }

    @Test func malformedResponsesAreRejected() {
        #expect(SignInResponse.parse([1, 4, 0]) == nil)
        #expect(SignInResponse.parse([1, 4, 0, 0, 0]) == nil)
        #expect(SignInResponse.parse([2, 4, 0, 0]) == nil)
        #expect(SignInResponse.parse([1, 0, 0, 0]) == nil)
        #expect(SignInResponse.parse([1, 7, 0, 0]) == nil)
    }

    /// INV-6: random and mutated input never crashes either parser.
    @Test func fuzzedInputNeverCrashes() {
        var rng = SplitMix64(seed: 0x5161)
        let seeds = [SignInRequest(op: .signIn, user: "alex", password: "secret", device: "Air").encoded(),
                     SignInRequest(op: .query, device: "Mini").encoded()]
        for _ in 0..<20_000 {
            _ = SignInRequest.parse(rng.bytes(rng.int(0..<1400)))
            _ = SignInResponse.parse(rng.bytes(rng.int(0..<8)))
            var m = seeds[rng.int(0..<seeds.count)]
            for _ in 0..<rng.int(1..<6) where !m.isEmpty {
                m[rng.int(0..<m.count)] ^= UInt8(truncatingIfNeeded: rng.next())
            }
            if rng.int(0..<3) == 0 { m = Array(m.prefix(rng.int(0..<max(1, m.count)))) }
            _ = SignInRequest.parse(m)
        }
    }
}
