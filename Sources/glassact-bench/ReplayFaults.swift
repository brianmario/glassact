// replay --mode loop's video faults, by count (deterministic), and the check that every frame
// the Viewer shows is the encoder's own picture of it.
import Foundation
import GlassActAV1
import GlassActCodec
import GlassActCore
import libaom

/// The faults a Viewer's video can meet, and what came of them:
/// - `--fault-decode n,…`: the Viewer's n-th frame given to a region's decoder (counting from 1
///   over the session) reaches it corrupted, so VideoToolbox's session fails and is rebuilt,
///   dropping every frame until a sync frame (a sleep/wake or media-engine reset, §5);
/// - `--fault-reset n,…`: once the Host has sent n frames, the video stream fails: what's in
///   flight is lost, the Viewer hears of it at once and the Host 20 ms later (frames it sends
///   meanwhile go out on the replacement stream);
/// - `--fault-dissolve n,…`: once the Host has sent n frames, its region dissolves (it re-forms
///   as the screen keeps changing).
///
/// With `checksPictures` (the hybrid, whose reconstruction the adapter returns), every frame the
/// Viewer's decoder shows is decoded again by a libaom decoder that holds what the Viewer's does
/// (rebuilt where it is, fed what it's fed), and compared with the encoder's reconstruction of
/// that frame: a frame that predicted from a picture the Viewer never got wouldn't match.
final class ReplayVideoFaults: @unchecked Sendable {
    var decodeAt: Set<Int> = []
    var resetAt: [Int] = []
    var dissolveAt: [Int] = []
    var checksPictures = false
    var now: () -> UInt64 = { 0 }

    /// Any fault asked for, or the check (as the run starts: the faults by count are used up).
    private(set) var active = false
    func armed() { active = !decodeAt.isEmpty || !resetAt.isEmpty || !dissolveAt.isEmpty || checksPictures }

    // the encoder's threads (`lock`): each frame's reconstruction by its bytes, and what used GOLDEN_FRAME
    private let lock = NSLock()
    private var reconstruction: [UInt64: UInt64] = [:]
    private var goldenFrames = 0
    private var goldenSlots: Set<Int> = []
    private var keySeconds: [Double] = []

    @available(macOS 27, *)
    func written(_ frame: AV1HybridEncoder.Frame, key: Bool, seconds: Double) {
        let picture = frame.planes.count == 3 ? Self.hash(frame.planes) : nil
        let bytes = XXH64.hash(frame.obu)
        lock.withLock {
            if let picture { reconstruction[bytes] = picture }
            if frame.timing.goldenSlot >= 0 && frame.timing.copiedGolden > 0 {
                goldenFrames += 1
                goldenSlots.insert(frame.timing.goldenSlot)
            }
            if key { keySeconds.append(seconds) }
        }
    }

    static func hash(_ planes: [[UInt8]]) -> UInt64 {
        XXH64.hash(planes[2], seed: XXH64.hash(planes[1], seed: XXH64.hash(planes[0])))
    }

    // the Viewer's side (the rig's one thread)
    private(set) var viewerFrames = 0
    private(set) var injected = 0, corruptAccepted = 0
    private(set) var shown = 0, exact = 0, mismatched = 0, unchecked = 0
    private(set) var resets = 0, lostMessages = 0, dissolves = 0
    /// Per fault: frames given to a decoder and not shown until one was, the virtual time to it,
    /// and the frames that had used GOLDEN_FRAME by the fault.
    private(set) var recoveries: [(us: UInt64, dropped: Int)] = []
    private(set) var goldenAtFault: [Int] = []
    private var faultSinceUS: UInt64?
    private var droppedSince = 0
    /// Faults that came while the last one was still unrecovered.
    private(set) var overlapping = 0

    func nextViewerFrame() -> Int {
        viewerFrames += 1
        return viewerFrames
    }

    func faultStarted() {
        if faultSinceUS != nil { overlapping += 1 }
        faultSinceUS = now()
        droppedSince = 0
        goldenAtFault.append(lock.withLock { goldenFrames })
    }

    func noteInjected(accepted: Bool) {
        injected += 1
        if accepted { corruptAccepted += 1 }
    }

    func noteShown(check: UInt64?, bytes: [UInt8]) {
        shown += 1
        if let since = faultSinceUS {
            recoveries.append((now() - since, droppedSince))
            faultSinceUS = nil
        }
        guard let check else { unchecked += 1; return }
        let want = lock.withLock { reconstruction[XXH64.hash(bytes)] }
        if want == nil { unchecked += 1 } else if want == check { exact += 1 } else { mismatched += 1 }
    }

    func noteNotShown() { droppedSince += 1 }

    func noteReset(lost: Int) {
        resets += 1
        lostMessages += lost
        faultStarted()
    }

    func noteDissolve() { dissolves += 1 }

