import Combine
import SwiftUI

/// The resident companion's life in the notch: her behaviour, what's showing in her space, the
/// cookies lying about, and the pieces the controller needs to let you touch them (where she and
/// they are, and where the controls are, so those always get their clicks).
@MainActor
final class CompanionHome: ObservableObject {
    let link: CompanionLink
    let settings: NotchSettings
    let sim = CompanionSim()
    /// Bumped when someone moves in (the notch gulps her down).
    @Published private(set) var gulp = 0
    /// Bumped for a burst of hearts around her.
    @Published private(set) var hearts = 0
    /// The message the card shows.
    @Published var shownMessage: String?
    /// Her space in the notch window, while it's on screen.
    var space: Space?
    private var lastCookie = Date.distantPast
    private var bag = Set<AnyCancellable>()

    /// The opened notch's open area she lives in: where it is in the window (top-left points,
    /// as drawn, so scaled), its layout size, and the controls laid over it.
    struct Space {
        var frame: CGRect
        var size: CGSize
        var controls: [CGRect]

        var scale: CGFloat { frame.width / max(1, size.width) }

        func local(_ window: CGPoint) -> CGPoint {
            CGPoint(x: (window.x - frame.minX) / scale, y: (window.y - frame.minY) / scale)
        }
    }

    /// What's under the pointer in her space.
    enum Target: Equatable {
        case control, her, cookie(Int), none
    }

    init(link: CompanionLink, settings: NotchSettings) {
        self.link = link
        self.settings = settings
        sim.onEat = { [weak self] in
            Task { await self?.link.send("feed") }
        }
        link.gestures.sink { [weak self] kind in
            guard let self else { return }
            if kind == "hearts" { hearts += 1 }
            sim.play(kind)
        }.store(in: &bag)
        link.arrivals.sink { [weak self] in
            guard let self else { return }
            sim.arrive()
            gulp += 1
        }.store(in: &bag)
        // A new resident starts in the middle, and the old one's cookies go with her.
        link.$resident.map(\.?.character).removeDuplicates().sink { [weak self] _ in
            self?.sim.reset()
        }.store(in: &bag)
        link.$messages.sink { [weak self] messages in
            guard let self else { return }
            // Keep the card on a message that still exists, preferring the oldest unread one.
            if let id = shownMessage, messages.contains(where: { $0.id == id }) {
                if link.isOpen || messages.first(where: { !$0.read }) == nil { return }
            }
            shownMessage = messages.first(where: { !$0.read })?.id ?? messages.last?.id
        }.store(in: &bag)
        // Read messages fade away after a while (Notch Settings › Companion).
        Timer.publish(every: 30, on: .main, in: .common).autoconnect().sink { [weak self] _ in
            self?.expireMessages()
        }.store(in: &bag)
        expireMessages()
    }

    private func expireMessages() {
        link.expireRead(after: settings.messageLifetime.seconds)
    }

    /// The notch opened: she turns to greet you, the card shows the oldest unread message, and
    /// now and then there's a cookie waiting.
    func opened() {
        if let first = link.unread.first { shownMessage = first.id }
        expireMessages()
        sim.greet()
        let chance = settings.cookieFrequency.chance
        if link.resident != nil, sim.cookies.isEmpty, Date().timeIntervalSince(lastCookie) > 90,
           Double.random(in: 0..<1) < chance {
            lastCookie = Date()
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(450)) // once the notch has opened
                self.sim.spawnCookie()
            }
        }
    }

    /// The cookie button: one drops in.
    func spawnCookie() {
        guard link.resident != nil else { return }
        lastCookie = Date()
        sim.spawnCookie()
    }

    /// A pat from you.
    func petted() {
        hearts += 1
        sim.play("happy")
    }

    func dismissMessage(_ id: String) {
        let messages = link.messages
        if shownMessage == id, let i = messages.firstIndex(where: { $0.id == id }) {
            // Show the next one along (or the one before, at the end).
            let rest = messages.enumerated().filter { $0.offset != i }.map(\.element)
            shownMessage = rest.first(where: { !$0.read })?.id ?? (i < rest.count ? rest[i].id : rest.last?.id)
        }
        link.dismiss(id)
    }

    // MARK: Touching

    func target(at window: CGPoint) -> Target {
        guard link.resident != nil, let space else { return .none }
        let p = space.local(window)
        guard CGRect(origin: .zero, size: space.size).insetBy(dx: -4, dy: -4).contains(p) else { return .none }
        if space.controls.contains(where: { $0.contains(p) }) { return .control }
        if let id = sim.cookie(at: p) { return .cookie(id) }
        if let body = sim.body, !sim.carried, body.insetBy(dx: -6, dy: -4).contains(p) { return .her }
        return .none
    }

    /// Start dragging her or a cookie from `window`.
    func grab(_ target: Target, at window: CGPoint) {
        guard let space else { return }
        let p = space.local(window)
        switch target {
        case .her: sim.hold(at: p)
        case .cookie(let id): sim.holdCookie(id, at: p)
        default: break
        }
    }

    func drag(to window: CGPoint) {
        guard let space else { return }
        let p = space.local(window)
        let clamped = CGPoint(x: min(max(p.x, 0), space.size.width), y: min(max(p.y, 0), space.size.height))
        sim.moveHeld(to: clamped)
    }

    /// Let go, moving at `velocity` (screen points per second, y-up).
    func release(velocity v: CGVector) {
        let k = space?.scale ?? 1
        sim.release(vx: v.dx / k, vy: v.dy / k)
    }

    /// A click on a cookie: she goes and eats it.
    func tap(cookie id: Int) {
        sim.fetch(id)
    }

    /// Where the pointer is over her space (nil when it isn't).
    func hover(_ window: CGPoint?) {
        guard let window, let space else { sim.pointer = nil; return }
        let p = space.local(window)
        sim.pointer = CGRect(origin: .zero, size: space.size).contains(p) ? p : nil
    }

    /// Where she's drawn (window points), for picking her up from outside her space.
    var spriteRect: CGRect? {
        guard let space, let b = sim.body else { return nil }
        let k = space.scale
        return CGRect(x: space.frame.minX + b.minX * k, y: space.frame.minY + b.minY * k, width: b.width * k, height: b.height * k)
    }
}

// MARK: - Behaviour

