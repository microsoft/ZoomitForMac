import AppKit

extension SelfTestRunner {
    static func testCommittedFreehandRenderCache() throws {
        func penStroke(
            index: Int,
            sampleCount: Int = 1_000,
            pressureEnabled: Bool = false,
            sloppiness: AnnotationSloppiness = .artist
        ) -> AnnotationElement {
            var style = AnnotationStyle(
                color: index.isMultiple(of: 2) ? .blue : .red,
                rootWidth: 5,
                alpha: 0.9
            )
            style.sloppiness = sloppiness
            style.smoothingEnabled = true
            style.pressureMode = pressureEnabled ? .tablet : .fixed
            let samples = (0..<sampleCount).map { sampleIndex in
                AnnotationPointSample(
                    location: CGPoint(
                        x: 8 + CGFloat(sampleIndex) * 0.075,
                        y: 10 + CGFloat(index) * 7
                            + sin(CGFloat(sampleIndex) * 0.035) * 2
                    ),
                    pressure: pressureEnabled
                        ? 0.25 + CGFloat(sampleIndex % 80) / 120
                        : nil
                )
            }
            return AnnotationElement(
                geometry: .freehand(
                    AnnotationFreehandGeometry(
                        samples: samples,
                        isHighlighter: false
                    )
                ),
                style: style
            )
        }

        let renderer = AnnotationRenderer()
        var strokes = (0..<10).map { penStroke(index: $0) }
        _ = try renderPixels(
            elements: strokes,
            renderer: renderer,
            width: 96,
            height: 88
        )
        try expect(
            renderer.committedStrokeCacheCountersForTesting.rebuiltElements == 10,
            "Expected the first 10x1000 Artist-stroke render to build ten committed cache entries"
        )
        let buildsBeforeUnchanged =
            renderer.committedStrokeCacheCountersForTesting.rebuiltElements
        _ = try renderPixels(
            elements: strokes,
            renderer: renderer,
            width: 96,
            height: 88
        )
        try expect(
            renderer.committedStrokeCacheCountersForTesting.rebuiltElements
                == buildsBeforeUnchanged,
            "Expected unchanged committed freehand redraw to rebuild zero elements"
        )

        strokes.append(penStroke(index: 10, sampleCount: 300))
        var buildsBeforeMutation =
            renderer.committedStrokeCacheCountersForTesting.rebuiltElements
        _ = try renderPixels(
            elements: strokes,
            renderer: renderer,
            width: 96,
            height: 96
        )
        try expect(
            renderer.committedStrokeCacheCountersForTesting.rebuiltElements
                - buildsBeforeMutation == 1,
            "Expected appending a committed stroke to build only the new element"
        )

        strokes[2].style.strokeWidth += 2
        buildsBeforeMutation =
            renderer.committedStrokeCacheCountersForTesting.rebuiltElements
        _ = try renderPixels(elements: strokes, renderer: renderer)
        try expect(
            renderer.committedStrokeCacheCountersForTesting.rebuiltElements
                - buildsBeforeMutation == 1,
            "Expected a style edit to rebuild only the affected freehand element"
        )

        strokes[3].style.sloppiness = .cartoonist
        buildsBeforeMutation =
            renderer.committedStrokeCacheCountersForTesting.rebuiltElements
        _ = try renderPixels(elements: strokes, renderer: renderer)
        try expect(
            renderer.committedStrokeCacheCountersForTesting.rebuiltElements
                - buildsBeforeMutation == 1,
            "Expected a sloppiness edit to rebuild only the affected freehand element"
        )

        guard case .freehand(var pressureGeometry) = strokes[4].geometry else {
            throw SelfTestError.failure("Expected pressure-cache freehand geometry")
        }
        strokes[4].style.pressureMode = .tablet
        pressureGeometry.samples[100].pressure = 0.35
        strokes[4].geometry = .freehand(pressureGeometry)
        buildsBeforeMutation =
            renderer.committedStrokeCacheCountersForTesting.rebuiltElements
        _ = try renderPixels(elements: strokes, renderer: renderer)
        try expect(
            renderer.committedStrokeCacheCountersForTesting.rebuiltElements
                - buildsBeforeMutation == 1,
            "Expected a pressure edit to rebuild only the affected freehand element"
        )

        strokes[5].metadata.rotation = .pi / 8
        buildsBeforeMutation =
            renderer.committedStrokeCacheCountersForTesting.rebuiltElements
        _ = try renderPixels(elements: strokes, renderer: renderer)
        try expect(
            renderer.committedStrokeCacheCountersForTesting.rebuiltElements
                - buildsBeforeMutation == 1,
            "Expected a transform edit to rebuild only the affected freehand element"
        )

        strokes[6].style.strokeColor = .palette(.green)
        buildsBeforeMutation =
            renderer.committedStrokeCacheCountersForTesting.rebuiltElements
        _ = try renderPixels(elements: strokes, renderer: renderer)
        try expect(
            renderer.committedStrokeCacheCountersForTesting.rebuiltElements
                - buildsBeforeMutation == 1,
            "Expected a color edit to invalidate only the affected freehand element"
        )

        let scaleRenderer = AnnotationRenderer()
        let scaleStroke = penStroke(
            index: 0,
            sampleCount: 220,
            sloppiness: .cartoonist
        )
        _ = try renderPixels(
            elements: [scaleStroke],
            renderer: scaleRenderer,
            destinationPointScale: 1
        )
        _ = try renderPixels(
            elements: [scaleStroke],
            renderer: scaleRenderer,
            destinationPointScale: 2
        )
        let buildsBeforeScaleReuse =
            scaleRenderer.committedStrokeCacheCountersForTesting.rebuiltElements
        _ = try renderPixels(
            elements: [scaleStroke],
            renderer: scaleRenderer,
            destinationPointScale: 1
        )
        _ = try renderPixels(
            elements: [scaleStroke],
            renderer: scaleRenderer,
            destinationPointScale: 3
        )
        try expect(
            buildsBeforeScaleReuse == 2
                && scaleRenderer.committedStrokeCacheCountersForTesting.rebuiltElements
                    == 3
                && scaleRenderer.committedStrokeCacheScaleVariantCountForTesting(
                    elementID: scaleStroke.id
                ) == 2,
            "Expected scale-specific reuse with at most two recent variants per element"
        )

        var highlighterStyle = AnnotationStyle(
            color: .highlighterYellow,
            rootWidth: 18,
            alpha: 0.8,
            sloppiness: .architect
        )
        highlighterStyle.smoothingEnabled = true
        let highlighter = AnnotationElement(
            geometry: .freehand(
                AnnotationFreehandGeometry(
                    samples: [
                        AnnotationPointSample(
                            location: CGPoint(x: 12, y: 48),
                            pressure: nil
                        ),
                        AnnotationPointSample(
                            location: CGPoint(x: 84, y: 48),
                            pressure: nil
                        )
                    ],
                    isHighlighter: true
                )
            ),
            style: highlighterStyle
        )
        let highlighterRenderer = AnnotationRenderer()
        let yellowPixels = try renderPixels(
            elements: [highlighter],
            renderer: highlighterRenderer
        )
        let highlighterBuilds =
            highlighterRenderer.committedStrokeCacheCountersForTesting.rebuiltElements
        _ = try renderPixels(
            elements: [highlighter],
            renderer: highlighterRenderer
        )
        var editedHighlighter = highlighter
        editedHighlighter.style.strokeColor = .palette(.highlighterPink)
        editedHighlighter.style.opacity = 0.35
        let pinkPixels = try renderPixels(
            elements: [editedHighlighter],
            renderer: highlighterRenderer
        )
        let yellowPixel = pixel(yellowPixels, width: 96, x: 48, y: 48)
        let pinkPixel = pixel(pinkPixels, width: 96, x: 48, y: 48)
        try expect(
            highlighterBuilds == 1
                && highlighterRenderer.committedStrokeCacheCountersForTesting.rebuiltElements
                    == highlighterBuilds + 1
                && pinkPixel.alpha < yellowPixel.alpha
                && pinkPixel.red > pinkPixel.green,
            "Expected cached Highlighter paths to preserve updated color and effective opacity"
        )

        let activeRenderer = AnnotationRenderer()
        let promotableStroke = penStroke(
            index: 0,
            sampleCount: 64,
            sloppiness: .architect
        )
        _ = try renderPixels(
            elements: [],
            renderer: activeRenderer,
            activeElement: promotableStroke
        )
        try expect(
            activeRenderer.committedStrokeCacheEntryCountForTesting == 0,
            "Expected active/immediate presentation to stay out of the committed cache"
        )
        activeRenderer.promoteActiveStrokeCache(
            for: promotableStroke,
            destinationPointScale: 1
        )
        _ = try renderPixels(
            elements: [promotableStroke],
            renderer: activeRenderer
        )
        try expect(
            activeRenderer.committedStrokeCacheCountersForTesting.promotedElements == 1
                && activeRenderer.committedStrokeCacheCountersForTesting.rebuiltElements == 0,
            "Expected an exact finalized active chunk to promote without committed reconstruction"
        )

        let promotionController = AnnotationController()
        promotionController.currentStyle.sloppiness = .architect
        promotionController.currentStyle.smoothingEnabled = false
        promotionController.begin(
            at: CGPoint(x: 12, y: 32),
            pressure: nil,
            timestamp: 0,
            zoomScale: 1
        )
        for index in 1...20 {
            promotionController.update(
                at: CGPoint(x: 12 + CGFloat(index) * 2, y: 32),
                pressure: nil,
                timestamp: Double(index) / 120,
                zoomScale: 1
            )
        }
        _ = try renderControllerPixels(
            promotionController,
            freehandPresentationOwner: .immediateLayers,
            width: 64,
            height: 64
        )
        try expect(
            promotionController.committedStrokeCacheEntryCountForTesting == 0,
            "Expected the immediate-layer owner not to leak active geometry into committed entries"
        )
        _ = try renderControllerPixels(
            promotionController,
            freehandPresentationOwner: .canonicalRenderer,
            width: 64,
            height: 64
        )
        promotionController.end(
            at: CGPoint(x: 52, y: 32),
            pressure: nil,
            timestamp: 21.0 / 120,
            zoomScale: 1
        )
        _ = try renderControllerPixels(
            promotionController,
            freehandPresentationOwner: .canonicalRenderer,
            width: 64,
            height: 64
        )
        try expect(
            promotionController.committedStrokeCacheCountersForTesting.promotedElements
                == 1
                && promotionController.committedStrokeCacheCountersForTesting.rebuiltElements
                    == 0,
            "Expected controller commit to promote a finalized active cache entry"
        )

        let historyRenderer = AnnotationRenderer()
        let scene = AnnotationScene()
        let historyStroke = penStroke(index: 0, sampleCount: 180)
        scene.append(historyStroke)
        _ = try renderPixels(
            elements: scene.elements,
            renderer: historyRenderer
        )
        scene.removeElements(withIDs: [historyStroke.id])
        _ = try renderPixels(elements: scene.elements, renderer: historyRenderer)
        try expect(
            !historyRenderer.hasCommittedStrokeCacheForTesting(
                elementID: historyStroke.id
            ),
            "Expected deletion to evict the removed committed stroke"
        )
        try expect(scene.undo(), "Expected undo to restore the deleted stroke")
        let buildsBeforeUndoRestore =
            historyRenderer.committedStrokeCacheCountersForTesting.rebuiltElements
        _ = try renderPixels(elements: scene.elements, renderer: historyRenderer)
        try expect(
            historyRenderer.committedStrokeCacheCountersForTesting.rebuiltElements
                == buildsBeforeUndoRestore + 1
                && historyRenderer.hasCommittedStrokeCacheForTesting(
                    elementID: historyStroke.id
                ),
            "Expected undo to rebuild the restored stable-ID cache entry"
        )
        try expect(scene.redo(), "Expected redo to delete the restored stroke")
        _ = try renderPixels(elements: scene.elements, renderer: historyRenderer)
        try expect(
            historyRenderer.committedStrokeCacheEntryCountForTesting == 0,
            "Expected redo deletion to evict the restored cache entry"
        )
        scene.undo()
        _ = try renderPixels(elements: scene.elements, renderer: historyRenderer)
        scene.clear()
        _ = try renderPixels(elements: scene.elements, renderer: historyRenderer)
        try expect(
            historyRenderer.committedStrokeCacheEntryCountForTesting == 0,
            "Expected clear to evict all committed freehand cache entries"
        )

        let boundedRenderer = AnnotationRenderer(
            committedStrokeCacheCostLimit: 1_000_000,
            committedStrokeCacheEntryLimit: 3
        )
        let boundedStrokes = (0..<8).map { penStroke(index: $0) }
        _ = try renderPixels(
            elements: boundedStrokes,
            renderer: boundedRenderer,
            width: 96,
            height: 72
        )
        try expect(
            boundedRenderer.committedStrokeCacheEntryCountForTesting <= 3
                && boundedRenderer.committedStrokeCacheEstimatedCostForTesting
                    <= 1_000_000
                && boundedRenderer.committedStrokeCacheCountersForTesting.evictedEntries
                    >= 5,
            "Expected committed stroke cache LRU limits to bound entries and estimated memory"
        )
    }

