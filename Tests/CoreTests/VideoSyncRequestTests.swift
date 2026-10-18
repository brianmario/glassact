import Foundation
import Testing
import GlassActWire
@testable import GlassActCore
import GlassActTestSupport

/// SYNC_REQUEST (§3.5, §4.6, §5): a viewer whose region decoder can't decode
/// asks the host for a sync frame and recovers the region in place — no new
/// START, no session failure, no reconnect. The host answers at most one
/// request every `syncRequestMinIntervalUS` and only for its live region.
@Suite struct VideoSyncRequestTests {
    /// VTRegionDecoder's recovery model over the mock codec: once broken (a
    /// hardware session invalidated by sleep/wake or a media-engine reset),
    /// every frame fails until a sync frame arrives.
    final class ResyncingDecoder: VideoRegionDecoder {
        let inner = MockVideoDecoder()
        var awaitingSync = false
        var syncFramesDecoded = 0

        func start(codec: UInt8, config: [UInt8], width: Int, height: Int) -> Bool {
            inner.start(codec: codec, config: config, width: width, height: height)
        }

        func decode(_ data: [UInt8], sync: Bool,
                    onPixels: (_ pixels: UnsafeRawBufferPointer, _ bytesPerRow: Int) -> Void) -> Bool {
            if awaitingSync && !sync { return false }
            guard inner.decode(data, sync: sync, onPixels: onPixels) else {
                awaitingSync = true
                return false
            }
            if sync { syncFramesDecoded += 1 }
            awaitingSync = false
            return true
        }

        func stop() { inner.stop() }
    }

    /// Every decoder the viewer built (one per START).
    final class Decoders {
        var all: [ResyncingDecoder] = []
        func make() -> ResyncingDecoder {
            let d = ResyncingDecoder()
            all.append(d)
            return d
        }
    }

    typealias SyncRecordingEncoder = VideoRefreshTests.SyncRecordingEncoder

    static let side = 512 // 8×8 tiles, a full-screen region
    static let whole = DirtyRect(x: 0, y: 0, width: 512, height: 512)

    private func session(_ rng: inout SplitMix64, encoder: SyncRecordingEncoder,
                         decoders: Decoders) -> Harness {
        let h = Harness(width: Self.side, height: Self.side, video: true,
                        encoderFactory: { _ in encoder }, decoderFactory: { decoders.make() })
        h.frame.fillRandom(&rng)
        h.encodeFrame() // pinned cold start: the region forms on the first frame
        h.run(untilUS: h.now + 50_000)
        return h
    }

    /// Whole-screen motion, one encode tick every 50 ms.
    private func churn(_ h: Harness, _ rng: inout SplitMix64, ticks: Int, each: (() -> Void)? = nil) {
        for _ in 0..<ticks {
            each?()
            h.frame.fillRandom(&rng)
            h.encodeFrame(dirtyRects: [Self.whole])
            h.run(untilUS: h.now + 50_000)
        }
    }

    /// Tile `t` presents video, and the overlay holds the current frame as
    /// the mock codec codes it (5-bit channels, opaque).
    private func overlayShowsFrame(_ h: Harness, tile t: Int) -> Bool {
        let grid = TileGrid(width: h.frame.width, height: h.frame.height)
        let (x, y, tw, th) = grid.rect(of: t)
        return h.viewer.withPresentSources { _, overlay, shows -> Bool in
            guard shows(t), let overlay else { return false }
            for row in y..<(y + th) {
                for i in ((row * grid.width + x) * 4)..<((row * grid.width + x + tw) * 4) {
                    let want: UInt8 = i & 3 == 3 ? 0xFF : h.frame.bytes[i] & 0xF8
                    if overlay[i] != want { return false }
                }
            }
            return true
        } ?? false
    }

    private func syncRequests(_ h: Harness) -> (viewer: Int, host: Int, answered: Int) {
        (h.viewer.stats.videoSyncRequests, h.host.stats.videoSyncRequests, h.host.stats.videoSyncRequestSyncs)
    }

