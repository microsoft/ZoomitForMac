import AppKit

@MainActor
final class ZoomCanvasView: NSView {
    private var capturedFrame: CapturedFrame
    private let viewportController: ZoomViewportController
    private let annotationController: AnnotationController
    private let commandSink: (AppCommand) -> Void
    private var latestCursorLocation: CGPoint?
    private var pointerViewPoint: CGPoint = .zero
    private var isDrawingMode = false
    private var isStroking = false
    private var isDrawOnly = false
    /// The tool of the in-progress stroke, used to hide the pen cursor while a
    /// shape (line/arrow/rectangle/ellipse) is being dragged out.
    private var activeStrokeTool: AnnotationTool?
    private var cursorHidden = false
    /// While interactive live zoom is on, the overlay is click-through and a
    /// global monitor tracks the real cursor so the magnified view follows it.
    private var liveMouseMonitor: Any?
    private var liveZoomClickThrough = false
    /// Region-snip state: while active, a drag selects a rectangle of the
    /// current viewport to copy or save.
    private var isSelectingRegion = false
    private var regionSaveToFile = false
    private var regionAnchor: CGPoint?
    private var regionRect: CGRect = .zero
    private var regionCursorPushed = false
    private var onRegionSnipFinished: (() -> Void)?
    private var scrollZoomAccumulator: CGFloat = 0
    private let smoothImage: Bool

    private enum BlankScreen {
        case black
        case white

        var fillColor: NSColor {
            switch self {
            case .black: return .black
            case .white: return .white
            }
        }
    }
    private var blankScreen: BlankScreen?

    var interactionMode: AppMode = .staticZoom {
        didSet {
            let leftTypingMode = oldValue == .typing && interactionMode != .typing
            switch interactionMode {
            case .typing:
                exitDrawingMode()
                // Place the caret at the current cursor position, like ZoomIt.
                annotationController.setInsertionPoint(contentPoint(forViewPoint: pointerViewPoint))
            case .drawOnly:
                // Draw-without-zoom starts already in drawing mode so the first
                // click begins a stroke immediately.
                isDrawOnly = true
                enterDrawingMode()
            default:
                break
            }
            if leftTypingMode {
                anchorCursorAfterTyping()
            }
            updateLiveZoomInteractivity()
            needsDisplay = true
        }
    }

    init(
        frame frameRect: CGRect,
        capturedFrame: CapturedFrame,
        viewportController: ZoomViewportController,
        annotationController: AnnotationController,
        smoothImage: Bool,
        commandSink: @escaping (AppCommand) -> Void
    ) {
        self.capturedFrame = capturedFrame
        self.viewportController = viewportController
        self.annotationController = annotationController
        self.smoothImage = smoothImage
        self.commandSink = commandSink
        super.init(frame: frameRect)
        // Anchor the initial zoom on the current cursor position so the view
        // does not jump when the mouse first moves after the hotkey activates.
        latestCursorLocation = NSEvent.mouseLocation
        wantsLayer = true
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    /// Replaces the displayed screen image with a freshly captured live frame.
    /// Used by live zoom, where the magnified content keeps updating instead of
    /// being a frozen snapshot. The display geometry is unchanged, so only the
    /// pixels are swapped and a redraw is requested.
    func updateLiveImage(_ image: CGImage) {
        capturedFrame.image = image
        needsDisplay = true
    }

    /// Toggles drawing mode from outside (e.g. the draw hotkey while live
    /// zoomed): it arms drawing if idle, or leaves drawing mode if already on,
    /// without changing magnification.
    func toggleDrawingMode() {
        if isDrawingMode {
            exitDrawingMode()
        } else {
            enterDrawingMode()
        }
        needsDisplay = true
    }

    override var acceptsFirstResponder: Bool { true }

    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }

        context.interpolationQuality = smoothImage ? .high : .none

        let source = viewportController.sourceRect(for: bounds, cursorLocation: latestCursorLocation)

