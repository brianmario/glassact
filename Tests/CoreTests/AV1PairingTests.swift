import Foundation
import Testing
import GlassActWire
@testable import GlassActCore
import GlassActTestSupport

/// Which AV1 a session runs (§3.8, §4.6, DESIGN's pairing table): Glass Act's encoder (the
/// hybrid) on an up-to-date Host, libaom's on an older one (or this one switched back), each to
/// the Viewers that decode it. VideoToolbox (AV1 hardware) decodes both; Glass Act's own decoder,
/// on a Viewer without the hardware, only the hybrid's streams, so it's offered under its own bit,
/// `videoAV1GlassAct`, which older Hosts don't know.
///
/// Every pairing of new and old Host and Viewer, with and without AV1 hardware, through the real
/// engines with mock codecs on the real ids (AV1 3, HEVC 1). A mock AV1 stream says whose encoder
/// made it, and Glass Act's mock decoder refuses libaom's, as the real one does. Old peers are
/// what released builds (26.10.0 on) send and do: their HELLO / HELLO_OK caps as literals, and
/// their rules (an old Host sends AV1 only under `videoAV1`; an old Viewer takes a START only for
/// a codec it offered, AV1 under `videoAV1`).
@Suite struct AV1PairingTests {
    /// Who made a stream (its config's first byte).
    enum Maker: UInt8 { case hevc = 0, glassAct = 1, libaom = 2 }

    /// A mock encoder on a real codec id whose config names its maker.
    final class TaggedEncoder: VideoRegionEncoder {
        let codecID: UInt8
        let maker: Maker
        let shown: Shown?
        private let inner = MockVideoEncoder()
        init(codecID: UInt8, maker: Maker, shown: Shown? = nil) {
            self.codecID = codecID
            self.maker = maker
            self.shown = shown
        }
        func setReducedFrames(_ allowed: Bool) { shown?.reducedFrames.append(allowed) }
        func start(width: Int, height: Int, onFrame: @escaping ([UInt8], Bool, [UInt8]?) -> Void) -> Bool {
            let tag = maker.rawValue
            return inner.start(width: width, height: height) { data, sync, config in
                onFrame(data, sync, config.map { [tag] + $0 })
            }
        }
        func encode(bgra: UnsafeRawBufferPointer, forceSync: Bool, timeUS: UInt64) {
            inner.encode(bgra: bgra, forceSync: forceSync, timeUS: timeUS)
        }
        func stop() { inner.stop() }
    }

    /// What the Viewer's decoders started and showed, by maker.
    final class Shown: @unchecked Sendable {
        var started: [Maker] = []
        var refused: [Maker] = []
        var frames = 0
        /// The engine's `setReducedFrames` calls on the region's encoder.
        var reducedFrames: [Bool] = []
    }

    /// A mock decoder that takes streams from `accepts` only: VideoToolbox any, Glass Act's own
    /// decoder only Glass Act's encoder's.
    final class TaggedDecoder: VideoRegionDecoder {
        let accepts: Set<Maker>
        let shown: Shown
        private let inner = MockVideoDecoder()
        init(accepts: Set<Maker>, shown: Shown) {
            self.accepts = accepts
            self.shown = shown
        }
        func start(codec: UInt8, config: [UInt8], width: Int, height: Int) -> Bool {
            guard let tag = config.first.flatMap(Maker.init(rawValue:)) else { return false }
            guard accepts.contains(tag),
                  inner.start(codec: MockVideoEncoder.mockCodecID, config: Array(config.dropFirst()), width: width, height: height)
            else {
                shown.refused.append(tag)
                return false
            }
            shown.started.append(tag)
            return true
        }
        func decode(_ data: [UInt8], sync: Bool,
                    onPixels: (_ pixels: UnsafeRawBufferPointer, _ bytesPerRow: Int) -> Void) -> Bool {
            let ok = inner.decode(data, sync: sync, onPixels: onPixels)
            if ok { shown.frames += 1 }
            return ok
        }
        func stop() { inner.stop() }
    }

    // MARK: - The peers

    enum HostKind: CaseIterable, Sendable {
        /// This release, where Glass Act's encoder runs (macOS 27, Apple-silicon GPU).
        case newGlassAct
        /// This release where it can't (macOS 15.5–26, Intel): HEVC only.
        case newHEVCOnly
        /// This release switched back to libaom (`HostVideoEncoders.AV1.libaom`).
        case newLibaom
        /// A released Host on Apple silicon (26.10.0–26.11): libaom's AV1, then HEVC.
        case old
        /// A released Host on Intel: HEVC only.
        case oldIntel

