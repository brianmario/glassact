import Testing
import GlassActWire
import GlassActTestSupport

/// Video-stream TLVs (§3.7).
@Suite struct VideoTests {
    private func roundTrip(_ m: VideoMessage) {
        var d = VideoDeframer()
        d.append(m.encoded())
        #expect(d.next() == .message(m))
        #expect(d.next() == nil)
        #expect(!d.isMalformed)
    }

    @Test func startRoundTrip() {
        roundTrip(.start(region: 0, generation: 1, x: 320, y: 192, width: 640, height: 384,
                         codec: VideoCodec.hevc, config: [0x01, 0x22, 0x60]))
        roundTrip(.start(region: 1, generation: 0xFFFF_FFFF, x: 0, y: 0, width: 5120, height: 2880,
                         codec: VideoCodec.hevc, config: []))
    }

    @Test func frameRoundTrip() {
        var rng = SplitMix64(seed: 60)
        roundTrip(.frame(region: 0, generation: 3, seq: 1, sync: true, captureUS: 0, data: rng.bytes(200_000)))
        roundTrip(.frame(region: 2, generation: 7, seq: 42, sync: false, captureUS: 0xDEAD_BEEF_1234, data: rng.bytes(1000)))
        roundTrip(.frame(region: 1, generation: 3, seq: 900, sync: false, captureUS: 0, data: []))
    }

    @Test func frameClaimsRoundTrip() {
        var rng = SplitMix64(seed: 64)
        roundTrip(.frame(region: 0, generation: 1, seq: 7, sync: false, captureUS: 9,
                         claims: .runs([]), data: rng.bytes(500)))
        roundTrip(.frame(region: 0, generation: 1, seq: 8, sync: false, captureUS: 9,
                         claims: .runs([.init(start: 0, count: 1), .init(start: 5, count: 11),
                                        .init(start: 3_000, count: 600)]),
                         data: rng.bytes(500)))
        // Gaps and lengths are 4-byte varints (§3: < 2^28).
        roundTrip(.frame(region: 0, generation: 1, seq: 9, sync: true, captureUS: 0,
                         claims: .runs([.init(start: (1 << 28) - 2, count: 1)]), data: []))
    }

    /// Runs are delta-coded: a strip of an animating panel costs a few bytes
    /// per tile row, not a bitmap of the grid.
    @Test func claimsAreCompact() {
        let rows = (0..<16).map { VideoClaims.TileRun(start: UInt32($0 * 46), count: 11) }
        let claimed = VideoMessage.frame(region: 0, generation: 1, seq: 1, sync: false, captureUS: 0,
                                         claims: .runs(rows), data: []).encoded().count
        let all = VideoMessage.frame(region: 0, generation: 1, seq: 1, sync: false, captureUS: 0,
                                     data: []).encoded().count
        #expect(claimed - all <= 2 + 16 * 2, "16 runs: \(claimed - all) bytes over an all-claim")
    }

    @Test func revealRoundTrip() {
        roundTrip(.reveal(region: 0, generation: 4, tiles: [0xFF, 0x00, 0x81]))
        roundTrip(.reveal(region: 0, generation: 4, tiles: []))
    }

    /// INV-6: claim lists are bounded by the bytes that carry them, and
    /// never overflow the tile index space.
    @Test func malformedClaimsAreRejected() {
        func frameBody(_ claims: (inout ByteWriter) -> Void) -> [UInt8] {
            var body = ByteWriter()
            body.writeU8(0); body.writeU32(1); body.writeU32(1); body.writeU8(0); body.writeU64(0)
            claims(&body)
            var tlv = ByteWriter()
            tlv.writeU8(0x02)
            tlv.writeVarint(UInt32(body.bytes.count))
            tlv.writeBytes(body.bytes)
            return tlv.bytes
        }
        let cases: [(String, [UInt8])] = [
            ("unknown claims mode", frameBody { $0.writeU8(2) }),
            ("run count past the body", frameBody { $0.writeU8(1); $0.writeVarint(1_000_000) }),
            ("zero-length run", frameBody { $0.writeU8(1); $0.writeVarint(1); $0.writeVarint(0); $0.writeVarint(0) }),
            ("runs past UInt32", frameBody { // 17 × (2^28 − 1) gaps overflow the index space
                $0.writeU8(1); $0.writeVarint(17)
                for _ in 0..<17 { $0.writeVarint((1 << 28) - 1); $0.writeVarint(1) }
            }),
            ("truncated run", frameBody { $0.writeU8(1); $0.writeVarint(2); $0.writeVarint(0); $0.writeVarint(1) }),
            ("no claims byte", frameBody { _ in }),
        ]
        for (name, bytes) in cases {
            var d = VideoDeframer()
            d.append(bytes)
            #expect(d.next() == nil, "\(name)")
            #expect(d.isMalformed, "\(name)")
        }
    }

    @Test func stopRoundTrip() {
        // An empty bitmap reveals nothing (a lost video stream's STOP).
        roundTrip(.stop(region: 0, generation: 12, reveal: []))
        roundTrip(.stop(region: 0, generation: 13, reveal: [0xFF, 0x01, 0x00, 0x80]))
    }

