import AppKit
@preconcurrency import ScreenCaptureKit

/// Draws a blue capture border plus an instruction banner around the panorama
/// region. It lives in a click-through, non-shareable window so it never
/// appears in the captured frames (mirroring the Windows excluded-from-capture
/// SelectRectangle border).
@MainActor
private final class PanoramaBorderView: NSView {
    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        let lineWidth: CGFloat = 4
        let rect = bounds.insetBy(dx: lineWidth / 2, dy: lineWidth / 2)
        context.setStrokeColor(NSColor.systemBlue.cgColor)
        context.setLineWidth(lineWidth)
        context.stroke(rect)
    }
}

@MainActor
private final class PanoramaProgressWindow: NSWindow {
    var onCancel: (() -> Void)?

    override var canBecomeKey: Bool { true }

    override func cancelOperation(_ sender: Any?) {
        onCancel?()
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 {
            onCancel?()
        } else {
            super.keyDown(with: event)
        }
    }
}

/// Captures a scrolling panorama of a selected region, mirroring ZoomIt's
/// panorama feature (Windows Ctrl+8 / Ctrl+Shift+8).
///
/// Flow: select a region, then repeatedly snapshot it while the user scrolls
/// the underlying content. Near-duplicate frames are discarded. Pressing the
/// panorama hotkey again stops capture; the frames are stitched together
/// (`PanoramaStitcher`) and copied to the clipboard or saved to a PNG file.
@MainActor
final class PanoramaController {
    private let displayManager: DisplayManager
    private let permissionService: PermissionService
    private let settingsStore: SettingsStore

    private(set) var isCapturing = false
    private var stopRequested = false
    /// True from the moment a panorama is initiated (region selection) until it
    /// finishes, so a second trigger can't stack a new selection.
    private var isActive = false
    private var onStateChange: ((Bool) -> Void)?
    /// Called right before the Save dialog is shown so any obscuring overlay can
    /// be dismissed first.
    var onWillShowSaveDialog: (() -> Void)?

    private var borderWindow: NSWindow?
    private var bannerWindow: NSWindow?
    private var completionWindow: NSWindow?
    private var progressWindow: NSWindow?
    private var progressIndicator: NSProgressIndicator?
    private var stitchTask: Task<PanoramaStitcher.Frame?, Never>?
    private var stitchCancelled = false
    private var captureDisplay: DisplayDescriptor?

    /// Upper bound on captured frames to keep stitching tractable.
    private let maxFrames = 400
    /// Memory budget for accumulated frames (~1.2 GB of RGBA pixels). Capture
    /// stops when exceeded so the stitch doesn't exhaust memory and stall.
    private let maxFrameBytes = 1_200_000_000

    init(
        displayManager: DisplayManager,
        permissionService: PermissionService,
        settingsStore: SettingsStore
    ) {
        self.displayManager = displayManager
        self.permissionService = permissionService
        self.settingsStore = settingsStore
    }

    /// Toggles panorama capture. The first call selects a region and begins
    /// capturing; a second call stops and produces the panorama. `save` chooses
    /// between saving to a file and copying to the clipboard.
    func toggle(save: Bool, onStateChange: @escaping (Bool) -> Void) {
        if isCapturing {
            stopRequested = true
            return
        }
        if isActive {
            // A region selection is already on screen; ignore re-triggers.
            return
        }
        isActive = true
        self.onStateChange = onStateChange
        start(save: save)
    }

    private func start(save: Bool) {
        guard ScreenRecordingPrompt.ensureGranted(permissionService) else {
            isActive = false
            return
        }
        guard let display = displayManager.activeDisplay() else {
            NSSound.beep()
            isActive = false
            return
        }

        selectRegion(on: display) { [weak self] rect in
            guard let self else { return }
            guard let rect else {
                self.isActive = false
                return
            }
            self.beginCapture(display: display, region: rect, save: save)
        }
    }

    // MARK: - Region selection

