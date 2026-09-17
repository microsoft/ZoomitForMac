import AppKit

extension SelfTestRunner {
    static func testShapeAnnotationEndpointReplacement() throws {
        let controller = AnnotationController()
        controller.currentTool = .rectangle

        controller.begin(at: CGPoint(x: 10, y: 20))
        controller.update(at: CGPoint(x: 30, y: 40))
        controller.update(at: CGPoint(x: 50, y: 60))
        controller.end(at: CGPoint(x: 70, y: 80))

        try expect(controller.elementSnapshot.count == 1, "Expected one rectangle annotation")
        guard case .shape(let shape) = controller.elementSnapshot[0].geometry else {
            throw SelfTestError.failure("Expected rectangle geometry")
        }
        try expect(
            shape.start == CGPoint(x: 10, y: 20) && shape.end == CGPoint(x: 70, y: 80),
            "Shape should keep start and final endpoint"
        )
    }

    static func testAxisAlignedShapeCreation() throws {
        let anchor = CGPoint(x: 100, y: 100)
        let endpoints = [
            CGPoint(x: 145, y: 160),
            CGPoint(x: 55, y: 160),
            CGPoint(x: 145, y: 40),
            CGPoint(x: 55, y: 40)
        ]

        for tool in [AnnotationTool.rectangle, .diamond] {
            for endpoint in endpoints {
                let controller = AnnotationController()
                controller.begin(at: anchor, tool: tool)
                controller.update(at: endpoint)
                guard let preview = controller.inProgressElementSnapshot,
                      case .shape(let previewShape) = preview.geometry else {
                    throw SelfTestError.failure("Expected an in-progress axis-aligned shape")
                }
                let expectedBounds = CGRect(
                    x: min(anchor.x, endpoint.x),
                    y: min(anchor.y, endpoint.y),
                    width: abs(endpoint.x - anchor.x),
                    height: abs(endpoint.y - anchor.y)
                )
                try expect(
                    previewShape.start == expectedBounds.origin
                        && previewShape.end == CGPoint(
                            x: expectedBounds.maxX,
                            y: expectedBounds.maxY
                        )
                        && preview.metadata.rotation == 0,
                    "Expected \(tool) preview to use canonical bounds in every drag quadrant"
                )

                controller.end(at: endpoint)
                guard let committed = controller.elementSnapshot.first,
                      case .shape(let committedShape) = committed.geometry else {
                    throw SelfTestError.failure("Expected a committed axis-aligned shape")
                }
                try expect(
                    committedShape == previewShape && committed.metadata.rotation == 0,
                    "Expected \(tool) committed geometry to exactly match its aligned preview"
                )
            }
        }

        for tool in [AnnotationTool.rectangle, .diamond] {
            for endpoint in endpoints {
                let controller = AnnotationController()
                controller.begin(at: anchor, tool: tool)
                controller.update(at: endpoint, constrainShapeAspect: true)
                guard let preview = controller.inProgressElementSnapshot,
                      case .shape(let previewShape) = preview.geometry else {
                    throw SelfTestError.failure("Expected a constrained shape preview")
                }
                let side = max(abs(endpoint.x - anchor.x), abs(endpoint.y - anchor.y))
                let constrainedEndpoint = CGPoint(
                    x: anchor.x + (endpoint.x < anchor.x ? -side : side),
                    y: anchor.y + (endpoint.y < anchor.y ? -side : side)
                )
                let expectedBounds = CGRect(
                    x: min(anchor.x, constrainedEndpoint.x),
                    y: min(anchor.y, constrainedEndpoint.y),
                    width: side,
                    height: side
                )
                try expect(
                    previewShape.bounds == expectedBounds,
                    "Expected Shift-\(tool) to preserve the anchor and drag quadrant"
                )
                controller.end(at: endpoint, constrainShapeAspect: true)
                guard let committed = controller.elementSnapshot.first,
                      case .shape(let committedShape) = committed.geometry else {
                    throw SelfTestError.failure("Expected a committed constrained shape")
                }
                try expect(
                    committedShape == previewShape
                        && committedShape.bounds.width == committedShape.bounds.height
                        && committed.metadata.rotation == 0,
                    "Expected Shift-\(tool) preview and commit to remain the same aligned square"
                )
            }
        }

        let legacyRectangle = AnnotationController()
        legacyRectangle.begin(
            at: anchor,
            tool: .rectangle,
            legacyModifierGesture: true
        )
        legacyRectangle.end(at: CGPoint(x: 42, y: 168))
        guard let legacyElement = legacyRectangle.elementSnapshot.first,
              case .shape(let legacyShape) = legacyElement.geometry else {
            throw SelfTestError.failure("Expected a legacy modifier rectangle")
        }
        try expect(
            legacyShape.bounds == CGRect(x: 42, y: 100, width: 58, height: 68)
                && legacyShape.start == legacyShape.bounds.origin
                && legacyElement.metadata.rotation == 0,
            "Expected the existing Control-drag rectangle to remain canonically axis-aligned"
        )
        try expect(
            ZoomCanvasView.gestureTool(
                control: false,
                shift: true,
                tab: false,
                selectedTool: .rectangle
            ) == nil
                && ZoomCanvasView.gestureTool(
                    control: false,
                    shift: true,
                    tab: false,
                    selectedTool: .diamond
                ) == nil,
            "Expected Shift to constrain direct rectangle and diamond tools instead of switching tools"
        )

        let rotationController = AnnotationController()
        rotationController.begin(at: CGPoint(x: 30, y: 40), tool: .rectangle)
        rotationController.end(at: CGPoint(x: 110, y: 90))
        guard let original = rotationController.elementSnapshot.first,
              case .shape(let originalShape) = original.geometry else {
            throw SelfTestError.failure("Expected an aligned rectangle before explicit rotation")
        }
        rotationController.currentTool = .select
        let selectionPoint = CGPoint(
            x: originalShape.bounds.minX,
            y: originalShape.bounds.midY
        )
        _ = rotationController.beginSelectionInteraction(
            at: selectionPoint,
            zoomScale: 1,
            modifiers: [],
            clickCount: 1
        )
        rotationController.endSelectionInteraction(at: selectionPoint, modifiers: [])
        guard let selected = rotationController.elementSnapshot.first,
              let rotationHandle = AnnotationGeometry.selectionDecoration(
                  for: selected,
                  zoomScale: 1
              )?.handles.first(where: { $0.kind == .rotation }) else {
            throw SelfTestError.failure("Expected an explicit rotation handle on the aligned shape")
        }
        _ = rotationController.beginSelectionInteraction(
            at: rotationHandle.center,
            zoomScale: 1,
            modifiers: [],
            clickCount: 1
        )
        rotationController.endSelectionInteraction(
            at: CGPoint(x: originalShape.bounds.maxX + 30, y: originalShape.bounds.midY),
            modifiers: []
        )
        guard let rotated = rotationController.elementSnapshot.first,
              case .shape(let rotatedShape) = rotated.geometry else {
            throw SelfTestError.failure("Expected the explicitly rotated rectangle")
        }
        try expect(
            rotated.metadata.rotation != 0 && rotatedShape == originalShape,
            "Expected later rotation-handle edits to preserve canonical shape geometry"
        )
    }

