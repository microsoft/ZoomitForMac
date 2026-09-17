import AppKit

extension SelfTestRunner {
    static func testDrawingToolbarStateMapping() throws {
        let controller = AnnotationController()
        controller.currentTool = .rectangle
        controller.setStrokeColor(.palette(.blue))
        controller.setFillStyle(.solid)
        controller.setFillColor(.palette(.yellow))
        controller.setStrokeWidth(6)
        controller.setSloppiness(.cartoonist)

        let idle = DrawingToolbarState(annotationController: controller)
        try expect(idle.currentTool == .rectangle, "Expected toolbar to mirror the current tool")
        try expect(idle.strokeColor == .value(.palette(.blue)), "Expected toolbar to mirror stroke color")
        try expect(idle.fillStyle == .value(.solid), "Expected toolbar to mirror fill mode")
        try expect(idle.strokeWidth == .value(6), "Expected toolbar to mirror stroke width")
        try expect(
            idle.sloppiness == .value(.cartoonist),
            "Expected toolbar to mirror the current sloppiness"
        )
        try expect(idle.supportsFill && idle.supportsRoundness, "Expected rectangle style capabilities")
        try expect(
            idle.visibleInspectorSections == [
                .strokeColor,
                .background,
                .fill,
                .strokeWidth,
                .strokeStyle,
                .sloppiness,
                .edges,
                .opacity,
                .layers
            ],
            "Expected a filled rectangle to insert Fill after Background"
        )

        let matrixController = AnnotationController()
        matrixController.setShapeBackground(nil)
        let exactToolMatrices: [(AnnotationTool, [DrawingInspectorSection])] = [
            (.hand, []),
            (.select, []),
            (
                .rectangle,
                [
                    .strokeColor, .background, .strokeWidth, .strokeStyle,
                    .sloppiness, .edges, .opacity, .layers
                ]
            ),
            (
                .diamond,
                [
                    .strokeColor, .background, .strokeWidth, .strokeStyle,
                    .sloppiness, .edges, .opacity, .layers
                ]
            ),
            (
                .ellipse,
                [
                    .strokeColor, .background, .strokeWidth, .strokeStyle,
                    .sloppiness, .opacity, .layers
                ]
            ),
            (
                .arrow,
                [
                    .strokeColor, .strokeWidth, .strokeStyle, .sloppiness,
                    .arrowType, .arrowheads, .arrowheadSize, .opacity, .layers
                ]
            ),
            (
                .line,
                [
                    .strokeColor, .strokeWidth, .strokeStyle, .edges,
                    .opacity, .layers
                ]
            ),
            (.pen, [.strokeColor, .strokeWidth, .smartDraw, .pressure, .opacity]),
            (.highlighter, [.strokeColor, .strokeWidth, .opacity]),
            (
                .text,
                [.strokeColor, .textFont, .textSize, .textAlignment, .opacity, .layers]
            ),
            (.eraser, [])
        ]
        for (tool, expectedSections) in exactToolMatrices {
            matrixController.currentTool = tool
            try expect(
                DrawingToolbarState(annotationController: matrixController)
                    .visibleInspectorSections == expectedSections,
                "Expected exact compact inspector matrix for \(tool)"
            )
        }
        matrixController.currentTool = .rectangle
        matrixController.setShapeBackground(.palette(.pink))
        try expect(
            matrixController.currentStyle.fillColor == .palette(.pink)
                && matrixController.currentStyle.fillStyle == .hachure,
            "Expected a nontransparent Background choice to become immediately visible"
        )
        matrixController.setShapeBackground(nil)
        try expect(
            matrixController.currentStyle.fillStyle == .none,
            "Expected Transparent Background to hide shape fill"
        )
        matrixController.currentTool = .diamond
        matrixController.setEdgeStyle(.round)
        try expect(
            matrixController.currentStyle.roundness == 20
                && DrawingToolbarState(annotationController: matrixController).edgeStyle
                    == .value(.round),
            "Expected Round edges to affect rectangle and diamond geometry"
        )
        let lineEdgeController = AnnotationController()
        lineEdgeController.currentTool = .line
        lineEdgeController.setEdgeStyle(.round)
        try expect(
            lineEdgeController.currentLinearRoute == .curved
                && lineEdgeController.currentStyle.roundness == nil
                && DrawingToolbarState(annotationController: lineEdgeController).edgeStyle
                    == .value(.round),
            "Expected Line Round edges to map to the supported curved linear behavior"
        )

        controller.currentTool = .pen
        controller.setPressureMode(.simulated)
        controller.setSmartDrawEnabled(true)
        try expect(
            DrawingToolbarState(annotationController: controller).visibleInspectorSections
                == [
                    .strokeColor,
                    .strokeWidth,
                    .smartDraw,
                    .opacity
                ],
            "Expected Smart Draw to replace Pressure with the Pen wand control"
        )
        try expect(
            DrawingToolbarState(annotationController: controller).smartDrawEnabled
                && DrawingToolbarState(annotationController: controller).supportsSmartDraw
                && DrawingToolbarState(annotationController: controller).pressureMode
                    == .value(.fixed)
                && DrawingToolbarState(annotationController: controller)
                    .preferredVariablePressureMode == .simulated
                && DrawingToolbarState(annotationController: controller).smartDrawStatusText
                    == "Ready for a shape",
            "Expected Smart Draw to expose an on-state while preserving the prior pressure mode"
        )
        controller.begin(
            at: CGPoint(x: 10, y: 10),
            pressure: 0.8,
            timestamp: 0,
            zoomScale: 1
        )
        guard case .freehand(let smartFreehand) =
            controller.inProgressElementSnapshot?.geometry else {
            throw SelfTestError.failure("Expected an active Smart Draw Pen stroke")
        }
        try expect(
            smartFreehand.samples.allSatisfy { $0.pressure == nil },
            "Expected Smart Draw to expose fixed-pressure samples even for tablet input"
        )
        controller.clear()
        controller.setSmartDrawEnabled(false)
        try expect(
            DrawingToolbarState(annotationController: controller).visibleInspectorSections
                == [.strokeColor, .strokeWidth, .smartDraw, .pressure, .opacity]
                && controller.currentStyle.pressureMode == .simulated,
            "Expected disabling Smart Draw to restore Pen pressure and its inspector section"
        )
        controller.currentTool = .line
        let lineToolState = DrawingToolbarState(annotationController: controller)
        try expect(
            lineToolState.visibleInspectorSections == [
                .strokeColor,
                .strokeWidth,
                .strokeStyle,
                .edges,
                .opacity,
                .layers
            ],
            "Expected Line to expose supported open-linear controls without fill"
        )
        controller.begin(at: .zero, tool: .line)
        controller.beginLinearConstructionFromClick(at: .zero, zoomScale: 1)
        let pendingLineState = DrawingToolbarState(annotationController: controller)
        _ = controller.commitLinearConstructionPoint(
            at: CGPoint(x: 40, y: 0),
            zoomScale: 1
        )
        let finishableLineState = DrawingToolbarState(annotationController: controller)
        try expect(
            pendingLineState.isConstructingLinearPath
                && !pendingLineState.canFinishLinearPath
                && finishableLineState.canFinishLinearPath,
            "Expected toolbar state to expose Finish Path and Cancel Path during construction"
        )
        controller.cancelLinearConstruction()
        let sizeStateController = AnnotationController()
        sizeStateController.currentTool = .line
        sizeStateController.setLinearArrowheadSize(.small)
        sizeStateController.begin(at: CGPoint(x: 0, y: 0), tool: .line)
        sizeStateController.end(at: CGPoint(x: 60, y: 0))
        sizeStateController.setLinearArrowheadSize(.large)
        sizeStateController.begin(at: CGPoint(x: 0, y: 20), tool: .line)
        sizeStateController.end(at: CGPoint(x: 60, y: 20))
        sizeStateController.currentTool = .select
        sizeStateController.selectAll()
        let mixedSizeState = DrawingToolbarState(
            annotationController: sizeStateController
        )
        try expect(
            mixedSizeState.arrowheadSize == .mixed
                && mixedSizeState.visibleInspectorSections.contains(.edges)
                && mixedSizeState.visibleInspectorSections.contains(.arrowheads)
                && mixedSizeState.visibleInspectorSections.contains(.arrowheadSize),
            "Expected selected Line elements to retain route and endpoint controls"
        )
        sizeStateController.toggleSelectionLock()
        try expect(
            DrawingToolbarState(annotationController: sizeStateController)
                .arrowheadSize == .unavailable,
            "Expected arrowhead size to become unavailable for a fully locked selection"
        )
        let mixedLine = AnnotationElement(
            geometry: .linear(
                AnnotationLinearGeometry(
                    points: [.zero, CGPoint(x: 80, y: 0)],
                    route: .straight,
                    startArrowhead: .none,
                    endArrowhead: .none,
                    startBinding: nil,
                    endBinding: nil
                )
            ),
            style: .default
        )
        let mixedArrow = AnnotationElement(
            geometry: .linear(
                AnnotationLinearGeometry(
                    points: [
                        CGPoint(x: 0, y: 20),
                        CGPoint(x: 80, y: 20)
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
        var lockedArrow = AnnotationElement(
            geometry: .linear(
                AnnotationLinearGeometry(
                    points: [
                        CGPoint(x: 0, y: 40),
                        CGPoint(x: 80, y: 40)
                    ],
                    route: .straight,
                    startArrowhead: .none,
                    endArrowhead: .triangle,
                    startBinding: nil,
                    endBinding: nil
                )
            ),
            style: .default
        )
        lockedArrow.metadata.isLocked = true
        let mixedLinearController = AnnotationController(
            elements: [mixedLine, mixedArrow, lockedArrow]
        )
        mixedLinearController.currentTool = .select
        mixedLinearController.selectAll()
        let mixedLinearState = DrawingToolbarState(
            annotationController: mixedLinearController
        )
        try expect(
            mixedLinearState.visibleInspectorSections == [
                .strokeColor,
                .strokeWidth,
                .strokeStyle,
                .arrowType,
                .arrowheads,
                .arrowheadSize,
                .opacity,
                .layers
            ]
                && !mixedLinearState.visibleInspectorSections.contains(.edges)
                && mixedLinearState.visibleInspectorSections.contains(.arrowheads)
                && mixedLinearState.visibleInspectorSections.contains(.arrowheadSize),
            "Expected mixed Line and Arrow selections to expose their shared route "
                + "and endpoint controls"
        )
        mixedLinearController.setLinearRoute(.curved)
        let mixedLineRoute: AnnotationLinearRoute? =
            mixedLinearController.elementSnapshot.first {
            $0.id == mixedLine.id
        }.flatMap {
            guard case .linear(let linear) = $0.geometry else { return nil }
            return linear.route
        }
        let mixedArrowRoute: AnnotationLinearRoute? =
            mixedLinearController.elementSnapshot.first {
            $0.id == mixedArrow.id
        }.flatMap {
            guard case .linear(let linear) = $0.geometry else { return nil }
            return linear.route
        }
        let lockedArrowRoute: AnnotationLinearRoute? =
            mixedLinearController.elementSnapshot.first {
            $0.id == lockedArrow.id
        }.flatMap {
            guard case .linear(let linear) = $0.geometry else { return nil }
            return linear.route
        }
        try expect(
            mixedLineRoute == .curved
                && mixedArrowRoute == .curved
                && lockedArrowRoute == .straight,
            "Expected shared route edits to update every unlocked selected linear "
                + "while preserving locked elements"
        )
        controller.currentTool = .text
        let textToolState = DrawingToolbarState(annotationController: controller)
        try expect(
            textToolState.visibleInspectorSections == [
                .strokeColor,
                .textFont,
                .textSize,
                .textAlignment,
                .opacity,
                .layers
            ]
                && textToolState.textFontSize == .value(controller.typingFontSize)
                && textToolState.textAlignment == .value(.left),
            "Expected the text tool to expose only text-specific properties"
        )
        let inspector = DrawingPropertiesController(
            commandSink: { _ in },
            colorPanelActivityChanged: { _ in }
        )
        let inspectorViewIdentity = ObjectIdentifier(inspector.view)
        let compactRectangleController = AnnotationController()
        compactRectangleController.currentTool = .rectangle
        compactRectangleController.setShapeBackground(nil)
        inspector.update(
            state: DrawingToolbarState(annotationController: compactRectangleController)
        )
        let rectangleInspectorHeight = inspector.preferredContentSize.height
        let rectangleFittingHeight = ceil(inspector.view.fittingSize.height)
        inspector.update(state: lineToolState)
        let lineInspectorHeight = inspector.preferredContentSize.height
        let lineFittingHeight = ceil(inspector.view.fittingSize.height)
        try expect(
            ObjectIdentifier(inspector.view) == inspectorViewIdentity
                && rectangleInspectorHeight == rectangleFittingHeight
                && lineInspectorHeight == lineFittingHeight,
            "Expected the inspector to resize live without rebuilding its interaction view "
                + "while the attached panel hugs its content "
                + "(rectangle \(rectangleInspectorHeight), line \(lineInspectorHeight))"
        )
        controller.currentTool = .select
        try expect(
            DrawingToolbarState(annotationController: controller).visibleInspectorSections.isEmpty,
            "Expected an empty selection inspector to avoid unrelated property sections"
        )

        let mixedController = AnnotationController()
        mixedController.currentTool = .rectangle
        mixedController.setStrokeColor(.palette(.red))
        mixedController.setStrokeWidth(3)
        mixedController.setSloppiness(.architect)
        mixedController.begin(at: CGPoint(x: 10, y: 10))
        mixedController.end(at: CGPoint(x: 40, y: 40))
        mixedController.setStrokeColor(.palette(.green))
        mixedController.setStrokeWidth(10)
        mixedController.setSloppiness(.cartoonist)
        mixedController.begin(at: CGPoint(x: 50, y: 10))
        mixedController.end(at: CGPoint(x: 80, y: 40))
        mixedController.currentTool = .select
        _ = mixedController.beginSelectionInteraction(
            at: CGPoint(x: 12, y: 25),
            zoomScale: 1,
            modifiers: [],
            clickCount: 1
        )
        mixedController.endSelectionInteraction(at: CGPoint(x: 12, y: 25), modifiers: [])
        _ = mixedController.beginSelectionInteraction(
            at: CGPoint(x: 52, y: 25),
            zoomScale: 1,
            modifiers: [.shift],
            clickCount: 1
        )
        mixedController.endSelectionInteraction(
            at: CGPoint(x: 52, y: 25),
            modifiers: [.shift]
        )
        let mixed = DrawingToolbarState(annotationController: mixedController)
        try expect(mixed.strokeColor == .mixed, "Expected mixed stroke colors for multi-selection")
        try expect(mixed.strokeWidth == .mixed, "Expected mixed stroke widths for multi-selection")
        try expect(mixed.sloppiness == .mixed, "Expected mixed sloppiness for multi-selection")
        try expect(mixed.canGroupSelection, "Expected toolbar grouping state for multi-selection")
        try expect(
            mixed.visibleInspectorSections
                == [
                    .strokeColor,
                    .background,
                    .strokeWidth,
                    .strokeStyle,
                    .sloppiness,
                    .edges,
                    .opacity,
                    .layers
                ],
            "Expected same-type multi-selection to retain the exact rectangle matrix"
        )
        let mixedInspector = DrawingPropertiesController(
            commandSink: { _ in },
            colorPanelActivityChanged: { _ in }
        )
        mixedInspector.update(state: mixed)
        let mixedGroups = descendantViews(
            of: DrawingMixedIndicatorStackView.self,
            in: mixedInspector.view
        ).filter(\.isMixed)
        let perOptionMixedButtons = descendantViews(
            of: DrawingAppearanceButton.self,
            in: mixedInspector.view
        ).filter(\.isMixed)
        try expect(
            mixedGroups.count >= 3 && perOptionMixedButtons.isEmpty,
            "Expected mixed values to use one capsule per option group, not mark every tile"
        )
        mixedController.setSloppiness(.artist)
        try expect(
            mixedController.selectedElementSnapshot.allSatisfy {
                $0.style.sloppiness == .artist
            },
            "Expected one mixed-selection command to update every applicable element"
        )
        mixedController.undo()
        try expect(
            DrawingToolbarState(annotationController: mixedController).sloppiness == .mixed,
            "Expected one undo to restore all mixed sloppiness values"
        )

        let textController = AnnotationController()
        textController.currentTool = .text
        textController.setInsertionPoint(CGPoint(x: 20, y: 20))
        textController.beginTypingSession(rightAligned: false)
        textController.insertText("Text")
        textController.finishTypingSession()
        textController.currentTool = .select
        _ = textController.beginSelectionInteraction(
            at: CGPoint(x: 22, y: 28),
            zoomScale: 1,
            modifiers: [],
            clickCount: 1
        )
        textController.endSelectionInteraction(
            at: CGPoint(x: 22, y: 28),
            modifiers: []
        )
        textController.setTextFontSize(42)
        textController.setTextAlignment(.center)
        let selectedText = DrawingToolbarState(annotationController: textController)
        try expect(
            selectedText.visibleInspectorSections == [
                .strokeColor,
                .textFont,
                .textSize,
                .textAlignment,
                .opacity,
                .layers
            ]
                && selectedText.textFontSize == .value(42)
                && selectedText.textAlignment == .value(.center),
            "Expected selected text properties and focused text commands to stay in sync"
        )
    }

    static func testLockedInspectorActionsAndDefaults() throws {
        let lockedShapeController = AnnotationController()
        lockedShapeController.currentTool = .rectangle
        lockedShapeController.setStrokeColor(.palette(.blue))
        lockedShapeController.setShapeBackground(.palette(.yellow))
        lockedShapeController.setFillStyle(.solid)
        lockedShapeController.setStrokeWidth(6)
        lockedShapeController.setStrokePattern(.dashed)
        lockedShapeController.setSloppiness(.cartoonist)
        lockedShapeController.setOpacity(0.75)
        lockedShapeController.setEdgeStyle(.round)
        lockedShapeController.begin(at: CGPoint(x: 10, y: 10))
        lockedShapeController.end(at: CGPoint(x: 70, y: 70))
        lockedShapeController.currentTool = .select
        lockedShapeController.selectAll()
        lockedShapeController.toggleSelectionLock()

        let lockedShapeState = DrawingToolbarState(
            annotationController: lockedShapeController
        )
        try expect(
            lockedShapeState.selectionIsFullyLocked
                && lockedShapeState.selectionLock == .value(true)
                && lockedShapeState.strokeColor == .unavailable
                && lockedShapeState.fillColor == .unavailable
                && lockedShapeState.fillStyle == .unavailable
                && lockedShapeState.strokeWidth == .unavailable
                && lockedShapeState.strokePattern == .unavailable
                && lockedShapeState.sloppiness == .unavailable
                && lockedShapeState.opacity == .unavailable
                && lockedShapeState.roundness == .unavailable
                && lockedShapeState.edgeStyle == .unavailable
                && lockedShapeState.visibleInspectorSections.contains(.fill)
                && !lockedShapeState.supportsStrokeOptions
                && !lockedShapeState.supportsFill
                && !lockedShapeState.supportsSloppiness
                && !lockedShapeState.supportsRoundness,
            "Expected locked-only shapes to expose unavailable property state"
        )
        let lockedInspector = DrawingPropertiesController(
            commandSink: { _ in },
            colorPanelActivityChanged: { _ in }
        )
        lockedInspector.update(state: lockedShapeState)
        try expect(
            descendantViews(of: NSButton.self, in: lockedInspector.view)
                .allSatisfy { !$0.isEnabled }
                && descendantViews(of: NSSlider.self, in: lockedInspector.view)
                    .allSatisfy { !$0.isEnabled }
                && descendantViews(of: NSColorWell.self, in: lockedInspector.view)
                    .allSatisfy { !$0.isEnabled },
            "Expected locked-only inspector controls to be disabled"
        )

        guard let lockedShapeBefore = lockedShapeController.elementSnapshot.first else {
            throw SelfTestError.failure("Expected a locked shape")
        }
        let lockedShapeDefaultStyle = lockedShapeController.currentStyle
        let lockedShapeDefaultRoute = lockedShapeController.currentLinearRoute
        let lockedShapeDefaultStart = lockedShapeController.currentStartArrowhead
        let lockedShapeDefaultEnd = lockedShapeController.currentEndArrowhead
        let lockedShapeTypingSize = lockedShapeController.typingFontSize
        let lockedShapeTypingPreset = lockedShapeController.typingFontPreset
        let lockedShapeTypingName = lockedShapeController.typingFontName
        let lockedShapeTypingAlignment = lockedShapeController.typingTextAlignment

        lockedShapeController.setStrokeColor(.palette(.orange))
        lockedShapeController.setShapeBackground(.palette(.pink))
        lockedShapeController.setFillStyle(.crossHatch)
        lockedShapeController.setStrokeWidth(14)
        lockedShapeController.setStrokePattern(.dotted)
        lockedShapeController.setSloppiness(.artist)
        lockedShapeController.setOpacity(0.35)
        lockedShapeController.setRoundness(nil)
        lockedShapeController.setEdgeStyle(.sharp)
        lockedShapeController.setLinearRoute(.curved)
        lockedShapeController.setLinearArrowheads(start: .circle, end: .diamond)
        lockedShapeController.setTextColor(.palette(.green))
        lockedShapeController.setTextOpacity(0.4)
        lockedShapeController.setTextFontPreset(.rounded)
        lockedShapeController.setTextFontName("Menlo")
        lockedShapeController.setTextFontSize(48)
        lockedShapeController.setTextAlignment(.right)

        try expect(
            lockedShapeController.elementSnapshot.first == lockedShapeBefore
                && lockedShapeController.currentStyle == lockedShapeDefaultStyle
                && lockedShapeController.currentLinearRoute == lockedShapeDefaultRoute
                && lockedShapeController.currentStartArrowhead == lockedShapeDefaultStart
                && lockedShapeController.currentEndArrowhead == lockedShapeDefaultEnd
                && lockedShapeController.typingFontSize == lockedShapeTypingSize
                && lockedShapeController.typingFontPreset == lockedShapeTypingPreset
                && lockedShapeController.typingFontName == lockedShapeTypingName
                && lockedShapeController.typingTextAlignment == lockedShapeTypingAlignment,
            "Expected locked-only and incompatible mutations to preserve elements and defaults"
        )

        let mixedController = AnnotationController()
        mixedController.currentTool = .rectangle
        mixedController.setStrokeColor(.palette(.red))
        mixedController.setShapeBackground(.palette(.pink))
        mixedController.setFillStyle(.hachure)
        mixedController.setStrokeWidth(1)
        mixedController.setStrokePattern(.dashed)
        mixedController.setSloppiness(.architect)
        mixedController.begin(at: CGPoint(x: 10, y: 10))
        mixedController.end(at: CGPoint(x: 60, y: 60))
        mixedController.setStrokeColor(.palette(.green))
        mixedController.setShapeBackground(.palette(.yellow))
        mixedController.setFillStyle(.solid)
        mixedController.setStrokeWidth(6)
        mixedController.setStrokePattern(.dotted)
        mixedController.setSloppiness(.cartoonist)
        mixedController.setEdgeStyle(.round)
        mixedController.begin(at: CGPoint(x: 90, y: 10))
        mixedController.end(at: CGPoint(x: 140, y: 60))
        mixedController.currentTool = .select
        _ = mixedController.beginSelectionInteraction(
            at: CGPoint(x: 12, y: 35),
            zoomScale: 1,
            modifiers: [],
            clickCount: 1
        )
        mixedController.endSelectionInteraction(
            at: CGPoint(x: 12, y: 35),
            modifiers: []
        )
        mixedController.toggleSelectionLock()
        mixedController.selectAll()

        let editableCommonState = DrawingToolbarState(
            annotationController: mixedController
        )
        try expect(
            editableCommonState.selectionLock == .mixed
                && editableCommonState.strokeColor == .value(.palette(.green))
                && editableCommonState.fillColor == .value(.palette(.yellow))
                && editableCommonState.fillStyle == .value(.solid)
                && editableCommonState.strokeWidth == .value(6)
                && editableCommonState.strokePattern == .value(.dotted)
                && editableCommonState.sloppiness == .value(.cartoonist)
                && editableCommonState.edgeStyle == .value(.round)
                && editableCommonState.supportsStrokeOptions
                && editableCommonState.supportsFill
                && editableCommonState.supportsSloppiness
                && editableCommonState.supportsRoundness,
            "Expected mixed lock selections to resolve properties from unlocked elements only"
        )
        guard let lockedMixedBefore = mixedController.elementSnapshot.first(where: {
            $0.metadata.isLocked
        }) else {
            throw SelfTestError.failure("Expected one locked shape in the mixed selection")
        }

        mixedController.setStrokeColor(.palette(.orange))
        mixedController.setShapeBackground(.palette(.blue))
        mixedController.setFillStyle(.crossHatch)
        mixedController.setStrokeWidth(3)
        mixedController.setStrokePattern(.solid)
        mixedController.setSloppiness(.artist)
        mixedController.setOpacity(0.55)
        mixedController.setEdgeStyle(.sharp)

        guard let lockedMixedAfter = mixedController.elementSnapshot.first(where: {
            $0.metadata.isLocked
        }),
        let editableMixedAfter = mixedController.elementSnapshot.first(where: {
            !$0.metadata.isLocked
        }) else {
            throw SelfTestError.failure("Expected locked and editable mixed-selection shapes")
        }
        try expect(
            lockedMixedAfter == lockedMixedBefore
                && editableMixedAfter.style.strokeColor == .palette(.orange)
                && editableMixedAfter.style.fillColor == .palette(.blue)
                && editableMixedAfter.style.fillStyle == .crossHatch
                && editableMixedAfter.style.strokeWidth == 3
                && editableMixedAfter.style.strokePattern == .solid
                && editableMixedAfter.style.sloppiness == .artist
                && editableMixedAfter.style.opacity == 0.55
                && editableMixedAfter.style.roundness == nil,
            "Expected mixed lock mutations to update only unlocked compatible elements"
        )

        mixedController.currentTool = .rectangle
        mixedController.setStrokeColor(.palette(.blue))
        mixedController.setStrokeWidth(10)
        mixedController.begin(at: CGPoint(x: 170, y: 10))
        mixedController.end(at: CGPoint(x: 220, y: 60))
        mixedController.currentTool = .select
        mixedController.selectAll()
        let editableMixedState = DrawingToolbarState(
            annotationController: mixedController
        )
        try expect(
            editableMixedState.strokeColor == .mixed
                && editableMixedState.strokeWidth == .mixed
                && editableMixedState.selectionLock == .mixed,
            "Expected differing unlocked values to remain visibly mixed while ignoring locked values"
        )

        let textController = AnnotationController()
        textController.currentTool = .text
        textController.setInsertionPoint(CGPoint(x: 20, y: 20))
        textController.beginTypingSession(rightAligned: false)
        textController.insertText("Locked")
        textController.finishTypingSession()
        textController.currentTool = .select
        textController.selectAll()
        guard let unlockedTextBefore = textController.elementSnapshot.first else {
            throw SelfTestError.failure("Expected an unlocked text element")
        }
        let incompatibleStyleBefore = textController.currentStyle
        let incompatibleRouteBefore = textController.currentLinearRoute
        let incompatibleStartBefore = textController.currentStartArrowhead
        let incompatibleEndBefore = textController.currentEndArrowhead
        textController.setFillColor(.palette(.yellow))
        textController.setFillStyle(.solid)
        textController.setStrokeWidth(12)
        textController.setStrokePattern(.dashed)
        textController.setSloppiness(.artist)
        textController.setRoundness(20)
        textController.setEdgeStyle(.round)
        textController.setLinearRoute(.curved)
        textController.setLinearArrowheads(start: .circle, end: .triangle)
        try expect(
            textController.elementSnapshot.first == unlockedTextBefore
                && textController.currentStyle == incompatibleStyleBefore
                && textController.currentLinearRoute == incompatibleRouteBefore
                && textController.currentStartArrowhead == incompatibleStartBefore
                && textController.currentEndArrowhead == incompatibleEndBefore,
            "Expected an unlocked but incompatible selection to preserve unrelated defaults"
        )

        textController.toggleSelectionLock()
        let lockedTextState = DrawingToolbarState(annotationController: textController)
        try expect(
            lockedTextState.strokeColor == .unavailable
                && lockedTextState.opacity == .unavailable
                && lockedTextState.textColor == .unavailable
                && lockedTextState.textOpacity == .unavailable
                && lockedTextState.textFontPreset == .unavailable
                && lockedTextState.textFontName == .unavailable
                && lockedTextState.textFontSize == .unavailable
                && lockedTextState.textAlignment == .unavailable
                && !lockedTextState.supportsTextOptions,
            "Expected locked-only text properties to be unavailable"
        )
        let lockedTextBefore = textController.elementSnapshot.first
        let lockedTextStyleBefore = textController.currentStyle
        let lockedTypingSize = textController.typingFontSize
        let lockedTypingPreset = textController.typingFontPreset
        let lockedTypingName = textController.typingFontName
        let lockedTypingAlignment = textController.typingTextAlignment
        textController.setTextColor(.palette(.green))
        textController.setTextOpacity(0.3)
        textController.setTextFontPreset(.monospaced)
        textController.setTextFontName("Courier")
        textController.setTextFontSize(72)
        textController.setTextAlignment(.right)
        try expect(
            textController.elementSnapshot.first == lockedTextBefore
                && textController.currentStyle == lockedTextStyleBefore
                && textController.typingFontSize == lockedTypingSize
                && textController.typingFontPreset == lockedTypingPreset
                && textController.typingFontName == lockedTypingName
                && textController.typingTextAlignment == lockedTypingAlignment,
            "Expected locked-only text commands to preserve typing defaults"
        )

        let lockedLinearController = AnnotationController()
        lockedLinearController.currentTool = .arrow
        lockedLinearController.setLinearRoute(.curved)
        lockedLinearController.setLinearArrowheads(start: .circle, end: .triangle)
        lockedLinearController.begin(at: CGPoint(x: 10, y: 20))
        lockedLinearController.update(at: CGPoint(x: 120, y: 20))
        lockedLinearController.end(at: CGPoint(x: 120, y: 20))
        lockedLinearController.currentTool = .select
        lockedLinearController.selectAll()
        lockedLinearController.toggleSelectionLock()
        let lockedLinearState = DrawingToolbarState(
            annotationController: lockedLinearController
        )
        let lockedLinearAvailability =
            DrawingToolbarOverflowActionAvailability.enabledStates(
                for: lockedLinearState
            )
        try expect(
            lockedLinearState.linearRoute == .unavailable
                && lockedLinearState.startArrowhead == .unavailable
                && lockedLinearState.endArrowhead == .unavailable
                && !lockedLinearState.supportsLinearOptions
                && !lockedLinearState.canEditLinearPoints
                && !lockedLinearState.canInsertLinearPoint
                && !lockedLinearState.canRemoveLinearPoints
                && !lockedLinearState.canUnbindLinearEndpoints
                && lockedLinearAvailability[DrawingToolbarOverflowActionTitle.editPoints]
                    == false
                && lockedLinearAvailability[DrawingToolbarOverflowActionTitle.insertPoint]
                    == false
                && lockedLinearAvailability[DrawingToolbarOverflowActionTitle.removePoints]
                    == false
                && lockedLinearAvailability[
                    DrawingToolbarOverflowActionTitle.unbindEndpoints
                ] == false,
            "Expected locked-only linear state and overflow actions to be disabled"
        )
        let lockedLinearBefore = lockedLinearController.elementSnapshot.first
        let lockedRouteBefore = lockedLinearController.currentLinearRoute
        let lockedStartBefore = lockedLinearController.currentStartArrowhead
        let lockedEndBefore = lockedLinearController.currentEndArrowhead
        lockedLinearController.setLinearRoute(.curved)
        lockedLinearController.setLinearArrowheads(start: .bar, end: .diamond)
        try expect(
            lockedLinearController.elementSnapshot.first == lockedLinearBefore
                && lockedLinearController.currentLinearRoute == lockedRouteBefore
                && lockedLinearController.currentStartArrowhead == lockedStartBefore
                && lockedLinearController.currentEndArrowhead == lockedEndBefore,
            "Expected locked-only linear commands to preserve route and arrowhead defaults"
        )

        let editingLinearController = AnnotationController()
        editingLinearController.currentTool = .line
        editingLinearController.begin(at: CGPoint(x: 10, y: 20))
        editingLinearController.update(at: CGPoint(x: 120, y: 20))
        editingLinearController.end(at: CGPoint(x: 120, y: 20))
        editingLinearController.currentTool = .select
        let editingLinearState = DrawingToolbarState(
            annotationController: editingLinearController
        )
        let editingAvailability =
            DrawingToolbarOverflowActionAvailability.enabledStates(
                for: editingLinearState
            )
        try expect(
            editingLinearState.isEditingLinearPoints
                && editingLinearState.canEditLinearPoints
                && !editingLinearState.canInsertLinearPoint
                && !editingLinearState.canRemoveLinearPoints
                && editingAvailability[
                    DrawingToolbarOverflowActionTitle.finishPointEditing
                ] == true
                && editingAvailability[DrawingToolbarOverflowActionTitle.insertPoint]
                    == false
                && editingAvailability[DrawingToolbarOverflowActionTitle.removePoints]
                    == false,
            "Expected overflow point actions to use exact capabilities, not editing state"
        )
        _ = editingLinearController.toggleLinearPointEditing()
        let passiveLinearState = DrawingToolbarState(
            annotationController: editingLinearController
        )
        let passiveAvailability =
            DrawingToolbarOverflowActionAvailability.enabledStates(
                for: passiveLinearState
            )
        try expect(
            passiveLinearState.canEditLinearPoints
                && passiveLinearState.supportsLinearOptions
                && passiveLinearState.hasSelection
                && passiveAvailability[DrawingToolbarOverflowActionTitle.editPoints] == true
                && passiveAvailability[DrawingToolbarOverflowActionTitle.insertPoint] == false
                && passiveAvailability[DrawingToolbarOverflowActionTitle.removePoints] == false
                && passiveAvailability[
                    DrawingToolbarOverflowActionTitle.unbindEndpoints
                ] == false,
            "Expected passive linear overflow actions to reject insert, remove, and unbind no-ops"
        )

        let defaultsController = AnnotationController()
        defaultsController.currentTool = .rectangle
        defaultsController.setStrokeColor(.palette(.orange))
        defaultsController.setShapeBackground(.palette(.pink))
        defaultsController.setFillStyle(.solid)
        defaultsController.setStrokeWidth(14)
        defaultsController.setStrokePattern(.dotted)
        defaultsController.setSloppiness(.artist)
        defaultsController.setOpacity(0.45)
        defaultsController.setEdgeStyle(.round)
        defaultsController.setLinearRoute(.curved)
        defaultsController.setLinearArrowheads(start: .circle, end: .diamond)
        defaultsController.setTextFontName("Menlo")
        defaultsController.setTextFontSize(48)
        defaultsController.setTextAlignment(.right)
        try expect(
            defaultsController.currentStyle.strokeColor == .palette(.orange)
                && defaultsController.currentStyle.fillColor == .palette(.pink)
                && defaultsController.currentStyle.fillStyle == .solid
                && defaultsController.currentStyle.strokeWidth == 14
                && defaultsController.currentStyle.strokePattern == .dotted
                && defaultsController.currentStyle.sloppiness == .artist
                && defaultsController.currentStyle.opacity == 0.45
                && defaultsController.currentStyle.roundness == 20
                && defaultsController.currentLinearRoute == .curved
                && defaultsController.currentStartArrowhead == .circle
                && defaultsController.currentEndArrowhead == .diamond
                && defaultsController.typingFontPreset == .typeSetting
                && defaultsController.typingFontName == "Menlo"
                && defaultsController.typingFontSize == 48
                && defaultsController.typingTextAlignment == .right,
            "Expected no-selection commands to continue updating drawing and typing defaults"
        )

        let scopedController = AnnotationController()
        scopedController.currentTool = .rectangle
        scopedController.setStrokeColor(.palette(.orange))
        scopedController.setStrokePattern(.dotted)
        scopedController.currentTool = .pen
        let penState = DrawingToolbarState(annotationController: scopedController)
        scopedController.begin(at: CGPoint(x: 0, y: 0))
        scopedController.end(at: CGPoint(x: 20, y: 0))
        guard let pen = scopedController.elementSnapshot.last else {
            throw SelfTestError.failure("Expected scoped Pen stroke")
        }
        scopedController.currentTool = .highlighter
        let initialHighlighterColor = scopedController.currentStyle.strokeColor
        scopedController.setStrokeColor(.palette(.highlighterPink))
        scopedController.currentStyle.pressureMode = .simulated
        scopedController.begin(at: CGPoint(x: 0, y: 10))
        scopedController.end(at: CGPoint(x: 20, y: 10))
        guard let highlighter = scopedController.elementSnapshot.last else {
            throw SelfTestError.failure("Expected scoped Highlighter stroke")
        }
        scopedController.currentTool = .rectangle
        let restoredRectangleStyle = scopedController.currentStyle
        scopedController.currentTool = .highlighter
        try expect(
            penState.strokePattern == .unavailable
                && pen.style.strokePattern == .solid
                && initialHighlighterColor == .palette(.highlighterYellow)
                && highlighter.style.strokePattern == .solid
                && highlighter.style.pressureMode == .fixed
                && restoredRectangleStyle.strokeColor == .palette(.orange)
                && restoredRectangleStyle.strokePattern == .dotted
                && scopedController.currentStyle.strokeColor
                    == .palette(.highlighterPink),
            "Expected freehand pattern/pressure isolation and independent Highlighter color scope"
        )
    }

    static func testDrawingInspectorLayoutAndVisibilityPolicy() throws {
        let emptyController = AnnotationController()
        emptyController.currentTool = .select
        let emptyState = DrawingToolbarState(annotationController: emptyController)
        try expect(
            !emptyState.hasInspectorContent
                && !DrawingInspectorPresentationPolicy.shouldShow(
                    hasContent: emptyState.hasInspectorContent
                )
                && DrawingInspectorPresentationPolicy.shouldShow(
                    hasContent: true
                ),
            "Expected inspector visibility to follow property availability only"
        )
        for tool in [AnnotationTool.hand, .eraser] {
            emptyController.currentTool = tool
            try expect(
                !DrawingToolbarState(annotationController: emptyController).hasInspectorContent,
                "Expected \(tool) to omit an empty inspector"
            )
        }

        emptyController.currentTool = .pen
        let penState = DrawingToolbarState(annotationController: emptyController)
        try expect(
            penState.hasInspectorContent
                && DrawingInspectorPresentationPolicy.shouldShow(
                    hasContent: penState.hasInspectorContent
                ),
            "Expected the inspector to reappear when a property-bearing tool becomes active"
        )

        let firstContext = emptyState.inspectorContext
        try expect(
            DrawingInspectorPresentationPolicy.shouldResetScroll(
                from: firstContext,
                to: penState.inspectorContext
            )
                && !DrawingInspectorPresentationPolicy.shouldResetScroll(
                    from: penState.inspectorContext,
                    to: penState.inspectorContext
                ),
            "Expected tool changes to reset inspector scrolling while same-context updates retain it"
        )
        try expect(
            DrawingInspectorDocumentLayout.documentSize(
                contentSize: CGSize(width: 900, height: 280),
                viewportSize: CGSize(width: 208, height: 520)
            ) == CGSize(width: 208, height: 280),
            "Expected inspector documents to remain no wider than the viewport "
                + "without stretching their height"
        )
        try expect(
            DrawingInspectorDocumentLayout.clampedScrollOrigin(
                CGPoint(x: 12, y: 900),
                documentSize: CGSize(width: 900, height: 90),
                viewportSize: CGSize(width: 520, height: 90),
                resetsToOrigin: false
            ) == .zero
                && DrawingInspectorDocumentLayout.clampedScrollOrigin(
                    CGPoint(x: 200, y: 0),
                    documentSize: CGSize(width: 900, height: 90),
                    viewportSize: CGSize(width: 520, height: 90),
                    resetsToOrigin: true
                ) == .zero,
            "Expected attached inspector documents to stay pinned to the viewport origin"
        )
        try expect(
            DrawingInspectorDocumentLayout.clampedScrollOrigin(
                CGPoint(x: 40, y: 900),
                documentSize: CGSize(width: 208, height: 600),
                viewportSize: CGSize(width: 208, height: 200),
                resetsToOrigin: false
            ) == CGPoint(x: 0, y: 400)
                && DrawingInspectorDocumentLayout.clampedScrollOrigin(
                    CGPoint(x: 0, y: -20),
                    documentSize: CGSize(width: 208, height: 600),
                    viewportSize: CGSize(width: 208, height: 200),
                    resetsToOrigin: false
                ) == .zero,
            "Expected vertical inspector scrolling to clamp within the document"
        )

        let inspector = DrawingPropertiesController(
            commandSink: { _ in },
            colorPanelActivityChanged: { _ in }
        )
        inspector.update(state: penState)
        let frames = inspector.visibleSectionFramesForTesting()
        let penLayout = DrawingInspectorSectionMatrix
            .DrawingToolbarHorizontalSectionPacker.layout(
                sections: penState.visibleInspectorSections,
                availableWidth:
                    DrawingInspectorVisualMetrics.attachedMaximumWidth
                        - DrawingInspectorVisualMetrics.attachedHorizontalChrome
            )
        try expect(
            Set(frames.keys) == Set(penState.visibleInspectorSections),
            "Expected hidden inspector sections to detach completely "
                + "(actual \(Array(frames.keys)), expected \(penState.visibleInspectorSections))"
        )
        try expect(
            frames.values.allSatisfy { $0.height > 0 }
                && penLayout.rows.count <= 2,
            "Expected attached Pen sections to occupy at most two compact rows: \(frames)"
        )

        func verifyTitleLayout(
            availableWidth: CGFloat,
            expectedRows: Int
        ) throws {
            inspector.setAvailableHorizontalWidth(availableWidth)
            inspector.update(state: penState)
            let layout = DrawingInspectorSectionMatrix
                .DrawingToolbarHorizontalSectionPacker.layout(
                    sections: penState.visibleInspectorSections,
                    availableWidth: availableWidth
                )
            guard let title = descendantViews(
                of: NSTextField.self,
                in: inspector.view
            ).first(where: { $0.stringValue == DrawingInspectorSection.opacity.title }) else {
                throw SelfTestError.failure("Expected the Opacity section title")
            }
            title.layoutSubtreeIfNeeded()
            guard let representation = title.bitmapImageRepForCachingDisplay(
                in: title.bounds
            ) else {
                throw SelfTestError.failure("Could not rasterize the Opacity title")
            }
            title.cacheDisplay(in: title.bounds, to: representation)
            let paintedRows = (0..<representation.pixelsHigh).filter { y in
                (0..<representation.pixelsWide).contains { x in
                    (representation.colorAt(x: x, y: y)?.alphaComponent ?? 0) > 0.05
                }
            }
            guard let firstPaintedRow = paintedRows.first,
                  let lastPaintedRow = paintedRows.last else {
                throw SelfTestError.failure("Expected rendered Opacity title pixels")
            }
            let scale = CGFloat(representation.pixelsHigh) / title.bounds.height
            let baseline = title.isFlipped
                ? title.firstBaselineOffsetFromTop * scale
                : title.lastBaselineOffsetFromBottom * scale
            let hasDescenderPixels = title.isFlipped
                ? CGFloat(lastPaintedRow) > baseline
                : CGFloat(firstPaintedRow) < baseline
            try expect(
                layout.rows.count == expectedRows
                    && inspector.preferredContentSize.height
                        == ceil(inspector.view.fittingSize.height)
                    && title.intrinsicContentSize.height >= 14
                    && title.frame.height >= 14
                    && title.firstBaselineOffsetFromTop > 0
                    && title.lastBaselineOffsetFromBottom > 0
                    && firstPaintedRow > 0
                    && lastPaintedRow < representation.pixelsHigh - 1
                    && hasDescenderPixels,
                "Expected \(expectedRows)-row titles to preserve intrinsic height, "
                    + "baseline, and rendered descenders without clipping"
            )
        }
        try verifyTitleLayout(availableWidth: 900, expectedRows: 1)
        try verifyTitleLayout(availableWidth: 420, expectedRows: 2)

        let layoutWidths: [CGFloat] = [1_440, 1_280, 1_024, 800, 600]
        let matrixTools: [AnnotationTool] = [
            AnnotationTool.rectangle, .diamond, .ellipse, .arrow, .line, .pen, .text
        ] + [.highlighter]
        for screenWidth in layoutWidths {
            let panelWidth = min(
                DrawingInspectorVisualMetrics.attachedMaximumWidth,
                screenWidth - DrawingAttachedInspectorPlacement.screenMargin * 2
            )
            let availableWidth = panelWidth
                - DrawingInspectorVisualMetrics.attachedHorizontalChrome
            for tool in matrixTools {
                try autoreleasepool {
                    let matrixInspector = DrawingPropertiesController(
                        commandSink: { _ in },
                        colorPanelActivityChanged: { _ in }
                    )
                    let fillVariants = [.rectangle, .diamond, .ellipse].contains(tool)
                        ? [false, true, false]
                        : [false]
                    var transitionHeights: [CGFloat] = []
                    var transitionLayouts:
                        [DrawingInspectorSectionMatrix.DrawingToolbarHorizontalSectionLayout] = []
                    for showsFill in fillVariants {
                        let controller = AnnotationController()
                        controller.currentTool = tool
                        controller.setShapeBackground(
                            showsFill ? .palette(.backgroundRed) : nil
                        )
                        let state = DrawingToolbarState(annotationController: controller)
                        matrixInspector.setAvailableHorizontalWidth(availableWidth)
                        matrixInspector.update(state: state)
                        let frames = matrixInspector.visibleSectionFramesForTesting()
                        transitionHeights.append(matrixInspector.preferredContentSize.height)
                        let layout = matrixInspector.sectionLayoutForTesting
                        transitionLayouts.append(layout)
                        let frameValues = Array(frames.values)
                        let rootBounds = matrixInspector.view.bounds.insetBy(
                            dx: -0.5,
                            dy: -0.5
                        )
                        let sectionsDoNotOverlap = frameValues.indices.allSatisfy { index in
                            frameValues.indices.dropFirst(index + 1).allSatisfy {
                                !frameValues[index].intersects(frameValues[$0])
                            }
                        }
                        let visibleDescendants = descendantViews(
                            of: NSView.self,
                            in: matrixInspector.view
                        ).filter {
                            $0 !== matrixInspector.view
                                && !($0.superview is NSTextField)
                                && !$0.isHidden
                                && !$0.frame.isEmpty
                        }
                        let descendantsFit = visibleDescendants.allSatisfy {
                            rootBounds.contains(
                                frame($0, convertedTo: matrixInspector.view)
                            )
                        }
                        let clippedDescendants = visibleDescendants.compactMap {
                            view -> String? in
                            let frame = frame(
                                view,
                                convertedTo: matrixInspector.view
                            )
                            return rootBounds.contains(frame)
                                ? nil
                                : "\(type(of: view)) \(frame)"
                        }

                        let card = DrawingInspectorView(propertiesView: matrixInspector.view)
                        card.frame = CGRect(
                            origin: .zero,
                            size: CGSize(
                                width: matrixInspector.preferredContentSize.width
                                    + DrawingInspectorVisualMetrics.attachedHorizontalChrome,
                                height: matrixInspector.preferredContentSize.height
                                    + DrawingInspectorVisualMetrics.attachedVerticalInset * 2
                            )
                        )
                        card.update(
                            state: state,
                            contentSize: matrixInspector.preferredContentSize
                        )
                        card.layoutSubtreeIfNeeded()

                        try expect(
                            layout.rows.count >= 1
                                && layout.rows.count <= 3
                                && layout.rows.flatMap { $0 }
                                    == state.visibleInspectorSections
                                && layout.documentWidth <= availableWidth
                                && layout.rowWidths.allSatisfy {
                                    $0 <= availableWidth + 0.5
                                }
                                && matrixInspector.preferredContentSize.width
                                    == layout.documentWidth
                                && matrixInspector.preferredContentSize.height.isFinite
                                && matrixInspector.preferredContentSize.height
                                    == ceil(matrixInspector.view.fittingSize.height)
                                && Set(frames.keys) == Set(state.visibleInspectorSections)
                                && frameValues.allSatisfy {
                                    !$0.isEmpty && rootBounds.contains($0)
                                }
                                && sectionsDoNotOverlap
                                && descendantsFit
                                && card.frame.width <= panelWidth + 0.5
                                && !card.hasHorizontalScrollerForTesting
                                && card.documentSizeForTesting.width
                                    <= card.viewportSizeForTesting.width + 0.5,
                            "Expected \(tool) at \(Int(screenWidth)) px with Fill "
                                + "\(showsFill ? "visible" : "hidden") to fit in 1-3 "
                                + "ordered rows without clipping, overlap, or horizontal scrolling "
                                + "(layout \(layout), frames \(frames), root \(rootBounds), "
                                + "clipped \(clippedDescendants), preferred "
                                + "\(matrixInspector.preferredContentSize), fitting "
                                + "\(matrixInspector.view.fittingSize), document "
                                + "\(card.documentSizeForTesting), viewport "
                                + "\(card.viewportSizeForTesting), scroller "
                                + "\(card.hasHorizontalScrollerForTesting))"
                        )
                        if [.rectangle, .diamond].contains(tool), showsFill {
                            try expect(
                                state.visibleInspectorSections == [
                                    .strokeColor,
                                    .background,
                                    .fill,
                                    .strokeWidth,
                                    .strokeStyle,
                                    .sloppiness,
                                    .edges,
                                    .opacity,
                                    .layers
                                ],
                                "Expected the full shape matrix to preserve section order"
                            )
                        }
                    }
                    if transitionHeights.count == 3 {
                        try expect(
                            transitionHeights[0] == transitionHeights[2],
                            "Expected Fill off/on/off to restore the exact original inspector height "
                                + "for \(tool) at \(Int(screenWidth)) px: \(transitionHeights), "
                                + "layouts \(transitionLayouts)"
                        )
                    }
                }
            }
        }

        emptyController.currentTool = .rectangle
        emptyController.setStrokeColor(.palette(.red))
        inspector.update(state: DrawingToolbarState(annotationController: emptyController))
        _ = inspector.visibleSectionFramesForTesting()
        let colorButtons = descendantViews(of: NSButton.self, in: inspector.view).filter {
            $0.accessibilityLabel()?.hasPrefix("Stroke ") == true
        }
        let backgroundButtons = descendantViews(of: NSButton.self, in: inspector.view).filter {
            $0.accessibilityLabel()?.hasPrefix("Background ") == true
        }
        let customColorWells = descendantViews(of: NSColorWell.self, in: inspector.view)
        let initialColorFrames = colorButtons.map(\.frame)
        emptyController.setStrokeColor(.palette(.blue))
        inspector.update(state: DrawingToolbarState(annotationController: emptyController))
        _ = inspector.visibleSectionFramesForTesting()
        try expect(
            colorButtons.count == 5
                && backgroundButtons.count == 5
                && customColorWells.count == 2
                && colorButtons.allSatisfy {
                    abs($0.frame.width - DrawingInspectorVisualMetrics.colorTileSide) < 0.01
                        && abs(
                            $0.frame.height - DrawingInspectorVisualMetrics.colorTileSide
                        ) < 0.01
                        && $0.superview?.bounds.contains($0.frame) == true
                }
                && colorButtons.map(\.frame) == initialColorFrames,
            "Expected exactly five preset colors plus one separated custom/current tile"
        )

        emptyController.setShapeBackground(nil)
        let transparentRectangle = DrawingToolbarState(annotationController: emptyController)
        emptyController.setShapeBackground(.palette(.pink))
        let filledRectangle = DrawingToolbarState(annotationController: emptyController)
        emptyController.setFillColor(.rgba(red: 1, green: 0, blue: 0, alpha: 0))
        let alphaTransparentRectangle = DrawingToolbarState(
            annotationController: emptyController
        )
        try expect(
            !transparentRectangle.visibleInspectorSections.contains(.fill)
                && filledRectangle.visibleInspectorSections.firstIndex(of: .fill)
                    == filledRectangle.visibleInspectorSections.firstIndex(of: .background)
                        .map { $0 + 1 }
                && !alphaTransparentRectangle.visibleInspectorSections.contains(.fill),
            "Expected Fill to appear directly after a nontransparent Background only"
        )

        let toolbar = DrawingToolbarView(
            commandSink: { _ in },
            showOverflow: { _ in }
        )
        toolbar.update(
            state: emptyState,
            transientTool: nil
        )
        toolbar.update(
            state: penState,
            transientTool: nil
        )
        let primaryLabels = descendantViews(
            of: NSButton.self,
            in: toolbar
        ).compactMap { $0.accessibilityLabel() }
        try expect(
            !primaryLabels.contains("Open Drawing Inspector")
                && !primaryLabels.contains("Close Drawing Inspector")
                && !primaryLabels.contains("Attach Inspector to Toolbar")
                && !primaryLabels.contains("Dock Inspector to Side"),
            "Expected inspector visibility, pinning, and presentation controls to stay in overflow"
        )
    }

    static func testDrawingInspectorRuntimePresentationSwitch() throws {
        let visibleFrame = NSScreen.main?.visibleFrame
            ?? CGRect(x: 0, y: 0, width: 1_200, height: 800)
        let availableFrame = visibleFrame.insetBy(
            dx: DrawingAttachedInspectorPlacement.screenMargin,
            dy: DrawingAttachedInspectorPlacement.screenMargin
        )
        let parent = NSWindow(
            contentRect: visibleFrame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        parent.isReleasedWhenClosed = false
        parent.level = .screenSaver

        let annotationController = AnnotationController()
        annotationController.currentTool = .hand
        var persistedToolbarPosition: CGPoint?
        let controller = DrawingToolbarController(
            parentWindow: parent,
            annotationController: annotationController,
            toolbarNormalizedPosition: nil,
            commandSink: { _ in },
            restoreCanvasFocus: {},
            toolbarPlacementDidChange: {
                persistedToolbarPosition = $0
            },
            pointerInteractionChanged: { _ in }
        )
        controller.show()
        controller.inspectorWindowForTesting.setFrame(.zero, display: false)
        try expect(
            !controller.inspectorIsVisibleForTesting,
            "Expected propertyless Hand to start with a hidden inspector"
        )
        try expect(
            controller.inspectorFrameForTesting == .zero,
            "Expected the initial hidden-inspector drag regression to use a zero frame"
        )
        try expect(
            !controller.inspectorHasChromeForTesting
                && controller.toolbarWindowForTesting.delegate == nil,
            "Expected a chrome-free inspector and delegate-free toolbar window"
        )

        controller.applyDragSampleForTesting(
            proposedOrigin: CGPoint(
                x: visibleFrame.maxX + 1_000,
                y: visibleFrame.minY - 1_000
            ),
            visibleFrame: visibleFrame
        )
        let handEdgeToolbarFrame = controller.toolbarFrameForTesting
        try expect(
            abs(handEdgeToolbarFrame.maxX - availableFrame.maxX) < 0.001
                && abs(handEdgeToolbarFrame.minY - availableFrame.minY) < 0.001
                && controller.inspectorFrameForTesting == .zero,
            "Expected Hand edge dragging to clamp only the toolbar and ignore a zero inspector frame"
        )

        annotationController.currentTool = .rectangle
        controller.updateState(
            DrawingToolbarState(annotationController: annotationController)
        )
        try expect(
            controller.inspectorIsVisibleForTesting
                && controller.toolbarFrameForTesting == handEdgeToolbarFrame
                && controller.inspectorWindowForTesting.parent
                    === controller.toolbarWindowForTesting
                && availableFrame.contains(controller.inspectorFrameForTesting),
            "Expected showing the attached inspector after edge placement to leave the toolbar fixed"
        )

        annotationController.currentTool = .select
        controller.updateState(
            DrawingToolbarState(annotationController: annotationController)
        )
        let staleSelectInspectorFrame = controller.inspectorFrameForTesting
        try expect(
            !controller.inspectorIsVisibleForTesting
                && staleSelectInspectorFrame.width > 0
                && staleSelectInspectorFrame.height > 0,
            "Expected empty Select to hide the inspector without depending on frame reset"
        )
        controller.applyDragSampleForTesting(
            proposedOrigin: CGPoint(
                x: visibleFrame.minX - 1_000,
                y: visibleFrame.minY - 1_000
            ),
            visibleFrame: visibleFrame
        )
        let selectEdgeToolbarFrame = controller.toolbarFrameForTesting
        try expect(
            abs(selectEdgeToolbarFrame.minX - availableFrame.minX) < 0.001
                && abs(selectEdgeToolbarFrame.minY - availableFrame.minY) < 0.001
                && controller.inspectorFrameForTesting == staleSelectInspectorFrame,
            "Expected empty Select edge dragging to ignore the hidden inspector's stale frame"
        )

        annotationController.currentTool = .rectangle
        controller.updateState(
            DrawingToolbarState(annotationController: annotationController)
        )
        let toolbarFrameBeforeHeightTransitions = controller.toolbarFrameForTesting
        annotationController.setShapeBackground(nil)
        controller.updateState(
            DrawingToolbarState(annotationController: annotationController)
        )
        let fillOffFrame = controller.inspectorFrameForTesting
        annotationController.setShapeBackground(.palette(.backgroundRed))
        controller.updateState(
            DrawingToolbarState(annotationController: annotationController)
        )
        let fillOnFrame = controller.inspectorFrameForTesting
        annotationController.setShapeBackground(nil)
        controller.updateState(
            DrawingToolbarState(annotationController: annotationController)
        )
        let fillOffAgainFrame = controller.inspectorFrameForTesting

        func inspectorHugsCurrentContent(_ frame: CGRect) -> Bool {
            abs(
                frame.height
                    - controller.propertiesContentSizeForTesting.height
                    - DrawingInspectorVisualMetrics.attachedVerticalInset * 2
            ) <= 1
                && controller.propertiesContentSizeForTesting.height
                    == controller.propertiesFittingHeightForTesting
                && abs(
                    controller.inspectorDocumentSizeForTesting.height
                        - controller.inspectorViewportSizeForTesting.height
                ) <= 1
                && !controller.inspectorHasHorizontalScrollerForTesting
        }

        try expect(
            controller.toolbarFrameForTesting == toolbarFrameBeforeHeightTransitions
                && fillOnFrame.height > fillOffFrame.height
                && fillOffAgainFrame.height == fillOffFrame.height
                && inspectorHugsCurrentContent(fillOffAgainFrame)
                && availableFrame.contains(fillOffFrame)
                && availableFrame.contains(fillOnFrame)
                && availableFrame.contains(fillOffAgainFrame),
            "Expected Fill off/on/off to grow and shrink the attached inspector exactly "
                + "without moving the toolbar or leaving scrollable empty space"
        )

        annotationController.setShapeBackground(.palette(.backgroundRed))
        controller.updateState(
            DrawingToolbarState(annotationController: annotationController)
        )
        let tallFrame = controller.inspectorFrameForTesting
        annotationController.currentTool = .highlighter
        controller.updateState(
            DrawingToolbarState(annotationController: annotationController)
        )
        let shortFrame = controller.inspectorFrameForTesting
        annotationController.currentTool = .rectangle
        controller.updateState(
            DrawingToolbarState(annotationController: annotationController)
        )
        let tallAgainFrame = controller.inspectorFrameForTesting
        try expect(
            controller.toolbarFrameForTesting == toolbarFrameBeforeHeightTransitions
                && tallFrame.height > shortFrame.height
                && tallAgainFrame.height == tallFrame.height
                && inspectorHugsCurrentContent(tallAgainFrame)
                && availableFrame.contains(tallFrame)
                && availableFrame.contains(shortFrame)
                && availableFrame.contains(tallAgainFrame),
            "Expected tall-to-short-to-tall tool transitions to restore the exact fitting height "
                + "while preserving the adjoining toolbar edge"
        )

        annotationController.setShapeBackground(nil)
        controller.updateState(
            DrawingToolbarState(annotationController: annotationController)
        )
        try expect(
            controller.inspectorIsVisibleForTesting
                && controller.toolbarFrameForTesting == selectEdgeToolbarFrame,
            "Expected a hidden-to-visible tool transition to place the inspector around the current toolbar"
        )

        annotationController.currentTool = .eraser
        controller.updateState(
            DrawingToolbarState(annotationController: annotationController)
        )
        let staleEraserInspectorFrame = controller.inspectorFrameForTesting
        controller.applyDragSampleForTesting(
            proposedOrigin: CGPoint(
                x: visibleFrame.maxX + 1_000,
                y: visibleFrame.maxY + 1_000
            ),
            visibleFrame: visibleFrame
        )
        let eraserEdgeToolbarFrame = controller.toolbarFrameForTesting
        try expect(
            !controller.inspectorIsVisibleForTesting
                && abs(eraserEdgeToolbarFrame.maxX - availableFrame.maxX) < 0.001
                && abs(eraserEdgeToolbarFrame.maxY - availableFrame.maxY) < 0.001
                && controller.inspectorFrameForTesting == staleEraserInspectorFrame,
            "Expected Eraser edge dragging to clamp only the toolbar despite stale inspector geometry"
        )

        annotationController.currentTool = .rectangle
        controller.updateState(
            DrawingToolbarState(annotationController: annotationController)
        )
        let toolbarFrame = controller.toolbarFrameForTesting
        let inspectorFrame = controller.inspectorFrameForTesting
        let offset = CGPoint(
            x: inspectorFrame.minX - toolbarFrame.minX,
            y: inspectorFrame.minY - toolbarFrame.minY
        )
        controller.applyDragSampleForTesting(
            proposedOrigin: CGPoint(
                x: visibleFrame.minX - 1_000,
                y: visibleFrame.minY - 1_000
            ),
            visibleFrame: visibleFrame
        )
        let clampedToolbarFrame = controller.toolbarFrameForTesting
        let clampedInspectorFrame = controller.inspectorFrameForTesting
        controller.persistCurrentToolbarPositionForTesting(
            visibleFrame: visibleFrame
        )
        let expectedPersistedPosition = DrawingToolbarPlacement
            .normalizedPosition(
                origin: clampedToolbarFrame.origin,
                panelSize: clampedToolbarFrame.size,
                visibleFrame: visibleFrame
            )
        try expect(
            controller.inspectorIsVisibleForTesting
                && clampedInspectorFrame.minX - clampedToolbarFrame.minX == offset.x
                && clampedInspectorFrame.minY - clampedToolbarFrame.minY == offset.y
                && availableFrame.contains(
                    clampedToolbarFrame.union(clampedInspectorFrame)
                ),
            "Expected visible combined dragging to preserve the exact inspector offset and clamp both frames"
        )
        try expect(
            persistedToolbarPosition == expectedPersistedPosition,
            "Expected a completed grip drag to persist the clamped toolbar position"
        )

        controller.close()
        parent.close()
    }
}
