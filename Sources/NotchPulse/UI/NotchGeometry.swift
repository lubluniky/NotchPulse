import AppKit

/// Layout of the island on a particular screen. All values in points.
///
/// Notch screens: the shape's top edge is flush with the screen top and the collapsed
/// state is exactly as tall as the hardware notch, so it reads as an extension of it.
/// Screens without a notch: a compact floating pill centered just under the menu bar.
struct NotchGeometry: Equatable {
    var hasNotch: Bool
    /// Width of the hardware notch (0 when there is none).
    var notchWidth: CGFloat
    /// Height of the collapsed band (= notch height on notch screens).
    var bandHeight: CGFloat
    /// Distance from the screen's top edge to the top of the shape.
    var topInset: CGFloat
    /// Full screen frame (global AppKit coordinates, bottom-left origin).
    var screenFrame: CGRect
    /// Horizontal center of the notch / pill in global coordinates.
    var centerX: CGFloat

    var expandedSize = CGSize(width: 640, height: 252)
    /// Transparent margin around the shape inside the panel so the drop shadow isn't clipped.
    var shadowMargin: CGFloat = 32

    // Corner styling
    var collapsedEar: CGFloat { hasNotch ? 6 : 0 }
    var expandedEar: CGFloat { hasNotch ? 14 : 0 }
    var collapsedBottomRadius: CGFloat { hasNotch ? 10 : bandHeight / 2 }
    var expandedBottomRadius: CGFloat { 24 }
    /// Convex top corners — only for the floating pill.
    var collapsedTopRadius: CGFloat { hasNotch ? 0 : bandHeight / 2 }
    var expandedTopRadius: CGFloat { hasNotch ? 0 : 24 }

    var collapsedSize: CGSize {
        CGSize(width: hasNotch ? notchWidth : 180, height: bandHeight)
    }

    var panelSize: CGSize {
        CGSize(width: max(expandedSize.width, collapsedSize.width) + 2 * shadowMargin,
               height: topInset + expandedSize.height + shadowMargin)
    }

    var panelFrame: CGRect {
        let size = panelSize
        return CGRect(x: (centerX - size.width / 2).rounded(),
                      y: screenFrame.maxY - size.height,
                      width: size.width, height: size.height)
    }

    /// Screen-space rect of the visible shape for the given state (for hit testing).
    func shapeRect(expanded: Bool) -> CGRect {
        let size = expanded ? expandedSize : collapsedSize
        return CGRect(x: centerX - size.width / 2,
                      y: screenFrame.maxY - topInset - size.height,
                      width: size.width, height: size.height)
    }

    static func make(for screen: NSScreen) -> NotchGeometry {
        let frame = screen.frame
        let safeTop = screen.safeAreaInsets.top
        if safeTop > 0,
           let left = screen.auxiliaryTopLeftArea,
           let right = screen.auxiliaryTopRightArea {
            let notchMinX = left.maxX
            let notchMaxX = right.minX
            let width = max(0, notchMaxX - notchMinX)
            return NotchGeometry(hasNotch: true,
                                 notchWidth: width,
                                 bandHeight: safeTop,
                                 topInset: 0,
                                 screenFrame: frame,
                                 centerX: notchMinX + width / 2)
        }
        // No notch: float just under the menu bar.
        var menuBar = frame.maxY - screen.visibleFrame.maxY
        if menuBar <= 0 || menuBar > 60 { menuBar = 25 }
        return NotchGeometry(hasNotch: false,
                             notchWidth: 0,
                             bandHeight: 30,
                             topInset: menuBar + 6,
                             screenFrame: frame,
                             centerX: frame.midX)
    }

    /// The screen with a notch if any, else the main screen.
    static func preferredScreen() -> NSScreen? {
        NSScreen.screens.first(where: { $0.safeAreaInsets.top > 0 }) ?? NSScreen.main ?? NSScreen.screens.first
    }

    static let placeholder = NotchGeometry(hasNotch: true, notchWidth: 180, bandHeight: 32, topInset: 0,
                                           screenFrame: CGRect(x: 0, y: 0, width: 1470, height: 956),
                                           centerX: 735)
}
