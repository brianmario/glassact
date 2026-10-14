import Testing
import GlassActWire
import GlassActTestSupport

/// INV-6 — malformed input must never crash, over-read, or allocate unboundedly.
/// "No crash" is the pass condition; run `just test-asan` for over-read detection.
@Suite struct FuzzTests {
    @Test func randomBuffersNeverCrashDatagramParser() {
        var rng = SplitMix64(seed: 0xFA22)
        for _ in 0..<20_000 {
            var bytes = rng.bytes(rng.int(0..<800))
            // Steer half the corpus past the version check to exercise deeper paths.
            if !bytes.isEmpty && rng.int(0..<2) == 0 {
                bytes[0] = WireVersion.current << 4
            }
            Datagram.parse(bytes, { _, r in _ = r.payload.count })
        }
    }

    @Test func mutatedValidDatagramsNeverCrash() {
        var rng = SplitMix64(seed: 0xBEEF)
        for _ in 0..<50 {
            let original = randomValidDatagram(&rng)
            for _ in 0..<200 {
                var m = original
                switch rng.int(0..<3) {
                case 0: // flip random bytes
                    for _ in 0..<rng.int(1..<8) where !m.isEmpty {
                        m[rng.int(0..<m.count)] ^= UInt8(truncatingIfNeeded: rng.next())
                    }
                case 1: // truncate
                    m = Array(m.prefix(rng.int(0..<max(1, m.count))))
                default: // splice random tail
                    m.append(contentsOf: rng.bytes(rng.int(0..<64)))
                }
                Datagram.parse(m, { _, r in _ = r.payload.count })
            }
        }
    }

    @Test func unmutatedCorpusAlwaysParses() {
        var rng = SplitMix64(seed: 0x1DEA)
        for _ in 0..<200 {
            let d = randomValidDatagram(&rng)
            #expect(Datagram.parse(d, { _, _ in }))
        }
    }

    @Test func randomChunksNeverCrashControlDeframer() {
        var rng = SplitMix64(seed: 0xACED)
        for _ in 0..<200 {
            var d = ControlDeframer()
            for _ in 0..<20 {
                d.append(rng.bytes(rng.int(0..<200)))
                while d.next() != nil {}
                if d.isMalformed { break }
            }
        }
    }

    @Test func mutatedControlStreamsNeverCrash() {
        var rng = SplitMix64(seed: 0xD00D)
        let corpus: [ControlMessage] = [
            .hello(ver: 1, width: 2560, height: 1440, tileSize: 64, pixfmt: 1, caps: 0),
            .helloOK(ver: 1, caps: 0, geoMode: 0, geoWidth: 0, geoHeight: 0, geoScale: 0),
            .ack(frameSeq: 77, dgramCnt: 12, bitmap: [0xFF, 0x0F]),
            .ping(nonce: 8, tUS: 9),
            .pong(nonce: 8, tUS: 9, recvTUS: 10),
            .pauseHint(paused: true),
            .quality(presentedScalePct: 50, floor: QualityFloor.high, preferSharpness: 1),
        ]
        for _ in 0..<300 {
            var stream: [UInt8] = []
            for _ in 0..<rng.int(1..<6) {
                stream.append(contentsOf: corpus[rng.int(0..<corpus.count)].encoded())
            }
            for _ in 0..<rng.int(1..<6) where !stream.isEmpty {
                stream[rng.int(0..<stream.count)] ^= UInt8(truncatingIfNeeded: rng.next())
            }
            var d = ControlDeframer()
            var i = 0
            while i < stream.count {
                let n = min(stream.count - i, rng.int(1..<64))
                d.append(stream[i ..< i + n])
                while d.next() != nil {}
                i += n
            }
        }
    }
}
