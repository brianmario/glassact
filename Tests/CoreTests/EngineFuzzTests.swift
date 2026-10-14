import Foundation
import Testing
import GlassActCodec
import GlassActCore
import GlassActTransport
import GlassActWire
import GlassActTestSupport

/// INV-6 past the framing: the datagram parser validates a whole datagram
/// before any record is seen, so random bytes (the old engine fuzz, which
/// also stamped the retired v1 version nibble) never reached a payload
/// decoder. This corpus is REAL host output — RAW, LZ4, LZBITMAP, VP8L,
/// DELTA and CACHE STORE/REF records — whose payloads are corrupted and
/// re-framed validly, so every mutation lands in a decoder.
@Suite struct EngineFuzzTests {
    struct Record {
        var opcode: UInt8
        var tile: UInt16
        var fragIdx: UInt8
        var fragCnt: UInt8
        var payload: [UInt8]
    }

    static func records(of datagram: Data) -> [Record] {
        var out: [Record] = []
        datagram.withUnsafeBytes { buf in
            _ = Datagram.parse(buf) { _, r in
                out.append(Record(opcode: r.opcode, tile: r.tileIdx, fragIdx: r.fragIdx,
                                  fragCnt: r.fragCnt, payload: [UInt8](r.payload)))
            }
        }
        return out
    }

    static func frame(_ records: [Record], seq: UInt32) -> Data {
        var w = ByteWriter()
        DatagramHeader(frameSeq: seq, dgramIdx: 0, dgramCnt: 1, captureTimestampUS: 0).encode(into: &w)
        for r in records {
            Datagram.appendRecord(opcode: r.opcode, tileIdx: r.tile, fragIdx: r.fragIdx,
                                  fragCnt: r.fragCnt, payload: r.payload, into: &w)
        }
        return Data(w.bytes)
    }

    /// Host output over a scripted session: noise, UI-like flats with text,
    /// small in-tile edits after ACK (DELTA), and repeated tiles (CACHE).
    static func corpus(width: Int, height: Int, deltas: Bool) -> [Data] {
        var rng = SplitMix64(seed: 0xF0CC)
        let (host, capture) = makeRunningHost(width: width, height: height, deltas: deltas)
        var frame = TestFrame(width: width, height: height)
        var now: UInt64 = 10_000
        func encodeAndAck() {
            let before = capture.sentDatagrams.count
            frame.encode(host: host, nowUS: now)
            for ack in fullAcks(for: Array(capture.sentDatagrams[before...])) {
                host.handleControl(ack, nowUS: now + 2_000)
            }
            now += 50_000
        }
        func paintUI() { // flat panels + dark "text" strokes: LZBITMAP / VP8L territory
            for y in 0..<height {
                for x in 0..<width {
                    let i = (y * width + x) * 4
                    let panel = UInt8(((x / 96) + (y / 80)) % 3 * 60 + 40)
                    let ink = (y % 14 < 2 && (x / 5) % 3 != 0) || (x % 23 == 0 && y % 14 < 9)
                    frame.bytes[i] = ink ? 20 : panel
                    frame.bytes[i + 1] = ink ? 20 : panel &+ 30
                    frame.bytes[i + 2] = ink ? 20 : panel &+ 60
                    frame.bytes[i + 3] = 255
                }
            }
        }
        frame.fillRandom(&rng)
        encodeAndAck()                                   // RAW / LZ4
        paintUI()
        encodeAndAck()                                   // LZBITMAP / VP8L, cache STOREs
        for _ in 0..<4 {                                 // small edits vs ACKed bases: DELTA
            frame.fillRect(x: rng.int(0..<width - 12), y: rng.int(0..<height - 12), w: 6, h: 5, &rng)
            encodeAndAck()
        }
        frame.fillRandom(&rng)
        encodeAndAck()
        paintUI()                                        // stored content returns: CACHE REFs
        encodeAndAck()
        return capture.sentDatagrams
    }

    static func codecRecords(width: Int, height: Int) -> [Data] {
        var rng = SplitMix64(seed: 0xC0DE)
        let codec = LZ4Codec()
        var out: [Data] = []
        var dst = [UInt8](repeating: 0, count: 64 * 64 * 4 * 2)
        for tile in 0..<6 {
            // Flat with a noisy stripe: compressible, fits one record.
            var tight = [UInt8](repeating: UInt8(tile * 40), count: 64 * 64 * 4)
            for i in 0..<(96 + tile * 64) { tight[i * 7 % tight.count] = UInt8(truncatingIfNeeded: rng.next()) }
            for (opcode, bitmap) in [(Opcode.lz4, false), (Opcode.lzbitmap, true)] {
                let n = tight.withUnsafeBytes { src in
                    dst.withUnsafeMutableBytes { d in
                        bitmap ? codec.encodeBitmap(src: src, dst: d) : codec.encode(src: src, dst: d)
                    }
                }
                guard n > 0, n <= 1100 else { continue } // one unfragmented record
                out.append(Self.frame([Record(opcode: opcode, tile: UInt16(tile), fragIdx: 0, fragCnt: 1,
                                              payload: Array(dst.prefix(n)))], seq: UInt32(900 + out.count)))
            }
        }
        return out
    }

