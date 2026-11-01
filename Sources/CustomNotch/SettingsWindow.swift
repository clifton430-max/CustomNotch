import AppKit
import SwiftUI

@MainActor
final class SettingsWindowController {
    private let settings: NotchSettings
    private let stats: SystemStats
    private let link: CompanionLink
    private let resetPosition: () -> Void
    private var window: NSWindow?

    static let size = CGSize(width: 860, height: 660)

    init(settings: NotchSettings, stats: SystemStats, link: CompanionLink, resetPosition: @escaping () -> Void) {
        self.settings = settings
        self.stats = stats
        self.link = link
        self.resetPosition = resetPosition
    }

    func show() {
        if window == nil {
            let w = NSWindow(contentRect: NSRect(origin: .zero, size: Self.size),
                             styleMask: [.titled, .closable, .miniaturizable, .fullSizeContentView],
                             backing: .buffered, defer: false)
            w.title = "Notch Settings"
            w.titleVisibility = .hidden
            w.titlebarAppearsTransparent = true
            w.appearance = NSAppearance(named: .darkAqua)
            w.isOpaque = true
            w.backgroundColor = .black
            w.isReleasedWhenClosed = false
            w.animationBehavior = .alertPanel
            w.level = .floating
            let root = SettingsView(settings: settings, stats: stats, link: link, resetPosition: resetPosition)
            let host = NSHostingView(rootView: root)
            host.sizingOptions = []
            w.contentView = host
            w.center()
            window = w
        }
        NSApp.activate()
        window?.makeKeyAndOrderFront(nil)
    }
}

// MARK: - Navigation

/// Every settings page, in sidebar order. Adding a page means adding a case here (with its
/// sidebar group, icon and search keywords) and a branch in `SettingsView.page(for:)`.
enum SettingsPage: String, CaseIterable, Hashable {
    case general, appearance, edges, companion, about

    var title: String {
        switch self {
        case .general: "General"
        case .appearance: "Appearance & Size"
        case .edges: "Edge Presets"
        case .companion: "Companion"
        case .about: "About"
        }
    }

    var symbol: String {
        switch self {
        case .general: "gearshape.fill"
        case .appearance: "rectangle.topthird.inset.filled"
        case .edges: "rectangle.dashed"
        case .companion: "heart.fill"
        case .about: "info.circle.fill"
        }
    }

    var colors: [Color] {
        switch self {
        case .general: Theme.graphite
        case .appearance: Theme.violet
        case .edges: Theme.blue
        case .companion: Theme.pink
        case .about: Theme.graphite
        }
    }

    /// Sidebar groups, like System Settings' clusters of related panes.
    var group: Int {
        switch self {
        case .general: 0
        case .appearance, .edges: 1
        case .companion: 2
        case .about: 3
        }
    }

    /// Extra words the sidebar search matches.
    var keywords: [String] {
        switch self {
        case .general: ["position", "reset", "docked", "overview"]
        case .appearance: ["size", "width", "height", "scale", "resize", "edge"]
        case .edges: ["top", "bottom", "left", "right", "preset", "size"]
        case .companion: ["terraria", "cookie", "messages", "inventory", "pet"]
        case .about: ["version"]
        }
    }

    func matches(_ query: String) -> Bool {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        return q.isEmpty || title.lowercased().contains(q) || keywords.contains { $0.contains(q) }
    }
}

private enum Theme {
    static let secondary = Color.white.opacity(0.55)
    static let tertiary = Color.white.opacity(0.35)
    static let separator = Color.white.opacity(0.08)
    static let sidebar = Color(white: 0.085)
    static let detail = Color(white: 0.045)
    static let accent = Color(red: 0.04, green: 0.52, blue: 1)
    static let page = Animation.spring(response: 0.44, dampingFraction: 0.9)
    static let control = Animation.spring(response: 0.32, dampingFraction: 0.82)
    static let violet = [Color(red: 0.47, green: 0.42, blue: 1), Color(red: 0.74, green: 0.36, blue: 0.96)]
    static let graphite = [Color(white: 0.52), Color(white: 0.3)]
    static let blue = [Color(red: 0.3, green: 0.62, blue: 1), Color(red: 0.12, green: 0.4, blue: 0.95)]
    static let pink = [Color(red: 1, green: 0.45, blue: 0.7), Color(red: 0.92, green: 0.2, blue: 0.5)]
    static let green = [Color(red: 0.35, green: 0.85, blue: 0.45), Color(red: 0.15, green: 0.65, blue: 0.3)]
    static let orange = [Color(red: 1, green: 0.7, blue: 0.3), Color(red: 0.95, green: 0.45, blue: 0.15)]
}

