import AppKit

@MainActor
final class AppController: NSObject {
    private let settingsStore: SettingsStore
    private let permissionService: PermissionService
    private let hotkeyService: HotkeyService
    private let modeCoordinator: ModeCoordinator
    /// One-shot observer used to re-present the permissions dialog when the user
    /// returns to ZoomIt after being sent to System Settings.
    private var permissionReactivationObserver: NSObjectProtocol?
    private lazy var settingsWindowController = SettingsWindowController(
        settingsStore: settingsStore,
        onHotKeyChange: { [weak self] in self?.hotkeyService.reloadHotkey() },
        onSuspendHotkeys: { [weak self] in self?.hotkeyService.stop() },
        onResumeHotkeys: { [weak self] in self?.hotkeyService.start() },
        onRequestMicrophone: { [weak self] in self?.permissionService.requestMicrophoneAccess(completion: nil) },
        onRequestCamera: { [weak self] in self?.permissionService.requestCameraAccess(completion: nil) },
        onOpenTrimEditor: { [weak self] in self?.modeCoordinator.openTrimEditor() }
    )
    private lazy var permissionsWizardWindowController = PermissionsWizardWindowController(
        permissionService: permissionService,
        settingsStore: settingsStore
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

    @objc func activateDrawWithoutZoom() {
        modeCoordinator.handle(.activateDrawWithoutZoom)
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

    @objc func toggleBreakTimer() {
        modeCoordinator.handle(.toggleBreakTimer)
    }

    @objc func showSettings() {
        settingsWindowController.show()
    }

    @objc func checkPermissions() {
        presentPermissionsDialog()
    }

    @objc func showPermissionsWizard() {
        permissionsWizardWindowController.show()
    }

    /// The button reads "Grant…" only the very first time — once macOS has
    /// shown the one-time system prompt (whether granted, denied, or
    /// dismissed), it always reads "Settings…" since re-requesting can no
    /// longer show anything.
    private func screenButtonTitle(granted: Bool) -> String {
        (granted || settingsStore.hasRequestedScreenCaptureAccess) ? "Screen Recording Settings…" : "Grant Screen Recording…"
    }

    /// Shows the permission status dialog and acts on the chosen button, then
    /// re-presents itself so the user can grant or open settings for several
    /// permissions in one sitting and watch the status refresh. For the
    /// microphone/camera grant prompts (which are asynchronous), it waits for the
    /// system prompt to resolve before re-presenting; other actions re-present on
    /// the next runloop turn. It stops only when the user clicks Done.
    private func presentPermissionsDialog() {
        let state = permissionService.currentState()
        let screenGranted = state.screenCapture.isGranted
        let micStatus = permissionService.microphoneStatus()
        let camStatus = permissionService.cameraStatus()

        let alert = NSAlert()
        alert.messageText = "ZoomIt Permissions"
        alert.accessoryView = Self.makePermissionsAccessoryView(
            screenGranted: screenGranted,
            micStatus: micStatus,
            camStatus: camStatus
        )
        alert.addButton(withTitle: "Done")
        alert.addButton(withTitle: screenButtonTitle(granted: screenGranted))
        alert.addButton(withTitle: micStatus == .notDetermined ? "Grant Microphone…" : "Microphone Settings…")
        alert.addButton(withTitle: camStatus == .notDetermined ? "Grant Camera…" : "Camera Settings…")
        alert.addButton(withTitle: "Run Welcome…")
        // Use a standard macOS-style rounded-square icon so the dialog matches
        // the look of system permission prompts and the icon top lines up with
        // the message text.
        if let icon = ZoomItAppIcon.standardIcon() {
            alert.icon = icon
        }
        alert.window.animationBehavior = .none
        NSApp.activate(ignoringOtherApps: true)

        switch alert.runModal() {
        case .alertSecondButtonReturn:
            if screenGranted || settingsStore.hasRequestedScreenCaptureAccess {
                // Either already granted, or macOS already showed the
                // one-time prompt before — requesting again would silently
                // do nothing, so send the user to Settings instead.
                permissionService.openSystemSettings()
                representWhenActive()
            } else {
                settingsStore.markScreenCaptureAccessRequested()
                let granted = permissionService.requestScreenCaptureAccess()
                if granted {
                    presentPermissionsDialog()
                }
            }
        case .alertThirdButtonReturn:
            if micStatus == .notDetermined {
                // Wait for the system prompt to resolve, then re-present so the
                // dialog doesn't collide with it and shows the updated status.
                permissionService.requestMicrophoneAccess { [weak self] in
                    self?.presentPermissionsDialog()
                }
            } else {
                permissionService.openMicrophoneSettings()
                representWhenActive()
            }
        case NSApplication.ModalResponse(rawValue: NSApplication.ModalResponse.alertThirdButtonReturn.rawValue + 1):
            if camStatus == .notDetermined {
                permissionService.requestCameraAccess { [weak self] in
                    self?.presentPermissionsDialog()
                }
            } else {
                permissionService.openCameraSettings()
                representWhenActive()
            }
        case NSApplication.ModalResponse(rawValue: NSApplication.ModalResponse.alertThirdButtonReturn.rawValue + 2):
            showPermissionsWizard()
        default:
            break
        }
    }

    /// Re-presents the permissions dialog the next time ZoomIt becomes active.
    /// Used after sending the user to System Settings so the dialog reappears
    /// when they switch back, without stealing focus from System Settings.
    private func representWhenActive() {
        if let permissionReactivationObserver {
            NotificationCenter.default.removeObserver(permissionReactivationObserver)
            self.permissionReactivationObserver = nil
        }
        permissionReactivationObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                if let observer = self.permissionReactivationObserver {
                    NotificationCenter.default.removeObserver(observer)
                    self.permissionReactivationObserver = nil
                }
                self.presentPermissionsDialog()
            }
        }
    }

