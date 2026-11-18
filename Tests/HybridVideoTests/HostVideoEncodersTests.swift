import Foundation
import Testing
import GlassActCore
@testable import GlassActHybridVideo
import GlassActWire

/// The Host's choice of video encoders (§4.6): Glass Act's AV1 where it runs, libaom's only when
/// switched back to, HEVC alone otherwise; and which Viewers each AV1 may go to (§3.8).
@Suite struct HostVideoEncodersTests {
    static let queue = DispatchQueue(label: "test.host-encoders")

    @Test(arguments: [true, false], [true, false])
    func theChosenAV1RunsWhereItCanAndNothingStandsIn(glassAct: Bool, libaom: Bool) {
        func make(_ choice: HostVideoEncoders.AV1) -> HostVideoEncoders {
            HostVideoEncoders(choice: choice, callbackQueue: Self.queue, glassActAvailable: glassAct, libaomAvailable: libaom)
        }
        let ours = make(.glassAct)
        #expect(ours.av1 == (glassAct ? .glassAct : .none), "libaom is no fallback for Glass Act's encoder")
        #expect(ours.preference == (glassAct ? [VideoCodec.av1, VideoCodec.hevc] : [VideoCodec.hevc]))
        #expect(ours.av1FromGlassAct == glassAct)
        let back = make(.libaom)
        #expect(back.av1 == (libaom ? .libaom : .none), "nor Glass Act's for libaom's")
        #expect(back.preference == (libaom ? [VideoCodec.av1, VideoCodec.hevc] : [VideoCodec.hevc]))
        #expect(!back.av1FromGlassAct)
        #expect(make(.none).preference == [VideoCodec.hevc])
    }

    @Test func eachCodecGetsItsEncoder() {
        let hevcOnly = HostVideoEncoders(choice: .glassAct, callbackQueue: Self.queue, glassActAvailable: false, libaomAvailable: true)
        #expect(hevcOnly.encoder(forCodec: VideoCodec.hevc) is VTHEVCRegionEncoder)
        #expect(hevcOnly.encoder(forCodec: VideoCodec.av1) == nil)
        #expect(hevcOnly.encoder(forCodec: VideoCodec.reservedH264) == nil)
        let back = HostVideoEncoders(choice: .libaom, callbackQueue: Self.queue, glassActAvailable: true, libaomAvailable: true)
        #expect(back.encoder(forCodec: VideoCodec.av1) is AOMRegionEncoder)
    }

    /// Glass Act's AV1 only once its kernels have compiled: before, a region takes HEVC (the
    /// engine's next codec) instead of waiting on the compile in the engine's queue.
    @Test(.enabled(if: HostVideoEncoders.glassActAvailable, "needs macOS 27 and an Apple-silicon GPU"))
    func glassActsEncoderOnceItsKernelsHaveCompiled() async throws {
        guard #available(macOS 27, *) else { return }
        let ours = HostVideoEncoders(choice: .glassAct, callbackQueue: Self.queue)
        #expect(ours.av1 == .glassAct)
        if !HybridRegionEncoder.isReady { #expect(ours.encoder(forCodec: VideoCodec.av1) == nil) }
        let t0 = Date()
        let ready = await withCheckedContinuation { (c: CheckedContinuation<Bool, Never>) in
            HostVideoEncoders.prepare(.glassAct) { c.resume(returning: $0) }
        }
        #expect(ready && HybridRegionEncoder.isReady)
        let again = await withCheckedContinuation { (c: CheckedContinuation<Bool, Never>) in
            HybridRegionEncoder.prepare { c.resume(returning: $0) }
        }
        #expect(again, "a later prepare hears at once")
        #expect(ours.encoder(forCodec: VideoCodec.av1) is HybridRegionEncoder)
        print("HostVideoEncoders: kernels ready \(Int(Date().timeIntervalSince(t0) * 1000)) ms after prepare")
    }
}
