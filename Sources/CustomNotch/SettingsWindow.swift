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
            w.backgroundColor = NSColor(white: 0.055, alpha: 1)
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
            context.duration = 0.34
            context.timingFunction = CAMediaTimingFunction(controlPoints: 0.2, 0.9, 0.25, 1)
            w.animator().setFrame(frame, display: true)
        }
    }
}

// MARK: - Navigation

/// Every settings page. Adding a page means adding a case here, a `SettingsCategory` entry
/// pointing at it, and a branch in `SettingsView.page(for:)`.
enum SettingsRoute: Hashable {
    case home
    case appearance

    var windowSize: CGSize {
        switch self {
        case .home: CGSize(width: 460, height: 420)
        case .appearance: CGSize(width: 720, height: 650)
        }
    }
}

private struct SettingsCategory: Identifiable {
    let route: SettingsRoute
    let title: String
    let symbol: String
    let tint: [Color]
    let detail: @MainActor (NotchSettings) -> String
    var id: SettingsRoute { route }
}

private struct SettingsGroup: Identifiable {
    let title: String
    let categories: [SettingsCategory]
    var id: String { title }

    static let all = [
        SettingsGroup(title: "Notch", categories: [
            SettingsCategory(route: .appearance, title: "Notch Appearance & Size",
                             symbol: "rectangle.topthird.inset.filled",
                             tint: [Color(red: 0.45, green: 0.4, blue: 1), Color(red: 0.75, green: 0.35, blue: 0.95)]) { settings in
                let s = settings.sizing
                return "Width \(percent(s.width)) · Height \(percent(s.height)) · Size \(percent(s.scale))"
            },
        ]),
    ]
}

private func percent(_ value: CGFloat) -> String { "\(Int((value * 100).rounded()))%" }

private enum Theme {
    static let background = Color(white: 0.055)
    static let card = Color(white: 0.1)
    static let stroke = Color.white.opacity(0.07)
    static let secondary = Color.white.opacity(0.5)
    static let tertiary = Color.white.opacity(0.3)
    static let pageAnimation = Animation.spring(response: 0.42, dampingFraction: 0.9)
}

private struct SettingsView: View {
    @ObservedObject var settings: NotchSettings
    @ObservedObject var stats: SystemStats
    let resizeWindow: (CGSize) -> Void

    @State private var route: SettingsRoute = .home
    @State private var forward = true

    var body: some View {
        ZStack(alignment: .top) {
            Theme.background.ignoresSafeArea()
            page(for: route)
                .id(route)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                .transition(.asymmetric(
                    insertion: .move(edge: forward ? .trailing : .leading).combined(with: .opacity),
                    removal: .move(edge: forward ? .leading : .trailing).combined(with: .opacity)))
        }
        .clipped()
        .environment(\.colorScheme, .dark)
        #if DEBUG
        .onReceive(DistributedNotificationCenter.default().publisher(for: .init("CustomNotch.debugRoute"))) { _ in
            navigate(to: route == .home ? .appearance : .home)
        }
        #endif
    }

    @ViewBuilder
    private func page(for route: SettingsRoute) -> some View {
        switch route {
        case .home:
            HomePage(settings: settings, open: navigate)
        case .appearance:
            AppearancePage(settings: settings, stats: stats) { navigate(to: .home) }
        }
    }

    private func navigate(to next: SettingsRoute) {
        // Set the direction first so the outgoing page picks up the matching transition.
        forward = next != .home
        resizeWindow(next.windowSize)
        DispatchQueue.main.async {
            withAnimation(Theme.pageAnimation) { route = next }
        }
    }
}

// MARK: - Shared pieces

private extension View {
    func settingsCard() -> some View {
        background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Theme.card)
                .overlay(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .strokeBorder(LinearGradient(colors: [.white.opacity(0.13), Theme.stroke],
                                                     startPoint: .top, endPoint: .bottom))))
    }
}

private struct SectionLabel: View {
    let title: String

