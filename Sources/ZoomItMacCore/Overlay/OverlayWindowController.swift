import AppKit

private final class OverlayWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

enum OverlayWindowSharingContext {
    case standardWindow
    case staticOverlay
    case liveOverlay
}

enum OverlayWindowSharingPolicy {
    static func sharingType(
        for context: OverlayWindowSharingContext
    ) -> NSWindow.SharingType {
        switch context {
        case .standardWindow:
            .readWrite
        case .staticOverlay, .liveOverlay:
            .readOnly
        }
    }

    static func isVisibleToExternalCapture(
        context: OverlayWindowSharingContext
    ) -> Bool {
        sharingType(for: context) != .none
    }
}

@MainActor
final class OverlayWindowController {
    private let userSelectedResourceAccess: UserSelectedResourceAccess
    private var window: NSWindow?
    private weak var canvasView: ZoomCanvasView?
    private weak var annotationController: AnnotationController?
    private var drawingToolbarController: DrawingToolbarController?
    private var isDrawingAccessoryActive = false
    private var drawingSurfaceInteractionState = DrawingAccessoryInteractionState()
    private var drawingAccessorySuppressions = DrawingAccessorySuppressionLifecycle()
    private var canvasModalSuppression: DrawingAccessorySuppressionToken?
    private var viewportController: ZoomViewportController?
    private var overlayDisplayID: CGDirectDisplayID?
    private var zoomTimer: Timer?
    private var zoomAnimationCompletion: (() -> Void)?

    // ZoomIt's nominal telescope cadence is ZOOM_LEVEL_STEP_TIME (20ms), but on
    // Windows WM_TIMER messages are coalesced and effectively fire slower, so the
    // real animation is more deliberate. Use ~33ms (≈30fps) to match that feel
    // while keeping ZoomIt's 1.1x/0.8x per-step factors.
    private static let zoomStepInterval: TimeInterval = 1.0 / 30.0

    init(userSelectedResourceAccess: UserSelectedResourceAccess) {
        self.userSelectedResourceAccess = userSelectedResourceAccess
    }

