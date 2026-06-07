import Foundation
import ServiceManagement

/// Launch-at-login via SMAppService (macOS 13+). `register()`/`unregister()` throw.
enum LoginItem {
    static var isEnabled: Bool { SMAppService.mainApp.status == .enabled }

    static var statusDescription: String {
        switch SMAppService.mainApp.status {
        case .enabled: return "On"
        case .notRegistered: return "Off"
        case .requiresApproval: return "Needs approval in System Settings › Login Items"
        case .notFound: return "Unavailable (run the bundled app)"
        @unknown default: return "Unknown"
        }
    }

    /// Returns nil on success, or a user-facing error message.
    @discardableResult
    static func setEnabled(_ on: Bool) -> String? {
        do {
            if on { try SMAppService.mainApp.register() }
            else { try SMAppService.mainApp.unregister() }
            return nil
        } catch {
            return error.localizedDescription
        }
    }
}
