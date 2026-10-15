import Foundation

/// Capability bits carried in HELLO / HELLO_OK `caps` (§3.5). A capability is
/// active only when both sides advertise it — additive negotiation, no wire
/// version bump.
public enum WireCaps {
    /// Video regions (§4.6) over the dedicated reliable video stream, HEVC.
    public static let videoHEVC: UInt32 = 1 << 0
    /// Reserved for AV1 video regions once hardware AV1 encode exists
    /// (software libaom would need `disable-library-validation`). Only the
    /// rig's alternate mock codec (0x7E) advertises it, to test codec
    /// negotiation.
    public static let videoAV1: UInt32 = 1 << 1
    // Bits 2 and 3 are unassigned.
    /// Cursor as metadata (§5): the viewer composites the pointer
    /// at present time from CURSOR_POS/CURSOR_IMAGE control messages; a host
    /// seeing this bit stops burning the cursor into captured pixels.
    public static let cursor: UInt32 = 1 << 4
    /// Host → viewer in HELLO: this geometry already reflects the host's
    /// best effort for the viewer's HELLO_OK request — accept it, don't
    /// re-request (best-fit rarely equals the literal ask).
    public static let geometryFinal: UInt32 = 1 << 5
    /// Host → viewer: the host can enumerate on-screen windows (it holds
    /// Screen Recording permission) and therefore supports single-window mode.
    /// The viewer greys out the mode when this bit is absent.
    public static let windowList: UInt32 = 1 << 6
    // Bits 7 and 8 are unassigned.
    /// Host → viewer in HELLO: the host saves VIEWER_LOG uploads (the
    /// viewer's "Send Logs to Host").
    public static let logUpload: UInt32 = 1 << 9
    /// Host → viewer in HELLO: the host can create a virtual display at the
    /// viewer's exact size (HELLO_OK geoMode 4, `GeometryMode.virtualDisplay`)
    /// and share that — the picture fills a screen whose shape no host
    /// display mode matches. A viewer sends geoMode 4 only when this is set;
    /// a host without the virtual-display SPI doesn't advertise it.
    public static let virtualDisplay: UInt32 = 1 << 10
    /// Agents (§14), host → viewer in HELLO: the host understands
    /// TEXT_INPUT, AGENT_STATE, UI_TREE_REQUEST and agent-flagged INPUT, and
    /// answers with AGENT_SCOPE / UI_TREE.
    public static let agentControl: UInt32 = 1 << 11

    /// Caps bit advertising support for a given region codec id. The rig-only
    /// mock ids map onto the real bits (0x7F → HEVC bit, 0x7E → AV1 bit) so
    /// negotiation logic is testable without real codecs.
    public static func bit(forVideoCodec codec: UInt8) -> UInt32 {
        codec == VideoCodec.reservedAV1 || codec == 0x7E ? videoAV1 : videoHEVC
    }
}

/// Video-region codec identifiers carried in VIDEO_START (§3.7). The wire is
/// codec-agnostic so a more bandwidth-efficient coder can slot in without a
/// format change: the host's encoder factory is keyed by these ids.
public enum VideoCodec {
    public static let hevc: UInt8 = 1
    /// Reserved: 2 = H.264. Do not reuse.
    public static let reservedH264: UInt8 = 2
    /// Reserved for AV1 once hardware AV1 encode exists (no Apple chip
    /// through M6 has it, and software libaom would need
    /// `disable-library-validation`). Its config record would be the ISO
    /// `av1C` box.
    public static let reservedAV1: UInt8 = 3

    /// Human-readable name for status lines and logs.
    public static func name(_ codec: UInt8) -> String {
        switch codec {
        case hevc: "HEVC"
        case reservedAV1: "AV1"
        default: "codec 0x\(String(codec, radix: 16))"
        }
    }
}

