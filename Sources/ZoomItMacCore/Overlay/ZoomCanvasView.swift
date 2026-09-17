import AppKit
import QuartzCore

@MainActor
enum OverlayPresentedWindowLifecycle {
    static func perform(
        prepareAccessories: () -> Void,
        showSystemCursor: () -> Void,
        present: () -> Void,
        restoreAccessories: () -> Void,
        reapplyCursorPolicy: () -> Void
    ) {
        prepareAccessories()
        showSystemCursor()
        defer {
            restoreAccessories()
            reapplyCursorPolicy()
        }
        present()
    }
}

enum ZoomCanvasCapturePolicy: Equatable {
    case stillImage
    case recording

    var includesInProgressAnnotations: Bool {
        self == .recording
    }

    var includesSmartDrawPreview: Bool {
        self == .recording
    }

    var includesEditorChrome: Bool {
        false
    }

    var includesTransientEraserFeedback: Bool {
        false
    }

    var freehandPresentationOwner: AnnotationFreehandPresentationOwner {
        .canonicalRenderer
    }

    var includesImmediateFreehandLayers: Bool {
        false
    }
}

enum DrawingSelectionShortcut {
    static func arrangeAction(
        key: String,
        command: Bool,
        option: Bool,
        shift: Bool
    ) -> AnnotationArrangeAction? {
        guard command else { return nil }
        switch key {
        case "]":
            return option || shift ? .bringToFront : .bringForward
        case "[":
            return option || shift ? .sendToBack : .sendBackward
        default:
            return nil
        }
    }
}

struct DrawingFreehandFrameInvalidationState: Equatable {
    private(set) var invalidationCount = 0
    private var pending = false

    mutating func noteInput() {
        pending = true
    }

    mutating func beginFrame() -> Bool {
        guard pending else { return false }
        pending = false
        invalidationCount += 1
        return true
    }
}

struct DrawingLatestRawPointerLane: Equatable {
    static let maximumSampleCount = 24
    static let maximumDuration: TimeInterval = 0.05

    private(set) var recentSamples: [AnnotationRawFreehandInput] = []
    private(set) var latestRawPointer: AnnotationRawFreehandInput?

    mutating func update(_ input: AnnotationRawFreehandInput) {
        latestRawPointer = input
        if let last = recentSamples.last,
           last.location == input.location,
           last.timestamp == input.timestamp {
            recentSamples[recentSamples.count - 1] = input
        } else if recentSamples.count >= 2,
                  Self.canReplaceMiddle(
                      previous: recentSamples[recentSamples.count - 2],
                      middle: recentSamples[recentSamples.count - 1],
                      next: input
                  ) {
            recentSamples[recentSamples.count - 1] = input
        } else {
            recentSamples.append(input)
        }

        if input.timestamp.isFinite {
            let cutoff = input.timestamp - Self.maximumDuration
            if let firstRecent = recentSamples.firstIndex(where: {
                !$0.timestamp.isFinite || $0.timestamp >= cutoff
            }), firstRecent > 0 {
                recentSamples.removeSubrange(0..<firstRecent)
            }
        }
        if recentSamples.count > Self.maximumSampleCount {
            recentSamples.removeFirst(
                recentSamples.count - Self.maximumSampleCount
            )
        }
    }

    mutating func clear() {
        recentSamples.removeAll(keepingCapacity: true)
        latestRawPointer = nil
    }

    func samples(after timestamp: TimeInterval?) -> [AnnotationRawFreehandInput] {
        guard let timestamp else { return recentSamples }
        return recentSamples.filter {
            !$0.timestamp.isFinite || $0.timestamp > timestamp
        }
    }

    private static func canReplaceMiddle(
        previous: AnnotationRawFreehandInput,
        middle: AnnotationRawFreehandInput,
        next: AnnotationRawFreehandInput
    ) -> Bool {
        let incoming = CGPoint(
            x: middle.location.x - previous.location.x,
            y: middle.location.y - previous.location.y
        )
        let outgoing = CGPoint(
            x: next.location.x - middle.location.x,
            y: next.location.y - middle.location.y
        )
        let incomingLength = hypot(incoming.x, incoming.y)
        let outgoingLength = hypot(outgoing.x, outgoing.y)
        guard incomingLength > 0.000_1, outgoingLength > 0.000_1 else {
            return true
        }
        let cosine = (
            incoming.x * outgoing.x + incoming.y * outgoing.y
        ) / (incomingLength * outgoingLength)
        guard cosine > 0.985 else { return false }
        guard let middlePressure = middle.pressure else { return true }
        let previousPressure = previous.pressure ?? middlePressure
        let nextPressure = next.pressure ?? middlePressure
        return middlePressure >= min(previousPressure, nextPressure)
            && middlePressure <= max(previousPressure, nextPressure)
    }
}

enum DrawingImmediateFreehandPresentationPolicy {
    static func viewPoint(
        forContentPoint point: CGPoint,
        source: CGRect,
        destinationBounds: CGRect
    ) -> CGPoint {
        guard source.width > 0, source.height > 0 else { return .zero }
        return CGPoint(
            x: destinationBounds.minX
                + ((point.x - source.minX) / source.width)
                    * destinationBounds.width,
            y: destinationBounds.minY
                + ((point.y - source.minY) / source.height)
                    * destinationBounds.height
        )
    }

    static func contentPoint(
        forViewPoint point: CGPoint,
        source: CGRect,
        destinationBounds: CGRect
    ) -> CGPoint {
        guard destinationBounds.width > 0,
              destinationBounds.height > 0 else {
            return .zero
        }
        return CGPoint(
            x: source.minX
                + ((point.x - destinationBounds.minX) / destinationBounds.width)
                    * source.width,
            y: source.minY
                + ((point.y - destinationBounds.minY) / destinationBounds.height)
                    * source.height
        )
    }

    static func showsStandalonePointer(
        hasMoved: Bool,
        tailPointCount: Int
    ) -> Bool {
        !hasMoved && tailPointCount <= 1
    }

    static func immediateTipComponentCount(
        tailPointCount: Int,
        showsStandalonePointer: Bool
    ) -> Int {
        (tailPointCount > 1 ? 1 : 0) + (showsStandalonePointer ? 1 : 0)
    }
}

@MainActor
final class ZoomCanvasView: NSView {
    static let maximumFreehandEventsPerUpdate = 1

    private var capturedFrame: CapturedFrame
    private let viewportController: ZoomViewportController
    private let annotationController: AnnotationController
    private let userSelectedResourceAccess: UserSelectedResourceAccess
    private let commandSink: (AppCommand) -> Void
    private let drawingModeDidChange: (Bool) -> Void
    private let transientToolDidChange: (AnnotationTool?) -> Void
    private let modalPresentationDidChange: (Bool) -> Void
    private let captureCompositor:
        (CGImage, CGRect, CGRect, CGSize) -> CGImage?
    private var latestCursorLocation: CGPoint?
    private var pointerViewPoint: CGPoint = .zero
    private var mouseLocationOverrideForTesting: CGPoint?
    private var isDrawingMode = false
    private var isStroking = false
    private var isHandPanning = false
    private var mouseCoalescingRestoreValue: Bool?
    private var freehandDisplayLink: CADisplayLink?
    private var latestRawPointerLane = DrawingLatestRawPointerLane()
    private var hasImmediateFreehandMovement = false
    private let immediateFreehandTailLayer = CAShapeLayer()
    private let immediateFreehandPointerLayer = CAShapeLayer()
    private var freehandInvalidationState = DrawingFreehandFrameInvalidationState()
    private var isDrawingAccessoryInteractionActive = false
    /// The tool of the in-progress stroke, used to hide the pen cursor while a
    /// shape (line/arrow/rectangle/ellipse) is being dragged out.
    private var activeStrokeTool: AnnotationTool?
    private struct LinearPointerGesture {
        var downViewPoint: CGPoint
        var downContentPoint: CGPoint
        var continuedConstruction: Bool
        var dragThresholdExceeded = false
    }
    private var linearPointerGesture: LinearPointerGesture?
    private var isOverLinearFinishHandle = false
    private var ownsHiddenSystemCursor = false
    private var postTypingCursorAnchorOffset: CGPoint?
    private var lastReportedDrawingAccessoryActive: Bool?
    /// While interactive live zoom is on, the overlay is click-through and a
    /// global monitor tracks the real cursor so the magnified view follows it.
    private var liveMouseMonitor: Any?
    private var drawingRightClickMonitor: Any?
    private var drawingGlobalRightClickMonitor: Any?
    private var suppressNextSelectionRightMouseUp = false
    private var capturePolicy: ZoomCanvasCapturePolicy?
    private var liveZoomClickThrough = false
    /// Region-snip state: while active, a drag selects a rectangle of the
    /// current viewport to copy or save.
    private var isSelectingRegion = false
    private var regionAction: SnipAction = .copyImage
    private var regionAnchor: CGPoint?
    private var regionRect: CGRect = .zero
    private var regionCursorLease: CrosshairCursorLease?
    private var onRegionSnipFinished: (() -> Void)?
    private var scrollZoomAccumulator: CGFloat = 0
    private var resumeDrawingAfterTyping = false
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

    var hasPendingAnnotationInputForTesting: Bool {
        freehandDisplayLink != nil || isStroking
    }

    var hasActiveFreehandDrainTimerForTesting: Bool {
        freehandDisplayLink != nil
    }

    var latestRawPointerForTesting: AnnotationRawFreehandInput? {
        latestRawPointerLane.latestRawPointer
    }

