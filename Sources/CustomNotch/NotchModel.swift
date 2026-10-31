import SwiftUI

enum NotchEdge: String, CaseIterable {
    case top, bottom, left, right

    var isHorizontal: Bool { self == .top || self == .bottom }

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

    static func expanded(horizontal: Bool) -> CGSize {
        horizontal ? CGSize(width: 440, height: 150) : CGSize(width: 244, height: 420)
    }
}

/// User-adjustable notch dimensions, as multipliers of the defaults in `NotchMetrics`.
/// `width` runs along the attached edge and `height` away from it, so they follow the notch
/// when it rotates onto a side edge. `scale` enlarges everything, opened panel included.
struct NotchSizing: Equatable {
    var width: CGFloat = 1
    var height: CGFloat = 1
    var scale: CGFloat = 1

    static let standard = NotchSizing()
    static let widthRange: ClosedRange<CGFloat> = 0.6...1.6
    static let heightRange: ClosedRange<CGFloat> = 0.7...1.6
    static let scaleRange: ClosedRange<CGFloat> = 0.8...1.25

    /// Collapsed size before `scale`; collapsed content is laid out at this size, then scaled.
    func collapsedLayout(horizontal: Bool) -> CGSize {
        let base = NotchMetrics.collapsed(horizontal: horizontal)
        return horizontal
            ? CGSize(width: base.width * width, height: base.height * height)
            : CGSize(width: base.width * height, height: base.height * width)
    }

    func collapsed(horizontal: Bool) -> CGSize {
        let s = collapsedLayout(horizontal: horizontal)
        return CGSize(width: s.width * scale, height: s.height * scale)
    }

    func expanded(horizontal: Bool) -> CGSize {
        let s = NotchMetrics.expanded(horizontal: horizontal)
        return CGSize(width: s.width * scale, height: s.height * scale)
    }
}

/// Persisted notch preferences, edited live from the Notch Settings window.
@MainActor
final class NotchSettings: ObservableObject {
    @Published var sizing: NotchSizing {
        didSet { save() }
    }

    init() {
        let d = UserDefaults.standard
        func value(_ key: String, _ range: ClosedRange<CGFloat>) -> CGFloat {
            guard let v = d.object(forKey: key) as? Double else { return 1 }
            return min(max(CGFloat(v), range.lowerBound), range.upperBound)
        }
        sizing = NotchSizing(width: value("sizeWidth", NotchSizing.widthRange),
                             height: value("sizeHeight", NotchSizing.heightRange),
                             scale: value("sizeScale", NotchSizing.scaleRange))
    }

    func reset() { sizing = .standard }

    private func save() {
        let d = UserDefaults.standard
        d.set(Double(sizing.width), forKey: "sizeWidth")
        d.set(Double(sizing.height), forKey: "sizeHeight")
        d.set(Double(sizing.scale), forKey: "sizeScale")
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

    var openSettings: () -> Void = {}
}
