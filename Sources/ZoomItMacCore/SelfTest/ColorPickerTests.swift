import AppKit

extension SelfTestRunner {
    static func testDrawingPaletteVisualParity() throws {
        let lightAppearance = NSAppearance(named: .aqua)
        let darkAppearance = NSAppearance(named: .darkAqua)

        func cachedCenterColor(of view: NSView) throws -> NSColor {
            view.layoutSubtreeIfNeeded()
            guard let representation = view.bitmapImageRepForCachingDisplay(
                in: view.bounds
            ) else {
                throw SelfTestError.failure(
                    "Could not cache palette preview"
                )
            }
            view.cacheDisplay(in: view.bounds, to: representation)
            guard let color = representation.colorAt(
                x: representation.pixelsWide / 2,
                y: representation.pixelsHigh / 2
            )?.usingColorSpace(.sRGB) else {
                throw SelfTestError.failure(
                    "Could not sample palette preview"
                )
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

        let expectedStrokeLight: [(AnnotationColor, UInt32)] = [
            (.strokeNeutral, 0x1B1B1F),
            (.strokeCoral, 0xE03131),
            (.strokeGreen, 0x2F9E44),
            (.strokeBlue, 0x1971C2),
            (.strokeOrange, 0xE8590C)
        ]
        let expectedStrokeDark: [(AnnotationColor, UInt32)] = [
            (.strokeNeutral, 0xE9ECEF),
            (.strokeCoral, 0xFF8787),
            (.strokeGreen, 0x69DB7C),
            (.strokeBlue, 0x74C0FC),
            (.strokeOrange, 0xFFA94D)
        ]
        let expectedBackgroundLight: [(AnnotationColor, UInt32)] = [
            (.backgroundRed, 0xFFC9C9),
            (.backgroundGreen, 0xB2F2BB),
            (.backgroundBlue, 0xA5D8FF),
            (.backgroundYellow, 0xFFEC99)
        ]
        let expectedBackgroundDark: [(AnnotationColor, UInt32)] = [
            (.backgroundRed, 0x5C2B2B),
            (.backgroundGreen, 0x244A31),
            (.backgroundBlue, 0x243F5A),
            (.backgroundYellow, 0x5A4A22)
        ]

        func rgb(_ color: NSColor) -> UInt32 {
            let resolved = color.usingColorSpace(.sRGB) ?? color
            return UInt32((resolved.redComponent * 255).rounded()) << 16
                | UInt32((resolved.greenComponent * 255).rounded()) << 8
                | UInt32((resolved.blueComponent * 255).rounded())
        }

        try expect(
            DrawingInspectorControlMapping.strokeColors
                == expectedStrokeLight.map(\.0)
                && DrawingInspectorControlMapping.backgroundColors
                    == expectedBackgroundLight.map(\.0)
                && expectedStrokeLight.allSatisfy {
                    rgb($0.0.resolvedNSColor(for: lightAppearance)) == $0.1
                }
                && expectedStrokeDark.allSatisfy {
                    rgb($0.0.resolvedNSColor(for: darkAppearance)) == $0.1
                }
                && expectedBackgroundLight.allSatisfy {
                    rgb($0.0.resolvedNSColor(for: lightAppearance)) == $0.1
                }
                && expectedBackgroundDark.allSatisfy {
                    rgb($0.0.resolvedNSColor(for: darkAppearance)) == $0.1
                },
            "Expected exact ordered light/dark Excalidraw stroke and background palettes"
        )

        let geometry = DrawingColorSwatchGeometry(
            bounds: CGRect(
                origin: .zero,
                size: CGSize(
                    width: DrawingInspectorVisualMetrics.colorTileSide,
                    height: DrawingInspectorVisualMetrics.colorTileSide
                )
            )
        )
        let selectedLightRing = DrawingColorSwatchAppearance.ringColor(
            isSelected: true,
            isHovered: false,
            appearance: lightAppearance
        )
        let selectedDarkRing = DrawingColorSwatchAppearance.ringColor(
            isSelected: true,
            isHovered: false,
            appearance: darkAppearance
        )
        let hoverDarkRing = DrawingColorSwatchAppearance.ringColor(
            isSelected: false,
            isHovered: true,
            appearance: darkAppearance
        )
        try expect(
            geometry.swatchRect.size == CGSize(width: 35, height: 35)
                && geometry.ringRect.size == CGSize(width: 37, height: 37)
                && DrawingColorSwatchGeometry.cornerRadius == 6
                && DrawingColorSwatchGeometry.ringCornerRadius == 7
                && rgb(selectedLightRing ?? .clear) == 0x5E59D6
                && rgb(selectedDarkRing ?? .clear) == 0xA8A3FF
                && hoverDarkRing?.alphaComponent == 0.9
                && DrawingColorSwatchAppearance.ringColor(
                    isSelected: false,
                    isHovered: false,
                    appearance: darkAppearance
                ) == nil,
            "Expected fixed square geometry plus selected and hover rings without layout changes"
        )

        let annotationController = AnnotationController()
        annotationController.currentTool = .rectangle
        annotationController.setStrokeColor(.palette(.strokeBlue))
        annotationController.setShapeBackground(.palette(.backgroundBlue))
        annotationController.setFillStyle(.solid)
        let inspector = DrawingPropertiesController(
            commandSink: { _ in },
            colorPanelActivityChanged: { _ in }
        )
        inspector.update(
            state: DrawingToolbarState(annotationController: annotationController)
        )
        let host = NSPanel(
            contentRect: CGRect(x: 0, y: 0, width: 300, height: 640),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        host.isReleasedWhenClosed = false
        host.appearance = darkAppearance
        host.contentView = inspector.view
        host.orderFront(nil)
        inspector.view.layoutSubtreeIfNeeded()

        let strokeButtons = descendantViews(
            of: NSButton.self,
            in: inspector.view
        ).filter { $0.accessibilityLabel()?.hasPrefix("Stroke ") == true }
        let backgroundButtons = descendantViews(
            of: NSButton.self,
            in: inspector.view
        ).filter { $0.accessibilityLabel()?.hasPrefix("Background ") == true }
        let customWells = descendantViews(of: NSColorWell.self, in: inspector.view)
        let dividers = descendantViews(
            of: DrawingColorPaletteDivider.self,
            in: inspector.view
        )
        let strokeFrames = strokeButtons.map {
            $0.convert($0.bounds, to: inspector.view)
        }.sorted { $0.minX < $1.minX }
        let strokeGaps = zip(strokeFrames, strokeFrames.dropFirst()).map {
            $1.minX - $0.maxX
        }
        try expect(
            strokeButtons.count == 5
                && backgroundButtons.count == 5
                && customWells.count == 2
                && dividers.count == 2
                && strokeFrames.allSatisfy {
                    abs($0.width - 38) < 0.01
                        && abs($0.height - 38) < 0.01
                }
                && strokeGaps.allSatisfy { abs($0 - 7) < 0.01 }
                && customWells.allSatisfy {
                    abs($0.frame.width - 26) < 0.01
                        && abs($0.frame.height - 26) < 0.01
                        && $0.layer?.cornerRadius == 5
                        && $0.layer?.borderWidth == 0
                }
                && dividers.allSatisfy {
                    abs($0.frame.width - 1) < 0.01
                        && abs($0.frame.height - 24) < 0.01
                        && ($0.superview as? NSStackView)?.spacing == 8
                }
                && strokeButtons.allSatisfy {
                    $0.layer?.borderWidth == 0
                        && ($0.layer?.backgroundColor?.alpha ?? 0) == 0
                }
                && strokeButtons.filter {
                    $0.accessibilityValue() as? String == "Selected"
                }.map { $0.accessibilityLabel() } == ["Stroke Light Blue"]
                && backgroundButtons.filter {
                    $0.accessibilityValue() as? String == "Selected"
                }.map { $0.accessibilityLabel() } == ["Background Muted Blue"],
            "Expected five square presets, separated custom wells, exact gaps/dividers, "
                + "and ring-only selected states"
        )

        guard let strokeBlueButton = strokeButtons.first(where: {
            $0.accessibilityLabel() == "Stroke Light Blue"
        }),
        let backgroundBlueButton = backgroundButtons.first(where: {
            $0.accessibilityLabel() == "Background Muted Blue"
        }),
        let transparentButton = backgroundButtons.first(where: {
            $0.accessibilityLabel() == "Background Transparent"
        }) else {
            throw SelfTestError.failure("Expected semantic palette buttons")
        }
        let cachedStrokePreview = try cachedCenterColor(of: strokeBlueButton)
        let cachedBackgroundPreview = try cachedCenterColor(of: backgroundBlueButton)
        let panelBackground = DrawingColorSwatchAppearance.panelBackground(
            for: darkAppearance
        )
        let strokePreview = DrawingColorSwatchAppearance.previewColor(
            .palette(.strokeBlue),
            opacity: 1,
            appearance: darkAppearance
        )
        let backgroundPreview = DrawingColorSwatchAppearance.previewColor(
            .palette(.backgroundBlue),
            opacity: 1,
            appearance: darkAppearance
        )

        var lineStyle = AnnotationStyle(
            color: .strokeBlue,
            rootWidth: 6,
            alpha: 1,
            sloppiness: .architect
        )
        lineStyle.strokeColor = .palette(.strokeBlue)
        let line = AnnotationElement.legacy(
            tool: .line,
            points: [CGPoint(x: 12, y: 32), CGPoint(x: 84, y: 32)],
            style: lineStyle
        )
        var fillStyle = lineStyle
        fillStyle.fillColor = .palette(.backgroundBlue)
        fillStyle.fillStyle = .solid
        let rectangle = AnnotationElement.legacy(
            tool: .rectangle,
            points: [CGPoint(x: 16, y: 16), CGPoint(x: 80, y: 56)],
            style: fillStyle
        )
        var linePixels: [UInt8]?
        var rectanglePixels: [UInt8]?
        var renderError: Error?
        darkAppearance?.performAsCurrentDrawingAppearance {
            do {
                linePixels = try renderPixels(
                    elements: [line],
                    renderer: AnnotationRenderer(),
                    width: 96,
                    height: 64,
                    backgroundColor: panelBackground
                )
                rectanglePixels = try renderPixels(
                    elements: [rectangle],
                    renderer: AnnotationRenderer(),
                    width: 96,
                    height: 72,
                    backgroundColor: panelBackground
                )
            } catch {
                renderError = error
            }
        }
        if let renderError { throw renderError }
        guard let linePixels, let rectanglePixels else {
            throw SelfTestError.failure("Expected dark palette render pixels")
        }
        let linePixel = pixel(linePixels, width: 96, x: 48, y: 32)
        let fillPixel = pixel(rectanglePixels, width: 96, x: 48, y: 36)
        let lineColor = NSColor(
            srgbRed: CGFloat(linePixel.red) / 255,
            green: CGFloat(linePixel.green) / 255,
            blue: CGFloat(linePixel.blue) / 255,
            alpha: 1
        )
        let fillColor = NSColor(
            srgbRed: CGFloat(fillPixel.red) / 255,
            green: CGFloat(fillPixel.green) / 255,
            blue: CGFloat(fillPixel.blue) / 255,
            alpha: 1
        )
        try expect(
            colorDistance(strokePreview, lineColor) < 0.04
                && colorDistance(backgroundPreview, fillColor) < 0.04
                && colorDistance(cachedStrokePreview, panelBackground) > 0.1
                && colorDistance(cachedBackgroundPreview, panelBackground) > 0.05,
            "Expected dark semantic swatch previews to match rendered stroke/fill colors "
                + "(stroke preview \(strokePreview), cached \(cachedStrokePreview), "
                + "render \(lineColor), background preview \(backgroundPreview), "
                + "cached \(cachedBackgroundPreview), render \(fillColor))"
        )

        annotationController.setShapeBackground(nil)
        inspector.update(
            state: DrawingToolbarState(annotationController: annotationController)
        )
        try expect(
            transparentButton.accessibilityValue() as? String == "Selected"
                && DrawingColorSwatchAppearance.ringColor(
                    isSelected: true,
                    isHovered: false,
                    appearance: darkAppearance
                ) != nil,
            "Expected the checkerboard Transparent swatch to retain an obvious selected ring"
        )

        annotationController.currentTool = .highlighter
        inspector.update(
            state: DrawingToolbarState(annotationController: annotationController)
        )
        let highlighterLabels = strokeButtons.sorted {
            $0.frame.minX < $1.frame.minX
        }.compactMap { $0.accessibilityLabel() }
        try expect(
            highlighterLabels == [
                "Stroke Light Yellow",
                "Stroke Cyan",
                "Stroke Pink",
                "Stroke Green",
                "Stroke Orange"
            ]
                && strokeButtons.allSatisfy {
                    abs($0.frame.width - 38) < 0.01
                        && abs($0.frame.height - 38) < 0.01
                        && $0.layer?.borderWidth == 0
                        && ($0.layer?.backgroundColor?.alpha ?? 0) == 0
                },
            "Expected the dedicated neon Highlighter palette to reuse the same square/ring layout"
        )
        host.close()
    }

    static func testDrawingColorPickerCoordinatorLifecycle() throws {
        var state = DrawingColorPickerCoordinatorState()
        try expect(
            state.activate(.stroke) == .started
                && state.transactionActive
                && state.activeChannel == .stroke
                && state.activate(.stroke) == .unchanged
                && state.activate(.background) == .switched
                && state.activeChannel == .background
                && !state.deactivate(.stroke)
                && state.activate(.text) == .switched
                && state.activeChannel == .text
                && state.close()
                && !state.transactionActive
                && state.activeChannel == nil
                && !state.close(),
            "Expected one picker transaction while channels switch without duplicate close events"
        )

        var commands: [AppCommand] = []
        var activityChanges: [Bool] = []
        let inspector = DrawingPropertiesController(
            commandSink: { commands.append($0) },
            colorPanelActivityChanged: { activityChanges.append($0) }
        )
        let annotationController = AnnotationController()
        annotationController.currentTool = .rectangle
        annotationController.setStrokeColor(
            .rgba(red: 0.2, green: 0.4, blue: 0.8, alpha: 1)
        )
        inspector.update(state: DrawingToolbarState(annotationController: annotationController))

        let host = NSPanel(
            contentRect: CGRect(x: 0, y: 0, width: 216, height: 600),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        host.isReleasedWhenClosed = false
        host.contentView = inspector.view
        host.orderFront(nil)
        inspector.view.layoutSubtreeIfNeeded()

        let colorWells = descendantViews(of: NSColorWell.self, in: inspector.view)
        guard let strokeWell = colorWells.first(where: {
            $0.accessibilityLabel() == "Custom stroke color"
        }),
        let backgroundWell = colorWells.first(where: {
            $0.accessibilityLabel() == "Custom background color"
        }) else {
            throw SelfTestError.failure("Expected coordinated stroke and background wells")
        }
        let selectedAppearance = strokeWell.accessibilityValue() as? String
        let sharedPanel = NSColorPanel.shared
        let originalParent = sharedPanel.parent
        let originalLevel = sharedPanel.level
        let originalSharingType = sharedPanel.sharingType
        let originalVisibility = sharedPanel.isVisible

        strokeWell.activate(true)
        try expect(
            commands == [.beginContinuousStyleEdit(.colorPicker)]
                && activityChanges == [true]
                && inspector.colorPickerStateForTesting.activeChannel == .stroke
                && inspector.colorPickerStateForTesting.transactionActive
                && colorsMatch(sharedPanel.color, strokeWell.color)
                && strokeWell.accessibilityValue() as? String == "Selected",
            "Expected repeated Stroke activation to open one picker transaction "
                + "(commands \(commands), activity \(activityChanges), channel "
                + "\(String(describing: inspector.colorPickerStateForTesting.activeChannel)), "
                + "transaction \(inspector.colorPickerStateForTesting.transactionActive), "
                + "panel synchronized \(colorsMatch(sharedPanel.color, strokeWell.color)), "
                + "value \(String(describing: strokeWell.accessibilityValue())))"
        )

        let textColor = AnnotationColorValue.rgba(
            red: 0.16,
            green: 0.68,
            blue: 0.42,
            alpha: 1
        )
        annotationController.setTextColor(textColor)
        annotationController.currentTool = .text
        inspector.update(state: DrawingToolbarState(annotationController: annotationController))
        try expect(
            inspector.colorPickerStateForTesting.activeChannel == .text
                && colorsMatch(sharedPanel.color, textColor.nsColor),
            "Expected an open picker to switch to the Text channel and refresh its color"
        )

        annotationController.currentTool = .rectangle
        inspector.update(state: DrawingToolbarState(annotationController: annotationController))
        guard let coralButton = descendantViews(
            of: NSButton.self,
            in: inspector.view
        ).first(where: { $0.accessibilityLabel() == "Stroke Coral" }) else {
            throw SelfTestError.failure("Expected Stroke Coral preset")
        }
        coralButton.performClick(nil)
        NotificationCenter.default.post(
            name: NSColorPanel.colorDidChangeNotification,
            object: sharedPanel
        )
        let adjustedStrokeColor = AnnotationColorValue.rgba(
            red: 0.31,
            green: 0.52,
            blue: 0.73,
            alpha: 0.88
        )
        sharedPanel.color = adjustedStrokeColor.nsColor
        NotificationCenter.default.post(
            name: NSColorPanel.colorDidChangeNotification,
            object: sharedPanel
        )
        try expect(
            commands == [
                .beginContinuousStyleEdit(.colorPicker),
                .setStrokeColor(.palette(.strokeCoral)),
                .setStrokeColor(adjustedStrokeColor)
            ]
                && colorsMatch(strokeWell.color, adjustedStrokeColor.nsColor),
            "Expected a preset to synchronize the open panel without a stale duplicate "
                + "and the next adjustment to continue from that selection "
                + "(commands \(commands), panel \(sharedPanel.color), well \(strokeWell.color))"
        )

        backgroundWell.activate(true)
        let visiblePickerWindows = NSApp.windows.filter {
            guard $0.isVisible else { return false }
            return $0 === sharedPanel
                || String(describing: type(of: $0)).contains("Popover")
        }
        try expect(
            commands == [
                .beginContinuousStyleEdit(.colorPicker),
                .setStrokeColor(.palette(.strokeCoral)),
                .setStrokeColor(adjustedStrokeColor)
            ]
                && activityChanges == [true]
                && inspector.colorPickerStateForTesting.activeChannel == .background
                && colorWells.filter(\.isActive).count == 1
                && visiblePickerWindows.count == 1
                && sharedPanel.parent === host
                && sharedPanel.level.rawValue == host.level.rawValue + 1
                && sharedPanel.sharingType == .none
                && colorsMatch(sharedPanel.color, backgroundWell.color)
                && sharedPanel.isVisible,
            "Expected channel switching to retain one shared color panel "
                + "(active wells \(colorWells.filter(\.isActive).count), "
                + "visible picker windows \(visiblePickerWindows.count), "
                + "parent attached \(sharedPanel.parent === host), "
                + "level elevated \(sharedPanel.level.rawValue == host.level.rawValue + 1), "
                + "sharing disabled \(sharedPanel.sharingType == .none), "
                + "panel synchronized \(colorsMatch(sharedPanel.color, backgroundWell.color)), "
                + "visibility \(sharedPanel.isVisible)/\(originalVisibility))"
        )

        inspector.dismissColorPanel()
        inspector.dismissColorPanel()
        try expect(
            commands == [
                .beginContinuousStyleEdit(.colorPicker),
                .setStrokeColor(.palette(.strokeCoral)),
                .setStrokeColor(adjustedStrokeColor),
                .endContinuousStyleEdit(.colorPicker)
            ]
                && activityChanges == [true, false]
                && !inspector.colorPickerStateForTesting.transactionActive
                && inspector.colorPickerStateForTesting.activeChannel == nil
                && sharedPanel.parent === originalParent
                && sharedPanel.level == originalLevel
                && sharedPanel.sharingType == originalSharingType
                && sharedPanel.isVisible == originalVisibility
                && strokeWell.accessibilityValue() as? String == selectedAppearance,
            "Expected one close, one matching transaction end, and stable custom-tile selection"
        )

        annotationController.currentTool = .select
        inspector.update(state: DrawingToolbarState(annotationController: annotationController))
        try expect(
            !strokeWell.isEnabled
                && strokeWell.toolTip == "Choose a custom stroke color",
            "Expected unavailable custom wells to disable and reset their tooltip"
        )
        annotationController.currentTool = .rectangle
        inspector.update(state: DrawingToolbarState(annotationController: annotationController))
        try expect(
            strokeWell.isEnabled
                && strokeWell.toolTip == "Choose a custom stroke color",
            "Expected custom wells to restore their normal tooltip when available"
        )

        strokeWell.activate(true)
        RunLoop.current.run(until: Date().addingTimeInterval(0.03))
        try expect(
            colorsMatch(sharedPanel.color, strokeWell.color)
                && commands == [
                    .beginContinuousStyleEdit(.colorPicker),
                    .setStrokeColor(.palette(.strokeCoral)),
                    .setStrokeColor(adjustedStrokeColor),
                    .endContinuousStyleEdit(.colorPicker),
                    .beginContinuousStyleEdit(.colorPicker)
                ]
                && activityChanges == [true, false, true],
            "Expected close and reopen to seed the shared panel from the current Stroke color"
        )
        inspector.dismissColorPanel()

        host.contentView = nil
        host.orderOut(nil)
    }

    static func testDrawingColorPickerPhysicalClicks() throws {
        let visibleFrame = NSScreen.main?.visibleFrame
            ?? CGRect(x: 0, y: 0, width: 1_200, height: 800)
        let host = NSWindow(
            contentRect: visibleFrame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        host.isReleasedWhenClosed = false
        host.level = .screenSaver
        host.orderFront(nil)

        let annotationController = AnnotationController()
        annotationController.currentTool = .rectangle
        var commands: [AppCommand] = []
        let controller = DrawingToolbarController(
            parentWindow: host,
            annotationController: annotationController,
            toolbarNormalizedPosition: nil,
            commandSink: { command in
                commands.append(command)
                switch command {
                case .beginContinuousStyleEdit(let owner):
                    annotationController.beginContinuousStyleEdit(owner: owner)
                case .endContinuousStyleEdit(let owner):
                    _ = annotationController.endContinuousStyleEdit(owner: owner)
                case .setStrokeColor(let color):
                    annotationController.setStrokeColor(color)
                case .setTextColor(let color):
                    annotationController.setTextColor(color)
                case .setShapeBackground(let color):
                    annotationController.setShapeBackground(color)
                default:
                    break
                }
            },
            restoreCanvasFocus: {},
            toolbarPlacementDidChange: { _ in },
            pointerInteractionChanged: { _ in }
        )
        controller.show()
        RunLoop.current.run(until: Date().addingTimeInterval(0.05))

        let originalPolicy = NSApp.activationPolicy()
        let appWasActive = NSApp.isActive
        _ = NSApp.setActivationPolicy(.accessory)
        let sharedPanel = NSColorPanel.shared
        let originalSharedParent = sharedPanel.parent
        let originalSharedLevel = sharedPanel.level
        let originalSharedSharingType = sharedPanel.sharingType
        let originalSharedVisibility = sharedPanel.isVisible
        defer {
            controller.close()
            host.orderOut(nil)
            sharedPanel.level = originalSharedLevel
            sharedPanel.sharingType = originalSharedSharingType
            if let originalSharedParent {
                originalSharedParent.addChildWindow(sharedPanel, ordered: .above)
            } else {
                sharedPanel.parent?.removeChildWindow(sharedPanel)
            }
            if originalSharedVisibility {
                sharedPanel.orderFront(nil)
            } else {
                sharedPanel.orderOut(nil)
            }
            _ = NSApp.setActivationPolicy(originalPolicy)
            if appWasActive {
                NSApp.activate(ignoringOtherApps: true)
            }
        }

        func visibleColorPickerWindows() -> [NSWindow] {
            NSApp.windows.filter {
                guard $0.isVisible else { return false }
                return $0 === sharedPanel
                    || String(describing: type(of: $0)).contains("Popover")
            }
        }

        func customWell(label: String) throws -> NSColorWell {
            guard let contentView = controller.inspectorWindowForTesting.contentView,
                  let well = descendantViews(
                    of: NSColorWell.self,
                    in: contentView
                  ).first(where: { $0.accessibilityLabel() == label }) else {
                throw SelfTestError.failure("Expected \(label)")
            }
            return well
        }

        func exercise(
            tool: AnnotationTool,
            label: String,
            channel: DrawingColorPickerChannel,
            color: AnnotationColorValue,
            expectedColorCommand: AppCommand,
            closeUsingPanel: Bool = false,
            modelMatches: () -> Bool
        ) throws {
            controller.dismissTransientUI()
            annotationController.currentTool = tool
            if channel == .background {
                annotationController.setShapeBackground(.palette(.backgroundRed))
            }
            controller.updateState(
                DrawingToolbarState(annotationController: annotationController)
            )
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
            let well = try customWell(label: label)
            let toolbarFrame = controller.toolbarFrameForTesting
            let events = try physicalClickEvents(in: well)
            guard let contentView = controller.inspectorWindowForTesting.contentView else {
                throw SelfTestError.failure("Expected attached inspector content")
            }
            let hitPoint = contentView.convert(events.mouseDown.locationInWindow, from: nil)

            commands.removeAll()
            NSApp.deactivate()
            RunLoop.current.run(until: Date().addingTimeInterval(0.03))
            try expect(
                !NSApp.isActive
                    && NSApp.activationPolicy() == .accessory
                    && well.isEnabled
                    && well.acceptsFirstMouse(for: events.mouseDown)
                    && contentView.hitTest(hitPoint) === well
                    && well.mouseDownCanMoveWindow == false
                    && well.colorWellStyle != .minimal
                    && visibleColorPickerWindows().isEmpty,
                "Expected the inactive \(channel) custom tile to own its first mouse event "
                    + "without entering toolbar drag handling"
            )

            try dispatchPhysicalMouseClick(in: well)
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
            try expect(
                NSApp.activationPolicy() == .accessory
                    && controller.toolbarFrameForTesting == toolbarFrame
                    && controller.colorPickerStateForTesting.activeChannel == channel
                    && controller.colorPickerStateForTesting.transactionActive
                    && well.isActive
                    && visibleColorPickerWindows().count == 1
                    && commands == [.beginContinuousStyleEdit(.colorPicker)]
                    && colorsMatch(sharedPanel.color, well.color)
                    && sharedPanel.parent === controller.inspectorWindowForTesting
                    && sharedPanel.level.rawValue
                        == controller.inspectorWindowForTesting.level.rawValue + 1
                    && sharedPanel.sharingType == .none
                    && sharedPanel.isVisible,
                "Expected one shared picker and one transaction for the inactive \(channel) tile "
                    + "(app active \(NSApp.isActive), policy \(NSApp.activationPolicy()), "
                    + "toolbar stable \(controller.toolbarFrameForTesting == toolbarFrame), "
                    + "channel \(String(describing: controller.colorPickerStateForTesting.activeChannel)), "
                    + "transaction \(controller.colorPickerStateForTesting.transactionActive), "
                    + "well active \(well.isActive), windows "
                    + "\(visibleColorPickerWindows().map { String(describing: type(of: $0)) }), "
                    + "commands \(commands), shared visible \(sharedPanel.isVisible))"
            )

            sharedPanel.color = color.nsColor
            NotificationCenter.default.post(
                name: NSColorPanel.colorDidChangeNotification,
                object: sharedPanel
            )
            RunLoop.current.run(until: Date().addingTimeInterval(0.03))
            try expect(
                commands == [
                    .beginContinuousStyleEdit(.colorPicker),
                    expectedColorCommand
                ]
                    && modelMatches(),
                "Expected the \(channel) picker to dispatch exactly one channel-specific color change "
                    + "(commands \(commands), expected \(expectedColorCommand), "
                    + "model matches \(modelMatches()))"
            )

            if closeUsingPanel {
                sharedPanel.close()
            } else {
                controller.dismissTransientUI()
            }
            controller.dismissTransientUI()
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
            try expect(
                commands == [
                    .beginContinuousStyleEdit(.colorPicker),
                    expectedColorCommand,
                    .endContinuousStyleEdit(.colorPicker)
                ]
                    && !controller.colorPickerStateForTesting.transactionActive
                    && controller.colorPickerStateForTesting.activeChannel == nil
                    && visibleColorPickerWindows().isEmpty
                    && sharedPanel.parent === originalSharedParent
                    && sharedPanel.level == originalSharedLevel
                    && sharedPanel.sharingType == originalSharedSharingType
                    && sharedPanel.isVisible == originalSharedVisibility,
                "Expected one close and one matching transaction end for the \(channel) picker"
            )
        }

        let strokeColor = AnnotationColorValue.rgba(
            red: 0.12,
            green: 0.34,
            blue: 0.56,
            alpha: 1
        )
        try exercise(
            tool: .rectangle,
            label: "Custom stroke color",
            channel: .stroke,
            color: strokeColor,
            expectedColorCommand: .setStrokeColor(strokeColor),
            modelMatches: {
                annotationController.currentStyle.strokeColor == strokeColor
            }
        )

        let backgroundColor = AnnotationColorValue.rgba(
            red: 0.68,
            green: 0.24,
            blue: 0.42,
            alpha: 0.9
        )
        try exercise(
            tool: .rectangle,
            label: "Custom background color",
            channel: .background,
            color: backgroundColor,
            expectedColorCommand: .setShapeBackground(backgroundColor),
            modelMatches: {
                annotationController.currentStyle.fillColor == backgroundColor
                    && annotationController.currentStyle.fillStyle != .none
            }
        )

        let textColor = AnnotationColorValue.rgba(
            red: 0.22,
            green: 0.72,
            blue: 0.38,
            alpha: 1
        )
        try exercise(
            tool: .text,
            label: "Custom stroke color",
            channel: .text,
            color: textColor,
            expectedColorCommand: .setTextColor(textColor),
            closeUsingPanel: true,
            modelMatches: {
                annotationController.currentStyle.strokeColor == textColor
            }
        )

        let highlighterColor = AnnotationColorValue.rgba(
            red: 0.92,
            green: 0.54,
            blue: 0.16,
            alpha: 0.7
        )
        try exercise(
            tool: .highlighter,
            label: "Custom stroke color",
            channel: .stroke,
            color: highlighterColor,
            expectedColorCommand: .setStrokeColor(highlighterColor),
            modelMatches: {
                annotationController.currentStyle.strokeColor == highlighterColor
            }
        )
    }
}
