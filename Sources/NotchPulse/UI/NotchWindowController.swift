import AppKit
import SwiftUI
import Combine

/// Owns the panel: positions it over the notch, keeps it there across screen changes,
/// and turns mouse movement into hover-intent expand / delayed collapse.
///
/// Click-through strategy: the panel is permanently sized for the expanded island (plus a
/// shadow margin) and never resized; `ignoresMouseEvents` is flipped on every mouse move
/// depending on whether the cursor is inside the *currently visible* shape. A global monitor
/// sees moves while we're click-through, the tracking area sees moves while we're not.
@MainActor
final class NotchWindowController: NSObject {
    let model: NotchViewModel
    let panel: NotchPanel
    private let hostingView: NotchHostingView<NotchRootView>
    private let container: TrackingContainerView

    /// Keep expanded regardless of the mouse (debug `--expanded`).
    var forceExpanded = false {
        didSet { if forceExpanded { model.isExpanded = true } }
    }
    var contextMenuProvider: (() -> NSMenu?)? {
        didSet { hostingView.contextMenuProvider = contextMenuProvider }
    }

    private let expandDelay: TimeInterval = 0.15
    private let collapseDelay: TimeInterval = 0.4

    private var globalMonitor: Any?
    private var observers: [NSObjectProtocol] = []
    private var cancellables = Set<AnyCancellable>()
    private var expandWork: DispatchWorkItem?
    private var collapseWork: DispatchWorkItem?
    private var watchdog: Timer?
    private var mouseInside = false

    init(model: NotchViewModel) {
        self.model = model
        let screen = NotchGeometry.preferredScreen()
        let geometry = screen.map(NotchGeometry.make(for:)) ?? .placeholder
        model.geometry = geometry

        panel = NotchPanel(frame: geometry.panelFrame)
        container = TrackingContainerView(frame: NSRect(origin: .zero, size: geometry.panelFrame.size))
        hostingView = NotchHostingView(rootView: NotchRootView(model: model))
        super.init()

        hostingView.sizingOptions = []
        hostingView.frame = container.bounds
        hostingView.autoresizingMask = [.width, .height]
        container.addSubview(hostingView)
        container.onMouseEvent = { [weak self] in self?.evaluateMouse() }
        panel.contentView = container

        installMonitors()

        // Re-check hit area whenever the shape changes size (e.g. collapsed after a click).
        model.$isExpanded
            .removeDuplicates()
            .dropFirst()
            .sink { [weak self] expanded in
                self?.debugLog(expanded ? "expanded" : "collapsed")
                DispatchQueue.main.async { self?.evaluateMouse() }
            }
            .store(in: &cancellables)
    }

    func show() {
        reposition()
        panel.orderFrontRegardless()
        if forceExpanded { model.isExpanded = true }
    }

    func tearDown() {
        if let globalMonitor { NSEvent.removeMonitor(globalMonitor) }
        observers.forEach { NotificationCenter.default.removeObserver($0); NSWorkspace.shared.notificationCenter.removeObserver($0) }
        watchdog?.invalidate()
        panel.orderOut(nil)
    }

    // MARK: Positioning

    func reposition() {
        guard let screen = NotchGeometry.preferredScreen() else { return }
        let geometry = NotchGeometry.make(for: screen)
        if geometry != model.geometry { model.geometry = geometry }
        panel.setFrame(geometry.panelFrame, display: true)
        panel.orderFrontRegardless()
    }

    private func installMonitors() {
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.mouseMoved, .leftMouseDragged]) { [weak self] _ in
            MainActor.assumeIsolated { self?.evaluateMouse() }
        }

        let nc = NotificationCenter.default
        observers.append(nc.addObserver(forName: NSApplication.didChangeScreenParametersNotification,
                                        object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.reposition() }
        })
        let wnc = NSWorkspace.shared.notificationCenter
        observers.append(wnc.addObserver(forName: NSWorkspace.activeSpaceDidChangeNotification,
                                         object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.panel.orderFrontRegardless() }
        })
        observers.append(wnc.addObserver(forName: NSWorkspace.didWakeNotification,
                                         object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.reposition() }
        })
    }

    // MARK: Hover logic

    private func evaluateMouse() {
        let location = NSEvent.mouseLocation
        let g = model.geometry
        // Slight slop so the top screen pixel and the notch edge count as inside.
        var rect = g.shapeRect(expanded: model.isExpanded).insetBy(dx: -2, dy: -2)
        rect.size.height += 2  // extend above the screen top edge
        let inside = rect.contains(location)

        if panel.ignoresMouseEvents == inside {
            panel.ignoresMouseEvents = !inside
            debugLog("ignoresMouseEvents=\(!inside)")
        }
        guard inside != mouseInside else { return }
        mouseInside = inside
        debugLog(inside ? "mouse entered" : "mouse exited")
        inside ? mouseDidEnter() : mouseDidExit()
    }

    private func mouseDidEnter() {
        collapseWork?.cancel()
        startWatchdog()
        guard !model.isExpanded else { return }
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.mouseInside else { return }
            self.model.isExpanded = true
        }
        expandWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + expandDelay, execute: work)
    }

    private func mouseDidExit() {
        expandWork?.cancel()
        guard model.isExpanded, !forceExpanded else { stopWatchdogIfIdle(); return }
        let work = DispatchWorkItem { [weak self] in
            guard let self, !self.mouseInside, !self.forceExpanded else { return }
            self.model.isExpanded = false
            self.stopWatchdogIfIdle()
        }
        collapseWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + collapseDelay, execute: work)
    }

    /// Safety net for missed exit events (fast flicks, Mission Control, display sleep):
    /// re-evaluate a few times per second while the island is hot.
    private func startWatchdog() {
        guard watchdog == nil else { return }
        let t = Timer(timeInterval: 0.25, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.evaluateMouse() }
        }
        RunLoop.main.add(t, forMode: .common)
        watchdog = t
    }

    private let debug = ProcessInfo.processInfo.environment["NOTCHPULSE_DEBUG"] != nil
    private func debugLog(_ message: @autoclosure () -> String) {
        guard debug else { return }
        print(String(format: "[%.3f] ", Date().timeIntervalSince1970.truncatingRemainder(dividingBy: 1000)) + message())
        fflush(stdout)
    }

    private func stopWatchdogIfIdle() {
        guard !mouseInside, !model.isExpanded || forceExpanded else { return }
        watchdog?.invalidate()
        watchdog = nil
    }
}
