import AppKit

extension SelfTestRunner {
    static func testMultiArrowMutationBatching() throws {
        let firstTarget = AnnotationElement.legacy(
            tool: .rectangle,
            points: [CGPoint(x: 10, y: 10), CGPoint(x: 40, y: 40)],
            style: .default
        )
        let secondTarget = AnnotationElement.legacy(
            tool: .rectangle,
            points: [CGPoint(x: 10, y: 70), CGPoint(x: 40, y: 100)],
            style: .default
        )
        let firstArrow = AnnotationElement(
            geometry: .linear(
                AnnotationLinearGeometry(
                    points: [CGPoint(x: 40, y: 25), CGPoint(x: 140, y: 25)],
                    route: .straight,
                    startArrowhead: .none,
                    endArrowhead: .arrow,
                    startBinding: AnnotationBinding(
                        targetElementID: firstTarget.id,
                        side: .trailing
                    ),
                    endBinding: nil
                )
            ),
            style: .default
        )
        let secondArrow = AnnotationElement(
            geometry: .linear(
                AnnotationLinearGeometry(
                    points: [CGPoint(x: 40, y: 85), CGPoint(x: 140, y: 85)],
                    route: .straight,
                    startArrowhead: .none,
                    endArrowhead: .arrow,
                    startBinding: AnnotationBinding(
                        targetElementID: secondTarget.id,
                        side: .trailing
                    ),
                    endBinding: nil
                )
            ),
            style: .default
        )
        let scene = AnnotationScene(
            elements: [firstTarget, secondTarget, firstArrow, secondArrow]
        )
        let editor = AnnotationEditor(scene: scene)
        let arrowIDs: Set<AnnotationElementID> = [firstArrow.id, secondArrow.id]
        scene.select(arrowIDs)

        var notificationCount = 0
        scene.onChange = { notificationCount += 1 }

        editor.setLinearRoute(.curved)
        try expect(
            notificationCount == 1
                && scene.elements.filter { arrowIDs.contains($0.id) }.allSatisfy {
                    guard case .linear(let linear) = $0.geometry else { return false }
                    return linear.route == .curved && !linear.bezierControls.isEmpty
                },
            "Expected one scene notification to update every selected arrow route"
        )

        notificationCount = 0
        editor.setLinearArrowheads(start: .circleOutline, end: .diamond)
        try expect(
            notificationCount == 1,
            "Expected combined arrowhead edits to use one scene pass"
        )

        notificationCount = 0
        editor.setLinearStartArrowhead(.bar)
        try expect(
            notificationCount == 1,
            "Expected start-arrowhead edits to use one scene notification"
        )

        notificationCount = 0
        editor.setLinearEndArrowhead(.triangleOutline)
        try expect(
            notificationCount == 1,
            "Expected end-arrowhead edits to use one scene notification"
        )

        notificationCount = 0
        editor.unbindLinearEndpoints()
        try expect(
            notificationCount == 1,
            "Expected batched endpoint unbinding to notify once"
        )
        try expect(
            arrowIDs.allSatisfy { elementID in
                guard case .linear(let linear) = scene.element(withID: elementID)?.geometry else {
                    return false
                }
                return linear.startBinding == nil && linear.endBinding == nil
            },
            "Expected endpoint unbinding to update every selected arrow"
        )
    }

