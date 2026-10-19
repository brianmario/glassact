public import Foundation
public import GlassActWire
import GlassActCodec
public import GlassActTransport
import os

public struct HostStats: Sendable {
    public init() {}
    public var cacheStoresSent = 0
    public var cacheRefsSent = 0
    public var scrollsSent = 0
    public var scrollSatisfiedTiles = 0
    public var bytesOut = 0
    public var datagramsSent = 0
    public var tilesSent = 0
    public var batchesSent = 0
    public var batchesDropped = 0
    public var lastTickQualifiedTiles = 0
    public var acksReceived = 0
    public var webpProbes = 0
    public var webpProbesSkipped = 0
    public var videoRegionsFormed = 0
    public var videoRegionsDissolved = 0
    /// Re-sharpening keyframes: the region went quiet after a large change.
    public var videoRefreshes = 0
    /// Region tiles handed back to their exact canvas copy while the region
    /// kept running: by REVEAL (the canvas already held them) and by a
    /// confirmed lossless record.
    public var overlayHandoffReveals = 0
    public var overlayHandoffRecords = 0
    public var videoFramesSent = 0
    public var videoBytesSent = 0
    public var videoBacklogSkips = 0
    /// Tiles a dissolve revealed for free (unchanged under the video)
    /// instead of repainting.
    public var overlayTilesRevealed = 0
    /// Encode ticks skipped because the viewer paused content.
    public var ticksPaused = 0
    public var keyframesSent = 0
    public var keyframeBytesSent = 0
    public var keyframeFallbacks = 0
    public var deltasSent = 0
    public var deltaNacksRepaired = 0
    public var scrollDigestRepairs = 0
    public var qualityDowngrades = 0
    public var qualityUpgrades = 0
    public var governorDeferredTiles = 0
    /// Cache slots dropped after a viewer REF miss (DELTA_NACK on a REF).
    public var cacheSlotsPoisoned = 0
    /// Scrolls dropped from the SCROLL_ACK repair list before their ACK.
    public var scrollsEvictedUnacked = 0
    /// Regions dissolved because the encoder kept delivering nothing.
    public var videoEncoderFailures = 0
    /// Regions dissolved because the transport lost the video stream.
    public var videoChannelResets = 0
    /// SYNC_REQUESTs for the live region (§4.6), sync frames sent in answer
    /// (requests coalesce: at most one every `syncRequestMinIntervalUS`), and
    /// requests ignored (no live region, or a stale generation).
    public var videoSyncRequests = 0
    public var videoSyncRequestSyncs = 0
    public var videoSyncRequestsIgnored = 0
    /// Qualified tiles deferred because the batch reached its datagram cap.
    public var batchCapDeferredTiles = 0
    public var tileBytesOut = 0 // datagram (tile-record) bytes only — the governed path
    public var lossyFirstPaintsSent = 0
    /// The governor's current refill rate (bytes/s) under the rate policy.
    public var governorRate = 0
    /// Encode time as a share of the capture interval (EWMA, %; 0 when the
    /// host doesn't measure it) — Auto's headroom bound.
    public var encodeDutyPercent = 0
    /// Adaptive datagram pace (bytes/s) and how often it moved.
    public var datagramPaceRate = PaceController.initialRate
    public var paceDecreases = 0
    public var paceIncreases = 0
    /// Ticks skipped because the transport's pacer was backlogged (also
    /// counted in batchesDropped).
    public var pacerBacklogSkips = 0
    public var videoColdStarts = 0
}

/// §4 — host engine.
///
/// Queue confinement: every method must be called from one serial context (the
/// app's `encodeQueue`); `@unchecked Sendable` reflects confinement, not
/// internal locking. No actors/await in the pixel path (§2, §8.8). Time is
/// always injected (`nowUS`) so the trace/replay rig is deterministic.
public final class HostEngine: @unchecked Sendable {
    public enum EngineState: Equatable, Sendable {
        case idle
        case helloSent
        case running
        case failed
    }

    struct BatchTile {
        var tileIdx: UInt16
        var hash: UInt64
        var firstDgram: Int32
        var lastDgram: Int32
        /// Tile-cache involvement: 0 none, 1 this send STOREs into cacheSlot,
        /// 2 this send is a REF to cacheSlot.
        var cacheKind: UInt8 = 0
        var cacheSlot: UInt16 = 0
        /// Unconfirmed datagrams still carrying fragments of this tile. The
        /// tile's send is ACK-confirmed only when this reaches zero — for a
        /// fragmented tile, *every* datagram carrying one of its fragments
        /// must be confirmed, else the viewer cannot have applied it (its
        /// reassembly is all-or-nothing) and marking it acked would diverge.
        var remaining: Int32
    }

    struct OpenBatch {
        var active = false
        var frameSeq: UInt32 = 0
        var sendTimeUS: UInt64 = 0
        /// Time for this batch's last datagram to leave the host: its own
        /// bytes plus whatever the transport's pacer still held at send
        /// time, at the pace in effect then. The timeout's serialization
        /// allowance.
        var serializationUS: UInt64 = 0
        /// The same split for path-delay samples: time for what the pacer
        /// held ahead of this batch, and for the batch's own bytes.
        var aheadUS: UInt64 = 0
        var ownUS: UInt64 = 0
        /// The adaptive pace this batch was sent at (0 = transport doesn't
        /// pace), and its own bytes — the controller's input on resolution.
        var paceRate = 0
        var byteSize = 0
        var dgramCnt = 0
        var confirmed: [Bool] = []
        var confirmedCnt = 0
        var tiles: [BatchTile] = []
        /// Per datagram, the first tile entry it carries a record for (tiles
        /// are packed in order and each spans consecutive datagrams, so a
        /// datagram's tiles are the contiguous run starting here). Lets an
        /// ACK touch only the tiles in newly confirmed datagrams — a full scan
        /// would be O(datagrams × tiles), ~47M steps for a 16 MB batch.
        var dgramFirstTile: [Int32] = []
    }

    public let grid: TileGrid
    public private(set) var state: EngineState = .idle
    public internal(set) var stats = HostStats()
    public internal(set) var srttUS: UInt64 = 0

    let transport: any GlassActTransport
    /// §4.2 per-tile bookkeeping + owed-send queues (TileLedger).
    var ledger: TileLedger
    var batches = [OpenBatch(), OpenBatch()]
    var nextFrameSeq: UInt32 = 1
    private var deframer = ControlDeframer()
    let tileScratch: UnsafeMutableRawBufferPointer
    private let lz4Out: UnsafeMutableRawBufferPointer
    private let bitmapOut: UnsafeMutableRawBufferPointer
    private let encodeOut: UnsafeMutableRawBufferPointer
    struct EncodedMeta {
        var opcode: UInt8 = 0
        var length: Int32 = 0
        /// VP8L probe result for routing memory: 0 = not attempted,
        /// 1 = won decisively (≥ 1/16 below the cheap best — worth the probe
        /// time), 2 = lost, failed the smaller-than-RAW gate, or won by a
        /// margin too thin to buy its ~240 µs (photographic tiles: LZBITMAP
        /// lands within tenths of a percent of VP8L, measured on the video
        /// synth — a hair-thin win still routes the position away).
        var webpOutcome: UInt8 = 0
    }
    var encodeMeta: ContiguousArray<EncodedMeta>
    var qualTiles = ContiguousArray<Int32>()
    private var qualHashes = ContiguousArray<UInt64>()
    // Codec routing memory (positional; design from BENCHMARKS "Codec
    // routing measurement"): no cheap static signal separates AA text
    // (LZ4-hostile, VP8L-friendly) from photographic content (hostile to
    // both), but content *class* is positionally coherent even when exact
    // pixels churn — so the expensive codec's own outcome, remembered per
    // tile position, is the classifier.
    // A tile whose VP8L probe fails to win *decisively* (photographic tiles:
    // LZBITMAP lands within tenths of a percent of VP8L, so a strict win can
    // still be worthless) skips VP8L for `webpBackoff` subsequent probes
    // (8, doubling to 64 on repeated failure); a decisive win clears the
    // backoff. Byte regret is bounded by one backoff window
    // after a class change; on photographic churn ≥ 87 % of probe time is
    // avoided.
    private var webpSkips: ContiguousArray<UInt8>
    private var webpBackoff: ContiguousArray<UInt8>
    private var webpTryFlags: ContiguousArray<UInt8>
    // DELTA (§4.8) — per-qualifying-tile ACKed base hash (0 = delta ineligible). A
    // tile qualifies for a delta only when quiescent-acked: the viewer's
    // content is then provably the ACKed shadow, which the encoder holds
    // pixel-for-pixel.
    private var deltaBases: ContiguousArray<UInt64>
    static let webpBackoffInitial: UInt8 = 8
    static let webpBackoffMax: UInt8 = 64

