import AppKit

extension SelfTestRunner {
    static func testFreehandAnnotationLifecycle() throws {
        let controller = AnnotationController()

        controller.begin(at: CGPoint(x: 1, y: 2))
        controller.update(at: CGPoint(x: 3, y: 4))
        controller.update(at: CGPoint(x: 5, y: 6))
        controller.end(at: CGPoint(x: 7, y: 8))

        try expect(controller.elementSnapshot.count == 1, "Expected one freehand annotation")
        guard case .freehand(let freehand) = controller.elementSnapshot[0].geometry else {
            throw SelfTestError.failure("Expected freehand geometry")
        }
        try expect(!freehand.isHighlighter, "Expected freehand tool to be pen")
        let points = freehand.samples.map(\.location)
        try expect(
            points.first == CGPoint(x: 1, y: 2)
                && points.last == CGPoint(x: 7, y: 8)
                && points.count >= 4
                && zip(points, points.dropFirst()).allSatisfy {
                    hypot($1.x - $0.x, $1.y - $0.y)
                        <= AnnotationFreehandInputResampler.screenSpacing + 0.01
                },
            "Expected uniformly resampled freehand points with an immediate trailing endpoint"
        )
    }

    static func testFixedStrokeVariablePressureConversion() throws {
        let controller = AnnotationController()
        controller.currentStyle.sloppiness = .architect
        controller.currentStyle.smoothingEnabled = false
        controller.currentStyle.strokeWidth = 14
        controller.currentStyle.pressureMode = .fixed
        controller.begin(
            at: CGPoint(x: 12, y: 40),
            tool: .pen,
            timestamp: 0,
            zoomScale: 1
        )
        controller.update(
            at: CGPoint(x: 24, y: 40),
            timestamp: 0.2,
            zoomScale: 1
        )
        controller.update(
            at: CGPoint(x: 96, y: 40),
            timestamp: 0.24,
            zoomScale: 1
        )
        controller.end(
            at: CGPoint(x: 116, y: 40),
            timestamp: 0.5,
            zoomScale: 1
        )
        controller.currentTool = .select
        controller.selectAll()

        guard let fixedElement = controller.selectedElementSnapshot.first,
              case .freehand(let fixedFreehand) = fixedElement.geometry else {
            throw SelfTestError.failure("Expected a selected fixed freehand stroke")
        }
        try expect(
            fixedElement.style.pressureMode == .fixed
                && fixedFreehand.samples.allSatisfy {
                    $0.pressure == nil && $0.timestamp != nil
                },
            "Expected fixed strokes to retain timing metadata without claiming pressure"
        )
        let renderer = AnnotationRenderer()
        let fixedPixels = try renderPixels(
            elements: [fixedElement],
            renderer: renderer,
            width: 128,
            height: 80
        )

        controller.setPressureMode(.simulated)
        guard let variableElement = controller.selectedElementSnapshot.first,
              case .freehand(let variableFreehand) = variableElement.geometry else {
            throw SelfTestError.failure("Expected a selected variable freehand stroke")
        }
        let variablePressures = variableFreehand.samples.compactMap(\.pressure)
        let variablePixels = try renderPixels(
            elements: [variableElement],
            renderer: renderer,
            width: 128,
            height: 80
        )
        let variableSpans = stride(from: 16, through: 112, by: 4).map {
            paintedVerticalSpan(
                variablePixels,
                width: 128,
                height: 80,
                x: $0
            )
        }
        try expect(
            variableElement.style.pressureMode == .simulated
                && DrawingToolbarState(annotationController: controller)
                    .pressureOption == .value(.variable)
                && variablePressures.count == variableFreehand.samples.count
                && (variablePressures.max() ?? 0)
                    - (variablePressures.min() ?? 0) > 0.15
                && (variableSpans.max() ?? 0) - (variableSpans.min() ?? 0) >= 3
                && pixelDifferenceCount(fixedPixels, variablePixels) > 0,
            "Expected fixed-to-variable conversion to backfill pressure and visibly vary width"
        )

        controller.undo()
        guard let undoneElement = controller.selectedElementSnapshot.first,
              case .freehand(let undoneFreehand) = undoneElement.geometry else {
            throw SelfTestError.failure("Expected undo to restore the fixed stroke")
        }
        let undonePixels = try renderPixels(
            elements: [undoneElement],
            renderer: renderer,
            width: 128,
            height: 80
        )
        try expect(
            undoneElement.style.pressureMode == .fixed
                && undoneFreehand.samples == fixedFreehand.samples
                && DrawingToolbarState(annotationController: controller)
                    .pressureOption == .value(.constant)
                && undonePixels == fixedPixels,
            "Expected one undo to restore pressure metadata, rendering, and inspector state"
        )

        controller.redo()
        guard let redoneElement = controller.selectedElementSnapshot.first,
              case .freehand(let redoneFreehand) = redoneElement.geometry else {
            throw SelfTestError.failure("Expected redo to restore the variable stroke")
        }
        try expect(
            redoneElement.style.pressureMode == .simulated
                && redoneFreehand.samples == variableFreehand.samples
                && DrawingToolbarState(annotationController: controller)
                    .pressureOption == .value(.variable),
            "Expected one redo to restore pressure samples and inspector state"
        )

        let highlighterController = AnnotationController()
        highlighterController.currentTool = .highlighter
        highlighterController.currentStyle.pressureMode = .fixed
        highlighterController.begin(
            at: CGPoint(x: 10, y: 20),
            tool: .highlighter,
            timestamp: 0,
            zoomScale: 1
        )
        highlighterController.update(
            at: CGPoint(x: 50, y: 20),
            timestamp: 0.08,
            zoomScale: 1
        )
        highlighterController.end(
            at: CGPoint(x: 100, y: 20),
            timestamp: 0.2,
            zoomScale: 1
        )
        highlighterController.currentTool = .select
        highlighterController.selectAll()
        highlighterController.setPressureMode(.tablet)
        guard let highlighter = highlighterController.selectedElementSnapshot.first,
              case .freehand(let highlighterFreehand) = highlighter.geometry else {
            throw SelfTestError.failure("Expected a selected highlighter stroke")
        }
        try expect(
            highlighter.style.pressureMode == .fixed
                && highlighterFreehand.samples.allSatisfy { $0.pressure == nil }
                && DrawingToolbarState(annotationController: highlighterController)
                    .pressureOption == .value(.constant)
                && !DrawingToolbarState(annotationController: highlighterController)
                    .visibleInspectorSections.contains(.pressure),
            "Expected Highlighter selection to reject hidden variable-pressure mutations"
        )

        let legacySamples = [
            AnnotationPointSample(
                location: CGPoint(x: 12, y: 34),
                pressure: nil
            ),
            AnnotationPointSample(
                location: CGPoint(x: 36, y: 34),
                pressure: nil
            ),
            AnnotationPointSample(
                location: CGPoint(x: 68, y: 34),
                pressure: nil
            ),
            AnnotationPointSample(
                location: CGPoint(x: 116, y: 34),
                pressure: nil
            )
        ]
        let firstLegacyBackfill = AnnotationPressureBackfill.simulatedSamples(
            from: legacySamples
        )
        let repeatedLegacyBackfill = AnnotationPressureBackfill.simulatedSamples(
            from: legacySamples
        )
        let legacyPressures = firstLegacyBackfill.compactMap(\.pressure)
        try expect(
            firstLegacyBackfill == repeatedLegacyBackfill
                && firstLegacyBackfill.allSatisfy { $0.timestamp == nil }
                && legacyPressures.count == legacySamples.count
                && (legacyPressures.max() ?? 0)
                    - (legacyPressures.min() ?? 0) > 0.15,
            "Expected timestamp-less legacy strokes to use a stable distance profile"
        )

        var legacyStyle = AnnotationStyle(
            color: .blue,
            rootWidth: 14,
            alpha: 1
        )
        legacyStyle.sloppiness = .architect
        legacyStyle.smoothingEnabled = false
        legacyStyle.pressureMode = .fixed
        let legacyID = AnnotationElementID()
        let fixedLegacyElement = AnnotationElement(
            id: legacyID,
            geometry: .freehand(
                AnnotationFreehandGeometry(
                    samples: legacySamples,
                    isHighlighter: false
                )
            ),
            style: legacyStyle
        )
        legacyStyle.pressureMode = .simulated
        let variableLegacyElement = AnnotationElement(
            id: legacyID,
            geometry: .freehand(
                AnnotationFreehandGeometry(
                    samples: firstLegacyBackfill,
                    isHighlighter: false
                )
            ),
            style: legacyStyle
        )
        let fixedLegacyPixels = try renderPixels(
            elements: [fixedLegacyElement],
            renderer: renderer,
            width: 128,
            height: 72
        )
        let variableLegacyPixels = try renderPixels(
            elements: [variableLegacyElement],
            renderer: renderer,
            width: 128,
            height: 72
        )
        try expect(
            pixelDifferenceCount(fixedLegacyPixels, variableLegacyPixels) > 0
                && paintedVerticalSpan(
                    variableLegacyPixels,
                    width: 128,
                    height: 72,
                    x: 68
                ) > paintedVerticalSpan(
                    variableLegacyPixels,
                    width: 128,
                    height: 72,
                    x: 12
                ),
            "Expected the legacy fallback profile to produce visible variable width"
        )
    }

