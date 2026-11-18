public import Foundation
public import GlassActCore
import AV1Core
public import GlassActAV1
import GlassActWire
import Metal
import QuartzCore

/// Video regions (§4.6): AV1 from the Metal/CPU hybrid encoder (`AV1HybridEncoder`), behind the
/// contract `AOMRegionEncoder` keeps: the Host's AV1 (`HostVideoEncoders`), and the bench's
/// `replay --video hybrid`.
///
/// - **Aim**: where libaom aims, so the two compare at equal targets: `targetPercent` (40 %) of the
///   same base bitrate (`AOMRegionEncoder.baseBitrate`), quality ladder and link cap
///   (`AOMRegionEncoder.target`), `smoothTargetPercent` (60 %) under smooth motion; the frame-QP
///   ceiling mapped to libaom's quantizer scale and on to qindex (34 → 42 → 168), the smooth
///   ceiling quantizer 60 (qindex 240). `HybridRateController` turns that into each picture's
///   qindex, budgeting by the pictures' capture times.
/// - **Pipeline**: BGRA → I420 on the caller's queue (`I420Converter`, full range BT.709: what the
///   Viewer's decoder makes of the encoder's sequence header), or with `chroma444` → planar 4:4:4
///   (`YCbCr444Converter`, full range BT.709, as the High-profile stream's header signals), then
///   the picture is pushed into the encoder's stream (`AV1HybridEncoder.submit`), which returns at
///   once: its copies, analysis, closed loop, filters and write run on the encoder's own queues and
///   threads, and the frame comes back on `callbackQueue` as soon as its bitstream exists. A
///   picture with no successor comes out without waiting for one; one submitted while the last
///   is being finished is analyzed beside it.
/// - **Contract**: one delivery per `encode` (empty when it failed; after a failure the next
///   picture starts a new stream with a key frame); `forceSync` and a region's first picture are
///   key frames; the config (`av1C`) goes with the first frame, built from its sequence header
///   (every key frame of a region carries the same one). Any even size, and sizes that change
///   between starts.
/// - **One encoder for the process** (`Shared`): the hybrid's kernels compile once, and regions
///   form and dissolve often. Its calls run on one serial queue, so a region's stream ends there
///   before the next one's starts; only the region that started last may submit. The first
///   `start` compiles them, on the caller's queue, unless `prepare()` already has on its own:
///   the Host prepares at launch and offers the encoder only once `isReady`, so a region never
///   waits on the compile.
///
/// Concurrency (`@unchecked Sendable`): the region's state belongs to the caller's queue (the
/// engine's); the rate controller is shared with the encoder's begin queue and writer threads
/// under `rateLock`; the encoder is confined to `Shared.control`.
///
/// ## Deviations
/// - Each picture's planes are new arrays: `AV1HybridEncoder.Picture` holds them by value, and the
///   encoder keeps past pictures (the copy finder's, the long-term references') for as long as it
///   needs them; the encoder itself allocates per picture too (its Deviations).
@available(macOS 27, iOS 27, *)
public final class HybridRegionEncoder: VideoRegionEncoder, @unchecked Sendable {
    /// An Apple-silicon GPU that runs the encoder's kernels.
    public static var isAvailable: Bool { AV1ShaderSource.hasCapableGPU }

    /// Compiles the encoder's kernels (makes the process's encoder) on a queue of its own, once;
    /// `isReady` says when it's done, and `done` (on that queue) how it went: false where the
    /// encoder isn't available or its kernels didn't compile.
    public static func prepare(done: (@Sendable (_ ready: Bool) -> Void)? = nil) {
        guard isAvailable else {
            done?(false)
            return
        }
        guard Shared.preparation.begin(done) else { return }
        DispatchQueue.global(qos: .utility).async {
            Shared.preparation.end(ready: Shared.instance != nil)
        }
    }

    /// The process's encoder exists: its kernels compiled (`prepare()`, or a region's `start`).
    public static var isReady: Bool { Shared.preparation.isReady }
    public var codecID: UInt8 { VideoCodec.av1 }

