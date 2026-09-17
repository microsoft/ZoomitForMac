import AppKit

extension SelfTestRunner {
    static func testDrawingStyleSessionScoping() throws {
        let controller = AnnotationController()
        controller.applyDrawingDefaults(
            .default,
            strokeWidth: 7,
            highlighterWidth: 18,
            geometryWidth: 3
        )
        controller.currentTool = .pen
        controller.setStrokeColor(.palette(.green))
        controller.setOpacity(0.4)
        controller.currentTool = .highlighter
        controller.setStrokeColor(.palette(.highlighterPink))
        controller.setOpacity(0.8)

        controller.reset()
        controller.applyDrawingDefaults(
            .default,
            strokeWidth: 7,
            highlighterWidth: 18,
            geometryWidth: 3
        )
        controller.currentTool = .highlighter
        let freshHighlighterColor = controller.currentStyle.strokeColor
        let freshHighlighterWidth = controller.currentStyle.strokeWidth
        let freshHighlighterOpacity = controller.currentStyle.opacity
        controller.currentTool = .pen
        try expect(
            freshHighlighterColor == .palette(.highlighterYellow)
                && freshHighlighterWidth == 18
                && freshHighlighterOpacity == 1
                && controller.currentStyle.strokeColor == .palette(.red)
                && controller.currentStyle.strokeWidth == 7
                && controller.currentStyle.opacity == 1,
            "Expected a non-remembered overlay session to restore independent fresh colors, widths, and opacities"
        )

        var rememberedDefaults = DrawingDefaults.default
        rememberedDefaults.tool = .highlighter
        rememberedDefaults.strokeColor = .palette(.highlighterPink)
        rememberedDefaults.regularStrokeColor = .palette(.green)
        rememberedDefaults.highlighterStrokeColor = .palette(.highlighterPink)
        rememberedDefaults.penStrokeWidth = 11
        rememberedDefaults.highlighterStrokeWidth = 28
        rememberedDefaults.geometryStrokeWidth = 6
        rememberedDefaults.penOpacity = 0.4
        rememberedDefaults.geometryOpacity = 0.65
        rememberedDefaults.highlighterOpacity = 0.8
        rememberedDefaults.opacity = 0.8
        rememberedDefaults.pressureMode = .simulated
        rememberedDefaults.freehandSloppiness = .cartoonist
        rememberedDefaults.outlinedSloppiness = .architect
        rememberedDefaults.synchronizeSelectedSloppiness()
        let suiteName = "ZoomItMacSelfTest.DrawingStyleScopes.\(UUID().uuidString)"
        guard let userDefaults = UserDefaults(suiteName: suiteName) else {
            throw SelfTestError.failure("Could not create drawing-style UserDefaults suite")
        }
        defer { userDefaults.removePersistentDomain(forName: suiteName) }
        let store = UserDefaultsSettingsStore(defaults: userDefaults)
        var settings = AppSettings.defaults
        settings.rememberLastDrawingStyle = true
        settings.lastDrawingDefaults = rememberedDefaults
        store.save(settings)

        let reloaded = store.load()
        guard let persistedDefaults = reloaded.lastDrawingDefaults else {
            throw SelfTestError.failure("Expected remembered drawing defaults to persist")
        }
        controller.reset()
        controller.applyDrawingDefaults(
            persistedDefaults,
            strokeWidth: reloaded.rootPenWidth
        )
        let rememberedHighlighterColor = controller.currentStyle.strokeColor
        let rememberedHighlighterWidth = controller.currentStyle.strokeWidth
        controller.currentTool = .pen
        let rememberedRegularColor = controller.currentStyle.strokeColor
        let rememberedPenWidth = controller.currentStyle.strokeWidth
        let rememberedPenPressure = controller.currentStyle.pressureMode
        let rememberedPenSloppiness = controller.currentStyle.sloppiness
        let rememberedPenOpacity = controller.currentStyle.opacity
        controller.currentTool = .rectangle
        let rememberedOutlinedSloppiness = controller.currentStyle.sloppiness
        let rememberedGeometryOpacity = controller.currentStyle.opacity
        controller.currentTool = .highlighter
        try expect(
            reloaded.rememberLastDrawingStyle
                && rememberedHighlighterColor == .palette(.highlighterPink)
                && rememberedHighlighterWidth == 28
                && rememberedRegularColor == .palette(.green)
                && rememberedPenWidth == 11
                && rememberedPenPressure == .simulated
                && rememberedPenSloppiness == .cartoonist
                && rememberedPenOpacity == 0.4
                && rememberedOutlinedSloppiness == .architect
                && rememberedGeometryOpacity == 0.65
                && controller.currentStyle.strokeColor == .palette(.highlighterPink)
                && controller.currentStyle.strokeWidth == 28
                && controller.currentStyle.opacity == 0.8,
            "Expected remembered color, width, pressure, sloppiness, and opacity scopes to persist independently"
        )
    }

