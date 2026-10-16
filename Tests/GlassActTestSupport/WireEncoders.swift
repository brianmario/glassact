public import GlassActWire

// Reference encoders for building wire input in tests. Production packs
// datagrams in DatagramPacker and sends video with `encodedForSend()`.

extension DatagramHeader {
    public func encode(into w: inout ByteWriter) {
        w.writeU8(Self.wireVersion << 4) // high nibble = version, low nibble reserved (0)
        w.writeU32(frameSeq)
        w.writeU16(dgramIdx)
        w.writeU16(dgramCnt)
        w.writeU64(captureTimestampUS)
    }
}

extension Datagram {
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

    @discardableResult
    public static func parse(_ bytes: [UInt8], _ body: (DatagramHeader, TileRecord) -> Void) -> Bool {
        bytes.withUnsafeBytes { parse($0, body) }
    }
}

extension VideoMessage {
    /// The TLV encoding. Traps on a body over `maxBodyLength`.
    public func encoded() -> [UInt8] {
        guard let bytes = encodedForSend() else { preconditionFailure("video message body over maxBodyLength") }
        return bytes
    }
}