private struct SettingsView: View {
    @ObservedObject var settings: NotchSettings
    @ObservedObject var stats: SystemStats
    @ObservedObject var link: CompanionLink
    let resetPosition: () -> Void

    @State private var page: SettingsPage = .general
    @State private var history: [SettingsPage] = []
    @State private var future: [SettingsPage] = []
    @State private var editingEdge: NotchEdge = .right
    @State private var query = ""

    var body: some View {
        HStack(spacing: 0) {
            Sidebar(settings: settings, page: page, query: $query) { navigate(to: $0) }
                .frame(width: 228)
            Rectangle().fill(Color.white.opacity(0.07)).frame(width: 1)
            VStack(spacing: 0) {
                Toolbar(title: page.title, canGoBack: !history.isEmpty, canGoForward: !future.isEmpty,
                        back: goBack, forward: goForward)
                ScrollView {
                    pageView(for: page)
                        .id(page)
                        .frame(maxWidth: .infinity, alignment: .top)
                        .transition(.opacity.combined(with: .offset(y: 6)))
                }
                .scrollIndicators(.automatic)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Theme.detail)
        }
        .foregroundStyle(.white)
        .background(Theme.detail.ignoresSafeArea())
        .ignoresSafeArea()
        .environment(\.colorScheme, .dark)
        .tint(Theme.accent)
        #if DEBUG
        .onReceive(DistributedNotificationCenter.default().publisher(for: .init("CustomNotch.debugRoute"))) { note in
            // An edge name opens its size; a page name opens that page.
            let name = note.object as? String
            if let edge = name.flatMap(NotchEdge.init(rawValue:)) {
                navigate(to: .appearance, editing: edge)
            } else if let p = name.flatMap(SettingsPage.init(rawValue:)) {
                navigate(to: p)
            } else {
                navigate(to: page == .general ? .appearance : .general)
            }
        }
        #endif
    }

    @ViewBuilder
    private func pageView(for page: SettingsPage) -> some View {
        switch page {
        case .general:
            GeneralPage(settings: settings, stats: stats, resetPosition: resetPosition,
                        open: { navigate(to: $0) })
        case .appearance:
            AppearancePage(settings: settings, stats: stats, edge: $editingEdge)
        case .edges:
            EdgesPage(settings: settings) { edge in navigate(to: .appearance, editing: edge) }
        case .companion:
            CompanionPage(settings: settings, link: link)
        case .about:
            AboutPage()
        }
    }

    private func navigate(to next: SettingsPage, editing edge: NotchEdge? = nil) {
        if let edge { editingEdge = edge } else if next == .appearance, next != page { editingEdge = settings.dockedEdge }
        guard next != page else { return }
        history.append(page)
        future.removeAll()
        withAnimation(Theme.page) { page = next }
    }

    private func goBack() {
        guard let previous = history.popLast() else { return }
        future.append(page)
        withAnimation(Theme.page) { page = previous }
    }

    private func goForward() {
        guard let next = future.popLast() else { return }
        history.append(page)
        withAnimation(Theme.page) { page = next }
    }
}

// MARK: - Sidebar

/// System Settings' sidebar: room for the traffic lights, a search field, the notch's own card,
/// then the panes in groups with coloured icon tiles.
private struct Sidebar: View {
    @ObservedObject var settings: NotchSettings
    let page: SettingsPage
    @Binding var query: String
    let select: (SettingsPage) -> Void

    var body: some View {
        let shown = SettingsPage.allCases.filter { $0.matches(query) }
        VStack(alignment: .leading, spacing: 0) {
            Color.clear.frame(height: 46)
            SearchField(text: $query)
                .padding(.horizontal, 10)
                .padding(.bottom, 10)
            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    if query.isEmpty {
                        NotchCard(settings: settings, selected: false) { select(.general) }
                            .padding(.bottom, 8)
                    }
                    ForEach(Array(shown.enumerated()), id: \.element) { index, item in
                        if index > 0, shown[index - 1].group != item.group {
                            Color.clear.frame(height: 10)
                        }
                        SidebarRow(page: item, selected: item == page) { select(item) }
                    }
                    if shown.isEmpty {
                        Text("No Results")
                            .font(.system(size: 12))
                            .foregroundStyle(Theme.tertiary)
                            .frame(maxWidth: .infinity)
                            .padding(.top, 20)
                    }
                }
                .padding(.horizontal, 10)
                .padding(.bottom, 12)
            }
            .scrollIndicators(.never)
        }
        .background(Theme.sidebar)
        .onSubmit { if let first = shown.first { select(first) } }
    }
}