    static func testFreehandRenderingQualityAndHighlighterPreview() throws {
        let renderer = AnnotationRenderer()
        var markerStyle = AnnotationStyle(
            color: .highlighterYellow,
            rootWidth: 20,
            alpha: 1
        )
        markerStyle.strokePattern = .dotted
        markerStyle.sloppiness = .cartoonist
        markerStyle.pressureMode = .simulated
        let markerStamp = AnnotationElement(
            geometry: .freehand(
                AnnotationFreehandGeometry(
                    samples: [
                        AnnotationPointSample(
                            location: CGPoint(x: 48, y: 32),
                            pressure: 0.2
                        )
                    ],
                    isHighlighter: true
                )
            ),
            style: markerStyle
        )
        let stampPixels = try renderPixels(
            elements: [markerStamp],
            renderer: renderer,
            width: 96,
            height: 64
        )
        guard let stampBounds = paintedBounds(
            stampPixels,
            width: 96,
            height: 64
        ) else {
            throw SelfTestError.failure("Expected a Highlighter marker stamp")
        }
        let markerLine = AnnotationElement(
            geometry: .freehand(
                AnnotationFreehandGeometry(
                    samples: [
                        AnnotationPointSample(location: CGPoint(x: 20, y: 32), pressure: 0.2),
                        AnnotationPointSample(location: CGPoint(x: 76, y: 32), pressure: 1)
                    ],
                    isHighlighter: true
                )
            ),
            style: markerStyle
        )
        let markerPixels = try renderPixels(
            elements: [markerLine],
            renderer: renderer,
            width: 96,
            height: 64
        )
        try expect(
            stampBounds.height > stampBounds.width + 4
                && AnnotationHighlighterGeometry.stampRect(
                    center: .zero,
                    strokeWidth: 20
                ).width < 20
                && alpha(markerPixels, width: 96, x: 18, y: 32) == 0
                && alpha(markerPixels, width: 96, x: 20, y: 32) > 0
                && alpha(markerPixels, width: 96, x: 75, y: 32) > 0
                && alpha(markerPixels, width: 96, x: 78, y: 32) == 0,
            "Expected a rectangular stamp and clean flat/butt Highlighter nib"
        )

        var pressureStyle = AnnotationStyle(color: .blue, rootWidth: 12, alpha: 1)
        pressureStyle.sloppiness = .architect
        pressureStyle.pressureMode = .tablet
        pressureStyle.smoothingEnabled = true
        let pressureSamples = (0...20).map { index in
            AnnotationPointSample(
                location: CGPoint(x: 12 + CGFloat(index) * 3.5, y: 28),
                pressure: 0.2 + CGFloat(index) * 0.04
            )
        }
        let pressureStroke = AnnotationElement(
            geometry: .freehand(
                AnnotationFreehandGeometry(
                    samples: pressureSamples,
                    isHighlighter: false
                )
            ),
            style: pressureStyle
        )
        let pressurePixels = try renderPixels(
            elements: [pressureStroke],
            renderer: renderer,
            width: 96,
            height: 64
        )
        let spans = stride(from: 14, through: 80, by: 2).map {
            paintedVerticalSpan(
                pressurePixels,
                width: 96,
                height: 64,
                x: $0
            )
        }
        try expect(
            spans.allSatisfy { $0 > 0 }
                && zip(spans, spans.dropFirst()).allSatisfy {
                    abs($1 - $0) <= 4
                },
            "Expected interpolated variable-width outlines without gaps, pinching, or spikes"
        )

        let penController = AnnotationController()
        penController.currentStyle.sloppiness = .architect
        penController.currentStyle.strokeWidth = 6
        penController.begin(at: CGPoint(x: 8, y: 32))
        for index in 1...85 {
            penController.update(
                at: CGPoint(
                    x: 8 + CGFloat(index) * 1.25,
                    y: 32 + sin(CGFloat(index) * 0.72) * 0.8
                ),
                zoomScale: 1
            )
        }
        penController.end(at: CGPoint(x: 116, y: 32), zoomScale: 1)
        let penPixels = try renderPixels(
            elements: penController.elementSnapshot,
            renderer: renderer,
            width: 128,
            height: 64
        )
        try expect(
            stride(from: 10, through: 114, by: 2).allSatisfy {
                hasPaintedPixel(
                    penPixels,
                    width: 128,
                    height: 64,
                    near: CGPoint(x: $0, y: 32),
                    radius: 4
                )
            },
            "Expected a fluid smoothed pen centerline with no rendered gaps"
        )

        func cachedCenterColor(of view: NSView) throws -> NSColor {
            view.layoutSubtreeIfNeeded()
            guard let representation = view.bitmapImageRepForCachingDisplay(
                in: view.bounds
            ) else {
                throw SelfTestError.failure("Could not cache inspector color preview")
            }
            view.cacheDisplay(in: view.bounds, to: representation)
            guard let color = representation.colorAt(
                x: representation.pixelsWide / 2,
                y: representation.pixelsHigh / 2
            )?.usingColorSpace(.sRGB) else {
                throw SelfTestError.failure("Could not sample inspector color preview")
            }
            return color
        }

        func colorDistance(_ lhs: NSColor, _ rhs: NSColor) -> CGFloat {
            let left = lhs.usingColorSpace(.sRGB) ?? lhs
            let right = rhs.usingColorSpace(.sRGB) ?? rhs
            return max(
                abs(left.redComponent - right.redComponent),
                abs(left.greenComponent - right.greenComponent),
                abs(left.blueComponent - right.blueComponent)
            )
        }

        let highlighterController = AnnotationController()
        highlighterController.currentTool = .highlighter
        highlighterController.currentStyle.sloppiness = .architect
        highlighterController.currentStyle.strokeWidth = 14
        highlighterController.setStrokeColor(.palette(.highlighterOrange))
        highlighterController.setOpacity(0.8)
        let inspector = DrawingPropertiesController(
            commandSink: { _ in },
            colorPanelActivityChanged: { _ in }
        )
        inspector.update(
            state: DrawingToolbarState(annotationController: highlighterController)
        )
        _ = inspector.visibleSectionFramesForTesting()
        guard let orangeButton = descendantViews(
            of: NSButton.self,
            in: inspector.view
        ).first(where: { $0.accessibilityLabel() == "Stroke Orange" }) else {
            throw SelfTestError.failure("Expected the highlighter orange stroke swatch")
        }
        let presetPreview = try cachedCenterColor(of: orangeButton)
        let panelBackground = DrawingColorSwatchAppearance.panelBackground(
            for: orangeButton.effectiveAppearance
        )
        let expectedPreset = AnnotationColorResolver.compositedColor(
            .palette(.highlighterOrange),
            opacity: 0.8,
            highlightMultiplier: AnnotationStyle.highlightAlpha,
            over: panelBackground
        )
        highlighterController.begin(at: CGPoint(x: 12, y: 32))
        highlighterController.end(at: CGPoint(x: 84, y: 32))
        let presetCanvasPixels = try renderPixels(
            elements: highlighterController.elementSnapshot,
            renderer: renderer,
            width: 96,
            height: 64,
            backgroundColor: panelBackground
        )
        let presetCanvasPixel = pixel(
            presetCanvasPixels,
            width: 96,
            x: 48,
            y: 32
        )
        let presetCanvasColor = NSColor(
            srgbRed: CGFloat(presetCanvasPixel.red) / 255,
            green: CGFloat(presetCanvasPixel.green) / 255,
            blue: CGFloat(presetCanvasPixel.blue) / 255,
            alpha: 1
        )
        try expect(
            colorDistance(presetPreview, expectedPreset) < 0.09
                && colorDistance(presetCanvasColor, expectedPreset) < 0.09
                && orangeButton.accessibilityValue() as? String == "Selected"
                && orangeButton.layer?.borderWidth == 0,
            "Expected the selected preset swatch and canvas highlighter to share one effective color"
        )

        let customColor = AnnotationColorValue.rgba(
            red: 0.2,
            green: 0.6,
            blue: 1,
            alpha: 0.6
        )
        highlighterController.reset()
        highlighterController.currentTool = .highlighter
        highlighterController.currentStyle.sloppiness = .architect
        highlighterController.currentStyle.strokeWidth = 14
        highlighterController.setStrokeColor(customColor)
        highlighterController.setOpacity(0.8)
        inspector.update(
            state: DrawingToolbarState(annotationController: highlighterController)
        )
        _ = inspector.visibleSectionFramesForTesting()
        guard let customWell = descendantViews(
            of: NSColorWell.self,
            in: inspector.view
        ).first(where: { $0.accessibilityLabel() == "Custom stroke color" }) else {
            throw SelfTestError.failure("Expected the highlighter custom stroke tile")
        }
        let customPreview = try cachedCenterColor(of: customWell)
        let expectedCustom = AnnotationColorResolver.compositedColor(
            customColor,
            opacity: 0.8,
            highlightMultiplier: AnnotationStyle.highlightAlpha,
            over: panelBackground
        )
        let resolvedCustom = AnnotationColorResolver.resolved(
            customColor,
            opacity: 0.8,
            highlightMultiplier: AnnotationStyle.highlightAlpha
        )
        highlighterController.begin(at: CGPoint(x: 12, y: 32))
        highlighterController.end(at: CGPoint(x: 84, y: 32))
        let customCanvasPixels = try renderPixels(
            elements: highlighterController.elementSnapshot,
            renderer: renderer,
            width: 96,
            height: 64,
            backgroundColor: panelBackground
        )
        let customCanvasPixel = pixel(
            customCanvasPixels,
            width: 96,
            x: 48,
            y: 32
        )
        let customCanvasColor = NSColor(
            srgbRed: CGFloat(customCanvasPixel.red) / 255,
            green: CGFloat(customCanvasPixel.green) / 255,
            blue: CGFloat(customCanvasPixel.blue) / 255,
            alpha: 1
        )
        try expect(
            abs(resolvedCustom.alpha - 0.24) < 0.001
                && colorDistance(customPreview, expectedCustom) < 0.09
                && colorDistance(customCanvasColor, expectedCustom) < 0.09
                && customWell.accessibilityValue() as? String == "Not selected",
            "Expected custom sRGB alpha, style opacity, and highlight opacity to apply once"
        )
    }