    static func testLinearBindingLifecycle() throws {
        let scene = AnnotationScene()
        let shape = AnnotationElement(
            geometry: .shape(
                AnnotationShapeGeometry(
                    kind: .rectangle,
                    start: CGPoint(x: 40, y: 40),
                    end: CGPoint(x: 100, y: 100)
                )
            ),
            style: .default
        )
        let line = AnnotationElement(
            geometry: .linear(
                AnnotationLinearGeometry(
                    points: [CGPoint(x: 0, y: 70), CGPoint(x: 100, y: 70)],
                    route: .curved,
                    startArrowhead: .none,
                    endArrowhead: .arrow,
                    startBinding: nil,
                    endBinding: nil
                )
            ),
            style: .default
        )
        scene.append(shape)
        scene.append(line)
        guard let binding = AnnotationGeometry.binding(
            to: shape,
            near: CGPoint(x: 100, y: 70)
        ) else {
            throw SelfTestError.failure("Expected a shape-edge binding")
        }
        scene.bindLinearEndpoint(elementID: line.id, atStart: false, to: binding)

        guard case .linear(let initiallyBound) = scene.element(withID: line.id)?.geometry else {
            throw SelfTestError.failure("Expected bound linear geometry")
        }
        try expect(
            initiallyBound.endBinding?.targetElementID == shape.id
                && approximatelyEqual(initiallyBound.points.last!, CGPoint(x: 100, y: 70)),
            "Expected the endpoint to bind to the nearest shape edge"
        )

        scene.select([line.id])
        let editor = AnnotationEditor(scene: scene)
        try expect(editor.beginLinearPointEditing(), "Expected bound endpoint point editing")
        _ = editor.beginInteraction(
            at: initiallyBound.points.last!,
            zoomScale: 1,
            modifiers: [.option],
            clickCount: 1
        )
        editor.updateInteraction(
            to: CGPoint(x: 125, y: 70),
            modifiers: [.option]
        )
        editor.endInteraction(
            at: CGPoint(x: 125, y: 70),
            modifiers: [.option]
        )
        guard case .linear(let optionUnbound) = scene.element(withID: line.id)?.geometry else {
            throw SelfTestError.failure("Expected Option-dragged endpoint")
        }
        try expect(
            optionUnbound.endBinding == nil
                && approximatelyEqual(optionUnbound.points.last!, CGPoint(x: 125, y: 70)),
            "Expected Option-drag to explicitly unbind and move a bound endpoint"
        )
        scene.bindLinearEndpoint(elementID: line.id, atStart: false, to: binding)
        editor.finishLinearPointEditing()

        scene.updateElement(withID: shape.id) { element in
            guard case .shape(var geometry) = element.geometry else { return }
            geometry.start.x += 20
            geometry.end.x += 20
            element.geometry = .shape(geometry)
        }
        guard case .linear(let movedBinding) = scene.element(withID: line.id)?.geometry else {
            throw SelfTestError.failure("Expected binding after target movement")
        }
        try expect(
            approximatelyEqual(movedBinding.points.last!, CGPoint(x: 120, y: 70)),
            "Expected bound endpoints to update live when the shape moves"
        )

        scene.updateElement(withID: shape.id) { element in
            guard case .shape(var geometry) = element.geometry else { return }
            geometry.end.x = 160
            element.geometry = .shape(geometry)
        }
        guard case .linear(let resizedBinding) = scene.element(withID: line.id)?.geometry else {
            throw SelfTestError.failure("Expected binding after target resize")
        }
        try expect(
            approximatelyEqual(resizedBinding.points.last!, CGPoint(x: 160, y: 70)),
            "Expected bound endpoints to update live when the shape resizes"
        )

        scene.updateElement(withID: shape.id) { element in
            element.metadata.rotation = .pi / 2
        }
        guard case .linear(let rotatedBinding) = scene.element(withID: line.id)?.geometry else {
            throw SelfTestError.failure("Expected binding after target rotation")
        }
        try expect(
            approximatelyEqual(rotatedBinding.points.last!, CGPoint(x: 110, y: 120)),
            "Expected bound endpoints to follow rotated shape edges"
        )

        scene.unbindLinearEndpoints(elementID: line.id, start: false, end: true)
        guard case .linear(let unbound) = scene.element(withID: line.id)?.geometry else {
            throw SelfTestError.failure("Expected explicitly unbound geometry")
        }
        let preservedEndpoint = unbound.points.last!
        try expect(unbound.endBinding == nil, "Expected explicit endpoint unbinding")
        scene.updateElement(withID: shape.id) { element in
            guard case .shape(var geometry) = element.geometry else { return }
            geometry.start.y += 50
            geometry.end.y += 50
            element.geometry = .shape(geometry)
        }
        guard case .linear(let afterUnboundMove) = scene.element(withID: line.id)?.geometry else {
            throw SelfTestError.failure("Expected line after moving an unbound target")
        }
        try expect(
            approximatelyEqual(afterUnboundMove.points.last!, preservedEndpoint),
            "Expected unbinding to preserve the endpoint and stop live target updates"
        )

        guard let rebound = AnnotationGeometry.binding(
            to: scene.element(withID: shape.id)!,
            near: CGPoint(x: 110, y: 170)
        ) else {
            throw SelfTestError.failure("Expected rebinding before deletion")
        }
        scene.bindLinearEndpoint(elementID: line.id, atStart: false, to: rebound)
        guard case .linear(let beforeDeletion) = scene.element(withID: line.id)?.geometry else {
            throw SelfTestError.failure("Expected rebound line before deletion")
        }
        let deletionEndpoint = beforeDeletion.points.last!
        scene.removeElements(withIDs: [shape.id])
        guard case .linear(let afterDeletion) = scene.element(withID: line.id)?.geometry else {
            throw SelfTestError.failure("Expected bound line to survive target deletion")
        }
        try expect(
            afterDeletion.endBinding == nil
                && approximatelyEqual(afterDeletion.points.last!, deletionEndpoint),
            "Expected safe target deletion to clear binding without moving or deleting the line"
        )
    }

