import AppKit

extension SelfTestRunner {
    static func testAdvancedLinearPointEditing() throws {
        let scene = AnnotationScene()
        let line = AnnotationElement(
            geometry: .linear(
                AnnotationLinearGeometry(
                    points: [
                        CGPoint(x: 0, y: 0),
                        CGPoint(x: 50, y: 0),
                        CGPoint(x: 100, y: 0)
                    ],
                    route: .straight,
                    startArrowhead: .none,
                    endArrowhead: .arrow,
                    startBinding: nil,
                    endBinding: nil
                )
            ),
            style: AnnotationStyle(color: .red, rootWidth: 2, alpha: 1)
        )
        scene.append(line)
        scene.select([line.id])
        let editor = AnnotationEditor(scene: scene)

        try expect(
            editor.beginLinearPointEditing(),
            "Expected a selected multi-point line to enter point-edit mode"
        )
        try expect(
            editor.stateKind == .editingLinearPoints,
            "Expected an explicit linear point-edit state"
        )

        _ = editor.beginInteraction(
            at: CGPoint(x: 50, y: 0),
            zoomScale: 1,
            modifiers: [],
            clickCount: 1
        )
        editor.updateInteraction(to: CGPoint(x: 50, y: 20), modifiers: [])
        editor.endInteraction(at: CGPoint(x: 50, y: 20), modifiers: [])
        guard case .linear(let dragged) = scene.element(withID: line.id)?.geometry else {
            throw SelfTestError.failure("Expected dragged multi-point geometry")
        }

        try expect(
            dragged.points == [
                CGPoint(x: 0, y: 0),
                CGPoint(x: 50, y: 20),
                CGPoint(x: 100, y: 0)
            ],
            "Expected individual point dragging to preserve the other local path points"
        )

        _ = editor.beginInteraction(
            at: CGPoint(x: 25, y: 10),
            zoomScale: 1,
            modifiers: [],
            clickCount: 2
        )
        editor.endInteraction(at: CGPoint(x: 25, y: 10), modifiers: [])
        guard case .linear(let inserted) = scene.element(withID: line.id)?.geometry else {
            throw SelfTestError.failure("Expected point insertion geometry")
        }
        try expect(
            inserted.points.count == 4 && inserted.points[1] == CGPoint(x: 25, y: 10),
            "Expected double-clicking a segment to insert a point at the selected location"
        )

        editor.removeSelectedLinearPoints()
        guard case .linear(let removed) = scene.element(withID: line.id)?.geometry else {
            throw SelfTestError.failure("Expected point removal geometry")
        }
        try expect(
            removed.points.count == 3,
            "Expected selected point removal while retaining a valid two-or-more-point path"
        )

        _ = editor.beginInteraction(
            at: CGPoint(x: 75, y: 10),
            zoomScale: 1,
            modifiers: [],
            clickCount: 1
        )
        editor.updateInteraction(to: CGPoint(x: 75, y: 30), modifiers: [])
        editor.endInteraction(at: CGPoint(x: 75, y: 30), modifiers: [])
        guard case .linear(let movedSegment) = scene.element(withID: line.id)?.geometry else {
            throw SelfTestError.failure("Expected segment drag geometry")
        }
        try expect(
            movedSegment.points[1] == CGPoint(x: 50, y: 40)
                && movedSegment.points[2] == CGPoint(x: 100, y: 20),
            "Expected segment dragging to move both adjacent points as one transaction"
        )
        try expect(scene.undo(), "Expected the segment drag to be undoable")
        try expect(
            editor.stateKind == .editingLinearPoints,
            "Expected point-edit mode to remain active after a completed point transaction"
        )
        editor.finishLinearPointEditing()
        try expect(editor.stateKind == .idle, "Expected point-edit mode to exit explicitly")
    }

