import Foundation

/// Shared pieces of the WebP decoder fuzz tests (INV-6 past the wire parser:
/// `WebPTile` and the striped keyframe decode): synthetic screen-like
/// images for the corpus, structure-aware mutations of RIFF/VP8L (and VP8)
/// payloads, and a decode harness that checks every byte the decoder may
/// touch.

/// Screen-like BGRA content for the corpus, so the encoder emits the
/// transforms real tiles use (colour indexing with bit packing, predictors,
/// cross-colour, colour cache, backward references).
public enum FuzzImage: CaseIterable, Sendable {
    case flat, gradient, text, photo, noise, palette2, palette16, alpha

    public func pixels(width w: Int, height h: Int, _ rng: inout SplitMix64) -> [UInt8] {
        var out = [UInt8](repeating: 0, count: w * h * 4)
        let palette: [[UInt8]] = (0..<16).map { _ in rng.bytes(3) + [0xFF] }
        let base = rng.bytes(3)
        for y in 0..<h {
            for x in 0..<w {
                let i = (y * w + x) * 4
                var px: [UInt8]
                switch self {
                case .flat:
                    px = base + [0xFF]
                case .gradient:
                    px = [UInt8(truncatingIfNeeded: x * 4), UInt8(truncatingIfNeeded: y * 4),
                          UInt8(truncatingIfNeeded: x + y), 0xFF]
                case .text: // light panel, dark glyph-like strokes
                    let ink = (y % 12 < 2 && (x / 3) % 4 != 0) || (x % 7 == 0 && y % 12 < 9)
                    px = ink ? [24, 24, 28, 0xFF] : [236, 236, 240, 0xFF]
                case .photo: // smooth field plus sensor-like noise
                    let n = UInt8(truncatingIfNeeded: rng.next() & 7)
                    px = [UInt8(truncatingIfNeeded: 80 + x / 2) &+ n, UInt8(truncatingIfNeeded: 60 + y) &+ n,
                          UInt8(truncatingIfNeeded: 120 + (x + y) / 3) &+ n, 0xFF]
                case .noise:
                    px = rng.bytes(3) + [0xFF]
                case .palette2:
                    px = palette[Int(rng.next() % 2)]
                case .palette16:
                    px = palette[Int(rng.next() % 16)]
                case .alpha: // translucent ramp under content (exact = 1 keeps RGB)
                    px = [UInt8(truncatingIfNeeded: x * 3), base[1], UInt8(truncatingIfNeeded: y * 5),
                          UInt8(truncatingIfNeeded: (x * 9 + y * 5) & 0xFF)]
                }
                out[i] = px[0]; out[i + 1] = px[1]; out[i + 2] = px[2]; out[i + 3] = px[3]
            }
        }
        return out
    }
}

/// Mutations of a simple-format WebP file: `RIFF size WEBP` then one
/// `VP8L` (or `VP8 `) chunk. Each one targets a part of the format a
/// decoder has to distrust: chunk lengths, declared dimensions, the
/// transform / Huffman prologue, or the bit-aligned entropy-coded body.
public enum WebPMutator {
    public static let kinds = 16
    static let riffSizeAt = 4, chunkSizeAt = 16, streamAt = 20

