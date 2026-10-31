import AppKit
import SwiftUI

struct NotchRootView: View {
    @ObservedObject var model: NotchModel
    @ObservedObject var stats: SystemStats

    var body: some View {
        let pad = NotchMetrics.earPad
        let shape = NotchShape(edge: model.edge, ear: model.ear, radius: model.radius)

        ZStack {
            shape
                .fill(Color.black)
                .shadow(color: .black.opacity(model.isFloating ? 0.55 : (model.isExpanded ? 0.4 : 0)),
                        radius: model.isFloating ? 24 : 18,
                        y: model.isFloating ? 12 : 6)

            NotchContent(model: model, stats: stats)
                .frame(width: model.bodySize.width, height: model.bodySize.height, alignment: model.edge.alignment)
                .padding(pad)
                .mask(shape)

            shape
                .stroke(Color.white.opacity(model.isFloating ? 0.16 : 0), lineWidth: 0.75)
        }
        .frame(width: model.bodySize.width + pad * 2, height: model.bodySize.height + pad * 2)
        .scaleEffect(model.isAppeared ? (model.isFloating ? 1.05 : 1) : 0.35, anchor: model.edge.unitPoint)
        .opacity(model.isAppeared ? 1 : 0)
        .blur(radius: model.isAppeared ? 0 : 8)
        .position(model.bodyCenter)
        .frame(width: NotchMetrics.canvas, height: NotchMetrics.canvas)
        .environment(\.colorScheme, .dark)
    }
}

// MARK: - Content

private struct NotchContent: View {
    @ObservedObject var model: NotchModel
    @ObservedObject var stats: SystemStats

    var body: some View {
        let horizontal = model.edge.isHorizontal
        ZStack(alignment: model.edge.alignment) {
            if model.isExpanded {
                Group {
                    if horizontal {
                        HorizontalExpanded(model: model, stats: stats)
                    } else {
                        VerticalExpanded(model: model, stats: stats)
                    }
                }
                .scaled(to: NotchMetrics.expanded(horizontal: horizontal), by: model.sizing.scale)
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
                        HorizontalCollapsed(stats: stats)
                    } else {
                        VerticalCollapsed(stats: stats)
                    }
                }
                .id(horizontal)
                .scaled(to: model.sizing.collapsedLayout(horizontal: horizontal), by: model.sizing.scale)
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

/// Fades, de-blurs and gently scales content in from the attached edge.
private struct Reveal: ViewModifier {
    var progress: CGFloat
    var anchor: UnitPoint

    func body(content: Content) -> some View {
        content
            .opacity(progress)
            .blur(radius: (1 - progress) * 10)
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
            TimelineView(.periodic(from: .now, by: 1)) { context in
                Text(context.date, format: .dateTime.hour().minute())
            }
        }
        .font(.system(size: 12, weight: .semibold, design: .rounded))
        .monospacedDigit()
        .foregroundStyle(.white.opacity(0.94))
        .padding(.horizontal, 16)
    }
}

private struct VerticalCollapsed: View {
    @ObservedObject var stats: SystemStats

    var body: some View {
        VStack(spacing: 12) {
            Ring(value: stats.battery, tint: stats.batteryTint, lineWidth: 2.5)
                .frame(width: 15, height: 15)
            TimelineView(.periodic(from: .now, by: 1)) { context in
                VStack(spacing: 1) {
                    Text(context.date, format: .dateTime.hour(.defaultDigits(amPM: .omitted)))
                    Text(context.date, format: .dateTime.minute(.twoDigits))
                        .foregroundStyle(.white.opacity(0.6))
                }
            }
            .font(.system(size: 13, weight: .semibold, design: .rounded))
            .monospacedDigit()
            .foregroundStyle(.white.opacity(0.94))
            Circle()
                .fill(.white.opacity(0.35))
                .frame(width: 4, height: 4)
        }
    }
}

// MARK: - Expanded

private struct HorizontalExpanded: View {
    @ObservedObject var model: NotchModel
    @ObservedObject var stats: SystemStats

