import AppKit

extension SelfTestRunner {
    static func testSmartDrawClosedShapeRecognition() throws {
        let circle = noisyEllipsePoints(
            center: CGPoint(x: 120, y: 100),
            radiusX: 58,
            radiusY: 57,
            rotation: 0,
            count: 64
        )
        try expect(
            SmartDrawRecognizer.recognize(points: circle, duration: 0.8, zoomScale: 1)?.kind
                == .circle,
            "Expected a noisy closed round gesture to classify as a circle"
        )

        let ellipse = noisyEllipsePoints(
            center: CGPoint(x: 140, y: 120),
            radiusX: 82,
            radiusY: 39,
            rotation: 0.22,
            count: 64
        )
        try expect(
            SmartDrawRecognizer.recognize(points: ellipse, duration: 0.9, zoomScale: 1)?.kind
                == .ellipse,
            "Expected an elongated noisy round gesture to classify as an ellipse"
        )

        let square = noisyPolygonPoints(
            corners: [
                CGPoint(x: 40, y: 40),
                CGPoint(x: 140, y: 40),
                CGPoint(x: 140, y: 140),
                CGPoint(x: 40, y: 140)
            ],
            samplesPerEdge: 12
        )
        try expect(
            SmartDrawRecognizer.recognize(points: square, duration: 0.75, zoomScale: 1)?.kind
                == .square,
            "Expected square-vs-rectangle recognition to preserve a square"
        )

        let rectangle = noisyPolygonPoints(
            corners: [
                CGPoint(x: 30, y: 55),
                CGPoint(x: 190, y: 55),
                CGPoint(x: 190, y: 125),
                CGPoint(x: 30, y: 125)
            ],
            samplesPerEdge: 12
        )
        try expect(
            SmartDrawRecognizer.recognize(points: rectangle, duration: 0.8, zoomScale: 1)?.kind
                == .rectangle,
            "Expected square-vs-rectangle recognition to preserve an elongated rectangle"
        )

        let diamond = noisyPolygonPoints(
            corners: [
                CGPoint(x: 120, y: 28),
                CGPoint(x: 192, y: 100),
                CGPoint(x: 120, y: 172),
                CGPoint(x: 48, y: 100)
            ],
            samplesPerEdge: 12
        )
        guard let diamondCandidate = SmartDrawRecognizer.recognize(
            points: diamond,
            duration: 0.8,
            zoomScale: 1
        ) else {
            throw SelfTestError.failure("Expected a rotated square gesture to produce a candidate")
        }
        try expect(
            diamondCandidate.kind == .diamond,
            "Expected a rotated square to classify as a diamond"
        )
        guard case .shape(let diamondGeometry) = diamondCandidate.geometry else {
            throw SelfTestError.failure("Expected diamond recognition to return typed shape geometry")
        }
        try expect(
            diamondGeometry.kind == .diamond
                && diamondCandidate.rotation == 0
                && distance(
                    CGPoint(x: diamondGeometry.bounds.midX, y: diamondGeometry.bounds.midY),
                    CGPoint(x: 120, y: 100)
                ) < 4
                && abs(diamondGeometry.bounds.width - 144) < 10
                && abs(diamondGeometry.bounds.height - 144) < 10,
            "Expected diamond recognition to emit aligned cardinal vertices with zero rotation"
        )
    }

