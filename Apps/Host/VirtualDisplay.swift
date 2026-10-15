import CoreGraphics
import Foundation

/// A virtual display at a viewer's exact size, so the shared picture fills a
/// screen whose shape no physical display mode matches (e.g. a 1470×918
/// MacBook Air full-screen area vs a Studio Display that only offers 16:9
/// modes, where Client Resolution leaves ~50 pt bars). The physical
/// displays mirror it while it exists, so the whole desktop lives at the
/// viewer's size.
///
/// Resizable in place (the viewer's window drives its size): new settings
/// on the same display keep its id and the mirroring — measured ~0.9 s, no
/// teardown. With a maximum larger than the mode macOS may pick the 1×
/// variant, so the 2× mode is selected explicitly (`selectMode`).
///
/// Uses CoreGraphics' CGVirtualDisplay family — SPI (present since macOS 11,
/// what Sidecar-style tools use), declared here as @objc protocols and bound
/// to the runtime classes; absent classes → `make` returns nil and the host
/// falls back to Client Resolution. Recipe measured on macOS 27: modes are
/// given in POINTS with `hiDPI = 1` and maxPixels at 2× — the display then
/// comes up in the HiDPI mode (1470×918 pt, 2940×1836 px); pixel-sized modes
/// produce no usable display.
///
/// The display lives as long as this object (and the process).
/// Main-thread confined (HostController's display state); `@unchecked
/// Sendable` only so main-actor Tasks can hold it.
final class VirtualDisplay: @unchecked Sendable {
    let displayID: CGDirectDisplayID
    private(set) var widthPoints: Int
    private(set) var heightPoints: Int
    let scale: Int
    /// Largest size (points) this display can be resized to in place.
    let maxWidthPoints: Int
    let maxHeightPoints: Int
    private let display: NSObject

    static var isAvailable: Bool {
        ["CGVirtualDisplayDescriptor", "CGVirtualDisplayMode", "CGVirtualDisplaySettings", "CGVirtualDisplay"]
            .allSatisfy { NSClassFromString($0) != nil }
    }

    private init(display: NSObject, id: CGDirectDisplayID, width: Int, height: Int, scale: Int,
                 maxWidth: Int, maxHeight: Int) {
        self.display = display
        displayID = id
        widthPoints = width
        heightPoints = height
        self.scale = scale
        maxWidthPoints = maxWidth
        maxHeightPoints = maxHeight
    }

    /// nil when the SPI is missing or the display couldn't be created.
    static func make(widthPoints: Int, heightPoints: Int, scale: Int) -> VirtualDisplay? {
        guard isAvailable,
              let descriptorClass = NSClassFromString("CGVirtualDisplayDescriptor"),
              let modeClass = NSClassFromString("CGVirtualDisplayMode"),
              let settingsClass = NSClassFromString("CGVirtualDisplaySettings"),
              let displayClass = NSClassFromString("CGVirtualDisplay") else { return nil }
        let s = max(1, min(2, scale))
        // Room to grow in place (a window going full screen): 3840×2400 pt
        // at 2×, bounded by the canvas limit.
        let maxW = min(8192 / s, max(widthPoints, 3840)), maxH = min(8192 / s, max(heightPoints, 2400))
        let descriptor = unsafeBitCast(descriptorClass, to: VirtualDisplayDescriptor.Type.self).init()
        descriptor.queue = DispatchQueue(label: "glassact.host.virtual-display")
        descriptor.name = "Glass Act Virtual Display"
        descriptor.maxPixelsWide = UInt32(maxW * s)
        descriptor.maxPixelsHigh = UInt32(maxH * s)
        // ~220 ppi at 2× — Retina-class, so macOS treats it as HiDPI.
        descriptor.sizeInMillimeters = CGSize(width: Double(maxW * s) / 220 * 25.4,
                                              height: Double(maxH * s) / 220 * 25.4)
        descriptor.vendorID = 0x5343 // "SC"
        descriptor.productID = 0x5644 // "VD"
        descriptor.serialNum = UInt32(widthPoints << 16 | heightPoints)
        guard let descriptorObject = descriptor as? NSObject else { return nil }
        let display = unsafeBitCast(displayClass, to: VirtualDisplayObject.Type.self).init(descriptor: descriptorObject)
        let settings = unsafeBitCast(settingsClass, to: VirtualDisplaySettings.Type.self).init()
        let mode = unsafeBitCast(modeClass, to: VirtualDisplayMode.Type.self)
            .init(width: UInt32(widthPoints), height: UInt32(heightPoints), refreshRate: 60)
        guard let modeObject = mode as? NSObject, let settingsObject = settings as? NSObject,
              let displayObject = display as? NSObject else { return nil }
        settings.modes = [modeObject]
        settings.hiDPI = s > 1 ? 1 : 0
        guard display.applySettings(settingsObject), display.displayID != 0 else { return nil }
        return VirtualDisplay(display: displayObject, id: display.displayID,
                              width: widthPoints, height: heightPoints, scale: s, maxWidth: maxW, maxHeight: maxH)
    }

    func canResize(toWidth w: Int, height h: Int) -> Bool { w <= maxWidthPoints && h <= maxHeightPoints }

