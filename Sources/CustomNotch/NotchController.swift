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
    /// The Terraria Companion who lives in the notch (if any), and her life here.
    let link = CompanionLink()
    private(set) lazy var home = CompanionHome(link: link, settings: settings)
    private var companionObservers: [AnyCancellable] = []
    private var hasResident = false
    private var showsRoom = false
    /// Pressed on her or a cookie in her space (where), and whether it's become a drag there.
    private var touch: (target: CompanionHome.Target, down: CGPoint)?
    private var holding = false
    /// Pulling her out: her held sprite once she's dragged out past the notch.
    private var carry: CompanionCarry?
    private lazy var settingsWindow = SettingsWindowController(settings: settings, stats: stats, link: link) { [weak self] in
        self?.resetPosition()
    }
    private lazy var detailPanel = ResourceDetailController(stats: stats)
    /// Per-edge sizes, mirrored from `settings` (its publisher fires before the value lands).
    private var sizes: [NotchEdge: NotchSizing] = [:]
    private var sizingObserver: AnyCancellable?
    /// The size for whichever edge the notch is on, or heading to while dragged.
    private var sizing: NotchSizing { sizes[edge] ?? .standard }

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
    /// Runs only while the cursor is near the notch or something is in motion; mouse-move
    /// monitors wake it, so an idle notch costs no timer wakeups.
    private var hoverTimer: Timer?
    private var moveMonitors: [Any] = []
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
        let root = NotchRootView(model: model, stats: stats, home: home, link: link)
        let host = NotchHostingView(rootView: root)
        host.frame = NSRect(x: 0, y: 0, width: canvas, height: canvas)
        panel.contentView = host
        model.openSettings = { [weak self] in self?.openSettings() }
        model.openDetail = { [weak self] kind in self?.openDetail(kind) }
        model.openInventory = { [weak self] in self?.openInventory() }
        model.spawnCookie = { [weak self] in self?.home.spawnCookie() }

        sizes = settings.sizes
        sizingObserver = settings.$sizes.removeDuplicates().dropFirst().sink { [weak self] new in
            self?.sizesChanged(to: new)
        }

        restorePosition()
        moveWindow(to: attachPoint)
        applyLayout(nil)
        panel.orderFrontRegardless()

        link.start()
        companionObservers = [
            link.$resident.map { $0 != nil }.removeDuplicates().sink { [weak self] _ in
                DispatchQueue.main.async { self?.companionChanged() }
            },
            link.$messages.map { $0.contains { !$0.read } }.removeDuplicates().sink { [weak self] _ in
                DispatchQueue.main.async { self?.companionChanged() }
            },
            link.$connected.removeDuplicates().sink { [weak self] _ in
                DispatchQueue.main.async { self?.publishGeometry() }
            },
        ]

        DispatchQueue.main.async {
            withAnimation(.spring(response: 0.6, dampingFraction: 0.72)) { self.model.isAppeared = true }
        }

        eventMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .leftMouseDragged, .leftMouseUp]) { [weak self] event in
            MainActor.assumeIsolated { self?.handle(event) ?? event }
        }
        let moves: NSEvent.EventTypeMask = [.mouseMoved, .leftMouseDragged, .rightMouseDragged]
        if let global = NSEvent.addGlobalMonitorForEvents(matching: moves, handler: { [weak self] _ in
            MainActor.assumeIsolated { self?.mouseMoved() }
        }) { moveMonitors.append(global) }
        if let local = NSEvent.addLocalMonitorForEvents(matching: moves, handler: { [weak self] event in
            MainActor.assumeIsolated { self?.mouseMoved() }
            return event
        }) { moveMonitors.append(local) }
        wakeHover()

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

    func openDetail(_ kind: ResourceKind) {
        guard let screen = NSScreen.screens.first(where: { $0.frame.insetBy(dx: -1, dy: -1).contains(attachPoint) })
            ?? NSScreen.screens.first else { return }
        // Place the panel against the opened notch, which stays open while the panel shows.
        if !model.isExpanded { expand() }
        let rect = bodyRect.offsetBy(dx: windowAnchor.x, dy: windowAnchor.y)
        detailPanel.show(kind, beside: rect, edge: edge, on: screen)
    }

    /// Her Terraria inventory, from the companion app, with her staying at home.
    func openInventory() {
        Task { await link.send("inventory") }
    }

    /// Someone moved in or out, or her unread messages changed: make room (or give it back).
    private func companionChanged() {
        let resident = link.resident != nil
        let room = resident || !link.unread.isEmpty
        guard resident != hasResident || room != showsRoom else { return }
        hasResident = resident
        showsRoom = room
        model.hasResident = resident
        model.showsRoom = room
        guard !isDragging else { return }
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
        applyLayout(Anim.open)
    }

    private func sizesChanged(to new: [NotchEdge: NotchSizing]) {
        let old = sizing
        sizes = new
        // Only the edge the notch is on affects it; other edges' presets wait until it moves there.
        guard sizing != old, !isDragging else { return }
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
        publishGeometry()
    }

    /// Tell the companion app where the notch body is (global points, top-left origin), so it can
    /// catch a companion dropped or thrown onto it.
    private func publishGeometry() {
        guard link.connected else { return }
        let rect = bodyRect.offsetBy(dx: windowAnchor.x, dy: windowAnchor.y)
        let primaryHeight = NSScreen.screens.first?.frame.height ?? rect.maxY
        let topLeft = CGRect(x: rect.minX, y: primaryHeight - rect.maxY, width: rect.width, height: rect.height)
        link.postGeometry(topLeft, edge: edge, expanded: model.isExpanded, dragging: isDragging)
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
        if settings.dockedEdge != newEdge { settings.dockedEdge = newEdge }
        alongRange = allowedRange(edge: newEdge, screen: screen, near: along)
        let collapsed = sizing.collapsed(horizontal: newEdge.isHorizontal, lane: hasResident)
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
            size = sizing.collapsed(horizontal: horizontal, lane: hasResident)
            rect = CGRect(x: -size.width / 2, y: -size.height / 2, width: size.width, height: size.height)
            radius = min(size.width, size.height) / 2
            ear = -radius
        } else {
            size = isExpanded ? sizing.expanded(horizontal: horizontal, room: showsRoom)
                : sizing.collapsed(horizontal: horizontal, lane: hasResident)
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
        // Poll system stats only while the notch is open (the detail panel keeps it open).
        stats.setLive(isExpanded)
        // Opening the notch is reading what she said: the glow goes, her bubble shows.
        if isExpanded != link.isOpen {
            link.isOpen = isExpanded
            if isExpanded { home.opened() }
        }

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
        publishGeometry()
    }

    // MARK: Mouse

    private func handle(_ event: NSEvent) -> NSEvent? {
        guard event.window === panel else { return event }
        let p = NSEvent.mouseLocation
        switch event.type {
        case .leftMouseDown:
            mouseDownPoint = p
            // A press on her or a cookie in the opened notch picks it up (or pats her, or sends
            // her for the cookie) instead of the notch; the controls over her space keep theirs.
            touchDown(at: p)
            return event
        case .leftMouseDragged:
            if let touch {
                dragTouch(touch.target, from: touch.down, to: p)
                return nil
            }
            guard let down = mouseDownPoint else { return event }
            if !isDragging {
                guard hypot(p.x - down.x, p.y - down.y) > 4 else { return event }
                beginDrag(at: p)
            }
            updateDrag(at: p)
            return nil
        case .leftMouseUp:
            mouseDownPoint = nil
            if let t = touch {
                touch = nil
                endTouch(t.target, at: p)
                return nil
            }
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
        detailPanel.close()
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
            // Morph into the destination edge's saved size and orientation on the way there.
            edge = nearest
            applyLayout(Anim.lift)
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
        wakeHover()
        savePosition(screen: screen)
    }

    // MARK: Companion

    /// A screen point (y-up) in the notch window's top-left coordinates, where SwiftUI lays out.
    private func windowPoint(_ p: CGPoint) -> CGPoint {
        let origin = panel.frame.origin
        return CGPoint(x: p.x - origin.x, y: canvas - (p.y - origin.y))
    }

    private func touchDown(at p: CGPoint) {
        touch = nil
        holding = false
        guard model.isExpanded else { return }
        let target = home.target(at: windowPoint(p))
        if target != .none, target != .control { touch = (target, p) }
    }

    /// Dragging her or a cookie: around her space, and her out of the notch past its edge (back
    /// in again if you change your mind).
    private func dragTouch(_ target: CompanionHome.Target, from down: CGPoint, to p: CGPoint) {
        if !holding {
            guard hypot(p.x - down.x, p.y - down.y) > 4 else { return }
            holding = true
            samples = [(CACurrentMediaTime(), p)]
            home.grab(target, at: windowPoint(down))
            NSCursor.closedHand.push()
        }
        let now = CACurrentMediaTime()
        samples.append((now, p))
        samples.removeAll { now - $0.time > 0.1 }
        guard target == .her else {
            home.drag(to: windowPoint(p))
            return
        }
        let outside = !hoverRect.insetBy(dx: -10, dy: -10).contains(p)
        if outside, carry == nil {
            beginCarry(at: p)
        } else if !outside, let c = carry {
            // Back over the notch: she's in her space again, still in your hand.
            carry = nil
            c.vanish()
            home.sim.carried = false
            home.grab(.her, at: windowPoint(p))
        }
        if carry != nil { updateCarry(at: p) } else { home.drag(to: windowPoint(p)) }
    }

    private func endTouch(_ target: CompanionHome.Target, at p: CGPoint) {
        defer { holding = false }
        guard holding else {
            // A click.
            switch target {
            case .her: pet()
            case .cookie(let id): home.tap(cookie: id)
            default: break
            }
            return
        }
        NSCursor.pop()
        if carry != nil {
            endCarry(at: p)
        } else {
            home.release(velocity: releaseVelocity(at: p))
        }
        wakeHover()
    }

    private func pet() {
        home.petted()
        Task { await link.send("pet") }
    }

    private func beginCarry(at p: CGPoint) {
        guard let atlas = link.atlas else { return }
        detailPanel.close()
        home.release(velocity: .zero)
        home.sim.carried = true
        let roomScale = atlas.scale(forBodyHeight: edge.isHorizontal ? 40 : 44) * sizing.scale
        let c = CompanionCarry(atlas: atlas, roomScale: roomScale)
        carry = c
        panel.ignoresMouseEvents = false
        c.show(at: p)
    }

    private func updateCarry(at p: CGPoint) {
        let now = CACurrentMediaTime()
        samples.append((now, p))
        samples.removeAll { now - $0.time > 0.1 }
        let v: CGVector
        if let first = samples.first, let last = samples.last, last.time - first.time > 0.008 {
            let dt = last.time - first.time
            v = CGVector(dx: (last.point.x - first.point.x) / dt, dy: (last.point.y - first.point.y) / dt)
        } else {
            v = .zero
        }
        carry?.move(to: p, velocity: v)
    }

    /// Let go: outside the notch she goes back to the desktop right there, keeping the throw;
    /// over the notch (or with no companion app to take her) she drops back into her room.
    private func endCarry(at p: CGPoint) {
        guard let c = carry else { return }
        carry = nil
        let v = releaseVelocity(at: p)
        let home = self.home
        let back = CGPoint(x: bodyRect.midX + windowAnchor.x, y: bodyRect.midY + windowAnchor.y)
        let stayIn = {
            c.retreat(to: back) {
                home.sim.carried = false
                home.sim.play("happy")
            }
        }
        suppressHoverUntilExit = false
        wakeHover()
        if hoverRect.insetBy(dx: -8, dy: -8).contains(p) {
            stayIn()
            return
        }
        let primaryHeight = NSScreen.screens.first?.frame.height ?? p.y
        let global = CGPoint(x: p.x, y: primaryHeight - p.y)
        Task {
            if await link.send("exit", at: global, velocity: CGVector(dx: v.dx, dy: -v.dy)) {
                c.handOff()
            } else {
                stayIn()
            }
        }
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
            wakeHover()
        } else {
            windowAnchor = pos
            panel.setFrameOrigin(CGPoint(x: pos.x - canvas / 2, y: pos.y - canvas / 2))
        }
    }

    // MARK: Hover

    private var hoverRect: CGRect {
        bodyRect.offsetBy(dx: windowAnchor.x, dy: windowAnchor.y).insetBy(dx: -2, dy: -2)
    }

    private func mouseMoved() {
        // Only bother when the cursor comes near the notch or the notch needs watching.
        if hoverTimer == nil, !needsHoverTimer { return }
        wakeHover()
    }

    private var needsHoverTimer: Bool {
        model.isExpanded || isDragging || carry != nil || isSpringing || insideSince != nil || outsideSince != nil
            || suppressHoverUntilExit || hoverRect.insetBy(dx: -60, dy: -60).contains(NSEvent.mouseLocation)
    }

    private func wakeHover() {
        pollHover()
        guard hoverTimer == nil else { return }
        let timer = Timer(timeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.pollHover()
                if !self.needsHoverTimer {
                    self.hoverTimer?.invalidate()
                    self.hoverTimer = nil
                }
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        hoverTimer = timer
    }

    private func pollHover() {
        guard !isDragging, carry == nil, !holding, panel != nil else { return }
        let inside = hoverRect.contains(NSEvent.mouseLocation)
        if panel.ignoresMouseEvents == inside { panel.ignoresMouseEvents = !inside }

        if suppressHoverUntilExit {
            if !inside { suppressHoverUntilExit = false }
            return
        }
        guard !isSpringing else { return }

        // She notices the pointer over her space (and a long touch).
        home.hover(model.isExpanded && inside ? windowPoint(NSEvent.mouseLocation) : nil)

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
            guard model.isExpanded, !model.isPinned, !detailPanel.isVisible else { return }
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
        settings.setSizing(NotchSizing(width: v[0], height: v[1], scale: v[2]), for: edge)
    }

    func installDebugHooks() {
        let center = DistributedNotificationCenter.default()
        center.addObserver(self, selector: #selector(debugThrow(_:)), name: .init("CustomNotch.debugThrow"), object: nil)
        center.addObserver(self, selector: #selector(debugSize(_:)), name: .init("CustomNotch.debugSize"), object: nil)
        center.addObserver(self, selector: #selector(debugDetail(_:)), name: .init("CustomNotch.debugDetail"), object: nil)
        center.addObserver(self, selector: #selector(debugCompanion(_:)), name: .init("CustomNotch.debugCompanion"), object: nil)
    }

    /// "CustomNotch.debugCompanion": "open" / "close" the notch, "pin", "pet" or "inventory" the
    /// resident, or "carry x,y[,steps]" to pick her up in the room and drag her to that screen
    /// point (global, y-up) through the real carry pipeline.
    @objc private func debugCompanion(_ note: Notification) {
        guard let s = note.object as? String else { return }
        let parts = s.split(separator: " ", maxSplits: 1).map(String.init)
        switch parts.first {
        case "open": expand()
        case "close": model.isPinned = false; collapse()
        case "pin": model.isPinned.toggle()
        case "pet": pet()
        case "inventory": openInventory()
        case "cookie": home.spawnCookie()
        case "fetch":
            if let c = home.sim.cookies.first { home.tap(cookie: c.id) }
        case "dismiss":
            if let id = home.shownMessage { home.dismissMessage(id) }
        case "toss":
            // "toss fx,fy,vx,vy": pick her up, carry her to that fraction of her space and let go
            // moving at vx,vy (screen points/s, y-up).
            guard parts.count > 1, let space = home.space, let rect = home.spriteRect else { return }
            let v = parts[1].split(separator: ",").compactMap { Double($0) }.map { CGFloat($0) }
            guard v.count >= 2 else { return }
            home.grab(.her, at: CGPoint(x: rect.midX, y: rect.midY))
            home.drag(to: CGPoint(x: space.frame.minX + space.frame.width * v[0], y: space.frame.minY + space.frame.height * v[1]))
            home.release(velocity: CGVector(dx: v.count > 2 ? v[2] : 0, dy: v.count > 3 ? v[3] : 0))
        case "feed":
            // Drag the first cookie onto her and drop it.
            guard let c = home.sim.cookies.first, let space = home.space, let rect = home.spriteRect else { return }
            let r = home.sim.cookieRect(c)
            home.grab(.cookie(c.id), at: CGPoint(x: space.frame.minX + r.midX * space.scale, y: space.frame.minY + r.midY * space.scale))
            home.drag(to: CGPoint(x: rect.midX, y: rect.minY + rect.height * 0.3))
            home.release(velocity: .zero)
        case "mouse":
            // "mouse fx,fy fx2,fy2[,steps]": press at that fraction of her space ("her" or "cookie"
            // for where they are), drag to the second (fractions past 0…1 leave the space) and let
            // go, through the real mouse handling. Steps 0 is a click.
            guard parts.count > 1, let space = home.space else { return }
            var words = parts[1]
            let local: CGRect? = words.hasPrefix("her") ? home.sim.body
                : words.hasPrefix("cookie") ? home.sim.cookies.first.map { home.sim.cookieRect($0) } : nil
            if let local {
                words = "\(local.midX / space.size.width),\(local.midY / space.size.height)" + words.drop { $0 != " " }
            }
            let v = words.split(whereSeparator: { $0 == " " || $0 == "," }).compactMap { Double($0) }.map { CGFloat($0) }
            guard v.count >= 4 else { return }
            let screen = { (fx: CGFloat, fy: CGFloat) -> CGPoint in
                let w = CGPoint(x: space.frame.minX + space.frame.width * fx, y: space.frame.minY + space.frame.height * fy)
                return CGPoint(x: self.panel.frame.minX + w.x, y: self.panel.frame.minY + self.canvas - w.y)
            }
            let start = screen(v[0], v[1]), end = screen(v[2], v[3])
            let steps = v.count > 4 ? v[4] : 20
            touchDown(at: start)
            guard let t = touch else { return }
            var i = 0
            Timer.scheduledTimer(withTimeInterval: 0.016, repeats: true) { timer in
                MainActor.assumeIsolated {
                    i += 1
                    let k = min(1, CGFloat(i) / steps)
                    let p = CGPoint(x: start.x + (end.x - start.x) * k, y: start.y + (end.y - start.y) * k)
                    if steps > 0 { self.dragTouch(t.target, from: start, to: p) }
                    if k >= 1 {
                        timer.invalidate()
                        self.touch = nil
                        self.endTouch(t.target, at: p)
                    }
                }
            }
        case "carry":
            guard parts.count > 1, let rect = home.spriteRect else { return }
            let v = parts[1].split(separator: ",").compactMap { Double($0) }
            guard v.count >= 2 else { return }
            let steps = v.count > 2 ? CGFloat(v[2]) : 24
            // The sprite's centre, from window (top-left) to screen (y-up) points.
            let origin = panel.frame.origin
            let start = CGPoint(x: origin.x + rect.midX, y: origin.y + canvas - rect.midY)
            let end = CGPoint(x: v[0], y: v[1])
            beginCarry(at: start)
            var i = 0
            Timer.scheduledTimer(withTimeInterval: 0.016, repeats: true) { timer in
                MainActor.assumeIsolated {
                    i += 1
                    let t = min(1, CGFloat(i) / steps)
                    let p = CGPoint(x: start.x + (end.x - start.x) * t, y: start.y + (end.y - start.y) * t)
                    self.updateCarry(at: p)
                    if t >= 1 {
                        timer.invalidate()
                        self.endCarry(at: p)
                    }
                }
            }
        default: break
        }
    }

    /// "CustomNotch.debugDetail" with "cpu", "memory" or "battery" opens the notch and that panel.
    @objc private func debugDetail(_ note: Notification) {
        guard let kind = (note.object as? String).flatMap(ResourceKind.init(rawValue:)) else { return detailPanel.close() }
        openDetail(kind)
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
