import AppKit

extension SelfTestRunner {
    static func testDrawingToolShortcuts() throws {
        try expect(
            DrawingToolbarVisualMetrics.shellHeight == 54
                && DrawingToolbarVisualMetrics.desktopWidth == 648
                && DrawingToolbarVisualMetrics.shellInset == 5
                && DrawingToolbarVisualMetrics.shellCornerRadius == 15
                && DrawingToolbarVisualMetrics.buttonSide == 44
                && DrawingToolbarVisualMetrics.dragHandleWidth == 24
                && DrawingToolbarVisualMetrics.buttonCornerRadius == 10
                && (19...21).contains(
                    DrawingToolbarVisualMetrics.iconPointSize
                )
                && DrawingToolbarVisualMetrics.numericHintFontSize == 11
                && DrawingToolbarVisualMetrics.numericHintFontDesign
                    == "system-regular"
                && DrawingToolShortcuts.DrawingToolbarStructure.orderedGroups
                    == [.hand, .mainTools, .overflow],
            "Expected larger toolbar tiles and legible Excalidraw-style numeric hints"
        )
        let expectedNumericTools: [(String, UInt16, AnnotationTool)] = [
            ("1", 18, .select),
            ("2", 19, .rectangle),
            ("3", 20, .diamond),
            ("4", 21, .ellipse),
            ("5", 23, .arrow),
            ("6", 22, .line),
            ("7", 26, .pen),
            ("8", 28, .text),
            ("0", 29, .eraser)
        ]
        for (key, keyCode, tool) in expectedNumericTools {
            try expect(
                DrawingToolShortcuts.numericCommand(
                    characters: key,
                    keyCode: keyCode,
                    modifierFlags: [],
                    isDrawingMode: true,
                    isTyping: false
                ) == .setTool(tool),
                "Expected \(key) to select \(tool)"
            )
        }
        try expect(
            DrawingToolShortcuts.numericCommand(
                characters: "9",
                keyCode: 25,
                modifierFlags: [],
                isDrawingMode: true,
                isTyping: false
            ) == nil,
            "Expected 9 to remain unassigned while image insertion is unsupported"
        )
        try expect(
            DrawingToolShortcuts.numericCommand(
                characters: "1",
                keyCode: 83,
                modifierFlags: [.numericPad],
                isDrawingMode: true,
                isTyping: false
            ) == .setTool(.select),
            "Expected numeric-pad characters to use the same numeric mapping"
        )
        for modifier: NSEvent.ModifierFlags in [.command, .control, .option] {
            try expect(
                DrawingToolShortcuts.numericCommand(
                    characters: "2",
                    keyCode: 19,
                    modifierFlags: modifier,
                    isDrawingMode: true,
                    isTyping: false
                ) == nil,
                "Expected Command, Control, and Option number keys to preserve existing shortcuts"
            )
        }
        try expect(
            DrawingToolShortcuts.numericCommand(
                characters: "1",
                keyCode: 18,
                modifierFlags: [.shift],
                isDrawingMode: true,
                isTyping: false
            ) == .setTool(.select)
                && DrawingToolShortcuts.numericCommand(
                    characters: "!",
                    keyCode: 19,
                    modifierFlags: [.shift],
                    isDrawingMode: true,
                    isTyping: false
                ) == .setTool(.rectangle),
            "Expected shifted physical number-row keys to resolve by ANSI keyCode"
        )
        try expect(
            DrawingToolShortcuts.numericCommand(
                characters: "8",
                keyCode: 28,
                modifierFlags: [],
                isDrawingMode: true,
                isTyping: true
            ) == nil,
            "Expected number keys to remain text input while typing"
        )
        try expect(
            DrawingToolShortcuts.numericCommand(
                characters: "8",
                keyCode: 28,
                modifierFlags: [],
                isDrawingMode: false,
                isTyping: false
            ) == nil,
            "Expected numeric tool shortcuts to apply only while drawing"
        )

        let expectedLegacyCommands: [(String, Bool, AppCommand)] = [
            ("v", false, .setTool(.select)),
            (" ", false, .setTool(.hand)),
            ("f", false, .setTool(.pen)),
            ("l", false, .setTool(.line)),
            ("a", false, .setTool(.arrow)),
            ("e", true, .setTool(.eraser)),
            ("h", false, .setTool(.highlighter)),
            ("t", false, .toggleTyping(rightAligned: false)),
            ("t", true, .toggleTyping(rightAligned: true))
        ]
        for (key, shift, command) in expectedLegacyCommands {
            try expect(
                DrawingToolShortcuts.legacyCommand(
                    characters: key,
                    shift: shift
                ) == command,
                "Expected legacy drawing shortcut \(key) to remain compatible"
            )
        }
        try expect(
            DrawingToolShortcuts.legacyCommand(characters: "e", shift: false) == nil,
            "Expected plain E to remain the clear command rather than selecting Eraser"
        )
        try expect(
            DrawingToolShortcuts.metadata(for: .highlighter)?.numericHint == nil
                && DrawingToolShortcuts.metadata(for: .highlighter)?.legacyHint
                    == "H",
            "Expected visible Highlighter to remain unnumbered while advertising H"
        )

        let visibleNumericHints = DrawingToolShortcuts.toolbarMetadata.compactMap(\.numericHint)
        try expect(
            visibleNumericHints.count == expectedNumericTools.count
                && expectedNumericTools.allSatisfy {
                    DrawingToolShortcuts.metadata(for: $0.2)?.numericHint == $0.0
                }
                && !visibleNumericHints.contains("9"),
            "Expected toolbar numeric hints to match the supported tool mapping"
        )
        try expect(
            DrawingToolShortcuts.reservedNumericHints == ["9"],
            "Expected unsupported Image to reserve 9 without rendering a misleading tool"
        )
        try expect(
            DrawingSelectionShortcut.arrangeAction(
                key: "[",
                command: true,
                option: true,
                shift: false
            ) == .sendToBack
                && DrawingSelectionShortcut.arrangeAction(
                    key: "[",
                    command: true,
                    option: false,
                    shift: false
                ) == .sendBackward
                && DrawingSelectionShortcut.arrangeAction(
                    key: "]",
                    command: true,
                    option: false,
                    shift: false
                ) == .bringForward
                && DrawingSelectionShortcut.arrangeAction(
                    key: "]",
                    command: true,
                    option: true,
                    shift: false
                ) == .bringToFront
                && DrawingSelectionShortcut.arrangeAction(
                    key: "]",
                    command: true,
                    option: false,
                    shift: true
                ) == .bringToFront,
            "Expected Command+Option terminal layer shortcuts with Shift compatibility"
        )
        try expect(
            DrawingToolShortcuts.metadata(for: .select)?.toolTip(label: "Select")
                == "Select (1, V)"
                && DrawingToolShortcuts.metadata(for: .rectangle)?.toolTip(
                    label: "Rectangle"
                ) == "Rectangle (2, Control-drag)"
                && DrawingToolShortcuts.metadata(for: .diamond)?.toolTip(label: "Diamond")
                    == "Diamond (3)"
                && DrawingToolShortcuts.metadata(for: .highlighter)?.toolTip(
                    label: "Highlighter"
                ) == "Highlighter (H)",
            "Expected tooltips to include numeric and legacy shortcuts where applicable"
        )
    }