        var preference: [UInt8] {
            switch self {
            case .newGlassAct, .newLibaom, .old: [VideoCodec.av1, VideoCodec.hevc]
            case .newHEVCOnly, .oldIntel: [VideoCodec.hevc]
            }
        }

        var av1Maker: Maker { self == .newGlassAct ? .glassAct : .libaom }
        var av1FromGlassAct: Bool { self == .newGlassAct }
    }

    enum ViewerKind: CaseIterable, Sendable {
        /// This release, AV1 on, with VideoToolbox's AV1 (M3 and later).
        case newHardware
        /// This release, AV1 on, without it (M1, M2, Intel, older iPads): Glass Act's decoder.
        case newNoHardware
        /// This release, AV1 off.
        case newOff
        /// A released Viewer, AV1 on, M3 and later.
        case oldHardware
        /// A released Viewer without AV1 hardware (its switch was disabled), or AV1 off.
        case oldNoAV1

        func decoders(_ shown: Shown) -> ViewerVideoDecoders {
            let hardware: @Sendable () -> any VideoRegionDecoder = {
                TaggedDecoder(accepts: [.hevc, .glassAct, .libaom], shown: shown)
            }
            let own: @Sendable () -> any VideoRegionDecoder = { TaggedDecoder(accepts: [.glassAct], shown: shown) }
            switch self {
            case .newHardware: return .offer(av1: true, hardwareAV1: true, hardware: hardware, glassActAV1: own)
            case .newNoHardware: return .offer(av1: true, hardwareAV1: false, hardware: hardware, glassActAV1: own)
            case .newOff: return .offer(av1: false, hardwareAV1: true, hardware: hardware, glassActAV1: own)
            // HELLO_OK's video caps as released Viewers send them: HEVC, AV1 (0x03); HEVC (0x01).
            // One VideoToolbox decoder for every codec, as theirs.
            case .oldHardware: return ViewerVideoDecoders(caps: 0x03) { _ in hardware() }
            case .oldNoAV1: return ViewerVideoDecoders(caps: 0x01) { _ in hardware() }
            }
        }
    }

    /// What the session should run: the codec, and whose AV1.
    static func expected(_ host: HostKind, _ viewer: ViewerKind) -> Maker {
        switch (host, viewer) {
        case (.newHEVCOnly, _), (.oldIntel, _), (_, .newOff), (_, .oldNoAV1): .hevc
        case (.newGlassAct, _): .glassAct
        // libaom's only where VideoToolbox decodes it; Glass Act's decoder can't, so HEVC there
        case (.newLibaom, .newNoHardware), (.old, .newNoHardware): .hevc
        case (.newLibaom, _), (.old, _): .libaom
        }
    }

    /// The pinned cold start forms the region on the first frame, on a link that has shown room
    /// (AV1 needs it, LinkRoomPolicy).
    static func session(_ host: HostKind, _ viewer: ViewerKind, shown: Shown) -> Harness {
        var rng = SplitMix64(seed: 709)
        let h = Harness(width: 320, height: 320, video: true, hostCodecs: host.preference,
                        encoderFactory: { codec in
                            codec == VideoCodec.av1 ? TaggedEncoder(codecID: codec, maker: host.av1Maker, shown: shown)
                                : TaggedEncoder(codecID: codec, maker: .hevc, shown: shown)
                        },
                        viewerDecoders: viewer.decoders(shown), hostAV1FromGlassAct: host.av1FromGlassAct)
        _ = h.host.linkRoom.noteSecond(deliveredBytesPerSecond: LinkRoomPolicy.roomyBitsPerSecond / 8,
                                      recentCapacityBytesPerSecond: 0, reports: 1)
        h.frame.fillRandom(&rng)
        h.encodeFrame()
        h.run(untilUS: h.now + 200_000)
        return h
    }

    static let pairings = HostKind.allCases.flatMap { h in ViewerKind.allCases.map { (h, $0) } }