    static func testUndoAndClear() throws {
        let controller = AnnotationController()

        controller.begin(at: .zero)
        controller.end(at: CGPoint(x: 1, y: 1))
        controller.begin(at: CGPoint(x: 2, y: 2))
        controller.end(at: CGPoint(x: 3, y: 3))

        try expect(controller.elementSnapshot.count == 2, "Expected two annotations before undo")
        controller.undo()
        try expect(controller.elementSnapshot.count == 1, "Expected one annotation after undo")
        try expect(controller.canRedo, "Expected undo to enable redo")
        controller.redo()
        try expect(controller.elementSnapshot.count == 2, "Expected redo to restore the annotation")
        controller.clear()
        try expect(controller.elementSnapshot.isEmpty, "Expected no annotations after clear")
        controller.undo()
        try expect(controller.elementSnapshot.count == 2, "Expected undo to restore a cleared scene")
        controller.redo()
        try expect(controller.elementSnapshot.isEmpty, "Expected redo to clear the scene again")
    }

    static func testClearCancelsTransientAnnotationState() throws {
        let queuedController = AnnotationController()
        var smartDefaults = DrawingDefaults.default
        smartDefaults.smartDrawEnabled = true
        smartDefaults.pressureMode = .simulated
        queuedController.applyDrawingDefaults(smartDefaults, strokeWidth: 5)
        queuedController.begin(
            at: CGPoint(x: 4, y: 32),
            pressure: nil,
            timestamp: 0,
            zoomScale: 1
        )
        for index in 1...12 {
            queuedController.update(
                at: CGPoint(x: 4 + CGFloat(index * 8), y: 32),
                timestamp: Double(index) / 30,
                zoomScale: 1
            )
        }
        queuedController.enqueueFreehandInputs([
            AnnotationRawFreehandInput(
                location: CGPoint(x: 300, y: 32),
                pressure: nil,
                timestamp: 0.5
            ),
            AnnotationRawFreehandInput(
                location: CGPoint(x: 600, y: 32),
                pressure: nil,
                timestamp: 0.6
            )
        ])
        _ = queuedController.drainFreehandInput(
            zoomScale: 1,
            budget: AnnotationFreehandDrainBudget(
                maximumRawEvents: 1,
                maximumGeneratedSamples: 1
            )
        )

        let width = 128
        let height = 64
        let bytesPerPixel = 4
        var pixels = [UInt8](repeating: 0, count: width * height * bytesPerPixel)
        guard let context = CGContext(
            data: &pixels,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * bytesPerPixel,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            throw SelfTestError.failure("Could not create clear-state render context")
        }
        queuedController.render(
            in: context,
            bounds: CGRect(x: 0, y: 0, width: width, height: height)
        )
        try expect(
            queuedController.hasPendingFreehandInput
                && queuedController.hasPendingSmartDrawRecognitionForTesting
                && queuedController.hasPendingTransientAnnotationWorkForTesting,
            "Expected queued interpolation, pressure, Smart Draw, and render cache state before clear"
        )

        queuedController.clear()
        let postClearDrain = queuedController.drainFreehandInput(zoomScale: 1)
        try expect(
            queuedController.elementSnapshot.isEmpty
                && queuedController.inProgressElementSnapshot == nil
                && queuedController.smartDrawPreviewElementSnapshot == nil
                && !queuedController.hasPendingFreehandInput
                && !queuedController.hasPendingSmartDrawRecognitionForTesting
                && !queuedController.hasPendingTransientAnnotationWorkForTesting
                && queuedController.editorStateKind == .idle
                && !queuedController.hasActiveDrawingGesture
                && postClearDrain == AnnotationFreehandDrainStats()
                && !queuedController.canUndo,
            "Expected clear to cancel every queued creation state without committing a partial stroke"
        )
        queuedController.clear()
        try expect(
            !queuedController.hasPendingTransientAnnotationWorkForTesting
                && !queuedController.canUndo,
            "Expected repeated clear cancellation to remain idempotent"
        )

        let timerController = AnnotationController()
        let timerCanvas = try makeCanvas(annotationController: timerController)
        timerController.onStateChanged = { [weak timerCanvas] in
            timerCanvas?.annotationStateDidChange()
        }
        timerCanvas.interactionMode = .drawOnly
        guard let mouseDown = NSEvent.mouseEvent(
            with: .leftMouseDown,
            location: CGPoint(x: 4, y: 20),
            modifierFlags: [],
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            eventNumber: 1,
            clickCount: 1,
            pressure: 0
        ), let mouseDragged = NSEvent.mouseEvent(
            with: .leftMouseDragged,
            location: CGPoint(x: 100, y: 20),
            modifierFlags: [],
            timestamp: 0.1,
            windowNumber: 0,
            context: nil,
            eventNumber: 2,
            clickCount: 1,
            pressure: 0
        ) else {
            throw SelfTestError.failure("Could not create clear-state pointer events")
        }
        timerCanvas.mouseDown(with: mouseDown)
        timerCanvas.mouseDragged(with: mouseDragged)
        try expect(
            timerCanvas.hasActiveFreehandDrainTimerForTesting
                && timerCanvas.hasPendingAnnotationInputForTesting,
            "Expected the freehand drain timer to be active before clear"
        )
        timerController.clear()
        try expect(
            !timerController.hasPendingFreehandInput
                && !timerCanvas.hasActiveFreehandDrainTimerForTesting
                && !timerCanvas.hasPendingAnnotationInputForTesting,
            "Expected clear to stop the canvas timer and pending end state immediately"
        )
        timerCanvas.prepareForClose()

        let eraserController = AnnotationController()
        eraserController.currentTool = .rectangle
        eraserController.begin(at: CGPoint(x: 10, y: 10))
        eraserController.end(at: CGPoint(x: 50, y: 50))
        eraserController.begin(at: CGPoint(x: 70, y: 10))
        eraserController.end(at: CGPoint(x: 110, y: 50))
        eraserController.beginErasing(
            at: CGPoint(x: 10, y: 30),
            zoomScale: 1
        )
        try expect(
            eraserController.elementSnapshot.count == 2
                && eraserController.pendingErasureElementIDsForTesting.count == 1
                && eraserController.hasActiveDrawingGesture,
            "Expected eraser hits to remain staged before clear"
        )
        eraserController.clear()
        eraserController.clear()
        try expect(
            eraserController.elementSnapshot.isEmpty
                && !eraserController.hasPendingTransientAnnotationWorkForTesting,
            "Expected clear to cancel the eraser transaction before clearing the scene"
        )
        eraserController.undo()
        try expect(
            eraserController.elementSnapshot.count == 2,
            "Expected one undo to restore the complete pre-eraser scene"
        )
        eraserController.undo()
        try expect(
            eraserController.elementSnapshot.count == 1,
            "Expected normal history to continue before the clear operation"
        )
        eraserController.redo()
        eraserController.redo()
        try expect(
            eraserController.elementSnapshot.isEmpty,
            "Expected normal redo history to reapply creation and clear without a stale transaction"
        )
    }