/// Which of a region's tiles a video frame takes over on the viewer.
/// Tile indices are region-relative, row-major over the region's tile box
/// (tile (c, r) of a box whose first tile is (c0, r0) and that is `cols`
/// wide is `(r - r0) * cols + (c - c0)`).
///
/// A frame always decodes (and refreshes) the whole region; claims decide
/// only which tiles SHOW video from then on. A tile the frame doesn't claim
/// keeps showing what it showed — its exact canvas copy if the host handed
/// it off (a newer record, or REVEAL), else its earlier video. That is what
/// lets the still majority of a screen be exact while a small area moves;
/// otherwise a full-screen region carries minutes of soft static text
/// around one animating panel (BENCHMARKS "Per-tile handoff inside a live
/// video region").
public enum VideoClaims: Equatable, Sendable {
    /// Every tile of the region (a generation's first frame).
    case all
    /// Ascending, non-overlapping runs; empty = no tile (a re-sharpen).
    case runs([TileRun])

    public struct TileRun: Equatable, Sendable {
        public var start: UInt32
        public var count: UInt32
        public init(start: UInt32, count: UInt32) {
            self.start = start
            self.count = count
        }
    }
}

/// Messages on the dedicated *video stream* (§3.7; reliable, ordered,
/// head-of-line isolated from control). This is the quarantined multi-frame
/// path (§4.6): everything else in Glass Act is absolute per-tile state; a video
/// region is an explicit host-managed exception with its own lifecycle.
///
/// `generation` guards region restarts: a region that moves, resizes, or
/// re-forms bumps the generation, and the viewer drops frames whose
/// (region, generation) doesn't match the START it last saw — closing races
/// with the asynchronous encoder on the host side.
public enum VideoMessage: Equatable, Sendable {
    /// Host → viewer: a region is live. `config` is the codec configuration
    /// record (HEVC: hvcC — VPS/SPS/PPS). Pixel rect is in canvas coordinates,
    /// tile-aligned by construction on the host but not required by the wire.
    case start(region: UInt8, generation: UInt32, x: UInt16, y: UInt16,
               width: UInt16, height: UInt16, codec: UInt8, config: [UInt8])
    /// Host → viewer: one encoded frame. `sync` marks a random-access frame
    /// (IDR); the first frame after START must be sync. `seq` is a stamp in
    /// the host's `frame_seq` domain (§3.6 serial arithmetic): the viewer
    /// blits the frame per tile iff `newer(seq, tileSeq[t])` — which lets a
    /// straggler video frame lose to a dissolve repaint record that crossed
    /// it on the datagram path, while still beating pre-region stragglers.
    /// The viewer records the stamp only on `claims` tiles (see
    /// `VideoClaims`).
    case frame(region: UInt8, generation: UInt32, seq: UInt32, sync: Bool, captureUS: UInt64,
               claims: VideoClaims = .all, data: [UInt8])
    /// Host → viewer: region dissolved. `reveal` is a tile bitmap over the
    /// session grid (bit t = byte t/8, LSB first; missing bytes are 0, bits
    /// past the grid are ignored). A set bit says the viewer's canvas
    /// already holds this tile's current content — drop the overlay there
    /// now. Every other overlay tile stays visible until a record newer
    /// than its video stamp lands on the canvas (the host repaints exactly
    /// those).
    case stop(region: UInt8, generation: UInt32, reveal: [UInt8])
    /// Host → viewer: a LOSSLESS region keyframe (§4.7) (whole-rect image in
    /// `codec` format). Unlike lossy video frames, an applied keyframe is a
    /// definitive write: the viewer blits per tile iff `newer(seq, tileSeq)`
    /// AND advances tileSeq to `seq` — it is a batch of one giant record.
    /// The viewer confirms application with KEYFRAME_ACK on control (the
    /// stream is reliable, so this acknowledges *application*, not
    /// delivery). Rect is tile-aligned by construction, not by wire law.
    case keyframe(seq: UInt32, x: UInt16, y: UInt16, width: UInt16, height: UInt16,
                  codec: UInt8, stripes: [[UInt8]])
    /// Host → viewer, while the region lives: these tiles' canvas
    /// copies are exact for their current content — stop showing video
    /// there. Bitmap over the session grid, as STOP's `reveal`. Safe by
    /// stream order: everything sent before it on this stream has applied,
    /// and a later frame that changes a tile claims it again.
    case reveal(region: UInt8, generation: UInt32, tiles: [UInt8])