    static func testSmartDrawRobustGeometryFitting() throws {
        let circleCenter = CGPoint(x: 145, y: 112)
        var circle = noisyEllipsePoints(
            center: circleCenter,
            radiusX: 62,
            radiusY: 58,
            rotation: 0.28,
            count: 84
        )
        circle.insert(CGPoint(x: 330, y: -75), at: 37)
        circle = [
            CGPoint(x: 224, y: 91),
            CGPoint(x: 216, y: 103)
        ] + circle + [
            CGPoint(x: 216, y: 121),
            CGPoint(x: 226, y: 132)
        ]
        guard let circleCandidate = SmartDrawRecognizer.recognize(
            points: circle,
            duration: 1.1,
            zoomScale: 1
        ), circleCandidate.kind == .circle,
        case .shape(let circleGeometry) = circleCandidate.geometry else {
            throw SelfTestError.failure(
                "Expected a near-circular overshooting gesture with one outlier to fit a circle"
            )
        }
        let fittedCircleCenter = CGPoint(
            x: circleGeometry.bounds.midX,
            y: circleGeometry.bounds.midY
        )
        try expect(
            abs(circleGeometry.bounds.width - circleGeometry.bounds.height) < 0.001
                && distance(fittedCircleCenter, circleCenter) < 5
                && abs(circleGeometry.bounds.width - 120) < 12,
            "Expected circle snapping to preserve the robust center and overall footprint, "
                + "got \(circleGeometry.bounds)"
        )

        let ellipseCenter = CGPoint(x: 210, y: 165)
        let ellipseRotation: CGFloat = 0.43
        var incompleteEllipse = imperfectEllipsePoints(
            center: ellipseCenter,
            radiusX: 92,
            radiusY: 43,
            rotation: ellipseRotation,
            startAngle: 0.24,
            endAngle: 2 * .pi - 0.42,
            count: 91,
            unevenPower: 1.45
        )
        incompleteEllipse.insert(CGPoint(x: 410, y: 350), at: 51)
        guard let ellipseCandidate = SmartDrawRecognizer.recognize(
            points: incompleteEllipse,
            duration: 1.25,
            zoomScale: 1
        ), ellipseCandidate.kind == .ellipse,
        case .shape(let ellipseGeometry) = ellipseCandidate.geometry else {
            throw SelfTestError.failure(
                "Expected an incomplete, unevenly sampled rotated ellipse to be recognized"
            )
        }
        let fittedEllipseCenter = CGPoint(
            x: ellipseGeometry.bounds.midX,
            y: ellipseGeometry.bounds.midY
        )
        try expect(
            distance(fittedEllipseCenter, ellipseCenter) < 7
                && abs(ellipseGeometry.bounds.width - 184) < 16
                && abs(ellipseGeometry.bounds.height - 86) < 13
                && angleDifferenceModulo(
                    ellipseCandidate.rotation,
                    ellipseRotation,
                    period: .pi
                ) < 0.12,
            "Expected robust ellipse center, radii, and orientation, got bounds "
                + "\(ellipseGeometry.bounds) at \(ellipseCandidate.rotation)"
        )

        let rectangleCenter = CGPoint(x: 190, y: 150)
        let rectangleRotation: CGFloat = 0.31
        let rectangleCorners = rotatedRectangleCorners(
            center: rectangleCenter,
            width: 174,
            height: 78,
            rotation: rectangleRotation
        )
        var rectangle = unevenPolygonPoints(
            corners: rectangleCorners,
            samplesPerEdge: [9, 24, 12, 19],
            close: true
        )
        rectangle.insert(CGPoint(x: -120, y: 380), at: 28)
        rectangle = [
            CGPoint(
                x: rectangleCorners[0].x - 7,
                y: rectangleCorners[0].y + 5
            )
        ] + rectangle + [
            CGPoint(
                x: rectangleCorners[0].x + 9,
                y: rectangleCorners[0].y - 6
            )
        ]
        guard let rectangleCandidate = SmartDrawRecognizer.recognize(
            points: rectangle,
            duration: 1.05,
            zoomScale: 1
        ), rectangleCandidate.kind == .rectangle,
        case .shape(let rectangleGeometry) = rectangleCandidate.geometry else {
            throw SelfTestError.failure(
                "Expected a noisy rotated rectangle with closure overshoot to be recognized"
            )
        }
        let fittedRectangleCenter = CGPoint(
            x: rectangleGeometry.bounds.midX,
            y: rectangleGeometry.bounds.midY
        )
        let expectedAxisWidth = abs(174 * cos(rectangleRotation))
            + abs(78 * sin(rectangleRotation))
        let expectedAxisHeight = abs(174 * sin(rectangleRotation))
            + abs(78 * cos(rectangleRotation))
        try expect(
            distance(fittedRectangleCenter, rectangleCenter) < 7
                && abs(rectangleGeometry.bounds.width - expectedAxisWidth) < 18
                && abs(rectangleGeometry.bounds.height - expectedAxisHeight) < 16
                && rectangleCandidate.rotation == 0,
            "Expected noisy rotated rectangle fitting to preserve its robust screen footprint "
                + "while emitting horizontal/vertical edges, got "
                + "\(rectangleGeometry.bounds) at \(rectangleCandidate.rotation)"
        )

        let nearSquareCorners = rotatedRectangleCorners(
            center: CGPoint(x: 120, y: 120),
            width: 106,
            height: 98,
            rotation: 0.19
        )
        guard let squareCandidate = SmartDrawRecognizer.recognize(
            points: unevenPolygonPoints(
                corners: nearSquareCorners,
                samplesPerEdge: [10, 17, 12, 20],
                close: false
            ),
            duration: 0.9,
            zoomScale: 1
        ), squareCandidate.kind == .square,
        case .shape(let squareGeometry) = squareCandidate.geometry else {
            throw SelfTestError.failure(
                "Expected a nearly equal-sided rotated box to snap to a square"
            )
        }
        try expect(
            abs(squareGeometry.bounds.width - squareGeometry.bounds.height) < 0.001
                && distance(
                    CGPoint(x: squareGeometry.bounds.midX, y: squareGeometry.bounds.midY),
                    CGPoint(x: 120, y: 120)
                ) < 6
                && squareCandidate.rotation == 0,
            "Expected near-square fitting to snap equal axis-aligned sides around the fitted center"
        )

        let robustDiamondCenter = CGPoint(x: 205, y: 138)
        let robustDiamond = unevenPolygonPoints(
            corners: [
                CGPoint(x: robustDiamondCenter.x, y: robustDiamondCenter.y - 74),
                CGPoint(x: robustDiamondCenter.x + 66, y: robustDiamondCenter.y),
                CGPoint(x: robustDiamondCenter.x, y: robustDiamondCenter.y + 74),
                CGPoint(x: robustDiamondCenter.x - 66, y: robustDiamondCenter.y)
            ],
            samplesPerEdge: [11, 23, 14, 19],
            close: true
        )
        guard let robustDiamondCandidate = SmartDrawRecognizer.recognize(
            points: robustDiamond,
            duration: 0.95,
            zoomScale: 1
        ), robustDiamondCandidate.kind == .diamond,
        case .shape(let robustDiamondGeometry) = robustDiamondCandidate.geometry else {
            throw SelfTestError.failure("Expected an uneven noisy diamond gesture to be recognized")
        }
        try expect(
            robustDiamondCandidate.rotation == 0
                && distance(
                    CGPoint(
                        x: robustDiamondGeometry.bounds.midX,
                        y: robustDiamondGeometry.bounds.midY
                    ),
                    robustDiamondCenter
                ) < 6
                && abs(robustDiamondGeometry.bounds.width - 132) < 14
                && abs(robustDiamondGeometry.bounds.height - 148) < 14,
            "Expected robust diamond fitting to preserve cardinal footprint with zero rotation"
        )

        let doubleLoop = noisyEllipsePoints(
            center: CGPoint(x: 120, y: 100),
            radiusX: 58,
            radiusY: 56,
            rotation: 0,
            count: 52
        )
        try expect(
            SmartDrawRecognizer.recognize(
                points: doubleLoop + Array(doubleLoop.dropFirst()),
                duration: 1.8,
                zoomScale: 1
            ) == nil,
            "Expected an overtraced double-loop scribble to remain freehand"
        )
    }

