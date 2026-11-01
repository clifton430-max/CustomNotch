import AppKit
import SwiftUI

/// Shows the CPU / Memory / Battery breakdown in a glass panel beside the notch. It closes on
/// Escape, its close button, or a click anywhere outside it and the notch.
@MainActor
final class ResourceDetailController {
    private let stats: SystemStats
    private let monitor = ResourceMonitor()
    private let state = DetailState()
    private var panel: DetailPanel?
    private var clickMonitor: Any?
    private(set) var isVisible = false

    private static let cardSize = CGSize(width: 384, height: 548)
    private static let margin: CGFloat = 32

    init(stats: SystemStats) {
        self.stats = stats
    }

    func show(_ kind: ResourceKind, beside notch: CGRect, edge: NotchEdge, on screen: NSScreen) {
        let panel = self.panel ?? makePanel()
        withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) { state.kind = kind }
        guard !isVisible else { return }

        // Sit next to the opened notch, on the screen side of it, growing out from the notch.
        let card = Self.cardSize
        let gap: CGFloat = 12
        var origin: CGPoint
        switch edge {
        case .top: origin = CGPoint(x: notch.midX - card.width / 2, y: notch.minY - gap - card.height)
        case .bottom: origin = CGPoint(x: notch.midX - card.width / 2, y: notch.maxY + gap)
        case .left: origin = CGPoint(x: notch.maxX + gap, y: notch.midY - card.height / 2)
        case .right: origin = CGPoint(x: notch.minX - gap - card.width, y: notch.midY - card.height / 2)
        }
        let visible = screen.visibleFrame.insetBy(dx: 8, dy: 8)
        origin.x = min(max(origin.x, visible.minX), visible.maxX - card.width)
        origin.y = min(max(origin.y, visible.minY), visible.maxY - card.height)
        let m = Self.margin
        panel.setFrame(NSRect(x: origin.x - m, y: origin.y - m, width: card.width + m * 2, height: card.height + m * 2),
                       display: false)

        state.anchor = edge.unitPoint
        isVisible = true
        monitor.start()
        panel.makeKeyAndOrderFront(nil)
        withAnimation(.spring(response: 0.42, dampingFraction: 0.8)) { state.isShown = true }

        clickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            MainActor.assumeIsolated { self?.close() }
        }
    }

    func close() {
        guard isVisible else { return }
        isVisible = false
        monitor.stop()
        if let clickMonitor { NSEvent.removeMonitor(clickMonitor) }
        clickMonitor = nil
        withAnimation(.easeIn(duration: 0.16)) { state.isShown = false }
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(200))
            if !self.isVisible { self.panel?.orderOut(nil) }
        }
    }

    private func makePanel() -> DetailPanel {
        let panel = DetailPanel()
        panel.onCancel = { [weak self] in self?.close() }
        let root = ResourceDetailView(state: state, stats: stats, monitor: monitor) { [weak self] in self?.close() }
        let host = NSHostingView(rootView: root)
        host.sizingOptions = []
        panel.contentView = host
        self.panel = panel
        return panel
    }
}

final class DetailPanel: NSPanel {
    var onCancel: () -> Void = {}

    init() {
        super.init(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        isFloatingPanel = true
        hidesOnDeactivate = false
        // Just beneath the notch so the notch stays on top where they meet.
        level = NSWindow.Level(rawValue: NSWindow.Level.mainMenu.rawValue + 2)
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
    }

    override var canBecomeKey: Bool { true }
    override func cancelOperation(_ sender: Any?) { onCancel() }
}

@MainActor
final class DetailState: ObservableObject {
    @Published var kind: ResourceKind = .cpu
    @Published var isShown = false
    @Published var anchor: UnitPoint = .center
}

// MARK: - Root

private struct ResourceDetailView: View {
    @ObservedObject var state: DetailState
    @ObservedObject var stats: SystemStats
    @ObservedObject var monitor: ResourceMonitor
    let close: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                TabBar(selection: $state.kind)
                Spacer(minLength: 0)
                LiveBadge()
                CloseButton(action: close)
            }
            .padding(.horizontal, 14)
            .padding(.top, 14)
            .padding(.bottom, 10)

