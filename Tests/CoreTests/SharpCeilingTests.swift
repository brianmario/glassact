import Foundation
import Testing
@testable import GlassActCore
import GlassActTestSupport
import GlassActWire

/// Prefer sharpness on a link with headroom (§4.6): the encoder's frame-QP
/// ceiling drops from the default to `sharpMaxFrameQP` after enough
/// pressure-free quality windows, and goes back at the first pressured one.
@Suite struct SharpCeilingTests {
    /// Records every frame-QP ceiling the host asks for.
    final class CeilingRecordingEncoder: VideoRegionEncoder {
        let inner = MockVideoEncoder(codecID: MockVideoEncoder.mockCodecID)
        var ceilings: [Int?] = []
        var smooth: [Bool] = []
        var codecID: UInt8 { inner.codecID }
        func start(width: Int, height: Int,
                   onFrame: @escaping ([UInt8], Bool, [UInt8]?) -> Void) -> Bool {
            inner.start(width: width, height: height, onFrame: onFrame)
        }
        func encode(bgra: UnsafeRawBufferPointer, forceSync: Bool, timeUS: UInt64) {
            inner.encode(bgra: bgra, forceSync: forceSync, timeUS: timeUS)
        }
        func setMaxFrameQP(_ qp: Int?) { ceilings.append(qp) }
        func setSmoothMotion(_ on: Bool) { smooth.append(on) }
        func stop() { inner.stop() }
    }

    private func session(_ encoder: CeilingRecordingEncoder, preferSharpness: Bool) -> Harness {
        var rng = SplitMix64(seed: 4401)
        let h = Harness(width: 1280, height: 640, video: true, encoderFactory: { _ in encoder })
        h.frame.fillRandom(&rng)
        h.encodeFrame() // pinned cold start: the region forms on the first frame
        h.run(untilUS: h.now + 100_000)
        h.host.applyQualityPolicy(scalePct: 100, floor: QualityFloor.automatic, preferSharpness: preferSharpness)
        return h
    }

    /// One quality window through the real evaluation path.
    private func window(_ h: Harness, pressured: Bool) {
        h.host.qualityWindowAttempts = HostEngine.videoQualityWindow
        h.host.qualityWindowPressure = pressured ? HostEngine.videoQualityWindow : 0
        h.host.evaluateQualityPressure()
    }

    @Test func earnedByHealthyWindowsLostToPressure() {
        let encoder = CeilingRecordingEncoder()
        let h = session(encoder, preferSharpness: true)
        #expect(h.host.activeVideoRegionCount == 1, "setup: pinned region")

        for _ in 1..<HostEngine.sharpHealthyWindowsMin { window(h, pressured: false) }
        #expect(encoder.ceilings.isEmpty, "not before enough healthy windows")
        window(h, pressured: false)
        #expect(encoder.ceilings == [HostEngine.sharpMaxFrameQP])
        #expect(h.host.stats.sharpCeilingOn == 1)

        window(h, pressured: true)
        #expect(encoder.ceilings.last == .some(nil), "pressure restores the default ceiling at once")
        #expect(h.host.stats.sharpCeilingOff == 1)
        #expect(h.host.qualityLevel == 0, "prefer sharpness still never steps the quality ladder")
    }

    @Test func eachFallBackDoublesTheNextWait() {
        let encoder = CeilingRecordingEncoder()
        let h = session(encoder, preferSharpness: true)
        var needed = HostEngine.sharpHealthyWindowsMin
        for _ in 0..<6 {
            for _ in 1..<needed { window(h, pressured: false) }
            #expect(!h.host.sharpCeiling, "off until \(needed) healthy windows")
            window(h, pressured: false)
            #expect(h.host.sharpCeiling, "on after \(needed) healthy windows")
            window(h, pressured: true)
            needed = min(needed * 2, HostEngine.sharpHealthyWindowsMax)
        }
        #expect(h.host.sharpHealthyNeeded == HostEngine.sharpHealthyWindowsMax, "the wait is capped")

        // A pressured window part-way through a healthy run starts it over.
        for _ in 1..<needed { window(h, pressured: false) }
        window(h, pressured: true)
        window(h, pressured: false)
        #expect(!h.host.sharpCeiling)
    }

    @Test func offWithoutPreferSharpness() {
        let encoder = CeilingRecordingEncoder()
        let h = session(encoder, preferSharpness: false)
        for _ in 0..<(HostEngine.sharpHealthyWindowsMin * 4) { window(h, pressured: false) }
        #expect(encoder.ceilings.isEmpty)
        #expect(!h.host.sharpCeiling)
    }

    @Test func turningPreferenceOffRestoresDefaultAndResetsTheWait() {
        let encoder = CeilingRecordingEncoder()
        let h = session(encoder, preferSharpness: true)
        for _ in 0..<HostEngine.sharpHealthyWindowsMin { window(h, pressured: false) }
        window(h, pressured: true)
        for _ in 0..<(HostEngine.sharpHealthyWindowsMin * 2) { window(h, pressured: false) }
        #expect(h.host.sharpCeiling)

        h.host.applyQualityPolicy(scalePct: 100, floor: QualityFloor.automatic, preferSharpness: false)
        #expect(!h.host.sharpCeiling)
        #expect(encoder.ceilings.last == .some(nil))
        #expect(h.host.sharpHealthyNeeded == HostEngine.sharpHealthyWindowsMin)
    }

    @Test func aReformedRegionStartsUnderTheCurrentCeiling() {
        var encoders: [CeilingRecordingEncoder] = []
        var rng = SplitMix64(seed: 4402)
        let h = Harness(width: 1280, height: 640, video: true, encoderFactory: { _ in
            let e = CeilingRecordingEncoder()
            encoders.append(e)
            return e
        })
        h.frame.fillRandom(&rng)
        h.encodeFrame()
        h.run(untilUS: h.now + 100_000)
        h.host.applyQualityPolicy(scalePct: 100, floor: QualityFloor.automatic, preferSharpness: true)
        for _ in 0..<HostEngine.sharpHealthyWindowsMin { window(h, pressured: false) }
        #expect(h.host.sharpCeiling)

        // Let the region dissolve on a quiet screen, then move everything.
        h.run(untilUS: h.now + 10_000_000)
        #expect(h.host.activeVideoRegionCount == 0, "setup: the region dissolved")
        for _ in 0..<4 {
            h.frame.fillRandom(&rng)
            h.encodeFrame()
            h.run(untilUS: h.now + 50_000)
        }
        #expect(h.host.activeVideoRegionCount == 1, "setup: the region re-formed")
        #expect(encoders.count >= 2)
        #expect(encoders.last?.ceilings == [HostEngine.sharpMaxFrameQP],
                "the new encoder starts at the sharper ceiling")
    }
}
