import Foundation

/// Bitrate targeting for the hybrid AV1 encoder (`HybridRegionEncoder`): each picture's qindex,
/// chosen before its analysis begins (the analysis's λ follows it), from a model of what the
/// picture will cost and a leaky bucket of the bits sent against the aimed rate.
///
/// **The model.** A picture's bits ≈ a header + its coded 64×64s × the bits a coded 64×64 costs at
/// that qindex, exp(a − slope × (qindex − 80)). The copy finder's skip map gives the coded 64×64s
/// before the analysis begins, and a picture's cost spans 100× between copy-heavy and all-new, so
/// this is most of the prediction; `a` is learned online from the frames written (an EMA in the
/// log domain, weighted by how many 64×64s a frame coded), one for inter frames and one for key
/// frames; the slope is fixed (measured, `defaultSlope`).
///
/// **Bits in flight.** A picture's qindex is fixed one to two pictures before the sizes of the
/// pictures before it are known. Each decision charges the bucket its prediction at once, and the
/// frame's real size corrects it when it's written (`wrote`), so the next decision always sees
/// every picture decided, written or not.
///
/// **The bucket.** `debtBits` is what was sent above the aimed rate, drained at the rate over the
/// pictures' own capture times (frames skipped upstream don't shrink the next one's share). A
/// picture aims at its time's share plus a correction that brings the debt to `targetDebtUS`
/// of the rate over `recoveryUS`; capped at `bufferUS` (libaom's one-second buffer).
///
/// **The encoder's offsets.** The controller chooses the base qindex, which the encoder adjusts:
/// key frames `keyQindexDelta` finer, fast mostly-new pictures `fastQindexDelta` coarser. Fast
/// pictures cost what a normal one does at the base (that's how the offset was chosen), so the
/// inter model predicts both at the base; the key model predicts at the key frame's own qindex.
/// The ceiling bounds the final qindex: a fast picture's base stays `fastQindexDelta` under it.
///
/// **Key frames.** A key frame may spend `keyBudgetUS` of the rate, and the bucket is charged no
/// more than its time's share: its burst is paid back by the frames the send gate skips
/// (`VideoRateController`), not by the next pictures' quality. The budget is large (2.5 s of the
/// aim) because the inter frames copy the key frame's 64×64s and never re-code them: a key frame
/// at the ceiling stays the stream's quality wherever the screen is still (a quarter second of
/// the aim bought a 5K text key frame only qindex 168, and the replay's typing and dragging came
/// out 5–8 dB under libaom at a fraction of its bytes; at 2.5 s, qindex 76–99 and within 1 dB of
/// it at a quarter of the bytes; the burst moves a 2 Mbit/s link's glass-to-glass p50 from 88 to
/// 626 ms on typing's first frames). With a link cap (a session always has one: the startup cap
/// at first) the key frame also spends no more than `keyLinkUS` (1 s) of the link. The key model
/// can't tell a photo's key frame (2.6× the seed's bits) from text's, so the bound trades: at
/// 0.5 s, 5K key frames came out at the ceiling under the startup cap and copy-heavy streams 4–9 dB
/// under libaom, but a 2 Mbit/s link kept moving (photos 91–110 frames of 300, scrolling images
/// 210); at 1 s, key frames at qindex 76–99 and those streams within 1 dB of libaom at a quarter of
/// its bytes, and on 2 Mbit/s photos and scrolling images stall behind the first key frame (7
/// frames, as libaom's 7 and 4). AV1 runs on a link with room (`LinkRoomPolicy`, 6 Mbit/s), where
/// 1 s is the better side (photos at 6 Mbit/s: 146 frames, libaom 120, HEVC 21).
///
/// A deterministic value type; `HybridRegionEncoder` holds it under a lock (decisions on the
/// encoder's begin queue, sizes from its writer).
public struct HybridRateController: Sendable {
    public static let referenceQindex = 80

    /// Bits ≈ overhead + coded × exp(logBitsPerSuperblock − slope × (qindex − referenceQindex)).
    public struct Model: Sendable, Equatable {
        public var logBitsPerSuperblock: Double
        public var slope: Double
        public var overheadBits: Double

        public init(logBitsPerSuperblock: Double, slope: Double, overheadBits: Double) {
            (self.logBitsPerSuperblock, self.slope, self.overheadBits) = (logBitsPerSuperblock, slope, overheadBits)
        }