    var summary: String {
        let r = recoveries.map(\.us).sorted()
        let ks = lock.withLock { keySeconds }.sorted()
        func ms(_ us: UInt64) -> String { String(format: "%.0f", Double(us) / 1000) }
        let recov = r.isEmpty ? "-" : "p50 \(ms(r[r.count / 2])) max \(ms(r.last!)) ms"
        let keys = ks.isEmpty ? "-" : String(format: "p50 %.1f max %.1f ms", ks[ks.count / 2] * 1000, ks.last! * 1000)
        return "  faults: decode \(injected) injected (\(corruptAccepted) taken by the decoder, which was rebuilt), "
            + "resets \(resets) (\(lostMessages) messages lost), dissolves \(dissolves) · frames that copied from GOLDEN_FRAME by each fault \(goldenAtFault) (\(lock.withLock { goldenFrames }) in all, slots \(lock.withLock { goldenSlots.sorted() })) · "
            + "recovered \(recoveries.count)/\(injected + resets - overlapping): \(recov) (virtual), frames not shown \(recoveries.map(\.dropped))"
            + (faultSinceUS != nil ? " · STILL UNRECOVERED" : "") + (overlapping > 0 ? " · \(overlapping) during another" : "")
            + "\n  shown frames: \(shown), the encoder's picture exactly \(exact), not \(mismatched), unchecked \(unchecked) · "
            + "key frames' encode latency \(keys) (real)"
    }
}

/// A Viewer's region decoder with `ReplayVideoFaults`' corruption and picture check.
final class FaultingDecoder: VideoRegionDecoder {
    private let inner: any VideoRegionDecoder
    private let faults: ReplayVideoFaults
    private var codec: UInt8 = 0, config: [UInt8] = [], width = 0, height = 0
    /// A decoder rebuilt here (the corrupted frame decoded): nothing until a sync frame.
    private var awaitsSync = false
    /// The libaom decoder that holds what `inner` holds.
    private var mirror: OpaquePointer?
    private var scratch: [UInt8] = []

    init(_ inner: any VideoRegionDecoder, _ faults: ReplayVideoFaults) {
        self.inner = inner
        self.faults = faults
    }

    func start(codec: UInt8, config: [UInt8], width: Int, height: Int) -> Bool {
        (self.codec, self.config, self.width, self.height) = (codec, config, width, height)
        rebuildMirror()
        return inner.start(codec: codec, config: config, width: width, height: height)
    }

    private func rebuildMirror() {
        if let mirror { glassact_aom_dec_destroy(mirror) }
        mirror = faults.checksPictures ? glassact_aom_dec_create(4) : nil
    }

    @discardableResult
    func decode(_ data: [UInt8], sync: Bool, onPixels: (_ pixels: UnsafeRawBufferPointer, _ bytesPerRow: Int) -> Void) -> Bool {
        let n = faults.nextViewerFrame()
        if faults.decodeAt.contains(n) {
            // corrupted on the way in: VideoToolbox's session fails, is rebuilt and drops
            // everything until a sync frame (VTRegionDecoder); so is the mirror
            let accepted = inner.decode(Array(data.prefix(max(1, data.count / 3))), sync: sync) { _, _ in }
            faults.noteInjected(accepted: accepted)
            if accepted {
                // (it took the bytes: rebuilt here instead, as it would rebuild itself)
                inner.stop()
                _ = inner.start(codec: codec, config: config, width: width, height: height)
                awaitsSync = true
            }
            rebuildMirror()
            faults.faultStarted()
            faults.noteNotShown()
            return false
        }
        if awaitsSync && !sync {
            faults.noteNotShown()
            return false
        }
        let ok = inner.decode(data, sync: sync, onPixels: onPixels)
        guard ok else {
            faults.noteNotShown()
            return false
        }
        awaitsSync = false
        faults.noteShown(check: mirrorPicture(data), bytes: data)
        return true
    }

    /// The mirror's picture of `data`, hashed as `ReplayVideoFaults.hash` hashes the encoder's.
    private func mirrorPicture(_ data: [UInt8]) -> UInt64? {
        guard let mirror else { return nil }
        var f = glassact_aom_frame()
        guard glassact_aom_dec_decode(mirror, data, data.count, &f) == 0 else { return 0 }  // (a mismatch)
        let planes = [f.planes.0, f.planes.1, f.planes.2], strides = [f.strides.0, f.strides.1, f.strides.2]
        var h: UInt64 = 0
        for p in 0..<3 {
            let w = p == 0 ? width : (width + 1) / 2, rows = p == 0 ? height : (height + 1) / 2
            guard let base = planes[p] else { return 0 }
            if scratch.count < w * rows { scratch = [UInt8](repeating: 0, count: w * rows) }
            scratch.withUnsafeMutableBytes { dst in
                for r in 0..<rows {
                    (dst.baseAddress! + r * w).copyMemory(from: base + r * Int(strides[p]), byteCount: w)
                }
            }
            h = scratch.withUnsafeBytes { XXH64.hash(UnsafeRawBufferPointer(rebasing: $0[0..<(w * rows)]), seed: h) }
        }
        return h
    }

    func stop() {
        inner.stop()
        if let mirror { glassact_aom_dec_destroy(mirror) }
        mirror = nil
    }
}
