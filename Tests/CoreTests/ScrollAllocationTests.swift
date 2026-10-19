import Foundation
import Synchronization
import Testing
import GlassActWire
@testable import GlassActCore
import GlassActTransport
import GlassActTestSupport

/// INV-7 on the scroll path (§4.8, §8.1): a steady-state heavy tick runs
/// detection (row/column signature votes, the 2-D drag probe), verification,
/// emission and SCROLL_ACK repair without a heap allocation. The one
/// allocation left per emitted SCROLL is the Data the transport API takes,
/// the same boundary allocation every datagram has.
///
/// Allocations are counted on the calling thread through libmalloc's
/// `malloc_logger` hook (the one MallocStackLogging uses). The counts are
/// asserted in optimized builds only — `just test-alloc` (`swift test -c
/// release`): at -Onone the codecs' generic and SIMD code allocates on its
/// own (xxh64's streaming state, ~100 allocations per hashed row), which
/// says nothing about the shipped engine. Under a malloc that doesn't
/// report through the hook (AddressSanitizer), calibration reads 0 and the
/// counts aren't asserted either. In a debug build the scenario still runs
/// and its scrolls are checked.
@Suite(.serialized) struct ScrollAllocationTests {
    static let width = 1280, height = 768 // 20×12 tiles
    static let stripeCol = 9 // a static column of tiles: not dirty, inside every scroll rect

    /// Host and viewer wired through capture transports, pumped by hand so
    /// nothing but the engine runs inside a measured window.
    final class Loop {
        let host: HostEngine
        let hostOut: CaptureTransport
        let viewer: ViewerEngine
        let viewerOut: CaptureTransport
        var now: UInt64 = 10_000

        init(width: Int, height: Int) {
            (host, hostOut) = makeRunningHost(width: width, height: height)
            (viewer, viewerOut) = makeRunningViewer(width: width, height: height)
        }

        /// Delivers everything both ways until quiet: datagrams and SCROLLs
        /// to the viewer, ACKs and SCROLL_ACKs back to the host.
        func pump() {
            for _ in 0..<4 {
                now += 2_000
                let datagrams = hostOut.sentDatagrams, toViewer = hostOut.sentControl
                hostOut.sentDatagrams.removeAll()
                hostOut.sentControl.removeAll()
                for c in toViewer { viewer.handleControl(c, nowUS: now) }
                for d in datagrams { viewer.handleDatagram(d, nowUS: now) }
                viewer.tick(nowUS: now)
                let toHost = viewerOut.sentControl
                viewerOut.sentControl.removeAll()
                for c in toHost { host.handleControl(c, nowUS: now) }
                host.tick(nowUS: now)
            }
        }

        func encode(_ frame: TestFrame) {
            now += 16_000
            frame.encode(host: host, nowUS: now)
            pump()
        }

        /// The first half of `encodeTick` by hand — candidates (every tile
        /// but the static stripe), their hashes — then `maybeEmitScroll`
        /// alone inside the counted window. Returns its allocations.
        func countScrollTick(_ frame: TestFrame) -> Int? {
            now += 16_000
            let grid = host.grid
            host.candidateEpoch &+= 1
            host.worklist.removeAll(keepingCapacity: true)
            for idx in 0..<grid.count where idx % grid.cols != ScrollAllocationTests.stripeCol {
                host.candidateMark[idx] = host.candidateEpoch
                host.worklist.append(Int32(idx))
            }
            host.worklistFresh = host.worklist.count
            hostOut.sentControl.reserveCapacity(hostOut.sentControl.count + 8)
            return frame.bytes.withUnsafeBytes { raw in
                host.hashCandidates(frame: raw, bytesPerRow: frame.width * 4)
                return MallocCounter.count {
                    host.maybeEmitScroll(frame: raw, bytesPerRow: frame.width * 4)
                }
            }
        }
    }

