import AppKit

extension SelfTestRunner {
    static func testAnnotationGeometryBoundsAndTransforms() throws {
        var style = AnnotationStyle.default
        style.strokeWidth = 4
        var element = AnnotationElement(
            geometry: .shape(
                AnnotationShapeGeometry(
                    kind: .rectangle,
                    start: CGPoint(x: 10, y: 20),
                    end: CGPoint(x: 50, y: 40)
                )
            ),
            style: style
        )
        element.metadata.rotation = .pi / 2

        try expect(
            AnnotationGeometry.localBounds(of: element) == CGRect(x: 10, y: 20, width: 40, height: 20),
            "Expected unrotated shape bounds to remain in content coordinates"
        )
        try expect(
            approximatelyEqual(
                AnnotationGeometry.worldBounds(of: element, includingStroke: false),
                CGRect(x: 20, y: 10, width: 20, height: 40)
            ),
            "Expected rotation-aware world bounds"
        )
        let expectedStrokeInset = style.strokeWidth / 2
            + AnnotationRoughStroke.maximumDestinationDeviation(
                for: style.sloppiness,
                strokeWidth: style.strokeWidth
            )
        try expect(
            approximatelyEqual(
                AnnotationGeometry.worldBounds(of: element),
                CGRect(x: 20, y: 10, width: 20, height: 40)
                    .insetBy(dx: -expectedStrokeInset, dy: -expectedStrokeInset)
            ),
            "Expected stroke width and rough destination deviation to expand world bounds"
        )

        let localPoint = CGPoint(x: 10, y: 20)
        let worldPoint = localPoint.applying(AnnotationGeometry.worldTransform(for: element))
        let roundTrip = worldPoint.applying(AnnotationGeometry.inverseWorldTransform(for: element))
        try expect(
            approximatelyEqual(roundTrip, localPoint),
            "Expected element transforms to round-trip between local and world space"
        )

        let arrow = AnnotationElement(
            geometry: .linear(
                AnnotationLinearGeometry(
                    points: [CGPoint(x: 30, y: 30), CGPoint(x: 70, y: 30)],
                    route: .straight,
                    startArrowhead: .arrow,
                    endArrowhead: .none,
                    startBinding: nil,
                    endBinding: nil
                )
            ),
            style: style
        )
        try expect(
            AnnotationGeometry.localBounds(of: arrow).height >= style.strokeWidth * 4,
            "Expected arrowhead geometry to participate in element bounds"
        )
    }

