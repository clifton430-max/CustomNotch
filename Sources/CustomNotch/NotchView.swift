import AppKit
import SwiftUI

struct NotchRootView: View {
    @ObservedObject var model: NotchModel
    @ObservedObject var stats: SystemStats
    @ObservedObject var home: CompanionHome
    @ObservedObject var link: CompanionLink

    /// 0 none · 1 she's talking (until opened) · 2 a companion is held over it · 3 one is coming in.
    private var glowLevel: Int {
        switch link.hover {
        case "incoming": 3
        case "empty": 2
        default: link.glowing && !model.isExpanded ? 1 : 0
        }
    }

    var body: some View {
        let pad = NotchMetrics.earPad
        let shape = NotchShape(edge: model.edge, ear: model.ear, radius: model.radius)
        let tint = CompanionPalette.glow(link.resident)
        let edge = model.edge

        ZStack {
            if glowLevel > 0 {
                GlowAura(shape: shape, tint: tint, level: glowLevel)
                    .transition(.opacity.animation(.easeOut(duration: 0.35)))
            }
            shape
                .fill(Color.black)
                .shadow(color: .black.opacity(model.isFloating ? 0.55 : (model.isExpanded ? 0.4 : 0)),
                        radius: model.isFloating ? 24 : 18,
                        y: model.isFloating ? 12 : 6)

            NotchContent(model: model, stats: stats, home: home, link: link)
                .frame(width: model.bodySize.width, height: model.bodySize.height, alignment: model.edge.alignment)
                .padding(pad)
                .mask(shape)

            shape
                .stroke(Color.white.opacity(model.isFloating ? 0.16 : 0), lineWidth: 0.75)
            if glowLevel > 0 {
                shape.stroke(tint.opacity(glowLevel > 1 ? 0.95 : 0.8), lineWidth: glowLevel > 1 ? 2 : 1.4)
                    .transition(.opacity.animation(.easeOut(duration: 0.3)))
            }
            Gulp(trigger: home.gulp, tint: tint)
        }
        .frame(width: model.bodySize.width + pad * 2, height: model.bodySize.height + pad * 2)
        // Held over it, the notch opens up for her; taken, it shakes its head.
        .scaleEffect(glowLevel >= 2 ? 1.06 : 1, anchor: model.edge.unitPoint)
        .animation(.spring(response: 0.3, dampingFraction: 0.55), value: glowLevel)
        .keyframeAnimator(initialValue: CGFloat(0), trigger: link.hover == "full") { content, x in
            content.offset(x: edge.isHorizontal ? x : 0, y: edge.isHorizontal ? 0 : x)
        } keyframes: { _ in
            KeyframeTrack {
                for v in [7.0, -6, 5, -4, 2, 0] { LinearKeyframe(CGFloat(v), duration: 0.06) }
            }
        }
        // Gulp: she's swallowed down, the notch bulges and settles.
        .keyframeAnimator(initialValue: CGFloat(1), trigger: home.gulp) { content, k in
            content.scaleEffect(k, anchor: edge.unitPoint)
        } keyframes: { _ in
            KeyframeTrack {
                SpringKeyframe(1.16, duration: 0.16, spring: .snappy)
                SpringKeyframe(0.94, duration: 0.18, spring: .snappy)
                SpringKeyframe(1.04, duration: 0.2, spring: .bouncy)
                SpringKeyframe(1, duration: 0.3, spring: .smooth)
            }
        }
        .scaleEffect(model.isAppeared ? (model.isFloating ? 1.05 : 1) : 0.35, anchor: model.edge.unitPoint)
        .opacity(model.isAppeared ? 1 : 0)
        .position(model.bodyCenter)
        .frame(width: NotchMetrics.canvas, height: NotchMetrics.canvas)
        .environment(\.colorScheme, .dark)
    }
}

// MARK: - Content

private struct NotchContent: View {
    @ObservedObject var model: NotchModel
    @ObservedObject var stats: SystemStats
    let home: CompanionHome
    let link: CompanionLink

