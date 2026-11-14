import SwiftUI

/// The island silhouette.
///
/// - `earRadius`: concave flares at the top corners that melt into the screen's top edge
///   (notch screens). The body is inset by this amount on each side.
/// - `topRadius`: convex top corners (floating pill on screens without a notch).
/// - `bottomRadius`: convex bottom corners.
///
/// All three animate, so the spring between collapsed and expanded morphs the corners too.
struct NotchShape: Shape {
    var earRadius: CGFloat
    var topRadius: CGFloat
    var bottomRadius: CGFloat

    var animatableData: AnimatablePair<CGFloat, AnimatablePair<CGFloat, CGFloat>> {
        get { AnimatablePair(earRadius, AnimatablePair(topRadius, bottomRadius)) }
        set {
            earRadius = newValue.first
            topRadius = newValue.second.first
            bottomRadius = newValue.second.second
        }
    }

    func path(in rect: CGRect) -> Path {
        let ear = max(0, min(earRadius, rect.width / 4, rect.height / 2))
        let bodyMinX = rect.minX + ear
        let bodyMaxX = rect.maxX - ear
        let bodyWidth = bodyMaxX - bodyMinX
        let top = max(0, min(topRadius, bodyWidth / 2, rect.height / 2))
        let bottom = max(0, min(bottomRadius, bodyWidth / 2, rect.height - max(ear, top)))

        // Circular-arc corners drawn with cubic Béziers (k ≈ 0.5523) for smooth curvature.
        let k: CGFloat = 0.5523

        var p = Path()
        if ear > 0 {
            // Top-left ear: from the screen edge curving down into the body's left side.
            p.move(to: CGPoint(x: rect.minX, y: rect.minY))
            p.addCurve(to: CGPoint(x: bodyMinX, y: rect.minY + ear),
                       control1: CGPoint(x: rect.minX + ear * k, y: rect.minY),
                       control2: CGPoint(x: bodyMinX, y: rect.minY + ear * (1 - k)))
        } else if top > 0 {
            p.move(to: CGPoint(x: bodyMinX, y: rect.minY + top))
        } else {
            p.move(to: CGPoint(x: bodyMinX, y: rect.minY))
        }

        // Left side down to bottom-left corner.
        p.addLine(to: CGPoint(x: bodyMinX, y: rect.maxY - bottom))
        p.addCurve(to: CGPoint(x: bodyMinX + bottom, y: rect.maxY),
                   control1: CGPoint(x: bodyMinX, y: rect.maxY - bottom * (1 - k)),
                   control2: CGPoint(x: bodyMinX + bottom * (1 - k), y: rect.maxY))
        // Bottom edge.
        p.addLine(to: CGPoint(x: bodyMaxX - bottom, y: rect.maxY))
        p.addCurve(to: CGPoint(x: bodyMaxX, y: rect.maxY - bottom),
                   control1: CGPoint(x: bodyMaxX - bottom * (1 - k), y: rect.maxY),
                   control2: CGPoint(x: bodyMaxX, y: rect.maxY - bottom * (1 - k)))

        if ear > 0 {
            p.addLine(to: CGPoint(x: bodyMaxX, y: rect.minY + ear))
            p.addCurve(to: CGPoint(x: rect.maxX, y: rect.minY),
                       control1: CGPoint(x: bodyMaxX, y: rect.minY + ear * (1 - k)),
                       control2: CGPoint(x: rect.maxX - ear * k, y: rect.minY))
        } else if top > 0 {
            p.addLine(to: CGPoint(x: bodyMaxX, y: rect.minY + top))
            p.addCurve(to: CGPoint(x: bodyMaxX - top, y: rect.minY),
                       control1: CGPoint(x: bodyMaxX, y: rect.minY + top * (1 - k)),
                       control2: CGPoint(x: bodyMaxX - top * (1 - k), y: rect.minY))
            p.addLine(to: CGPoint(x: bodyMinX + top, y: rect.minY))
            p.addCurve(to: CGPoint(x: bodyMinX, y: rect.minY + top),
                       control1: CGPoint(x: bodyMinX + top * (1 - k), y: rect.minY),
                       control2: CGPoint(x: bodyMinX, y: rect.minY + top * (1 - k)))
        } else {
            p.addLine(to: CGPoint(x: bodyMaxX, y: rect.minY))
        }
        p.closeSubpath()
        return p
    }
}
