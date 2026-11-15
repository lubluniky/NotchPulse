import SwiftUI
import Combine

/// The only object the UI observes. Data sources (mock today, T3Store / SystemMonitor later)
/// push snapshots into `agents` / `system`; the UI calls back out through the closures.
@MainActor
final class NotchViewModel: ObservableObject {
    // MARK: Data (written by the data layer)
    @Published var agents: AgentsSnapshot = .empty
    @Published var system: SystemSnapshot = .empty

    // MARK: UI state
    @Published var isExpanded: Bool = false {
        didSet {
            guard oldValue != isExpanded else { return }
            onExpandedChanged(isExpanded)
        }
    }
    /// Layout for the current screen; set by the window controller.
    @Published var geometry: NotchGeometry = .placeholder

    // MARK: Hooks (wired by AppDelegate)
    /// User clicked an agent row.
    var onOpenThread: (String) -> Void = { _ in }
    /// Island expanded/collapsed (e.g. switch SystemMonitor.fastMode).
    var onExpandedChanged: (Bool) -> Void = { _ in }
    /// "Open T3 Code" (header button + context menu).
    var onOpenT3App: () -> Void = { T3AppLauncher.open() }

    // MARK: Intents (called by views)
    func openThread(_ id: String) {
        onOpenThread(id)
        isExpanded = false
    }

    func openT3App() {
        onOpenT3App()
        isExpanded = false
    }

    // MARK: Derived
    var visibleThreads: [AgentThread] {
        Array(agents.threads.filter { !$0.isSubagent }.prefix(8))
    }
}

/// Best-effort launcher for the T3 Code desktop app.
enum T3AppLauncher {
    static let bundleIDs = ["com.t3tools.t3code", "com.t3tools.t3code.nightly", "com.t3tools.t3code.dev"]

    @MainActor
    static func open() {
        let ws = NSWorkspace.shared
        var url: URL? = bundleIDs.lazy.compactMap { ws.urlForApplication(withBundleIdentifier: $0) }.first
        if url == nil {
            let fm = FileManager.default
            let dirs = ["/Applications", NSHomeDirectory() + "/Applications"]
            outer: for dir in dirs {
                for name in (try? fm.contentsOfDirectory(atPath: dir)) ?? [] where name.hasPrefix("T3 Code") && name.hasSuffix(".app") {
                    url = URL(fileURLWithPath: dir).appendingPathComponent(name)
                    break outer
                }
            }
        }
        guard let url else { NSSound.beep(); return }
        let config = NSWorkspace.OpenConfiguration()
        config.activates = true
        ws.openApplication(at: url, configuration: config, completionHandler: nil)
    }
}
