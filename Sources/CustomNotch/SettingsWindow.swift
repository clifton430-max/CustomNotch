import AppKit
import SwiftUI

@MainActor
final class SettingsWindowController {
    private let settings: NotchSettings
    private let stats: SystemStats
    private var window: NSWindow?

    init(settings: NotchSettings, stats: SystemStats) {
        self.settings = settings
        self.stats = stats
    }

    func show() {
        if window == nil {
            let w = NSWindow(contentRect: NSRect(origin: .zero, size: SettingsRoute.home.windowSize),
                             styleMask: [.titled, .closable, .fullSizeContentView],
                             backing: .buffered, defer: false)
            w.title = "Notch Settings"
            w.titleVisibility = .hidden
            w.titlebarAppearsTransparent = true
            w.appearance = NSAppearance(named: .darkAqua)
            // Clear so the SwiftUI glass can blur the desktop behind the window.
            w.isOpaque = false
            w.backgroundColor = .clear
            w.isReleasedWhenClosed = false
            w.animationBehavior = .alertPanel
            w.level = .floating
            let root = SettingsView(settings: settings, stats: stats) { [weak self] size in
                self?.resizeWindow(to: size)
            }
            let host = NSHostingView(rootView: root)
            host.sizingOptions = []
            w.contentView = host
            w.center()
            window = w
        }
        NSApp.activate()
        window?.makeKeyAndOrderFront(nil)
    }

    /// Grows or shrinks the window around its top edge so pages can have their own size.
    private func resizeWindow(to size: CGSize) {
        guard let w = window else { return }
        let old = w.frame
        var frame = NSRect(x: old.midX - size.width / 2, y: old.maxY - size.height,
                           width: size.width, height: size.height)
        if let visible = w.screen?.visibleFrame {
            frame.origin.x = min(max(frame.minX, visible.minX), visible.maxX - frame.width)
            frame.origin.y = min(max(frame.minY, visible.minY), visible.maxY - frame.height)
        }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.36
            context.timingFunction = CAMediaTimingFunction(controlPoints: 0.2, 0.9, 0.25, 1)
            w.animator().setFrame(frame, display: true)
        }
    }
}

// MARK: - Navigation

/// Every settings page. Adding a page means adding a case here, a row on the home page that
/// opens it, and a branch in `SettingsView.page(for:)`.
enum SettingsRoute: Hashable {
    case home
    case appearance

    var title: String {
        switch self {
        case .home: "Notch Settings"
        case .appearance: "Appearance & Size"
        }
    }

    var windowSize: CGSize {
        switch self {
        case .home: CGSize(width: 500, height: 624)
        case .appearance: CGSize(width: 760, height: 668)
        }
    }
}

private enum Theme {
    static let secondary = Color.white.opacity(0.55)
    static let tertiary = Color.white.opacity(0.35)
    static let separator = Color.white.opacity(0.08)
    static let page = Animation.spring(response: 0.44, dampingFraction: 0.9)
    static let control = Animation.spring(response: 0.32, dampingFraction: 0.82)
    static let violet = [Color(red: 0.47, green: 0.42, blue: 1), Color(red: 0.74, green: 0.36, blue: 0.96)]
    static let graphite = [Color(white: 0.42), Color(white: 0.24)]
}

private struct SettingsView: View {
    @ObservedObject var settings: NotchSettings
    @ObservedObject var stats: SystemStats
    let resizeWindow: (CGSize) -> Void

    @State private var route: SettingsRoute = .home
    @State private var forward = true
    @State private var editingEdge: NotchEdge = .right

