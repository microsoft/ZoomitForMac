import AppKit

extension SelfTestRunner {
    static func testAnnotationRenderingTouchesPixels() throws {
        let width = 64
        let height = 64
        let controller = AnnotationController()
        controller.currentStyle = AnnotationStyle(color: .red, rootWidth: 8, alpha: 1)
        controller.begin(at: CGPoint(x: 8, y: 32))
        controller.update(at: CGPoint(x: 56, y: 32))
        controller.end(at: CGPoint(x: 56, y: 32))
        let pixels = try renderBitmap(width: width, height: height, antialias: true) { context in
            controller.render(in: context, bounds: CGRect(x: 0, y: 0, width: width, height: height))
        }
        try expect(pixels.contains { $0 > 0 }, "Expected annotation rendering to modify offscreen bitmap pixels")
    }

    static func testAnnotationRenderingStylesAndFamilies() throws {
        let renderer = AnnotationRenderer()

        var shapeStyle = AnnotationStyle(
            color: .blue,
            rootWidth: 4,
            alpha: 1,
            fillColor: .rgba(red: 1, green: 0, blue: 0, alpha: 1),
            fillStyle: .solid,
            sloppiness: .architect
        )
        shapeStyle.strokeColor = .rgba(red: 0, green: 0, blue: 1, alpha: 1)
        let rectangle = AnnotationElement(
            geometry: .shape(
                AnnotationShapeGeometry(
                    kind: .rectangle,
                    start: CGPoint(x: 8, y: 8),
                    end: CGPoint(x: 32, y: 32)
                )
            ),
            style: shapeStyle
        )
        let rectanglePixels = try renderPixels(elements: [rectangle], renderer: renderer)
        let rectangleCenter = pixel(rectanglePixels, width: 96, x: 20, y: 20)
        let rectangleBorder = pixel(rectanglePixels, width: 96, x: 8, y: 20)
        try expect(
            rectangleCenter.red > rectangleCenter.blue && rectangleBorder.blue > rectangleBorder.red,
            "Expected shape fill and stroke colors to render independently; center \(rectangleCenter), border \(rectangleBorder), painted \(String(describing: paintedBounds(rectanglePixels, width: 96, height: 96)))"
        )

        let diamond = AnnotationElement(
            geometry: .shape(
                AnnotationShapeGeometry(
                    kind: .diamond,
                    start: CGPoint(x: 40, y: 8),
                    end: CGPoint(x: 72, y: 40)
                )
            ),
            style: shapeStyle
        )
        let ellipse = AnnotationElement(
            geometry: .shape(
                AnnotationShapeGeometry(
                    kind: .ellipse,
                    start: CGPoint(x: 8, y: 48),
                    end: CGPoint(x: 40, y: 80)
                )
            ),
            style: shapeStyle
        )
        let shapePixels = try renderPixels(elements: [diamond, ellipse], renderer: renderer)
        try expect(
            alpha(shapePixels, width: 96, x: 56, y: 24) > 0
                && alpha(shapePixels, width: 96, x: 24, y: 64) > 0
                && alpha(shapePixels, width: 96, x: 40, y: 8) == 0,
            "Expected diamond and ellipse paths to render their distinct filled geometry"
        )

        var dashedStyle = AnnotationStyle(color: .red, rootWidth: 4, alpha: 1)
        dashedStyle.sloppiness = .architect
        dashedStyle.strokePattern = .dashed
        let dashed = AnnotationElement.legacy(
            tool: .line,
            points: [CGPoint(x: 8, y: 16), CGPoint(x: 80, y: 16)],
            style: dashedStyle
        )
        var dottedStyle = dashedStyle
        dottedStyle.strokePattern = .dotted
        let dotted = AnnotationElement.legacy(
            tool: .line,
            points: [CGPoint(x: 8, y: 32), CGPoint(x: 80, y: 32)],
            style: dottedStyle
        )
        let patternPixels = try renderPixels(elements: [dashed, dotted], renderer: renderer)
        let dashedPaintedCount = (8..<81).filter {
            alpha(patternPixels, width: 96, x: $0, y: 16) > 0
        }.count
        try expect(
            dashedPaintedCount > 0
                && dashedPaintedCount < 73
                && paintedRuns(patternPixels, width: 96, y: 16, xRange: 8..<81) >= 2,
            "Expected dashed strokes to contain deterministic painted and empty runs"
        )
        try expect(
            paintedRuns(patternPixels, width: 96, y: 32, xRange: 8..<81) >= 5,
            "Expected dotted strokes to render repeated round marks"
        )

        let pen = AnnotationElement.legacy(
            tool: .pen,
            points: [
                CGPoint(x: 8, y: 48),
                CGPoint(x: 28, y: 42),
                CGPoint(x: 48, y: 52),
                CGPoint(x: 80, y: 48)
            ],
            style: AnnotationStyle(
                color: .green,
                rootWidth: 5,
                alpha: 1,
                sloppiness: .architect
            )
        )
        let arrow = AnnotationElement.legacy(
            tool: .arrow,
            points: [CGPoint(x: 80, y: 72), CGPoint(x: 12, y: 72)],
            style: AnnotationStyle(
                color: .blue,
                rootWidth: 4,
                alpha: 1,
                sloppiness: .architect
            )
        )
        let linearPixels = try renderPixels(elements: [pen, arrow], renderer: renderer)
        try expect(
            alpha(linearPixels, width: 96, x: 40, y: 48) > 0
                && alpha(linearPixels, width: 96, x: 78, y: 72) > 0
                && alpha(linearPixels, width: 96, x: 36, y: 72) > 0,
            "Expected smoothed pen and legacy start-anchored arrow output"
        )

        var translucentStyle = AnnotationStyle(color: .orange, rootWidth: 2, alpha: 0.25)
        translucentStyle.fillStyle = .solid
        let translucent = AnnotationElement(
            geometry: .shape(
                AnnotationShapeGeometry(
                    kind: .rectangle,
                    start: CGPoint(x: 8, y: 8),
                    end: CGPoint(x: 32, y: 32)
                )
            ),
            style: translucentStyle
        )
        let translucentPixels = try renderPixels(elements: [translucent], renderer: renderer)
        let translucentAlpha = alpha(translucentPixels, width: 96, x: 20, y: 20)
        try expect(
            (55...70).contains(translucentAlpha),
            "Expected style opacity to apply to filled geometry, got alpha \(translucentAlpha)"
        )

        var rotatedStyle = AnnotationStyle(color: .pink, rootWidth: 2, alpha: 1)
        rotatedStyle.fillStyle = .solid
        var rotated = AnnotationElement(
            geometry: .shape(
                AnnotationShapeGeometry(
                    kind: .rectangle,
                    start: CGPoint(x: 20, y: 28),
                    end: CGPoint(x: 44, y: 36)
                )
            ),
            style: rotatedStyle
        )
        rotated.metadata.rotation = .pi / 2
        let rotatedPixels = try renderPixels(elements: [rotated], renderer: renderer)
        try expect(
            alpha(rotatedPixels, width: 96, x: 32, y: 22) > 0
                && alpha(rotatedPixels, width: 96, x: 22, y: 32) == 0,
            "Expected renderer transforms to rotate shape pixels around their center"
        )

        var highlighterStyle = AnnotationStyle(color: .yellow, rootWidth: 12, alpha: 1)
        highlighterStyle.sloppiness = .architect
        highlighterStyle.pressureEnabled = false
        let highlight = AnnotationElement(
            geometry: .freehand(
                AnnotationFreehandGeometry(
                    samples: [
                        AnnotationPointSample(location: CGPoint(x: 8, y: 48), pressure: nil),
                        AnnotationPointSample(location: CGPoint(x: 80, y: 48), pressure: nil)
                    ],
                    isHighlighter: true
                )
            ),
            style: highlighterStyle
        )
        let highlightPixels = try renderPixels(elements: [highlight, highlight], renderer: renderer)
        let highlightAlpha = alpha(highlightPixels, width: 96, x: 40, y: 48)
        try expect(
            (120...135).contains(highlightAlpha),
            "Expected overlapping highlighter output to composite once, got alpha \(highlightAlpha)"
        )

        var pressureStyle = AnnotationStyle(color: .black, rootWidth: 12, alpha: 1)
        pressureStyle.sloppiness = .architect
        pressureStyle.pressureEnabled = true
        let pressureStroke = AnnotationElement(
            geometry: .freehand(
                AnnotationFreehandGeometry(
                    samples: [
                        AnnotationPointSample(location: CGPoint(x: 16, y: 72), pressure: 0.2),
                        AnnotationPointSample(location: CGPoint(x: 80, y: 72), pressure: 1)
                    ],
                    isHighlighter: false
                )
            ),
            style: pressureStyle
        )
        let pressurePixels = try renderPixels(elements: [pressureStroke], renderer: renderer)
        try expect(
            paintedVerticalSpan(pressurePixels, width: 96, height: 96, x: 75)
                > paintedVerticalSpan(pressurePixels, width: 96, height: 96, x: 20),
            "Expected pressure samples to widen the rendered freehand stroke"
        )

        let text = AnnotationElement(
            geometry: .text(
                AnnotationTextGeometry(
                    origin: CGPoint(x: 8, y: 8),
                    bounds: nil,
                    text: "T",
                    fontSize: 28,
                    fontName: "",
                    alignment: .left
                )
            ),
            style: AnnotationStyle(color: .white, rootWidth: 2, alpha: 1)
        )
        let textPixels = try renderPixels(elements: [text], renderer: renderer)
        try expect(
            textPixels.enumerated().contains { index, value in index % 4 == 3 && value > 0 },
            "Expected text rendering to modify the offscreen bitmap"
        )

        let decorationPixels = try renderPixels(
            elements: [],
            renderer: renderer,
            decorationElements: [rectangle],
            selectedElementIDs: [rectangle.id],
            zoomScale: 2
        )
        try expect(
            decorationPixels.enumerated().contains { index, value in index % 4 == 3 && value > 0 },
            "Expected selection decoration primitives to render independently from scene content"
        )
    }