        if let blankScreen {
            // Sketch-pad mode: replace the captured screen with a solid color.
            context.setFillColor(blankScreen.fillColor.cgColor)
            context.fill(bounds)
        } else {
            context.setFillColor(NSColor.black.cgColor)
            context.fill(bounds)

            let scaledSource = source.applying(CGAffineTransform(scaleX: capturedFrame.display.scaleFactor, y: capturedFrame.display.scaleFactor))

            // The view is flipped (top-left origin) so annotations share the same
            // coordinate space as the captured image. A CGImage draws upside down in
            // a flipped context, so flip vertically around the bounds while drawing it.
            context.saveGState()
            context.translateBy(x: 0, y: bounds.height)
            context.scaleBy(x: 1, y: -1)
            if let cropped = capturedFrame.image.cropping(to: scaledSource) {
                context.draw(cropped, in: bounds)
            } else {
                context.draw(capturedFrame.image, in: bounds)
            }
            context.restoreGState()
        }

        context.saveGState()
        context.concatenate(viewportController.contentToDestinationTransform(source: source, destinationBounds: bounds))
        annotationController.render(in: context, bounds: bounds)
        if interactionMode == .typing {
            drawTypingCaret(in: context)
        }
        context.restoreGState()

        if isDrawingMode && !isDrawingShapeStroke {
            drawCursorIndicator(in: context, source: source)
        }