/// Her little life: wander, idle, turn around, look about, sit, nap, play the gestures and
/// expressions the companion app sends, fall and bounce when dropped, and eat the cookies she's
/// given. Pure state, stepped by the views' clock. Positions along the floor are fractions of the
/// width (so she keeps her place between the closed lane and the opened space); heights are points.
@MainActor
final class CompanionSim {
    struct Pose {
        var x: CGFloat
        /// Feet above the floor, in points.
        var alt: CGFloat
        var frame: String
        var flip: Bool
        var squash: CGFloat
        /// Tilt while she's held, degrees.
        var sway: Double
        var napping: Bool
        var hidden: Bool
    }

    struct Cookie: Identifiable {
        let id: Int
        var x: Double
        var alt: Double
        var vx: Double = 0
        var vy: Double = 0
        var held = false
        /// Thrown by you (and still flying): it can land in her mouth.
        var thrown = false
        /// Seconds the held cookie has been over her.
        var hover: Double = 0
        /// Eating progress (s), or nil.
        var eating: Double?
        var born: Double
        var landed: Double?
        var spin: Double = 0
    }

    private enum Mode {
        case idle(until: Double)
        case walk(to: Double, cookie: Int?)
        case gesture(String, until: Double)
        case listen(until: Double)
        case look(until: Double)
        case nap(until: Double)
        case eat(until: Double)
    }

    static let gravity = 1400.0
    static let cookieSize: CGFloat = 14
    static let eatTime = 1.2
    static let cookieLife = 75.0
    static let maxCookies = 3

    private(set) var x = 0.5
    private var alt = 0.0
    private var vx = 0.0
    private var vy = 0.0
    private var facing: Double = 1
    private var mode: Mode = .idle(until: 0)
    private var walked: Double = 0
    private var landAt: Double = -10
    private(set) var clock: Double = 0
    private var last: Date?
    private(set) var held = false
    private var grip = CGPoint.zero
    private var heldSway: Double = 0
    /// She's out in the carry window (being pulled out of the notch).
    var carried = false
    /// The pointer over her space (space points), for her to notice it.
    var pointer: CGPoint?
    private var touchedFor: Double = 0
    private var lastShy: Double = -10
    /// What the companion app asked for, waiting for the next step to start it.
    private var queued: String?
    private(set) var cookies: [Cookie] = []
    private var nextCookie = 0
    private var cookieHeld: Int?
    /// Her body in the opened space (space points), from its last step.
    private(set) var body: CGRect?
    private var space: CGSize = .zero
    private var floorY: CGFloat = 0
    /// The highest anything may go in the space (the message card's bottom, when it's up).
    private var topY: CGFloat = 0
    private var scale: CGFloat = 2
    /// Right-hand stretch kept for the inventory button (fraction of the width): she doesn't
    /// wander into it or leave cookies there.
    private var reserved = 0.0
    /// She started eating (the companion app feeds her).
    var onEat: () -> Void = {}

    func reset() {
        x = 0.5
        alt = 0
        vx = 0
        vy = 0
        mode = .idle(until: clock + 1)
        queued = nil
        carried = false
        held = false
        cookies.removeAll()
        cookieHeld = nil
    }

    /// Moving in: she drops in from above and lands with a bounce.
    func arrive() {
        alt = 70
        vy = 0
        vx = 0
        mode = .idle(until: clock + 0.6)
        queued = "wave"
    }

    func greet() {
        if case .nap = mode { mode = .idle(until: clock) } // woken up
        queued = queued ?? "wave"
    }

    func play(_ kind: String) {
        queued = kind
    }

    // MARK: Held

    func hold(at p: CGPoint) {
        held = true
        vx = 0
        vy = 0
        if case .nap = mode { mode = .idle(until: clock) }
        let feet = CGPoint(x: CGFloat(x) * space.width, y: floorY - CGFloat(alt))
        grip = CGPoint(x: feet.x - p.x, y: feet.y - p.y)
    }

    func holdCookie(_ id: Int, at p: CGPoint) {
        guard let i = cookies.firstIndex(where: { $0.id == id }), cookies[i].eating == nil else { return }
        cookieHeld = id
        cookies[i].held = true
        cookies[i].vx = 0
        cookies[i].vy = 0
        cookies[i].hover = 0
        cookies[i].landed = nil
        moveHeld(to: p)
    }

    /// Follow the pointer (space points).
    func moveHeld(to p: CGPoint) {
        guard space.width > 0 else { return }
        if held {
            let feet = CGPoint(x: p.x + grip.x, y: p.y + grip.y)
            let nx = Double(feet.x / space.width)
            heldSway = max(-24, min(24, (nx - x) * Double(space.width) * -2.5))
            x = min(max(nx, 0.02), 0.98)
            alt = Double(max(0, min(floorY - feet.y, floorY - topY - bodyHeight)))
        } else if let id = cookieHeld, let i = cookies.firstIndex(where: { $0.id == id }) {
            let s = Self.cookieSize
            cookies[i].x = Double(min(max(p.x, s / 2), space.width - s / 2) / space.width)
            cookies[i].alt = Double(max(0, min(floorY - p.y - s / 2, floorY - topY - s)))
        }
    }

    /// Let go, moving at (vx, vy) points per second (y up).
    func release(vx rvx: Double, vy rvy: Double) {
        let cap = 1600.0
        if held {
            held = false
            heldSway = 0
            vx = max(-cap, min(cap, rvx))
            vy = max(-cap, min(cap, rvy))
            mode = .idle(until: clock + 0.8)
        } else if let id = cookieHeld, let i = cookies.firstIndex(where: { $0.id == id }) {
            cookieHeld = nil
            cookies[i].held = false
            cookies[i].vx = max(-cap, min(cap, rvx))
            cookies[i].vy = max(-cap, min(cap, rvy))
            cookies[i].thrown = true
            // Dropped on her: she eats it.
            if overHer(cookies[i]) { eat(i) }
        }
    }

    /// Go and eat the cookie `id`.
    func fetch(_ id: Int) {
        guard let c = cookies.first(where: { $0.id == id }), c.eating == nil, !held else { return }
        if case .eat = mode { return }
        mode = .walk(to: c.x, cookie: id)
    }

    // MARK: Cookies

