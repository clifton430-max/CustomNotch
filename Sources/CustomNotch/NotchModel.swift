import SwiftUI

enum NotchEdge: String, CaseIterable, Codable {
    case top, bottom, left, right

    var isHorizontal: Bool { self == .top || self == .bottom }

    var title: String { rawValue.capitalized }

    var symbol: String {
        switch self {
        case .top: "arrow.up.to.line"
        case .bottom: "arrow.down.to.line"
        case .left: "arrow.left.to.line"
        case .right: "arrow.right.to.line"
        }
    }

    var alignment: Alignment {
        switch self {
        case .top: .top
        case .bottom: .bottom
        case .left: .leading
        case .right: .trailing
        }
    }

    var unitPoint: UnitPoint {
        switch self {
        case .top: .top
        case .bottom: .bottom
        case .left: .leading
        case .right: .trailing
        }
    }
}

enum NotchMetrics {
    /// Side length of the transparent window the notch lives in. The window is centred on the
    /// attach point, so the body can grow in any direction without resizing the window.
    static let canvas: CGFloat = 1000
    /// Room reserved around the body for the concave "ears" that flare along the attached edge.
    static let earPad: CGFloat = 14
    static let screenMargin: CGFloat = 8

    static func collapsed(horizontal: Bool) -> CGSize {
        horizontal ? CGSize(width: 200, height: 34) : CGSize(width: 36, height: 168)
    }

    /// `room` adds the resident companion's home below the usual panel.
    static func expanded(horizontal: Bool, room: Bool = false) -> CGSize {
        let base = horizontal ? CGSize(width: 440, height: 150) : CGSize(width: 244, height: 420)
        guard room else { return base }
        return CGSize(width: base.width, height: base.height + (horizontal ? CompanionMetrics.roomHorizontal : CompanionMetrics.roomVertical))
    }
}

/// Room made for a companion living in the notch (layout points, before `scale`).
enum CompanionMetrics {
    /// Collapsed: her lane beside the clock (along a top/bottom edge) or below it (on a side edge).
    static let laneAlong: CGFloat = 84
    static let laneBelow: CGFloat = 58
    /// Opened: her room under the panel.
    static let roomHorizontal: CGFloat = 146
    static let roomVertical: CGFloat = 196
}

/// User-adjustable notch dimensions, as multipliers of the defaults in `NotchMetrics`.
/// `width` runs along the attached edge and `height` away from it, so they follow the notch
/// when it rotates onto a side edge. `scale` enlarges everything, opened panel included.
struct NotchSizing: Equatable, Codable {
    var width: CGFloat = 1
    var height: CGFloat = 1
    var scale: CGFloat = 1

    static let standard = NotchSizing()
    static let widthRange: ClosedRange<CGFloat> = 0.6...1.6
    static let heightRange: ClosedRange<CGFloat> = 0.7...1.6
    static let scaleRange: ClosedRange<CGFloat> = 0.8...1.25

    func clamped() -> NotchSizing {
        func clamp(_ v: CGFloat, _ r: ClosedRange<CGFloat>) -> CGFloat { min(max(v, r.lowerBound), r.upperBound) }
        return NotchSizing(width: clamp(width, Self.widthRange), height: clamp(height, Self.heightRange),
                           scale: clamp(scale, Self.scaleRange))
    }

    /// Collapsed size before `scale`; collapsed content is laid out at this size, then scaled.
    /// `lane` adds the strip a resident companion lives in.
    func collapsedLayout(horizontal: Bool, lane: Bool = false) -> CGSize {
        let base = NotchMetrics.collapsed(horizontal: horizontal)
        var s = horizontal
            ? CGSize(width: base.width * width, height: base.height * height)
            : CGSize(width: base.width * height, height: base.height * width)
        if lane {
            if horizontal { s.width += CompanionMetrics.laneAlong } else { s.height += CompanionMetrics.laneBelow }
        }
        return s
    }

    func collapsed(horizontal: Bool, lane: Bool = false) -> CGSize {
        let s = collapsedLayout(horizontal: horizontal, lane: lane)
        return CGSize(width: s.width * scale, height: s.height * scale)
    }

    func expanded(horizontal: Bool, room: Bool = false) -> CGSize {
        let s = NotchMetrics.expanded(horizontal: horizontal, room: room)
        return CGSize(width: s.width * scale, height: s.height * scale)
    }
}

/// How often a cookie turns up when you open the notch with a companion inside.
enum CookieFrequency: String, CaseIterable, Codable {
    case never, rarely, sometimes, often

    var title: String { rawValue.capitalized }

    /// Chance per opening (a short cooldown keeps it from repeating back to back).
    var chance: Double {
        switch self {
        case .never: 0
        case .rarely: 0.1
        case .sometimes: 0.22
        case .often: 0.4
        }
    }
}

/// How long her messages stay after you've read them.
enum MessageLifetime: String, CaseIterable, Codable {
    case fiveMinutes, thirtyMinutes, oneHour, oneDay, forever