    static func testAnnotationSceneCreationAndStableIDs() throws {
        let scene = AnnotationScene()
        let elementID = AnnotationElementID()
        let element = AnnotationElement.legacy(
            id: elementID,
            tool: .pen,
            points: [CGPoint(x: 1, y: 2), CGPoint(x: 3, y: 4)],
            style: .default
        )

        scene.append(element)
        try expect(scene.elements.count == 1, "Expected one scene element")
        try expect(scene.elements[0].id == elementID, "Expected the scene to preserve the element ID")
        guard case .freehand(let freehand) = scene.elements[0].geometry else {
            throw SelfTestError.failure("Expected typed freehand geometry")
        }
        try expect(
            freehand.samples.map(\.location) == [CGPoint(x: 1, y: 2), CGPoint(x: 3, y: 4)],
            "Expected freehand samples to preserve legacy points"
        )

        scene.updateElement(withID: elementID) { element in
            element.metadata.rotation = .pi / 4
        }
        try expect(scene.elements[0].id == elementID, "Expected element edits to retain the stable ID")
    }

    static func testAnnotationSceneTransactionalHistory() throws {
        let scene = AnnotationScene()
        let first = AnnotationElement.legacy(
            tool: .line,
            points: [.zero, CGPoint(x: 10, y: 10)],
            style: .default
        )
        let second = AnnotationElement.legacy(
            tool: .ellipse,
            points: [CGPoint(x: 20, y: 20), CGPoint(x: 40, y: 50)],
            style: .default
        )

        scene.beginTransaction()
        scene.append(first)
        scene.append(second)
        scene.commitTransaction()

        try expect(scene.elements.map(\.id) == [first.id, second.id], "Expected both transaction elements")
        try expect(scene.undo(), "Expected the transaction to be undoable")
        try expect(scene.elements.isEmpty, "Expected one undo to revert the entire transaction")
        try expect(scene.redo(), "Expected the transaction to be redoable")
        try expect(scene.elements.map(\.id) == [first.id, second.id], "Expected redo to restore stable IDs")

        let third = AnnotationElement.legacy(
            tool: .rectangle,
            points: [CGPoint(x: 60, y: 60), CGPoint(x: 80, y: 80)],
            style: .default
        )
        try expect(scene.undo(), "Expected a second undo before branching history")
        scene.append(third)
        try expect(!scene.canRedo, "Expected a new mutation to discard the redo branch")
    }

