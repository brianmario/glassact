import Testing
@testable import GlassActCore

/// What an agent's `wait_for_change` rests on: which tiles changed after a version it was given.
@Suite struct DirtyTilesTests {
    @Test func tilesChangedAfterAVersionByRegion() {
        var dirty = DirtyTiles()
        dirty.reset(tileCount: 12) // 4 × 3
        let v = dirty.version
        let all = (rows: 0..<3, columns: 0..<4)
        #expect(!dirty.anyChanged(since: v, rows: all.rows, columns: all.columns, stride: 4))

        dirty.mark(6) // row 1, column 2
        #expect(dirty.anyChanged(since: v, rows: 1..<2, columns: 2..<3, stride: 4))
        #expect(dirty.anyChanged(since: v, rows: all.rows, columns: all.columns, stride: 4))
        #expect(!dirty.anyChanged(since: v, rows: 0..<1, columns: 0..<4, stride: 4))
        #expect(!dirty.anyChanged(since: v, rows: 1..<2, columns: 3..<4, stride: 4))
        #expect(!dirty.anyChanged(since: dirty.version, rows: all.rows, columns: all.columns, stride: 4))

        // draining for the present path doesn't lose them
        var drained: [Int] = []
        dirty.drain(into: &drained)
        #expect(drained == [6])
        #expect(dirty.anyChanged(since: v, rows: 1..<2, columns: 2..<3, stride: 4))
    }

    /// A new canvas changed everything, though its tiles' stamps restart.
    @Test func aResetChangesEveryRegionForOlderVersions() {
        var dirty = DirtyTiles()
        dirty.reset(tileCount: 4)
        dirty.mark(1)
        let old = dirty.version
        dirty.reset(tileCount: 4)
        #expect(dirty.anyChanged(since: old, rows: 0..<1, columns: 0..<1, stride: 2))
        #expect(!dirty.anyChanged(since: dirty.version, rows: 0..<2, columns: 0..<2, stride: 2))
    }

    /// A version it never gave out (another session's) can't vouch for anything.
    @Test func aVersionFromElsewhereCountsAsChanged() {
        var dirty = DirtyTiles()
        dirty.reset(tileCount: 4)
        #expect(dirty.anyChanged(since: dirty.version + 1, rows: 0..<1, columns: 0..<1, stride: 2))
    }
}
