import Foundation
import os

/// §7 signposts. Note: the encode tick interleaves diff/encode/pack in a
/// single pass over candidate tiles (one extraction per tile), so the host
/// emits one `encode` interval per tick rather than separate
/// capture/diff/encode/pack intervals; finer breakdown arrives if/when the
/// stages physically separate.
enum Signposts {
    static let host = OSSignposter(subsystem: "app.glassact", category: "host")
    static let viewer = OSSignposter(subsystem: "app.glassact", category: "viewer")
}


/// Forensics: GLASSACT_TRACE_TILE=<idx> logs every mutation touching that tile
/// on both engines (debug only; stderr).
let glassactTraceTile: Int? = ProcessInfo.processInfo.environment["GLASSACT_TRACE_TILE"].flatMap(Int.init)

@inline(__always)
func traceTile(_ idx: Int, _ message: @autoclosure () -> String) {
    if let t = glassactTraceTile, t == idx {
        FileHandle.standardError.write(Data(("[tile \(idx)] " + message() + "\n").utf8))
    }
}

/// Scroll-digest mix (verified scroll promotion, §4.8), shared by both
/// engines: one (tileIdx, tileHash) pair folded into the SCROLL_ACK digest.
/// XOR-folded by callers, so the combination is order-independent; the
/// murmur3 finalizer gives dispersion.
@inline(__always)
func scrollDigestMix(tile: Int, hash: UInt64) -> UInt64 {
    var x = hash ^ (UInt64(tile) &+ 0x9E37_79B9_7F4A_7C15)
    x ^= x >> 33
    x = x &* 0xFF51_AFD7_ED55_8CCD
    x ^= x >> 33
    x = x &* 0xC4CE_B9FE_1A85_EC53
    x ^= x >> 33
    return x
}

/// Forensics: GLASSACT_DRAG_DEBUG=1 logs the scroll detector's per-tick decision
/// path (1-D votes, probe positions, candidates, verification counts) on the
/// host engine (debug only; stderr).
let glassactDragDebug: Bool = ProcessInfo.processInfo.environment["GLASSACT_DRAG_DEBUG"] != nil

@inline(__always)
func traceDrag(_ message: @autoclosure () -> String) {
    if glassactDragDebug {
        FileHandle.standardError.write(Data(("[drag] " + message() + "\n").utf8))
    }
}
