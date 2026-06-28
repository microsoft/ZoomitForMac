import AppKit

@MainActor
final class ModeCoordinator {
    private let settingsStore: SettingsStore
    private let permissionService: PermissionService
    private let displayManager: DisplayManager
    private let captureService: ScreenCaptureService
    private let overlayController: OverlayWindowController
    private let annotationController: AnnotationController
    private let viewportController: ZoomViewportController

    private(set) var mode: AppMode = .idle

    init(
        settingsStore: SettingsStore,
        permissionService: PermissionService,
        displayManager: DisplayManager,
        captureService: ScreenCaptureService,
        overlayController: OverlayWindowController,
        annotationController: AnnotationController,
        viewportController: ZoomViewportController
    ) {
        self.settingsStore = settingsStore
        self.permissionService = permissionService
        self.displayManager = displayManager
        self.captureService = captureService
        self.overlayController = overlayController
        self.annotationController = annotationController
        self.viewportController = viewportController
    }

    func handle(_ command: AppCommand) {
        switch command {
        case .activateStaticZoom:
            activateStaticZoom()
        case .zoomIn:
            zoomIn()
        case .zoomOutOrExit:
            zoomOutOrExit()
        case .exit:
            exitActiveMode()
        case .undo:
            annotationController.undo()
            overlayController.requestRedraw()
        case .clear:
            annotationController.clear()
            overlayController.requestRedraw()
        case .setTool(let tool):
            annotationController.currentTool = tool
        case .setColor(let color):
            annotationController.currentStyle.color = color
        case .increasePenWidth:
            annotationController.currentStyle.rootWidth += 1
        case .decreasePenWidth:
            annotationController.currentStyle.rootWidth = max(1, annotationController.currentStyle.rootWidth - 1)
        case .toggleTyping:
            mode = mode == .typing ? .staticZoom : .typing
            overlayController.updateInteractionMode(mode)
        case .activateLiveZoom, .captureStill, .startPanorama, .toggleRecording:
            NSSound.beep()
        }
    }

    private func activateStaticZoom() {
        guard mode == .idle else {
            exitActiveMode()
            return
        }

        let permissions = permissionService.currentState()
        guard permissions.screenCapture.isGranted else {
            permissionService.requestScreenCaptureAccess()
            return
        }

        guard let display = displayManager.activeDisplay() else {
            NSSound.beep()
            return
        }

        Task { @MainActor in
            do {
                let frame = try await captureService.captureDisplay(display)
                let settings = settingsStore.load()
                viewportController.configure(for: frame, initialZoom: settings.defaultZoomFactor)
                annotationController.reset()
                overlayController.show(
                    frame: frame,
                    viewportController: viewportController,
                    annotationController: annotationController,
                    commandSink: { [weak self] command in self?.handle(command) }
                )
                mode = .staticZoom
            } catch {
                presentError(error)
            }
        }
    }

    private func zoomIn() {
        guard mode == .staticZoom || mode == .typing else { return }

        let settings = settingsStore.load()
        viewportController.setZoomFactor(min(settings.maximumZoomFactor, viewportController.zoomFactor + 1))
        overlayController.requestRedraw()
    }

    private func zoomOutOrExit() {
        guard mode == .staticZoom || mode == .typing else { return }

        let settings = settingsStore.load()
        guard viewportController.zoomFactor > settings.defaultZoomFactor else {
            exitActiveMode()
            return
        }

        viewportController.setZoomFactor(max(settings.defaultZoomFactor, viewportController.zoomFactor - 1))
        overlayController.requestRedraw()
    }

    private func exitActiveMode() {
        overlayController.close()
        annotationController.reset()
        mode = .idle
    }

    private func presentError(_ error: Error) {
        let alert = NSAlert(error: error)
        alert.runModal()
    }
}