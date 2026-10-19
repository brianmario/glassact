import Foundation
import Testing
import GlassActCodec
import GlassActWire
@testable import GlassActCore
import GlassActTestSupport

/// INV-6 inside the striped keyframe decode (§4.7). The video stream parser
/// frames the stripes; their bytes go to libwebp, decoded in parallel into
/// adjacent row bands of one scratch buffer and blitted onto the canvas.
/// The corpus is the host's own `encodeStripes` output (lossless and the
/// lossy first paint) of a screen-like image, mutated per stripe
/// (`WebPMutator`) and re-striped (stripes dropped, duplicated, swapped,
/// added, emptied). Each outcome is checked against an independent
/// reference: every stripe decoded alone, under guard. The applier must
/// apply exactly that image (a stripe writing into its neighbour's band
/// would show here) or drop the keyframe without touching the canvas,
/// tileSeq or the dirty set, and never write outside the canvas.
@Suite struct KeyframeDecodeFuzzTests {
    struct Keyframe {
        var codec: UInt8
        var stripes: [[UInt8]]
    }

    /// `GLASSACT_EXHAUSTIVE=1` runs 100× the iterations.
    static let scale = ProcessInfo.processInfo.environment["GLASSACT_EXHAUSTIVE"] == "1" ? 100 : 1

    /// An odd-sized canvas, and a keyframe from tile (1, 1) to the cropped
    /// edges: partial tiles on two sides, a short last stripe.
    static let grid = TileGrid(width: 300, height: 230)
    static let (kx, ky, kw, kh) = (64, 64, 236, 166)

    /// Bands of every corpus image kind, top to bottom, so stripes differ.
    static func image(_ rng: inout SplitMix64) -> [UInt8] {
        var out: [UInt8] = []
        var row = 0
        for kind in FuzzImage.allCases.cycled(toCover: kh, band: 24) {
            let rows = min(24, kh - row)
            out += kind.pixels(width: kw, height: rows, &rng)
            row += rows
        }
        return out
    }

    static func corpus() -> [Keyframe] {
        var rng = SplitMix64(seed: 0x4B46_F022)
        let img = image(&rng)
        let (host, _) = makeRunningHost(width: grid.width, height: grid.height)
        let stripes = min(HostEngine.keyframeStripes, kh)
        let out = UnsafeMutableRawBufferPointer.allocate(byteCount: stripes * ((kh + stripes - 1) / stripes) * kw * 4,
                                                         alignment: 64)
        defer { out.deallocate() }
        return img.withUnsafeBytes { px in
            [(KeyframeCodec.vp8lStriped, nil), (KeyframeCodec.webpLossyStriped, Float(90))].map { codec, q in
                Keyframe(codec: codec,
                         stripes: host.encodeStripes(pixels: px, width: kw, height: kh, into: out, lossyQuality: q)!)
            }
        }
    }