    static func testAnnotationHitTestingAndSelectionDecorations() throws {
        var filledStyle = AnnotationStyle.default
        filledStyle.strokeWidth = 2
        filledStyle.fillStyle = .solid
        filledStyle.sloppiness = .architect
        let diamond = AnnotationElement(
            geometry: .shape(
                AnnotationShapeGeometry(
                    kind: .diamond,
                    start: CGPoint(x: 20, y: 20),
                    end: CGPoint(x: 60, y: 60)
                )
            ),
            style: filledStyle
        )
        try expect(
            AnnotationHitTester.contains(CGPoint(x: 40, y: 40), in: diamond, zoomScale: 1),
            "Expected filled diamond hit testing to include its interior"
        )
        for fillStyle in [AnnotationFillStyle.hachure, .crossHatch] {
            var patternedStyle = filledStyle
            patternedStyle.fillStyle = fillStyle
            for kind in [
                AnnotationShapeKind.rectangle,
                .diamond,
                .ellipse
            ] {
                let patternedShape = AnnotationElement(
                    geometry: .shape(
                        AnnotationShapeGeometry(
                            kind: kind,
                            start: CGPoint(x: 20, y: 20),
                            end: CGPoint(x: 60, y: 60)
                        )
                    ),
                    style: patternedStyle
                )
                try expect(
                    AnnotationHitTester.contains(
                        CGPoint(x: 40, y: 40),
                        in: patternedShape,
                        zoomScale: 1
                    ),
                    "Expected \(fillStyle) \(kind) hit testing to include its visible interior"
                )
            }
        }
        try expect(
            !AnnotationHitTester.contains(CGPoint(x: 20, y: 20), in: diamond, zoomScale: 4),
            "Expected diamond hit testing to reject points outside its rotated edges"
        )

        var roundedStyle = filledStyle
        roundedStyle.roundness = 50
        let roundedRectangle = AnnotationElement(
            geometry: .shape(
                AnnotationShapeGeometry(
                    kind: .rectangle,
                    start: .zero,
                    end: CGPoint(x: 100, y: 100)
                )
            ),
            style: roundedStyle
        )
        let roundedDiamond = AnnotationElement(
            geometry: .shape(
                AnnotationShapeGeometry(
                    kind: .diamond,
                    start: .zero,
                    end: CGPoint(x: 100, y: 100)
                )
            ),
            style: roundedStyle
        )
        try expect(
            AnnotationHitTester.hitTest(
                point: .zero,
                elements: [roundedRectangle],
                zoomScale: 1
            ) == nil
                && AnnotationHitTester.hitTest(
                    point: CGPoint(x: 50, y: 50),
                    elements: [roundedRectangle],
                    zoomScale: 1
                ) == AnnotationHitTester.Hit(
                    elementID: roundedRectangle.id,
                    part: .body
                )
                && !AnnotationHitTester.contains(
                    .zero,
                    in: roundedDiamond,
                    zoomScale: 1
                ),
            "Expected rounded rectangle and diamond hit testing to follow their rendered paths"
        )

        var transparentFillStyle = roundedStyle
        transparentFillStyle.fillColor = .rgba(
            red: 1,
            green: 0,
            blue: 0,
            alpha: 0
        )
        let transparentFilledRectangle = AnnotationElement(
            geometry: roundedRectangle.geometry,
            style: transparentFillStyle
        )
        try expect(
            !AnnotationHitTester.contains(
                CGPoint(x: 50, y: 50),
                in: transparentFilledRectangle,
                zoomScale: 1
            ),
            "Expected a fully transparent solid fill not to create an interior hit"
        )

        var roundedOutlineStyle = roundedStyle
        roundedOutlineStyle.fillStyle = .none
        let roundedOutline = AnnotationElement(
            geometry: roundedRectangle.geometry,
            style: roundedOutlineStyle
        )
        try expect(
            AnnotationHitTester.contains(
                CGPoint(x: 50, y: -6),
                in: roundedOutline,
                zoomScale: 1
            ),
            "Expected rounded shape outlines to include destination-space hit tolerance"
        )

        var sharpOutlineStyle = roundedOutlineStyle
        sharpOutlineStyle.roundness = nil
        let sharpOutline = AnnotationElement(
            geometry: roundedRectangle.geometry,
            style: sharpOutlineStyle
        )
        try expect(
            !AnnotationHitTester.contains(
                CGPoint(x: -6, y: -6),
                in: sharpOutline,
                zoomScale: 1
            ),
            "Expected sharp outlines not to inherit phantom corners from expanded bounds"
        )

        let ellipseOutline = AnnotationElement(
            geometry: .shape(
                AnnotationShapeGeometry(
                    kind: .ellipse,
                    start: .zero,
                    end: CGPoint(x: 100, y: 50)
                )
            ),
            style: roundedOutlineStyle
        )
        try expect(
            AnnotationHitTester.contains(
                CGPoint(x: 50, y: -6),
                in: ellipseOutline,
                zoomScale: 1
            )
                && !AnnotationHitTester.contains(
                    .zero,
                    in: ellipseOutline,
                    zoomScale: 1
                ),
            "Expected ellipse outlines to preserve curved-edge hit behavior"
        )

        var roughOutlineStyle = roundedOutlineStyle
        roughOutlineStyle.roundness = nil
        roughOutlineStyle.strokeWidth = 3
        roughOutlineStyle.sloppiness = .cartoonist
        let roughOutline = AnnotationElement(
            geometry: .shape(
                AnnotationShapeGeometry(
                    kind: .rectangle,
                    start: CGPoint(x: 200, y: 0),
                    end: CGPoint(x: 300, y: 100)
                )
            ),
            style: roughOutlineStyle
        )
        try expect(
            AnnotationHitTester.contains(
                CGPoint(x: 190, y: 50),
                in: roughOutline,
                zoomScale: 1
            ),
            "Expected rough shape hit testing to include maximum rendered displacement"
        )

        var rotated = AnnotationElement(
            geometry: .shape(
                AnnotationShapeGeometry(
                    kind: .rectangle,
                    start: CGPoint(x: 70, y: 20),
                    end: CGPoint(x: 110, y: 40)
                )
            ),
            style: roundedStyle
        )
        rotated.metadata.rotation = .pi / 2
        try expect(
            AnnotationHitTester.contains(CGPoint(x: 90, y: 45), in: rotated, zoomScale: 1),
            "Expected rounded shape hit testing to invert element rotation"
        )

        let roundedCornerEraserHits = AnnotationHitTester.bodyHits(
            point: .zero,
            elements: [roundedRectangle],
            zoomScale: 1
        )
        let roundedInteriorEraserHits = AnnotationHitTester.bodyHits(
            point: CGPoint(x: 50, y: 50),
            elements: [roundedRectangle],
            zoomScale: 1
        )
        try expect(
            roundedCornerEraserHits.elementIDs.isEmpty
                && roundedCornerEraserHits.testedElementCount == 1
                && roundedInteriorEraserHits.elementIDs == [roundedRectangle.id]
                && roundedInteriorEraserHits.testedElementCount == 1,
            "Expected eraser hit testing to share rounded shape path semantics"
        )

        for kind in [
            AnnotationShapeKind.rectangle,
            .diamond,
            .ellipse
        ] {
            var tinyStyle = roundedOutlineStyle
            tinyStyle.strokeWidth = 2
            tinyStyle.roundness = kind == .ellipse ? nil : 6
            let tiny = AnnotationElement(
                geometry: .shape(
                    AnnotationShapeGeometry(
                        kind: kind,
                        start: .zero,
                        end: CGPoint(x: 8, y: 6)
                    )
                ),
                style: tinyStyle
            )
            try expect(
                AnnotationHitTester.contains(
                    CGPoint(x: 4, y: 3),
                    in: tiny,
                    zoomScale: 1
                ),
                "Expected oversized low-zoom \(kind) hit tolerance to fall back "
                    + "to canonical boundary distance"
            )
            if kind == .rectangle {
                try expect(
                    !AnnotationHitTester.contains(
                        CGPoint(x: -6, y: -6),
                        in: tiny,
                        zoomScale: 1
                    ),
                    "Expected rounded empty corners to remain outside the "
                        + "canonical boundary tolerance"
                )
            }
        }

        let line = AnnotationElement.legacy(
            tool: .line,
            points: [CGPoint(x: 10, y: 90), CGPoint(x: 110, y: 90)],
            style: AnnotationStyle(color: .red, rootWidth: 2, alpha: 1)
        )
        let nearLine = CGPoint(x: 50, y: 95)
        try expect(
            AnnotationHitTester.contains(nearLine, in: line, zoomScale: 1),
            "Expected screen-space hit tolerance at 1x"
        )
        try expect(
            !AnnotationHitTester.contains(nearLine, in: line, zoomScale: 4),
            "Expected hit tolerance to shrink in content space when zoomed"
        )

        guard let oneX = AnnotationGeometry.selectionDecoration(for: rotated, zoomScale: 1),
              let threeX = AnnotationGeometry.selectionDecoration(for: rotated, zoomScale: 3),
              let rotationHandle = oneX.handles.first(where: { $0.kind == .rotation }) else {
            throw SelfTestError.failure("Expected reusable selection decoration geometry")
        }
        try expect(
            approximatelyEqual(oneX.handles[0].bounds.width, threeX.handles[0].bounds.width * 3),
            "Expected selection handles to retain a fixed destination-space size"
        )
        let handleHit = AnnotationHitTester.hitTest(
            point: rotationHandle.center,
            elements: [rotated],
            selection: [rotated.id],
            zoomScale: 1
        )
        try expect(
            handleHit == AnnotationHitTester.Hit(elementID: rotated.id, part: .handle(.rotation)),
            "Expected selected-element handles to take precedence over body hits"
        )
    }

