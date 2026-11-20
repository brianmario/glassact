import Foundation

/// Reduced frames for video (§4.6, BENCHMARKS "reduced frames for video"): a region whose pictures
/// keep changing almost everywhere (video) and whose content is softer than the screen it's on
/// (video scaled up to fill it) is coded at half size each way, as AV1 reduced frames: coded
/// smaller, the region's size their render size, scaled back up by the Viewer (VideoToolbox's
/// own scaling, or Glass Act's decoder's Lanczos). On the owner's 60 fps video at 5K that is
/// ~1.5 dB better at the same bytes and twice the frame rate; on a movie at its own resolution,
/// photos or maps it loses 1–6 dB, so the policy measures it:
///
/// - **A run**: from the `enterAfter + 1`th inter frame in a row coding more than half its
///   64×64s (a switch of screens is one such picture, or three at worst; video, all of them).
/// - **The margin**: how much less the half-size round trip (Lanczos down and up) loses than the
///   picture's coding does, by luma MSE in dB; at least `marginDB`. The video's is ~+9 dB, the
///   movie's +2, maps −4.
/// - **Back to full size** when the run ends: `leaveAfter` inter frames in a row that code half
///   their 64×64s or less (one is a pause or a cut; each switch is a key frame).
///
/// Each switch starts a new stream, so its first picture is a key frame (the encoder codes one
/// size a stream). The caller's queue owns this state; frames' results come in under its lock.
public struct ReducedFramesPolicy: Sendable, Equatable {
    public static let defaultEnterAfter = 3
    public static let defaultMarginDB = 5.0

    public static let defaultLeaveAfter = 2

    public var enterAfter = defaultEnterAfter
    public var marginDB = defaultMarginDB
    public var leaveAfter = defaultLeaveAfter
    /// Inter frames in a row coding half their 64×64s or less.
    public private(set) var quiet = 0

    /// Mostly-new inter frames in a row, of the current stream.
    public private(set) var run = 0
    /// The last mostly-new full-size inter frame's luma MSE (its coding loss), or nil.
    public private(set) var codingMSE: Double?
    /// The stream is reduced.
    public private(set) var reduced = false

    public init(enterAfter: Int = defaultEnterAfter, marginDB: Double = defaultMarginDB) {
        (self.enterAfter, self.marginDB) = (enterAfter, marginDB)
    }

    /// A frame of the current stream came out: a key frame (neither extends nor breaks a run), or an
    /// inter frame coding `codedShare` of its 64×64s, with its luma MSE (negative: not measured).
    public mutating func wrote(key: Bool, codedShare: Double, lumaMSE: Double) {
        guard !key else { return }
        if reduced { sawReducedInter = true }
        if codedShare > 0.5 {
            run += 1
            quiet = 0
            if !reduced, lumaMSE >= 0 { codingMSE = lumaMSE }
        } else {
            run = 0
            quiet += 1
            if !reduced { codingMSE = nil }
        }
    }

    /// Whether the next picture should have its half-size round trip measured (`margin(resampleMSE:)`).
    public var wantsMargin: Bool { !reduced && run > enterAfter && codingMSE != nil }

    /// Whether to go to half size, given the next picture's round-trip luma MSE: the round trip
    /// must lose `marginDB` less than coding did.
    public func entersReduced(resampleMSE: Double) -> Bool {
        guard wantsMargin, let coding = codingMSE, coding > 0 else { return false }
        return resampleMSE <= 0 || 10 * log10(coding / resampleMSE) >= marginDB
    }

    /// Whether a reduced stream should go back to full size: its run ended.
    public var leavesReduced: Bool { reduced && quiet >= leaveAfter && sawReducedInter }

    private var sawReducedInter = false

    /// A new stream starts, reduced or not.
    public mutating func started(reduced: Bool) {
        self.reduced = reduced
        sawReducedInter = false
        quiet = 0
        if !reduced { run = 0 }
        codingMSE = nil
    }
}