        if isSelectingRegion {
            drawRegionSelection(in: context)
        }
    }

    /// True while the user is actively dragging out a shape, where the pen dot
    /// would just clutter the shape being drawn.
    private var isDrawingShapeStroke: Bool {
        guard isStroking, let tool = activeStrokeTool else { return false }
        switch tool {
        case .line, .arrow, .rectangle, .ellipse:
            return true
        default:
            return false
        }
    }

    override func mouseMoved(with event: NSEvent) {
        pointerViewPoint = convert(event.locationInWindow, from: nil)
        if interactionMode == .typing {
            // The caret follows the mouse until the first character is typed,
            // then locks in place, matching ZoomIt.
            if !annotationController.isTypingLocked {
                annotationController.setInsertionPoint(contentPoint(forViewPoint: pointerViewPoint))
            }
        } else if !isDrawingMode {
            latestCursorLocation = NSEvent.mouseLocation
        }
        needsDisplay = true
    }

    override func mouseDown(with event: NSEvent) {
        pointerViewPoint = convert(event.locationInWindow, from: nil)

        if isSelectingRegion {
            regionAnchor = pointerViewPoint
            regionRect = .zero
            needsDisplay = true
            return
        }

        if interactionMode == .typing {
            annotationController.setInsertionPoint(contentPoint(for: event))
            needsDisplay = true
            return
        }

        guard isDrawingMode else {
            // In live zoom, clicking must not enter drawing mode; the user
            // explicitly enters it with the draw hotkey (Control+1/Control+2).
            if interactionMode == .liveZoom {
                return
            }
            // The first press only arms drawing mode and shows the pen cursor;
            // it does not begin a stroke.
            enterDrawingMode()
            needsDisplay = true
            return
        }

        let tool = gestureTool(for: event) ?? annotationController.currentTool
        let point = contentPoint(for: event)
        annotationController.setInsertionPoint(point)
        annotationController.begin(at: point, tool: tool)
        isStroking = true
        activeStrokeTool = tool
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        pointerViewPoint = convert(event.locationInWindow, from: nil)
        if isSelectingRegion {
            updateRegionRect(to: pointerViewPoint)
            needsDisplay = true
            return
        }
        if isDrawingMode && isStroking {
            annotationController.update(at: contentPoint(for: event))
        }
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        pointerViewPoint = convert(event.locationInWindow, from: nil)
        if isSelectingRegion {
            finishRegionSnip()
            return
        }
        if isDrawingMode && isStroking {
            annotationController.end(at: contentPoint(for: event))
            isStroking = false
            activeStrokeTool = nil
        }
        needsDisplay = true
    }

    override func rightMouseDown(with event: NSEvent) {
        if interactionMode == .typing {
            if annotationController.isTypingLocked {
                // Finish the current text block and return to a free-floating
                // caret, leaving it where the text cursor was while typing.
                let insertion = annotationController.typingCaret()?.origin ?? contentPoint(for: event)
                annotationController.setInsertionPoint(insertion)
                // Warp the hidden system cursor to the caret so the next mouse
                // move continues from there rather than snapping back to where
                // typing mode was entered.
                if let screenPoint = screenLocation(forContentPoint: insertion) {
                    warpCursor(toGlobal: screenPoint)
                }
            } else {
                // Caret mode with nothing typed yet: return to pan/zoom mode.
                commandSink(.toggleTyping(rightAligned: false))
            }
            needsDisplay = true
            return
        }

        if isDrawingMode {
            // Right click leaves drawing mode and returns to pannable zoom. In
            // draw-without-zoom there is no zoom to return to, so exit instead.
            if isDrawOnly {
                commandSink(.exit)
            } else {
                exitDrawingMode()
                needsDisplay = true
            }
        }
        // Right click no longer exits the overlay; use Esc or zoom out to 1x.
    }

    override func scrollWheel(with event: NSEvent) {
        if isDrawingMode {
            if event.scrollingDeltaY > 0 {
                commandSink(.increasePenWidth)
            } else if event.scrollingDeltaY < 0 {
                commandSink(.decreasePenWidth)
            }
            needsDisplay = true
            return
        }

        let delta = event.scrollingDeltaY
        guard delta != 0 else { return }

        // Use the same discrete steps as the Up/Down arrow keys (ZoomIt's
        // doubling/halving telescope steps) instead of a smooth zoom.
        if event.hasPreciseScrollingDeltas {
            // Trackpad / precise mouse: accumulate pixels into whole steps and
            // reset the accumulator whenever the scroll direction reverses.
            if (delta > 0) != (scrollZoomAccumulator > 0) {
                scrollZoomAccumulator = 0
            }
            scrollZoomAccumulator += delta
            let threshold: CGFloat = 40
            while scrollZoomAccumulator >= threshold {
                scrollZoomAccumulator -= threshold
                commandSink(.zoomIn)
            }
            while scrollZoomAccumulator <= -threshold {
                scrollZoomAccumulator += threshold
                commandSink(.zoomOutOrExit)
            }
        } else {
            // Classic wheel: one zoom step per notch.
            commandSink(delta > 0 ? .zoomIn : .zoomOutOrExit)
        }
        needsDisplay = true
    }

    override func keyDown(with event: NSEvent) {
        if isSelectingRegion {
            // Only Escape (cancel) is honoured while selecting a snip region.
            if event.keyCode == 53 {
                cancelRegionSnip()
            }
            return
        }
        switch event.keyCode {
        case 53:
            // Esc leaves typing mode first (matching ZoomIt). In live-zoom
            // drawing it leaves drawing mode but stays in live zoom; otherwise
            // it exits the overlay.
            if interactionMode == .typing {
                commandSink(.toggleTyping(rightAligned: false))
            } else if interactionMode == .liveZoom && isDrawingMode {
                exitDrawingMode()
                needsDisplay = true
            } else {
                commandSink(.exit)
            }
        case 48:
            // Swallow Tab so it never beeps; the ellipse gesture reads the live
            // Tab key state at stroke start instead.
            break
        case 126:
            if interactionMode == .typing {
                commandSink(.increaseFontSize)
                needsDisplay = true
            } else {
                handleVerticalArrow(up: true, shift: event.modifierFlags.contains(.shift))
            }
        case 125:
            if interactionMode == .typing {
                commandSink(.decreaseFontSize)
                needsDisplay = true
            } else {
                handleVerticalArrow(up: false, shift: event.modifierFlags.contains(.shift))
            }
        case 6 where event.modifierFlags.contains(.command) || event.modifierFlags.contains(.control):
            // Ctrl+Z (matching Windows ZoomIt) or ⌘Z undoes the last gesture.
            commandSink(.undo)
        case 1 where event.modifierFlags.contains(.command):
            // ⌘S saves the whole zoomed viewport (matching ZoomIt's Ctrl+S).
            saveViewport()
        case 8 where event.modifierFlags.contains(.command):
            // ⌘C copies the whole zoomed viewport (matching ZoomIt's Ctrl+C).
            copyViewport()
        case 51 where interactionMode == .typing, 117 where interactionMode == .typing:
            annotationController.deleteBackward()
            needsDisplay = true
        case 36 where interactionMode == .typing, 76 where interactionMode == .typing:
            // Return / Enter starts a new line. The caret drops to the next line
            // left-aligned with the start of the text (right edge for
            // right-aligned typing), matching standard multi-line text entry.
            annotationController.insertText("\n")
            needsDisplay = true
        default:
            if interactionMode == .typing, let characters = event.characters, !characters.isEmpty {
                annotationController.insertText(characters)
                needsDisplay = true
            } else {
                handleDrawingShortcut(event) ?? interpretKeyEvents([event])
            }
        }
    }

    private func handleDrawingShortcut(_ event: NSEvent) -> Void? {
        guard let key = event.charactersIgnoringModifiers?.lowercased() else { return nil }

        switch key {
        case "r": commandSink(.setColor(.red))
        case "g": commandSink(.setColor(.green))
        case "b": commandSink(.setColor(.blue))
        case "y": commandSink(.setColor(.yellow))
        case "o": commandSink(.setColor(.orange))
        case "p": commandSink(.setColor(.pink))
        case "w":
            // In drawing mode, W blanks the screen white (sketch pad); otherwise
            // it selects the white pen.
            if isDrawingMode {
                toggleBlankScreen(.white)
            } else {
                commandSink(.setColor(.white))
            }
        case "k":
            // In drawing mode, K blanks the screen black; otherwise selects black pen.
            if isDrawingMode {
                toggleBlankScreen(.black)
            } else {
                commandSink(.setColor(.black))
            }
        case "f": commandSink(.setTool(.pen))
        case "l": commandSink(.setTool(.line))
        case "a": commandSink(.setTool(.arrow))
        case "e":
            // E erases all drawing, matching Windows ZoomIt.
            commandSink(.clear)
        case "h": commandSink(.setTool(.highlighter))
        case "t":
            // T enters typing mode left-justified; Shift+T right-justified.
            commandSink(.toggleTyping(rightAligned: event.modifierFlags.contains(.shift)))
        case "[": commandSink(.decreasePenWidth)
        case "]": commandSink(.increasePenWidth)
        default: return nil
        }

        needsDisplay = true
        return ()
    }

    private func toggleBlankScreen(_ screen: BlankScreen) {
        blankScreen = (blankScreen == screen) ? nil : screen
        needsDisplay = true
    }

    private func drawTypingCaret(in context: CGContext) {
        guard let caret = annotationController.typingCaret() else { return }
        let color = annotationController.currentStyle.color.nsColor
        context.setStrokeColor(color.cgColor)
        context.setLineWidth(max(1, caret.height * 0.06))
        context.setLineCap(.butt)
        context.beginPath()
        context.move(to: caret.origin)
        context.addLine(to: CGPoint(x: caret.origin.x, y: caret.origin.y + caret.height))
        context.strokePath()
    }

    private func contentPoint(for event: NSEvent) -> CGPoint {
        let viewPoint = convert(event.locationInWindow, from: nil)
        return contentPoint(forViewPoint: viewPoint)
    }

    private func contentPoint(forViewPoint viewPoint: CGPoint) -> CGPoint {
        viewportController.contentPoint(for: viewPoint, destinationBounds: bounds, cursorLocation: latestCursorLocation)
    }

    /// Maps a held modifier (or Tab) at stroke start to a ZoomIt shape gesture:
    /// Ctrl = rectangle, Shift = line, Ctrl+Shift = arrow, Tab = ellipse.
    private func gestureTool(for event: NSEvent) -> AnnotationTool? {
        let modifiers = event.modifierFlags
        let shift = modifiers.contains(.shift)
        let control = modifiers.contains(.control)
        if control && shift { return .arrow }
        if control { return .rectangle }
        if shift { return .line }
        if tabKeyIsDown() { return .ellipse }
        return nil
    }

    private func tabKeyIsDown() -> Bool {
        // Query the live keyboard state so a missed key-up can never leave us
        // stuck in the ellipse gesture. 0x30 is the Tab virtual key code.
        CGEventSource.keyState(.combinedSessionState, key: 0x30)
    }

    private func handleVerticalArrow(up: Bool, shift: Bool) {
        if shift {
            commandSink(up ? .increasePenWidth : .decreasePenWidth)
        } else {
            commandSink(up ? .zoomIn : .zoomOutOrExit)
        }
        needsDisplay = true
    }

    private func enterDrawingMode() {
        guard !isDrawingMode else { return }
        isDrawingMode = true
        isStroking = false
        updateLiveZoomInteractivity()
    }

    private func exitDrawingMode() {
        guard isDrawingMode else { return }
        isDrawingMode = false
        isStroking = false
        activeStrokeTool = nil
        blankScreen = nil
        // Keep the zoom anchored where it was while drawing. The physical mouse
        // moved around the screen while drawing, so warp the (hidden) system
        // cursor back to the frozen anchor. This keeps panning continuous and
        // prevents the view from jumping when leaving drawing mode.
        if let anchor = latestCursorLocation {
            warpCursor(toGlobal: anchor)
        }
        updateLiveZoomInteractivity()
    }

    /// When typing mode ends, the hidden system cursor is wherever the user
    /// moved it to place the caret, so the next mouse move would re-anchor the
    /// view there. This mirrors ZoomIt's `WM_USER_TYPING_OFF` handling:
    ///   * In drawing mode the canvas is frozen, so move the cursor to the
    ///     caret (`cursorRc`) so drawing continues from where the text ended.
    ///   * In static zoom we must restore the cursor to where typing began
    ///     (`textStartPt`) so the zoomed viewport does not recenter on the
    ///     caret. That entry point is the still-frozen `latestCursorLocation`.
    private func anchorCursorAfterTyping() {
        if isDrawingMode {
            guard let caret = annotationController.typingCaret(),
                  let screenPoint = screenLocation(forContentPoint: caret.origin) else { return }
            latestCursorLocation = screenPoint
            warpCursor(toGlobal: screenPoint)
        } else if let anchor = latestCursorLocation {
            // Keep the zoom window anchored where it was before typing.
            warpCursor(toGlobal: anchor)
        }
    }

    private func warpCursor(toGlobal point: CGPoint) {
        guard let primaryHeight = NSScreen.screens.first?.frame.height else { return }
        // NSEvent.mouseLocation uses a bottom-left origin on the primary screen;
        // CGWarpMouseCursorPosition expects a top-left origin, so flip Y.
        CGWarpMouseCursorPosition(CGPoint(x: point.x, y: primaryHeight - point.y))
    }

    /// Converts a point in captured-content space to a global screen location in
    /// NSEvent.mouseLocation coordinates (bottom-left origin on the primary
    /// screen), suitable for `warpCursor(toGlobal:)`.
    private func screenLocation(forContentPoint contentPoint: CGPoint) -> CGPoint? {
        guard let window else { return nil }
        let source = viewportController.sourceRect(for: bounds, cursorLocation: latestCursorLocation)
        let transform = viewportController.contentToDestinationTransform(source: source, destinationBounds: bounds)
        let viewPoint = contentPoint.applying(transform)
        let windowPoint = convert(viewPoint, to: nil)
        return window.convertPoint(toScreen: windowPoint)
    }

    private func hideSystemCursor() {
        guard !cursorHidden else { return }
        NSCursor.hide()
        cursorHidden = true
    }

    private func showSystemCursor() {
        guard cursorHidden else { return }
        NSCursor.unhide()
        cursorHidden = false
    }

    func prepareForClose() {
        stopLiveMouseTracking()
        showSystemCursor()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        // Keep the system cursor hidden the whole time the overlay is on screen so
        // it is invisible while panning and drawing; the pen indicator is drawn
        // separately in drawing mode.
        if window != nil {
            hideSystemCursor()
            updateLiveZoomInteractivity()
        } else {
            stopLiveMouseTracking()
            showSystemCursor()
        }
    }

    /// Live zoom is interactive (click-through, real cursor visible) whenever it
    /// is not in drawing mode, letting the user keep using the system while the
    /// magnified view follows the cursor. Drawing mode (and every other mode)
    /// captures input modally as usual.
    private var isInteractiveLiveZoom: Bool {
        interactionMode == .liveZoom && !isDrawingMode && !isSelectingRegion
    }

    private func updateLiveZoomInteractivity() {
        guard let window else { return }
        let interactive = isInteractiveLiveZoom
        guard interactive != liveZoomClickThrough else { return }
        liveZoomClickThrough = interactive
        if interactive {
            // Pass mouse events through to the apps underneath and show the real
            // cursor; a global monitor keeps the magnified view tracking it.
            window.ignoresMouseEvents = true
            showSystemCursor()
            startLiveMouseTracking()
        } else {
            // Reclaim input so the overlay can draw/pan modally.
            stopLiveMouseTracking()
            window.ignoresMouseEvents = false
            hideSystemCursor()
            NSApp.activate(ignoringOtherApps: true)
            window.makeKeyAndOrderFront(nil)
            window.makeFirstResponder(self)
        }
    }

    private func startLiveMouseTracking() {
        guard liveMouseMonitor == nil else { return }
        liveMouseMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.mouseMoved, .leftMouseDragged, .rightMouseDragged, .otherMouseDragged]
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.handleGlobalMouseMove()
            }
        }
    }

    private func stopLiveMouseTracking() {
        if let liveMouseMonitor {
            NSEvent.removeMonitor(liveMouseMonitor)
        }
        liveMouseMonitor = nil
    }

    private func handleGlobalMouseMove() {
        // Follow the real cursor so the magnified region recenters on it. The
        // source-rect math anchors the point under the cursor to itself, so the
        // content beneath the cursor stays aligned for accurate clicks.
        latestCursorLocation = NSEvent.mouseLocation
        needsDisplay = true
    }

    /// Renders the current viewport (magnified image plus annotations) to a
    /// bitmap and copies it to the clipboard.
    private func copyViewport() {
        guard let image = captureViewportImage() else { return }
        ImageExporter.copyToPasteboard(image)
    }

    /// Renders the current viewport and presents a Save dialog to write it as
    /// PNG.
    private func saveViewport() {
        guard let image = captureViewportImage() else { return }
        presentSavePanelOverOverlay(image)
    }

    /// Presents a Save dialog above the overlay (whose `.screenSaver` level would
    /// otherwise hide it) with the cursor visible, then restores both.
    private func presentSavePanelOverOverlay(_ image: CGImage) {
        let savedLevel = window?.level
        let wasCursorHidden = cursorHidden
        window?.level = NSWindow.Level(rawValue: NSWindow.Level.normal.rawValue - 1)
        if wasCursorHidden { showSystemCursor() }
        ImageExporter.presentSavePanel(for: image)
        if let savedLevel { window?.level = savedLevel }
        if wasCursorHidden { hideSystemCursor() }
    }

    /// Snapshots exactly what the overlay is displaying (magnified image plus
    /// annotations) at the view's backing resolution.
    private func captureViewportImage() -> CGImage? {
        guard let rep = bitmapImageRepForCachingDisplay(in: bounds) else { return nil }
        cacheDisplay(in: bounds, to: rep)
        return rep.cgImage
    }

    // MARK: - Region snip

    /// Begins selecting a rectangle of the current viewport to copy or save.
    func beginRegionSnip(save: Bool, onFinished: @escaping () -> Void) {
        regionSaveToFile = save
        onRegionSnipFinished = onFinished
        regionAnchor = nil
        regionRect = .zero
        isSelectingRegion = true
        // In live zoom this drops click-through so the canvas captures the drag.
        if interactionMode == .liveZoom {
            updateLiveZoomInteractivity()
        }
        showSystemCursor()
        pushRegionCursor()
        needsDisplay = true
    }

    private func updateRegionRect(to point: CGPoint) {
        guard let anchor = regionAnchor else { return }
        regionRect = CGRect(
            x: min(anchor.x, point.x),
            y: min(anchor.y, point.y),
            width: abs(point.x - anchor.x),
            height: abs(point.y - anchor.y)
        )
    }

    private func finishRegionSnip() {
        let rect = regionRect
        let save = regionSaveToFile
        isSelectingRegion = false
        regionRect = .zero
        regionAnchor = nil
        popRegionCursor()

        if rect.width >= 3, rect.height >= 3, let full = captureViewportImage() {
            let scale = window?.backingScaleFactor ?? capturedFrame.display.scaleFactor
            let pixelRect = CGRect(
                x: rect.minX * scale,
                y: rect.minY * scale,
                width: rect.width * scale,
                height: rect.height * scale
            ).integral
            if let cropped = full.cropping(to: pixelRect) {
                if save {
                    presentSavePanelOverOverlay(cropped)
                } else {
                    ImageExporter.copyToPasteboard(cropped)
                }
            }
        }
        endRegionSnip()
    }

    private func cancelRegionSnip() {
        isSelectingRegion = false
        regionRect = .zero
        regionAnchor = nil
        popRegionCursor()
        endRegionSnip()
    }

    private func endRegionSnip() {
        needsDisplay = true
        if interactionMode == .liveZoom {
            updateLiveZoomInteractivity()
        } else {
            hideSystemCursor()
        }
        let callback = onRegionSnipFinished
        onRegionSnipFinished = nil
        callback?()
    }

    private func pushRegionCursor() {
        guard !regionCursorPushed else { return }
        NSCursor.crosshair.push()
        regionCursorPushed = true
    }

    private func popRegionCursor() {
        guard regionCursorPushed else { return }
        NSCursor.pop()
        regionCursorPushed = false
    }

    private func drawRegionSelection(in context: CGContext) {
        let dim = NSColor(white: 0, alpha: 0.45).cgColor
        context.setFillColor(dim)
        guard regionRect.width > 0, regionRect.height > 0 else {
            context.fill(bounds)
            return
        }
        // Dim everything except the selected region (four surrounding rects).
        let b = bounds
        context.fill(CGRect(x: 0, y: 0, width: b.width, height: regionRect.minY))
        context.fill(CGRect(x: 0, y: regionRect.maxY, width: b.width, height: b.height - regionRect.maxY))
        context.fill(CGRect(x: 0, y: regionRect.minY, width: regionRect.minX, height: regionRect.height))
        context.fill(CGRect(x: regionRect.maxX, y: regionRect.minY, width: b.width - regionRect.maxX, height: regionRect.height))

        context.setStrokeColor(NSColor.white.cgColor)
        context.setLineWidth(1)
        context.stroke(regionRect.insetBy(dx: 0.5, dy: 0.5))
    }

    private func drawCursorIndicator(in context: CGContext, source: CGRect) {
        let zoomScale = source.width > 0 ? bounds.width / source.width : 1
        let radius = max(4, annotationController.currentStyle.rootWidth * zoomScale / 2)
        let center = pointerViewPoint
        let rect = CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2)

        context.saveGState()
        context.setFillColor(annotationController.currentStyle.color.nsColor.cgColor)
        context.fillEllipse(in: rect)
        context.restoreGState()
    }
}