    var body: some View {
        VStack(spacing: 0) {
            Toolbar(route: route) { navigate(to: .home) }
            ZStack(alignment: .top) {
                page(for: route)
                    .id(route)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                    .transition(.asymmetric(
                        insertion: .offset(x: forward ? 60 : -60).combined(with: .opacity),
                        removal: .offset(x: forward ? -60 : 60).combined(with: .opacity)))
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .clipped()
        }
        .foregroundStyle(.white)
        .background(GlassBackground(tint: 0.5).ignoresSafeArea())
        .environment(\.colorScheme, .dark)
        #if DEBUG
        .onReceive(DistributedNotificationCenter.default().publisher(for: .init("CustomNotch.debugRoute"))) { note in
            if let edge = (note.object as? String).flatMap(NotchEdge.init(rawValue:)) {
                navigate(to: .appearance, editing: edge)
            } else {
                navigate(to: route == .home ? .appearance : .home)
            }
        }
        #endif
    }

    @ViewBuilder
    private func page(for route: SettingsRoute) -> some View {
        switch route {
        case .home:
            HomePage(settings: settings, stats: stats) { edge in navigate(to: .appearance, editing: edge) }
        case .appearance:
            AppearancePage(settings: settings, stats: stats, edge: $editingEdge)
        }
    }

    private func navigate(to next: SettingsRoute, editing edge: NotchEdge? = nil) {
        guard next != route else { return }
        if let edge { editingEdge = edge } else if next == .appearance { editingEdge = settings.dockedEdge }
        // Set the direction first so the outgoing page picks up the matching transition.
        forward = next != .home
        resizeWindow(next.windowSize)
        DispatchQueue.main.async {
            withAnimation(Theme.page) { route = next }
        }
    }
}

/// A System Settings-style toolbar: room for the traffic lights, a back button on inner
/// pages, and the page title.
private struct Toolbar: View {
    let route: SettingsRoute
    let back: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Color.clear.frame(width: 64)
            if route != .home {
                BackButton(action: back)
                    .transition(.scale(scale: 0.6).combined(with: .opacity))
            }
            Text(route.title)
                .font(.system(size: 14, weight: .semibold))
                .id(route)
                .transition(.opacity.combined(with: .offset(y: 4)))
            Spacer()
        }
        .padding(.horizontal, 12)
        .frame(height: 52)
        .animation(Theme.page, value: route)
        .overlay(alignment: .bottom) { Rectangle().fill(Theme.separator).frame(height: 1) }
    }
}

private struct BackButton: View {
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: "chevron.left")
                .font(.system(size: 12, weight: .semibold))
                .frame(width: 28, height: 24)
                .background(RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(.white.opacity(hovering ? 0.12 : 0.06)))
                .contentShape(Rectangle())
        }
        .buttonStyle(PressStyle(scale: 0.92))
        .keyboardShortcut("[", modifiers: .command)
        .onHover { h in withAnimation(.easeOut(duration: 0.15)) { hovering = h } }
        .help("Back")
    }
}

// MARK: - Shared pieces

private struct PressStyle: ButtonStyle {
    var scale: CGFloat = 0.98

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? scale : 1)
            .opacity(configuration.isPressed ? 0.85 : 1)
            .animation(.spring(response: 0.25, dampingFraction: 0.65), value: configuration.isPressed)
    }
}

private extension View {
    /// A rounded glass group, like the inset sections in System Settings.
    func glassGroup(cornerRadius: CGFloat = 12) -> some View {
        background(
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .fill(.white.opacity(0.06))
                .overlay(
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .strokeBorder(LinearGradient(colors: [.white.opacity(0.14), .white.opacity(0.05)],
                                                     startPoint: .top, endPoint: .bottom))))
    }
}

private struct GroupHeader: View {
    let title: String

    var body: some View {
        Text(title)
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(Theme.secondary)
            .padding(.leading, 6)
    }
}

private struct IconTile: View {
    let symbol: String
    let colors: [Color]
    var size: CGFloat = 24

    var body: some View {
        RoundedRectangle(cornerRadius: size * 0.26, style: .continuous)
            .fill(LinearGradient(colors: colors, startPoint: .top, endPoint: .bottom))
            .overlay(RoundedRectangle(cornerRadius: size * 0.26, style: .continuous).strokeBorder(.white.opacity(0.16)))
            .overlay(
                Image(systemName: symbol)
                    .font(.system(size: size * 0.5, weight: .semibold))
                    .foregroundStyle(.white))
            .frame(width: size, height: size)
            .shadow(color: .black.opacity(0.25), radius: 1.5, y: 1)
    }
}

