import AppKit

extension SelfTestRunner {
    static func testDrawingInspectorControlMappingsAndTextPresets() throws {
        try expect(
            DrawingInspectorControlMapping.fillStyles
                == [.hachure, .crossHatch, .solid]
                && DrawingInspectorControlMapping.strokeWidths.count == 3
                && DrawingInspectorControlMapping.strokePatterns.count == 3
                && DrawingInspectorControlMapping.sloppiness.count == 3
                && DrawingInspectorControlMapping.edgeStyles.count == 2
                && DrawingInspectorControlMapping.linearRoutes
                    == [.straight, .curved]
                && SettingsWindowController.drawingLinearRouteOptionsForTesting
                    == ["Straight", "Curved"]
                && DrawingInspectorControlMapping.arrowheadSizes
                    == [.small, .medium, .large]
                && DrawingInspectorControlMapping.layerActions.map(\.action)
                    == [.sendToBack, .sendBackward, .bringForward, .bringToFront]
                && DrawingInspectorControlMapping.pressureOptions.count == 2
                && DrawingInspectorControlMapping.textFontPresets.count == 3
                && DrawingInspectorControlMapping.textSizes.count == 4
                && DrawingInspectorControlMapping.textAlignments.count == 3
                && DrawingInspectorControlMapping.strokeColors.count == 5
                && DrawingInspectorControlMapping.highlighterColors.count == 5
                && DrawingInspectorControlMapping.backgroundColors.count == 4,
            "Expected exact compact option and preset-color counts"
        )
        try expect(
            AnnotationLinearRoute.route(forOptionShortcut: "1") == .straight
                && AnnotationLinearRoute.route(forOptionShortcut: "2") == .curved
                && AnnotationLinearRoute.route(forOptionShortcut: "3") == nil,
            "Expected only Option+1 and Option+2 to expose user-selectable routes"
        )
        let expectedHighlighterRGB: [(AnnotationColor, (Int, Int, Int))] = [
            (.highlighterYellow, (255, 244, 92)),
            (.highlighterCyan, (50, 215, 255)),
            (.highlighterPink, (255, 92, 173)),
            (.highlighterGreen, (102, 242, 111)),
            (.highlighterOrange, (255, 159, 67))
        ]
        try expect(
            zip(
                DrawingInspectorControlMapping.highlighterColors,
                expectedHighlighterRGB
            ).allSatisfy { actual, expected in
                guard actual == expected.0,
                      let color = actual.nsColor.usingColorSpace(.sRGB) else {
                    return false
                }
                return Int((color.redComponent * 255).rounded()) == expected.1.0
                    && Int((color.greenComponent * 255).rounded()) == expected.1.1
                    && Int((color.blueComponent * 255).rounded()) == expected.1.2
            },
            "Expected the exact neon sRGB Highlighter palette"
        )
        try expect(
            DrawingInspectorControlMapping.fillStyleCommand(at: 0) == .setFillStyle(.hachure)
                && DrawingInspectorControlMapping.fillStyleCommand(at: 1)
                    == .setFillStyle(.crossHatch)
                && DrawingInspectorControlMapping.fillStyleCommand(at: 2)
                    == .setFillStyle(.solid)
                && DrawingInspectorControlMapping.fillStyleCommand(at: -1) == nil,
            "Expected fill palette indices to map to typed commands"
        )
        try expect(
            DrawingInspectorSection.allCases.map(\.title) == [
                "Stroke",
                "Background",
                "Fill",
                "Stroke width",
                "Stroke style",
                "Sloppiness",
                "Edges",
                "Arrow type",
                "Arrowheads",
                "Arrowhead size",
                "Smart Draw",
                "Pressure",
                "Font family",
                "Font size",
                "Text align",
                "Opacity",
                "Layers"
            ],
            "Expected exact compact inspector section titles"
        )
        for (index, arrowhead) in DrawingInspectorControlMapping.arrowheads.enumerated() {
            try expect(
                DrawingInspectorControlMapping.startArrowheadCommand(at: index)
                    == .setLinearStartArrowhead(arrowhead)
                    && DrawingInspectorControlMapping.endArrowheadCommand(at: index)
                        == .setLinearEndArrowhead(arrowhead),
                "Expected arrowhead palette index \(index) to preserve endpoint direction"
            )
        }

        try expect(
            DrawingInspectorControlMapping.startArrowheadCommand(
                at: DrawingInspectorControlMapping.arrowheads.count
            ) == nil,
            "Expected out-of-range arrowhead palette commands to be rejected"
        )
        for (index, preset) in DrawingInspectorControlMapping.textFontPresets.enumerated() {
            try expect(
                DrawingInspectorControlMapping.textFontPresetCommand(at: index)
                    == .setTextFontPreset(preset),
                "Expected font palette index \(index) to map to a typed preset command"
            )
        }
        try expect(
            DrawingInspectorControlMapping.textSizeCommand(at: 3) == .setTextFontSize(72),
            "Expected Very large text to map to the 72 point preset"
        )
        let pressureController = AnnotationController()
        try expect(
            DrawingToolbarState(annotationController: pressureController)
                .preferredVariablePressureMode == .simulated,
            "Expected Variable pressure to use mouse-speed input without a tablet"
        )
        pressureController.noteTabletInputAvailable()
        try expect(
            DrawingToolbarState(annotationController: pressureController)
                .preferredVariablePressureMode == .tablet,
            "Expected Variable pressure to prefer an observed tablet input"
        )

        let controller = AnnotationController()
        controller.typingFontName = "Helvetica"
        controller.setTextFontPreset(.typeSetting)
        controller.currentTool = .text
        controller.setInsertionPoint(CGPoint(x: 20, y: 20))
        controller.beginTypingSession(rightAligned: false)
        controller.insertText("Custom")
        controller.finishTypingSession()
        controller.setTextFontPreset(.system)
        controller.setInsertionPoint(CGPoint(x: 20, y: 60))
        controller.beginTypingSession(rightAligned: false)
        controller.insertText("System")
        controller.finishTypingSession()
        let originalFontNames: [String] = controller.elementSnapshot.compactMap {
            element -> String? in
            guard case .text(let text) = element.geometry else { return nil }
            return text.fontName
        }

        controller.currentTool = .select
        controller.selectAll()
        controller.setTextFontPreset(.serif)
        try expect(
            controller.selectedElementSnapshot.allSatisfy {
                guard case .text(let text) = $0.geometry else { return false }
                return text.fontName == AnnotationTextFontPreset.serifStorageName
            },
            "Expected one font preset command to update every editable selected text element"
        )
        controller.undo()
        let restoredFontNames: [String] = controller.elementSnapshot.compactMap {
            element -> String? in
            guard case .text(let text) = element.geometry else { return nil }
            return text.fontName
        }
        try expect(
            restoredFontNames == originalFontNames,
            "Expected one undo to restore the complete text font preset mutation"
        )
        try expect(
            controller.typingFontName == "Helvetica",
            "Expected native preset changes to preserve the custom Type settings font"
        )
        controller.setTextFontName("Courier")
        try expect(
            controller.typingFontPreset == .system
                && controller.typingFontName == "Helvetica"
                && controller.selectedElementSnapshot.allSatisfy {
                    guard case .text(let text) = $0.geometry else { return false }
                    return text.fontName == "Courier"
                },
            "Expected the compact font picker to update selected text without "
                + "overwriting text creation defaults"
        )

        let presetNames = [
            AnnotationTextFontPreset.roundedStorageName,
            AnnotationTextFontPreset.serifStorageName,
            AnnotationTextFontPreset.monospacedStorageName
        ]
        try expect(
            presetNames.allSatisfy {
                AnnotationController.typingFont(named: $0, size: 24).pointSize == 24
            },
            "Expected every safe native font preset to resolve at the requested size"
        )
        let handDrawnFont = AnnotationController.typingFont(
            named: AnnotationTextFontPreset.roundedStorageName,
            size: 24
        )
        let normalFont = AnnotationController.typingFont(named: "", size: 24)
        let codeFont = AnnotationController.typingFont(
            named: AnnotationTextFontPreset.monospacedStorageName,
            size: 24
        )
        let fontPreviewSignatures = try [
            AnnotationTextFontPreset.rounded,
            .system,
            .monospaced
        ].map {
            try previewAlphaSignature(
                .textFont($0, customFontName: nil)
            )
        }
        try expect(
            Set([
                handDrawnFont.fontName,
                normalFont.fontName,
                codeFont.fontName
            ]).count == 3
                && handDrawnFont.fontName != normalFont.fontName
                && codeFont.fontDescriptor.symbolicTraits.contains(.monoSpace)
                && Set(fontPreviewSignatures).count == 3,
            "Expected visibly distinct Hand-drawn, Normal sans, and Code mono fonts/previews"
        )
    }

