import AppKit

/// A borderless window that can still become key, so the selection view
/// receives key events (Escape) and the crosshair cursor is shown. Shared by
/// the snip and region-recording selectors.
final class SnipWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

/// Owns temporary crosshair cursor pushes for region selection. The second push
/// happens after app/window activation has had a chance to reset the cursor.
@MainActor
final class CrosshairCursorLease {
    private weak var window: NSWindow?
    private var active = false
    private var pushCount = 0

    init(window: NSWindow) {
        self.window = window
    }

    func activate() {
        active = true
        pushIfActive()
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated {
                self?.setIfActive()
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) { [weak self] in
            MainActor.assumeIsolated {
                self?.pushIfActive()
            }
        }
    }

    func invalidate() {
        active = false
        while pushCount > 0 {
            NSCursor.pop()
            pushCount -= 1
        }
    }

    private func pushIfActive() {
        guard active, window != nil else { return }
        NSCursor.crosshair.push()
        pushCount += 1
        NSCursor.crosshair.set()
    }

    private func setIfActive() {
        guard active, window != nil else { return }
        NSCursor.crosshair.set()
    }
}

/// A full-screen region selector used by the snip feature. It freezes a capture
/// of the display, dims it, and lets the user drag out a rectangle. On mouse-up
/// it reports the selected rectangle (in top-left view points); Escape cancels.
@MainActor
final class SnipSelectionView: NSView {
    private let image: CGImage
    /// Called with the selected rectangle in view points (top-left origin), or
    /// nil if the selection was cancelled or empty.
    var onComplete: ((CGRect?) -> Void)?

    private var anchorPoint: CGPoint?
    private var selectionRect: CGRect = .zero

    init(frame frameRect: CGRect, image: CGImage) {
        self.image = image
        super.init(frame: frameRect)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }

    override func resetCursorRects() {
        // Show a crosshair (plus-sign) cursor over the whole selection area.
        addCursorRect(bounds, cursor: .crosshair)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in trackingAreas {
            removeTrackingArea(area)
        }
        addTrackingArea(NSTrackingArea(
            rect: bounds,
            options: [.activeAlways, .cursorUpdate, .mouseEnteredAndExited, .inVisibleRect],
            owner: self,
            userInfo: nil
        ))
    }

    override func cursorUpdate(with event: NSEvent) {
        NSCursor.crosshair.set()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil {
            NSCursor.crosshair.set()
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }

        // Draw the frozen capture (CGImage draws bottom-up, so flip it).
        drawImage(in: context)

        // Dim the whole screen, then re-draw the selected region at full
        // brightness with a bright border, like a region screenshot tool.
        context.setFillColor(NSColor(white: 0, alpha: 0.45).cgColor)
        context.fill(bounds)

        guard selectionRect.width > 0, selectionRect.height > 0 else { return }
        context.saveGState()
        context.clip(to: selectionRect)
        drawImage(in: context)
        context.restoreGState()

        context.setStrokeColor(NSColor.white.cgColor)
        context.setLineWidth(1)
        context.stroke(selectionRect.insetBy(dx: 0.5, dy: 0.5))
    }

    private func drawImage(in context: CGContext) {
        context.saveGState()
        context.translateBy(x: 0, y: bounds.height)
        context.scaleBy(x: 1, y: -1)
        context.draw(image, in: bounds)
        context.restoreGState()
    }

    override func mouseDown(with event: NSEvent) {
        anchorPoint = convert(event.locationInWindow, from: nil)
        selectionRect = .zero
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        guard let anchor = anchorPoint else { return }
        let point = convert(event.locationInWindow, from: nil)
        selectionRect = CGRect(
            x: min(anchor.x, point.x),
            y: min(anchor.y, point.y),
            width: abs(point.x - anchor.x),
            height: abs(point.y - anchor.y)
        )
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        let rect = selectionRect
        anchorPoint = nil
        // Ignore an accidental click/tiny drag.
        onComplete?(rect.width >= 3 && rect.height >= 3 ? rect : nil)
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { // Escape cancels.
            onComplete?(nil)
        }
    }
}

/// What to do with a selected region: copy the image, save it to a file, or
/// recognize its text and copy that to the clipboard (OCR).
enum SnipAction {
    case copyImage
    case saveImage
    case recognizeText
}

/// Drives the region snip: captures the active display, shows the selection
/// overlay, and copies or saves the chosen region when the drag is released.
@MainActor
final class SnipController {
    private struct PreviousSelection {
        let displayID: CGDirectDisplayID
        let displaySize: CGSize
        let rect: CGRect

        func rectForCurrentDisplay(_ display: DisplayDescriptor) -> CGRect {
            guard displaySize.width > 0, displaySize.height > 0 else { return rect }
            if display.id == displayID {
                return rect
            }

            let widthScale = display.frame.width / displaySize.width
            let heightScale = display.frame.height / displaySize.height
            return CGRect(
                x: rect.minX * widthScale,
                y: rect.minY * heightScale,
                width: rect.width * widthScale,
                height: rect.height * heightScale
            )
        }
    }

