/// §3.4 tile record opcodes. The parser passes any nonzero opcode
/// through structurally; the apply layer skips opcodes it doesn't implement
/// (forward compatibility). SKIP is the absence of a record.
///
/// | op   | name     | payload                                             |
/// |------|----------|-----------------------------------------------------|
/// | 0x00 | —        | invalid                                             |
/// | 0x01 | RAW      | cropped BGRA, tightly packed (§3.1)                 |
/// | 0x02 | LZ4      | Apple Compression `COMPRESSION_LZ4` of RAW          |
/// | 0x07 | CACHE    | STORE_APPLY / REF — `CachePayload`                  |
/// | 0x09 | LZBITMAP | Apple Compression `COMPRESSION_LZBITMAP` of RAW     |
/// | 0x0A | WEBPL    | VP8L lossless (vendored libwebp) of RAW             |
/// | 0x0B | DELTA    | hash-pinned delta vs ACKed content — `DeltaPayload` |
///
/// Reserved, never reused: 0x03 COPY (scrolls ship as control TLVs instead),
/// 0x04 PALETTE, 0x05 DCT, 0x06 REFINE, 0x08 VIDEO_REGION (video rides its
/// own stream). The encoder picks the smallest absolute encoding per tile;
/// LZBITMAP is skipped on very large batches where its encode cost would
/// threaten the frame budget.
public enum Opcode {
    public static let raw: UInt8 = 0x01
    public static let lz4: UInt8 = 0x02
    public static let lzbitmap: UInt8 = 0x09
    /// VP8L lossless (vendored libwebp) of the RAW payload — ~2× smaller
    /// than LZBITMAP on text tiles; used on moderate-size ticks where the
    /// (parallelized) encode cost fits the frame budget.
    public static let webpl: UInt8 = 0x0A
    /// DELTA (§4.8) — delta against the ACKed tile content, hash-pinned.
    /// Payload: `{mode u8, baseHash u64le, [x u8, y u8, w u8, h u8 when
    /// mode=1], inner opcode u8, inner payload}`. mode 0 = whole-tile XOR
    /// against the base; mode 1 = absolute sub-rect (tile coords). The viewer
    /// applies iff its current tile content hashes to `baseHash` — else clean
    /// drop, and the host's ack/timeout machinery repaints (the REF
    /// discipline). INV-1 note: the base is ACK-confirmed, hash-verified
    /// content — *specified* prior content, which INV-1's letter permits and
    /// INV-3 governs.
    public static let delta: UInt8 = 0x0B
    /// Session tile cache (§4.8). Payload sub-format:
    ///   sub u8 = 0 STORE_APPLY {slot u16 LE, inner-opcode u8, inner payload…}
    ///     — apply like the inner opcode AND store the decoded 64×64 tile
    ///     into cache[slot]. Storing happens on receipt, independent of the
    ///     LWW canvas gate (content and slot travel together: race-free).
    ///   sub u8 = 1 REF {slot u16 LE, contentHash u64 LE}
    ///     — tile := cache[slot], LWW-gated like any record; dropped unless
    ///     the slot's stored hash matches contentHash (stale-slot guard).
    /// References are ACK-gated and memcmp-verified host-side (INV-3; hash
    /// quality is not load-bearing). Note the INV-1 scope clarification:
    /// payload-carrying records remain absolute; 0x07 REF is a guarded
    /// reference op like SCROLL.
    public static let cache: UInt8 = 0x07
}

/// §3.3 — fixed 17-byte datagram header.
public struct DatagramHeader: Equatable, Sendable {
    public static let byteSize = 17
    public static let wireVersion: UInt8 = WireVersion.current

    /// Batch id; increments per sent batch.
    public var frameSeq: UInt32
    /// 0-based index of this datagram within the batch.
    public var dgramIdx: UInt16
    /// Total datagrams in the batch (≥ 1).
    public var dgramCnt: UInt16
    /// µs, mach_absolute-derived; telemetry only, never used for scheduling.
    public var captureTimestampUS: UInt64

