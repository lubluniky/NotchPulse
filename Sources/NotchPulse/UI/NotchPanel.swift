import AppKit
import SwiftUI

/// Borderless, non-activating, transparent panel that floats above the menu bar on every Space.
final class NotchPanel: NSPanel {
    init(frame: NSRect) {
        super.init(contentRect: frame,
                   styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered,
                   defer: false)
        isFloatingPanel = true
        // Above the menu bar (mainMenu = 24) and its status items.
        level = NSWindow.Level(rawValue: NSWindow.Level.mainMenu.rawValue + 3)
        collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        backgroundColor = .clear
        isOpaque = false
        hasShadow = false
        isMovable = false
        isMovableByWindowBackground = false
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        becomesKeyOnlyIfNeeded = true
        acceptsMouseMovedEvents = true
        ignoresMouseEvents = true
        animationBehavior = .none
        titleVisibility = .hidden
        titlebarAppearsTransparent = true
    }

    // Never steal focus from the user's app.
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    // Borderless windows may sit over the menu bar; don't let AppKit push us down.
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }
}

/// Hosting view that takes the first click (window is never key) and routes right-clicks
/// to an AppKit context menu.
final class NotchHostingView<Content: View>: NSHostingView<Content> {
    var contextMenuProvider: (() -> NSMenu?)?

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func rightMouseDown(with event: NSEvent) {
        guard let menu = contextMenuProvider?() else { return super.rightMouseDown(with: event) }
        NSMenu.popUpContextMenu(menu, with: event, for: self)
    }
}

/// Container that owns an always-active tracking area, so we get mouse-moved / exited events
/// even though the panel is never key. Events are forwarded to the controller.
final class TrackingContainerView: NSView {
    var onMouseEvent: (() -> Void)?
    private var area: NSTrackingArea?

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let area { removeTrackingArea(area) }
        let a = NSTrackingArea(rect: .zero,
                               options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                               owner: self, userInfo: nil)
        addTrackingArea(a)
        area = a
    }

    override func mouseMoved(with event: NSEvent) { onMouseEvent?(); super.mouseMoved(with: event) }
    override func mouseEntered(with event: NSEvent) { onMouseEvent?(); super.mouseEntered(with: event) }
    override func mouseExited(with event: NSEvent) { onMouseEvent?(); super.mouseExited(with: event) }
}
