import SwiftUI

/// Picks a "nice" vertical ceiling so low loads still show shape (0.25 / 0.5 / 1.0).
func sparklineCeiling(_ values: [Double]) -> Double {
    let peak = values.max() ?? 0
    for c in [0.25, 0.5, 1.0] where peak <= c * 0.95 { return c }
    return 1.0
}

/// Smooth line (or closed area) through normalized samples.
struct SparklineShape: Shape {
    var values: [Double]
    var ceiling: Double = 1
    var closed: Bool = false

    func path(in rect: CGRect) -> Path {
        var p = Path()
        guard values.count > 1 else { return p }
        let n = values.count
        let step = rect.width / CGFloat(n - 1)
        let c = max(ceiling, 0.0001)
        let pts: [CGPoint] = values.enumerated().map { i, v in
            let y = rect.maxY - CGFloat(min(1, max(0, v / c))) * rect.height
            return CGPoint(x: rect.minX + CGFloat(i) * step, y: y)
        }

        p.move(to: pts[0])
        // Monotone-ish smoothing: cubic with horizontal tangents at midpoints.
        for i in 1..<pts.count {
            let a = pts[i - 1], b = pts[i]
            let mx = (a.x + b.x) / 2
            p.addCurve(to: b, control1: CGPoint(x: mx, y: a.y), control2: CGPoint(x: mx, y: b.y))
        }
        if closed {
            p.addLine(to: CGPoint(x: pts[n - 1].x, y: rect.maxY))
            p.addLine(to: CGPoint(x: pts[0].x, y: rect.maxY))
            p.closeSubpath()
        }
        return p
    }
}

/// Line + gradient area sparkline.
struct Sparkline: View {
    var values: [Double]
    var color: Color
    var lineWidth: CGFloat = 1.5
    var showArea: Bool = true
    var showHead: Bool = false

    var body: some View {
        let ceiling = sparklineCeiling(values)
        ZStack {
            if showArea {
                SparklineShape(values: values, ceiling: ceiling, closed: true)
                    .fill(LinearGradient(colors: [color.opacity(0.38), color.opacity(0.0)],
                                         startPoint: .top, endPoint: .bottom))
            }
            SparklineShape(values: values, ceiling: ceiling)
                .stroke(color, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round, lineJoin: .round))
            if showHead, let last = values.last {
                GeometryReader { geo in
                    let y = geo.size.height - CGFloat(min(1, last / ceiling)) * geo.size.height
                    Circle()
                        .fill(color)
                        .frame(width: lineWidth * 2.6, height: lineWidth * 2.6)
                        .shadow(color: color.opacity(0.8), radius: 3)
                        .position(x: geo.size.width, y: y)
                }
            }
        }
    }
}
