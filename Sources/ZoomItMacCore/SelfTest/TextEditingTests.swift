import AppKit

extension SelfTestRunner {
    static func testTextResizeUsesUniformHandlesAndScale() throws {
        let text = AnnotationElement(
            geometry: .text(
                AnnotationTextGeometry(
                    origin: CGPoint(x: 20, y: 20),
                    bounds: nil,
                    text: "Resize me",
                    fontSize: 20,
                    fontName: "",
                    alignment: .left
                )
            ),
            style: AnnotationStyle.default
        )
        let scene = AnnotationScene(elements: [text])
        let editor = AnnotationEditor(scene: scene)
        scene.select([text.id])
        guard let before = AnnotationGeometry.selectionDecoration(for: text, zoomScale: 1),
              let dragged = before.handles.first(where: { $0.kind == .bottomTrailing }),
              let fixed = before.handles.first(where: { $0.kind == .topLeading }) else {
            throw SelfTestError.failure("Expected text resize handles")
        }
        try expect(
            before.handles.map(\.kind) == [
                .topLeading,
                .topTrailing,
                .bottomTrailing,
                .bottomLeading,
                .rotation
            ],
            "Expected text selection to expose only uniform corner resize handles"
        )

        let target = CGPoint(
            x: fixed.center.x + (dragged.center.x - fixed.center.x) * 1.5,
            y: fixed.center.y + (dragged.center.y - fixed.center.y) * 1.5
        )
        _ = editor.beginInteraction(
            at: dragged.center,
            zoomScale: 1,
            modifiers: [],
            clickCount: 1
        )
        editor.endInteraction(at: target, modifiers: [])

        guard let resized = scene.element(withID: text.id),
              case .text(let resizedText) = resized.geometry,
              let after = AnnotationGeometry.selectionDecoration(for: resized, zoomScale: 1),
              let draggedAfter = after.handles.first(where: { $0.kind == .bottomTrailing }),
              let fixedAfter = after.handles.first(where: { $0.kind == .topLeading }) else {
            throw SelfTestError.failure("Expected uniformly resized text")
        }
        try expect(
            approximatelyEqual(fixedAfter.center, fixed.center)
                && approximatelyEqual(draggedAfter.center, target, tolerance: 0.05),
            "Expected text selection bounds to land on the requested uniform resize handle"
        )
        try expect(
            approximatelyEqual(resizedText.fontSize, 30, tolerance: 0.05)
                && approximatelyEqual(resizedText.bounds ?? .zero, CGRect(
                    x: fixed.center.x,
                    y: fixed.center.y,
                    width: target.x - fixed.center.x,
                    height: target.y - fixed.center.y
                ), tolerance: 0.05),
            "Expected text resize to scale the font consistently into the requested bounds"
        )

        let resizedBounds = AnnotationGeometry.worldBounds(
            of: resized,
            includingStroke: false
        )
        let outcome = editor.beginInteraction(
            at: CGPoint(x: resizedBounds.midX, y: resizedBounds.midY),
            zoomScale: 1,
            modifiers: [],
            clickCount: 2
        )
        try expect(
            outcome == .beginTextEditing(text.id),
            "Expected resized text to remain editable by double-clicking"
        )
    }