    static func testAdaptiveCurveAndArrowheadHitTesting() throws {
        var thinStyle = AnnotationStyle.default
        thinStyle.strokeWidth = 1
        thinStyle.sloppiness = .architect
        let extremeCurve = AnnotationLinearGeometry(
            points: [
                CGPoint(x: 0, y: 0),
                CGPoint(x: 120, y: 0)
            ],
            route: .curved,
            startArrowhead: .none,
            endArrowhead: .none,
            startBinding: nil,
            endBinding: nil,
            bezierControls: [
                AnnotationBezierControl(
                    start: CGPoint(x: 0, y: 100_000),
                    end: CGPoint(x: 120, y: -100_000)
                )
            ]
        )
        let extremeElement = AnnotationElement(
            geometry: .linear(extremeCurve),
            style: thinStyle
        )
        let renderedCenterlinePoint = AnnotationGeometry.linearDisplayPoints(
            extremeCurve,
            subdivisions: 4_096
        )[557]
        let approximation = AnnotationGeometry.linearApproximation(
            extremeCurve,
            maximumError: 0.15
        )
        let selectionHit = AnnotationHitTester.hitTest(
            point: renderedCenterlinePoint,
            elements: [extremeElement],
            zoomScale: 200
        )
        let eraserHits = AnnotationHitTester.bodyHits(
            point: renderedCenterlinePoint,
            elements: [extremeElement],
            zoomScale: 200
        )
        try expect(
            selectionHit == AnnotationHitTester.Hit(
                elementID: extremeElement.id,
                part: .body
            )
                && eraserHits.elementIDs == [extremeElement.id]
                && eraserHits.testedElementCount == 1
                && approximation.segments.count > 16
                && approximation.segments.count
                    <= AnnotationGeometry.maximumAdaptiveCubicSegmentsPerCurve
                && approximation.operationCount
                    <= AnnotationGeometry.maximumAdaptiveCubicSegmentsPerCurve * 2 - 1,
            "Expected selection and eraser hit testing to follow extreme cubic "
                + "centerlines at high zoom with a bounded adaptive workload"
        )

        func arrowheadElement(
            _ arrowhead: AnnotationArrowhead,
            size: AnnotationArrowheadSize = .large
        ) -> AnnotationElement {
            var style = AnnotationStyle.default
            style.strokeWidth = 2
            style.sloppiness = .architect
            return AnnotationElement(
                geometry: .linear(
                    AnnotationLinearGeometry(
                        points: [
                            CGPoint(x: 0, y: 0),
                            CGPoint(x: 100, y: 0)
                        ],
                        route: .straight,
                        startArrowhead: .none,
                        endArrowhead: arrowhead,
                        arrowheadSize: size,
                        startBinding: nil,
                        endBinding: nil
                    )
                ),
                style: style
            )
        }

        let metrics = AnnotationGeometry.arrowheadMetrics(
            strokeWidth: 2,
            size: .large
        )
        let circleCenter = CGPoint(
            x: 100 - metrics.halfWidth,
            y: 0
        )
        let circleCorner = CGPoint(
            x: 100 - metrics.halfWidth * 2 + 1.25,
            y: -metrics.halfWidth + 1.25
        )
        let circleEdge = CGPoint(
            x: circleCenter.x,
            y: -metrics.halfWidth
        )
        let outlinedCircle = arrowheadElement(.circleOutline)
        let filledCircle = arrowheadElement(.circle)
        try expect(
            !AnnotationHitTester.contains(
                circleCorner,
                in: outlinedCircle,
                zoomScale: 20
            )
                && AnnotationHitTester.contains(
                    circleEdge,
                    in: outlinedCircle,
                    zoomScale: 20
                )
                && !AnnotationHitTester.contains(
                    circleCorner,
                    in: filledCircle,
                    zoomScale: 20
                )
                && AnnotationHitTester.contains(
                    circleCenter,
                    in: filledCircle,
                    zoomScale: 20
                ),
            "Expected large circle heads to use their exact fill or stroked edge, "
                + "not an expanded bounding-box corner"
        )

        let outlinedTriangle = arrowheadElement(.triangleOutline)
        let triangleInterior = CGPoint(x: 88, y: 0)
        let triangleEdge = CGPoint(
            x: 100 - metrics.length / 2,
            y: metrics.halfWidth / 2
        )
        let bar = arrowheadElement(.bar)
        let barCorner = CGPoint(
            x: 101.2,
            y: metrics.halfWidth + 1.2
        )
        let crowFoot = arrowheadElement(.crowFoot)
        let crowInterior = CGPoint(x: 90, y: 4.2)
        let zeroOrOne = arrowheadElement(.zeroOrOne)
        let compoundCorner = CGPoint(x: 99, y: 12)
        try expect(
            !AnnotationHitTester.contains(
                triangleInterior,
                in: outlinedTriangle,
                zoomScale: 20
            )
                && AnnotationHitTester.contains(
                    triangleEdge,
                    in: outlinedTriangle,
                    zoomScale: 20
                )
                && !AnnotationHitTester.contains(
                    barCorner,
                    in: bar,
                    zoomScale: 20
                )
                && !AnnotationHitTester.contains(
                    crowInterior,
                    in: crowFoot,
                    zoomScale: 20
                )
                && !AnnotationHitTester.contains(
                    compoundCorner,
                    in: zeroOrOne,
                    zoomScale: 20
                ),
            "Expected outlined, bar, crow-foot, and compound arrowheads to hit "
                + "only their stroked paths within destination-space tolerance"
        )
    }

