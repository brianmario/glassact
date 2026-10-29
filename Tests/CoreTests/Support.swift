import Foundation
import GlassActWire
import GlassActCodec
@testable import GlassActCore
import GlassActTransport
import GlassActTestSupport


/// Transport stub that records everything sent; input is injected directly via
/// the engines' `handleControl`/`handleDatagram`.
final class CaptureTransport: GlassActTransport {
    var maxDatagramSize: Int = 1452
    var videoBacklogBytes: Int { 0 }
    var sentControl: [Data] = []
    var sentDatagrams: [Data] = []
    var sentVideo: [Data] = []

    func sendControl(_ data: Data) { sentControl.append(data) }
    func sendDatagram(_ data: Data) { sentDatagrams.append(data) }
    func sendVideo(_ data: Data) { sentVideo.append(data) }
}

/// A host past its handshake, wired to a capture transport. The cold-start
/// keyframe and DELTA records are always on in a real session; here they are
/// off unless asked for, so a test sees its first frame as plain tile
/// records and can decode every payload on its own.
func makeRunningHost(width: Int, height: Int, keyframes: Bool = false, deltas: Bool = false)
    -> (HostEngine, CaptureTransport) {
    let capture = CaptureTransport()
    let host = HostEngine(width: width, height: height, transport: capture)
    host.assumeFastLinkForTests() // no path to measure: logic tests, not governor tests
    host.coldStartKeyframes = keyframes
    host.deltaRecords = deltas
    host.start(nowUS: 0)
    let helloOK = ControlMessage.helloOK(ver: WireVersion.current, caps: 0, geoMode: 0, geoWidth: 0, geoHeight: 0, geoScale: 0)
    host.handleControl(Data(helloOK.encoded()), nowUS: 1_000)
    return (host, capture)
}

func makeRunningViewer(width: Int, height: Int) -> (ViewerEngine, CaptureTransport) {
    let capture = CaptureTransport()
    let viewer = ViewerEngine(transport: capture)
    let hello = ControlMessage.hello(ver: WireVersion.current,
                                     width: UInt16(width), height: UInt16(height),
                                     tileSize: 64, pixfmt: PixelFormat.bgra8sRGB, caps: 0)
    viewer.handleControl(Data(hello.encoded()), nowUS: 0)
    return (viewer, capture)
}

/// A tightly-packed BGRA test frame.
struct TestFrame {
    let width: Int
    let height: Int
    var bytes: [UInt8]

    init(width: Int, height: Int) {
        self.width = width
        self.height = height
        bytes = [UInt8](repeating: 0, count: width * height * 4)
    }

    mutating func fillRandom(_ rng: inout SplitMix64) {
        bytes.withUnsafeMutableBytes { Self.fill($0, &rng) }
    }

    mutating func fillRect(x: Int, y: Int, w: Int, h: Int, _ rng: inout SplitMix64) {
        let count = min(w, width - x) * 4
        guard count > 0 else { return }
        bytes.withUnsafeMutableBytes { buf in
            for row in y ..< min(y + h, height) {
                Self.fill(UnsafeMutableRawBufferPointer(rebasing: buf[(row * width + x) * 4 ..< (row * width + x) * 4 + count]),
                          &rng)
            }
        }
    }

    /// Exactly the bytes `rng.bytes(dst.count)` would produce (each word
    /// little-endian, the last one truncated), written in place — the
    /// per-byte array version would dominate the big video tests in debug
    /// builds.
    private static func fill(_ dst: UnsafeMutableRawBufferPointer, _ rng: inout SplitMix64) {
        var i = 0
        while i + 8 <= dst.count {
            dst.storeBytes(of: rng.next().littleEndian, toByteOffset: i, as: UInt64.self)
            i += 8
        }
        if i < dst.count {
            var v = rng.next()
            while i < dst.count {
                dst[i] = UInt8(truncatingIfNeeded: v)
                v >>= 8
                i += 1
            }
        }
    }

    func encode(host: HostEngine, dirtyRects: [DirtyRect]? = nil, nowUS: UInt64) {
        bytes.withUnsafeBytes { raw in
            host.encodeTick(frame: raw, bytesPerRow: width * 4, dirtyRects: dirtyRects,
                            captureTimestampUS: nowUS, nowUS: nowUS)
        }
    }