    static func testSmartDrawArrowAndNegativeRecognition() throws {
        let tail = CGPoint(x: 30, y: 110)
        let tip = CGPoint(x: 205, y: 62)
        let arrow = interpolatedPoints(from: tail, to: tip, count: 18)
            + interpolatedPoints(
                from: tip,
                to: CGPoint(x: 166, y: 50),
                count: 6,
                droppingFirst: true
            )
            + interpolatedPoints(
                from: CGPoint(x: 166, y: 50),
                to: tip,
                count: 6,
                droppingFirst: true
            )
            + interpolatedPoints(
                from: tip,
                to: CGPoint(x: 180, y: 94),
                count: 6,
                droppingFirst: true
            )
        guard let arrowCandidate = SmartDrawRecognizer.recognize(
            points: arrow,
            duration: 0.7,
            zoomScale: 1
        ) else {
            throw SelfTestError.failure("Expected a shaft-and-head gesture to classify as an arrow")
        }
        try expect(arrowCandidate.kind == .arrow, "Expected arrow candidate kind")
        guard case .linear(let arrowGeometry) = arrowCandidate.geometry else {
            throw SelfTestError.failure("Expected arrow recognition to return linear geometry")
        }
        try expect(
            arrowGeometry.points.first == tail
                && distance(arrowGeometry.points.last ?? .zero, tip) < 2
                && arrowGeometry.startArrowhead == .none
                && arrowGeometry.endArrowhead == .arrow,
            "Expected arrow direction and head endpoint to follow the drawn shaft"
        )
        guard let reversedArrow = SmartDrawRecognizer.recognize(
            points: Array(arrow.reversed()),
            duration: 0.7,
            zoomScale: 1
        ), case .linear(let reversedGeometry) = reversedArrow.geometry else {
            throw SelfTestError.failure("Expected a head-first arrow gesture to be recognized")
        }
        try expect(
            reversedArrow.kind == .arrow
                && distance(reversedGeometry.points.first ?? .zero, tail) < 2
                && distance(reversedGeometry.points.last ?? .zero, tip) < 2
                && reversedGeometry.endArrowhead == .arrow,
            "Expected arrow direction detection to find the converging head at either stroke endpoint"
        )

        let scribble = [
            CGPoint(x: 20, y: 20),
            CGPoint(x: 180, y: 160),
            CGPoint(x: 30, y: 150),
            CGPoint(x: 170, y: 30),
            CGPoint(x: 45, y: 35),
            CGPoint(x: 165, y: 145),
            CGPoint(x: 25, y: 90),
            CGPoint(x: 175, y: 92),
            CGPoint(x: 22, y: 22)
        ]
        try expect(
            SmartDrawRecognizer.recognize(points: scribble, duration: 1.4, zoomScale: 1) == nil,
            "Expected an intersecting scribble to be rejected"
        )
        try expect(
            SmartDrawRecognizer.recognize(
                points: noisyEllipsePoints(
                    center: CGPoint(x: 5, y: 5),
                    radiusX: 4,
                    radiusY: 4,
                    rotation: 0,
                    count: 24
                ),
                duration: 0.4,
                zoomScale: 1
            ) == nil,
            "Expected tiny gestures to be rejected at the current zoom"
        )
        let zoomScaledCircle = (0..<32).map { index in
            let angle = CGFloat(index) * 2 * .pi / 31
            return CGPoint(
                x: 30 + cos(angle) * 10,
                y: 30 + sin(angle) * 10
            )
        }
        let zoomOneCandidate = SmartDrawRecognizer.recognize(
            points: zoomScaledCircle,
            duration: 0.45,
            zoomScale: 1
        )
        let zoomTwoCandidate = SmartDrawRecognizer.recognize(
            points: zoomScaledCircle,
            duration: 0.45,
            zoomScale: 2
        )
        try expect(
            zoomOneCandidate == nil && zoomTwoCandidate?.kind == .circle,
            "Expected minimum recognition distances to scale with the current zoom "
                + "(1x: \(String(describing: zoomOneCandidate)), "
                + "2x: \(String(describing: zoomTwoCandidate)))"
        )
        try expect(
            SmartDrawRecognizer.recognize(
                points: scribble,
                duration: 6,
                zoomScale: 1
            ) == nil,
            "Expected slow scribbles to be rejected"
        )

        let noisyTail = CGPoint(x: 24, y: 158)
        let noisyTip = CGPoint(x: 218, y: 68)
        let shaftVector = CGPoint(
            x: noisyTip.x - noisyTail.x,
            y: noisyTip.y - noisyTail.y
        )
        let shaftLength = hypot(shaftVector.x, shaftVector.y)
        let shaftNormal = CGPoint(
            x: -shaftVector.y / shaftLength,
            y: shaftVector.x / shaftLength
        )
        let noisyShaft = (0..<31).map { index -> CGPoint in
            let fraction = CGFloat(index) / 30
            let noise = sin(CGFloat(index) * 1.19) * 1.4
            return CGPoint(
                x: noisyTail.x + shaftVector.x * fraction + shaftNormal.x * noise,
                y: noisyTail.y + shaftVector.y * fraction + shaftNormal.y * noise
            )
        }
        let noisyArrow = noisyShaft
            + interpolatedPoints(
                from: noisyTip,
                to: CGPoint(x: 169, y: 55),
                count: 8,
                droppingFirst: true
            )
            + interpolatedPoints(
                from: CGPoint(x: 169, y: 55),
                to: CGPoint(x: 217, y: 69),
                count: 7,
                droppingFirst: true
            )
            + interpolatedPoints(
                from: CGPoint(x: 217, y: 69),
                to: CGPoint(x: 183, y: 113),
                count: 9,
                droppingFirst: true
            )
        guard let noisyArrowCandidate = SmartDrawRecognizer.recognize(
            points: noisyArrow,
            duration: 1.0,
            zoomScale: 1
        ), noisyArrowCandidate.kind == .arrow,
        case .linear(let noisyArrowGeometry) = noisyArrowCandidate.geometry else {
            throw SelfTestError.failure(
                "Expected a noisy, unevenly sampled shaft-and-head gesture to fit an arrow"
            )
        }
        try expect(
            distance(noisyArrowGeometry.points[0], noisyTail) < 5
                && distance(noisyArrowGeometry.points[1], noisyTip) < 5,
            "Expected arrow fitting to preserve the intended shaft endpoints, got "
                + "\(noisyArrowGeometry.points)"
        )
    }