    static func testPatternFillRenderingDeterminismAndOpacity() throws {
        guard let uuid = UUID(uuidString: "4A66FA7B-BB0A-4E80-9B5A-49EE9EC9BB45") else {
            throw SelfTestError.failure("Could not create deterministic pattern fill UUID")
        }

        var style = AnnotationStyle(
            color: .black,
            rootWidth: 4,
            alpha: 0.4,
            fillColor: .palette(.blue),
            fillStyle: .hachure,
            sloppiness: .architect
        )
        style.strokeColor = .rgba(red: 0, green: 0, blue: 0, alpha: 0)
        let hachure = AnnotationElement(
            id: AnnotationElementID(uuid),
            geometry: .shape(
                AnnotationShapeGeometry(
                    kind: .rectangle,
                    start: CGPoint(x: 12, y: 12),
                    end: CGPoint(x: 84, y: 84)
                )
            ),
            style: style
        )
        let renderer = AnnotationRenderer()
        let first = try renderPixels(elements: [hachure], renderer: renderer)
        let second = try renderPixels(elements: [hachure], renderer: renderer)
        try expect(
            first == second,
            "Expected seeded hachure rendering to be byte-identical across redraws"
        )

        let hachureInterior = (16..<80).flatMap { y in
            (16..<80).map { x in Int(alpha(first, width: 96, x: x, y: y)) }
        }
        let hachurePainted = hachureInterior.filter { $0 > 0 }
        try expect(
            !hachurePainted.isEmpty
                && hachurePainted.allSatisfy { (95...110).contains($0) }
                && hachureInterior.contains(0)
                && alpha(first, width: 96, x: 6, y: 6) == 0,
            "Expected clipped hachure lines to apply one consistent 40% opacity"
        )

        var roughHachure = hachure
        roughHachure.style.sloppiness = .cartoonist
        let roughHachurePixels = try renderPixels(
            elements: [roughHachure],
            renderer: renderer
        )
        let repeatedRoughHachurePixels = try renderPixels(
            elements: [roughHachure],
            renderer: renderer
        )
        let roughHachureAlpha = stride(
            from: 3,
            to: roughHachurePixels.count,
            by: 4
        ).map { roughHachurePixels[$0] }.filter { $0 > 0 }
        try expect(
            roughHachurePixels == repeatedRoughHachurePixels
                && pixelDifferenceCount(first, roughHachurePixels) >= 80
                && roughHachureAlpha.allSatisfy { (95...110).contains(Int($0)) },
            "Expected hachure strokes to use deterministic rough passes without opacity buildup"
        )

        var crossHatch = hachure
        crossHatch.style.fillStyle = .crossHatch
        let crossPixels = try renderPixels(elements: [crossHatch], renderer: renderer)
        let repeatedCrossPixels = try renderPixels(elements: [crossHatch], renderer: renderer)
        let crossInterior = (16..<80).flatMap { y in
            (16..<80).map { x in Int(alpha(crossPixels, width: 96, x: x, y: y)) }
        }
        let crossPainted = crossInterior.filter { $0 > 0 }
        try expect(
            crossPixels == repeatedCrossPixels
                && crossPixels != first
                && crossPainted.count > hachurePainted.count
                && crossPainted.allSatisfy { (95...110).contains($0) },
            "Expected cross-hatch to add a deterministic second pass without darkening intersections"
        )
    }

