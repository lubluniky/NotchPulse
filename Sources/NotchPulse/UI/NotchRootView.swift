import SwiftUI

/// Fills the whole (mostly transparent) panel; draws the island anchored to the top center.
struct NotchRootView: View {
    @ObservedObject var model: NotchViewModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let g = model.geometry
        let expanded = model.isExpanded
        let size = expanded ? g.expandedSize : g.collapsedSize
        let shape = NotchShape(
            earRadius: expanded ? g.expandedEar : g.collapsedEar,
            topRadius: expanded ? g.expandedTopRadius : g.collapsedTopRadius,
            bottomRadius: expanded ? g.expandedBottomRadius : g.collapsedBottomRadius)

        ZStack(alignment: .top) {
            // Static silhouette + shadow on its own layer, so per-second content updates
            // never invalidate (and re-blur) the shadow.
            shape
                .fill(Color.black)
                .shadow(color: .black.opacity(expanded ? 0.5 : 0), radius: expanded ? 16 : 0, x: 0, y: expanded ? 8 : 0)
                .overlay(
                    // Hairline rim when expanded / floating so the body separates from dark wallpapers.
                    shape.stroke(Color.white.opacity(expanded || !g.hasNotch ? 0.07 : 0), lineWidth: 1)
                        .mask(LinearGradient(colors: [.clear, .white], startPoint: .top, endPoint: .bottom))
                )

            ZStack(alignment: .top) {
                if expanded {
                    ExpandedView(model: model)
                        .frame(width: g.expandedSize.width, height: g.expandedSize.height)
                        .transition(.asymmetric(
                            // Content grows with the silhouette instead of being revealed by the clip.
                            insertion: .opacity.combined(with: .scale(scale: 0.82, anchor: .top))
                                .animation(.spring(response: 0.36, dampingFraction: 0.84).delay(0.04)),
                            removal: .opacity.animation(.easeOut(duration: 0.1))))
                } else {
                    CollapsedView(model: model)
                        .frame(width: g.collapsedSize.width, height: g.collapsedSize.height)
                        .transition(.asymmetric(
                            insertion: .opacity.animation(.easeOut(duration: 0.2).delay(0.12)),
                            removal: .opacity.animation(.easeOut(duration: 0.08))))
                }
            }
            .frame(width: size.width, height: size.height, alignment: .top)
            .clipShape(shape)
        }
        .frame(width: size.width, height: size.height, alignment: .top)
        .padding(.top, g.topInset)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .animation(reduceMotion ? Motion.reduced : Motion.notchSpring, value: expanded)
        .animation(reduceMotion ? Motion.reduced : Motion.notchSpring, value: g)
        .ignoresSafeArea()
        .environment(\.colorScheme, .dark)
    }
}

/// Expanded island: header band beside the notch, then agents (left) and system (right).
struct ExpandedView: View {
    @ObservedObject var model: NotchViewModel

    /// Uniform gutter between the black body edge and inner cards (inner radius 12 + 12 = outer 24).
    static let gutter: CGFloat = 12

    var body: some View {
        let g = model.geometry
        let inset = g.expandedEar + Self.gutter
        let innerWidth = g.expandedSize.width - 2 * inset
        let gap: CGFloat = 12
        let leftWidth = ((innerWidth - gap) * 0.6).rounded()
        let rightWidth = innerWidth - gap - leftWidth
        // Header items must stay clear of the hardware notch.
        let notchHalf = g.hasNotch ? g.notchWidth / 2 + 10 : 0
        let sideWidth = g.hasNotch ? g.expandedSize.width / 2 - notchHalf - inset : innerWidth / 2

        VStack(spacing: 0) {
            HStack(spacing: 0) {
                AgentsHeader(agents: model.agents)
                    .padding(.leading, 2)
                    .frame(width: sideWidth, alignment: .leading)
                Spacer(minLength: 0)
                T3HeaderButton(online: model.agents.serverOnline) { model.openT3App() }
                    .frame(width: sideWidth, alignment: .trailing)
            }
            .frame(height: g.hasNotch ? g.bandHeight : 36)

            HStack(alignment: .top, spacing: gap) {
                AgentsColumn(model: model)
                    .frame(width: leftWidth)
                    .frame(maxHeight: .infinity, alignment: .top)
                SystemColumn(system: model.system)
                    .frame(width: rightWidth)
            }
            .padding(.top, 8)
        }
        .padding(.horizontal, inset)
        .padding(.bottom, Self.gutter)
    }
}