    func show(
        frame capturedFrame: CapturedFrame,
        viewportController: ZoomViewportController,
        annotationController: AnnotationController,
        smoothImage: Bool,
        excludeFromScreenCapture: Bool = false,
        drawingToolbarNormalizedPosition: CGPoint?,
        drawingToolbarPlacementDidChange: @escaping (CGPoint) -> Void,
        commandSink: @escaping (AppCommand) -> Void
    ) {
        close()

        let window = OverlayWindow(
            contentRect: capturedFrame.display.frame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.level = .screenSaver
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        window.backgroundColor = .black
        window.isOpaque = true
        window.acceptsMouseMovedEvents = true
        window.isReleasedWhenClosed = false
        let sharingContext: OverlayWindowSharingContext =
            excludeFromScreenCapture ? .liveOverlay : .staticOverlay
        // Live capture excludes the whole ZoomIt process, so the overlay can
        // remain externally shareable without feeding back into its own stream.
        window.sharingType = OverlayWindowSharingPolicy.sharingType(
            for: sharingContext
        )

        let canvasView = ZoomCanvasView(
            frame: CGRect(origin: .zero, size: capturedFrame.display.frame.size),
            capturedFrame: capturedFrame,
            viewportController: viewportController,
            annotationController: annotationController,
            smoothImage: smoothImage,
            userSelectedResourceAccess: userSelectedResourceAccess,
            commandSink: commandSink,
            drawingModeDidChange: { [weak self] isDrawing in
                self?.setDrawingModeActive(isDrawing)
            },
            transientToolDidChange: { [weak self] tool in
                self?.drawingToolbarController?.setTransientTool(tool)
            },
            modalPresentationDidChange: { [weak self] isPresenting in
                self?.setToolbarSuppressed(isPresenting)
            },
            captureCompositor: { [weak self] baseImage, displayFrame, sourceRegion, outputPixelSize in
                self?.composeDrawingAccessories(
                    over: baseImage,
                    displayFrame: displayFrame,
                    sourceRegion: sourceRegion,
                    outputPixelSize: outputPixelSize
                ) ?? CaptureAccessoryCompositor.compose(
                    baseImage: baseImage,
                    displayFrame: displayFrame,
                    sourceRegion: sourceRegion,
                    outputPixelSize: outputPixelSize,
                    accessories: []
                )
            }
        )
        window.contentView = canvasView
        window.makeKeyAndOrderFront(nil)
        // Activate the app so NSCursor.hide() takes effect immediately; as a
        // menu-bar accessory the app is otherwise inactive and the hidden cursor
        // would stay visible until the first click or mouse move.
        NSApp.activate(ignoringOtherApps: true)
        window.makeFirstResponder(canvasView)
        self.canvasView = canvasView
        self.annotationController = annotationController
        self.window = window
        self.viewportController = viewportController
        overlayDisplayID = capturedFrame.display.id

        drawingToolbarController = DrawingToolbarController(
            parentWindow: window,
            annotationController: annotationController,
            toolbarNormalizedPosition: drawingToolbarNormalizedPosition,
            commandSink: commandSink,
            restoreCanvasFocus: { [weak self] in
                guard let self,
                      let window = self.window,
                      let canvasView = self.canvasView else {
                    return
                }
                window.makeFirstResponder(canvasView)
                canvasView.restoreFocusAfterDrawingAccessoryAction()
            },
            toolbarPlacementDidChange: drawingToolbarPlacementDidChange,
            pointerInteractionChanged: { [weak self, weak canvasView] interactionState in
                self?.setDrawingSurfaceInteractionState(interactionState)
                canvasView?.setDrawingAccessoryInteractionActive(interactionState.isActive)
            }
        )
        annotationController.onStateChanged = { [weak self, weak annotationController] in
            guard let self, let annotationController else { return }
            self.canvasView?.annotationStateDidChange()
            self.drawingToolbarController?.updateState(
                DrawingToolbarState(annotationController: annotationController)
            )
            self.requestRedraw()
        }
    }

    /// Drives the viewport's telescope zoom animation, redrawing each step, and
    /// invokes `completion` once the target zoom is reached.
    func runZoomAnimation(completion: (() -> Void)? = nil) {
        zoomTimer?.invalidate()
        zoomTimer = nil

        guard let viewportController, viewportController.isAnimatingZoom else {
            completion?()
            return
        }

        zoomAnimationCompletion = completion
        let timer = Timer(timeInterval: Self.zoomStepInterval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.handleZoomTick()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        zoomTimer = timer
    }

    private func handleZoomTick() {
        guard let viewportController else {
            zoomTimer?.invalidate()
            zoomTimer = nil
            return
        }

        let continuing = viewportController.advanceZoomAnimation()
        canvasView?.needsDisplay = true
        if !continuing {
            zoomTimer?.invalidate()
            zoomTimer = nil
            let completion = zoomAnimationCompletion
            zoomAnimationCompletion = nil
            completion?()
        }
    }

    func updateInteractionMode(_ mode: AppMode) {
        canvasView?.interactionMode = mode
        requestRedraw()
    }

    func typingInsertionPointForCurrentPointer() -> CGPoint? {
        canvasView?.typingInsertionPointForCurrentPointer()
    }

    /// Pushes a freshly captured live frame to the canvas during live zoom.
    func updateLiveImage(_ image: CGImage) {
        canvasView?.updateLiveImage(image)
    }

    /// Toggles drawing mode on the overlay (used by the draw hotkey while live
    /// zoomed): arms drawing if idle, or leaves it if already drawing.
    func toggleDrawingMode() {
        canvasView?.toggleDrawingMode()
    }
    /// Begins a region snip on the current viewport (used when the snip hotkey is
    /// pressed while already zoomed). `onFinished` is called when it ends.
    func beginRegionSnip(action: SnipAction, onFinished: @escaping () -> Void) {
        guard let canvasView else {
            onFinished()
            return
        }
        let suppression = suppressDrawingAccessories()
        canvasView.beginRegionSnip(action: action) { [weak self] in
            self?.finishDrawingAccessorySuppression(
                suppression,
                restoreIfOverlayActive: true
            )
            onFinished()
        }
    }
    /// The overlay's window number, used to exclude it from live screen capture
    /// so the magnified overlay is never captured back into itself.
    var overlayWindowNumber: Int? { window?.windowNumber }

    var isOverlayPresented: Bool {
        window != nil
    }

    var drawingAccessoryWindowNumbers: [Int] {
        drawingToolbarController?.windowNumbers ?? []
    }

    var canvasViewForTesting: ZoomCanvasView? {
        canvasView
    }

    var drawingToolbarIsVisibleForTesting: Bool {
        drawingToolbarController?.toolbarIsVisibleForTesting == true
    }

    var drawingInspectorIsVisibleForTesting: Bool {
        drawingToolbarController?.inspectorIsVisibleForTesting == true
    }

    func suppressDrawingAccessories() -> DrawingAccessorySuppressionToken {
        let token = drawingAccessorySuppressions.begin()
        updateDrawingToolbarVisibility()
        return token
    }

    func finishDrawingAccessorySuppression(
        _ token: DrawingAccessorySuppressionToken,
        restoreIfOverlayActive: Bool
    ) {
        guard drawingAccessorySuppressions.finish(token) else { return }
        if restoreIfOverlayActive && window != nil {
            updateDrawingToolbarVisibility()
        }
    }

    /// Renders the overlay exactly as ZoomIt shows it so the recorder can encode
    /// zoom/drawing even when ScreenCaptureKit omits our own windows.
    func captureFrameForRecording(
        displayID: CGDirectDisplayID,
        sourceRect: CGRect?,
        outputPixelSize: CGSize
    ) -> CGImage? {
        guard overlayDisplayID == displayID else { return nil }
        return canvasView?.captureRecordingImage(
            sourceRect: sourceRect,
            outputPixelSize: outputPixelSize
        )
    }

    func requestRedraw() {
        canvasView?.needsDisplay = true
    }

    func annotationContentOffset(forDestinationOffset offset: CGPoint) -> CGPoint {
        canvasView?.annotationContentOffset(forDestinationOffset: offset) ?? offset
    }

    func prepareForPresentedWindow() {
        guard let window else { return }
        setToolbarSuppressed(true)
        canvasView?.prepareForClose()
        window.level = NSWindow.Level(rawValue: NSWindow.Level.normal.rawValue - 1)
    }

    func close() {
        zoomTimer?.invalidate()
        zoomTimer = nil
        zoomAnimationCompletion = nil

        guard let window else { return }

        isDrawingAccessoryActive = false
        drawingSurfaceInteractionState = DrawingAccessoryInteractionState()
        canvasModalSuppression = nil
        drawingAccessorySuppressions.reset()
        drawingToolbarController?.close()
        drawingToolbarController = nil
        canvasView?.prepareForClose()
        annotationController?.onStateChanged = nil
        window.orderOut(nil)
        canvasView = nil
        annotationController = nil
        viewportController = nil
        overlayDisplayID = nil
        self.window = nil

        // Defer the final close so the window and its content view are not
        // deallocated while still unwinding the key event that triggered exit.
        DispatchQueue.main.async {
            window.close()
        }
    }

    private func setDrawingModeActive(_ isActive: Bool) {
        isDrawingAccessoryActive = isActive
        if !isActive {
            drawingToolbarController?.hide()
        }
        updateDrawingToolbarVisibility()
    }

    private func setToolbarSuppressed(_ isSuppressed: Bool) {
        if isSuppressed {
            guard canvasModalSuppression == nil else { return }
            canvasModalSuppression = suppressDrawingAccessories()
        } else if let suppression = canvasModalSuppression {
            canvasModalSuppression = nil
            finishDrawingAccessorySuppression(
                suppression,
                restoreIfOverlayActive: true
            )
        }
    }

    private func setDrawingSurfaceInteractionState(
        _ interactionState: DrawingAccessoryInteractionState
    ) {
        drawingSurfaceInteractionState = interactionState
        updateDrawingToolbarVisibility()
    }

    private func updateDrawingToolbarVisibility() {
        let shouldShow = DrawingToolbarLifecycle.shouldShow(
            isOverlayPresented: window != nil && !drawingAccessorySuppressions.isSuppressed,
            isDrawingAccessoryActive: isDrawingAccessoryActive,
            interactionState: drawingSurfaceInteractionState
        )
        if shouldShow {
            drawingToolbarController?.show()
        } else {
            drawingToolbarController?.hide()
        }
    }

    private func composeDrawingAccessories(
        over baseImage: CGImage,
        displayFrame: CGRect,
        sourceRegion: CGRect,
        outputPixelSize: CGSize
    ) -> CGImage? {
        let scaleX = outputPixelSize.width / sourceRegion.width
        let scaleY = outputPixelSize.height / sourceRegion.height
        let snapshots = drawingToolbarController?.captureAccessorySnapshots(
            scaleX: scaleX,
            scaleY: scaleY
        ) ?? []
        return CaptureAccessoryCompositor.compose(
            baseImage: baseImage,
            displayFrame: displayFrame,
            sourceRegion: sourceRegion,
            outputPixelSize: outputPixelSize,
            accessories: snapshots
        )
    }
}