    func spawnCookie() {
        guard space.width > 0 else { return }
        if cookies.count >= Self.maxCookies { cookies.removeFirst() }
        // Somewhere along the floor, clear of her and the inventory button.
        let margin = Double(Self.cookieSize / space.width) + 0.04
        let hi = max(margin + 0.05, 1 - margin - reserved)
        var spot = Double.random(in: margin...hi)
        for _ in 0..<12 where abs(spot - x) * Double(space.width) < 60 { spot = Double.random(in: margin...hi) }
        nextCookie += 1
        cookies.append(Cookie(id: nextCookie, x: spot, alt: Double(max(30, floorY - topY - Self.cookieSize - 2)),
                              vx: Double.random(in: -30...30), vy: 40, born: clock, spin: Double.random(in: 0..<360)))
    }

    func cookie(at p: CGPoint) -> Int? {
        cookies.last { c in c.eating == nil && cookieRect(c).insetBy(dx: -6, dy: -6).contains(p) }?.id
    }

    func cookieRect(_ c: Cookie) -> CGRect {
        let s = Self.cookieSize
        return CGRect(x: CGFloat(c.x) * space.width - s / 2, y: floorY - CGFloat(c.alt) - s, width: s, height: s)
    }

    /// Where she takes a bite (space points).
    var mouth: CGPoint? {
        guard let b = body else { return nil }
        return CGPoint(x: b.midX + CGFloat(facing) * b.width * 0.3, y: b.minY + b.height * 0.24)
    }

    private var bodyHeight: CGFloat { body?.height ?? 40 }

    private func overHer(_ c: Cookie) -> Bool {
        guard let b = body else { return false }
        // Generous, like the desktop cookie: her face and body.
        let target = CGRect(x: b.minX - 6, y: b.minY - 6, width: b.width + 12, height: b.height * 0.8 + 6)
        return cookieRect(c).intersects(target)
    }

    private func eat(_ i: Int) {
        guard cookies[i].eating == nil, !carried else { return }
        cookies[i].eating = 0
        cookies[i].held = false
        if cookieHeld == cookies[i].id { cookieHeld = nil }
        facing = cookies[i].x >= x ? 1 : -1
        mode = .eat(until: clock + Self.eatTime)
        onEat()
    }

    private func stepCookies(_ dt: Double) {
        let w = Double(max(1, space.width))
        let half = Double(Self.cookieSize) / 2 / w
        for i in cookies.indices.reversed() {
            var c = cookies[i]
            if let e = c.eating {
                c.eating = e + dt
                if e + dt >= Self.eatTime { cookies.remove(at: i); continue }
            } else if c.held {
                c.hover = overHer(c) ? c.hover + dt : 0
                cookies[i] = c
                if c.hover >= 0.35 { eat(i) }
                continue
            } else {
                if c.alt > 0 || c.vy != 0 {
                    c.vy -= Self.gravity * dt
                    c.alt += c.vy * dt
                    c.spin += c.vx * dt * 3
                    let ceiling = Double(floorY - topY - Self.cookieSize)
                    if c.alt > ceiling { c.alt = ceiling; c.vy = min(c.vy, 0) }
                    if c.alt <= 0 {
                        c.alt = 0
                        c.vy = c.vy < -180 ? -c.vy * 0.35 : 0
                        if c.vy == 0 { c.landed = c.landed ?? clock; c.thrown = false }
                    }
                } else {
                    c.vx *= exp(-9 * dt)
                    if abs(c.vx) > 1 { c.spin += c.vx * dt * 6 }
                }
                c.x += c.vx * dt / w
                if c.x < half || c.x > 1 - half {
                    c.x = min(max(c.x, half), 1 - half)
                    c.vx = -c.vx * 0.5
                }
                // A cookie thrown at her lands in her mouth.
                if c.thrown, abs(c.vx) + abs(c.vy) > 120, overHer(c) {
                    cookies[i] = c
                    eat(i)
                    continue
                }
                if let landed = c.landed, clock - landed > Self.cookieLife { cookies.remove(at: i); continue }
            }
            cookies[i] = c
        }
    }

    /// 0…1 as a resting cookie is about to go (it shrinks away), else 1.
    func fade(_ c: Cookie) -> Double {
        guard let landed = c.landed, !c.held, c.eating == nil else { return 1 }
        return min(1, max(0, (Self.cookieLife - (clock - landed)) / 0.6))
    }

    // MARK: Stepping

    /// Advance to `date` in the opened space (`size` points, floor `floor` points from its top,
    /// nothing above `top`, `reserved` of its width kept for the inventory button) where she's
    /// drawn at `scale`.
    func stepSpace(to date: Date, size: CGSize, floor: CGFloat, top: CGFloat, reserved: Double, scale s: CGFloat,
                   bodySize: CGSize, walkFrames: Int, stride: Double, listening: Bool, gestures: [String]) -> Pose {
        space = size
        floorY = floor
        topY = top
        self.reserved = reserved
        scale = s
        let pose = step(to: date, width: size.width, bodySize: bodySize, ceiling: max(0, floor - top - bodySize.height * s),
                        walkFrames: walkFrames, stride: stride, roomy: true, listening: listening, gestures: gestures)
        let feet = CGPoint(x: pose.x, y: floor - pose.alt)
        body = pose.hidden ? nil : CGRect(x: feet.x - bodySize.width * s / 2, y: feet.y - bodySize.height * s,
                                         width: bodySize.width * s, height: bodySize.height * s)
        return pose
    }

    /// Advance to `date` in the closed notch's lane, `width` points wide with `headroom` above
    /// her head (higher hops are drawn lower there).
    func stepLane(to date: Date, width: CGFloat, scale s: CGFloat, bodySize: CGSize, headroom: CGFloat,
                  walkFrames: Int, stride: Double, listening: Bool, gestures: [String]) -> Pose {
        var pose = step(to: date, width: width, bodySize: bodySize, ceiling: .infinity, walkFrames: walkFrames,
                        stride: stride, roomy: false, listening: listening, gestures: gestures)
        pose.alt = min(pose.alt * 0.4, headroom)
        return pose
    }