    static func testLinearPointEditingRevalidation() throws {
        func makeEditingLine() -> (
            scene: AnnotationScene,
            editor: AnnotationEditor,
            elementID: AnnotationElementID
        ) {
            let line = AnnotationElement(
                geometry: .linear(
                    AnnotationLinearGeometry(
                        points: [
                            CGPoint(x: 0, y: 0),
                            CGPoint(x: 50, y: 0),
                            CGPoint(x: 100, y: 0)
                        ],
                        route: .straight,
                        startArrowhead: .none,
                        endArrowhead: .arrow,
                        startBinding: nil,
                        endBinding: nil
                    )
                ),
                style: .default
            )
            let scene = AnnotationScene(elements: [line])
            scene.select([line.id])
            let editor = AnnotationEditor(scene: scene)
            _ = editor.beginLinearPointEditing()
            return (scene, editor, line.id)
        }

        do {
            let setup = makeEditingLine()
            setup.scene.setLocked(true, for: [setup.elementID])
            let locked = setup.scene.snapshot
            _ = setup.editor.beginInteraction(
                at: CGPoint(x: 50, y: 0),
                zoomScale: 1,
                modifiers: [],
                clickCount: 1
            )
            setup.editor.updateInteraction(to: CGPoint(x: 50, y: 30), modifiers: [])
            setup.editor.endInteraction(at: CGPoint(x: 50, y: 30), modifiers: [])
            try expect(
                setup.scene.snapshot == locked && setup.editor.stateKind == .idle,
                "Expected locked targets to block point dragging and exit point-edit mode"
            )
        }

        do {
            let setup = makeEditingLine()
            setup.scene.setLocked(true, for: [setup.elementID])
            let locked = setup.scene.snapshot
            _ = setup.editor.beginInteraction(
                at: CGPoint(x: 25, y: 0),
                zoomScale: 1,
                modifiers: [],
                clickCount: 2
            )
            try expect(
                setup.scene.snapshot == locked && setup.editor.stateKind == .idle,
                "Expected locked targets to block double-click point insertion"
            )
        }

        do {
            let setup = makeEditingLine()
            _ = setup.editor.beginInteraction(
                at: CGPoint(x: 25, y: 0),
                zoomScale: 1,
                modifiers: [],
                clickCount: 1
            )
            setup.editor.endInteraction(at: CGPoint(x: 25, y: 0), modifiers: [])
            setup.scene.setLocked(true, for: [setup.elementID])
            let locked = setup.scene.snapshot
            setup.editor.insertLinearPoint()
            try expect(
                setup.scene.snapshot == locked && setup.editor.stateKind == .idle,
                "Expected locked targets to block explicit point insertion"
            )
        }

        do {
            let setup = makeEditingLine()
            _ = setup.editor.beginInteraction(
                at: CGPoint(x: 50, y: 0),
                zoomScale: 1,
                modifiers: [],
                clickCount: 1
            )
            setup.editor.endInteraction(at: CGPoint(x: 50, y: 0), modifiers: [])
            setup.scene.setLocked(true, for: [setup.elementID])
            let locked = setup.scene.snapshot
            setup.editor.removeSelectedLinearPoints()
            try expect(
                setup.scene.snapshot == locked && setup.editor.stateKind == .idle,
                "Expected locked targets to block point removal"
            )
        }

        let controller = AnnotationController()
        controller.currentTool = .line
        controller.begin(at: CGPoint(x: 0, y: 0))
        controller.update(at: CGPoint(x: 100, y: 0))
        controller.end(at: CGPoint(x: 100, y: 0))
        controller.currentTool = .select
        if controller.isEditingLinearPoints {
            _ = controller.toggleLinearPointEditing()
        }
        controller.selectAll()
        controller.toggleSelectionLock()
        controller.toggleSelectionLock()
        try expect(
            controller.toggleLinearPointEditing(),
            "Expected the unlocked line to re-enter point-edit mode"
        )
        controller.undo()
        try expect(
            controller.elementSnapshot.first?.metadata.isLocked == true
                && !controller.isEditingLinearPoints,
            "Expected undo restoring a lock to exit point-edit mode immediately"
        )
    }