    static func testSmartDrawRecognitionBudget() async throws {
        try expect(
            SmartDrawRecognitionBudget.shouldRecognizePreview(
                lastRecognitionTime: nil,
                lastRecognizedSampleCount: 0,
                timestamp: 10,
                sampleCount: SmartDrawRecognitionBudget.minimumPointCount
            ),
            "Expected the first viable Smart Draw preview analysis to run"
        )
        try expect(
            !SmartDrawRecognitionBudget.shouldRecognizePreview(
                lastRecognitionTime: 10,
                lastRecognizedSampleCount: 6,
                timestamp: 10 + SmartDrawRecognitionBudget.minimumPreviewInterval / 2,
                sampleCount: 12
            )
                && SmartDrawRecognitionBudget.shouldRecognizePreview(
                    lastRecognitionTime: 10,
                    lastRecognizedSampleCount: 6,
                    timestamp: 10 + SmartDrawRecognitionBudget.minimumPreviewInterval * 2,
                    sampleCount: 14
                )
                && !SmartDrawRecognitionBudget.shouldRecognizePreview(
                    lastRecognitionTime: 10,
                    lastRecognizedSampleCount: 12,
                    timestamp: 11,
                    sampleCount: 12
                ),
            "Expected drag recognition to be throttled by deterministic timestamps "
                + "and new-sample progress"
        )
        try expect(
            SmartDrawRecognitionBudget.minimumPreviewInterval >= 1.0 / 30.0
                && SmartDrawRecognitionBudget.minimumPreviewInterval <= 1.0 / 20.0
                && SmartDrawRecognitionBudget.minimumPointCount <= 5
                && SmartDrawRecognitionBudget.minimumAdditionalPointCount == 4,
            "Expected an early bounded 20-30 Hz Smart Draw preview cadence"
        )

        let denseCircle = noisyEllipsePoints(
            center: CGPoint(x: 160, y: 140),
            radiusX: 90,
            radiusY: 88,
            rotation: 0.08,
            count: 12_000
        )
        let prepared = SmartDrawRecognizer.preparedPointsForTesting(
            denseCircle,
            zoomScale: 1
        )
        try expect(
            prepared.count <= SmartDrawRecognitionBudget.maximumInputPointCount
                && prepared.first == denseCircle.first
                && prepared.last == denseCircle.last,
            "Expected Smart Draw input to be deterministically resampled before "
                + "higher-cost recognition passes"
        )
        let controllerPrepared = AnnotationController.boundedSmartDrawLocations(
            from: denseCircle.map {
                AnnotationPointSample(location: $0, pressure: nil)
            },
            maximumCount: SmartDrawRecognitionBudget.previewInputPointCount
        )
        try expect(
            controllerPrepared.count
                == SmartDrawRecognitionBudget.previewInputPointCount
                && controllerPrepared.first == denseCircle.first
                && controllerPrepared.last == denseCircle.last,
            "Expected controller-side Smart Draw preparation to cap each recognition frame before scanning"
        )
        let denseCandidate = SmartDrawRecognizer.recognize(
            points: denseCircle,
            duration: 1,
            zoomScale: 1
        )
        let preparedCandidate = SmartDrawRecognizer.recognize(
            points: prepared,
            duration: 1,
            zoomScale: 1
        )
        try expect(
            denseCandidate == preparedCandidate && denseCandidate != nil,
            "Expected bounded Smart Draw input to preserve deterministic recognition output"
        )

        let queueController = AnnotationController()
        queueController.setSmartDrawEnabled(true)
        let queuePoints = noisyEllipsePoints(
            center: CGPoint(x: 120, y: 100),
            radiusX: 60,
            radiusY: 58,
            rotation: 0.05,
            count: 80
        )
        queueController.begin(
            at: queuePoints[0],
            pressure: 0.9,
            timestamp: 20,
            zoomScale: 1
        )
        for (index, point) in queuePoints.dropFirst().enumerated() {
            queueController.update(
                at: point,
                pressure: 0.9,
                timestamp: 20 + Double(index + 1) * 0.04,
                zoomScale: 1
            )
        }
        try expect(
            queueController.smartDrawRecognitionSubmissionCountForTesting == 1
                && queueController.hasPendingSmartDrawRecognitionForTesting
                && queueController
                    .smartDrawMaximumConcurrentRecognitionCountForTesting == 1,
            "Expected one in-flight recognition with one replaceable latest pending snapshot"
        )
        for _ in 0..<500
            where queueController.hasPendingSmartDrawRecognitionForTesting {
            await Task.yield()
            try await Task.sleep(for: .milliseconds(1))
        }
        try expect(
            !queueController.hasPendingSmartDrawRecognitionForTesting
                && queueController.smartDrawRecognitionSubmissionCountForTesting == 2
                && queueController
                    .smartDrawMaximumConcurrentRecognitionCountForTesting == 1
                && queueController.smartDrawRejectedRecognitionCountForTesting == 0,
            "Expected the in-flight result to deliver before the latest pending snapshot"
        )
        queueController.clear()
    }

