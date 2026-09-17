import AppKit

extension SelfTestRunner {
    static func testArrowheadFamiliesAndScaling() throws {
        let allHeads = DrawingInspectorControlMapping.arrowheads
        for size in AnnotationArrowheadSize.allCases {
            for arrowhead in allHeads {
                let path = AnnotationGeometry.arrowheadPath(
                    arrowhead,
                    tip: CGPoint(x: 40, y: 40),
                    adjacent: CGPoint(x: 10, y: 40),
                    strokeWidth: 3,
                    size: size
                )
                if arrowhead == .none {
                    try expect(
                        path == nil,
                        "Expected the none arrowhead to produce no geometry"
                    )
                } else {
                    try expect(
                        path != nil && !path!.boundingBoxOfPath.isNull,
                        "Expected \(size) \(arrowhead) arrowhead geometry"
                    )
                }
            }
        }

        let thin = AnnotationGeometry.arrowheadMetrics(strokeWidth: 0.5)
        let thick = AnnotationGeometry.arrowheadMetrics(strokeWidth: 8)
        let medium = AnnotationGeometry.arrowheadMetrics(
            strokeWidth: 3,
            size: .medium
        )
        let large = AnnotationGeometry.arrowheadMetrics(
            strokeWidth: 3,
            size: .large
        )
        try expect(
            thin.length >= 23
                && thin.halfWidth >= 13.5
                && thick.length > thin.length
                && thick.halfWidth > thin.halfWidth
                && abs(medium.length / AnnotationGeometry.arrowheadMetrics(
                    strokeWidth: 3,
                    size: .small
                ).length - 1.35) < 0.001
                && abs(large.length / medium.length - 1.75 / 1.35) < 0.001,
            "Expected arrowheads to scale by stroke width and the exact S/M/L factors"
        )

        let rasterTargets: [
            (size: AnnotationArrowheadSize, width: CGFloat, height: CGFloat)
        ] = [
            (.small, 22, 26),
            (.medium, 30, 35),
            (.large, 39, 46)
        ]
        for target in rasterTargets {
            let pixels = try renderArrowheadPixels(
                .arrow,
                size: target.size,
                strokeWidth: 3
            )
            guard let bounds = paintedBounds(
                pixels,
                width: 128,
                height: 128
            ) else {
                throw SelfTestError.failure(
                    "Expected a rasterized \(target.size) open arrowhead"
                )
            }
            try expect(
                bounds.width >= target.width
                    && bounds.height >= target.height
                    && bounds.minX > 1
                    && bounds.minY > 1
                    && bounds.maxX < 126
                    && bounds.maxY < 126,
                "Expected \(target.size) open arrow raster at least "
                    + "\(target.width)x\(target.height) without clipping, got "
                    + "\(bounds.width)x\(bounds.height) in \(bounds)"
            )
        }

        for size in AnnotationArrowheadSize.allCases {
            for arrowhead in allHeads where arrowhead != .none {
                let pixels = try renderArrowheadPixels(
                    arrowhead,
                    size: size,
                    strokeWidth: 3
                )
                guard let bounds = paintedBounds(
                    pixels,
                    width: 128,
                    height: 128
                ) else {
                    throw SelfTestError.failure(
                        "Expected rasterized \(size) \(arrowhead) geometry"
                    )
                }
                try expect(
                    bounds.minX > 1
                        && bounds.minY > 1
                        && bounds.maxX < 126
                        && bounds.maxY < 126,
                    "Expected \(size) \(arrowhead) raster to avoid clipping: \(bounds)"
                )
            }
        }

        let line = AnnotationElement(
            geometry: .linear(
                AnnotationLinearGeometry(
                    points: [CGPoint(x: 20, y: 20), CGPoint(x: 100, y: 80)],
                    route: .straight,
                    startArrowhead: .diamond,
                    endArrowhead: .circle,
                    startBinding: nil,
                    endBinding: nil
                )
            ),
            style: AnnotationStyle(color: .green, rootWidth: 8, alpha: 1)
        )
        let bounds = AnnotationGeometry.localBounds(of: line)
        guard case .linear(let linearGeometry) = line.geometry else {
            throw SelfTestError.failure("Expected arrowhead test line")
        }
        let shaftBounds = AnnotationGeometry.linearPath(linearGeometry).boundingBoxOfPath
        try expect(
            bounds.width > shaftBounds.width || bounds.height > shaftBounds.height,
            "Expected independently configured start and end arrowheads in path bounds"
        )

        let insetLinear = AnnotationLinearGeometry(
            points: [CGPoint(x: 0, y: 0), CGPoint(x: 100, y: 0)],
            route: .straight,
            startArrowhead: .circleOutline,
            endArrowhead: .triangleOutline,
            startBinding: nil,
            endBinding: nil
        )
        let insetShaft = AnnotationGeometry.linearShaftGeometry(
            insetLinear,
            strokeWidth: 5
        )
        try expect(
            insetShaft.points[0].x > insetLinear.points[0].x
                && insetShaft.points[1].x < insetLinear.points[1].x,
            "Expected outlined endpoint shapes to trim the shaft instead of drawing through them"
        )

        var curved = insetLinear
        curved.route = .curved
        curved.points = [
            CGPoint(x: 0, y: 20),
            CGPoint(x: 50, y: 70),
            CGPoint(x: 100, y: 20)
        ]
        curved.bezierControls = AnnotationGeometry.bezierControls(for: curved)
        let originalControls = curved.bezierControls
        let curvedShaft = AnnotationGeometry.linearShaftGeometry(curved, strokeWidth: 5)
        try expect(
            curvedShaft.points.first != curved.points.first
                && curvedShaft.points.last != curved.points.last
                && curvedShaft.bezierControls.first?.start
                    != originalControls.first?.start
                && curvedShaft.bezierControls.last?.end
                    != originalControls.last?.end,
            "Expected curved shaft trimming to preserve endpoint tangent attachment"
        )

        let short = AnnotationLinearGeometry(
            points: [CGPoint(x: 10, y: 10), CGPoint(x: 18, y: 10)],
            route: .straight,
            startArrowhead: .diamondOutline,
            endArrowhead: .diamondOutline,
            startBinding: nil,
            endBinding: nil
        )
        let shortShaft = AnnotationGeometry.linearShaftGeometry(short, strokeWidth: 8)
        try expect(
            shortShaft.points[0].x <= shortShaft.points[1].x,
            "Expected arrowhead insets to clamp before reversing a short shaft"
        )

        let insetHeads: [AnnotationArrowhead] = [
            .triangleOutline,
            .triangle,
            .circleOutline,
            .circle,
            .diamondOutline,
            .diamond,
            .oneOrMany,
            .zeroOrOne,
            .zeroOrMany
        ]
        for route in [
            AnnotationLinearRoute.straight,
            .curved
        ] {
            for head in insetHeads {
                var shortEndpoints = AnnotationLinearGeometry(
                    points: [
                        CGPoint(x: 10, y: 20),
                        CGPoint(x: 13, y: 21),
                        CGPoint(x: 86, y: 62),
                        CGPoint(x: 90, y: 64)
                    ],
                    route: route,
                    startArrowhead: head,
                    endArrowhead: head,
                    startBinding: nil,
                    endBinding: nil
                )
                if route == .curved {
                    shortEndpoints.bezierControls =
                        AnnotationGeometry.bezierControls(for: shortEndpoints)
                }
                let shaft = AnnotationGeometry.linearShaftGeometry(
                    shortEndpoints,
                    strokeWidth: 8
                )
                let originalStartOffset = CGPoint(
                    x: shortEndpoints.points[1].x - shortEndpoints.points[0].x,
                    y: shortEndpoints.points[1].y - shortEndpoints.points[0].y
                )
                let trimmedStartOffset = CGPoint(
                    x: shaft.points[1].x - shaft.points[0].x,
                    y: shaft.points[1].y - shaft.points[0].y
                )
                let originalEndOffset = CGPoint(
                    x: shortEndpoints.points[shortEndpoints.points.count - 2].x
                        - shortEndpoints.points[shortEndpoints.points.count - 1].x,
                    y: shortEndpoints.points[shortEndpoints.points.count - 2].y
                        - shortEndpoints.points[shortEndpoints.points.count - 1].y
                )
                let trimmedEndOffset = CGPoint(
                    x: shaft.points[shaft.points.count - 2].x
                        - shaft.points[shaft.points.count - 1].x,
                    y: shaft.points[shaft.points.count - 2].y
                        - shaft.points[shaft.points.count - 1].y
                )
                let startDot = originalStartOffset.x * trimmedStartOffset.x
                    + originalStartOffset.y * trimmedStartOffset.y
                let endDot = originalEndOffset.x * trimmedEndOffset.x
                    + originalEndOffset.y * trimmedEndOffset.y
                try expect(
                    startDot >= -0.000_001 && endDot >= -0.000_001,
                    "Expected short \(route) endpoint segments to avoid reversing for \(head)"
                )
            }
        }

        for route in [
            AnnotationLinearRoute.straight,
            .curved
        ] {
            for size in AnnotationArrowheadSize.allCases {
                for head in allHeads {
                    var linear = AnnotationLinearGeometry(
                        points: [
                            CGPoint(x: 20, y: 30),
                            CGPoint(x: 70, y: 70),
                            CGPoint(x: 130, y: 34)
                        ],
                        route: route,
                        startArrowhead: head,
                        endArrowhead: head,
                        arrowheadSize: size,
                        startBinding: nil,
                        endBinding: nil
                    )
                    if route == .curved {
                        linear.bezierControls =
                            AnnotationGeometry.bezierControls(for: linear)
                    }
                    let shaft = AnnotationGeometry.linearShaftGeometry(
                        linear,
                        strokeWidth: 3
                    )
                    let element = AnnotationElement(
                        geometry: .linear(linear),
                        style: AnnotationStyle(
                            color: .blue,
                            rootWidth: 3,
                            alpha: 1
                        )
                    )
                    let bounds = AnnotationGeometry.localBounds(of: element)
                    let startPath = AnnotationGeometry.arrowheadPath(
                        head,
                        tip: linear.points[0],
                        adjacent: AnnotationGeometry.endpointAdjacentPoint(
                            in: linear,
                            atStart: true
                        ) ?? linear.points[1],
                        strokeWidth: 3,
                        size: size
                    )
                    let endPath = AnnotationGeometry.arrowheadPath(
                        head,
                        tip: linear.points.last!,
                        adjacent: AnnotationGeometry.endpointAdjacentPoint(
                            in: linear,
                            atStart: false
                        ) ?? linear.points[linear.points.count - 2],
                        strokeWidth: 3,
                        size: size
                    )
                    try expect(
                        shaft.points.count == linear.points.count
                            && (startPath == nil
                                || bounds.contains(
                                    startPath!.boundingBoxOfPath
                                ))
                            && (endPath == nil
                                || bounds.contains(
                                    endPath!.boundingBoxOfPath
                                )),
                        "Expected \(head) \(size) heads, shaft trim, and bounds for \(route)"
                    )
                }
            }
        }

        let editController = AnnotationController()
        editController.currentTool = .arrow
        editController.begin(at: CGPoint(x: 20, y: 20), tool: .arrow)
        editController.end(at: CGPoint(x: 120, y: 70))
        editController.currentTool = .select
        editController.selectAll()
        editController.setLinearArrowheadSize(.large)
        try expect(
            editController.selectedElementSnapshot.allSatisfy {
                guard case .linear(let linear) = $0.geometry else {
                    return false
                }
                return linear.arrowheadSize == .large
            },
            "Expected unlocked selected linears to accept arrowhead-size edits"
        )
        editController.undo()
        try expect(
            editController.selectedElementSnapshot.allSatisfy {
                guard case .linear(let linear) = $0.geometry else {
                    return false
                }
                return linear.arrowheadSize == .medium
            },
            "Expected one undo to restore the selected arrowhead size"
        )

        for route in [
            AnnotationLinearRoute.straight,
            .curved
        ] {
            for width in [CGFloat(1), 8] {
                for sloppiness in [
                    AnnotationSloppiness.architect,
                    .cartoonist
                ] {
                    let points = [CGPoint(x: 12, y: 20), CGPoint(x: 112, y: 76)]
                    var style = AnnotationStyle(
                        color: .blue,
                        rootWidth: width,
                        alpha: 1,
                        sloppiness: sloppiness
                    )
                    style.lineCap = .round
                    let geometry = AnnotationLinearGeometry(
                        points: points,
                        route: route,
                        startArrowhead: .zeroOrMany,
                        endArrowhead: .triangleOutline,
                        startBinding: nil,
                        endBinding: nil
                    )
                    let element = AnnotationElement(
                        geometry: .linear(geometry),
                        style: style
                    )
                    let firstRender = try renderPixels(
                        elements: [element],
                        renderer: AnnotationRenderer(),
                        width: 128,
                        height: 96
                    )
                    let secondRender = try renderPixels(
                        elements: [element],
                        renderer: AnnotationRenderer(),
                        width: 128,
                        height: 96
                    )
                    try expect(
                        firstRender == secondRender
                            && hasPaintedPixel(
                                firstRender,
                                width: 128,
                                height: 96,
                                near: CGPoint(x: 12, y: 20),
                                radius: max(4, Int(width * 2))
                            )
                            && hasPaintedPixel(
                                firstRender,
                                width: 128,
                                height: 96,
                                near: CGPoint(x: 112, y: 76),
                                radius: max(4, Int(width * 2))
                            ),
                        "Expected clean deterministic \(route) arrowhead attachment at width "
                            + "\(width) and \(sloppiness)"
                    )
                }
            }
        }

    }