private struct SearchField: View {
    @Binding var text: String
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(Theme.tertiary)
            TextField("Search", text: $text)
                .textFieldStyle(.plain)
                .font(.system(size: 12.5))
                .focused($focused)
            if !text.isEmpty {
                Button { text = "" } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.tertiary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 8)
        .frame(height: 26)
        .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(.white.opacity(0.07)))
        .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous)
            .strokeBorder(focused ? Theme.accent.opacity(0.8) : .white.opacity(0.06), lineWidth: focused ? 2 : 1))
    }
}

/// Like the Apple Account card at the top of System Settings' sidebar.
private struct NotchCard: View {
    @ObservedObject var settings: NotchSettings
    let selected: Bool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        let edge = settings.dockedEdge
        Button(action: action) {
            HStack(spacing: 10) {
                ZStack {
                    Circle().fill(LinearGradient(colors: [Color(white: 0.3), Color(white: 0.14)], startPoint: .top, endPoint: .bottom))
                    Capsule().fill(.black)
                        .frame(width: edge.isHorizontal ? 22 : 8, height: edge.isHorizontal ? 8 : 22)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: edge.alignment)
                        .padding(edge.isHorizontal ? 6 : 6)
                }
                .frame(width: 34, height: 34)
                .overlay(Circle().strokeBorder(.white.opacity(0.14)))
                VStack(alignment: .leading, spacing: 1) {
                    Text("CustomNotch")
                        .font(.system(size: 13, weight: .semibold))
                    Text("Docked \(edge.title) · \(pointSize(settings.sizing(for: edge), on: edge))")
                        .font(.system(size: 10.5))
                        .foregroundStyle(selected ? .white.opacity(0.8) : Theme.secondary)
                        .lineLimit(1)
                        .monospacedDigit()
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 7)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(selected ? Theme.accent : .white.opacity(hovering ? 0.05 : 0)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { h in withAnimation(.easeOut(duration: 0.12)) { hovering = h } }
    }
}

private struct SidebarRow: View {
    let page: SettingsPage
    let selected: Bool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                IconTile(symbol: page.symbol, colors: page.colors, size: 20)
                Text(page.title)
                    .font(.system(size: 13))
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 6)
            .frame(height: 28)
            .background(RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(selected ? Theme.accent : .white.opacity(hovering ? 0.05 : 0)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { h in withAnimation(.easeOut(duration: 0.1)) { hovering = h } }
    }
}

/// The detail column's toolbar: back and forward, then the page title, like System Settings.
private struct Toolbar: View {
    let title: String
    let canGoBack: Bool
    let canGoForward: Bool
    let back: () -> Void
    let forward: () -> Void

    var body: some View {
        HStack(spacing: 6) {
            NavButton(symbol: "chevron.left", enabled: canGoBack, help: "Back", action: back)
                .keyboardShortcut("[", modifiers: .command)
            NavButton(symbol: "chevron.right", enabled: canGoForward, help: "Forward", action: forward)
                .keyboardShortcut("]", modifiers: .command)
            Text(title)
                .font(.system(size: 14, weight: .semibold))
                .padding(.leading, 6)
                .id(title)
                .transition(.opacity)
            Spacer()
        }
        .padding(.horizontal, 14)
        .frame(height: 52)
        .animation(Theme.page, value: title)
        .overlay(alignment: .bottom) { Rectangle().fill(Theme.separator).frame(height: 1) }
    }
}

private struct NavButton: View {
    let symbol: String
    let enabled: Bool
    let help: String
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 13, weight: .semibold))
                .frame(width: 26, height: 24)
                .background(RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(.white.opacity(hovering && enabled ? 0.1 : 0)))
                .contentShape(Rectangle())
        }
        .buttonStyle(PressStyle(scale: 0.92))
        .disabled(!enabled)
        .opacity(enabled ? 0.85 : 0.3)
        .onHover { h in withAnimation(.easeOut(duration: 0.12)) { hovering = h } }
        .help(help)
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
    /// A rounded group, like the inset sections in System Settings.
    func glassGroup(cornerRadius: CGFloat = 10) -> some View {
        background(
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .fill(.white.opacity(0.05))
                .overlay(
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .strokeBorder(.white.opacity(0.08))))
    }
}