    static func testContinuousStyleUndoAndAtomicLegacyColor() throws {
        let controller = AnnotationController()
        controller.currentTool = .rectangle
        controller.begin(at: CGPoint(x: 10, y: 10))
        controller.end(at: CGPoint(x: 70, y: 70))
        controller.currentTool = .select
        _ = controller.beginSelectionInteraction(
            at: CGPoint(x: 12, y: 40),
            zoomScale: 1,
            modifiers: [],
            clickCount: 1
        )
        controller.endSelectionInteraction(at: CGPoint(x: 12, y: 40), modifiers: [])

        let originalStyle = controller.selectedElementSnapshot[0].style
        controller.beginContinuousStyleEdit(owner: .opacitySlider)
        controller.setOpacity(0.8)
        controller.setOpacity(0.6)
        controller.setOpacity(0.4)
        controller.endContinuousStyleEdit(owner: .opacitySlider)
        try expect(
            controller.selectedElementSnapshot[0].style.opacity == 0.4,
            "Expected continuous opacity updates to reach the final slider value"
        )
        controller.undo()
        try expect(
            controller.selectedElementSnapshot[0].style == originalStyle,
            "Expected one undo to revert the complete continuous opacity edit"
        )
        controller.redo()

        let beforeOverlappingEdit = controller.selectedElementSnapshot[0].style
        controller.beginContinuousStyleEdit(owner: .colorPicker)
        controller.setStrokeColor(.palette(.green))
        controller.beginContinuousStyleEdit(owner: .opacitySlider)
        controller.setOpacity(0.7)
        try expect(
            !controller.endContinuousStyleEdit(owner: .colorPicker)
                && controller.hasActiveContinuousStyleEdit
                && !controller.endContinuousStyleEdit(owner: .colorPicker),
            "Expected closing the color owner to leave an overlapping opacity edit active"
        )
        try expect(
            controller.endContinuousStyleEdit(owner: .opacitySlider)
                && !controller.hasActiveContinuousStyleEdit
                && controller.selectedElementSnapshot[0].style.strokeColor
                    == .palette(.green)
                && controller.selectedElementSnapshot[0].style.opacity == 0.7,
            "Expected the final owner to commit the combined continuous style edit once"
        )
        controller.undo()
        try expect(
            controller.selectedElementSnapshot[0].style == beforeOverlappingEdit,
            "Expected one undo to revert overlapping picker and slider edits atomically"
        )
        controller.redo()

        let beforeHighlightShortcut = controller.selectedElementSnapshot[0].style
        controller.setLegacyColor(.yellow, highlighted: true)
        let highlighted = controller.selectedElementSnapshot[0].style
        try expect(
            highlighted.strokeColor == .palette(.yellow)
                && highlighted.opacity == AnnotationStyle.highlightAlpha
                && highlighted.usesLegacyHighlightCompositing,
            "Expected legacy highlight color and opacity to update atomically"
        )
        controller.undo()
        try expect(
            controller.selectedElementSnapshot[0].style == beforeHighlightShortcut,
            "Expected one undo to restore color, opacity, and highlight semantics together"
        )
    }