    /// Experiments (the bench), as `AOMRegionEncoder`'s: the share of the target and the link cap
    /// aimed at, and under smooth motion, its aim and quantizer ceiling (libaom's scale).
    public var targetPercent = 40
    public var smoothTargetPercent = 60
    public var smoothQuantizerCeiling = 60
    /// Experiment: libaom's quantizer ceiling (0–63) instead of the frame-QP mapping; nil = the mapping.
    public var quantizerCeiling: Int?
    /// Experiments: the controller's key frame budget and qindex floor (nil: its defaults).
    public var keyBudgetUS: UInt64?
    public var keyLinkUS: UInt64?
    public var minQindex: Int?
    /// Bench: every picture at this qindex (key frames `keyFrameQindexDelta` finer, fast ones
    /// coarser, as `av1seq` codes them), no rate control.
    public var fixedQindex: Int?
    /// Bench: the encoder's settings for each stream, before it starts (on the encoder's queue).
    public var configure: (@Sendable (AV1HybridEncoder) -> Void)?
    /// Bench: each frame as it's written (the encoder's thread), whether it's a key frame, and its
    /// submit-to-frame time in seconds.
    public var onWritten: (@Sendable (_ frame: AV1HybridEncoder.Frame, _ key: Bool, _ seconds: Double) -> Void)?

    private let callbackQueue: DispatchQueue
    /// Full range, BT.709 matrix: how VideoToolbox's AV1 decoder (the Viewer's) shows the encoder's
    /// streams. Their sequence header says BT.601, full range, sRGB transfer, BT.709 primaries; the
    /// decoder takes the range and, measured, a BT.709 matrix: text at qindex 8 comes back at
    /// 50.8 dB luma PSNR against the capture this way, 38.6 converted BT.601 full, 31.4 as libaom
    /// converts (BT.709 video range); photos 55.8 against 44.6 (replay, `--hybrid-colour`).
    private let converter: I420Converter?
    /// A 4:4:4 stream (AV1's High profile, the hybrid's 4:4:4 inter frames): pictures converted
    /// with the full chroma (`YCbCr444Converter`), an av1C saying so (`AV1Config.build444`), and
    /// the rate controller's 4:4:4 models. Our decoder (`OwnAV1RegionDecoder`) shows it;
    /// VideoToolbox can't. No Viewer is offered it yet: the bench's (`replay --chroma 444`).
    public let chroma444: Bool
    private let converter444: YCbCr444Converter?
    // the caller's queue
    private var width = 0
    private var height = 0
    private var onFrame: (([UInt8], Bool, [UInt8]?) -> Void)?
    private var shared: Shared?
    /// This region's stream on the shared encoder (`Shared.owner`).
    private var token = 0
    /// This region's streams, counted: a failure restarts the stream only if it came from the
    /// current one (a picture submitted before the restart fails in the old one too).
    private var epoch = 0
    private var restartNext = false
    private var baseBitrate = 20_000_000
    private var qualityLevel = 0
    private var bitrateCap: Int?
    private var maxFrameQP = VTHEVCRegionEncoder.defaultMaxFrameQP
    private var smoothMotion = false
    // `rateLock`: the controller, and the frames' submit times
    private let rateLock = NSLock()
    private var rate = HybridRateController(bitsPerSecond: 8_000_000)
    private var submitted: [Double] = []
    private var configSent = false

    /// `callbackQueue` must be the host engine's confining queue (the VideoRegionEncoder threading
    /// contract).
    public init(callbackQueue: DispatchQueue, colour: I420Converter.Colour = .bt709Full, chroma444: Bool = false) {
        self.callbackQueue = callbackQueue
        self.chroma444 = chroma444
        converter = chroma444 ? nil : I420Converter(colour)
        converter444 = chroma444 ? YCbCr444Converter() : nil
        if chroma444 { rate = HybridRateController(bitsPerSecond: 8_000_000, inter: HybridRateController.defaultInter444, key: HybridRateController.defaultKey444) }
    }

    public func start(width: Int, height: Int,
                      onFrame: @escaping ([UInt8], Bool, [UInt8]?) -> Void) -> Bool {
        guard Self.isAvailable, converter != nil || converter444 != nil, width > 0, height > 0, width & 1 == 0, height & 1 == 0,
              let shared = Shared.instance else { return false }
        self.width = width
        self.height = height
        self.onFrame = onFrame
        self.shared = shared
        baseBitrate = AOMRegionEncoder.baseBitrate(width: width, height: height)
        applyRate()
        rateLock.withLock {
            rate.restart()
            submitted = []
            configSent = false
        }
        token = shared.claim()
        restartNext = false
        startStream()
        return true
    }