/// A page's content column: centred, at System Settings' reading width.
private struct PageColumn<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 22) { content }
            .frame(maxWidth: 580, alignment: .leading)
            .padding(.horizontal, 24)
            .padding(.top, 18)
            .padding(.bottom, 28)
            .frame(maxWidth: .infinity)
    }
}

/// A titled form section: a heading, its rows in a rounded group, and an optional footnote.
private struct FormSection<Content: View>: View {
    var title: String?
    var footer: String?
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            if let title {
                Text(title)
                    .font(.system(size: 13, weight: .semibold))
                    .padding(.leading, 2)
            }
            VStack(spacing: 0) { content }
                .glassGroup()
            if let footer {
                Text(footer)
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 2)
            }
        }
    }
}

/// One row of a form section: label (and description) on the left, its control on the right.
private struct FormRow<Control: View>: View {
    let title: String
    var detail: String?
    var symbol: String?
    var colors: [Color] = Theme.graphite
    var divider = true
    @ViewBuilder let control: Control

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                if let symbol { IconTile(symbol: symbol, colors: colors, size: 22) }
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.system(size: 13))
                    if let detail {
                        Text(detail)
                            .font(.system(size: 11))
                            .foregroundStyle(Theme.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer(minLength: 12)
                control
            }
            .padding(.horizontal, 12)
            .padding(.vertical, detail == nil ? 9 : 8)
            .frame(minHeight: 40)
            if divider {
                Rectangle().fill(Theme.separator).frame(height: 1)
                    .padding(.leading, symbol == nil ? 12 : 44)
            }
        }
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
    var divider = true
    let action: () -> Void
    @ViewBuilder let trailing: Trailing
    @State private var hovering = false

    var body: some View {
        VStack(spacing: 0) {
            Button(action: action) {
                HStack(spacing: 10) {
                    IconTile(symbol: symbol, colors: colors, size: 22)
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
                .padding(.horizontal, 12)
                .frame(height: 40)
                .background(Color.white.opacity(hovering ? 0.04 : 0))
                .contentShape(Rectangle())
            }
            .buttonStyle(PressStyle(scale: 0.995))
            .onHover { h in withAnimation(.easeOut(duration: 0.12)) { hovering = h } }
            if divider {
                Rectangle().fill(Theme.separator).frame(height: 1).padding(.leading, 44)
            }
        }
    }
}

/// A plain push button, System Settings style.
private struct FormButton: View {
    let title: String
    var role: ButtonRole?
    var isEnabled = true
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 12.5, weight: .medium))
                .foregroundStyle(role == .destructive ? Color(red: 1, green: 0.42, blue: 0.4) : .white)
                .padding(.horizontal, 11)
                .frame(height: 24)
                .background(RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(.white.opacity(hovering && isEnabled ? 0.18 : 0.11)))
                .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).strokeBorder(.white.opacity(0.08)))
        }
        .buttonStyle(PressStyle(scale: 0.96))
        .disabled(!isEnabled)
        .opacity(isEnabled ? 1 : 0.4)
        .onHover { h in withAnimation(.easeOut(duration: 0.12)) { hovering = h } }
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

// MARK: - General

private struct GeneralPage: View {
    @ObservedObject var settings: NotchSettings
    @ObservedObject var stats: SystemStats
    let resetPosition: () -> Void
    let open: (SettingsPage) -> Void