    static func testPenPressureAndSelectionStyleScopes() throws {
        let pressureController = AnnotationController()
        pressureController.currentTool = .pen
        pressureController.setPressureMode(.simulated)
        pressureController.currentTool = .highlighter
        try expect(
            pressureController.currentStyle.pressureMode == .fixed,
            "Expected Highlighter creation to retain fixed pressure"
        )
        pressureController.currentTool = .pen
        try expect(
            pressureController.currentStyle.pressureMode == .simulated
                && pressureController.preferredVariablePressureMode == .simulated,
            "Expected Pen to restore its mouse-speed pressure choice after Highlighter"
        )
        pressureController.setPressureMode(.tablet)
        pressureController.currentTool = .highlighter
        pressureController.currentStyle.pressureMode = .simulated
        pressureController.currentTool = .pen
        try expect(
            pressureController.currentStyle.pressureMode == .tablet
                && pressureController.preferredVariablePressureMode == .tablet,
            "Expected Highlighter normalization not to overwrite Pen tablet pressure"
        )

        pressureController.currentTool = .highlighter
        let rememberedPressure = DrawingDefaults(
            tool: pressureController.currentTool,
            style: pressureController.drawingDefaultsStyle,
            smartDrawEnabled: false,
            linearRoute: .straight,
            startArrowhead: .none,
            endArrowhead: .arrow,
            regularStrokeColor: pressureController
                .drawingDefaultsRegularStrokeColor,
            highlighterStrokeColor: pressureController
                .drawingDefaultsHighlighterStrokeColor,
            penStrokeWidth: pressureController.drawingDefaultsPenStrokeWidth,
            highlighterStrokeWidth: pressureController
                .drawingDefaultsHighlighterStrokeWidth,
            geometryStrokeWidth: pressureController
                .drawingDefaultsGeometryStrokeWidth,
            freehandSloppiness: pressureController
                .drawingDefaultsFreehandSloppiness,
            outlinedSloppiness: pressureController
                .drawingDefaultsOutlinedSloppiness
        )
        let restoredPressureController = AnnotationController()
        restoredPressureController.applyDrawingDefaults(
            rememberedPressure,
            strokeWidth: 7
        )
        try expect(
            restoredPressureController.currentStyle.pressureMode == .fixed,
            "Expected remembered Highlighter presentation to remain fixed"
        )
        restoredPressureController.currentTool = .pen
        try expect(
            restoredPressureController.currentStyle.pressureMode == .tablet,
            "Expected remembered Pen pressure to survive a Highlighter last-tool state"
        )

        let selectionController = AnnotationController()
        selectionController.currentTool = .pen
        selectionController.setStrokeColor(.palette(.blue))
        selectionController.currentTool = .highlighter
        selectionController.setStrokeColor(.palette(.highlighterOrange))
        selectionController.begin(at: CGPoint(x: 12, y: 36))
        selectionController.end(at: CGPoint(x: 84, y: 36))
        selectionController.currentTool = .select
        selectionController.selectAll()
        selectionController.setStrokeColor(.palette(.highlighterPink))
        try expect(
            selectionController.selectedElementSnapshot.first?.style.strokeColor
                == .palette(.highlighterPink),
            "Expected selected Highlighter color edits to update the element"
        )
        selectionController.currentTool = .pen
        let penColor = selectionController.currentStyle.strokeColor
        selectionController.currentTool = .rectangle
        let shapeColor = selectionController.currentStyle.strokeColor
        selectionController.currentTool = .highlighter
        try expect(
            penColor == .palette(.blue)
                && shapeColor == .palette(.blue)
                && selectionController.currentStyle.strokeColor
                    == .palette(.highlighterOrange),
            "Expected selection-only Highlighter edits not to corrupt Pen, shape, "
                + "or Highlighter creation color scopes"
        )
    }

