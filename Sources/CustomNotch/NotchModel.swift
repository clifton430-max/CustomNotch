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
        horizontal ? CGSize(width: 440, height: 146) : CGSize(width: 244, height: 420)
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
}