    private func selectRegion(on display: DisplayDescriptor, completion: @escaping (CGRect?) -> Void) {
        Task { @MainActor in
            guard let image = await self.captureRegion(display: display, region: nil) else {
                NSSound.beep()
                completion(nil)
                return
            }
            let frame = CapturedFrame(
                image: image,
                display: display,
                pixelSize: CGSize(width: image.width, height: image.height),
                timestamp: Date()
            )
            let window = SnipWindow(
                contentRect: display.frame,
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
                frame: CGRect(origin: .zero, size: display.frame.size),
                image: frame.image
            )
            var holder: NSWindow? = window
            var cursorLease: CrosshairCursorLease?
            view.onComplete = { rect in
                holder?.orderOut(nil)
                holder = nil
                cursorLease?.invalidate()
                cursorLease = nil
                completion(rect)
            }
            window.contentView = view
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            window.makeFirstResponder(view)
            cursorLease = CrosshairCursorLease(window: window)
            cursorLease?.activate()
        }
    }

    // MARK: - Capture loop

    private func beginCapture(display: DisplayDescriptor, region: CGRect, save: Bool) {
        captureDisplay = display
        showBorder(display: display, region: region)
        isCapturing = true
        stopRequested = false
        onStateChange?(true)

        Task { @MainActor in
            // Always release the capture state, even on an early return or
            // error, so a stuck panorama can never wedge the hotkey.
            defer {
                isCapturing = false
                isActive = false
                hideOverlays()
            }

            guard let (filter, configuration) = await makeRegionCapture(display: display, region: region) else {
                onStateChange?(false)
                NSSound.beep()
                return
            }

            var frames: [PanoramaStitcher.Frame] = []
            let frameBytes = configuration.width * configuration.height * 4
            var totalBytes = 0

            @MainActor func appendFrameIfNew(_ frame: PanoramaStitcher.Frame) {
                if frames.isEmpty || !PanoramaStitcher.isNearDuplicate(frames[frames.count - 1], frame) {
                    frames.append(frame)
                    totalBytes += frameBytes
                    updateBanner(captureText(frameCount: frames.count))
                }
            }

            while !stopRequested && frames.count < maxFrames && totalBytes + frameBytes <= maxFrameBytes {
                let image = try? await SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration)
                if let image, let frame = Self.makeFrame(from: image) {
                    appendFrameIfNew(frame)
                }
                // Match Windows' ~16 ms cadence; duplicate filtering and memory
                // caps keep the retained frame set bounded.
                try? await Task.sleep(nanoseconds: 16_000_000)
            }

            if stopRequested && frames.count < maxFrames && totalBytes + frameBytes <= maxFrameBytes {
                let image = try? await SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration)
                if let image, let frame = Self.makeFrame(from: image) {
                    appendFrameIfNew(frame)
                }
            }

            // Capture finished: drop the live border, switch the banner to a
            // processing message, and report the recording state as stopped.
            isCapturing = false
            borderWindow?.orderOut(nil)
            borderWindow = nil
            onStateChange?(false)
            updateBanner("ZoomIt panorama stitching...")

            // Optional: dump raw frames for offline algorithm debugging when
            // ZOOMIT_PANORAMA_DUMP is set. Each file is width,height-prefixed
            // RGBA. Enables building regressions from real captures.
            Self.dumpFramesIfRequested(frames)

