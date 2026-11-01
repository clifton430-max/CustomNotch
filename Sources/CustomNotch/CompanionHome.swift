import Combine
import SwiftUI

/// The resident companion's life in the notch: her behaviour, what's showing in her room, and the
/// pieces the controller needs (where she is, for picking her up).
@MainActor
final class CompanionHome: ObservableObject {
    let link: CompanionLink
    let sim = CompanionSim()
    /// Bumped when someone moves in (the notch gulps her down).
    @Published private(set) var gulp = 0
    /// Bumped for a burst of hearts around her.
    @Published private(set) var hearts = 0
    /// The message the room's speech bubble shows.
    @Published var shownMessage: String?
    /// Where she's drawn in the notch window (top-left origin), while her room is on screen.
    var spriteRect: CGRect?
    private var bag = Set<AnyCancellable>()

    init(link: CompanionLink) {
        self.link = link
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
        // A new resident starts in the middle of her lane.
        link.$resident.map(\.?.character).removeDuplicates().sink { [weak self] _ in
            self?.sim.reset()
        }.store(in: &bag)
        link.$messages.sink { [weak self] messages in
            guard let self else { return }
            // Keep the bubble on a message that still exists, preferring the oldest unread one.
            if let id = shownMessage, messages.contains(where: { $0.id == id }) {
                if link.isOpen || messages.first(where: { !$0.read }) == nil { return }
            }
            shownMessage = messages.first(where: { !$0.read })?.id ?? messages.last?.id
        }.store(in: &bag)
    }

    /// The notch opened: she turns to greet you, and the bubble shows the oldest unread message.
    func opened() {
        if let first = link.unread.first { shownMessage = first.id }
        sim.greet()
    }

    /// A pat from you.
    func petted() {
        hearts += 1
        sim.play("happy")
    }

    func spriteContains(windowPoint p: CGPoint) -> Bool {
        guard link.resident != nil, let r = spriteRect else { return false }
        return r.insetBy(dx: -6, dy: -4).contains(p)
    }
}

// MARK: - Behaviour

/// Her little life: wander, idle, turn around, sit, nap, use the room's things, and play the
/// gestures and expressions the companion app sends. Pure state stepped by the views' clock.
@MainActor
final class CompanionSim {
    enum Prop: CaseIterable {
        case bed, window, torch, chest

        /// Where it stands, as a fraction of the room's width.
        var spot: Double {
            switch self {
            case .bed: 0.11
            case .window: 0.4
            case .torch: 0.63
            case .chest: 0.86
            }
        }
    }

    struct Pose {
        var x: CGFloat
        var lift: CGFloat
        var frame: String
        var flip: Bool
        var squash: CGFloat
        var napping: Bool
        var hidden: Bool
    }

    private enum Mode {
        case idle(until: Double)
        case walk(to: Double, then: Prop?)
        case use(Prop, until: Double)
        case gesture(String, until: Double)
        case listen(until: Double)
    }

    private(set) var x = 0.5
    private var lift: Double = 0
    private var vy: Double = 0
    private var facing: Double = 1
    private var mode: Mode = .idle(until: 0)
    private var walked: Double = 0
    private var landAt: Double = -10
    private var clock: Double = 0
    private var last: Date?
    private var falling = false
    var carried = false
    /// What the companion app asked for, waiting for the next step to start it.
    private var queued: String?

    func reset() {
        x = 0.5
        lift = 0
        vy = 0
        mode = .idle(until: clock + 1)
        queued = nil
        carried = false
    }

    /// Moving in: she drops in from above the floor and lands with a bounce.
    func arrive() {
        lift = 1
        vy = 0
        falling = true
        mode = .idle(until: clock + 0.6)
        queued = "wave"
    }

    func greet() {
        if case .use(.bed, _) = mode { mode = .idle(until: clock) } // woken up
        queued = queued ?? "wave"
    }

    func play(_ kind: String) {
        queued = kind
    }