    private let captureService: ScreenCaptureService
    private let displayManager: DisplayManager
    private let permissionService: PermissionService
    private let settingsStore: SettingsStore

    private var window: NSWindow?
    private var capturedFrame: CapturedFrame?
    private var action: SnipAction = .copyImage
    private var onFinished: (() -> Void)?
    private var cursorLease: CrosshairCursorLease?
    private var previousSelection: PreviousSelection?

    init(
        captureService: ScreenCaptureService,
        displayManager: DisplayManager,
        permissionService: PermissionService,
        settingsStore: SettingsStore
    ) {
        self.captureService = captureService
        self.displayManager = displayManager
        self.permissionService = permissionService
        self.settingsStore = settingsStore
    }

    /// Begins a region selection. `action` chooses what to do with the selected
    /// region: copy the image, save it to a file, or OCR it to the clipboard.
    /// When `frame` is supplied (e.g. a snapshot of the zoomed viewport) it is
    /// selected directly; otherwise the active display is captured.
    /// `onFinished` is always called once, when the selection completes or is
    /// cancelled.
    func begin(action: SnipAction, frame providedFrame: CapturedFrame? = nil, onFinished: @escaping () -> Void) {
        self.action = action
        self.onFinished = onFinished

        if let providedFrame {
            show(frame: providedFrame)
            return
        }

        guard ScreenRecordingPrompt.ensureGranted(permissionService) else {
            finish()
            return
        }
        guard let display = displayManager.activeDisplay() else {
            NSSound.beep()
            finish()
            return
        }

        Task { @MainActor in
            do {
                let frame = try await captureService.captureDisplay(display)
                self.show(frame: frame)
            } catch {
                NSSound.beep()
                self.finish()
            }
        }
    }

    /// Repeats the last successful region snip with no selection UI.
    /// Returns false if there is no previous region to reuse.
    @discardableResult
    func capturePrevious(action: SnipAction, onFinished: @escaping () -> Void) -> Bool {
        guard let previousSelection else {
            return false
        }

        self.action = action
        self.onFinished = onFinished

        guard ScreenRecordingPrompt.ensureGranted(permissionService) else {
            finish()
            return true
        }
        guard let display = displayManager.activeDisplay() else {
            NSSound.beep()
            finish()
            return true
        }

        Task { @MainActor in
            do {
                let frame = try await captureService.captureDisplay(display)
                let rect = previousSelection.rectForCurrentDisplay(frame.display)
                _ = self.handleSelection(rect, in: frame)
                self.finish()
            } catch {
                NSSound.beep()
                self.finish()
            }
        }
        return true
    }

    private func show(frame: CapturedFrame) {
        capturedFrame = frame

        let window = SnipWindow(
            contentRect: frame.display.frame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.level = .screenSaver
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        window.backgroundColor = .clear
        window.isOpaque = false
        window.isReleasedWhenClosed = false

        let view = SnipSelectionView(
            frame: CGRect(origin: .zero, size: frame.display.frame.size),
            image: frame.image
        )
        view.onComplete = { [weak self] rect in
            self?.handleSelection(rect)
        }
        window.contentView = view
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        window.makeFirstResponder(view)
        let cursorLease = CrosshairCursorLease(window: window)
        cursorLease.activate()
        self.cursorLease = cursorLease
        self.window = window
    }

    private func handleSelection(_ rect: CGRect?) {
        let frame = capturedFrame
        // Tear down the overlay first so a Save dialog isn't hidden behind it.
        closeWindow()

        guard let rect, let frame else {
            finish()
            return
        }

        _ = handleSelection(rect, in: frame)
        finish()
    }

    @discardableResult
    private func handleSelection(_ rect: CGRect, in frame: CapturedFrame) -> Bool {
        guard rect.width >= 3, rect.height >= 3 else {
            return false
        }

        let boundedRect = rect.intersection(CGRect(origin: .zero, size: frame.display.frame.size))
        guard boundedRect.width >= 3, boundedRect.height >= 3 else {
            return false
        }

        let scale = frame.display.scaleFactor
        let pixelRect = CGRect(
            x: boundedRect.minX * scale,
            y: boundedRect.minY * scale,
            width: boundedRect.width * scale,
            height: boundedRect.height * scale
        ).integral

        guard let cropped = frame.image.cropping(to: pixelRect) else {
            return false
        }

        previousSelection = PreviousSelection(
            displayID: frame.display.id,
            displaySize: frame.display.frame.size,
            rect: boundedRect
        )

        switch action {
        case .saveImage:
            ImageExporter.saveImage(cropped, settings: settingsStore.load())
        case .copyImage:
            ImageExporter.copyToPasteboard(cropped)
        case .recognizeText:
            OcrService.recognizeAndCopy(cropped)
        }
        return true
    }

    private func closeWindow() {
        cursorLease?.invalidate()
        cursorLease = nil
        window?.orderOut(nil)
        window = nil
    }

    private func finish() {
        capturedFrame = nil
        let callback = onFinished
        onFinished = nil
        callback?()
    }
}