/// A navigation row: icon, title, trailing value and a chevron, highlighted on hover.
private struct NavigationRow<Trailing: View>: View {
    let symbol: String
    let colors: [Color]
    let title: String
    let action: () -> Void
    @ViewBuilder let trailing: Trailing
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                IconTile(symbol: symbol, colors: colors)
                Text(title)
                    .font(.system(size: 13))
                Spacer(minLength: 8)
                trailing
                    .font(.system(size: 12.5))
                    .foregroundStyle(Theme.secondary)
                Image(systemName: "chevron.right")
                    .font(.system(size: 10.5, weight: .semibold))
                    .foregroundStyle(hovering ? Color.white.opacity(0.7) : Theme.tertiary)
                    .offset(x: hovering ? 1.5 : 0)
            }
            .padding(.horizontal, 10)
            .frame(height: 42)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(.white.opacity(hovering ? 0.06 : 0)))
            .contentShape(Rectangle())
        }
        .buttonStyle(PressStyle(scale: 0.99))
        .onHover { h in withAnimation(.easeOut(duration: 0.12)) { hovering = h } }
    }
}

private struct RowSeparator: View {
    var body: some View {
        Rectangle().fill(Theme.separator).frame(height: 1).padding(.leading, 44).padding(.trailing, 10)
    }
}

private func percent(_ value: CGFloat) -> String { "\(Int((value * 100).rounded()))%" }

private func pointSize(_ sizing: NotchSizing, on edge: NotchEdge) -> String {
    let size = sizing.collapsed(horizontal: edge.isHorizontal)
    return "\(Int(size.width.rounded())) × \(Int(size.height.rounded())) pt"
}

private struct Wallpaper: View {
    var body: some View {
        ZStack {
            LinearGradient(colors: [Color(red: 0.12, green: 0.13, blue: 0.34),
                                    Color(red: 0.34, green: 0.17, blue: 0.48),
                                    Color(red: 0.76, green: 0.36, blue: 0.44)],
                           startPoint: .topLeading, endPoint: .bottomTrailing)
            RadialGradient(colors: [Color(red: 0.45, green: 0.55, blue: 1).opacity(0.45), .clear],
                           center: UnitPoint(x: 0.2, y: 0.85), startRadius: 0, endRadius: 320)
            RadialGradient(colors: [Color(red: 1, green: 0.6, blue: 0.4).opacity(0.35), .clear],
                           center: UnitPoint(x: 0.9, y: 0.2), startRadius: 0, endRadius: 280)
        }
    }
}

/// The collapsed notch drawn at `zoom`, for previews. Its frame includes the ear padding;
/// place it with `docked(to:zoom:)` so the body meets the container's edge.
private struct NotchMiniature: View {
    let edge: NotchEdge
    let sizing: NotchSizing
    @ObservedObject var stats: SystemStats
    let zoom: CGFloat
    var outlineActive = false

    var body: some View {
        let pad = NotchMetrics.earPad * zoom
        let k = sizing.scale * zoom
        let layout = sizing.collapsedLayout(horizontal: edge.isHorizontal)
        let size = CGSize(width: layout.width * k, height: layout.height * k)
        let shape = NotchShape(edge: edge, ear: 9 * k, radius: 14 * k, pad: pad)

        ZStack {
            shape.fill(Color.black)
                .shadow(color: .black.opacity(outlineActive ? 0.55 : 0.3), radius: outlineActive ? 18 : 10)
            Group {
                if edge.isHorizontal {
                    HorizontalCollapsed(stats: stats)
                } else {
                    VerticalCollapsed(stats: stats, size: layout, edge: edge)
                }
            }
            .frame(width: layout.width, height: layout.height)
            .scaleEffect(k)
            .frame(width: size.width, height: size.height)
            .padding(pad)
            .mask(shape)
            ResizeOutline(shape: NotchShape(edge: edge, ear: 9 * k, radius: 14 * k, pad: pad, isClosed: false),
                          isActive: outlineActive)
        }
        .frame(width: size.width + pad * 2, height: size.height + pad * 2)
        .environment(\.colorScheme, .dark)
    }
}

