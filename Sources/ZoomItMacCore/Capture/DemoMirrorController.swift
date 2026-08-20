import AppKit
@preconcurrency import ScreenCaptureKit

/// Draws a bright green border around the source window being mirrored, on
/// the source display, matching Windows ZoomIt's DemoMirror border color. It
/// lives in a click-through, non-shareable window so it never appears in the
/// mirrored content itself.
@MainActor
private final class DemoMirrorBorderView: NSView {
    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        let lineWidth: CGFloat = 4
        let rect = bounds.insetBy(dx: lineWidth / 2, dy: lineWidth / 2)
        context.setStrokeColor(NSColor(red: 0, green: 1, blue: 0, alpha: 1).cgColor)
        context.setLineWidth(lineWidth)
        context.stroke(rect)
    }
}

/// A flipped container so a border view lines up with the top-left origin
/// rectangle it is given.
@MainActor
private final class FlippedContainerView: NSView {
    override var isFlipped: Bool { true }
}

/// Displays the live mirrored image, letterboxed within the mirror window.
@MainActor
private final class DemoMirrorImageView: NSView {
    // A flipped (top-left origin) view, matching ZoomCanvasView/SnipSelectionView:
    // CGImage always draws with row 0 at the bottom of the current graphics
    // context's coordinate space, so without both the flip below *and* this
    // `isFlipped` override the image renders upside down.
    override var isFlipped: Bool { true }

    var image: CGImage? {
        didSet { needsDisplay = true }
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext, let image else { return }
        context.saveGState()
        context.translateBy(x: 0, y: bounds.height)
        context.scaleBy(x: 1, y: -1)
        context.draw(image, in: bounds)
        context.restoreGState()
    }
}

/// A CGImage that is safe to hand across concurrency domains, matching
/// LiveCaptureSession's SendableCGImage.
private struct DemoMirrorSendableImage: @unchecked Sendable {
    let image: CGImage
}

/// Forwards ScreenCaptureKit frames from the mirrored source to the main actor.
private final class DemoMirrorStreamOutput: NSObject, SCStreamOutput, @unchecked Sendable {
    private let ciContext = CIContext(options: [.useSoftwareRenderer: false])
    let frameHandler: @MainActor (CGImage) -> Void

    init(frameHandler: @escaping @MainActor (CGImage) -> Void) {
        self.frameHandler = frameHandler
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen, sampleBuffer.isValid, let pixelBuffer = sampleBuffer.imageBuffer else { return }
        let ciImage = CIImage(cvPixelBuffer: pixelBuffer)
        guard let cgImage = ciContext.createCGImage(ciImage, from: ciImage.extent) else { return }
        let boxed = DemoMirrorSendableImage(image: cgImage)
        let handler = frameHandler
        Task { @MainActor in
            handler(boxed.image)
        }
    }
}

/// Drives DemoMirror: mirrors the entire screen, a selected region, or the
/// window under the cursor (including the mouse pointer) onto a second
/// display, matching Windows ZoomIt's DemoMirror feature (Ctrl+9, Shift for a
/// region, Option for a window). Lets a presenter show a demo app on the
/// presentation display, on top of a slide show, without leaving the current
/// view. Enter the hotkey again (any of the three variants) to stop.
@MainActor
final class DemoMirrorController {
    private let displayManager: DisplayManager
    private let permissionService: PermissionService
    private let settingsStore: SettingsStore

    /// True once mirroring is on screen (streaming to the target display).
    private(set) var isActive = false
    /// True while a region drag-selection is in progress (before mirroring
    /// actually starts), so a second hotkey press cancels it.
    private var isSelecting = false

    private var stream: SCStream?
    private var streamOutput: DemoMirrorStreamOutput?
    private let sampleQueue = DispatchQueue(label: "com.zoomitmac.demomirror")

    private var backdropWindow: NSWindow?
    private var mirrorWindow: NSWindow?
    private var mirrorImageView: DemoMirrorImageView?
    private var borderWindow: NSWindow?
    private var selectionWindow: NSWindow?
    private var cursorLease: CrosshairCursorLease?

