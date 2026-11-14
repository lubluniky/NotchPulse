import Foundation
import ServiceManagement

/// "Launch at Login" via SMAppService. Only works from a bundled .app (scripts/bundle.sh);
/// when run as a bare SwiftPM binary every call fails gracefully.
enum LoginItem {
    static var isSupported: Bool {
        Bundle.main.bundleIdentifier != nil && Bundle.main.bundlePath.hasSuffix(".app")
    }

    static var isEnabled: Bool {
        guard isSupported else { return false }
        return SMAppService.mainApp.status == .enabled
    }

    /// Returns an error message on failure.
    @discardableResult
    static func setEnabled(_ enabled: Bool) -> String? {
        guard isSupported else { return "Launch at Login requires the bundled NotchPulse.app." }
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            return nil
        } catch {
            return error.localizedDescription
        }
    }
}