    static func testLinearArrowheadEndpointEditsPreserveOppositeEndpoints() throws {
        let first = AnnotationElement(
            geometry: .linear(
                AnnotationLinearGeometry(
                    points: [CGPoint(x: 0, y: 0), CGPoint(x: 80, y: 0)],
                    route: .straight,
                    startArrowhead: .none,
                    endArrowhead: .circle,
                    startBinding: nil,
                    endBinding: nil
                )
            ),
            style: .default
        )
        let second = AnnotationElement(
            geometry: .linear(
                AnnotationLinearGeometry(
                    points: [CGPoint(x: 0, y: 30), CGPoint(x: 80, y: 30)],
                    route: .straight,
                    startArrowhead: .triangle,
                    endArrowhead: .diamond,
                    startBinding: nil,
                    endBinding: nil
                )
            ),
            style: .default
        )
        let scene = AnnotationScene(elements: [first, second])
        scene.select([first.id, second.id])
        let editor = AnnotationEditor(scene: scene)

        editor.setLinearStartArrowhead(.bar)
        guard case .linear(let firstStartEdited) = scene.element(withID: first.id)?.geometry,
              case .linear(let secondStartEdited) = scene.element(withID: second.id)?.geometry else {
            throw SelfTestError.failure("Expected two selected linear elements")
        }
        try expect(
            firstStartEdited.startArrowhead == .bar
                && firstStartEdited.endArrowhead == .circle
                && secondStartEdited.startArrowhead == .bar
                && secondStartEdited.endArrowhead == .diamond,
            "Expected a start-arrowhead edit to preserve each selected line's distinct end arrowhead"
        )

        scene.updateElement(withID: first.id) { element in
            guard case .linear(var linear) = element.geometry else { return }
            linear.startArrowhead = .circle
            element.geometry = .linear(linear)
        }
        scene.updateElement(withID: second.id) { element in
            guard case .linear(var linear) = element.geometry else { return }
            linear.startArrowhead = .diamond
            element.geometry = .linear(linear)
        }
        editor.setLinearEndArrowhead(.arrow)
        guard case .linear(let firstEndEdited) = scene.element(withID: first.id)?.geometry,
              case .linear(let secondEndEdited) = scene.element(withID: second.id)?.geometry else {
            throw SelfTestError.failure("Expected endpoint-edited linear elements")
        }
        try expect(
            firstEndEdited.startArrowhead == .circle
                && firstEndEdited.endArrowhead == .arrow
                && secondEndEdited.startArrowhead == .diamond
                && secondEndEdited.endArrowhead == .arrow,
            "Expected an end-arrowhead edit to preserve each selected line's distinct start arrowhead"
        )

        let transitionController = AnnotationController()
        transitionController.currentTool = .line
        transitionController.begin(at: CGPoint(x: 10, y: 10))
        transitionController.end(at: CGPoint(x: 90, y: 10))
        transitionController.currentTool = .select
        transitionController.selectAll()
        transitionController.setLinearStartArrowhead(.bar)
        transitionController.setLinearStartArrowhead(.none)
        guard case .linear(let headless) =
            transitionController.elementSnapshot.first?.geometry else {
            throw SelfTestError.failure("Expected a selected headless linear element")
        }
        let headlessState = DrawingToolbarState(
            annotationController: transitionController
        )
        try expect(
            headless.startArrowhead == .none
                && headless.endArrowhead == .none
                && headlessState.visibleInspectorSections.contains(.edges)
                && headlessState.visibleInspectorSections.contains(.arrowheads)
                && headlessState.visibleInspectorSections.contains(.arrowheadSize),
            "Expected a selected headless linear element to retain endpoint controls"
        )
        transitionController.setLinearEndArrowhead(.triangleOutline)
        guard case .linear(let transitioned) =
            transitionController.elementSnapshot.first?.geometry else {
            throw SelfTestError.failure("Expected a headless-to-ended arrow transition")
        }
        try expect(
            transitioned.endArrowhead == .triangleOutline,
            "Expected a selected headless line to accept a new end arrowhead"
        )
        transitionController.undo()
        guard case .linear(let undoneTransition) =
            transitionController.elementSnapshot.first?.geometry else {
            throw SelfTestError.failure("Expected an undoable selected arrowhead update")
        }
        transitionController.redo()
        guard case .linear(let redoneTransition) =
            transitionController.elementSnapshot.first?.geometry else {
            throw SelfTestError.failure("Expected a redoable selected arrowhead update")
        }
        try expect(
            undoneTransition.endArrowhead == .none
                && redoneTransition.endArrowhead == .triangleOutline,
            "Expected selected arrowhead updates to undo and redo atomically"
        )

        let immediateController = AnnotationController()
        immediateController.currentTool = .arrow
        immediateController.setLinearArrowheads(
            start: .circle,
            end: .diamond
        )
        immediateController.begin(at: CGPoint(x: 10, y: 80))
        immediateController.end(at: CGPoint(x: 110, y: 80))
        immediateController.currentTool = .select
        immediateController.selectAll()
        immediateController.setLinearStartArrowhead(.bar)
        guard case .linear(let immediateEdit) =
            immediateController.selectedElementSnapshot.first?.geometry else {
            throw SelfTestError.failure(
                "Expected an immediately edited selected arrow"
            )
        }
        try expect(
            immediateEdit.startArrowhead == .bar
                && immediateEdit.endArrowhead == .diamond,
            "Expected a selected start-head edit to apply immediately and preserve the opposite endpoint"
        )
        immediateController.undo()
        guard case .linear(let undoneImmediateEdit) =
            immediateController.selectedElementSnapshot.first?.geometry else {
            throw SelfTestError.failure(
                "Expected one undo to restore the selected arrowhead family"
            )
        }
        try expect(
            undoneImmediateEdit.startArrowhead == .circle
                && undoneImmediateEdit.endArrowhead == .diamond,
            "Expected one undo to restore only the edited arrowhead family"
        )
        immediateController.redo()
        immediateController.setLinearArrowheadSize(.large)
        guard case .linear(let resizedImmediateEdit) =
            immediateController.selectedElementSnapshot.first?.geometry else {
            throw SelfTestError.failure(
                "Expected an immediately resized selected arrowhead"
            )
        }
        try expect(
            resizedImmediateEdit.startArrowhead == .bar
                && resizedImmediateEdit.endArrowhead == .diamond
                && resizedImmediateEdit.arrowheadSize == .large,
            "Expected selected arrowhead size changes to apply immediately without changing either family"
        )
        immediateController.undo()
        guard case .linear(let undoneImmediateResize) =
            immediateController.selectedElementSnapshot.first?.geometry else {
            throw SelfTestError.failure(
                "Expected one undo to restore the selected arrowhead size"
            )
        }
        try expect(
            undoneImmediateResize.arrowheadSize == .medium
                && undoneImmediateResize.startArrowhead == .bar
                && undoneImmediateResize.endArrowhead == .diamond,
            "Expected one undo to restore only the arrowhead size"
        )

        let lockController = AnnotationController()
        lockController.currentTool = .arrow
        lockController.begin(at: CGPoint(x: 10, y: 20))
        lockController.end(at: CGPoint(x: 90, y: 20))
        lockController.currentTool = .select
        lockController.selectAll()
        lockController.toggleSelectionLock()
        let lockedState = DrawingToolbarState(annotationController: lockController)
        let defaultsBeforeLockedCommand = (
            lockController.currentStartArrowhead,
            lockController.currentEndArrowhead
        )
        guard case .linear(let lockedBefore) =
            lockController.elementSnapshot.first?.geometry else {
            throw SelfTestError.failure("Expected a locked selected arrow")
        }
        lockController.setLinearStartArrowhead(.diamond)
        guard case .linear(let lockedAfter) =
            lockController.elementSnapshot.first?.geometry else {
            throw SelfTestError.failure("Expected the locked arrow to remain present")
        }
        try expect(
            lockedState.startArrowhead == .unavailable
                && lockedState.endArrowhead == .unavailable
                && lockedState.visibleInspectorSections.contains(.arrowheads)
                && lockedAfter == lockedBefore
                && lockController.currentStartArrowhead
                    == defaultsBeforeLockedCommand.0
                && lockController.currentEndArrowhead
                    == defaultsBeforeLockedCommand.1,
            "Expected locked-only arrowhead controls to disable without mutating defaults"
        )

        lockController.currentTool = .arrow
        lockController.begin(at: CGPoint(x: 10, y: 50))
        lockController.end(at: CGPoint(x: 90, y: 50))
        lockController.currentTool = .select
        lockController.selectAll()
        let mixedLockState = DrawingToolbarState(annotationController: lockController)
        lockController.setLinearEndArrowhead(.circleOutline)
        let lockedLinear = lockController.elementSnapshot.first {
            $0.metadata.isLocked
        }
        let editableLinear = lockController.elementSnapshot.first {
            !$0.metadata.isLocked
        }
        guard case .linear(let lockedGeometry) = lockedLinear?.geometry,
              case .linear(let editableGeometry) = editableLinear?.geometry else {
            throw SelfTestError.failure("Expected locked and editable selected arrows")
        }
        try expect(
            mixedLockState.arrowheadChangesApplyToEditableOnly
                && lockedGeometry.endArrowhead == .arrow
                && editableGeometry.endArrowhead == .circleOutline,
            "Expected mixed locked/unlocked arrow commands to apply only to editable elements"
        )

        var undoLockedElement = AnnotationElement(
            geometry: .linear(
                AnnotationLinearGeometry(
                    points: [CGPoint(x: 0, y: 0), CGPoint(x: 60, y: 0)],
                    route: .straight,
                    startArrowhead: .none,
                    endArrowhead: .arrow,
                    startBinding: nil,
                    endBinding: nil
                )
            ),
            style: .default
        )
        undoLockedElement.metadata.isLocked = true
        let undoLockedScene = AnnotationScene(elements: [undoLockedElement])
        undoLockedScene.select([undoLockedElement.id])
        undoLockedScene.setLocked(false, for: [undoLockedElement.id])
        let undoLockedEditor = AnnotationEditor(scene: undoLockedScene)
        try expect(
            undoLockedEditor.beginLinearPointEditing(),
            "Expected the temporarily unlocked arrow to enter point-edit mode"
        )
        try expect(
            undoLockedScene.undo(),
            "Expected undo to restore the arrow's locked state"
        )
        undoLockedEditor.setLinearStartArrowhead(.bar)
        guard case .linear(let undoLockedGeometry) =
            undoLockedScene.element(withID: undoLockedElement.id)?.geometry else {
            throw SelfTestError.failure("Expected the undo-restored locked arrow")
        }
        try expect(
            undoLockedScene.element(withID: undoLockedElement.id)?.metadata.isLocked == true
                && undoLockedGeometry.startArrowhead == .none,
            "Expected point-edit mutations to revalidate selection and lock state after undo"
        )
    }
}