    // Video (§4.6): pinned full-screen HEVC on the dedicated video
    // stream, drawn by the viewer as an overlay above the canvas. The only
    // multi-frame state in the system.
    //
    // Lifecycle: churn on ≥ `pinnedFormMinTiles` tiles forms one full-screen
    // region (generation++, encoder session, VIDEO_START once config
    // arrives). While active, region tiles are excluded from candidates —
    // no records, no scroll, no cache — except still tiles owed a handoff
    // record; the region ships encoder frames, paced newest-wins by encoder
    // backlog and transport backlog. Quiescence (`regionQuietLimit` quiet
    // ticks, or the matching wall time) dissolves it: VIDEO_STOP reveals the
    // tiles the canvas already holds, and the rest go back through the
    // lossless path. Exactness is restored at settle; the golden bar holds.
    //
    // Codecs: the factory is codec-keyed (a hardware AV1 encoder can slot in
    // beside HEVC). The host's preference order is intersected with the
    // viewer's caps to form `negotiatedVideoCodecs`; a region starts on the
    // first of them whose encoder starts, and VIDEO_START carries its id.
    let videoEncoderFactory: ((UInt8) -> any VideoRegionEncoder?)?
    private let videoCodecPreference: [UInt8]
    var negotiatedVideoCodecs: [UInt8] = []
    // Adaptive quality (bandwidth pressure): level 0 = best; raise on
    // bandwidth pressure (backlog high while the ENCODER keeps up —
    // network-bound, not CPU-bound), lower when healthy.
    var qualityLevel = 0
    var qualityWindowAttempts = 0
    var qualityWindowPressure = 0
    var qualityHealthyStreak = 0
    // Client quality policy (§3.5 QUALITY TLV): bounds the bandwidth loop.
    var policyScaleLevel = 0      // floor from presented scale (<100% → shed detail)
    var policyMaxLevel = 3        // cap from the client's quality floor (QualityFloor)
    var policyPreferSharpness = false // freeze quality, let framerate absorb pressure
    static let maxQualityLevel = 3
    static let videoQualityWindow = 30       // frames per evaluation
    static let videoQualityHealthyWindows = 4 // sustained-healthy windows to recover a level
    private(set) var videoNegotiated = false
    // Last hash observed per tile position (any diff tick, acked or not) —
    // the formation rule's churn signal (`churningCandidateCount`). It must
    // key on the content actually CHANGING between observations:
    // `h != ackedHash` conflates "changed" with "not yet ACKed", and on a
    // slow link (~1 s RTT) a dissolve repaint's cold static tiles then read
    // as churn for the whole ACK round trip — the region re-forms from its
    // own repaint, dissolves, re-colds, and the session livelocks.
    var lastObservedHash: ContiguousArray<UInt64>
    var inRegion: ContiguousArray<Bool>
    // Repaint tiles volunteered into THIS tick's worklist (the drain empties
    // the ledger's repaint queue, so the settle-drain probe widening below
    // needs the per-tick snapshot).
    private var tickSettleVolunteers = 0
    var regionActive = false
    var regionGeneration: UInt32 = 0
    var regionTileBox = (c0: 0, r0: 0, c1: 0, r1: 0)
    var regionPixelRect = (x: 0, y: 0, w: 0, h: 0)
    var regionEncoder: any VideoRegionEncoder?
    var regionStartSent = false
    var regionFrameSeq: UInt32 = 0
    var regionPixels: UnsafeMutableRawBufferPointer?
    var regionScratch: UnsafeMutableRawBufferPointer?
    var regionFramesPending = 0
    // Re-sharpen (engine queue): VideoToolbox never re-codes content that
    // stops changing, so whatever a large change got coded at — the startup
    // cap, a thin moment, the frame after a blank first capture — is what
    // the viewer sees for as long as the region lives (e.g. minutes of soft
    // text while a 704×1024 strip animates; BENCHMARKS 'Soft video for
    // minutes: capture-time PTS, QP 34 floor, re-sharpen'). One keyframe
    // once things settle re-codes it at the budget the gap earned.
    /// Region pixels changed by large updates since the last keyframe.
    var refreshDamagePixels = 0
    // Per-tile handoff inside a live region (engine queue). A tile that
    // stops changing goes back to its exact canvas copy while the region
    // keeps running — REVEAL when the canvas already holds its content, else
    // an ordinary lossless record newer than the frame that last claimed it
    // (VideoClaims). Grid-sized.
    /// When each region tile last changed between region frames.
    var regionTileChangedUS = ContiguousArray<UInt64>()
    /// The viewer shows video on the tile (a delivered frame claimed it),
    /// and no lossless record at least as new has been confirmed since.
    var videoShown = ContiguousArray<Bool>()
    /// Stamp of the frame that last claimed the tile.
    var videoClaimSeq = ContiguousArray<UInt32>()
    /// Still and owed a lossless record: the tile path may send it although
    /// it lies in the region.
    var handoffDue = ContiguousArray<Bool>()
    /// The tile's content hash, taken once it went still (0 = not yet).
    var stillHash = ContiguousArray<UInt64>()
    /// When a lossless record last handed the tile back (0 = not recently),
    /// and how long it must now be still before the next record handoff: a
    /// tile video reclaims soon after (a slideshow, a page that keeps
    /// changing) doubles it — the record was bytes thrown away.
    var recordHandoffUS = ContiguousArray<UInt64>()
    var handoffBackoffUS = ContiguousArray<UInt64>()
    /// Changed since the last submitted frame: claims ride the next one.
    var claimPending = ContiguousArray<Bool>()
    var claimPendingTiles = ContiguousArray<Int32>()
    /// Claims of submitted, undelivered frames (one per submit, in order).
    var claimsInFlight: [ContiguousArray<Int32>] = []
    var claimBufferPool: [ContiguousArray<Int32>] = []
    /// Per-tile-column "changed" marks for one band of the region diff.
    var diffBandScratch = ContiguousArray<Bool>()
    /// Per-tile handoff inside live regions (default on). Off only for
    /// bench comparisons: every frame then claims the whole region.
    public var overlayHandoff = true
    var handoffActive: Bool { overlayHandoff }
    static let handoffHashesPerTick = 256
    /// Reclaimed within this of a record handoff → that tile's record
    /// threshold doubles, up to the max.
    static let handoffRechurnWindowUS: UInt64 = 10_000_000
    static let handoffMaxBackoffUS: UInt64 = 16_000_000
    /// Record handoffs wait until the region has had no large update (¼ of
    /// its area) for this long: during scrolls, drags and slideshows a
    /// lossless copy of a tile is soon overwritten — and photographic tiles
    /// are the most expensive to encode and send (measured ungated: photos
    /// 38 → 95 MB, host encode p95 5 → 20 ms; BENCHMARKS 'Per-tile handoff
    /// inside a live video region'). A small animating
    /// panel doesn't count as large, so the still rest of the screen still
    /// gets its records. REVEAL (free) isn't gated.
    static let handoffRecordQuietUS: UInt64 = 2_000_000
    /// …and only while the region is kept alive by a change this recent.
    static let handoffRecordActiveUS: UInt64 = 1_000_000
    /// See `defaultHandoffStillUS` (a bench knob).
    public var handoffStillUS = HostEngine.defaultHandoffStillUS
    /// When the region last went quiet (only small updates since); 0 = busy.
    var refreshQuietSinceUS: UInt64 = 0
    /// When the last keyframe went to the encoder, and the cap it had then.
    var lastRegionSyncUS: UInt64 = 0
    var capAtLastSync = 0
    /// The viewer asked for a sync frame (SYNC_REQUEST) and none has gone
    /// to the encoder since; and when the last answer did (0 = never).
    var syncRequestPending = false
    var lastRequestedSyncUS: UInt64 = 0
    var regionEmptyDeliveries = 0 // consecutive empty encoder deliveries
    public static let videoMaxEmptyDeliveries = 30 // ~0.5 s of failed encodes at 60 Hz
    var regionLastChangeUS: UInt64 = 0
    var regionQuietTicks = 0
    /// A full-screen region is media browsing until proven otherwise: it
    /// starts with gap-surviving patience (measured: starting at a 30-tick
    /// limit leaves ~800 MB of uncovered transitions on the photos trace
    /// while it learns through dissolve/repaint cycles).
    static let videoQuietTicksLimit = 90
    /// Paging anti-thrash: a region re-formed shortly after its predecessor
    /// dissolved means the quiet limit was shorter than the workload's gaps
    /// (Photos pages every ~2 s; each dissolve costs a lossless repaint of
    /// whatever changed). A quick re-form triples the limit to this; a
    /// re-form that wasn't quick resets it.
    static let videoQuietTicksMax = 270
    static let videoReformWindowTicks = 120 // ~6 s at 20 fps
    var regionQuietLimit = HostEngine.videoQuietTicksLimit
    var videoTickCounter = 0
    var lastDissolveTick = Int.min / 2
    /// Wall-time quiet limit at `videoQuietTicksLimit`, scaled with the
    /// adaptive limit (captures may stop entirely on a static screen).
    static let videoQuietUSLimit: UInt64 = 2_100_000
    static let videoMaxPendingFrames = 2
    /// Video send gate + encoder bitrate cap from the measured drain rate.
    public internal(set) var videoRate = VideoRateController()