    static func testAnnotationEditorStateTransitionsAndTextReselection() throws {
        let scene = AnnotationScene()
        let editor = AnnotationEditor(scene: scene)
        editor.beginCreating(tool: .pen)
        try expect(editor.stateKind == .creating, "Expected creation to have an explicit editor state")
        editor.finishCreating()
        try expect(editor.stateKind == .idle, "Expected completing creation to return to idle")

        _ = editor.beginInteraction(
            at: .zero,
            zoomScale: 1,
            modifiers: [],
            clickCount: 1
        )
        try expect(editor.stateKind == .marqueeSelecting, "Expected marquee state transition")
        editor.cancelInteraction()
        try expect(editor.stateKind == .idle, "Expected cancelling an interaction to return to idle")

        let controller = AnnotationController()
        controller.setInsertionPoint(CGPoint(x: 20, y: 30))
        controller.beginTypingSession(rightAligned: false)
        var observedActiveInsertionDuringStateChange = false
        controller.onStateChanged = {
            observedActiveInsertionDuringStateChange =
                observedActiveInsertionDuringStateChange || controller.isTypingLocked
        }
        controller.insertText("A")
        try expect(
            observedActiveInsertionDuringStateChange,
            "Expected the first text state change to expose the active insertion caret "
                + "so the native I-beam can be hidden immediately"
        )
        controller.finishTypingSession()
        guard let textID = controller.elementSnapshot.first?.id else {
            throw SelfTestError.failure("Expected a committed text element")
        }

        try expect(
            controller.beginEditingText(elementID: textID),
            "Expected an existing text element to re-enter typing"
        )
        try expect(
            controller.editorStateKind == .editingText,
            "Expected text re-selection to enter the editing-text state"
        )
        controller.insertText("B")
        controller.finishTypingSession()
        try expect(
            controller.elementSnapshot.first?.textGeometryForTesting?.text == "AB",
            "Expected re-selected text to append through the existing typing path"
        )
        controller.undo()
        try expect(
            controller.elementSnapshot.first?.textGeometryForTesting?.text == "A",
            "Expected one undo to revert the complete text re-edit transaction"
        )

        controller.setInsertionPoint(CGPoint(x: 80, y: 30))
        controller.beginTypingSession(rightAligned: true)
        controller.insertText("R")
        controller.finishTypingSession()
        guard case .text(let rightAlignedText) = controller.elementSnapshot.last?.geometry else {
            throw SelfTestError.failure("Expected Shift+T-compatible text geometry")
        }
        try expect(
            rightAlignedText.alignment == .right && rightAlignedText.text == "R",
            "Expected right-aligned typing sessions to retain Shift+T behavior"
        )
    }

    static func testModeCoordinatorExistingTextEditTransition() throws {
        let defaultsName = "ZoomItMacSelfTest.TextEdit.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: defaultsName) else {
            throw SelfTestError.failure("Could not create text-edit test defaults")
        }
        defaults.removePersistentDomain(forName: defaultsName)

        let settingsStore = UserDefaultsSettingsStore(defaults: defaults)
        let resourceAccess = UserDefaultsUserSelectedResourceAccess(defaults: defaults)
        let annotationController = AnnotationController()
        annotationController.setInsertionPoint(CGPoint(x: 40, y: 50))
        annotationController.beginTypingSession(rightAligned: false)
        annotationController.insertText("A")
        annotationController.finishTypingSession()
        guard let textID = annotationController.elementSnapshot.first?.id else {
            throw SelfTestError.failure("Expected coordinator text-edit setup")
        }
        annotationController.currentTool = .select

        let frame = try makeFrame()
        let viewportController = ZoomViewportController()
        viewportController.configure(for: frame, initialZoom: 1)
        let overlayController = OverlayWindowController(
            userSelectedResourceAccess: resourceAccess
        )
        var modeCoordinator: ModeCoordinator?
        overlayController.show(
            frame: frame,
            viewportController: viewportController,
            annotationController: annotationController,
            smoothImage: true,
            drawingToolbarNormalizedPosition: nil,
            drawingToolbarPlacementDidChange: { _ in },
            commandSink: { command in
                modeCoordinator?.handle(command)
            }
        )
        defer {
            overlayController.close()
            defaults.removePersistentDomain(forName: defaultsName)
        }

        guard let canvas = overlayController.canvasViewForTesting else {
            throw SelfTestError.failure("Expected coordinator test canvas")
        }
        canvas.interactionMode = .drawOnly

        let displayManager = SystemDisplayManager()
        modeCoordinator = ModeCoordinator(
            settingsStore: settingsStore,
            permissionService: SystemPermissionService(),
            displayManager: displayManager,
            captureService: ScreenCaptureKitCaptureService(
                displayManager: displayManager
            ),
            overlayController: overlayController,
            annotationController: annotationController,
            viewportController: viewportController,
            userSelectedResourceAccess: resourceAccess,
            initialMode: .drawOnly
        )
        guard let modeCoordinator else {
            throw SelfTestError.failure("Expected coordinator test instance")
        }

        let insertionWritesBeforeExistingEdit =
            annotationController.insertionPointWriteCountForTesting
        modeCoordinator.handle(.editText(textID))
        try expect(
            modeCoordinator.mode == .typing
                && canvas.interactionMode == .typing
                && annotationController.isTypingLocked
                && annotationController.editorStateKind == .editingText
                && annotationController.elementSnapshot.count == 1
                && overlayController.drawingToolbarIsVisibleForTesting
                && overlayController.drawingInspectorIsVisibleForTesting
                && annotationController.insertionPointWriteCountForTesting
                    == insertionWritesBeforeExistingEdit,
            "Expected drawing-to-typing to retain the existing text target, "
                + "toolbar, inspector, single active caret, and no fresh placement write"
        )