    @Test func INV_6_mutatedStripedKeyframesApplyExactlyOrDropCleanly() {
        let corpus = Self.corpus()
        #expect(corpus.allSatisfy { $0.stripes.count == HostEngine.keyframeStripes })
        let grid = Self.grid
        let canvasBytes = grid.width * grid.height * 4
        let guardBytes = 4_096, canary: UInt8 = 0xCD
        let buf = UnsafeMutableRawBufferPointer.allocate(byteCount: guardBytes + canvasBytes + guardBytes, alignment: 64)
        defer { buf.deallocate() }
        buf.initializeMemory(as: UInt8.self, repeating: canary)
        let canvas = UnsafeMutableRawBufferPointer(rebasing: buf[guardBytes..<(guardBytes + canvasBytes)])
        var rng = SplitMix64(seed: 0x5781_9E5)
        let initial = rng.bytes(canvasBytes)
        initial.withUnsafeBytes { canvas.copyMemory(from: $0) }
        var expected = initial // the canvas the applier must leave behind
        var tileSeq = ContiguousArray<UInt32>(repeating: 0, count: grid.count)
        var dirty = DirtyTiles()
        dirty.reset(tileCount: grid.count)
        var drained: [Int] = []
        let covered = Set((0..<grid.count).filter {
            let r = grid.rect(of: $0)
            return r.x >= Self.kx && r.y >= Self.ky
        })

        var seq: UInt32 = 0, applied = 0, dropped = 0, violations = 0
        for iteration in 0..<(500 * Self.scale) {
            let kf = corpus[rng.int(0..<corpus.count)]
            let lossless = kf.codec == KeyframeCodec.vp8lStriped
            var stripes = kf.stripes
            let mode = rng.int(0..<6) // 0–3 stripe payloads, 4 re-striping, 5 both
            if mode != 4 {
                for _ in 0..<rng.int(1..<4) {
                    let s = rng.int(0..<stripes.count)
                    let bandH = (Self.kh + stripes.count - 1) / stripes.count
                    stripes[s] = WebPMutator.mutate(stripes[s], donor: stripes[rng.int(0..<stripes.count)],
                                                    width: Self.kw, height: min(bandH, Self.kh - s * bandH),
                                                    kind: rng.int(0..<WebPMutator.kinds), &rng)
                }
            }
            if mode >= 4 {
                let s = rng.int(0..<stripes.count), t = rng.int(0..<stripes.count)
                switch rng.int(0..<5) {
                case 0: if stripes.count > 1 { stripes.remove(at: s) }
                case 1: stripes.insert(stripes[s], at: t)
                case 2: stripes.swapAt(s, t)
                case 3: stripes.append(stripes[s])
                default: stripes[s] = []
                }
            }

            // Reference: the image the stripes describe, each decoded alone.
            let bandH = (Self.kh + stripes.count - 1) / stripes.count
            var reference = [UInt8](repeating: 0, count: Self.kw * Self.kh * 4)
            var decodes = (stripes.count - 1) * bandH < Self.kh
            for (s, stripe) in stripes.enumerated() where decodes {
                let bh = min(bandH, Self.kh - s * bandH)
                let r = GuardedDecode.run(stripe, dstBytes: bh * Self.kw * 4, fill: 0) {
                    lossless ? WebPTile.decodeLossless(src: $0, width: Self.kw, height: bh, dst: $1)
                             : WebPTile.decodeBGRA(src: $0, width: Self.kw, height: bh, dst: $1)
                }
                if !r.canariesIntact { violations += 1 }
                decodes = r.count == bh * Self.kw * 4
                if decodes { reference.replaceSubrange((s * bandH * Self.kw * 4)..<((s * bandH + bh) * Self.kw * 4), with: r.output) }
            }

            seq &+= 1
            let seqBefore = tileSeq
            var applier = KeyframeApplier() // fresh: its scratch is exactly the rect, so ASan sees overruns
            let outcome = applier.apply(seq: seq, x: Self.kx, y: Self.ky, w: Self.kw, h: Self.kh, codec: kf.codec,
                                        stripes: stripes, canvas: canvas, grid: grid,
                                        tileSeq: &tileSeq, dirty: &dirty)
            drained.removeAll(keepingCapacity: true)
            dirty.drain(into: &drained)

            var ok: Bool
            if decodes {
                applied += 1
                for r in 0..<Self.kh {
                    let at = ((Self.ky + r) * grid.width + Self.kx) * 4
                    expected.replaceSubrange(at..<(at + Self.kw * 4),
                                             with: reference[(r * Self.kw * 4)..<((r + 1) * Self.kw * 4)])
                }
                ok = outcome == (lossless ? .applied : .appliedTransient)
                    && Set(drained) == covered
                    && (0..<grid.count).allSatisfy {
                        tileSeq[$0] == (lossless && covered.contains($0) ? seq : seqBefore[$0])
                    }
            } else {
                dropped += 1
                ok = outcome == .dropped && drained.isEmpty && tileSeq == seqBefore
            }
            ok = ok && expected.withUnsafeBytes { memcmp($0.baseAddress!, canvas.baseAddress!, canvasBytes) == 0 }
                && GuardedDecode.allBytes(UnsafeRawBufferPointer(rebasing: buf[0..<guardBytes]), equal: canary)
                && GuardedDecode.allBytes(UnsafeRawBufferPointer(rebasing: buf[(guardBytes + canvasBytes)...]),
                                          equal: canary)
            if !ok {
                violations += 1
                if violations <= 5 {
                    Issue.record("""
                        iteration \(iteration) mode \(mode) codec \(kf.codec) \(stripes.count) stripes: \
                        \(outcome), expected \(decodes ? "applied" : "dropped")
                        """)
                }
                expected = [UInt8](UnsafeRawBufferPointer(canvas)) // resync, keep looking
            }
        }
        #expect(violations == 0)
        // Both outcomes must be common, or the corpus isn't reaching the
        // decoder (all dropped) or the mutations aren't biting (all applied).
        #expect(applied > 30 * Self.scale && dropped > 200 * Self.scale, "applied \(applied), dropped \(dropped)")
    }
}

private extension Array {
    /// Enough elements, cycling, to cover `total` in steps of `band`.
    func cycled(toCover total: Int, band: Int) -> [Element] {
        (0..<((total + band - 1) / band)).map { self[$0 % count] }
    }
}