            ZStack {
                switch state.kind {
                case .cpu: CPUDetail(stats: stats, monitor: monitor)
                case .memory: MemoryDetail(stats: stats, monitor: monitor)
                case .battery: BatteryDetail(monitor: monitor)
                }
            }
            .id(state.kind)
            .transition(.asymmetric(insertion: .opacity.combined(with: .offset(y: 8)), removal: .opacity))
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
        .frame(width: 384, height: 548)
        // Solid rather than desktop-blurred glass: in this floating panel a live blur costs
        // around 20% CPU for as long as it's open.
        .background(
            ZStack {
                Color(white: 0.075)
                LinearGradient(colors: [.white.opacity(0.07), .clear], startPoint: .top, endPoint: .center)
            })
        .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .strokeBorder(LinearGradient(colors: [.white.opacity(0.2), .white.opacity(0.05)],
                                             startPoint: .top, endPoint: .bottom)))
        // Shadow a static shape behind the panel, so live content updates don't re-render it.
        .background(
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .fill(.black)
                .shadow(color: .black.opacity(0.5), radius: 24, y: 12))
        .scaleEffect(state.isShown ? 1 : 0.9, anchor: state.anchor)
        // No blur here: even at radius 0 it forces the whole panel to be redrawn on the CPU
        // whenever a value animates.
        .opacity(state.isShown ? 1 : 0)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .environment(\.colorScheme, .dark)
    }
}

struct VisualEffect: NSViewRepresentable {
    var material: NSVisualEffectView.Material = .hudWindow

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = material
        view.blendingMode = .behindWindow
        view.state = .active
        return view
    }

    func updateNSView(_ view: NSVisualEffectView, context: Context) {
        view.material = material
    }
}

/// Frosted dark glass: system blur, a black tint to match the notch, and a soft top sheen.
struct GlassBackground: View {
    var tint: Double = 0.55

    var body: some View {
        ZStack {
            VisualEffect()
            Color.black.opacity(tint)
            LinearGradient(colors: [.white.opacity(0.07), .clear], startPoint: .top, endPoint: .center)
        }
    }
}

private struct TabBar: View {
    @Binding var selection: ResourceKind
    @Namespace private var namespace

    var body: some View {
        HStack(spacing: 2) {
            ForEach(ResourceKind.allCases) { kind in
                let selected = kind == selection
                Button {
                    withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) { selection = kind }
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: kind.symbol)
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(selected ? kind.tint : .white.opacity(0.5))
                        Text(kind.title)
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(.white.opacity(selected ? 1 : 0.55))
                    }
                    .padding(.horizontal, 11)
                    .padding(.vertical, 6)
                    .background {
                        if selected {
                            Capsule()
                                .fill(.white.opacity(0.13))
                                .overlay(Capsule().strokeBorder(.white.opacity(0.1)))
                                .matchedGeometryEffect(id: "tab", in: namespace)
                        }
                    }
                    .contentShape(Capsule())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(3)
        .background(Capsule().fill(.white.opacity(0.05)))
    }
}

private struct LiveBadge: View {
    var body: some View {
        // Deliberately static: a looping pulse would redraw the panel continuously.
        HStack(spacing: 4) {
            Circle()
                .fill(Color.green)
                .frame(width: 5, height: 5)
            Text("Live")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.white.opacity(0.45))
        }
        .help("Updates every 2 seconds while open")
    }
}

private struct CloseButton: View {
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: "xmark")
                .font(.system(size: 9.5, weight: .bold))
                .foregroundStyle(.white.opacity(hovering ? 0.9 : 0.5))
                .frame(width: 22, height: 22)
                .background(Circle().fill(.white.opacity(hovering ? 0.16 : 0.08)))
        }
        .buttonStyle(.plain)
        .onHover { h in withAnimation(.easeOut(duration: 0.15)) { hovering = h } }
        .help("Close (Esc)")
    }
}

// MARK: - Shared pieces

private struct DetailScroll<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) { content }
                .padding(.horizontal, 16)
                .padding(.bottom, 16)
        }
        .scrollIndicators(.never)
    }
}