    static func testFreehandSmoothingAndPressureSampling() throws {
        let raw = [
            AnnotationPointSample(location: CGPoint(x: 5, y: 5), pressure: 0.2),
            AnnotationPointSample(location: CGPoint(x: 20, y: 15), pressure: 0.5),
            AnnotationPointSample(location: CGPoint(x: 35, y: 5), pressure: 1)
        ]
        let smoothed = AnnotationGeometry.smoothedFreehandSamples(raw, subdivisions: 4)
        try expect(smoothed.first == raw.first, "Expected smoothing to preserve the first sample")
        try expect(smoothed.last == raw.last, "Expected smoothing to preserve the final sample")
        try expect(smoothed.count == 9, "Expected deterministic smoothing subdivisions")
        try expect(
            smoothed.allSatisfy { $0.pressure == nil || (0...1).contains($0.pressure!) },
            "Expected smoothing to interpolate normalized pressure"
        )

        let currentInput = AnnotationRawFreehandInput(
            location: CGPoint(x: 36, y: 8),
            pressure: 0.9,
            timestamp: 0.03
        )
        let orderedInputs = ZoomCanvasView.orderedUniqueFreehandInputs(
            coalesced: [
                AnnotationRawFreehandInput(
                    location: CGPoint(x: 12, y: 2),
                    pressure: 0.3,
                    timestamp: 0.01
                ),
                AnnotationRawFreehandInput(
                    location: CGPoint(x: 24, y: 4),
                    pressure: 0.6,
                    timestamp: 0.02
                ),
                AnnotationRawFreehandInput(
                    location: currentInput.location,
                    pressure: 0.7,
                    timestamp: currentInput.timestamp
                )
            ],
            current: currentInput
        )
        try expect(
            orderedInputs.map(\.timestamp) == [0.01, 0.02, 0.03]
                && orderedInputs.map(\.location) == [
                    CGPoint(x: 12, y: 2),
                    CGPoint(x: 24, y: 4),
                    CGPoint(x: 36, y: 8)
                ]
                && orderedInputs.last?.pressure == 0.9,
            "Expected ordered freehand input to avoid sorting, deduplicate the current event, and preserve pressure"
        )

        let batchedController = AnnotationController()
        batchedController.currentStyle.pressureMode = .tablet
        batchedController.begin(
            at: .zero,
            pressure: 0.1,
            timestamp: 0,
            zoomScale: 1
        )
        batchedController.updateFreehand(inputs: orderedInputs, zoomScale: 1)
        guard let batchedElement = batchedController.inProgressElementSnapshot,
              case .freehand(let batchedFreehand) = batchedElement.geometry else {
            throw SelfTestError.failure("Expected batched coalesced freehand geometry")
        }
        try expect(
            orderedInputs.allSatisfy { input in
                batchedFreehand.samples.contains {
                    $0.location == input.location
                        && $0.timestamp == input.timestamp
                        && $0.pressure == input.pressure
                }
            },
            "Expected one batched freehand update to preserve each coalesced location, timestamp, and pressure"
        )

        let mouseController = AnnotationController()
        mouseController.currentStyle.pressureMode = .tablet
        mouseController.begin(at: CGPoint(x: 1, y: 1))
        mouseController.update(at: CGPoint(x: 2, y: 2))
        mouseController.end(at: CGPoint(x: 3, y: 3))
        guard case .freehand(let mouseStroke) = mouseController.elementSnapshot.first?.geometry else {
            throw SelfTestError.failure("Expected a mouse freehand element")
        }
        try expect(
            mouseStroke.samples.allSatisfy { $0.pressure == nil },
            "Expected mouse-only strokes to retain deterministic constant-width samples"
        )

        let pressureController = AnnotationController()
        pressureController.currentStyle.pressureMode = .tablet
        pressureController.begin(at: CGPoint(x: 1, y: 1), pressure: 0.2)
        pressureController.update(at: CGPoint(x: 2, y: 2), pressure: 0.6)
        pressureController.end(at: CGPoint(x: 3, y: 3), pressure: 1.4)
        guard case .freehand(let pressureStroke) = pressureController.elementSnapshot.first?.geometry else {
            throw SelfTestError.failure("Expected a pressure-aware freehand element")
        }
        let tabletPressures = pressureStroke.samples.compactMap(\.pressure)
        try expect(
            tabletPressures.first == 0.2
                && tabletPressures.last == 1
                && tabletPressures.allSatisfy { (0...1).contains($0) }
                && zip(
                    pressureStroke.samples,
                    pressureStroke.samples.dropFirst()
                ).allSatisfy {
                    hypot(
                        $1.location.x - $0.location.x,
                        $1.location.y - $0.location.y
                    ) <= AnnotationFreehandInputResampler.screenSpacing + 0.01
                },
            "Expected tablet pressure to remain clamped while centerline samples are resampled"
        )

        var slowTracker = AnnotationSimulatedPressureTracker()
        _ = slowTracker.begin(at: .zero, timestamp: 0)
        let slowPressure = slowTracker.sample(
            at: CGPoint(x: 2, y: 0),
            timestamp: 0.1,
            zoomScale: 1
        )
        var fastTracker = AnnotationSimulatedPressureTracker()
        _ = fastTracker.begin(at: .zero, timestamp: 0)
        let fastPressure = fastTracker.sample(
            at: CGPoint(x: 120, y: 0),
            timestamp: 0.1,
            zoomScale: 1
        )
        try expect(
            slowPressure > fastPressure
                && (AnnotationSimulatedPressureTracker.minimumPressure...1)
                    .contains(slowPressure)
                && (AnnotationSimulatedPressureTracker.minimumPressure...1)
                    .contains(fastPressure),
            "Expected slower mouse movement to produce thicker deterministic simulated pressure"
        )
        var seededTracker = AnnotationSimulatedPressureTracker()
        _ = seededTracker.begin(at: .zero, timestamp: 0)
        _ = seededTracker.resampledSamples(
            at: CGPoint(x: 10, y: 0),
            timestamp: 0.1,
            zoomScale: 1
        )
        try expect(
            abs((seededTracker.filteredSpeed ?? 0) - 100) < 0.001
                && abs(
                    (seededTracker.smoothedPressure ?? 0)
                        - AnnotationSimulatedPressureTracker.pressure(forSpeed: 100)
                ) < 0.001,
            "Expected the first measured segment to seed speed and pressure filters"
        )
        var hugeGapTracker = AnnotationSimulatedPressureTracker()
        _ = hugeGapTracker.begin(at: .zero, timestamp: 0)
        let hugeGapPressureSamples = hugeGapTracker.resampledSamples(
            at: CGPoint(x: 1_000, y: 0),
            timestamp: 0.1,
            zoomScale: 2
        )
        let hugeGapLocations = [CGPoint.zero]
            + hugeGapPressureSamples.map(\.location)
        try expect(
            hugeGapPressureSamples.count
                == AnnotationSimulatedPressureTracker.maximumSamplesPerEvent
                && hugeGapPressureSamples.last?.location
                    == CGPoint(x: 1_000, y: 0)
                && zip(
                    hugeGapLocations,
                    hugeGapLocations.dropFirst()
                ).allSatisfy {
                    $1.x > $0.x
                }
                && zip(
                    hugeGapPressureSamples.compactMap(\.timestamp),
                    hugeGapPressureSamples.compactMap(\.timestamp).dropFirst()
                ).allSatisfy { $0 <= $1 },
            "Expected simulated pressure to adaptively cover huge gaps within its per-event work cap"
        )
        let calibrationSpeeds: [CGFloat] = [
            40, 50, 100, 150, 300, 500, 700, 1_000, 1_500, 1_800
        ]
        let expectedCalibration: [CGFloat] = [
            0.98, 0.979, 0.971, 0.958, 0.898, 0.796, 0.684, 0.524, 0.336, 0.3
        ]
        let speedResponse = calibrationSpeeds.map(
            AnnotationSimulatedPressureTracker.pressure
        )
        try expect(
            zip(speedResponse, expectedCalibration).allSatisfy {
                abs($0 - $1) <= 0.01
            }
                && zip(speedResponse, speedResponse.dropFirst()).allSatisfy {
                    $0 > $1
                },
            "Expected the calibrated velocity-pressure response within ±0.01 "
                + "(actual \(speedResponse))"
        )

        func trackedPressures(
            _ events: [(CGPoint, TimeInterval)],
            zoomScale: CGFloat = 1
        ) -> [CGFloat] {
            var tracker = AnnotationSimulatedPressureTracker()
            var result = [tracker.begin(at: .zero, timestamp: 0)]
            for (point, timestamp) in events {
                result.append(
                    contentsOf: tracker.resampledSamples(
                        at: point,
                        timestamp: timestamp,
                        zoomScale: zoomScale
                    ).compactMap(\.pressure)
                )
            }
            return result
        }

        let uniformTiming = trackedPressures(
            stride(from: 1, through: 10, by: 1).map {
                (CGPoint(x: CGFloat($0) * 6, y: 0), Double($0) * 0.02)
            }
        )
        let irregularTiming = trackedPressures([
            (CGPoint(x: 3, y: 0), 0.01),
            (CGPoint(x: 18, y: 0), 0.06),
            (CGPoint(x: 24, y: 0), 0.08),
            (CGPoint(x: 48, y: 0), 0.16),
            (CGPoint(x: 60, y: 0), 0.20)
        ])
        try expect(
            abs((uniformTiming.last ?? 0) - (irregularTiming.last ?? 0)) < 0.035,
            "Expected distance/time resampling to stabilize irregular mouse event timing"
        )

        func finalBatchedSimulatedPressure(
            _ inputs: [AnnotationRawFreehandInput]
        ) throws -> CGFloat {
            let controller = AnnotationController()
            controller.currentStyle.pressureMode = .simulated
            controller.begin(
                at: .zero,
                pressure: nil,
                timestamp: 0,
                zoomScale: 1
            )
            controller.updateFreehand(inputs: inputs, zoomScale: 1)
            guard let element = controller.inProgressElementSnapshot,
                  case .freehand(let freehand) = element.geometry,
                  let pressure = freehand.samples.last?.pressure else {
                throw SelfTestError.failure(
                    "Expected batched simulated-pressure geometry"
                )
            }
            return pressure
        }
        let densePressure = try finalBatchedSimulatedPressure(
            (1...20).map { index in
                AnnotationRawFreehandInput(
                    location: CGPoint(x: CGFloat(index) * 5, y: 0),
                    pressure: nil,
                    timestamp: Double(index) * 0.005
                )
            }
        )
        let sparsePressure = try finalBatchedSimulatedPressure([
            AnnotationRawFreehandInput(
                location: CGPoint(x: 50, y: 0),
                pressure: nil,
                timestamp: 0.05
            ),
            AnnotationRawFreehandInput(
                location: CGPoint(x: 100, y: 0),
                pressure: nil,
                timestamp: 0.1
            )
        ])
        try expect(
            abs(densePressure - sparsePressure) <= 0.045,
            "Expected dense and sparse samples with equal timestamped velocity to resolve comparable pressure "
                + "(dense \(densePressure), sparse \(sparsePressure))"
        )

        let zoomOne = trackedPressures([
            (CGPoint(x: 12, y: 0), 0.04),
            (CGPoint(x: 24, y: 0), 0.08),
            (CGPoint(x: 36, y: 0), 0.12)
        ])
        let zoomTwo = trackedPressures(
            [
                (CGPoint(x: 6, y: 0), 0.04),
                (CGPoint(x: 12, y: 0), 0.08),
                (CGPoint(x: 18, y: 0), 0.12)
            ],
            zoomScale: 2
        )
        try expect(
            zoomOne == zoomTwo,
            "Expected equivalent screen-space motion to produce equal pressure across zoom levels"
        )

        let interpolatedPressure = AnnotationGeometry.pressureInterpolatedFreehandSamples(
            [
                AnnotationPointSample(location: .zero, pressure: 0.2),
                AnnotationPointSample(location: CGPoint(x: 24, y: 0), pressure: 1)
            ]
        )
        try expect(
            interpolatedPressure.count > 2
                && zip(interpolatedPressure, interpolatedPressure.dropFirst()).allSatisfy {
                    pair in
                    let pressureDelta = abs(
                        (pair.1.pressure ?? 1) - (pair.0.pressure ?? 1)
                    )
                    let distance = hypot(
                        pair.1.location.x - pair.0.location.x,
                        pair.1.location.y - pair.0.location.y
                    )
                    return pressureDelta <= 0.061 && distance <= 4.001
                },
            "Expected rendering interpolation to avoid abrupt per-segment width jumps"
        )

        var taperSamples = [
            AnnotationPointSample(location: CGPoint(x: 0, y: 0), pressure: 0.8),
            AnnotationPointSample(location: CGPoint(x: 12, y: 0), pressure: 0.8),
            AnnotationPointSample(location: CGPoint(x: 24, y: 0), pressure: 0.8)
        ]
        AnnotationSimulatedPressureTracker.applyEndTaper(
            to: &taperSamples,
            zoomScale: 1
        )
        let taperPressures = taperSamples.compactMap(\.pressure)
        try expect(
            abs((taperPressures.first ?? 0) - 0.8) < 0.001
                && abs(taperPressures[1] - 0.52) < 0.001
                && abs((taperPressures.last ?? 0) - 0.3) < 0.001,
            "Expected the final taper to preserve the readable pressure floor"
        )

        func simulatedStrokePressures() throws -> [CGFloat?] {
            let controller = AnnotationController()
            controller.currentStyle.pressureMode = .simulated
            controller.currentStyle.strokeWidth = 12
            controller.begin(
                at: .zero,
                pressure: nil,
                timestamp: 0,
                zoomScale: 1
            )
            controller.update(
                at: CGPoint(x: 2, y: 0),
                timestamp: 0.1,
                zoomScale: 1
            )
            controller.update(
                at: CGPoint(x: 122, y: 0),
                timestamp: 0.2,
                zoomScale: 1
            )
            controller.end(
                at: CGPoint(x: 124, y: 0),
                timestamp: 0.3,
                zoomScale: 1
            )
            guard let element = controller.elementSnapshot.first,
                  case .freehand(let freehand) = element.geometry else {
                throw SelfTestError.failure("Expected simulated-pressure freehand geometry")
            }
            try expect(
                AnnotationGeometry.maximumStrokeWidth(for: element) == 12,
                "Expected simulated pressure to leave canonical hit bounds at root width"
            )
            return freehand.samples.map(\.pressure)
        }
        let firstSimulated = try simulatedStrokePressures()
        let repeatedSimulated = try simulatedStrokePressures()
        let resolvedSimulated = firstSimulated.compactMap { $0 }
        let maximumSimulatedDelta = zip(
            resolvedSimulated,
            resolvedSimulated.dropFirst()
        ).map { abs($1 - $0) }.max() ?? 0
        try expect(
            firstSimulated == repeatedSimulated
                && resolvedSimulated.count > 12
                && (resolvedSimulated.max() ?? 0) - (resolvedSimulated.min() ?? 0) > 0.15
                && (resolvedSimulated.first ?? 1) < (resolvedSimulated.max() ?? 0)
                && (resolvedSimulated.last ?? 1) < (resolvedSimulated.max() ?? 0),
            "Expected deterministic resampling and calibrated start/end envelopes"
                + " (count \(resolvedSimulated.count), max delta "
                + "\(maximumSimulatedDelta), range "
                + "\((resolvedSimulated.max() ?? 0) - (resolvedSimulated.min() ?? 0)), "
                + "first \(resolvedSimulated.first ?? -1), "
                + "last \(resolvedSimulated.last ?? -1))"
        )

        let outlierPressures = trackedPressures([
            (CGPoint(x: 3, y: 0), 0.02),
            (CGPoint(x: 6, y: 0), 0.04),
            (CGPoint(x: 180, y: 0), 0.041),
            (CGPoint(x: 183, y: 0), 0.08),
            (CGPoint(x: 186, y: 0), 0.12)
        ])
        try expect(
            outlierPressures.allSatisfy {
                (AnnotationSimulatedPressureTracker.minimumPressure...0.98).contains($0)
            }
                && (outlierPressures.min() ?? 1) < (outlierPressures.max() ?? 0),
            "Expected asymmetric speed and pressure filters to keep outlier response bounded"
        )

        func meanTurn(_ points: [CGPoint]) -> CGFloat {
            guard points.count > 2 else { return 0 }
            let turns = (1..<(points.count - 1)).map { index -> CGFloat in
                let first = CGPoint(
                    x: points[index].x - points[index - 1].x,
                    y: points[index].y - points[index - 1].y
                )
                let second = CGPoint(
                    x: points[index + 1].x - points[index].x,
                    y: points[index + 1].y - points[index].y
                )
                let firstLength = hypot(first.x, first.y)
                let secondLength = hypot(second.x, second.y)
                guard firstLength > 0.0001, secondLength > 0.0001 else { return 0 }
                let cosine = min(
                    1,
                    max(
                        -1,
                        (first.x * second.x + first.y * second.y)
                            / (firstLength * secondLength)
                    )
                )
                return acos(cosine)
            }
            return turns.reduce(0, +) / CGFloat(turns.count)
        }

        let jitterEvents = (0...40).map {
            CGPoint(
                x: CGFloat($0) * 1.2,
                y: $0.isMultiple(of: 2) ? 0.7 : -0.7
            )
        }
        var centerlineResampler = AnnotationFreehandInputResampler()
        let initialJitterSample = AnnotationPointSample(
            location: jitterEvents[0],
            pressure: nil
        )
        centerlineResampler.begin(with: initialJitterSample)
        var resampledCenterline = [initialJitterSample]
        for point in jitterEvents.dropFirst() {
            let result = centerlineResampler.append(
                AnnotationPointSample(location: point, pressure: nil),
                zoomScale: 1
            )
            if result.removesTrailingPreview {
                resampledCenterline.removeLast()
            }
            resampledCenterline.append(contentsOf: result.samples)
            try expect(
                resampledCenterline.last?.location == point,
                "Expected active freehand rendering to reach the current pointer without lag"
            )
        }
        let smoothedCenterline = AnnotationGeometry.smoothedFreehandSamples(
            resampledCenterline,
            subdivisions: 4
        )
        try expect(
            zip(resampledCenterline, resampledCenterline.dropFirst()).allSatisfy {
                hypot(
                    $1.location.x - $0.location.x,
                    $1.location.y - $0.location.y
                ) <= AnnotationFreehandInputResampler.screenSpacing + 0.01
            }
                && meanTurn(smoothedCenterline.map(\.location))
                    < meanTurn(jitterEvents) * 0.55,
            "Expected uniform resampling and corner-aware splines to reduce angular jitter"
        )

        var cornerResampler = AnnotationFreehandInputResampler()
        let cornerStart = AnnotationPointSample(location: .zero, pressure: nil)
        cornerResampler.begin(with: cornerStart)
        var cornerSamples = [cornerStart]
        for point in [CGPoint(x: 8, y: 0), CGPoint(x: 8, y: 8)] {
            let result = cornerResampler.append(
                AnnotationPointSample(location: point, pressure: nil),
                zoomScale: 1
            )
            if result.removesTrailingPreview {
                cornerSamples.removeLast()
            }
            cornerSamples.append(contentsOf: result.samples)
        }
        let boundedJump = cornerResampler.append(
            AnnotationPointSample(
                location: CGPoint(x: 10_000, y: 8),
                pressure: nil,
                timestamp: 1
            ),
            zoomScale: 1
        )
        let jumpAnchor = AnnotationPointSample(
            location: CGPoint(x: 8, y: 8),
            pressure: nil,
            timestamp: 0
        )
        let expectedJumpCount = AnnotationFreehandInputResampler.interpolationStepCount(
            from: jumpAnchor,
            to: AnnotationPointSample(
                location: CGPoint(x: 10_000, y: 8),
                pressure: nil,
                timestamp: 1
            ),
            zoomScale: 1
        )
        var jumpBatches = [boundedJump]
        while cornerResampler.hasPendingSamples {
            jumpBatches.append(cornerResampler.drainPending())
        }
        let drainedJumpSamples = jumpBatches.flatMap(\.samples)
        let jumpSamples = [jumpAnchor] + drainedJumpSamples
        try expect(
            cornerSamples.contains { $0.location == CGPoint(x: 8, y: 0) }
                && jumpBatches.allSatisfy {
                    $0.samples.count
                        <= AnnotationFreehandInputResampler.maximumGeneratedSamplesPerDrain
                }
                && drainedJumpSamples.count == expectedJumpCount
                && drainedJumpSamples.last?.location
                    == CGPoint(x: 10_000, y: 8)
                && zip(jumpSamples, jumpSamples.dropFirst()).allSatisfy {
                    $1.location.x > $0.location.x
                }
                && zip(
                    drainedJumpSamples.compactMap(\.timestamp),
                    drainedJumpSamples.compactMap(\.timestamp).dropFirst()
                ).allSatisfy { $0 <= $1 },
            "Expected intentional corners and timestamps to survive multi-frame bounded resampling"
        )
        try expect(
            drainedJumpSamples.first?.timestamp ?? 0 > 0
                && drainedJumpSamples.last?.timestamp == 1,
            "Expected reconstructed samples to interpolate event timestamps through the full segment"
        )

        let renderInterpolationStress =
            AnnotationGeometry.pressureInterpolatedFreehandSamples(
                [
                    AnnotationPointSample(
                        location: .zero,
                        pressure: AnnotationSimulatedPressureTracker.minimumPressure
                    ),
                    AnnotationPointSample(
                        location: CGPoint(x: 100_000, y: 0),
                        pressure: 0.98
                    )
                ]
            )
        try expect(
            renderInterpolationStress.count
                <= AnnotationGeometry.maximumPressureInterpolationStepsPerSegment + 1
                && renderInterpolationStress.last?.location
                    == CGPoint(x: 100_000, y: 0),
            "Expected render interpolation to cap per-segment work without losing the endpoint"
        )

        let highlighterPressureController = AnnotationController()
        highlighterPressureController.currentTool = .highlighter
        highlighterPressureController.currentStyle.pressureMode = .simulated
        highlighterPressureController.begin(
            at: .zero,
            tool: .highlighter,
            timestamp: 0,
            zoomScale: 1
        )
        highlighterPressureController.update(
            at: CGPoint(x: 100, y: 0),
            timestamp: 0.1,
            zoomScale: 1
        )
        highlighterPressureController.end(
            at: CGPoint(x: 200, y: 0),
            timestamp: 0.2,
            zoomScale: 1
        )
        guard case .freehand(let highlighterPressureStroke) =
                highlighterPressureController.elementSnapshot.first?.geometry else {
            throw SelfTestError.failure("Expected simulated-pressure highlighter geometry")
        }
        try expect(
            highlighterPressureController.elementSnapshot[0].style.pressureMode == .fixed
                && highlighterPressureStroke.samples.allSatisfy {
                    $0.pressure == nil
                },
            "Expected Highlighter to stay constant-width and ignore hidden pressure state"
        )

        var zoomAwareResampler = AnnotationFreehandInputResampler()
        let zoomAwareStart = AnnotationPointSample(
            location: .zero,
            pressure: nil,
            timestamp: 0
        )
        zoomAwareResampler.begin(with: zoomAwareStart)
        let zoomAware = zoomAwareResampler.append(
            AnnotationPointSample(
                location: CGPoint(x: 10, y: 0),
                pressure: nil,
                timestamp: 0.01
            ),
            zoomScale: 2
        )
        try expect(
            zoomAware.samples.count == 8
                && zip(
                    [zoomAwareStart] + zoomAware.samples,
                    ([zoomAwareStart] + zoomAware.samples).dropFirst()
                ).allSatisfy {
                    hypot(
                        $1.location.x - $0.location.x,
                        $1.location.y - $0.location.y
                    ) * 2 <= AnnotationFreehandInputResampler.screenSpacing + 0.001
                },
            "Expected freehand spacing to remain constant in destination pixels across zoom"
        )

        let sparseEvents: [(CGPoint, TimeInterval)] = [
            (CGPoint(x: 8, y: 20), 0),
            (CGPoint(x: 82, y: 20), 0.008),
            (CGPoint(x: 136, y: 52), 0.016),
            (CGPoint(x: 82, y: 84), 0.024),
            (CGPoint(x: 8, y: 84), 0.032)
        ]
        let sparseController = AnnotationController()
        sparseController.currentStyle.sloppiness = .architect
        sparseController.currentStyle.smoothingEnabled = true
        sparseController.begin(
            at: sparseEvents[0].0,
            pressure: nil,
            timestamp: sparseEvents[0].1,
            zoomScale: 1
        )
        for event in sparseEvents.dropFirst().dropLast() {
            sparseController.update(
                at: event.0,
                timestamp: event.1,
                zoomScale: 1
            )
        }
        let lastSparseEvent = sparseEvents[sparseEvents.count - 1]
        sparseController.end(
            at: lastSparseEvent.0,
            timestamp: lastSparseEvent.1,
            zoomScale: 1
        )
        guard let sparseElement = sparseController.elementSnapshot.first,
              case .freehand(let sparseFreehand) = sparseElement.geometry else {
            throw SelfTestError.failure("Expected sparse high-speed freehand geometry")
        }
        let sparseLocations = sparseFreehand.samples.map(\.location)
        let sparseTimestamps = sparseFreehand.samples.compactMap(\.timestamp)
        let smoothedSparse = AnnotationGeometry.smoothedFreehandSamples(
            sparseFreehand.samples,
            subdivisions: 3
        )
        let smoothedPath = AnnotationGeometry.smoothedFreehandPath(
            sparseFreehand.samples
        )
        let expectedSparseMaximum = zip(
            sparseEvents,
            sparseEvents.dropFirst()
        ).reduce(1) { count, events in
            count + AnnotationFreehandInputResampler.interpolationStepCount(
                from: AnnotationPointSample(
                    location: events.0.0,
                    pressure: nil,
                    timestamp: events.0.1
                ),
                to: AnnotationPointSample(
                    location: events.1.0,
                    pressure: nil,
                    timestamp: events.1.1
                ),
                zoomScale: 1
            )
        }
        try expect(
            sparseEvents.allSatisfy { event in
                sparseFreehand.samples.contains {
                    $0.location == event.0 && $0.timestamp == event.1
                }
            }
                && sparseLocations.first == sparseEvents.first?.0
                && sparseLocations.last == sparseEvents.last?.0
                && zip(sparseLocations, sparseLocations.dropFirst()).allSatisfy {
                    hypot($1.x - $0.x, $1.y - $0.y)
                        <= AnnotationFreehandInputResampler.screenSpacing + 0.001
                }
                && sparseTimestamps.count == sparseFreehand.samples.count
                && zip(sparseTimestamps, sparseTimestamps.dropFirst()).allSatisfy {
                    $0 <= $1
                }
                && sparseFreehand.samples.count <= expectedSparseMaximum
                && smoothedSparse.allSatisfy {
                    AnnotationGeometry.distance(
                        from: $0.location,
                        toPolyline: sparseLocations
                    ) <= 1
                }
                && AnnotationRoughStroke.pathElementCount(smoothedPath)
                    <= sparseFreehand.samples.count,
            "Expected sparse high-speed events to produce a timestamped, bounded, loop-safe stroke"
        )

        let fastLoopEvents = (0...8).map { index -> (CGPoint, TimeInterval) in
            let angle = CGFloat(index) * 2 * .pi / 8
            return (
                CGPoint(
                    x: 180 + cos(angle) * 54,
                    y: 80 + sin(angle) * 34
                ),
                Double(index) * 0.006
            )
        }
        let loopController = AnnotationController()
        loopController.currentStyle.sloppiness = .architect
        loopController.begin(
            at: fastLoopEvents[0].0,
            pressure: nil,
            timestamp: fastLoopEvents[0].1,
            zoomScale: 1
        )
        for event in fastLoopEvents.dropFirst().dropLast() {
            loopController.update(
                at: event.0,
                timestamp: event.1,
                zoomScale: 1
            )
        }
        let loopEnd = fastLoopEvents[fastLoopEvents.count - 1]
        loopController.end(
            at: loopEnd.0,
            timestamp: loopEnd.1,
            zoomScale: 1
        )
        guard let loopElement = loopController.elementSnapshot.first,
              case .freehand(let loopFreehand) = loopElement.geometry else {
            throw SelfTestError.failure("Expected fast loop freehand geometry")
        }
        let smoothLoop = AnnotationGeometry.smoothedFreehandSamples(
            loopFreehand.samples,
            subdivisions: 3
        ).map(\.location)
        try expect(
            smoothLoop.allSatisfy {
                (124...236).contains($0.x)
                    && (44...116).contains($0.y)
            }
                && zip(smoothLoop, smoothLoop.dropFirst()).allSatisfy {
                    hypot($1.x - $0.x, $1.y - $0.y)
                        <= AnnotationFreehandInputResampler.screenSpacing + 0.5
                },
            "Expected a sparse fast loop to stay inside its local envelope without giant spline loops"
        )

        func properIntersectionCount(_ points: [CGPoint]) -> Int {
            guard points.count > 3 else { return 0 }
            func cross(_ first: CGPoint, _ second: CGPoint) -> CGFloat {
                first.x * second.y - first.y * second.x
            }
            func vector(from start: CGPoint, to end: CGPoint) -> CGPoint {
                CGPoint(x: end.x - start.x, y: end.y - start.y)
            }
            var count = 0
            for firstIndex in 0..<(points.count - 1) {
                let firstStart = points[firstIndex]
                let firstEnd = points[firstIndex + 1]
                guard firstIndex + 2 < points.count - 1 else { continue }
                for secondIndex in (firstIndex + 2)..<(points.count - 1) {
                    let secondStart = points[secondIndex]
                    let secondEnd = points[secondIndex + 1]
                    if firstStart == secondStart
                        || firstStart == secondEnd
                        || firstEnd == secondStart
                        || firstEnd == secondEnd {
                        continue
                    }
                    let firstVector = vector(from: firstStart, to: firstEnd)
                    let secondVector = vector(from: secondStart, to: secondEnd)
                    let firstSide = cross(
                        firstVector,
                        vector(from: firstStart, to: secondStart)
                    )
                    let secondSide = cross(
                        firstVector,
                        vector(from: firstStart, to: secondEnd)
                    )
                    let thirdSide = cross(
                        secondVector,
                        vector(from: secondStart, to: firstStart)
                    )
                    let fourthSide = cross(
                        secondVector,
                        vector(from: secondStart, to: firstEnd)
                    )
                    if firstSide * secondSide < -0.000_1
                        && thirdSide * fourthSide < -0.000_1 {
                        count += 1
                    }
                }
            }
            return count
        }

        let figureEightEvents: [(CGPoint, TimeInterval)] = [
            (CGPoint(x: 300, y: 80), 0),
            (CGPoint(x: 270, y: 48), 0.006),
            (CGPoint(x: 238, y: 80), 0.012),
            (CGPoint(x: 270, y: 112), 0.018),
            (CGPoint(x: 300, y: 80), 0.024),
            (CGPoint(x: 330, y: 48), 0.030),
            (CGPoint(x: 362, y: 80), 0.036),
            (CGPoint(x: 330, y: 112), 0.042),
            (CGPoint(x: 300, y: 80), 0.048)
        ]
        let figureEightController = AnnotationController()
        figureEightController.currentStyle.sloppiness = .architect
        figureEightController.begin(
            at: figureEightEvents[0].0,
            pressure: nil,
            timestamp: figureEightEvents[0].1,
            zoomScale: 1
        )
        figureEightController.updateFreehand(
            inputs: figureEightEvents.dropFirst().map {
                AnnotationRawFreehandInput(
                    location: $0.0,
                    pressure: nil,
                    timestamp: $0.1
                )
            },
            zoomScale: 1
        )
        guard let figureEightElement =
                figureEightController.inProgressElementSnapshot,
              case .freehand(let figureEight) = figureEightElement.geometry else {
            throw SelfTestError.failure("Expected figure-eight freehand geometry")
        }
        let smoothFigureEight = AnnotationGeometry.smoothedFreehandSamples(
            figureEight.samples,
            subdivisions: 2
        ).map(\.location)
        let sampledFigureEight = stride(
            from: 0,
            to: smoothFigureEight.count,
            by: 2
        ).map { smoothFigureEight[$0] }
        try expect(
            properIntersectionCount(sampledFigureEight)
                <= properIntersectionCount(figureEightEvents.map(\.0)),
            "Expected loop-safe smoothing not to add intersections to a sparse figure-eight"
        )
    }