    public var activeVideoRegionCount: Int { regionActive ? 1 : 0 }
    public var activeVideoRegionRect: (x: Int, y: Int, width: Int, height: Int)? {
        regionActive
            ? (regionPixelRect.x, regionPixelRect.y, regionPixelRect.w, regionPixelRect.h)
            : nil
    }
    /// Codec id currently carrying the active region (0 = no region).
    public var activeVideoCodec: UInt8 { regionActive ? regionEncoder?.codecID ?? 0 : 0 }
    /// Tiles owed a lossless send that dirty rects won't volunteer (dissolve
    /// repaint, timeout invalidation). The settle loop must drain this to
    /// zero before declaring convergence.
    public var pendingRepaintTiles: Int { ledger.pendingRepaintCount }
    /// Per-worker codec state for the parallel payload-encode phase.
    final class EncodeWorker {
        let codec = LZ4Codec()
        let scratch: UnsafeMutableRawBufferPointer
        // DELTA: per-tick budget for VP8L trials on delta sub-rects, in pixels
        // (worker-local ⇒ deterministic under the strided assignment). Reset
        // by the engine before each job.
        var webpSubPixelBudget = 0
        // DELTA scratch: ACKed-base extraction, XOR image, sub-rect, and
        // inner-encode output.
        let base: UnsafeMutableRawBufferPointer
        let delta: UnsafeMutableRawBufferPointer
        let sub: UnsafeMutableRawBufferPointer
        let inner: UnsafeMutableRawBufferPointer
        init() {
            scratch = .allocate(byteCount: HostEngine.tileBytes, alignment: 64)
            base = .allocate(byteCount: HostEngine.tileBytes, alignment: 64)
            delta = .allocate(byteCount: HostEngine.tileBytes, alignment: 64)
            sub = .allocate(byteCount: HostEngine.tileBytes, alignment: 64)
            // Two full-tile halves: mode-0 inner at [0, tileBytes),
            // mode-1 inner at [tileBytes, 2×tileBytes).
            inner = .allocate(byteCount: 2 * HostEngine.tileBytes, alignment: 64)
        }
        deinit {
            scratch.deallocate()
            base.deallocate()
            delta.deallocate()
            sub.deallocate()
            inner.deallocate()
        }
    }
    private let encodeWorkers: [EncodeWorker]
    private var packer: DatagramPacker
    var worklist = ContiguousArray<Int32>()
    /// worklist[0..<worklistFresh] came from this tick's dirty rects (or a
    /// full scan); the rest are owed tiles (carry, repaint) volunteered by
    /// the ledger. Admission serves fresh first (see encodeTick).
    var worklistFresh = 0
    var hashResults: ContiguousArray<UInt64>
    var candidateMark: ContiguousArray<UInt32>
    var candidateEpoch: UInt32 = 0
    /// Dirty tiles of captures whose tick returned before collecting
    /// candidates (INV-4 skip, pause). Dirty rects
    /// are deltas against the PREVIOUS capture: drop a tick's rects and the
    /// tiles changed in that capture are never hashed again unless they
    /// change again — stale on the viewer indefinitely (capture drops run
    /// at up to 47 per 2 s; BENCHMARKS 'Stale tiles: damage from skipped
    /// captures is carried forward'). "The pixels re-qualify next tick"
    /// (INV-4) holds only if next tick looks at them; this is what makes it
    /// look.
    var missedDirty: ContiguousArray<Bool>
    var missedDirtyTiles = ContiguousArray<Int32>()
    /// A skipped tick had no usable rects: the next tick scans every tile.
    var missedScanAll = false
    /// This tick's candidates included skipped ticks' damage (read by the
    /// region service, which runs after candidates are collected).
    var tickMissedDamage = false
    var firstBatchSent = false
    // ACKed shadow canvas (§4.2): the viewer's canvas in pixels as far as
    // ACKs prove it (INV-3 — only ACKed content is ever referenced; scroll,
    // DELTA and the cache read it), a snapshot scratch for shifting it, and
    // per-batch retention of sent tile pixels so ACKs can promote them into
    // the shadow. Sized for the worst case once, at init (§8.1: never per
    // frame) — at 5K that is ~59 MB for the shadow and twice that for the
    // two retention slots.
    static let tileBytes = TileGrid.tileSize * TileGrid.tileSize * 4
    let shadow: UnsafeMutableRawBufferPointer
    /// emitScroll scratch, per rect tile: 0 = no span, 1 = shifted but its
    /// post-scroll content is unknown, 2 = shifted and known (promote).
    var scrollPlan: ContiguousArray<UInt8>
    var retention: [UnsafeMutableRawBufferPointer] = []
    var scrollSatisfied = ContiguousArray<Bool>()
    var scrollQualified = ContiguousArray<Bool>()
    struct RecentScroll {
        var frameSeq: UInt32
        var dx: Int
        var dy: Int
        // Verified scroll promotion: the rect and the emit-time post-mirror tile
        // hashes (every rect tile, KNOWN or not). At SCROLL_ACK time the host
        // folds these over rect ∖ skipped and compares the viewer's digest —
        // mismatch demotes the whole rect. Snapshotted because the live
        // shadow/acked state may legitimately move on before the ACK arrives.
        var rectX: Int
        var rectY: Int
        var rectW: Int
        var rectH: Int
        /// Post-mirror hash per rect tile, row-major over the rect's tiles
        /// (not the whole grid — retained until the SCROLL_ACK).
        var marks: ContiguousArray<UInt64>
    }
    // Scrolls awaiting their SCROLL_ACK (reliable control stream: every
    // applied scroll is ACKed). Entries leave on ACK. The cap only bounds a
    // stalled viewer; an entry evicted unACKed can never be verified, so its
    // rect is demoted (see emitScroll). A fixed ring of 8 would silently drop
    // the repair for scrolls older than the 8 most recent — > 8 scrolls per
    // RTT is ~130 ms RTT at 60 Hz, and scroll ticks with no residual tiles
    // open no batch, so INV-4 doesn't slow them.
    var recentScrolls: [RecentScroll] = []
    public static let recentScrollCap = 32
    /// Marks buffers of resolved or evicted scrolls, each with capacity for
    /// the whole grid, reused by the next emitScroll (INV-7).
    var scrollMarksPool: [ContiguousArray<UInt64>] = []
    /// Scroll detection and repair scratch (§4.8, INV-7), sized at init.
    let scrollScratch: ScrollScratch
    /// Wire limit on datagrams per batch (u16 dgram_cnt).
    public static let wireMaxBatchDatagrams = 65_535
    /// This engine's per-batch datagram cap (the wire limit; tests lower it).
    private let maxBatchDatagrams: Int

    // Session tile cache (§4.8; host mirror, see HostTileCache).
    var cache = HostTileCache()
    /// PAUSE_HINT: the viewer can't be seen — ship no content at all
    /// (keep-alives only). Skipped captures are the INV-4 principle again:
    /// changed pixels re-qualify on the first tick after resume. The active
    /// region is kept (not dissolved) so resume is a plain P-frame
    /// continuation and no settle repaint burns CPU for a window nobody can
    /// see.
    public private(set) var contentPaused = false
    /// Fired on the engine queue when the viewer pauses or resumes — the
    /// app can drop the capture rate itself (SCK reconfigure), which is
    /// where most of the host-side battery lives.
    public var onPausedChanged: ((_ paused: Bool) -> Void)?
    /// RESIZE (viewer → host): (mode, widthPoints, heightPoints, scale).
    /// The app owns display switching / capture scaling + session reset.
    public var onResizeRequested: ((Int, Int, Int, Int) -> Void)?
    /// Remote input (viewer → host): (kind, canvasX, canvasY, a, b). The app
    /// maps canvas→display and injects CGEvents (needs Accessibility TCC).
    public var onInput: ((Int, Int, Int, Int, Int) -> Void)?
    /// Clipboard sync (bidirectional): fired on inbound; the app applies.
    public var onClipboard: ((_ format: UInt8, _ data: [UInt8]) -> Void)?
    public func sendClipboard(format: UInt8, data: [UInt8]) {
        guard state == .running, data.count <= ControlMessage.maxClipboardBytes else { return }
        sendControl(.clipboard(format: format, data: data))
    }
    /// Active video codec changed: region formed (codec id), or region
    /// dissolved (nil = back to lossless tiles). Status/log surface for the
    /// app; fires on the engine's confining queue.
    public var onVideoCodecChanged: ((UInt8?) -> Void)?
    /// Once per engine: the first video frame went to the transport —
    /// its size, whether it is a sync frame, and submit → delivery time (µs).
    public var onFirstVideoFrame: ((_ bytes: Int, _ sync: Bool, _ encodeUS: UInt64) -> Void)?
    var firstVideoSubmitUS: UInt64 = 0
    /// Single-window mode (§4.10): the viewer picked a window (0 = revert to full
    /// display). The app rebuilds its SCK capture filter around that window.
    public var onWindowSelect: ((_ windowID: UInt32) -> Void)?
    /// Single-window mode: the viewer issued a window-chrome action (see
    /// WindowAction). The app drives the host window via Accessibility
    /// (fullscreen / resize) or ends the single-window session.
    public var onWindowControl: ((_ action: UInt8, _ width: UInt16, _ height: UInt16) -> Void)?
    /// A chunk of an uploaded viewer log (VIEWER_LOG): the app stores it.
    /// Engine queue; validated by the parser (safe name, bounded sizes).
    public var onViewerLog: ((_ name: String, _ offset: UInt32, _ total: UInt32, _ data: [UInt8]) -> Void)?
    /// Agents: TEXT_INPUT — type this text (the app posts Unicode key events).
    public var onTextInput: ((_ text: String) -> Void)?
    /// Agents: AGENT_STATE — an agent started or stopped driving this session.
    public var onAgentState: ((_ active: Bool, _ label: String) -> Void)?
    /// VIEWER_INFO: the computer the viewer runs on (display only).
    public var onViewerInfo: ((_ name: String) -> Void)?
    /// Agents: UI_TREE_REQUEST — the app answers with `sendUITree`.
    public var onUITreeRequest: ((_ requestID: UInt32, _ windowID: UInt32, _ maxNodes: Int) -> Void)?
    /// Agents: answer a UI_TREE_REQUEST. A tree too big for one control
    /// message goes back as `UITreeStatus.tooLarge` instead of killing the stream.
    public func sendUITree(requestID: UInt32, status: UInt8, json: [UInt8]) {
        guard state == .running else { return }
        if json.count + 5 > Int(ControlMessage.maxBodyLength) {
            sendControl(.uiTree(requestID: requestID, status: UITreeStatus.tooLarge, json: []))
        } else {
            sendControl(.uiTree(requestID: requestID, status: status, json: json))
        }
    }
    /// Agents: tell the viewer whether agent input is accepted right now.
    public func sendAgentScope(control: Bool, reason: String) {
        guard state == .running else { return }
        sendControl(.agentScope(control: control, reason: String(reason.utf8Prefix(ControlMessage.maxAgentReasonBytes))))
    }
    /// Single-window mode: push the pickable-window snapshot to the viewer (host must hold
    /// Screen Recording to have enumerated them). Bounded so the TLV stays
    /// under maxBodyLength — the app caps count and thumbnail size.
    /// Single-window mode, host → viewer: the shared window is gone, the session is over
    /// (WINDOW_CONTROL endSession, the viewer's own close message, reversed).
    public func sendSharedWindowClosed() {
        sendControl(.windowControl(action: WindowAction.endSession, width: 0, height: 0))
    }

    public func sendWindowList(_ windows: [WireWindow]) {
        guard state == .running else { return }
        sendControl(.windowList(windows: windows))
    }
    // Lossless region keyframes (§4.7; striped VP8L on the video stream).
    // One whole-rect image instead of N tile records: the encoder's window
    // spans tiles (measured 1.1–3× smaller), and the cold start needs no
    // datagram flood (the blob rides the reliable stream). A
    // keyframe is a batch of one giant record: seq-stamped, per-tile LWW at
    // the viewer, confirmed by KEYFRAME_ACK, promoted into acked/shadow
    // exactly like a datagram batch. One in flight at a time.
    //
    // Tests only: the cold-start keyframe and DELTA records are always on
    // (every viewer decodes them); these switch them off so a test can
    // watch the plain tile path.
    var coldStartKeyframes = true
    var deltaRecords = true
    var kfActive = false
    var kfSeq: UInt32 = 0
    var kfSentUS: UInt64 = 0
    var kfSentBytes = 0
    var kfBox = (c0: 0, r0: 0, c1: 0, r1: 0)
    var kfRect = (x: 0, y: 0, w: 0, h: 0)
    var kfHashes: [UInt64] = []
    var kfPixels: UnsafeMutableRawBufferPointer? // retained until resolution (shadow promotion)
    var kfPixelsCapacity = 0
    var kfOut: UnsafeMutableRawBufferPointer?
    var kfOutCapacity = 0
    static let keyframeStripes = 8
    static let keyframeMaxBytes = 7 << 20 // fits the 8 MB video-TLV bound with headroom
    public var keyframeInFlight: Bool { kfActive }
    private var helloSentUS: UInt64 = 0
    private var lastPingUS: UInt64 = 0
    var currentCaptureUS: UInt64 = 0 // capture_ts of the frame being processed (video g2g)
    /// Liveness: time of the last PONG (0 until the first). PINGs go out 1/s;
    /// a running session with no PONG for many seconds is a dead peer the
    /// transport hasn't noticed (otherwise a host can stream video into a
    /// torn-down viewer for 30+ s).
    public private(set) var lastPongUS: UInt64 = 0
    private var pingNonce: UInt64 = 0
    private var budget: Int
    /// Real time (µs, the same domain callers pass as `nowUS`), read at the
    /// moment a batch, keyframe, HELLO or PING is handed to the transport
    /// (everything whose age later becomes an RTT/ACK-delay sample or a
    /// timeout). `nowUS` is the
    /// tick's START: stamped with it, a slow tick (a 2048² noise cold start
    /// takes 2.3 s to encode) would date its batch that much in the past, so
    /// the next tick would time it out before the viewer could ACK it —
    /// every tile re-sent, and the adaptive pace reading the phantom loss
    /// and halving itself. Nil (virtual-time tests) stamps with `nowUS`.
    let clock: (@Sendable () -> UInt64)?
    /// Real time (µs, any monotonic domain — only differences are used) for
    /// measuring encode duty, which bounds Auto's growth (SendGovernor).
    /// Defaults to `clock`; nil (virtual-time tests, deterministic replays)
    /// disables the bound. The bench passes one to measure it.
    let encodeTimer: (@Sendable () -> UInt64)?
    var lastEncodeNowUS: UInt64 = 0
    private var outgoingDatagrams: [Data] = [] // per-batch handoff, capacity reused
    /// CACHE record prefix (STORE_APPLY 4 B / REF 11 B), reused per tile.
    private let cachePrefix = UnsafeMutableRawBufferPointer.allocate(byteCount: 16, alignment: 8)