            let message = await finishCapture(frames: frames, save: save)
            showCompletion(message: message)
        }
    }

    private static func dumpFramesIfRequested(_ frames: [PanoramaStitcher.Frame]) {
        guard let dir = ProcessInfo.processInfo.environment["ZOOMIT_PANORAMA_DUMP"], !frames.isEmpty else { return }
        let base = URL(fileURLWithPath: dir, isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        for (i, f) in frames.enumerated() {
            var data = Data()
            var header = "\(f.width) \(f.height)\n"
            data.append(header.data(using: .utf8)!)
            data.append(contentsOf: f.pixels)
            try? data.write(to: base.appendingPathComponent(String(format: "frame_%04d.bin", i)))
            header.removeAll()
        }
        NSLog("ZoomIt: dumped \(frames.count) panorama frames to \(dir)")
    }

    private func captureText(frameCount: Int) -> String {
        let frameWord = frameCount == 1 ? "frame" : "frames"
        return "Panorama: scroll the content, then press the shortcut again to finish — \(frameCount) \(frameWord)"
    }

    private func finishCapture(frames: [PanoramaStitcher.Frame], save: Bool) async -> String {
        guard !frames.isEmpty else { return "Panorama cancelled — nothing captured" }

        // Swap the capture banner for a determinate progress dialog so the user
        // can see that stitching is underway (it can take a while on long runs).
        bannerWindow?.orderOut(nil)
        bannerWindow = nil
        stitchCancelled = false
        showStitchingProgress { [weak self] in
            self?.cancelStitching()
        }

        // Stitch off the main actor; it is CPU-heavy and AppKit-free. The
        // progress closure is `@Sendable` and hops back to the main actor to
        // drive the progress bar.
        let onProgress: @Sendable (Int) -> Void = { [weak self] percent in
            Task { @MainActor in self?.updateStitchProgress(percent) }
        }
        let task = Task.detached(priority: .userInitiated) {
            PanoramaStitcher.stitch(frames: frames, progress: onProgress) {
                Task.isCancelled
            }
        }
        stitchTask = task
        let stitched = await task.value
        stitchTask = nil
        let wasCancelled = stitchCancelled

        hideStitchingProgress()

        if wasCancelled {
            return "Panorama stitching cancelled"
        }

        guard let stitched, let cgImage = Self.makeCGImage(from: stitched) else {
            NSSound.beep()
            return "Panorama failed to stitch"
        }

        if save {
            onWillShowSaveDialog?()
            ImageExporter.presentSavePanel(for: cgImage)
            return "Panorama ready to save"
        } else {
            ImageExporter.copyToPasteboard(cgImage)
            return "Panorama copied to clipboard"
        }
    }

    // MARK: - ScreenCaptureKit

    /// Captures the display, optionally cropped to `region` (in view points,
    /// top-left origin within the display), at native pixel resolution.
    private func captureRegion(display: DisplayDescriptor, region: CGRect?) async -> CGImage? {
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
            guard let scDisplay = content.displays.first(where: { $0.displayID == display.id }) else {
                return nil
            }
            let filter = SCContentFilter(display: scDisplay, excludingWindows: [])
            let configuration = SCStreamConfiguration()
            let scale = display.scaleFactor
            if let region {
                configuration.sourceRect = region
                configuration.width = Int(region.width * scale)
                configuration.height = Int(region.height * scale)
            } else {
                configuration.width = Int(display.frame.width * scale)
                configuration.height = Int(display.frame.height * scale)
            }
            configuration.showsCursor = false
            return try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration)
        } catch {
            return nil
        }
    }

    /// Builds the reusable content filter and configuration for the capture
    /// loop once, so each frame grab doesn't re-query shareable content.
    private func makeRegionCapture(display: DisplayDescriptor, region: CGRect) async -> (SCContentFilter, SCStreamConfiguration)? {
        guard let content = try? await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true),
              let scDisplay = content.displays.first(where: { $0.displayID == display.id }) else {
            return nil
        }
        let filter = SCContentFilter(display: scDisplay, excludingWindows: [])
        let configuration = SCStreamConfiguration()
        let scale = display.scaleFactor
        configuration.sourceRect = region
        configuration.width = Int(region.width * scale)
        configuration.height = Int(region.height * scale)
        configuration.showsCursor = false
        return (filter, configuration)
    }

    // MARK: - Border + banner overlay

    private func showBorder(display: DisplayDescriptor, region: CGRect) {
        let window = NSWindow(
            contentRect: display.frame,
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

        // SnipSelectionView reports the region in view points (top-left origin);
        // the border container is flipped to match.
        window.contentView = makeBorderContainer(displaySize: display.frame.size, region: region)
        window.orderFrontRegardless()
        borderWindow = window

        updateBanner(captureText(frameCount: 0))
    }

    private func makeBorderContainer(displaySize: CGSize, region: CGRect) -> NSView {
        // A flipped container so the blue border lines up with the top-left
        // origin rectangle reported by the selection view.
        final class FlippedContainer: NSView { override var isFlipped: Bool { true } }
        let container = FlippedContainer(frame: CGRect(origin: .zero, size: displaySize))
        let border = PanoramaBorderView(frame: region)
        container.addSubview(border)
        return container
    }

    /// Shows or updates the instruction/status banner near the top of the
    /// capture display.
    private func updateBanner(_ text: String) {
        guard let display = captureDisplay else { return }
        let window = bannerWindow ?? makeHUDWindow()
        window.contentView = makeHUDContent(text: text)
        let size = window.contentView?.fittingSize ?? NSSize(width: 320, height: 36)
        let originX = display.frame.minX + (display.frame.width - size.width) / 2
        let originY = display.frame.maxY - size.height - 60
        window.setFrame(CGRect(x: originX, y: originY, width: size.width, height: size.height), display: true)
        window.orderFrontRegardless()
        bannerWindow = window
    }

    /// Shows a transient confirmation HUD that auto-dismisses, so clipboard
    /// copies (which have no other visible result) are noticeable.
    private func showCompletion(message: String) {
        guard let display = captureDisplay else { return }
        let window = makeHUDWindow()
        window.contentView = makeHUDContent(text: message)
        let size = window.contentView?.fittingSize ?? NSSize(width: 320, height: 36)
        let originX = display.frame.minX + (display.frame.width - size.width) / 2
        let originY = display.frame.maxY - size.height - 60
        window.setFrame(CGRect(x: originX, y: originY, width: size.width, height: size.height), display: true)
        window.orderFrontRegardless()
        completionWindow?.orderOut(nil)
        completionWindow = window

        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 1_800_000_000)
            if self.completionWindow === window {
                window.orderOut(nil)
                self.completionWindow = nil
            }
        }
    }

    // MARK: - Stitching progress

    /// Shows a determinate progress dialog centered on the capture display while
    /// the frames are stitched, so the user knows work is happening.
    private func showStitchingProgress(onCancel: @escaping () -> Void) {
        guard let display = captureDisplay else { return }
        let window = makeProgressWindow(onCancel: onCancel)

        let label = NSTextField(labelWithString: "ZoomIt panorama stitching...")
        label.font = .systemFont(ofSize: 14, weight: .medium)
        label.textColor = .white
        label.sizeToFit()

        let indicator = NSProgressIndicator()
        indicator.style = .bar
        indicator.isIndeterminate = false
        indicator.minValue = 0
        indicator.maxValue = 100
        indicator.doubleValue = 0

        let contentWidth: CGFloat = 280
        let padding: CGFloat = 16
        let spacing: CGFloat = 12
        let barHeight: CGFloat = 14
        let totalHeight = padding + label.frame.height + spacing + barHeight + padding
        let container = NSView(frame: CGRect(x: 0, y: 0, width: contentWidth + padding * 2, height: totalHeight))
        container.wantsLayer = true
        container.layer?.backgroundColor = NSColor(white: 0, alpha: 0.78).cgColor
        container.layer?.cornerRadius = 10

        // The container is unflipped (bottom-left origin), so place the bar below
        // the label.
        indicator.frame = CGRect(x: padding, y: padding, width: contentWidth, height: barHeight)
        label.frame = CGRect(x: padding, y: padding + barHeight + spacing,
                             width: contentWidth, height: label.frame.height)
        container.addSubview(indicator)
        container.addSubview(label)

        window.contentView = container
        let size = container.frame.size
        let originX = display.frame.minX + (display.frame.width - size.width) / 2
        let originY = display.frame.minY + (display.frame.height - size.height) / 2
        window.setFrame(CGRect(x: originX, y: originY, width: size.width, height: size.height), display: true)
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)

        progressIndicator = indicator
        progressWindow = window
    }

    private func cancelStitching() {
        stitchCancelled = true
        stitchTask?.cancel()
    }

    private func updateStitchProgress(_ percent: Int) {
        progressIndicator?.doubleValue = Double(max(0, min(100, percent)))
    }

    private func hideStitchingProgress() {
        progressWindow?.orderOut(nil)
        progressWindow = nil
        progressIndicator = nil
    }

    private func makeProgressWindow(onCancel: @escaping () -> Void) -> NSWindow {
        let window = PanoramaProgressWindow(
            contentRect: CGRect(x: 0, y: 0, width: 320, height: 64),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.onCancel = onCancel
        window.level = NSWindow.Level(rawValue: NSWindow.Level.screenSaver.rawValue + 1)
        window.isOpaque = false
        window.backgroundColor = .clear
        window.ignoresMouseEvents = false
        window.sharingType = .none
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        window.isReleasedWhenClosed = false
        return window
    }

    private func makeHUDWindow() -> NSWindow {
        let window = NSWindow(
            contentRect: CGRect(x: 0, y: 0, width: 320, height: 36),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.level = NSWindow.Level(rawValue: NSWindow.Level.screenSaver.rawValue + 1)
        window.isOpaque = false
        window.backgroundColor = .clear
        window.ignoresMouseEvents = true
        window.sharingType = .none
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        window.isReleasedWhenClosed = false
        return window
    }

    private func makeHUDContent(text: String) -> NSView {
        let label = NSTextField(labelWithString: text)
        label.font = .systemFont(ofSize: 14, weight: .medium)
        label.textColor = .white
        label.sizeToFit()

        let padding: CGFloat = 12
        let size = NSSize(width: label.frame.width + padding * 2, height: label.frame.height + padding)
        let container = NSView(frame: CGRect(origin: .zero, size: size))
        container.wantsLayer = true
        container.layer?.backgroundColor = NSColor(white: 0, alpha: 0.7).cgColor
        container.layer?.cornerRadius = 8
        label.frame = CGRect(x: padding, y: padding / 2, width: label.frame.width, height: label.frame.height)
        container.addSubview(label)
        return container
    }

    private func hideOverlays() {
        borderWindow?.orderOut(nil)
        borderWindow = nil
        bannerWindow?.orderOut(nil)
        bannerWindow = nil
        progressWindow?.orderOut(nil)
        progressWindow = nil
        progressIndicator = nil
        stitchTask?.cancel()
        stitchTask = nil
    }

    // MARK: - CGImage <-> Frame

    /// Convert a captured CGImage into a top-down RGBA frame for stitching.
    static func makeFrame(from image: CGImage) -> PanoramaStitcher.Frame? {
        let width = image.width
        let height = image.height
        guard width > 0, height > 0 else { return nil }
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGImageAlphaInfo.premultipliedLast.rawValue
        let success = pixels.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(
                data: buffer.baseAddress,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: width * 4,
                space: colorSpace,
                bitmapInfo: bitmapInfo
            ) else { return false }
            // Draw without flipping: a freshly created bitmap context already
            // stores row 0 as the top of the image (matching CGImage's top-down
            // memory layout and `makeCGImage`'s interpretation). Adding a flip
            // here would store the buffer bottom-up, producing an upside-down,
            // reverse-ordered panorama.
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard success else { return nil }
        return PanoramaStitcher.Frame(width: width, height: height, pixels: pixels)
    }

    /// Build a CGImage from a top-down RGBA panorama frame.
    static func makeCGImage(from frame: PanoramaStitcher.Frame) -> CGImage? {
        guard frame.width > 0, frame.height > 0 else { return nil }
        let data = Data(frame.pixels)
        guard let provider = CGDataProvider(data: data as CFData) else { return nil }
        let bitmapInfo = CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue)
        return CGImage(
            width: frame.width,
            height: frame.height,
            bitsPerComponent: 8,
            bitsPerPixel: 32,
            bytesPerRow: frame.width * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: bitmapInfo,
            provider: provider,
            decode: nil,
            shouldInterpolate: false,
            intent: .defaultIntent
        )
    }
}