    @Test(arguments: pairings)
    func everyPairingRunsTheAV1ItCanDecode(host: HostKind, viewer: ViewerKind) {
        let shown = Shown()
        let h = Self.session(host, viewer, shown: shown)
        let want = Self.expected(host, viewer)
        let codec = want == .hevc ? VideoCodec.hevc : VideoCodec.av1
        #expect(h.host.activeVideoRegionCount == 1)
        #expect(h.host.activeVideoCodec == codec)
        #expect(h.viewer.activeVideoCodec == codec, "VIDEO_START carries the codec id")
        #expect(shown.started == [want], "the Viewer's decoder took the stream")
        #expect(shown.refused.isEmpty, "no stream went to a decoder that can't take it")
        #expect(shown.frames > 0)
        #expect(h.viewer.stats.videoDropped == 0)
        #expect(h.settle())
        #expect(h.canvasMatchesFrame())
        // reduced frames (`videoReducedFrames`) only from Glass Act's AV1 to a Viewer of this
        // release decoding with VideoToolbox (it scales them for free); a released one fails on them
        let reduced = want == .glassAct && viewer == .newHardware
        #expect(shown.reducedFrames == [reduced], "setReducedFrames: \(shown.reducedFrames)")
    }

    // MARK: - Caps on the wire