    /// Every pixel random, except the static stripe column (one flat colour).
    static func noise(_ rng: inout SplitMix64) -> TestFrame {
        var frame = TestFrame(width: width, height: height)
        frame.fillRandom(&rng)
        paintStripe(&frame)
        return frame
    }

    static func paintStripe(_ frame: inout TestFrame) {
        let x0 = stripeCol * TileGrid.tileSize
        let width = frame.width
        frame.bytes.withUnsafeMutableBytes { raw in
            for y in 0..<(raw.count / (width * 4)) {
                let row = raw.baseAddress!.advanced(by: (y * width + x0) * 4)
                    .bindMemory(to: UInt32.self, capacity: TileGrid.tileSize)
                row.update(repeating: 0xFF50_4030, count: TileGrid.tileSize)
            }
        }
    }

    /// `frame` moved by (mx, my): every pixel takes the content at
    /// -(mx, my); revealed pixels are fresh noise; the stripe stays put.
    static func moved(_ frame: TestFrame, mx: Int, my: Int, _ rng: inout SplitMix64) -> TestFrame {
        var out = TestFrame(width: frame.width, height: frame.height)
        out.fillRandom(&rng)
        let w = frame.width, h = frame.height
        let x0 = max(0, mx), x1 = min(w, w + mx) // destination columns with a source
        frame.bytes.withUnsafeBytes { src in
            out.bytes.withUnsafeMutableBytes { dst in
                for y in 0..<h where y - my >= 0 && y - my < h {
                    dst.baseAddress!.advanced(by: (y * w + x0) * 4)
                        .copyMemory(from: src.baseAddress!.advanced(by: ((y - my) * w + x0 - mx) * 4),
                                    byteCount: (x1 - x0) * 4)
                }
            }
        }
        paintStripe(&out)
        return out
    }

    /// Allocation counts are asserted only against optimized code.
    static var assertsCounts: Bool {
        #if DEBUG
        false
        #else
        true
        #endif
    }

    /// Allocations `emitScroll` is allowed: the SCROLL frame's Data.
    static func boundaryAllocations() -> Int? {
        let bytes = [UInt8](repeating: 7, count: ControlFrames.scrollBytes)
        var sink = 0
        var last: Int?
        for _ in 0..<3 { // warm: first-use metadata and caches
            last = bytes.withUnsafeBytes { raw in
                MallocCounter.count { sink &+= Data(bytes: raw.baseAddress!, count: raw.count).count }
            }
        }
        #expect(sink == 3 * ControlFrames.scrollBytes)
        return last
    }

