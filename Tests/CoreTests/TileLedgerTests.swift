import Testing
@testable import GlassActCore

/// TileLedger in isolation: INV-9's one-slot-per-tile rules and the owed-send
/// queues that keep cold and deferred tiles from stranding.
@Suite struct TileLedgerTests {
    @Test func INV_9_staleAckAndStaleTimeoutAreIgnored() {
        var l = TileLedger(count: 4)
        l.markInflight(0, hash: 0xA, seq: 1)
        l.markInflight(0, hash: 0xB, seq: 2) // re-send overwrites the slot
        let staleAck = l.commit(0, seq: 1, hash: 0xA)
        let staleTimeout = l.invalidate(0, seq: 1)
        #expect(!staleAck, "ACK for the overwritten send")
        #expect(!staleTimeout, "timeout for the overwritten send")
        #expect(l[0].inflightSeq == 2 && l[0].ackedHash == 0)
        let current = l.commit(0, seq: 2, hash: 0xB)
        #expect(current)
        #expect(l[0].ackedHash == 0xB && l[0].inflightSeq == 0 && l[0].inflightHash == 0)
    }

    @Test func timeoutMarksColdAndSchedulesTheRepaint() {
        var l = TileLedger(count: 4)
        l.markInflight(1, hash: 0xA, seq: 1)
        _ = l.commit(1, seq: 1, hash: 0xA)
        l.markInflight(1, hash: 0xB, seq: 2)
        let invalidated = l.invalidate(1, seq: 2)
        #expect(invalidated)
        #expect(l[1].ackedHash == 0, "the viewer's copy is unknown")
        #expect(l.pendingRepaintCount == 1, "…and the tile is owed a send")
        #expect(l.qualifies(1, hash: 0xA), "even reverted content re-sends")
    }

    @Test func deferralRoutesColdToRepaintAndWarmToCarry() {
        var l = TileLedger(count: 8)
        l.markInflight(2, hash: 5, seq: 1)
        _ = l.commit(2, seq: 1, hash: 5)       // tile 2 warm
        l.deferTile(2)                         // warm → carry (not settle work)
        l.deferTile(3)                         // cold → repaint (settle work)
        l.deferTile(3)                         // idempotent
        var volunteered: [Int] = []
        let settleWork = l.drainOwed { volunteered.append($0) }
        #expect(settleWork == 1)
        #expect(volunteered.sorted() == [2, 3])
        var again: [Int] = []
        let second = l.drainOwed { again.append($0) }
        #expect(second == 0 && again.isEmpty, "queues empty after a drain")
    }

    @Test func settledMeansAckedWithNothingInFlight() {
        var l = TileLedger(count: 2)
        #expect(!l.isSettled(0))
        l.markInflight(0, hash: 7, seq: 1)
        _ = l.commit(0, seq: 1, hash: 7)
        #expect(l.isSettled(0))
        l.markInflight(0, hash: 8, seq: 2)
        #expect(!l.isSettled(0), "a newer send is in flight")
        l.clearInflight(0, onlyIfSeq: 1)
        #expect(!l.isSettled(0), "clearing another batch's slot does nothing")
        l.clearInflight(0)
        #expect(l.isSettled(0))
    }
}
