import Foundation
import Testing
@testable import GlassActCore
import GlassActWire
import GlassActTestSupport

/// DatagramPacker in isolation: whatever it packs, the checked parser reads
/// back exactly — within budget, records never spanning datagrams, headers
/// numbered and counted.
@Suite struct DatagramPackerTests {
    @Test func packedBatchParsesBackExactly() {
        var rng = SplitMix64(seed: 11)
        var packer = DatagramPacker(capacity: 1 << 20)
        let budget = 1200
        let maxFrag = budget - DatagramHeader.byteSize - 8
        var expected: [(tile: UInt16, frag: UInt8, cnt: UInt8, bytes: [UInt8])] = []
        packer.reset()
        for tile in 0..<40 {
            let prefix = tile % 3 == 0 ? rng.bytes(4) : []
            let body = rng.bytes(rng.int(1..<4_000))
            let logical = prefix + body
            let fragCnt = max(1, (logical.count + maxFrag - 1) / maxFrag)
            var offset = 0
            for frag in 0..<fragCnt {
                let len = min(maxFrag, logical.count - offset)
                prefix.withUnsafeBytes { p in
                    body.withUnsafeBytes { b in
                        _ = packer.append(opcode: Opcode.raw, tileIdx: UInt16(tile), fragIdx: UInt8(frag),
                                          fragCnt: UInt8(fragCnt), prefix: p, body: b,
                                          logicalOffset: offset, length: len, budget: budget)
                    }
                }
                expected.append((UInt16(tile), UInt8(frag), UInt8(fragCnt), Array(logical[offset..<offset + len])))
                offset += len
            }
        }
        let count = packer.finish(frameSeq: 77, captureTimestampUS: 123)
        var got: [(tile: UInt16, frag: UInt8, cnt: UInt8, bytes: [UInt8])] = []
        for i in 0..<count {
            let d = packer.datagram(i)
            #expect(d.count <= budget, "datagram \(i) is \(d.count) B")
            let ok = Datagram.parse(d) { h, r in
                #expect(h.frameSeq == 77 && h.dgramIdx == UInt16(i) && h.dgramCnt == UInt16(count)
                        && h.captureTimestampUS == 123)
                got.append((r.tileIdx, r.fragIdx, r.fragCnt, [UInt8](r.payload)))
            }
            #expect(ok, "datagram \(i) must parse")
        }
        #expect(got.count == expected.count)
        #expect(zip(got, expected).allSatisfy { $0.tile == $1.tile && $0.frag == $1.frag
                                                 && $0.cnt == $1.cnt && $0.bytes == $1.bytes })
    }
}