    static func testDrawingToolbarLifecycleAndPlacement() throws {
        try expect(
            DrawingToolbarLifecycle.shouldShow(
                isOverlayPresented: true,
                isDrawingAccessoryActive: true
            ),
            "Expected toolbar to show while a drawing accessory session is active"
        )
        try expect(
            !DrawingToolbarLifecycle.shouldShow(
                isOverlayPresented: true,
                isDrawingAccessoryActive: false
            )
                && !DrawingToolbarLifecycle.shouldShow(
                    isOverlayPresented: false,
                    isDrawingAccessoryActive: true
                ),
            "Expected toolbar lifecycle to hide outside drawing accessory sessions"
        )
        var activeControlInteraction = DrawingAccessoryInteractionState()
        activeControlInteraction.controlTracking = true
        try expect(
                DrawingToolbarLifecycle.shouldShow(
                    isOverlayPresented: true,
                    isDrawingAccessoryActive: false,
                    interactionState: activeControlInteraction
                ),
                "Expected an active inspector control to prevent lifecycle hide"
        )
        try expect(
            DrawingAccessoryLifecycle.isActive(
                interactionMode: .staticZoom,
                isDrawingMode: true,
                resumesDrawingAfterTyping: false
            )
                && DrawingAccessoryLifecycle.isActive(
                    interactionMode: .typing,
                    isDrawingMode: false,
                    resumesDrawingAfterTyping: true
                )
                && !DrawingAccessoryLifecycle.isActive(
                    interactionMode: .typing,
                    isDrawingMode: false,
                    resumesDrawingAfterTyping: false
                ),
            "Expected drawing-originated typing to remain in the drawing accessory lifecycle"
        )

        let visibleFrame = CGRect(x: 100, y: 200, width: 800, height: 600)
        let panelSize = CGSize(width: 300, height: 50)
        let dragged = DrawingToolbarPlacement.draggedOrigin(
            initialOrigin: CGPoint(x: 250, y: 400),
            initialPointerScreenLocation: CGPoint(x: 500, y: 600),
            currentPointerScreenLocation: CGPoint(x: 440, y: 675)
        )
        try expect(
            dragged == CGPoint(x: 190, y: 475),
            "Expected toolbar dragging to apply global pointer deltas to the initial frame"
        )
        let clamped = DrawingToolbarPlacement.clampedOrigin(
            CGPoint(x: -1_000, y: 10_000),
            panelSize: panelSize,
            visibleFrame: visibleFrame
        )
        try expect(
            clamped.x >= visibleFrame.minX
                && clamped.y >= visibleFrame.minY
                && clamped.x + panelSize.width <= visibleFrame.maxX
                && clamped.y + panelSize.height <= visibleFrame.maxY,
            "Expected toolbar origin to clamp to the active display"
        )

        let original = CGPoint(x: 360, y: 520)
        let normalized = DrawingToolbarPlacement.normalizedPosition(
            origin: original,
            panelSize: panelSize,
            visibleFrame: visibleFrame
        )
        let restored = DrawingToolbarPlacement.origin(
            normalizedPosition: normalized,
            panelSize: panelSize,
            visibleFrame: visibleFrame
        )
        try expect(
            abs(restored.x - original.x) < 0.001 && abs(restored.y - original.y) < 0.001,
            "Expected normalized toolbar positioning to round-trip"
        )
        let defaultToolbarOrigin = DrawingToolbarPlacement.defaultOrigin(
            panelSize: panelSize,
            visibleFrame: visibleFrame
        )
        try expect(
            abs(defaultToolbarOrigin.x - (visibleFrame.midX - panelSize.width / 2)) < 0.001
                && defaultToolbarOrigin.y > visibleFrame.midY,
            "Expected the horizontal toolbar to default near the top center"
        )
        let compactToolbarSize = DrawingToolbarLayout.preferredSize(
            mainContentSize: CGSize(width: 720, height: 30),
            pathActionsSize: CGSize(width: 63, height: 30),
            maximumWidth: 520
        )
        let compactToolbarFrames = DrawingToolbarLayout.frames(
            in: CGRect(origin: .zero, size: compactToolbarSize),
            pathActionsSize: CGSize(width: 63, height: 30)
        )
        try expect(
            compactToolbarSize.width == 520
                && compactToolbarSize.height < 60
                && compactToolbarFrames.scrollFrame.height > 0
                && compactToolbarFrames.pathActionsFrame.minX
                    >= compactToolbarFrames.scrollFrame.maxX,
            "Expected compact path actions to remain beside a horizontal scrolling tool strip"
        )

        for tool in [
            AnnotationTool.rectangle,
            .diamond,
            .ellipse,
            .arrow,
            .line,
            .pen,
            .highlighter,
            .text
        ] {
            let sections = DrawingInspectorSectionMatrix.sections(for: tool)
            let layout = DrawingInspectorSectionMatrix
                .DrawingToolbarHorizontalSectionPacker.layout(
                    sections: sections,
                    availableWidth: 552
                )
            try expect(
                layout.rows.count <= 3
                    && layout.rows.flatMap { $0 } == sections,
                "Expected \(tool) attached properties to preserve exact section order "
                    + "in at most three rows on a 600-point display"
            )
        }

        let narrowAttachedLayout = DrawingInspectorSectionMatrix
            .DrawingToolbarHorizontalSectionPacker.layout(
                sections: DrawingInspectorSectionMatrix.sections(for: .rectangle),
                availableWidth: 220
            )
        try expect(
            narrowAttachedLayout.rows.flatMap { $0 }
                == DrawingInspectorSectionMatrix.sections(for: .rectangle)
                && narrowAttachedLayout.documentWidth <= 220
                && narrowAttachedLayout.rowWidths.allSatisfy { $0 <= 220 },
            "Expected narrow attached layouts to add rows instead of widening the document"
        )

        let attachedToolbar = CGRect(x: 300, y: 650, width: 300, height: 50)
        let attached = DrawingAttachedInspectorPlacement.frame(
            toolbarFrame: attachedToolbar,
            contentSize: CGSize(width: 208, height: 200),
            visibleFrame: visibleFrame
        )
        let attachedAfterContentChange = DrawingAttachedInspectorPlacement.frame(
            toolbarFrame: attachedToolbar,
            contentSize: CGSize(width: 208, height: 100),
            visibleFrame: visibleFrame,
            previousAlignment: .below
        )
        try expect(
            attached.width == 232
                && attached.minX == attachedToolbar.minX
                && attached.maxY == attachedToolbar.minY
                    - DrawingAttachedInspectorPlacement.gap
                && attachedAfterContentChange.maxY == attached.maxY
                && attachedToolbar == CGRect(x: 300, y: 650, width: 300, height: 50),
            "Expected attached content height changes to leave the toolbar frame stable"
        )
        let attachedAbove = DrawingAttachedInspectorPlacement.frame(
            toolbarFrame: CGRect(x: 300, y: 220, width: 300, height: 50),
            contentSize: CGSize(width: 208, height: 200),
            visibleFrame: visibleFrame
        )
        let attachedClampedRight = DrawingAttachedInspectorPlacement.frame(
            toolbarFrame: CGRect(x: 800, y: 650, width: 200, height: 50),
            contentSize: CGSize(width: 208, height: 200),
            visibleFrame: visibleFrame
        )
        let attachedAlignedRight = DrawingAttachedInspectorPlacement.frame(
            toolbarFrame: CGRect(x: 600, y: 650, width: 200, height: 50),
            contentSize: CGSize(width: 208, height: 200),
            visibleFrame: visibleFrame
        )
        try expect(
            attachedAbove.minY == 276
                && attachedClampedRight.maxX
                    == visibleFrame.maxX
                        - DrawingAttachedInspectorPlacement.screenMargin
                && attachedAlignedRight.maxX == 800
                && visibleFrame.contains(attachedAbove)
                && visibleFrame.contains(attachedClampedRight),
            "Expected attached mode to flip above when needed and remain screen-clamped"
        )
        let hysteresisContent = CGSize(
            width: 600,
            height: 100
        )
        let hysteresisThresholdY = visibleFrame.minY
            + DrawingAttachedInspectorPlacement.screenMargin
            + DrawingAttachedInspectorPlacement.gap
            + hysteresisContent.height
            + DrawingInspectorVisualMetrics.attachedVerticalInset * 2
        let hysteresisFrame = CGRect(
            x: 300,
            y: hysteresisThresholdY,
            width: 300,
            height: 50
        )
        let retainedBelow = DrawingAttachedInspectorPlacement.result(
            toolbarFrame: hysteresisFrame,
            contentSize: hysteresisContent,
            visibleFrame: visibleFrame,
            previousAlignment: .below
        )
        let flippedAbove = DrawingAttachedInspectorPlacement.result(
            toolbarFrame: CGRect(
                x: 300,
                y: hysteresisThresholdY - 1,
                width: 300,
                height: 50
            ),
            contentSize: hysteresisContent,
            visibleFrame: visibleFrame,
            previousAlignment: .below
        )
        try expect(
            retainedBelow.alignment == .below
                && flippedAbove.alignment == .above
                && [retainedBelow.alignment, flippedAbove.alignment].allSatisfy {
                    $0 == .below || $0 == .above
                },
            "Expected attached mode to remain vertically attached across the flip threshold"
        )

        struct TestScreen: Equatable {
            let name: String
            let frame: CGRect
            let visibleFrame: CGRect
        }
        let secondaryScreen = TestScreen(
            name: "secondary",
            frame: CGRect(x: 1_200, y: 0, width: 1_000, height: 700),
            visibleFrame: CGRect(x: 1_200, y: 0, width: 1_000, height: 676)
        )
        let secondaryToolbar = CGRect(x: 1_520, y: 590, width: 360, height: 50)

        let secondaryAttached = DrawingAttachedInspectorPlacement.frame(
            toolbarFrame: secondaryToolbar,
            contentSize: CGSize(width: 208, height: 180),
            visibleFrame: secondaryScreen.visibleFrame
        )
        let secondaryAttachedAfterHeightChange = DrawingAttachedInspectorPlacement.frame(
            toolbarFrame: secondaryToolbar,
            contentSize: CGSize(width: 208, height: 240),
            visibleFrame: secondaryScreen.visibleFrame,
            previousAlignment: .below
        )
        let lowerSecondaryToolbar = CGRect(x: 2_050, y: 18, width: 260, height: 50)
        let secondaryAttachedAbove = DrawingAttachedInspectorPlacement.frame(
            toolbarFrame: lowerSecondaryToolbar,
            contentSize: CGSize(width: 208, height: 180),
            visibleFrame: secondaryScreen.visibleFrame
        )
        try expect(
            secondaryAttached.maxY
                == secondaryToolbar.minY - DrawingAttachedInspectorPlacement.gap
                && secondaryAttachedAfterHeightChange.maxY == secondaryAttached.maxY
                && secondaryAttachedAbove.minY
                    == lowerSecondaryToolbar.maxY + DrawingAttachedInspectorPlacement.gap
                && secondaryAttachedAbove.maxX
                    == secondaryScreen.visibleFrame.maxX
                        - DrawingAttachedInspectorPlacement.screenMargin
                && secondaryScreen.visibleFrame.contains(secondaryAttached)
                && secondaryScreen.visibleFrame.contains(secondaryAttachedAfterHeightChange)
                && secondaryScreen.visibleFrame.contains(secondaryAttachedAbove),
            "Expected attached inspector height updates, flipping, and clamping to use the "
                + "toolbar's secondary display"
        )

        let initialToolbarFrame = CGRect(
            x: 300,
            y: 620,
            width: 698,
            height: 54
        )
        let initialInspectorFrame = DrawingAttachedInspectorPlacement.frame(
            toolbarFrame: initialToolbarFrame,
            contentSize: CGSize(width: 669, height: 66),
            visibleFrame: CGRect(x: 0, y: 0, width: 1_440, height: 900)
        )
        let inspectorOffset = CGPoint(
            x: initialInspectorFrame.minX - initialToolbarFrame.minX,
            y: initialInspectorFrame.minY - initialToolbarFrame.minY
        )
        let dragSamples = stride(from: 0, through: 240, by: 8).map {
            CGPoint(
                x: initialToolbarFrame.minX + CGFloat($0),
                y: initialToolbarFrame.minY - CGFloat($0) * 0.45
            )
        }
        try expect(
            dragSamples.allSatisfy { proposed in
                let toolbarOrigin = DrawingAttachedInspectorDragLock
                    .clampedToolbarOrigin(
                        proposed,
                        toolbarSize: initialToolbarFrame.size,
                        inspectorOffset: inspectorOffset,
                        inspectorSize: initialInspectorFrame.size,
                        visibleFrame: CGRect(
                            x: 0,
                            y: 0,
                            width: 1_440,
                            height: 900
                        )
                    )
                let inspectorOrigin = DrawingAttachedInspectorDragLock
                    .inspectorOrigin(
                        toolbarOrigin: toolbarOrigin,
                        inspectorOffset: inspectorOffset
                    )
                return inspectorOrigin.x - toolbarOrigin.x == inspectorOffset.x
                    && inspectorOrigin.y - toolbarOrigin.y == inspectorOffset.y
            },
            "Expected toolbar and inspector relative offsets to remain exactly invariant at every drag sample"
        )

        let portraitVisibleFrame = CGRect(
            x: 1_440,
            y: 0,
            width: 430,
            height: 800
        )
        let destinationMaximumWidth = portraitVisibleFrame.width
            - DrawingToolbarLayout.screenMargin * 2
        let destinationToolbarSize = DrawingToolbarLayout.preferredSize(
            mainContentSize: CGSize(width: 720, height: 44),
            pathActionsSize: CGSize(width: 63, height: 30),
            maximumWidth: destinationMaximumWidth
        )
        let destinationToolbarOrigin = DrawingToolbarPlacement.clampedOrigin(
            CGPoint(x: 1_700, y: 690),
            panelSize: destinationToolbarSize,
            visibleFrame: portraitVisibleFrame
        )
        let destinationToolbarFrame = CGRect(
            origin: destinationToolbarOrigin,
            size: destinationToolbarSize
        )
        let destinationToolbarFrames = DrawingToolbarLayout.frames(
            in: CGRect(origin: .zero, size: destinationToolbarSize),
            pathActionsSize: CGSize(width: 63, height: 30)
        )
        let destinationInspectorFrame = DrawingAttachedInspectorPlacement.frame(
            toolbarFrame: destinationToolbarFrame,
            contentSize: CGSize(width: 669, height: 66),
            visibleFrame: portraitVisibleFrame
        )
        let persistedDestinationPosition = DrawingToolbarPlacement.normalizedPosition(
            origin: destinationToolbarFrame.origin,
            panelSize: destinationToolbarFrame.size,
            visibleFrame: portraitVisibleFrame
        )
        let restoredDestinationOrigin = DrawingToolbarPlacement.origin(
            normalizedPosition: persistedDestinationPosition,
            panelSize: destinationToolbarFrame.size,
            visibleFrame: portraitVisibleFrame
        )
        let inspectorRemainsAttached =
            destinationInspectorFrame.maxY
                == destinationToolbarFrame.minY - DrawingAttachedInspectorPlacement.gap
            || destinationInspectorFrame.minY
                == destinationToolbarFrame.maxY + DrawingAttachedInspectorPlacement.gap
        try expect(
            destinationToolbarSize.width == destinationMaximumWidth
                && destinationToolbarSize.width < initialToolbarFrame.width
                && destinationToolbarFrames.scrollFrame.width > 0
                && destinationToolbarFrames.pathActionsFrame.maxX
                    <= destinationToolbarSize.width
                && portraitVisibleFrame.contains(destinationToolbarFrame)
                && portraitVisibleFrame.contains(destinationInspectorFrame)
                && inspectorRemainsAttached
                && abs(restoredDestinationOrigin.x - destinationToolbarOrigin.x) < 0.001
                && abs(restoredDestinationOrigin.y - destinationToolbarOrigin.y) < 0.001,
            "Expected a cross-display drag to reflow toolbar controls and attached inspector "
                + "before persisting on a narrower portrait display"
        )
        try expect(
            DrawingAccessoryEventDispatch.bracketsControlTracking(.leftMouseDown)
                && DrawingAccessoryEventDispatch.bracketsControlTracking(.rightMouseDown)
                && DrawingAccessoryEventDispatch.bracketsControlTracking(.otherMouseDown)
                && !DrawingAccessoryEventDispatch.bracketsControlTracking(.leftMouseUp)
                && !DrawingAccessoryEventDispatch.bracketsControlTracking(.scrollWheel),
            "Expected mouse-down dispatch to bracket accessory control tracking"
        )
        var selectedCommand: AppCommand?
        let toolbarView = DrawingToolbarView(
            commandSink: { selectedCommand = $0 },
            showOverflow: { _ in }
        )
        toolbarView.activateTool(.ellipse)
        guard case .setTool(.ellipse)? = selectedCommand else {
            throw SelfTestError.failure(
                "Expected the first toolbar click to dispatch the selected tool"
            )
        }
        try expect(
            toolbarView.isToolSelected(.ellipse),
            "Expected toolbar selection state to update synchronously on the first click"
        )

        let pendingController = AnnotationController()
        pendingController.currentTool = .line
        pendingController.begin(at: CGPoint(x: 10, y: 10), tool: .line)
        pendingController.beginLinearConstructionFromClick(
            at: CGPoint(x: 10, y: 10),
            zoomScale: 1
        )
        _ = pendingController.commitLinearConstructionPoint(
            at: CGPoint(x: 80, y: 50),
            zoomScale: 1
        )
        var typingWasResolved = false
        ModeCoordinator.applyDrawingToolSelection(
            .rectangle,
            annotationController: pendingController,
            finishTypingIfNeeded: {
                typingWasResolved = true
            }
        )
        try expect(
            typingWasResolved
                && pendingController.currentTool == .rectangle
                && !pendingController.isConstructingLinearPath
                && pendingController.elementSnapshot.count == 1,
            "Expected tool switching to finish typing, resolve a pending path, and keep the click"
        )

        try expect(
            DrawingCursorPolicy.presentation(
                interactionMode: .typing,
                isDrawingMode: false,
                tool: .text,
                isAccessoryInteractionActive: false,
                isHandPanning: false,
                isLiveZoomInteractive: false
            ) == .iBeam,
            "Expected pre-placement typing to use the native I-beam"
        )
        try expect(
            !DrawingTextCaretPolicy.shouldDrawInsertionCaret(
                interactionMode: .typing,
                isTextInsertionActive: false,
                isAccessoryInteractionActive: false
            )
                && DrawingCursorPolicy.presentation(
                    interactionMode: .typing,
                    isDrawingMode: false,
                    tool: .text,
                    isAccessoryInteractionActive: false,
                    isHandPanning: false,
                    isLiveZoomInteractive: false,
                    isTextInsertionActive: true
                ) == .hidden
                && DrawingTextCaretPolicy.shouldDrawInsertionCaret(
                    interactionMode: .typing,
                    isTextInsertionActive: true,
                    isAccessoryInteractionActive: false
                ),
            "Expected exactly one text indicator: native I-beam before placement, "
                + "then only the insertion caret while editing"
        )
        try expect(
            DrawingCursorPolicy.presentation(
                interactionMode: .typing,
                isDrawingMode: false,
                tool: .text,
                isAccessoryInteractionActive: true,
                isHandPanning: false,
                isLiveZoomInteractive: false,
                isTextInsertionActive: true
            ) == .arrow
                && !DrawingTextCaretPolicy.shouldDrawInsertionCaret(
                    interactionMode: .typing,
                    isTextInsertionActive: true,
                    isAccessoryInteractionActive: true
                ),
            "Expected inspector interaction to show only its native pointer, not a second canvas caret"
        )
        try expect(
            DrawingCursorPolicy.presentation(
                interactionMode: .staticZoom,
                isDrawingMode: true,
                tool: .text,
                isAccessoryInteractionActive: false,
                isHandPanning: false,
                isLiveZoomInteractive: false
            ) == .iBeam
                && DrawingCursorPolicy.presentation(
                    interactionMode: .staticZoom,
                    isDrawingMode: true,
                    tool: .select,
                    isAccessoryInteractionActive: false,
                    isHandPanning: false,
                    isLiveZoomInteractive: false
                ) == .arrow
                && DrawingCursorPolicy.presentation(
                    interactionMode: .staticZoom,
                    isDrawingMode: true,
                    tool: .hand,
                    isAccessoryInteractionActive: false,
                    isHandPanning: true,
                    isLiveZoomInteractive: false
                ) == .closedHand,
            "Expected text, select, and hand tools to use visible system cursors"
        )
        try expect(
            DrawingCursorPolicy.presentation(
                interactionMode: .staticZoom,
                isDrawingMode: true,
                tool: .pen,
                isAccessoryInteractionActive: true,
                isHandPanning: false,
                isLiveZoomInteractive: false
            ) == .arrow
                && DrawingCursorPolicy.presentation(
                    interactionMode: .staticZoom,
                    isDrawingMode: true,
                    tool: .pen,
                    isAccessoryInteractionActive: false,
                    isHandPanning: false,
                    isLiveZoomInteractive: false
                ) == .hidden,
            "Expected toolbar interaction to show an arrow and pen drawing to restore its indicator cursor"
        )
    }