    static func testRotatedConnectorBindingRefreshUsesStablePivot() throws {
        let target = AnnotationElement(
            geometry: .shape(
                AnnotationShapeGeometry(
                    kind: .rectangle,
                    start: CGPoint(x: 200, y: 100),
                    end: CGPoint(x: 260, y: 160)
                )
            ),
            style: .default
        )
        let binding = AnnotationBinding(
            targetElementID: target.id,
            normalizedAnchor: CGPoint(x: 0, y: 0.5),
            focus: 0,
            side: .leading
        )
        var connector = AnnotationElement(
            geometry: .linear(
                AnnotationLinearGeometry(
                    points: [CGPoint(x: 40, y: 130), CGPoint(x: 180, y: 130)],
                    route: .straight,
                    startArrowhead: .none,
                    endArrowhead: .arrow,
                    startBinding: nil,
                    endBinding: binding
                )
            ),
            style: .default
        )
        connector.metadata.rotation = .pi / 4
        let scene = AnnotationScene(elements: [target, connector])

        func expectBoundEndpointAtDesiredWorldPoint(_ message: String) throws {
            guard let currentTarget = scene.element(withID: target.id),
                  let currentConnector = scene.element(withID: connector.id),
                  case .linear(let linear) = currentConnector.geometry,
                  let endpoint = linear.points.last,
                  linear.points.count >= 2,
                  let currentBinding = linear.endBinding else {
                throw SelfTestError.failure("Expected a rotated bound connector")
            }
            let transform = AnnotationGeometry.worldTransform(for: currentConnector)
            let actualWorldPoint = endpoint.applying(transform)
            let neighborWorldPoint = linear.points[linear.points.count - 2].applying(transform)
            guard let desiredWorldPoint = AnnotationGeometry.bindingPoint(
                for: currentBinding,
                on: currentTarget,
                toward: neighborWorldPoint
            ) else {
                throw SelfTestError.failure("Expected a desired world-space binding point")
            }
            try expect(
                approximatelyEqual(actualWorldPoint, desiredWorldPoint),
                "\(message): expected \(desiredWorldPoint), got \(actualWorldPoint)"
            )
            try expect(
                linear.rotationPivot != nil,
                "Expected rotated connectors to retain a stable local rotation pivot"
            )
        }

        try expectBoundEndpointAtDesiredWorldPoint(
            "Expected initial rotated connector binding to land exactly"
        )
        scene.updateElement(withID: target.id) { element in
            guard case .shape(var shape) = element.geometry else { return }
            shape.start.x += 45
            shape.end.x += 45
            shape.start.y += 20
            shape.end.y += 20
            element.geometry = .shape(shape)
        }
        try expectBoundEndpointAtDesiredWorldPoint(
            "Expected rotated connector refresh to avoid pivot drift after target movement"
        )
    }

    static func testLegacyArrowGestureOrientation() throws {
        try expect(
            ZoomCanvasView.gestureTool(control: true, shift: true, tab: false) == .arrow
                && ZoomCanvasView.gestureTool(control: true, shift: false, tab: false) == .rectangle
                && ZoomCanvasView.gestureTool(control: false, shift: true, tab: false) == .line
                && ZoomCanvasView.gestureTool(control: false, shift: false, tab: true) == .ellipse,
            "Expected the existing modifier gestures, including Control+Shift arrow, to remain unchanged"
        )

        let controller = AnnotationController()
        controller.begin(
            at: CGPoint(x: 10, y: 20),
            tool: .arrow,
            legacyModifierGesture: true
        )
        controller.end(at: CGPoint(x: 100, y: 20))
        guard case .linear(let arrow) = controller.elementSnapshot.first?.geometry else {
            throw SelfTestError.failure("Expected legacy arrow geometry")
        }
        try expect(
            arrow.points == [CGPoint(x: 10, y: 20), CGPoint(x: 100, y: 20)]
                && arrow.startArrowhead == .arrow
                && arrow.endArrowhead == .none
                && arrow.arrowheadSize == .small,
            "Expected the drag origin to remain the legacy arrow tip"
        )
        guard let arrowhead = AnnotationGeometry.arrowheadPath(
            arrow.startArrowhead,
            tip: arrow.points[0],
            adjacent: arrow.points[1],
            strokeWidth: controller.currentStyle.strokeWidth
        ) else {
            throw SelfTestError.failure("Expected legacy arrowhead geometry")
        }
        try expect(
            arrowhead.boundingBoxOfPath.maxX > arrow.points[0].x,
            "Expected the legacy arrowhead to point back toward the Control+Shift drag origin"
        )

        let persistentController = AnnotationController()
        persistentController.setLinearRoute(.curved)
        persistentController.setLinearArrowheads(start: .circle, end: .diamond)
        persistentController.begin(
            at: CGPoint(x: 10, y: 40),
            tool: .line,
            legacyModifierGesture: true
        )
        persistentController.end(at: CGPoint(x: 100, y: 40))
        persistentController.begin(
            at: CGPoint(x: 10, y: 70),
            tool: .arrow,
            legacyModifierGesture: true
        )
        persistentController.end(at: CGPoint(x: 100, y: 70))
        guard persistentController.elementSnapshot.count == 2,
              case .linear(let shiftLine) = persistentController.elementSnapshot[0].geometry,
              case .linear(let controlShiftArrow) = persistentController.elementSnapshot[1].geometry else {
            throw SelfTestError.failure("Expected modifier gesture linear elements")
        }
        try expect(
            shiftLine.route == .straight
                && shiftLine.startArrowhead == .none
                && shiftLine.endArrowhead == .none
                && shiftLine.arrowheadSize == .small,
            "Expected Shift-drag to remain a straight headless legacy line"
        )
        try expect(
            controlShiftArrow.route == .straight
                && controlShiftArrow.startArrowhead == .arrow
                && controlShiftArrow.endArrowhead == .none
                && controlShiftArrow.arrowheadSize == .small,
            "Expected Control+Shift-drag to retain the straight legacy start arrow"
        )
    }

