import AppKit

extension SelfTestRunner {
    static func testPendingErasureRasterCompositing() throws {
        var roughShapeStyle = AnnotationStyle(
            color: .blue,
            rootWidth: 4,
            alpha: 0.82,
            fillColor: .rgba(red: 1, green: 0.5, blue: 0, alpha: 0.9),
            fillStyle: .hachure,
            sloppiness: .artist
        )
        roughShapeStyle.strokePattern = .dashed
        let roughShape = AnnotationElement(
            geometry: .shape(
                AnnotationShapeGeometry(
                    kind: .rectangle,
                    start: CGPoint(x: 14, y: 14),
                    end: CGPoint(x: 72, y: 64)
                )
            ),
            style: roughShapeStyle
        )

        var crossHatchStyle = roughShapeStyle
        crossHatchStyle.fillStyle = .crossHatch
        crossHatchStyle.sloppiness = .cartoonist
        let crossHatch = AnnotationElement(
            geometry: .shape(
                AnnotationShapeGeometry(
                    kind: .diamond,
                    start: CGPoint(x: 22, y: 12),
                    end: CGPoint(x: 82, y: 70)
                )
            ),
            style: crossHatchStyle
        )

        var solidStyle = roughShapeStyle
        solidStyle.fillStyle = .solid
        solidStyle.strokePattern = .solid
        let fillAndStroke = AnnotationElement(
            geometry: .shape(
                AnnotationShapeGeometry(
                    kind: .ellipse,
                    start: CGPoint(x: 18, y: 14),
                    end: CGPoint(x: 88, y: 70)
                )
            ),
            style: solidStyle
        )

        var pressureStyle = AnnotationStyle(
            color: .black,
            rootWidth: 14,
            alpha: 0.74,
            sloppiness: .artist
        )
        pressureStyle.pressureEnabled = true
        let pressure = AnnotationElement(
            geometry: .freehand(
                AnnotationFreehandGeometry(
                    samples: [
                        AnnotationPointSample(
                            location: CGPoint(x: 10, y: 42),
                            pressure: 0.2
                        ),
                        AnnotationPointSample(
                            location: CGPoint(x: 42, y: 24),
                            pressure: 0.65
                        ),
                        AnnotationPointSample(
                            location: CGPoint(x: 92, y: 50),
                            pressure: 1
                        )
                    ],
                    isHighlighter: false
                )
            ),
            style: pressureStyle
        )

        var highlighterStyle = AnnotationStyle(
            color: .highlighterYellow,
            rootWidth: 18,
            alpha: 0.8,
            sloppiness: .architect
        )
        highlighterStyle.pressureEnabled = false
        let highlighter = AnnotationElement(
            geometry: .freehand(
                AnnotationFreehandGeometry(
                    samples: [
                        AnnotationPointSample(
                            location: CGPoint(x: 10, y: 42),
                            pressure: nil
                        ),
                        AnnotationPointSample(
                            location: CGPoint(x: 94, y: 42),
                            pressure: nil
                        )
                    ],
                    isHighlighter: true
                )
            ),
            style: highlighterStyle
        )

        var arrowStyle = AnnotationStyle(
            color: .pink,
            rootWidth: 5,
            alpha: 0.88,
            sloppiness: .artist
        )
        arrowStyle.strokePattern = .dotted
        let compoundArrow = AnnotationElement(
            geometry: .linear(
                AnnotationLinearGeometry(
                    points: [
                        CGPoint(x: 12, y: 58),
                        CGPoint(x: 52, y: 18),
                        CGPoint(x: 104, y: 52)
                    ],
                    route: .curved,
                    startArrowhead: .triangle,
                    endArrowhead: .zeroOrMany,
                    arrowheadSize: .large,
                    startBinding: nil,
                    endBinding: nil
                )
            ),
            style: arrowStyle
        )

        let text = AnnotationElement(
            geometry: .text(
                AnnotationTextGeometry(
                    origin: CGPoint(x: 14, y: 18),
                    bounds: nil,
                    text: "Fade",
                    fontSize: 32,
                    fontName: "",
                    alignment: .left
                )
            ),
            style: AnnotationStyle(
                color: .white,
                rootWidth: 2,
                alpha: 0.76
            )
        )

        let headlessLine = AnnotationElement(
            geometry: .linear(
                AnnotationLinearGeometry(
                    points: [
                        CGPoint(x: 12, y: 28),
                        CGPoint(x: 98, y: 54)
                    ],
                    route: .curved,
                    startArrowhead: .none,
                    endArrowhead: .none,
                    startBinding: nil,
                    endBinding: nil,
                    bezierControls: [
                        AnnotationBezierControl(
                            start: CGPoint(x: 38, y: 4),
                            end: CGPoint(x: 74, y: 76)
                        )
                    ]
                )
            ),
            style: AnnotationStyle(
                color: .green,
                rootWidth: 6,
                alpha: 0.7,
                sloppiness: .cartoonist
            )
        )

        var stackStyle = solidStyle
        stackStyle.opacity = 1
        let stackedBottom = AnnotationElement(
            geometry: .shape(
                AnnotationShapeGeometry(
                    kind: .rectangle,
                    start: CGPoint(x: 24, y: 20),
                    end: CGPoint(x: 82, y: 68)
                )
            ),
            style: stackStyle
        )
        var stackedTop = stackedBottom
        stackedTop = AnnotationElement(
            geometry: stackedTop.geometry,
            style: stackStyle
        )

        let families: [(String, [AnnotationElement])] = [
            ("rough hachure", [roughShape]),
            ("rough cross-hatch", [crossHatch]),
            ("solid fill plus stroke", [fillAndStroke]),
            ("pressure freehand", [pressure]),
            ("highlighter", [highlighter]),
            ("filled and compound arrowheads", [compoundArrow]),
            ("text", [text]),
            ("headless line", [headlessLine]),
            ("stacked pending run", [stackedBottom, stackedTop])
        ]

        for destinationScale in [CGFloat(1), 2, 4] {
            for (label, elements) in families {
                let normal = try renderPixels(
                    elements: elements,
                    renderer: AnnotationRenderer(),
                    width: 120,
                    height: 88,
                    destinationPointScale: destinationScale
                )
                let pending = try renderPixels(
                    elements: elements,
                    renderer: AnnotationRenderer(),
                    pendingErasureElementIDs: Set(elements.map(\.id)),
                    width: 120,
                    height: 88,
                    destinationPointScale: destinationScale
                )
                try expectRaster(
                    pending,
                    uniformlyScaling: normal,
                    by: 0.28,
                    context: "\(label) at \(destinationScale)x"
                )
            }
        }
    }