    static func testPassiveLinearPointDiscovery() throws {
        let controller = AnnotationController()
        controller.currentTool = .line
        controller.begin(at: CGPoint(x: 16, y: 40))
        controller.update(at: CGPoint(x: 96, y: 40))
        controller.end(at: CGPoint(x: 96, y: 40))
        controller.currentTool = .select
        if controller.isEditingLinearPoints {
            _ = controller.toggleLinearPointEditing()
        }
        let passiveState = DrawingToolbarState(annotationController: controller)
        try expect(
            controller.hasSelection
                && !controller.isEditingLinearPoints
                && controller.linearPointDecorationElement != nil
                && passiveState.showsLinearPointHandles
                && !passiveState.canInsertLinearPoint
                && !passiveState.canRemoveLinearPoints
                && !passiveState.canUnbindLinearEndpoints,
            "Expected selected unbound lines to expose passive handles while disabling no-op actions "
                + "(selection \(controller.hasSelection), editing \(controller.isEditingLinearPoints), "
                + "decoration \(controller.linearPointDecorationElement != nil), "
                + "state handles \(passiveState.showsLinearPointHandles), "
                + "insert \(passiveState.canInsertLinearPoint), "
                + "remove \(passiveState.canRemoveLinearPoints), "
                + "unbind \(passiveState.canUnbindLinearEndpoints))"
        )
        let inspector = DrawingPropertiesController(
            commandSink: { _ in },
            colorPanelActivityChanged: { _ in }
        )
        inspector.update(state: passiveState)
        _ = inspector.visibleSectionFramesForTesting()
        let inspectorButtons = descendantViews(of: NSButton.self, in: inspector.view)
        try expect(
            ["Edit Points", "Insert Point", "Remove Points", "Unbind Ends"].allSatisfy {
                label in
                !inspectorButtons.contains { $0.accessibilityLabel() == label }
            },
            "Expected point-editing actions to remain in context and overflow menus"
        )
        let decorationPixels = try renderSelectionPixels(
            annotationController: controller,
            width: 112,
            height: 80
        )
        try expect(
            hasPaintedPixel(
                decorationPixels,
                width: 112,
                height: 80,
                near: CGPoint(x: 16, y: 40),
                radius: 5
            )
                && hasPaintedPixel(
                    decorationPixels,
                    width: 112,
                    height: 80,
                    near: CGPoint(x: 96, y: 40),
                    radius: 5
                ),
            "Expected passive Select-mode endpoint dots to remain visibly rendered"
        )

        var curved = AnnotationLinearGeometry(
            points: [
                CGPoint(x: 16, y: 60),
                CGPoint(x: 56, y: 18),
                CGPoint(x: 100, y: 60)
            ],
            route: .curved,
            startArrowhead: .circleOutline,
            endArrowhead: .arrow,
            startBinding: nil,
            endBinding: nil
        )
        curved.bezierControls = AnnotationGeometry.bezierControls(for: curved)
        let curveElement = AnnotationElement(
            geometry: .linear(curved),
            style: .default
        )
        let scene = AnnotationScene(elements: [curveElement])
        scene.select([curveElement.id])
        let editor = AnnotationEditor(scene: scene)
        let controlPoint = curved.bezierControls[0].start
        _ = editor.beginInteraction(
            at: controlPoint,
            zoomScale: 1,
            modifiers: [],
            clickCount: 1
        )
        try expect(
            editor.stateKind == .editingLinearPoints
                && editor.selectedLinearControl
                    == .control(segment: 0, end: .start),
            "Expected clicking a visible Bezier control to enter point editing directly"
        )
        editor.updateInteraction(
            to: CGPoint(x: controlPoint.x + 12, y: controlPoint.y - 8),
            modifiers: []
        )
        editor.endInteraction(
            at: CGPoint(x: controlPoint.x + 12, y: controlPoint.y - 8),
            modifiers: []
        )
        guard case .linear(let editedCurve) = scene.element(
            withID: curveElement.id
        )?.geometry else {
            throw SelfTestError.failure("Expected edited curve geometry")
        }
        try expect(
            editedCurve.bezierControls[0].start != controlPoint,
            "Expected dragging a passive control dot to mutate the curve"
        )

        editor.finishLinearPointEditing()
        let endpoint = editedCurve.points[0]
        _ = editor.beginInteraction(
            at: endpoint,
            zoomScale: 1,
            modifiers: [],
            clickCount: 1
        )
        try expect(
            editor.stateKind == .editingLinearPoints
                && editor.selectedLinearPointIndices == [0],
            "Expected clicking a visible endpoint dot to enter point editing directly"
        )
    }