private extension View {
    /// Pins a notch-sized view to `edge` of its container, overhanging by the ear padding so
    /// the body itself touches the edge.
    func docked(to edge: NotchEdge, zoom: CGFloat) -> some View {
        let pad = -NotchMetrics.earPad * zoom
        let edges: Edge.Set = switch edge {
        case .top: .top
        case .bottom: .bottom
        case .left: .leading
        case .right: .trailing
        }
        return frame(maxWidth: .infinity, maxHeight: .infinity, alignment: edge.alignment)
            .padding(edges, pad)
    }
}

// MARK: - Home

private struct HomePage: View {
    @ObservedObject var settings: NotchSettings
    @ObservedObject var stats: SystemStats
    let openAppearance: (NotchEdge?) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HeroCard(settings: settings, stats: stats) { openAppearance(nil) }

            VStack(alignment: .leading, spacing: 7) {
                GroupHeader(title: "Appearance")
                VStack(spacing: 0) {
                    NavigationRow(symbol: "rectangle.topthird.inset.filled", colors: Theme.violet,
                                  title: "Appearance & Size", action: { openAppearance(nil) }) {
                        Text(percent(settings.sizing(for: settings.dockedEdge).scale))
                            .monospacedDigit()
                    }
                }
                .padding(4)
                .glassGroup()
            }

            VStack(alignment: .leading, spacing: 7) {
                GroupHeader(title: "Edge Presets")
                VStack(spacing: 0) {
                    ForEach(Array(NotchEdge.allCases.enumerated()), id: \.element) { index, edge in
                        if index > 0 { RowSeparator() }
                        NavigationRow(symbol: edge.symbol, colors: Theme.graphite, title: edge.title,
                                      action: { openAppearance(edge) }) {
                            HStack(spacing: 8) {
                                if edge == settings.dockedEdge { DockedBadge() }
                                Text(pointSize(settings.sizing(for: edge), on: edge))
                                    .monospacedDigit()
                                    .contentTransition(.numericText())
                            }
                        }
                    }
                }
                .padding(4)
                .glassGroup()
                Text("Each edge remembers its own size. Move the notch and it switches automatically.")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.tertiary)
                    .padding(.horizontal, 6)
            }

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 22)
        .padding(.top, 18)
        .padding(.bottom, 16)
    }
}

private struct DockedBadge: View {
    var body: some View {
        Text("Docked")
            .font(.system(size: 9.5, weight: .bold))
            .foregroundStyle(Color.green)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(Capsule().fill(Color.green.opacity(0.16)))
    }
}

/// Like the account card at the top of System Settings: a live miniature of the notch on the
/// edge it's docked to, with a summary underneath.
private struct HeroCard: View {
    @ObservedObject var settings: NotchSettings
    @ObservedObject var stats: SystemStats
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        let edge = settings.dockedEdge
        let sizing = settings.sizing(for: edge)
        let collapsed = sizing.collapsed(horizontal: edge.isHorizontal)
        // Fit the miniature in the 118 pt strip whatever its size.
        let zoom = min(0.8, (edge.isHorizontal ? 400 : 100) / (edge.isHorizontal ? collapsed.width : collapsed.height))

        Button(action: action) {
            VStack(spacing: 0) {
                ZStack {
                    Wallpaper()
                    NotchMiniature(edge: edge, sizing: sizing, stats: stats, zoom: zoom)
                        .docked(to: edge, zoom: zoom)
                        .id(edge)
                        .transition(.opacity.combined(with: .scale(scale: 0.9)))
                }
                .frame(height: 118)
                .clipped()

                HStack(spacing: 12) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("CustomNotch")
                            .font(.system(size: 14, weight: .semibold))
                        Text("Docked to the \(edge.rawValue) edge · \(pointSize(sizing, on: edge))")
                            .font(.system(size: 11.5))
                            .foregroundStyle(Theme.secondary)
                            .contentTransition(.numericText())
                    }
                    Spacer()
                    Text("Customize")
                        .font(.system(size: 12, weight: .medium))
                        .padding(.horizontal, 11)
                        .padding(.vertical, 5)
                        .background(Capsule().fill(.white.opacity(hovering ? 0.18 : 0.1)))
                }
                .padding(.horizontal, 14)
                .frame(height: 56)
                .background(.white.opacity(0.04))
            }
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(.white.opacity(0.12)))
            .shadow(color: .black.opacity(0.3), radius: 12, y: 6)
            .animation(Theme.control, value: edge)
            .animation(Theme.control, value: sizing)
        }
        .buttonStyle(PressStyle(scale: 0.99))
        .onHover { h in withAnimation(.easeOut(duration: 0.15)) { hovering = h } }
    }
}

