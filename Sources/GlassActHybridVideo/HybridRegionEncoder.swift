public import Foundation
public import GlassActCore
import AV1Core
public import GlassActAV1
import GlassActWire
import Metal
import QuartzCore

/// Video regions (§4.6): AV1 from the Metal/CPU hybrid encoder (`AV1HybridEncoder`, research),
/// behind the contract `AOMRegionEncoder` keeps, for a Host to put in libaom's place. Not wired
/// into the Host yet: the bench's `replay --video hybrid` drives it.
///
/// - **Aim**: where libaom aims, so the two compare at equal targets: `targetPercent` (40 %) of the
///   same base bitrate (`AOMRegionEncoder.baseBitrate`), quality ladder and link cap
///   (`AOMRegionEncoder.target`), `smoothTargetPercent` (60 %) under smooth motion; the frame-QP
///   ceiling mapped to libaom's quantizer scale and on to qindex (34 → 42 → 168), the smooth
///   ceiling quantizer 60 (qindex 240). `HybridRateController` turns that into each picture's
///   qindex, budgeting by the pictures' capture times.
/// - **Pipeline**: BGRA → I420 on the caller's queue (`I420Converter`, full range BT.709: what the
///   Viewer's decoder makes of the encoder's sequence header), then
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
///   before the next one's starts; only the region that started last may submit.
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
    /// Bench: each frame as it's written (the encoder's thread): its size, qindex, whether it's a
    /// key frame, and its submit-to-frame time in seconds.
    public var onWritten: (@Sendable (_ bytes: Int, _ qindex: Int, _ key: Bool, _ seconds: Double) -> Void)?

    private let callbackQueue: DispatchQueue
    /// Full range, BT.709 matrix: how VideoToolbox's AV1 decoder (the Viewer's) shows the encoder's
    /// streams. Their sequence header says BT.601, full range, sRGB transfer, BT.709 primaries; the
    /// decoder takes the range and, measured, a BT.709 matrix: text at qindex 8 comes back at
    /// 50.8 dB luma PSNR against the capture this way, 38.6 converted BT.601 full, 31.4 as libaom
    /// converts (BT.709 video range); photos 55.8 against 44.6 (replay, `--hybrid-colour`).
    private let converter: I420Converter?
    // the caller's queue
    private var width = 0
    private var height = 0
    private var onFrame: (([UInt8], Bool, [UInt8]?) -> Void)?
    private var shared: Shared?
    /// This region's stream on the shared encoder (`Shared.owner`).
    private var token = 0
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
    public init(callbackQueue: DispatchQueue, colour: I420Converter.Colour = .bt709Full) {
        self.callbackQueue = callbackQueue
        converter = I420Converter(colour)
    }

    public func start(width: Int, height: Int,
                      onFrame: @escaping ([UInt8], Bool, [UInt8]?) -> Void) -> Bool {
        guard Self.isAvailable, converter != nil, width > 0, height > 0, width & 1 == 0, height & 1 == 0,
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
        guard let shared, let converter, onFrame != nil else { return }
        let (w, h) = (width, height)
        let cw = w / 2, ch = h / 2
        // (every sample is the conversion's)
        var y = [UInt8](unsafeUninitializedCapacity: w * h) { _, n in n = w * h }
        var u = [UInt8](unsafeUninitializedCapacity: cw * ch) { _, n in n = cw * ch }
        var v = [UInt8](unsafeUninitializedCapacity: cw * ch) { _, n in n = cw * ch }
        let ok = y.withUnsafeMutableBytes { yp in
            u.withUnsafeMutableBytes { up in
                v.withUnsafeMutableBytes { vp in
                    converter.convert(bgra: bgra, width: w, height: h, y: yp.baseAddress!, u: up.baseAddress!, v: vp.baseAddress!)
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
        let picture = AV1HybridEncoder.Picture(y: y, u: u, v: v, width: w, height: h)
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
        let token = token, configure = configure
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
            e.startStream { [weak self] _, result in self?.written(result, token: token) }
            shared.streaming = true
        }
    }

    /// A frame (or a failure) from the encoder's thread: the controller learns its size, and it
    /// goes to the caller's queue.
    private func written(_ result: Result<AV1HybridEncoder.Frame, any Error>, token: Int) {
        let now = CACurrentMediaTime()
        switch result {
        case let .success(frame):
            let key = frame.params.frame_type != UInt8(AV1G_FRAME_INTER)
            let (config, seconds): ([UInt8]?, Double) = rateLock.withLock {
                if fixedQindex == nil { rate.wrote(bytes: frame.obu.count) }
                let t0 = submitted.isEmpty ? now : submitted.removeFirst()
                // the av1C record with the region's first frame (a key frame: its sequence header)
                guard !configSent, key else { return (nil, now - t0) }
                let config = AV1Config.sequenceHeaderOBU(inTemporalUnit: frame.obu).flatMap { AV1Config.build(sequenceHeaderOBU: $0) }
                configSent = config != nil
                return (config, now - t0)
            }
            onWritten?(frame.obu.count, frame.timing.qindex, key, seconds)
            let obu = frame.obu
            callbackQueue.async { [weak self] in self?.deliver(obu, sync: key, config: config, token: token) }
        case .failure:
            rateLock.withLock {
                if fixedQindex == nil { rate.failed() }
                if !submitted.isEmpty { submitted.removeFirst() }
            }
            callbackQueue.async { [weak self] in
                guard let self, token == self.token else { return }
                self.restartNext = true
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
            guard let device = MTLCreateSystemDefaultDevice(), let e = try? AV1HybridEncoder(device: device) else { return nil }
            return Shared(encoder: e)
        }()

        let encoder: AV1HybridEncoder
        let control = DispatchQueue(label: "glassact.hybrid.control", qos: .userInteractive)
        /// The control queue's: whether a stream is under way, and whose.
        var streaming = false
        private(set) var owner = 0
        private var tokens = 0
        private let lock = NSLock()

        init(encoder: AV1HybridEncoder) {
            self.encoder = encoder
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