    /// Steady wheel scroll (vertical 1-D pass), a horizontal pan (column
    /// pass) and a diagonal drag (2-D probe search): each scroll tick
    /// allocates exactly the SCROLL frame's Data, and the SCROLL_ACK repair
    /// that follows allocates nothing.
    @Test(arguments: [(0, -64), (-64, 0), (48, 32)])
    func INV_7_steadyStateScrollTickAllocatesOnlyTheControlFrame(mx: Int, my: Int) throws {
        switch MallocCounter.install() {
        case .installed: break
        case .missing:
            Issue.record("libmalloc exports no malloc_logger")
            return
        case .busy: return // MallocStackLogging or Instruments owns the hook
        }
        defer { MallocCounter.uninstall() }
        let boundary = try #require(Self.boundaryAllocations())

        var rng = SplitMix64(seed: 2026_10_18 &+ UInt64(bitPattern: Int64(mx * 1000 + my)))
        let loop = Loop(width: Self.width, height: Self.height)
        var frame = Self.noise(&rng)
        loop.encode(frame)
        for _ in 0..<3 { loop.encode(frame) } // cold start fully ACKed
        // Warm-up scrolls through the normal tick: pools and capacities settle.
        for _ in 0..<3 {
            frame = Self.moved(frame, mx: mx, my: my, &rng)
            loop.encode(frame)
            for _ in 0..<3 { loop.encode(frame) }
        }
        #expect(loop.host.stats.scrollsSent >= 2, "warm-up must engage scroll")

        for _ in 0..<3 {
            frame = Self.moved(frame, mx: mx, my: my, &rng)
            let scrollsBefore = loop.host.stats.scrollsSent
            let allocations = try #require(loop.countScrollTick(frame))
            #expect(loop.host.stats.scrollsSent == scrollsBefore + 1, "the counted tick must emit a scroll")
            if Self.assertsCounts && boundary > 0 {
                #expect(allocations == boundary,
                        "scroll tick (\(mx), \(my)) allocated \(allocations), allowed \(boundary) (the SCROLL Data)")
            }

            // The SCROLL_ACK: parsed outside the window, repaired inside it.
            loop.viewer.handleControl(try #require(loop.hostOut.sentControl.last), nowUS: loop.now)
            loop.hostOut.sentControl.removeAll()
            var ack: (UInt32, [UInt16], UInt64)?
            for message in controlMessages(loop.viewerOut.sentControl) {
                if case let .scrollAck(seq, skipped, digest) = message { ack = (seq, skipped, digest) }
            }
            loop.viewerOut.sentControl.removeAll()
            // Nothing raced the scroll here, so the viewer skipped nothing;
            // two more skipped sources (one in the rect, one a hostile index)
            // exercise the skipped-tile marks. Leaving a written tile out of
            // the digest fold also forces the whole-rect demotion.
            let (seq, viewerSkipped, digest) = try #require(ack)
            let skipped = viewerSkipped + [UInt16(loop.host.grid.count / 2 + 3), UInt16.max]
            let repairAllocations = try #require(MallocCounter.count {
                loop.host.repairAfterScrollAck(frameSeq: seq, skipped: skipped, digest: digest)
            })
            if Self.assertsCounts && boundary > 0 {
                #expect(repairAllocations == 0, "SCROLL_ACK repair allocated \(repairAllocations)")
            }
            // Ship the residuals and settle before the next step.
            for _ in 0..<3 { loop.encode(frame) }
        }
        #expect(loop.host.stats.scrollDigestRepairs == 3, "each forced mismatch demotes its rect")
    }
}

/// Heap allocations on the calling thread, via libmalloc's `malloc_logger`.
enum MallocCounter {
    private typealias Logger = @convention(c) (UInt32, UInt, UInt, UInt, UInt, UInt32) -> Void
    private static let armed = Atomic<UInt>(0) // the counting thread, 0 = off
    private static let allocations = Atomic<Int>(0)
    private static let hook: Logger = { type, _, _, _, _, _ in
        // MALLOC_LOG_TYPE_ALLOCATE (malloc, calloc, realloc).
        guard type & 2 != 0, UInt(bitPattern: pthread_self()) == MallocCounter.armed.load(ordering: .relaxed) else {
            return
        }
        MallocCounter.allocations.add(1, ordering: .relaxed)
    }

    private static var slot: UnsafeMutablePointer<Logger?>? {
        dlsym(UnsafeMutableRawPointer(bitPattern: -2), "malloc_logger")?.assumingMemoryBound(to: Logger?.self)
    }

    enum Install { case installed, missing, busy }

    static func install() -> Install {
        guard let slot else { return .missing }
        guard slot.pointee == nil else { return .busy }
        armed.store(0, ordering: .relaxed) // initialize the statics outside the hook
        _ = allocations.load(ordering: .relaxed)
        slot.pointee = hook
        return .installed
    }

    static func uninstall() {
        slot?.pointee = nil
    }

    static func count(_ body: () -> Void) -> Int? {
        guard slot?.pointee != nil else { return nil }
        let before = allocations.load(ordering: .relaxed)
        armed.store(UInt(bitPattern: pthread_self()), ordering: .sequentiallyConsistent)
        body()
        armed.store(0, ordering: .sequentiallyConsistent)
        return allocations.load(ordering: .relaxed) - before
    }
}