    var body: some View {
        let horizontal = model.edge.isHorizontal
        let lane = model.hasResident
        ZStack(alignment: model.edge.alignment) {
            if model.isExpanded {
                Group {
                    if horizontal {
                        HorizontalExpanded(model: model, stats: stats, home: home, link: link)
                    } else {
                        VerticalExpanded(model: model, stats: stats, home: home, link: link)
                    }
                }
                .scaled(to: NotchMetrics.expanded(horizontal: horizontal, room: model.showsRoom), by: model.sizing.scale)
                .transition(.asymmetric(
                    insertion: .modifier(active: Reveal(progress: 0, anchor: model.edge.unitPoint),
                                         identity: Reveal(progress: 1, anchor: model.edge.unitPoint))
                        .animation(.spring(response: 0.42, dampingFraction: 0.86).delay(0.07)),
                    removal: .modifier(active: Reveal(progress: 0, anchor: model.edge.unitPoint),
                                       identity: Reveal(progress: 1, anchor: model.edge.unitPoint))
                        .animation(.easeOut(duration: 0.14))))
            } else {
                Group {
                    if horizontal {
                        HStack(spacing: 0) {
                            if lane {
                                CompanionLane(home: home, link: link,
                                              size: CGSize(width: CompanionMetrics.laneAlong,
                                                           height: model.sizing.collapsedLayout(horizontal: true).height))
                                    .padding(.leading, 6)
                            }
                            HorizontalCollapsed(stats: stats)
                        }
                    } else {
                        let clock = model.sizing.collapsedLayout(horizontal: false)
                        VStack(spacing: 0) {
                            VerticalCollapsed(stats: stats, size: clock, edge: model.edge)
                                .frame(width: clock.width, height: clock.height)
                            if lane {
                                CompanionLane(home: home, link: link,
                                              size: CGSize(width: clock.width, height: CompanionMetrics.laneBelow))
                            }
                        }
                    }
                }
                .id(horizontal ? (lane ? 1 : 0) : (lane ? 3 : 2))
                .scaled(to: model.sizing.collapsedLayout(horizontal: horizontal, lane: lane), by: model.sizing.scale)
                .transition(.asymmetric(
                    insertion: .opacity.animation(.easeOut(duration: 0.22).delay(0.12)),
                    removal: .opacity.animation(.easeOut(duration: 0.1))))
            }
        }
    }
}

private extension View {
    /// Lays the view out at `size`, then scales it uniformly so it occupies `size * scale`.
    func scaled(to size: CGSize, by scale: CGFloat) -> some View {
        frame(width: size.width, height: size.height)
            .scaleEffect(scale)
            .frame(width: size.width * scale, height: size.height * scale)
    }
}

/// Fades and gently scales content in from the attached edge. (No blur: a blur left at
/// radius 0 keeps the content rendering on the CPU.)
private struct Reveal: ViewModifier {
    var progress: CGFloat
    var anchor: UnitPoint

    func body(content: Content) -> some View {
        content
            .opacity(progress)
            .scaleEffect(0.9 + 0.1 * progress, anchor: anchor)
    }
}

// MARK: - Collapsed

struct HorizontalCollapsed: View {
    @ObservedObject var stats: SystemStats

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: stats.batterySymbol)
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(stats.batteryTint)
            Text("\(stats.batteryPercent)%")
                .foregroundStyle(.white.opacity(0.7))
            Spacer(minLength: 8)
            TimelineView(.everyMinute) { context in
                Text(context.date, format: .dateTime.hour().minute())
            }
        }
        .font(.system(size: 12, weight: .semibold, design: .rounded))
        .monospacedDigit()
        .foregroundStyle(.white.opacity(0.94))
        .padding(.horizontal, 16)
    }
}

/// The side-docked notch. The time is sized from the notch's depth; once the notch is long
/// enough to hold time and battery side by side without crowding, they run along the edge
/// (letters facing the edge), otherwise they stack upright.
struct VerticalCollapsed: View {
    @ObservedObject var stats: SystemStats
    /// Layout size before scaling: `width` is the depth, `height` the length along the edge.
    let size: CGSize
    let edge: NotchEdge

    private var timeSize: CGFloat { min(max(size.width * 0.52, 12), 24) }

    private var runsAlongEdge: Bool {
        // Time, battery glyph and percentage, plus padding, with room to breathe.
        let needed = timeSize * 2.9 + timeSize * 0.62 * 4.4 + 40
        return size.height >= needed * 1.25
    }