    var title: String {
        switch self {
        case .fiveMinutes: "5 Minutes"
        case .thirtyMinutes: "30 Minutes"
        case .oneHour: "1 Hour"
        case .oneDay: "1 Day"
        case .forever: "Until Dismissed"
        }
    }

    var seconds: TimeInterval? {
        switch self {
        case .fiveMinutes: 5 * 60
        case .thirtyMinutes: 30 * 60
        case .oneHour: 60 * 60
        case .oneDay: 24 * 60 * 60
        case .forever: nil
        }
    }
}

/// Persisted notch preferences, edited live from the Notch Settings window.
@MainActor
final class NotchSettings: ObservableObject {
    /// Each edge keeps its own dimensions; resizing while docked somewhere only changes that
    /// edge's entry.
    @Published private(set) var sizes: [NotchEdge: NotchSizing] {
        didSet { save() }
    }
    /// Where the notch is docked right now. Kept current by `NotchController`.
    @Published var dockedEdge: NotchEdge = .right

    // The resident companion.
    @Published var cookieFrequency: CookieFrequency {
        didSet { UserDefaults.standard.set(cookieFrequency.rawValue, forKey: Self.cookieFrequencyKey) }
    }
    /// The cookie button beside Notch Settings in the opened notch.
    @Published var showsCookieButton: Bool {
        didSet { UserDefaults.standard.set(showsCookieButton, forKey: Self.cookieButtonKey) }
    }
    @Published var messageLifetime: MessageLifetime {
        didSet { UserDefaults.standard.set(messageLifetime.rawValue, forKey: Self.messageLifetimeKey) }
    }

    private static let sizesKey = "edgeSizes"
    private static let cookieFrequencyKey = "cookieFrequency"
    private static let cookieButtonKey = "cookieButton"
    private static let messageLifetimeKey = "messageLifetime"

    init() {
        let d = UserDefaults.standard
        if let data = d.data(forKey: Self.sizesKey),
           let stored = try? JSONDecoder().decode([String: NotchSizing].self, from: data) {
            var loaded: [NotchEdge: NotchSizing] = [:]
            for edge in NotchEdge.allCases {
                loaded[edge] = stored[edge.rawValue]?.clamped() ?? .standard
            }
            sizes = loaded
        } else {
            // Earlier versions kept one size for every edge; start each edge from it.
            func legacy(_ key: String) -> CGFloat { (d.object(forKey: key) as? Double).map { CGFloat($0) } ?? 1 }
            let shared = NotchSizing(width: legacy("sizeWidth"), height: legacy("sizeHeight"),
                                     scale: legacy("sizeScale")).clamped()
            sizes = Dictionary(uniqueKeysWithValues: NotchEdge.allCases.map { ($0, shared) })
        }
        cookieFrequency = d.string(forKey: Self.cookieFrequencyKey).flatMap(CookieFrequency.init(rawValue:)) ?? .sometimes
        showsCookieButton = d.object(forKey: Self.cookieButtonKey) as? Bool ?? true
        messageLifetime = d.string(forKey: Self.messageLifetimeKey).flatMap(MessageLifetime.init(rawValue:)) ?? .thirtyMinutes
    }

    func sizing(for edge: NotchEdge) -> NotchSizing { sizes[edge] ?? .standard }

    func setSizing(_ sizing: NotchSizing, for edge: NotchEdge) {
        let clamped = sizing.clamped()
        guard sizes[edge] != clamped else { return }
        sizes[edge] = clamped
    }

    func reset(_ edge: NotchEdge) { setSizing(.standard, for: edge) }

    private func save() {
        let stored = Dictionary(uniqueKeysWithValues: sizes.map { ($0.key.rawValue, $0.value) })
        if let data = try? JSONEncoder().encode(stored) {
            UserDefaults.standard.set(data, forKey: Self.sizesKey)
        }
    }
}

/// View state for the notch. Every geometric value is set by `NotchController` inside an
/// explicit animation, so SwiftUI interpolates exactly what the controller asks for.
@MainActor
final class NotchModel: ObservableObject {
    @Published var edge: NotchEdge = .right
    @Published var isFloating = false
    @Published var isExpanded = false
    @Published var isPinned = false
    @Published var isAppeared = false
    @Published var bodyCenter = CGPoint(x: NotchMetrics.canvas / 2, y: NotchMetrics.canvas / 2)
    @Published var bodySize = NotchMetrics.collapsed(horizontal: false)
    @Published var ear: CGFloat = 9
    @Published var radius: CGFloat = 14
    @Published var sizing = NotchSizing.standard
    /// A companion lives here (her lane shows while collapsed).
    @Published var hasResident = false
    /// Her room shows when opened (she lives here, or left messages to read).
    @Published var showsRoom = false

    var openSettings: () -> Void = {}
    var openInventory: () -> Void = {}
    var spawnCookie: () -> Void = {}
    var openDetail: (ResourceKind) -> Void = { _ in }
}