    public var tlvType: UInt8 {
        switch self {
        case .start: 0x01
        case .frame: 0x02
        case .stop: 0x03
        case .keyframe: 0x04
        case .reveal: 0x05
        }
    }

    /// Full TLV encoding (type + varint length + body). Total: encodes any
    /// message, including one whose body exceeds `maxBodyLength` — which the
    /// receiver treats as a malformed stream and tears the session down.
    /// Senders use `encodedForSend()`.
    public func encoded() -> [UInt8] {
        Self.frame(type: tlvType, body: encodedBody())
    }

    /// The TLV encoding, or nil when the body exceeds `maxBodyLength` (the
    /// receiver's bound). Every engine send path goes through this: an
    /// oversize message is dropped or handled at the sender instead of
    /// killing the stream at the receiver.
    public func encodedForSend() -> [UInt8]? {
        let body = encodedBody()
        guard body.count <= Int(Self.maxBodyLength) else { return nil }
        return Self.frame(type: tlvType, body: body)
    }

    private static func frame(type: UInt8, body: [UInt8]) -> [UInt8] {
        var out = ByteWriter(reserving: body.count + 6)
        out.writeU8(type)
        out.writeVarint(UInt32(body.count))
        out.writeBytes(body)
        return out.bytes
    }

    private func encodedBody() -> [UInt8] {
        var body = ByteWriter(reserving: 64)
        switch self {
        case let .start(region, generation, x, y, width, height, codec, config):
            body.writeU8(region)
            body.writeU32(generation)
            body.writeU16(x)
            body.writeU16(y)
            body.writeU16(width)
            body.writeU16(height)
            body.writeU8(codec)
            body.writeVarint(UInt32(config.count))
            body.writeBytes(config)
        case let .frame(region, generation, seq, sync, captureUS, claims, data):
            body.writeU8(region)
            body.writeU32(generation)
            body.writeU32(seq)
            body.writeU8(sync ? 1 : 0)
            body.writeU64(captureUS)
            switch claims {
            case .all:
                body.writeU8(0)
            case let .runs(runs):
                body.writeU8(1)
                body.writeVarint(UInt32(runs.count))
                var end: UInt32 = 0
                for run in runs {
                    body.writeVarint(run.start &- end)
                    body.writeVarint(run.count)
                    end = run.start &+ run.count
                }
            }
            body.writeBytes(data)
        case let .reveal(region, generation, tiles):
            body.writeU8(region)
            body.writeU32(generation)
            body.writeBytes(tiles)
        case let .stop(region, generation, reveal):
            body.writeU8(region)
            body.writeU32(generation)
            body.writeBytes(reveal)
        case let .keyframe(seq, x, y, width, height, codec, stripes):
            precondition(stripes.count >= 1 && stripes.count <= 255)
            body.writeU32(seq)
            body.writeU16(x)
            body.writeU16(y)
            body.writeU16(width)
            body.writeU16(height)
            body.writeU8(codec)
            body.writeU8(UInt8(stripes.count))
            for stripe in stripes {
                body.writeVarint(UInt32(stripe.count))
                body.writeBytes(stripe)
            }
        }
        return body.bytes
    }
}

extension VideoMessage: TLVMessage {
    /// HEVC sync frames at large region sizes reach hundreds of KB; 8 MB is
    /// far above any legitimate frame while still bounding buffering (INV-6).
    public static let maxBodyLength: UInt32 = 8 << 20

    public static func isKnownType(_ t: UInt8) -> Bool {
        (0x01...0x05).contains(t)
    }