    static func testPenOpacityScopes() throws {
        let controller = AnnotationController()
        controller.currentTool = .pen
        controller.setOpacity(0.4)
        controller.currentTool = .highlighter
        controller.setOpacity(0.8)
        controller.currentTool = .pen
        try expect(
            controller.currentStyle.opacity == 0.4,
            "Expected Pen 0.4 -> Highlighter 0.8 -> Pen to restore 0.4"
        )

        controller.currentTool = .rectangle
        controller.setOpacity(0.65)
        controller.currentTool = .pen
        try expect(
            controller.currentStyle.opacity == 0.4,
            "Expected Pen opacity to survive a Rectangle 0.65 roundtrip"
        )
        controller.currentTool = .rectangle
        try expect(
            controller.currentStyle.opacity == 0.65,
            "Expected geometry opacity to remain independent from Pen"
        )
        controller.currentTool = .highlighter
        try expect(
            controller.currentStyle.opacity == 0.8,
            "Expected Highlighter opacity to remain independent from Pen and geometry"
        )

        controller.begin(at: CGPoint(x: 10, y: 10))
        controller.end(at: CGPoint(x: 80, y: 10))
        controller.currentTool = .select
        controller.selectAll()
        controller.setOpacity(0.25)
        controller.currentTool = .pen
        let penOpacityAfterSelectionEdit = controller.currentStyle.opacity
        controller.currentTool = .rectangle
        let geometryOpacityAfterSelectionEdit = controller.currentStyle.opacity
        controller.currentTool = .highlighter
        try expect(
            penOpacityAfterSelectionEdit == 0.4
                && geometryOpacityAfterSelectionEdit == 0.65
                && controller.currentStyle.opacity == 0.8,
            "Expected selection-only opacity edits not to corrupt creation scopes"
        )

        let rememberedDefaults = DrawingDefaults(
            tool: .highlighter,
            style: controller.drawingDefaultsStyle,
            smartDrawEnabled: false,
            linearRoute: .straight,
            startArrowhead: .none,
            endArrowhead: .arrow,
            regularStrokeColor: controller.drawingDefaultsRegularStrokeColor,
            highlighterStrokeColor:
                controller.drawingDefaultsHighlighterStrokeColor,
            penStrokeWidth: controller.drawingDefaultsPenStrokeWidth,
            highlighterStrokeWidth:
                controller.drawingDefaultsHighlighterStrokeWidth,
            geometryStrokeWidth:
                controller.drawingDefaultsGeometryStrokeWidth,
            penOpacity: controller.drawingDefaultsPenOpacity,
            geometryOpacity: controller.drawingDefaultsGeometryOpacity,
            highlighterOpacity: controller.drawingDefaultsHighlighterOpacity,
            freehandSloppiness:
                controller.drawingDefaultsFreehandSloppiness,
            outlinedSloppiness:
                controller.drawingDefaultsOutlinedSloppiness
        )
        let restored = AnnotationController()
        restored.applyDrawingDefaults(rememberedDefaults, strokeWidth: 7)
        restored.currentTool = .pen
        let restoredPenOpacity = restored.currentStyle.opacity
        restored.currentTool = .rectangle
        let restoredGeometryOpacity = restored.currentStyle.opacity
        restored.currentTool = .highlighter
        try expect(
            restoredPenOpacity == 0.4
                && restoredGeometryOpacity == 0.65
                && restored.currentStyle.opacity == 0.8,
            "Expected remembered opacity scopes to restore independently"
        )

        let reset = AnnotationController()
        reset.currentTool = .pen
        reset.setOpacity(0.4)
        reset.reset()
        try expect(
            reset.currentTool == .pen
                && reset.currentStyle.opacity == 1
                && reset.drawingDefaultsPenOpacity == 1,
            "Expected a nonremembered session to reset Pen opacity to defaults"
        )
    }