    private var sourceDisplay: DisplayDescriptor?
    private var targetDisplay: DisplayDescriptor?
    /// The window being mirrored, if any (nil for screen/region mirroring).
    private var trackedWindowID: CGWindowID?
    /// Re-checks a tracked window's position/existence periodically, matching
    /// Windows ZoomIt's window-tracking + topmost-reclaim timer.
    private var trackingTimer: Timer?
    /// Watches for displays being connected/disconnected so mirroring can stop
    /// if the target display goes away.
    private var screenParametersObserver: NSObjectProtocol?

    init(
        displayManager: DisplayManager,
        permissionService: PermissionService,
        settingsStore: SettingsStore
    ) {
        self.displayManager = displayManager
        self.permissionService = permissionService
        self.settingsStore = settingsStore
    }

    /// Toggles DemoMirror. If mirroring is active, or a region selection is in
    /// progress, any of the three hotkey variants stops it (matching "enter the
    /// hotkey again to stop mirroring"). Otherwise begins mirroring per `scope`.
    func toggle(scope: DemoMirrorScope) {
        if isActive || isSelecting {
            stop()
            return
        }

        guard ScreenRecordingPrompt.ensureGranted(permissionService) else { return }

        let displays = displayManager.displays()
        guard let source = displayManager.activeDisplay() else {
            NSSound.beep()
            return
        }
        guard let target = displays.first(where: { $0.id != source.id }) else {
            presentAlert("Screen mirroring requires a second display.")
            return
        }

        sourceDisplay = source
        targetDisplay = target

        switch scope {
        case .screen:
            Task { await beginMirroring(source: source, target: target, region: nil, window: nil) }
        case .region:
            beginRegionSelection(source: source, target: target)
        case .window:
            Task { await beginWindowSelection(source: source, target: target) }
        }
    }

    func stop() {
        isSelecting = false
        isActive = false
        trackingTimer?.invalidate()
        trackingTimer = nil
        trackedWindowID = nil
        sourceDisplay = nil
        targetDisplay = nil

        if let screenParametersObserver {
            NotificationCenter.default.removeObserver(screenParametersObserver)
            self.screenParametersObserver = nil
        }

        cursorLease?.invalidate()
        cursorLease = nil
        selectionWindow?.orderOut(nil)
        selectionWindow = nil
        borderWindow?.orderOut(nil)
        borderWindow = nil
        mirrorWindow?.orderOut(nil)
        mirrorWindow = nil
        mirrorImageView = nil
        backdropWindow?.orderOut(nil)
        backdropWindow = nil

        let activeStream = stream
        stream = nil
        streamOutput = nil
        if let activeStream {
            Task { try? await activeStream.stopCapture() }
        }
    }

    // MARK: - Region selection (Shift variant)

