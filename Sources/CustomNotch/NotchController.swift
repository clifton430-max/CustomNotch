import AppKit
import Combine
import QuartzCore
import SwiftUI

final class NotchPanel: NSPanel {
    init(size: CGFloat) {
        super.init(contentRect: NSRect(x: 0, y: 0, width: size, height: size),
                   styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered, defer: false)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        isMovable = false
        isFloatingPanel = true
        hidesOnDeactivate = false
        becomesKeyOnlyIfNeeded = true
        ignoresMouseEvents = true
        // Above the menu bar so the notch can sit on the top edge, like the real one.
        level = NSWindow.Level(rawValue: NSWindow.Level.mainMenu.rawValue + 3)
        collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
    // Never let AppKit nudge the window back on screen; it intentionally overhangs edges.
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }
}

final class NotchHostingView<Content: View>: NSHostingView<Content> {
    required init(rootView: Content) {
        super.init(rootView: rootView)
        sizingOptions = []
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

/// Owns the notch window and everything that moves it: dragging, throwing, spring-snapping
/// to a screen edge, and hover-driven expansion.
@MainActor
final class NotchController: NSObject {
    let model = NotchModel()
    let stats = SystemStats()
    let settings = NotchSettings()
    private lazy var settingsWindow = SettingsWindowController(settings: settings, stats: stats)
    private var sizing = NotchSizing.standard
    private var sizingObserver: AnyCancellable?

    private let canvas = NotchMetrics.canvas
    private var panel: NotchPanel!

    // Attachment. `windowAnchor` is where the canvas centre currently is on screen; at rest it
    // equals `attachPoint`, the point on the screen edge the notch is pinned to.
    private var edge: NotchEdge = .right
    private var attachPoint: CGPoint = .zero
    private var windowAnchor: CGPoint = .zero
    private var alongRange: ClosedRange<CGFloat> = 0...1
    /// Body rect relative to `windowAnchor`, in screen (y-up) orientation. Used for hit-testing.
    private var bodyRect: CGRect = .zero

    // Dragging.
    private var mouseDownPoint: CGPoint?
    private var isDragging = false
    private var samples: [(time: CFTimeInterval, point: CGPoint)] = []

    // Spring.
    private var displayLink: CADisplayLink?
    private var springVelocity = CGVector.zero
    private var lastTick: CFTimeInterval = 0
    private var didLandHaptic = false
    private var isSpringing: Bool { displayLink != nil }

    // Hover.
    private var hoverTimer: Timer?
    private var insideSince: CFTimeInterval?
    private var outsideSince: CFTimeInterval?
    private var suppressHoverUntilExit = false
    private var eventMonitor: Any?

    private enum Anim {
        static let open = Animation.spring(response: 0.46, dampingFraction: 0.76)
        static let close = Animation.spring(response: 0.38, dampingFraction: 0.9)
        static let snap = Animation.spring(response: 0.5, dampingFraction: 0.72)
        static let lift = Animation.spring(response: 0.34, dampingFraction: 0.74)
        static let resize = Animation.spring(response: 0.3, dampingFraction: 0.82)
    }

    // MARK: Lifecycle

    func show() {
        panel = NotchPanel(size: canvas)
        let root = NotchRootView(model: model, stats: stats)
        let host = NotchHostingView(rootView: root)
        host.frame = NSRect(x: 0, y: 0, width: canvas, height: canvas)
        panel.contentView = host
        model.openSettings = { [weak self] in self?.openSettings() }

        sizing = settings.sizing
        // `$sizing` fires before the stored value changes, so use the value it delivers.
        sizingObserver = settings.$sizing.removeDuplicates().dropFirst().sink { [weak self] new in
            self?.sizingChanged(to: new)
        }

        restorePosition()
        moveWindow(to: attachPoint)
        applyLayout(nil)
        panel.orderFrontRegardless()

        DispatchQueue.main.async {
            withAnimation(.spring(response: 0.6, dampingFraction: 0.72)) { self.model.isAppeared = true }
        }

        eventMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .leftMouseDragged, .leftMouseUp]) { [weak self] event in
            MainActor.assumeIsolated { self?.handle(event) ?? event }
        }
        let timer = Timer(timeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.pollHover() }
        }
        RunLoop.main.add(timer, forMode: .common)
        hoverTimer = timer