    static func testDrawingInspectorVisualPreviewsAndWiring() throws {
        try expect(
            DrawingInspectorVisualMetrics.contentWidth == 261
                && DrawingInspectorVisualMetrics.tileSide == 32
                && DrawingInspectorVisualMetrics.colorTileSide == 38
                && DrawingInspectorVisualMetrics.customColorTileSide == 26
                && DrawingInspectorVisualMetrics.customColorCornerRadius == 5
                && DrawingInspectorVisualMetrics.tileSpacing == 8
                && DrawingInspectorVisualMetrics.swatchSpacing == 7
                && DrawingInspectorVisualMetrics.sectionSpacing == 16
                && DrawingInspectorVisualMetrics.attachedHorizontalChrome == 24,
            "Expected the audited compact inspector geometry"
        )
        let lightAppearance = NSAppearance(named: .aqua)
        let darkAppearance = NSAppearance(named: .darkAqua)
        let lightIdle = DrawingControlAppearanceResolver.resolve(
            DrawingControlVisualState(),
            appearance: lightAppearance
        )
        let lightHover = DrawingControlAppearanceResolver.resolve(
            DrawingControlVisualState(isHovered: true),
            appearance: lightAppearance
        )
        let lightPressed = DrawingControlAppearanceResolver.resolve(
            DrawingControlVisualState(isPressed: true),
            appearance: lightAppearance
        )
        let lightSelected = DrawingControlAppearanceResolver.resolve(
            DrawingControlVisualState(isSelected: true),
            appearance: lightAppearance
        )
        let lightMixed = DrawingControlAppearanceResolver.resolve(
            DrawingControlVisualState(isMixed: true),
            appearance: lightAppearance
        )
        let lightFocused = DrawingControlAppearanceResolver.resolve(
            DrawingControlVisualState(isFocused: true),
            appearance: lightAppearance
        )
        let lightDisabled = DrawingControlAppearanceResolver.resolve(
            DrawingControlVisualState(isEnabled: false),
            appearance: lightAppearance
        )
        let darkIdle = DrawingControlAppearanceResolver.resolve(
            DrawingControlVisualState(),
            appearance: darkAppearance
        )
        let darkHover = DrawingControlAppearanceResolver.resolve(
            DrawingControlVisualState(isHovered: true),
            appearance: darkAppearance
        )
        let darkPressed = DrawingControlAppearanceResolver.resolve(
            DrawingControlVisualState(isPressed: true),
            appearance: darkAppearance
        )
        let darkSelected = DrawingControlAppearanceResolver.resolve(
            DrawingControlVisualState(isSelected: true),
            appearance: darkAppearance
        )
        try expect(
            lightIdle.background.alpha == 0
                && lightIdle.border.alpha == 0
                && lightHover.background == DrawingControlColor(
                    red: 0xF1 / 255,
                    green: 0xF0 / 255,
                    blue: 1
                )
                && lightPressed.background == DrawingControlColor(
                    red: 0xEC / 255,
                    green: 0xEB / 255,
                    blue: 1
                )
                && lightPressed.border.alpha == 0
                && lightSelected.background == DrawingControlColor(
                    red: 0xE0 / 255,
                    green: 0xDF / 255,
                    blue: 1
                )
                && lightSelected.border.alpha == 0
                && lightSelected.content == DrawingControlColor(
                    red: 0x03 / 255,
                    green: 0,
                    blue: 0x64 / 255
                )
                && lightMixed.showsMixedIndicator
                && lightFocused.border == lightSelected.border
                && lightDisabled.contentOpacity == 0.38
                && lightDisabled.fillOpacity == 0.55,
            "Expected exact light idle, hover, pressed, selected, mixed, focused, and disabled states"
        )
        try expect(
            darkIdle.background.alpha == 0
                && darkIdle.border.alpha == 0
                && darkHover.background == DrawingControlColor(
                    red: 0x2E / 255,
                    green: 0x2D / 255,
                    blue: 0x39 / 255
                )
                && darkPressed.background == DrawingControlColor(
                    red: 0x40 / 255,
                    green: 0x3B / 255,
                    blue: 0x5F / 255
                )
                && darkPressed.border.alpha == 0
                && darkSelected.background == DrawingControlColor(
                    red: 0x40 / 255,
                    green: 0x3E / 255,
                    blue: 0x6A / 255
                )
                && darkSelected.border.alpha == 0
                && darkSelected.content == DrawingControlColor(
                    red: 0xE0 / 255,
                    green: 0xDF / 255,
                    blue: 1
                ),
            "Expected exact dark control-state equivalents"
        )
        let previewFamilies: [[DrawingInspectorPreview]] = [
            DrawingInspectorControlMapping.strokeWidths.map(DrawingInspectorPreview.strokeWidth),
            DrawingInspectorControlMapping.strokePatterns.map(
                DrawingInspectorPreview.strokePattern
            ),
            DrawingInspectorControlMapping.sloppiness.map(
                DrawingInspectorPreview.sloppiness
            ),
            DrawingInspectorControlMapping.fillStyles.map(DrawingInspectorPreview.fillStyle),
            DrawingInspectorControlMapping.edgeStyles.map(DrawingInspectorPreview.edges),
            DrawingInspectorControlMapping.linearRoutes.map(
                DrawingInspectorPreview.linearRoute
            ),
            [
                .textFont(.rounded, customFontName: "Helvetica"),
                .textFont(.system, customFontName: "Helvetica"),
                .textFont(.monospaced, customFontName: "Helvetica")
            ],
            DrawingInspectorControlMapping.textAlignments.map(
                DrawingInspectorPreview.textAlignment
            ),
            DrawingInspectorControlMapping.arrowheads.map {
                .arrowhead($0, pointsRight: true)
            },
            DrawingInspectorControlMapping.arrowheadSizes.map(
                DrawingInspectorPreview.arrowheadSize
            ),
            DrawingInspectorControlMapping.pressureOptions.map(
                DrawingInspectorPreview.pressure
            ),
            DrawingInspectorControlMapping.layerActions.map {
                .layer($0.action)
            },
            [.smartDraw]
        ]
        for (index, family) in previewFamilies.enumerated() {
            let signatures = family.compactMap { $0.image.tiffRepresentation }
            try expect(
                signatures.count == family.count
                    && Set(signatures).count == family.count,
                "Expected inspector preview family \(index) to draw distinct actual effects"
            )
        }

        var commands: [AppCommand] = []
        let inspector = DrawingPropertiesController(
            commandSink: { commands.append($0) },
            colorPanelActivityChanged: { _ in }
        )
        let root = inspector.view
        let expectedButtonCommands: [(String, AppCommand)] = [
            ("Hachure", .setFillStyle(.hachure)),
            ("Bold", .setStrokeWidth(6)),
            ("Dashed", .setStrokePattern(.dashed)),
            ("Cartoonist", .setSloppiness(.cartoonist)),
            ("Variable", .setPressureMode(.simulated)),
            ("Round", .setEdgeStyle(.round)),
            ("Curved arrow", .setLinearRoute(.curved)),
            ("Large", .setLinearArrowheadSize(.large)),
            ("Hand-drawn", .setTextFontPreset(.rounded)),
            ("Very large", .setTextFontSize(72)),
            ("Center", .setTextAlignment(.center)),
            ("Send to back", .arrangeSelection(.sendToBack)),
            ("Send backward", .arrangeSelection(.sendBackward)),
            ("Bring forward", .arrangeSelection(.bringForward)),
            ("Bring to front", .arrangeSelection(.bringToFront))
        ]
        let buttons = descendantViews(of: NSButton.self, in: root)
        let exactOptionTitles = [
            "Thin", "Medium", "Bold",
            "Solid", "Dashed", "Dotted",
            "Architect", "Artist", "Cartoonist",
            "Sharp", "Round",
            "Sharp arrow (straight)", "Curved arrow",
            "Constant", "Variable",
            "Smart Draw: Off",
            "Hand-drawn", "Normal", "Code",
            "Small", "Medium", "Large", "Very large",
            "Left", "Center", "Right",
            "Send to back", "Send backward", "Bring forward", "Bring to front"
        ]
        try expect(
            exactOptionTitles.allSatisfy { title in
                buttons.contains { $0.accessibilityLabel() == title }
            }
                && [
                    "10 point stroke",
                    "Soft edges",
                    "Rounded edges",
                    "Fixed",
                    "Tablet",
                    "Mouse speed",
                    "Serif",
                    "Mono",
                    "Type",
                    "Raw freehand stroke",
                    "Smoothed freehand stroke",
                    "Smart Draw on",
                    "Smart Draw off"
                ].allSatisfy { title in
                    !buttons.contains { $0.accessibilityLabel() == title }
                },
            "Expected exact compact option titles on programmatic preview controls"
        )
        for (label, expectedCommand) in expectedButtonCommands {
            guard let button = buttons.first(where: { $0.accessibilityLabel() == label }) else {
                throw SelfTestError.failure("Expected inspector button labeled \(label)")
            }
            commands.removeAll()
            button.performClick(nil)
            try expect(
                commands == [expectedCommand],
                "Expected \(label) to dispatch \(expectedCommand), got \(commands)"
            )
        }

        let colorButtonCommands: [(String, AppCommand)] = [
            ("Stroke Coral", .setStrokeColor(.palette(.strokeCoral))),
            ("Background Transparent", .setShapeBackground(nil)),
            (
                "Background Muted Red",
                .setShapeBackground(.palette(.backgroundRed))
            )
        ]
        for (label, expectedCommand) in colorButtonCommands {
            guard let button = buttons.first(where: { $0.accessibilityLabel() == label }) else {
                throw SelfTestError.failure("Expected color button labeled \(label)")
            }
            commands.removeAll()
            button.performClick(nil)
            try expect(
                commands == [expectedCommand],
                "Expected \(label) to dispatch its scoped color command"
            )
        }

        let penController = AnnotationController()
        penController.currentTool = .pen
        inspector.update(
            state: DrawingToolbarState(annotationController: penController)
        )
        guard let smartDrawButton = buttons.first(where: {
            $0.accessibilityLabel() == "Smart Draw: Off"
        }) else {
            throw SelfTestError.failure("Expected the Pen Smart Draw wand button")
        }
        commands.removeAll()
        smartDrawButton.performClick(nil)
        try expect(
            commands == [.setSmartDrawEnabled(true)],
            "Expected the Pen wand button to dispatch one clear Smart Draw toggle"
        )
        penController.setSmartDrawEnabled(true)
        inspector.update(
            state: DrawingToolbarState(annotationController: penController)
        )
        try expect(
            smartDrawButton.accessibilityLabel() == "Smart Draw: On"
                && smartDrawButton.accessibilityValue() as? String == "Selected",
            "Expected the Smart Draw wand to expose clear on/off selected state"
        )
        let restoredInspectorController = AnnotationController()
        restoredInspectorController.currentTool = .rectangle
        inspector.update(
            state: DrawingToolbarState(
                annotationController: restoredInspectorController
            )
        )

        let relocatedLabels = [
            "Edit Points",
            "Insert Point",
            "Remove Points",
            "Unbind Ends",
            "Group",
            "Ungroup",
            "Lock Selection",
            "Duplicate Selection",
            "Delete Selection",
            "Smart Draw on",
            "Raw freehand stroke"
        ]
        try expect(
            descendantViews(of: NSStepper.self, in: root).isEmpty
                && relocatedLabels.allSatisfy { label in
                    !buttons.contains { $0.accessibilityLabel() == label }
                }
                && DrawingToolbarOverflowActionTitle.relocatedSelectionActions == [
                    "Duplicate",
                    "Delete",
                    "Bring to Front",
                    "Bring Forward",
                    "Send Backward",
                    "Send to Back",
                    "Group",
                    "Ungroup",
                    "Lock Selection"
                ],
            "Expected fine adjustments and generic actions to stay outside the compact inspector"
        )

        let sliders = descendantViews(of: NSSlider.self, in: root)
        guard sliders.count == 1,
              let opacity = sliders.first(where: {
                  $0.accessibilityLabel() == "Opacity"
              }) else {
            throw SelfTestError.failure("Expected one shared compact opacity slider")
        }
        opacity.doubleValue = 0.4
        commands.removeAll()
        _ = opacity.sendAction(opacity.action, to: opacity.target)
        try expect(
            commands == [.setOpacity(0.4)],
            "Expected opacity slider changes to dispatch immediately"
        )

        let colorWells = descendantViews(of: NSColorWell.self, in: root)
        let customColor = NSColor(
            srgbRed: 0.25,
            green: 0.5,
            blue: 0.75,
            alpha: 1
        )
        let colorWellCommands: [(String, AppCommand)] = [
            (
                "Custom stroke color",
                .setStrokeColor(.rgba(red: 0.25, green: 0.5, blue: 0.75, alpha: 1))
            ),
            (
                "Custom background color",
                .setShapeBackground(
                    .rgba(red: 0.25, green: 0.5, blue: 0.75, alpha: 1)
                )
            )
        ]
        for (label, expectedCommand) in colorWellCommands {
            guard let colorWell = colorWells.first(where: {
                $0.accessibilityLabel() == label
            }) else {
                throw SelfTestError.failure("Expected color well labeled \(label)")
            }
            colorWell.color = customColor
            commands.removeAll()
            _ = colorWell.sendAction(colorWell.action, to: colorWell.target)
            try expect(
                commands == [expectedCommand],
                "Expected \(label) to dispatch its scoped custom color command"
            )
        }

        let arrowInspectorController = AnnotationController()
        arrowInspectorController.currentTool = .arrow
        inspector.update(
            state: DrawingToolbarState(
                annotationController: arrowInspectorController
            )
        )
        let arrowheadPickers = descendantViews(
            of: DrawingInspectorArrowheadPicker.self,
            in: root
        )
        guard let startPicker = arrowheadPickers.first(where: {
            $0.accessibilityLabel() == "Start arrowhead"
        }),
        let endPicker = arrowheadPickers.first(where: {
            $0.accessibilityLabel() == "End arrowhead"
        }) else {
            throw SelfTestError.failure("Expected visual start and end arrowhead pickers")
        }
        startPicker.update(.value(.circleOutline))
        guard let startTrigger = descendantViews(
            of: NSButton.self,
            in: startPicker
        ).first else {
            throw SelfTestError.failure("Expected an arrowhead picker trigger")
        }
        try expect(
            startTrigger.accessibilityValue() as? String == "Not selected",
            "Expected picker triggers to show the value without persistent selected styling"
        )
        commands.removeAll()
        startPicker.selectForTesting(.zeroOrMany)
        endPicker.selectForTesting(.triangleOutline)
        try expect(
            commands == [
                .setLinearStartArrowhead(.zeroOrMany),
                .setLinearEndArrowhead(.triangleOutline)
            ],
            "Expected visual arrowhead palette choices to dispatch endpoint-specific commands"
        )

        arrowInspectorController.currentTool = .text
        inspector.update(
            state: DrawingToolbarState(
                annotationController: arrowInspectorController
            )
        )
        guard let fontPicker = descendantViews(
            of: DrawingInspectorFontPicker.self,
            in: root
        ).first else {
            throw SelfTestError.failure("Expected the fourth font-family picker button")
        }
        commands.removeAll()
        fontPicker.selectForTesting("Helvetica")
        try expect(
            commands == [.setTextFontName("Helvetica")],
            "Expected the compact font-picker button to dispatch the selected family"
        )
    }