    static func testSmartDrawPreviewStabilityAndHistory() throws {
        let geometry = AnnotationElementGeometry.shape(
            AnnotationShapeGeometry(
                kind: .ellipse,
                start: CGPoint(x: 0, y: 0),
                end: CGPoint(x: 100, y: 100)
            )
        )
        let circle = SmartDrawCandidate(
            kind: .circle,
            geometry: geometry,
            rotation: 0,
            confidence: SmartDrawStabilityTracker.previewThreshold + 0.01
        )
        let ellipse = SmartDrawCandidate(
            kind: .ellipse,
            geometry: geometry,
            rotation: 0,
            confidence: SmartDrawStabilityTracker.previewThreshold + 0.02
        )
        var immediateTracker = SmartDrawStabilityTracker()
        immediateTracker.update(
            SmartDrawCandidate(
                kind: .circle,
                geometry: geometry,
                rotation: 0,
                confidence: SmartDrawStabilityTracker.immediatePreviewThreshold
            )
        )
        try expect(
            immediateTracker.previewCandidate?.kind == .circle,
            "Expected a high-confidence candidate to preview on its first useful update"
        )
        var tracker = SmartDrawStabilityTracker()
        tracker.update(circle)
        try expect(
            tracker.previewCandidate == nil
                && tracker.displayCandidate?.kind == .circle,
            "Expected a faint provisional candidate before stable preview confirmation"
        )
        tracker.update(circle)
        try expect(
            tracker.previewCandidate?.kind == .circle,
            "Expected a stable candidate to appear at the preview threshold"
        )
        let shiftedCircle = SmartDrawCandidate(
            kind: .circle,
            geometry: .shape(
                AnnotationShapeGeometry(
                    kind: .ellipse,
                    start: CGPoint(x: 40, y: 20),
                    end: CGPoint(x: 140, y: 120)
                )
            ),
            rotation: 0,
            confidence: SmartDrawStabilityTracker.immediatePreviewThreshold
        )
        tracker.update(shiftedCircle)
        guard case .shape(let smoothedPreviewGeometry) =
            tracker.previewCandidate?.geometry else {
            throw SelfTestError.failure("Expected a smoothed Smart Draw preview geometry")
        }
        try expect(
            smoothedPreviewGeometry.bounds.minX > 0
                && smoothedPreviewGeometry.bounds.minX < 40
                && smoothedPreviewGeometry.bounds.minY > 0
                && smoothedPreviewGeometry.bounds.minY < 20,
            "Expected same-class preview geometry to move smoothly instead of jumping"
        )
        tracker.update(ellipse)
        try expect(
            tracker.previewCandidate?.kind == .circle,
            "Expected one competing update not to flicker the preview class"
        )
        let belowCommit = SmartDrawCandidate(
            kind: .circle,
            geometry: geometry,
            rotation: 0,
            confidence: SmartDrawStabilityTracker.mediumConfidenceCommitThreshold - 0.01
        )
        try expect(
            tracker.commitCandidate(final: belowCommit) == nil,
            "Expected commit to reject candidates below the medium-confidence floor"
        )
        let mediumConfidenceFinal = SmartDrawCandidate(
            kind: .circle,
            geometry: geometry,
            rotation: 0,
            confidence: SmartDrawStabilityTracker.mediumConfidenceCommitThreshold
        )
        try expect(
            tracker.commitCandidate(final: mediumConfidenceFinal)?.kind == .circle,
            "Expected a medium-confidence final fit to commit after a stable same-class preview"
        )
        let highConfidenceFinal = SmartDrawCandidate(
            kind: .circle,
            geometry: geometry,
            rotation: 0,
            confidence: SmartDrawStabilityTracker.highConfidenceCommitThreshold
        )
        let finalOnlyTracker = SmartDrawStabilityTracker()
        try expect(
            finalOnlyTracker.commitCandidate(final: highConfidenceFinal)?.kind == .circle,
            "Expected a throttled stroke to commit from its deterministic final analysis "
                + "even if no preview interval elapsed"
        )

        let controller = AnnotationController()
        controller.setSmartDrawEnabled(true)
        controller.currentStyle.pressureEnabled = true
        controller.currentStyle.sloppiness = .cartoonist
        let points = noisyEllipsePoints(
            center: CGPoint(x: 110, y: 95),
            radiusX: 55,
            radiusY: 54,
            rotation: 0,
            count: 64
        )
        controller.begin(
            at: points[0],
            pressure: 0.25,
            timestamp: 10,
            zoomScale: 2
        )
        try expect(
            controller.smartDrawStatusText == "Analyzing stroke...",
            "Expected optional inspector feedback while Smart Draw is evaluating a stroke"
        )
        for (index, point) in points.dropFirst().enumerated() {
            controller.update(
                at: point,
                pressure: 0.25 + CGFloat(index) / 100,
                timestamp: 10 + Double(index + 1) * 0.01,
                zoomScale: 2
            )
        }
        controller.update(
            at: points[0],
            pressure: 0.9,
            timestamp: 10.7,
            zoomScale: 2
        )
        try expect(
            controller.smartDrawRecognitionSubmissionCountForTesting > 0
                && controller.elementSnapshot.isEmpty,
            "Expected preview recognition to run off-main while remaining absent from scene history"
        )
        try expect(
            controller.smartDrawStatusText == "Analyzing stroke..."
                || controller.smartDrawStatusText?.hasPrefix("Circle · ") == true,
            "Expected inspector feedback while asynchronous preview recognition is pending or ready"
        )
        controller.end(
            at: points[0],
            pressure: 1,
            timestamp: 10.72,
            zoomScale: 2
        )
        try expect(
            controller.elementSnapshot.count == 1
                && controller.elementSnapshot[0].style.sloppiness == .cartoonist
                && controller.elementSnapshot[0].metadata.wasSmartDrawRecognized,
            "Expected one committed smart-draw element with the current sloppiness"
        )
        guard case .shape(let committedShape) = controller.elementSnapshot[0].geometry else {
            throw SelfTestError.failure("Expected the raw pen stroke to be replaced by a typed shape")
        }
        try expect(
            committedShape.kind == .ellipse,
            "Expected smart circle geometry to use the native ellipse shape family"
        )
        controller.currentTool = .select
        let selectionPoint = CGPoint(
            x: committedShape.bounds.minX,
            y: committedShape.bounds.midY
        )
        _ = controller.beginSelectionInteraction(
            at: selectionPoint,
            zoomScale: 1,
            modifiers: [],
            clickCount: 1
        )
        controller.endSelectionInteraction(at: selectionPoint, modifiers: [])
        let recognizedState = DrawingToolbarState(annotationController: controller)
        try expect(
            recognizedState.smartDrawStatusText == nil
                && !recognizedState.supportsSmartDraw
                && recognizedState.visibleInspectorSections == [
                    .strokeColor,
                    .background,
                    .strokeWidth,
                    .strokeStyle,
                    .sloppiness,
                    .opacity,
                    .layers
                ],
            "Expected a selected Smart Draw result to use only its recognized shape matrix"
        )
        controller.undo()
        try expect(
            controller.elementSnapshot.isEmpty,
            "Expected recognized replacement to undo in one history step"
        )

        let previewParityController = AnnotationController()
        previewParityController.setSmartDrawEnabled(true)
        let previewParityPoints = noisyPolygonPoints(
            corners: rotatedRectangleCorners(
                center: CGPoint(x: 180, y: 140),
                width: 164,
                height: 76,
                rotation: 0.27
            ),
            samplesPerEdge: 16
        )
        previewParityController.begin(
            at: previewParityPoints[0],
            pressure: nil,
            timestamp: 40,
            zoomScale: 1
        )
        for (index, point) in previewParityPoints.dropFirst().enumerated() {
            previewParityController.update(
                at: point,
                timestamp: 40 + Double(index + 1) * 0.02,
                zoomScale: 1
            )
        }
        previewParityController.end(
            at: previewParityPoints[previewParityPoints.count - 1],
            timestamp: 41.5,
            zoomScale: 1
        )
        guard let alignedCommit = previewParityController.elementSnapshot.first,
              case .shape(let alignedCommitShape) = alignedCommit.geometry else {
            throw SelfTestError.failure("Expected the Smart Draw rectangle ghost to commit")
        }
        try expect(
            alignedCommitShape.kind == .rectangle
                && alignedCommit.metadata.rotation == 0,
            "Expected final Smart Draw geometry to preserve the aligned rectangle contract"
        )

        let fallback = AnnotationController()
        fallback.setSmartDrawEnabled(true)
        fallback.currentStyle.pressureEnabled = true
        fallback.begin(at: CGPoint(x: 10, y: 10), pressure: 0.2, timestamp: 20)
        fallback.update(at: CGPoint(x: 35, y: 24), pressure: 0.5, timestamp: 20.1)
        fallback.update(at: CGPoint(x: 62, y: 12), pressure: 0.8, timestamp: 20.2)
        fallback.end(at: CGPoint(x: 85, y: 28), pressure: 1, timestamp: 20.3)
        guard case .freehand(let fallbackStroke) = fallback.elementSnapshot.first?.geometry else {
            throw SelfTestError.failure("Expected an ambiguous gesture to keep the pen stroke")
        }
        let fallbackPressures = fallbackStroke.samples.compactMap(\.pressure)
        try expect(
            fallbackPressures.isEmpty
                && fallbackStroke.samples.count > 4,
            "Expected Smart Draw fallback ink to remain fixed-pressure"
        )
        fallback.setSmartDrawEnabled(false)
        try expect(
            fallback.currentStyle.pressureMode == .tablet,
            "Expected Smart Draw fallback to restore the saved Pen pressure mode"
        )

        let finalOnlyController = AnnotationController()
        finalOnlyController.setSmartDrawEnabled(true)
        let finalOnlyPoints = noisyEllipsePoints(
            center: CGPoint(x: 150, y: 130),
            radiusX: 66,
            radiusY: 64,
            rotation: 0,
            count: 48
        )
        finalOnlyController.begin(
            at: finalOnlyPoints[0],
            pressure: nil,
            timestamp: 30,
            zoomScale: 1
        )
        for point in finalOnlyPoints.dropFirst().dropLast() {
            finalOnlyController.update(
                at: point,
                timestamp: 30,
                zoomScale: 1
            )
        }
        try expect(
            finalOnlyController.smartDrawPreviewElementSnapshot == nil,
            "Expected preview throttling to be independent from final recognition"
        )
        finalOnlyController.end(
            at: finalOnlyPoints[finalOnlyPoints.count - 1],
            timestamp: 30,
            zoomScale: 1
        )
        guard case .shape = finalOnlyController.elementSnapshot.first?.geometry else {
            throw SelfTestError.failure(
                "Expected pointer release to run a full-quality fit even without a preview"
            )
        }
    }
}