    @Test func keyframeRoundTrip() {
        var rng = SplitMix64(seed: 63)
        roundTrip(.keyframe(seq: 42, x: 0, y: 0, width: 5120, height: 2880,
                            codec: KeyframeCodec.vp8lStriped,
                            stripes: (0..<8).map { _ in rng.bytes(rng.int(1..<40_000)) }))
        roundTrip(.keyframe(seq: 1, x: 64, y: 128, width: 640, height: 384,
                            codec: KeyframeCodec.vp8lStriped, stripes: [rng.bytes(100)]))
        // Zero-length stripe is invalid.
        var bad = ByteWriter()
        var body = ByteWriter()
        body.writeU32(1)
        body.writeU16(0); body.writeU16(0); body.writeU16(64); body.writeU16(64)
        body.writeU8(KeyframeCodec.vp8lStriped)
        body.writeU8(1)
        body.writeVarint(0)
        bad.writeU8(0x04)
        bad.writeVarint(UInt32(body.bytes.count))
        bad.writeBytes(body.bytes)
        var d = VideoDeframer()
        d.append(bad.bytes)
        #expect(d.next() == nil)
        #expect(d.isMalformed)
    }

    @Test func mixedStreamChunkedDelivery() {
        var rng = SplitMix64(seed: 61)
        let messages: [VideoMessage] = [
            .start(region: 0, generation: 1, x: 64, y: 64, width: 512, height: 512,
                   codec: VideoCodec.hevc, config: rng.bytes(90)),
            .frame(region: 0, generation: 1, seq: 1, sync: true, captureUS: 0, data: rng.bytes(40_000)),
            .frame(region: 0, generation: 1, seq: 2, sync: false, captureUS: 0, data: rng.bytes(3_000)),
            .stop(region: 0, generation: 1, reveal: [0x0F]),
        ]
        let stream = messages.flatMap { $0.encoded() }
        var d = VideoDeframer()
        var events: [VideoDeframer.Event] = []
        // Deliver in ragged chunks to exercise resumption points.
        var i = 0
        var chunk = 1
        while i < stream.count {
            let end = min(stream.count, i + chunk)
            d.append(stream[i..<end])
            while let e = d.next() { events.append(e) }
            i = end
            chunk = (chunk * 7 + 3) % 4096 + 1
        }
        #expect(events == messages.map { .message($0) })
        #expect(!d.isMalformed)
    }

    @Test func malformedBodiesAreRejected() {
        // START whose declared config length disagrees with the body remainder.
        var bad = ByteWriter()
        var body = ByteWriter()
        body.writeU8(0)
        body.writeU32(1)
        body.writeU16(0); body.writeU16(0); body.writeU16(64); body.writeU16(64)
        body.writeU8(VideoCodec.hevc)
        body.writeVarint(10)           // claims 10 config bytes…
        body.writeBytes([1, 2, 3] as [UInt8]) // …carries 3
        bad.writeU8(0x01)
        bad.writeVarint(UInt32(body.bytes.count))
        bad.writeBytes(body.bytes)
        var d = VideoDeframer()
        d.append(bad.bytes)
        #expect(d.next() == nil)
        #expect(d.isMalformed)

        // Zero-size region is invalid.
        var zero = ByteWriter()
        var zbody = ByteWriter()
        zbody.writeU8(0)
        zbody.writeU32(1)
        zbody.writeU16(0); zbody.writeU16(0); zbody.writeU16(0); zbody.writeU16(64)
        zbody.writeU8(VideoCodec.hevc)
        zbody.writeVarint(0)
        zero.writeU8(0x01)
        zero.writeVarint(UInt32(zbody.bytes.count))
        zero.writeBytes(zbody.bytes)
        var d2 = VideoDeframer()
        d2.append(zero.bytes)
        #expect(d2.next() == nil)
        #expect(d2.isMalformed)
    }

    @Test func unknownVideoTypeIsSkipped() {
        var unknown = ByteWriter()
        unknown.writeU8(0x09)
        unknown.writeVarint(2)
        unknown.writeBytes([7, 7] as [UInt8])
        var stream = unknown.bytes
        stream.append(contentsOf: VideoMessage.stop(region: 0, generation: 5, reveal: [1]).encoded())
        var d = VideoDeframer()
        d.append(stream)
        #expect(d.next() == .skippedUnknown(type: 0x09))
        #expect(d.next() == .message(.stop(region: 0, generation: 5, reveal: [1])))
        #expect(!d.isMalformed)
    }

    /// INV-6 fuzz: random bytes and mutated valid streams must never crash and
    /// must never emit more data than the stream contains.
    @Test func fuzzRandomAndMutated() {
        var rng = SplitMix64(seed: 62)
        for round in 0..<300 {
            var stream: [UInt8]
            if round % 2 == 0 {
                stream = rng.bytes(rng.int(1..<2_000))
            } else {
                stream = VideoMessage.frame(region: UInt8(round % 3), generation: 1,
                                            seq: UInt32(round), sync: round % 4 == 0,
                                            captureUS: 0, data: rng.bytes(rng.int(0..<800))).encoded()
                for _ in 0..<rng.int(1..<6) {
                    stream[rng.int(0..<stream.count)] = UInt8(truncatingIfNeeded: rng.next())
                }
            }
            var d = VideoDeframer()
            d.append(stream)
            var drained = 0
            while d.next() != nil {
                drained += 1
                #expect(drained <= stream.count)
            }
        }
    }
}