    var body: some View {
        TimelineView(.everyMinute) { context in
            if runsAlongEdge {
                alongEdge(context.date)
            } else {
                stacked(context.date)
            }
        }
        .monospacedDigit()
        .foregroundStyle(.white)
    }

    private func stacked(_ date: Date) -> some View {
        let font = timeSize
        let showsPercent = size.height >= font * 5.4 + 24
        return VStack(spacing: font * 0.4) {
            Ring(value: stats.battery, tint: stats.batteryTint, lineWidth: max(2, font * 0.13))
                .frame(width: font * 0.9, height: font * 0.9)
            VStack(spacing: -font * 0.14) {
                Text(date, format: .dateTime.hour(.defaultDigits(amPM: .omitted)))
                Text(date, format: .dateTime.minute(.twoDigits))
                    .foregroundStyle(.white.opacity(0.72))
            }
            .font(.system(size: font, weight: .bold, design: .rounded))
            .lineLimit(1)
            .minimumScaleFactor(0.6)
            if showsPercent {
                Text("\(stats.batteryPercent)%")
                    .font(.system(size: font * 0.52, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white.opacity(0.55))
            }
        }
        .padding(.horizontal, 3)
    }

    private func alongEdge(_ date: Date) -> some View {
        let font = timeSize
        return HStack(spacing: 6) {
            Text(date, format: .dateTime.hour(.defaultDigits(amPM: .omitted)).minute())
                .font(.system(size: font, weight: .bold, design: .rounded))
            Spacer(minLength: 10)
            Image(systemName: stats.batterySymbol)
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(stats.batteryTint)
            Text("\(stats.batteryPercent)%")
                .foregroundStyle(.white.opacity(0.7))
        }
        .font(.system(size: font * 0.62, weight: .semibold, design: .rounded))
        .lineLimit(1)
        .padding(.horizontal, 16)
        .frame(width: size.height, height: size.width)
        .rotationEffect(.degrees(edge == .left ? -90 : 90))
        .frame(width: size.width, height: size.height)
    }
}

// MARK: - Expanded

private struct HorizontalExpanded: View {
    @ObservedObject var model: NotchModel
    @ObservedObject var stats: SystemStats
    let home: CompanionHome
    let link: CompanionLink

    var body: some View {
        VStack(spacing: 0) {
            VStack(spacing: 8) {
                ExpandedHeader(model: model, settings: home.settings)
                HStack(alignment: .center, spacing: 12) {
                    ClockBlock(stats: stats)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    StatRings(model: model, stats: stats, size: 42)
                    Rectangle().fill(Color.white.opacity(0.1)).frame(width: 1, height: 70)
                    ActionGrid(showsLabels: false)
                }
            }
            .padding(.horizontal, 20)
            .padding(.top, 12)
            .padding(.bottom, 16)
            .frame(height: NotchMetrics.expanded(horizontal: true).height)
            if model.showsRoom {
                CompanionSpace(home: home, link: link,
                               size: CGSize(width: NotchMetrics.expanded(horizontal: true).width - 28,
                                            height: CompanionMetrics.roomHorizontal - 14),
                               openInventory: model.openInventory)
                    .padding(.bottom, 14)
            }
        }
    }
}

private struct VerticalExpanded: View {
    @ObservedObject var model: NotchModel
    @ObservedObject var stats: SystemStats
    let home: CompanionHome
    let link: CompanionLink

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 20) {
                ExpandedHeader(model: model, settings: home.settings)
                ClockBlock(stats: stats)
                StatRings(model: model, stats: stats, size: 52)
                    .frame(maxWidth: .infinity)
                ActionGrid(showsLabels: true)
                    .frame(maxWidth: .infinity)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 18)
            .frame(height: NotchMetrics.expanded(horizontal: false).height, alignment: .top)
            if model.showsRoom {
                CompanionSpace(home: home, link: link,
                               size: CGSize(width: NotchMetrics.expanded(horizontal: false).width - 28,
                                            height: CompanionMetrics.roomVertical - 16),
                               openInventory: model.openInventory)
                    .padding(.bottom, 16)
            }
        }
    }
}

// MARK: - Companion glow

/// The pink glow around the notch: a soft breathing halo while she has something to tell you,
/// brighter and quicker while a companion is held over it or on her way in.
private struct GlowAura: View {
    let shape: NotchShape
    let tint: Color
    let level: Int

