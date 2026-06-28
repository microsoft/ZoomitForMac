import AppKit

private final class OverlayWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

@MainActor
final class OverlayWindowController {
    private var window: NSWindow?
    private weak var canvasView: ZoomCanvasView?

    func show(
        frame capturedFrame: CapturedFrame,
        viewportController: ZoomViewportController,
        annotationController: AnnotationController,
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

        let canvasView = ZoomCanvasView(
            frame: CGRect(origin: .zero, size: capturedFrame.display.frame.size),
            capturedFrame: capturedFrame,
            viewportController: viewportController,
            annotationController: annotationController,
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
    }

    func updateInteractionMode(_ mode: AppMode) {
        canvasView?.interactionMode = mode
        requestRedraw()
    }

    func requestRedraw() {
        canvasView?.needsDisplay = true
    }

    func close() {
        guard let window else { return }

        canvasView?.prepareForClose()
        window.orderOut(nil)
        canvasView = nil
        self.window = nil

        // Defer the final close so the window and its content view are not
        // deallocated while still unwinding the key event that triggered exit.
        DispatchQueue.main.async {
            window.close()
        }
    }
}