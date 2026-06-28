import AppKit

@MainActor
public final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem?
    private var appController: AppController?

    public override init() {
        super.init()
    }

    public func applicationDidFinishLaunching(_ notification: Notification) {
        let settingsStore = UserDefaultsSettingsStore()
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

        statusItem = makeStatusItem(controller: appController!)
        hotkeyService.start()
    }

    private func makeStatusItem(controller: AppController) -> NSStatusItem {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
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
        guard let url = Bundle.module.url(forResource: "ZoomItIcon", withExtension: "png"),
              let image = NSImage(contentsOf: url) else {
            return nil
        }
        image.size = NSSize(width: 18, height: 18)
        image.isTemplate = true
        return image
    }
}