public import Foundation
public import GlassActCore
import AV1Core
public import GlassActAV1
import GlassActWire
import Accelerate
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
    /// Reduced frames (`ReducedFramesPolicy`), under `rateLock`: the policy, fed by the current
    /// stream's frames.
    private var reducedPolicy = ReducedFramesPolicy()
    /// `epoch` as the frames' thread sees it, so only the current stream's frames feed the policy.
    private var streamEpoch = 0
    // the caller's queue: the Viewer shows reduced frames (`setReducedFrames`), and the current
    // stream's coded size (the region's, or half of it each way)
    private var reducedAllowed = false
    private var codedWidth = 0
    private var codedHeight = 0
    /// Reduced frames: a margin measurement under way, and pictures since the last (the caller's
    /// queue); the last one's result, until a picture takes it (`rateLock`).
    private var marginInFlight = false
    private var picturesSinceMargin = 0
    private var roundTripMSE: Double?

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
        (codedWidth, codedHeight) = (width, height)
        picturesSinceMargin = Self.marginEvery
        self.onFrame = onFrame
        self.shared = shared
        baseBitrate = AOMRegionEncoder.baseBitrate(width: width, height: height)
        applyRate()
        rateLock.withLock {
            rate.restart()
            submitted = []
            configSent = false
            reducedPolicy = ReducedFramesPolicy()
        }
        token = shared.claim()
        restartNext = false
        startStream()
        return true
    }

    public func encode(bgra: UnsafeRawBufferPointer, forceSync: Bool, timeUS: UInt64) {
        encode(bgra: bgra, forceSync: forceSync, timeUS: timeUS, changed: nil)
    }

    /// A frame dropped before the stream got it: the next frame's change map (the engine's, since
    /// the frame it passed before) isn't since the picture the stream had last, so it isn't passed.
    private var changesBroken = false

    public func encode(bgra: UnsafeRawBufferPointer, forceSync: Bool, timeUS: UInt64, changed: UnsafeBufferPointer<UInt8>?) {
        let changes = changesBroken ? nil : changed.map { Array($0) }
        changesBroken = true  // (until this frame reaches the stream)
        guard let shared, converter != nil || converter444 != nil, onFrame != nil else { return }
        let (w, h) = (width, height)
        let (cw, ch) = chroma444 ? (w, h) : (w / 2, h / 2)
        // reduced frames: a run that ended goes back to the region's size (a new stream)
        let policy = reducedAllowed && !chroma444 ? rateLock.withLock { reducedPolicy } : nil
        var reduceNow = policy != nil && codedWidth != w
        if let policy, reduceNow, policy.leavesReduced { reduceNow = false }
        // (every sample is the conversion's)
        // (`var`: a reduced stream's pictures are these scaled down)
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
        // reduced frames: a run long enough, whose content loses less to the half-size round trip
        // than to its coding, goes to half size (a new stream)
        if let policy, !reduceNow, policy.wantsMargin {
            // (measured off this queue, every `marginEvery` pictures of a run: the last one's
            // result decides)
            let measured = rateLock.withLock { () -> Double? in defer { roundTripMSE = nil }; return roundTripMSE }
            if let measured { reduceNow = policy.entersReduced(resampleMSE: measured) }
            picturesSinceMargin += 1
            if !reduceNow, !marginInFlight, picturesSinceMargin >= Self.marginEvery {
                picturesSinceMargin = 0
                marginInFlight = true
                let (w, h, luma) = (width, height, y)
                Self.marginQueue.async { [weak self] in
                    let mse = Self.halfRoundTripMSE(luma, width: w, height: h)
                    guard let self else { return }
                    self.rateLock.withLock { self.roundTripMSE = mse }
                    self.callbackQueue.async { [weak self] in self?.marginInFlight = false }
                }
            }
        } else {
            picturesSinceMargin = Self.marginEvery  // (a run's first chance measures at once)
        }
        let sizeChanges = reduceNow != (codedWidth != w)
        if sizeChanges {
            (codedWidth, codedHeight) = reduceNow ? (Self.half(w), Self.half(h)) : (w, h)
        }
        if restartNext || sizeChanges {
            restartNext = false
            let reduced = codedWidth != w
            if reduced && sizeChanges { reducedStreams += 1 }
            startStream()  // (a key frame: the stream's first)
            rateLock.withLock {
                rate.restart()
                reducedPolicy.started(reduced: reduced)
            }
        }
        if codedWidth != w {
            guard let small = Self.downscale([y, u, v], from: [(w, h), (cw, ch), (cw, ch)],
                                             to: [(codedWidth, codedHeight), (codedWidth / 2, codedHeight / 2), (codedWidth / 2, codedHeight / 2)])
            else {
                deliverNothing()
                return
            }
            (y, u, v) = (small[0], small[1], small[2])
            reducedPictures += 1
        }
        // (the engine's frames are the picture's: 64×64s of the frame are the picture's 64×64s,
        // and the conversion is per pixel, 2×2 for 4:2:0's chroma, so an unchanged one converts
        // to the same samples)
        let picture = AV1HybridEncoder.Picture(y: y, u: u, v: v, width: codedWidth, height: codedHeight, chroma444: chroma444,
                                               changed: codedWidth == w && !sizeChanges ? changes : nil)
        changesBroken = false
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

    /// The Viewer shows reduced frames (`WireCaps.videoReducedFrames`): runs of video whose
    /// content is softer than the region may be coded at half size (`ReducedFramesPolicy`).
    public func setReducedFrames(_ allowed: Bool) {
        guard allowed != reducedAllowed else { return }
        reducedAllowed = allowed
        // (the stream under way measures its frames' coding loss from now on, or stops)
        guard let shared else { return }
        let token = token, measures = allowed && !chroma444
        shared.control.async {
            guard shared.owner == token else { return }
            shared.encoder.measuresLumaError = measures
        }
    }

    /// Reduced frames: the streams this region started at half size, and the pictures submitted
    /// to them (the bench).
    public private(set) var reducedStreams = 0
    public private(set) var reducedPictures = 0

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

    /// Three frames may wait: with two the stream can't overlap enough new 5K pictures to keep up
    /// with 60 fps of changes (movie 41 → 57 frames a second shown, maps 45 → 57, p50 latency
    /// +0–4 ms; content it keeps up with never uses the third). BENCHMARKS "three frames waiting".
    public var maxPendingFrames: Int { 3 }

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
        rateLock.withLock { streamEpoch = epoch }
        let token = token, epoch = epoch, configure = configure
        let w = codedWidth
        let stream: (width: Int, height: Int)? = codedWidth != width ? (width, height) : nil
        let measures = reducedAllowed && !chroma444
        shared.control.async { [weak self] in
            guard shared.owner == token else { return }
            if shared.streaming { shared.encoder.endStream() }
            let e = shared.encoder
            e.interFrames = true
            e.returnsPlanes = false
            // eight tile columns, as the encoder was measured (fewer where the picture is narrower)
            let sb128 = (w + 127) / 128
            e.tiling = (min(3, sb128 <= 1 ? 0 : Int(ceil(log2(Double(sb128))))), 0)
            // (reduced frames: coded smaller, shown at the region's size; and each frame's coding
            // loss, which the policy weighs)
            e.streamSize = stream
            e.measuresLumaError = measures
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
                if epoch == self.streamEpoch {
                    let t = frame.timing
                    reducedPolicy.wrote(key: key, codedShare: 1 - t.copied - t.copiedGolden, lumaMSE: t.lumaMSE)
                }
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

    // MARK: - Reduced frames

    /// Half a side, even (4:2:0's chroma is half of it again).
    static func half(_ n: Int) -> Int { max(2, (n / 2) & ~1) }

    /// Each plane scaled to its size (vImage's high-quality resampling, Lanczos); nil if vImage fails.
    static func downscale(_ planes: [[UInt8]], from: [(Int, Int)], to: [(Int, Int)]) -> [[UInt8]]? {
        var out: [[UInt8]] = []
        for k in planes.indices {
            let (fw, fh) = from[k], (tw, th) = to[k]
            var d = [UInt8](unsafeUninitializedCapacity: tw * th) { _, n in n = tw * th }
            let ok = planes[k].withUnsafeBufferPointer { src in
                d.withUnsafeMutableBufferPointer { dst in
                    var sb = vImage_Buffer(data: UnsafeMutableRawPointer(mutating: src.baseAddress!), height: vImagePixelCount(fh),
                                           width: vImagePixelCount(fw), rowBytes: fw)
                    var db = vImage_Buffer(data: dst.baseAddress!, height: vImagePixelCount(th), width: vImagePixelCount(tw), rowBytes: tw)
                    return vImageScale_Planar8(&sb, &db, nil, vImage_Flags(kvImageHighQualityResampling)) == kvImageNoError
                }
            }
            guard ok else { return nil }
            out.append(d)
        }
        return out
    }

    /// Reduced frames: a run's pictures between margin measurements (~0.5 s at 60 fps), and the
    /// queue they're measured on (off the engine's).
    static let marginEvery = 30
    static let marginQueue = DispatchQueue(label: "glassact.hybrid.reduced-margin", qos: .utility)

    /// The luma's loss to the half-size round trip (down and back up, as the stream would code and
    /// the Viewer show it), as mean squared difference: over 8 bands of 64 rows spread down the
    /// picture, each scaled with 16 rows either side so its edges don't count; nil if vImage fails.
    static func halfRoundTripMSE(_ y: [UInt8], width w: Int, height h: Int) -> Double? {
        let bandRows = 64, apron = 16, bands = 8
        guard w >= 4, h >= bandRows + 2 * apron, y.count == w * h else { return nil }
        let rows = bandRows + 2 * apron, hw = half(w)
        var small = [UInt8](repeating: 0, count: hw * rows / 2), back = [UInt8](repeating: 0, count: w * rows)
        let flags = vImage_Flags(kvImageHighQualityResampling)
        var sum: UInt64 = 0, count = 0
        for b in 0..<bands {
            let top = (h - rows) * b / max(1, bands - 1) & ~1
            let ok = y.withUnsafeBufferPointer { src in
                small.withUnsafeMutableBufferPointer { m in
                    back.withUnsafeMutableBufferPointer { o in
                        var s = vImage_Buffer(data: UnsafeMutableRawPointer(mutating: src.baseAddress! + top * w),
                                              height: vImagePixelCount(rows), width: vImagePixelCount(w), rowBytes: w)
                        var d = vImage_Buffer(data: m.baseAddress!, height: vImagePixelCount(rows / 2), width: vImagePixelCount(hw), rowBytes: hw)
                        var u = vImage_Buffer(data: o.baseAddress!, height: vImagePixelCount(rows), width: vImagePixelCount(w), rowBytes: w)
                        return vImageScale_Planar8(&s, &d, nil, flags) == kvImageNoError && vImageScale_Planar8(&d, &u, nil, flags) == kvImageNoError
                    }
                }
            }
            guard ok else { return nil }
            y.withUnsafeBufferPointer { a in
                back.withUnsafeBufferPointer { o in
                    for r in apron..<(apron + bandRows) {
                        var row: UInt32 = 0
                        let src = a.baseAddress! + (top + r) * w, got = o.baseAddress! + r * w
                        for c in 0..<w {
                            let e = Int32(src[c]) - Int32(got[c])
                            row &+= UInt32(e * e)
                        }
                        sum &+= UInt64(row)
                        count += w
                    }
                }
            }
        }
        return count == 0 ? nil : Double(sum) / Double(count)
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
