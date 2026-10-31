import SwiftUI

/// The notch silhouette. The body sits inside `rect` inset by `pad` on every side.
///
/// `ear > 0` draws concave fillets that flare out along the attached edge (the classic notch
/// look); `ear < 0` rounds the attached corners instead. Animating `ear` through zero morphs
/// smoothly between an attached notch and a free-floating capsule.
struct NotchShape: Shape {
    var edge: NotchEdge
    var ear: CGFloat
    var radius: CGFloat
    var pad: CGFloat = NotchMetrics.earPad

    var animatableData: AnimatablePair<CGFloat, CGFloat> {
        get { AnimatablePair(ear, radius) }
        set { ear = newValue.first; radius = newValue.second }
    }

    func path(in rect: CGRect) -> Path {
        let body = rect.insetBy(dx: pad, dy: pad)
        guard body.width > 1, body.height > 1 else { return Path() }

        // Work in edge-local coordinates: u runs along the attached edge, v runs away from it.
        let length = edge.isHorizontal ? body.width : body.height
        let depth = edge.isHorizontal ? body.height : body.width
        let limit = min(length, depth) / 2
        let r = min(max(radius, 0), limit)
        let s = min(max(ear, -limit), min(pad, limit))
        let a = abs(s)

        func pt(_ u: CGFloat, _ v: CGFloat) -> CGPoint {
            switch edge {
            case .top: CGPoint(x: body.minX + u, y: body.minY + v)
            case .bottom: CGPoint(x: body.minX + u, y: body.maxY - v)
            case .left: CGPoint(x: body.minX + v, y: body.minY + u)
            case .right: CGPoint(x: body.maxX - v, y: body.minY + u)
            }
        }

        var p = Path()
        p.move(to: pt(-s, 0))
        p.continuousCorner(corner: pt(0, 0), to: pt(0, a))
        p.addLine(to: pt(0, depth - r))
        p.continuousCorner(corner: pt(0, depth), to: pt(r, depth))
        p.addLine(to: pt(length - r, depth))
        p.continuousCorner(corner: pt(length, depth), to: pt(length, depth - r))
        p.addLine(to: pt(length, a))
        p.continuousCorner(corner: pt(length, 0), to: pt(length + s, 0))
        p.closeSubpath()
        return p
    }
}

private extension Path {
    /// A corner from the current point to `end`, pulled towards `corner`, approximating the
    /// soft continuous-curvature corners Apple uses.
    mutating func continuousCorner(corner: CGPoint, to end: CGPoint) {
        guard let start = currentPoint else { return }
        let k: CGFloat = 0.6
        let c1 = CGPoint(x: start.x + (corner.x - start.x) * k, y: start.y + (corner.y - start.y) * k)
        let c2 = CGPoint(x: end.x + (corner.x - end.x) * k, y: end.y + (corner.y - end.y) * k)
        addCurve(to: end, control1: c1, control2: c2)
    }
}