    public var openBatchCount: Int {
        (batches[0].active ? 1 : 0) + (batches[1].active ? 1 : 0)
    }

    /// The next batch seq the encoder will emit. Read before an
    /// in-session geometry rebuild and fed to the replacement engine's
    /// `startFrameSeq` so the LWW domain stays monotonic across the swap (the
    /// viewer resets tileSeq to 0, so continuity is what keeps new records
    /// winning over in-flight old-geometry stragglers).
    public var currentFrameSeq: UInt32 { nextFrameSeq }

    public init(width: Int, height: Int, transport: any GlassActTransport,
                videoEncoderFactory: ((UInt8) -> any VideoRegionEncoder?)? = nil,
                videoCodecPreference: [UInt8] = [VideoCodec.hevc],
                startFrameSeq: UInt32 = 1,
                maxBatchDatagrams: Int = HostEngine.wireMaxBatchDatagrams,
                clock: (@Sendable () -> UInt64)? = nil,
                encodeTimer: (@Sendable () -> UInt64)? = nil) {
        precondition(maxBatchDatagrams > 256 && maxBatchDatagrams <= Self.wireMaxBatchDatagrams)
        self.maxBatchDatagrams = maxBatchDatagrams
        self.clock = clock
        self.encodeTimer = encodeTimer ?? clock
        grid = TileGrid(width: width, height: height)
        nextFrameSeq = startFrameSeq == 0 ? 1 : startFrameSeq
        self.transport = transport
        self.videoEncoderFactory = videoEncoderFactory
        self.videoCodecPreference = videoCodecPreference
        ledger = TileLedger(count: grid.count)
        hashResults = ContiguousArray(repeating: 0, count: grid.count)
        candidateMark = ContiguousArray(repeating: 0, count: grid.count)
        missedDirty = ContiguousArray(repeating: false, count: grid.count)
        missedDirtyTiles.reserveCapacity(grid.count)
        let tileBytes = TileGrid.tileSize * TileGrid.tileSize * 4
        tileScratch = .allocate(byteCount: tileBytes, alignment: 64)
        lz4Out = .allocate(byteCount: tileBytes, alignment: 64)
        bitmapOut = .allocate(byteCount: tileBytes, alignment: 64)
        encodeOut = .allocate(byteCount: grid.count * tileBytes, alignment: 64)
        encodeMeta = ContiguousArray(repeating: EncodedMeta(), count: grid.count)
        webpSkips = ContiguousArray(repeating: 0, count: grid.count)
        webpBackoff = ContiguousArray(repeating: 0, count: grid.count)
        webpTryFlags = ContiguousArray(repeating: 0, count: grid.count)
        deltaBases = ContiguousArray(repeating: 0, count: grid.count)
        lastObservedHash = ContiguousArray(repeating: 0, count: grid.count)
        inRegion = ContiguousArray(repeating: false, count: grid.count)
        regionTileChangedUS = ContiguousArray(repeating: 0, count: grid.count)
        videoShown = ContiguousArray(repeating: false, count: grid.count)
        videoClaimSeq = ContiguousArray(repeating: 0, count: grid.count)
        handoffDue = ContiguousArray(repeating: false, count: grid.count)
        stillHash = ContiguousArray(repeating: 0, count: grid.count)
        recordHandoffUS = ContiguousArray(repeating: 0, count: grid.count)
        handoffBackoffUS = ContiguousArray(repeating: 0, count: grid.count)
        claimPending = ContiguousArray(repeating: false, count: grid.count)
        claimPendingTiles = ContiguousArray()
        claimPendingTiles.reserveCapacity(grid.count)
        diffBandScratch = ContiguousArray(repeating: false, count: grid.cols)
        encodeWorkers = (0..<max(2, min(12, ProcessInfo.processInfo.activeProcessorCount - 2))).map { _ in EncodeWorker() }
        qualTiles.reserveCapacity(grid.count)
        qualHashes.reserveCapacity(grid.count)
        // §3.3: budget queried from the transport at runtime.
        precondition(width <= TileGrid.maxDimension && height <= TileGrid.maxDimension,
                     "capture \(width)×\(height) exceeds TileGrid.maxDimension — the app must clamp")
        budget = Self.datagramBudget(forTransportMax: transport.maxDatagramSize) ?? 1168
        // Worst case: every tile RAW plus record/fragment overhead plus headers.
        packer = DatagramPacker(capacity: grid.count * (tileBytes + 512) + 65_536)
        let canvasBytes = width * height * 4
        shadow = .allocate(byteCount: canvasBytes, alignment: 16_384)
        shadow.baseAddress!.initializeMemory(as: UInt8.self, repeating: 0, count: canvasBytes)
        scrollPlan = ContiguousArray(repeating: 0, count: grid.count)
        retention = [
            .allocate(byteCount: grid.count * Self.tileBytes, alignment: 64),
            .allocate(byteCount: grid.count * Self.tileBytes, alignment: 64),
        ]
        scrollSatisfied = ContiguousArray(repeating: false, count: grid.count)
        scrollQualified = ContiguousArray(repeating: false, count: grid.count)
        scrollScratch = ScrollScratch(grid: grid)
        recentScrolls.reserveCapacity(Self.recentScrollCap + 1)
        scrollMarksPool.reserveCapacity(Self.recentScrollCap + 1)
        worklist.reserveCapacity(grid.count)
        outgoingDatagrams.reserveCapacity(4096)
        for i in 0..<batches.count {
            batches[i].tiles.reserveCapacity(grid.count)
            batches[i].confirmed.reserveCapacity(4096)
            batches[i].dgramFirstTile.reserveCapacity(4096)
        }
    }

    deinit {
        cachePrefix.deallocate()
        scrollScratch.deallocate()
        tileScratch.deallocate()
        lz4Out.deallocate()
        bitmapOut.deallocate()
        encodeOut.deallocate()
        shadow.deallocate()
        for r in retention { r.deallocate() }
        regionPixels?.deallocate()
        regionScratch?.deallocate()
        kfPixels?.deallocate()
        kfOut?.deallocate()
    }

    // MARK: - Control plane

    public func start(nowUS: UInt64) {
        guard state == .idle else { return }
        state = .helloSent
        helloSentUS = sendStampUS(nowUS)
        sendControl(.hello(ver: WireVersion.current,
                           width: UInt16(grid.width), height: UInt16(grid.height),
                           tileSize: UInt8(TileGrid.tileSize),
                           pixfmt: PixelFormat.bgra8sRGB,
                           caps: extraHelloCaps | videoCaps))
    }

    public func handleControl(_ data: Data, nowUS: UInt64) {
        guard state != .failed else { return }
        deframer.append(data)
        while let event = deframer.next() {
            guard case let .message(message) = event else { continue }
            switch message {
            case let .helloOK(ver, caps, geoMode, geoWidth, geoHeight, geoScale):
                guard WireVersion.isCompatible(ver) else {
                    enterFailed("incompatible viewer version \(ver)")
                    return
                }
                if geoMode != GeometryMode.none {
                    // Geometry requested in the handshake: hold ALL pixel
                    // data (never enter .running), surface to the app — it
                    // applies (display switch / capture scale) and resets the
                    // session; the re-offered HELLO carries geometryFinal.
                    // A switch/scale request with nonsense dimensions (the
                    // parser only bounds the mode) is answered as native
                    // (mode 3) — the viewer still gets its final HELLO, and
                    // the app never computes a 0×0 capture from it.
                    let sane = geoWidth >= 1 && geoHeight >= 1 && (1...4).contains(geoScale)
                    let resizes = geoMode == GeometryMode.clientResolution || geoMode == GeometryMode.scale
                    let mode = resizes && !sane ? GeometryMode.native : geoMode
                    onResizeRequested?(Int(mode), Int(geoWidth), Int(geoHeight), Int(geoScale))
                    break
                }
                if state == .helloSent {
                    state = .running
                    negotiatedVideoCodecs = videoEncoderFactory == nil ? []
                        : videoCodecPreference.filter { caps & WireCaps.bit(forVideoCodec: $0) != 0 }
                    videoNegotiated = !negotiatedVideoCodecs.isEmpty
                    cursorNegotiated = caps & WireCaps.cursor != 0
                    // The handshake round trip seeds SRTT so the first batch
                    // timeout is already RTT-aware. (An arrival stamp can
                    // predate a re-offered HELLO's stamp only for a stale
                    // reply; no sample beats a wrapped one.)
                    if nowUS > helloSentUS { updateSRTT(sample: nowUS - helloSentUS) }
                    lastPingUS = nowUS
                }
            case let .ack(frameSeq, dgramCnt, bitmap):
                lastControlNowUS = nowUS
                applyAck(frameSeq: frameSeq, dgramCnt: dgramCnt, bitmap: bitmap)
            case let .pong(_, tUS, _):
                lastPongUS = nowUS
                if nowUS > tUS { updateSRTT(sample: nowUS - tUS) }
            case let .ping(nonce, tUS):
                sendControl(.pong(nonce: nonce, tUS: tUS, recvTUS: nowUS))
            case let .scrollAck(frameSeq, skipped, digest):
                repairAfterScrollAck(frameSeq: frameSeq, skipped: skipped, digest: digest)
            case let .deltaNack(frameSeq, tiles):
                repairAfterDeltaNack(frameSeq: frameSeq, tiles: tiles)
            case let .keyframeAck(seq):
                commitKeyframeAck(seq: seq)
            case let .pauseHint(paused):
                guard paused != contentPaused else { break }
                contentPaused = paused
                if !paused && regionActive {
                    // Quiet accumulated while paused must not dissolve the
                    // region the instant we resume.
                    regionLastChangeUS = nowUS
                }
                onPausedChanged?(paused)
            case let .resize(mode, width, height, scale):
                onResizeRequested?(Int(mode), Int(width), Int(height), Int(scale))
            case let .input(kind, x, y, a, b):
                onInput?(Int(kind), Int(x), Int(y), Int(a), Int(b))
            case let .clipboard(format, data):
                onClipboard?(format, data)
            case let .quality(scale, floor, pref):
                applyQualityPolicy(scalePct: Int(scale), floor: floor, preferSharpness: pref == 1)
            case let .windowSelect(windowID):
                onWindowSelect?(windowID)
            case let .windowControl(action, width, height):
                onWindowControl?(action, width, height)
            case let .viewerLog(name, offset, total, data):
                onViewerLog?(name, offset, total, data)
            case let .textInput(text):
                onTextInput?(text)
            case let .agentState(active, label):
                onAgentState?(active, label)
            case let .uiTreeRequest(requestID, windowID, maxNodes):
                onUITreeRequest?(requestID, windowID, Int(maxNodes))
            case let .viewerInfo(name):
                onViewerInfo?(name)
            case let .syncRequest(region, generation):
                noteSyncRequest(region: region, generation: generation)
            case .hello, .scroll, .cursorPos, .cursorImage, .windowList, .uiTree, .agentScope:
                break // host-originated / not addressed to the host
            }
        }
        if deframer.isMalformed {
            enterFailed("malformed control stream")
        }
    }