    static func testAnnotationSloppinessDeterminismAndEndpoints() throws {
        guard let uuid = UUID(uuidString: "2F3D3E7A-18A7-4F65-9E50-5B17C2AA0031") else {
            throw SelfTestError.failure("Could not create deterministic sloppiness test UUID")
        }
        let elementID = AnnotationElementID(uuid)
        let straight = CGMutablePath()
        straight.move(to: CGPoint(x: 8, y: 20))
        straight.addLine(to: CGPoint(x: 88, y: 34))

        for sloppiness in [AnnotationSloppiness.artist, .cartoonist] {
            let first = AnnotationRoughStroke.paths(
                for: straight,
                sloppiness: sloppiness,
                elementID: elementID,
                strokeWidth: 5
            )
            let second = AnnotationRoughStroke.paths(
                for: straight,
                sloppiness: sloppiness,
                elementID: elementID,
                strokeWidth: 5
            )
            try expect(
                first.count == 2
                    && second.count == 2
                    && zip(first, second).allSatisfy { $0 == $1 },
                "Expected seeded sloppiness paths to be identical across redraws"
            )
            let endpoints = first.compactMap(AnnotationRoughStroke.endpoints)
            try expect(
                endpoints.count == 2
                    && !approximatelyEqual(endpoints[0].start, endpoints[1].start)
                    && !approximatelyEqual(endpoints[0].end, endpoints[1].end),
                "Expected unbound rough line passes to remain independently separated at endpoints"
            )
            let pinned = AnnotationRoughStroke.paths(
                for: straight,
                sloppiness: sloppiness,
                elementID: elementID,
                strokeWidth: 5,
                pinnedPoints: [CGPoint(x: 8, y: 20), CGPoint(x: 88, y: 34)]
            )
            try expect(
                pinned.allSatisfy {
                    AnnotationRoughStroke.endpoints(of: $0)?.start == CGPoint(x: 8, y: 20)
                        && AnnotationRoughStroke.endpoints(of: $0)?.end == CGPoint(x: 88, y: 34)
                },
                "Expected explicitly pinned bindings and arrow tips to remain canonical"
            )
        }

        let precise = AnnotationRoughStroke.paths(
            for: straight,
            sloppiness: .architect,
            elementID: elementID,
            strokeWidth: 5
        )
        try expect(
            precise.count == 1 && precise[0] == straight,
            "Expected Architect sloppiness to preserve one precise path"
        )

        var style = AnnotationStyle(
            color: .blue,
            rootWidth: 5,
            alpha: 1,
            sloppiness: .cartoonist
        )
        style.lineCap = .butt
        let element = AnnotationElement(
            id: elementID,
            geometry: .linear(
                AnnotationLinearGeometry(
                    points: [CGPoint(x: 8, y: 20), CGPoint(x: 88, y: 34)],
                    route: .straight,
                    startArrowhead: .none,
                    endArrowhead: .arrow,
                    startBinding: nil,
                    endBinding: nil
                )
            ),
            style: style
        )
        let firstPixels = try renderPixels(
            elements: [element],
            renderer: AnnotationRenderer()
        )
        let secondPixels = try renderPixels(
            elements: [element],
            renderer: AnnotationRenderer()
        )
        try expect(
            firstPixels == secondPixels,
            "Expected seeded rough rendering to remain deterministic across capture redraws"
        )
        try expect(
            AnnotationHitTester.contains(
                CGPoint(x: 48, y: 27),
                in: element,
                zoomScale: 1
            ),
            "Expected rough rendering to keep canonical hit testing"
        )
    }