    static func testHighlighterGeometryStyleIsolation() throws {
        let geometryTools: [AnnotationTool] = [
            .line, .arrow, .rectangle, .diamond, .ellipse
        ]

        func expectGeometryStyle(
            _ style: AnnotationStyle,
            strokeColor: AnnotationColorValue,
            width: CGFloat,
            pattern: AnnotationStrokePattern,
            sloppiness: AnnotationSloppiness,
            opacity: CGFloat,
            fillColor: AnnotationColorValue,
            fillStyle: AnnotationFillStyle,
            context: String
        ) throws {
            try expect(
                style.strokeColor == strokeColor
                    && style.strokeWidth == width
                    && style.strokePattern == pattern
                    && style.sloppiness == sloppiness
                    && style.opacity == opacity
                    && style.fillColor == fillColor
                    && style.fillStyle == fillStyle
                    && style.lineCap == .round
                    && style.lineJoin == .round
                    && style.pressureMode == .fixed
                    && !style.usesLegacyHighlightCompositing,
                context
            )
        }

        for tool in geometryTools {
            let controller = AnnotationController()
            controller.currentTool = .highlighter
            controller.setStrokeColor(.palette(.highlighterPink))
            controller.setStrokeWidth(28)
            controller.setOpacity(0.35)
            controller.currentTool = tool
            try expectGeometryStyle(
                controller.currentStyle,
                strokeColor: .palette(.red),
                width: AnnotationStrokeWidthDefaults.geometry,
                pattern: .solid,
                sloppiness: tool == .line ? .architect : .artist,
                opacity: 1,
                fillColor: .palette(.red),
                fillStyle: .none,
                context: "Expected \(tool) selection after Highlighter to restore complete geometry defaults"
            )
        }

        let roundTripController = AnnotationController()
        roundTripController.currentTool = .rectangle
        roundTripController.setStrokeColor(.palette(.blue))
        roundTripController.setStrokeWidth(6)
        roundTripController.setStrokePattern(.dotted)
        roundTripController.setSloppiness(.cartoonist)
        roundTripController.setShapeBackground(.palette(.orange))
        roundTripController.setFillStyle(.solid)
        roundTripController.setOpacity(0.65)
        let geometryStyle = roundTripController.currentStyle

        roundTripController.currentTool = .highlighter
        roundTripController.setStrokeColor(.palette(.highlighterGreen))
        roundTripController.setStrokeWidth(28)
        roundTripController.setOpacity(0.4)
        let highlighterStyle = roundTripController.currentStyle

        for tool in geometryTools {
            roundTripController.currentTool = tool
            try expectGeometryStyle(
                roundTripController.currentStyle,
                strokeColor: geometryStyle.strokeColor,
                width: geometryStyle.strokeWidth,
                pattern: geometryStyle.strokePattern,
                sloppiness: tool == .line
                    ? .architect
                    : geometryStyle.sloppiness,
                opacity: geometryStyle.opacity,
                fillColor: geometryStyle.fillColor,
                fillStyle: geometryStyle.fillStyle,
                context: "Expected \(tool) to restore the pre-Highlighter geometry scope"
            )
            roundTripController.currentTool = .highlighter
            try expect(
                roundTripController.currentStyle == highlighterStyle,
                "Expected Highlighter presentation to survive a \(tool) roundtrip"
            )
        }

        let rememberedDefaults = DrawingDefaults(
            tool: roundTripController.currentTool,
            style: roundTripController.drawingDefaultsStyle,
            smartDrawEnabled: false,
            linearRoute: .straight,
            startArrowhead: .none,
            endArrowhead: .arrow,
            regularStrokeColor: roundTripController
                .drawingDefaultsRegularStrokeColor,
            highlighterStrokeColor: roundTripController
                .drawingDefaultsHighlighterStrokeColor,
            penStrokeWidth: roundTripController.drawingDefaultsPenStrokeWidth,
            highlighterStrokeWidth: roundTripController
                .drawingDefaultsHighlighterStrokeWidth,
            geometryStrokeWidth: roundTripController
                .drawingDefaultsGeometryStrokeWidth,
            geometryOpacity: roundTripController
                .drawingDefaultsGeometryOpacity,
            highlighterOpacity: roundTripController
                .drawingDefaultsHighlighterOpacity,
            freehandSloppiness: roundTripController
                .drawingDefaultsFreehandSloppiness,
            outlinedSloppiness: roundTripController
                .drawingDefaultsOutlinedSloppiness
        )
        let restoredController = AnnotationController()
        restoredController.applyDrawingDefaults(
            rememberedDefaults,
            strokeWidth: AnnotationStrokeWidthDefaults.pen
        )
        try expect(
            restoredController.currentStyle == highlighterStyle,
            "Expected persisted Highlighter scope to restore independently"
        )
        restoredController.currentTool = .rectangle
        try expectGeometryStyle(
            restoredController.currentStyle,
            strokeColor: geometryStyle.strokeColor,
            width: geometryStyle.strokeWidth,
            pattern: geometryStyle.strokePattern,
            sloppiness: geometryStyle.sloppiness,
            opacity: geometryStyle.opacity,
            fillColor: geometryStyle.fillColor,
            fillStyle: geometryStyle.fillStyle,
            context: "Expected persisted geometry scope to survive a Highlighter last-tool state"
        )

        let gestureController = AnnotationController()
        gestureController.currentTool = .rectangle
        gestureController.setStrokeColor(.palette(.green))
        gestureController.setStrokeWidth(6)
        gestureController.setStrokePattern(.dashed)
        gestureController.setSloppiness(.cartoonist)
        gestureController.setShapeBackground(.palette(.yellow))
        gestureController.setFillStyle(.solid)
        gestureController.setOpacity(0.7)
        gestureController.currentTool = .highlighter
        gestureController.setStrokeColor(.palette(.highlighterOrange))
        gestureController.setStrokeWidth(28)
        gestureController.setOpacity(0.3)
        let preservedHighlighterStyle = gestureController.currentStyle
        let gestures: [(
            control: Bool,
            shift: Bool,
            tab: Bool,
            tool: AnnotationTool
        )] = [
            (false, true, false, .line),
            (true, false, false, .rectangle),
            (true, true, false, .arrow),
            (false, false, true, .ellipse)
        ]

        for (index, gesture) in gestures.enumerated() {
            guard let tool = ZoomCanvasView.gestureTool(
                control: gesture.control,
                shift: gesture.shift,
                tab: gesture.tab,
                selectedTool: .highlighter
            ), tool == gesture.tool else {
                throw SelfTestError.failure(
                    "Expected modifier gesture to resolve \(gesture.tool)"
                )
            }
            let y = CGFloat(index * 20)
            gestureController.begin(
                at: CGPoint(x: 10, y: y),
                tool: tool,
                legacyModifierGesture: tool == .line || tool == .arrow
            )
            gestureController.end(at: CGPoint(x: 80, y: y + 10))
            guard let element = gestureController.elementSnapshot.last else {
                throw SelfTestError.failure(
                    "Expected modifier gesture to create \(tool)"
                )
            }
            try expectGeometryStyle(
                element.style,
                strokeColor: .palette(.green),
                width: 6,
                pattern: .dashed,
                sloppiness: tool == .line ? .architect : .cartoonist,
                opacity: 0.7,
                fillColor: .palette(.yellow),
                fillStyle: .solid,
                context: "Expected \(tool) modifier gesture to use the isolated geometry scope"
            )
            try expect(
                gestureController.currentTool == .highlighter
                    && gestureController.currentStyle == preservedHighlighterStyle,
                "Expected transient \(tool) gesture to preserve the selected Highlighter scope"
            )
        }
    }
}