    /// `.failed` is terminal — no pixels, no PINGs — so the app must hear
    /// about it: its PONG liveness check only runs while `.running`, and a
    /// silently failed engine otherwise wedges the session until the viewer
    /// gives up.
    private func enterFailed(_ reason: String) {
        guard state != .failed else { return }
        state = .failed
        onFailed?(reason)
    }

    /// The transport lost the video stream (QUICTransport `onVideoReset`):
    /// frames and keyframes in flight are gone, and the viewer has discarded
    /// any partial message. A live region can't continue — its decoder is
    /// missing references and its encoder emits config only once — so it
    /// dissolves (lossless repaint) and re-forms later with a fresh START
    /// and sync frame. A keyframe in flight times out into the tile path.
    public func videoChannelReset() {
        guard state == .running else { return }
        stats.videoChannelResets += 1
        dissolveRegion(revealUnchanged: false)
    }

    /// Timeout resolution + PING cadence (1/s). Call regularly.
    public func tick(nowUS: UInt64) {
        resolveTimeouts(nowUS: nowUS)
        // Video: captures may stop entirely (video paused on an otherwise-static
        // screen) — quiescence dissolve must not depend on encode ticks.
        // Scaled by the same adaptive patience as the tick-based limit: an
        // unscaled 700 ms would fire in every Photos page gap (~2 s between
        // pages) and silently bypass the anti-thrash escalation.
        let quietUS = Self.videoQuietUSLimit
            &* UInt64(regionQuietLimit) / UInt64(Self.videoQuietTicksLimit)
        // contentPaused: quiet is expected (nothing is fed to the encoder) —
        // dissolving would queue a settle repaint for a window nobody sees.
        if regionActive && !contentPaused && nowUS &- regionLastChangeUS >= quietUS {
            dissolveRegion()
        }
        // No application keepalive datagrams (INV-10 holds exactly): QUIC's
        // own keepalive on both tunnels (QUICTransport.keepAliveS) keeps an
        // idle flow — pinned mode can idle it for minutes — alive through
        // idle timers and middleboxes; `silentSessionOutlivesTheIdleTimeout`
        // proves it.
        if state == .running && nowUS &- lastPingUS >= 1_000_000 {
            pingNonce &+= 1
            sendControl(.ping(nonce: pingNonce, tUS: sendStampUS(nowUS)))
            lastPingUS = nowUS
            evaluateScalePressure()
        }
    }

    // MARK: - Auto-scale pressure (thin links)

    /// Resolution is the adaptive ladder's rung below quality: when the
    /// link's ack-delay sits above the severe threshold for a sustained
    /// window (and quality has nowhere left to go), the app should downscale
    /// the capture — fewer pixels shrink video bitrate and settle size at
    /// once. Latched for the session: native restores
    /// on disconnect (the app's captureModified path), never mid-session —
    /// a healthy-streak swap-back would cost a renegotiation blink and invite
    /// an immediate return trip on an intermittently-healthy link.
    /// Fires at most once; evaluated on the 1 Hz PING cadence, and only on
    /// seconds that produced a fresh ack-delay reading (neither an idle
    /// session nor a video-only one may accumulate streaks off a stale EWMA).
    public var onScalePressureConstrained: (() -> Void)?
    /// The engine entered `.failed` (terminal). Engine queue, once.
    public var onFailed: ((_ reason: String) -> Void)?
    public static let autoScaleSevereSeconds = 6
    private var scalePressureConstrained = false
    private var severeStreakS = 0
    private var scaleEvalPrevSampleUS: UInt64 = 0

    private func evaluateScalePressure() {
        guard !scalePressureConstrained else { return }
        // Only seconds with a FRESH ack-delay reading count. ackDelayUS
        // updates solely on tile-batch ACKs, so gating on total send
        // activity (video included) would count a value frozen since the
        // last congested settle, every second, while pinned video carries the
        // motion over a recovered link. No fresh reading: hold.
        guard ackDelaySampleUS != scaleEvalPrevSampleUS else { return }
        scaleEvalPrevSampleUS = ackDelaySampleUS
        severeStreakS = ackDelayUS > Self.governorSevereAckDelayUS ? severeStreakS + 1 : 0
        if severeStreakS >= Self.autoScaleSevereSeconds {
            scalePressureConstrained = true
            onScalePressureConstrained?()
        }
    }

    // MARK: - Encode tick (§4.3)

    /// §3.3 budget: `min(transport max − 32, 1200)`. Nil below 1024 — no QUIC
    /// path is that small (Initial packets need 1200-byte UDP payloads), and
    /// the arena's per-tile record/header headroom assumes it.
    static func datagramBudget(forTransportMax max: Int) -> Int? {
        let b = min(max - 32, 1200)
        return b >= 1024 ? b : nil
    }