    func tightTile(_ idx: Int) -> [UInt8] {
        let grid = TileGrid(width: width, height: height)
        let (x, y, tw, th) = grid.rect(of: idx)
        var out = [UInt8](repeating: 0, count: tw * th * 4)
        _ = bytes.withUnsafeBytes { src in
            out.withUnsafeMutableBytes { dst in
                TileOps.extract(src: src, bytesPerRow: width * 4, x: x, y: y, tw: tw, th: th, into: dst)
            }
        }
        return out
    }
}

// MARK: - Wire-level helpers

func header(of datagram: Data) -> DatagramHeader? {
    datagram.withUnsafeBytes { raw in
        var r = ByteReader(raw)
        return DatagramHeader.parse(&r)
    }
}

/// Builds a datagram of unfragmented records: (tileIdx, tight RAW payload).
func makeDatagram(seq: UInt32, dgramIdx: UInt16 = 0, dgramCnt: UInt16 = 1,
                  records: [(tile: UInt16, payload: [UInt8])],
                  opcode: UInt8 = Opcode.raw) -> Data {
    var w = ByteWriter()
    DatagramHeader(frameSeq: seq, dgramIdx: dgramIdx, dgramCnt: dgramCnt,
                   captureTimestampUS: 0).encode(into: &w)
    for r in records {
        Datagram.appendRecord(opcode: opcode, tileIdx: r.tile, fragIdx: 0, fragCnt: 1,
                              payload: r.payload, into: &w)
    }
    return Data(w.bytes)
}

/// Reassembles and decodes every tile carried by `datagrams` (test-side,
/// standalone — deliberately shares no state with the engines).
func decodeTilePayloads(_ datagrams: [Data]) -> [UInt16: [UInt8]] {
    struct Frags {
        var cnt = 0
        var opcode: UInt8 = 0
        var parts: [Int: [UInt8]] = [:]
    }
    var perTile: [UInt16: Frags] = [:]
    for d in datagrams {
        _ = d.withUnsafeBytes { raw in
            Datagram.parse(raw) { _, rec in
                var f = perTile[rec.tileIdx] ?? Frags()
                f.cnt = Int(rec.fragCnt)
                f.opcode = rec.opcode
                f.parts[Int(rec.fragIdx)] = [UInt8](rec.payload)
                perTile[rec.tileIdx] = f
            }
        }
    }
    var out: [UInt16: [UInt8]] = [:]
    let lz4 = LZ4Codec()
    for (tile, f) in perTile where f.parts.count == f.cnt {
        var payload: [UInt8] = []
        for i in 0..<f.cnt {
            payload.append(contentsOf: f.parts[i] ?? [])
        }
        var opcode = f.opcode
        if opcode == Opcode.cache {
            // Unwrap STORE_APPLY {sub=0, slot u16, inner}; REF records are
            // references, not standalone payloads, and are skipped here.
            guard payload.count > 4, payload[0] == 0 else { continue }
            opcode = payload[3]
            payload = Array(payload[4...])
        }
        if opcode == Opcode.raw {
            out[tile] = payload
        } else if opcode == Opcode.lz4 || opcode == Opcode.lzbitmap || opcode == Opcode.webpl {
            var dst = [UInt8](repeating: 0, count: 64 * 64 * 4)
            let n = payload.withUnsafeBytes { s -> Int in
                dst.withUnsafeMutableBytes { d -> Int in
                    switch opcode {
                    case Opcode.lz4: return lz4.decode(src: s, dst: d)
                    case Opcode.lzbitmap: return lz4.decodeBitmap(src: s, dst: d)
                    default:
                        // decodeTilePayloads is only used on full 64×64 tiles
                        return WebPTile.decodeLossless(src: s, width: 64, height: 64, dst: d)
                    }
                }
            }
            out[tile] = Array(dst[0..<n])
        }
    }
    return out
}