    /// Advance to `date` in a lane `width` points wide where she's drawn at `scale`; `room` means
    /// the opened room with its furniture, `listening` that her message bubble is up.
    func step(to date: Date, width: CGFloat, scale: CGFloat, bodyWidth: CGFloat, walkFrames: Int, stride: Double,
              room: Bool, listening: Bool, gestures: [String]) -> Pose {
        let dt = min(0.1, max(0, last.map { date.timeIntervalSince($0) } ?? 0))
        last = date
        clock += dt
        let w = max(1, Double(width))
        let margin = min(0.45, (Double(bodyWidth * scale) / 2 + 4) / w)
        x = min(max(x, margin), 1 - margin)

        // Falling in (lift is a fraction of the drop height), then the landing squash.
        if falling {
            vy += 3.2 * dt
            lift -= vy * dt
            if lift <= 0 {
                lift = 0
                vy = 0
                falling = false
                landAt = clock
            }
        } else if lift > 0 || vy != 0 {
            // A hop (lift in points / 100).
            vy -= 9 * dt
            lift += vy * dt
            if lift <= 0 { lift = 0; vy = 0; landAt = clock }
        }

        if let q = queued, !falling {
            queued = nil
            start(q, gestures: gestures)
        }
        if listening, case .idle = mode {
            mode = .listen(until: clock + 0.5)
        }

        var frame = "idle"
        var napping = false
        switch mode {
        case .idle(let until):
            if clock >= until { decide(room: room, margin: margin, gestures: gestures) }
        case .listen(let until):
            if !listening && clock >= until { mode = .idle(until: clock + 0.8) }
        case .walk(let target, let then):
            if listening {
                mode = .listen(until: clock + 0.5)
                break
            }
            let speed = 26 * Double(scale) / w // art px per second, as a fraction of the lane
            let dir: Double = target > x ? 1 : -1
            facing = dir
            let stepX = min(abs(target - x), speed * dt)
            x += dir * stepX
            walked += stepX * w / Double(scale)
            if abs(target - x) < 0.002 {
                if let prop = then, room {
                    facing = prop == .window ? (x < 0.5 ? 1 : -1) : facing
                    mode = .use(prop, until: clock + duration(of: prop))
                } else {
                    mode = .idle(until: clock + Double.random(in: 1.2...3.5))
                }
            } else if walkFrames > 0 {
                frame = "walk\(Int(walked * stride / 6) % walkFrames)"
            }
        case .use(let prop, let until):
            if !room { mode = .idle(until: clock + 1); break }
            switch prop {
            case .bed:
                frame = "nap"
                napping = true
            case .chest:
                frame = "use\(1 + Int(clock * 6) % 4)"
            case .torch:
                frame = "cast"
            case .window:
                // Looking out, glancing back now and then.
                facing = Int(clock / 1.6) % 3 == 2 ? -facing0(x) : facing0(x)
            }
            if clock >= until {
                if prop == .chest { start("happy", gestures: gestures) } else { mode = .idle(until: clock + 1.5) }
            }
        case .gesture(let kind, let until):
            switch kind {
            case "wave": frame = Int(clock * 4) % 2 == 0 ? "wave1" : "wave2"
            case "hug", "sit", "shy", "happy": frame = kind
            default: frame = "idle"
            }
            if clock >= until { mode = .idle(until: clock + Double.random(in: 1...2.5)) }
        }
        if lift > 0 { frame = vy > 0 && !falling ? "jump" : "fall" }

        let landing = clock - landAt
        let squash = landing < 0.22 ? 1 - 0.18 * sin(landing / 0.22 * .pi) : 1
        return Pose(x: CGFloat(x) * width, lift: CGFloat(lift), frame: frame, flip: facing < 0,
                    squash: CGFloat(squash), napping: napping, hidden: carried)
    }

    /// Facing the window: it's on the wall behind her, so she looks toward the room's middle.
    private func facing0(_ x: Double) -> Double { x < 0.5 ? 1 : -1 }

    private func duration(of prop: Prop) -> Double {
        switch prop {
        case .bed: Double.random(in: 7...12)
        case .chest: 2.2
        case .torch: Double.random(in: 2.5...4)
        case .window: Double.random(in: 3.5...6)
        }
    }

    private func start(_ kind: String, gestures: [String]) {
        switch kind {
        case "jump":
            vy = 2.2
            lift = 0.01
            mode = .idle(until: clock + 0.8)
        case "happy", "hearts":
            vy = 1.6
            lift = 0.01
            mode = .gesture("happy", until: clock + 1.6)
        case "wave", "hug", "sit", "shy":
            mode = .gesture(kind, until: clock + (kind == "sit" ? 3 : 1.8))
        default:
            mode = .gesture("wave", until: clock + 1.6)
        }
    }