    private func step(to date: Date, width: CGFloat, bodySize: CGSize, ceiling: CGFloat, walkFrames: Int,
                      stride: Double, roomy: Bool, listening: Bool, gestures: [String]) -> Pose {
        let dt = min(0.1, max(0, last.map { date.timeIntervalSince($0) } ?? 0))
        last = date
        clock += dt
        let w = max(1, Double(width))
        let margin = min(0.45, (Double(bodySize.width * scale) / 2 + 6) / w)
        if roomy { stepCookies(dt) }

        // Up in the air: falling, flying from a throw, or hopping.
        let airborne = !held && (alt > 0 || vy != 0)
        if airborne {
            vy -= Self.gravity * dt
            alt += vy * dt
            x += vx * dt / w
            if x < margin || x > 1 - margin {
                x = min(max(x, margin), 1 - margin)
                vx = -vx * 0.4
                facing = vx >= 0 ? 1 : -1
            }
            if alt > Double(ceiling) { alt = Double(ceiling); vy = min(vy, 0) }
            if alt <= 0 {
                alt = 0
                let impact = -vy
                vy = impact > 380 ? impact * 0.28 : 0
                if impact > 120 { landAt = clock }
            }
        } else if !held {
            x = min(max(x, margin), 1 - margin)
            if abs(vx) > 1 {
                x += vx * dt / w
                vx *= exp(-12 * dt)
            } else {
                vx = 0
            }
        }

        if let q = queued, !held, !airborne {
            queued = nil
            start(q, gestures: gestures)
        }
        if listening, case .idle = mode {
            mode = .listen(until: clock + 0.5)
        }
        notice(dt: dt, width: CGFloat(w))

        var frame = "idle"
        var napping = false
        switch mode {
        case .idle(let until):
            if clock >= until, !held { decide(margin: margin, roomy: roomy, gestures: gestures) }
        case .listen(let until):
            if !listening && clock >= until { mode = .idle(until: clock + 0.8) }
        case .look(let until):
            // Glancing one way, then the other.
            facing = Int(clock / 1.1) % 2 == 0 ? 1 : -1
            if clock >= until { mode = .idle(until: clock + 1) }
        case .nap(let until):
            frame = "nap"
            napping = true
            if clock >= until || held { mode = .idle(until: clock + 1.5) }
        case .eat(let until):
            frame = "idle"
            if clock >= until { mode = .idle(until: clock + Double.random(in: 1...2)) }
        case .walk(let target, let cookie):
            if listening && cookie == nil {
                mode = .listen(until: clock + 0.5)
                break
            }
            if held || airborne { break }
            var goal = target
            if let cookie {
                guard let c = cookies.first(where: { $0.id == cookie }), c.eating == nil, !c.held else {
                    mode = .idle(until: clock + 1)
                    break
                }
                goal = c.x
            }
            goal = min(max(goal, margin), 1 - margin)
            let speed = (cookie == nil ? 26 : 70) * Double(scale) / w // art px per second, as a fraction
            let dir: Double = goal > x ? 1 : -1
            facing = dir
            let reach = cookie == nil ? 0.002 : Double(bodySize.width * scale) * 0.45 / w
            let stepX = min(max(0, abs(goal - x) - reach * 0.5), speed * dt)
            x += dir * stepX
            walked += stepX * w / Double(scale)
            if abs(goal - x) <= reach {
                if let cookie, let i = cookies.firstIndex(where: { $0.id == cookie }) {
                    eat(i)
                } else {
                    mode = .idle(until: clock + Double.random(in: 1.2...3.5))
                }
            } else if walkFrames > 0 {
                frame = "walk\(Int(walked * stride / 6) % walkFrames)"
            }
        case .gesture(let kind, let until):
            switch kind {
            case "wave": frame = Int(clock * 4) % 2 == 0 ? "wave1" : "wave2"
            case "hug", "sit", "shy", "happy": frame = kind
            default: frame = "idle"
            }
            if clock >= until { mode = .idle(until: clock + Double.random(in: 1...2.5)) }
        }
        if held {
            frame = "fall"
        } else if alt > 0 {
            frame = vy > 0 ? "jump" : "fall"
        }

        let landing = clock - landAt
        let squash = landing < 0.22 ? 1 - 0.18 * sin(landing / 0.22 * .pi) : 1
        return Pose(x: CGFloat(x) * width, alt: CGFloat(alt), frame: frame, flip: facing < 0,
                    squash: CGFloat(squash), sway: held ? heldSway : 0, napping: napping, hidden: carried)
    }

    /// The pointer near her: she looks at it, and a long touch makes her shy (or wakes her).
    private func notice(dt: Double, width: CGFloat) {
        guard let p = pointer, !held, let b = body else { touchedFor = 0; return }
        let near = abs(p.x - b.midX) < 90
        let touching = b.insetBy(dx: -4, dy: -4).contains(p)
        touchedFor = touching ? touchedFor + dt : 0
        switch mode {
        case .idle, .listen:
            if near { facing = p.x >= b.midX ? 1 : -1 }
        case .nap:
            if touchedFor > 0.6 { mode = .idle(until: clock + 0.5); queued = "wave" }
        default:
            break
        }
        if touchedFor > 1.1, clock - lastShy > 8 {
            lastShy = clock
            queued = "shy"
        }
    }

    private func start(_ kind: String, gestures: [String]) {
        switch kind {
        case "jump":
            vy = 330
            alt = max(alt, 0.01)
            mode = .idle(until: clock + 0.8)
        case "happy", "hearts":
            vy = 230
            alt = max(alt, 0.01)
            mode = .gesture("happy", until: clock + 1.6)
        case "wave", "hug", "sit", "shy":
            mode = .gesture(kind, until: clock + (kind == "sit" ? 3 : 1.8))
        default:
            mode = .gesture("wave", until: clock + 1.6)
        }
    }

    private func decide(margin: Double, roomy: Bool, gestures: [String]) {
        let roll = Double.random(in: 0..<1)
        let far = max(margin, 1 - margin - (roomy ? reserved : 0))
        if roll < 0.16 {
            // Turn around and look the other way.
            facing = -facing
            mode = .idle(until: clock + Double.random(in: 1.5...3.5))
        } else if roll < 0.52 {
            mode = .walk(to: Double.random(in: margin...max(margin, far)), cookie: nil)
        } else if roll < 0.62 {
            mode = .look(until: clock + Double.random(in: 2.5...4.5))
        } else if roll < 0.7 {
            // A little hop for no reason.
            vy = 260
            alt = 0.01
            vx = Double.random(in: -60...60)
            mode = .idle(until: clock + 1.2)
        } else if roll < 0.8, let g = gestures.randomElement() {
            start(g, gestures: gestures)
        } else if roll < 0.92 {
            mode = .gesture("sit", until: clock + Double.random(in: 3...6))
        } else if roomy {
            mode = .nap(until: clock + Double.random(in: 7...12))
        } else {
            mode = .idle(until: clock + 2)
        }
    }
}