        annotationController.insertText("B")
        guard let click = NSEvent.mouseEvent(
            with: .leftMouseDown,
            location: CGPoint(x: 60, y: 60),
            modifierFlags: [],
            timestamp: 0,
            windowNumber: canvas.window?.windowNumber ?? 0,
            context: nil,
            eventNumber: 1,
            clickCount: 1,
            pressure: 0
        ) else {
            throw SelfTestError.failure("Could not create text-edit commit click")
        }
        canvas.mouseDown(with: click)
        try expect(
            modeCoordinator.mode == .drawOnly
                && canvas.interactionMode == .drawOnly
                && annotationController.elementSnapshot.count == 1
                && annotationController.elementSnapshot.first?.textGeometryForTesting?.text == "AB"
                && overlayController.drawingToolbarIsVisibleForTesting
                && overlayController.drawingInspectorIsVisibleForTesting,
            "Expected a click to commit the existing text transaction without "
                + "creating a second element or hiding drawing accessories"
        )

        modeCoordinator.handle(.undo)
        try expect(
            annotationController.elementSnapshot.count == 1
                && annotationController.elementSnapshot.first?.textGeometryForTesting?.text == "A",
            "Expected one undo to revert the coordinator-driven text edit"
        )
        modeCoordinator.handle(.redo)
        try expect(
            annotationController.elementSnapshot.count == 1
                && annotationController.elementSnapshot.first?.textGeometryForTesting?.text == "AB",
            "Expected redo to restore the coordinator-driven text edit"
        )