    /// One mutation of `p`; `donor` is another real payload (for splices
    /// and dimension lies), `width × height` the size the caller expects.
    public static func mutate(_ p: [UInt8], donor: [UInt8], width: Int, height: Int,
                              kind: Int, _ rng: inout SplitMix64) -> [UInt8] {
        var m = p
        switch kind {
        case 0: // bit flips anywhere
            for _ in 0..<rng.int(1..<9) where !m.isEmpty {
                m[rng.int(0..<m.count)] ^= 1 << UInt8(rng.int(0..<8))
            }
        case 1: // bit flips in the headers and the transform / Huffman prologue
            let span = min(m.count, 64)
            for _ in 0..<rng.int(1..<5) where span > 0 {
                m[rng.int(0..<span)] ^= 1 << UInt8(rng.int(0..<8))
            }
        case 2: // byte runs overwritten with boundary or random values
            let values: [UInt8] = [0x00, 0xFF, 0x7F, 0x80, 0x01, 0xFE]
            for _ in 0..<rng.int(1..<5) where !m.isEmpty {
                let at = rng.int(0..<m.count)
                let v = rng.int(0..<2) == 0 ? values[rng.int(0..<values.count)] : UInt8(truncatingIfNeeded: rng.next())
                for i in at..<min(m.count, at + rng.int(1..<9)) { m[i] = v }
            }
        case 3: // truncation anywhere
            m = Array(m.prefix(rng.int(0..<(m.count + 1))))
        case 4: // truncation inside or just past the headers
            m = Array(m.prefix(rng.int(0..<(min(m.count, 48) + 1))))
        case 5: // RIFF size lies
            writeLE32(&m, at: riffSizeAt, lie(actual: m.count - 8, &rng))
        case 6: // chunk size lies
            writeLE32(&m, at: chunkSizeAt, lie(actual: m.count - streamAt, &rng))
        case 7: // declared dimensions: 1, the 14-bit maximum, or random
            func pick(_ r: inout SplitMix64) -> Int {
                switch r.int(0..<3) {
                case 0: return 1
                case 1: return 16_384
                default: return r.int(1..<16_385)
                }
            }
            setDims(&m, width: pick(&rng), height: pick(&rng))
        case 8: // dimension lie: another payload's body under the expected size
            m = donor
            setDims(&m, width: width, height: height)
        case 9: // signature, alpha hint and version bits of the stream header
            if m.count > streamAt + 4 {
                let at = [streamAt, streamAt + 4, streamAt + 4][rng.int(0..<3)]
                m[at] ^= at == streamAt ? UInt8(truncatingIfNeeded: rng.next() | 1) : UInt8(0x10 << rng.int(0..<4))
            }
        case 10: // splice: a prefix of this payload, a suffix of another
            let cut = rng.int(0..<(m.count + 1))
            m = Array(m.prefix(cut)) + Array(donor.suffix(rng.int(0..<(donor.count + 1))))
        case 11: // trailing garbage
            m += rng.bytes(rng.int(1..<256))
        case 12: // container stripped: a bare bitstream (libwebp accepts one)
            m = Array(m.dropFirst(min(m.count, streamAt)))
            if !m.isEmpty && rng.int(0..<2) == 0 { m[rng.int(0..<m.count)] ^= 1 << UInt8(rng.int(0..<8)) }
        case 13: // bytes inserted or deleted mid-stream: the bit reader desyncs
            let at = rng.int(0..<(m.count + 1))
            if rng.int(0..<2) == 0 || at == m.count {
                m.insert(contentsOf: rng.bytes(rng.int(1..<5)), at: at)
            } else {
                m.removeSubrange(at..<min(m.count, at + rng.int(1..<5)))
            }
        case 14: // random body behind intact headers
            m = Array(m.prefix(streamAt + 5)) + rng.bytes(rng.int(0..<(2 * max(m.count, 1))))
        default: // empty
            m = []
        }
        return m
    }

    /// Declared dimensions, for either stream flavour (no-op when the
    /// headers are too short or unrecognised).
    public static func setDims(_ m: inout [UInt8], width: Int, height: Int) {
        if m.count >= streamAt + 5, m[streamAt] == 0x2F { // VP8L: 14 bits each, minus one
            var bits = UInt32(m[streamAt + 1]) | UInt32(m[streamAt + 2]) << 8
                | UInt32(m[streamAt + 3]) << 16 | UInt32(m[streamAt + 4]) << 24
            bits = (bits & 0xF000_0000) | UInt32((width - 1) & 0x3FFF) | UInt32((height - 1) & 0x3FFF) << 14
            writeLE32(&m, at: streamAt + 1, bits)
        } else if m.count >= streamAt + 10, m[12] == 0x56, m[13] == 0x50, m[14] == 0x38, m[15] == 0x20 {
            // VP8 key frame: 3-byte tag, start code, then 14-bit w / h (+2-bit scale).
            m[streamAt + 6] = UInt8(width & 0xFF); m[streamAt + 7] = UInt8((width >> 8) & 0x3F)
            m[streamAt + 8] = UInt8(height & 0xFF); m[streamAt + 9] = UInt8((height >> 8) & 0x3F)
        }
    }