    static func testMixedLockSelectionHandlesMatchEditableElements() throws {
        let editable = AnnotationElement.legacy(
            tool: .rectangle,
            points: [CGPoint(x: 10, y: 30), CGPoint(x: 50, y: 70)],
            style: .default
        )
        var locked = AnnotationElement.legacy(
            tool: .rectangle,
            points: [CGPoint(x: 150, y: 30), CGPoint(x: 210, y: 90)],
            style: .default
        )
        locked.metadata.isLocked = true
        let elements = [editable, locked]
        let selection: Set<AnnotationElementID> = [editable.id, locked.id]

        let presented = AnnotationSelectionPresentation.editableElements(
            from: elements,
            selectedElementIDs: selection
        )
        try expect(
            presented.map(\.id) == [editable.id],
            "Expected mixed selection decorations to describe only editable elements"
        )

        guard let editableDecoration = AnnotationGeometry.selectionDecoration(
            for: editable,
            zoomScale: 1
        ),
        let editableResizeHandle = editableDecoration.handles.first(where: {
            $0.kind == .bottomTrailing
        }),
        let mixedDecoration = AnnotationGeometry.selectionDecoration(
            for: elements,
            zoomScale: 1
        ),
        let staleMixedHandle = mixedDecoration.handles.first(where: {
            $0.kind == .top
        }),
        let lockedDecoration = AnnotationGeometry.selectionDecoration(
            for: locked,
            zoomScale: 1
        ),
        let lockedRotationHandle = lockedDecoration.handles.first(where: {
            $0.kind == .rotation
        }) else {
            throw SelfTestError.failure("Expected selection handles for mixed-lock regression setup")
        }

        try expect(
            AnnotationHitTester.hitTest(
                point: staleMixedHandle.center,
                elements: elements,
                selection: selection,
                zoomScale: 1
            ) == nil,
            "Expected handles from locked-inclusive bounds to be non-interactive"
        )
        try expect(
            AnnotationHitTester.hitTest(
                point: editableResizeHandle.center,
                elements: elements,
                selection: selection,
                zoomScale: 1
            ) == AnnotationHitTester.Hit(
                elementID: editable.id,
                part: .handle(.bottomTrailing)
            ),
            "Expected mixed selection handles to align with the editable transform bounds"
        )

        try expect(
            AnnotationHitTester.hitTest(
                point: lockedRotationHandle.center,
                elements: elements,
                selection: selection,
                zoomScale: 1
            ) == nil,
            "Expected selected locked elements not to expose inferred handles"
        )
        let lockedHandleScene = AnnotationScene(elements: elements)
        lockedHandleScene.select(selection)
        let lockedHandleEditor = AnnotationEditor(scene: lockedHandleScene)
        let editableBeforeLockedHandle =
            lockedHandleScene.element(withID: editable.id)
        let lockedBeforeLockedHandle =
            lockedHandleScene.element(withID: locked.id)
        _ = lockedHandleEditor.beginInteraction(
            at: lockedRotationHandle.center,
            zoomScale: 1,
            modifiers: [],
            clickCount: 1
        )
        lockedHandleEditor.updateInteraction(
            to: CGPoint(
                x: lockedRotationHandle.center.x + 20,
                y: lockedRotationHandle.center.y + 15
            ),
            modifiers: []
        )
        lockedHandleEditor.endInteraction(
            at: CGPoint(
                x: lockedRotationHandle.center.x + 20,
                y: lockedRotationHandle.center.y + 15
            ),
            modifiers: []
        )
        try expect(
            lockedHandleScene.element(withID: editable.id)
                == editableBeforeLockedHandle
                && lockedHandleScene.element(withID: locked.id)
                    == lockedBeforeLockedHandle,
            "Expected clicking a locked element's inferred handle not to transform "
                + "the editable selection"
        )

        let scene = AnnotationScene(elements: elements)
        scene.select(selection)
        let editor = AnnotationEditor(scene: scene)
        let lockedBefore = scene.element(withID: locked.id)
        _ = editor.beginInteraction(
            at: editableResizeHandle.center,
            zoomScale: 1,
            modifiers: [],
            clickCount: 1
        )
        editor.endInteraction(
            at: CGPoint(
                x: editableResizeHandle.center.x + 20,
                y: editableResizeHandle.center.y + 15
            ),
            modifiers: []
        )
        try expect(
            scene.element(withID: locked.id) == lockedBefore,
            "Expected a mixed-selection resize to leave locked elements unchanged"
        )
    }
}