    static func testDrawingInspectorPreviewGeometryAndSignatures() throws {
        let previewRect = CGRect(x: 2, y: 2, width: 28, height: 28)
        let straight = DrawingInspectorPreview.linearRouteGeometry(.straight, in: previewRect)
        let curved = DrawingInspectorPreview.linearRouteGeometry(.curved, in: previewRect)

        try expect(
            straight.points.count == 2 && straight.bezierControls.isEmpty,
            "Expected the Straight inspector preview to remain a direct two-point segment"
        )
        guard curved.points.count == 2, curved.bezierControls.count == 1 else {
            throw SelfTestError.failure(
                "Expected the Curved inspector preview to use one explicit cubic Bezier segment"
            )
        }
        let chord = CGPoint(
            x: curved.points[1].x - curved.points[0].x,
            y: curved.points[1].y - curved.points[0].y
        )
        let firstControlOffset = CGPoint(
            x: curved.bezierControls[0].start.x - curved.points[0].x,
            y: curved.bezierControls[0].start.y - curved.points[0].y
        )
        let controlCrossProduct =
            chord.x * firstControlOffset.y - chord.y * firstControlOffset.x
        try expect(
            abs(controlCrossProduct) > 1,
            "Expected the Curved inspector preview controls to be visibly non-collinear"
        )

        let sharpEdge = DrawingInspectorPreview.edgePreviewGeometry(
            .sharp,
            in: previewRect
        )
        let roundEdge = DrawingInspectorPreview.edgePreviewGeometry(
            .round,
            in: previewRect
        )
        let sharpPoints = AnnotationRoughStroke.sampledPoints(
            on: sharpEdge.solidPath
        )
        let dottedPoints = AnnotationRoughStroke.sampledPoints(
            on: sharpEdge.dottedPath
        )
        try expect(
            sharpEdge.bounds.size == CGSize(width: 16, height: 16)
                && sharpEdge.bounds.midX == previewRect.midX
                && sharpEdge.bounds.midY == previewRect.midY
                && sharpPoints == [
                    CGPoint(x: sharpEdge.bounds.maxX, y: sharpEdge.bounds.minY),
                    CGPoint(x: sharpEdge.bounds.minX, y: sharpEdge.bounds.minY),
                    CGPoint(x: sharpEdge.bounds.minX, y: sharpEdge.bounds.maxY)
                ]
                && dottedPoints == [
                    CGPoint(x: sharpEdge.bounds.maxX, y: sharpEdge.bounds.minY),
                    CGPoint(x: sharpEdge.bounds.maxX, y: sharpEdge.bounds.maxY),
                    CGPoint(x: sharpEdge.bounds.minX, y: sharpEdge.bounds.maxY)
                ]
                && AnnotationRoughStroke.pathElementCount(
                    roundEdge.solidPath
                ) == 2,
            "Expected centered 16-point Sharp/Round corner previews with dotted right/bottom edges"
        )

        let routeSignatures = try DrawingInspectorControlMapping.linearRoutes.map {
            try previewAlphaSignature(.linearRoute($0))
        }
        try expect(
            Set(routeSignatures).count == routeSignatures.count,
            "Expected Straight and Curved inspector previews to have distinct images"
        )

        for arrowhead in DrawingInspectorControlMapping.arrowheads {
            let startPreview = DrawingInspectorPreview.arrowhead(
                arrowhead,
                pointsRight: false
            )
            let endPreview = DrawingInspectorPreview.arrowhead(
                arrowhead,
                pointsRight: true
            )
            let startGeometry = DrawingInspectorPreview.arrowheadGeometry(
                arrowhead,
                pointsRight: false,
                in: previewRect
            )
            let endGeometry = DrawingInspectorPreview.arrowheadGeometry(
                arrowhead,
                pointsRight: true,
                in: previewRect
            )

            try expect(
                startGeometry.linear.points == endGeometry.linear.points
                    && startGeometry.linear.points[0].x < startGeometry.linear.points[1].x,
                "Expected \(arrowhead) preview shafts to consistently run left to right"
            )
            try expect(
                startGeometry.tip == startGeometry.linear.points[0]
                    && startGeometry.adjacent == startGeometry.linear.points[1]
                    && startGeometry.linear.startArrowhead == arrowhead
                    && startGeometry.linear.endArrowhead == .none,
                "Expected \(arrowhead) Start preview to attach at and face outward from the left endpoint"
            )
            try expect(
                endGeometry.tip == endGeometry.linear.points[1]
                    && endGeometry.adjacent == endGeometry.linear.points[0]
                    && endGeometry.linear.startArrowhead == .none
                    && endGeometry.linear.endArrowhead == arrowhead,
                "Expected \(arrowhead) End preview to attach at and face outward from the right endpoint"
            )

            let startSignature = try previewAlphaSignature(startPreview)
            let endSignature = try previewAlphaSignature(endPreview)
            try expect(
                startSignature.horizontallyMirrored() == endSignature,
                "Expected \(arrowhead) Start and End preview images to face in opposite directions"
            )
            if arrowhead != .none {
                try expect(
                    startSignature.painted.contains(true)
                        && endSignature.painted.contains(true),
                    "Expected normalized \(arrowhead) previews to remain visible without clipping"
                )
            }
        }

        let layerActions = DrawingInspectorControlMapping.layerActions
        try expect(
            layerActions.map(\.label) == [
                "Send to back",
                "Send backward",
                "Bring forward",
                "Bring to front"
            ]
                && layerActions.map(\.toolTip) == [
                    "Send to back — Cmd+Option+[",
                    "Send backward — Cmd+[",
                    "Bring forward — Cmd+]",
                    "Bring to front — Cmd+Option+]"
                ],
            "Expected exact Layers order, labels, and Option terminal shortcuts"
        )
        let layerPaths = layerActions.map {
            DrawingInspectorPreview.layerActionPath($0.action, in: previewRect)
        }
        try expect(
            layerPaths.allSatisfy {
                let bounds = $0.boundingBoxOfPath
                return bounds.width <= 16.001
                    && bounds.height <= 16.001
                    && abs(bounds.midX - previewRect.midX) < 0.001
            },
            "Expected every Layers glyph to fit its centered 16-point model"
        )
        let sendBackwardPoints = AnnotationRoughStroke.sampledPoints(
            on: layerPaths[1]
        )
        let bringForwardPoints = AnnotationRoughStroke.sampledPoints(
            on: layerPaths[2]
        )
        let sendToBackPoints = AnnotationRoughStroke.sampledPoints(
            on: layerPaths[0]
        )
        let bringToFrontPoints = AnnotationRoughStroke.sampledPoints(
            on: layerPaths[3]
        )
        try expect(
            zip(sendBackwardPoints, bringForwardPoints).allSatisfy {
                abs($0.x - $1.x) < 0.001
                    && abs(($0.y + $1.y) - previewRect.midY * 2) < 0.001
            }
                && zip(sendToBackPoints, bringToFrontPoints).allSatisfy {
                    abs($0.x - $1.x) < 0.001
                        && abs(($0.y + $1.y) - previewRect.midY * 2) < 0.001
                }
                && bringForwardPoints.contains(
                    CGPoint(x: previewRect.midX, y: previewRect.midY - 4.7)
                )
                && bringToFrontPoints.contains(
                    CGPoint(x: previewRect.midX, y: previewRect.midY - 1.3)
                ),
            "Expected exact vertically mirrored one-step and terminal arrow geometry"
        )

        let sloppinessPaths = AnnotationSloppiness.allCases.map {
            DrawingInspectorPreview.sloppinessPreviewPaths($0, in: previewRect)
        }
        try expect(
            sloppinessPaths.map(\.count) == [1, 2, 2]
                && Set(
                    try AnnotationSloppiness.allCases.map {
                        try previewAlphaSignature(.sloppiness($0))
                    }
                ).count == 3,
            "Expected fixed one-pass, subtle two-pass, and clearly rough two-pass previews"
        )

        let lightAuditedIdle =
            DrawingControlAppearanceResolver.resolveAuditedPropertyTile(
                DrawingControlVisualState(),
                appearance: NSAppearance(named: .aqua)
            )
        let lightAuditedSelected =
            DrawingControlAppearanceResolver.resolveAuditedPropertyTile(
                DrawingControlVisualState(isSelected: true),
                appearance: NSAppearance(named: .aqua)
            )
        let darkAuditedIdle =
            DrawingControlAppearanceResolver.resolveAuditedPropertyTile(
                DrawingControlVisualState(),
                appearance: NSAppearance(named: .darkAqua)
            )
        let darkAuditedSelected =
            DrawingControlAppearanceResolver.resolveAuditedPropertyTile(
                DrawingControlVisualState(isSelected: true),
                appearance: NSAppearance(named: .darkAqua)
            )
        try expect(
            lightAuditedIdle.background == DrawingControlColor(
                red: 0xF6 / 255,
                green: 0xF6 / 255,
                blue: 0xF9 / 255
            )
                && lightAuditedIdle.content == DrawingControlColor(
                    red: 0x1B / 255,
                    green: 0x1B / 255,
                    blue: 0x1F / 255
                )
                && lightAuditedSelected.background == DrawingControlColor(
                    red: 0xE0 / 255,
                    green: 0xDF / 255,
                    blue: 1
                )
                && lightAuditedSelected.content == DrawingControlColor(
                    red: 0x03 / 255,
                    green: 0,
                    blue: 0x64 / 255
                )
                && darkAuditedIdle.background == DrawingControlColor(
                    red: 0x2E / 255,
                    green: 0x2D / 255,
                    blue: 0x39 / 255
                )
                && darkAuditedIdle.content == DrawingControlColor(
                    red: 0xE3 / 255,
                    green: 0xE3 / 255,
                    blue: 0xE8 / 255
                )
                && darkAuditedSelected.background == DrawingControlColor(
                    red: 0x40 / 255,
                    green: 0x3E / 255,
                    blue: 0x6A / 255
                )
                && darkAuditedSelected.content == DrawingControlColor(
                    red: 0xE0 / 255,
                    green: 0xDF / 255,
                    blue: 1
                ),
            "Expected exact audited Layers and Sloppiness idle/selected colors"
        )
    }
}
