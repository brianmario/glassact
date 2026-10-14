/// §5 present-side dirty-tile set: one flag per tile, plus a count so an
/// idle drain is O(1). Apply paths mark; the present path drains.
///
/// Queue confinement: stored inline in `ViewerEngine` and mutated only on
/// the engine's confining queue (the app's `applyQueue`); apply components
/// receive it `inout`.
struct DirtyTiles {
    private var flags = ContiguousArray<Bool>()
    private(set) var count = 0
    /// Bumped on every mark (and geometry reset): "has anything on screen
    /// changed since I last looked" for readers other than the present
    /// path, which owns `drain` (an agent waiting for the screen to settle).
    private(set) var version: UInt64 = 0
    /// Per tile, the version of its last mark — "how much of the screen
    /// moved since then" (an agent tolerating a spinner while it waits for
    /// everything else to settle).
    private var stamps = ContiguousArray<UInt64>()

    /// New canvas geometry: nothing dirty.
    mutating func reset(tileCount: Int) {
        flags = ContiguousArray(repeating: false, count: tileCount)
        stamps = ContiguousArray(repeating: 0, count: tileCount)
        count = 0
        version &+= 1
    }

    @inline(__always)
    mutating func mark(_ tile: Int) {
        version &+= 1
        stamps[tile] = version
        if !flags[tile] {
            flags[tile] = true
            count += 1
        }
    }

    /// Tiles marked after `since` (a `version` read earlier).
    func changed(since: UInt64) -> Int {
        var n = 0
        for s in stamps where s > since { n += 1 }
        return n
    }

    var tileCount: Int { stamps.count }

    /// Moves the dirty tiles, in index order, into `out` (replacing its
    /// contents) and clears the set.
    mutating func drain(into out: inout [Int]) {
        out.removeAll(keepingCapacity: true)
        guard count > 0 else { return }
        for i in 0..<flags.count where flags[i] {
            out.append(i)
            flags[i] = false
        }
        count = 0
    }
}