    var body: some View {
        let edge = settings.dockedEdge
        let sizing = settings.sizing(for: edge)
        PageColumn {
            HeroCard(settings: settings, stats: stats) { open(.appearance) }

            FormSection(title: "Notch") {
                FormRow(title: "Docked edge", detail: "Drag the notch to any screen edge to move it there.",
                        symbol: edge.symbol, colors: Theme.blue) {
                    HStack(spacing: 6) {
                        DockedBadge()
                        Text(edge.title).foregroundStyle(Theme.secondary)
                    }
                    .font(.system(size: 12.5))
                }
                FormRow(title: "Size", symbol: "ruler", colors: Theme.violet) {
                    Text(pointSize(sizing, on: edge))
                        .font(.system(size: 12.5))
                        .foregroundStyle(Theme.secondary)
                        .monospacedDigit()
                        .contentTransition(.numericText())
                }
                FormRow(title: "Overall size", symbol: "arrow.up.left.and.arrow.down.right", colors: Theme.violet, divider: false) {
                    Text(percent(sizing.scale))
                        .font(.system(size: 12.5))
                        .foregroundStyle(Theme.secondary)
                        .monospacedDigit()
                }
            }

            FormSection(title: "Customize") {
                NavigationRow(symbol: SettingsPage.appearance.symbol, colors: Theme.violet, title: "Appearance & Size",
                              action: { open(.appearance) }) {
                    Text(percent(sizing.scale)).monospacedDigit()
                }
                NavigationRow(symbol: SettingsPage.edges.symbol, colors: Theme.blue, title: "Edge Presets",
                              action: { open(.edges) }) {
                    Text("4 edges")
                }
                NavigationRow(symbol: SettingsPage.companion.symbol, colors: Theme.pink, title: "Companion",
                              divider: false, action: { open(.companion) }) {
                    EmptyView()
                }
            }

            FormSection(footer: "Puts the notch back in the middle of the right edge of the main display.") {
                FormRow(title: "Reset notch position", symbol: "arrow.counterclockwise", colors: Theme.orange, divider: false) {
                    FormButton(title: "Reset Position", action: resetPosition)
                }
            }
        }
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

/// A live miniature of the notch on the edge it's docked to, with a summary underneath.
private struct HeroCard: View {
    @ObservedObject var settings: NotchSettings
    @ObservedObject var stats: SystemStats
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        let edge = settings.dockedEdge
        let sizing = settings.sizing(for: edge)
        let collapsed = sizing.collapsed(horizontal: edge.isHorizontal)
        // Fit the miniature in the 128 pt strip whatever its size.
        let zoom = min(0.85, (edge.isHorizontal ? 420 : 108) / (edge.isHorizontal ? collapsed.width : collapsed.height))

        Button(action: action) {
            VStack(spacing: 0) {
                ZStack {
                    Wallpaper()
                    NotchMiniature(edge: edge, sizing: sizing, stats: stats, zoom: zoom)
                        .docked(to: edge, zoom: zoom)
                        .id(edge)
                        .transition(.opacity.combined(with: .scale(scale: 0.9)))
                }
                .frame(height: 128)
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
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(.white.opacity(0.1)))
            .animation(Theme.control, value: edge)
            .animation(Theme.control, value: sizing)
        }
        .buttonStyle(PressStyle(scale: 0.995))
        .onHover { h in withAnimation(.easeOut(duration: 0.15)) { hovering = h } }
    }
}

// MARK: - Edge presets

private struct EdgesPage: View {
    @ObservedObject var settings: NotchSettings
    let openEdge: (NotchEdge) -> Void

    var body: some View {
        PageColumn {
            FormSection(title: "Sizes", footer: "Each edge remembers its own size. Move the notch and it switches automatically.") {
                ForEach(Array(NotchEdge.allCases.enumerated()), id: \.element) { index, edge in
                    NavigationRow(symbol: edge.symbol, colors: edge == settings.dockedEdge ? Theme.blue : Theme.graphite,
                                  title: edge.title, divider: index < NotchEdge.allCases.count - 1,
                                  action: { openEdge(edge) }) {
                        HStack(spacing: 8) {
                            if edge == settings.dockedEdge { DockedBadge() }
                            Text(pointSize(settings.sizing(for: edge), on: edge))
                                .monospacedDigit()
                                .contentTransition(.numericText())
                        }
                    }
                }
            }
            FormSection(footer: "Puts every edge back to the standard size.") {
                FormRow(title: "Reset all edges", symbol: "arrow.counterclockwise", colors: Theme.orange, divider: false) {
                    FormButton(title: "Reset All", isEnabled: NotchEdge.allCases.contains { settings.sizing(for: $0) != .standard }) {
                        withAnimation(.spring(response: 0.45, dampingFraction: 0.8)) {
                            for edge in NotchEdge.allCases { settings.reset(edge) }
                        }
                    }
                }
            }
        }
    }
}

// MARK: - Companion

private struct CompanionPage: View {
    @ObservedObject var settings: NotchSettings
    @ObservedObject var link: CompanionLink

