import AV1Core
import Foundation
import GlassActAV1
import GlassActAV1Decode
import GlassActCodec
@testable import GlassActCore
import GlassActHybridVideo
import GlassActTestSupport
import GlassActTransport
import GlassActWire
import Testing

/// A new Host and a new Viewer over real QUIC on loopback, wired as the apps wire them
/// (`HostVideoEncoders`, `ViewerVideoDecoders.glassAct`): they negotiate Glass Act's AV1, the
/// Viewer shows its frames, and the canvas comes back exact when the motion stops. With
/// `hardwareAV1: false` the Viewer decodes with Glass Act's own decoder (an M1 / M2 / Intel Mac,
/// an older iPad), and every frame it shows is checked against the encoder's reconstruction of
/// that frame; with `true`, VideoToolbox's, where this Mac has AV1 hardware. Real time and real
/// sockets, so deadlines, not exact counts. Old peers' pairings are AV1PairingTests'.
@Suite(.serialized, .tags(.quic), .notInFastLane,
       .enabled(if: HostVideoEncoders.glassActAvailable, "needs macOS 27 and an Apple-silicon GPU (Glass Act's encoder)"))
struct AV1SessionQUICTests {
    static let width = 1280, height = 768

    /// The encoder's reconstruction of each frame, by the frame's bytes (its threads write it).
    final class Reconstructions: @unchecked Sendable {
        private let lock = NSLock()
        private var byFrame: [UInt64: UInt64] = [:]
        func add(obu: [UInt8], planes: [[UInt8]]) {
            guard planes.count == 3 else { return }
            let h = XXH64.hash(planes[2], seed: XXH64.hash(planes[1], seed: XXH64.hash(planes[0])))
            lock.withLock { byFrame[XXH64.hash(obu)] = h }
        }
        func picture(of data: [UInt8]) -> UInt64? { lock.withLock { byFrame[XXH64.hash(data)] } }
    }

    /// Glass Act's decoder, every shown frame compared with the encoder's picture of it.
    final class CheckingDecoder: VideoRegionDecoder {
        let inner: OwnAV1RegionDecoder
        let reconstructions: Reconstructions
        private(set) var shown = 0, exact = 0, failed = 0
        private var scratch: [UInt8] = []
        init(_ inner: OwnAV1RegionDecoder, _ reconstructions: Reconstructions) {
            self.inner = inner
            self.reconstructions = reconstructions
        }
        func start(codec: UInt8, config: [UInt8], width: Int, height: Int) -> Bool {
            inner.start(codec: codec, config: config, width: width, height: height)
        }
        func decode(_ data: [UInt8], sync: Bool,
                    onPixels: (_ pixels: UnsafeRawBufferPointer, _ bytesPerRow: Int) -> Void) -> Bool {
            guard inner.decode(data, sync: sync, onPixels: onPixels) else {
                failed += 1
                return false
            }
            shown += 1
            let picture = inner.withShownPicture { p -> UInt64? in
                let planes = [p.planes.0, p.planes.1, p.planes.2], strides = [p.stride.0, p.stride.1, p.stride.2]
                let ws = [p.plane_w.0, p.plane_w.1, p.plane_w.2], hs = [p.plane_h.0, p.plane_h.1, p.plane_h.2]
                var h: UInt64 = 0
                for k in 0..<3 {
                    guard let base = planes[k] else { return nil }
                    let (w, rows) = (Int(ws[k]), Int(hs[k]))
                    scratch = [UInt8](repeating: 0, count: w * rows)
                    scratch.withUnsafeMutableBytes { dst in
                        for r in 0..<rows { (dst.baseAddress! + r * w).copyMemory(from: base + r * Int(strides[k]), byteCount: w) }
                    }
                    h = XXH64.hash(scratch, seed: h)
                }
                return h
            } ?? nil
            if let picture, picture == reconstructions.picture(of: data) { exact += 1 }
            return true
        }
        func stop() { inner.stop() }
    }

    /// The Viewer's decoders: the apps' choice, Glass Act's decoder checked.
    final class Decoders: @unchecked Sendable {
        let reconstructions = Reconstructions()
        private(set) var checking: [CheckingDecoder] = []
        private(set) var vt = 0
        func offer(hardwareAV1: Bool) -> ViewerVideoDecoders {
            let real = ViewerVideoDecoders.glassAct(av1: true, hardwareAV1: hardwareAV1)
            return ViewerVideoDecoders(caps: real.caps) { [self] codec in
                let d = real.decoder(forCodec: codec)
                if let own = d as? OwnAV1RegionDecoder {
                    let c = CheckingDecoder(own, reconstructions)
                    checking.append(c)
                    return c
                }
                if codec == VideoCodec.av1 && d is VTRegionDecoder { vt += 1 }
                return d
            }
        }
    }

