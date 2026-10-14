import Testing
import GlassActWire
@testable import GlassActCore
import GlassActTestSupport

/// §3.5 ACK cadence and slot policy, driven on the tracker alone.
@Suite struct AckTrackerTests {
    private struct Ack: Equatable {
        let seq: UInt32
        let cnt: Int
        let bitmap: [UInt8]
    }

    private static func header(_ seq: UInt32, _ idx: Int, of cnt: Int) -> DatagramHeader {
        DatagramHeader(frameSeq: seq, dgramIdx: UInt16(idx), dgramCnt: UInt16(cnt), captureTimestampUS: 0)
    }

    private final class Sink {
        var acks: [Ack] = []
        func take(_ seq: UInt32, _ cnt: UInt16, _ bitmap: UnsafeRawBufferPointer) {
            acks.append(Ack(seq: seq, cnt: Int(cnt), bitmap: [UInt8](bitmap)))
        }
    }

    @Test func completionAckFiresOnceWithTheFullBitmap() {
        var tracker = AckTracker()
        let sink = Sink()
        // Arrival order shuffled, with a duplicate: completion is by count of
        // distinct datagrams.
        var rng = SplitMix64(seed: 7)
        var order = Array(0..<11)
        order.shuffle(using: &rng)
        order.insert(order[3], at: 6)
        for idx in order {
            tracker.note(Self.header(40, idx, of: 11), nowUS: 1_000, send: sink.take)
        }
        #expect(sink.acks == [Ack(seq: 40, cnt: 11, bitmap: [0xFF, 0x07])])
        #expect(tracker.latestSeq == 40)
    }

    @Test func evictionPrefersACompletedSlotOverAnIncompleteOlderOne() {
        var tracker = AckTracker()
        let sink = Sink()
        // Seq 1 is incomplete (1 of 2); 2, 3, 4 complete. All four slots taken.
        tracker.note(Self.header(1, 0, of: 2), nowUS: 0, send: sink.take)
        for seq: UInt32 in 2...4 {
            tracker.note(Self.header(seq, 0, of: 1), nowUS: 0, send: sink.take)
        }
        // A fifth batch must evict a completed non-latest slot (seq 2), not
        // the serially-oldest (seq 1, which still owes a report).
        tracker.note(Self.header(5, 0, of: 1), nowUS: 0, send: sink.take)
        sink.acks.removeAll()
        // Seq 1's late datagram completes it in its own slot: the ACK carries
        // BOTH bits. (Evicting seq 1 would have reported this datagram alone.)
        tracker.note(Self.header(1, 1, of: 2), nowUS: 0, send: sink.take)
        #expect(sink.acks == [Ack(seq: 1, cnt: 2, bitmap: [0b11])])
    }

    @Test func stragglerOlderThanEveryTrackedBatchIsReportedAlone() {
        var tracker = AckTracker()
        let sink = Sink()
        for seq: UInt32 in 10...13 {
            tracker.note(Self.header(seq, 0, of: 2), nowUS: 0, send: sink.take) // all incomplete
        }
        tracker.note(Self.header(9, 2, of: 3), nowUS: 0, send: sink.take)
        #expect(sink.acks == [Ack(seq: 9, cnt: 3, bitmap: [0b100])])
        // No tracked batch was displaced: 10..13 still complete in place.
        sink.acks.removeAll()
        for seq: UInt32 in 10...13 {
            tracker.note(Self.header(seq, 1, of: 2), nowUS: 0, send: sink.take)
        }
        #expect(sink.acks.map(\.seq) == [10, 11, 12, 13])
        #expect(sink.acks.allSatisfy { $0.bitmap == [0b11] })
    }

    @Test func partialAckAt8msKeepaliveAt100msAndExpiry() {
        var tracker = AckTracker()
        let sink = Sink()
        tracker.note(Self.header(3, 0, of: 2), nowUS: 1_000, send: sink.take)
        tracker.tick(nowUS: 8_999, send: sink.take)
        #expect(sink.acks.isEmpty) // < 8 ms after the first datagram
        tracker.tick(nowUS: 9_000, send: sink.take)
        #expect(sink.acks == [Ack(seq: 3, cnt: 2, bitmap: [0b01])])
        // Nothing new: no partial re-ACK; the keepalive waits 100 ms.
        tracker.tick(nowUS: 50_000, send: sink.take)
        #expect(sink.acks.count == 1)
        tracker.tick(nowUS: 109_000, send: sink.take)
        #expect(sink.acks.count == 2)
        // Past the expiry the incomplete slot is dropped: no more keepalives.
        tracker.tick(nowUS: 1_000 + AckTracker.slotExpiryUS + 1, send: sink.take)
        tracker.tick(nowUS: 1_000 + AckTracker.slotExpiryUS + 200_000, send: sink.take)
        #expect(sink.acks.count == 2)
    }
}