        NotificationCenter.default.addObserver(self, selector: #selector(screensChanged),
                                               name: NSApplication.didChangeScreenParametersNotification, object: nil)
        #if DEBUG
        installDebugHooks()
        #endif
    }

    func dismiss(then completion: @escaping () -> Void) {
        withAnimation(.easeIn(duration: 0.22)) {
            model.isExpanded = false
            model.isAppeared = false
        }
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(280))
            completion()
        }
    }

    func resetPosition() {
        guard let screen = NSScreen.screens.first else { return }
        let f = screen.frame
        attach(edge: .right, screen: screen, along: f.midY)
        model.isExpanded = false
        springVelocity = .zero
        startSpring()
        applyLayout(Anim.snap)
        savePosition(screen: screen)
    }

    func openSettings() {
        settingsWindow.show()
    }

    private func sizingChanged(to new: NotchSizing) {
        sizing = new
        guard !isDragging else { return }
        // Re-attach so the resized notch still fits its edge, gliding there if it had to move.
        let screen = NSScreen.screens.first(where: { $0.frame.insetBy(dx: -1, dy: -1).contains(attachPoint) })
            ?? NSScreen.screens.first
        if let screen {
            let previous = attachPoint
            attach(edge: edge, screen: screen, along: edge.isHorizontal ? attachPoint.x : attachPoint.y)
            if attachPoint != previous {
                springVelocity = .zero
                startSpring()
            }
        }
        applyLayout(Anim.resize)
    }

    @objc private func screensChanged() {
        let screen = NSScreen.screens.first(where: { $0.frame.insetBy(dx: -1, dy: -1).contains(attachPoint) })
            ?? NSScreen.screens.first
        guard let screen else { return }
        attach(edge: edge, screen: screen, along: edge.isHorizontal ? attachPoint.x : attachPoint.y)
        moveWindow(to: attachPoint)
        applyLayout(nil)
    }

    // MARK: Geometry

    private func moveWindow(to point: CGPoint) {
        windowAnchor = point
        panel.setFrameOrigin(CGPoint(x: (point.x - canvas / 2).rounded(), y: (point.y - canvas / 2).rounded()))
    }

    /// Range of the attached edge the notch body may occupy on `screen`.
    private func allowedRange(edge: NotchEdge, screen: NSScreen, near along: CGFloat) -> ClosedRange<CGFloat> {
        let f = screen.frame
        let m = NotchMetrics.screenMargin
        switch edge {
        case .left, .right:
            let menuBar = max(f.maxY - screen.visibleFrame.maxY, screen.safeAreaInsets.top, 24)
            return (f.minY + m)...(f.maxY - menuBar - m)
        case .bottom:
            return (f.minX + m)...(f.maxX - m)
        case .top:
            let keepOut = topKeepOut(on: screen)
            return along < keepOut.midX
                ? (f.minX + m)...(keepOut.minX - m)
                : (keepOut.maxX + m)...(f.maxX - m)
        }
    }

    /// The stretch of the top edge reserved for the hardware notch and any other notch app
    /// (any other app's overlay window hugging the top of this screen above the menu bar).
    private func topKeepOut(on screen: NSScreen) -> CGRect {
        let f = screen.frame
        var notchWidth: CGFloat = 200
        if let l = screen.auxiliaryTopLeftArea, let r = screen.auxiliaryTopRightArea {
            notchWidth = f.width - l.width - r.width
        }
        var keepOut = CGRect(x: f.midX - notchWidth / 2 - 90, y: f.maxY - 40, width: notchWidth + 180, height: 40)

        // Window-list bounds use a top-left origin relative to the primary display.
        let primaryHeight = NSScreen.screens.first?.frame.height ?? f.height
        let screenTop = primaryHeight - f.maxY
        let ownPID = ProcessInfo.processInfo.processIdentifier
        let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
            as? [[String: Any]] ?? []
        for info in windows {
            guard let pid = info[kCGWindowOwnerPID as String] as? Int32, pid != ownPID,
                  let layer = info[kCGWindowLayer as String] as? Int,
                  layer > Int(CGWindowLevelForKey(.mainMenuWindow)), layer < Int(CGWindowLevelForKey(.screenSaverWindow)),
                  let dict = info[kCGWindowBounds as String] as? NSDictionary,
                  let b = CGRect(dictionaryRepresentation: dict),
                  abs(b.minY - screenTop) < 2, b.width < f.width * 0.8,
                  b.midX > f.minX, b.midX < f.maxX else { continue }
            keepOut = keepOut.union(CGRect(x: b.minX, y: keepOut.minY, width: b.width, height: keepOut.height))
        }
        return keepOut
    }

    private func clamp(_ value: CGFloat, centeredSpan span: CGFloat, in range: ClosedRange<CGFloat>) -> CGFloat {
        let lo = range.lowerBound + span / 2
        let hi = range.upperBound - span / 2
        return lo > hi ? (range.lowerBound + range.upperBound) / 2 : min(max(value, lo), hi)
    }

    private func attach(edge newEdge: NotchEdge, screen: NSScreen, along: CGFloat) {
        let f = screen.frame
        edge = newEdge
        alongRange = allowedRange(edge: newEdge, screen: screen, near: along)
        let collapsed = sizing.collapsed(horizontal: newEdge.isHorizontal)
        let span = newEdge.isHorizontal ? collapsed.width : collapsed.height
        let a = clamp(along, centeredSpan: span, in: alongRange)
        switch newEdge {
        case .top: attachPoint = CGPoint(x: a, y: f.maxY)
        case .bottom: attachPoint = CGPoint(x: a, y: f.minY)
        case .left: attachPoint = CGPoint(x: f.minX, y: a)
        case .right: attachPoint = CGPoint(x: f.maxX, y: a)
        }
    }

    /// Computes the target body geometry for the current state and hands it to SwiftUI.
    private func applyLayout(_ animation: Animation?, expanded: Bool? = nil) {
        let isExpanded = !isDragging && (expanded ?? model.isExpanded)
        let horizontal = edge.isHorizontal
        let size: CGSize
        let rect: CGRect
        let ear: CGFloat
        let radius: CGFloat

        if isDragging {
            size = sizing.collapsed(horizontal: horizontal)
            rect = CGRect(x: -size.width / 2, y: -size.height / 2, width: size.width, height: size.height)
            radius = min(size.width, size.height) / 2
            ear = -radius
        } else {
            size = isExpanded ? sizing.expanded(horizontal: horizontal) : sizing.collapsed(horizontal: horizontal)
            let along = horizontal ? attachPoint.x : attachPoint.y
            let span = horizontal ? size.width : size.height
            let shift = clamp(along, centeredSpan: span, in: alongRange) - along
            let w = size.width, h = size.height
            switch edge {
            case .top: rect = CGRect(x: shift - w / 2, y: -h, width: w, height: h)
            case .bottom: rect = CGRect(x: shift - w / 2, y: 0, width: w, height: h)
            case .left: rect = CGRect(x: 0, y: shift - h / 2, width: w, height: h)
            case .right: rect = CGRect(x: -w, y: shift - h / 2, width: w, height: h)
            }
            ear = (isExpanded ? 14 : 9) * sizing.scale
            radius = (isExpanded ? 32 : 14) * sizing.scale
        }
        bodyRect = rect

        let center = CGPoint(x: canvas / 2 + rect.midX, y: canvas / 2 - rect.midY)
        let update = {
            self.model.edge = self.edge
            self.model.isFloating = self.isDragging
            self.model.isExpanded = isExpanded
            self.model.bodyCenter = center
            self.model.bodySize = size
            self.model.ear = ear
            self.model.radius = radius
            self.model.sizing = self.sizing
        }
        if let animation {
            withAnimation(animation, update)
        } else {
            var t = Transaction()
            t.disablesAnimations = true
            withTransaction(t, update)
        }
    }

    // MARK: Mouse

    private func handle(_ event: NSEvent) -> NSEvent? {
        guard event.window === panel else { return event }
        let p = NSEvent.mouseLocation
        switch event.type {
        case .leftMouseDown:
            mouseDownPoint = p
            return event
        case .leftMouseDragged:
            guard let down = mouseDownPoint else { return event }
            if !isDragging {
                guard hypot(p.x - down.x, p.y - down.y) > 4 else { return event }
                beginDrag(at: p)
            }
            updateDrag(at: p)
            return nil
        case .leftMouseUp:
            mouseDownPoint = nil
            if isDragging {
                endDrag(at: p)
                return nil
            }
            if !model.isExpanded { expand() }
            return event
        default:
            return event
        }
    }

    private func beginDrag(at p: CGPoint) {
        stopSpring()
        let visual = bodyRect.offsetBy(dx: windowAnchor.x, dy: windowAnchor.y)
        isDragging = true
        insideSince = nil
        outsideSince = nil
        panel.ignoresMouseEvents = false

        // Re-centre the window on the cursor while keeping the body visually where it was,
        // then let it glide into a capsule under the cursor.
        let current = model.bodyCenter
        let offset = CGPoint(x: canvas / 2 + (visual.midX - p.x), y: canvas / 2 - (visual.midY - p.y))
        var t = Transaction()
        t.disablesAnimations = true
        withTransaction(t) { model.bodyCenter = offset }
        panel.contentView?.layoutSubtreeIfNeeded()
        panel.contentView?.displayIfNeeded()
        moveWindow(to: p)
        samples = [(CACurrentMediaTime(), p)]
        if current == offset {
            applyLayout(Anim.lift)
        } else {
            DispatchQueue.main.async { self.applyLayout(Anim.lift) }
        }
    }

    private func updateDrag(at p: CGPoint) {
        moveWindow(to: p)
        let now = CACurrentMediaTime()
        samples.append((now, p))
        samples.removeAll { now - $0.time > 0.1 }

        // Preview the orientation of whichever edge we're approaching.
        guard let screen = screen(containing: p) else { return }
        let (nearest, distance) = nearestEdge(to: p, in: screen.frame)
        if distance < 150, nearest != edge {
            let flips = nearest.isHorizontal != edge.isHorizontal
            edge = nearest
            if flips { applyLayout(Anim.lift) }
        }
    }

    private func endDrag(at p: CGPoint) {
        isDragging = false
        let v = releaseVelocity(at: p)

        // Project the throw forward like a scroll view decelerating, then pick the edge there.
        let projected = CGPoint(x: p.x + v.dx * 0.2, y: p.y + v.dy * 0.2)
        let screen = screen(containing: projected) ?? screen(containing: p) ?? NSScreen.screens.first!
        let f = screen.frame
        let q = CGPoint(x: min(max(projected.x, f.minX), f.maxX), y: min(max(projected.y, f.minY), f.maxY))
        let target = nearestEdge(to: q, in: f).edge
        attach(edge: target, screen: screen, along: target.isHorizontal ? q.x : q.y)

        springVelocity = v
        startSpring()
        applyLayout(Anim.snap, expanded: false)
        suppressHoverUntilExit = true
        savePosition(screen: screen)
    }

    private func releaseVelocity(at p: CGPoint) -> CGVector {
        let now = CACurrentMediaTime()
        guard let first = samples.first, let last = samples.last,
              now - last.time < 0.06, last.time - first.time > 0.008 else { return .zero }
        let dt = last.time - first.time
        var v = CGVector(dx: (last.point.x - first.point.x) / dt, dy: (last.point.y - first.point.y) / dt)
        let speed = hypot(v.dx, v.dy)
        let cap: CGFloat = 5000
        if speed > cap { v = CGVector(dx: v.dx / speed * cap, dy: v.dy / speed * cap) }
        return v
    }

    private func screen(containing p: CGPoint) -> NSScreen? {
        NSScreen.screens.first { $0.frame.contains(p) }
    }

    private func nearestEdge(to p: CGPoint, in f: CGRect) -> (edge: NotchEdge, distance: CGFloat) {
        let candidates: [(NotchEdge, CGFloat)] = [
            (.top, f.maxY - p.y), (.bottom, p.y - f.minY),
            (.left, p.x - f.minX), (.right, f.maxX - p.x),
        ]
        let best = candidates.min { $0.1 < $1.1 }!
        return (best.0, best.1)
    }

    // MARK: Spring

    private func startSpring() {
        didLandHaptic = false
        lastTick = CACurrentMediaTime()
        guard displayLink == nil, let view = panel.contentView else { return }
        let link = view.displayLink(target: self, selector: #selector(tick(_:)))
        link.add(to: .main, forMode: .common)
        displayLink = link
    }

    private func stopSpring() {
        displayLink?.invalidate()
        displayLink = nil
    }

    @objc private func tick(_ link: CADisplayLink) {
        let now = CACurrentMediaTime()
        let dt = min(now - lastTick, 1.0 / 30.0)
        lastTick = now

        // Slightly under-damped so the notch lands with a small, satisfying settle.
        let stiffness: CGFloat = 420
        let damping: CGFloat = 32
        var pos = windowAnchor
        let steps = 4
        let h = CGFloat(dt) / CGFloat(steps)
        for _ in 0..<steps {
            let ax = -stiffness * (pos.x - attachPoint.x) - damping * springVelocity.dx
            let ay = -stiffness * (pos.y - attachPoint.y) - damping * springVelocity.dy
            springVelocity.dx += ax * h
            springVelocity.dy += ay * h
            pos.x += springVelocity.dx * h
            pos.y += springVelocity.dy * h
        }

        let distance = hypot(pos.x - attachPoint.x, pos.y - attachPoint.y)
        if !didLandHaptic, distance < 2 {
            didLandHaptic = true
            NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
        }
        if distance < 0.3, hypot(springVelocity.dx, springVelocity.dy) < 4 {
            moveWindow(to: attachPoint)
            stopSpring()
        } else {
            windowAnchor = pos
            panel.setFrameOrigin(CGPoint(x: pos.x - canvas / 2, y: pos.y - canvas / 2))
        }
    }

    // MARK: Hover

    private func pollHover() {
        guard !isDragging, panel != nil else { return }
        let mouse = NSEvent.mouseLocation
        let rect = bodyRect.offsetBy(dx: windowAnchor.x, dy: windowAnchor.y).insetBy(dx: -2, dy: -2)
        let inside = rect.contains(mouse)
        if panel.ignoresMouseEvents == inside { panel.ignoresMouseEvents = !inside }

        if suppressHoverUntilExit {
            if !inside { suppressHoverUntilExit = false }
            return
        }
        guard !isSpringing else { return }

        let now = CACurrentMediaTime()
        if inside {
            outsideSince = nil
            guard !model.isExpanded else { return }
            if let since = insideSince {
                if now - since > 0.07 { expand() }
            } else {
                insideSince = now
            }
        } else {
            insideSince = nil
            guard model.isExpanded, !model.isPinned else { return }
            if let since = outsideSince {
                if now - since > 0.28 { collapse() }
            } else {
                outsideSince = now
            }
        }
    }

    private func expand() {
        insideSince = nil
        applyLayout(Anim.open, expanded: true)
    }

    private func collapse() {
        outsideSince = nil
        applyLayout(Anim.close, expanded: false)
    }

    #if DEBUG
    /// Replays a drag from the notch to "x,y[,steps]" (screen coordinates) through the real drag
    /// pipeline, for testing without synthetic mouse events. Post the distributed notification
    /// "CustomNotch.debugThrow" with that string as the object.
    @objc private func debugThrow(_ note: Notification) {
        guard let s = note.object as? String else { return }
        let parts = s.split(separator: ",").compactMap { Double($0) }
        guard parts.count >= 2 else { return }
        let steps = parts.count > 2 ? CGFloat(parts[2]) : 20
        let start = CGPoint(x: bodyRect.midX + windowAnchor.x, y: bodyRect.midY + windowAnchor.y)
        let end = CGPoint(x: parts[0], y: parts[1])
        beginDrag(at: start)
        var i = 0
        Timer.scheduledTimer(withTimeInterval: 0.012, repeats: true) { timer in
            MainActor.assumeIsolated {
                i += 1
                let t = min(1, CGFloat(i) / steps)
                let p = CGPoint(x: start.x + (end.x - start.x) * t, y: start.y + (end.y - start.y) * t)
                self.updateDrag(at: p)
                if t >= 1 {
                    timer.invalidate()
                    self.endDrag(at: p)
                }
            }
        }
    }

    /// "CustomNotch.debugSize" with "width,height,scale" sets the sizing; with no object it
    /// opens Notch Settings.
    @objc private func debugSize(_ note: Notification) {
        guard let s = note.object as? String else { return openSettings() }
        let v = s.split(separator: ",").compactMap { Double($0) }.map { CGFloat($0) }
        guard v.count == 3 else { return }
        settings.sizing = NotchSizing(width: v[0], height: v[1], scale: v[2])
    }

    func installDebugHooks() {
        let center = DistributedNotificationCenter.default()
        center.addObserver(self, selector: #selector(debugThrow(_:)), name: .init("CustomNotch.debugThrow"), object: nil)
        center.addObserver(self, selector: #selector(debugSize(_:)), name: .init("CustomNotch.debugSize"), object: nil)
    }
    #endif

    // MARK: Persistence

    private func savePosition(screen: NSScreen) {
        let f = screen.frame
        let fraction = edge.isHorizontal ? (attachPoint.x - f.minX) / f.width : (attachPoint.y - f.minY) / f.height
        UserDefaults.standard.set(edge.rawValue, forKey: "edge")
        UserDefaults.standard.set(Double(fraction), forKey: "fraction")
    }

    private func restorePosition() {
        guard let screen = NSScreen.screens.first else { return }
        let f = screen.frame
        let defaults = UserDefaults.standard
        // Default to the middle of the right edge, well away from the hardware notch.
        let saved = defaults.string(forKey: "edge").flatMap(NotchEdge.init(rawValue:)) ?? .right
        let fraction = defaults.object(forKey: "fraction") as? Double ?? 0.5
        let along = saved.isHorizontal ? f.minX + f.width * fraction : f.minY + f.height * fraction
        attach(edge: saved, screen: screen, along: along)
    }
}