    static func testBezierLinearGeometry() throws {
        let linear = AnnotationLinearGeometry(
            points: [
                CGPoint(x: 0, y: 0),
                CGPoint(x: 50, y: 0),
                CGPoint(x: 100, y: 0)
            ],
            route: .curved,
            startArrowhead: .circle,
            endArrowhead: .triangle,
            startBinding: nil,
            endBinding: nil,
            bezierControls: [
                AnnotationBezierControl(
                    start: CGPoint(x: 0, y: 40),
                    end: CGPoint(x: 50, y: 40)
                ),
                AnnotationBezierControl(
                    start: CGPoint(x: 50, y: -40),
                    end: CGPoint(x: 100, y: -40)
                )
            ]
        )
        let displayPoints = AnnotationGeometry.linearDisplayPoints(linear, subdivisions: 16)
        try expect(
            displayPoints.count == 33
                && displayPoints.map(\.y).max()! > 20
                && displayPoints.map(\.y).min()! < -20,
            "Expected editable cubic controls to produce deterministic curved segments"
        )
        try expect(
            AnnotationGeometry.linearPath(linear).boundingBoxOfPath.height > 40,
            "Expected curved-path bounds to include Bezier extrema"
        )

        let insertion = AnnotationLinearLocation(
            segmentIndex: 0,
            parameter: 0.5,
            point: .zero,
            distance: 0
        )
        let split = AnnotationGeometry.insertingPoint(into: linear, at: insertion)
        try expect(
            split.points.count == 4
                && split.bezierControls.count == 3
                && approximatelyEqual(split.points[1], CGPoint(x: 25, y: 30)),
            "Expected de Casteljau insertion to preserve an editable Bezier curve"
        )

        let element = AnnotationElement(
            geometry: .linear(linear),
            style: AnnotationStyle(color: .blue, rootWidth: 2, alpha: 1)
        )
        try expect(
            AnnotationHitTester.contains(displayPoints[8], in: element, zoomScale: 4),
            "Expected curved linear hit testing to follow the rendered Bezier path"
        )

        let scene = AnnotationScene(elements: [element])
        scene.select([element.id])
        let editor = AnnotationEditor(scene: scene)
        try expect(editor.beginLinearPointEditing(), "Expected curved point editing")
        _ = editor.beginInteraction(
            at: CGPoint(x: 0, y: 40),
            zoomScale: 1,
            modifiers: [],
            clickCount: 1
        )
        editor.updateInteraction(to: CGPoint(x: 10, y: 50), modifiers: [])
        editor.endInteraction(at: CGPoint(x: 10, y: 50), modifiers: [])
        guard case .linear(let editedCurve) = scene.element(withID: element.id)?.geometry else {
            throw SelfTestError.failure("Expected edited Bezier controls")
        }
        try expect(
            editedCurve.bezierControls[0].start == CGPoint(x: 10, y: 50),
            "Expected direct dragging of an editable Bezier control"
        )

        let degenerate = AnnotationLinearGeometry(
            points: [CGPoint(x: 7, y: 9)],
            route: .curved,
            startArrowhead: .diamond,
            endArrowhead: .bar,
            startBinding: nil,
            endBinding: nil
        )
        try expect(
            AnnotationGeometry.linearDisplayPoints(degenerate) == [CGPoint(x: 7, y: 9)]
                && AnnotationGeometry.closestLinearLocation(to: .zero, linear: degenerate) == nil,
            "Expected single-point curved paths to remain safe and deterministic"
        )
    }

