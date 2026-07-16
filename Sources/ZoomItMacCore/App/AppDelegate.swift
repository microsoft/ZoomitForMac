import AppKit

@MainActor
public final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem?
    private var appController: AppController?

    public override init() {
        super.init()
    }

    public func applicationDidFinishLaunching(_ notification: Notification) {
        guard SingleInstance.claimOrActivateExisting() else {
            NSApplication.shared.terminate(nil)
            return
        }

        ZoomItAppIcon.apply()

        let settingsStore = UserDefaultsSettingsStore()
        let savedSettings = settingsStore.load()
        if settingsStore.hasLaunchAtLoginPreference {
            LaunchAtLogin.applySavedPreference(savedSettings.launchAtLogin)
        } else if LaunchAtLogin.isEnabledOrPending {
            var migratedSettings = savedSettings
            migratedSettings.launchAtLogin = true
            settingsStore.save(migratedSettings)
        }
        let permissionService = SystemPermissionService()
        let displayManager = SystemDisplayManager()
        let captureService = ScreenCaptureKitCaptureService(displayManager: displayManager)
        let overlayController = OverlayWindowController()
        let annotationController = AnnotationController()
        let viewportController = ZoomViewportController()

        let modeCoordinator = ModeCoordinator(
            settingsStore: settingsStore,
            permissionService: permissionService,
            displayManager: displayManager,
            captureService: captureService,
            overlayController: overlayController,
            annotationController: annotationController,
            viewportController: viewportController
        )

        let hotkeyService = HotkeyService(settingsStore: settingsStore) { command in
            Task { @MainActor in
                modeCoordinator.handle(command)
            }
        }

        // Register Control+Up/Down zoom hotkeys only while live zoom is active.
        modeCoordinator.onBeginLiveZoomNavigation = { [weak hotkeyService] in
            hotkeyService?.beginLiveZoomNavigation()
        }
        modeCoordinator.onEndLiveZoomNavigation = { [weak hotkeyService] in
            hotkeyService?.endLiveZoomNavigation()
        }

        appController = AppController(
            settingsStore: settingsStore,
            permissionService: permissionService,
            hotkeyService: hotkeyService,
            modeCoordinator: modeCoordinator
        )

        DistributedNotificationCenter.default().addObserver(
            self,
            selector: #selector(showSettingsFromOtherInstance(_:)),
            name: SingleInstance.showSettingsNotification,
            object: nil
        )

        statusItem = makeStatusItem(controller: appController!)
        modeCoordinator.onRecordingStateChanged = { [weak self] recording in
            self?.updateRecordingIndicator(recording)
        }
        hotkeyService.start()

        // On a fresh install, open Settings so the user has a clear entry point
        // instead of a silent menu-bar-only launch (issue #21). Upgrading users
        // are detected as returning by hasCompletedFirstLaunch, so they don't get
        // an unexpected pop-up. Persist the flag either way so later launches no
        // longer depend on the legacy migration sentinel.
        if !settingsStore.hasCompletedFirstLaunch {
            appController?.showSettings()
        }
        settingsStore.markFirstLaunchCompleted()
    }

    public func applicationWillTerminate(_ notification: Notification) {
        DistributedNotificationCenter.default().removeObserver(self)
        SingleInstance.release()
    }

    @objc private func showSettingsFromOtherInstance(_ notification: Notification) {
        appController?.showSettings()
    }

    /// Swaps the menu-bar icon for a red record indicator while recording.
    private func updateRecordingIndicator(_ recording: Bool) {
        guard let button = statusItem?.button else { return }
        if recording {
            let config = NSImage.SymbolConfiguration(paletteColors: [.systemRed])
            let image = NSImage(systemSymbolName: "record.circle.fill", accessibilityDescription: "Recording")?
                .withSymbolConfiguration(config)
            image?.size = NSSize(width: 18, height: 18)
            button.image = image
        } else {
            button.image = Self.menuBarIcon()
        }
    }

    private func makeStatusItem(controller: AppController) -> NSStatusItem {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        // Intentionally no autosaveName: persisting an absolute menu-bar slot makes
        // AppKit re-assert that position on every relaunch/relayout, which fights
        // menu-bar managers like Bartender and Ice (the icon snaps back out of their
        // "shown" section). Letting the system place the item keeps ZoomIt compatible
        // with those tools; users can still Command-drag it to reorder.
        // Use the Windows ZoomIt icon (document with a magnifying glass) rendered
        // as a black template image so it tints to match the menu bar, following
        // the macOS convention for menu-bar icons.
        if let button = item.button {
            if let image = Self.menuBarIcon() {
                button.image = image
            } else {
                button.title = "ZoomIt"
            }
        }

        let menu = NSMenu()
        let staticZoomItem = NSMenuItem(title: "Static Zoom", action: #selector(AppController.activateStaticZoom), keyEquivalent: "")
        menu.addItem(staticZoomItem)
        let liveZoomItem = NSMenuItem(title: "Live Zoom", action: #selector(AppController.activateLiveZoom), keyEquivalent: "")
        menu.addItem(liveZoomItem)
        let recordItem = NSMenuItem(title: "Record Screen", action: #selector(AppController.toggleRecording), keyEquivalent: "")
        menu.addItem(recordItem)
        let panoramaItem = NSMenuItem(title: "Panorama Capture", action: #selector(AppController.startPanorama), keyEquivalent: "")
        menu.addItem(panoramaItem)
        let breakItem = NSMenuItem(title: "Break Timer", action: #selector(AppController.toggleBreakTimer), keyEquivalent: "")
        menu.addItem(breakItem)
        menu.addItem(.separator())
        let settingsItem = NSMenuItem(title: "Settings…", action: #selector(AppController.showSettings), keyEquivalent: ",")
        menu.addItem(settingsItem)
        menu.addItem(NSMenuItem(title: "Check Permissions", action: #selector(AppController.checkPermissions), keyEquivalent: ""))
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit", action: #selector(AppController.quit), keyEquivalent: "q"))

        for item in menu.items {
            item.target = controller
        }

        item.menu = menu
        return item
    }

    /// Loads the bundled black template version of the Windows ZoomIt icon and
    /// sizes it for the menu bar. As a template image it is tinted by the system
    /// (black on a light menu bar, white on a dark one).
    private static func menuBarIcon() -> NSImage? {
        guard let image = loadZoomItIcon() else { return nil }
        image.size = NSSize(width: 18, height: 18)
        image.isTemplate = true
        return image
    }

    private static func loadZoomItIcon() -> NSImage? {
        ZoomItAppIcon.loadTemplateIcon()
    }
}