import GlassActCore
import GlassActSession
import GlassActTransport
import UIKit

/// §5 present path on the iPad, and the session's input. Like the Mac's
/// CanvasView: each display-link tick starts at most one blit on the
/// engine's queue (`SurfacePresenter`), and the main thread only flips the
/// content layer when it lands.
///
/// The picture is fit to the view, and pinching zooms it locally (the host
/// isn't asked for anything). Input, in canvas pixels:
/// - **Touch** is the pointer: tap to click (taps in quick succession are a
///   double or triple click), drag to drag, touch and hold or two-finger tap
///   to right-click, two fingers to scroll; a pinch zooms and pans the view.
/// - **A trackpad or mouse** is a Mac's: hover moves the pointer, buttons
///   press and release as they do, and scrolling scrolls.
/// - **A hardware keyboard** sends physical keys (`HIDKeyMap`); the on-screen
///   keyboard (`KeyboardProxy`) types characters as US-layout keystrokes.
final class CanvasView: UIView, UIGestureRecognizerDelegate {
    private let controller: ViewerController
    private var grid: TileGrid
    private var presenter: SurfacePresenter
    private var presenterGeneration = 0
    private var blitInFlight = false
    private var link: CADisplayLink?

    private let contentLayer = CALayer()
    private let cursorLayer = CALayer()

    /// Local zoom (1 = fit) and the zoomed picture's offset from centred,
    /// in view points.
    private var zoom: CGFloat = 1
    private var pan = CGPoint.zero
    private static let maxZoom: CGFloat = 6

    /// The pointer as this device last put it (canvas px): drawn at once,
    /// ahead of the host's report a round trip later (as on the Mac).
    private var localCursor: (x: Int, y: Int)?
    private var localCursorAt: CFTimeInterval = 0
    private static let localCursorHold: CFTimeInterval = 1.0

    private var clicks = ClickCounter()
    private var heldKeys: [Int: UInt16] = [:] // HID usage → key code sent down
    /// The view's size settled (rotation, Split View, Stage Manager).
    var onSizeSettled: ((CGSize) -> Void)?
    private var lastSettledSize = CGSize.zero
    private var settleWork: DispatchWorkItem?

    let keyboard = KeyboardProxy()