    static func testLinearClickConstructionLifecycle() throws {
        try expect(
            !ZoomCanvasView.shouldTreatLinearCreationAsDrag(
                from: CGPoint(x: 10, y: 10),
                to: CGPoint(x: 13, y: 12)
            )
                && ZoomCanvasView.shouldTreatLinearCreationAsDrag(
                    from: CGPoint(x: 10, y: 10),
                    to: CGPoint(x: 15, y: 10)
                ),
            "Expected persistent line tools to distinguish a small click from a drag"
        )

        let controller = AnnotationController()
        controller.currentTool = .line
        controller.begin(at: CGPoint(x: 10, y: 10), tool: .line)
        controller.beginLinearConstructionFromClick(
            at: CGPoint(x: 10, y: 10),
            zoomScale: 1
        )
        try expect(
            controller.isConstructingLinearPath
                && controller.elementSnapshot.isEmpty
                && !controller.canUndo,
            "Expected a first click to remain pending outside scene history"
        )

        controller.updateLinearConstructionPreview(
            at: CGPoint(x: 50, y: 20),
            zoomScale: 1
        )
        try expect(
            controller.commitLinearConstructionPoint(
                at: CGPoint(x: 50, y: 20),
                zoomScale: 1
            ) && controller.canFinishLinearPath,
            "Expected a second click to commit a distinct path anchor"
        )
        _ = controller.commitLinearConstructionPoint(
            at: CGPoint(x: 90, y: 10),
            zoomScale: 1
        )
        guard case .linear(let pending) = controller.linearConstructionElementSnapshot?.geometry else {
            throw SelfTestError.failure("Expected pending multi-click line geometry")
        }
        try expect(
            pending.points == [
                CGPoint(x: 10, y: 10),
                CGPoint(x: 50, y: 20),
                CGPoint(x: 90, y: 10)
            ],
            "Expected each straight-route click to append a polyline anchor"
        )
        try expect(
            controller.isLinearConstructionFinishHandle(
                at: CGPoint(x: 90, y: 10),
                zoomScale: 1
            ),
            "Expected the terminal anchor to expose a discoverable finish handle"
        )
        try expect(
            controller.finishLinearConstruction(commitPreview: false),
            "Expected a multi-point pending path to finish"
        )
        try expect(
            controller.elementSnapshot.count == 1 && controller.canUndo,
            "Expected the complete multi-click path to enter history as one element"
        )
        controller.undo()
        try expect(
            controller.elementSnapshot.isEmpty && controller.canRedo,
            "Expected one undo to remove the entire click-constructed path"
        )

        let cancelController = AnnotationController()
        cancelController.currentTool = .arrow
        cancelController.begin(at: CGPoint(x: 0, y: 0), tool: .arrow)
        cancelController.beginLinearConstructionFromClick(at: .zero, zoomScale: 1)
        cancelController.resolveLinearConstructionForExit()
        try expect(
            !cancelController.isConstructingLinearPath
                && cancelController.elementSnapshot.isEmpty
                && !cancelController.canUndo,
            "Expected Escape or tool exit to cancel a one-point path"
        )

        cancelController.begin(at: .zero, tool: .arrow)
        cancelController.beginLinearConstructionFromClick(at: .zero, zoomScale: 1)
        _ = cancelController.commitLinearConstructionPoint(
            at: CGPoint(x: 30, y: 0),
            zoomScale: 1
        )
        cancelController.cancelLinearConstruction()
        try expect(
            cancelController.elementSnapshot.isEmpty && !cancelController.canUndo,
            "Expected the explicit Cancel Path action to discard all pending anchors"
        )

        cancelController.begin(at: .zero, tool: .arrow)
        cancelController.beginLinearConstructionFromClick(at: .zero, zoomScale: 1)
        cancelController.updateLinearConstructionPreview(
            at: CGPoint(x: 60, y: 15),
            zoomScale: 1
        )
        try expect(
            cancelController.finishLinearConstruction(commitPreview: true),
            "Expected Return or Finish Path to commit the live preview endpoint"
        )
        guard let arrowElement = cancelController.elementSnapshot.first,
              case .linear(let arrow) = arrowElement.geometry else {
            throw SelfTestError.failure("Expected click-constructed arrow geometry")
        }
        try expect(
            arrow.startArrowhead == .none
                && arrow.endArrowhead == .arrow
                && arrow.points.last == CGPoint(x: 60, y: 15),
            "Expected the persistent Arrow tool to place its configured head at the final endpoint"
        )
        cancelController.currentTool = .select
        try expect(
            cancelController.isEditingLinearPoints
                && cancelController.selectedElementIDs == [arrowElement.id],
            "Expected switching to Select after Return to enter point editing on the new arrow"
        )

        let selectController = AnnotationController()
        selectController.currentTool = .line
        selectController.begin(at: .zero, tool: .line)
        selectController.beginLinearConstructionFromClick(at: .zero, zoomScale: 1)
        _ = selectController.commitLinearConstructionPoint(
            at: CGPoint(x: 20, y: 0),
            zoomScale: 1
        )
        selectController.currentTool = .select
        try expect(
            selectController.elementSnapshot.count == 1
                && selectController.isEditingLinearPoints
                && selectController.selectedElementIDs.count == 1,
            "Expected switching to Select to commit and immediately expose every path point"
        )
    }