    private func decide(room: Bool, margin: Double, gestures: [String]) {
        let roll = Double.random(in: 0..<1)
        if roll < 0.18 {
            // Turn around and look the other way.
            facing = -facing
            mode = .idle(until: clock + Double.random(in: 1.5...3.5))
        } else if roll < 0.55 {
            mode = .walk(to: Double.random(in: margin...(1 - margin)), then: nil)
        } else if roll < 0.85, room {
            let prop = Prop.allCases.randomElement()!
            mode = .walk(to: min(max(prop.spot, margin), 1 - margin), then: prop)
        } else if roll < 0.93, let g = gestures.randomElement() {
            start(g, gestures: gestures)
        } else {
            mode = .gesture("sit", until: clock + Double.random(in: 3...6))
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
        let pose = home.sim.step(to: date, width: size.width, scale: scale, bodyWidth: CGFloat(r.body.w),
                                 walkFrames: atlas.walkFrames, stride: r.stride, room: false,
                                 listening: link.glowing, gestures: r.gestures)
        let floor = size.height - 4
        let feet = CGPoint(x: pose.x, y: floor - pose.lift * min(size.height * 0.8, 40))
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

// MARK: - Opened: her room

/// Her home inside the opened notch: a cosy little room with a bed, a window, a torch and a chest
/// she uses, her speech bubble, and the inventory button.
struct CompanionRoom: View {
    @ObservedObject var home: CompanionHome
    @ObservedObject var link: CompanionLink
    let size: CGSize
    let openInventory: () -> Void

    private var floorHeight: CGFloat { 15 }
    private var vertical: Bool { size.height > 170 }

    var body: some View {
        let resident = link.resident
        let tint = CompanionPalette.glow(resident)
        ZStack(alignment: .topLeading) {
            RoomBackdrop(size: size, floor: floorHeight, tint: tint)
            if let atlas = link.atlas, resident != nil {
                GeometryReader { geo in
                    TimelineView(.animation(minimumInterval: 1 / 30)) { context in
                        occupant(atlas: atlas, date: context.date, origin: geo.frame(in: .global).origin)
                    }
                }
            } else {
                Text(link.messages.isEmpty ? "Nobody's home" : "She went back to the desktop")
                    .font(.system(size: 10, weight: .medium, design: .rounded))
                    .foregroundStyle(.white.opacity(0.4))
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
                    .padding(.bottom, floorHeight + 10)
            }
            VStack(alignment: .leading, spacing: 0) {
                HStack(alignment: .top, spacing: 6) {
                    MessageCard(home: home, link: link, height: vertical ? 88 : 66)
                    VStack(spacing: 6) {
                        InventoryButton(tint: tint, enabled: resident != nil, action: openInventory)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(8)
        }
        .frame(width: size.width, height: size.height)
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(tint.opacity(0.28), lineWidth: 1))
        .onChange(of: link.resident == nil) { _, gone in if gone { home.spriteRect = nil } }
        .onDisappear { home.spriteRect = nil }
    }

    private func occupant(atlas: CompanionAtlas, date: Date, origin: CGPoint) -> some View {
        let r = atlas.resident
        let scale = atlas.scale(forBodyHeight: vertical ? 44 : 40)
        let listening = home.shownMessage.flatMap { id in link.messages.first { $0.id == id } }.map { !$0.read } ?? false
        let pose = home.sim.step(to: date, width: size.width, scale: scale, bodyWidth: CGFloat(r.body.w),
                                 walkFrames: atlas.walkFrames, stride: r.stride, room: true,
                                 listening: listening, gestures: r.gestures)
        let floor = size.height - floorHeight + 1
        let feet = CGPoint(x: pose.x, y: floor - pose.lift * (size.height - floorHeight - 20))
        let o = atlas.origin(feet: feet, scale: scale, flip: pose.flip)
        let b = r.body
        let bodyRect = CGRect(x: feet.x - CGFloat(b.w) * scale / 2, y: feet.y - CGFloat(b.h) * scale,
                              width: CGFloat(b.w) * scale, height: CGFloat(b.h) * scale)
        home.spriteRect = pose.hidden ? nil : bodyRect.offsetBy(dx: origin.x, dy: origin.y)
        return ZStack(alignment: .topLeading) {
            if !pose.hidden {
                // Her shadow on the floor.
                Ellipse()
                    .fill(.black.opacity(0.35 * (1 - min(1, pose.lift))))
                    .frame(width: CGFloat(b.w) * scale * 1.3, height: 4)
                    .offset(x: feet.x - CGFloat(b.w) * scale * 0.65, y: floor - 2)
                CompanionSprite(atlas: atlas, frame: pose.frame, flip: pose.flip, scale: scale)
                    .scaleEffect(x: 2 - pose.squash, y: pose.squash, anchor: .bottom)
                    .offset(x: o.x, y: o.y)
                if pose.napping {
                    Zzz(date: date)
                        .offset(x: feet.x + 8, y: bodyRect.minY - 14)
                }
            }
            Hearts(trigger: home.hearts, tint: Color(hex: r.bubble.heart) ?? CompanionPalette.pink)
                .offset(x: feet.x - 30, y: bodyRect.minY - 10)
        }
        .frame(width: size.width, height: size.height, alignment: .topLeading)
    }
}

/// Wall, window, torch, bed, chest and floor, drawn in chunky Terraria-ish shapes.
private struct RoomBackdrop: View {
    let size: CGSize
    let floor: CGFloat
    let tint: Color

    var body: some View {
        let w = size.width, h = size.height
        let floorY = h - floor
        ZStack(alignment: .topLeading) {
            LinearGradient(colors: [Color(red: 0.16, green: 0.08, blue: 0.2), Color(red: 0.27, green: 0.1, blue: 0.24)],
                           startPoint: .top, endPoint: .bottom)
            // Wallpaper: soft polka dots.
            Canvas { ctx, s in
                for row in stride(from: 6.0, to: s.height, by: 14) {
                    for col in stride(from: row.truncatingRemainder(dividingBy: 28) == 6 ? 6.0 : 13.0, to: s.width, by: 14) {
                        ctx.fill(Path(ellipseIn: CGRect(x: col, y: row, width: 2.5, height: 2.5)), with: .color(.white.opacity(0.05)))
                    }
                }
            }
            // Window with the night outside.
            NightWindow()
                .frame(width: 34, height: 30)
                .offset(x: w * CompanionSim.Prop.window.spot - 17, y: floorY - 62)
            // Torch, flickering.
            Torch()
                .frame(width: 10, height: 22)
                .offset(x: w * CompanionSim.Prop.torch.spot - 5, y: floorY - 52)
            // Bed.
            Bed(tint: tint)
                .frame(width: 44, height: 20)
                .offset(x: max(4, w * CompanionSim.Prop.bed.spot - 22), y: floorY - 20)
            // Chest.
            PixelChest()
                .frame(width: 20, height: 15)
                .offset(x: min(w - 24, w * CompanionSim.Prop.chest.spot + 10), y: floorY - 15)
            // Wooden floor.
            VStack(spacing: 0) {
                Rectangle().fill(Color(red: 0.55, green: 0.33, blue: 0.2)).frame(height: 3)
                Rectangle().fill(Color(red: 0.4, green: 0.23, blue: 0.14))
                    .overlay(
                        Canvas { ctx, s in
                            for x in stride(from: 0.0, to: s.width, by: 22) {
                                ctx.fill(Path(CGRect(x: x, y: 0, width: 1, height: s.height)), with: .color(.black.opacity(0.25)))
                            }
                        })
            }
            .frame(width: w, height: floor)
            .offset(y: floorY)
        }
        .frame(width: w, height: h, alignment: .topLeading)
    }
}

private struct NightWindow: View {
    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 2).fill(Color(red: 0.45, green: 0.27, blue: 0.16))
            LinearGradient(colors: [Color(red: 0.05, green: 0.06, blue: 0.22), Color(red: 0.22, green: 0.12, blue: 0.38)],
                           startPoint: .top, endPoint: .bottom)
                .padding(3)
            Circle().fill(Color(red: 1, green: 0.95, blue: 0.75)).frame(width: 7, height: 7).offset(x: 6, y: -6)
            ForEach(0..<4) { i in
                Rectangle().fill(.white.opacity(0.8)).frame(width: 1.5, height: 1.5)
                    .offset(x: [-9, -4, 3, -7][i], y: [-7, 2, 6, 7][i])
            }
            Rectangle().fill(Color(red: 0.45, green: 0.27, blue: 0.16)).frame(width: 2)
            Rectangle().fill(Color(red: 0.45, green: 0.27, blue: 0.16)).frame(height: 2)
        }
    }
}

private struct Torch: View {
    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 8)) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            let flick = 0.85 + 0.15 * sin(t * 9) * cos(t * 5.3)
            ZStack(alignment: .top) {
                Circle()
                    .fill(RadialGradient(colors: [Color.orange.opacity(0.35 * flick), .clear], center: .center, startRadius: 0, endRadius: 22))
                    .frame(width: 44, height: 44)
                    .offset(y: -16)
                Rectangle().fill(Color(red: 0.5, green: 0.3, blue: 0.15)).frame(width: 3, height: 13).offset(y: 9)
                Ellipse().fill(Color(red: 1, green: 0.6, blue: 0.15)).frame(width: 7, height: 10 * flick).offset(y: 1)
                Ellipse().fill(Color(red: 1, green: 0.95, blue: 0.6)).frame(width: 3, height: 5 * flick).offset(y: 4)
            }
        }
    }
}