    static func testAnnotationSceneOrdering() throws {
        let scene = AnnotationScene()
        let first = AnnotationElement.legacy(tool: .pen, points: [.zero], style: .default)
        let second = AnnotationElement.legacy(tool: .line, points: [.zero], style: .default)
        let third = AnnotationElement.legacy(tool: .ellipse, points: [.zero], style: .default)
        scene.append(first)
        scene.append(second)
        scene.append(third)

        scene.moveElements(withIDs: [second.id], to: 0)
        try expect(
            scene.elements.map(\.id) == [second.id, first.id, third.id],
            "Expected scene ordering to move the requested element"
        )

        try expect(scene.undo(), "Expected ordering to be undoable")
        try expect(
            scene.elements.map(\.id) == [first.id, second.id, third.id],
            "Expected undo to restore the previous ordering"
        )
    }

    static func testAnnotationSceneGroupingAndLocking() throws {
        let scene = AnnotationScene()
        let first = AnnotationElement.legacy(tool: .rectangle, points: [.zero], style: .default)
        let second = AnnotationElement.legacy(tool: .ellipse, points: [.zero], style: .default)
        let third = AnnotationElement.legacy(tool: .pen, points: [.zero], style: .default)
        scene.append(first)
        scene.append(second)
        scene.append(third)

        guard let groupID = scene.groupElements(withIDs: [first.id, second.id]) else {
            throw SelfTestError.failure("Expected two elements to form a group")
        }
        scene.setLocked(true, for: [first.id, second.id])
        scene.select([first.id, third.id, AnnotationElementID()])

        try expect(
            scene.element(withID: first.id)?.metadata.groupIDs == [groupID]
                && scene.element(withID: second.id)?.metadata.groupIDs == [groupID],
            "Expected grouped elements to share group metadata"
        )
        try expect(
            scene.element(withID: third.id)?.metadata.groupIDs.isEmpty == true,
            "Expected ungrouped elements to remain unchanged"
        )
        try expect(
            scene.element(withID: first.id)?.metadata.isLocked == true
                && scene.element(withID: second.id)?.metadata.isLocked == true,
            "Expected lock metadata on the requested elements"
        )
        try expect(
            scene.selection.contains(first.id)
                && scene.selection.contains(third.id)
                && scene.selection.elementIDs.count == 2,
            "Expected selection to retain only IDs present in the scene"
        )
    }