    static func testLinearConstructionEscapeAndToolSwitch() throws {
        let escapeController = AnnotationController()
        escapeController.currentTool = .line
        escapeController.begin(at: .zero, tool: .line)
        escapeController.beginLinearConstructionFromClick(at: .zero, zoomScale: 1)
        _ = escapeController.commitLinearConstructionPoint(
            at: CGPoint(x: 40, y: 0),
            zoomScale: 1
        )
        let canvas = try makeCanvas(annotationController: escapeController)
        canvas.toggleDrawingMode()
        guard let escape = NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: [],
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            characters: "\u{1b}",
            charactersIgnoringModifiers: "\u{1b}",
            isARepeat: false,
            keyCode: 53
        ) else {
            throw SelfTestError.failure("Could not create an Escape key event")
        }
        canvas.keyDown(with: escape)
        canvas.prepareForClose()
        try expect(
            !escapeController.isConstructingLinearPath
                && escapeController.elementSnapshot.isEmpty,
            "Expected Escape to cancel an active click-to-place path and discard its anchors"
        )

        let toolSwitchController = AnnotationController()
        toolSwitchController.currentTool = .arrow
        toolSwitchController.begin(at: .zero, tool: .arrow)
        toolSwitchController.beginLinearConstructionFromClick(at: .zero, zoomScale: 1)
        _ = toolSwitchController.commitLinearConstructionPoint(
            at: CGPoint(x: 50, y: 10),
            zoomScale: 1
        )
        toolSwitchController.currentTool = .pen
        try expect(
            !toolSwitchController.isConstructingLinearPath
                && toolSwitchController.elementSnapshot.count == 1,
            "Expected tool switching to commit existing path anchors independently of Escape"
        )
    }

    static func testLinearDragThresholdLatching() throws {
        let origin = CGPoint(x: 20, y: 20)
        let exceeded = ZoomCanvasView.linearDragThresholdExceeded(
            previouslyExceeded: false,
            from: origin,
            to: CGPoint(x: 30, y: 20)
        )
        let remainedExceeded = ZoomCanvasView.linearDragThresholdExceeded(
            previouslyExceeded: exceeded,
            from: origin,
            to: CGPoint(x: 21, y: 20)
        )
        try expect(
            exceeded && remainedExceeded,
            "Expected a line or arrow drag to stay classified as a drag after returning near its origin"
        )
    }

    static func testLinearConstructionRoutesAndBindings() throws {
        let curvedController = AnnotationController()
        curvedController.currentTool = .line
        curvedController.setLinearRoute(.curved)
        curvedController.begin(at: .zero, tool: .line)
        curvedController.beginLinearConstructionFromClick(at: .zero, zoomScale: 1)
        _ = curvedController.commitLinearConstructionPoint(
            at: CGPoint(x: 40, y: 30),
            zoomScale: 1
        )
        _ = curvedController.commitLinearConstructionPoint(
            at: CGPoint(x: 90, y: 0),
            zoomScale: 1
        )
        _ = curvedController.finishLinearConstruction(commitPreview: false)
        guard case .linear(let curved) = curvedController.elementSnapshot.first?.geometry else {
            throw SelfTestError.failure("Expected curved click construction geometry")
        }
        try expect(
            curved.bezierControls.count == curved.points.count - 1
                && curved.bezierControls == AnnotationGeometry.bezierControls(for: curved),
            "Expected curved construction to commit explicit editable Bezier controls"
        )

        let bindingController = AnnotationController()
        bindingController.currentTool = .rectangle
        bindingController.begin(at: CGPoint(x: 40, y: 40), tool: .rectangle)
        bindingController.end(at: CGPoint(x: 100, y: 100))
        bindingController.currentTool = .arrow
        bindingController.begin(at: CGPoint(x: 40, y: 70), tool: .arrow)
        bindingController.beginLinearConstructionFromClick(
            at: CGPoint(x: 40, y: 70),
            zoomScale: 1
        )
        _ = bindingController.commitLinearConstructionPoint(
            at: CGPoint(x: 100, y: 70),
            zoomScale: 1
        )
        _ = bindingController.finishLinearConstruction(commitPreview: false)
        guard bindingController.elementSnapshot.count == 2,
              case .linear(let bound) = bindingController.elementSnapshot[1].geometry else {
            throw SelfTestError.failure("Expected a shape-bound click-constructed arrow")
        }
        try expect(
            bound.startBinding?.targetElementID == bindingController.elementSnapshot[0].id
                && bound.endBinding?.targetElementID == bindingController.elementSnapshot[0].id,
            "Expected final click-construction endpoints to evaluate shape binding"
        )
        bindingController.currentTool = .select
        try expect(
            DrawingToolbarState(annotationController: bindingController)
                .canUnbindLinearEndpoints,
            "Expected Unbind Ends to enable only for a selected bound connector"
        )
        bindingController.undo()
        try expect(
            bindingController.elementSnapshot.count == 1,
            "Expected the bound multi-click arrow to remain a single undo step"
        )
    }

    static func testCurvedTangentEditingAndControlPreservation() throws {
        let curve = AnnotationElement(
            geometry: .linear(
                AnnotationLinearGeometry(
                    points: [
                        CGPoint(x: 0, y: 0),
                        CGPoint(x: 50, y: 0),
                        CGPoint(x: 100, y: 0)
                    ],
                    route: .curved,
                    startArrowhead: .none,
                    endArrowhead: .arrow,
                    startBinding: nil,
                    endBinding: nil,
                    bezierControls: [
                        AnnotationBezierControl(
                            start: CGPoint(x: 10, y: 0),
                            end: CGPoint(x: 40, y: 0)
                        ),
                        AnnotationBezierControl(
                            start: CGPoint(x: 60, y: 0),
                            end: CGPoint(x: 90, y: 0)
                        )
                    ]
                )
            ),
            style: .default
        )
        let scene = AnnotationScene(elements: [curve])
        scene.select([curve.id])
        let editor = AnnotationEditor(scene: scene)
        try expect(editor.beginLinearPointEditing(), "Expected curved tangent point editing")

        _ = editor.beginInteraction(
            at: CGPoint(x: 40, y: 0),
            zoomScale: 1,
            modifiers: [.command],
            clickCount: 1
        )
        editor.updateInteraction(
            to: CGPoint(x: 40, y: 20),
            modifiers: [.command]
        )
        editor.endInteraction(
            at: CGPoint(x: 40, y: 20),
            modifiers: [.command]
        )
        guard case .linear(let mirrored) = scene.element(withID: curve.id)?.geometry else {
            throw SelfTestError.failure("Expected mirrored curved controls")
        }
        try expect(
            mirrored.bezierControls[0].end == CGPoint(x: 40, y: 20)
                && mirrored.bezierControls[1].start == CGPoint(x: 60, y: -20),
            "Expected Command-drag to mirror the opposite tangent with equal length"
        )

        _ = editor.beginInteraction(
            at: CGPoint(x: 40, y: 20),
            zoomScale: 1,
            modifiers: [.option],
            clickCount: 1
        )
        editor.updateInteraction(
            to: CGPoint(x: 35, y: 30),
            modifiers: [.option]
        )
        editor.endInteraction(
            at: CGPoint(x: 35, y: 30),
            modifiers: [.option]
        )
        guard case .linear(let broken) = scene.element(withID: curve.id)?.geometry else {
            throw SelfTestError.failure("Expected independently edited curved controls")
        }
        try expect(
            broken.bezierControls[0].end == CGPoint(x: 35, y: 30)
                && broken.bezierControls[1].start == CGPoint(x: 60, y: -20),
            "Expected Option-drag to break tangents while retaining the opposite explicit control"
        )

        let reduced = AnnotationGeometry.removingLinearPoints([1], from: broken)
        try expect(
            reduced.points == [CGPoint(x: 0, y: 0), CGPoint(x: 100, y: 0)]
                && reduced.bezierControls == [
                    AnnotationBezierControl(
                        start: broken.bezierControls[0].start,
                        end: broken.bezierControls[1].end
                    )
                ],
            "Expected point removal to preserve explicit controls on the surviving curve"
        )
    }
}