    /// Builds the Check Permissions dialog's accessory view: the three status
    /// lines (with "Granted" shown in green, since NSAlert's plain
    /// `informativeText` can't color individual words) followed by the
    /// explanatory paragraph.
    private static func makePermissionsAccessoryView(
        screenGranted: Bool,
        micStatus: MicrophonePermission,
        camStatus: MicrophonePermission
    ) -> NSView {
        func describe(_ status: MicrophonePermission) -> String {
            switch status {
            case .granted: return "Granted"
            case .denied: return "Denied"
            case .notDetermined: return "Not requested"
            }
        }

        let width: CGFloat = 300
        let labelFont = NSFont.systemFont(ofSize: 13)

        let statusText = NSMutableAttributedString()
        func appendStatusLine(_ label: String, _ value: String, granted: Bool) {
            if statusText.length > 0 {
                statusText.append(NSAttributedString(string: "\n"))
            }
            statusText.append(NSAttributedString(
                string: "\(label): ",
                attributes: [.font: labelFont, .foregroundColor: NSColor.labelColor]
            ))
            statusText.append(NSAttributedString(
                string: value,
                attributes: [.font: labelFont, .foregroundColor: granted ? NSColor.systemGreen : NSColor.labelColor]
            ))
        }
        appendStatusLine("Screen Recording", screenGranted ? "Granted" : "Missing", granted: screenGranted)
        appendStatusLine("Microphone", describe(micStatus), granted: micStatus == .granted)
        appendStatusLine("Camera", describe(camStatus), granted: camStatus == .granted)

        let statusField = NSTextField(labelWithAttributedString: statusText)
        let statusHeight = statusField.sizeThatFits(NSSize(width: width, height: .greatestFiniteMagnitude)).height

        let explanation = NSTextField(wrappingLabelWithString: """
        Screen Recording is required for zoom, snip, and recording. Microphone and Camera are optional — used for recording your voice and webcam.

        Newly granted Screen Recording takes effect after you relaunch ZoomIt.
        """)
        explanation.font = labelFont
        explanation.textColor = .labelColor
        explanation.preferredMaxLayoutWidth = width
        let explanationHeight = explanation.sizeThatFits(NSSize(width: width, height: .greatestFiniteMagnitude)).height

        let spacing: CGFloat = 12
        let totalHeight = statusHeight + spacing + explanationHeight

        let container = NSView(frame: NSRect(x: 0, y: 0, width: width, height: totalHeight))
        explanation.frame = NSRect(x: 0, y: 0, width: width, height: explanationHeight)
        statusField.frame = NSRect(x: 0, y: explanationHeight + spacing, width: width, height: statusHeight)
        container.addSubview(explanation)
        container.addSubview(statusField)
        return container
    }

    @objc func quit() {
        hotkeyService.stop()
        NSApplication.shared.terminate(nil)
    }
}