import Foundation
import GlassActHybridVideo
import Testing

/// The hybrid's rate controller against synthetic encoders: a picture's true cost is
/// header + coded 64×64s × exp(a − slope × (qindex − 80)) at the frame's own qindex (a fast
/// picture costs what a normal one does at the base, as the encoder's offset was chosen).
struct HybridRateControllerTests {
    struct Encoder {
        var a = log(500.0), slope = 0.010, header = 440.0, keyFactor = 2.0, fastDelta = 7
        func bits(key: Bool, fast: Bool, coded: Int, finalQindex: Int) -> Double {
            let q = fast ? finalQindex - fastDelta : finalQindex
            return header + Double(coded) * exp(a + (key ? log(keyFactor) : 0) - slope * Double(q - 80))
        }
    }

    struct Picture {
        var key = false
        var fast = false
        var coded: Int
        var timeUS: UInt64
    }

    /// Runs pictures through the controller with sizes arriving `lag` decisions late; returns each
    /// picture's base and final qindex and its bits.
    static func run(_ c: inout HybridRateController, _ e: Encoder, _ pictures: [Picture], lag: Int)
        -> [(qindex: Int, finalQindex: Int, bits: Double)] {
        var out: [(Int, Int, Double)] = []
        var waiting: [Double] = []
        for p in pictures {
            let q = c.decide(key: p.key, coded: p.coded, fast: p.fast, timeUS: p.timeUS)
            let final = p.key ? q + c.keyQindexDelta : p.fast ? q + c.fastQindexDelta : q
            let bits = e.bits(key: p.key, fast: p.fast, coded: p.coded, finalQindex: final)
            out.append((q, final, bits))
            waiting.append(bits)
            while waiting.count > lag { c.wrote(bytes: Int(waiting.removeFirst() / 8)) }
        }
        while !waiting.isEmpty { c.wrote(bytes: Int(waiting.removeFirst() / 8)) }
        return out
    }

    static func stream(_ n: Int, coded: Int, everyUS: UInt64 = 16_667, from t0: UInt64 = 1_000_000, key: Bool = true) -> [Picture] {
        (0..<n).map { Picture(key: key && $0 == 0, coded: coded, timeUS: t0 + UInt64($0) * everyUS) }
    }

    static func rate(_ frames: ArraySlice<(qindex: Int, finalQindex: Int, bits: Double)>, everyUS: UInt64) -> Double {
        frames.map(\.bits).reduce(0, +) / (Double(frames.count) * Double(everyUS) / 1e6)
    }

    /// Steady content at a rate the qindex range can meet: the rate settles within 10 % of the aim
    /// whether sizes come back at once or one or two pictures late (bits in flight), and the
    /// qindex holds still.
    @Test(arguments: [0, 1, 2])
    func settlesOnTheAimWithSizesInFlight(lag: Int) {
        let e = Encoder(a: log(300))
        // 600 coded 64×64s a picture at 60 a second: qindex 80 costs ~10.8 Mbit/s
        for aim in [6_000_000, 12_000_000] {
            var c = HybridRateController(bitsPerSecond: aim)
            c.maxQindex = 255
            c.minQindex = 1
            let frames = Self.run(&c, e, Self.stream(300, coded: 600), lag: lag)
            let tail = frames.suffix(120)
            let achieved = Self.rate(tail, everyUS: 16_667)
            #expect(abs(achieved / Double(aim) - 1) < 0.10, "lag \(lag), aim \(aim): \(achieved)")
            let qs = Set(tail.map(\.qindex))
            #expect(qs.count <= 3, "lag \(lag): the qindex wanders: \(qs.sorted())")
            #expect(c.inFlight.isEmpty)
        }
    }

    /// The encoder's real cost 4× or ¼ of the model's seed: learned within a second (aims each
    /// would meet near qindex 125).
    @Test(arguments: [(log(2000.0), 30_000_000), (log(125.0), 2_000_000)])
    func learnsWhatTheContentCosts(a: Double, aim: Int) {
        let e = Encoder(a: a)
        var c = HybridRateController(bitsPerSecond: aim)
        c.maxQindex = 255
        c.minQindex = 1
        let frames = Self.run(&c, e, Self.stream(240, coded: 400), lag: 1)
        let achieved = Self.rate(frames.suffix(120), everyUS: 16_667)
        #expect(abs(achieved / Double(aim) - 1) < 0.12, "a \(a): \(achieved)")
    }