    var body: some View {
        PageColumn {
            FormSection(title: "Terraria Companion") {
                FormRow(title: status.title, detail: status.detail, symbol: "heart.fill", colors: Theme.pink, divider: false) {
                    HStack(spacing: 5) {
                        Circle().fill(link.connected ? Color.green : Color.white.opacity(0.3)).frame(width: 7, height: 7)
                        Text(link.connected ? "Connected" : "Not running")
                            .font(.system(size: 12))
                            .foregroundStyle(Theme.secondary)
                    }
                }
            }

            FormSection(title: "Cookies",
                        footer: "Drag a cookie onto her, or click it and she'll go and eat it. She loves them (it fills her affection meter, like a cookie on the desktop).") {
                FormRow(title: "Cookies turn up", detail: "When you open the notch with her inside.",
                        symbol: "sparkles", colors: Theme.orange) {
                    Picker("", selection: $settings.cookieFrequency) {
                        ForEach(CookieFrequency.allCases, id: \.self) { Text($0.title).tag($0) }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .fixedSize()
                }
                FormRow(title: "Cookie button", detail: "Beside Notch Settings in the opened notch.",
                        symbol: "hand.tap.fill", colors: Theme.orange, divider: false) {
                    Toggle("", isOn: $settings.showsCookieButton)
                        .labelsHidden()
                        .toggleStyle(.switch)
                        .controlSize(.small)
                }
            }

            FormSection(title: "Messages",
                        footer: "Unread messages stay until you've read them. Dismiss one with its \u{2715}.") {
                FormRow(title: "Keep read messages", symbol: "text.bubble.fill", colors: Theme.green) {
                    Picker("", selection: $settings.messageLifetime) {
                        ForEach(MessageLifetime.allCases, id: \.self) { Text($0.title).tag($0) }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .fixedSize()
                }
                FormRow(title: "Messages", detail: messageSummary, symbol: "tray.full.fill", colors: Theme.graphite, divider: false) {
                    FormButton(title: "Clear All", role: .destructive, isEnabled: !link.messages.isEmpty) {
                        withAnimation(Theme.control) { link.clearAll() }
                    }
                }
            }
        }
    }

    private var status: (title: String, detail: String) {
        if let r = link.resident {
            return ("\(r.name) lives in the notch", "Open the notch to see her. Drag her out to bring her back to the desktop.")
        }
        if link.connected {
            return ("Nobody lives here yet", "Drag or throw a companion onto the notch to let her move in.")
        }
        return ("Terraria Companion isn't running", "Open it to let a companion move into the notch.")
    }

    private var messageSummary: String {
        let all = link.messages.count, unread = link.unread.count
        if all == 0 { return "None kept" }
        return unread > 0 ? "\(all) kept, \(unread) unread" : "\(all) kept"
    }
}

// MARK: - About

private struct AboutPage: View {
    var body: some View {
        PageColumn {
            VStack(spacing: 10) {
                ZStack {
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .fill(LinearGradient(colors: [Color(white: 0.28), Color(white: 0.1)], startPoint: .top, endPoint: .bottom))
                    Capsule().fill(.black).frame(width: 34, height: 11).frame(maxHeight: .infinity, alignment: .top).padding(.top, 9)
                }
                .frame(width: 64, height: 64)
                .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(.white.opacity(0.14)))
                Text("CustomNotch").font(.system(size: 17, weight: .semibold))
                Text("Version \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0")")
                    .font(.system(size: 11.5))
                    .foregroundStyle(Theme.secondary)
            }
            .frame(maxWidth: .infinity)
            .padding(.top, 10)

            FormSection {
                FormRow(title: "Open the notch", detail: "Hover over it. Pin it to keep it open.", symbol: "cursorarrow.motionlines", colors: Theme.blue) {
                    EmptyView()
                }
                FormRow(title: "Move it", detail: "Drag or throw it to any screen edge.", symbol: "hand.draw.fill", colors: Theme.violet) {
                    EmptyView()
                }
                FormRow(title: "Details", detail: "Click Battery, CPU or Memory for a closer look.", symbol: "chart.bar.fill", colors: Theme.green, divider: false) {
                    EmptyView()
                }
            }
        }
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
        .frame(maxWidth: 600)
        .padding(.horizontal, 24)
        .padding(.top, 16)
        .padding(.bottom, 24)
        .frame(maxWidth: .infinity)
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
                    .frame(width: 104, height: 26)
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
    private var zoom: CGFloat { edge.isHorizontal ? 1.3 : 0.92 }

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