private struct Hero: View {
    let value: String
    let unit: String
    let caption: String

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(value)
                    .font(.system(size: 40, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                Text(unit)
                    .font(.system(size: 15, weight: .medium, design: .rounded))
                    .foregroundStyle(.white.opacity(0.5))
            }
            Text(caption)
                .font(.system(size: 12))
                .foregroundStyle(.white.opacity(0.5))
        }
        .foregroundStyle(.white)
    }
}

private struct SectionTitle: View {
    let title: String
    var trailing: String?

    var body: some View {
        HStack {
            Text(title)
                .font(.system(size: 12.5, weight: .semibold))
                .foregroundStyle(.white.opacity(0.85))
            Spacer()
            if let trailing {
                Text(trailing)
                    .font(.system(size: 10.5))
                    .foregroundStyle(.white.opacity(0.4))
            }
        }
        .padding(.top, 4)
    }
}

private extension View {
    func detailCard(padding: CGFloat = 12) -> some View {
        self.padding(padding)
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(.white.opacity(0.05))
                    .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(.white.opacity(0.07))))
    }
}

private struct Metric: View {
    let label: String
    let value: String
    let tint: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 5) {
                Circle().fill(tint).frame(width: 6, height: 6)
                Text(label)
                    .font(.system(size: 10.5, weight: .medium))
                    .foregroundStyle(.white.opacity(0.5))
            }
            Text(value)
                .font(.system(size: 14, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(.white)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// One application or process, with a soft bar behind it showing its share of the leader.
/// Rows update without animating: with a dozen rows refreshing every couple of seconds,
/// per-row animations kept the panel redrawing most of the time.
private struct UsageRow: View {
    let app: AppUsage
    let icon: NSImage?
    let value: String
    let fraction: Double
    let tint: Color
    var badge: String?

    var body: some View {
        HStack(spacing: 10) {
            AppIcon(app: app, image: icon)
            VStack(alignment: .leading, spacing: 1) {
                Text(app.name)
                    .font(.system(size: 12.5, weight: .medium))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(app.detail)
                    .font(.system(size: 10.5))
                    .foregroundStyle(.white.opacity(0.45))
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            if let badge {
                Text(badge)
                    .font(.system(size: 9.5, weight: .bold))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Capsule().fill(tint.opacity(0.22)))
                    .foregroundStyle(tint)
            }
            Text(value)
                .font(.system(size: 12.5, weight: .semibold, design: .rounded))
                .monospacedDigit()
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(alignment: .leading) {
            GeometryReader { geo in
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(LinearGradient(colors: [tint.opacity(0.22), tint.opacity(0.08)],
                                         startPoint: .leading, endPoint: .trailing))
                    .frame(width: max(0, geo.size.width * min(1, fraction)))
            }
        }
    }
}

private struct AppIcon: View {
    let app: AppUsage
    let image: NSImage?

    var body: some View {
        Group {
            if let image {
                Image(nsImage: image).resizable().interpolation(.high)
            } else {
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(.white.opacity(0.1))
                    .overlay(
                        Image(systemName: app.kind == .system ? "gearshape.2.fill" : "terminal.fill")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(.white.opacity(0.6)))
                    .padding(2)
            }
        }
        .frame(width: 26, height: 26)
    }
}

private struct LoadingRows: View {
    var body: some View {
        HStack(spacing: 8) {
            ProgressView().controlSize(.small)
            Text("Gathering process information…")
                .font(.system(size: 11.5))
                .foregroundStyle(.white.opacity(0.5))
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 24)
    }
}

private func percentText(_ fraction: Double) -> String { "\(Int((fraction * 100).rounded()))%" }

private func bytesText(_ bytes: Double) -> String {
    ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .memory)
}

private func durationText(minutes: Int) -> String {
    let h = minutes / 60, m = minutes % 60
    return h > 0 ? "\(h)h \(m)m" : "\(m)m"
}

// MARK: - CPU

private struct CPUDetail: View {
    @ObservedObject var stats: SystemStats
    @ObservedObject var monitor: ResourceMonitor

    var body: some View {
        let tint = ResourceKind.cpu.tint
        let top = Array(monitor.apps.sorted { $0.cpu > $1.cpu }.prefix(14))
        let leader = max(top.first?.cpu ?? 1, 1)

        DetailScroll {
            Hero(value: percentText(stats.cpu), unit: "in use",
                 caption: "\(ProcessInfo.processInfo.activeProcessorCount) cores · \(loadAverage)")

            VStack(spacing: 12) {
                Sparkline(values: stats.cpuHistory, tint: tint)
                    .frame(height: 54)
                HStack {
                    Metric(label: "User", value: percentText(stats.cpuUser), tint: tint)
                    Metric(label: "System", value: percentText(stats.cpuSystem), tint: .orange)
                    Metric(label: "Idle", value: percentText(max(0, 1 - stats.cpu)), tint: .white.opacity(0.3))
                }
            }
            .detailCard()

            SectionTitle(title: "Using the Most CPU", trailing: "100% = one full core")
            if top.isEmpty {
                LoadingRows()
            } else {
                VStack(spacing: 4) {
                    ForEach(top) { app in
                        UsageRow(app: app, icon: monitor.icon(for: app), value: cpuText(app.cpu),
                                 fraction: app.cpu / leader, tint: tint)
                    }
                }
            }
        }
    }

    private var loadAverage: String {
        var loads = [Double](repeating: 0, count: 3)
        guard getloadavg(&loads, 3) == 3 else { return "" }
        return "Load " + loads.map { String(format: "%.2f", $0) }.joined(separator: "  ")
    }

    private func cpuText(_ value: Double) -> String {
        value < 10 ? String(format: "%.1f%%", value) : "\(Int(value.rounded()))%"
    }
}

private struct Sparkline: View {
    let values: [Double]
    let tint: Color

    var body: some View {
        GeometryReader { geo in
            let points = values.suffix(60)
            let count = max(points.count - 1, 1)
            let path = Path { p in
                for (i, v) in points.enumerated() {
                    let x = geo.size.width * CGFloat(i) / CGFloat(count)
                    let y = geo.size.height * (1 - CGFloat(min(max(v, 0), 1)))
                    i == 0 ? p.move(to: CGPoint(x: x, y: y)) : p.addLine(to: CGPoint(x: x, y: y))
                }
            }
            ZStack {
                // Gridlines at 25% steps.
                ForEach(1..<4) { i in
                    Rectangle().fill(.white.opacity(0.05))
                        .frame(height: 1)
                        .position(x: geo.size.width / 2, y: geo.size.height * CGFloat(i) / 4)
                }
                if points.count > 1 {
                    var area = path
                    let _ = area.addLine(to: CGPoint(x: geo.size.width, y: geo.size.height))
                    let _ = area.addLine(to: CGPoint(x: 0, y: geo.size.height))
                    area.fill(LinearGradient(colors: [tint.opacity(0.35), tint.opacity(0)], startPoint: .top, endPoint: .bottom))
                    path.stroke(tint, style: StrokeStyle(lineWidth: 1.6, lineCap: .round, lineJoin: .round))
                }
            }
        }
    }
}

// MARK: - Memory

private struct MemoryDetail: View {
    @ObservedObject var stats: SystemStats
    @ObservedObject var monitor: ResourceMonitor

    var body: some View {
        let tint = ResourceKind.memory.tint
        let m = stats.memoryBreakdown
        let top = Array(monitor.apps.sorted { $0.memory > $1.memory }.prefix(14))
        let leader = max(top.first?.memory ?? 1, 1)
        let segments: [(String, Double, Color)] = [
            ("App Memory", m.app, tint),
            ("Wired", m.wired, .orange),
            ("Compressed", m.compressed, Color(red: 1, green: 0.42, blue: 0.62)),
            ("Cached Files", m.cached, .white.opacity(0.3)),
        ]

        DetailScroll {
            Hero(value: bytesText(m.used), unit: "used", caption: "of \(bytesText(m.total)) installed memory")

            VStack(alignment: .leading, spacing: 12) {
                GeometryReader { geo in
                    HStack(spacing: 2) {
                        ForEach(segments, id: \.0) { segment in
                            Rectangle()
                                .fill(segment.2)
                                .frame(width: max(0, geo.size.width * segment.1 / m.total - 2))
                        }
                        Spacer(minLength: 0)
                    }
                    .background(.white.opacity(0.06))
                    .clipShape(Capsule())
                }
                .frame(height: 12)

                Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 10) {
                    GridRow {
                        Metric(label: segments[0].0, value: bytesText(segments[0].1), tint: segments[0].2)
                        Metric(label: segments[1].0, value: bytesText(segments[1].1), tint: segments[1].2)
                    }
                    GridRow {
                        Metric(label: segments[2].0, value: bytesText(segments[2].1), tint: segments[2].2)
                        Metric(label: segments[3].0, value: bytesText(segments[3].1), tint: segments[3].2)
                    }
                }

                Rectangle().fill(.white.opacity(0.07)).frame(height: 1)

                HStack {
                    PressureLabel(pressure: m.pressure)
                    Spacer()
                    Text("Swap \(bytesText(m.swapUsed))")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.white.opacity(0.5))
                }
            }
            .detailCard()

            SectionTitle(title: "Using the Most Memory", trailing: "Physical footprint")
            if top.isEmpty {
                LoadingRows()
            } else {
                VStack(spacing: 4) {
                    ForEach(top) { app in
                        UsageRow(app: app, icon: monitor.icon(for: app), value: bytesText(app.memory),
                                 fraction: app.memory / leader, tint: tint)
                    }
                }
            }
        }
    }
}