/// One full-bitmap ACK per distinct batch seen in `datagrams`.
func fullAcks(for datagrams: [Data]) -> [Data] {
    var bySeq: [UInt32: (cnt: Int, bits: Set<Int>)] = [:]
    for d in datagrams {
        guard let h = header(of: d) else { continue }
        var entry = bySeq[h.frameSeq] ?? (Int(h.dgramCnt), [])
        entry.bits.insert(Int(h.dgramIdx))
        bySeq[h.frameSeq] = entry
    }
    return bySeq.map { seq, entry in
        var bitmap = [UInt8](repeating: 0, count: (entry.cnt + 7) / 8)
        for b in entry.bits {
            bitmap[b >> 3] |= 1 << UInt8(b & 7)
        }
        return Data(ControlMessage.ack(frameSeq: seq, dgramCnt: UInt16(entry.cnt), bitmap: bitmap).encoded())
    }
}

func controlMessages(_ chunks: [Data]) -> [ControlMessage] {
    var deframer = ControlDeframer()
    for c in chunks {
        deframer.append(c)
    }
    var out: [ControlMessage] = []
    while let event = deframer.next() {
        if case let .message(m) = event {
            out.append(m)
        }
    }
    return out
}

func canvasTile(_ viewer: ViewerEngine, _ idx: Int) -> [UInt8]? {
    guard let grid = viewer.grid else { return nil }
    let (x, y, tw, th) = grid.rect(of: idx)
    var out = [UInt8](repeating: 0, count: tw * th * 4)
    let ok = viewer.withCanvas { canvas in
        out.withUnsafeMutableBytes { dst in
            TileOps.extract(src: canvas, bytesPerRow: grid.width * 4, x: x, y: y, tw: tw, th: th, into: dst)
        }
    }
    return ok != nil ? out : nil
}

// MARK: - Full-loop harness (host engine → faults → viewer engine)

final class Harness {
    let link: InProcLink
    private(set) var host: HostEngine
    let viewer: ViewerEngine
    var frame: TestFrame
    private var hostVideo: Bool
    private var hostEncoderFactory: ((UInt8) -> any VideoRegionEncoder?)?
    private var hostCodecPref: [UInt8]
    private var hostClock: (@Sendable () -> UInt64)?

    var now: UInt64 { link.nowUS }

    init(width: Int = 320, height: Int = 240, faults: FaultConfig = .none, video: Bool = false,
         hostCodecs: [UInt8] = [MockVideoEncoder.mockCodecID],
         viewerCodecs: [UInt8] = [MockVideoEncoder.mockCodecID],
         encoderFactory: ((UInt8) -> any VideoRegionEncoder?)? = nil,
         decoderFactory: (() -> any VideoRegionDecoder)? = nil,
         fastLink: Bool = false,
         sendClock: Bool = false,
         encodeTimer: (@Sendable () -> UInt64)? = nil,
         viewerQualityPolicy: (floor: Int, preferSharpness: Bool, preferSmoothness: Bool)? = nil) {
        frame = TestFrame(width: width, height: height)
        let link = InProcLink(faults: faults)
        self.link = link
        // sendClock: the host stamps sends with the link's clock at hand-off
        // time (like the app's real clock), not the tick's `nowUS`.
        if sendClock {
            hostClock = { link.nowUS }
        } else {
            hostClock = nil
        }
        hostVideo = video
        hostEncoderFactory = encoderFactory
        hostCodecPref = hostCodecs
        host = HostEngine(width: width, height: height, transport: link.a,
                          videoEncoderFactory: video ? (encoderFactory ?? { MockVideoEncoder(codecID: $0) }) : nil,
                          videoCodecPreference: hostCodecs,
                          clock: hostClock,
                          encodeTimer: encodeTimer)
        if fastLink { host.assumeFastLinkForTests() }
        viewer = ViewerEngine(transport: link.b,
                              videoDecoderFactory: video ? (decoderFactory ?? { MockVideoDecoder() }) : nil,
                              supportedVideoCodecs: viewerCodecs)
        viewer.initialQualityPolicy = viewerQualityPolicy
        link.a.onControl = { [weak self] data in
            guard let self else { return }
            self.host.handleControl(data, nowUS: self.link.nowUS)
        }
        link.b.onControl = { [weak self] data in
            guard let self else { return }
            self.viewer.handleControl(data, nowUS: self.link.nowUS)
        }
        link.b.onDatagram = { [weak self] data in
            guard let self else { return }
            self.viewer.handleDatagram(data, nowUS: self.link.nowUS)
        }
        link.b.onVideo = { [weak self] data in
            guard let self else { return }
            self.viewer.handleVideo(data, nowUS: self.link.nowUS)
        }
        host.start(nowUS: 0)
        run(untilUS: 300_000) // complete the handshake (control latency ≤ 50 ms/way)
    }