    static func testMeasuredRoughRenderingModel() throws {
        try expect(
            AnnotationRoughStroke.maximumDestinationDeviation(for: .architect) == 0
                && AnnotationRoughStroke.maximumDestinationDeviation(for: .artist) == 5.5
                && AnnotationRoughStroke.maximumDestinationDeviation(for: .cartoonist) == 11,
            "Expected rough-stroke deviation caps to remain defined in destination pixels"
        )
        let elementID = AnnotationElementID(
            UUID(uuidString: "6E470104-94ED-401E-A78A-FF74BE313A69")!
        )
        let duplicateID = AnnotationElementID(
            UUID(uuidString: "C140D863-BB53-4D02-B849-E79B7EEC1678")!
        )
        let line = CGMutablePath()
        line.move(to: CGPoint(x: 20, y: 40))
        line.addLine(to: CGPoint(x: 200, y: 40))

        let artist = AnnotationRoughStroke.paths(
            for: line,
            sloppiness: .artist,
            elementID: elementID,
            strokeWidth: 2
        )
        let cartoonist = AnnotationRoughStroke.paths(
            for: line,
            sloppiness: .cartoonist,
            elementID: elementID,
            strokeWidth: 2
        )
        let artistDeviation = meanHorizontalWaviness(artist)
        let cartoonistDeviation = meanHorizontalWaviness(cartoonist)
        let artistSeparation = meanPathSeparation(artist[0], artist[1])
        let cartoonistSeparation = meanPathSeparation(cartoonist[0], cartoonist[1])
        let artistMaximum = maximumHorizontalDeviation(artist, canonicalY: 40)
        let cartoonistMaximum = maximumHorizontalDeviation(cartoonist, canonicalY: 40)
        try expect(
            (1.4...1.9).contains(artistDeviation)
                && (2.3...3.1).contains(artistSeparation)
                && (1.6...2.5).contains(artistMaximum),
            "Expected audited 180px/2px Artist calibration (waviness "
                + "\(artistDeviation), separation \(artistSeparation), max "
                + "\(artistMaximum))"
        )
        try expect(
            cartoonistDeviation >= artistDeviation * 1.7,
            "Expected Cartoonist line deviation to be at least 1.7x Artist "
                + "(artist \(artistDeviation), cartoonist \(cartoonistDeviation))"
        )
        try expect(
            cartoonistSeparation >= artistSeparation * 1.6,
            "Expected Cartoonist pass separation to be at least 1.6x Artist "
                + "(artist \(artistSeparation), cartoonist \(cartoonistSeparation))"
        )
        try expect(
            artistMaximum
                <= AnnotationRoughStroke.maximumDestinationDeviation(
                    for: .artist,
                    strokeWidth: 2
                ) + 0.01
                && cartoonistMaximum
                    <= AnnotationRoughStroke.maximumDestinationDeviation(
                        for: .cartoonist,
                        strokeWidth: 2
                    ) + 0.01,
            "Expected measured rough lines to honor width-aware destination caps "
                + "(artist \(artistMaximum), cartoonist \(cartoonistMaximum))"
        )

        for strokeWidth in [CGFloat(1), 3] {
            let thinCartoonist = AnnotationRoughStroke.paths(
                for: line,
                sloppiness: .cartoonist,
                elementID: elementID,
                strokeWidth: strokeWidth
            )
            let firstPoints = AnnotationRoughStroke.sampledPoints(
                on: thinCartoonist[0],
                curveSubdivisions: 48
            )
            let secondPoints = AnnotationRoughStroke.sampledPoints(
                on: thinCartoonist[1],
                curveSubdivisions: 48
            )
            let separations = zip(firstPoints, secondPoints).map {
                hypot($0.x - $1.x, $0.y - $1.y)
            }
            let visiblySeparatedFraction = CGFloat(
                separations.filter { $0 >= 2 }.count
            ) / CGFloat(max(1, separations.count))
            let endpoints = thinCartoonist.compactMap(
                AnnotationRoughStroke.endpoints
            )
            try expect(
                visiblySeparatedFraction >= 0.35
                    && (separations.max() ?? 0) >= 4
                    && endpoints.count == 2
                    && endpoints.allSatisfy {
                        $0.start.x <= 16.1 && $0.end.x >= 203.9
                    },
                "Expected thin/normal Cartoonist traces to diverge over substantial edge portions "
                    + "with 4px+ independent overruns (width \(strokeWidth), fraction "
                    + "\(visiblySeparatedFraction), max \(separations.max() ?? 0), "
                    + "endpoints \(endpoints))"
            )
        }

        let zoomedArtist = AnnotationRoughStroke.paths(
            for: line,
            sloppiness: .artist,
            elementID: elementID,
            strokeWidth: 2,
            destinationScale: 2
        )
        let zoomedScreenDeviation = meanHorizontalDeviation(
            zoomedArtist,
            canonicalY: 40
        ) * 2
        let unzoomedScreenDeviation = meanHorizontalDeviation(
            artist,
            canonicalY: 40
        )
        try expect(
            abs(zoomedScreenDeviation - unzoomedScreenDeviation) <= 0.08,
            "Expected roughness to remain stable in destination pixels across content zoom "
                + "(1x \(unzoomedScreenDeviation), 2x \(zoomedScreenDeviation))"
        )

        let duplicate = AnnotationRoughStroke.paths(
            for: line,
            sloppiness: .artist,
            elementID: duplicateID,
            strokeWidth: 2
        )
        try expect(
            AnnotationRoughStroke.roughSeed(for: elementID)
                != AnnotationRoughStroke.roughSeed(for: duplicateID)
                && duplicate != artist,
            "Expected duplicated elements to derive distinct stable rough seeds"
        )

        let solidArtist = AnnotationStyle(
            color: .black,
            rootWidth: 2,
            alpha: 1,
            sloppiness: .artist
        )
        var dashedArtist = solidArtist
        dashedArtist.strokePattern = .dashed
        var dottedCartoonist = solidArtist
        dottedCartoonist.sloppiness = .cartoonist
        dottedCartoonist.strokePattern = .dotted
        var architect = solidArtist
        architect.sloppiness = .architect
        try expect(
            AnnotationRenderer.strokePassCount(for: architect) == 1
                && AnnotationRenderer.strokePassCount(for: solidArtist) == 2
                && AnnotationRenderer.strokePassCount(for: dashedArtist) == 2
                && AnnotationRenderer.strokePassCount(for: dottedCartoonist) == 2
                && AnnotationRenderer.strokeWidthCompensation(for: dashedArtist) == 1,
            "Expected patterned rough strokes to keep independent passes without widening"
        )

        let rectangle = CGMutablePath()
        rectangle.addRect(CGRect(x: 20, y: 20, width: 180, height: 60))
        let artistRectangle = AnnotationRoughStroke.paths(
            for: rectangle,
            sloppiness: .artist,
            elementID: elementID,
            strokeWidth: 2,
            independentClosedCorners: true
        )
        let cartoonistRectangle = AnnotationRoughStroke.paths(
            for: rectangle,
            sloppiness: .cartoonist,
            elementID: elementID,
            strokeWidth: 2,
            independentClosedCorners: true
        )
        try expect(
            artistRectangle.allSatisfy {
                AnnotationRoughStroke.pathMoveCount($0) == 4
            }
                && cartoonistRectangle.allSatisfy {
                    AnnotationRoughStroke.pathMoveCount($0) == 4
                }
                && artistRectangle[0] != artistRectangle[1]
                && cartoonistRectangle[0] != cartoonistRectangle[1],
            "Expected Artist and Cartoonist sides and passes to sample independent corners"
        )

        let crossingCount = (0..<12).filter { salt in
            let independentPaths = AnnotationRoughStroke.paths(
                for: line,
                sloppiness: .cartoonist,
                elementID: elementID,
                strokeWidth: 2,
                salt: UInt64(salt)
            )
            let differences = zip(
                AnnotationRoughStroke.sampledPoints(
                    on: independentPaths[0],
                    curveSubdivisions: 24
                ),
                AnnotationRoughStroke.sampledPoints(
                    on: independentPaths[1],
                    curveSubdivisions: 24
                )
            ).map { $0.y - $1.y }
            return differences.contains { $0 > 0.1 }
                && differences.contains { $0 < -0.1 }
        }.count
        try expect(
            crossingCount >= 4,
            "Expected independently seeded Cartoonist passes to cross instead of forming systematic rails"
        )

        for length in [CGFloat(60), 180, 400] {
            let calibrationLine = CGMutablePath()
            calibrationLine.move(to: CGPoint(x: 20, y: 40))
            calibrationLine.addLine(to: CGPoint(x: 20 + length, y: 40))
            let paths = AnnotationRoughStroke.paths(
                for: calibrationLine,
                sloppiness: .cartoonist,
                elementID: elementID,
                strokeWidth: 2
            )
            let firstPoints = AnnotationRoughStroke.sampledPoints(
                on: paths[0],
                curveSubdivisions: 48
            )
            let secondPoints = AnnotationRoughStroke.sampledPoints(
                on: paths[1],
                curveSubdivisions: 48
            )
            let separations = zip(firstPoints, secondPoints).map {
                hypot($0.x - $1.x, $0.y - $1.y)
            }
            let resolvedSeparations = separations.filter { $0 >= 2.25 }
            let resolvedFraction = CGFloat(
                resolvedSeparations.count
            ) / CGFloat(max(1, separations.count))
            let separation = resolvedSeparations.isEmpty
                ? separations.max() ?? 0
                : resolvedSeparations.reduce(0, +)
                    / CGFloat(resolvedSeparations.count)
            let waviness = meanHorizontalDeviation(paths, canonicalY: 40)
            try expect(
                resolvedFraction >= 0.55
                    && (2.5...10).contains(separation)
                    && (1.2...8).contains(waviness),
                "Expected deliberately strong Cartoonist variation across substantial portions at "
                    + "\(length)px (fraction \(resolvedFraction), separation "
                    + "\(separation), waviness \(waviness))"
            )
        }

        let smallEllipse = CGRect(x: 10, y: 10, width: 60, height: 60)
        let wideEllipse = CGRect(x: 10, y: 10, width: 400, height: 60)
        let ellipsePaths = AnnotationRoughStroke.ellipsePaths(
            in: smallEllipse,
            sloppiness: .cartoonist,
            elementID: elementID,
            strokeWidth: 2
        )
        let smallSampleCount = AnnotationRoughStroke.ellipseSampleCount(
            in: smallEllipse,
            destinationScale: 1
        )
        let wideSampleCount = AnnotationRoughStroke.ellipseSampleCount(
            in: wideEllipse,
            destinationScale: 1
        )
        try expect(
            ellipsePaths.count == 2
                && smallSampleCount >= 9
                && wideSampleCount > smallSampleCount
                && ellipsePaths.allSatisfy {
                    AnnotationRoughStroke.pathElementCount($0) >= smallSampleCount + 2
                },
            "Expected adaptively sampled rough ellipses with at least nine perimeter samples"
        )

        let pressureSamples = (0..<1_200).map { index in
            AnnotationPointSample(
                location: CGPoint(
                    x: CGFloat(index) * 0.35,
                    y: 80 + sin(CGFloat(index) * 0.025) * 8
                ),
                pressure: 0.25 + CGFloat(index % 17) / 24
            )
        }
        let pressurePaths = AnnotationRoughStroke.pressurePaths(
            samples: pressureSamples,
            baseWidth: 8,
            sloppiness: .cartoonist,
            elementID: elementID,
            salt: 0x5052_4553_5355_5245,
            destinationScale: 1
        )
        try expect(
            pressurePaths.count == 2
                && pressurePaths.allSatisfy {
                    AnnotationRoughStroke.pathElementCount($0)
                        <= pressureSamples.count * 2 + 5
                },
            "Expected pressure rendering to stay O(n) with two bounded fill operations"
        )

        let pressurePrefix = Array(pressureSamples.prefix(320))
        let pressureExtended = Array(pressureSamples.prefix(760))
        let prefixPaths = AnnotationRoughStroke.pressurePaths(
            samples: pressurePrefix,
            baseWidth: 8,
            sloppiness: .artist,
            elementID: elementID,
            salt: 0x5052_4546_4958_5354,
            destinationScale: 1
        )
        let extendedPaths = AnnotationRoughStroke.pressurePaths(
            samples: pressureExtended,
            baseWidth: 8,
            sloppiness: .artist,
            elementID: elementID,
            salt: 0x5052_4546_4958_5354,
            destinationScale: 1
        )
        let stablePrefixCount = pressurePrefix.count - 2
        try expect(
            zip(prefixPaths, extendedPaths).allSatisfy { pair in
                let prefixPoints = AnnotationRoughStroke.sampledPoints(
                    on: pair.0,
                    curveSubdivisions: 2
                )
                let extendedPoints = AnnotationRoughStroke.sampledPoints(
                    on: pair.1,
                    curveSubdivisions: 2
                )
                return zip(
                    prefixPoints.prefix(stablePrefixCount),
                    extendedPoints.prefix(stablePrefixCount)
                ).allSatisfy {
                    hypot($1.x - $0.x, $1.y - $0.y) <= 0.000_001
                }
            },
            "Expected absolute-arc-length roughness to keep finalized pressure-stroke prefixes stable"
        )

        var arrowStyle = AnnotationStyle(
            color: .black,
            rootWidth: 4,
            alpha: 1,
            strokePattern: .dashed,
            sloppiness: .cartoonist
        )
        arrowStyle.lineCap = .butt
        let arrow = AnnotationElement(
            id: elementID,
            geometry: .linear(
                AnnotationLinearGeometry(
                    points: [CGPoint(x: 12, y: 48), CGPoint(x: 84, y: 48)],
                    route: .straight,
                    startArrowhead: .none,
                    endArrowhead: .triangle,
                    startBinding: nil,
                    endBinding: nil
                )
            ),
            style: arrowStyle
        )
        var preciseArrow = arrow
        preciseArrow.style.sloppiness = .architect
        let roughArrowPixels = try renderPixels(
            elements: [arrow],
            renderer: AnnotationRenderer()
        )
        let preciseArrowPixels = try renderPixels(
            elements: [preciseArrow],
            renderer: AnnotationRenderer()
        )
        let headDifference = pixelDifferenceCount(
            roughArrowPixels,
            preciseArrowPixels,
            width: 96,
            xRange: 68..<92,
            yRange: 34..<63
        )
        let roughArrowCenterAlpha = alpha(
            roughArrowPixels,
            width: 96,
            x: 76,
            y: 48
        )
        let roughArrowHasTip = hasPaintedPixel(
            roughArrowPixels,
            width: 96,
            height: 96,
            near: CGPoint(x: 84, y: 48),
            radius: 1
        )
        try expect(
            headDifference >= 20
                && roughArrowCenterAlpha > 0
                && roughArrowHasTip,
            "Expected capped rough arrowhead variation, a solid filled head, and a preserved tip"
                + " (difference \(headDifference), center alpha "
                + "\(roughArrowCenterAlpha), tip \(roughArrowHasTip))"
        )
    }