    /// The coded 64×64s are known before the qindex is: a switch from copies to an all-new picture
    /// is priced as one at once, not 100× over its share.
    @Test func pricesAnAllNewPictureBeforeItsAnalysis() {
        let e = Encoder(a: log(300))
        var c = HybridRateController(bitsPerSecond: 12_000_000)
        c.minQindex = 1
        c.maxQindex = 255
        var pictures = Self.stream(120, coded: 20)
        for i in 120..<180 { pictures.append(Picture(coded: 1200, timeUS: 1_000_000 + UInt64(i) * 16_667)) }
        let frames = Self.run(&c, e, pictures, lag: 2)
        let share = 12e6 / 60
        let first = frames[120]
        #expect(first.bits < 2 * share, "the first all-new picture: \(first.bits / share)× its share")
        #expect(first.finalQindex > frames[119].finalQindex + 30, "qindex \(frames[119].finalQindex) → \(first.finalQindex)")
        #expect(abs(Self.rate(frames.suffix(40), everyUS: 16_667) / 12e6 - 1) < 0.10)
    }

    /// Budget by time: pictures arriving every 50 ms (frames skipped upstream) each get 50 ms of
    /// the rate, not a frame's.
    @Test func budgetsByTimeNotByFrame() {
        let e = Encoder()
        var c = HybridRateController(bitsPerSecond: 6_000_000)
        c.minQindex = 1
        c.maxQindex = 255
        let frames = Self.run(&c, e, Self.stream(120, coded: 800, everyUS: 50_000), lag: 1)
        let achieved = Self.rate(frames.suffix(60), everyUS: 50_000)
        #expect(abs(achieved / 6e6 - 1) < 0.10, "\(achieved)")
    }

    /// Film in a 60 Hz capture: pictures 33 and 50 ms apart in turn. The rate holds and the qindex
    /// doesn't swing from one picture to the next with the interval.
    @Test func filmCadenceDoesNotSwingTheQindex() {
        let e = Encoder(a: log(300))
        var c = HybridRateController(bitsPerSecond: 20_000_000)
        c.minQindex = 1
        c.maxQindex = 255
        var t: UInt64 = 1_000_000
        let pictures = (0..<240).map { i -> Picture in
            t += i % 2 == 0 ? 33_333 : 50_000
            return Picture(coded: 3600, timeUS: t)
        }
        let frames = Self.run(&c, e, pictures, lag: 1)
        let tail = frames.suffix(100)
        let qs = tail.map(\.qindex)
        #expect(qs.max()! - qs.min()! <= 12, "qindex \(qs.min()!)…\(qs.max()!)")
        let achieved = tail.map(\.bits).reduce(0, +) / (Double(pictures.last!.timeUS - pictures[139].timeUS) / 1e6)
        #expect(abs(achieved / 20e6 - 1) < 0.10, "\(achieved)")
    }