    static func testExplicitLegacyHighlightSemantics() throws {
        var ordinaryStyle = AnnotationStyle(color: .orange, rootWidth: 4, alpha: 0.5)
        ordinaryStyle.sloppiness = .architect
        ordinaryStyle.fillStyle = .none
        let ordinaryShape = AnnotationElement(
            geometry: .shape(
                AnnotationShapeGeometry(
                    kind: .rectangle,
                    start: CGPoint(x: 12, y: 12),
                    end: CGPoint(x: 52, y: 52)
                )
            ),
            style: ordinaryStyle
        )
        let ordinaryPixels = try renderPixels(
            elements: [ordinaryShape],
            renderer: AnnotationRenderer()
        )
        try expect(
            alpha(ordinaryPixels, width: 96, x: 32, y: 32) == 0
                && !AnnotationHitTester.contains(
                    CGPoint(x: 32, y: 32),
                    in: ordinaryShape,
                    zoomScale: 1
                ),
            "Expected ordinary 50% opacity to remain an outlined, normally hit-tested shape"
        )

        var legacyStyle = ordinaryStyle
        legacyStyle.usesLegacyHighlightCompositing = true
        let legacyShape = AnnotationElement(
            geometry: ordinaryShape.geometry,
            style: legacyStyle
        )
        let legacyPixels = try renderPixels(
            elements: [legacyShape],
            renderer: AnnotationRenderer()
        )
        try expect(
            (120...135).contains(alpha(legacyPixels, width: 96, x: 32, y: 32))
                && AnnotationHitTester.contains(
                    CGPoint(x: 32, y: 32),
                    in: legacyShape,
                    zoomScale: 1
                ),
            "Expected only explicitly marked legacy highlights to force fill and non-darkening compositing"
        )

        var blueStyle = AnnotationStyle(color: .blue, rootWidth: 12, alpha: 1)
        blueStyle.sloppiness = .architect
        blueStyle.lineCap = .butt
        var redStyle = AnnotationStyle(color: .red, rootWidth: 12, alpha: 0.5)
        redStyle.sloppiness = .architect
        redStyle.lineCap = .butt
        let blueLine = AnnotationElement.legacy(
            tool: .line,
            points: [CGPoint(x: 48, y: 16), CGPoint(x: 48, y: 80)],
            style: blueStyle
        )
        let redLine = AnnotationElement.legacy(
            tool: .line,
            points: [CGPoint(x: 16, y: 48), CGPoint(x: 80, y: 48)],
            style: redStyle
        )
        let orderedPixels = try renderPixels(
            elements: [blueLine, redLine],
            renderer: AnnotationRenderer()
        )
        let crossing = pixel(orderedPixels, width: 96, x: 48, y: 48)
        try expect(
            crossing.red > 100 && crossing.blue > 100,
            "Expected ordinary translucent elements to preserve scene z-order, got \(crossing)"
        )
    }

