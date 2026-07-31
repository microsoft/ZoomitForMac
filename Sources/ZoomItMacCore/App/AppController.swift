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

    @objc func showShortcuts() {
        presentShortcutsDialog()
    }

    /// Shows a summary of every global keyboard shortcut ZoomIt currently
    /// responds to. Values are read live from the settings store so any user
    /// customization is reflected. The list also documents the in-mode keys
    /// (colors, shapes, undo, etc.) that are handled once an overlay is active.
    private func presentShortcutsDialog() {
        let settings = settingsStore.load()

        func describe(code: Int, modifiers: UInt) -> String {
            guard code != 0 else { return "None" }
            return SettingsWindowController.describe(
                keyCode: code,
                modifiers: NSEvent.ModifierFlags(rawValue: modifiers)
            )
        }

        let zoom = describe(code: settings.hotKeyCode, modifiers: settings.hotKeyModifiers)
        let draw = describe(code: settings.drawHotKeyCode, modifiers: settings.drawHotKeyModifiers)
        let live = describe(code: settings.liveHotKeyCode, modifiers: settings.liveHotKeyModifiers)
        let snipCopy = describe(code: settings.snipHotKeyCode, modifiers: settings.snipHotKeyModifiers)
        let snipSave = describe(
            code: settings.snipHotKeyCode,
            modifiers: settings.snipHotKeyModifiers ^ NSEvent.ModifierFlags.shift.rawValue
        )
        let snipOcr = describe(code: settings.snipOcrHotKeyCode, modifiers: settings.snipOcrHotKeyModifiers)
        let record = describe(code: settings.recordHotKeyCode, modifiers: settings.recordHotKeyModifiers)
        let recordRegion = describe(
            code: settings.recordHotKeyCode,
            modifiers: settings.recordHotKeyModifiers ^ NSEvent.ModifierFlags.shift.rawValue
        )
        let demo = describe(code: settings.demoTypeHotKeyCode, modifiers: settings.demoTypeHotKeyModifiers)
        let demoReset: String = {
            guard settings.demoTypeHotKeyCode != 0 else { return "None" }
            return describe(
                code: settings.demoTypeHotKeyCode,
                modifiers: settings.demoTypeHotKeyModifiers ^ NSEvent.ModifierFlags.shift.rawValue
            )
        }()
        let panoramaCopy = describe(code: settings.panoramaHotKeyCode, modifiers: settings.panoramaHotKeyModifiers)
        let panoramaSave = describe(
            code: settings.panoramaHotKeyCode,
            modifiers: settings.panoramaHotKeyModifiers ^ NSEvent.ModifierFlags.shift.rawValue
        )
        let breakTimer = describe(code: settings.breakHotKeyCode, modifiers: settings.breakHotKeyModifiers)

        let global = """
        Global shortcuts
          Static Zoom:        \(zoom)
          Live Zoom:          \(live)
          Draw w/out Zoom:    \(draw)
          Snip → Clipboard:   \(snipCopy)
          Snip → File:        \(snipSave)
          Snip → OCR:         \(snipOcr)
          Record Screen:      \(record)
          Record Region:      \(recordRegion)
          Panorama → Clipbd:  \(panoramaCopy)
          Panorama → File:    \(panoramaSave)
          DemoType Start:     \(demo)
          DemoType Reset:     \(demoReset)
          Break Timer:        \(breakTimer)
        """

        let inMode = """
        While zoomed / drawing
          Zoom in / out:      Option+Up / Option+Down (Live Zoom)
          Draw:               Left mouse button
          Exit draw:          Right mouse button
          Undo:               Command+Z or Control+Z
          Erase all:          E
          Pen width:          Mouse wheel, [ / ], or Shift+Up/Down
          Colors:             R G B O Y P W K
          Highlighter:        Shift + color key
          Line:               Hold Shift while dragging
          Rectangle:          Hold Control while dragging
          Ellipse:            Hold Tab while dragging
          Arrow:              Hold Shift+Control while dragging
          Blank screen:       Control+W (white) / Control+K (black)
          Type text:          T (left) / Shift+T (right)
          Font size:          + / − while typing
          Exit:               Esc
        """

        let alert = NSAlert()
        alert.messageText = "ZoomIt Keyboard Shortcuts"
        alert.informativeText = "Customize global shortcuts in Settings…"
        alert.addButton(withTitle: "Done")
        alert.addButton(withTitle: "Open Settings…")
        if let icon = ZoomItAppIcon.standardIcon() {
            alert.icon = icon
        }

        // Render the shortcut tables in a monospaced font inside an accessory
        // view so the two columns line up. NSAlert's informativeText uses the
        // proportional system font, which makes space-padded columns wobble.
        let body = global + "\n\n" + inMode
        let font = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
        let attributed = NSAttributedString(
            string: body,
            attributes: [
                .font: font,
                .foregroundColor: NSColor.labelColor
            ]
        )

        let label = NSTextField(labelWithAttributedString: attributed)
        label.isSelectable = true
        label.lineBreakMode = .byClipping
        label.usesSingleLineMode = false
        label.translatesAutoresizingMaskIntoConstraints = false

        // Size the accessory view to fit the intrinsic text size so NSAlert
        // grows the whole dialog around it instead of clipping it.
        let fitting = label.sizeThatFits(NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude))
        let container = NSView(frame: NSRect(origin: .zero, size: fitting))
        container.translatesAutoresizingMaskIntoConstraints = true
        container.addSubview(label)
        label.frame = container.bounds
        label.autoresizingMask = [.width, .height]
        alert.accessoryView = container

        alert.window.animationBehavior = .none
        NSApp.activate(ignoringOtherApps: true)

        if alert.runModal() == .alertSecondButtonReturn {
            settingsWindowController.show()
        }
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
        Screen Recording: \(screenGranted ? "Granted" : "Missing")
        Microphone: \(describe(micStatus))
        Camera: \(describe(camStatus))

        Screen Recording is required for zoom, snip, and recording. Microphone and Camera are optional — used for recording your voice and webcam.

        Newly granted Screen Recording takes effect after you relaunch ZoomIt.
        """
        alert.addButton(withTitle: "Done")
        alert.addButton(withTitle: screenGranted ? "Screen Recording Settings…" : "Grant Screen Recording…")
        alert.addButton(withTitle: micStatus == .notDetermined ? "Grant Microphone…" : "Microphone Settings…")
        alert.addButton(withTitle: camStatus == .notDetermined ? "Grant Camera…" : "Camera Settings…")
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
            if screenGranted {
                permissionService.openSystemSettings()
                representWhenActive()
            } else {
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

    @objc func quit() {
        hotkeyService.stop()
        NSApplication.shared.terminate(nil)
    }
}