    /// The ceiling bounds the final qindex, a fast picture's (+7) included; the floor holds.
    @Test func theCeilingBoundsTheFinalQindex() {
        let e = Encoder(a: log(5000))
        var c = HybridRateController(bitsPerSecond: 500_000)
        c.maxQindex = 168
        var pictures = Self.stream(60, coded: 3600)
        for i in pictures.indices where i % 2 == 1 { pictures[i].fast = true }
        for f in Self.run(&c, e, pictures, lag: 1) { #expect(f.finalQindex <= 168) }
        var d = HybridRateController(bitsPerSecond: 50_000_000)
        d.minQindex = 40
        for f in Self.run(&d, e, Self.stream(60, coded: 4, key: false), lag: 0) { #expect(f.finalQindex >= 40) }
    }

    /// A key frame at 2 Mbit/s spends at most its budget and isn't
    /// charged past its time's share: the send gate pays for its burst, and the inter frames after
    /// it are back at their steady qindex within a few pictures.
    @Test(arguments: [0, 2])
    func aKeyFrameDoesNotStarveThePicturesAfterIt(lag: Int) {
        let e = Encoder(a: log(300), keyFactor: 3)
        var c = HybridRateController(bitsPerSecond: 2_000_000)
        c.minQindex = 1
        c.maxQindex = 255
        var pictures = Self.stream(200, coded: 200, key: false)
        pictures[100].key = true
        pictures[100].coded = 3600
        let frames = Self.run(&c, e, pictures, lag: lag)
        let steady = frames[90].qindex
        #expect(frames[100].bits <= 2e6 * Double(c.keyBudgetUS) / 1e6 * 1.5, "the key frame: \(frames[100].bits) bits")
        let back = (101..<200).first { abs(frames[$0].qindex - steady) <= 4 } ?? 200
        #expect(back - 100 <= 3, "the inter frames took \(back - 100) pictures to come back to qindex \(steady)")
    }

    /// With a link cap, a key frame spends no more than `keyLinkUS` of the link, however large its
    /// budget at the aim: its burst mustn't fill a thin link's buffer.
    @Test func aKeyFrameFitsTheLink() {
        let e = Encoder(a: log(1000), keyFactor: 1)  // (as the key model's seed predicts)
        var c = HybridRateController(bitsPerSecond: 3_000_000)
        c.minQindex = 1
        c.maxQindex = 255
        let free = Self.run(&c, e, [Picture(key: true, coded: 3600, timeUS: 0)], lag: 0)[0]
        var d = HybridRateController(bitsPerSecond: 3_000_000)
        d.minQindex = 1
        d.maxQindex = 255
        d.linkBitsPerSecond = 2_000_000
        let linked = Self.run(&d, e, [Picture(key: true, coded: 3600, timeUS: 0)], lag: 0)[0]
        #expect(free.bits > 2e6 * Double(d.keyLinkUS) / 1e6 * 2, "the free key frame: \(free.bits) bits")
        #expect(linked.bits <= 2e6 * Double(d.keyLinkUS) / 1e6 * 1.1, "the key frame on the link: \(linked.bits) bits")
    }

    /// 4:4:4's models (`HybridRegionEncoder.chroma444`) price a coded 64×64 above 4:2:0's at every
    /// qindex, by the measured ratio, on the same slope; a 4:4:4 stream whose content costs what
    /// they seed settles on its aim, and its first all-new picture is priced near its share.
    @Test func the444ModelsPriceTheFullChroma() {
        for (m444, m420) in [(HybridRateController.defaultInter444, HybridRateController.defaultInter),
                             (HybridRateController.defaultKey444, HybridRateController.defaultKey)] {
            #expect(m444.slope == m420.slope && m444.overheadBits == m420.overheadBits)
            for q in [40, 80, 168] {
                let r = (m444.bits(coded: 1000, qindex: q) - m444.overheadBits) / (m420.bits(coded: 1000, qindex: q) - m420.overheadBits)
                #expect(r > 1.1 && r < 1.4, "qindex \(q): \(r)")
            }
        }
        let e = Encoder(a: HybridRateController.defaultInter444.logBitsPerSuperblock)
        var c = HybridRateController(bitsPerSecond: 12_000_000, inter: HybridRateController.defaultInter444,
                                     key: HybridRateController.defaultKey444)
        c.minQindex = 1
        c.maxQindex = 255
        var pictures = Self.stream(120, coded: 20)
        for i in 120..<180 { pictures.append(Picture(coded: 1200, timeUS: 1_000_000 + UInt64(i) * 16_667)) }
        let frames = Self.run(&c, e, pictures, lag: 2)
        #expect(frames[120].bits < 1.5 * 12e6 / 60, "the first all-new picture: \(frames[120].bits / (12e6 / 60))× its share")
        #expect(abs(Self.rate(frames.suffix(40), everyUS: 16_667) / 12e6 - 1) < 0.10)
    }

    /// A failed picture's charge comes back; a restart leaves nothing in flight.
    @Test func aFailureRefundsItsCharge() {
        var c = HybridRateController(bitsPerSecond: 6_000_000)
        _ = c.decide(key: true, coded: 3600, fast: false, timeUS: 0)
        _ = c.decide(key: false, coded: 100, fast: false, timeUS: 16_667)
        let before = c.debtBits
        let charged = c.inFlight[0].chargedBits
        c.failed()
        #expect(abs(c.debtBits - max(0, before - charged)) < 1e-6)
        c.restart()
        #expect(c.inFlight.isEmpty)
    }
}