    static func testHighlightZOrderRendering() throws {
        var highlightStyle = AnnotationStyle(color: .yellow, rootWidth: 20, alpha: 1)
        highlightStyle.sloppiness = .architect
        highlightStyle.pressureEnabled = false
        let highlight = AnnotationElement(
            geometry: .freehand(
                AnnotationFreehandGeometry(
                    samples: [
                        AnnotationPointSample(location: CGPoint(x: 12, y: 48), pressure: nil),
                        AnnotationPointSample(location: CGPoint(x: 84, y: 48), pressure: nil)
                    ],
                    isHighlighter: true
                )
            ),
            style: highlightStyle
        )
        var solidStyle = AnnotationStyle(color: .blue, rootWidth: 20, alpha: 1)
        solidStyle.sloppiness = .architect
        solidStyle.lineCap = .butt
        let solid = AnnotationElement.legacy(
            tool: .line,
            points: [CGPoint(x: 48, y: 12), CGPoint(x: 48, y: 84)],
            style: solidStyle
        )
        let scene = AnnotationScene(elements: [highlight, solid])
        let editor = AnnotationEditor(scene: scene)
        let renderer = AnnotationRenderer()

        let behindPixels = try renderPixels(elements: scene.elements, renderer: renderer)
        let behind = pixel(behindPixels, width: 96, x: 48, y: 48)
        scene.select([highlight.id])
        editor.arrangeSelection(.bringToFront)
        let frontPixels = try renderPixels(elements: scene.elements, renderer: renderer)
        let front = pixel(frontPixels, width: 96, x: 48, y: 48)
        try expect(
            behind.blue > 200 && behind.red < 30
                && front.red > behind.red + 80
                && front.green > behind.green,
            "Expected bring-to-front to visibly move a highlighter above solid ink"
        )

        editor.arrangeSelection(.sendToBack)
        let sentBackPixels = try renderPixels(elements: scene.elements, renderer: renderer)
        try expect(
            pixel(sentBackPixels, width: 96, x: 48, y: 48).blue == behind.blue,
            "Expected send-to-back to restore the highlighter beneath solid ink"
        )

        let overlappingHighlights = try renderPixels(
            elements: [highlight, highlight],
            renderer: renderer
        )
        try expect(
            (120...135).contains(alpha(overlappingHighlights, width: 96, x: 48, y: 48)),
            "Expected contiguous highlighter runs to retain non-darkening overlap semantics"
        )
    }