    private func beginRegionSelection(source: DisplayDescriptor, target: DisplayDescriptor) {
        isSelecting = true
        Task { @MainActor in
            guard let content = try? await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true),
                  let scDisplay = content.displays.first(where: { $0.displayID == source.id }) else {
                isSelecting = false
                return
            }
            let filter = SCContentFilter(display: scDisplay, excludingWindows: [])
            let configuration = SCStreamConfiguration()
            let scale = source.scaleFactor
            configuration.width = Int(source.frame.width * scale)
            configuration.height = Int(source.frame.height * scale)
            configuration.showsCursor = false
            guard let image = try? await SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration) else {
                isSelecting = false
                return
            }
            showRegionSelector(image: image, source: source, target: target)
        }
    }

    private func showRegionSelector(image: CGImage, source: DisplayDescriptor, target: DisplayDescriptor) {
        let window = SnipWindow(
            contentRect: source.frame,
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
            frame: CGRect(origin: .zero, size: source.frame.size),
            image: image,
            borderColor: NSColor(red: 0, green: 1, blue: 0, alpha: 1)
        )
        view.onComplete = { [weak self] rect in
            self?.finishRegionSelection(rect, source: source, target: target)
        }
        window.contentView = view
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        window.makeFirstResponder(view)
        let lease = CrosshairCursorLease(window: window)
        lease.activate()
        cursorLease = lease
        selectionWindow = window
    }

    private func finishRegionSelection(_ rect: CGRect?, source: DisplayDescriptor, target: DisplayDescriptor) {
        cursorLease?.invalidate()
        cursorLease = nil
        selectionWindow?.orderOut(nil)
        selectionWindow = nil
        isSelecting = false

        guard let rect else { return }
        Task { await beginMirroring(source: source, target: target, region: rect, window: nil) }
    }

    // MARK: - Window selection (Option variant)

    private func beginWindowSelection(source: DisplayDescriptor, target: DisplayDescriptor) async {
        guard let window = await windowUnderCursor() else {
            NSSound.beep()
            return
        }
        trackedWindowID = window.windowID
        await beginMirroring(source: source, target: target, region: nil, window: window)
    }

    /// Finds the frontmost on-screen window (excluding ZoomIt's own windows and
    /// the desktop) under the current mouse location.
    private func windowUnderCursor() async -> SCWindow? {
        guard let content = try? await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true) else {
            return nil
        }
        let cursor = Self.quartzGlobalPoint(fromAppKitGlobal: NSEvent.mouseLocation)
        let ownProcessID = ProcessInfo.processInfo.processIdentifier
        return content.windows.first { window in
            window.owningApplication?.processID != ownProcessID &&
                window.frame.width > 20 && window.frame.height > 20 &&
                window.frame.contains(cursor)
        }
    }

    private func showWindowBorder(source: DisplayDescriptor, localRect: CGRect) {
        let window = NSWindow(
            contentRect: source.frame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.level = NSWindow.Level(rawValue: NSWindow.Level.screenSaver.rawValue + 1)
        window.backgroundColor = .clear
        window.isOpaque = false
        window.ignoresMouseEvents = true
        window.sharingType = .none
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        window.isReleasedWhenClosed = false

        let container = FlippedContainerView(frame: CGRect(origin: .zero, size: source.frame.size))
        container.addSubview(DemoMirrorBorderView(frame: localRect))
        window.contentView = container
        window.orderFrontRegardless()
        borderWindow = window
    }

    // MARK: - Mirroring

    private func beginMirroring(source: DisplayDescriptor, target: DisplayDescriptor, region: CGRect?, window: SCWindow?) async {
        guard let content = try? await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true),
              let scDisplay = content.displays.first(where: { $0.displayID == source.id }) else {
            stop()
            return
        }

        let settings = settingsStore.load()
        let trackWindow = settings.demoMirrorTrackWindowRegion
        let scale = source.scaleFactor

        let filter: SCContentFilter
        let contentSize: CGSize
        // The mirrored area in source-display-local, top-left-origin points, so
        // the green border can mark it on the source display.
        let sourceRect: CGRect
        let configuration = SCStreamConfiguration()
        configuration.showsCursor = true
        configuration.queueDepth = 3
        configuration.pixelFormat = kCVPixelFormatType_32BGRA
        configuration.minimumFrameInterval = CMTime(value: 1, timescale: 30)

        if let window, !trackWindow {
            // Mirror the window's surface directly: unaffected by overlapping
            // windows, but ZoomIt's own overlays (drawn as separate windows)
            // won't be visible in the mirror.
            filter = SCContentFilter(desktopIndependentWindow: window)
            contentSize = CGSize(width: window.frame.width * scale, height: window.frame.height * scale)
            configuration.width = Int(contentSize.width)
            configuration.height = Int(contentSize.height)
            sourceRect = Self.displayLocalRect(fromQuartzGlobal: window.frame, display: source)
        } else {
            filter = SCContentFilter(display: scDisplay, excludingWindows: [])
            let cropRect: CGRect
            if let window {
                // Track the window's screen region instead of its surface, so
                // ZoomIt zoom/draw overlays (drawn on top, on the source
                // display) show in the mirror in place.
                cropRect = Self.displayLocalRect(fromQuartzGlobal: window.frame, display: source)
            } else if let region {
                cropRect = region
            } else {
                cropRect = CGRect(origin: .zero, size: source.frame.size)
            }
            configuration.sourceRect = cropRect
            configuration.width = Int(cropRect.width * scale)
            configuration.height = Int(cropRect.height * scale)
            contentSize = CGSize(width: cropRect.width * scale, height: cropRect.height * scale)
            sourceRect = cropRect
        }

        let newStream = SCStream(filter: filter, configuration: configuration, delegate: nil)
        let output = DemoMirrorStreamOutput { [weak self] image in
            self?.mirrorImageView?.image = image
        }
        do {
            try newStream.addStreamOutput(output, type: .screen, sampleHandlerQueue: sampleQueue)
            try await newStream.startCapture()
        } catch {
            stop()
            return
        }

        stream = newStream
        streamOutput = output
        isActive = true

        showBackdrop(target: target)
        showMirrorWindow(target: target, contentSize: contentSize)
        // Mark what's being mirrored on the source display, for every scope
        // (whole screen, selected region, or window).
        showWindowBorder(source: source, localRect: sourceRect)
        startWatchingForDisplayChanges()

        if window != nil {
            startTrackingTimer(source: source)
        }
    }

    private func showBackdrop(target: DisplayDescriptor) {
        let window = NSWindow(
            contentRect: target.frame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.level = .screenSaver
        window.backgroundColor = .black
        window.isOpaque = true
        window.ignoresMouseEvents = true
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        window.isReleasedWhenClosed = false
        window.orderFrontRegardless()
        backdropWindow = window
    }

    private func showMirrorWindow(target: DisplayDescriptor, contentSize: CGSize) {
        let frame = Self.fitRect(contentSize: contentSize, in: target.frame)
        let window = NSWindow(
            contentRect: frame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.level = NSWindow.Level(rawValue: NSWindow.Level.screenSaver.rawValue + 1)
        window.backgroundColor = .black
        window.isOpaque = true
        window.ignoresMouseEvents = true
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        window.isReleasedWhenClosed = false

        let view = DemoMirrorImageView(frame: CGRect(origin: .zero, size: frame.size))
        window.contentView = view
        mirrorImageView = view
        window.orderFrontRegardless()
        mirrorWindow = window
    }

    /// Stops mirroring if the target (or source) display is disconnected.
    /// Without this, the mirror's full-screen, screen-saver-level windows get
    /// migrated by macOS onto the remaining display, where they cover
    /// everything (including the menu bar) and — being click-through — leave no
    /// way to reach ZoomIt to turn mirroring off.
    private func startWatchingForDisplayChanges() {
        if let screenParametersObserver {
            NotificationCenter.default.removeObserver(screenParametersObserver)
            self.screenParametersObserver = nil
        }
        screenParametersObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.isActive else { return }
                let displayIDs = Set(self.displayManager.displays().map(\.id))
                let targetGone = self.targetDisplay.map { !displayIDs.contains($0.id) } ?? true
                let sourceGone = self.sourceDisplay.map { !displayIDs.contains($0.id) } ?? true
                if targetGone || sourceGone {
                    self.stop()
                }
            }
        }
    }

    /// Periodically re-checks a tracked window: stops mirroring if it closed,
    /// and re-fits the crop region / border / mirror window if it moved or
    /// resized. Also re-asserts front ordering, matching Windows ZoomIt's
    /// topmost-reclaim behavior (e.g. against a reasserting slide show window).
    private func startTrackingTimer(source: DisplayDescriptor) {
        trackingTimer?.invalidate()
        trackingTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                Task { @MainActor in
                    await self.refreshTrackedWindow(source: source)
                }
            }
        }
    }

    private func refreshTrackedWindow(source: DisplayDescriptor) async {
        guard isActive, let trackedWindowID else { return }
        guard let content = try? await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true),
              let window = content.windows.first(where: { $0.windowID == trackedWindowID }) else {
            // The mirrored window closed.
            stop()
            return
        }

        let localRect = Self.displayLocalRect(fromQuartzGlobal: window.frame, display: source)
        if let borderView = borderWindow?.contentView?.subviews.first {
            borderView.frame = localRect
        }

        guard settingsStore.load().demoMirrorTrackWindowRegion, let stream else { return }
        let configuration = SCStreamConfiguration()
        configuration.showsCursor = true
        configuration.sourceRect = localRect
        let scale = source.scaleFactor
        configuration.width = Int(localRect.width * scale)
        configuration.height = Int(localRect.height * scale)
        configuration.pixelFormat = kCVPixelFormatType_32BGRA
        configuration.minimumFrameInterval = CMTime(value: 1, timescale: 30)
        try? await stream.updateConfiguration(configuration)

        if let target = targetDisplay, let mirrorWindow {
            let contentSize = CGSize(width: localRect.width * scale, height: localRect.height * scale)
            let frame = Self.fitRect(contentSize: contentSize, in: target.frame)
            if frame != mirrorWindow.frame {
                mirrorWindow.setFrame(frame, display: true)
                mirrorImageView?.frame = CGRect(origin: .zero, size: frame.size)
            }
        }

        backdropWindow?.orderFrontRegardless()
        mirrorWindow?.orderFrontRegardless()
        borderWindow?.orderFrontRegardless()
    }

    private func presentAlert(_ message: String) {
        let alert = NSAlert()
        alert.messageText = message
        alert.addButton(withTitle: "OK")
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }

    // MARK: - Geometry helpers

    /// Converts an AppKit global point (origin bottom-left of the primary
    /// display, y increasing upward) to the Quartz/ScreenCaptureKit global
    /// space that `SCWindow.frame` uses (origin top-left of the primary
    /// display, y increasing downward).
    private static func quartzGlobalPoint(fromAppKitGlobal point: CGPoint) -> CGPoint {
        let primaryHeight = NSScreen.screens.first(where: { $0.frame.origin == .zero })?.frame.height
            ?? NSScreen.screens.first?.frame.height ?? 0
        return CGPoint(x: point.x, y: primaryHeight - point.y)
    }

    /// Converts a Quartz-global rect (as reported by `SCWindow.frame`) into a
    /// rect local to `display`, in top-left-origin view points — the same
    /// coordinate space `SCStreamConfiguration.sourceRect` expects.
    private static func displayLocalRect(fromQuartzGlobal rect: CGRect, display: DisplayDescriptor) -> CGRect {
        let primaryHeight = NSScreen.screens.first(where: { $0.frame.origin == .zero })?.frame.height
            ?? NSScreen.screens.first?.frame.height ?? 0
        // The display's own AppKit frame has a bottom-left origin; its top-left
        // corner in Quartz global space is (minX, primaryHeight - maxY).
        let displayQuartzOrigin = CGPoint(x: display.frame.minX, y: primaryHeight - display.frame.maxY)
        let local = CGRect(
            x: rect.minX - displayQuartzOrigin.x,
            y: rect.minY - displayQuartzOrigin.y,
            width: rect.width,
            height: rect.height
        )
        // Clamp to the display's own bounds so a partially off-screen window
        // doesn't produce an invalid capture region.
        return local.intersection(CGRect(origin: .zero, size: display.frame.size))
    }

    /// The largest rect that fits `contentSize` within `bounds` while
    /// preserving its aspect ratio, centered (letterboxing any leftover space).
    private static func fitRect(contentSize: CGSize, in bounds: CGRect) -> CGRect {
        guard contentSize.width > 0, contentSize.height > 0 else { return bounds }
        let scale = min(bounds.width / contentSize.width, bounds.height / contentSize.height)
        let width = (contentSize.width * scale).rounded()
        let height = (contentSize.height * scale).rounded()
        let x = (bounds.minX + (bounds.width - width) / 2).rounded()
        let y = (bounds.minY + (bounds.height - height) / 2).rounded()
        return CGRect(x: x, y: y, width: width, height: height)
    }
}