private struct PressureLabel: View {
    let pressure: Double

    var body: some View {
        let (label, color): (String, Color) = switch pressure {
        case ..<0.5: ("Normal", .green)
        case ..<0.75: ("Elevated", .yellow)
        default: ("High", .red)
        }
        HStack(spacing: 6) {
            Image(systemName: "gauge.with.dots.needle.33percent")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(color)
            Text("Memory Pressure")
                .foregroundStyle(.white.opacity(0.5))
            Text(label)
                .foregroundStyle(color)
        }
        .font(.system(size: 11, weight: .semibold))
    }
}

// MARK: - Battery

private struct BatteryDetail: View {
    @ObservedObject var monitor: ResourceMonitor

    var body: some View {
        if let battery = monitor.battery {
            content(battery)
        } else if monitor.lastUpdated != nil {
            VStack(spacing: 10) {
                Image(systemName: "powerplug.fill")
                    .font(.system(size: 34))
                    .foregroundStyle(.white.opacity(0.4))
                Text("No battery detected")
                    .font(.system(size: 14, weight: .semibold))
                Text("This Mac runs on wall power.")
                    .font(.system(size: 12))
                    .foregroundStyle(.white.opacity(0.5))
            }
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            LoadingRows()
        }
    }

    private func content(_ b: BatteryDetails) -> some View {
        let tint = b.percent < 0.2 && !b.isPluggedIn ? Color.red : ResourceKind.battery.tint
        let energy = Array(monitor.apps.filter { $0.cpu >= 1 }.sorted { $0.cpu > $1.cpu }.prefix(6))
        let leader = max(energy.first?.cpu ?? 1, 1)

        return DetailScroll {
            HStack(spacing: 16) {
                BatteryGlyph(level: b.percent, tint: tint, isCharging: b.isCharging || b.isPluggedIn)
                    .frame(width: 92, height: 42)
                Hero(value: percentText(b.percent), unit: "", caption: status(b))
            }
            .padding(.top, 2)

            Grid(horizontalSpacing: 8, verticalSpacing: 8) {
                GridRow {
                    if b.isCharging, let watts = b.batteryWatts, watts > 0 {
                        Tile(symbol: "bolt.fill", title: "Charging Rate", value: String(format: "%.1f W", watts),
                             caption: "Into the battery", tint: tint)
                    } else {
                        Tile(symbol: "bolt.horizontal.fill", title: "Power Draw",
                             value: b.systemWatts.map { String(format: "%.1f W", $0) } ?? "—",
                             caption: "Whole system right now", tint: .yellow)
                    }
                    Tile(symbol: "powerplug.fill", title: "Power Adapter",
                         value: b.adapterWatts.map { "\($0) W" } ?? (b.isPluggedIn ? "Connected" : "None"),
                         caption: b.isPluggedIn ? "Connected" : "Not connected", tint: .white.opacity(0.7))
                }
                GridRow {
                    Tile(symbol: "heart.fill", title: "Maximum Capacity",
                         value: b.maxCapacityPercent.map { "\($0)%" } ?? "—",
                         caption: capacityCaption(b), tint: .pink)
                    Tile(symbol: "arrow.triangle.2.circlepath", title: "Cycle Count",
                         value: b.cycleCount.map(String.init) ?? "—",
                         caption: "Full charge cycles", tint: .cyan)
                }
                GridRow {
                    Tile(symbol: "waveform.path.ecg", title: "Voltage",
                         value: b.voltage.map { String(format: "%.2f V", $0) } ?? "—",
                         caption: b.temperature.map { String(format: "%.1f °C", $0) } ?? "Battery pack",
                         tint: .orange)
                    Tile(symbol: "leaf.fill", title: "Low Power Mode", value: b.isLowPowerMode ? "On" : "Off",
                         caption: "System Settings › Battery", tint: .green)
                }
            }

            SectionTitle(title: "Using Significant Energy", trailing: "Estimated from CPU activity")
            if energy.isEmpty {
                Text(monitor.lastUpdated == nil ? "Measuring…" : "No apps are using significant energy.")
                    .font(.system(size: 11.5))
                    .foregroundStyle(.white.opacity(0.5))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
                    .detailCard(padding: 0)
            } else {
                VStack(spacing: 4) {
                    ForEach(energy) { app in
                        let impact = app.cpu >= 50 ? "HIGH" : (app.cpu >= 15 ? "MED" : "LOW")
                        UsageRow(app: app, icon: monitor.icon(for: app),
                                 value: "\(Int(app.cpu.rounded()))%", fraction: app.cpu / leader,
                                 tint: impact == "HIGH" ? .orange : ResourceKind.battery.tint, badge: impact)
                    }
                }
            }
        }
    }