    var body: some View {
        // ~24 fps is plenty for a slow breath, and keeps a long-waiting glow cheap.
        TimelineView(.animation(minimumInterval: 1 / 24)) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            let speed = level >= 2 ? 5.5 : 2.2
            let breath = 0.5 + 0.5 * sin(t * speed)
            let strength = level == 3 ? 1.0 : (level == 2 ? 0.85 : 0.55 + 0.35 * breath)
            ZStack {
                shape.fill(tint).blur(radius: 10 + 6 * breath).opacity(strength * 0.9)
                shape.fill(tint.opacity(0.6)).blur(radius: 26 + 10 * breath).opacity(strength * 0.7)
            }
        }
        .allowsHitTesting(false)
    }
}

/// Bubbles rushing into the notch and popping as a companion arrives.
private struct Gulp: View {
    let trigger: Int
    let tint: Color

    var body: some View {
        GeometryReader { geo in
            let c = CGPoint(x: geo.size.width / 2, y: geo.size.height / 2)
            ZStack {
                ForEach(0..<12, id: \.self) { i in
                    let a = Double(i) / 12 * 2 * .pi
                    Circle()
                        .fill(RadialGradient(colors: [.white.opacity(0.95), tint.opacity(0.75), tint.opacity(0)],
                                             center: .init(x: 0.35, y: 0.3), startRadius: 0, endRadius: 7))
                        .frame(width: CGFloat(6 + (i * 7) % 8), height: CGFloat(6 + (i * 7) % 8))
                        .keyframeAnimator(initialValue: CGFloat(0), trigger: trigger) { content, k in
                            let r = (1 - k) * max(geo.size.width, geo.size.height) * 0.6
                            content
                                .position(x: c.x + cos(a) * r, y: c.y + sin(a) * r * 0.6)
                                .opacity(k > 0 && k < 1 ? Double(1 - k * 0.6) : 0)
                                .scaleEffect(k > 0.85 ? 1.6 : 1)
                        } keyframes: { _ in
                            KeyframeTrack {
                                LinearKeyframe(0.001, duration: 0.01)
                                LinearKeyframe(0.001, duration: Double(i) * 0.02)
                                CubicKeyframe(1, duration: 0.45)
                                LinearKeyframe(0, duration: 0.01)
                            }
                        }
                }
            }
        }
        .allowsHitTesting(false)
    }
}

/// Date on the left; pin, cookie (with a companion inside) and settings controls in the
/// top-right corner. The controls only exist while the notch is open on hover, and settle in
/// just after the panel does.
private struct ExpandedHeader: View {
    @ObservedObject var model: NotchModel
    @ObservedObject var settings: NotchSettings
    @State private var showsControls = false

    var body: some View {
        HStack(spacing: 4) {
            TimelineView(.everyMinute) { context in
                Text(context.date, format: .dateTime.weekday(.abbreviated).month(.abbreviated).day())
                    .lineLimit(1)
                    .font(.system(size: 11, weight: .semibold, design: .rounded))
                    .textCase(.uppercase)
                    .foregroundStyle(.white.opacity(0.5))
            }
            Spacer(minLength: 4)
            Group {
                PinButton(isPinned: $model.isPinned)
                if model.hasResident && settings.showsCookieButton {
                    CookieButton(action: model.spawnCookie)
                        .transition(.scale(scale: 0.5).combined(with: .opacity))
                }
                HeaderIconButton(symbol: "gearshape.fill", help: "Notch Settings", spinsOnHover: true,
                                 action: model.openSettings)
            }
            .opacity(showsControls ? 1 : 0)
            .scaleEffect(showsControls ? 1 : 0.5)
        }
        .frame(height: 20)
        .onAppear {
            withAnimation(.spring(response: 0.38, dampingFraction: 0.7).delay(0.16)) { showsControls = true }
        }
    }
}

private struct HeaderIconButton: View {
    let symbol: String
    let help: String
    var tint: Color = .white
    var isActive = false
    var spinsOnHover = false
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 10.5, weight: .semibold))
                .rotationEffect(.degrees(spinsOnHover && hovering ? 60 : 0))
                .foregroundStyle(isActive ? tint : .white.opacity(hovering ? 0.9 : 0.45))
                .frame(width: 22, height: 22)
                .background(Circle().fill(.white.opacity(hovering ? 0.12 : 0)))
                .contentShape(Circle())
        }
        .buttonStyle(PressableStyle())
        .onHover { h in withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) { hovering = h } }
        .help(help)
    }
}