    public static func parseBody(type: UInt8, _ buf: UnsafeRawBufferPointer) -> VideoMessage? {
        var r = unsafe ByteReader(buf)
        switch type {
        case 0x01:
            guard let region = r.readU8(), let generation = r.readU32(),
                  let x = r.readU16(), let y = r.readU16(),
                  let w = r.readU16(), let h = r.readU16(), w >= 1, h >= 1,
                  let codec = r.readU8(), codec != 0,
                  let cfgLen = r.readVarint(), Int(cfgLen) == r.remaining,
                  let config = unsafe r.readBytes(Int(cfgLen)),
                  r.remaining == 0 else { return nil }
            return unsafe .start(region: region, generation: generation, x: x, y: y,
                          width: w, height: h, codec: codec, config: [UInt8](config))
        case 0x02:
            guard let region = r.readU8(), let generation = r.readU32(),
                  let seq = r.readU32(), let syncByte = r.readU8(), syncByte <= 1,
                  let captureUS = r.readU64(), let mode = r.readU8() else { return nil }
            let claims: VideoClaims
            switch mode {
            case 0:
                claims = .all
            case 1:
                // Each run is ≥ 2 bytes: a count past that is malformed (and
                // would size an allocation from untrusted input — INV-6).
                guard let n = r.readVarint(), Int(n) <= r.remaining / 2 else { return nil }
                var runs: [VideoClaims.TileRun] = []
                runs.reserveCapacity(Int(n))
                var end: UInt32 = 0
                for _ in 0..<n {
                    guard let gap = r.readVarint(), let count = r.readVarint(), count >= 1 else { return nil }
                    let (start, o1) = end.addingReportingOverflow(gap)
                    let (next, o2) = start.addingReportingOverflow(count)
                    guard !o1, !o2 else { return nil }
                    runs.append(.init(start: start, count: count))
                    end = next
                }
                claims = .runs(runs)
            default:
                return nil
            }
            guard let data = unsafe r.readBytes(r.remaining) else { return nil }
            return unsafe .frame(region: region, generation: generation, seq: seq,
                          sync: syncByte == 1, captureUS: captureUS, claims: claims, data: [UInt8](data))
        case 0x03:
            guard let region = r.readU8(), let generation = r.readU32(),
                  let reveal = unsafe r.readBytes(r.remaining) else { return nil }
            return unsafe .stop(region: region, generation: generation, reveal: [UInt8](reveal))
        case 0x05:
            guard let region = r.readU8(), let generation = r.readU32(),
                  let tiles = unsafe r.readBytes(r.remaining) else { return nil }
            return unsafe .reveal(region: region, generation: generation, tiles: [UInt8](tiles))
        case 0x04:
            guard let seq = r.readU32(), let x = r.readU16(), let y = r.readU16(),
                  let w = r.readU16(), let h = r.readU16(), w >= 1, h >= 1,
                  let codec = r.readU8(), codec != 0,
                  let count = r.readU8(), count >= 1 else { return nil }
            var stripes: [[UInt8]] = []
            stripes.reserveCapacity(Int(count))
            for _ in 0..<count {
                guard let len = r.readVarint(), len >= 1,
                      let blob = unsafe r.readBytes(Int(len)) else { return nil }
                unsafe stripes.append([UInt8](blob))
            }
            guard r.remaining == 0 else { return nil }
            return .keyframe(seq: seq, x: x, y: y, width: w, height: h,
                             codec: codec, stripes: stripes)
        default:
            return nil
        }
    }
}

/// Keyframe payload codecs (§3.7; independent of the region video codecs).
public enum KeyframeCodec {
    /// Striped VP8L: `stripes` independent lossless WebP images, each
    /// `width` wide and `ceil(height/stripeCount)` tall (last stripe may be
    /// shorter). Striping exists to parallelize encode/decode — measured at
    /// ~5–13× wall-time win for ≤ 6 % ratio cost at 5K.
    public static let vp8lStriped: UInt8 = 1
    /// Reserved: 2 = JXL (future marketplace entry for photographic-heavy
    /// keyframes). Do not reuse.
    public static let reservedJXL: UInt8 = 2
    /// Striped WebP *lossy* (VP8) — the cold-start first paint: a small
    /// (~300–800 KB at 5K, q90 ≈ 51 dB) instant full picture with
    /// video-frame semantics: the viewer blits per tile under the LWW gate
    /// but never advances tileSeq and never ACKs — the lossless keyframe
    /// that follows on the same ordered stream overwrites it and carries
    /// the real state. Purely transient; exactness is untouched.
    public static let webpLossyStriped: UInt8 = 3
}

/// Deframer for the video stream.
public typealias VideoDeframer = TLVDeframer<VideoMessage>
