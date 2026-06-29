import ServiceManagement

/// Thin wrapper over `SMAppService.mainApp` for the "launch at login" option.
/// Requires the app to be a bundled `.app` registered with launchd; when run as
/// a bare executable the register/unregister calls throw, which the settings UI
/// surfaces to the user.
enum LaunchAtLogin {
    /// True when the app is currently registered to launch at login.
    static var isEnabled: Bool {
        SMAppService.mainApp.status == .enabled
    }

    /// True when macOS already has a registered or pending login item for the
    /// app, used to migrate the older status-only setting into UserDefaults.
    static var isEnabledOrPending: Bool {
        let status = SMAppService.mainApp.status
        return status == .enabled || status == .requiresApproval
    }

    /// Best-effort reconciliation of the persisted preference at app launch.
    static func applySavedPreference(_ enabled: Bool) {
        try? setEnabled(enabled)
    }

    /// Registers or unregisters the app as a login item.
    static func setEnabled(_ enabled: Bool) throws {
        let service = SMAppService.mainApp
        if enabled {
            if service.status != .enabled {
                try service.register()
            }
        } else {
            if service.status != .notRegistered {
                try service.unregister()
            }
        }
    }
}
