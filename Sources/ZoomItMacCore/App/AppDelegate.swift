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
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.title = "ZoomIt"

        let menu = NSMenu()
        let staticZoomItem = NSMenuItem(title: "Static Zoom", action: #selector(AppController.activateStaticZoom), keyEquivalent: "")
        menu.addItem(staticZoomItem)
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
}