    public func encodeTick(
        frame: UnsafeRawBufferPointer,
        bytesPerRow: Int,
        dirtyRects: [DirtyRect]?,
        captureTimestampUS: UInt64,
        nowUS: UInt64
    ) {
        // Encode duty (Auto's headroom bound): this tick's real encode time
        // over the capture interval since the previous tick (`nowUS` — real
        // in the app, trace time in a replay).
        let encodeStartUS = encodeTimer?()
        let encodeIntervalUS = lastEncodeNowUS == 0 ? 0 : Self.elapsedUS(nowUS, since: lastEncodeNowUS)
        lastEncodeNowUS = nowUS
        defer {
            if let encodeStartUS, let encodeTimer {
                governor.noteEncode(durationUS: Self.elapsedUS(encodeTimer(), since: encodeStartUS),
                                    intervalUS: encodeIntervalUS)
            }
        }
        // Re-read every tick: QUIC reports the path's usable datagram size
        // only once the flow is ready — after this engine was built — and a
        // budget above it makes every full datagram fail to send, looping
        // the same tiles through timeout forever.
        if let live = Self.datagramBudget(forTransportMax: transport.maxDatagramSize), live != budget {
            budget = live
        }
        resolveTimeouts(nowUS: nowUS)
        guard state == .running else { return }
        // Paused: viewer invisible — ship nothing at all. Changed pixels
        // still differ from the ACKed map and re-qualify on resume (INV-4's
        // argument); the active region idles un-dissolved.
        if contentPaused {
            stats.ticksPaused += 1
            noteSkippedRects(dirtyRects)
            return
        }
        currentCaptureUS = captureTimestampUS
        // INV-4: newest wins, never queue. Changed pixels still differ from the
        // ACKed map and re-qualify on the next allowed tick.
        //
        // The same holds for the transport's pacer: a batch encoded behind a
        // deep backlog only waits there, and an overflowing pacer queue
        // drops the OLDEST datagrams — the ones about to leave. Measured at
        // cold start (2048² over QUIC) without this wait: the first batch
        // (~14.6k datagrams) plus the second open batch overflow the queue,
        // 1,431 datagrams die on the host, and the adaptive pace reads them
        // as viewer loss and halves itself. Waiting for the backlog to drain
        // sends fresher pixels no later.
        let pacerBacklogged = transport.pacesDatagrams
            && transport.queuedDatagramBytes > pace.rate / 1_000_000 * Self.pacerBacklogLimitUS
        guard openBatchCount < 2 && !pacerBacklogged else {
            stats.batchesDropped += 1
            if pacerBacklogged { stats.pacerBacklogSkips += 1 }
            noteSkippedRects(dirtyRects)
            // Video: the path is exempt from record-pipeline saturation —
            // an active region keeps streaming (its frames don't ride
            // batches). Without hashes there is no churn evidence, so a
            // saturated tick never forms a region.
            if videoNegotiated {
                videoSaturatedTick(frame: frame, bytesPerRow: bytesPerRow,
                                   dirtyRects: dirtyRects, nowUS: nowUS)
            }
            return
        }
        precondition(bytesPerRow >= grid.width * 4, "bytesPerRow too small")
        precondition(frame.count >= (grid.height - 1) * bytesPerRow + grid.width * 4, "frame too small")

        let signpostState = Signposts.host.beginInterval("encode", id: Signposts.host.makeSignpostID())
        defer { Signposts.host.endInterval("encode", signpostState) }

        collectCandidates(dirtyRects: dirtyRects)

        let slot = batches[0].active ? 1 : 0
        batches[slot].tiles.removeAll(keepingCapacity: true)
        packer.reset()
        var qualified = 0
        let maxFragPayload = budget - DatagramHeader.byteSize - 8

        // Hash candidates in place (no copies; §4.5 canonical
        // row order via XXH64.hashRows). Read-only over the frame and disjoint
        // writes per candidate, so wide candidate sets fan out across cores;
        // encodeTick itself stays synchronous on the encode queue (§8.8 —
        // this is data parallelism, not actors/await).
        hashCandidates(frame: frame, bytesPerRow: bytesPerRow)

        // Cold start with video (§4.3 step 3): the first paint
        // IS the video stream — form the full-screen region on the very
        // first tick and let the encoder's sync frame carry the picture. Wire cost is one streaming-sized frame
        // instead of the striped WebP pair (lossy paint + lossless keyframe
        // is ~MBs of reliable-stream data at 5K — tens of seconds on a
        // residential uplink). Every tile stays cold (ackedHash = 0), so the
        // usual dissolve → pendingRepaint → governed tile path performs the
        // lossless settle behind the already-presented picture.
        if !firstBatchSent && videoNegotiated && !regionActive {
            formRegion(frame: frame, bytesPerRow: bytesPerRow, nowUS: nowUS)
            if regionActive {
                firstBatchSent = true
                stats.videoColdStarts += 1
                stats.lastTickQualifiedTiles = 0
                return
            }
            // Encoder refused to start — fall through to the keyframe path.
        }

        // Cold start without video (§4.3 step 3, §4.7) — a video-less
        // session, or the encoder refused to start: the entire first frame as one striped
        // VP8L keyframe on the reliable stream — 2–3× smaller than the tile
        // flood and immune to datagram loss. Falls through to the normal
        // path when the frame is too incompressible to fit the budget.
        // A lossy q90 first paint goes out ahead of it on the same
        // ordered stream — a full picture in a blink, transient by
        // construction (see KeyframeCodec.webpLossyStriped).
        if !firstBatchSent && coldStartKeyframes && !kfActive {
            sendLossyFirstPaint(c0: 0, r0: 0, c1: grid.cols - 1, r1: grid.rows - 1,
                                frame: frame, bytesPerRow: bytesPerRow)
            if sendKeyframe(c0: 0, r0: 0, c1: grid.cols - 1, r1: grid.rows - 1,
                            frame: frame, bytesPerRow: bytesPerRow, nowUS: nowUS) {
                firstBatchSent = true
                stats.lastTickQualifiedTiles = 0
                return
            }
            stats.keyframeFallbacks += 1
        }

        // Scroll detection (§4.3 step 4, §4.8): if the tick is heavy, try to
        // explain it as a shift of ACKed content (vertical, horizontal or a
        // 2-D drag); on success the SCROLL op ships via control, the
        // shadow/acked maps shift, and qualification sees most tiles already
        // satisfied.
        maybeEmitScroll(frame: frame, bytesPerRow: bytesPerRow)

        // The batch seq is claimed AFTER any scroll emission: the scroll
        // consumes a seq of its own, and the residual batch must be strictly
        // newer or the viewer's LWW gate (tileSeq = scrollSeq) blocks every
        // same-tick residual (a same-seq collision diverges the real-trace
        // golden).
        let frameSeq = nextFrameSeq

        // Qualify (§4.3 step 5; serial, cheap): send iff changed vs ACKed AND
        // not identical to what is already in flight (skip-if-identical-in-
        // flight covers the ACK round trip).
        //
        // Send governor (§4.9): qualification is where the global send-rate cap
        // lives. A deferred tile is NOT queued — it simply fails to qualify
        // this tick and re-qualifies next tick against the CURRENT frame, so
        // pacing degrades temporal resolution under overload, never
        // freshness (the INV-4 property, applied per tile). Deferrals still
        // count as pending work (lastTickQualifiedTiles) so settle knows the
        // canvas hasn't converged.
        governor.adapt(nowUS: nowUS,
                       ceiling: transport.pacesDatagrams ? pace.rate : SendGovernor.maxAutoRate)
        governor.refill(nowUS: nowUS, limit: rateLimit)
        stats.governorRate = governor.rate(rateLimit)
        stats.encodeDutyPercent = Int((governor.encodeDuty ?? 0) * 100)
        var governorBudget = governor.tokens
        var governorDeferred = 0
        let estimate = governor.admissionEstimate
        qualTiles.removeAll(keepingCapacity: true)
        qualHashes.removeAll(keepingCapacity: true)
        // Fresh before owed: admitted in the same rotation as what the user
        // just typed, a dissolve's repaint — hundreds of owed tiles — would
        // queue a keystroke behind up to 1.8 s of catch-up on a 150 ms
        // tether (BENCHMARKS 'Fresh-before-owed admission; video cap on an
        // unmeasured queue'). Pass 0 admits this tick's dirty
        // rects; pass 1 the owed tiles, capped at `owedBurstUS` of the rate
        // per tick so a repaint trickles instead of bursting into the path
        // ahead of the next keystroke. Rotating admission (SendGovernor.rotor)
        // within each pass.
        var exhaustedAt = -1
        let owedCap = max(estimate, governor.rate(rateLimit) * Self.owedBurstUS / 1_000_000)
        for pass in 0..<2 {
        let lo = pass == 0 ? 0 : worklistFresh
        let span = (pass == 0 ? worklistFresh : worklist.count) - lo
        guard span > 0 else { continue }
        var start = 0
        if governor.rotor > 0 {
            while start < span && Int(worklist[lo + start]) < governor.rotor { start += 1 }
            if start == span { start = 0 }
        }
        let passBudgetStart = governorBudget
        for n in 0..<span {
            let i = lo + (start + n) % span
            let idx = Int(worklist[i])
            let h = hashResults[i]
            if ledger.qualifies(idx, hash: h) {
                let owedSpent = passBudgetStart - governorBudget
                guard governorBudget > 0, pass == 0 || owedSpent < owedCap else {
                    governorDeferred += 1
                    if exhaustedAt < 0 { exhaustedAt = idx }
                    // A deferred tile is owed a send that dirty rects may
                    // never volunteer again: capture only reports tiles whose
                    // pixels CHANGE, and "qualified" means "differs from the
                    // ACKed copy", not "still changing" — a tile that changed
                    // once and lost the budget would otherwise sit stale for
                    // as long as captures stay busy elsewhere (the app's
                    // quiet-gap full scans never fire). COLD tiles (cold
                    // start, dissolve repaint, timeout, NACK) re-arm
                    // pendingRepaint — they are settle work. WARM tiles ride
                    // the separate carry mask, which re-volunteers them
                    // without counting as settle volunteers: churn overload
                    // is not a settle drain (tickSettleVolunteers gates VP8L
                    // probing).
                    deferQualifiedTile(idx)
                    continue
                }
                governorBudget -= estimate
                qualTiles.append(worklist[i])
                qualHashes.append(h)
            }
        }
        }
        governor.rotor = exhaustedAt >= 0 ? exhaustedAt : 0
        if governorDeferred > 0 { governor.noteDeferred() }
        stats.governorDeferredTiles += governorDeferred
        let qualCount = qualTiles.count

        // Per-tile codec choice (§4.3 step 6): parallel per-tile payload
        // encode. Each qualifying tile is extracted into its retention slot
        // (which doubles as the RAW payload and the shadow-promotion source)
        // and compressed best-of:
        // RAW/LZ4/LZBITMAP always; WEBPL (VP8L, ~240 µs/tile at z4) only when
        // the tick is small enough that its fanned-out cost fits the 60 Hz
        // tick interval.
        // Settle drain (post-dissolve repaint, captures quiet): the content
        // is static and the CPU idle, so probe VP8L at the settle cap
        // instead of the 60 Hz limit — the governor's burst bucket admits a
        // dissolve repaint in ticks of 1000s of tiles, and the all-or-
        // nothing gate below would ship ENTIRE settles as LZ4 (~3× the
        // bytes on text; measured in BENCHMARKS.md "Settle coalescing").
        // A full 5K settle (3,600 tiles) fits the 4096 cap ≈ 100 ms fanned
        // out — a one-time stall on a quiet queue.
        let settleDrain = !regionActive && tickSettleVolunteers > 0
        let webpLimit = settleDrain ? Self.webpTileLimitSettleCap : Self.webpTileLimit
        let tryWebP = qualCount > 0 && qualCount <= webpLimit
        if qualCount > 0 {
            // Routing memory gate: even inside the global time budget, tiles
            // whose recent VP8L probes lost sit out until their backoff
            // countdown re-probes them. Countdown ticks only when the global
            // gate is open (a heavy tick probes nobody and teaches nothing).
            for q in 0..<qualCount {
                let idx = Int(qualTiles[q])
                deltaBases[q] = deltaRecords && ledger[idx].inflightSeq == 0
                    ? ledger[idx].ackedHash : 0
                if tryWebP {
                    if webpSkips[idx] > 0 {
                        webpSkips[idx] -= 1
                        webpTryFlags[q] = 0
                        stats.webpProbesSkipped += 1
                    } else {
                        webpTryFlags[q] = 1
                        stats.webpProbes += 1
                    }
                } else {
                    webpTryFlags[q] = 0
                }
            }
            qualTiles.withUnsafeBufferPointer { tilesBuf in
                encodeMeta.withUnsafeMutableBufferPointer { metaBuf in
                    webpTryFlags.withUnsafeBufferPointer { flagsBuf in
                        for worker in encodeWorkers {
                            worker.webpSubPixelBudget = Self.deltaWebpPixelBudgetPerWorker
                        }
                        deltaBases.withUnsafeBufferPointer { basesBuf in
                            let job = PayloadEncodeJob(
                                frame: frame, bytesPerRow: bytesPerRow, grid: grid,
                                tiles: tilesBuf,
                                retentionBase: retention[slot].baseAddress!,
                                outBase: encodeOut.baseAddress!,
                                meta: metaBuf,
                                count: qualCount, workers: encodeWorkers, webpTry: flagsBuf,
                                deltaBases: basesBuf,
                                shadow: UnsafeRawBufferPointer(shadow), canvasWidth: grid.width,
                                vp8lEffort: tileEffort(qualifiedTiles: qualCount))
                            if qualCount >= 8 {
                                DispatchQueue.concurrentPerform(iterations: encodeWorkers.count) { job.run($0) }
                            } else {
                                job.runSerially()
                            }
                        }
                    }
                }
            }
            for q in 0..<qualCount where encodeMeta[q].webpOutcome != 0 {
                let idx = Int(qualTiles[q])
                if encodeMeta[q].webpOutcome == 1 {
                    webpBackoff[idx] = 0
                } else {
                    let next = webpBackoff[idx] == 0
                        ? Self.webpBackoffInitial
                        : min(webpBackoff[idx] &* 2, Self.webpBackoffMax)
                    webpBackoff[idx] = next
                    webpSkips[idx] = next
                }
            }
        }

        // Pack (§4.3 step 7): serial fragmentation + packing (arena order matters).
        var capDeferred = 0
        for q in 0..<qualCount {
            // dgram_cnt is a u16 and one tile can span up to 255 datagrams:
            // stop admitting before the count could overflow (a 6K/8K screen
            // of incompressible RAW tiles can pass the governor's estimate and
            // would trip the precondition below). The rest ship next tick.
            if packer.closedCount > maxBatchDatagrams - 256 {
                for rest in q..<qualCount { deferQualifiedTile(Int(qualTiles[rest])) }
                capDeferred = qualCount - q
                stats.batchCapDeferredTiles += capDeferred
                break
            }
            let idx = Int(qualTiles[q])
            let hash = qualHashes[q]
            let meta = encodeMeta[q]
            let (_, _, tw, th) = grid.rect(of: idx)
            let tight = UnsafeRawBufferPointer(
                start: retention[slot].baseAddress!.advanced(by: q * Self.tileBytes),
                count: tw * th * 4)

            // Tile-cache decision (full 64×64 tiles only): a verified hit ships
            // an 11-byte REF; a miss with an allocatable slot wraps the payload
            // in STORE_APPLY so the content seeds the cache.
            //
            // A REF (11 B) beats every encoding, DELTA included — only the
            // STORE is barred for DELTA-coded tiles (a STORE wraps absolute
            // content). Skipping the lookup for DELTA tiles too would make a
            // revert to cached content (blink, window switch-back) always
            // ship the larger DELTA.
            var cacheKind: UInt8 = 0
            var cacheSlot: UInt16 = 0
            if tw == TileGrid.tileSize && th == TileGrid.tileSize {
                if let hit = cache.lookup(hash: hash, tight: tight) {
                    cacheKind = 2
                    cacheSlot = UInt16(hit)
                    cache.pinRef(hit)
                    stats.cacheRefsSent += 1
                } else if meta.opcode != Opcode.delta, let slot = cache.beginStore(hash: hash) {
                    cacheKind = 1
                    cacheSlot = UInt16(slot)
                    stats.cacheStoresSent += 1
                }
            }

            let opcode: UInt8
            let body: UnsafeRawBufferPointer
            var prefixLen = 0
            switch cacheKind {
            case 2: // REF: the whole payload is the prefix
                opcode = Opcode.cache
                prefixLen = CachePayload.writeRef(slot: cacheSlot, contentHash: hash, into: cachePrefix)
                body = UnsafeRawBufferPointer(start: nil, count: 0)
            case 1: // STORE_APPLY prefix ++ the tile's own payload
                opcode = Opcode.cache
                prefixLen = CachePayload.writeStoreApplyPrefix(slot: cacheSlot, innerOpcode: meta.opcode,
                                                               into: cachePrefix)
                body = UnsafeRawBufferPointer(
                    start: meta.opcode == Opcode.raw
                        ? retention[slot].baseAddress!.advanced(by: q * Self.tileBytes)
                        : encodeOut.baseAddress!.advanced(by: q * Self.tileBytes),
                    count: Int(meta.length))
            default:
                opcode = meta.opcode
                if opcode == Opcode.delta { stats.deltasSent += 1 }
                body = UnsafeRawBufferPointer(
                    start: meta.opcode == Opcode.raw
                        ? retention[slot].baseAddress!.advanced(by: q * Self.tileBytes)
                        : encodeOut.baseAddress!.advanced(by: q * Self.tileBytes),
                    count: Int(meta.length))
            }

            let logicalLen = prefixLen + body.count
            let fragCnt = max(1, (logicalLen + maxFragPayload - 1) / maxFragPayload)
            precondition(fragCnt <= 255, "tile payload cannot exceed 255 fragments")
            var firstDgram = Int32(-1)
            var lastDgram = Int32(-1)
            var offset = 0
            for frag in 0..<fragCnt {
                let fragLen = min(maxFragPayload, logicalLen - offset)
                let dgramIdx = packer.append(
                    opcode: opcode, tileIdx: UInt16(idx), fragIdx: UInt8(frag), fragCnt: UInt8(fragCnt),
                    prefix: UnsafeRawBufferPointer(start: cachePrefix.baseAddress, count: prefixLen),
                    body: body, logicalOffset: offset, length: fragLen, budget: budget)
                if firstDgram < 0 { firstDgram = dgramIdx }
                lastDgram = dgramIdx
                offset += fragLen
            }

            batches[slot].tiles.append(BatchTile(tileIdx: UInt16(idx), hash: hash,
                                                 firstDgram: firstDgram, lastDgram: lastDgram,
                                                 cacheKind: cacheKind, cacheSlot: cacheSlot,
                                                 remaining: 0))
            // INV-9: one in-flight slot per tile — overwrites any prior send;
            // ACKs for the overwritten send are ignored by the seq guard.
            ledger.markInflight(idx, hash: hash, seq: frameSeq)
            traceTile(idx, "host send seq=\(frameSeq) hash=\(String(hash, radix: 16)) op=\(opcode)")
            qualified += 1
            stats.tilesSent += 1
        }

        // Video (§4.6): formation, region service
        // (extract/diff/submit) and dissolve. Runs regardless of
        // `qualified` — a tick that is *pure* video churn has no records at
        // all, only encoder frames on the video stream.
        if videoNegotiated {
            videoPhase(frame: frame, bytesPerRow: bytesPerRow, dirtyRects: dirtyRects,
                       demandCount: qualCount + governorDeferred, nowUS: nowUS)
        }

        stats.lastTickQualifiedTiles = qualified + governorDeferred + capDeferred
        guard qualified > 0 else { return } // INV-10: idle = zero bytes

        let dgramCnt = packer.finish(frameSeq: frameSeq, captureTimestampUS: captureTimestampUS)
        precondition(dgramCnt >= 1 && dgramCnt <= maxBatchDatagrams)

        for i in 0..<batches[slot].tiles.count {
            batches[slot].tiles[i].remaining =
                batches[slot].tiles[i].lastDgram - batches[slot].tiles[i].firstDgram + 1
        }

        var batchBytes = 0
        outgoingDatagrams.removeAll(keepingCapacity: true)
        for i in 0..<dgramCnt {
            let datagram = packer.datagram(i)
            let size = datagram.count
            outgoingDatagrams.append(Data(datagram))
            stats.datagramsSent += 1
            stats.bytesOut += size
            stats.tileBytesOut += size
            batchBytes += size
        }
        let queuedAhead = transport.queuedDatagramBytes
        transport.sendDatagrams(outgoingDatagrams) // one handoff per batch
        outgoingDatagrams.removeAll(keepingCapacity: true)

        governor.settle(batchBytes: batchBytes, tilesSent: qualified)

        batches[slot].active = true
        batches[slot].frameSeq = frameSeq
        batches[slot].sendTimeUS = sendStampUS(nowUS)
        let serializationRate = transport.pacesDatagrams ? pace.rate : DatagramPacing.bytesPerSecond
        batches[slot].aheadUS = UInt64(queuedAhead) &* 1_000_000 / UInt64(serializationRate)
        batches[slot].ownUS = UInt64(batchBytes) &* 1_000_000 / UInt64(serializationRate)
        batches[slot].serializationUS = batches[slot].aheadUS &+ batches[slot].ownUS
        batches[slot].paceRate = transport.pacesDatagrams ? pace.rate : 0
        batches[slot].byteSize = batchBytes
        batches[slot].dgramCnt = dgramCnt
        batches[slot].confirmed.removeAll(keepingCapacity: true)
        batches[slot].confirmed.append(contentsOf: repeatElement(false, count: dgramCnt))
        batches[slot].confirmedCnt = 0
        batches[slot].dgramFirstTile.removeAll(keepingCapacity: true)
        batches[slot].dgramFirstTile.append(contentsOf: repeatElement(-1, count: dgramCnt))
        for t in stride(from: batches[slot].tiles.count - 1, through: 0, by: -1) {
            let tile = batches[slot].tiles[t]
            for d in Int(tile.firstDgram)...Int(tile.lastDgram) {
                batches[slot].dgramFirstTile[d] = Int32(t) // descending: ends at the lowest
            }
        }
        stats.batchesSent += 1
        firstBatchSent = true
        nextFrameSeq &+= 1
        if nextFrameSeq == 0 { nextFrameSeq = 1 }
    }

