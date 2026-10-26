import Foundation
import Testing
@testable import GlassActCore
import GlassActTestSupport
import GlassActWire

/// Input → update latency (HostStats.inputUpdate*): from a key, click,
/// scroll or text arriving to the first update that leaves after it.
@Suite struct InputLatencyTests {
    private func input(_ host: HostEngine, kind: UInt8, at nowUS: UInt64) {
        host.handleControl(Data(ControlMessage.input(kind: kind, x: 10, y: 10, a: 0, b: 0).encoded()), nowUS: nowUS)
    }

    @Test func aKeyThenAnUpdateMeasuresTheGap() {
        var rng = SplitMix64(seed: 7301)
        let (host, _) = makeRunningHost(width: 256, height: 192)
        var frame = TestFrame(width: 256, height: 192)
        frame.fillRandom(&rng)
        frame.encode(host: host, dirtyRects: nil, nowUS: 10_000)
        input(host, kind: 5, at: 100_000) // keyDown
        frame.fillRect(x: 0, y: 0, w: 64, h: 64, &rng)
        frame.encode(host: host, dirtyRects: nil, nowUS: 140_000)
        #expect(host.stats.inputUpdateCount == 1)
        #expect(host.stats.inputUpdateUSSum == 40_000)
    }

    @Test func movesDontCountAndAnInputNothingFollowsIsDropped() {
        var rng = SplitMix64(seed: 7302)
        let (host, _) = makeRunningHost(width: 256, height: 192)
        var frame = TestFrame(width: 256, height: 192)
        frame.fillRandom(&rng)
        frame.encode(host: host, dirtyRects: nil, nowUS: 10_000)
        input(host, kind: 1, at: 100_000) // a move
        frame.fillRect(x: 0, y: 0, w: 64, h: 64, &rng)
        frame.encode(host: host, dirtyRects: nil, nowUS: 140_000)
        #expect(host.stats.inputUpdateCount == 0, "a move")
        input(host, kind: 5, at: 200_000)
        host.tick(nowUS: 200_000 + HostEngine.inputUpdateGiveUpUS + 1)
        frame.fillRect(x: 64, y: 0, w: 64, h: 64, &rng)
        frame.encode(host: host, dirtyRects: nil, nowUS: 200_000 + HostEngine.inputUpdateGiveUpUS + 10_000)
        #expect(host.stats.inputUpdateCount == 0, "nothing followed within the give-up time")
    }
}