    /// (a) + (b) + (d): a decoder that breaks mid-motion asks at once, the
    /// host's next frame is a sync frame, and the region carries on — the
    /// same generation, the same decoder — well past the old 1 s deadline.
    @Test func brokenDecoderAsksForASyncFrameAndRecoversInPlace() {
        var rng = SplitMix64(seed: 1101)
        let encoder = SyncRecordingEncoder()
        let decoders = Decoders()
        let h = session(&rng, encoder: encoder, decoders: decoders)
        churn(h, &rng, ticks: 4)
        #expect(h.host.activeVideoRegionCount == 1, "setup: pinned region")
        #expect(decoders.all.count == 1 && h.viewer.stats.videoStarts == 1)
        let formed = h.host.stats.videoRegionsFormed
        let syncsBefore = encoder.syncTimes.count
        #expect(syncRequests(h) == (0, 0, 0), "a healthy region asks for nothing")

        decoders.all[0].awaitingSync = true // e.g. sleep/wake invalidated the hardware session
        let brokeAt = h.now
        churn(h, &rng, ticks: 6)

        #expect(syncRequests(h) == (1, 1, 1), "one request, answered by one sync frame")
        let answers = encoder.syncTimes.dropFirst(syncsBefore)
        #expect(answers.count == 1)
        if let at = answers.first {
            #expect(at - brokeAt <= 150_000, "answered on the next ticks, not by the deadline (\((at - brokeAt) / 1000) ms)")
        }
        #expect(!decoders.all[0].awaitingSync, "the sync frame resynchronized the decoder")
        #expect(decoders.all[0].syncFramesDecoded == 2) // formation + answer

        // Long past the old 1 s (and the new 2 s) deadline: still the same session and region.
        churn(h, &rng, ticks: 50)
        #expect(h.viewer.state == .running)
        #expect(h.host.state == .running)
        #expect(h.viewer.stats.videoStarts == 1, "recovered in place: no new START")
        #expect(h.host.stats.videoRegionsFormed == formed && h.host.activeVideoRegionCount == 1)
        #expect(decoders.all.count == 1)
        #expect(syncRequests(h) == (1, 1, 1))
        let grid = TileGrid(width: Self.side, height: Self.side)
        #expect((0..<grid.count).allSatisfy { overlayShowsFrame(h, tile: $0) }, "the overlay shows the live frame")

        // And the usual dissolve still settles byte-exact.
        #expect(h.settle(maxSimMS: 120_000))
        #expect(h.canvasMatchesFrame())
    }