    // The tile-path send governor (SendGovernor, §4.9); constants public
    // for tests and telemetry.
    var governor = SendGovernor()

    /// Tests only: start the send governor as if the link were already
    /// known fast (fast-link start: 8.4 MB/s, full 16 MB burst) — for tests of
    /// scroll/encoder logic that assume one tick ships a whole frame.
    public func assumeFastLinkForTests() {
        governor = SendGovernor(fastLinkStart: true)
    }
    /// The tile path's send-rate policy (the host app's Bandwidth setting).
    /// Engine queue.
    public var rateLimit: RateLimit = .auto
    /// libwebp lossless preset (0–9) overrides; nil = the measured policy
    /// below (BENCHMARKS "VP8L effort sweep"). Engine queue.
    public var vp8lEffort: Int32?
    public var keyframeEffort: Int32?
    /// Per-tile VP8L (and DELTA sub-rects): small ticks keep effort 4 —
    /// bytes matter there and CPU is noise (typing: effort 1 costs +5 %
    /// steady bytes for nothing); ticks past `vp8lBurstTiles` drop to 1,
    /// which costs 0.4–1.5 % bytes for 23–40 % less encode CPU on scroll /
    /// drag traces. 3 ≈ 4 and 5–6 buy only CPU.
    static let vp8lSmallTickEffort: Int32 = 4
    static let vp8lBurstEffort: Int32 = 1
    static let vp8lBurstTiles = 32
    /// Keyframes: time to exact ≈ encode + bytes / rate. Effort 0 encodes a
    /// 5K cold start in ~190 ms vs ~730–920 ms at 4 (+11 % bytes), winning
    /// above ~2.2 MB/s; effort 1 (~425 ms, +2.6 %) wins below that.
    static let keyframeFastEffort: Int32 = 0
    static let keyframeSlowEffort: Int32 = 1
    static let keyframeFastRateBytesPerSecond = 2_500_000

    /// This tick's tile effort.
    func tileEffort(qualifiedTiles: Int) -> Int32 {
        vp8lEffort ?? (qualifiedTiles > Self.vp8lBurstTiles ? Self.vp8lBurstEffort : Self.vp8lSmallTickEffort)
    }