    static func testDrawingToolbarMenuInteractionLifecycle() throws {
        var state = DrawingAccessoryInteractionState()
        try expect(
            !state.isActive,
            "Expected drawing accessory interaction to start inactive"
        )
        state.menuOpen = true
        try expect(
            state.isActive,
            "Expected overflow-menu tracking to keep drawing accessory interaction active"
        )
        state.menuOpen = false
        try expect(
            !state.isActive,
            "Expected drawing accessory interaction to restore after the menu closes"
        )
        state.popoverOpen = true
        try expect(
            state.isActive && state.preventsLifecycleHide,
            "Expected a separate arrowhead popover window to preserve accessory focus"
        )
        state.popoverOpen = false
        state.pointerOverToolbar = true
        state.menuOpen = true
        state.menuOpen = false
        try expect(
            state.isActive,
            "Expected closing the menu to preserve another active toolbar interaction"
        )
        state.pointerOverToolbar = false
        state.pointerOverInspector = true
        try expect(
            state.isActive && state.preventsLifecycleHide,
            "Expected inspector-window pointer state to cover the full drawing accessory"
        )
        state.pointerOverInspector = false
        state.controlTracking = true
        try expect(
            state.isActive && state.preventsLifecycleHide,
            "Expected inspector controls to prevent lifecycle hide until tracking ends"
        )
        state.controlTracking = false
        state.colorPanelOpen = true
        try expect(
            state.isActive,
            "Expected an active color panel to preserve drawing accessory interaction"
        )
        state.controlTracking = true
        state.menuOpen = true
        state.toolbarDragActive = true
        state.controlTracking = false
        try expect(
            state.colorPanelOpen && state.menuOpen && state.toolbarDragActive && state.isActive,
            "Expected control tracking to remain independent from color, menu, and drag state"
        )
        state.colorPanelOpen = false
        state.menuOpen = false
        state.toolbarDragActive = false
        state.popoverOpen = true
        try expect(
            state.isActive && state.preventsLifecycleHide,
            "Expected an open arrowhead popover to retain drawing accessory focus"
        )
        state.popoverOpen = false
        try expect(
            !state.isActive,
            "Expected drawing accessory focus to release after the final popover closes"
        )
    }