// MARK: - Drawing her

/// One frame of her sheet, pixel-crisp, with her feet at the bottom centre of her body box.
struct CompanionSprite: View {
    let atlas: CompanionAtlas
    let frame: String
    let flip: Bool
    let scale: CGFloat

    var body: some View {
        let r = atlas.resident
        if let image = atlas.frame(frame) {
            Image(decorative: image, scale: 1)
                .interpolation(.none)
                .resizable()
                .frame(width: CGFloat(r.frameWidth) * scale, height: CGFloat(r.frameHeight) * scale)
                .scaleEffect(x: flip ? -1 : 1, y: 1)
        }
    }
}

extension CompanionAtlas {
    /// A scale that draws her body about `height` points tall, in half-point steps (crisp on Retina).
    func scale(forBodyHeight height: CGFloat) -> CGFloat {
        max(0.5, (height / CGFloat(resident.body.h) * 2).rounded() / 2)
    }

    var bodySize: CGSize { CGSize(width: resident.body.w, height: resident.body.h) }

    /// Offset placing the frame so her feet stand at `feet` (a point in the lane).
    func origin(feet: CGPoint, scale: CGFloat, flip: Bool) -> CGPoint {
        let b = resident.body
        let cx = CGFloat(b.x + b.w / 2)
        let fw = CGFloat(resident.frameWidth)
        let anchorX = flip ? fw - cx : cx
        return CGPoint(x: feet.x - anchorX * scale, y: feet.y - CGFloat(b.y + b.h) * scale)
    }
}

extension Color {
    /// "#rrggbb" (or "#rgb") from the companion's roster colours.
    init?(hex: String) {
        var s = hex.trimmingCharacters(in: .whitespaces)
        guard s.hasPrefix("#") else { return nil }
        s.removeFirst()
        if s.count == 3 { s = s.map { "\($0)\($0)" }.joined() }
        guard s.count == 6, let v = UInt32(s, radix: 16) else { return nil }
        self.init(red: Double((v >> 16) & 0xff) / 255, green: Double((v >> 8) & 0xff) / 255, blue: Double(v & 0xff) / 255)
    }
}

enum CompanionPalette {
    static let pink = Color(red: 1, green: 0.36, blue: 0.72)
    static let deepPink = Color(red: 0.92, green: 0.18, blue: 0.58)

    /// Her glow: bright pink, warmed toward her own heart colour.
    static func glow(_ resident: CompanionLink.Resident?) -> Color {
        guard let heart = resident.flatMap({ Color(hex: $0.bubble.heart) }) else { return pink }
        return pink.mix(with: heart, by: 0.35)
    }
}

private extension Color {
    func mix(with other: Color, by t: Double) -> Color {
        let a = NSColor(self).usingColorSpace(.sRGB) ?? .systemPink
        let b = NSColor(other).usingColorSpace(.sRGB) ?? .systemPink
        return Color(red: a.redComponent + (b.redComponent - a.redComponent) * t,
                     green: a.greenComponent + (b.greenComponent - a.greenComponent) * t,
                     blue: a.blueComponent + (b.blueComponent - a.blueComponent) * t)
    }
}

// MARK: - Collapsed: her lane

/// Her strip of the closed notch: she lives there at a small size, and when she has something to
/// tell you she turns to face out with a little speech mark.
struct CompanionLane: View {
    @ObservedObject var home: CompanionHome
    @ObservedObject var link: CompanionLink
    /// Layout size (before the notch's scale).
    let size: CGSize

    var body: some View {
        if let atlas = link.atlas {
            TimelineView(.animation(minimumInterval: 1 / 20)) { context in
                lane(atlas: atlas, date: context.date)
            }
            .frame(width: size.width, height: size.height)
            .clipped()
        } else {
            Color.clear.frame(width: size.width, height: size.height)
        }
    }

    private func lane(atlas: CompanionAtlas, date: Date) -> some View {
        let scale = atlas.scale(forBodyHeight: min(size.height - 9, 24))
        let r = atlas.resident
        let floor = size.height - 4
        // Her whole head stays in the lane, however high she hops.
        let headroom = max(0, floor - atlas.bodySize.height * scale - 1)
        let pose = home.sim.stepLane(to: date, width: size.width, scale: scale, bodySize: atlas.bodySize,
                                     headroom: headroom, walkFrames: atlas.walkFrames, stride: r.stride,
                                     listening: link.glowing, gestures: r.gestures)
        let feet = CGPoint(x: pose.x, y: floor - pose.alt)
        let o = atlas.origin(feet: feet, scale: scale, flip: pose.flip)
        return ZStack(alignment: .topLeading) {
            if !pose.hidden {
                CompanionSprite(atlas: atlas, frame: pose.frame, flip: pose.flip, scale: scale)
                    .scaleEffect(x: 2 - pose.squash, y: pose.squash, anchor: .bottom)
                    .offset(x: o.x, y: o.y)
            }
            if link.glowing {
                SpeechMark(count: link.unread.count, tint: CompanionPalette.glow(r))
                    .offset(x: min(max(pose.x + 4, 2), size.width - 24), y: max(1, o.y + CGFloat(r.body.y) * scale - 13))
            }
        }
        .frame(width: size.width, height: size.height, alignment: .topLeading)
    }
}

/// The tiny "she said something" mark over her head while the notch is closed.
private struct SpeechMark: View {
    let count: Int
    let tint: Color

    var body: some View {
        HStack(spacing: 1) {
            Image(systemName: "ellipsis")
                .font(.system(size: 7, weight: .heavy))
            if count > 1 {
                Text("\(count)").font(.system(size: 7, weight: .heavy, design: .rounded))
            }
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 4)
        .frame(height: 11)
        .background(Capsule().fill(tint))
        .shadow(color: tint.opacity(0.8), radius: 3)
    }
}

// MARK: - Opened: her space

/// The open notch space she roams when the notch is opened: nothing but her, the cookies lying
/// about, her message card along the top and the inventory button in the corner.
struct CompanionSpace: View {
    @ObservedObject var home: CompanionHome
    @ObservedObject var link: CompanionLink
    let size: CGSize
    let openInventory: () -> Void

