import AppKit
import Combine
import Foundation

/// Live view of T3 Code agent threads, read from T3's local SQLite state (read-only).
///
/// All SQLite and file-watching work happens on a private serial queue inside `T3Monitor`;
/// snapshots are published on the main actor and only when they actually change.
@MainActor
final class T3Store: ObservableObject {
    @Published private(set) var snapshot: AgentsSnapshot = .empty

    private let monitor: T3Monitor
    private var isStarted = false

    init() {
        let monitor = T3Monitor()
        self.monitor = monitor
        monitor.setHandler { [weak self] snapshot in
            guard let store = self else { return }
            Task { @MainActor in store.apply(snapshot) }
        }
    }

    deinit {
        monitor.stop()
    }

    func start() {
        guard !isStarted else { return }
        isStarted = true
        monitor.start()
    }

    func stop() {
        guard isStarted else { return }
        isStarted = false
        monitor.stop()
    }

    /// Brings T3 Code to the front, deep-linking to the thread when the app supports it
    /// (`t3code://threads/<environmentId>/<threadId>`, handled by T3's desktop shell).
    /// Falls back to plain activation. Does nothing if T3 Code isn't installed.
    func openThread(_ id: String) {
        guard let appURL = T3AppLocator.applicationURL() else { return }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true

        guard let link = T3AppLocator.threadLink(threadId: id, appURL: appURL,
                                                 environmentIdPath: monitor.paths.environmentId) else {
            NSWorkspace.shared.openApplication(at: appURL, configuration: configuration, completionHandler: nil)
            return
        }
        NSWorkspace.shared.open([link], withApplicationAt: appURL, configuration: configuration) { _, error in
            guard error != nil else { return }
            DispatchQueue.main.async {
                NSWorkspace.shared.openApplication(at: appURL, configuration: NSWorkspace.OpenConfiguration(),
                                                   completionHandler: nil)
            }
        }
    }

    private func apply(_ newSnapshot: AgentsSnapshot) {
        guard isStarted, newSnapshot != snapshot else { return }
        snapshot = newSnapshot
    }
}

/// Finds the installed T3 Code app and builds thread deep links.
enum T3AppLocator {
    static let bundleIdentifier = "com.t3tools.t3code"

    static func applicationURL() -> URL? {
        if let running = NSRunningApplication.runningApplications(withBundleIdentifier: bundleIdentifier)
            .first(where: { $0.activationPolicy == .regular && $0.bundleURL != nil }),
           let url = running.bundleURL {
            return url
        }
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleIdentifier) {
            return url
        }
        // Name-based fallback: "T3 Code.app", "T3 Code (Nightly).app", ...
        let fileManager = FileManager.default
        let directories = [
            URL(fileURLWithPath: "/Applications"),
            fileManager.homeDirectoryForCurrentUser.appendingPathComponent("Applications"),
        ]
        for directory in directories {
            guard let entries = try? fileManager.contentsOfDirectory(atPath: directory.path) else { continue }
            if let name = entries.sorted().first(where: { $0.hasPrefix("T3 Code") && $0.hasSuffix(".app") }) {
                return directory.appendingPathComponent(name)
            }
        }
        return nil
    }

    static func urlSchemes(of appURL: URL) -> [String] {
        guard let types = Bundle(url: appURL)?.infoDictionary?["CFBundleURLTypes"] as? [[String: Any]] else { return [] }
        return types.flatMap { ($0["CFBundleURLSchemes"] as? [String]) ?? [] }
    }

    static func threadLink(threadId: String, appURL: URL, environmentIdPath: String) -> URL? {
        let schemes = urlSchemes(of: appURL)
        guard let scheme = ["t3code", "t3code-dev"].first(where: schemes.contains),
              let raw = try? String(contentsOfFile: environmentIdPath, encoding: .utf8) else { return nil }
        let environmentId = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !environmentId.isEmpty, !threadId.isEmpty,
              let env = encodeSegment(environmentId), let thread = encodeSegment(threadId) else { return nil }
        return URL(string: "\(scheme)://threads/\(env)/\(thread)")
    }

    /// Strict percent-encoding of one path segment (like T3's own link builder: only
    /// ASCII letters, digits, '-' and '_' stay literal; e.g. "mcp:launch:x" -> "mcp%3Alaunch%3Ax").
    private static func encodeSegment(_ value: String) -> String? {
        let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_")
        return value.addingPercentEncoding(withAllowedCharacters: allowed)
    }
}