    static func testBoundedFreehandPipelineAndRenderCache() throws {
        let controller = AnnotationController()
        controller.currentStyle.sloppiness = .architect
        controller.currentStyle.smoothingEnabled = false
        controller.begin(at: .zero, pressure: nil, timestamp: 0, zoomScale: 1)
        let inputs = (1...1_000).map { index in
            AnnotationRawFreehandInput(
                location: CGPoint(x: CGFloat(index) * 10, y: 0),
                pressure: nil,
                timestamp: Double(index) / 240
            )
        }
        controller.enqueueFreehandInputs(inputs)
        var drainCount = 0
        while controller.hasPendingFreehandInput {
            let stats = controller.drainFreehandInput(zoomScale: 1)
            drainCount += 1
            try expect(
                stats.rawEvents <= AnnotationFreehandDrainBudget.frame.maximumRawEvents
                    && stats.generatedSamples
                        <= AnnotationFreehandDrainBudget.frame.maximumGeneratedSamples,
                "Expected every freehand drain to remain inside raw-event and sample budgets"
            )
            guard drainCount < 10_000 else {
                throw SelfTestError.failure("Bounded freehand input did not eventually drain")
            }
        }
        guard let active = controller.inProgressElementSnapshot,
              case .freehand(let drained) = active.geometry else {
            throw SelfTestError.failure("Expected a drained active freehand stroke")
        }
        try expect(
            drained.samples.last?.location == inputs.last?.location
                && zip(drained.samples, drained.samples.dropFirst()).allSatisfy {
                    hypot(
                        $1.location.x - $0.location.x,
                        $1.location.y - $0.location.y
                    ) <= AnnotationFreehandInputResampler.screenSpacing + 0.001
                },
            "Expected 1,000 raw events and 10,000 pixels to drain to the reference trajectory"
        )

        var frameState = DrawingFreehandFrameInvalidationState()
        for _ in 0..<60 {
            for _ in 0..<4 {
                frameState.noteInput()
            }
            try expect(
                frameState.beginFrame() && !frameState.beginFrame(),
                "Expected at most one display invalidation in each 60 Hz frame"
            )
        }
        try expect(
            frameState.invalidationCount == 60
                && ZoomCanvasView.maximumFreehandEventsPerUpdate <= 8,
            "Expected 240 Hz input to coalesce to 60 invalidations"
        )

        var lastRecognitionTime: TimeInterval?
        var lastRecognizedSampleCount = 0
        var recognitionSubmissions = 0
        for sampleCount in 1...240 {
            let timestamp = Double(sampleCount) / 240
            if SmartDrawRecognitionBudget.shouldRecognizePreview(
                lastRecognitionTime: lastRecognitionTime,
                lastRecognizedSampleCount: lastRecognizedSampleCount,
                timestamp: timestamp,
                sampleCount: sampleCount
            ) {
                recognitionSubmissions += 1
                lastRecognitionTime = timestamp
                lastRecognizedSampleCount = sampleCount
            }
        }
        var generations = SmartDrawRecognitionGenerationState()
        generations.beginStroke()
        let staleRequest = generations.submit()
        let currentRequest = generations.submit()
        try expect(
            recognitionSubmissions <= 25
                && !generations.accepts(staleRequest)
                && generations.accepts(currentRequest),
            "Expected bounded recognizer cadence and latest-generation stale-result rejection"
        )

        let renderer = AnnotationRenderer()
        let samples = (0..<10_000).map { index in
            AnnotationPointSample(
                location: CGPoint(
                    x: 8 + CGFloat(index) * 0.004,
                    y: 32 + sin(CGFloat(index) * 0.01)
                ),
                pressure: nil
            )
        }
        var style = AnnotationStyle(color: .blue, rootWidth: 3, alpha: 1)
        style.sloppiness = .architect
        style.smoothingEnabled = false
        var activeStroke = AnnotationElement(
            geometry: .freehand(
                AnnotationFreehandGeometry(
                    samples: samples,
                    isHighlighter: false
                )
            ),
            style: style
        )
        _ = try renderPixels(
            elements: [],
            renderer: renderer,
            activeElement: activeStroke,
            width: 64,
            height: 64
        )
        let initialRebuilds = renderer.activeStrokeCacheCountersForTesting.rebuiltChunks
        guard case .freehand(var appended) = activeStroke.geometry else {
            throw SelfTestError.failure("Expected active cache freehand geometry")
        }
        appended.samples.append(
            AnnotationPointSample(location: CGPoint(x: 48.004, y: 32), pressure: nil)
        )
        activeStroke.geometry = .freehand(appended)
        _ = try renderPixels(
            elements: [],
            renderer: renderer,
            activeElement: activeStroke,
            width: 64,
            height: 64
        )
        let appendRebuilds =
            renderer.activeStrokeCacheCountersForTesting.rebuiltChunks - initialRebuilds
        let beforeUnchanged =
            renderer.activeStrokeCacheCountersForTesting.rebuiltChunks
        _ = try renderPixels(
            elements: [],
            renderer: renderer,
            activeElement: activeStroke,
            width: 64,
            height: 64
        )
        try expect(
            appendRebuilds <= 2
                && renderer.activeStrokeCacheCountersForTesting.rebuiltChunks
                    == beforeUnchanged,
            "Expected a 10k-stroke append to rebuild at most two chunks and unchanged redraw to rebuild none"
        )
    }