private struct Bed: View {
    let tint: Color

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            Rectangle().fill(Color(red: 0.45, green: 0.27, blue: 0.16)).frame(width: 4, height: 20)
            Rectangle().fill(Color(red: 0.45, green: 0.27, blue: 0.16)).frame(height: 6).offset(y: 0)
            RoundedRectangle(cornerRadius: 2).fill(tint.opacity(0.85)).frame(height: 8).offset(x: 4, y: -6)
            RoundedRectangle(cornerRadius: 2).fill(.white.opacity(0.9)).frame(width: 9, height: 5).offset(x: 5, y: -12)
        }
    }
}

/// A little Terraria-style wooden chest with gold trim.
struct PixelChest: View {
    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width, h = geo.size.height
            ZStack(alignment: .topLeading) {
                RoundedRectangle(cornerRadius: w * 0.12).fill(Color(red: 0.55, green: 0.33, blue: 0.17))
                Rectangle().fill(Color(red: 0.42, green: 0.24, blue: 0.12)).frame(height: h * 0.42)
                Rectangle().fill(Color(red: 0.95, green: 0.78, blue: 0.3)).frame(height: max(1, h * 0.1)).offset(y: h * 0.42)
                Rectangle().fill(Color(red: 0.95, green: 0.78, blue: 0.3)).frame(width: max(1, w * 0.1)).offset(x: w * 0.08)
                Rectangle().fill(Color(red: 0.95, green: 0.78, blue: 0.3)).frame(width: max(1, w * 0.1)).offset(x: w * 0.82)
                RoundedRectangle(cornerRadius: 1).fill(Color(red: 1, green: 0.88, blue: 0.45))
                    .frame(width: w * 0.22, height: h * 0.3)
                    .offset(x: w * 0.39, y: h * 0.32)
            }
        }
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

