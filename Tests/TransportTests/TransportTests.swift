import Foundation
import Testing
import GlassActTransport

@Suite struct InProcTransportTests {
    private func faultyConfig(seed: UInt64) -> FaultConfig {
        var f = FaultConfig()
        f.dropPermille = 100
        f.dupPermille = 50
        f.reorderPermille = 200
        f.latencyMinUS = 5_000
        f.latencyMaxUS = 20_000
        f.seed = seed
        return f
    }

    private func deliveryLog(seed: UInt64) -> (bytes: [UInt8], times: [UInt64]) {
        let link = InProcLink(faults: faultyConfig(seed: seed))
        var bytes: [UInt8] = []
        var times: [UInt64] = []
        link.b.onDatagram = { data in
            bytes.append(data[0])
            times.append(link.nowUS)
        }
        for i in 0..<300 {
            link.a.sendDatagram(Data([UInt8(i & 0xFF)]))
            link.advance(toUS: UInt64(i) * 700)
        }
        link.advance(toUS: 10_000_000)
        return (bytes, times)
    }

    @Test func sameSeedReproducesTheSameDeliverySequence() {
        let first = deliveryLog(seed: 7)
        let second = deliveryLog(seed: 7)
        #expect(first.bytes == second.bytes)
        #expect(first.times == second.times)
        let other = deliveryLog(seed: 8)
        #expect(first.bytes != other.bytes || first.times != other.times)
    }

    @Test func dropRateIsApproximatelyConfigured() {
        var f = FaultConfig()
        f.dropPermille = 100
        f.seed = 3
        let link = InProcLink(faults: f)
        for _ in 0..<2000 {
            link.a.sendDatagram(Data([0]))
        }
        link.advance(toUS: 1_000_000)
        #expect(link.droppedDatagrams > 140 && link.droppedDatagrams < 260,
                "dropped \(link.droppedDatagrams)/2000 at 10%")
        #expect(link.deliveredDatagrams == 2000 - link.droppedDatagrams)
    }

    @Test func controlIsReliableOrderedUnderJitter() {
        let link = InProcLink(faults: faultyConfig(seed: 5))
        var received: [UInt8] = []
        link.b.onControl = { received.append($0[0]) }
        for i in 0..<100 {
            link.a.sendControl(Data([UInt8(i)]))
            link.advance(toUS: UInt64(i) * 300)
        }
        link.advance(toUS: 10_000_000)
        #expect(received == (0..<100).map { UInt8($0) }) // no loss, no reorder
    }

    @Test func datagramsDoReorderUnderJitter() {
        let link = InProcLink(faults: faultyConfig(seed: 11))
        var received: [UInt8] = []
        link.b.onDatagram = { received.append($0[0]) }
        for i in 0..<200 {
            link.a.sendDatagram(Data([UInt8(i & 0xFF)]))
            link.advance(toUS: UInt64(i) * 200)
        }
        link.advance(toUS: 10_000_000)
        var inversions = 0
        for i in 1..<received.count where received[i - 1] > received[i] {
            inversions += 1
        }
        #expect(inversions > 0, "expected at least one reordered delivery")
    }

    @Test func zeroFaultsDeliversEverythingInOrder() {
        let link = InProcLink()
        var received: [UInt8] = []
        link.b.onDatagram = { received.append($0[0]) }
        for i in 0..<50 {
            link.a.sendDatagram(Data([UInt8(i)]))
        }
        link.advance(toUS: 1)
        #expect(received == (0..<50).map { UInt8($0) })
        #expect(link.pendingEventCount == 0)
    }
}

@Suite struct InProcVideoTests {
    /// The video channel is reliable and FIFO within itself, independent of
    /// control, and never subject to datagram faults.
    @Test func videoChannelIsOrderedAndLossless() {
        var faults = FaultConfig()
        faults.dropPermille = 500 // datagram-only faults must not touch video
        faults.latencyMinUS = 1_000
        faults.latencyMaxUS = 1_000
        faults.seed = 5
        let link = InProcLink(faults: faults)
        var videoSeen: [Data] = []
        var controlSeen: [Data] = []
        link.b.onVideo = { videoSeen.append($0) }
        link.b.onControl = { controlSeen.append($0) }

        for i in 0..<50 {
            link.a.sendVideo(Data([UInt8(i)]))
        }
        link.a.sendControl(Data("ctl".utf8))
        link.advance(toUS: 10_000)
        #expect(videoSeen.count == 50)
        #expect(videoSeen == (0..<50).map { Data([UInt8($0)]) })
        #expect(controlSeen.count == 1)
        #expect(link.a.videoBacklogBytes == 0)
    }

    /// Behind a bottleneck, host video waits for room instead of dropping:
    /// it backs up in the send buffer (`videoBacklogBytes`), shares the
    /// queue with datagrams (which drop when it's full), arrives whole and
    /// in order at the link's rate, and shows up in the modeled RTT.
    @Test func videoSharesTheBottleneck() {
        var faults = FaultConfig()
        faults.latencyMinUS = 50_000
        faults.latencyMaxUS = 50_000
        let link = InProcLink(faults: faults)
        let rate = 250_000 // 2 Mbit/s
        link.bottleneck = .init(bytesPerSecond: rate, bufferBytes: rate / 2) // 500 ms deep
        var videoSeen: [(Int, UInt64)] = []
        link.b.onVideo = { videoSeen.append((Int($0[0]), link.nowUS)) }
        var datagramsSeen = 0
        link.b.onDatagram = { _ in datagramsSeen += 1 }

        let frame = 50_000 // 4 frames = 200 KB, 800 ms at the link's rate
        for i in 0..<4 {
            link.a.sendVideo(Data([UInt8(i)] + [UInt8](repeating: 0, count: frame - 1)))
        }
        #expect(link.a.videoBacklogBytes == 4 * frame - rate / 2, "only the buffer's worth is in the network")
        for _ in 0..<20 { link.a.sendDatagram(Data(repeating: 0, count: 1000)) }
        #expect(link.bottleneckDroppedDatagrams == 20, "a buffer full of video leaves datagrams no room")

        link.advance(toUS: 2_000_000)
        #expect(videoSeen.map { $0.0 } == [0, 1, 2, 3])
        #expect(link.a.videoBacklogBytes == 0)
        let lastArrival = videoSeen.last?.1 ?? 0
        #expect(lastArrival >= 800_000 + 50_000 && lastArrival <= 900_000, "drained at the link's rate: \(lastArrival)")
        let rtt = link.a.transportRTT
        #expect(rtt.map { $0.smoothedUS > $0.minUS } == true, "queueing shows in the RTT: \(String(describing: rtt))")
        #expect(rtt?.minUS == 100_000, "minimum RTT is the path's: \(String(describing: rtt))")
    }

    /// Without a bottleneck nothing models an RTT: the engine falls back to
    /// PING, as before.
    @Test func noBottleneckNoTransportRTT() {
        let link = InProcLink()
        link.a.sendVideo(Data([1]))
        link.advance(toUS: 1_000)
        #expect(link.a.transportRTT == nil)
    }
}