    @Test func INV_6_mutatedRealPayloadsNeverCrashTheViewer() {
        // Odd dims: edge tiles can't use the cache, so plain records appear too.
        let width = 400, height = 270
        // Two sessions: with DELTA records, and without (so reverted
        // content ships as CACHE REFs), plus LZ4 / LZBITMAP records coded
        // directly — VP8L outbids them on this content, but the viewer must
        // decode whatever a host may legally send.
        let corpus = Self.corpus(width: width, height: height, deltas: true)
            + Self.corpus(width: width, height: height, deltas: false)
            + Self.codecRecords(width: width, height: height)
        let records = corpus.flatMap(Self.records(of:))

        // The corpus must actually cover the decoders, or this test proves
        // nothing: top-level opcodes, CACHE sub-ops, and the absolute codecs
        // reached inside STORE and DELTA payloads.
        var topLevel = Set<UInt8>(), inner = Set<UInt8>(), cacheOps = Set<UInt8>()
        for r in records where r.fragIdx == 0 {
            topLevel.insert(r.opcode)
            if r.opcode == Opcode.cache, let sub = r.payload.first {
                cacheOps.insert(sub)
                if sub == 0 && r.payload.count > 3 { inner.insert(r.payload[3]) }
            }
            if r.opcode == Opcode.delta, let mode = r.payload.first {
                let at = mode == 0 ? 9 : 13
                if r.payload.count > at { inner.insert(r.payload[at]) }
            }
        }
        let absolute: Set<UInt8> = [Opcode.raw, Opcode.lz4, Opcode.lzbitmap, Opcode.webpl]
        #expect(!topLevel.isDisjoint(with: absolute), "no plain records: \(topLevel.sorted())")
        #expect(topLevel.contains(Opcode.delta), "no DELTA records")
        #expect(cacheOps == [0, 1], "CACHE sub-ops covered: \(cacheOps.sorted())")
        #expect(inner.union(topLevel).isSuperset(of: absolute),
                "codecs never reached: \(absolute.subtracting(inner.union(topLevel)).sorted())")

        let (viewer, _) = makeRunningViewer(width: width, height: height)
        // Seed the viewer with the real session (cache slots, delta bases).
        for d in corpus { viewer.handleDatagram(d, nowUS: 1_000) }
        let appliedClean = viewer.stats.recordsApplied
        #expect(appliedClean > 0)

        var rng = SplitMix64(seed: 0xF1DD)
        var seq: UInt32 = 1_000_000 // LWW-newer than the corpus: every record gets decoded
        for _ in 0..<6_000 {
            var picked = (0..<rng.int(1..<4)).map { _ in records[rng.int(0..<records.count)] }
            for i in picked.indices {
                var p = picked[i].payload
                switch rng.int(0..<5) {
                case 0, 1: // flip bytes
                    for _ in 0..<rng.int(1..<9) where !p.isEmpty {
                        p[rng.int(0..<p.count)] ^= UInt8(truncatingIfNeeded: rng.next() | 1)
                    }
                case 2: // truncate
                    p = Array(p.prefix(rng.int(0..<p.count + 1)))
                case 3: // extend
                    p += rng.bytes(rng.int(1..<64))
                default: // swap the opcode under the same payload
                    let all = [Opcode.raw, Opcode.lz4, Opcode.lzbitmap, Opcode.webpl, Opcode.delta, Opcode.cache]
                    picked[i].opcode = all[rng.int(0..<all.count)]
                }
                picked[i].payload = p
                if rng.int(0..<8) == 0 { picked[i].tile = UInt16(rng.int(0..<200)) }
            }
            seq &+= 1
            viewer.handleDatagram(Self.frame(picked, seq: seq), nowUS: 2_000)
        }
        // Survival is the bar (INV-6); ASan (`just test-asan`) checks over-reads.
        #expect(viewer.state == .running)
        #expect(viewer.stats.malformedDatagrams == 0, "re-framing must keep every datagram well-formed")
    }
}