    static let pad: CGFloat = 8
    static let button: CGFloat = 34
    /// Her feet, above the bottom of the space.
    static let floorInset: CGFloat = 10

    private var vertical: Bool { size.height > 170 }
    private var cardHeight: CGFloat { vertical ? 86 : 64 }
    private var floor: CGFloat { size.height - Self.floorInset }
    private var buttonRect: CGRect {
        CGRect(x: size.width - Self.pad - Self.button, y: size.height - Self.pad - Self.button,
               width: Self.button, height: Self.button)
    }

    var body: some View {
        let resident = link.resident
        let tint = CompanionPalette.glow(resident)
        let message = home.shownMessage.flatMap { id in link.messages.first { $0.id == id } }
        ZStack(alignment: .topLeading) {
            if let atlas = link.atlas, resident != nil {
                GeometryReader { geo in
                    TimelineView(.animation(minimumInterval: 1 / 30)) { context in
                        stage(atlas: atlas, date: context.date, frame: geo.frame(in: .global), listening: message.map { !$0.read } ?? false,
                              card: message != nil)
                    }
                }
            } else {
                Text(link.messages.isEmpty ? "Nobody's home" : "She went back to the desktop")
                    .font(.system(size: 10, weight: .medium, design: .rounded))
                    .foregroundStyle(.white.opacity(0.35))
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
                    .padding(.bottom, Self.floorInset + 6)
            }
            if message != nil {
                MessageCard(home: home, link: link, height: cardHeight)
                    .padding(.horizontal, Self.pad)
                    .padding(.top, Self.pad)
                    .transition(.scale(scale: 0.85, anchor: .top).combined(with: .opacity))
            }
            InventoryButton(tint: tint, enabled: resident != nil, action: openInventory)
                .frame(width: Self.button, height: Self.button)
                .offset(x: buttonRect.minX, y: buttonRect.minY)
        }
        .frame(width: size.width, height: size.height, alignment: .topLeading)
        .animation(.spring(response: 0.35, dampingFraction: 0.82), value: message?.id)
        .onChange(of: resident == nil) { _, gone in if gone { home.space = nil } }
        .onDisappear { home.space = nil }
    }

    private func stage(atlas: CompanionAtlas, date: Date, frame: CGRect, listening: Bool, card: Bool) -> some View {
        let r = atlas.resident
        let scale = atlas.scale(forBodyHeight: vertical ? 44 : 40)
        var controls = [buttonRect.insetBy(dx: -3, dy: -3)]
        if card {
            controls.append(CGRect(x: Self.pad, y: Self.pad, width: size.width - Self.pad * 2, height: cardHeight))
        }
        home.space = CompanionHome.Space(frame: frame, size: size, controls: controls)
        let reserved = Double((Self.button + Self.pad + 6) / size.width)
        let top = card ? Self.pad + cardHeight + 4 : 0
        let pose = home.sim.stepSpace(to: date, size: size, floor: floor, top: top, reserved: reserved, scale: scale,
                                      bodySize: atlas.bodySize, walkFrames: atlas.walkFrames, stride: r.stride,
                                      listening: listening, gestures: r.gestures)
        let feet = CGPoint(x: pose.x, y: floor - pose.alt)
        let o = atlas.origin(feet: feet, scale: scale, flip: pose.flip)
        let b = atlas.bodySize
        let head = feet.y - b.height * scale
        let sim = home.sim
        return ZStack(alignment: .topLeading) {
            // Cookies on the floor (and the one in her hands while she eats).
            ForEach(sim.cookies) { c in
                cookieView(c, sim: sim)
            }
            if !pose.hidden {
                // Her shadow on the floor, smaller the higher she is.
                let lift = min(1, pose.alt / 60)
                Ellipse()
                    .fill(.black.opacity(0.4 * (1 - lift)))
                    .frame(width: b.width * scale * (1.3 - 0.5 * lift), height: 4)
                    .offset(x: feet.x - b.width * scale * (1.3 - 0.5 * lift) / 2, y: floor - 2)
                CompanionSprite(atlas: atlas, frame: pose.frame, flip: pose.flip, scale: scale)
                    .scaleEffect(x: 2 - pose.squash, y: pose.squash, anchor: .bottom)
                    .rotationEffect(.degrees(pose.sway), anchor: .top)
                    .offset(x: o.x, y: o.y)
                if pose.napping {
                    Zzz(date: date)
                        .offset(x: feet.x + 8, y: head - 14)
                }
                if let c = sim.cookies.first(where: { $0.eating != nil }), let mouth = sim.mouth {
                    CookieArt(stage: min(2, Int((c.eating ?? 0) / CompanionSim.eatTime * 3)), crumbs: c.eating)
                        .frame(width: CompanionSim.cookieSize, height: CompanionSim.cookieSize)
                        .offset(x: mouth.x - CompanionSim.cookieSize / 2, y: mouth.y - CompanionSim.cookieSize / 2)
                }
            }
            Hearts(trigger: home.hearts, tint: Color(hex: r.bubble.heart) ?? CompanionPalette.pink)
                .offset(x: feet.x - 30, y: head - 10)
        }
        .frame(width: size.width, height: size.height, alignment: .topLeading)
    }

    @ViewBuilder
    private func cookieView(_ c: CompanionSim.Cookie, sim: CompanionSim) -> some View {
        if c.eating == nil {
            let rect = sim.cookieRect(c)
            let age = sim.clock - c.born
            let fade = sim.fade(c)
            ZStack {
                // A soft shadow where it'll land.
                Ellipse()
                    .fill(.black.opacity(0.35 * max(0, 1 - c.alt / 50) * fade))
                    .frame(width: rect.width * 0.9, height: 3)
                    .offset(y: floor - rect.midY + 0)
                CookieArt(stage: 0, crumbs: nil)
                    .frame(width: rect.width, height: rect.height)
                    .rotationEffect(.degrees(c.spin))
                    .scaleEffect(c.held ? 1.25 : (0.4 + 0.6 * min(1, age / 0.18)) * fade)
                    .shadow(color: .white.opacity(c.held ? 0.35 : 0), radius: 4)
                if age < 0.6 {
                    Sparkle(progress: age / 0.6)
                        .frame(width: 30, height: 30)
                }
            }
            .frame(width: rect.width, height: rect.height)
            .offset(x: rect.minX, y: rect.minY)
            .opacity(fade)
        }
    }
}