    /// A region that stops changing right after its decoder broke still gets
    /// its sync frame: the host doesn't wait for the next change.
    @Test func staticRegionStillGetsItsSyncFrame() {
        var rng = SplitMix64(seed: 1102)
        let encoder = SyncRecordingEncoder()
        let decoders = Decoders()
        let h = session(&rng, encoder: encoder, decoders: decoders)
        churn(h, &rng, ticks: 4)
        let syncsBefore = encoder.syncTimes.count
        decoders.all[0].awaitingSync = true
        churn(h, &rng, ticks: 1) // undecodable: the viewer asks
        #expect(h.viewer.stats.videoSyncRequests == 1)
        #expect(!overlayShowsFrame(h, tile: 0), "setup: the viewer missed the last frame")
        for _ in 0..<3 { // the screen holds still
            h.encodeFrame()
            h.run(untilUS: h.now + 50_000)
        }
        #expect(encoder.syncTimes.count == syncsBefore + 1)
        #expect(h.host.stats.videoSyncRequestSyncs == 1)
        #expect(!decoders.all[0].awaitingSync)
        let grid = TileGrid(width: Self.side, height: Self.side)
        #expect((0..<grid.count).allSatisfy { overlayShowsFrame(h, tile: $0) },
                "the sync frame brought the missed content")
        #expect(h.viewer.state == .running && h.viewer.stats.videoStarts == 1)
    }

    /// (c) A viewer asking on every tick gets one sync frame per 500 ms at
    /// most — requests in between coalesce into the next allowed one, none
    /// is lost — and requests for anything but the live region are ignored.
    @Test func hostRateLimitsAndCoalescesRequests() {
        var rng = SplitMix64(seed: 1103)
        let encoder = SyncRecordingEncoder()
        let decoders = Decoders()
        let h = session(&rng, encoder: encoder, decoders: decoders)
        churn(h, &rng, ticks: 4)
        let syncsBefore = encoder.syncTimes.count
        let generation = h.host.regionGeneration
        func ask(region: UInt8 = 0, generation: UInt32) {
            h.host.handleControl(Data(ControlMessage.syncRequest(region: region, generation: generation).encoded()),
                                 nowUS: h.now)
        }

        // Not the live region: ignored, nothing encoded as a sync.
        ask(generation: generation &- 1)
        ask(region: 1, generation: generation)
        churn(h, &rng, ticks: 2)
        #expect(h.host.stats.videoSyncRequestsIgnored == 2)
        #expect(h.host.stats.videoSyncRequests == 0)
        #expect(encoder.syncTimes.count == syncsBefore)

        // A flood: a request before every tick for 3 s.
        let floodStart = h.now
        churn(h, &rng, ticks: 60) { ask(generation: generation) }
        let answers = Array(encoder.syncTimes.dropFirst(syncsBefore))
        #expect(h.host.stats.videoSyncRequests == 60)
        #expect(h.host.stats.videoSyncRequestSyncs == answers.count)
        #expect(answers.first.map { $0 - floodStart <= 50_000 } == true, "the first request is answered at once")
        for (a, b) in zip(answers, answers.dropFirst()) {
            #expect(b - a >= HostEngine.syncRequestMinIntervalUS, "sync frames \((b - a) / 1000) ms apart")
        }
        #expect((6...7).contains(answers.count), "coalesced to one per 500 ms (got \(answers.count))")
        // The decoder never broke: the extra sync frames decode like any other.
        #expect(h.viewer.state == .running && h.viewer.stats.videoSyncRequests == 0)

    }

    @Test func requestWithoutALiveRegionIsIgnored() {
        let (host, _) = makeRunningHost(width: 128, height: 64)
        host.handleControl(Data(ControlMessage.syncRequest(region: 0, generation: 0).encoded()), nowUS: 2_000)
        #expect(host.state == .running)
        #expect(host.stats.videoSyncRequestsIgnored == 1 && host.stats.videoSyncRequests == 0)
    }

    /// INV-6 at the host: mutated SYNC_REQUESTs into a live region never
    /// crash it, and whatever parses still can't buy more than one sync
    /// frame per 500 ms.
    @Test func mutatedSyncRequestsNeverCrashTheHost() {
        var rng = SplitMix64(seed: 1105)
        let encoder = SyncRecordingEncoder()
        let decoders = Decoders()
        let h = session(&rng, encoder: encoder, decoders: decoders)
        churn(h, &rng, ticks: 2)
        let syncsBefore = encoder.syncTimes.count
        let valid = ControlMessage.syncRequest(region: 0, generation: h.host.regionGeneration).encoded()
        var mutator = SplitMix64(seed: 1106)
        churn(h, &rng, ticks: 40) {
            for _ in 0..<8 {
                var bytes = valid
                for _ in 0..<mutator.int(0..<3) {
                    bytes[mutator.int(0..<bytes.count)] ^= UInt8(truncatingIfNeeded: mutator.next() | 1)
                }
                h.host.handleControl(Data(bytes), nowUS: h.now)
            }
        }
        let answers = Array(encoder.syncTimes.dropFirst(syncsBefore))
        for (a, b) in zip(answers, answers.dropFirst()) {
            #expect(b - a >= HostEngine.syncRequestMinIntervalUS)
        }
        #expect(answers.count <= 4) // 2 s of requests
    }

    /// The answering sync frame re-claims every tile the host believes shows
    /// video. The viewer dropped the claims of the frames it couldn't decode:
    /// a tile that had gone back to its exact canvas copy and then changed
    /// while the decoder was broken would otherwise keep showing its old
    /// canvas content after the sync frame, if it held still from then on.
    @Test func answeringSyncFrameReclaimsTilesTheViewerMissed() {
        var rng = SplitMix64(seed: 1104)
        let encoder = SyncRecordingEncoder()
        let decoders = Decoders()
        let h = Harness(width: Self.side, height: Self.side, video: true,
                        encoderFactory: { _ in encoder }, decoderFactory: { decoders.make() })
        h.frame.fillRandom(&rng)
        h.encodeFrame()
        #expect(h.settle(maxSimMS: 120_000), "cold start must settle")
        let grid = TileGrid(width: Self.side, height: Self.side)

        // Columns 0–5 animate (48 tiles: a region); columns 6–7 hold still
        // and hand back to their exact canvas copy by REVEAL.
        let strip = DirtyRect(x: 0, y: 0, width: 384, height: 512)
        func animate(_ ticks: Int) {
            for _ in 0..<ticks {
                h.frame.fillRect(x: 0, y: 0, w: 384, h: 512, &rng)
                h.encodeFrame(dirtyRects: [strip])
                h.run(untilUS: h.now + 50_000)
            }
        }
        animate(40)
        #expect(h.host.activeVideoRegionCount == 1, "setup: the strip formed a region")
        let still = 0 * grid.cols + 6 // tile (col 6, row 0)
        #expect(!h.viewer.tileShowsVideo(still), "setup: the still tile is back on its canvas copy")
        let decoder = decoders.all.last!

        // Broken decoder; the still tile changes once (claimed by a frame the
        // viewer can't decode) and then holds still again.
        decoder.awaitingSync = true
        h.frame.fillRect(x: 384, y: 0, w: 64, h: 64, &rng)
        h.frame.fillRect(x: 0, y: 0, w: 384, h: 512, &rng)
        h.encodeFrame(dirtyRects: [DirtyRect(x: 0, y: 0, width: 448, height: 512)])
        h.run(untilUS: h.now + 50_000)
        #expect(h.viewer.stats.videoSyncRequests == 1)
        animate(2) // the answer rides the next frame
        #expect(h.host.stats.videoSyncRequestSyncs == 1 && !decoder.awaitingSync)
        #expect(overlayShowsFrame(h, tile: still), "the sync frame shows the change the viewer missed")
        #expect(!h.viewer.tileShowsVideo(0 * grid.cols + 7), "an untouched still tile stays on its canvas copy")
        #expect(h.viewer.state == .running)
    }
}