    private func status(_ b: BatteryDetails) -> String {
        if b.isFullyCharged { return "Fully charged" }
        if b.isCharging {
            return b.minutesToFull.map { "Charging · \(durationText(minutes: $0)) until full" } ?? "Charging"
        }
        if b.isPluggedIn { return "Plugged in · Not charging" }
        return b.minutesToEmpty.map { "On battery · \(durationText(minutes: $0)) remaining" } ?? "On battery · Estimating…"
    }

    private func capacityCaption(_ b: BatteryDetails) -> String {
        guard let full = b.fullChargeCapacity, let design = b.designCapacity else { return "Relative to new" }
        return "\(full) of \(design) mAh"
    }
}

private struct BatteryGlyph: View {
    let level: Double
    let tint: Color
    let isCharging: Bool

    var body: some View {
        HStack(spacing: 3) {
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(.white.opacity(0.35), lineWidth: 2)
                GeometryReader { geo in
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(LinearGradient(colors: [tint, tint.opacity(0.75)], startPoint: .top, endPoint: .bottom))
                        .frame(width: max(6, (geo.size.width) * min(1, level)))
                }
                .padding(5)
                if isCharging {
                    Image(systemName: "bolt.fill")
                        .font(.system(size: 18, weight: .bold))
                        .foregroundStyle(.white)
                        .shadow(color: .black.opacity(0.4), radius: 2)
                        .frame(maxWidth: .infinity)
                }
            }
            RoundedRectangle(cornerRadius: 2).fill(.white.opacity(0.35)).frame(width: 4, height: 14)
        }
        .animation(.smooth(duration: 0.6), value: level)
    }
}

private struct Tile: View {
    let symbol: String
    let title: String
    let value: String
    let caption: String
    let tint: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 5) {
                Image(systemName: symbol)
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(tint)
                Text(title)
                    .font(.system(size: 10.5, weight: .medium))
                    .foregroundStyle(.white.opacity(0.5))
            }
            Text(value)
                .font(.system(size: 18, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(.white)
            Text(caption)
                .font(.system(size: 10))
                .foregroundStyle(.white.opacity(0.4))
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .detailCard(padding: 11)
    }
}
