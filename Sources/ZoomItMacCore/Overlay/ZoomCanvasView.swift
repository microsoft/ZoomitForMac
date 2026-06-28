import AppKit

@MainActor
final class ZoomCanvasView: NSView {
    private let capturedFrame: CapturedFrame
    private let viewportController: ZoomViewportController
    private let annotationController: AnnotationController
    private let commandSink: (AppCommand) -> Void
    private var latestCursorLocation: CGPoint?
    private var pointerViewPoint: CGPoint = .zero
    private var isDrawingMode = false
    private var isStroking = false
    private var cursorHidden = false
    private var tabHeld = false

    var interactionMode: AppMode = .staticZoom {
        didSet {
            if interactionMode == .typing {
                exitDrawingMode()
            }
        }
    }

    init(
        frame frameRect: CGRect,
        capturedFrame: CapturedFrame,
        viewportController: ZoomViewportController,
        annotationController: AnnotationController,
        commandSink: @escaping (AppCommand) -> Void
    ) {
        self.capturedFrame = capturedFrame
        self.viewportController = viewportController
        self.annotationController = annotationController
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

    override var acceptsFirstResponder: Bool { true }

    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }

        context.interpolationQuality = .high
        context.setFillColor(NSColor.black.cgColor)
        context.fill(bounds)

        let source = viewportController.sourceRect(for: bounds, cursorLocation: latestCursorLocation)
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

        context.saveGState()
        context.concatenate(viewportController.contentToDestinationTransform(source: source, destinationBounds: bounds))
        annotationController.render(in: context, bounds: bounds)
        context.restoreGState()

        if isDrawingMode {
            drawCursorIndicator(in: context, source: source)
        }
    }

    override func mouseMoved(with event: NSEvent) {
        pointerViewPoint = convert(event.locationInWindow, from: nil)
        if !isDrawingMode && interactionMode != .typing {
            latestCursorLocation = NSEvent.mouseLocation
        }
        needsDisplay = true
    }

    override func mouseDown(with event: NSEvent) {
        pointerViewPoint = convert(event.locationInWindow, from: nil)

        if interactionMode == .typing {
            annotationController.setInsertionPoint(contentPoint(for: event))
            needsDisplay = true
            return
        }

        guard isDrawingMode else {
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
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        pointerViewPoint = convert(event.locationInWindow, from: nil)
        if isDrawingMode && isStroking {
            annotationController.update(at: contentPoint(for: event))
        }
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        pointerViewPoint = convert(event.locationInWindow, from: nil)
        if isDrawingMode && isStroking {
            annotationController.end(at: contentPoint(for: event))
            isStroking = false
        }
        needsDisplay = true
    }

    override func rightMouseDown(with event: NSEvent) {
        if isDrawingMode {
            // Right click leaves drawing mode and returns to pannable zoom.
            exitDrawingMode()
            needsDisplay = true
        } else {
            commandSink(.exit)
        }
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

        let delta = event.scrollingDeltaY > 0 ? 1.1 : 1 / 1.1
        viewportController.setZoomFactor(viewportController.zoomFactor * delta)
        needsDisplay = true
    }

    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 53:
            commandSink(.exit)
        case 126:
            handleVerticalArrow(up: true, shift: event.modifierFlags.contains(.shift))
        case 125:
            handleVerticalArrow(up: false, shift: event.modifierFlags.contains(.shift))
        case 48 where interactionMode != .typing:
            tabHeld = true
        case 6 where event.modifierFlags.contains(.command):
            commandSink(.undo)
        case 8 where event.modifierFlags.contains(.command):
            commandSink(.clear)
        case 51 where interactionMode == .typing, 117 where interactionMode == .typing:
            annotationController.deleteBackward()
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
        case "w": commandSink(.setColor(.white))
        case "k": commandSink(.setColor(.black))
        case "f": commandSink(.setTool(.pen))
        case "l": commandSink(.setTool(.line))
        case "a": commandSink(.setTool(.arrow))
        case "e": commandSink(.setTool(.ellipse))
        case "h": commandSink(.setTool(.highlighter))
        case "t": commandSink(.toggleTyping)
        case "[": commandSink(.decreasePenWidth)
        case "]": commandSink(.increasePenWidth)
        default: return nil
        }

        needsDisplay = true
        return ()
    }

    override func keyUp(with event: NSEvent) {
        if event.keyCode == 48 {
            tabHeld = false
        }
    }

    private func contentPoint(for event: NSEvent) -> CGPoint {
        let viewPoint = convert(event.locationInWindow, from: nil)
        return viewportController.contentPoint(for: viewPoint, destinationBounds: bounds, cursorLocation: latestCursorLocation)
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
        if tabHeld { return .ellipse }
        return nil
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
    }

    private func exitDrawingMode() {
        guard isDrawingMode else { return }
        isDrawingMode = false
        isStroking = false
        // Keep the zoom anchored where it was while drawing. The physical mouse
        // moved around the screen while drawing, so warp the (hidden) system
        // cursor back to the frozen anchor. This keeps panning continuous and
        // prevents the view from jumping when leaving drawing mode.
        if let anchor = latestCursorLocation {
            warpCursor(toGlobal: anchor)
        }
    }

    private func warpCursor(toGlobal point: CGPoint) {
        guard let primaryHeight = NSScreen.screens.first?.frame.height else { return }
        // NSEvent.mouseLocation uses a bottom-left origin on the primary screen;
        // CGWarpMouseCursorPosition expects a top-left origin, so flip Y.
        CGWarpMouseCursorPosition(CGPoint(x: point.x, y: primaryHeight - point.y))
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
        showSystemCursor()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        // Keep the system cursor hidden the whole time the overlay is on screen so
        // it is invisible while panning and drawing; the pen indicator is drawn
        // separately in drawing mode.
        if window != nil {
            hideSystemCursor()
        } else {
            showSystemCursor()
        }
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