        public func bits(coded: Int, qindex: Int) -> Double {
            overheadBits + Double(coded) * exp(logBitsPerSuperblock - slope * Double(qindex - HybridRateController.referenceQindex))
        }

        /// The (fractional) qindex at which `coded` 64×64s cost `bits`; +∞ when the header alone is over.
        public func qindex(forBits bits: Double, coded: Int) -> Double {
            guard coded > 0 else { return -.infinity }
            let each = (bits - overheadBits) / Double(coded)
            guard each > 0 else { return .infinity }
            return Double(HybridRateController.referenceQindex) + (logBitsPerSuperblock - log(each)) / slope
        }

        /// A frame's real size, at weight 0…1.
        mutating func learn(bits: Double, coded: Int, qindex: Int, weight: Double) {
            guard coded > 0, weight > 0 else { return }
            let each = max(8, bits - overheadBits) / Double(coded)
            let seen = log(each) + slope * Double(qindex - HybridRateController.referenceQindex)
            logBitsPerSuperblock += min(1, weight) * (seen - logBitsPerSuperblock)
        }
    }

    /// Bits per coded 64×64 fall by e^-slope per qindex step. Measured at 5K, q 14/20/28/36 (qindex
    /// 56–144), 30 frames each of scrolling, dragging, video and scrolling images: inter frames
    /// 0.006 (scrolling), 0.008 (dragging), 0.012 (video, scrolling images); key frames 0.009
    /// (text) to 0.012 (video, images). Flat: the whole range moves a picture's bytes 2–3×, so the
    /// coded 64×64s are most of the prediction, and a picture far over its share is held at the
    /// ceiling and paid by the send gate.
    public static let defaultSlope = 0.010
    /// Inter frames' and key frames' bits per coded 64×64 at qindex 80 (the same runs: inter frames
    /// 245 on video, 470 scrolling, 500 scrolling images, 970 dragging; key frames 330 on video,
    /// 950 on text, 2,600 on images), and a frame's header (a frame that copies everything: 440).
    public static let defaultInter = Model(logBitsPerSuperblock: log(500), slope: defaultSlope, overheadBits: 440)
    public static let defaultKey = Model(logBitsPerSuperblock: log(1000), slope: defaultSlope, overheadBits: 440)

    /// What it aims at, bits a second.
    public var bitsPerSecond: Int
    /// The final qindex's range (a fast picture's included).
    public var minQindex = 40
    public var maxQindex = 168
    /// The encoder's offsets (`AV1HybridEncoder.keyFrameQindexDelta`, `newPictureEffort`'s).
    public var keyQindexDelta = -16
    public var fastQindexDelta = 7
    /// The bucket: its size, the debt it aims at, and the time it takes to get there.
    public var bufferUS: UInt64 = 1_000_000
    public var targetDebtUS: UInt64 = 50_000
    public var recoveryUS: UInt64 = 500_000
    /// What a key frame may spend.
    public var keyBudgetUS: UInt64 = 2_500_000
    /// An inter frame keeps the last one's qindex when the new one is this close (the analysis
    /// keeps its buffers only for one qindex at a time).
    public var hysteresis = 4
    /// The link's measured rate (the encoder's bitrate cap), when there is one: a key frame spends
    /// no more than `keyLinkUS` of it, so that its burst doesn't fill a thin link's buffer.
    public var linkBitsPerSecond: Int?
    public var keyLinkUS: UInt64 = 1_000_000

    public private(set) var inter: Model
    public private(set) var key: Model
    /// Bits sent above the aimed rate, every picture decided counted (its prediction until it's written).
    public private(set) var debtBits = 0.0

    /// A picture decided and not yet written.
    public struct Decision: Sendable, Equatable {
        public var key: Bool, fast: Bool
        public var coded: Int
        /// The qindex the controller chose (the encoder's base) and the frame's own.
        public var qindex: Int, finalQindex: Int
        public var predictedBits: Double
        /// What the bucket was charged.
        public var chargedBits: Double
        /// Its time's share of the rate.
        public var shareBits: Double
    }
    public private(set) var inFlight: [Decision] = []
    private var lastTimeUS: UInt64?
    private var intervalUS: Double?
    private var lastInterQindex: Int?

    public init(bitsPerSecond: Int, inter: Model = defaultInter, key: Model = defaultKey) {
        self.bitsPerSecond = bitsPerSecond
        self.inter = inter
        self.key = key
    }