    var body: some View {
        Text(title)
            .font(.system(size: 11.5, weight: .semibold))
            .textCase(.uppercase)
            .kerning(0.4)
            .foregroundStyle(Theme.tertiary)
            .padding(.leading, 4)
    }
}

private struct IconTile: View {
    let symbol: String
    let tint: [Color]
    var size: CGFloat = 30

    var body: some View {
        RoundedRectangle(cornerRadius: size * 0.27, style: .continuous)
            .fill(LinearGradient(colors: tint, startPoint: .topLeading, endPoint: .bottomTrailing))
            .overlay(
                RoundedRectangle(cornerRadius: size * 0.27, style: .continuous)
                    .strokeBorder(.white.opacity(0.18)))
            .overlay(
                Image(systemName: symbol)
                    .font(.system(size: size * 0.47, weight: .semibold))
                    .foregroundStyle(.white))
            .frame(width: size, height: size)
    }
}

private struct PressStyle: ButtonStyle {
    var scale: CGFloat = 0.97

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? scale : 1)
            .animation(.spring(response: 0.25, dampingFraction: 0.65), value: configuration.isPressed)
    }
}

// MARK: - Home

private struct HomePage: View {
    @ObservedObject var settings: NotchSettings
    let open: (SettingsRoute) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 26) {
            HStack(spacing: 14) {
                AppGlyph()
                VStack(alignment: .leading, spacing: 3) {
                    Text("Notch Settings")
                        .font(.system(size: 22, weight: .bold, design: .rounded))
                    Text("Customize how your notch looks and behaves")
                        .font(.system(size: 12.5))
                        .foregroundStyle(Theme.secondary)
                }
            }

            ForEach(SettingsGroup.all) { group in
                VStack(alignment: .leading, spacing: 8) {
                    SectionLabel(title: group.title)
                    VStack(spacing: 0) {
                        ForEach(Array(group.categories.enumerated()), id: \.element.id) { index, category in
                            if index > 0 {
                                Rectangle().fill(Theme.stroke).frame(height: 1).padding(.leading, 56)
                            }
                            CategoryRow(category: category, detail: category.detail(settings)) {
                                open(category.route)
                            }
                        }
                    }
                    .padding(4)
                    .settingsCard()
                }
            }

            Spacer(minLength: 0)

            Text("CustomNotch 1.0")
                .font(.system(size: 11, weight: .medium, design: .rounded))
                .foregroundStyle(Theme.tertiary)
                .frame(maxWidth: .infinity)
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 26)
        .padding(.top, 46)
        .padding(.bottom, 18)
    }
}

private struct AppGlyph: View {
    var body: some View {
        RoundedRectangle(cornerRadius: 12, style: .continuous)
            .fill(LinearGradient(colors: [Color(white: 0.2), Color(white: 0.08)], startPoint: .top, endPoint: .bottom))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(.white.opacity(0.14)))
            .overlay(alignment: .top) {
                NotchShape(edge: .top, ear: 3, radius: 5, pad: 3)
                    .fill(Color.black)
                    .overlay(NotchShape(edge: .top, ear: 3, radius: 5, pad: 3).stroke(.white.opacity(0.25), lineWidth: 0.5))
                    .frame(width: 30, height: 16)
                    .padding(.top, -3)
            }
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .frame(width: 46, height: 46)
            .shadow(color: .black.opacity(0.4), radius: 6, y: 3)
    }
}

private struct CategoryRow: View {
    let category: SettingsCategory
    let detail: String
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                IconTile(symbol: category.symbol, tint: category.tint)
                VStack(alignment: .leading, spacing: 2) {
                    Text(category.title)
                        .font(.system(size: 13.5, weight: .semibold))
                    Text(detail)
                        .font(.system(size: 11.5))
                        .foregroundStyle(Theme.secondary)
                        .contentTransition(.numericText())
                }
                Spacer(minLength: 8)
                Image(systemName: "chevron.right")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(hovering ? Color.white.opacity(0.8) : Theme.tertiary)
                    .offset(x: hovering ? 2 : 0)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 10)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(.white.opacity(hovering ? 0.06 : 0)))
            .contentShape(Rectangle())
        }
        .buttonStyle(PressStyle(scale: 0.985))
        .onHover { h in withAnimation(.easeOut(duration: 0.15)) { hovering = h } }
    }
}