    /// Simulate an in-session geometry change (§4.10) (window resize / pick):
    /// swap the host engine to new dims on the SAME link, seeding nextFrameSeq
    /// for LWW continuity, and re-point the control route. The viewer
    /// reconfigures its canvas in place on the re-HELLO. Mirrors
    /// HostController.reconfigureEngineInSession — no reconnect.
    func reconfigure(width: Int, height: Int) {
        let seed = host.currentFrameSeq
        host = HostEngine(width: width, height: height, transport: link.a,
                          videoEncoderFactory: hostVideo ? (hostEncoderFactory ?? { MockVideoEncoder(codecID: $0) }) : nil,
                          videoCodecPreference: hostCodecPref,
                          startFrameSeq: seed,
                          clock: hostClock)
        link.a.onControl = { [weak self] data in
            guard let self else { return }
            self.host.handleControl(data, nowUS: self.link.nowUS)
        }
        host.start(nowUS: link.nowUS) // HELLO at new dims → viewer reconfigures
        frame = TestFrame(width: width, height: height)
        run(untilUS: now + 300_000)   // let the re-HELLO / HELLO_OK settle
    }

    /// Advances virtual time in 1 ms steps, ticking both engines.
    func run(untilUS: UInt64) {
        var t = now
        while t < untilUS {
            t = min(t + 1_000, untilUS)
            link.advance(toUS: t)
            viewer.tick(nowUS: link.nowUS)
            host.tick(nowUS: link.nowUS)
        }
    }

    func encodeFrame(dirtyRects: [DirtyRect]? = nil) {
        frame.encode(host: host, dirtyRects: dirtyRects, nowUS: now)
    }

    func mutateRandomRects(_ rng: inout SplitMix64, count: Int) -> [DirtyRect] {
        var rects: [DirtyRect] = []
        for _ in 0..<count {
            let w = rng.int(8..<120)
            let h = rng.int(8..<120)
            let x = rng.int(0..<max(1, frame.width - w))
            let y = rng.int(0..<max(1, frame.height - h))
            frame.fillRect(x: x, y: y, w: w, h: h, &rng)
            rects.append(DirtyRect(x: x, y: y, width: w, height: h))
        }
        return rects
    }

    /// The canvas is byte-exact AND nothing still presents from the video
    /// overlay (the presented image is the canvas).
    func canvasMatchesFrame() -> Bool {
        guard viewer.overlayVisibleTileCount == 0 else { return false }
        return viewer.withCanvas { canvas in
            frame.bytes.withUnsafeBytes { expected in
                canvas.count == expected.count
                    && memcmp(canvas.baseAddress, expected.baseAddress, expected.count) == 0
            }
        } ?? false
    }

    /// §7 golden-divergence settle: keep ticking the encoder on the final frame
    /// until no open batches and no qualifying tiles (bounded iterations).
    @discardableResult
    func settle(maxSimMS: Int = 60_000) -> Bool {
        var sinceEncodeMS = 16
        for _ in 0..<maxSimMS {
            if sinceEncodeMS >= 16 {
                encodeFrame()
                sinceEncodeMS = 0
                if host.openBatchCount == 0
                    && host.stats.lastTickQualifiedTiles == 0
                    && host.activeVideoRegionCount == 0
                    && host.pendingRepaintTiles == 0
                    && !host.keyframeInFlight
                    && link.pendingDatagramCount == 0
                    && link.pendingVideoCount == 0 {
                    return true
                }
            }
            run(untilUS: now + 1_000)
            sinceEncodeMS += 1
        }
        return false
    }
}

/// Repacks decoder output (row stride ≥ width*4) into tight BGRA bytes.
func tightPixels(_ pixels: UnsafeRawBufferPointer, bytesPerRow: Int, width: Int, height: Int) -> [UInt8] {
    var out = [UInt8](repeating: 0, count: width * height * 4)
    out.withUnsafeMutableBytes { dst in
        for row in 0..<height {
            dst.baseAddress!.advanced(by: row * width * 4)
                .copyMemory(from: pixels.baseAddress!.advanced(by: row * bytesPerRow), byteCount: width * 4)
        }
    }
    return out
}