    /// New size in place (same display id; mirroring follows). The mode
    /// appears a moment later — then `selectMode()`.
    func resize(widthPoints w: Int, heightPoints h: Int) -> Bool {
        guard canResize(toWidth: w, height: h),
              let modeClass = NSClassFromString("CGVirtualDisplayMode"),
              let settingsClass = NSClassFromString("CGVirtualDisplaySettings") else { return false }
        let settings = unsafeBitCast(settingsClass, to: VirtualDisplaySettings.Type.self).init()
        let mode = unsafeBitCast(modeClass, to: VirtualDisplayMode.Type.self)
            .init(width: UInt32(w), height: UInt32(h), refreshRate: 60)
        guard let modeObject = mode as? NSObject, let settingsObject = settings as? NSObject else { return false }
        settings.modes = [modeObject]
        settings.hiDPI = scale > 1 ? 1 : 0
        guard unsafeBitCast(display, to: VirtualDisplayObject.self).applySettings(settingsObject) else { return false }
        widthPoints = w
        heightPoints = h
        return true
    }

    /// Currently in its w×h mode at `scale`. macOS can move it to the 1×
    /// variant with the same pixels (e.g. after the Mac locks and its
    /// display sleeps, 1450×778@2x can come back as 2900×1556@1x —
    /// everything half-size for the viewer).
    var isInMode: Bool {
        guard let cur = CGDisplayCopyDisplayMode(displayID) else { return false }
        return cur.width == widthPoints && cur.height == heightPoints && cur.pixelWidth == widthPoints * scale
    }

    /// The display is in its w×h mode at `scale` (selecting it if it is
    /// offered but not current). False until the mode exists and is set.
    @discardableResult
    func selectMode() -> Bool {
        let wantPixels = widthPoints * scale
        if let cur = CGDisplayCopyDisplayMode(displayID), cur.width == widthPoints, cur.height == heightPoints,
           cur.pixelWidth == wantPixels { return true }
        let modes = (CGDisplayCopyAllDisplayModes(displayID, [kCGDisplayShowDuplicateLowResolutionModes: true]
                                                  as CFDictionary) as? [CGDisplayMode]) ?? []
        guard let target = modes.first(where: { $0.width == widthPoints && $0.height == heightPoints
                                                && $0.pixelWidth == wantPixels }) else { return false }
        var config: CGDisplayConfigRef?
        guard CGBeginDisplayConfiguration(&config) == .success, let config else { return false }
        CGConfigureDisplayWithDisplayMode(config, displayID, target, nil)
        _ = CGCompleteDisplayConfiguration(config, .forAppOnly)
        return false // takes effect asynchronously; the caller polls
    }

    /// The display is online (it appears a few hundred ms after creation).
    var isOnline: Bool {
        var ids = [CGDirectDisplayID](repeating: 0, count: 16)
        var count: UInt32 = 0
        guard CGGetOnlineDisplayList(16, &ids, &count) == .success else { return false }
        return ids.prefix(Int(count)).contains(displayID)
    }

    /// Every other online display, i.e. the ones that should mirror it.
    var physicalDisplays: [CGDirectDisplayID] {
        var ids = [CGDirectDisplayID](repeating: 0, count: 16)
        var count: UInt32 = 0
        guard CGGetOnlineDisplayList(16, &ids, &count) == .success else { return [] }
        return ids.prefix(Int(count)).filter { $0 != displayID }
    }

    /// Whether every physical display mirrors this one.
    var isMirrored: Bool {
        let physical = physicalDisplays
        return !physical.isEmpty && physical.allSatisfy { CGDisplayMirrorsDisplay($0) == displayID }
    }

    /// Point the physical displays at this one (or back, `on: false`).
    /// `.forAppOnly`: macOS undoes it if the host exits, crash included.
    @discardableResult
    func mirror(_ on: Bool) -> Bool {
        var config: CGDisplayConfigRef?
        guard CGBeginDisplayConfiguration(&config) == .success, let config else { return false }
        for id in physicalDisplays {
            CGConfigureDisplayMirrorOfDisplay(config, id, on ? displayID : kCGNullDirectDisplay)
        }
        return CGCompleteDisplayConfiguration(config, .forAppOnly) == .success
    }
}

// The SPI's shapes, bound with unsafeBitCast to the runtime classes. Swift
// derives the selectors (initWithWidth:height:refreshRate:, setHiDPI:, …).
@objc private protocol VirtualDisplayDescriptor: NSObjectProtocol {
    init()
    var queue: DispatchQueue { get set }
    var name: String { get set }
    var maxPixelsWide: UInt32 { get set }
    var maxPixelsHigh: UInt32 { get set }
    var sizeInMillimeters: CGSize { get set }
    var productID: UInt32 { get set }
    var vendorID: UInt32 { get set }
    var serialNum: UInt32 { get set }
}

@objc private protocol VirtualDisplayMode: NSObjectProtocol {
    init(width: UInt32, height: UInt32, refreshRate: Double)
}

@objc private protocol VirtualDisplaySettings: NSObjectProtocol {
    init()
    var modes: [NSObject] { get set }
    var hiDPI: UInt32 { get set }
}

@objc private protocol VirtualDisplayObject: NSObjectProtocol {
    init(descriptor: NSObject)
    @objc(applySettings:) func applySettings(_ settings: NSObject) -> Bool
    var displayID: UInt32 { get }
}