    public func encode(bgra: UnsafeRawBufferPointer, forceSync: Bool, timeUS: UInt64) {
        guard let shared, converter != nil || converter444 != nil, onFrame != nil else { return }
        let (w, h) = (width, height)
        let (cw, ch) = chroma444 ? (w, h) : (w / 2, h / 2)
        // (every sample is the conversion's)
        var y = [UInt8](unsafeUninitializedCapacity: w * h) { _, n in n = w * h }
        var u = [UInt8](unsafeUninitializedCapacity: cw * ch) { _, n in n = cw * ch }
        var v = [UInt8](unsafeUninitializedCapacity: cw * ch) { _, n in n = cw * ch }
        let ok = y.withUnsafeMutableBytes { yp in
            u.withUnsafeMutableBytes { up in
                v.withUnsafeMutableBytes { vp in
                    if let converter444 {
                        converter444.convert(bgra: bgra, width: w, height: h, y: yp.baseAddress!, u: up.baseAddress!, v: vp.baseAddress!)
                    } else {
                        converter!.convert(bgra: bgra, width: w, height: h, y: yp.baseAddress!, u: up.baseAddress!, v: vp.baseAddress!)
                    }
                }
            }
        }
        guard ok else {
            deliverNothing()
            return
        }
        if restartNext {
            restartNext = false
            rateLock.withLock { rate.restart() }
            startStream()  // (a key frame: the stream's first)
        }
        let picture = AV1HybridEncoder.Picture(y: y, u: u, v: v, width: w, height: h, chroma444: chroma444)
        let token = token, fixed = fixedQindex
        let chooser = fixed != nil ? nil : rateChooser(timeUS: timeUS)
        rateLock.withLock { submitted.append(CACurrentMediaTime()) }
        let callbackQueue = callbackQueue
        shared.control.async { [weak self] in
            guard shared.owner == token else {
                // (another region started since: this one's stream is over)
                callbackQueue.async { [weak self] in self?.deliver([], sync: false, config: nil, token: token) }
                return
            }
            shared.encoder.submit(picture, qindex: fixed ?? HybridRateController.referenceQindex,
                                  forceKey: forceSync, chooser: chooser)
        }
    }

    public func setQualityLevel(_ level: Int) {
        guard level != qualityLevel else { return }
        qualityLevel = level
        applyRate()
    }

    public func setBitrateCap(_ bitsPerSecond: Int?) {
        bitrateCap = bitsPerSecond
        applyRate()
    }

    public func setMaxFrameQP(_ qp: Int?) {
        maxFrameQP = qp ?? VTHEVCRegionEncoder.defaultMaxFrameQP
        applyRate()
    }

    /// While on, the smooth ceiling and aim replace the frame-QP mapping and `targetPercent`, as
    /// libaom's do.
    public func setSmoothMotion(_ on: Bool) {
        smoothMotion = on
        applyRate()
    }

    public func stop() {
        onFrame = nil
        guard let shared else { return }
        self.shared = nil
        let token = token
        shared.control.async {
            guard shared.owner == token else { return }
            shared.encoder.endStream()
            shared.streaming = false
            shared.trimWhenIdle()
        }
    }

    // MARK: - Rate

    /// What the controller aims at: the target's share, as libaom aims.
    var aimedBitrate: Int {
        AOMRegionEncoder.target(base: baseBitrate, level: qualityLevel, cap: bitrateCap)
            * (smoothMotion ? smoothTargetPercent : targetPercent) / 100
    }

    /// The final qindex's ceiling: libaom's quantizer ceiling, on the qindex scale.
    var maxQindex: Int {
        let q = quantizerCeiling ?? (smoothMotion ? smoothQuantizerCeiling : AOMRegionEncoder.quantizer(forFrameQP: maxFrameQP))
        return q >= 63 ? 255 : 4 * max(0, q)
    }