    init(controller: ViewerController, grid: TileGrid) {
        self.controller = controller
        self.grid = grid
        presenter = SurfacePresenter(grid: grid)
        super.init(frame: .zero)
        backgroundColor = .black
        clipsToBounds = true
        isMultipleTouchEnabled = true
        contentLayer.magnificationFilter = .linear
        contentLayer.minificationFilter = .trilinear
        contentLayer.contentsGravity = .resize
        contentLayer.actions = ["contents": NSNull(), "frame": NSNull(), "position": NSNull(),
                                "bounds": NSNull(), "transform": NSNull()]
        layer.addSublayer(contentLayer)
        cursorLayer.isHidden = true
        cursorLayer.magnificationFilter = .nearest
        cursorLayer.actions = ["position": NSNull(), "bounds": NSNull(), "hidden": NSNull(), "contents": NSNull()]
        contentLayer.addSublayer(cursorLayer)
        controller.onCursorUpdate = { [weak self] in self?.updateCursorLayer() }
        keyboard.onKey = { [weak self] code, down, flags in self?.sendKey(code, down: down, flags: flags) }
        keyboard.onPresses = { [weak self] presses, down in self?.handle(presses, down: down) ?? false }
        addSubview(keyboard)
        installGestures()
        addInteraction(UIPointerInteraction(delegate: self))
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    // MARK: - Presenting

    func reconfigure(grid newGrid: TileGrid) {
        grid = newGrid
        presenter = SurfacePresenter(grid: newGrid)
        presenterGeneration += 1
        layoutContent()
        updateCursorLayer()
    }

    func startPresenting() {
        let link = CADisplayLink(target: self, selector: #selector(present))
        link.preferredFrameRateRange = CAFrameRateRange(minimum: 30, maximum: 120, preferred: 120)
        link.add(to: .main, forMode: .common)
        self.link = link
    }

    func stopPresenting() {
        link?.invalidate()
        link = nil
    }

    @objc private func present() {
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

    private func blitLanded(_ frame: SurfacePresenter.Frame?, generation: Int) {
        blitInFlight = false
        guard generation == presenterGeneration, let frame else { return }
        contentLayer.contents = frame.surface
        let flippedUS = SurfacePresenter.uptimeUS()
        controller.recordPresent(blitUS: frame.blitUS,
                                 flipDelayUS: flippedUS > frame.completedUptimeUS ? flippedUS - frame.completedUptimeUS : 0)
        if !frame.captureTimestampsUS.isEmpty {
            let nowUS = Int64(bitPattern: MonotonicClock.nowUS)
            let offset = controller.hostClockOffsetUS
            controller.recordGlassToGlass(frame.captureTimestampsUS.map {
                let g2g = nowUS &- (Int64(bitPattern: $0) &+ offset)
                return g2g > 0 ? UInt64(g2g) : 0
            })
        }
    }

    // MARK: - Geometry

    private var screenScale: CGFloat { window?.screen.scale ?? traitCollection.displayScale }

    /// The picture's frame in view points: fit, then zoomed about the
    /// centre and panned.
    private var pictureFrame: CGRect {
        guard bounds.width > 0, grid.width > 0 else { return .zero }
        let fit = min(bounds.width / CGFloat(grid.width), bounds.height / CGFloat(grid.height))
        let w = CGFloat(grid.width) * fit * zoom, h = CGFloat(grid.height) * fit * zoom
        // Whole device pixels, so a 1:1 picture lands on pixels.
        let s = screenScale
        let x = ((bounds.width - w) / 2 + pan.x) * s, y = ((bounds.height - h) / 2 + pan.y) * s
        return CGRect(x: x.rounded() / s, y: y.rounded() / s, width: w, height: h)
    }

    private func layoutContent() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        clampPan()
        let frame = pictureFrame
        contentLayer.frame = frame
        // Nearest when one received pixel is a whole number of screen
        // pixels; smooth otherwise (as on the Mac).
        let perPixel = frame.width * screenScale / CGFloat(max(1, grid.width))
        contentLayer.magnificationFilter = abs(perPixel - perPixel.rounded()) < 0.001 ? .nearest : .linear
    }

    /// A zoomed picture can't be dragged off the view.
    private func clampPan() {
        guard grid.width > 0, bounds.width > 0 else { return }
        let fit = min(bounds.width / CGFloat(grid.width), bounds.height / CGFloat(grid.height))
        let w = CGFloat(grid.width) * fit * zoom, h = CGFloat(grid.height) * fit * zoom
        let maxX = max(0, (w - bounds.width) / 2), maxY = max(0, (h - bounds.height) / 2)
        pan.x = min(maxX, max(-maxX, pan.x))
        pan.y = min(maxY, max(-maxY, pan.y))
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        layoutContent()
        updateCursorLayer()
        reportPresentedScale()
        noteSizeMaybeSettled()
    }

    /// Settled = unchanged for half a second (a rotation or a Stage Manager
    /// drag runs through many sizes).
    private func noteSizeMaybeSettled() {
        guard bounds.width > 0, bounds.size != lastSettledSize else { return }
        settleWork?.cancel()
        let size = bounds.size
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.bounds.size == size, size != self.lastSettledSize else { return }
            self.lastSettledSize = size
            self.onSizeSettled?(size)
        }
        settleWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: work)
    }

    /// Displayed ÷ received pixels, capped at 100 % (§3.5 QUALITY).
    private func reportPresentedScale() {
        guard grid.width > 0, bounds.width > 0 else { return }
        let pct = min(100, Int(pictureFrame.width * screenScale / CGFloat(grid.width) * 100))
        controller.updatePresentedScale(max(1, pct))
    }

    func resetZoom() {
        zoom = 1
        pan = .zero
        layoutContent()
        updateCursorLayer()
        reportPresentedScale()
    }

    // MARK: - Cursor (metadata, §5)