    static func testImmediateFreehandPresentationAndQueueBounds() throws {
        for rate in [125, 240, 500, 1_000] {
            var visualLane = DrawingLatestRawPointerLane()
            let controller = AnnotationController()
            controller.currentStyle.sloppiness = .architect
            controller.currentStyle.smoothingEnabled = false
            controller.begin(
                at: .zero,
                pressure: nil,
                timestamp: 0,
                zoomScale: 1
            )
            let eventCount = rate * 10
            let eventsPerFrame = max(1, Int(ceil(Double(rate) / 60)))
            var latest = AnnotationRawFreehandInput(
                location: .zero,
                pressure: nil,
                timestamp: 0
            )
            var maximumQueueCount = 0
            var maximumQueueAge = TimeInterval.zero
            for index in 1...eventCount {
                latest = AnnotationRawFreehandInput(
                    location: CGPoint(
                        x: CGFloat(index) * 0.4,
                        y: sin(CGFloat(index) * 0.018) * 14
                    ),
                    pressure: index.isMultiple(of: 97)
                        ? 1
                        : 0.35 + CGFloat(index % 11) * 0.04,
                    timestamp: Double(index) / Double(rate)
                )
                visualLane.update(latest)
                controller.enqueueFreehandInputs([latest])
                maximumQueueCount = max(
                    maximumQueueCount,
                    controller.pendingRawFreehandInputCountForTesting
                )
                maximumQueueAge = max(
                    maximumQueueAge,
                    controller.pendingRawFreehandInputAgeForTesting
                )
                if index.isMultiple(of: eventsPerFrame) {
                    let stats = controller.drainFreehandInput(
                        zoomScale: 1,
                        budget: AnnotationFreehandDrainBudget(
                            maximumRawEvents: 12,
                            maximumGeneratedSamples: 96,
                            spacingScale: controller
                                .pendingRawFreehandInputCountForTesting > 20
                                ? 2
                                : 1
                        )
                    )
                    try expect(
                        stats.rawEvents <= 12
                            && stats.generatedSamples <= 96,
                        "Expected strict per-frame freehand work budgets at \(rate) Hz"
                    )
                }
                try expect(
                    visualLane.latestRawPointer == latest
                        && visualLane.recentSamples.last == latest,
                    "Expected the replace-only visual lane to expose the newest \(rate) Hz event immediately"
                )
            }
            _ = controller.finishQueuedFreehandBounded(
                endingPressure: latest.pressure,
                timestamp: latest.timestamp,
                zoomScale: 1
            )
            guard let element = controller.elementSnapshot.last,
                  case .freehand(let freehand) = element.geometry else {
                throw SelfTestError.failure(
                    "Expected finalized sustained \(rate) Hz freehand geometry"
                )
            }
            try expect(
                maximumQueueCount <= AnnotationRawFreehandInputBuffer.defaultCapacity
                    && maximumQueueAge
                        <= AnnotationRawFreehandInputBuffer.maximumBufferedDuration
                            + 1 / Double(rate) + 0.001
                    && visualLane.recentSamples.count
                        <= DrawingLatestRawPointerLane.maximumSampleCount
                    && (visualLane.recentSamples.last!.timestamp
                        - visualLane.recentSamples.first!.timestamp)
                        <= DrawingLatestRawPointerLane.maximumDuration + 0.001
                    && freehand.samples.last?.location == latest.location
                    && !controller.hasPendingFreehandInput
                    && zip(
                        freehand.samples.map(\.location),
                        freehand.samples.map(\.location).dropFirst()
                    ).allSatisfy { $0.x <= $1.x },
                "Expected bounded \(rate) Hz queues, an immediate latest endpoint, and loop-safe finalization"
            )
        }

        var buffer = AnnotationRawFreehandInputBuffer(capacity: 8)
        let corner = AnnotationRawFreehandInput(
            location: CGPoint(x: 10, y: 0),
            pressure: 0.5,
            timestamp: 0.005
        )
        let pressureMinimum = AnnotationRawFreehandInput(
            location: CGPoint(x: 20, y: 10),
            pressure: 0.2,
            timestamp: 0.015
        )
        let pressureMaximum = AnnotationRawFreehandInput(
            location: CGPoint(x: 30, y: 10),
            pressure: 0.95,
            timestamp: 0.02
        )
        [
            AnnotationRawFreehandInput(
                location: .zero,
                pressure: 0.5,
                timestamp: 0
            ),
            corner,
            AnnotationRawFreehandInput(
                location: CGPoint(x: 10, y: 10),
                pressure: 0.5,
                timestamp: 0.01
            ),
            pressureMinimum,
            pressureMaximum,
            AnnotationRawFreehandInput(
                location: CGPoint(x: 40, y: 10),
                pressure: 0.5,
                timestamp: 0.025
            )
        ].forEach { buffer.append($0) }
        var retained: [AnnotationRawFreehandInput] = []
        while let input = buffer.popFirst() {
            retained.append(input)
        }
        try expect(
            retained.contains(corner)
                && retained.contains(pressureMinimum)
                && retained.contains(pressureMaximum),
            "Expected queue compaction to preserve endpoints, significant turns, and pressure extrema"
        )

        let source = CGRect(x: 120, y: 80, width: 640, height: 360)
        let destination = CGRect(x: 0, y: 0, width: 1_280, height: 720)
        let cursor = CGPoint(x: 913.25, y: 421.5)
        let content = DrawingImmediateFreehandPresentationPolicy.contentPoint(
            forViewPoint: cursor,
            source: source,
            destinationBounds: destination
        )
        let projected = DrawingImmediateFreehandPresentationPolicy.viewPoint(
            forContentPoint: content,
            source: source,
            destinationBounds: destination
        )
        let movingPointerVisible =
            DrawingImmediateFreehandPresentationPolicy.showsStandalonePointer(
                hasMoved: true,
                tailPointCount: 3
            )
        try expect(
            hypot(projected.x - cursor.x, projected.y - cursor.y) < 0.001
                && !movingPointerVisible
                && DrawingImmediateFreehandPresentationPolicy
                    .immediateTipComponentCount(
                        tailPointCount: 3,
                        showsStandalonePointer: movingPointerVisible
                    ) == 1
                && DrawingImmediateFreehandPresentationPolicy
                    .immediateTipComponentCount(
                        tailPointCount: 1,
                        showsStandalonePointer:
                            DrawingImmediateFreehandPresentationPolicy
                                .showsStandalonePointer(
                                    hasMoved: false,
                                    tailPointCount: 1
                                )
                    ) == 1,
            "Expected the moving tail endpoint to coincide with the cursor and render exactly one nib component"
        )

        for scale in [1, 2] {
            let logicalWidth = 64
            let logicalHeight = 48
            let width = logicalWidth * scale
            let height = logicalHeight * scale
            var layerPixels = [UInt8](repeating: 0, count: width * height * 4)
            try layerPixels.withUnsafeMutableBytes { bytes in
                guard let context = CGContext(
                    data: bytes.baseAddress,
                    width: width,
                    height: height,
                    bitsPerComponent: 8,
                    bytesPerRow: width * 4,
                    space: CGColorSpaceCreateDeviceRGB(),
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
                ) else {
                    throw SelfTestError.failure(
                        "Could not create immediate-layer raster bitmap"
                    )
                }
                context.scaleBy(x: CGFloat(scale), y: CGFloat(scale))
                let parent = CALayer()
                parent.frame = CGRect(
                    x: 0,
                    y: 0,
                    width: logicalWidth,
                    height: logicalHeight
                )
                parent.isGeometryFlipped = true
                let child = CAShapeLayer()
                child.frame = parent.bounds
                child.contentsScale = CGFloat(scale)
                ZoomCanvasView.configureImmediateFreehandLayerGeometry(child)
                let asymmetric = CGMutablePath()
                asymmetric.move(to: CGPoint(x: 6, y: 5))
                asymmetric.addLine(to: CGPoint(x: 24, y: 14))
                asymmetric.addLine(to: CGPoint(x: 50, y: 36))
                child.path = asymmetric
                child.strokeColor = NSColor.white.cgColor
                child.fillColor = nil
                child.lineWidth = 2
                child.lineCap = .round
                parent.addSublayer(child)
                parent.render(in: context)
                context.flush()
            }
            let endpointAlpha = alpha(
                layerPixels,
                width: width,
                x: 50 * scale,
                y: 36 * scale
            )
            let reflectedAlpha = alpha(
                layerPixels,
                width: width,
                x: 50 * scale,
                y: (logicalHeight - 36) * scale
            )
            try expect(
                endpointAlpha > 0 && reflectedAlpha == 0,
                "Expected the \(scale)x immediate CAShapeLayer endpoint at the raw cursor, not reflected"
            )
        }

        let stampController = AnnotationController()
        stampController.currentTool = .highlighter
        stampController.setOpacity(1)
        stampController.begin(at: CGPoint(x: 48, y: 32))
        let canonicalStamp = try renderControllerPixels(
            stampController,
            freehandPresentationOwner: .canonicalRenderer,
            width: 96,
            height: 64
        )
        let immediateOwnedStamp = try renderControllerPixels(
            stampController,
            freehandPresentationOwner: .immediateLayers,
            width: 96,
            height: 64
        )
        let configuredStampAlpha = alpha(
            canonicalStamp,
            width: 96,
            x: 48,
            y: 32
        )
        try expect(
            (120...135).contains(configuredStampAlpha)
                && alpha(immediateOwnedStamp, width: 96, x: 48, y: 32) == 0,
            "Expected a single Highlighter press to have one configured-opacity owner, "
                + "not a canonical-plus-overlay 75% composite"
        )

        let tailController = AnnotationController()
        tailController.currentTool = .highlighter
        tailController.currentStyle.smoothingEnabled = false
        tailController.begin(
            at: CGPoint(x: 12, y: 32),
            pressure: nil,
            timestamp: 0,
            zoomScale: 1
        )
        tailController.update(
            at: CGPoint(x: 40, y: 32),
            timestamp: 0.1,
            zoomScale: 1
        )
        tailController.enqueueFreehandInputs([
            AnnotationRawFreehandInput(
                location: CGPoint(x: 84, y: 32),
                pressure: nil,
                timestamp: 0.2
            )
        ])
        let canonicalTail = try renderControllerPixels(
            tailController,
            freehandPresentationOwner: .canonicalRenderer,
            width: 96,
            height: 64
        )
        let immediateOwnedTail = try renderControllerPixels(
            tailController,
            freehandPresentationOwner: .immediateLayers,
            width: 96,
            height: 64
        )
        try expect(
            alpha(canonicalTail, width: 96, x: 70, y: 32) > 0
                && alpha(immediateOwnedTail, width: 96, x: 24, y: 32) > 0
                && alpha(immediateOwnedTail, width: 96, x: 70, y: 32) == 0,
            "Expected the canonical renderer to retain committed freehand content "
                + "while immediate layers exclusively own the queued straight tail"
        )
    }
}