/// Drops a cookie into her space; sized and coloured like the header's other buttons.
private struct CookieButton: View {
    let action: () -> Void
    @State private var hovering = false
    @State private var dropped = 0

    var body: some View {
        Button {
            dropped += 1
            action()
        } label: {
            CookieGlyph()
                .fill(.white.opacity(hovering ? 0.9 : 0.45), style: FillStyle(eoFill: true))
                .frame(width: 11.5, height: 11.5)
                .rotationEffect(.degrees(hovering ? -18 : 0))
                .keyframeAnimator(initialValue: CGFloat(0), trigger: dropped) { content, y in
                    content.offset(y: y)
                } keyframes: { _ in
                    KeyframeTrack {
                        SpringKeyframe(3, duration: 0.1, spring: .snappy)
                        SpringKeyframe(0, duration: 0.3, spring: .bouncy)
                    }
                }
                .frame(width: 22, height: 22)
                .background(Circle().fill(.white.opacity(hovering ? 0.12 : 0)))
                .contentShape(Circle())
        }
        .buttonStyle(PressableStyle())
        .onHover { h in withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) { hovering = h } }
        .help("Give her a cookie")
    }
}

private struct ClockBlock: View {
    @ObservedObject var stats: SystemStats

    var body: some View {
        TimelineView(.everyMinute) { context in
            VStack(alignment: .leading, spacing: 2) {
                let time = context.date.formatted(.dateTime.hour(.defaultDigits(amPM: .omitted)).minute())
                Text(time)
                    .font(.system(size: 38, weight: .semibold, design: .rounded))
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                    .monospacedDigit()
                    .contentTransition(.numericText())
                    .animation(.smooth, value: time)
                    .foregroundStyle(.white)
                HStack(spacing: 4) {
                    Image(systemName: stats.batterySymbol)
                        .symbolRenderingMode(.hierarchical)
                        .foregroundStyle(stats.batteryTint)
                    Text("\(stats.batteryPercent)% · \(stats.batteryStatus)")
                        .foregroundStyle(.white.opacity(0.55))
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                }
                .font(.system(size: 11, weight: .medium, design: .rounded))
            }
        }
    }
}

private struct PinButton: View {
    @Binding var isPinned: Bool

    var body: some View {
        HeaderIconButton(symbol: isPinned ? "pin.fill" : "pin", help: isPinned ? "Unpin" : "Keep open",
                         tint: .orange, isActive: isPinned) {
            withAnimation(.spring(response: 0.3, dampingFraction: 0.6)) { isPinned.toggle() }
        }
    }
}

// MARK: - Stats

extension ResourceKind {
    /// Shared by the notch's rings and the detail panel so each resource keeps one colour.
    var tint: Color {
        switch self {
        case .cpu: Color(red: 0.25, green: 0.65, blue: 1)
        case .memory: Color(red: 0.72, green: 0.45, blue: 1)
        case .battery: Color(red: 0.30, green: 0.85, blue: 0.45)
        }
    }
}

private struct StatRings: View {
    @ObservedObject var model: NotchModel
    @ObservedObject var stats: SystemStats
    let size: CGFloat

    var body: some View {
        HStack(spacing: 12) {
            StatRing(value: stats.battery, label: "Battery",
                     symbol: stats.isCharging ? "bolt.fill" : nil,
                     tint: ResourceKind.battery.tint, size: size) { model.openDetail(.battery) }
            StatRing(value: stats.cpu, label: "CPU", symbol: nil,
                     tint: ResourceKind.cpu.tint, size: size) { model.openDetail(.cpu) }
            StatRing(value: stats.memory, label: "Memory", symbol: nil,
                     tint: ResourceKind.memory.tint, size: size) { model.openDetail(.memory) }
        }
    }
}