    static func testReliableEraserSweepAndHitCoverage() throws {
        let controller = AnnotationController()

        controller.currentTool = .pen
        controller.begin(at: CGPoint(x: 20, y: 28))
        controller.end(at: CGPoint(x: 20, y: 52))

        controller.currentTool = .highlighter
        controller.begin(at: CGPoint(x: 42, y: 28))
        controller.end(at: CGPoint(x: 42, y: 52))

        controller.currentTool = .rectangle
        controller.begin(at: CGPoint(x: 58, y: 30))
        controller.end(at: CGPoint(x: 72, y: 50))

        controller.setFillColor(.palette(.yellow))
        controller.setFillStyle(.solid)
        controller.currentTool = .ellipse
        controller.begin(at: CGPoint(x: 78, y: 30))
        controller.end(at: CGPoint(x: 92, y: 50))

        controller.currentTool = .arrow
        controller.begin(at: CGPoint(x: 108, y: 28))
        controller.end(at: CGPoint(x: 108, y: 52))

        controller.setInsertionPoint(CGPoint(x: 124, y: 30))
        controller.beginTypingSession(rightAligned: false)
        controller.insertText("Text")
        controller.finishTypingSession()

        let expectedIDs = Set(controller.elementSnapshot.map(\.id))
        controller.currentTool = .eraser
        var notificationCount = 0
        controller.onStateChanged = { notificationCount += 1 }
        controller.beginErasing(at: CGPoint(x: -40, y: 40), zoomScale: 1)
        let pendingAfterBegin = controller.pendingErasureElementIDsForTesting.count
        let notificationsAfterBegin = notificationCount
        controller.continueErasing(at: CGPoint(x: 180, y: 40), zoomScale: 1)
        let sampleCount = controller.eraserSweepSampleCountForTesting
        let hitTestCount = controller.eraserHitTestCountForTesting
        try expect(
            controller.pendingErasureElementIDsForTesting == expectedIDs
                && pendingAfterBegin == 0
                && notificationsAfterBegin == 0
                && notificationCount == 1
                && sampleCount <= 38
                && hitTestCount <= sampleCount * expectedIDs.count,
            "Expected one fast eraser sweep to stage every crossed annotation family once "
                + "with one candidate evaluation per sample and one redraw: pending="
                + "\(controller.pendingErasureElementIDsForTesting.count)/\(expectedIDs.count), "
                + "beginPending=\(pendingAfterBegin), beginNotifications="
                + "\(notificationsAfterBegin), notifications=\(notificationCount), "
                + "samples=\(sampleCount), "
                + "hitTests=\(hitTestCount)"
        )
        controller.continueErasing(at: CGPoint(x: 180, y: 40), zoomScale: 1)
        try expect(
            controller.pendingErasureElementIDsForTesting == expectedIDs
                && notificationCount == 1,
            "Expected duplicate eraser samples to leave the pending union and redraw count unchanged"
        )
        controller.cancelErasing()
        try expect(
            controller.elementSnapshot.count == expectedIDs.count
                && controller.pendingErasureElementIDsForTesting.isEmpty
                && notificationCount == 2,
            "Expected cancellation to restore the full staged sweep with one redraw and no deletion"
        )

        var cartoonistStyle = AnnotationStyle.default
        cartoonistStyle.strokeWidth = 3
        cartoonistStyle.sloppiness = .cartoonist
        let displacedRectangle = AnnotationElement(
            geometry: .shape(
                AnnotationShapeGeometry(
                    kind: .rectangle,
                    start: CGPoint(x: 200, y: 20),
                    end: CGPoint(x: 240, y: 60)
                )
            ),
            style: cartoonistStyle
        )
        var fillStyle = AnnotationStyle.default
        fillStyle.fillStyle = .solid
        let filledEllipse = AnnotationElement(
            geometry: .shape(
                AnnotationShapeGeometry(
                    kind: .ellipse,
                    start: CGPoint(x: 260, y: 20),
                    end: CGPoint(x: 300, y: 60)
                )
            ),
            style: fillStyle
        )
        let curvedGeometry = AnnotationLinearGeometry(
            points: [CGPoint(x: 320, y: 60), CGPoint(x: 380, y: 20)],
            route: .curved,
            startArrowhead: .none,
            endArrowhead: .none,
            startBinding: nil,
            endBinding: nil,
            bezierControls: [
                AnnotationBezierControl(
                    start: CGPoint(x: 330, y: 10),
                    end: CGPoint(x: 370, y: 70)
                )
            ]
        )
        let curved = AnnotationElement(
            geometry: .linear(curvedGeometry),
            style: .default
        )
        let arrowGeometry = AnnotationLinearGeometry(
            points: [CGPoint(x: 400, y: 40), CGPoint(x: 460, y: 40)],
            route: .straight,
            startArrowhead: .none,
            endArrowhead: .arrow,
            startBinding: nil,
            endBinding: nil
        )
        let arrow = AnnotationElement(
            geometry: .linear(arrowGeometry),
            style: .default
        )
        let text = AnnotationElement(
            geometry: .text(
                AnnotationTextGeometry(
                    origin: CGPoint(x: 480, y: 20),
                    bounds: CGRect(x: 480, y: 20, width: 60, height: 30),
                    text: "Text",
                    fontSize: 20,
                    fontName: "",
                    alignment: .left
                )
            ),
            style: .default
        )
        let curvedHitPoint = AnnotationGeometry.linearDisplayPoints(
            curvedGeometry,
            subdivisions: 32
        )[16]
        let arrowMetrics = AnnotationGeometry.arrowheadMetrics(strokeWidth: 3)
        let arrowheadHitPoint = CGPoint(
            x: 460 - arrowMetrics.length,
            y: 40 + arrowMetrics.halfWidth
        )
        try expect(
            AnnotationHitTester.contains(
                CGPoint(x: 190, y: 40),
                in: displacedRectangle,
                zoomScale: 1
            )
                && AnnotationHitTester.contains(
                    CGPoint(x: 280, y: 40),
                    in: filledEllipse,
                    zoomScale: 1
                )
                && AnnotationHitTester.contains(
                    curvedHitPoint,
                    in: curved,
                    zoomScale: 1
                )
                && AnnotationHitTester.contains(
                    arrowheadHitPoint,
                    in: arrow,
                    zoomScale: 1
                )
                && AnnotationHitTester.contains(
                    CGPoint(x: 510, y: 35),
                    in: text,
                    zoomScale: 1
                ),
            "Expected expanded eraser hit coverage for Cartoonist displacement, shape fill, curves, arrowheads, and text"
        )

        var stackedStyle = AnnotationStyle.default
        stackedStyle.fillStyle = .solid
        let stackedElements = (0..<10_000).map { _ in
            AnnotationElement(
                geometry: .shape(
                    AnnotationShapeGeometry(
                        kind: .rectangle,
                        start: CGPoint(x: 600, y: 20),
                        end: CGPoint(x: 640, y: 60)
                    )
                ),
                style: stackedStyle
            )
        }
        let stackedController = AnnotationController(elements: stackedElements)
        stackedController.beginErasing(
            at: CGPoint(x: 620, y: 40),
            zoomScale: 1
        )
        try expect(
            stackedController.pendingErasureElementIDsForTesting.count == 10_000
                && stackedController.eraserSweepSampleCountForTesting == 1
                && stackedController.eraserHitTestCountForTesting == 10_000,
            "Expected one eraser sample over 10k stacked elements to perform "
                + "exactly one linear candidate scan"
        )
        stackedController.continueErasing(
            at: CGPoint(x: 620, y: 40),
            zoomScale: 1
        )
        try expect(
            stackedController.eraserHitTestCountForTesting == 10_000,
            "Expected staged 10k elements to be excluded once without rescanning "
                + "or compacting the candidate array"
        )
        stackedController.cancelErasing()
    }
}
