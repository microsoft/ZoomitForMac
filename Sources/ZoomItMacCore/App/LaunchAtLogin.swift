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

    /// Registers or unregisters the app as a login item.
    static func setEnabled(_ enabled: Bool) throws {
        let service = SMAppService.mainApp
        if enabled {
            if service.status != .enabled {
                try service.register()
            }
        } else {
            if service.status == .enabled {
                try service.unregister()
            }
        }
    }
}