/// A ring that opens its resource's detail panel when clicked.
private struct StatRing: View {
    let value: Double
    let label: String
    let symbol: String?
    let tint: Color
    let size: CGFloat
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) { content }
            .buttonStyle(PressableStyle())
            .onHover { h in withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) { hovering = h } }
            .help("Show \(label) details")
    }

    private var content: some View {
        VStack(spacing: 6) {
            ZStack {
                Ring(value: value, tint: tint, lineWidth: 4.5)
                if let symbol {
                    Image(systemName: symbol)
                        .font(.system(size: size * 0.28, weight: .bold))
                        .foregroundStyle(tint)
                } else {
                    Text("\(Int((value * 100).rounded()))")
                        .font(.system(size: size * 0.27, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                        .contentTransition(.numericText(value: value))
                        .foregroundStyle(.white)
                }
            }
            .frame(width: size, height: size)
            .background(Circle().fill(tint.opacity(hovering ? 0.16 : 0)).padding(-5))
            .scaleEffect(hovering ? 1.06 : 1)
            HStack(spacing: 2) {
                Text(label)
                Image(systemName: "chevron.right")
                    .font(.system(size: 7, weight: .bold))
                    .opacity(hovering ? 1 : 0)
                    .frame(width: hovering ? 7 : 0)
            }
            .font(.system(size: 10, weight: .medium, design: .rounded))
            .foregroundStyle(.white.opacity(hovering ? 0.9 : 0.5))
            .fixedSize()
        }
        .contentShape(Rectangle())
        .animation(.smooth(duration: 0.6), value: value)
    }
}

struct Ring: View {
    let value: Double
    let tint: Color
    let lineWidth: CGFloat

    var body: some View {
        ZStack {
            Circle().stroke(tint.opacity(0.18), lineWidth: lineWidth)
            // A solid stroke; an angular gradient here is shaded on the CPU every frame.
            Circle()
                .trim(from: 0, to: max(0.001, min(1, value)))
                .stroke(tint, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                .rotationEffect(.degrees(-90))
        }
    }
}

// MARK: - Actions

private struct QuickAction: Identifiable {
    let symbol: String
    let title: String
    let bundleID: String
    var id: String { bundleID }

    static let all = [
        QuickAction(symbol: "folder.fill", title: "Finder", bundleID: "com.apple.finder"),
        QuickAction(symbol: "camera.viewfinder", title: "Capture", bundleID: "com.apple.screenshot.launcher"),
        QuickAction(symbol: "calendar", title: "Calendar", bundleID: "com.apple.iCal"),
        QuickAction(symbol: "gearshape.fill", title: "System", bundleID: "com.apple.systempreferences"),
    ]

    func perform() {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else { return }
        let config = NSWorkspace.OpenConfiguration()
        config.activates = true
        NSWorkspace.shared.openApplication(at: url, configuration: config)
    }
}

private struct ActionGrid: View {
    let showsLabels: Bool

    var body: some View {
        let columns = Array(repeating: GridItem(.fixed(showsLabels ? 94 : 40), spacing: 8), count: 2)
        LazyVGrid(columns: columns, spacing: 8) {
            ForEach(QuickAction.all) { action in
                ActionButton(action: action, showsLabel: showsLabels)
            }
        }
        .fixedSize()
    }
}

private struct ActionButton: View {
    let action: QuickAction
    let showsLabel: Bool
    @State private var hovering = false

    var body: some View {
        Button(action: action.perform) {
            VStack(spacing: 5) {
                Image(systemName: action.symbol)
                    .font(.system(size: showsLabel ? 17 : 15, weight: .medium))
                    .symbolRenderingMode(.hierarchical)
                if showsLabel {
                    Text(action.title)
                        .font(.system(size: 10.5, weight: .medium, design: .rounded))
                        .foregroundStyle(.white.opacity(0.65))
                }
            }
            .foregroundStyle(.white)
            .frame(width: showsLabel ? 94 : 40, height: showsLabel ? 58 : 40)
            .background(
                RoundedRectangle(cornerRadius: showsLabel ? 16 : 13, style: .continuous)
                    .fill(.white.opacity(hovering ? 0.16 : 0.08)))
        }
        .buttonStyle(PressableStyle())
        .onHover { h in withAnimation(.easeOut(duration: 0.15)) { hovering = h } }
        .help(action.title)
    }
}

private struct PressableStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.92 : 1)
            .animation(.spring(response: 0.25, dampingFraction: 0.6), value: configuration.isPressed)
    }
}