    /// The effort for a keyframe sent now.
    var currentKeyframeEffort: Int32 {
        keyframeEffort ?? (governor.rate(rateLimit) >= Self.keyframeFastRateBytesPerSecond
                           ? Self.keyframeFastEffort : Self.keyframeSlowEffort)
    }
    public static let governorSevereAckDelayUS = SendGovernor.severeAckDelayUS
    public static let governorBucketCap = SendGovernor.bucketCap
    public internal(set) var ackDelayUS: UInt64 = 0
    /// When ackDelayUS last took a sample (0 = never) — lets consumers tell
    /// a fresh congestion reading from a value frozen since the last batch.
    var ackDelaySampleUS: UInt64 = 0
    var lastControlNowUS: UInt64 = 0
    var pace = PaceController()
    /// Encode ticks are skipped while the pacer holds more than this much
    /// sending time (at the current pace) — a new batch waits ≤ ~20 ms.
    static let pacerBacklogLimitUS = 20_000
    /// Extra caps bits for the outgoing HELLO (the app sets geometryFinal
    /// after applying a handshake geometry request).
    public var extraHelloCaps: UInt32 = 0

    /// Handshake fast path: the viewer requested a geometry the host already
    /// satisfies (e.g. native when already native). Re-send HELLO with
    /// geometryFinal on the SAME connection so the viewer proceeds without a
    /// reconnect. Valid only while still in the handshake.
    public func reofferHelloFinal(nowUS: UInt64) {
        guard state == .helloSent else { return }
        extraHelloCaps |= WireCaps.geometryFinal
        // The SRTT seed is THIS exchange's round trip. Left at start()'s
        // stamp, the seed would span the whole negotiation (the app's display
        // switch takes seconds): SRTT, and 3 × SRTT batch timeouts, would run
        // seconds long until PINGs decayed it (~20 s at α = 1/8, 1 Hz).
        helloSentUS = sendStampUS(nowUS)
        sendControl(.hello(ver: WireVersion.current,
                           width: UInt16(grid.width), height: UInt16(grid.height),
                           tileSize: UInt8(TileGrid.tileSize),
                           pixfmt: PixelFormat.bgra8sRGB,
                           caps: extraHelloCaps | videoCaps))
    }
    /// Video caps for HELLO: one bit per codec the encoder factory may be
    /// asked for (none without a factory — `GLASSACT_TILE_ONLY`, agents).
    private var videoCaps: UInt32 {
        videoEncoderFactory == nil ? 0
            : videoCodecPreference.reduce(0) { $0 | WireCaps.bit(forVideoCodec: $1) }
    }
    /// Cursor as metadata: the viewer composites the pointer from control messages; while
    /// negotiated the host should capture with showsCursor = false.
    public private(set) var cursorNegotiated = false

    /// Cursor as metadata: publish pointer state (encodeQueue-confined, like everything).
    /// No-ops until negotiated; the app polls position and calls on change.
    public func publishCursor(x: Int, y: Int, visible: Bool) {
        guard state == .running, cursorNegotiated else { return }
        sendControl(.cursorPos(x: UInt16(clamping: x), y: UInt16(clamping: y), visible: visible))
    }

    public func publishCursorImage(width: Int, height: Int, hotspotX: Int, hotspotY: Int,
                                   scale: Int, bgra: [UInt8]) {
        guard state == .running, cursorNegotiated,
              width >= 1, height >= 1, width <= 512, height <= 512,
              bgra.count == width * height * 4 else { return }
        sendControl(.cursorImage(width: UInt16(width), height: UInt16(height),
                                 hotspotX: UInt16(clamping: hotspotX),
                                 hotspotY: UInt16(clamping: hotspotY),
                                 scale: UInt8(clamping: scale), bgra: bgra))
    }
    /// Formation: this many tiles churning in one tick form the region; a
    /// frame touching fewer counts as quiet (typing returns to tiles).
    static let pinnedFormMinTiles = 32
    /// Re-sharpen once the region has been quiet this long…
    public static let refreshQuietUS: UInt64 = 1_000_000
    /// …at most this often (a keyframe costs a second or two of a thin link)…
    public static let refreshMinIntervalUS: UInt64 = 5_000_000
    /// SYNC_REQUEST answers: at most one sync frame this often. A sync
    /// frame is the most expensive frame there is, and the request comes
    /// from the peer: a viewer asking every frame must not turn the region
    /// into all-keyframe video. Requests inside the window aren't dropped —
    /// they coalesce into one sync when it ends.
    public static let syncRequestMinIntervalUS: UInt64 = 500_000
    /// A region tile still this long goes back to its exact canvas copy.
    public static let defaultHandoffStillUS: UInt64 = 1_000_000
    /// …when large changes since the last keyframe covered ≥ 1/this of the
    /// region, or the cap grew this many times over since it.
    static let refreshDamageDivisor = 10
    static let refreshCapGrowth = 2
    /// An update under 1/this of the region's area is "small" (a caret, a
    /// spinner, one animating panel) and doesn't hold off the re-sharpen.
    static let refreshSmallUpdateDivisor = 4
    /// Owed tiles (repaint, carry) admitted per tick: at most this much of
    /// the send rate's time — they trickle; fresh changes get the bucket.
    static let owedBurstUS = 50_000

    // MARK: - Candidate selection

    private func collectCandidates(dirtyRects: [DirtyRect]?) {
        worklist.removeAll(keepingCapacity: true)
        candidateEpoch &+= 1
        if candidateEpoch == 0 {
            candidateEpoch = 1
            for i in 0..<candidateMark.count { candidateMark[i] = 0 }
        }
        // First frame after connect scans all tiles (cold start; ackedHash == 0
        // guarantees send). Dirty rects are hints and only trusted after that.
        // Skipped ticks' damage is this tick's damage too (missedDirty).
        let scanAll = missedScanAll
        missedScanAll = false
        tickMissedDamage = scanAll || !missedDirtyTiles.isEmpty
        guard let rects = dirtyRects, firstBatchSent, !scanAll else {
            clearMissedDirty()
            for i in 0..<grid.count where !videoHolds(i) {
                candidateMark[i] = candidateEpoch
                worklist.append(Int32(i))
            }
            worklistFresh = worklist.count
            drainPendingRepaint()
            return
        }
        let ts = TileGrid.tileSize
        for r in rects {
            guard r.width > 0 && r.height > 0 else { continue }
            let c0 = max(0, r.x) / ts
            let c1 = min(grid.width - 1, r.x + r.width - 1) / ts
            let r0 = max(0, r.y) / ts
            let r1 = min(grid.height - 1, r.y + r.height - 1) / ts
            guard c0 <= c1 && r0 <= r1 && c0 < grid.cols && r0 < grid.rows else { continue }
            for row in r0...r1 {
                for col in c0...c1 {
                    let idx = row * grid.cols + col
                    if candidateMark[idx] != candidateEpoch && !videoHolds(idx) {
                        candidateMark[idx] = candidateEpoch
                        worklist.append(Int32(idx))
                    }
                }
            }
        }
        for t in missedDirtyTiles {
            let idx = Int(t)
            missedDirty[idx] = false
            if candidateMark[idx] != candidateEpoch && !videoHolds(idx) {
                candidateMark[idx] = candidateEpoch
                worklist.append(t)
            }
        }
        missedDirtyTiles.removeAll(keepingCapacity: true)
        worklistFresh = worklist.count
        drainPendingRepaint()
    }

    /// A tick is returning before `collectCandidates`: keep its damage for
    /// the next tick that runs (see `missedDirty`). No rects (or not yet
    /// trusted) → that tick scans everything.
    private func noteSkippedRects(_ dirtyRects: [DirtyRect]?) {
        guard !missedScanAll else { return }
        guard let rects = dirtyRects, firstBatchSent else {
            missedScanAll = true
            clearMissedDirty()
            return
        }
        let ts = TileGrid.tileSize
        for r in rects {
            guard r.width > 0 && r.height > 0 else { continue }
            let c0 = max(0, r.x) / ts
            let c1 = min(grid.width - 1, r.x + r.width - 1) / ts
            let r0 = max(0, r.y) / ts
            let r1 = min(grid.height - 1, r.y + r.height - 1) / ts
            guard c0 <= c1 && r0 <= r1 && c0 < grid.cols && r0 < grid.rows else { continue }
            for row in r0...r1 {
                for col in c0...c1 {
                    let idx = row * grid.cols + col
                    if !missedDirty[idx] {
                        missedDirty[idx] = true
                        missedDirtyTiles.append(Int32(idx))
                    }
                }
            }
        }
    }

    private func clearMissedDirty() {
        for t in missedDirtyTiles { missedDirty[Int(t)] = false }
        missedDirtyTiles.removeAll(keepingCapacity: true)
    }

    /// Tiles owed a send that dirty rects will not volunteer (TileLedger's
    /// repaint + carry queues) join this tick's candidates; the repaint
    /// count is this tick's settle work.
    private func drainPendingRepaint() {
        tickSettleVolunteers = ledger.drainOwed { i in
            if candidateMark[i] != candidateEpoch && !videoHolds(i) {
                candidateMark[i] = candidateEpoch
                worklist.append(Int32(i))
            }
        }
    }

    /// The region's video owns this tile: the lossless path keeps out of it,
    /// unless the tile is still and owed its handoff record.
    @inline(__always)
    func videoHolds(_ idx: Int) -> Bool {
        inRegion[idx] && !handoffDue[idx]
    }

    /// A tile that qualified but won't ship this tick (governor budget, batch
    /// cap) re-volunteers next tick without needing a dirty rect.
    @inline(__always)
    private func deferQualifiedTile(_ idx: Int) {
        ledger.deferTile(idx)
    }

    func sendControl(_ message: ControlMessage) {
        // An oversize message would kill the control stream: not sent.
        guard let bytes = message.encodedForSend() else { return }
        transport.sendControl(Data(bytes))
    }

    // MARK: - Test hooks

    public func ackedHash(forTile idx: Int) -> UInt64 {
        ledger[idx].ackedHash
    }

    public func inflight(forTile idx: Int) -> (hash: UInt64, seq: UInt32) {
        (ledger[idx].inflightHash, ledger[idx].inflightSeq)
    }

    /// Arena identity — INV-7 smoke check (full allocation validation is a
    /// bench/Instruments job).
    public var debugArenaBase: UInt {
        packer.arenaAddress
    }

    /// Forensics: hash of the host's ACKed-shadow pixels for a tile.
    public func debugShadowHash(forTile idx: Int) -> UInt64 {
        let (x, y, tw, th) = grid.rect(of: idx)
        return XXH64.hashRows(frame: UnsafeRawBufferPointer(shadow),
                              bytesPerRow: grid.width * 4, x: x, y: y, tw: tw, th: th)
    }
}