    /// The base qindex for the next picture: a key frame, or an inter frame coding `coded` 64×64s
    /// (`fast`: it takes the encoder's fast offset), captured at `timeUS`.
    public mutating func decide(key isKey: Bool, coded: Int, fast: Bool, timeUS: UInt64) -> Int {
        let rate = Double(max(1, bitsPerSecond))
        let dtUS = lastTimeUS.map { timeUS > $0 ? min(1_000_000, max(1_000, timeUS - $0)) : 1_000 } ?? 16_667
        lastTimeUS = max(lastTimeUS ?? 0, timeUS)
        debtBits = max(0, debtBits - rate * Double(dtUS) / 1e6)
        // the bucket drains by each picture's own interval; its share of the rate follows their
        // mean (an EMA): 24 frames a second in a 60 Hz capture alternate 33 and 50 ms, and on the
        // flat rate curve that 1.5x would swing an inter frame's qindex by 40 from one to the next
        intervalUS = intervalUS.map { $0 + 0.3 * (Double(dtUS) - $0) } ?? Double(dtUS)
        let share = rate * (intervalUS ?? Double(dtUS)) / 1e6
        let decision: Decision
        if isKey {
            var budget = rate * Double(keyBudgetUS) / 1e6
            if let link = linkBitsPerSecond { budget = min(budget, Double(link) * Double(keyLinkUS) / 1e6) }
            let target = max(share, budget - max(0, debtBits - rate * Double(targetDebtUS) / 1e6))
            let q = clamp(key.qindex(forBits: target, coded: coded), minQindex, maxQindex)
            let predicted = key.bits(coded: coded, qindex: q)
            decision = Decision(key: true, fast: false, coded: coded, qindex: min(255, q - keyQindexDelta), finalQindex: q,
                                predictedBits: predicted, chargedBits: min(predicted, share), shareBits: share)
            lastInterQindex = nil
        } else {
            let correction = (rate * Double(targetDebtUS) / 1e6 - debtBits) * min(1, Double(dtUS) / Double(recoveryUS))
            let target = max(share * 0.05, share + correction)
            let ceiling = maxQindex - (fast ? fastQindexDelta : 0)
            var q = coded == 0 ? clamp(Double(lastInterQindex ?? Self.referenceQindex), minQindex, ceiling)
                : clamp(inter.qindex(forBits: target, coded: coded), minQindex, ceiling)
            if let last = lastInterQindex, abs(q - last) < hysteresis, last <= ceiling { q = last }
            lastInterQindex = q
            let predicted = inter.bits(coded: coded, qindex: q)
            decision = Decision(key: false, fast: fast, coded: coded, qindex: q,
                                finalQindex: fast ? min(255, q + fastQindexDelta) : q,
                                predictedBits: predicted, chargedBits: predicted, shareBits: share)
        }
        debtBits = min(rate * Double(bufferUS) / 1e6, debtBits + decision.chargedBits)
        inFlight.append(decision)
        return decision.qindex
    }

    /// The oldest decided picture's frame was written: `bytes` long.
    public mutating func wrote(bytes: Int) {
        guard !inFlight.isEmpty else { return }
        let d = inFlight.removeFirst()
        let bits = Double(bytes) * 8
        let charged = d.key ? min(bits, d.shareBits) : bits
        debtBits = min(Double(max(1, bitsPerSecond)) * Double(bufferUS) / 1e6, max(0, debtBits + charged - d.chargedBits))
        if d.key {
            key.learn(bits: bits, coded: d.coded, qindex: d.finalQindex, weight: 0.5)
        } else if d.coded == 0 {
            inter.overheadBits += 0.2 * (bits - inter.overheadBits)
        } else {
            inter.learn(bits: bits, coded: d.coded, qindex: d.qindex, weight: 0.35 * min(1, Double(d.coded) / 32))
        }
    }

    /// The oldest decided picture has no frame: its charge comes back.
    public mutating func failed() {
        guard !inFlight.isEmpty else { return }
        let d = inFlight.removeFirst()
        debtBits = max(0, debtBits - d.chargedBits)
    }

    /// A new stream: nothing in flight (its pictures were written or failed); the models stay.
    public mutating func restart() {
        inFlight = []
        lastInterQindex = nil
    }

    /// A fractional qindex (±∞ where nothing or everything fits) rounded up into lo…hi.
    private func clamp(_ v: Double, _ lo: Int, _ hi: Int) -> Int {
        let top = max(lo, hi)
        guard v.isFinite else { return v > 0 ? top : lo }
        return Int(min(Double(top), max(Double(lo), v.rounded(.up))))
    }
}