    private func applyRate() {
        let (bits, ceiling, key, floor, cap) = (aimedBitrate, maxQindex, keyBudgetUS, minQindex, bitrateCap)
        let keyLink = keyLinkUS
        rateLock.withLock {
            rate.bitsPerSecond = bits
            rate.linkBitsPerSecond = cap
            if let keyLink { rate.keyLinkUS = keyLink }
            rate.maxQindex = ceiling
            if let key { rate.keyBudgetUS = key }
            if let floor { rate.minQindex = floor }
        }
    }

    /// The controller's decision for a picture captured at `timeUS`, asked on the encoder's begin queue.
    private func rateChooser(timeUS: UInt64) -> @Sendable (AV1HybridEncoder.PictureInfo) -> Int {
        { [weak self] (info: AV1HybridEncoder.PictureInfo) -> Int in
            guard let self else { return HybridRateController.referenceQindex }
            return self.rateLock.withLock {
                self.rate.decide(key: info.key, coded: info.coded, fast: info.fast, timeUS: timeUS)
            }
        }
    }

    /// The rate controller's state (the bench).
    public var rateState: HybridRateController { rateLock.withLock { rate } }

    // MARK: - The stream

    /// A new stream on the shared encoder for this region (after its last one, if any, ends).
    private func startStream() {
        guard let shared else { return }
        epoch += 1
        let token = token, epoch = epoch, configure = configure
        let w = width
        shared.control.async { [weak self] in
            guard shared.owner == token else { return }
            if shared.streaming { shared.encoder.endStream() }
            let e = shared.encoder
            e.interFrames = true
            e.returnsPlanes = false
            // eight tile columns, as the encoder was measured (fewer where the picture is narrower)
            let sb128 = (w + 127) / 128
            e.tiling = (min(3, sb128 <= 1 ? 0 : Int(ceil(log2(Double(sb128))))), 0)
            configure?(e)
            e.startStream { [weak self] _, result in self?.written(result, token: token, epoch: epoch) }
            shared.streaming = true
            shared.streams += 1
        }
    }

    /// A frame (or a failure) from the encoder's thread: the controller learns its size, and it
    /// goes to the caller's queue.
    private func written(_ result: Result<AV1HybridEncoder.Frame, any Error>, token: Int, epoch: Int) {
        let now = CACurrentMediaTime()
        switch result {
        case let .success(frame):
            let key = frame.params.frame_type != UInt8(AV1G_FRAME_INTER)
            let (config, seconds): ([UInt8]?, Double) = rateLock.withLock {
                if fixedQindex == nil { rate.wrote(bytes: frame.obu.count) }
                let t0 = submitted.isEmpty ? now : submitted.removeFirst()
                // the av1C record with the region's first frame (a key frame: its sequence header)
                guard !configSent, key else { return (nil, now - t0) }
                let header = AV1Config.sequenceHeaderOBU(inTemporalUnit: frame.obu)
                let config = header.flatMap { chroma444 ? AV1Config.build444(sequenceHeaderOBU: $0) : AV1Config.build(sequenceHeaderOBU: $0) }
                configSent = config != nil
                return (config, now - t0)
            }
            onWritten?(frame, key, seconds)
            let obu = frame.obu
            callbackQueue.async { [weak self] in self?.deliver(obu, sync: key, config: config, token: token) }
        case .failure:
            rateLock.withLock {
                if fixedQindex == nil { rate.failed() }
                if !submitted.isEmpty { submitted.removeFirst() }
            }
            callbackQueue.async { [weak self] in
                guard let self else { return }
                // (the stream is broken from this picture on: every later one in it fails too, and
                // the next picture submitted starts a new one, with a key frame)
                if token == self.token && epoch == self.epoch { self.restartNext = true }
                self.deliver([], sync: false, config: nil, token: token)
            }
        }
    }

    private func deliver(_ data: [UInt8], sync: Bool, config: [UInt8]?, token: Int) {
        guard token == self.token, let onFrame else { return }
        onFrame(data, sync, config)
    }

    private func deliverNothing() {
        let token = token
        callbackQueue.async { [weak self] in self?.deliver([], sync: false, config: nil, token: token) }
    }

