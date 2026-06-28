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
    private var isExiting = false
    /// The mode to restore when leaving typing mode (zoom vs. draw-without-zoom).
    private var modeBeforeTyping: AppMode = .staticZoom

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
        case .activateDrawWithoutZoom:
            activateDrawWithoutZoom()
        case .zoomIn:
            zoomIn()
        case .zoomOutOrExit:
            zoomOutOrExit()
        case .exit:
            animateExit()
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
        case .toggleTyping(let rightAligned):
            if mode == .typing {
                mode = modeBeforeTyping
            } else {
                modeBeforeTyping = mode
                mode = .typing
                annotationController.beginTypingSession(rightAligned: rightAligned)
            }
            overlayController.updateInteractionMode(mode)
            overlayController.requestRedraw()
        case .increaseFontSize:
            annotationController.increaseFontSize()
            overlayController.requestRedraw()
        case .decreaseFontSize:
            annotationController.decreaseFontSize()
            overlayController.requestRedraw()
        case .activateLiveZoom, .captureStill, .startPanorama, .toggleRecording:
            NSSound.beep()
        }
    }

    private func activateStaticZoom() {
        guard mode == .idle else {
            animateExit()
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
                // Apply persisted drawing/typing defaults from the settings dialog.
                annotationController.currentStyle.rootWidth = settings.rootPenWidth
                annotationController.typingFontName = settings.typingFontName
                annotationController.typingFontSize = settings.typingFontSize
                if settings.animateZoom {
                    // Start fully zoomed out so the overlay telescopes in to the
                    // target zoom, matching Windows ZoomIt.
                    viewportController.beginZoomInAnimation()
                }
                overlayController.show(
                    frame: frame,
                    viewportController: viewportController,
                    annotationController: annotationController,
                    smoothImage: settings.smoothImage,
                    commandSink: { [weak self] command in self?.handle(command) }
                )
                mode = .staticZoom
                if settings.animateZoom {
                    overlayController.runZoomAnimation()
                }
            } catch {
                presentError(error)
            }
        }
    }

    private func activateDrawWithoutZoom() {
        guard mode == .idle else {
            animateExit()
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
                // Draw-without-zoom freezes the screen at 1x and goes straight
                // into drawing mode; there is no magnification or animation.
                viewportController.configure(for: frame, initialZoom: 1)
                annotationController.reset()
                annotationController.currentStyle.rootWidth = settings.rootPenWidth
                annotationController.typingFontName = settings.typingFontName
                annotationController.typingFontSize = settings.typingFontSize
                overlayController.show(
                    frame: frame,
                    viewportController: viewportController,
                    annotationController: annotationController,
                    smoothImage: settings.smoothImage,
                    commandSink: { [weak self] command in self?.handle(command) }
                )
                mode = .drawOnly
                // Arm drawing mode immediately so the first click starts a stroke.
                overlayController.updateInteractionMode(.drawOnly)
            } catch {
                presentError(error)
            }
        }
    }

    private func zoomIn() {
        guard mode == .staticZoom || mode == .typing, !isExiting else { return }

        let settings = settingsStore.load()
        let current = viewportController.targetZoomFactor
        guard current < settings.maximumZoomFactor else { return }

        // ZoomIt's mouse-wheel zoom-in steps: snap to 2x, then keep doubling.
        let target = current < 2 ? 2 : min(settings.maximumZoomFactor, current * 2)
        applyZoom(to: target, animate: settings.animateZoom)
    }

    private func zoomOutOrExit() {
        guard mode == .staticZoom || mode == .typing, !isExiting else { return }

        let settings = settingsStore.load()
        let current = viewportController.targetZoomFactor
        // At 1x there is nothing left to zoom out of, so exit the overlay.
        guard current > settings.minimumZoomFactor else {
            animateExit()
            return
        }

        // ZoomIt's zoom-out steps: halve while above 2x, then ease out by 0.75
        // down to the 1x minimum.
        let target = current <= 2
            ? max(settings.minimumZoomFactor, current * 0.75)
            : current / 2
        applyZoom(to: target, animate: settings.animateZoom)
    }

    private func applyZoom(to target: CGFloat, animate: Bool) {
        if animate {
            viewportController.animateZoom(to: target)
            overlayController.runZoomAnimation()
        } else {
            viewportController.setZoomFactor(target)
            overlayController.requestRedraw()
        }
    }

    private func animateExit() {
        guard mode != .idle, !isExiting else { return }
        isExiting = true
        // Telescope back out to 1x before tearing down the overlay.
        viewportController.animateZoom(to: 1)
        overlayController.runZoomAnimation { [weak self] in
            self?.exitActiveMode()
        }
    }

    private func exitActiveMode() {
        overlayController.close()
        annotationController.reset()
        mode = .idle
        isExiting = false
    }

    private func presentError(_ error: Error) {
        let alert = NSAlert(error: error)
        alert.runModal()
    }
}