    static func lie(actual: Int, _ rng: inout SplitMix64) -> UInt32 {
        let a = UInt32(clamping: max(actual, 0))
        switch rng.int(0..<6) {
        case 0: return 0
        case 1: return 0xFFFF_FFFF
        case 2: return 0x7FFF_FFFF
        case 3: return a &+ UInt32(rng.int(1..<9))
        case 4: return a &- UInt32(rng.int(1..<9))
        default: return UInt32(truncatingIfNeeded: rng.next())
        }
    }

    static func writeLE32(_ m: inout [UInt8], at: Int, _ v: UInt32) {
        guard m.count >= at + 4 else { return }
        for i in 0..<4 { m[at + i] = UInt8(truncatingIfNeeded: v >> (8 * UInt32(i))) }
    }

    /// The dimensions a payload's stream header declares (RIFF-wrapped or
    /// bare; VP8L or VP8 key frame), or nil if it has no readable header.
    public static func declaredDims(_ m: [UInt8]) -> (width: Int, height: Int)? {
        for at in [streamAt, 0] where m.count >= at + 5 && m[at] == 0x2F {
            let bits = Int(m[at + 1]) | Int(m[at + 2]) << 8 | Int(m[at + 3]) << 16 | Int(m[at + 4]) << 24
            return ((bits & 0x3FFF) + 1, ((bits >> 14) & 0x3FFF) + 1)
        }
        for at in [streamAt, 0] where m.count >= at + 10 && m[at + 3] == 0x9D && m[at + 4] == 0x01
            && m[at + 5] == 0x2A {
            return (Int(m[at + 6]) | Int(m[at + 7] & 0x3F) << 8, Int(m[at + 8]) | Int(m[at + 9] & 0x3F) << 8)
        }
        return nil
    }
}

/// Runs a decoder the way the Viewer does, but checks everything around
/// it: the source is copied into an exact-size allocation (ASan reports any
/// over-read), and the destination sits between canaries (any write past
/// either end fails the canary check, with or without ASan).
public enum GuardedDecode {
    public static let guardBytes = 256
    static let canary: UInt8 = 0xCD

    public struct Result {
        /// The decoder's return value.
        public var count: Int
        /// The destination after the call (exactly `dstBytes`).
        public var output: [UInt8]
        /// Bytes before / after the destination were untouched.
        public var canariesIntact: Bool
    }

    /// `decode(src, dst)` with `dst` exactly `dstBytes` long and pre-filled
    /// with `fill`.
    public static func run(_ payload: [UInt8], dstBytes: Int, fill: UInt8,
                           _ decode: (UnsafeRawBufferPointer, UnsafeMutableRawBufferPointer) -> Int) -> Result {
        let src = UnsafeMutableRawBufferPointer.allocate(byteCount: max(payload.count, 1), alignment: 1)
        defer { src.deallocate() }
        payload.withUnsafeBytes { if let b = $0.baseAddress { src.baseAddress!.copyMemory(from: b, byteCount: $0.count) } }
        let total = guardBytes + dstBytes + guardBytes
        let buf = UnsafeMutableRawBufferPointer.allocate(byteCount: total, alignment: 64)
        defer { buf.deallocate() }
        buf.initializeMemory(as: UInt8.self, repeating: canary)
        let dst = UnsafeMutableRawBufferPointer(rebasing: buf[guardBytes..<(guardBytes + dstBytes)])
        dst.initializeMemory(as: UInt8.self, repeating: fill)
        let n = decode(UnsafeRawBufferPointer(rebasing: src[0..<payload.count]), dst)
        let intact = allBytes(UnsafeRawBufferPointer(rebasing: buf[0..<guardBytes]), equal: canary)
            && allBytes(UnsafeRawBufferPointer(rebasing: buf[(guardBytes + dstBytes)...]), equal: canary)
        return Result(count: n, output: [UInt8](dst), canariesIntact: intact)
    }

    /// Every byte of `p` is `v` (memcmp: the debug-build fuzz loops stay fast).
    public static func allBytes(_ p: UnsafeRawBufferPointer, equal v: UInt8) -> Bool {
        guard let base = p.baseAddress, p.count > 0 else { return true }
        return p[0] == v && memcmp(base, base + 1, p.count - 1) == 0
    }
}