/// Her speech bubble in the room: the message she left, styled in her own colours. Unread ones are
/// marked read once you've had them on screen for a moment; the arrows page through the rest.
private struct MessageCard: View {
    @ObservedObject var home: CompanionHome
    @ObservedObject var link: CompanionLink
    let height: CGFloat

    var body: some View {
        let messages = link.messages
        let index = home.shownMessage.flatMap { id in messages.firstIndex { $0.id == id } }
        if let index {
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
            .padding(.horizontal, 9)
            .padding(.vertical, 6)
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
            .transition(.scale(scale: 0.8, anchor: .bottomLeading).combined(with: .opacity))
        } else if let name = link.resident?.name {
            Text("\(name) lives here now. Drag her out to bring her back to the desktop.")
                .font(.system(size: 10, weight: .medium, design: .rounded))
                .foregroundStyle(.white.opacity(0.42))
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.top, 2)
        } else {
            Spacer(minLength: 0).frame(maxWidth: .infinity)
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
            PageButton(symbol: "chevron.left", enabled: index > 0) { home.shownMessage = messages[index - 1].id }
            Text("\(index + 1)/\(messages.count)")
                .font(.system(size: 9, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .opacity(0.6)
            PageButton(symbol: "chevron.right", enabled: index < messages.count - 1) { home.shownMessage = messages[index + 1].id }
        }
        .fixedSize(horizontal: true, vertical: false)
    }
}

private struct PageButton: View {
    let symbol: String
    let enabled: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 8, weight: .heavy))
                .frame(width: 14, height: 14)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .opacity(enabled ? 0.8 : 0.25)
    }
}

/// Opens the companion app's inventory (the Terraria item grid), with her still at home.
private struct InventoryButton: View {
    let tint: Color
    let enabled: Bool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            VStack(spacing: 2) {
                PixelChest()
                    .frame(width: 22, height: 17)
                    .scaleEffect(hovering ? 1.1 : 1)
                Text("Inventory")
                    .font(.system(size: 8.5, weight: .bold, design: .rounded))
                    .foregroundStyle(.white.opacity(hovering ? 0.95 : 0.7))
            }
            .frame(width: 52, height: 42)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Color(red: 0.2, green: 0.25, blue: 0.55).opacity(hovering ? 0.75 : 0.55)))
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(hovering ? tint : Color(red: 0.45, green: 0.55, blue: 0.95).opacity(0.7), lineWidth: 1.2))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.4)
        .onHover { h in withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) { hovering = h } }
        .help("Open her Terraria inventory")
    }
}
