import AppKit
import IOSurface
import GlassActCore
import GlassActTransport

/// §5 present path: display link via `NSView.displayLink(target:selector:)`.
/// Each tick starts (at most) one blit on the engine's queue — the
/// canvas's own queue — via `SurfacePresenter` (two IOSurfaces, buffer-age
/// dirty union), and the main thread only flips the content layer's
/// contents when it completes. Main never copies pixels or waits on apply
/// work.
///
/// Two presentation modes share one content layer (so the cursor sublayer and
/// input mapping are mode-agnostic):
///   • fit  — the whole canvas scaled into the window (Scale / Client
///            Resolution, where canvas ≈ window).
///   • pan  — the canvas at 1:1 with an edge-driven pan viewport (Native,
///            where the canvas is larger than the window). Apple-style: the
///            viewport scrolls as the pointer nears an edge.
final class CanvasView: NSView {
    private let controller: ViewerController
    private var grid: TileGrid
    /// Opened as a pan viewport (Native on a smaller screen). It pans only
    /// while the picture is bigger than the view (`panning`): a picture
    /// that shrank (auto-scale) fits instead of sitting in a corner.
    private let panMode: Bool
    /// Blit state, engine-queue confined; replaced (never mutated) on main.
    private var presenter: SurfacePresenter
    /// Bumped by `reconfigure`: a blit started for an older presenter is
    /// dropped when it lands.
    private var presenterGeneration = 0
    private var blitInFlight = false
    private var link: CADisplayLink?

    // The canvas lives in its own layer so fit-scaling and panning are just its
    // frame; the cursor is a sublayer of it, positioned in canvas-point space,
    // so it scales and pans for free.
    private let contentLayer = CALayer()
    private let cursorLayer = CALayer()

    // Pan state (canvas pixels): top-left of the visible viewport.
    private var panX: CGFloat = 0
    private var panY: CGFloat = 0
    private var lastMouseView: CGPoint? // nil when the pointer is outside
    private static let edgeZone: CGFloat = 40      // points
    private static let maxPanSpeed: CGFloat = 25   // canvas px per present tick

    // Local cursor echo: the pointer is drawn where the user's mouse IS
    // (canvas px), not where the host last reported it — the host's report
    // is this same motion one RTT later (~250 ms on a remote Wi-Fi link).
    // While local motion is recent the host's positions are its own stale
    // echoes and are ignored; once the pointer has rested for
    // `localCursorHold`, the host's position wins again (host-side warps).
    private var localCursor: (x: Int, y: Int)?
    private var localCursorAt: CFTimeInterval = 0
    private static let localCursorHold: CFTimeInterval = 1.0

    private static let blankCursor: NSCursor = {
        let img = NSImage(size: NSSize(width: 1, height: 1))
        return NSCursor(image: img, hotSpot: .zero)
    }()

    private var backingScale: CGFloat { window?.backingScaleFactor ?? 2 }