// MARK: - Appearance & Size

private struct AppearancePage: View {
    @ObservedObject var settings: NotchSettings
    @ObservedObject var stats: SystemStats
    @Binding var edge: NotchEdge

    var body: some View {
        let sizing = settings.sizing(for: edge)

        VStack(spacing: 14) {
            VStack(spacing: 8) {
                EdgePicker(selection: $edge, docked: settings.dockedEdge)
                Group {
                    if edge == settings.dockedEdge {
                        Label("Docked here — changes apply to the notch as you make them", systemImage: "dot.radiowaves.left.and.right")
                    } else {
                        Label("Saved for when the notch is docked to the \(edge.rawValue) edge", systemImage: "tray.and.arrow.down")
                    }
                }
                .font(.system(size: 11.5))
                .foregroundStyle(Theme.secondary)
                .id(edge == settings.dockedEdge)
                .transition(.opacity)
            }

            ResizablePreview(settings: settings, stats: stats, edge: edge)
                .frame(height: 330)

            HStack(spacing: 0) {
                SizeSlider(title: "Width", symbol: "arrow.left.and.right", value: binding(\.width),
                           range: NotchSizing.widthRange)
                ColumnDivider()
                SizeSlider(title: "Height", symbol: "arrow.up.and.down", value: binding(\.height),
                           range: NotchSizing.heightRange)
                ColumnDivider()
                SizeSlider(title: "Overall Size", symbol: "arrow.up.left.and.arrow.down.right", value: binding(\.scale),
                           range: NotchSizing.scaleRange)
            }
            .padding(.vertical, 15)
            .glassGroup(cornerRadius: 14)

            HStack {
                Label("\(pointSize(sizing, on: edge)) on the \(edge.rawValue) edge", systemImage: "ruler")
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(Theme.secondary)
                    .monospacedDigit()
                    .contentTransition(.numericText())
                Spacer()
                ResetButton(title: "Reset \(edge.title) Edge", isEnabled: sizing != .standard) {
                    withAnimation(.spring(response: 0.45, dampingFraction: 0.8)) { settings.reset(edge) }
                }
            }
        }
        .padding(.horizontal, 26)
        .padding(.top, 14)
        .padding(.bottom, 18)
        .animation(Theme.control, value: edge)
    }

    private func binding(_ key: WritableKeyPath<NotchSizing, CGFloat>) -> Binding<CGFloat> {
        Binding(
            get: { settings.sizing(for: edge)[keyPath: key] },
            set: { value in
                var sizing = settings.sizing(for: edge)
                sizing[keyPath: key] = value
                settings.setSizing(sizing, for: edge)
            })
    }
}

/// A glass segmented control with a sliding selection, marking the edge the notch is on.
private struct EdgePicker: View {
    @Binding var selection: NotchEdge
    let docked: NotchEdge
    @Namespace private var namespace