    static func testRoughRasterMatrixAndSelectionClearance() throws {
        let elementID = AnnotationElementID(
            UUID(uuidString: "E03C4804-BC51-4F0A-9BED-8E14C1B2F2A7")!
        )
        let patterns: [AnnotationStrokePattern] = [.solid, .dashed, .dotted]
        let sloppinessValues: [AnnotationSloppiness] = [
            .architect, .artist, .cartoonist
        ]

        for strokeWidth in [CGFloat(1), 3, 6] {
            for pattern in patterns {
                var normalizedBoundsBySloppiness:
                    [AnnotationSloppiness: CGRect] = [:]
                for backingScale in [1, 2] {
                    var pixelsBySloppiness:
                        [AnnotationSloppiness: [UInt8]] = [:]
                    var comparisonPixelsBySloppiness:
                        [AnnotationSloppiness: [UInt8]] = [:]
                    var boundsBySloppiness:
                        [AnnotationSloppiness: CGRect] = [:]
                    for sloppiness in sloppinessValues {
                        var style = AnnotationStyle(
                            color: .black,
                            rootWidth: strokeWidth,
                            alpha: 1,
                            strokePattern: pattern,
                            sloppiness: sloppiness
                        )
                        style.lineCap = .butt
                        style.lineJoin = .miter
                        let element = AnnotationElement(
                            id: elementID,
                            geometry: .shape(
                                AnnotationShapeGeometry(
                                    kind: .rectangle,
                                    start: CGPoint(x: 20, y: 20),
                                    end: CGPoint(x: 76, y: 60)
                                )
                            ),
                            style: style
                        )
                        let pixels = try renderPixels(
                            elements: [element],
                            renderer: AnnotationRenderer(),
                            width: 96,
                            height: 80,
                            backingScale: backingScale
                        )
                        guard let bounds = paintedBounds(
                            pixels,
                            width: 96 * backingScale,
                            height: 80 * backingScale
                        ) else {
                            throw SelfTestError.failure(
                                "Expected \(sloppiness) \(pattern) raster at width \(strokeWidth)"
                            )
                        }
                        pixelsBySloppiness[sloppiness] = pixels
                        var comparisonElement = element
                        comparisonElement.geometry = .shape(
                            AnnotationShapeGeometry(
                                kind: .rectangle,
                                start: CGPoint(x: 40, y: 34),
                                end: CGPoint(x: 56, y: 46)
                            )
                        )
                        comparisonElement.style.fillStyle = .solid
                        comparisonElement.style.fillColor = .palette(.black)
                        comparisonElement.style.strokePattern = .solid
                        comparisonElement.style.strokeWidth = 1
                        comparisonPixelsBySloppiness[sloppiness] =
                            try renderPixels(
                                elements: [comparisonElement],
                                renderer: AnnotationRenderer(),
                                width: 96,
                                height: 80,
                                backingScale: backingScale
                            )
                        boundsBySloppiness[sloppiness] = bounds
                        let normalized = CGRect(
                            x: bounds.minX / CGFloat(backingScale),
                            y: bounds.minY / CGFloat(backingScale),
                            width: bounds.width / CGFloat(backingScale),
                            height: bounds.height / CGFloat(backingScale)
                        )
                        if backingScale == 1 {
                            normalizedBoundsBySloppiness[sloppiness] = normalized
                        } else if let reference = normalizedBoundsBySloppiness[sloppiness] {
                            try expect(
                                abs(normalized.minX - reference.minX) <= 6
                                    && abs(normalized.minY - reference.minY) <= 6
                                    && abs(normalized.width - reference.width) <= 6
                                    && abs(normalized.height - reference.height) <= 6,
                                "Expected logical rough silhouettes to remain stable at 1x/2x backing scale "
                                    + "(\(pattern), \(sloppiness), width \(strokeWidth), "
                                    + "1x \(reference), 2x \(normalized))"
                            )
                        }

                        let selectedPixels = try renderPixels(
                            elements: [element],
                            renderer: AnnotationRenderer(),
                            decorationElements: [element],
                            selectedElementIDs: [element.id],
                            zoomScale: 1,
                            width: 96,
                            height: 80,
                            backingScale: backingScale
                        )
                        try expect(
                            paintedPixelCount(selectedPixels)
                                >= paintedPixelCount(pixels),
                            "Expected selection chrome not to mask \(sloppiness) rough pixels"
                        )

                        guard let decoration = AnnotationGeometry.selectionDecoration(
                            for: element,
                            zoomScale: 1
                        ) else {
                            throw SelfTestError.failure(
                                "Expected selection decoration for rough raster matrix"
                            )
                        }
                        let outlineBounds = CGRect(
                            origin: CGPoint(
                                x: decoration.outline.map(\.x).min() ?? 0,
                                y: decoration.outline.map(\.y).min() ?? 0
                            ),
                            size: CGSize(
                                width: (decoration.outline.map(\.x).max() ?? 0)
                                    - (decoration.outline.map(\.x).min() ?? 0),
                                height: (decoration.outline.map(\.y).max() ?? 0)
                                    - (decoration.outline.map(\.y).min() ?? 0)
                            )
                        )
                        let requiredClearance = strokeWidth / 2
                            + AnnotationRoughStroke.maximumDestinationDeviation(
                                for: sloppiness,
                                strokeWidth: strokeWidth
                            )
                        try expect(
                            outlineBounds.minX
                                <= 20 - requiredClearance - 1.9
                                && outlineBounds.maxX
                                    >= 76 + requiredClearance + 1.9,
                            "Expected selection chrome outside stroke and maximum rough deviation"
                        )
                    }

                    guard let architectBounds = boundsBySloppiness[.architect],
                          let artistBounds = boundsBySloppiness[.artist],
                          let cartoonistBounds = boundsBySloppiness[.cartoonist],
                          let architectPixels =
                            comparisonPixelsBySloppiness[.architect],
                          let comparisonArtistPixels =
                            comparisonPixelsBySloppiness[.artist],
                          let comparisonCartoonistPixels =
                            comparisonPixelsBySloppiness[.cartoonist],
                          let cartoonistPixels = pixelsBySloppiness[.cartoonist] else {
                        throw SelfTestError.failure(
                            "Expected complete rough raster matrix"
                        )
                    }
                    let artistDifferenceRatio = alphaMaskSymmetricDifferenceRatio(
                        architectPixels,
                        comparisonArtistPixels
                    )
                    let cartoonistDifferenceRatio =
                        alphaMaskSymmetricDifferenceRatio(
                            architectPixels,
                            comparisonCartoonistPixels
                        )
                    let calibrationContext =
                        "\(pattern), width \(strokeWidth), backing "
                        + "\(backingScale)x, artist \(artistDifferenceRatio), "
                        + "cartoonist \(cartoonistDifferenceRatio), bounds "
                        + "\(architectBounds)/\(artistBounds)/\(cartoonistBounds)"
                    try expect(
                        (0.08...0.35).contains(artistDifferenceRatio)
                            && cartoonistDifferenceRatio
                                >= artistDifferenceRatio * 1.5,
                        "Expected calibrated Artist/Cartoonist alpha-mask separation "
                            + "(\(calibrationContext))"
                    )

                    if pattern != .solid {
                        let physicalWidth = 96 * backingScale
                        let maximumRuns = (10 * backingScale..<70 * backingScale)
                            .map {
                                paintedRuns(
                                    cartoonistPixels,
                                    width: physicalWidth,
                                    y: $0,
                                    xRange: 8 * backingScale..<88 * backingScale
                                )
                            }
                            .max() ?? 0
                        try expect(
                            maximumRuns >= 2,
                            "Expected patterned rough strokes to retain visible dash/dot separation "
                                + "(\(pattern), width \(strokeWidth), scale \(backingScale), "
                                + "runs \(maximumRuns))"
                        )
                    }
                }
            }
        }

        for route in [AnnotationLinearRoute.straight, .curved] {
            let geometry = AnnotationLinearGeometry(
                points: [
                    CGPoint(x: 16, y: 40),
                    CGPoint(x: 204, y: 40)
                ],
                route: route,
                startArrowhead: .none,
                endArrowhead: .none,
                startBinding: nil,
                endBinding: nil,
                bezierControls: route == .curved
                    ? [
                        AnnotationBezierControl(
                            start: CGPoint(x: 70, y: 12),
                            end: CGPoint(x: 150, y: 68)
                        )
                    ]
                    : []
            )
            for backingScale in [1, 2] {
                var renders: [AnnotationSloppiness: [UInt8]] = [:]
                for sloppiness in sloppinessValues {
                    var style = AnnotationStyle(
                        color: .black,
                        rootWidth: 3,
                        alpha: 1,
                        sloppiness: sloppiness
                    )
                    style.lineCap = .round
                    let element = AnnotationElement(
                        id: elementID,
                        geometry: .linear(geometry),
                        style: style
                    )
                    renders[sloppiness] = try renderPixels(
                        elements: [element],
                        renderer: AnnotationRenderer(),
                        width: 220,
                        height: 80,
                        backingScale: backingScale
                    )
                }
                try expect(
                    renders[.architect] == renders[.artist]
                        && renders[.architect] == renders[.cartoonist],
                    "Expected \(route) headless Line raster bytes to ignore stored "
                        + "sloppiness at backing \(backingScale)x"
                )
            }
        }

        let lineController = AnnotationController()
        lineController.currentTool = .rectangle
        lineController.setSloppiness(.cartoonist)
        lineController.currentTool = .line
        lineController.setSloppiness(.artist)
        try expect(
            lineController.currentStyle.sloppiness == .architect
                && lineController.drawingDefaultsOutlinedSloppiness
                    == .cartoonist,
            "Expected active Line defaults to ignore sloppiness changes without "
                + "overwriting the shared shape/Arrow scope"
        )

        var storedRoughStyle = AnnotationStyle.default
        storedRoughStyle.sloppiness = .cartoonist
        let storedHeadless = AnnotationElement(
            geometry: .linear(
                AnnotationLinearGeometry(
                    points: [
                        CGPoint(x: 16, y: 40),
                        CGPoint(x: 92, y: 40)
                    ],
                    route: .straight,
                    startArrowhead: .none,
                    endArrowhead: .none,
                    startBinding: nil,
                    endBinding: nil
                )
            ),
            style: storedRoughStyle
        )
        let selectedLineController = AnnotationController(
            elements: [storedHeadless]
        )
        selectedLineController.currentTool = .select
        selectedLineController.selectAll()
        let selectedLineState = DrawingToolbarState(
            annotationController: selectedLineController
        )
        selectedLineController.setSloppiness(.artist)
        try expect(
            selectedLineState.sloppiness == .unavailable
                && !selectedLineState.supportsSloppiness
                && !selectedLineState.visibleInspectorSections.contains(
                    .sloppiness
                )
                && selectedLineController.elementSnapshot[0].style.sloppiness
                    == .cartoonist,
            "Expected selected headless Lines to hide and reject sloppiness "
                + "mutations while preserving legacy stored values"
        )
        selectedLineController.setLinearEndArrowhead(.triangle)
        let selectedArrowState = DrawingToolbarState(
            annotationController: selectedLineController
        )
        selectedLineController.setSloppiness(.artist)
        var preciseArrow = selectedLineController.elementSnapshot[0]
        preciseArrow.style.sloppiness = .architect
        let restoredRoughArrow = selectedLineController.elementSnapshot[0]
        let roughArrowPixels = try renderPixels(
            elements: [restoredRoughArrow],
            renderer: AnnotationRenderer()
        )
        let preciseArrowPixels = try renderPixels(
            elements: [preciseArrow],
            renderer: AnnotationRenderer()
        )
        try expect(
            selectedArrowState.supportsSloppiness
                && selectedArrowState.visibleInspectorSections.contains(
                    .sloppiness
                )
                && restoredRoughArrow.style.sloppiness == .artist
                && roughArrowPixels != preciseArrowPixels,
            "Expected adding an arrowhead to restore Arrow roughness scope"
        )

        var lineDefaults = DrawingDefaults.default
        lineDefaults.selectTool(.line)
        lineDefaults.setSloppinessForSelectedTool(.cartoonist)
        try expect(
            lineDefaults.sloppiness == .architect
                && lineDefaults.outlinedSloppiness == .artist,
            "Expected default Line settings to stay Architect without mutating "
                + "shape/Arrow sloppiness"
        )
    }

