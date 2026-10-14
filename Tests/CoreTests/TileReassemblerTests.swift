import Testing
@testable import GlassActCore
import GlassActTestSupport

/// §5 fragment reassembly, driven on the reassembler alone.
@Suite struct TileReassemblerTests {
    private enum Result: Equatable {
        case pending, ignored, rejected
        case complete(opcode: UInt8, seq: UInt32, captureTS: UInt64, payload: [UInt8])
    }

    private static func add(_ r: inout TileReassembler, tile: Int, seq: UInt32, frag: Int, of cnt: Int,
                            _ bytes: [UInt8], opcode: UInt8 = 2, captureTS: UInt64 = 0,
                            nowUS: UInt64 = 0) -> Result {
        bytes.withUnsafeBytes { payload in
            switch r.reassemble(tile: tile, opcode: opcode, fragIdx: UInt8(frag), fragCnt: UInt8(cnt),
                                payload: payload, seq: seq, captureTimestampUS: captureTS, nowUS: nowUS) {
            case .pending: .pending
            case .ignored: .ignored
            case .rejected: .rejected
            case let .complete(op, s, ts, out): .complete(opcode: op, seq: s, captureTS: ts, payload: [UInt8](out))
            }
        }
    }

    @Test func staleOlderSeqFragmentIsIgnored() {
        var r = TileReassembler()
        r.reset(tileCount: 4)
        #expect(Self.add(&r, tile: 2, seq: 5, frag: 0, of: 2, [1, 2, 3], captureTS: 77) == .pending)
        // Fragment 1 of an OLDER send of the same tile must not complete
        // (or corrupt) the live seq-5 partial.
        #expect(Self.add(&r, tile: 2, seq: 4, frag: 1, of: 2, [9, 9]) == .ignored)
        #expect(r.activeCount == 1)
        #expect(Self.add(&r, tile: 2, seq: 5, frag: 1, of: 2, [4, 5]) ==
                .complete(opcode: 2, seq: 5, captureTS: 77, payload: [1, 2, 3, 4, 5]))
        #expect(r.activeCount == 0)
    }

    @Test func newerSeqDiscardsThePartial() {
        var r = TileReassembler()
        r.reset(tileCount: 1)
        #expect(Self.add(&r, tile: 0, seq: 0xFFFF_FFFF, frag: 0, of: 3, [1]) == .pending)
        // Serial arithmetic: 1 is newer than 0xFFFF_FFFF across the wrap.
        #expect(Self.add(&r, tile: 0, seq: 1, frag: 1, of: 2, [8]) == .pending)
        #expect(Self.add(&r, tile: 0, seq: 1, frag: 0, of: 2, [7]) ==
                .complete(opcode: 2, seq: 1, captureTS: 0, payload: [7, 8]))
    }

    @Test func shuffledDuplicatedFragmentsAssembleInOrder() {
        var rng = SplitMix64(seed: 0x5CA7)
        var r = TileReassembler()
        r.reset(tileCount: 16)
        for round in 0..<200 {
            let tile = Int.random(in: 0..<16, using: &rng)
            let cnt = Int.random(in: 2...20, using: &rng)
            let frags = (0..<cnt).map { _ in rng.bytes(Int.random(in: 0...800, using: &rng)) }
            var order = Array(0..<cnt)
            order.shuffle(using: &rng)
            let dup = order[Int.random(in: 0..<(cnt - 1), using: &rng)]
            order.insert(dup, at: cnt - 1) // a duplicate, before the last fragment
            let seq = UInt32(round + 1)
            for (i, f) in order.enumerated() {
                let got = Self.add(&r, tile: tile, seq: seq, frag: f, of: cnt, frags[f], opcode: 1)
                if i == order.count - 1 {
                    #expect(got == .complete(opcode: 1, seq: seq, captureTS: 0, payload: frags.flatMap { $0 }))
                } else if i == cnt - 1 {
                    #expect(got == .ignored) // the duplicate
                } else {
                    #expect(got == .pending)
                }
            }
        }
        #expect(r.activeCount == 0)
    }

    @Test func inconsistentFragCountIsRejected() {
        var r = TileReassembler()
        r.reset(tileCount: 1)
        #expect(Self.add(&r, tile: 0, seq: 3, frag: 0, of: 3, [1]) == .pending)
        #expect(Self.add(&r, tile: 0, seq: 3, frag: 1, of: 4, [2]) == .rejected)
        #expect(r.activeCount == 0)
        // Over-size total is rejected too.
        let big = [UInt8](repeating: 0, count: TileReassembler.bufferSize / 2)
        #expect(Self.add(&r, tile: 0, seq: 4, frag: 0, of: 2, big) == .pending)
        #expect(Self.add(&r, tile: 0, seq: 4, frag: 1, of: 2, big) == .rejected)
        #expect(r.activeCount == 0)
    }

    @Test func expiryReportsTileAndSeqAfter250ms() {
        var r = TileReassembler()
        r.reset(tileCount: 8)
        #expect(Self.add(&r, tile: 3, seq: 11, frag: 0, of: 2, [1], nowUS: 1_000) == .pending)
        #expect(Self.add(&r, tile: 6, seq: 12, frag: 0, of: 2, [1], nowUS: 100_000) == .pending)
        var expired: [[UInt32]] = []
        r.expire(nowUS: 1_000 + TileReassembler.expiryUS) { expired.append([UInt32($0), $1]) }
        #expect(expired.isEmpty) // not past the window yet
        r.expire(nowUS: 1_001 + TileReassembler.expiryUS) { expired.append([UInt32($0), $1]) }
        #expect(expired == [[3, 11]])
        #expect(r.activeCount == 1)
        // The expired fragment's late sibling starts a fresh partial.
        #expect(Self.add(&r, tile: 3, seq: 11, frag: 1, of: 2, [2], nowUS: 300_000) == .pending)
    }

    /// More concurrent partials than the arena's initial buffers: growth
    /// must keep every live partial's bytes.
    @Test func bufferPoolGrowthPreservesLivePartials() {
        var rng = SplitMix64(seed: 42)
        let tiles = TileReassembler.arenaInitial * 3
        var r = TileReassembler()
        r.reset(tileCount: tiles)
        let first = (0..<tiles).map { _ in rng.bytes(1000) }
        let second = (0..<tiles).map { _ in rng.bytes(700) }
        for t in 0..<tiles {
            #expect(Self.add(&r, tile: t, seq: 9, frag: 0, of: 2, first[t]) == .pending)
        }
        #expect(r.activeCount == tiles)
        for t in 0..<tiles {
            #expect(Self.add(&r, tile: t, seq: 9, frag: 1, of: 2, second[t]) ==
                    .complete(opcode: 2, seq: 9, captureTS: 0, payload: first[t] + second[t]))
        }
    }
}