    var body: some View {
        HStack(spacing: 2) {
            ForEach(NotchEdge.allCases, id: \.self) { edge in
                let selected = edge == selection
                Button {
                    withAnimation(Theme.control) { selection = edge }
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: edge.symbol)
                            .font(.system(size: 11, weight: .semibold))
                        Text(edge.title)
                            .font(.system(size: 12.5, weight: .medium))
                        if edge == docked {
                            Circle().fill(Color.green).frame(width: 5, height: 5)
                        }
                    }
                    .foregroundStyle(.white.opacity(selected ? 1 : 0.6))
                    .frame(width: 112, height: 28)
                    .background {
                        if selected {
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .fill(.white.opacity(0.16))
                                .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(.white.opacity(0.12)))
                                .shadow(color: .black.opacity(0.25), radius: 3, y: 1)
                                .matchedGeometryEffect(id: "edge", in: namespace)
                        }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(3)
        .glassGroup(cornerRadius: 11)
    }
}

private struct ColumnDivider: View {
    var body: some View {
        Rectangle().fill(Theme.separator).frame(width: 1, height: 50)
    }
}

private struct ResetButton: View {
    let title: String
    let isEnabled: Bool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Label(title, systemImage: "arrow.counterclockwise")
                .font(.system(size: 12, weight: .medium))
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(.white.opacity(hovering && isEnabled ? 0.16 : 0.09)))
                .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(.white.opacity(0.1)))
        }
        .buttonStyle(PressStyle(scale: 0.95))
        .disabled(!isEnabled)
        .opacity(isEnabled ? 1 : 0.4)
        .animation(.easeOut(duration: 0.2), value: isEnabled)
        .onHover { h in withAnimation(.easeOut(duration: 0.15)) { hovering = h } }
    }
}

private struct SizeSlider: View {
    let title: String
    let symbol: String
    @Binding var value: CGFloat
    let range: ClosedRange<CGFloat>

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 7) {
                Image(systemName: symbol)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Theme.secondary)
                Text(title)
                    .font(.system(size: 12.5, weight: .medium))
                Spacer(minLength: 4)
                Text(percent(value))
                    .font(.system(size: 11.5, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .contentTransition(.numericText(value: Double(value)))
                    .animation(.snappy, value: value)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .background(Capsule().fill(.white.opacity(0.09)))
            }
            Slider(value: $value, in: range)
                .controlSize(.small)
                .tint(.white)
        }
        .padding(.horizontal, 18)
    }
}

// MARK: - Resizable preview

/// A desktop with the notch docked to `edge`. The notch's free edges and outer corners can be
/// dragged like a window's to set width and height; a trackpad pinch sets the overall size.
/// Everything writes straight to `settings`, so the sliders, and the real notch when it's
/// docked on this edge, follow along.
private struct ResizablePreview: View {
    @ObservedObject var settings: NotchSettings
    @ObservedObject var stats: SystemStats
    let edge: NotchEdge

    @State private var activeHandle: Handle?
    @State private var dragStart: NotchSizing?
    @State private var pinchStart: CGFloat?
    @State private var hovering = false

    /// Fixed per orientation so a drag maps to the same change throughout.
    private var zoom: CGFloat { edge.isHorizontal ? 1.5 : 0.92 }

    enum Handle: CaseIterable {
        case start, end, depth, startCorner, endCorner

        var alongSign: CGFloat {
            switch self {
            case .start, .startCorner: -1
            case .end, .endCorner: 1
            case .depth: 0
            }
        }

        var resizesDepth: Bool { self == .depth || self == .startCorner || self == .endCorner }
    }