    static func testHighlighterEffectiveOpacityAndHistory() throws {
        func highlighter(
            from start: CGPoint,
            to end: CGPoint,
            color: AnnotationColorValue,
            opacity: CGFloat
        ) -> AnnotationElement {
            var style = AnnotationStyle(
                color: .yellow,
                rootWidth: 18,
                alpha: opacity,
                sloppiness: .architect
            )
            style.strokeColor = color
            return AnnotationElement(
                geometry: .freehand(
                    AnnotationFreehandGeometry(
                        samples: [
                            AnnotationPointSample(location: start, pressure: nil),
                            AnnotationPointSample(location: end, pressure: nil)
                        ],
                        isHighlighter: true
                    )
                ),
                style: style
            )
        }

        let horizontal = highlighter(
            from: CGPoint(x: 12, y: 48),
            to: CGPoint(x: 84, y: 48),
            color: .rgba(red: 1, green: 1, blue: 0, alpha: 1),
            opacity: 0.5
        )
        let verticalSameOpacity = highlighter(
            from: CGPoint(x: 48, y: 12),
            to: CGPoint(x: 48, y: 84),
            color: .rgba(red: 1, green: 0, blue: 0, alpha: 0.5),
            opacity: 1
        )
        let renderer = AnnotationRenderer()
        let sameOpacityPixels = try renderPixels(
            elements: [horizontal, verticalSameOpacity],
            renderer: renderer
        )
        let horizontalAlpha = alpha(sameOpacityPixels, width: 96, x: 24, y: 48)
        let crossingAlpha = alpha(sameOpacityPixels, width: 96, x: 48, y: 48)
        try expect(
            abs(Int(crossingAlpha) - Int(horizontalAlpha)) <= 2
                && (55...70).contains(crossingAlpha),
            "Expected equal effective highlighter opacity, including custom color alpha, "
                + "to composite once without overlap darkening"
        )

        let horizontalStrong = highlighter(
            from: CGPoint(x: 12, y: 48),
            to: CGPoint(x: 84, y: 48),
            color: .rgba(red: 1, green: 1, blue: 0, alpha: 1),
            opacity: 1
        )
        let verticalWeak = highlighter(
            from: CGPoint(x: 48, y: 12),
            to: CGPoint(x: 48, y: 84),
            color: .rgba(red: 1, green: 0, blue: 0, alpha: 1),
            opacity: 0.5
        )
        let mixedOpacityPixels = try renderPixels(
            elements: [horizontalStrong, verticalWeak],
            renderer: renderer
        )
        let reversedOpacityPixels = try renderPixels(
            elements: [verticalWeak, horizontalStrong],
            renderer: renderer
        )
        let mixedCrossing = pixel(mixedOpacityPixels, width: 96, x: 48, y: 48)
        let reversedCrossing = pixel(reversedOpacityPixels, width: 96, x: 48, y: 48)
        try expect(
            mixedCrossing.alpha > 145
                && mixedCrossing.green < reversedCrossing.green,
            "Expected mixed-opacity highlighter runs to composite separately in scene order"
        )

        let controller = AnnotationController()
        controller.currentTool = .highlighter
        controller.currentStyle.sloppiness = .architect
        controller.begin(at: CGPoint(x: 12, y: 48))
        controller.end(at: CGPoint(x: 84, y: 48))
        let beforeEdit = try renderPixels(
            elements: controller.elementSnapshot,
            renderer: renderer
        )
        controller.currentTool = .select
        _ = controller.beginSelectionInteraction(
            at: CGPoint(x: 48, y: 48),
            zoomScale: 1,
            modifiers: [],
            clickCount: 1
        )
        controller.endSelectionInteraction(
            at: CGPoint(x: 48, y: 48),
            modifiers: []
        )
        controller.beginContinuousStyleEdit(owner: .opacitySlider)
        controller.setOpacity(0.4)
        controller.endContinuousStyleEdit(owner: .opacitySlider)
        let afterEdit = try renderPixels(
            elements: controller.elementSnapshot,
            renderer: renderer
        )
        try expect(
            alpha(afterEdit, width: 96, x: 48, y: 48)
                < alpha(beforeEdit, width: 96, x: 48, y: 48) - 50,
            "Expected the inspector opacity control to visibly change highlighter output"
        )
        controller.undo()
        let afterUndo = try renderPixels(
            elements: controller.elementSnapshot,
            renderer: renderer
        )
        try expect(
            afterUndo == beforeEdit,
            "Expected one inspector-history undo to restore the visible highlighter opacity"
        )
    }
}