    /// HELLO_OK's video caps, by Viewer. `videoAV1` only with VideoToolbox's AV1;
    /// `videoAV1GlassAct` with any AV1 decoder; never AV1 without the opt-in.
    @Test func viewersOfferWhatTheyDecode() {
        let shown = Shown()
        let (hevc, av1, ours) = (WireCaps.videoHEVC, WireCaps.videoAV1 | WireCaps.videoReducedFrames, WireCaps.videoAV1GlassAct)
        #expect(ViewerKind.newHardware.decoders(shown).caps == hevc | av1 | ours)
        #expect(ViewerKind.newNoHardware.decoders(shown).caps == hevc | ours)
        #expect(ViewerKind.newOff.decoders(shown).caps == hevc)
        #expect(ViewerVideoDecoders.offer(av1: true, hardwareAV1: false, hardware: { MockVideoDecoder() },
                                          glassActAV1: nil).caps == hevc,
                "VideoToolbox alone, without the hardware: HEVC")
        #expect(ViewerVideoDecoders.offer(av1: true, hardwareAV1: true, hardware: { MockVideoDecoder() },
                                          glassActAV1: nil).caps == hevc | av1 | ours,
                "VideoToolbox's AV1 decodes the hybrid's streams too")
    }

    /// The decoder a region gets: VideoToolbox whenever it decodes AV1 (a libaom stream can
    /// come only then), Glass Act's otherwise; nothing for AV1 without the opt-in.
    @Test func viewersPickVideoToolboxWheneverItDecodesAV1() {
        final class Hardware: VideoRegionDecoder {
            func start(codec: UInt8, config: [UInt8], width: Int, height: Int) -> Bool { true }
            func decode(_ data: [UInt8], sync: Bool, onPixels: (UnsafeRawBufferPointer, Int) -> Void) -> Bool { true }
            func stop() {}
        }
        final class Own: VideoRegionDecoder {
            func start(codec: UInt8, config: [UInt8], width: Int, height: Int) -> Bool { true }
            func decode(_ data: [UInt8], sync: Bool, onPixels: (UnsafeRawBufferPointer, Int) -> Void) -> Bool { true }
            func stop() {}
        }
        func offer(av1: Bool, hardwareAV1: Bool) -> ViewerVideoDecoders {
            .offer(av1: av1, hardwareAV1: hardwareAV1, hardware: { Hardware() }, glassActAV1: { Own() })
        }
        #expect(offer(av1: true, hardwareAV1: true).decoder(forCodec: VideoCodec.av1) is Hardware)
        #expect(offer(av1: true, hardwareAV1: false).decoder(forCodec: VideoCodec.av1) is Own)
        #expect(offer(av1: false, hardwareAV1: true).decoder(forCodec: VideoCodec.av1) == nil)
        #expect(offer(av1: false, hardwareAV1: false).decoder(forCodec: VideoCodec.av1) == nil)
        for (av1, hw) in [(true, true), (true, false), (false, false)] {
            #expect(offer(av1: av1, hardwareAV1: hw).decoder(forCodec: VideoCodec.hevc) is Hardware)
            #expect(offer(av1: av1, hardwareAV1: hw).decoder(forCodec: VideoCodec.reservedH264) == nil)
        }
    }

    /// HELLO's video caps, by Host. A Host whose AV1 is libaom's sends what released Hosts do
    /// (HEVC, AV1); Glass Act's adds `videoAV1GlassAct`, which released Viewers ignore.
    @Test(arguments: HostKind.allCases)
    func hostsSayWhoseAV1TheyRun(host kind: HostKind) {
        let capture = CaptureTransport()
        let host = HostEngine(width: 320, height: 320, transport: capture,
                              videoEncoderFactory: { MockVideoEncoder(codecID: $0) },
                              videoCodecPreference: kind.preference, videoAV1FromGlassAct: kind.av1FromGlassAct)
        host.start(nowUS: 0)
        let caps = controlMessages(capture.sentControl).compactMap { message -> UInt32? in
            if case let .hello(_, _, _, _, _, caps) = message { return caps }
            return nil
        }.first
        let video = caps.map { $0 & (WireCaps.videoHEVC | WireCaps.videoAV1 | WireCaps.videoAV1GlassAct) }
        switch kind {
        case .newGlassAct: #expect(video == 0x83)
        case .newLibaom, .old: #expect(video == 0x03, "as released Hosts on Apple silicon")
        case .newHEVCOnly, .oldIntel: #expect(video == 0x01, "as released Hosts on Intel")
        }
    }

    /// A released Host's HELLO, verbatim (WireCompatSamples, 26.10.0 on): this Viewer, without AV1
    /// hardware, answers with `videoAV1GlassAct` and not `videoAV1`, so the old Host, which knows
    /// only `videoAV1`, sends HEVC.
    @Test func aReleasedHostSeesNoAV1FromAViewerWithoutTheHardware() {
        let capture = CaptureTransport()
        let shown = Shown()
        let viewer = ViewerEngine(transport: capture, videoDecoders: ViewerKind.newNoHardware.decoders(shown))
        let hello = ControlMessage.hello(ver: 4, width: 2940, height: 1912, tileSize: 64, pixfmt: 1, caps: 0x0E71)
        viewer.handleControl(Data(hello.encoded()), nowUS: 0)
        let caps = controlMessages(capture.sentControl).compactMap { message -> UInt32? in
            if case let .helloOK(_, caps, _, _, _, _) = message { return caps }
            return nil
        }.first
        #expect(caps.map { $0 & WireCaps.videoAV1 } == 0)
        #expect(caps.map { $0 & WireCaps.videoAV1GlassAct } == WireCaps.videoAV1GlassAct)
        #expect(caps.map { $0 & WireCaps.videoHEVC } == WireCaps.videoHEVC)
    }

    /// A Viewer takes AV1 under either AV1 bit it offered, and nothing it didn't: a Viewer with AV1
    /// off drops an AV1 START.
    @Test func viewersTakeAV1OnlyUnderABitTheyOffered() {
        func starts(_ kind: ViewerKind, maker: Maker) -> Int {
            let capture = CaptureTransport()
            let shown = Shown()
            let viewer = ViewerEngine(transport: capture, videoDecoders: kind.decoders(shown))
            let hello = ControlMessage.hello(ver: WireVersion.current, width: 128, height: 64,
                                             tileSize: 64, pixfmt: PixelFormat.bgra8sRGB, caps: 0)
            viewer.handleControl(Data(hello.encoded()), nowUS: 0)
            let start = VideoMessage.start(region: 0, generation: 1, x: 0, y: 0, width: 128, height: 64,
                                           codec: VideoCodec.av1,
                                           config: [maker.rawValue] + MockVideoEncoder.config(width: 128, height: 64))
            viewer.handleVideo(Data(start.encoded()), nowUS: 0)
            return viewer.stats.videoStarts
        }
        #expect(starts(.newHardware, maker: .glassAct) == 1)
        #expect(starts(.newHardware, maker: .libaom) == 1)
        #expect(starts(.newNoHardware, maker: .glassAct) == 1)
        #expect(starts(.newNoHardware, maker: .libaom) == 0, "Glass Act's decoder refuses libaom's stream")
        #expect(starts(.newOff, maker: .glassAct) == 0, "AV1 wasn't offered")
        #expect(starts(.oldNoAV1, maker: .glassAct) == 0, "as a released Viewer: AV1 wasn't offered")
    }
}