    var body: some View {
        let sizing = settings.sizing(for: edge)
        let k = sizing.scale * zoom
        let layout = sizing.collapsedLayout(horizontal: edge.isHorizontal)
        let body = CGSize(width: layout.width * k, height: layout.height * k)
        let pad = NotchMetrics.earPad * zoom

        ZStack {
            Wallpaper()

            ZStack {
                NotchMiniature(edge: edge, sizing: sizing, stats: stats, zoom: zoom, outlineActive: activeHandle != nil)
                handles(body: body)
                    .padding(pad)
            }
            .docked(to: edge, zoom: zoom)
            .id(edge)
            .transition(.opacity.combined(with: .scale(scale: 0.92, anchor: edge.unitPoint)))

            footer(sizing: sizing)
        }
        .coordinateSpace(name: "preview")
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(.white.opacity(0.12)))
        .shadow(color: .black.opacity(0.3), radius: 14, y: 6)
        .onHover { h in withAnimation(.easeOut(duration: 0.2)) { hovering = h } }
        .simultaneousGesture(
            MagnifyGesture()
                .onChanged { value in
                    if pinchStart == nil { pinchStart = sizing.scale; begin(.endCorner) }
                    var next = settings.sizing(for: edge)
                    next.scale = (pinchStart ?? 1) * value.magnification
                    settings.setSizing(next, for: edge)
                }
                .onEnded { _ in
                    pinchStart = nil
                    end()
                })
        #if DEBUG
        .onReceive(DistributedNotificationCenter.default().publisher(for: .init("CustomNotch.debugOutline"))) { _ in
            if activeHandle == nil { begin(.end) } else { end() }
        }
        #endif
    }

    // MARK: Handles

    private var depthAlignment: Alignment {
        switch edge {
        case .top: .bottom
        case .bottom: .top
        case .left: .trailing
        case .right: .leading
        }
    }

    private func alignment(for handle: Handle) -> Alignment {
        let h = edge.isHorizontal
        let start: Alignment = h ? .leading : .top
        let end: Alignment = h ? .trailing : .bottom
        switch handle {
        case .start: return start
        case .end: return end
        case .depth: return depthAlignment
        case .startCorner, .endCorner:
            let along = handle == .startCorner ? start : end
            return Alignment(horizontal: h ? along.horizontal : depthAlignment.horizontal,
                             vertical: h ? depthAlignment.vertical : along.vertical)
        }
    }

    /// Unit vector pointing outwards from the notch at `handle`.
    private func outward(_ handle: Handle) -> CGSize {
        let along: CGSize = edge.isHorizontal ? CGSize(width: handle.alongSign, height: 0)
                                              : CGSize(width: 0, height: handle.alongSign)
        guard handle.resizesDepth else { return along }
        let depth: CGSize = switch edge {
        case .top: CGSize(width: 0, height: 1)
        case .bottom: CGSize(width: 0, height: -1)
        case .left: CGSize(width: 1, height: 0)
        case .right: CGSize(width: -1, height: 0)
        }
        return CGSize(width: along.width + depth.width, height: along.height + depth.height)
    }

    private func handles(body: CGSize) -> some View {
        let showGrip = hovering || activeHandle != nil
        let h = edge.isHorizontal
        let alongLength = h ? body.width : body.height
        let depthLength = h ? body.height : body.width

        return ZStack {
            ForEach(Handle.allCases, id: \.self) { handle in
                let dir = outward(handle)
                let size: CGSize = switch handle {
                case .start, .end:
                    h ? CGSize(width: 22, height: max(depthLength - 12, 10)) : CGSize(width: max(depthLength - 12, 10), height: 22)
                case .depth:
                    h ? CGSize(width: max(alongLength - 24, 10), height: 22) : CGSize(width: 22, height: max(alongLength - 24, 10))
                case .startCorner, .endCorner:
                    CGSize(width: 24, height: 24)
                }
                let grip: CGSize = switch handle {
                case .start, .end:
                    h ? CGSize(width: 4, height: min(26, depthLength * 0.6)) : CGSize(width: min(26, depthLength * 0.6), height: 4)
                case .depth:
                    h ? CGSize(width: min(34, alongLength * 0.3), height: 4) : CGSize(width: 4, height: min(34, alongLength * 0.3))
                case .startCorner, .endCorner:
                    .zero
                }
                handleView(handle) {
                    Capsule()
                        .fill(.white.opacity(showGrip ? 0.6 : 0))
                        .frame(width: grip.width, height: grip.height)
                        .offset(x: dir.width * 6, y: dir.height * 6)
                }
                .frame(width: size.width, height: size.height)
                .offset(x: dir.width * 11, y: dir.height * 11)
                .frame(width: body.width, height: body.height, alignment: alignment(for: handle))
            }
        }
        .frame(width: body.width, height: body.height)
    }

    private func handleView(_ handle: Handle, @ViewBuilder grip: () -> some View) -> some View {
        ZStack { grip() }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .contentShape(Rectangle())
            .onContinuousHover { phase in
                switch phase {
                case .active: cursor(for: handle).set()
                case .ended: if activeHandle == nil { NSCursor.arrow.set() }
                }
            }
            .gesture(
                DragGesture(minimumDistance: 0, coordinateSpace: .named("preview"))
                    .onChanged { value in drag(handle, by: value.translation) }
                    .onEnded { _ in end() })
    }

    private func cursor(for handle: Handle) -> NSCursor {
        let a = alignment(for: handle)
        if #available(macOS 15.0, *) {
            let position: NSCursor.FrameResizePosition = switch (a.horizontal, a.vertical) {
            case (.leading, .top): .topLeft
            case (.trailing, .top): .topRight
            case (.leading, .bottom): .bottomLeft
            case (.trailing, .bottom): .bottomRight
            case (.leading, _): .left
            case (.trailing, _): .right
            case (_, .top): .top
            default: .bottom
            }
            return NSCursor.frameResize(position: position, directions: .all)
        }
        if handle == .start || handle == .end { return edge.isHorizontal ? .resizeLeftRight : .resizeUpDown }
        if handle == .depth { return edge.isHorizontal ? .resizeUpDown : .resizeLeftRight }
        return .crosshair
    }

    // MARK: Dragging

    private func footer(sizing: NotchSizing) -> some View {
        let isResizing = activeHandle != nil
        return Group {
            if isResizing {
                Text(pointSize(sizing, on: edge))
                    .monospacedDigit()
                    .contentTransition(.numericText())
                    .transition(.opacity.combined(with: .scale(scale: 0.9)))
            } else {
                Label("Drag the edges to resize · Pinch to scale", systemImage: "hand.draw")
                    .transition(.opacity.combined(with: .scale(scale: 0.9)))
            }
        }
        .font(.system(size: 11.5, weight: .semibold, design: .rounded))
        .foregroundStyle(.white.opacity(0.9))
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(Capsule().fill(.black.opacity(0.35)))
        .overlay(Capsule().strokeBorder(.white.opacity(0.12)))
        // Keep the label off the notch: opposite side for top/bottom, bottom for the sides.
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: edge == .bottom ? .top : .bottom)
        .padding(edge == .bottom ? .top : .bottom, 16)
        .animation(.spring(response: 0.3, dampingFraction: 0.85), value: isResizing)
    }

    private func begin(_ handle: Handle) {
        guard dragStart == nil else { return }
        dragStart = settings.sizing(for: edge)
        withAnimation(.easeOut(duration: 0.2)) { activeHandle = handle }
    }

    private func drag(_ handle: Handle, by translation: CGSize) {
        begin(handle)
        guard let start = dragStart else { return }
        cursor(for: handle).set()
        let base = NotchMetrics.collapsed(horizontal: edge.isHorizontal)
        let baseAlong = edge.isHorizontal ? base.width : base.height
        let baseDepth = edge.isHorizontal ? base.height : base.width
        let k = start.scale * zoom
        let along = edge.isHorizontal ? translation.width : translation.height
        let depth: CGFloat = switch edge {
        case .top: translation.height
        case .bottom: -translation.height
        case .left: translation.width
        case .right: -translation.width
        }

        var next = settings.sizing(for: edge)
        if handle.alongSign != 0 {
            // The notch grows from its centre, so each end moves by half the width change.
            next.width = start.width + 2 * handle.alongSign * along / (baseAlong * k)
        }
        if handle.resizesDepth {
            next.height = start.height + depth / (baseDepth * k)
        }
        settings.setSizing(next, for: edge)
    }

    private func end() {
        dragStart = nil
        withAnimation(.easeOut(duration: 0.35)) { activeHandle = nil }
        NSCursor.arrow.set()
    }
}

/// Bright marching-ants outline traced around the notch's exposed edges while resizing.
private struct ResizeOutline: View {
    let shape: NotchShape
    let isActive: Bool

    var body: some View {
        TimelineView(.animation(paused: !isActive)) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            let phase = CGFloat((t * 26).truncatingRemainder(dividingBy: 11))
            ZStack {
                shape.stroke(.white.opacity(0.35), lineWidth: 5).blur(radius: 4)
                shape.stroke(.white, style: StrokeStyle(lineWidth: 2, lineCap: .round, dash: [6, 5], dashPhase: -phase))
            }
        }
        .opacity(isActive ? 1 : 0)
        .allowsHitTesting(false)
    }
}