    static func testLinearToolDefaultTransitionsAndApplication() throws {
        var implicitDefaults = DrawingDefaults.default
        try expect(
            implicitDefaults.lineRoute == .straight
                && implicitDefaults.arrowRoute == .curved
                && implicitDefaults.arrowheadSize == .medium,
            "Expected fresh Line and Arrow route scopes plus medium arrowheads"
        )
        implicitDefaults.selectTool(.line)
        try expect(
            implicitDefaults.tool == .line
                && implicitDefaults.startArrowhead == .none
                && implicitDefaults.endArrowhead == .none,
            "Expected Line to discard the implicit forward Arrow default"
        )
        implicitDefaults.selectTool(.arrow)
        try expect(
            implicitDefaults.startArrowhead == .none
                && implicitDefaults.endArrowhead == .arrow,
            "Expected Arrow to default to a forward end arrowhead"
        )

        var customDefaults = DrawingDefaults.default
        customDefaults.startArrowhead = .circle
        customDefaults.endArrowhead = .diamond
        customDefaults.selectTool(.line)
        try expect(
            customDefaults.startArrowhead == .circle
                && customDefaults.endArrowhead == .diamond,
            "Expected Line tool transitions to preserve explicit custom arrowheads"
        )

        let transitionController = AnnotationController()
        transitionController.setLinearArrowheads(start: .none, end: .none)
        transitionController.currentTool = .arrow
        try expect(
            transitionController.currentStartArrowhead == .none
                && transitionController.currentEndArrowhead == .arrow
                && transitionController.currentLinearRoute == .curved,
            "Expected runtime Arrow selection to create only a forward end arrowhead"
        )
        transitionController.setLinearArrowheads(start: .none, end: .none)
        transitionController.begin(at: CGPoint(x: 10, y: 10), tool: .arrow)
        transitionController.end(at: CGPoint(x: 90, y: 40))
        guard case .linear(let headlessArrow) =
            transitionController.elementSnapshot.last?.geometry else {
            throw SelfTestError.failure(
                "Expected a headless nonlegacy Arrow creation"
            )
        }
        try expect(
            headlessArrow.startArrowhead == .none
                && headlessArrow.endArrowhead == .none,
            "Expected nonlegacy Arrow creation to assign both current none endpoints"
        )
        transitionController.setLinearRoute(.straight)
        transitionController.currentTool = .line
        try expect(
            transitionController.currentStartArrowhead == .none
                && transitionController.currentEndArrowhead == .none
                && transitionController.currentLinearRoute == .straight,
            "Expected Line to restore its independent straight route scope"
        )
        transitionController.setLinearRoute(.curved)
        transitionController.currentTool = .arrow
        try expect(
            transitionController.currentLinearRoute == .straight,
            "Expected Arrow to restore its independently edited route scope"
        )

        var explicitLine = DrawingDefaults.default
        explicitLine.tool = .line
        explicitLine.startArrowhead = .none
        explicitLine.endArrowhead = .arrow
        explicitLine.linearRoute = .curved
        let appliedController = AnnotationController()
        appliedController.applyDrawingDefaults(explicitLine, strokeWidth: 7)
        try expect(
            appliedController.currentTool == .line
                && appliedController.currentLinearRoute == .curved
                && appliedController.currentStartArrowhead == .none
                && appliedController.currentEndArrowhead == .arrow
                && appliedController.currentStyle.strokeWidth == 7,
            "Expected loading explicitly stored line heads to bypass implicit tool transitions"
        )
    }
}