    init(controller: ViewerController, grid: TileGrid, panMode: Bool) {
        self.controller = controller
        self.grid = grid
        self.panMode = panMode
        presenter = SurfacePresenter(grid: grid)
        super.init(frame: .zero)
        wantsLayer = true
        layer?.masksToBounds = true // clip the panned content to the window
        layer?.backgroundColor = NSColor.black.cgColor
        contentLayer.magnificationFilter = .nearest // crisp at 1:1 / zoom-in
        contentLayer.minificationFilter = .linear   // smooth downsample in fit
        contentLayer.contentsGravity = .resize
        contentLayer.actions = ["contents": NSNull(), "frame": NSNull(),
                                "position": NSNull(), "bounds": NSNull()]
        layer?.addSublayer(contentLayer)
        cursorLayer.isHidden = true
        cursorLayer.magnificationFilter = .nearest
        cursorLayer.actions = ["position": NSNull(), "bounds": NSNull(),
                               "hidden": NSNull(), "contents": NSNull()]
        contentLayer.addSublayer(cursorLayer)
        controller.onCursorUpdate = { [weak self] in self?.updateCursorLayer() }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    /// In-session resize (§4.10): adopt a new canvas grid IN PLACE — fresh flip
    /// surfaces, reset present state — without recreating the view. Swapping a
    /// window's contentView mid-transaction crashes AppKit's window animation
    /// (over-release in _NSWindowTransformAnimation); reconfiguring keeps the
    /// view, its display link, and the window untouched. Main thread; a
    /// blit still running for the old presenter is dropped when it lands.
    func reconfigure(grid newGrid: TileGrid) {
        grid = newGrid
        presenter = SurfacePresenter(grid: newGrid)
        presenterGeneration += 1
        panX = 0
        panY = 0
        layoutContent()
        updateCursorLayer()
    }

    func startPresenting() {
        let link = displayLink(target: self, selector: #selector(present))
        link.add(to: .main, forMode: .common)
        self.link = link
    }

    func stopPresenting() {
        link?.invalidate()
        link = nil
    }

    // MARK: - Geometry

    /// Canvas size in points at the current backing scale (1 px → 1/s points).
    private var canvasPoints: CGSize {
        let s = backingScale
        return CGSize(width: CGFloat(grid.width) / s, height: CGFloat(grid.height) / s)
    }

    /// Reposition the content layer for the current mode + pan offset. In fit
    /// mode the layer is an aspect-fit rect (canvas scaled to the window); in
    /// pan mode it's 1:1 with the viewport offset by the pan.
    private func layoutContent() {
        let cp = canvasPoints
        contentLayer.bounds = CGRect(origin: .zero, size: cp)
        contentLayer.contentsScale = backingScale
        if panning {
            clampPan()
            let s = backingScale
            // Bottom-left view coords: canvas row panY (viewport top) sits at
            // the window top (y = bounds.height).
            contentLayer.anchorPoint = .zero
            contentLayer.position = CGPoint(x: -panX / s,
                                            y: bounds.height - cp.height + panY / s)
        } else {
            let place = fitPlacement()
            contentLayer.anchorPoint = .zero
            contentLayer.bounds = CGRect(x: 0, y: 0, width: cp.width, height: cp.height)
            contentLayer.position = place.origin
            // Scale the layer to the fit rect via its transform so the cursor
            // sublayer (in canvas-point space) scales with it.
            contentLayer.transform = CATransform3DMakeScale(place.fit, place.fit, 1)
            return
        }
        contentLayer.transform = CATransform3DIdentity
    }

    /// The pan viewport is in use: opened as one, and the picture is bigger
    /// than the view.
    private var panning: Bool {
        let cp = canvasPoints
        return panMode && (cp.width > bounds.width || cp.height > bounds.height)
    }

    /// Where a fit picture goes: its scale and bottom-left corner (whole
    /// device pixels). Layout and input both use it, so a click lands on
    /// the pixel drawn under it.
    private func fitPlacement() -> (fit: CGFloat, origin: CGPoint) {
        let cp = canvasPoints
        let fitW = bounds.width / cp.width, fitH = bounds.height / cp.height
        var fit = min(fitW, fitH)
        // Never a black sliver: when covering the window crops no more
        // than a point and a half (window sizes round to whole points),
        // cover instead of fitting.
        let cover = max(fitW, fitH)
        if cp.width * cover - bounds.width <= 1.5 && cp.height * cover - bounds.height <= 1.5 { fit = cover }
        // Within 1% of the window and covering it: show it 1:1 and crop
        // the point or two. Otherwise a 1470×924 virtual display in a
        // 1470×923 full-screen window would draw at 99.9% — every pixel
        // resampled, visibly soft.
        if abs(fit - 1) < 0.01 && cp.width >= bounds.width && cp.height >= bounds.height { fit = 1 }
        // Whole device pixels, or a 1:1 picture lands between pixels.
        let s = backingScale
        let w = cp.width * fit, h = cp.height * fit
        return (fit, CGPoint(x: ((bounds.width - w) / 2 * s).rounded() / s,
                             y: ((bounds.height - h) / 2 * s).rounded() / s))
    }

    private func clampPan() {
        let s = backingScale
        let visW = min(CGFloat(grid.width), bounds.width * s)
        let visH = min(CGFloat(grid.height), bounds.height * s)
        panX = max(0, min(panX, CGFloat(grid.width) - visW))
        panY = max(0, min(panY, CGFloat(grid.height) - visH))
    }

    override func layout() {
        super.layout()
        layoutContent()
        updateCursorLayer()
        reportPresentedScale()
    }

    /// The view's size settled (a drag ended, or a resize that wasn't a
    /// drag: zoom, tiling, full screen). Virtual Display sizes the host's
    /// display from it. Fired from the view itself: window-delegate
    /// notifications can miss live drags.
    var onSizeSettled: ((CGSize) -> Void)?
    private var lastSettledSize = CGSize.zero

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        if !inLiveResize { noteSizeSettled() }
    }

    override func viewDidEndLiveResize() {
        super.viewDidEndLiveResize()
        noteSizeSettled()
    }

    private func noteSizeSettled() {
        guard bounds.size != lastSettledSize, bounds.width > 0 else { return }
        lastSettledSize = bounds.size
        onSizeSettled?(bounds.size)
    }

    /// Presented scale = displayed pixels ÷ canvas pixels (pan mode is 1:1 =
    /// 100%; fit mode downscales). Drives the host's quality policy — detail
    /// the viewer can't show is free to shed.
    private func reportPresentedScale() {
        guard bounds.width > 0 else { return }
        let pct: Int
        if panning {
            pct = 100
        } else {
            let s = backingScale
            pct = min(100, Int((bounds.width * s / CGFloat(grid.width)) * 100))
        }
        controller.updatePresentedScale(max(1, pct))
    }

    // MARK: - Present

    @objc private func present() {
        // Auto-pan runs every tick (even without a blit) so the viewport keeps
        // scrolling while the pointer rests near an edge.
        if panning {
            advanceAutoPan()
            layoutContent()
            updateCursorLayer()
        }
        // One blit at a time, started on a display tick: the surface it
        // writes was flipped away from at least one tick earlier.
        guard !blitInFlight else { return }
        blitInFlight = true
        let presenter = self.presenter
        let generation = presenterGeneration
        let engine = controller.engine
        let controller = self.controller
        controller.queue.async { [weak self] in
            let frame = presenter.blit(from: engine)
            let first = frame == nil ? nil : controller.takeFirstPicture()
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    self?.blitLanded(frame, generation: generation)
                    if let first { controller.logFirstPicture(first, presentedUS: MonotonicClock.nowUS) }
                }
            }
        }
    }

    /// Main thread: flip to a finished surface.
    private func blitLanded(_ frame: SurfacePresenter.Frame?, generation: Int) {
        blitInFlight = false
        guard generation == presenterGeneration, let frame else { return }
        contentLayer.contents = frame.surface
        let flippedUS = SurfacePresenter.uptimeUS()
        controller.recordPresent(blitUS: frame.blitUS,
                                 flipDelayUS: flippedUS > frame.completedUptimeUS ? flippedUS - frame.completedUptimeUS : 0)
        layoutContent()
        updateCursorLayer()
        if !frame.captureTimestampsUS.isEmpty {
            // capture_ts rides the host clock; correct by the PING offset or
            // cross-machine g2g reads as 0. Stamped at the flip.
            let nowUS = Int64(bitPattern: MonotonicClock.nowUS)
            let offset = controller.hostClockOffsetUS
            controller.recordGlassToGlass(frame.captureTimestampsUS.map {
                let g2g = nowUS &- (Int64(bitPattern: $0) &+ offset)
                return g2g > 0 ? UInt64(g2g) : 0
            })
        }
    }

    private func advanceAutoPan() {
        guard let m = lastMouseView, bounds.width > 0 else { return }
        let z = Self.edgeZone
        func speed(_ d: CGFloat) -> CGFloat { d < z ? (z - d) / z * Self.maxPanSpeed : 0 }
        // View is bottom-left: top edge is high y.
        panX -= speed(m.x)                     // near left → reveal left
        panX += speed(bounds.width - m.x)      // near right → reveal right
        panY -= speed(bounds.height - m.y)     // near top → reveal up
        panY += speed(m.y)                     // near bottom → reveal down
        clampPan()
    }

    // MARK: - Cursor composite (cursor as metadata, §5)

    private var localCursorActive: Bool {
        localCursor != nil && CACurrentMediaTime() - localCursorAt < Self.localCursorHold
    }

    private func noteLocalCursor(_ x: Int, _ y: Int) {
        localCursor = (x, y)
        let at = CACurrentMediaTime()
        localCursorAt = at
        updateCursorLayer()
        // Hand the pointer back to the host's latest position once idle.
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.localCursorHold) { [weak self] in
            guard let self, self.localCursorAt == at else { return }
            self.updateCursorLayer()
        }
    }

    private func updateCursorLayer() {
        let local = localCursorActive ? localCursor : nil
        // Moving the mouse shows the pointer (as macOS does after typing)
        // without waiting a round trip for the host to say so.
        guard controller.cursorVisible || local != nil, let image = controller.cursorImage else {
            cursorLayer.isHidden = true
            return
        }
        // Positioned in the content layer's canvas-point space (bottom-left),
        // so it scales in fit mode and pans in pan mode automatically.
        let s = backingScale
        let w = CGFloat(image.width) / s
        let h = CGFloat(image.height) / s
        let hx = controller.cursorHotspot.x / s
        let hy = controller.cursorHotspot.y / s
        let cx = CGFloat(local?.x ?? controller.cursorX) / s - hx
        let cyTop = CGFloat(local?.y ?? controller.cursorY) / s - hy
        let ch = canvasPoints.height
        cursorLayer.contents = image
        cursorLayer.frame = CGRect(x: cx, y: ch - cyTop - h, width: w, height: h)
        cursorLayer.isHidden = false
    }

    // MARK: - Input capture (viewer → host)

    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func resetCursorRects() { addCursorRect(bounds, cursor: Self.blankCursor) }

    /// View point → canvas pixel, honoring the current mode's mapping.
    private func canvasPoint(_ event: NSEvent) -> (Int, Int)? {
        guard bounds.width > 0 else { return nil }
        let p = convert(event.locationInWindow, from: nil)
        lastMouseView = p
        let s = backingScale
        var cx: Int, cy: Int
        if panning {
            cx = Int((panX + p.x * s).rounded())
            cy = Int((panY + (bounds.height - p.y) * s).rounded())
        } else {
            let place = fitPlacement()
            let top = place.origin.y + canvasPoints.height * place.fit // the picture's top edge
            cx = Int(((p.x - place.origin.x) / place.fit * s).rounded())
            cy = Int(((top - p.y) / place.fit * s).rounded())
        }
        guard cx >= 0, cy >= 0, cx < grid.width, cy < grid.height else { return nil }
        return (cx, cy)
    }

    private func sendMouse(_ event: NSEvent, kind: UInt8, button: Int) {
        guard let (cx, cy) = canvasPoint(event) else { return }
        noteLocalCursor(cx, cy)
        // Buttons carry this Mac's click count (its double-click speed and
        // slop decide), so the host posts a real double or triple click.
        let clicks = kind == 2 || kind == 3 ? event.clickCount : 0
        controller.sendInput(kind: kind, x: cx, y: cy, a: clicks, b: button)
    }

    override func mouseMoved(with event: NSEvent)        { sendMouse(event, kind: 1, button: 0) }
    override func mouseDragged(with event: NSEvent)      { sendMouse(event, kind: 1, button: 0) }
    override func rightMouseDragged(with event: NSEvent) { sendMouse(event, kind: 1, button: 0) }
    override func otherMouseDragged(with event: NSEvent) { sendMouse(event, kind: 1, button: 0) }
    override func mouseDown(with event: NSEvent)         { window?.makeFirstResponder(self); sendMouse(event, kind: 2, button: 0) }
    override func mouseUp(with event: NSEvent)           { sendMouse(event, kind: 3, button: 0) }
    override func rightMouseDown(with event: NSEvent)    { sendMouse(event, kind: 2, button: 1) }
    override func rightMouseUp(with event: NSEvent)      { sendMouse(event, kind: 3, button: 1) }
    override func otherMouseDown(with event: NSEvent)    { sendMouse(event, kind: 2, button: 2) }
    override func otherMouseUp(with event: NSEvent)      { sendMouse(event, kind: 3, button: 2) }
    override func mouseExited(with event: NSEvent)       { lastMouseView = nil }

    // Fractional scroll carried to the next event (a slow trackpad swipe
    // is mostly sub-point deltas; rounding each alone drops them).
    private var scrollRemainderX: CGFloat = 0
    private var scrollRemainderY: CGFloat = 0

    /// Precise devices (trackpad, Magic Mouse) report points → input kind 7
    /// (host posts pixel units); a wheel mouse reports lines → kind 4. Sent
    /// as lines, a trackpad swipe would scroll ~10× too far.
    override func scrollWheel(with event: NSEvent) {
        guard let (cx, cy) = canvasPoint(event) else { return }
        scrollRemainderX += event.scrollingDeltaX
        scrollRemainderY += event.scrollingDeltaY
        let dx = scrollRemainderX.rounded(.towardZero)
        let dy = scrollRemainderY.rounded(.towardZero)
        scrollRemainderX -= dx
        scrollRemainderY -= dy
        guard dx != 0 || dy != 0 else { return }
        controller.sendInput(kind: event.hasPreciseScrollingDeltas ? 7 : 4,
                             x: cx, y: cy, a: Int(dx), b: Int(dy))
    }

    /// Key equivalents (⌘C, ⌘Q…) belong to the remote Mac while this view
    /// has focus: claim them before the menu bar does and forward as keys.
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard event.type == .keyDown, window?.firstResponder === self else {
            return super.performKeyEquivalent(with: event)
        }
        keyDown(with: event)
        // AppKit swallows the key-up of a ⌘ combination; without this the
        // host would hold the key down.
        if event.modifierFlags.contains(.command) { keyUp(with: event) }
        return true
    }

    override func keyDown(with event: NSEvent) {
        controller.sendInput(kind: 5, x: Int(event.keyCode), y: 0, a: flags(event), b: 0)
    }
    override func keyUp(with event: NSEvent) {
        controller.sendInput(kind: 6, x: Int(event.keyCode), y: 0, a: flags(event), b: 0)
    }
    override func flagsChanged(with event: NSEvent) {
        guard let down = KeyModifiers.isDown(keyCode: event.keyCode, modifierFlags: event.modifierFlags.rawValue)
        else { return }
        controller.sendInput(kind: down ? 5 : 6, x: Int(event.keyCode), y: 0, a: flags(event), b: 0)
    }

    private func flags(_ event: NSEvent) -> Int {
        Int(Int32(bitPattern: KeyModifiers.forwarded(event.modifierFlags.rawValue)))
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(
            rect: bounds,
            options: [.activeInKeyWindow, .mouseMoved, .mouseEnteredAndExited, .inVisibleRect],
            owner: self, userInfo: nil))
    }
}
