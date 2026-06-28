import AppKit

@MainActor
final class AppController: NSObject {
    private let settingsStore: SettingsStore
    private let permissionService: PermissionService
    private let hotkeyService: HotkeyService
    private let modeCoordinator: ModeCoordinator
    private lazy var settingsWindowController = SettingsWindowController(
        settingsStore: settingsStore,
        onHotKeyChange: { [weak self] in self?.hotkeyService.reloadHotkey() },
        onSuspendHotkeys: { [weak self] in self?.hotkeyService.stop() },
        onResumeHotkeys: { [weak self] in self?.hotkeyService.start() },
        onRequestMicrophone: { [weak self] in self?.permissionService.requestMicrophoneAccess() }
    )

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

    @objc func activateLiveZoom() {
        modeCoordinator.handle(.activateLiveZoom)
    }

    @objc func toggleRecording() {
        modeCoordinator.handle(.toggleRecording(region: false))
    }

    @objc func showSettings() {
        settingsWindowController.show()
    }

    @objc func checkPermissions() {
        let state = permissionService.currentState()
        let screen = state.screenCapture.isGranted ? "Granted" : "Missing"
        let micStatus = permissionService.microphoneStatus()
        let mic: String
        switch micStatus {
        case .granted: mic = "Granted"
        case .denied: mic = "Denied"
        case .notDetermined: mic = "Not requested"
        }

        let alert = NSAlert()
        alert.messageText = "ZoomIt Permissions"
        alert.informativeText = """
        Screen Recording: \(screen)
        Microphone: \(mic)

        Screen Recording is required for zoom, snip, and recording. Microphone is optional — used only when recording your voice.
        """
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "Screen Recording Settings…")
        alert.addButton(withTitle: micStatus == .notDetermined ? "Grant Microphone…" : "Microphone Settings…")

        switch alert.runModal() {
        case .alertSecondButtonReturn:
            permissionService.openSystemSettings()
        case .alertThirdButtonReturn:
            if micStatus == .notDetermined {
                permissionService.requestMicrophoneAccess()
            } else {
                permissionService.openMicrophoneSettings()
            }
        default:
            break
        }
    }

    @objc func quit() {
        hotkeyService.stop()
        NSApplication.shared.terminate(nil)
    }
}