import Foundation
import Testing
@testable import GlassActCore
import GlassActTestSupport
import GlassActWire

/// Prefer smooth motion on a thin link (§4.6): QUALITY preference 2 loosens
/// the encoder's frame-QP ceiling to `smoothMaxFrameQP` while the link has
/// no room (`LinkRoomPolicy`), and restores the default once it has.
@Suite struct SmoothFloorTests {
    typealias Encoder = SharpCeilingTests.CeilingRecordingEncoder

    private func session(_ encoder: Encoder) -> Harness {
        var rng = SplitMix64(seed: 4402)
        let h = Harness(width: 640, height: 384, video: true, encoderFactory: { _ in encoder })
        h.frame.fillRandom(&rng)
        h.encodeFrame() // pinned cold start: the region forms on the first frame
        h.run(untilUS: h.now + 100_000)
        return h
    }

    /// A session starts without room, so the looser ceiling goes on at once;
    /// once the link has delivered room, the default comes back.
    @Test(.tags(.slow), .notInFastLane) func onWhileTheLinkHasNoRoomOffOnceItHas() {
        let encoder = Encoder()
        let h = session(encoder)
        #expect(!h.host.linkRoom.hasRoom, "setup: no room proven yet")
        h.host.applyQualityPolicy(scalePct: 100, floor: QualityFloor.automatic, preferSharpness: false,
                                  preferSmoothness: true)
        #expect(encoder.ceilings == [HostEngine.smoothMaxFrameQP])
        #expect(h.host.regionMaxFrameQP == HostEngine.smoothMaxFrameQP, "a region that forms now starts under it")
        #expect(h.host.stats.smoothFloorOn == 1)

        // Motion over the fast in-process link: a second of it proves room (a
        // static screen delivers nothing to measure).
        var rng = SplitMix64(seed: 4403)
        for _ in 0..<150 {
            h.frame.fillRect(x: 0, y: 0, w: 384, h: 384, &rng)
            h.encodeFrame()
            h.run(untilUS: h.now + 16_667)
        }
        #expect(h.host.linkRoom.hasRoom)
        #expect(encoder.ceilings.last == .some(nil), "the default ceiling once the link has room")
        #expect(h.host.stats.smoothFloorOff == 1)
    }

    /// Balanced and prefer sharpness never loosen the ceiling, room or not.
    @Test func onlyTheSmoothPreferenceLoosensIt() {
        let encoder = Encoder()
        let h = session(encoder)
        h.host.applyQualityPolicy(scalePct: 100, floor: QualityFloor.automatic, preferSharpness: false)
        h.host.applyQualityPolicy(scalePct: 100, floor: QualityFloor.automatic, preferSharpness: true)
        #expect(!encoder.ceilings.contains(.some(HostEngine.smoothMaxFrameQP)))
        #expect(h.host.stats.smoothFloorOn == 0)
    }

    /// Turning the preference off restores the default at once.
    @Test func turningItOffRestoresTheDefault() {
        let encoder = Encoder()
        let h = session(encoder)
        h.host.applyQualityPolicy(scalePct: 100, floor: QualityFloor.automatic, preferSharpness: false,
                                  preferSmoothness: true)
        h.host.applyQualityPolicy(scalePct: 100, floor: QualityFloor.automatic, preferSharpness: false)
        #expect(encoder.ceilings == [HostEngine.smoothMaxFrameQP, nil])
        #expect(h.host.regionMaxFrameQP == nil)
    }

    /// The viewer asks for smooth motion only from a host that understands
    /// it: older hosts reject preference 2 as malformed (§3.8).
    @Test func theViewerSendsItOnlyToAHostThatUnderstandsIt() {
        func sentPreference(hostCaps: UInt32) -> UInt8? {
            let capture = CaptureTransport()
            let viewer = ViewerEngine(transport: capture)
            let hello = ControlMessage.hello(ver: WireVersion.current, width: 256, height: 192, tileSize: 64,
                                             pixfmt: PixelFormat.bgra8sRGB, caps: hostCaps)
            viewer.handleControl(Data(hello.encoded()), nowUS: 0)
            capture.sentControl.removeAll()
            viewer.sendQualityPolicy(presentedScalePct: 100, floor: 0, preferSharpness: false, preferSmoothness: true)
            var d = ControlDeframer()
            for data in capture.sentControl { d.append(Array(data)) }
            while let message = d.next() {
                if case let .message(.quality(_, _, pref)) = message { return pref }
            }
            return nil
        }
        #expect(sentPreference(hostCaps: WireCaps.smoothnessPreference) == 2)
        #expect(sentPreference(hostCaps: 0) == 0)
    }
}