    static func testArrowheadPopoverClickLifecycle() throws {
        let controller = AnnotationController()
        controller.currentTool = .arrow
        controller.begin(at: CGPoint(x: 20, y: 20), tool: .arrow)
        controller.end(at: CGPoint(x: 120, y: 70))
        controller.currentTool = .select
        controller.selectAll()

        var commands: [AppCommand] = []
        var interactionStates: [DrawingAccessoryInteractionState] = []
        var focusRestoreCount = 0
        let focusView = SelfTestFocusView(
            frame: CGRect(x: 0, y: 0, width: 480, height: 320)
        )
        let host = NSWindow(
            contentRect: focusView.bounds,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        host.contentView = focusView
        host.orderFront(nil)
        host.makeFirstResponder(focusView)

        let toolbar = DrawingToolbarController(
            parentWindow: host,
            annotationController: controller,
            toolbarNormalizedPosition: nil,
            commandSink: { command in
                commands.append(command)
                switch command {
                case .setLinearStartArrowhead(let arrowhead):
                    controller.setLinearStartArrowhead(arrowhead)
                case .setLinearEndArrowhead(let arrowhead):
                    controller.setLinearEndArrowhead(arrowhead)
                case .setLinearArrowheadSize(let size):
                    controller.setLinearArrowheadSize(size)
                default:
                    break
                }
            },
            restoreCanvasFocus: {
                focusRestoreCount += 1
                host.makeFirstResponder(focusView)
            },
            toolbarPlacementDidChange: { _ in },
            pointerInteractionChanged: {
                interactionStates.append($0)
            }
        )
        toolbar.show()
        RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        let appWasActive = NSApp.isActive
        NSApp.deactivate()
        RunLoop.current.run(until: Date().addingTimeInterval(0.03))
        defer {
            toolbar.close()
            host.orderOut(nil)
            if appWasActive {
                NSApp.activate(ignoringOtherApps: true)
            }
        }

        func physicallySelect(
            _ arrowhead: AnnotationArrowhead,
            with picker: DrawingInspectorArrowheadPicker
        ) throws {
            try dispatchPhysicalClick(on: picker.triggerButtonForTesting)
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
            guard let palettePanel = picker.palettePanelForTesting,
                  palettePanel.isVisible,
                  let paletteView = palettePanel.contentViewController?.view,
                  let button = descendantViews(
                    of: NSButton.self,
                    in: paletteView
                  ).first(where: {
                      $0.accessibilityLabel() == arrowhead.displayName
                  }) else {
                throw SelfTestError.failure(
                    "Expected a nontransient arrowhead palette and "
                        + "\(arrowhead.displayName) button"
                )
            }
            try expect(
                interactionStates.last?.popoverOpen == true
                    && palettePanel.sharingType == .none
                    && controller.selectedElementSnapshot.count == 1,
                "Expected the arrowhead palette to retain accessory interaction "
                    + "and selection while remaining non-shareable"
            )
            try dispatchPhysicalClick(on: button)
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        }

        try expect(
            !NSApp.isActive,
            "Expected the physical arrowhead click test to begin with the app inactive"
        )

        let endPicker = toolbar.endArrowheadPickerForTesting
        commands.removeAll()
        try physicallySelect(.none, with: endPicker)
        guard case .linear(let headless) =
            controller.selectedElementSnapshot.first?.geometry else {
            throw SelfTestError.failure("Expected a selected headless linear element")
        }
        let headlessState = DrawingToolbarState(annotationController: controller)
        try expect(
            commands == [.setLinearEndArrowhead(.none)]
                && headless.startArrowhead == .none
                && headless.endArrowhead == .none
                && endPicker.palettePanelForTesting == nil
                && controller.currentTool == .select
                && controller.selectedElementSnapshot.count == 1
                && headlessState.visibleInspectorSections.contains(.arrowheads)
                && headlessState.visibleInspectorSections.contains(.arrowheadSize)
                && endPicker.triggerButtonForTesting.superview != nil
                && endPicker.triggerButtonForTesting.window
                    === toolbar.inspectorWindowForTesting
                && endPicker.triggerButtonForTesting.isEnabled,
            "Expected removing the last head to close the palette while retaining "
                + "selection, inspector sections, and enabled attached triggers"
        )
        commands.removeAll()
        try physicallySelect(.diamond, with: endPicker)
        guard case .linear(let restoredHead) =
            controller.selectedElementSnapshot.first?.geometry else {
            throw SelfTestError.failure("Expected a selected restored arrowhead")
        }
        try expect(
            commands == [.setLinearEndArrowhead(.diamond)]
                && restoredHead.endArrowhead == .diamond
                && endPicker.palettePanelForTesting == nil,
            "Expected the retained trigger to reopen and select a new arrowhead"
        )
        controller.undo()
        guard case .linear(let restoredHeadUndone) =
            controller.selectedElementSnapshot.first?.geometry else {
            throw SelfTestError.failure("Expected the restored arrowhead undo target")
        }
        try expect(
            restoredHeadUndone.endArrowhead == .none
                && controller.selectedElementSnapshot.count == 1,
            "Expected one undo to revert the reopened arrowhead selection"
        )
        toolbar.updateState(DrawingToolbarState(annotationController: controller))

        let startPicker = toolbar.startArrowheadPickerForTesting
        commands.removeAll()
        let startFocusRestoreCount = focusRestoreCount
        try physicallySelect(.triangle, with: startPicker)
        guard case .linear(let startEdited) =
            controller.selectedElementSnapshot.first?.geometry else {
            throw SelfTestError.failure("Expected a selected start-edited arrow")
        }
        try expect(
            commands == [.setLinearStartArrowhead(.triangle)]
                && startEdited.startArrowhead == .triangle
                && controller.selectedElementSnapshot.count == 1
                && controller.currentTool == .select
                && !controller.canRedo
                && startPicker.palettePanelForTesting == nil
                && focusRestoreCount == startFocusRestoreCount + 1
                && host.firstResponder === focusView,
            "Expected one inactive-app physical start-family command, retained "
                + "selection/edit mode, closed palette, and restored canvas focus"
        )
        controller.undo()
        guard case .linear(let startUndone) =
            controller.selectedElementSnapshot.first?.geometry else {
            throw SelfTestError.failure("Expected start-arrowhead undo target")
        }
        try expect(
            startUndone.startArrowhead == .none
                && controller.elementSnapshot.count == 1,
            "Expected one undo to revert only the physical start-family command"
        )
        toolbar.updateState(DrawingToolbarState(annotationController: controller))

        commands.removeAll()
        try physicallySelect(.diamond, with: endPicker)
        guard case .linear(let endEdited) =
            controller.selectedElementSnapshot.first?.geometry else {
            throw SelfTestError.failure("Expected a selected end-edited arrow")
        }
        try expect(
            commands == [.setLinearEndArrowhead(.diamond)]
                && endEdited.endArrowhead == .diamond
                && endPicker.palettePanelForTesting == nil
                && controller.currentTool == .select
                && controller.selectedElementSnapshot.count == 1,
            "Expected one inactive-app physical end-family command with retained "
                + "selection and edit mode"
        )
        controller.undo()
        guard case .linear(let endUndone) =
            controller.selectedElementSnapshot.first?.geometry else {
            throw SelfTestError.failure("Expected end-arrowhead undo target")
        }
        try expect(
            endUndone.endArrowhead == .none,
            "Expected one undo to revert only the physical end-family command"
        )
        toolbar.updateState(DrawingToolbarState(annotationController: controller))

        guard let largeSizeButton = descendantViews(
            of: NSButton.self,
            in: toolbar.inspectorWindowForTesting.contentView ?? NSView()
        ).first(where: {
            $0.accessibilityLabel() == AnnotationArrowheadSize.large.displayName
        }) else {
            throw SelfTestError.failure("Expected the Arrow size palette")
        }
        commands.removeAll()
        try dispatchPhysicalClick(on: largeSizeButton)
        RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        guard case .linear(let resized) =
            controller.selectedElementSnapshot.first?.geometry else {
            throw SelfTestError.failure("Expected a resized selected arrow")
        }
        try expect(
            commands == [.setLinearArrowheadSize(.large)]
                && resized.arrowheadSize == .large,
            "Expected the existing Arrow size palette to remain first-click interactive"
        )

        try dispatchPhysicalClick(on: startPicker.triggerButtonForTesting)
        RunLoop.current.run(until: Date().addingTimeInterval(0.03))
        guard let escapePanel = startPicker.palettePanelForTesting,
              let escape = NSEvent.keyEvent(
                  with: .keyDown,
                  location: .zero,
                  modifierFlags: [],
                  timestamp: 0,
                  windowNumber: escapePanel.windowNumber,
                  context: nil,
                  characters: "\u{1b}",
                  charactersIgnoringModifiers: "\u{1b}",
                  isARepeat: false,
                  keyCode: 53
              ) else {
            throw SelfTestError.failure(
                "Expected an Arrow palette for Escape dismissal"
            )
        }
        escapePanel.sendEvent(escape)
        RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        try expect(
            startPicker.palettePanelForTesting == nil,
            "Expected Escape to close the Arrow palette"
        )

    }

    static func testDrawingAccessorySuppressionLifecycle() throws {
        var lifecycle = DrawingAccessorySuppressionLifecycle()
        let selector = lifecycle.begin()
        let nestedModal = lifecycle.begin()
        try expect(
            lifecycle.isSuppressed,
            "Expected external selector and nested modal suppression to hide drawing accessories"
        )
        try expect(
            lifecycle.finish(selector) && lifecycle.isSuppressed,
            "Expected finishing one nested suppression not to restore drawing accessories"
        )
        try expect(
            !lifecycle.finish(selector) && lifecycle.isSuppressed,
            "Expected duplicate selector teardown to be idempotent"
        )
        try expect(
            lifecycle.finish(nestedModal) && !lifecycle.isSuppressed,
            "Expected drawing accessories to restore after the final suppression finishes"
        )

        let staleSelector = lifecycle.begin()
        lifecycle.reset()
        let currentSelector = lifecycle.begin()
        try expect(
            !lifecycle.finish(staleSelector) && lifecycle.isSuppressed,
            "Expected stale selector teardown not to release a newer suppression generation"
        )
        try expect(
            lifecycle.finish(currentSelector) && !lifecycle.isSuppressed,
            "Expected the current selector teardown to release its own suppression"
        )
    }

    static func testDrawingToolbarStyleActionsAndEraserHistory() throws {
        let controller = AnnotationController()
        controller.currentTool = .rectangle
        controller.begin(at: CGPoint(x: 10, y: 10))
        controller.end(at: CGPoint(x: 80, y: 80))
        controller.currentTool = .select
        _ = controller.beginSelectionInteraction(
            at: CGPoint(x: 12, y: 40),
            zoomScale: 1,
            modifiers: [],
            clickCount: 1
        )
        controller.endSelectionInteraction(at: CGPoint(x: 12, y: 40), modifiers: [])

        controller.setStrokeColor(.palette(.green))
        controller.setFillColor(.palette(.yellow))
        controller.setFillStyle(.solid)
        controller.setStrokePattern(.dashed)
        controller.setStrokeWidth(8)
        controller.setSloppiness(.cartoonist)
        controller.setOpacity(0.4)
        controller.setRoundness(12)

        guard let styled = controller.selectedElementSnapshot.first else {
            throw SelfTestError.failure("Expected selected element after toolbar style actions")
        }
        try expect(
            styled.style.strokeColor == .palette(.green)
                && styled.style.fillColor == .palette(.yellow)
                && styled.style.fillStyle == .solid
                && styled.style.strokePattern == .dashed
                && styled.style.strokeWidth == 8
                && styled.style.sloppiness == .cartoonist
                && styled.style.opacity == 0.4
                && styled.style.roundness == 12,
            "Expected toolbar style actions to update selection through the editor boundary"
        )

        controller.currentTool = .eraser
        let committedPixels = try renderControllerPixels(
            controller,
            freehandPresentationOwner: .canonicalRenderer,
            width: 96,
            height: 96
        )
        controller.beginErasing(at: CGPoint(x: 40, y: 40), zoomScale: 1)
        let pendingPixels = try renderControllerPixels(
            controller,
            freehandPresentationOwner: .canonicalRenderer,
            width: 96,
            height: 96
        )
        let capturePixels = try renderControllerPixels(
            controller,
            freehandPresentationOwner: .canonicalRenderer,
            includeTransientEraserFeedback: false,
            width: 96,
            height: 96
        )
        let committedAlpha = alpha(committedPixels, width: 96, x: 40, y: 40)
        let pendingAlpha = alpha(pendingPixels, width: 96, x: 40, y: 40)
        try expect(
            controller.elementSnapshot.count == 1
                && controller.pendingErasureElementIDsForTesting.count == 1
                && pendingAlpha > 0
                && abs(CGFloat(pendingAlpha) / CGFloat(committedAlpha) - 0.28) < 0.08
                && alpha(capturePixels, width: 96, x: 40, y: 40)
                    == committedAlpha,
            "Expected staged erasure to fade only the on-screen presentation"
        )
        controller.cancelErasing()
        try expect(
            controller.elementSnapshot.count == 1
                && controller.pendingErasureElementIDsForTesting.isEmpty,
            "Expected eraser cancellation to restore full presentation without history"
        )
        controller.beginErasing(at: CGPoint(x: 40, y: 40), zoomScale: 1)
        var releaseNotificationCount = 0
        controller.onStateChanged = { releaseNotificationCount += 1 }
        controller.endErasing()
        try expect(
            controller.elementSnapshot.isEmpty
                && releaseNotificationCount == 1,
            "Expected eraser release to remove the staged annotation with one "
                + "scene notification"
        )
        controller.onStateChanged = nil
        controller.undo()
        try expect(controller.elementSnapshot.count == 1, "Expected eraser gesture to undo as one transaction")
        controller.redo()
        try expect(controller.elementSnapshot.isEmpty, "Expected erased annotation to redo")

        controller.undo()
        let beforeZeroHitUndo = controller.elementSnapshot[0].style
        controller.beginErasing(at: CGPoint(x: 200, y: 200), zoomScale: 1)
        controller.endErasing()
        controller.undo()
        try expect(
            controller.elementSnapshot.count == 1
                && controller.elementSnapshot[0].style != beforeZeroHitUndo,
            "Expected a zero-hit eraser release to add no history step"
        )

        let overlapController = AnnotationController()
        overlapController.currentTool = .rectangle
        overlapController.begin(at: CGPoint(x: 10, y: 10))
        overlapController.end(at: CGPoint(x: 70, y: 70))
        overlapController.begin(at: CGPoint(x: 14, y: 14))
        overlapController.end(at: CGPoint(x: 74, y: 74))
        let originalOrder = overlapController.elementSnapshot.map(\.id)
        overlapController.beginErasing(
            at: CGPoint(x: 14, y: 40),
            zoomScale: 1
        )
        try expect(
            overlapController.pendingErasureElementIDsForTesting.count == 2
                && overlapController.elementSnapshot.map(\.id) == originalOrder,
            "Expected one eraser sample to collect every stacked hit without changing z-order"
        )
        let overlapHitTestCount = overlapController.eraserHitTestCountForTesting
        overlapController.continueErasing(
            at: CGPoint(x: 14, y: 40),
            zoomScale: 1
        )
        try expect(
            overlapController.pendingErasureElementIDsForTesting.count == 2
                && overlapController.eraserHitTestCountForTesting
                    == overlapHitTestCount,
            "Expected repeated samples to avoid duplicate hit tests after all stacked elements are pending"
        )
        overlapController.cancelErasing()
    }

    static func testToolScopedWidthsAndCompactToolbarGeometry() throws {
        let controller = AnnotationController()
        controller.applyDrawingDefaults(
            .default,
            strokeWidth: AnnotationStrokeWidthDefaults.pen,
            highlighterWidth: AnnotationStrokeWidthDefaults.highlighter,
            geometryWidth: AnnotationStrokeWidthDefaults.geometry
        )
        try expect(
            controller.currentTool == .pen
                && controller.currentStyle.strokeWidth == 7,
            "Expected the default Pen width to be 7 points"
        )
        controller.setStrokeWidth(11)
        controller.setStrokeColor(.palette(.blue))
        controller.currentTool = .rectangle
        try expect(
            controller.currentStyle.strokeWidth == 3,
            "Expected geometry to retain an independent default width"
        )
        controller.setStrokeWidth(6)
        controller.setStrokePattern(.dotted)
        controller.currentTool = .highlighter
        try expect(
            controller.currentStyle.strokeWidth == 18
                && controller.currentStyle.strokeColor
                    == .palette(.highlighterYellow)
                && controller.currentStyle.strokePattern == .solid
                && controller.currentStyle.pressureMode == .fixed,
            "Expected Highlighter to restore its dedicated width, color, and fixed solid marker style"
        )
        controller.setStrokeWidth(28)
        controller.setStrokeColor(.palette(.highlighterPink))
        controller.currentTool = .pen
        try expect(
            controller.currentStyle.strokeWidth == 11
                && controller.currentStyle.strokeColor == .palette(.blue)
                && controller.currentStyle.strokePattern == .solid,
            "Expected Pen to restore its independent width/color scope without geometry patterns"
        )
        controller.currentTool = .rectangle
        try expect(
            controller.currentStyle.strokeWidth == 6
                && controller.currentStyle.strokePattern == .dotted,
            "Expected geometry width and dotted style to survive freehand tool switches"
        )
        controller.currentTool = .highlighter
        try expect(
            controller.currentStyle.strokeWidth == 28
                && controller.currentStyle.strokeColor
                    == .palette(.highlighterPink),
            "Expected Highlighter width and color to persist independently"
        )

        let penState: DrawingToolbarState = {
            controller.currentTool = .pen
            return DrawingToolbarState(annotationController: controller)
        }()
        let highlighterState: DrawingToolbarState = {
            controller.currentTool = .highlighter
            return DrawingToolbarState(annotationController: controller)
        }()
        let geometryState: DrawingToolbarState = {
            controller.currentTool = .rectangle
            return DrawingToolbarState(annotationController: controller)
        }()
        try expect(
            penState.strokeWidthOptions == [3, 7, 11]
                && highlighterState.strokeWidthOptions == [10, 18, 28]
                && geometryState.strokeWidthOptions == [1, 3, 6]
                && DrawingInspectorSectionMatrix.sections(for: .highlighter)
                    == [.strokeColor, .strokeWidth, .opacity],
            "Expected exact per-tool width choices and Highlighter sections"
        )

        var toolbarCommands: [AppCommand] = []
        var dragEventTypes: [NSEvent.EventType] = []
        let toolbar = DrawingToolbarView(
            commandSink: { toolbarCommands.append($0) },
            showOverflow: { _ in },
            beginDragging: { dragEventTypes.append($0.type) }
        )
        toolbar.update(state: geometryState, transientTool: nil)
        let preferredSize = toolbar.preferredContentSize()
        toolbar.frame = CGRect(origin: .zero, size: preferredSize)
        toolbar.layoutSubtreeIfNeeded()
        let frames = toolbar.buttonFramesForTesting
        let itemOrder = toolbar.primaryItemOrderForTesting
        let buttonVisuals = toolbar.primaryButtonVisualsForTesting
        let shadowMetrics = toolbar.shellShadowMetricsForTesting
        let labels = descendantViews(
            of: NSButton.self,
            in: toolbar
        ).compactMap { $0.accessibilityLabel() }
        let selectedFilledButtons = buttonVisuals.filter {
            $0.value.isSelected && $0.value.backgroundAlpha > 0.99
        }.map(\.key)
        let idleButtonsAreClear = buttonVisuals.allSatisfy {
            $0.value.isSelected
                || (
                    $0.value.backgroundAlpha == 0
                        && $0.value.borderWidth == 0
                )
        }
        let flippedHintOrigin = DrawingToolbarVisualMetrics.numericHintOrigin(
            in: CGRect(x: 0, y: 0, width: 44, height: 44),
            textSize: CGSize(width: 5, height: 10),
            isFlipped: true
        )
        let backgroundHit = toolbar.hitTest(CGPoint(x: 1, y: 1))
        let rectangleHitPoint = toolbar.buttonHitPointsForTesting["rectangle"]
            ?? .zero
        let rectangleHit = toolbar.hitTest(
            rectangleHitPoint
        )
        let dragHandleFrame = toolbar.dragHandleFrameForTesting
        let dragHandleHitPoint = CGPoint(
            x: dragHandleFrame.midX,
            y: dragHandleFrame.midY
        )
        let dragHandleAccessibility =
            toolbar.dragHandleAccessibilityForTesting
        guard let highlighterButton = descendantViews(
            of: NSButton.self,
            in: toolbar
        ).first(where: {
            $0.accessibilityLabel() == "Highlighter"
        }), let dragMouseDown = NSEvent.mouseEvent(
            with: .leftMouseDown,
            location: dragHandleHitPoint,
            modifierFlags: [],
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            eventNumber: 1,
            clickCount: 1,
            pressure: 0
        ) else {
            throw SelfTestError.failure(
                "Expected visible Highlighter and drag-handle test controls"
            )
        }
        highlighterButton.performClick(nil)
        let controlClickAvoidedDrag = dragEventTypes.isEmpty
        toolbar.beginDragFromHandleForTesting(with: dragMouseDown)
        let expectedItemOrder = [
            "Move Drawing Toolbar",
            "separator",
            "Hand",
            "Select",
            "Rectangle",
            "Diamond",
            "Ellipse",
            "Arrow",
            "Line",
            "Pen",
            "Highlighter",
            "Text",
            "Eraser",
            "separator",
            "More Drawing Actions"
        ]
        let dragHandleIsValid =
            dragHandleFrame.size == CGSize(width: 24, height: 44)
                && toolbar.isDragHandleHitForTesting(at: dragHandleHitPoint)
                && dragHandleAccessibility.label == "Move Drawing Toolbar"
                && dragHandleAccessibility.help
                    == "Drag to move the drawing toolbar and attached inspector"
                && controlClickAvoidedDrag
                && dragEventTypes == [.leftMouseDown]
        let highlighterIsValid =
            highlighterButton.image != nil
                && highlighterButton.toolTip == "Highlighter (H)"
                && highlighterButton.accessibilityHelp() == "Highlighter (H)"
                && toolbarCommands == [.setTool(.highlighter)]
                && toolbar.isToolSelected(.highlighter)
        try expect(
            preferredSize.height == 54
                && preferredSize.width == 648
                && frames.count == 11
                && DrawingToolbarVisualMetrics.buttonSide == 44
                && itemOrder == expectedItemOrder
                && selectedFilledButtons == ["Rectangle"]
                && idleButtonsAreClear
                && toolbar.backgroundDragEnabledForTesting
                && backgroundHit === toolbar
                && rectangleHit !== toolbar
                && dragHandleIsValid
                && highlighterIsValid
                && toolbar.layer?.borderWidth == 0
                && toolbar.layer?.cornerRadius == 15
                && toolbar.shellShadowLayerCountForTesting == 3
                && shadowMetrics == [
                    DrawingToolbarShadowMetric(
                        opacity: 0.17,
                        blurRadius: 1,
                        offset: .zero
                    ),
                    DrawingToolbarShadowMetric(
                        opacity: 0.08,
                        blurRadius: 3,
                        offset: .zero
                    ),
                    DrawingToolbarShadowMetric(
                        opacity: 0.05,
                        blurRadius: 14,
                        offset: CGSize(width: 0, height: 7)
                    )
                ]
                && flippedHintOrigin == CGPoint(x: 35, y: 30)
                && labels.contains("Hand")
                && labels.contains("Highlighter")
                && labels.contains("More Drawing Actions")
                && !labels.contains("Toggle Drawing Inspector"),
            "Expected the polished primary toolbar with visible Highlighter, exact order, "
                + "accessible grip dragging, control-safe hit testing, transparent idle tiles, "
                + "one selected fill, and lower-right numeric hints"
        )
        controller.currentTool = .pen
        controller.begin(at: CGPoint(x: 0, y: 0))
        controller.end(at: CGPoint(x: 20, y: 20))
        try expect(
            controller.currentTool == .pen,
            "Expected drawing tools to remain selected after use without a toolbar lock mode"
        )
    }
}