    var body: some View {
        VStack(spacing: 8) {
            ExpandedHeader(model: model)
            HStack(alignment: .center, spacing: 12) {
                ClockBlock(stats: stats)
                    .frame(maxWidth: .infinity, alignment: .leading)
                StatRings(stats: stats, size: 42)
                Rectangle().fill(Color.white.opacity(0.1)).frame(width: 1, height: 70)
                ActionGrid(showsLabels: false)
            }
        }
        .padding(.horizontal, 20)
        .padding(.top, 12)
        .padding(.bottom, 16)
    }
}

private struct VerticalExpanded: View {
    @ObservedObject var model: NotchModel
    @ObservedObject var stats: SystemStats

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            ExpandedHeader(model: model)
            ClockBlock(stats: stats)
            StatRings(stats: stats, size: 52)
                .frame(maxWidth: .infinity)
            ActionGrid(showsLabels: true)
                .frame(maxWidth: .infinity)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 18)
    }
}

/// Date on the left; pin and settings controls in the top-right corner. The controls only
/// exist while the notch is open on hover, and settle in just after the panel does.
private struct ExpandedHeader: View {
    @ObservedObject var model: NotchModel
    @State private var showsControls = false

    var body: some View {
        HStack(spacing: 4) {
            TimelineView(.periodic(from: .now, by: 60)) { context in
                Text(context.date, format: .dateTime.weekday(.abbreviated).month(.abbreviated).day())
                    .lineLimit(1)
                    .font(.system(size: 11, weight: .semibold, design: .rounded))
                    .textCase(.uppercase)
                    .foregroundStyle(.white.opacity(0.5))
            }
            Spacer(minLength: 4)
            Group {
                PinButton(isPinned: $model.isPinned)
                HeaderIconButton(symbol: "gearshape.fill", help: "Notch Settings", spinsOnHover: true,
                                 action: model.openSettings)
            }
            .opacity(showsControls ? 1 : 0)
            .scaleEffect(showsControls ? 1 : 0.5)
            .blur(radius: showsControls ? 0 : 3)
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

private struct ClockBlock: View {
    @ObservedObject var stats: SystemStats

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
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

private struct StatRings: View {
    @ObservedObject var stats: SystemStats
    let size: CGFloat

    var body: some View {
        HStack(spacing: 12) {
            StatRing(value: stats.battery, label: "Battery",
                     symbol: stats.isCharging ? "bolt.fill" : nil,
                     tint: Color(red: 0.30, green: 0.85, blue: 0.45), size: size)
            StatRing(value: stats.cpu, label: "CPU", symbol: nil,
                     tint: Color(red: 0.25, green: 0.65, blue: 1), size: size)
            StatRing(value: stats.memory, label: "Memory", symbol: nil,
                     tint: Color(red: 0.72, green: 0.45, blue: 1), size: size)
        }
    }
}

private struct StatRing: View {
    let value: Double
    let label: String
    let symbol: String?
    let tint: Color
    let size: CGFloat

    var body: some View {
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
            Text(label)
                .font(.system(size: 10, weight: .medium, design: .rounded))
                .foregroundStyle(.white.opacity(0.5))
                .fixedSize()
        }
        .animation(.smooth(duration: 0.6), value: value)
    }
}

private struct Ring: View {
    let value: Double
    let tint: Color
    let lineWidth: CGFloat

    var body: some View {
        ZStack {
            Circle().stroke(tint.opacity(0.18), lineWidth: lineWidth)
            Circle()
                .trim(from: 0, to: max(0.001, min(1, value)))
                .stroke(
                    AngularGradient(colors: [tint.opacity(0.7), tint], center: .center,
                                    startAngle: .degrees(0), endAngle: .degrees(360 * max(0.001, value))),
                    style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
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
        QuickAction(symbol: "switch.2", title: "System", bundleID: "com.apple.systempreferences"),
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