    static func testAnnotationSloppinessOpacityAndFamilies() throws {
        guard let uuid = UUID(uuidString: "E4EB5377-5E30-43ED-B058-B56EE5400E92") else {
            throw SelfTestError.failure("Could not create sloppiness family test UUID")
        }
        let elementID = AnnotationElementID(uuid)
        var baseStyle = AnnotationStyle(
            color: .black,
            rootWidth: 4,
            alpha: 1,
            sloppiness: .artist
        )
        baseStyle.lineCap = .butt

        let families: [AnnotationElement] = [
            AnnotationElement(
                id: elementID,
                geometry: .shape(
                    AnnotationShapeGeometry(
                        kind: .rectangle,
                        start: CGPoint(x: 8, y: 8),
                        end: CGPoint(x: 38, y: 30)
                    )
                ),
                style: baseStyle
            ),
            AnnotationElement(
                id: AnnotationElementID(
                    UUID(uuidString: "C9EA20A1-D484-4964-B119-A8C5575F351E")!
                ),
                geometry: .shape(
                    AnnotationShapeGeometry(
                        kind: .diamond,
                        start: CGPoint(x: 48, y: 8),
                        end: CGPoint(x: 78, y: 34)
                    )
                ),
                style: baseStyle
            ),
            AnnotationElement(
                id: AnnotationElementID(
                    UUID(uuidString: "A4569306-4F90-459B-886C-10AE4B2A255B")!
                ),
                geometry: .shape(
                    AnnotationShapeGeometry(
                        kind: .ellipse,
                        start: CGPoint(x: 88, y: 8),
                        end: CGPoint(x: 120, y: 34)
                    )
                ),
                style: baseStyle
            ),
            AnnotationElement.legacy(
                id: AnnotationElementID(
                    UUID(uuidString: "A77953DA-0121-496D-B272-F127DCD362DA")!
                ),
                tool: .pen,
                points: [
                    CGPoint(x: 8, y: 52),
                    CGPoint(x: 34, y: 44),
                    CGPoint(x: 62, y: 56)
                ],
                style: baseStyle
            ),
            AnnotationElement(
                id: AnnotationElementID(
                    UUID(uuidString: "52C568B1-7650-4860-BAAE-72339D888981")!
                ),
                geometry: .linear(
                    AnnotationLinearGeometry(
                        points: [
                            CGPoint(x: 72, y: 50),
                            CGPoint(x: 96, y: 42),
                            CGPoint(x: 120, y: 56)
                        ],
                        route: .curved,
                        startArrowhead: .none,
                        endArrowhead: .arrow,
                        startBinding: nil,
                        endBinding: nil
                    )
                ),
                style: baseStyle
            ),
            AnnotationElement(
                id: AnnotationElementID(
                    UUID(uuidString: "A9B01865-1F8E-4090-9FD7-BBC540B8C985")!
                ),
                geometry: .linear(
                    AnnotationLinearGeometry(
                        points: [
                            CGPoint(x: 8, y: 82),
                            CGPoint(x: 38, y: 82),
                            CGPoint(x: 38, y: 110),
                            CGPoint(x: 68, y: 110)
                        ],
                        route: .straight,
                        startArrowhead: .none,
                        endArrowhead: .none,
                        startBinding: nil,
                        endBinding: nil
                    )
                ),
                style: baseStyle
            )
        ]

        let renderer = AnnotationRenderer()
        let artistPixels = try renderPixels(
            elements: families,
            renderer: renderer,
            width: 128,
            height: 128
        )
        let repeatedArtistPixels = try renderPixels(
            elements: families,
            renderer: renderer,
            width: 128,
            height: 128
        )
        let architectPixels = try renderPixels(
            elements: families.map {
                var element = $0
                element.style.sloppiness = .architect
                return element
            },
            renderer: renderer,
            width: 128,
            height: 128
        )
        let cartoonistPixels = try renderPixels(
            elements: families.map {
                var element = $0
                element.style.sloppiness = .cartoonist
                return element
            },
            renderer: renderer,
            width: 128,
            height: 128
        )
        try expect(
            artistPixels == repeatedArtistPixels
                && architectPixels != artistPixels
                && artistPixels != cartoonistPixels,
            "Expected Architect, Artist, and Cartoonist to render stable, visibly distinct paths "
                + "across shapes, freehand, curves, and arrows"
        )

        let calibrationID = AnnotationElementID(
            UUID(uuidString: "EB9579CB-F84E-42B5-B64D-EEBB8E3715DE")!
        )
        let calibrationShape = AnnotationShapeGeometry(
            kind: .rectangle,
            start: CGPoint(x: 24, y: 24),
            end: CGPoint(x: 72, y: 72)
        )
        func calibrationElement(_ sloppiness: AnnotationSloppiness) -> AnnotationElement {
            AnnotationElement(
                id: calibrationID,
                geometry: .shape(calibrationShape),
                style: AnnotationStyle(
                    color: .black,
                    rootWidth: 3,
                    alpha: 1,
                    sloppiness: sloppiness
                )
            )
        }
        let calibrationArchitect = try renderPixels(
            elements: [calibrationElement(.architect)],
            renderer: renderer
        )
        let calibrationArtist = try renderPixels(
            elements: [calibrationElement(.artist)],
            renderer: renderer
        )
        let calibrationCartoonist = try renderPixels(
            elements: [calibrationElement(.cartoonist)],
            renderer: renderer
        )
        let artistDifference = pixelDifferenceCount(
            calibrationArchitect,
            calibrationArtist
        )
        let cartoonistDifference = pixelDifferenceCount(
            calibrationArchitect,
            calibrationCartoonist
        )
        guard let cartoonistBounds = paintedBounds(
            calibrationCartoonist,
            width: 96,
            height: 96
        ) else {
            throw SelfTestError.failure("Expected calibrated Cartoonist shape pixels")
        }
        try expect(
            cartoonistDifference >= 80
                && cartoonistDifference > artistDifference
                && cartoonistBounds.minX >= 14
                && cartoonistBounds.minY >= 14
                && cartoonistBounds.maxX <= 82
                && cartoonistBounds.maxY <= 82,
            "Expected clearly separated Artist/Cartoonist shape strokes without excessive overshoot "
                + "(artist \(artistDifference), cartoonist \(cartoonistDifference), "
                + "bounds \(cartoonistBounds))"
        )

        var translucentStyle = baseStyle
        translucentStyle.opacity = 0.25
        let translucentLine = AnnotationElement.legacy(
            id: AnnotationElementID(
                UUID(uuidString: "11B42796-8E2D-410B-BE5C-3DB4C34FABE0")!
            ),
            tool: .line,
            points: [CGPoint(x: 8, y: 24), CGPoint(x: 88, y: 24)],
            style: translucentStyle
        )
        let translucentPixels = try renderPixels(
            elements: [translucentLine],
            renderer: renderer
        )
        let maximumAlpha = stride(from: 3, to: translucentPixels.count, by: 4)
            .map { translucentPixels[$0] }
            .max() ?? 0
        try expect(
            (55...70).contains(maximumAlpha),
            "Expected rough double strokes to apply opacity once, got alpha \(maximumAlpha)"
        )

        var highlighterStyle = baseStyle
        highlighterStyle.strokeWidth = 14
        highlighterStyle.sloppiness = .cartoonist
        let highlighter = AnnotationElement(
            id: AnnotationElementID(
                UUID(uuidString: "9ED05BC7-E650-467D-AF79-C21EB7DBB88B")!
            ),
            geometry: .freehand(
                AnnotationFreehandGeometry(
                    samples: [
                        AnnotationPointSample(
                            location: CGPoint(x: 8, y: 56),
                            pressure: nil
                        ),
                        AnnotationPointSample(
                            location: CGPoint(x: 88, y: 56),
                            pressure: nil
                        )
                    ],
                    isHighlighter: true
                )
            ),
            style: highlighterStyle
        )
        let highlighterPixels = try renderPixels(
            elements: [highlighter, highlighter],
            renderer: renderer
        )
        try expect(
            (120...135).contains(alpha(highlighterPixels, width: 96, x: 48, y: 56)),
            "Expected rough legacy highlighter passes to retain non-darkening compositing"
        )
    }
}