    /// The process's hybrid encoder and the queue its calls run on.
    final class Shared: @unchecked Sendable {
        static let instance: Shared? = {
            // (every kernel, including those a picture would otherwise compile on first use)
            guard let device = MTLCreateSystemDefaultDevice(), let e = try? Shared.compiledEncoder(device: device) else {
                preparation.end(ready: false)
                return nil
            }
            preparation.end(ready: true)
            return Shared(encoder: e, device: device)
        }()

        /// How long the encoder stays as its last stream left it, with nothing streaming, before
        /// `trimWhenIdle` swaps it for a fresh one. A video region ends whenever its motion does,
        /// so this outlasts the gaps inside a session; tests shorten it.
        nonisolated(unsafe) static var idleTrimAfter: TimeInterval = 60

        static let preparation = Preparation()

        /// An encoder with every kernel compiled (`AV1HybridEncoder.compileKernels`), so no
        /// picture waits on the compiler.
        static func compiledEncoder(device: any MTLDevice) throws -> AV1HybridEncoder {
            let e = try AV1HybridEncoder(device: device)
            try e.compileKernels()
            return e
        }

        /// Whether the encoder is being made, or was, and how that went.
        final class Preparation: @unchecked Sendable {
            private let lock = NSLock()
            private var started = false
            private var outcome: Bool?
            private var waiting: [@Sendable (Bool) -> Void] = []

            /// True for the first caller: it makes the encoder. `done` hears how it went, at once
            /// if it's known.
            func begin(_ done: (@Sendable (Bool) -> Void)?) -> Bool {
                let (first, known): (Bool, Bool?) = lock.withLock {
                    if outcome == nil, let done { waiting.append(done) }
                    defer { started = true }
                    return (!started, outcome)
                }
                if let known { done?(known) }
                return first && known == nil
            }

            /// The encoder exists (`ready`), or can't.
            func end(ready: Bool) {
                let waiters: [@Sendable (Bool) -> Void] = lock.withLock {
                    started = true
                    outcome = ready
                    defer { waiting = [] }
                    return waiting
                }
                for w in waiters { w(ready) }
            }

            var isReady: Bool { lock.withLock { outcome == true } }
        }

        /// The control queue's. Replaced by a fresh one once the Host has been idle a while
        /// (`trimWhenIdle`): a stream leaves its pictures' buffers in it (the analysis cache, the
        /// source pools, the filters' planes: about a gigabyte at 5K), which a Host between
        /// sessions shouldn't keep.
        private(set) var encoder: AV1HybridEncoder
        let device: any MTLDevice
        let control = DispatchQueue(label: "glassact.hybrid.control", qos: .userInteractive)
        /// The control queue's: whether a stream is under way, and whose.
        var streaming = false
        /// The control queue's: streams started, so a trim that outlived a new one is dropped.
        var streams = 0
        /// The control queue's: encoders swapped for fresh ones (tests).
        private(set) var trims = 0
        private var trimming = false
        private(set) var owner = 0
        private var tokens = 0
        private let lock = NSLock()

        init(encoder: AV1HybridEncoder, device: any MTLDevice) {
            self.encoder = encoder
            self.device = device
        }

        /// On the control queue, as a stream ends: if no stream starts within `idleTrimAfter`, a
        /// fresh encoder (no pictures' buffers; its kernels come from Metal's cache by now) is
        /// made on another queue and takes the old one's place, unless a stream started
        /// meanwhile. The old one is released on the control queue, where nothing else holds it.
        func trimWhenIdle() {
            let started = streams
            control.asyncAfter(deadline: .now() + Self.idleTrimAfter) { [self] in
                guard !streaming, streams == started, !trimming else { return }
                trimming = true
                let device = device
                DispatchQueue.global(qos: .utility).async { [self] in
                    let fresh = try? Self.compiledEncoder(device: device)
                    control.async { [self] in
                        trimming = false
                        guard let fresh, !streaming, streams == started else { return }
                        encoder = fresh
                        trims += 1
                    }
                }
            }
        }

        /// A new region's token; it owns the encoder from its first call on the control queue.
        func claim() -> Int {
            let t = lock.withLock {
                tokens += 1
                return tokens
            }
            control.async { self.owner = t }
            return t
        }
    }
}