    /// A screen whose every tile changes each frame (a moving gradient and noise band), then
    /// holds still.
    static func paint(_ frame: inout [UInt8], step: Int) {
        let w = width
        frame.withUnsafeMutableBufferPointer { p in
            for y in 0..<height {
                for x in 0..<w {
                    let i = (y * w + x) * 4
                    let band = (x + step * 9) % 160 < 24
                    p[i] = UInt8(truncatingIfNeeded: x + step * 3)
                    p[i + 1] = UInt8(truncatingIfNeeded: y * 2 + step)
                    p[i + 2] = band ? 255 : UInt8(truncatingIfNeeded: (x ^ y) + step * 5)
                    p[i + 3] = 255
                }
            }
        }
    }

    @Test(arguments: [false, true])
    func aNewHostAndViewerRunGlassActsAV1(hardwareAV1: Bool) throws {
        guard #available(macOS 27, *) else { return }
        if hardwareAV1 && !VTRegionDecoder.canDecodeAV1 { return } // (no AV1 hardware here: the other case covers it)
        // The kernels first, as the Host prepares them at launch.
        HostVideoEncoders.prepare(.glassAct)
        let t0 = Date()
        while !HybridRegionEncoder.isReady && Date().timeIntervalSince(t0) < 180 {
            Thread.sleep(forTimeInterval: 0.05)
        }
        try #require(HybridRegionEncoder.isReady)

        let dir = FileManager.default.temporaryDirectory.appending(path: "glassact-av1-quic-\(UInt64.random(in: 0...UInt64.max))")
        defer { try? FileManager.default.removeItem(at: dir) }
        let identity = try QUICIdentity.loadOrCreate(directory: dir, name: "id", commonName: "glassact-test")
        let fingerprint = try QUICIdentity.fingerprint(of: identity)

        let serverQueue = DispatchQueue(label: "test.av1.server"), clientQueue = DispatchQueue(label: "test.av1.client")
        let decoders = Decoders()
        let reconstructions = decoders.reconstructions
        nonisolated(unsafe) var host: HostEngine?
        nonisolated(unsafe) var viewer: ViewerEngine?
        let server = try QUICServer(port: 0, identity: identity, queue: serverQueue)
        let listening = DispatchSemaphore(value: 0), hostReady = DispatchSemaphore(value: 0)
        nonisolated(unsafe) var hostTransport: QUICTransport?
        server.onReady = { listening.signal() }
        server.onTransport = { transport in
            hostTransport = transport
            // The Host's wiring (HostController.makeEngine), its AV1 encoder returning its pictures.
            let encoders = HostVideoEncoders(choice: .glassAct, callbackQueue: serverQueue)
            let engine = HostEngine(
                width: Self.width, height: Self.height, transport: transport,
                videoEncoderFactory: { codec in
                    guard codec == VideoCodec.av1, encoders.av1 == .glassAct else { return encoders.encoder(forCodec: codec) }
                    let e = HybridRegionEncoder(callbackQueue: serverQueue)
                    e.configure = { $0.returnsPlanes = true }
                    e.onWritten = { frame, _, _ in reconstructions.add(obu: frame.obu, planes: frame.planes) }
                    return e
                },
                videoCodecPreference: encoders.preference, videoAV1FromGlassAct: encoders.av1FromGlassAct,
                clock: { MonotonicClock.nowUS })
            host = engine
            transport.onControl = { engine.handleControl($0, nowUS: MonotonicClock.nowUS) }
            transport.onVideoReset = { engine.videoChannelReset() }
            transport.onState = { if $0 == .ready { hostReady.signal() } }
            transport.start()
        }
        server.start()
        try #require(listening.wait(timeout: .now() + 5) == .success)
        let client = QUICTransport.connect(host: "127.0.0.1", port: try #require(server.port), fingerprint: fingerprint,
                                           datagramPort: server.datagramPort, identity: nil, queue: clientQueue)
        let engine = ViewerEngine(transport: client, videoDecoders: decoders.offer(hardwareAV1: hardwareAV1))
        viewer = engine
        client.onControl = { engine.handleControl($0, nowUS: MonotonicClock.nowUS) }
        client.onDatagram = { engine.handleDatagram($0, nowUS: MonotonicClock.nowUS) }
        client.onVideo = { engine.handleVideo($0, nowUS: MonotonicClock.nowUS) }
        client.onVideoReset = { engine.resetVideoStream() }
        let clientReady = DispatchSemaphore(value: 0)
        client.onState = { if $0 == .ready { clientReady.signal() } }
        client.start()
        defer {
            client.cancel()
            hostTransport?.cancel()
            server.cancel()
        }
        try #require(clientReady.wait(timeout: .now() + 10) == .success && hostReady.wait(timeout: .now() + 10) == .success)
        let h = try #require(host), v = try #require(viewer)

        var frame = [UInt8](repeating: 0, count: Self.width * Self.height * 4)
        serverQueue.sync { h.start(nowUS: MonotonicClock.nowUS) }
        // One tick of both engines; with `capture`, the screen captured (moved on a step when `moving`).
        var step = 0
        func tick(moving: Bool, capture: Bool = true) {
            if moving {
                step += 1
                Self.paint(&frame, step: step)
            }
            serverQueue.sync {
                let now = MonotonicClock.nowUS
                if capture && h.state == .running {
                    frame.withUnsafeBytes { h.encodeTick(frame: $0, bytesPerRow: Self.width * 4, dirtyRects: nil,
                                                        captureTimestampUS: now, nowUS: now) }
                }
                h.tick(nowUS: now)
            }
            clientQueue.sync { v.tick(nowUS: MonotonicClock.nowUS) }
            Thread.sleep(forTimeInterval: 0.016)
        }
        // The handshake, then a link that has shown room (LinkRoomPolicy: AV1 runs where it has).
        var deadline = Date().addingTimeInterval(10)
        while Date() < deadline && serverQueue.sync(execute: { h.state != .running }) { tick(moving: false, capture: false) }
        try #require(serverQueue.sync { h.state == .running })
        #expect(serverQueue.sync { h.negotiatedVideoCodecs } == [VideoCodec.av1, VideoCodec.hevc])
        serverQueue.sync {
            _ = h.linkRoom.noteSecond(deliveredBytesPerSecond: LinkRoomPolicy.roomyBitsPerSecond / 8,
                                     recentCapacityBytesPerSecond: 0, reports: 1)
        }

        // Motion: the region forms on AV1 and the Viewer shows its frames.
        var sawAV1 = false
        deadline = Date().addingTimeInterval(20)
        while Date() < deadline && clientQueue.sync(execute: { v.stats.videoFramesApplied }) < 40 {
            tick(moving: true)
            if clientQueue.sync(execute: { v.activeVideoCodec }) == VideoCodec.av1 { sawAV1 = true }
        }
        #expect(sawAV1, "the region ran AV1")
        #expect(serverQueue.sync { h.activeVideoCodec } == VideoCodec.av1)
        let applied = clientQueue.sync { v.stats.videoFramesApplied }
        #expect(applied >= 40, "the Viewer showed \(applied) video frames")
        #expect(clientQueue.sync { v.stats.videoDropped } == 0)

        // Still: the region dissolves and the lossless repaint makes the canvas exact.
        var matched = false
        deadline = Date().addingTimeInterval(20)
        while Date() < deadline && !matched {
            tick(moving: false)
            matched = clientQueue.sync {
                v.overlayVisibleTileCount == 0 && v.withCanvas { canvas in
                    frame.withUnsafeBytes { canvas.count == $0.count && memcmp(canvas.baseAddress, $0.baseAddress, $0.count) == 0 }
                } == true
            }
        }
        #expect(matched, "the canvas came back exact once the motion stopped")

        let checking = clientQueue.sync { decoders.checking }
        if hardwareAV1 {
            #expect(clientQueue.sync { decoders.vt } >= 1, "VideoToolbox decoded the AV1")
            #expect(checking.isEmpty)
        } else {
            let shown = checking.reduce(0) { $0 + $1.shown }, exact = checking.reduce(0) { $0 + $1.exact }
            #expect(!checking.isEmpty, "Glass Act's decoder decoded the AV1")
            #expect(shown >= 40 && exact == shown, "\(exact) of \(shown) shown frames the encoder's pictures")
            #expect(checking.allSatisfy { $0.failed == 0 })
            print("AV1SessionQUICTests: own decoder, \(exact)/\(shown) frames exact; \(applied) applied")
        }
    }
}