// MARK: - Appearance & Size

private struct AppearancePage: View {
    @ObservedObject var settings: NotchSettings
    @ObservedObject var stats: SystemStats
    let back: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 12) {
                BackButton(action: back)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Notch Appearance & Size")
                        .font(.system(size: 18, weight: .bold, design: .rounded))
                    Text("Drag the preview's edges, pinch to scale, or use the sliders")
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.secondary)
                }
            }

            ResizablePreview(settings: settings, stats: stats)
                .frame(height: 330)

            HStack(spacing: 0) {
                SizeSlider(title: "Width", symbol: "arrow.left.and.right",
                           value: $settings.sizing.width, range: NotchSizing.widthRange)
                ColumnDivider()
                SizeSlider(title: "Height", symbol: "arrow.up.and.down",
                           value: $settings.sizing.height, range: NotchSizing.heightRange)
                ColumnDivider()
                SizeSlider(title: "Overall Size", symbol: "arrow.up.left.and.arrow.down.right",
                           value: $settings.sizing.scale, range: NotchSizing.scaleRange)
            }
            .padding(.vertical, 16)
            .settingsCard()

            HStack {
                let size = settings.sizing.collapsed(horizontal: true)
                Label("\(Int(size.width.rounded())) × \(Int(size.height.rounded())) pt when docked to the top",
                      systemImage: "ruler")
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(Theme.secondary)
                    .contentTransition(.numericText())
                Spacer()
                ResetButton(isEnabled: settings.sizing != .standard) {
                    withAnimation(.spring(response: 0.45, dampingFraction: 0.8)) { settings.reset() }
                }
            }
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 28)
        .padding(.top, 40)
        .padding(.bottom, 22)
    }
}

private struct ColumnDivider: View {
    var body: some View {
        Rectangle().fill(Theme.stroke).frame(width: 1, height: 52)
    }
}

private struct BackButton: View {
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: "chevron.left")
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(.white.opacity(hovering ? 1 : 0.75))
                .offset(x: hovering ? -1 : 0)
                .frame(width: 32, height: 32)
                .background(Circle().fill(.white.opacity(hovering ? 0.14 : 0.08)))
                .overlay(Circle().strokeBorder(.white.opacity(0.1)))
                .contentShape(Circle())
        }
        .buttonStyle(PressStyle(scale: 0.9))
        .keyboardShortcut("[", modifiers: .command)
        .onHover { h in withAnimation(.easeOut(duration: 0.15)) { hovering = h } }
        .help("Back to Settings")
    }
}

private struct ResetButton: View {
    let isEnabled: Bool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Label("Reset to Default", systemImage: "arrow.counterclockwise")
                .font(.system(size: 12, weight: .semibold))
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .background(Capsule().fill(.white.opacity(hovering && isEnabled ? 0.15 : 0.08)))
                .overlay(Capsule().strokeBorder(.white.opacity(0.1)))
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
                    .background(Capsule().fill(.white.opacity(0.08)))
            }
            Slider(value: $value, in: range)
                .controlSize(.small)
                .tint(.white)
        }
        .padding(.horizontal, 18)
    }
}

// MARK: - Resizable preview

/// A zoomed-in desktop with the notch docked to its top edge. Its left, right and bottom
/// edges (and bottom corners) can be dragged like a window's to set width and height, and a
/// trackpad pinch sets the overall size. Everything writes straight to `settings`, so the
/// sliders and the real notch follow along.
private struct ResizablePreview: View {
    @ObservedObject var settings: NotchSettings
    @ObservedObject var stats: SystemStats

    @State private var activeHandle: Handle?
    @State private var dragStart: NotchSizing?
    @State private var pinchStart: CGFloat?
    @State private var hovering = false

    private let zoom: CGFloat = 1.5

    enum Handle: CaseIterable {
        case left, right, bottom, bottomLeft, bottomRight