/// The chocolate-chip cookie from the companion app, in its whole, bitten and nearly-gone
/// stages, with crumbs falling while she eats (`crumbs` is the eating time).
struct CookieArt: View {
    let stage: Int
    let crumbs: Double?

    private static let palette: [Character: Color] = [
        "o": Color(red: 0x5b / 255, green: 0x3a / 255, blue: 0x1e / 255),
        "c": Color(red: 0xc9 / 255, green: 0x8a / 255, blue: 0x4b / 255),
        "l": Color(red: 0xe6 / 255, green: 0xb2 / 255, blue: 0x76 / 255),
        "h": Color(red: 0xf4 / 255, green: 0xd4 / 255, blue: 0xa0 / 255),
        "k": Color(red: 0x3b / 255, green: 0x24 / 255, blue: 0x14 / 255),
    ]
    private static let stages: [[String]] = [
        ["....oooooo......", "..ooclllcloo....", ".oclhllkllclo...", ".olllkllllhlo...", "oclhllllkllllo..", "olllllkllllclo..", "ollkllllllhllo..", "oclllhllkllllo..", "olllllllllkllo..", ".ollklllhllco...", ".oclllkllllo....", "..oolllllloo....", "....oooooo......"],
        ["....oooo........", "..ooclllo.......", ".oclhllko.......", ".olllklllo......", "oclhlllllo......", "olllllkllo......", "ollklllllo......", "oclllhllklo.....", "olllllllllko....", ".ollklllhllo....", ".oclllkllllo....", "..oolllllloo....", "....oooooo......"],
        ["................", "................", "................", "................", "................", "........oo......", "......oollo.....", ".....olkllo.....", "....olllllo.....", "....ollkllo.....", ".....ollllo.....", "......oooo......", "................"],
    ]

    var body: some View {
        Canvas { ctx, size in
            let p = size.width / 15
            let rows = Self.stages[min(2, max(0, stage))]
            for (r, row) in rows.enumerated() {
                for (c, ch) in row.enumerated() {
                    guard let color = Self.palette[ch] else { continue }
                    ctx.fill(Path(CGRect(x: CGFloat(c) * p, y: (CGFloat(r) + 1) * p, width: p + 0.01, height: p + 0.01)),
                             with: .color(color))
                }
            }
            if let t = crumbs {
                let crumb = Self.palette["c"]!
                for i in 0..<5 {
                    let f = (t * 1.7 + Double(i) * 0.37).truncatingRemainder(dividingBy: 1)
                    ctx.fill(Path(CGRect(x: size.width * (0.2 + 0.15 * CGFloat(i)), y: size.height * (0.6 + CGFloat(f) * 0.9),
                                         width: p * 1.2, height: p * 1.2)), with: .color(crumb))
                }
            }
        }
    }
}

/// The twinkle a cookie appears with.
private struct Sparkle: View {
    let progress: Double

    var body: some View {
        let t = CGFloat(progress)
        ZStack {
            ForEach(0..<4) { i in
                Image(systemName: "sparkle")
                    .font(.system(size: 6 + CGFloat(i % 2) * 2, weight: .bold))
                    .foregroundStyle(.white)
                    .offset(x: cos(Double(i) * .pi / 2 + 0.6) * (4 + 10 * t), y: sin(Double(i) * .pi / 2 + 0.6) * (4 + 10 * t))
            }
        }
        .opacity(Double(1 - t))
        .scaleEffect(0.6 + 0.6 * t)
        .allowsHitTesting(false)
    }
}

private struct Zzz: View {
    let date: Date

    var body: some View {
        let t = date.timeIntervalSinceReferenceDate
        ZStack {
            ForEach(0..<3) { i in
                let p = (t * 0.5 + Double(i) / 3).truncatingRemainder(dividingBy: 1)
                Text("z")
                    .font(.system(size: 7 + CGFloat(p) * 5, weight: .heavy, design: .rounded))
                    .foregroundStyle(.white.opacity(0.85 * (1 - p)))
                    .offset(x: CGFloat(p) * 10, y: -CGFloat(p) * 16)
            }
        }
    }
}

/// A burst of little hearts each time `trigger` changes.
private struct Hearts: View {
    let trigger: Int
    let tint: Color

    var body: some View {
        ZStack {
            ForEach(0..<5) { i in
                Image(systemName: "heart.fill")
                    .font(.system(size: CGFloat([8, 10, 7, 9, 8][i])))
                    .foregroundStyle(tint)
                    .shadow(color: tint.opacity(0.7), radius: 2)
                    .keyframeAnimator(initialValue: HeartState(), trigger: trigger) { content, s in
                        content.opacity(s.opacity).scaleEffect(s.scale).offset(x: s.x * CGFloat([-1, -0.4, 0.2, 0.7, 1.1][i]), y: s.y)
                    } keyframes: { _ in
                        KeyframeTrack(\.opacity) {
                            LinearKeyframe(1, duration: 0.05 + Double(i) * 0.06)
                            LinearKeyframe(1, duration: 0.6)
                            LinearKeyframe(0, duration: 0.4)
                        }
                        KeyframeTrack(\.scale) {
                            SpringKeyframe(1, duration: 0.3, spring: .bouncy)
                            LinearKeyframe(0.6, duration: 0.8)
                        }
                        KeyframeTrack(\.x) { LinearKeyframe(26, duration: 1.1) }
                        KeyframeTrack(\.y) { LinearKeyframe(-30 - Double(i % 2) * 8, duration: 1.1, timingCurve: .easeOut) }
                    }
            }
        }
        .frame(width: 60, height: 20)
        .allowsHitTesting(false)
    }

    struct HeartState {
        var opacity: Double = 0
        var scale: CGFloat = 0.3
        var x: CGFloat = 0
        var y: CGFloat = 0
    }
}

// MARK: - Her words

/// Her speech bubble: the message she left, styled in her own colours. Unread ones are marked
/// read once you've had them on screen for a moment; the arrows page through the rest, and the
/// cross puts one away.
private struct MessageCard: View {
    @ObservedObject var home: CompanionHome
    @ObservedObject var link: CompanionLink
    let height: CGFloat