    public init(frameSeq: UInt32, dgramIdx: UInt16, dgramCnt: UInt16, captureTimestampUS: UInt64) {
        self.frameSeq = frameSeq
        self.dgramIdx = dgramIdx
        self.dgramCnt = dgramCnt
        self.captureTimestampUS = captureTimestampUS
    }

    public func encode(into w: inout ByteWriter) {
        w.writeU8(Self.wireVersion << 4) // high nibble = version, low nibble reserved (0)
        w.writeU32(frameSeq)
        w.writeU16(dgramIdx)
        w.writeU16(dgramCnt)
        w.writeU64(captureTimestampUS)
    }

    /// Rejects a wrong version nibble, `dgram_cnt == 0`, and `dgram_idx ≥
    /// dgram_cnt`. Reserved low-nibble flag bits are ignored on parse.
    public static func parse(_ r: inout ByteReader) -> DatagramHeader? {
        guard let verFlags = r.readU8(), verFlags >> 4 == wireVersion,
              let seq = r.readU32(),
              let idx = r.readU16(),
              let cnt = r.readU16(), cnt >= 1, idx < cnt,
              let ts = r.readU64()
        else { return nil }
        return DatagramHeader(frameSeq: seq, dgramIdx: idx, dgramCnt: cnt, captureTimestampUS: ts)
    }
}

/// §3.3 — tile record, parse-side view. `payload` points into the datagram
/// buffer and is valid only for the duration of the parse callback —
/// `@unsafe` under strict memory safety: escaping it is a use-after-free, so
/// every use is marked.
@unsafe public struct TileRecord {
    public var opcode: UInt8
    public var tileIdx: UInt16
    public var fragIdx: UInt8
    public var fragCnt: UInt8
    public var payload: UnsafeRawBufferPointer
}

public enum Datagram {
    /// Appends one tile record. Traps on structurally invalid fields (encoder
    /// bug, not wire input): zero opcode, `fragCnt == 0`, `fragIdx ≥ fragCnt`.
    public static func appendRecord(
        opcode: UInt8,
        tileIdx: UInt16,
        fragIdx: UInt8,
        fragCnt: UInt8,
        payload: some Collection<UInt8>,
        into w: inout ByteWriter
    ) {
        precondition(opcode != 0 && fragCnt >= 1 && fragIdx < fragCnt, "invalid record fields")
        w.writeU8(opcode)
        w.writeU16(tileIdx)
        w.writeU8(fragIdx)
        w.writeU8(fragCnt)
        w.writeVarint(UInt32(payload.count))
        w.writeBytes(payload)
    }

    /// Parses a whole datagram. The datagram is fully validated before any
    /// callback fires; a malformed datagram is rejected atomically (returns
    /// false, `body` never called). Record payloads are views into `buf`.
    @discardableResult
    public static func parse(
        _ buf: UnsafeRawBufferPointer,
        _ body: (DatagramHeader, TileRecord) -> Void
    ) -> Bool {
        var reader = unsafe ByteReader(buf)
        guard let header = DatagramHeader.parse(&reader) else { return false }
        var validator = reader
        while validator.remaining > 0 {
            guard unsafe parseRecord(&validator) != nil else { return false }
        }
        while reader.remaining > 0 {
            guard let record = unsafe parseRecord(&reader) else { return false } // unreachable: validated above
            unsafe body(header, record) // record.payload is valid only inside this call
        }
        return true
    }

    @discardableResult
    public static func parse(_ bytes: [UInt8], _ body: (DatagramHeader, TileRecord) -> Void) -> Bool {
        bytes.withUnsafeBytes { unsafe parse($0, body) }
    }

    static func parseRecord(_ r: inout ByteReader) -> TileRecord? {
        guard let opcode = r.readU8(), opcode != 0,
              let tileIdx = r.readU16(),
              let fragIdx = r.readU8(),
              let fragCnt = r.readU8(), fragCnt >= 1, fragIdx < fragCnt,
              let len = r.readVarint(),
              let payload = unsafe r.readBytes(Int(len))
        else { return nil }
        return unsafe TileRecord(opcode: opcode, tileIdx: tileIdx, fragIdx: fragIdx, fragCnt: fragCnt, payload: payload)
    }
}