        modeCoordinator.handle(.editText(textID))
        annotationController.insertText("C")
        guard let escape = NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: [],
            timestamp: 0,
            windowNumber: canvas.window?.windowNumber ?? 0,
            context: nil,
            characters: "\u{1b}",
            charactersIgnoringModifiers: "\u{1b}",
            isARepeat: false,
            keyCode: 53
        ) else {
            throw SelfTestError.failure("Could not create text-edit Escape event")
        }
        canvas.keyDown(with: escape)
        try expect(
            modeCoordinator.mode == .drawOnly
                && annotationController.elementSnapshot.count == 1
                && annotationController.elementSnapshot.first?.textGeometryForTesting?.text == "ABC",
            "Expected Escape to commit the existing text transaction"
        )

        let freshInsertionPoint = CGPoint(x: 146.5, y: 212.25)
        let writesBeforeFreshTyping =
            annotationController.insertionPointWriteCountForTesting
        modeCoordinator.handle(
            .toggleTyping(
                rightAligned: false,
                insertionPoint: freshInsertionPoint
            )
        )
        try expect(
            modeCoordinator.mode == .typing
                && !annotationController.isTypingLocked
                && annotationController.typingCaret()?.origin
                    == freshInsertionPoint
                && annotationController.insertionPointWriteCountForTesting
                    == writesBeforeFreshTyping + 1,
            "Expected the fresh T flow to write its explicit insertion point "
                + "exactly once before publishing typing mode"
        )
        annotationController.insertText("N")
        canvas.keyDown(with: escape)
        try expect(
            annotationController.elementSnapshot.count == 2
                && annotationController.elementSnapshot.first?.textGeometryForTesting?.text == "ABC"
                && annotationController.elementSnapshot.last?.textGeometryForTesting?.text == "N"
                && annotationController.elementSnapshot.last?.textGeometryForTesting?.origin == freshInsertionPoint,
            "Expected fresh T typing to keep creating a new text element"
        )

        modeCoordinator.handle(.editText(AnnotationElementID()))
        try expect(
            modeCoordinator.mode == .drawOnly
                && canvas.interactionMode == .drawOnly
                && overlayController.drawingToolbarIsVisibleForTesting,
            "Expected a failed existing-text edit to restore the prior canvas and mode"
        )
    }

    static func testSingleOwnerTextInsertionPlacement() throws {
        let displayOrigins = [
            CGPoint(x: 420, y: 180),
            CGPoint(x: -1_440, y: -760)
        ]
        let modes: [AppMode] = [.staticZoom, .liveZoom, .drawOnly]
        let clickPoint = CGPoint(x: 112.25, y: 86.75)

        for mode in modes {
            for zoom in [CGFloat(1), 2, 4] {
                for backingScale in [CGFloat(1), 2] {
                    for displayOrigin in displayOrigins {
                        let displayFrame = CGRect(
                            origin: displayOrigin,
                            size: CGSize(width: 320, height: 240)
                        )
                        let frame = try makeFrame(
                            displayFrame: displayFrame,
                            scaleFactor: backingScale
                        )
                        let viewportController = ZoomViewportController()
                        viewportController.configure(
                            for: frame,
                            initialZoom: zoom
                        )
                        let annotationController = AnnotationController()
                        annotationController.currentTool = .text
                        var receivedCommand: AppCommand?
                        var canvasReference: ZoomCanvasView?
                        let canvas = ZoomCanvasView(
                            frame: CGRect(origin: .zero, size: displayFrame.size),
                            capturedFrame: frame,
                            viewportController: viewportController,
                            annotationController: annotationController,
                            smoothImage: true,
                            userSelectedResourceAccess:
                                UserDefaultsUserSelectedResourceAccess(),
                            commandSink: { command in
                                receivedCommand = command
                                guard case .toggleTyping(
                                    let rightAligned,
                                    let insertionPoint?
                                ) = command else {
                                    return
                                }
                                annotationController.setInsertionPoint(
                                    insertionPoint
                                )
                                annotationController.beginTypingSession(
                                    rightAligned: rightAligned
                                )
                                canvasReference?.interactionMode = .typing
                            }
                        )
                        canvasReference = canvas
                        let host = NSWindow(
                            contentRect: displayFrame,
                            styleMask: [.borderless],
                            backing: .buffered,
                            defer: false
                        )
                        host.contentView = canvas
                        host.orderFront(nil)
                        host.makeFirstResponder(canvas)
                        canvas.interactionMode = mode
                        if mode != .drawOnly {
                            canvas.toggleDrawingMode()
                        }

                        let pointerScreenLocation = CGPoint(
                            x: displayFrame.minX + clickPoint.x,
                            y: displayFrame.maxY - clickPoint.y
                        )
                        canvas.setPointerForTesting(
                            viewPoint: clickPoint,
                            screenLocation: pointerScreenLocation
                        )
                        let expectedInsertion = viewportController.contentPoint(
                            for: clickPoint,
                            destinationBounds: canvas.bounds,
                            cursorLocation: pointerScreenLocation
                        )
                        let eventLocation = canvas.convert(clickPoint, to: nil)
                        guard let click = NSEvent.mouseEvent(
                            with: .leftMouseDown,
                            location: eventLocation,
                            modifierFlags: [],
                            timestamp: 0,
                            windowNumber: host.windowNumber,
                            context: nil,
                            eventNumber: 1,
                            clickCount: 1,
                            pressure: 0
                        ) else {
                            host.orderOut(nil)
                            throw SelfTestError.failure(
                                "Could not synthesize exact Text placement click"
                            )
                        }
                        canvas.mouseDown(with: click)
                        annotationController.insertText("X")
                        defer { host.orderOut(nil) }

                        guard case .toggleTyping(
                            rightAligned: false,
                            insertionPoint: let commandInsertion?
                        ) = receivedCommand else {
                            throw SelfTestError.failure(
                                "Expected Text click to carry an explicit insertion point"
                            )
                        }
                        let placedOrigin =
                            annotationController.elementSnapshot.last?.textGeometryForTesting?.origin
                        let context = "\(mode), zoom \(zoom), backing "
                            + "\(backingScale), display \(displayOrigin)"
                        try expect(
                            canvas.isFlipped
                                && approximatelyEqual(
                                    commandInsertion,
                                    expectedInsertion,
                                    tolerance: 0.000_001
                                )
                                && placedOrigin.map {
                                    approximatelyEqual(
                                        $0,
                                        expectedInsertion,
                                        tolerance: 0.000_001
                                    )
                                } == true
                                && annotationController
                                    .insertionPointWriteCountForTesting == 1
                                && canvas.interactionMode == .typing
                                && host.firstResponder === canvas,
                            "Expected one-owner exact Text insertion for \(context)"
                        )
                    }
                }
            }
        }

        guard let keyEvent = NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: [],
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            characters: "t",
            charactersIgnoringModifiers: "t",
            isARepeat: false,
            keyCode: 17
        ) else {
            throw SelfTestError.failure(
                "Could not synthesize the typing shortcut event"
            )
        }
        for mode in [AppMode.drawOnly, .liveZoom] {
            for zoom in [CGFloat(1), 4] {
                for displayOrigin in displayOrigins {
                    let keyboardDisplayFrame = CGRect(
                        origin: displayOrigin,
                        size: CGSize(width: 320, height: 240)
                    )
                    let keyboardFrame = try makeFrame(
                        displayFrame: keyboardDisplayFrame,
                        scaleFactor: 2
                    )
                    let keyboardViewport = ZoomViewportController()
                    keyboardViewport.configure(
                        for: keyboardFrame,
                        initialZoom: zoom
                    )
                    let keyboardController = AnnotationController()
                    var keyboardCommand: AppCommand?
                    let keyboardCanvas = ZoomCanvasView(
                        frame: CGRect(
                            origin: .zero,
                            size: keyboardDisplayFrame.size
                        ),
                        capturedFrame: keyboardFrame,
                        viewportController: keyboardViewport,
                        annotationController: keyboardController,
                        smoothImage: true,
                        userSelectedResourceAccess:
                            UserDefaultsUserSelectedResourceAccess(),
                        commandSink: { keyboardCommand = $0 }
                    )
                    let host = NSWindow(
                        contentRect: keyboardDisplayFrame,
                        styleMask: [.borderless],
                        backing: .buffered,
                        defer: false
                    )
                    host.contentView = keyboardCanvas
                    host.orderFront(nil)
                    defer { host.orderOut(nil) }

                    let frozenZoomAnchor = CGPoint(
                        x: keyboardDisplayFrame.minX + 48,
                        y: keyboardDisplayFrame.maxY - 38
                    )
                    keyboardCanvas.setPointerForTesting(
                        viewPoint: .zero,
                        screenLocation: frozenZoomAnchor
                    )
                    let activationViewPoint = CGPoint(x: 91.5, y: 74.25)
                    let activationScreenPoint = CGPoint(
                        x: keyboardDisplayFrame.minX + activationViewPoint.x,
                        y: keyboardDisplayFrame.maxY - activationViewPoint.y
                    )
                    keyboardCanvas.setMouseLocationForTesting(
                        activationScreenPoint
                    )
                    keyboardCanvas.interactionMode = mode
                    if mode == .liveZoom {
                        keyboardCanvas.toggleDrawingMode()
                    }
                    try expect(
                        approximatelyEqual(
                            keyboardCanvas.pointerViewPointForTesting,
                            activationViewPoint,
                            tolerance: 0.000_001
                        ),
                        "Expected \(mode) drawing activation to synchronize the "
                            + "nonzero global cursor for display \(displayOrigin)"
                    )

                    let movedViewPoint = CGPoint(x: 236.75, y: 168.5)
                    let movedScreenPoint = CGPoint(
                        x: keyboardDisplayFrame.minX + movedViewPoint.x,
                        y: keyboardDisplayFrame.maxY - movedViewPoint.y
                    )
                    keyboardCanvas.setMouseLocationForTesting(movedScreenPoint)
                    let expectedKeyboardInsertion =
                        keyboardViewport.contentPoint(
                            for: movedViewPoint,
                            destinationBounds: keyboardCanvas.bounds,
                            cursorLocation: frozenZoomAnchor
                        )
                    keyboardCanvas.keyDown(with: keyEvent)
                    guard case .toggleTyping(
                        rightAligned: false,
                        insertionPoint: let keyboardInsertion?
                    ) = keyboardCommand else {
                        throw SelfTestError.failure(
                            "Expected T to carry one resolved pointer insertion"
                        )
                    }
                    try expect(
                        approximatelyEqual(
                            keyboardInsertion,
                            expectedKeyboardInsertion,
                            tolerance: 0.000_001
                        ),
                        "Expected keyboard T after \(mode) activation to use the "
                            + "moved global cursor without changing the frozen "
                            + "zoom anchor at \(zoom)x on display \(displayOrigin)"
                    )
                }
            }
        }
    }

    static func testLockedTextEditingBoundaries() throws {
        var lockedText = AnnotationElement.legacy(
            tool: .text,
            points: [CGPoint(x: 20, y: 30)],
            style: .default,
            text: "Locked",
            fontSize: 24
        )
        lockedText.metadata.isLocked = true
        let scene = AnnotationScene(elements: [lockedText])
        let editor = AnnotationEditor(scene: scene)
        let bounds = AnnotationGeometry.localBounds(of: lockedText)
        let textPoint = CGPoint(x: bounds.midX, y: bounds.midY)
        let outcome = editor.beginInteraction(
            at: textPoint,
            zoomScale: 1,
            modifiers: [],
            clickCount: 2
        )
        try expect(
            outcome == .none && editor.stateKind != .editingText,
            "Expected the editor boundary to reject double-click editing for locked text"
        )
        editor.beginTextEditing(elementID: lockedText.id)
        try expect(
            editor.stateKind != .editingText,
            "Expected direct editor text-edit entry to reject locked text"
        )

        let controller = AnnotationController()
        controller.setInsertionPoint(CGPoint(x: 40, y: 40))
        controller.beginTypingSession(rightAligned: false)
        controller.insertText("Locked")
        controller.finishTypingSession()
        guard let textID = controller.elementSnapshot.first?.id else {
            throw SelfTestError.failure("Expected controller locked-text setup")
        }
        controller.currentTool = .select
        _ = controller.beginSelectionInteraction(
            at: CGPoint(x: 45, y: 45),
            zoomScale: 1,
            modifiers: [],
            clickCount: 1
        )
        controller.endSelectionInteraction(at: CGPoint(x: 45, y: 45), modifiers: [])
        controller.toggleSelectionLock()
        try expect(
            controller.elementSnapshot.first?.metadata.isLocked == true
                && !controller.beginEditingText(elementID: textID),
            "Expected the controller boundary to reject locked text editing"
        )
    }

    static func testActiveTextContextualStyleTransaction() throws {
        let controller = AnnotationController()
        controller.currentTool = .text
        controller.setInsertionPoint(CGPoint(x: 8, y: 12))
        controller.beginTypingSession(rightAligned: false)
        controller.insertText("Old")
        controller.finishTypingSession()
        guard let oldTextID = controller.elementSnapshot.first?.id,
              let oldTextStyle = controller.elementSnapshot.first?.style else {
            throw SelfTestError.failure("Expected prior text selection setup")
        }
        controller.currentTool = .select
        controller.selectAll()

        controller.setInsertionPoint(CGPoint(x: 24, y: 36))
        controller.beginTypingSession(rightAligned: false)
        let newTypingState = DrawingToolbarState(annotationController: controller)
        try expect(
            controller.currentTool == .text
                && controller.selectedElementSnapshot.isEmpty
                && newTypingState.currentTool == .text
                && newTypingState.visibleInspectorSections == [
                    .strokeColor,
                    .textFont,
                    .textSize,
                    .textAlignment,
                    .opacity,
                    .layers
                ],
            "Expected a fresh typing session to clear the old selection and "
                + "activate only the Text toolbar and inspector context"
        )
        controller.setTextColor(.palette(.green))
        controller.setOpacity(0.4)
        controller.insertText("Styled")

        controller.beginContinuousStyleEdit(owner: .colorPicker)
        controller.setTextColor(.palette(.blue))
        controller.setOpacity(0.35)
        controller.endContinuousStyleEdit(owner: .colorPicker)

        guard let activeText = controller.elementSnapshot.first(where: {
            $0.id != oldTextID
        }) else {
            throw SelfTestError.failure("Expected an active text element")
        }
        try expect(
            activeText.style.strokeColor == .palette(.blue)
                && activeText.style.opacity == 0.35
                && controller.elementSnapshot.first(where: {
                    $0.id == oldTextID
                })?.style == oldTextStyle,
            "Expected typing-time styles to update the active/new text without "
                + "mutating the previously selected text"
        )

        controller.finishTypingSession()
        controller.undo()
        try expect(
            controller.elementSnapshot.count == 1
                && controller.elementSnapshot.first?.id == oldTextID
                && controller.elementSnapshot.first?.style == oldTextStyle,
            "Expected active text style edits to remain inside the new typing transaction"
        )
        controller.redo()
        try expect(
            controller.elementSnapshot.first(where: {
                $0.id != oldTextID
            })?.style.strokeColor == .palette(.blue)
                && controller.elementSnapshot.first(where: {
                    $0.id != oldTextID
                })?.style.opacity == 0.35,
            "Expected redo to restore text and its contextual style as one transaction"
        )
    }

    static func testTextScopedStyleActionsInMixedSelection() throws {
        let controller = AnnotationController()
        controller.currentTool = .rectangle
        controller.begin(at: CGPoint(x: 10, y: 10))
        controller.end(at: CGPoint(x: 60, y: 60))

        controller.setStrokeColor(.palette(.blue))
        controller.setOpacity(0.8)
        controller.currentTool = .text
        controller.setInsertionPoint(CGPoint(x: 90, y: 20))
        controller.beginTypingSession(rightAligned: false)
        controller.insertText("Text")
        controller.finishTypingSession()

        controller.currentTool = .select
        _ = controller.beginSelectionInteraction(
            at: CGPoint(x: 12, y: 35),
            zoomScale: 1,
            modifiers: [],
            clickCount: 1
        )
        controller.endSelectionInteraction(at: CGPoint(x: 12, y: 35), modifiers: [])
        _ = controller.beginSelectionInteraction(
            at: CGPoint(x: 92, y: 28),
            zoomScale: 1,
            modifiers: [.shift],
            clickCount: 1
        )
        controller.endSelectionInteraction(
            at: CGPoint(x: 92, y: 28),
            modifiers: [.shift]
        )

        let mixedState = DrawingToolbarState(annotationController: controller)
        try expect(
            controller.selectedElementSnapshot.count == 2
                && mixedState.opacity == .mixed
                && mixedState.textColor == .value(.palette(.blue))
                && mixedState.textOpacity == .value(0.8)
                && mixedState.visibleInspectorSections == [
                    .strokeColor,
                    .opacity,
                    .layers
                ],
            "Expected mixed element types to expose only shared, effectful sections"
        )

        controller.setTextColor(.palette(.green))
        controller.setTextOpacity(0.35)
        guard let shape = controller.elementSnapshot.first(where: {
            if case .shape = $0.geometry { return true }
            return false
        }),
        let text = controller.elementSnapshot.first(where: {
            if case .text = $0.geometry { return true }
            return false
        }) else {
            throw SelfTestError.failure("Expected shape and text elements in mixed selection")
        }
        try expect(
            shape.style.strokeColor == .palette(.red)
                && shape.style.opacity == 1
                && text.style.strokeColor == .palette(.green)
                && text.style.opacity == 0.35,
            "Expected Text color and opacity controls to leave mixed-selection shapes unchanged"
        )

        controller.setStrokeColor(.palette(.yellow))
        controller.setOpacity(0.6)
        try expect(
            controller.elementSnapshot.allSatisfy {
                $0.style.strokeColor == .palette(.yellow) && $0.style.opacity == 0.6
            },
            "Expected general Stroke color and opacity controls to remain global"
        )
    }

    static func testTypingAnnotations() throws {
        let controller = AnnotationController()
        controller.setInsertionPoint(CGPoint(x: 20, y: 30))

        controller.insertText("H")
        controller.insertText("i")

        try expect(controller.elementSnapshot.count == 1, "Expected one text annotation")
        try expect(controller.elementSnapshot[0].textGeometryForTesting != nil, "Expected text annotation tool")
        try expect(controller.elementSnapshot[0].textGeometryForTesting?.origin == CGPoint(x: 20, y: 30), "Unexpected text insertion point")
        try expect(controller.elementSnapshot[0].textGeometryForTesting?.text == "Hi", "Expected text to append")

        controller.deleteBackward()

        try expect(controller.elementSnapshot[0].textGeometryForTesting?.text == "H", "Expected deleteBackward to remove one character")
        controller.undo()
        try expect(controller.elementSnapshot.isEmpty, "Expected undo to remove the active text annotation")
        controller.redo()
        try expect(controller.elementSnapshot[0].textGeometryForTesting?.text == "H", "Expected redo to restore the latest typed text")
        let textPixels = try renderPixels(
            elements: controller.elementSnapshot,
            renderer: AnnotationRenderer()
        )
        guard let glyphBounds = paintedBounds(
            textPixels,
            width: 96,
            height: 96
        ) else {
            throw SelfTestError.failure("Expected native text glyph ink")
        }
        try expect(
            glyphBounds.minY > 30 && glyphBounds.minY < 45,
            "Expected native glyph ink to keep its normal baseline inset "
                + "separate from the exact text origin"
        )
    }
}
