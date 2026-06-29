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
        onRequestMicrophone: { [weak self] in self?.permissionService.requestMicrophoneAccess() },
        onRequestCamera: { [weak self] in self?.permissionService.requestCameraAccess() },
        onOpenTrimEditor: { [weak self] in self?.modeCoordinator.openTrimEditor() }
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

    @objc func startPanorama() {
        modeCoordinator.handle(.startPanorama(save: false))
    }

    @objc func showSettings() {
        settingsWindowController.show()
    }

    @objc func checkPermissions() {
        let state = permissionService.currentState()
        let screen = state.screenCapture.isGranted ? "Granted" : "Missing"
        let micStatus = permissionService.microphoneStatus()
        let camStatus = permissionService.cameraStatus()
        func describe(_ status: MicrophonePermission) -> String {
            switch status {
            case .granted: return "Granted"
            case .denied: return "Denied"
            case .notDetermined: return "Not requested"
            }
        }

        let alert = NSAlert()
        alert.messageText = "ZoomIt Permissions"
        alert.informativeText = """
        Screen Recording: \(screen)
        Microphone: \(describe(micStatus))
        Camera: \(describe(camStatus))

        Screen Recording is required for zoom, snip, and recording. Microphone and Camera are optional — used for recording your voice and webcam.
        """
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "Screen Recording Settings…")
        alert.addButton(withTitle: micStatus == .notDetermined ? "Grant Microphone…" : "Microphone Settings…")
        alert.addButton(withTitle: camStatus == .notDetermined ? "Grant Camera…" : "Camera Settings…")

        switch alert.runModal() {
        case .alertSecondButtonReturn:
            permissionService.openSystemSettings()
        case .alertThirdButtonReturn:
            if micStatus == .notDetermined {
                permissionService.requestMicrophoneAccess()
            } else {
                permissionService.openMicrophoneSettings()
            }
        case NSApplication.ModalResponse(rawValue: NSApplication.ModalResponse.alertThirdButtonReturn.rawValue + 1):
            if camStatus == .notDetermined {
                permissionService.requestCameraAccess()
            } else {
                permissionService.openCameraSettings()
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