    var body: some View {
        let messages = link.messages
        if let index = home.shownMessage.flatMap({ id in messages.firstIndex { $0.id == id } }) {
            let m = messages[index]
            let colors = m.colors ?? link.resident?.bubble
            let top = colors.flatMap { Color(hex: $0.top) } ?? .white
            let bottom = colors.flatMap { Color(hex: $0.bottom) } ?? Color(red: 1, green: 0.84, blue: 0.92)
            let border = colors.flatMap { Color(hex: $0.border) } ?? CompanionPalette.deepPink
            let text = colors.flatMap { Color(hex: $0.text) } ?? Color(red: 0.42, green: 0.11, blue: 0.28)
            VStack(alignment: .leading, spacing: 3) {
                // Everything on one line when there's room; on a narrow (side-docked) card the
                // time and the count give way before anything wraps.
                ViewThatFits(in: .horizontal) {
                    header(m, index: index, messages: messages, border: border, full: true)
                    header(m, index: index, messages: messages, border: border, full: false)
                }
                ScrollView(.vertical, showsIndicators: false) {
                    Text(m.text)
                        .font(.system(size: 11.5, weight: .medium, design: .rounded))
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                }
            }
            .foregroundStyle(text)
            .padding(.leading, 9)
            .padding(.trailing, 5)
            .padding(.vertical, 5)
            .frame(maxWidth: .infinity, minHeight: height, maxHeight: height, alignment: .topLeading)
            .background(
                RoundedRectangle(cornerRadius: 11, style: .continuous)
                    .fill(LinearGradient(colors: [top, bottom], startPoint: .top, endPoint: .bottom)))
            .overlay(RoundedRectangle(cornerRadius: 11, style: .continuous).strokeBorder(border, lineWidth: 1.5))
            .shadow(color: border.opacity(0.45), radius: 6)
            .task(id: m.id) {
                // Read once it's been up for a moment (long ones get a little longer).
                guard !m.read else { return }
                try? await Task.sleep(for: .seconds(min(4, 1.4 + Double(m.text.count) * 0.012)))
                if !Task.isCancelled, link.isOpen { link.markRead(m.id) }
            }
            .id(m.id)
            .transition(.asymmetric(insertion: .opacity.combined(with: .offset(y: 4)),
                                    removal: .opacity.combined(with: .scale(scale: 0.92))))
        }
    }
}

private extension MessageCard {
    func header(_ m: CompanionLink.Message, index: Int, messages: [CompanionLink.Message], border: Color, full: Bool) -> some View {
        HStack(spacing: 4) {
            Text(m.name)
                .font(.system(size: 10, weight: .heavy, design: .rounded))
                .lineLimit(1)
            if full {
                Text(m.date, format: .dateTime.hour().minute())
                    .font(.system(size: 9, weight: .medium, design: .rounded))
                    .opacity(0.55)
            }
            if !m.read {
                Circle().fill(border).frame(width: 5, height: 5)
            }
            Spacer(minLength: 2)
            let unread = link.unread.count
            if full, unread > 0, !(unread == 1 && !m.read) {
                Text("\(unread) new")
                    .font(.system(size: 9, weight: .bold, design: .rounded))
                    .padding(.horizontal, 5)
                    .background(Capsule().fill(border.opacity(0.18)))
            }
            if messages.count > 1 {
                CardButton(symbol: "chevron.left", enabled: index > 0, help: "Previous") {
                    home.shownMessage = messages[index - 1].id
                }
                Text("\(index + 1)/\(messages.count)")
                    .font(.system(size: 9, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .opacity(0.6)
                CardButton(symbol: "chevron.right", enabled: index < messages.count - 1, help: "Next") {
                    home.shownMessage = messages[index + 1].id
                }
            }
            CardButton(symbol: "xmark", enabled: true, help: "Dismiss", circled: true, tint: border) {
                withAnimation(.spring(response: 0.32, dampingFraction: 0.8)) { home.dismissMessage(m.id) }
            }
        }
        .fixedSize(horizontal: true, vertical: false)
    }
}

private struct CardButton: View {
    let symbol: String
    let enabled: Bool
    let help: String
    var circled = false
    var tint: Color = .clear
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: circled ? 7 : 8, weight: .heavy))
                .frame(width: 15, height: 15)
                .background(Circle().fill(tint.opacity(circled ? (hovering ? 0.32 : 0.16) : 0)))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .opacity(enabled ? (hovering ? 1 : 0.8) : 0.25)
        .onHover { h in withAnimation(.easeOut(duration: 0.12)) { hovering = h } }
        .help(help)
    }
}

/// Opens the companion app's inventory with her still at home; styled like the notch's own
/// quick actions (Finder, Calendar, System).
private struct InventoryButton: View {
    let tint: Color
    let enabled: Bool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: "backpack.fill")
                .font(.system(size: 14, weight: .medium))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(.white)
                .frame(width: 34, height: 34)
                .background(
                    RoundedRectangle(cornerRadius: 11, style: .continuous)
                        .fill(.white.opacity(hovering ? 0.16 : 0.08)))
                .contentShape(Rectangle())
        }
        .buttonStyle(InventoryPressStyle())
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.4)
        .onHover { h in withAnimation(.easeOut(duration: 0.15)) { hovering = h } }
        .help("Inventory")
    }
}

private struct InventoryPressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.92 : 1)
            .animation(.spring(response: 0.25, dampingFraction: 0.6), value: configuration.isPressed)
    }
}

/// The cookie button's glyph: a round cookie with a bite out of it and chocolate chips, in one
/// colour like the SF Symbols beside it.
struct CookieGlyph: Shape {
    func path(in rect: CGRect) -> Path {
        let d = min(rect.width, rect.height)
        let r = CGRect(x: rect.midX - d / 2, y: rect.midY - d / 2, width: d, height: d)
        var cookie = Path(ellipseIn: r)
        let bite = Path(ellipseIn: CGRect(x: r.maxX - d * 0.36, y: r.minY - d * 0.12, width: d * 0.5, height: d * 0.5))
        cookie = cookie.subtracting(bite)
        for (x, y, s) in [(0.3, 0.38, 0.15), (0.55, 0.6, 0.15), (0.28, 0.66, 0.12), (0.62, 0.32, 0.1)] as [(CGFloat, CGFloat, CGFloat)] {
            cookie = cookie.subtracting(Path(ellipseIn: CGRect(x: r.minX + d * x - d * s / 2, y: r.minY + d * y - d * s / 2,
                                                               width: d * s, height: d * s)))
        }
        return cookie
    }
}