    private var localCursorActive: Bool {
        localCursor != nil && CACurrentMediaTime() - localCursorAt < Self.localCursorHold
    }

    private func noteLocalCursor(_ x: Int, _ y: Int) {
        localCursor = (x, y)
        let at = CACurrentMediaTime()
        localCursorAt = at
        updateCursorLayer()
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.localCursorHold) { [weak self] in
            guard let self, self.localCursorAt == at else { return }
            self.updateCursorLayer()
        }
    }

    private func updateCursorLayer() {
        let local = localCursorActive ? localCursor : nil
        guard controller.cursorVisible || local != nil, let image = controller.cursorImage,
              grid.width > 0, contentLayer.bounds.width > 0 else {
            cursorLayer.isHidden = true
            return
        }
        // The content layer's bounds are the picture in view points: canvas
        // pixels scale by `k` into it. The pointer keeps the Mac's size
        // relative to its screen (it scales with the picture).
        let k = contentLayer.bounds.width / CGFloat(grid.width)
        let x = CGFloat(local?.x ?? controller.cursorX), y = CGFloat(local?.y ?? controller.cursorY)
        cursorLayer.contents = image
        cursorLayer.frame = CGRect(x: (x - controller.cursorHotspot.x) * k, y: (y - controller.cursorHotspot.y) * k,
                                   width: CGFloat(image.width) * k, height: CGFloat(image.height) * k)
        cursorLayer.isHidden = false
    }

    // MARK: - Input mapping

    /// View point → canvas pixel; nil off the picture (`clamp` pins it to
    /// the edge instead, for drags that leave it).
    private func canvasPoint(_ p: CGPoint, clamp: Bool = false) -> (Int, Int)? {
        let frame = pictureFrame
        guard frame.width > 0 else { return nil }
        var cx = Int(((p.x - frame.minX) / frame.width * CGFloat(grid.width)).rounded(.down))
        var cy = Int(((p.y - frame.minY) / frame.height * CGFloat(grid.height)).rounded(.down))
        if clamp {
            cx = min(grid.width - 1, max(0, cx))
            cy = min(grid.height - 1, max(0, cy))
        }
        guard cx >= 0, cy >= 0, cx < grid.width, cy < grid.height else { return nil }
        return (cx, cy)
    }

    private func send(_ kind: UInt8, _ p: (Int, Int), a: Int = 0, b: Int = 0) {
        if kind <= 3 { noteLocalCursor(p.0, p.1) }
        controller.sendInput(kind: kind, x: p.0, y: p.1, a: a, b: b)
    }

    /// A whole click at `p`: the pointer moves there first, so the host's
    /// hover state (menus, tooltips) sees it arrive.
    private func click(at p: (Int, Int), button: Int) {
        let count = clicks.press(at: CGPoint(x: p.0, y: p.1), button: button, time: CACurrentMediaTime(),
                                 slop: 24 * CGFloat(grid.width) / max(1, pictureFrame.width))
        send(1, p)
        send(2, p, a: count, b: button)
        send(3, p, a: count, b: button)
    }

    // MARK: - Gestures (touch)

    private let pinch = UIPinchGestureRecognizer()
    private let twoFingerPan = UIPanGestureRecognizer()
    private var twoFingerMode: TwoFingerMode = .undecided
    private enum TwoFingerMode { case undecided, scroll, zoom }
    private var lastScrollTranslation = CGPoint.zero
    private var scrollRemainder = CGPoint.zero
    private var pinchStartZoom: CGFloat = 1
    private var pinchAnchor = CGPoint.zero
    private var dragging = false

    private func installGestures() {
        let direct = [NSNumber(value: UITouch.TouchType.direct.rawValue),
                      NSNumber(value: UITouch.TouchType.pencil.rawValue)]

        let longPress = UILongPressGestureRecognizer(target: self, action: #selector(longPressed(_:)))
        longPress.allowedTouchTypes = direct
        longPress.minimumPressDuration = 0.5
        addGestureRecognizer(longPress)

        let tap = UITapGestureRecognizer(target: self, action: #selector(tapped(_:)))
        tap.allowedTouchTypes = direct
        tap.require(toFail: longPress)
        addGestureRecognizer(tap)

        let twoFingerTap = UITapGestureRecognizer(target: self, action: #selector(twoFingerTapped(_:)))
        twoFingerTap.allowedTouchTypes = direct
        twoFingerTap.numberOfTouchesRequired = 2
        addGestureRecognizer(twoFingerTap)

        let drag = UIPanGestureRecognizer(target: self, action: #selector(dragged(_:)))
        drag.allowedTouchTypes = direct
        drag.maximumNumberOfTouches = 1
        addGestureRecognizer(drag)

        twoFingerPan.addTarget(self, action: #selector(twoFingerPanned(_:)))
        twoFingerPan.allowedTouchTypes = direct
        twoFingerPan.minimumNumberOfTouches = 2
        twoFingerPan.delegate = self
        addGestureRecognizer(twoFingerPan)

        pinch.addTarget(self, action: #selector(pinched(_:)))
        pinch.allowedTouchTypes = direct
        pinch.delegate = self
        addGestureRecognizer(pinch)

        // A trackpad's or mouse's scrolling (no touches: scroll events only).
        let scroll = UIPanGestureRecognizer(target: self, action: #selector(scrolled(_:)))
        scroll.allowedScrollTypesMask = .all
        scroll.allowedTouchTypes = []
        addGestureRecognizer(scroll)

        let hover = UIHoverGestureRecognizer(target: self, action: #selector(hovered(_:)))
        addGestureRecognizer(hover)
    }

    func gestureRecognizer(_ g: UIGestureRecognizer,
                           shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
        (g === pinch && other === twoFingerPan) || (g === twoFingerPan && other === pinch)
    }

    @objc private func tapped(_ g: UITapGestureRecognizer) {
        guard g.state == .ended, let p = canvasPoint(g.location(in: self)) else { return }
        claimKeyboardFocus()
        click(at: p, button: 0)
    }

    @objc private func longPressed(_ g: UILongPressGestureRecognizer) {
        guard g.state == .began, let p = canvasPoint(g.location(in: self)) else { return }
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        click(at: p, button: 1)
    }

    @objc private func twoFingerTapped(_ g: UITapGestureRecognizer) {
        guard g.state == .ended, let p = canvasPoint(g.location(in: self)) else { return }
        click(at: p, button: 1)
    }

    @objc private func dragged(_ g: UIPanGestureRecognizer) {
        let here = g.location(in: self)
        switch g.state {
        case .began:
            // Press where the finger first touched, not where the pan was
            // recognized ten points later.
            let t = g.translation(in: self)
            guard let start = canvasPoint(CGPoint(x: here.x - t.x, y: here.y - t.y)) else { return }
            claimKeyboardFocus()
            dragging = true
            send(1, start)
            send(2, start, a: 1, b: 0)
            if let p = canvasPoint(here, clamp: true) { send(1, p) }
        case .changed:
            guard dragging, let p = canvasPoint(here, clamp: true) else { return }
            send(1, p)
        case .ended, .cancelled, .failed:
            guard dragging else { return }
            dragging = false
            if let p = canvasPoint(here, clamp: true) { send(3, p, a: 1, b: 0) }
        default:
            break
        }
    }

    /// Two fingers: scroll the host, unless the fingers pinch, which zooms
    /// (and pans) this view instead. Decided once per gesture.
    @objc private func twoFingerPanned(_ g: UIPanGestureRecognizer) {
        let t = g.translation(in: self)
        switch g.state {
        case .began:
            lastScrollTranslation = t
            scrollRemainder = .zero
        case .changed:
            if twoFingerMode == .undecided, hypot(t.x, t.y) > 12 { twoFingerMode = .scroll }
            switch twoFingerMode {
            case .scroll:
                sendScroll(dx: t.x - lastScrollTranslation.x, dy: t.y - lastScrollTranslation.y, at: g.location(in: self))
            case .zoom:
                pan.x += t.x - lastScrollTranslation.x
                pan.y += t.y - lastScrollTranslation.y
                layoutContent()
                updateCursorLayer()
            case .undecided:
                return // don't consume the translation until decided
            }
            lastScrollTranslation = t
        default:
            if pinch.state != .changed && pinch.state != .began { twoFingerMode = .undecided }
        }
    }

    @objc private func pinched(_ g: UIPinchGestureRecognizer) {
        switch g.state {
        case .began:
            pinchStartZoom = zoom
            pinchAnchor = g.location(in: self)
        case .changed:
            if twoFingerMode == .undecided, abs(g.scale - 1) > 0.08 { twoFingerMode = .zoom }
            guard twoFingerMode == .zoom else { return }
            // Zoom about the pinch's centre: the picture point under it stays put.
            let newZoom = min(Self.maxZoom, max(1, pinchStartZoom * g.scale))
            let center = CGPoint(x: bounds.midX + pan.x, y: bounds.midY + pan.y)
            let ratio = newZoom / zoom
            pan.x = pinchAnchor.x - bounds.midX - (pinchAnchor.x - center.x) * ratio
            pan.y = pinchAnchor.y - bounds.midY - (pinchAnchor.y - center.y) * ratio
            zoom = newZoom
            layoutContent()
            updateCursorLayer()
        default:
            reportPresentedScale()
            if twoFingerPan.state != .changed && twoFingerPan.state != .began { twoFingerMode = .undecided }
        }
    }

    /// Scroll deltas in view points, as a Mac trackpad reports them (§3.5
    /// INPUT kind 7: the host posts pixel scrolling). The fingers move the
    /// content, so the direction is a trackpad's "natural" one.
    private func sendScroll(dx: CGFloat, dy: CGFloat, at location: CGPoint) {
        guard let p = canvasPoint(location, clamp: true) else { return }
        scrollRemainder.x += dx
        scrollRemainder.y += dy
        let sx = scrollRemainder.x.rounded(.towardZero), sy = scrollRemainder.y.rounded(.towardZero)
        scrollRemainder.x -= sx
        scrollRemainder.y -= sy
        guard sx != 0 || sy != 0 else { return }
        controller.sendInput(kind: 7, x: p.0, y: p.1, a: Int(sx), b: Int(sy))
    }

    // MARK: - Pointer (trackpad, mouse)

    @objc private func scrolled(_ g: UIPanGestureRecognizer) {
        let t = g.translation(in: self)
        switch g.state {
        case .began:
            lastScrollTranslation = t
            scrollRemainder = .zero
        case .changed:
            sendScroll(dx: t.x - lastScrollTranslation.x, dy: t.y - lastScrollTranslation.y, at: g.location(in: self))
            lastScrollTranslation = t
        default:
            break
        }
    }

    @objc private func hovered(_ g: UIHoverGestureRecognizer) {
        guard g.state == .began || g.state == .changed, let p = canvasPoint(g.location(in: self)) else { return }
        send(1, p)
    }

    /// The buttons a pointer touch pressed: down at begin, up at end, like a
    /// Mac's mouse (gestures ignore pointer touches).
    private var pointerButtons: [ObjectIdentifier: (button: Int, clicks: Int)] = [:]

    private func button(for event: UIEvent?) -> Int {
        guard let mask = event?.buttonMask else { return 0 }
        if mask.contains(.secondary) { return 1 }
        if mask.contains(.button(3)) { return 2 }
        return 0
    }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        for touch in touches where touch.type == .indirectPointer {
            guard let p = canvasPoint(touch.location(in: self)) else { continue }
            claimKeyboardFocus()
            let b = button(for: event)
            let count = clicks.press(at: CGPoint(x: p.0, y: p.1), button: b, time: touch.timestamp,
                                     slop: 6 * CGFloat(grid.width) / max(1, pictureFrame.width))
            pointerButtons[ObjectIdentifier(touch)] = (b, count)
            send(1, p)
            send(2, p, a: count, b: b)
        }
        super.touchesBegan(touches, with: event)
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        for touch in touches where touch.type == .indirectPointer {
            guard pointerButtons[ObjectIdentifier(touch)] != nil,
                  let p = canvasPoint(touch.location(in: self), clamp: true) else { continue }
            send(1, p)
        }
        super.touchesMoved(touches, with: event)
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        endPointerTouches(touches)
        super.touchesEnded(touches, with: event)
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
        endPointerTouches(touches)
        super.touchesCancelled(touches, with: event)
    }

    private func endPointerTouches(_ touches: Set<UITouch>) {
        for touch in touches where touch.type == .indirectPointer {
            guard let pressed = pointerButtons.removeValue(forKey: ObjectIdentifier(touch)),
                  let p = canvasPoint(touch.location(in: self), clamp: true) else { continue }
            send(3, p, a: pressed.clicks, b: pressed.button)
        }
    }

    // MARK: - Keyboard

    override var canBecomeFirstResponder: Bool { true }

    /// Hardware keys come to whichever of this view and the on-screen
    /// keyboard's proxy is first responder; touching the picture takes it
    /// back unless the on-screen keyboard is up.
    private func claimKeyboardFocus() {
        if !keyboard.isFirstResponder && !isFirstResponder { becomeFirstResponder() }
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window != nil { becomeFirstResponder() }
    }

    override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        if !handle(presses, down: true) { super.pressesBegan(presses, with: event) }
    }

    override func pressesEnded(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        if !handle(presses, down: false) { super.pressesEnded(presses, with: event) }
    }

    override func pressesCancelled(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        if !handle(presses, down: false) { super.pressesCancelled(presses, with: event) }
    }

    /// Hardware key presses → INPUT 5/6. True if any were the host's.
    @discardableResult
    private func handle(_ presses: Set<UIPress>, down: Bool) -> Bool {
        var handled = false
        for press in presses {
            guard let key = press.key else { continue }
            let usage = key.keyCode.rawValue
            if down {
                guard let mapped = HIDKeyMap.key(usage: usage) else { continue }
                heldKeys[usage] = mapped.code
                let flags = KeyModifiers.forwarded(UInt(key.modifierFlags.rawValue)) | mapped.flags
                sendKey(mapped.code, down: true, flags: flags)
            } else {
                // Up for whatever went down, even if the modifiers changed.
                guard let code = heldKeys.removeValue(forKey: usage) else { continue }
                let flags = KeyModifiers.forwarded(UInt(key.modifierFlags.rawValue))
                    | (HIDKeyMap.key(usage: usage)?.flags ?? 0)
                sendKey(code, down: false, flags: flags)
            }
            handled = true
        }
        return handled
    }

    private func sendKey(_ code: UInt16, down: Bool, flags: UInt32) {
        controller.sendInput(kind: down ? 5 : 6, x: Int(code), y: 0, a: Int(Int32(bitPattern: flags)), b: 0)
    }

    /// Lift every key still held (the view is going away, or the app is
    /// leaving the foreground): the host would hold them otherwise.
    func releaseHeldKeys() {
        for (_, code) in heldKeys { sendKey(code, down: false, flags: 0) }
        heldKeys.removeAll()
        keyboard.releaseHeldKeys()
    }
}

extension CanvasView: UIPointerInteractionDelegate {
    /// The host draws the pointer (cursor metadata): hide the iPad's own
    /// over the picture.
    func pointerInteraction(_ interaction: UIPointerInteraction, styleFor region: UIPointerRegion) -> UIPointerStyle? {
        .hidden()
    }
}

/// Click counting for taps and pointer presses: a press soon after the last
/// one, near it, with the same button, is the next click of a double or
/// triple click (what macOS does with its own double-click speed).
struct ClickCounter {
    static let interval: CFTimeInterval = 0.4
    private var last: (point: CGPoint, button: Int, time: CFTimeInterval, count: Int)?

    /// `slop`: how far apart (canvas px) presses can be and still count.
    mutating func press(at point: CGPoint, button: Int, time: CFTimeInterval, slop: CGFloat) -> Int {
        var count = 1
        if let last, last.button == button, time - last.time < Self.interval,
           hypot(point.x - last.point.x, point.y - last.point.y) <= slop {
            count = last.count % 3 + 1
        }
        last = (point, button, time, count)
        return count
    }
}
