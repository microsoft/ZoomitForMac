import AppKit

@MainActor
final class AppController: NSObject {
    private let settingsStore: SettingsStore
    private let permissionService: PermissionService
    private let hotkeyService: HotkeyService
    private let modeCoordinator: ModeCoordinator

    init(
        settingsStore: SettingsStore,
        permissionService: PermissionService,
        hotkeyService: HotkeyService,
        modeCoordinator: ModeCoordinator
    ) {
        self.settingsStore = settingsStore
        self.permissionService = permissionService
        self.hotkeyService = hotkeyService
        self.modeCoordinator = modeCoordinator
        super.init()
    }

    @objc func activateStaticZoom() {
        modeCoordinator.handle(.activateStaticZoom)
    }

    @objc func checkPermissions() {
        let state = permissionService.currentState()
        let message = "Screen Recording: \(state.screenCapture.isGranted ? "Granted" : "Missing")\nAccessibility: \(state.accessibility.isGranted ? "Granted" : "Missing")"
        let alert = NSAlert()
        alert.messageText = "ZoomIt Permissions"
        alert.informativeText = message
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "Open System Settings")

        if alert.runModal() == .alertSecondButtonReturn {
            permissionService.openSystemSettings()
        }
    }

    @objc func quit() {
        hotkeyService.stop()
        NSApplication.shared.terminate(nil)
    }
}