    var interactionMode: AppMode = .staticZoom {
        didSet {
            let leftTypingMode = oldValue == .typing && interactionMode != .typing
            if leftTypingMode {
                anchorCursorAfterTyping()
            }
            switch interactionMode {
            case .typing:
                let wasDrawing = isDrawingMode
                resumeDrawingAfterTyping = wasDrawing
                exitDrawingMode(restoreCursor: false)
            case .drawOnly:
                // Draw-without-zoom starts already in drawing mode so the first
                // click begins a stroke immediately. Returning from typing also
                // restores the drawn cursor, but without warping through the old
                // zoom anchor.
                if leftTypingMode {
                    resumeDrawingAfterTyping = false
                }
                enterDrawingMode()
            default:
                if leftTypingMode, resumeDrawingAfterTyping {
                    resumeDrawingAfterTyping = false
                    enterDrawingMode()
                }
                break
            }
            updateLiveZoomInteractivity()
            applyCursorPolicy()
            reportDrawingAccessoryLifecycle()
            needsDisplay = true
        }
    }

    init(
        frame frameRect: CGRect,
        capturedFrame: CapturedFrame,
        viewportController: ZoomViewportController,
        annotationController: AnnotationController,
        smoothImage: Bool,
        userSelectedResourceAccess: UserSelectedResourceAccess,
        commandSink: @escaping (AppCommand) -> Void,
        drawingModeDidChange: @escaping (Bool) -> Void = { _ in },
        transientToolDidChange: @escaping (AnnotationTool?) -> Void = { _ in },
        modalPresentationDidChange: @escaping (Bool) -> Void = { _ in },
        captureCompositor: @escaping
            (CGImage, CGRect, CGRect, CGSize) -> CGImage? = {
                baseImage,
                displayFrame,
                sourceRegion,
                outputPixelSize in
                CaptureAccessoryCompositor.compose(
                    baseImage: baseImage,
                    displayFrame: displayFrame,
                    sourceRegion: sourceRegion,
                    outputPixelSize: outputPixelSize,
                    accessories: []
                )
            }
    ) {
        self.capturedFrame = capturedFrame
        self.viewportController = viewportController
        self.annotationController = annotationController
        self.smoothImage = smoothImage
        self.userSelectedResourceAccess = userSelectedResourceAccess
        self.commandSink = commandSink
        self.drawingModeDidChange = drawingModeDidChange
        self.transientToolDidChange = transientToolDidChange
        self.modalPresentationDidChange = modalPresentationDidChange
        self.captureCompositor = captureCompositor
        super.init(frame: frameRect)
        // Anchor the initial zoom on the current cursor position so the view
        // does not jump when the mouse first moves after the hotkey activates.
        latestCursorLocation = NSEvent.mouseLocation
        wantsLayer = true
        configureImmediateFreehandLayers()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func layout() {
        super.layout()
        immediateFreehandTailLayer.frame = bounds
        immediateFreehandPointerLayer.frame = bounds
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

        context.saveGState()
        defer { context.restoreGState() }
        context.clip(to: dirtyRect)
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
        let includesInProgressAnnotations =
            capturePolicy?.includesInProgressAnnotations ?? true
        let includesSmartDrawPreview =
            capturePolicy?.includesSmartDrawPreview ?? true
        let includesEditorChrome = capturePolicy?.includesEditorChrome ?? true
        let freehandPresentationOwner =
            capturePolicy?.freehandPresentationOwner
            ?? (latestRawPointerLane.latestRawPointer == nil
                ? .canonicalRenderer
                : .immediateLayers)
        annotationController.render(
            in: context,
            bounds: bounds,
            destinationPointScale: zoomScale(for: source),
            includeSmartDrawPreview: includesSmartDrawPreview,
            includeInProgress: includesInProgressAnnotations,
            includeEditorChrome: includesEditorChrome,
            includeTransientEraserFeedback:
                capturePolicy?.includesTransientEraserFeedback ?? true,
            freehandPresentationOwner: freehandPresentationOwner
        )
        if isDrawingMode,
           annotationController.currentTool == .select,
           includesEditorChrome {
            annotationController.renderSelectionDecorations(
                in: context,
                zoomScale: zoomScale(for: source)
            )
        }
        if DrawingTextCaretPolicy.shouldDrawInsertionCaret(
            interactionMode: interactionMode,
            isTextInsertionActive: annotationController.isTypingLocked,
            isAccessoryInteractionActive: isDrawingAccessoryInteractionActive
        ) && includesEditorChrome {
            drawTypingCaret(in: context)
        }
        context.restoreGState()

        if isDrawingMode
            && includesEditorChrome
            && drawsCursorIndicator(annotationController.currentTool)
            && !isDrawingAccessoryInteractionActive
            && !isDrawingShapeStroke
            && latestRawPointerLane.latestRawPointer == nil
            && !annotationController.isConstructingLinearPath {
            drawCursorIndicator(in: context, source: source)
        }

        if isSelectingRegion && includesEditorChrome {
            drawRegionSelection(in: context)
        }
    }

    /// True while the user is actively dragging out a shape, where the pen dot
    /// would just clutter the shape being drawn.
    private var isDrawingShapeStroke: Bool {
        guard isStroking, let tool = activeStrokeTool else { return false }
        switch tool {
        case .line, .arrow, .rectangle, .diamond, .ellipse:
            return true
        default:
            return false
        }
    }

    override func mouseMoved(with event: NSEvent) {
        pointerViewPoint = convert(event.locationInWindow, from: nil)
        if interactionMode == .typing {
            postTypingCursorAnchorOffset = nil
            // Before text exists, the native I-beam is the only pointer
            // indicator and the prospective insertion point follows it.
            if !annotationController.isTypingLocked {
                let insertion = contentPoint(forViewPoint: pointerViewPoint)
                annotationController.setInsertionPoint(insertion)
            }
        } else if !isDrawingMode {
            updateLatestCursorLocationFromMouse()
        } else if annotationController.isConstructingLinearPath {
            annotationController.updateLinearConstructionPreview(
                at: contentPoint(forViewPoint: pointerViewPoint),
                zoomScale: currentAnnotationZoomScale
            )
        }
        updateLinearFinishHandleHover()
        applyCursorPolicy()
        needsDisplay = true
    }

    override func mouseDown(with event: NSEvent) {
        // Some devices/contexts deliver a right-click over this overlay as a
        // leftMouseDown carrying buttonNumber 1 (the secondary button) rather
        // than a rightMouseDown. Route the secondary button to the right-click
        // handler so it still exits drawing mode.
        if event.buttonNumber == 1 {
            rightMouseDown(with: event)
            return
        }
        pointerViewPoint = convert(event.locationInWindow, from: nil)

        if isSelectingRegion {
            regionAnchor = pointerViewPoint
            regionRect = .zero
            needsDisplay = true
            return
        }

        if interactionMode == .typing {
            if annotationController.isTypingLocked {
                finishLockedTypingAtCaret(reason: "mouse down locked")
                needsDisplay = true
                return
            }
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

        switch annotationController.currentTool {
        case .hand:
            isHandPanning = true
            applyCursorPolicy()
            return
        case .eraser:
            annotationController.beginErasing(
                at: contentPoint(for: event),
                zoomScale: currentAnnotationZoomScale
            )
            isStroking = true
            activeStrokeTool = .eraser
            return
        case .text:
            let insertionPoint = contentPoint(for: event)
            commandSink(
                .toggleTyping(
                    rightAligned: false,
                    insertionPoint: insertionPoint
                )
            )
            return
        case .select:
            let outcome = annotationController.beginSelectionInteraction(
                at: contentPoint(for: event),
                zoomScale: currentAnnotationZoomScale,
                modifiers: editorModifiers(from: event),
                clickCount: event.clickCount
            )
            if case .beginTextEditing(let elementID) = outcome {
                commandSink(.editText(elementID))
            }
            needsDisplay = true
            return
        default:
            break
        }

        let gestureTool = gestureTool(for: event)
        let tool = gestureTool ?? annotationController.currentTool
        let point = contentPoint(for: event)
        if gestureTool != nil, annotationController.isConstructingLinearPath {
            annotationController.resolveLinearConstructionForExit()
        }
        if gestureTool == nil,
           (tool == .line || tool == .arrow),
           annotationController.isConstructingLinearPath {
            annotationController.updateLinearConstructionPreview(
                at: point,
                zoomScale: currentAnnotationZoomScale
            )
            linearPointerGesture = LinearPointerGesture(
                downViewPoint: pointerViewPoint,
                downContentPoint: point,
                continuedConstruction: true
            )
            isStroking = true
            activeStrokeTool = tool
            updateLinearFinishHandleHover()
            applyCursorPolicy()
            needsDisplay = true
            return
        }
        annotationController.setInsertionPoint(point)
        beginHighFidelityFreehandInput(for: tool)
        let pressure = annotationPressure(from: event)
        annotationController.begin(
            at: point,
            tool: tool,
            pressure: pressure,
            legacyModifierGesture: gestureTool == .line || gestureTool == .arrow,
            timestamp: event.timestamp,
            zoomScale: currentAnnotationZoomScale
        )
        if tool == .pen || tool == .highlighter {
            updateImmediateFreehandPresentation(
                with: AnnotationRawFreehandInput(
                    location: point,
                    pressure: pressure,
                    timestamp: event.timestamp
                )
            )
        }
        isStroking = true
        activeStrokeTool = tool
        linearPointerGesture = gestureTool == nil && (tool == .line || tool == .arrow)
            ? LinearPointerGesture(
                downViewPoint: pointerViewPoint,
                downContentPoint: point,
                continuedConstruction: false
            )
            : nil
        transientToolDidChange(tool == annotationController.currentTool ? nil : tool)
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
            if var gesture = linearPointerGesture,
               !gesture.continuedConstruction,
               Self.linearDragThresholdExceeded(
                   previouslyExceeded: gesture.dragThresholdExceeded,
                   from: gesture.downViewPoint,
                   to: pointerViewPoint
               ) {
                gesture.dragThresholdExceeded = true
                linearPointerGesture = gesture
            }
            if activeStrokeTool == .eraser {
                annotationController.continueErasing(
                    at: contentPoint(for: event),
                    zoomScale: currentAnnotationZoomScale
                )
            } else if linearPointerGesture?.continuedConstruction == true {
                annotationController.updateLinearConstructionPreview(
                    at: contentPoint(for: event),
                    zoomScale: currentAnnotationZoomScale
                )
            } else if activeStrokeTool == .pen || activeStrokeTool == .highlighter {
                let input = freehandInput(from: event)
                updateImmediateFreehandPresentation(with: input)
                annotationController.enqueueFreehandInputs(
                    [input]
                )
                freehandInvalidationState.noteInput()
                scheduleFreehandDrain()
                return
            } else {
                annotationController.update(
                    at: contentPoint(for: event),
                    pressure: annotationPressure(from: event),
                    timestamp: event.timestamp,
                    zoomScale: currentAnnotationZoomScale,
                    constrainShapeAspect: shouldConstrainShapeAspect(for: event)
                )
            }
            updateLinearFinishHandleHover()
        } else if isDrawingMode && isHandPanning {
            latestCursorLocation = NSEvent.mouseLocation
            NSCursor.closedHand.set()
        } else if isDrawingMode && annotationController.currentTool == .select {
            annotationController.updateSelectionInteraction(
                to: contentPoint(for: event),
                modifiers: editorModifiers(from: event)
            )
        }
        needsDisplay = true
    }

    private func freehandInput(from event: NSEvent) -> AnnotationRawFreehandInput {
        AnnotationRawFreehandInput(
            location: contentPoint(for: event),
            pressure: annotationPressure(from: event),
            timestamp: event.timestamp
        )
    }

    static func orderedUniqueFreehandInputs(
        coalesced: [AnnotationRawFreehandInput],
        current: AnnotationRawFreehandInput
    ) -> [AnnotationRawFreehandInput] {
        (coalesced + [current]).reduce(into: []) { result, input in
            if let last = result.last,
               last.location == input.location,
               last.timestamp == input.timestamp {
                result[result.count - 1] = input
            } else {
                result.append(input)
            }
        }
    }

    override func mouseUp(with event: NSEvent) {
        if event.buttonNumber == 1 {
            rightMouseUp(with: event)
            return
        }
        pointerViewPoint = convert(event.locationInWindow, from: nil)
        if isSelectingRegion {
            finishRegionSnip()
            return
        }
        if isDrawingMode && isStroking {
            if activeStrokeTool == .eraser {
                annotationController.endErasing()
            } else if activeStrokeTool == .pen || activeStrokeTool == .highlighter {
                let input = freehandInput(from: event)
                updateImmediateFreehandPresentation(with: input)
                annotationController.enqueueFreehandInputs([input])
                _ = annotationController.finishQueuedFreehandBounded(
                    endingPressure: input.pressure,
                    timestamp: input.timestamp,
                    zoomScale: currentAnnotationZoomScale
                )
                freehandInvalidationState.noteInput()
                stopFreehandDrainTimer()
                clearImmediateFreehandPresentation()
                needsDisplay = true
                displayIfNeeded()
            } else if let gesture = linearPointerGesture {
                let contentPoint = contentPoint(for: event)
                if gesture.continuedConstruction {
                    annotationController.updateLinearConstructionPreview(
                        at: contentPoint,
                        zoomScale: currentAnnotationZoomScale
                    )
                    let hitFinishHandle = annotationController.isLinearConstructionFinishHandle(
                        at: contentPoint,
                        zoomScale: currentAnnotationZoomScale
                    )
                    if event.clickCount >= 2 {
                        if !hitFinishHandle {
                            _ = annotationController.commitLinearConstructionPoint(
                                at: contentPoint,
                                zoomScale: currentAnnotationZoomScale
                            )
                        }
                        _ = annotationController.finishLinearConstruction(commitPreview: false)
                    } else if hitFinishHandle {
                        _ = annotationController.finishLinearConstruction(commitPreview: false)
                    } else {
                        _ = annotationController.commitLinearConstructionPoint(
                            at: contentPoint,
                            zoomScale: currentAnnotationZoomScale
                        )
                    }
                } else if gesture.dragThresholdExceeded
                    || Self.shouldTreatLinearCreationAsDrag(
                        from: gesture.downViewPoint,
                        to: pointerViewPoint
                    ) {
                    annotationController.end(
                        at: contentPoint,
                        pressure: annotationPressure(from: event),
                        timestamp: event.timestamp,
                        zoomScale: currentAnnotationZoomScale
                    )
                } else {
                    annotationController.beginLinearConstructionFromClick(
                        at: gesture.downContentPoint,
                        zoomScale: currentAnnotationZoomScale
                    )
                    annotationController.updateLinearConstructionPreview(
                        at: contentPoint,
                        zoomScale: currentAnnotationZoomScale
                    )
                }
            } else {
                annotationController.end(
                    at: contentPoint(for: event),
                    pressure: annotationPressure(from: event),
                    timestamp: event.timestamp,
                    zoomScale: currentAnnotationZoomScale,
                    constrainShapeAspect: shouldConstrainShapeAspect(for: event)
                )
            }
            restoreMouseCoalescingIfNeeded()
            isStroking = false
            activeStrokeTool = nil
            linearPointerGesture = nil
            transientToolDidChange(nil)
            updateLinearFinishHandleHover()
            applyCursorPolicy()
        } else if isDrawingMode && isHandPanning {
            isHandPanning = false
            applyCursorPolicy()
        } else if isDrawingMode && annotationController.currentTool == .select {
            annotationController.endSelectionInteraction(
                at: contentPoint(for: event),
                modifiers: editorModifiers(from: event)
            )
        }
        needsDisplay = true
    }

    override func rightMouseDown(with event: NSEvent) {
        pointerViewPoint = convert(event.locationInWindow, from: nil)
        if interactionMode == .typing {
            if annotationController.isTypingLocked {
                finishLockedTypingAtCaret(reason: "right mouse locked")
            } else {
                // Caret mode with nothing typed yet: return to pan/zoom mode.
                commandSink(.toggleTyping(rightAligned: false))
            }
            needsDisplay = true
            return
        }

        if isDrawingMode {
            if annotationController.currentTool == .select,
               presentSelectionContextMenu(with: event) {
                return
            }
            // Right click leaves drawing mode and returns to the current
            // overlay mode; it does not exit ZoomIt.
            leaveDrawingModeFromRightClick()
            return
        }
        // Right click no longer exits the overlay; use Esc or zoom out to 1x.
    }

    override func rightMouseUp(with event: NSEvent) {
        pointerViewPoint = convert(event.locationInWindow, from: nil)
        if suppressNextSelectionRightMouseUp {
            suppressNextSelectionRightMouseUp = false
            return
        }
        leaveDrawingModeFromRightClick()
    }

    override func otherMouseDown(with event: NSEvent) {
        pointerViewPoint = convert(event.locationInWindow, from: nil)
        leaveDrawingModeFromRightClick()
    }

    override func otherMouseUp(with event: NSEvent) {
        pointerViewPoint = convert(event.locationInWindow, from: nil)
        leaveDrawingModeFromRightClick()
    }

    override func scrollWheel(with event: NSEvent) {
        if interactionMode == .typing {
            if event.scrollingDeltaY > 0 {
                commandSink(.increaseFontSize)
            } else if event.scrollingDeltaY < 0 {
                commandSink(.decreaseFontSize)
            }
            needsDisplay = true
            return
        }

        if isDrawingMode && annotationController.currentTool != .hand {
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
        if interactionMode != .typing,
           isDrawingMode,
           annotationController.isConstructingLinearPath {
            if event.keyCode == 53 {
                annotationController.cancelLinearConstruction()
                updateLinearFinishHandleHover()
                applyCursorPolicy()
                needsDisplay = true
                return
            }
            if event.keyCode == 36 || event.keyCode == 76 {
                _ = annotationController.finishLinearConstruction(commitPreview: true)
                updateLinearFinishHandleHover()
                applyCursorPolicy()
                needsDisplay = true
                return
            }
        }
        if interactionMode != .typing,
           isDrawingMode,
           annotationController.currentTool == .select,
           handleSelectionKeyDown(event) {
            needsDisplay = true
            return
        }
        if let command = DrawingToolShortcuts.numericCommand(
            characters: event.charactersIgnoringModifiers ?? event.characters,
            keyCode: event.keyCode,
            modifierFlags: event.modifierFlags,
            isDrawingMode: isDrawingMode,
            isTyping: interactionMode == .typing
        ) {
            commandSink(command)
            applyCursorPolicy()
            needsDisplay = true
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
        case 6 where event.modifierFlags.contains(.command) && event.modifierFlags.contains(.shift):
            commandSink(.redo)
        case 6 where event.modifierFlags.contains(.command) || event.modifierFlags.contains(.control):
            // ⌘Z (macOS convention) or Ctrl+Z (matching Windows ZoomIt) undoes the last gesture.
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

    private func handleSelectionKeyDown(_ event: NSEvent) -> Bool {
        let modifiers = event.modifierFlags
        let command = modifiers.contains(.command)
        let shift = modifiers.contains(.shift)
        let option = modifiers.contains(.option)
        let key = event.charactersIgnoringModifiers?.lowercased()

        if event.keyCode == 53 {
            if annotationController.isEditingLinearPoints {
                commandSink(.toggleLinearPointEditing)
                return true
            }
            if annotationController.editorStateKind != .idle || annotationController.hasSelection {
                annotationController.clearSelection()
                return true
            }
            return false
        }

        if event.keyCode == 51 || event.keyCode == 117 {
            if annotationController.isEditingLinearPoints {
                commandSink(.removeLinearPoints)
            } else {
                commandSink(.deleteSelection)
            }
            return true
        }

        if event.keyCode == 36 || event.keyCode == 76 {
            commandSink(.toggleLinearPointEditing)
            return true
        }

        if option {
            if let route = AnnotationLinearRoute.route(
                forOptionShortcut: key
            ) {
                commandSink(.setLinearRoute(route))
                return true
            }
            if key == "b", command {
                commandSink(.unbindLinearEndpoints)
                return true
            }
        }

        if annotationController.isEditingLinearPoints, key == "i" {
            commandSink(.insertLinearPoint)
            return true
        }

        if command {
            switch key {
            case "a":
                commandSink(.selectAllAnnotations)
            case "d":
                commandSink(
                    .duplicateSelection(
                        destinationOffset: AppCommand.defaultDuplicateDestinationOffset
                    )
                )
            case "g":
                if shift {
                    commandSink(.ungroupSelection)
                } else {
                    commandSink(.groupSelection)
                }
            case "l" where shift:
                commandSink(.toggleSelectionLock)
            case let key? where DrawingSelectionShortcut.arrangeAction(
                key: key,
                command: command,
                option: option,
                shift: shift
            ) != nil:
                commandSink(
                    .arrangeSelection(
                        DrawingSelectionShortcut.arrangeAction(
                            key: key,
                            command: command,
                            option: option,
                            shift: shift
                        )!
                    )
                )
            default:
                return false
            }
            return true
        }

        if let delta = Self.selectionNudge(
            keyCode: event.keyCode,
            shift: shift,
            hasMovableSelection: annotationController.hasMovableSelection
        ) {
            annotationController.moveSelection(by: delta)
            return true
        }
        return false
    }

    private func handleDrawingShortcut(_ event: NSEvent) -> Void? {
        guard let key = event.charactersIgnoringModifiers?.lowercased() else { return nil }
        let shift = event.modifierFlags.contains(.shift)
        let control = event.modifierFlags.contains(.control)

        if let command = DrawingToolShortcuts.legacyCommand(
            characters: key,
            shift: shift
        ) {
            if case .toggleTyping(let rightAligned, _) = command {
                let insertionPoint = typingInsertionPointForCurrentPointer()
                commandSink(
                    .toggleTyping(
                        rightAligned: rightAligned,
                        insertionPoint: insertionPoint
                    )
                )
            } else {
                commandSink(command)
            }
            applyCursorPolicy()
            needsDisplay = true
            return ()
        }

        switch key {
        case "r": commandSink(shift ? .setHighlightColor(.red) : .setColor(.red))
        case "g": commandSink(shift ? .setHighlightColor(.green) : .setColor(.green))
        case "b": commandSink(shift ? .setHighlightColor(.blue) : .setColor(.blue))
        case "y": commandSink(shift ? .setHighlightColor(.yellow) : .setColor(.yellow))
        case "o": commandSink(shift ? .setHighlightColor(.orange) : .setColor(.orange))
        case "p": commandSink(shift ? .setHighlightColor(.pink) : .setColor(.pink))
        case "w":
            // Ctrl+W blanks the screen white as a sketch pad (matches the Draw
            // tab help); Shift+W selects the white highlighter; plain W selects
            // the white pen.
            switch Self.whiteBlackKeyAction(control: control, shift: shift, isDrawingMode: isDrawingMode) {
            case .blankScreen: toggleBlankScreen(.white)
            case .highlightColor: commandSink(.setHighlightColor(.white))
            case .penColor: commandSink(.setColor(.white))
            }
        case "k":
            switch Self.whiteBlackKeyAction(control: control, shift: shift, isDrawingMode: isDrawingMode) {
            case .blankScreen: toggleBlankScreen(.black)
            case .highlightColor: commandSink(.setHighlightColor(.black))
            case .penColor: commandSink(.setColor(.black))
            }
        case "e":
            // E erases all drawing, matching Windows ZoomIt.
            commandSink(.clear)
        case "[": commandSink(.decreasePenWidth)
        case "]": commandSink(.increasePenWidth)
        default: return nil
        }

        applyCursorPolicy()
        needsDisplay = true
        return ()
    }

    private func presentSelectionContextMenu(with event: NSEvent) -> Bool {
        let point = contentPoint(for: event)
        guard annotationController.prepareContextSelection(
            at: point,
            zoomScale: currentAnnotationZoomScale
        ) else {
            return false
        }

        let menu = NSMenu(title: "Selection")
        menu.autoenablesItems = false

        func addItem(
            _ title: String,
            action: Selector,
            keyEquivalent: String = "",
            modifiers: NSEvent.ModifierFlags = []
        ) -> NSMenuItem {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: keyEquivalent)
            item.target = self
            item.keyEquivalentModifierMask = modifiers
            menu.addItem(item)
            return item
        }

        let duplicate = addItem(
            "Duplicate",
            action: #selector(duplicateSelectionFromMenu),
            keyEquivalent: "d",
            modifiers: [.command]
        )
        duplicate.isEnabled = annotationController.canDeleteSelection
        let delete = addItem("Delete", action: #selector(deleteSelectionFromMenu))
        delete.isEnabled = annotationController.canDeleteSelection

        if let linear = annotationController.selectedLinearGeometry {
            menu.addItem(.separator())
            let editPoints = addItem(
                annotationController.isEditingLinearPoints ? "Finish Point Editing" : "Edit Points",
                action: #selector(toggleLinearPointEditingFromMenu)
            )
            editPoints.isEnabled = annotationController.canEditLinearPoints

            let insertPoint = addItem(
                "Insert Point",
                action: #selector(insertLinearPointFromMenu)
            )
            insertPoint.isEnabled = annotationController.canInsertLinearPoint
            let removePoints = addItem(
                "Remove Selected Points",
                action: #selector(removeLinearPointsFromMenu)
            )
            removePoints.isEnabled = annotationController.canRemoveLinearPoints

            let routeItem = NSMenuItem(title: "Route", action: nil, keyEquivalent: "")
            routeItem.isEnabled = annotationController.canEditSelectedLinearProperties
            let routeMenu = NSMenu(title: "Route")
            for (tag, route) in AnnotationLinearRoute.userSelectableRoutes
                .enumerated() {
                let item = NSMenuItem(
                    title: route.displayName,
                    action: #selector(setLinearRouteFromMenu(_:)),
                    keyEquivalent: ""
                )
                item.target = self
                item.tag = tag
                item.state = linear.route == route ? .on : .off
                routeMenu.addItem(item)
            }
            routeItem.submenu = routeMenu
            menu.addItem(routeItem)

            let startArrowhead = arrowheadMenuItem(
                title: "Start Arrowhead",
                selected: linear.startArrowhead,
                action: #selector(setStartArrowheadFromMenu(_:))
            )
            startArrowhead.isEnabled = annotationController.canEditSelectedLinearProperties
            menu.addItem(startArrowhead)
            let endArrowhead = arrowheadMenuItem(
                title: "End Arrowhead",
                selected: linear.endArrowhead,
                action: #selector(setEndArrowheadFromMenu(_:))
            )
            endArrowhead.isEnabled = annotationController.canEditSelectedLinearProperties
            menu.addItem(endArrowhead)

            let unbind = addItem(
                "Unbind Endpoints",
                action: #selector(unbindLinearEndpointsFromMenu)
            )
            unbind.isEnabled = annotationController.canUnbindLinearEndpoints
        }

        menu.addItem(.separator())
        let bringToFront = addItem(
            "Bring to Front",
            action: #selector(bringSelectionToFrontFromMenu)
        )
        let bringForward = addItem(
            "Bring Forward",
            action: #selector(bringSelectionForwardFromMenu)
        )
        let sendBackward = addItem(
            "Send Backward",
            action: #selector(sendSelectionBackwardFromMenu)
        )
        let sendToBack = addItem(
            "Send to Back",
            action: #selector(sendSelectionToBackFromMenu)
        )
        for item in [bringToFront, bringForward, sendBackward, sendToBack] {
            item.isEnabled = annotationController.canDeleteSelection
        }

        menu.addItem(.separator())
        let group = addItem(
            "Group",
            action: #selector(groupSelectionFromMenu),
            keyEquivalent: "g",
            modifiers: [.command]
        )
        group.isEnabled = annotationController.canGroupSelection
        let ungroup = addItem(
            "Ungroup",
            action: #selector(ungroupSelectionFromMenu),
            keyEquivalent: "g",
            modifiers: [.command, .shift]
        )
        ungroup.isEnabled = annotationController.canUngroupSelection
        _ = addItem(
            annotationController.selectionIsFullyLocked ? "Unlock" : "Lock",
            action: #selector(toggleSelectionLockFromMenu),
            keyEquivalent: "l",
            modifiers: [.command, .shift]
        )

        suppressNextSelectionRightMouseUp = true
        NSMenu.popUpContextMenu(menu, with: event, for: self)
        suppressNextSelectionRightMouseUp = false
        needsDisplay = true
        return true
    }

    @objc private func duplicateSelectionFromMenu() {
        commandSink(
            .duplicateSelection(
                destinationOffset: AppCommand.defaultDuplicateDestinationOffset
            )
        )
        needsDisplay = true
    }

    @objc private func deleteSelectionFromMenu() {
        commandSink(.deleteSelection)
        needsDisplay = true
    }

    @objc private func toggleLinearPointEditingFromMenu() {
        commandSink(.toggleLinearPointEditing)
        needsDisplay = true
    }

    @objc private func insertLinearPointFromMenu() {
        commandSink(.insertLinearPoint)
        needsDisplay = true
    }

    @objc private func removeLinearPointsFromMenu() {
        commandSink(.removeLinearPoints)
        needsDisplay = true
    }

    @objc private func setLinearRouteFromMenu(_ sender: NSMenuItem) {
        guard AnnotationLinearRoute.userSelectableRoutes.indices
            .contains(sender.tag) else {
            return
        }
        let route = AnnotationLinearRoute.userSelectableRoutes[sender.tag]
        commandSink(.setLinearRoute(route))
        needsDisplay = true
    }

    @objc private func setStartArrowheadFromMenu(_ sender: NSMenuItem) {
        guard let linear = annotationController.selectedLinearGeometry else { return }
        commandSink(
            .setLinearArrowheads(
                start: Self.arrowhead(forTag: sender.tag),
                end: linear.endArrowhead
            )
        )
        needsDisplay = true
    }

    @objc private func setEndArrowheadFromMenu(_ sender: NSMenuItem) {
        guard let linear = annotationController.selectedLinearGeometry else { return }
        commandSink(
            .setLinearArrowheads(
                start: linear.startArrowhead,
                end: Self.arrowhead(forTag: sender.tag)
            )
        )
        needsDisplay = true
    }

    @objc private func unbindLinearEndpointsFromMenu() {
        commandSink(.unbindLinearEndpoints)
        needsDisplay = true
    }

    @objc private func bringSelectionToFrontFromMenu() {
        commandSink(.arrangeSelection(.bringToFront))
        needsDisplay = true
    }

    @objc private func bringSelectionForwardFromMenu() {
        commandSink(.arrangeSelection(.bringForward))
        needsDisplay = true
    }

    @objc private func sendSelectionBackwardFromMenu() {
        commandSink(.arrangeSelection(.sendBackward))
        needsDisplay = true
    }

    @objc private func sendSelectionToBackFromMenu() {
        commandSink(.arrangeSelection(.sendToBack))
        needsDisplay = true
    }

    @objc private func groupSelectionFromMenu() {
        commandSink(.groupSelection)
        needsDisplay = true
    }

    @objc private func ungroupSelectionFromMenu() {
        commandSink(.ungroupSelection)
        needsDisplay = true
    }

    @objc private func toggleSelectionLockFromMenu() {
        commandSink(.toggleSelectionLock)
        needsDisplay = true
    }

    private func arrowheadMenuItem(
        title: String,
        selected: AnnotationArrowhead,
        action: Selector
    ) -> NSMenuItem {
        let root = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        let submenu = NSMenu(title: title)
        for (tag, arrowhead) in Self.arrowheads.enumerated() {
            let item = NSMenuItem(
                title: Self.arrowheadTitle(arrowhead),
                action: action,
                keyEquivalent: ""
            )
            item.target = self
            item.tag = tag
            item.state = selected == arrowhead ? .on : .off
            submenu.addItem(item)
        }
        root.submenu = submenu
        return root
    }

    private static let arrowheads: [AnnotationArrowhead] = [
        .none,
        .arrow,
        .triangleOutline,
        .triangle,
        .circleOutline,
        .circle,
        .diamondOutline,
        .diamond,
        .bar,
        .crowFoot,
        .oneOrMany,
        .zeroOrOne,
        .zeroOrMany
    ]

    private static func arrowhead(forTag tag: Int) -> AnnotationArrowhead {
        arrowheads.indices.contains(tag) ? arrowheads[tag] : .none
    }

    private static func arrowheadTitle(_ arrowhead: AnnotationArrowhead) -> String {
        arrowhead.displayName
    }

    private func toggleBlankScreen(_ screen: BlankScreen) {
        blankScreen = (blankScreen == screen) ? nil : screen
        needsDisplay = true
    }

    enum WhiteBlackKeyAction: Equatable { case blankScreen, highlightColor, penColor }

    /// Decides what the W/K keys do while drawing: Ctrl blanks the screen (white
    /// or black sketch pad), Shift selects the highlighter of that shade, and
    /// plain selects the solid pen colour.
    static func whiteBlackKeyAction(control: Bool, shift: Bool, isDrawingMode: Bool) -> WhiteBlackKeyAction {
        if control && isDrawingMode { return .blankScreen }
        if shift { return .highlightColor }
        return .penColor
    }

    private func drawTypingCaret(in context: CGContext) {
        guard let caret = annotationController.typingCaret() else { return }
        let color = annotationController.currentStyle.strokeColor.nsColor
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

    func typingInsertionPointForCurrentPointer() -> CGPoint {
        syncPointerViewPointFromMouse()
        return contentPoint(forViewPoint: pointerViewPoint)
    }

    func setPointerForTesting(
        viewPoint: CGPoint,
        screenLocation: CGPoint
    ) {
        pointerViewPoint = viewPoint
        latestCursorLocation = screenLocation
    }

    func setMouseLocationForTesting(_ screenLocation: CGPoint?) {
        mouseLocationOverrideForTesting = screenLocation
    }

    var pointerViewPointForTesting: CGPoint {
        pointerViewPoint
    }

    private var currentAnnotationZoomScale: CGFloat {
        let source = viewportController.sourceRect(for: bounds, cursorLocation: latestCursorLocation)
        return zoomScale(for: source)
    }

    func annotationContentOffset(forDestinationOffset offset: CGPoint) -> CGPoint {
        Self.annotationContentOffset(
            forDestinationOffset: offset,
            zoomScale: currentAnnotationZoomScale
        )
    }

    static func annotationContentOffset(
        forDestinationOffset offset: CGPoint,
        zoomScale: CGFloat
    ) -> CGPoint {
        let scale = max(zoomScale, 0.001)
        return CGPoint(x: offset.x / scale, y: offset.y / scale)
    }

    private func zoomScale(for source: CGRect) -> CGFloat {
        source.width > 0 ? bounds.width / source.width : 1
    }

    private func editorModifiers(from event: NSEvent) -> AnnotationEditorModifiers {
        var modifiers: AnnotationEditorModifiers = []
        if event.modifierFlags.contains(.shift) {
            modifiers.insert(.shift)
        }
        if event.modifierFlags.contains(.command) {
            modifiers.insert(.command)
        }
        if event.modifierFlags.contains(.option) {
            modifiers.insert(.option)
        }
        return modifiers
    }

    private func annotationPressure(from event: NSEvent) -> CGFloat? {
        guard event.subtype == .tabletPoint else {
            return nil
        }
        annotationController.noteTabletInputAvailable()
        guard annotationController.currentStyle.pressureMode != .fixed else { return nil }
        return CGFloat(event.pressure)
    }

    /// Maps a held modifier (or Tab) at stroke start to a ZoomIt shape gesture:
    /// Ctrl = rectangle, Shift = line, Ctrl+Shift = arrow, Tab = ellipse.
    private func gestureTool(for event: NSEvent) -> AnnotationTool? {
        let modifiers = event.modifierFlags
        return Self.gestureTool(
            control: modifiers.contains(.control),
            shift: modifiers.contains(.shift),
            tab: tabKeyIsDown(),
            selectedTool: annotationController.currentTool
        )
    }

    static func gestureTool(
        control: Bool,
        shift: Bool,
        tab: Bool,
        selectedTool: AnnotationTool? = nil
    ) -> AnnotationTool? {
        if shift,
           !control,
           !tab,
           selectedTool == .rectangle || selectedTool == .diamond {
            return nil
        }
        if control && shift { return .arrow }
        if control { return .rectangle }
        if shift { return .line }
        if tab { return .ellipse }
        return nil
    }

    private func shouldConstrainShapeAspect(for event: NSEvent) -> Bool {
        guard event.modifierFlags.contains(.shift) else { return false }
        return activeStrokeTool == .rectangle || activeStrokeTool == .diamond
    }

    static func selectionNudge(
        keyCode: UInt16,
        shift: Bool,
        hasMovableSelection: Bool
    ) -> CGPoint? {
        guard hasMovableSelection else { return nil }
        let step: CGFloat = shift ? 10 : 1
        return switch keyCode {
        case 123: CGPoint(x: -step, y: 0)
        case 124: CGPoint(x: step, y: 0)
        case 125: CGPoint(x: 0, y: step)
        case 126: CGPoint(x: 0, y: -step)
        default: nil
        }
    }

    private func tabKeyIsDown() -> Bool {
        // Query the live keyboard state so a missed key-up can never leave us
        // stuck in the ellipse gesture. 0x30 is the Tab virtual key code.
        CGEventSource.keyState(.combinedSessionState, key: 0x30)
    }

    private func configureImmediateFreehandLayers() {
        for overlayLayer in [
            immediateFreehandTailLayer,
            immediateFreehandPointerLayer
        ] {
            overlayLayer.actions = [
                "bounds": NSNull(),
                "position": NSNull(),
                "path": NSNull(),
                "strokeColor": NSNull(),
                "fillColor": NSNull(),
                "lineWidth": NSNull(),
                "opacity": NSNull()
            ]
            Self.configureImmediateFreehandLayerGeometry(overlayLayer)
            overlayLayer.contentsScale = window?.backingScaleFactor
                ?? capturedFrame.display.scaleFactor
            overlayLayer.isHidden = true
            layer?.addSublayer(overlayLayer)
        }
        immediateFreehandTailLayer.fillColor = nil
        immediateFreehandTailLayer.zPosition = 10_000
        immediateFreehandPointerLayer.zPosition = 10_001
    }

    static func configureImmediateFreehandLayerGeometry(_ layer: CALayer) {
        layer.isGeometryFlipped = false
        layer.setAffineTransform(.identity)
    }

    private func updateImmediateFreehandPresentation(
        with input: AnnotationRawFreehandInput
    ) {
        if let previous = latestRawPointerLane.latestRawPointer,
           hypot(
               input.location.x - previous.location.x,
               input.location.y - previous.location.y
           ) > 0.25 {
            hasImmediateFreehandMovement = true
        }
        latestRawPointerLane.update(input)
        refreshImmediateFreehandPresentation()
    }

    private func refreshImmediateFreehandPresentation() {
        guard let latest = latestRawPointerLane.latestRawPointer,
              let activeElement = annotationController.inProgressElementSnapshot,
              case .freehand(let freehand) = activeElement.geometry else {
            clearImmediateFreehandPresentation()
            return
        }
        let source = viewportController.sourceRect(
            for: bounds,
            cursorLocation: latestCursorLocation
        )
        let destinationScale = zoomScale(for: source)
        let style = activeElement.style
        let effectiveOpacity = style.opacity
            * (freehand.isHighlighter ? AnnotationStyle.highlightAlpha : 1)
        let resolved = AnnotationColorResolver.resolved(
            style.strokeColor,
            opacity: effectiveOpacity
        )
        let latestPressure = latest.pressure
            ?? freehand.samples.last?.pressure
        let pressureScale = style.pressureEnabled && !freehand.isHighlighter
            ? AnnotationGeometry.pressureScale(latestPressure)
            : 1
        let lineWidth = max(
            freehand.isHighlighter ? 1 : 1.25,
            style.strokeWidth * destinationScale * pressureScale
        )

        var points: [CGPoint] = []
        if let committed = freehand.samples.last {
            points.append(
                viewPoint(forContentPoint: committed.location, source: source)
            )
        }
        let committedTimestamp = freehand.samples.last?.timestamp
        for sample in latestRawPointerLane.samples(after: committedTimestamp) {
            let point = viewPoint(forContentPoint: sample.location, source: source)
            if points.last != point {
                points.append(point)
            }
        }
        // The final presentation point comes directly from the latest AppKit
        // event in view coordinates. This avoids a content/view round-trip
        // introducing a second, mirrored nib under live zoom.
        let latestViewPoint = pointerViewPoint
        if points.last != latestViewPoint {
            points.append(latestViewPoint)
        }

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        immediateFreehandTailLayer.contentsScale = window?.backingScaleFactor
            ?? capturedFrame.display.scaleFactor
        immediateFreehandPointerLayer.contentsScale =
            immediateFreehandTailLayer.contentsScale
        immediateFreehandTailLayer.strokeColor = resolved.color.cgColor
        immediateFreehandTailLayer.opacity = Float(resolved.alpha)
        immediateFreehandTailLayer.lineWidth = lineWidth
        immediateFreehandTailLayer.lineCap =
            freehand.isHighlighter ? .butt : .round
        immediateFreehandTailLayer.lineJoin =
            freehand.isHighlighter ? .bevel : .round
        if points.count > 1 {
            let tailPath: CGPath
            if style.smoothingEnabled {
                tailPath = AnnotationGeometry.smoothedFreehandPath(
                    points.map { AnnotationPointSample(location: $0, pressure: nil) }
                )
            } else {
                let rawPath = CGMutablePath()
                rawPath.addLines(between: points)
                tailPath = rawPath
            }
            immediateFreehandTailLayer.path = tailPath
            immediateFreehandTailLayer.isHidden = false
        } else {
            immediateFreehandTailLayer.path = nil
            immediateFreehandTailLayer.isHidden = true
        }

        let showsStandalonePointer =
            DrawingImmediateFreehandPresentationPolicy.showsStandalonePointer(
                hasMoved: hasImmediateFreehandMovement,
                tailPointCount: points.count
            )
        if showsStandalonePointer {
            let pointerPath = CGMutablePath()
            if freehand.isHighlighter {
                pointerPath.addRect(
                    AnnotationHighlighterGeometry.stampRect(
                        center: latestViewPoint,
                        strokeWidth: lineWidth
                    )
                )
            } else {
                pointerPath.addEllipse(
                    in: CGRect(
                        x: latestViewPoint.x - lineWidth / 2,
                        y: latestViewPoint.y - lineWidth / 2,
                        width: lineWidth,
                        height: lineWidth
                    )
                )
            }
            immediateFreehandPointerLayer.path = pointerPath
            immediateFreehandPointerLayer.fillColor = resolved.color.cgColor
            immediateFreehandPointerLayer.opacity = Float(resolved.alpha)
            immediateFreehandPointerLayer.isHidden = false
        } else {
            immediateFreehandPointerLayer.path = nil
            immediateFreehandPointerLayer.isHidden = true
        }
        CATransaction.commit()
    }

    private func clearImmediateFreehandPresentation() {
        latestRawPointerLane.clear()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        immediateFreehandTailLayer.path = nil
        immediateFreehandTailLayer.isHidden = true
        immediateFreehandPointerLayer.path = nil
        immediateFreehandPointerLayer.isHidden = true
        hasImmediateFreehandMovement = false
        CATransaction.commit()
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
        syncPointerViewPointFromMouse()
        isDrawingMode = true
        isStroking = false
        isHandPanning = false
        startDrawingRightClickMonitor()
        updateLiveZoomInteractivity()
        applyCursorPolicy()
        reportDrawingAccessoryLifecycle()
    }

    private func exitDrawingMode(restoreCursor: Bool = true) {
        guard isDrawingMode else { return }
        stopFreehandDrainTimer()
        clearImmediateFreehandPresentation()
        annotationController.resolveActiveGestureForExit(
            zoomScale: currentAnnotationZoomScale
        )
        isDrawingMode = false
        restoreMouseCoalescingIfNeeded()
        isStroking = false
        isHandPanning = false
        activeStrokeTool = nil
        linearPointerGesture = nil
        isOverLinearFinishHandle = false
        transientToolDidChange(nil)
        annotationController.cancelSelectionInteraction()
        annotationController.clearSelection()
        blankScreen = nil
        stopDrawingRightClickMonitor()
        // Keep the zoom anchored where it was while drawing. The physical mouse
        // moved around the screen while drawing, so warp the (hidden) system
        // cursor back to the frozen anchor. This keeps panning continuous and
        // prevents the view from jumping when leaving drawing mode.
        if restoreCursor, let anchor = latestCursorLocation {
            warpCursor(toGlobal: anchor)
        }
        updateLiveZoomInteractivity()
        applyCursorPolicy()
        reportDrawingAccessoryLifecycle()
    }

    private func beginHighFidelityFreehandInput(for tool: AnnotationTool) {
        guard tool == .pen || tool == .highlighter,
              mouseCoalescingRestoreValue == nil else {
            return
        }
        mouseCoalescingRestoreValue = NSEvent.isMouseCoalescingEnabled
        NSEvent.isMouseCoalescingEnabled = true
    }

    private func restoreMouseCoalescingIfNeeded() {
        guard let restoreValue = mouseCoalescingRestoreValue else { return }
        NSEvent.isMouseCoalescingEnabled = restoreValue
        mouseCoalescingRestoreValue = nil
    }

    private func scheduleFreehandDrain() {
        guard freehandDisplayLink == nil,
              isStroking else {
            return
        }
        let displayLink = displayLink(
            target: self,
            selector: #selector(freehandDisplayLinkDidFire(_:))
        )
        displayLink.preferredFrameRateRange = CAFrameRateRange(
            minimum: 60,
            maximum: 120,
            preferred: 120
        )
        displayLink.add(to: .main, forMode: .common)
        freehandDisplayLink = displayLink
    }

    @objc private func freehandDisplayLinkDidFire(_ displayLink: CADisplayLink) {
        _ = displayLink
        drainFreehandFrame()
    }

    private func drainFreehandFrame() {
        guard annotationController.hasPendingFreehandInput else { return }
        let zoomScale = currentAnnotationZoomScale
        let oldTailBounds = annotationController.activeFreehandTailBounds(zoomScale: zoomScale)
        let rawCount = annotationController.pendingRawFreehandInputCountForTesting
        let stats = annotationController.drainFreehandInput(
            zoomScale: zoomScale,
            budget: AnnotationFreehandDrainBudget(
                maximumRawEvents: rawCount > 20 ? 12 : 8,
                maximumGeneratedSamples: rawCount > 20 ? 96 : 128,
                spacingScale: rawCount > 20 ? 2 : 1
            )
        )
        if stats.generatedSamples > 0, freehandInvalidationState.beginFrame() {
            let dirtyContent = oldTailBounds.union(
                annotationController.activeFreehandTailBounds(zoomScale: zoomScale)
            )
            let source = viewportController.sourceRect(
                for: bounds, cursorLocation: latestCursorLocation
            )
            let transform = viewportController.contentToDestinationTransform(
                source: source, destinationBounds: bounds
            )
            setNeedsDisplay(dirtyContent.applying(transform).integral.intersection(bounds))
        }
        refreshImmediateFreehandPresentation()
        if annotationController.hasPendingFreehandInput {
            freehandInvalidationState.noteInput()
        }
    }

    private func stopFreehandDrainTimer() {
        freehandDisplayLink?.invalidate()
        freehandDisplayLink = nil
    }

    private func cancelActiveStrokeTracking() {
        stopFreehandDrainTimer()
        clearImmediateFreehandPresentation()
        restoreMouseCoalescingIfNeeded()
        isStroking = false
        activeStrokeTool = nil
        linearPointerGesture = nil
        transientToolDidChange(nil)
    }

    private func leaveDrawingModeFromRightClick() {
        guard isDrawingMode else { return }
        exitDrawingMode()
        needsDisplay = true
    }

    private func startDrawingRightClickMonitor() {
        guard drawingRightClickMonitor == nil else { return }
        drawingRightClickMonitor = NSEvent.addLocalMonitorForEvents(matching: [.rightMouseDown, .rightMouseUp, .otherMouseDown, .otherMouseUp]) { [weak self] event in
            let windowNumber = event.window?.windowNumber
            let location = event.locationInWindow
            let handled = MainActor.assumeIsolated { () -> Bool in
                self?.handleDrawingRightClick(windowNumber: windowNumber, locationInWindow: location) ?? false
            }
            return handled ? nil : event
        }
        drawingGlobalRightClickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.rightMouseDown, .rightMouseUp, .otherMouseDown, .otherMouseUp]) { [weak self] _ in
            MainActor.assumeIsolated {
                _ = self?.handleDrawingRightClick(windowNumber: nil, locationInWindow: nil)
            }
        }
    }

    private func handleDrawingRightClick(windowNumber: Int?, locationInWindow: CGPoint?) -> Bool {
        guard isDrawingMode else { return false }
        if let windowNumber, windowNumber != window?.windowNumber {
            return false
        }
        if annotationController.currentTool == .select,
           windowNumber == window?.windowNumber {
            return false
        }
        if let locationInWindow, windowNumber == window?.windowNumber {
            pointerViewPoint = convert(locationInWindow, from: nil)
        } else {
            syncPointerViewPointFromMouse()
        }
        leaveDrawingModeFromRightClick()
        return true
    }

    private func stopDrawingRightClickMonitor() {
        if let drawingRightClickMonitor {
            NSEvent.removeMonitor(drawingRightClickMonitor)
        }
        drawingRightClickMonitor = nil
        if let drawingGlobalRightClickMonitor {
            NSEvent.removeMonitor(drawingGlobalRightClickMonitor)
        }
        drawingGlobalRightClickMonitor = nil
    }

    /// When typing mode ends, keep the system cursor at the last mouse position
    /// tracked while typing, or at the text caret once text has locked it.
    private func anchorCursorAfterTyping() {
        if annotationController.isTypingLocked, let caret = annotationController.typingCaret() {
            anchorCursor(toContentPoint: caret.origin, reason: "anchor after typing caret")
            return
        }
        syncPointerViewPointFromMouse()
        latestCursorLocation = NSEvent.mouseLocation
    }

    private func finishLockedTypingAtCaret(reason: String) {
        let insertion = annotationController.typingCaret()?.origin ?? contentPoint(forViewPoint: pointerViewPoint)
        annotationController.setInsertionPoint(insertion)
        anchorCursor(toContentPoint: insertion, reason: reason)
        commandSink(.toggleTyping(rightAligned: false))
    }

    private func anchorCursor(toContentPoint point: CGPoint, reason: String) {
        let source = viewportController.sourceRect(for: bounds, cursorLocation: latestCursorLocation)
        pointerViewPoint = viewPoint(forContentPoint: point, source: source)
        if let global = screenLocation(forViewPoint: pointerViewPoint) {
            warpCursor(toGlobal: global)
            if interactionMode == .drawOnly {
                latestCursorLocation = global
                postTypingCursorAnchorOffset = nil
            } else if let anchor = latestCursorLocation {
                postTypingCursorAnchorOffset = CGPoint(x: anchor.x - global.x, y: anchor.y - global.y)
            }
        }
    }

    private func updateLatestCursorLocationFromMouse() {
        let mouse = NSEvent.mouseLocation
        if let offset = postTypingCursorAnchorOffset {
            latestCursorLocation = CGPoint(x: mouse.x + offset.x, y: mouse.y + offset.y)
        } else {
            latestCursorLocation = mouse
        }
    }

    private func syncPointerViewPointFromMouse() {
        guard let window else { return }
        let mouseLocation = mouseLocationOverrideForTesting
            ?? NSEvent.mouseLocation
        let windowPoint = window.convertPoint(fromScreen: mouseLocation)
        pointerViewPoint = convert(windowPoint, from: nil)
    }

    private func warpCursor(toGlobal point: CGPoint) {
        guard let primaryHeight = NSScreen.screens.first?.frame.height else { return }
        // NSEvent.mouseLocation uses a bottom-left origin on the primary screen;
        // CGWarpMouseCursorPosition expects a top-left origin, so flip Y.
        CGWarpMouseCursorPosition(CGPoint(x: point.x, y: primaryHeight - point.y))
    }

    private func viewPoint(forContentPoint point: CGPoint, source: CGRect) -> CGPoint {
        DrawingImmediateFreehandPresentationPolicy.viewPoint(
            forContentPoint: point,
            source: source,
            destinationBounds: bounds
        )
    }

    private func screenLocation(forViewPoint viewPoint: CGPoint) -> CGPoint? {
        guard let window else { return nil }
        let windowPoint = convert(viewPoint, to: nil)
        return window.convertPoint(toScreen: windowPoint)
    }

    private func hideSystemCursor() {
        guard !ownsHiddenSystemCursor else { return }
        NSCursor.hide()
        ownsHiddenSystemCursor = true
    }

    private func showSystemCursor() {
        guard ownsHiddenSystemCursor else { return }
        NSCursor.unhide()
        ownsHiddenSystemCursor = false
    }

    private func applyCursorPolicy() {
        guard window != nil else { return }
        if isSelectingRegion {
            showSystemCursor()
            return
        }
        if isOverLinearFinishHandle {
            showSystemCursor()
            NSCursor.pointingHand.set()
            return
        }

        let presentation = DrawingCursorPolicy.presentation(
            interactionMode: interactionMode,
            isDrawingMode: isDrawingMode,
            tool: annotationController.currentTool,
            isAccessoryInteractionActive: isDrawingAccessoryInteractionActive,
            isHandPanning: isHandPanning,
            isLiveZoomInteractive: liveZoomClickThrough,
            isTextInsertionActive: annotationController.isTypingLocked
        )
        switch presentation {
        case .hidden:
            hideSystemCursor()
        case .arrow:
            showSystemCursor()
            NSCursor.arrow.set()
        case .iBeam:
            showSystemCursor()
            NSCursor.iBeam.set()
        case .openHand:
            showSystemCursor()
            NSCursor.openHand.set()
        case .closedHand:
            showSystemCursor()
            NSCursor.closedHand.set()
        }
    }

    private func reportDrawingAccessoryLifecycle() {
        let isActive = DrawingAccessoryLifecycle.isActive(
            interactionMode: interactionMode,
            isDrawingMode: isDrawingMode,
            resumesDrawingAfterTyping: resumeDrawingAfterTyping
        )
        guard isActive != lastReportedDrawingAccessoryActive else { return }
        lastReportedDrawingAccessoryActive = isActive
        drawingModeDidChange(isActive)
    }

    func annotationStateDidChange() {
        if !annotationController.hasActiveDrawingGesture,
           hasPendingAnnotationInputForTesting {
            cancelActiveStrokeTracking()
        }
        updateLinearFinishHandleHover()
        applyCursorPolicy()
    }

    func setDrawingAccessoryInteractionActive(_ isActive: Bool) {
        isDrawingAccessoryInteractionActive = isActive
        applyCursorPolicy()
        needsDisplay = true
    }

    private func usesSystemCursor(_ tool: AnnotationTool) -> Bool {
        tool == .hand || tool == .select || tool == .eraser || tool == .text
    }

    private func drawsCursorIndicator(_ tool: AnnotationTool) -> Bool {
        !usesSystemCursor(tool) && tool != .text
    }

    func prepareForClose() {
        if isDrawingMode {
            exitDrawingMode(restoreCursor: false)
        } else {
            annotationController.resolveActiveGestureForExit(
                zoomScale: currentAnnotationZoomScale
            )
            restoreMouseCoalescingIfNeeded()
            isStroking = false
            isHandPanning = false
            activeStrokeTool = nil
            linearPointerGesture = nil
            isOverLinearFinishHandle = false
            transientToolDidChange(nil)
        }
        endRegionSnip(restoreInteraction: false)
        stopLiveMouseTracking()
        stopDrawingRightClickMonitor()
        modalPresentationDidChange(false)
        isDrawingMode = false
        resumeDrawingAfterTyping = false
        reportDrawingAccessoryLifecycle()
        showSystemCursor()
    }

    private func updateLinearFinishHandleHover() {
        guard annotationController.isConstructingLinearPath else {
            isOverLinearFinishHandle = false
            return
        }
        isOverLinearFinishHandle = annotationController.isLinearConstructionFinishHandle(
            at: contentPoint(forViewPoint: pointerViewPoint),
            zoomScale: currentAnnotationZoomScale
        )
    }

    static func shouldTreatLinearCreationAsDrag(
        from start: CGPoint,
        to end: CGPoint,
        threshold: CGFloat = 4
    ) -> Bool {
        hypot(end.x - start.x, end.y - start.y) > threshold
    }

    static func linearDragThresholdExceeded(
        previouslyExceeded: Bool,
        from start: CGPoint,
        to end: CGPoint,
        threshold: CGFloat = 4
    ) -> Bool {
        previouslyExceeded
            || shouldTreatLinearCreationAsDrag(
                from: start,
                to: end,
                threshold: threshold
            )
    }

    func restoreFocusAfterDrawingAccessoryAction() {
        applyCursorPolicy()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil {
            updateLiveZoomInteractivity()
            applyCursorPolicy()
        } else {
            stopLiveMouseTracking()
            stopDrawingRightClickMonitor()
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
        if interactive != liveZoomClickThrough {
            liveZoomClickThrough = interactive
            if interactive {
                // Pass mouse events through to the apps underneath; a global
                // monitor keeps the magnified view tracking the pointer.
                window.ignoresMouseEvents = true
                startLiveMouseTracking()
            } else {
                // Reclaim input so the overlay can draw or type modally.
                stopLiveMouseTracking()
                window.ignoresMouseEvents = false
                NSApp.activate(ignoringOtherApps: true)
                window.makeKeyAndOrderFront(nil)
                window.makeFirstResponder(self)
            }
        }
        applyCursorPolicy()
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
        guard let image = captureViewportImage(policy: .stillImage) else { return }
        ImageExporter.copyToPasteboard(image)
    }

    /// Renders the current viewport and presents a Save dialog to write it as
    /// PNG.
    private func saveViewport() {
        guard let image = captureViewportImage(policy: .stillImage) else { return }
        presentSavePanelOverOverlay(image)
    }

    /// Presents a Save dialog above the overlay (whose `.screenSaver` level would
    /// otherwise hide it) with the cursor visible, then restores both. Honors the
    /// snip preferences: also copies to the clipboard when configured, and writes
    /// directly to the configured directory instead of showing a dialog.
    private func presentSavePanelOverOverlay(_ image: CGImage) {
        let settings = UserDefaultsSettingsStore().load()
        if settings.copySnipToClipboardOnSave {
            ImageExporter.copyToPasteboard(image)
        }
        if settings.saveSnipToDirectory {
            if ImageExporter.writeToDirectory(
                image,
                directoryPath: settings.snipSaveDirectory,
                userSelectedResourceAccess: userSelectedResourceAccess
            ) {
                return
            }
        }
        let savedLevel = window?.level
        OverlayPresentedWindowLifecycle.perform(
            prepareAccessories: {
                modalPresentationDidChange(true)
                window?.level = NSWindow.Level(rawValue: NSWindow.Level.normal.rawValue - 1)
            },
            showSystemCursor: {
                showSystemCursor()
            },
            present: {
                ImageExporter.presentSavePanel(for: image)
            },
            restoreAccessories: {
                if let savedLevel {
                    window?.level = savedLevel
                }
                modalPresentationDidChange(false)
            },
            reapplyCursorPolicy: {
                applyCursorPolicy()
            }
        )
    }

    /// Snapshots exactly what the overlay is displaying (magnified image plus
    /// annotations) at the view's backing resolution.
    private func captureCanonicalViewportImage(
        policy: ZoomCanvasCapturePolicy
    ) -> CGImage? {
        let previousPolicy = capturePolicy
        let previousTailHidden = immediateFreehandTailLayer.isHidden
        let previousPointerHidden = immediateFreehandPointerLayer.isHidden
        capturePolicy = policy
        if !policy.includesImmediateFreehandLayers {
            setImmediateFreehandLayersHidden(true)
        }
        defer {
            capturePolicy = previousPolicy
            setImmediateFreehandLayersHidden(
                tail: previousTailHidden,
                pointer: previousPointerHidden
            )
        }
        guard let rep = bitmapImageRepForCachingDisplay(in: bounds) else { return nil }
        cacheDisplay(in: bounds, to: rep)
        return rep.cgImage
    }

    private func captureViewportImage(
        policy: ZoomCanvasCapturePolicy,
        sourceRect: CGRect? = nil,
        outputPixelSize: CGSize? = nil
    ) -> CGImage? {
        displayIfNeeded()
        guard let baseImage = captureCanonicalViewportImage(policy: policy) else {
            return nil
        }
        let source = sourceRect ?? bounds
        let resolvedOutputSize = outputPixelSize
            ?? naturalOutputPixelSize(
                baseImage: baseImage,
                sourceRect: source
            )
        return captureCompositor(
            baseImage,
            capturedFrame.display.frame,
            source,
            resolvedOutputSize
        )
    }

    private func naturalOutputPixelSize(
        baseImage: CGImage,
        sourceRect: CGRect
    ) -> CGSize {
        let scaleX = bounds.width > 0
            ? CGFloat(baseImage.width) / bounds.width
            : capturedFrame.display.scaleFactor
        let scaleY = bounds.height > 0
            ? CGFloat(baseImage.height) / bounds.height
            : capturedFrame.display.scaleFactor
        return CGSize(
            width: max(1, (sourceRect.width * scaleX).rounded()),
            height: max(1, (sourceRect.height * scaleY).rounded())
        )
    }

    private func setImmediateFreehandLayersHidden(_ hidden: Bool) {
        setImmediateFreehandLayersHidden(tail: hidden, pointer: hidden)
    }

    private func setImmediateFreehandLayersHidden(
        tail: Bool,
        pointer: Bool
    ) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        immediateFreehandTailLayer.isHidden = tail
        immediateFreehandPointerLayer.isHidden = pointer
        CATransaction.commit()
    }

    /// Snapshots the visible overlay for the recorder. `sourceRect` is a region
    /// recording crop in display points with a top-left origin.
    func captureRecordingImage(
        sourceRect: CGRect?,
        outputPixelSize: CGSize
    ) -> CGImage? {
        captureViewportImage(
            policy: .recording,
            sourceRect: sourceRect,
            outputPixelSize: outputPixelSize
        )
    }

    func captureImageForTesting(
        policy: ZoomCanvasCapturePolicy,
        sourceRect: CGRect?,
        outputPixelSize: CGSize?
    ) -> CGImage? {
        captureViewportImage(
            policy: policy,
            sourceRect: sourceRect,
            outputPixelSize: outputPixelSize
        )
    }

    // MARK: - Region snip

    /// Begins selecting a rectangle of the current viewport to copy or save.
    func beginRegionSnip(action: SnipAction, onFinished: @escaping () -> Void) {
        endRegionSnip(restoreInteraction: true)
        regionAction = action
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
        let action = regionAction
        let teardown = clearRegionSnipState()

        if rect.width >= 3,
           rect.height >= 3,
           let cropped = captureViewportImage(
               policy: .stillImage,
               sourceRect: rect
           ) {
            switch action {
            case .saveImage:
                presentSavePanelOverOverlay(cropped)
            case .copyImage:
                ImageExporter.copyToPasteboard(cropped)
            case .recognizeText:
                OcrService.recognizeAndCopy(cropped)
            }
        }
        restoreAfterRegionSnip()
        teardown.callback?()
    }

    private func cancelRegionSnip() {
        endRegionSnip(restoreInteraction: true)
    }

    private func clearRegionSnipState() -> (wasActive: Bool, callback: (() -> Void)?) {
        let callback = onRegionSnipFinished
        onRegionSnipFinished = nil
        let wasActive = isSelectingRegion
            || regionAnchor != nil
            || !regionRect.isEmpty
            || regionCursorLease != nil
            || callback != nil
        isSelectingRegion = false
        regionAction = .copyImage
        regionRect = .zero
        regionAnchor = nil
        popRegionCursor()
        return (wasActive, callback)
    }

    private func endRegionSnip(restoreInteraction: Bool) {
        let teardown = clearRegionSnipState()
        if restoreInteraction, teardown.wasActive {
            restoreAfterRegionSnip()
        }
        teardown.callback?()
    }

    private func restoreAfterRegionSnip() {
        needsDisplay = true
        if interactionMode == .liveZoom {
            updateLiveZoomInteractivity()
        } else {
            applyCursorPolicy()
        }
    }

    private func pushRegionCursor() {
        guard regionCursorLease == nil, let window else { return }
        let cursorLease = CrosshairCursorLease(window: window)
        cursorLease.activate()
        regionCursorLease = cursorLease
    }

    private func popRegionCursor() {
        regionCursorLease?.invalidate()
        regionCursorLease = nil
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
        let center = pointerViewPoint
        let width = max(8, annotationController.currentStyle.rootWidth * zoomScale)

        context.saveGState()
        if annotationController.currentTool == .highlighter {
            let resolved = AnnotationColorResolver.resolved(
                annotationController.currentStyle.strokeColor,
                opacity: annotationController.currentStyle.opacity,
                highlightMultiplier: AnnotationStyle.highlightAlpha
            )
            context.setAlpha(resolved.alpha)
            context.setFillColor(resolved.color.cgColor)
            context.fill(
                AnnotationHighlighterGeometry.stampRect(
                    center: center,
                    strokeWidth: width
                )
            )
        } else {
            let radius = width / 2
            let rect = CGRect(
                x: center.x - radius,
                y: center.y - radius,
                width: width,
                height: width
            )
            context.setFillColor(annotationController.currentStyle.strokeColor.nsColor.cgColor)
            context.fillEllipse(in: rect)
        }
        context.restoreGState()
    }
}