        var widthSign: CGFloat {
            switch self {
            case .left, .bottomLeft: -1
            case .right, .bottomRight: 1
            case .bottom: 0
            }
        }

        var resizesHeight: Bool { self == .bottom || self == .bottomLeft || self == .bottomRight }

        var cursor: NSCursor {
            if #available(macOS 15.0, *) {
                let position: NSCursor.FrameResizePosition = switch self {
                case .left: .left
                case .right: .right
                case .bottom: .bottom
                case .bottomLeft: .bottomLeft
                case .bottomRight: .bottomRight
                }
                return NSCursor.frameResize(position: position, directions: .all)
            }
            return self == .bottom ? .resizeUpDown : (resizesHeight ? .crosshair : .resizeLeftRight)
        }
    }

    var body: some View {
        let sizing = settings.sizing
        let pad = NotchMetrics.earPad * zoom
        let k = sizing.scale * zoom
        let layout = sizing.collapsedLayout(horizontal: true)
        let body = CGSize(width: layout.width * k, height: layout.height * k)
        let isResizing = activeHandle != nil
        let fill = NotchShape(edge: .top, ear: 9 * k, radius: 14 * k, pad: pad)
        let outline = NotchShape(edge: .top, ear: 9 * k, radius: 14 * k, pad: pad, isClosed: false)

        ZStack(alignment: .top) {
            Wallpaper()

            ZStack {
                fill.fill(Color.black)
                    .shadow(color: .black.opacity(isResizing ? 0.5 : 0.3), radius: isResizing ? 18 : 10, y: 6)
                HorizontalCollapsed(stats: stats)
                    .frame(width: layout.width, height: layout.height)
                    .scaleEffect(k)
                    .frame(width: body.width, height: body.height)
                    .padding(pad)
                    .mask(fill)
                ResizeOutline(shape: outline, isActive: isResizing)
            }
            .frame(width: body.width + pad * 2, height: body.height + pad * 2)
            .padding(.top, -pad)
            .environment(\.colorScheme, .dark)

            handles(for: body)

            footer(isResizing: isResizing)
        }
        .coordinateSpace(name: "preview")
        .frame(maxWidth: .infinity)
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(.white.opacity(0.1)))
        .onHover { h in withAnimation(.easeOut(duration: 0.2)) { hovering = h } }
        .simultaneousGesture(
            MagnifyGesture()
                .onChanged { value in
                    if pinchStart == nil { pinchStart = settings.sizing.scale; begin(.bottomRight) }
                    settings.sizing.scale = clamp(pinchStart! * value.magnification, NotchSizing.scaleRange)
                }
                .onEnded { _ in
                    pinchStart = nil
                    end()
                })
        #if DEBUG
        .onReceive(DistributedNotificationCenter.default().publisher(for: .init("CustomNotch.debugOutline"))) { _ in
            if activeHandle == nil { begin(.right) } else { end() }
        }
        #endif
    }

    private func handles(for body: CGSize) -> some View {
        let grip = Color.white.opacity(hovering || activeHandle != nil ? 0.55 : 0)
        let side = max(body.height - 12, 10)
        return Color.clear
            .frame(width: body.width, height: body.height)
            .overlay(alignment: .leading) {
                handle(.left) { Capsule().fill(grip).frame(width: 4, height: min(26, side * 0.6)).offset(x: -6) }
                    .frame(width: 22, height: side).offset(x: -11)
            }
            .overlay(alignment: .trailing) {
                handle(.right) { Capsule().fill(grip).frame(width: 4, height: min(26, side * 0.6)).offset(x: 6) }
                    .frame(width: 22, height: side).offset(x: 11)
            }
            .overlay(alignment: .bottom) {
                handle(.bottom) { Capsule().fill(grip).frame(width: min(34, body.width * 0.3), height: 4).offset(y: 6) }
                    .frame(width: max(body.width - 24, 10), height: 22).offset(y: 11)
            }
            .overlay(alignment: .bottomLeading) {
                handle(.bottomLeft) { Color.clear }.frame(width: 24, height: 24).offset(x: -12, y: 12)
            }
            .overlay(alignment: .bottomTrailing) {
                handle(.bottomRight) { Color.clear }.frame(width: 24, height: 24).offset(x: 12, y: 12)
            }
    }

    private func handle(_ handle: Handle, @ViewBuilder grip: () -> some View) -> some View {
        ZStack { grip() }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .contentShape(Rectangle())
            .onContinuousHover { phase in
                switch phase {
                case .active: handle.cursor.set()
                case .ended: if activeHandle == nil { NSCursor.arrow.set() }
                }
            }
            .gesture(
                DragGesture(minimumDistance: 0, coordinateSpace: .named("preview"))
                    .onChanged { value in drag(handle, by: value.translation) }
                    .onEnded { _ in end() })
    }

    private func footer(isResizing: Bool) -> some View {
        let size = settings.sizing.collapsed(horizontal: true)
        return Group {
            if isResizing {
                Text("\(Int(size.width.rounded())) × \(Int(size.height.rounded())) pt")
                    .monospacedDigit()
                    .contentTransition(.numericText())
                    .transition(.opacity.combined(with: .scale(scale: 0.9)))
            } else {
                Label("Drag the edges to resize", systemImage: "hand.draw")
                    .transition(.opacity.combined(with: .scale(scale: 0.9)))
            }
        }
        .font(.system(size: 11.5, weight: .semibold, design: .rounded))
        .foregroundStyle(.white.opacity(0.9))
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(Capsule().fill(.black.opacity(0.35)))
        .overlay(Capsule().strokeBorder(.white.opacity(0.12)))
        .frame(maxHeight: .infinity, alignment: .bottom)
        .padding(.bottom, 16)
        .animation(.spring(response: 0.3, dampingFraction: 0.85), value: isResizing)
    }

    private func begin(_ handle: Handle) {
        guard dragStart == nil else { return }
        dragStart = settings.sizing
        withAnimation(.easeOut(duration: 0.2)) { activeHandle = handle }
    }

    private func drag(_ handle: Handle, by translation: CGSize) {
        begin(handle)
        guard let start = dragStart else { return }
        handle.cursor.set()
        let base = NotchMetrics.collapsed(horizontal: true)
        let k = start.scale * zoom
        var next = settings.sizing
        if handle.widthSign != 0 {
            // The notch grows from its centre, so each edge moves by half the width change.
            next.width = clamp(start.width + 2 * handle.widthSign * translation.width / (base.width * k),
                               NotchSizing.widthRange)
        }
        if handle.resizesHeight {
            next.height = clamp(start.height + translation.height / (base.height * k), NotchSizing.heightRange)
        }
        settings.sizing = next
    }

    private func end() {
        dragStart = nil
        withAnimation(.easeOut(duration: 0.35)) { activeHandle = nil }
        NSCursor.arrow.set()
    }

    private func clamp(_ value: CGFloat, _ range: ClosedRange<CGFloat>) -> CGFloat {
        min(max(value, range.lowerBound), range.upperBound)
    }
}

private struct Wallpaper: View {
    var body: some View {
        ZStack {
            LinearGradient(colors: [Color(red: 0.13, green: 0.14, blue: 0.36),
                                    Color(red: 0.36, green: 0.18, blue: 0.5),
                                    Color(red: 0.78, green: 0.37, blue: 0.45)],
                           startPoint: .topLeading, endPoint: .bottomTrailing)
            RadialGradient(colors: [Color(red: 0.45, green: 0.55, blue: 1).opacity(0.45), .clear],
                           center: UnitPoint(x: 0.2, y: 0.85), startRadius: 0, endRadius: 320)
            RadialGradient(colors: [Color(red: 1, green: 0.6, blue: 0.4).opacity(0.35), .clear],
                           center: UnitPoint(x: 0.9, y: 0.2), startRadius: 0, endRadius: 280)
        }
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
        .scaleEffect(isActive ? 1 : 0.985, anchor: .top)
        .allowsHitTesting(false)
    }
}
