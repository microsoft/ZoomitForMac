import AppKit

private final class OverlayWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

@MainActor
final class OverlayWindowController {
    private var window: NSWindow?
    private weak var canvasView: ZoomCanvasView?
    private var viewportController: ZoomViewportController?
    private var zoomTimer: Timer?
    private var zoomAnimationCompletion: (() -> Void)?

    // ZoomIt's nominal telescope cadence is ZOOM_LEVEL_STEP_TIME (20ms), but on
    // Windows WM_TIMER messages are coalesced and effectively fire slower, so the
    // real animation is more deliberate. Use ~33ms (≈30fps) to match that feel
    // while keeping ZoomIt's 1.1x/0.8x per-step factors.
    private static let zoomStepInterval: TimeInterval = 1.0 / 30.0

    func show(
        frame capturedFrame: CapturedFrame,
        viewportController: ZoomViewportController,
        annotationController: AnnotationController,
        smoothImage: Bool,
        excludeFromScreenCapture: Bool = false,
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
        if excludeFromScreenCapture {
            // Live zoom captures the screen live and displays it in this overlay.
            // Marking the window as non-shareable keeps ScreenCaptureKit from
            // capturing the overlay back into itself, which would otherwise feed
            // the magnified output into the next frame and zoom in infinitely.
            window.sharingType = .none
        } else {
            // Static zoom and draw-only overlays must be visible to the recorder
            // so annotations made during screen recording are captured.
            window.sharingType = .readOnly
        }

        let canvasView = ZoomCanvasView(
            frame: CGRect(origin: .zero, size: capturedFrame.display.frame.size),
            capturedFrame: capturedFrame,
            viewportController: viewportController,
            annotationController: annotationController,
            smoothImage: smoothImage,
            commandSink: commandSink
        )
        window.contentView = canvasView
        window.makeKeyAndOrderFront(nil)
        // Activate the app so NSCursor.hide() takes effect immediately; as a
        // menu-bar accessory the app is otherwise inactive and the hidden cursor
        // would stay visible until the first click or mouse move.
        NSApp.activate(ignoringOtherApps: true)
        window.makeFirstResponder(canvasView)
        self.canvasView = canvasView
        self.window = window
        self.viewportController = viewportController
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
        canvasView.beginRegionSnip(action: action, onFinished: onFinished)
    }

    /// Captures using the last successful viewport-region snip, without showing
    /// the drag selection UI. Returns false if no previous region exists.
    func capturePreviousRegionSnip(action: SnipAction, onFinished: @escaping () -> Void) -> Bool {
        guard let canvasView else {
            onFinished()
            return false
        }
        let captured = canvasView.capturePreviousRegionSnip(action: action)
        onFinished()
        return captured
    }
    /// The overlay's window number, used to exclude it from live screen capture
    /// so the magnified overlay is never captured back into itself.
    var overlayWindowNumber: Int? { window?.windowNumber }

    /// Renders the overlay exactly as ZoomIt shows it so the recorder can encode
    /// zoom/drawing even when ScreenCaptureKit omits our own windows.
    func captureFrameForRecording(sourceRect: CGRect?) -> CGImage? {
        canvasView?.captureRecordingImage(sourceRect: sourceRect)
    }

    func requestRedraw() {
        canvasView?.needsDisplay = true
    }

    func prepareForPresentedWindow() {
        guard let window else { return }
        canvasView?.prepareForClose()
        window.level = NSWindow.Level(rawValue: NSWindow.Level.normal.rawValue - 1)
    }

    func close() {
        zoomTimer?.invalidate()
        zoomTimer = nil
        zoomAnimationCompletion = nil

        guard let window else { return }

        canvasView?.prepareForClose()
        window.orderOut(nil)
        canvasView = nil
        viewportController = nil
        self.window = nil

        // Defer the final close so the window and its content view are not
        // deallocated while still unwinding the key event that triggered exit.
        DispatchQueue.main.async {
            window.close()
        }
    }
}