    static func testAnnotationSceneBindingIntegrity() throws {
        let scene = AnnotationScene()
        let targetID = AnnotationElementID()
        let target = AnnotationElement(
            id: targetID,
            geometry: .shape(
                AnnotationShapeGeometry(
                    kind: .rectangle,
                    start: CGPoint(x: 10, y: 10),
                    end: CGPoint(x: 50, y: 50)
                )
            ),
            style: .default
        )
        let lineID = AnnotationElementID()
        let line = AnnotationElement(
            id: lineID,
            geometry: .linear(
                AnnotationLinearGeometry(
                    points: [CGPoint(x: 30, y: 30), CGPoint(x: 80, y: 80)],
                    route: .straight,
                    startArrowhead: .none,
                    endArrowhead: .arrow,
                    startBinding: AnnotationBinding(targetElementID: targetID),
                    endBinding: nil
                )
            ),
            style: .default
        )
        scene.append(target)
        scene.append(line)

        guard case .linear(let boundLine) = scene.element(withID: lineID)?.geometry else {
            throw SelfTestError.failure("Expected a linear element")
        }
        try expect(boundLine.startBinding?.targetElementID == targetID, "Expected a valid binding to be retained")

        scene.removeElements(withIDs: [targetID])
        guard case .linear(let unboundLine) = scene.element(withID: lineID)?.geometry else {
            throw SelfTestError.failure("Expected the line to remain after deleting its target")
        }
        try expect(unboundLine.startBinding == nil, "Expected deletion to remove dangling bindings")

        try expect(scene.undo(), "Expected target deletion to be undoable")
        guard case .linear(let restoredLine) = scene.element(withID: lineID)?.geometry else {
            throw SelfTestError.failure("Expected the line after undo")
        }
        try expect(
            scene.element(withID: targetID) != nil && restoredLine.startBinding?.targetElementID == targetID,
            "Expected undo to restore the target and its binding"
        )
    }
}
