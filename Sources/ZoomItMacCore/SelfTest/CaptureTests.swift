import AppKit

extension SelfTestRunner {
    static func testDrawingCapturePolicies() throws {
        try expect(
            !ZoomCanvasCapturePolicy.stillImage.includesInProgressAnnotations
                && !ZoomCanvasCapturePolicy.stillImage.includesSmartDrawPreview
                && !ZoomCanvasCapturePolicy.stillImage.includesEditorChrome
                && !ZoomCanvasCapturePolicy.stillImage
                    .includesTransientEraserFeedback
                && ZoomCanvasCapturePolicy.stillImage.freehandPresentationOwner
                    == .canonicalRenderer
                && !ZoomCanvasCapturePolicy.stillImage
                    .includesImmediateFreehandLayers
                && ZoomCanvasCapturePolicy.recording.includesInProgressAnnotations
                && ZoomCanvasCapturePolicy.recording.includesSmartDrawPreview
                && !ZoomCanvasCapturePolicy.recording.includesEditorChrome
                && !ZoomCanvasCapturePolicy.recording
                    .includesTransientEraserFeedback
                && ZoomCanvasCapturePolicy.recording.freehandPresentationOwner
                    == .canonicalRenderer
                && !ZoomCanvasCapturePolicy.recording
                    .includesImmediateFreehandLayers,
            "Expected captures to omit editor/eraser presentation while recordings "
                + "preserve canonical active drawing without presentation layers"
        )

        for tool in [AnnotationTool.pen, .rectangle] {
            let controller = AnnotationController()
            controller.currentTool = tool
            controller.begin(at: CGPoint(x: 12, y: 14), tool: tool)
            controller.update(at: CGPoint(x: 54, y: 58))
            guard let activeElement = controller.inProgressElementSnapshot else {
                throw SelfTestError.failure(
                    "Expected an in-progress capture-policy \(tool)"
                )
            }
            let stillPixels = try renderPixels(
                elements: controller.elementSnapshot,
                renderer: AnnotationRenderer(),
                activeElement: ZoomCanvasCapturePolicy.stillImage
                    .includesInProgressAnnotations ? activeElement : nil,
                width: 72,
                height: 72
            )
            let recordingPixels = try renderPixels(
                elements: controller.elementSnapshot,
                renderer: AnnotationRenderer(),
                activeElement: ZoomCanvasCapturePolicy.recording
                    .includesInProgressAnnotations ? activeElement : nil,
                width: 72,
                height: 72
            )
            try expect(
                !stillPixels.contains(where: { $0 != 0 })
                    && recordingPixels.contains(where: { $0 != 0 }),
                "Expected recording policy to render active \(tool) content "
                    + "while still-image policy omits it"
            )
        }
    }

    static func testCaptureAccessoryCompositorGeometry() throws {
        let display = CGRect(x: -200, y: 500, width: 100, height: 80)
        let localAccessory = CGRect(x: 10, y: 20, width: 20, height: 10)
        func globalFrame(
            displayFrame: CGRect,
            localTopLeftFrame: CGRect
        ) -> CGRect {
            CGRect(
                x: displayFrame.minX + localTopLeftFrame.minX,
                y: displayFrame.maxY - localTopLeftFrame.maxY,
                width: localTopLeftFrame.width,
                height: localTopLeftFrame.height
            )
        }

        let accessory = globalFrame(
            displayFrame: display,
            localTopLeftFrame: localAccessory
        )
        let oneX = CaptureAccessoryCompositor.placement(
            accessoryFrame: accessory,
            displayFrame: display,
            sourceRegion: CGRect(x: 0, y: 0, width: 100, height: 80),
            outputPixelSize: CGSize(width: 100, height: 80)
        )
        let twoX = CaptureAccessoryCompositor.placement(
            accessoryFrame: accessory,
            displayFrame: display,
            sourceRegion: CGRect(x: 0, y: 0, width: 100, height: 80),
            outputPixelSize: CGSize(width: 200, height: 160)
        )
        try expect(
            oneX == CaptureAccessoryPlacement(
                drawRect: CGRect(x: 10, y: 50, width: 20, height: 10),
                clipRect: CGRect(x: 10, y: 50, width: 20, height: 10)
            )
                && twoX == CaptureAccessoryPlacement(
                    drawRect: CGRect(x: 20, y: 100, width: 40, height: 20),
                    clipRect: CGRect(x: 20, y: 100, width: 40, height: 20)
                ),
            "Expected accessory placement to use output/source scale at 1x and 2x"
        )

        let aboveDisplay = CGRect(x: -200, y: 1_200, width: 100, height: 80)
        let belowDisplay = CGRect(x: -200, y: -600, width: 100, height: 80)
        for shiftedDisplay in [aboveDisplay, belowDisplay] {
            let shiftedAccessory = globalFrame(
                displayFrame: shiftedDisplay,
                localTopLeftFrame: localAccessory
            )
            try expect(
                CaptureAccessoryCompositor.placement(
                    accessoryFrame: shiftedAccessory,
                    displayFrame: shiftedDisplay,
                    sourceRegion: CGRect(
                        x: 0,
                        y: 0,
                        width: 100,
                        height: 80
                    ),
                    outputPixelSize: CGSize(width: 100, height: 80)
                ) == oneX,
                "Expected display origins above and below the primary display "
                    + "to preserve display-local top-left placement"
            )
        }

        let mixedScaleRegion = CaptureAccessoryCompositor.placement(
            accessoryFrame: accessory,
            displayFrame: display,
            sourceRegion: CGRect(x: 5, y: 15, width: 40, height: 30),
            outputPixelSize: CGSize(width: 80, height: 90)
        )
        try expect(
            mixedScaleRegion == CaptureAccessoryPlacement(
                drawRect: CGRect(x: 10, y: 45, width: 40, height: 30),
                clipRect: CGRect(x: 10, y: 45, width: 40, height: 30)
            ),
            "Expected region placement to use independent mixed X/Y output scales"
        )

        let partiallyVisible = globalFrame(
            displayFrame: display,
            localTopLeftFrame: CGRect(
                x: -4.5,
                y: 12.25,
                width: 12,
                height: 8.5
            )
        )
        let partialPlacement = CaptureAccessoryCompositor.placement(
            accessoryFrame: partiallyVisible,
            displayFrame: display,
            sourceRegion: CGRect(x: 0, y: 10, width: 30, height: 20),
            outputPixelSize: CGSize(width: 75, height: 30)
        )
        try expect(
            partialPlacement == CaptureAccessoryPlacement(
                drawRect: CGRect(
                    x: -11.25,
                    y: 13.875,
                    width: 30,
                    height: 12.75
                ),
                clipRect: CGRect(
                    x: 0,
                    y: 13.875,
                    width: 18.75,
                    height: 12.75
                )
            ),
            "Expected fractional panels to clip against both the display and "
                + "top-left recording region without integral rounding"
        )
    }

    static func testCaptureAccessoryCompositorBlendingAndShadow() throws {
        let display = CGRect(x: 0, y: 0, width: 40, height: 30)
        let base = try makeSolidImage(
            width: 40,
            height: 30,
            color: .white
        )
        let red = try makeSolidImage(
            width: 20,
            height: 10,
            color: .red
        )
        let blue = try makeSolidImage(
            width: 20,
            height: 10,
            color: .blue
        )
        let translucent = try makeSolidImage(
            width: 6,
            height: 6,
            color: NSColor.red.withAlphaComponent(0.5)
        )
        func globalFrame(_ localTopLeftFrame: CGRect) -> CGRect {
            CGRect(
                x: localTopLeftFrame.minX,
                y: display.maxY - localTopLeftFrame.maxY,
                width: localTopLeftFrame.width,
                height: localTopLeftFrame.height
            )
        }

        guard let composed = CaptureAccessoryCompositor.compose(
            baseImage: base,
            displayFrame: display,
            sourceRegion: CGRect(origin: .zero, size: display.size),
            outputPixelSize: display.size,
            accessories: [
                CaptureAccessorySnapshot(
                    globalFrame: globalFrame(
                        CGRect(x: 4, y: 4, width: 20, height: 10)
                    ),
                    image: red
                ),
                CaptureAccessorySnapshot(
                    globalFrame: globalFrame(
                        CGRect(x: 9, y: 7, width: 20, height: 10)
                    ),
                    image: blue
                ),
                CaptureAccessorySnapshot(
                    globalFrame: globalFrame(
                        CGRect(x: 31, y: 3, width: 6, height: 6)
                    ),
                    image: translucent
                )
            ]
        ) else {
            throw SelfTestError.failure(
                "Could not create synthetic accessory composition"
            )
        }
        let representation = NSBitmapImageRep(cgImage: composed)
        guard let outside = representation.colorAt(x: 1, y: 1)?
                  .usingColorSpace(.sRGB),
              let toolbarOnly = representation.colorAt(x: 6, y: 6)?
                  .usingColorSpace(.sRGB),
              let overlap = representation.colorAt(x: 12, y: 9)?
                  .usingColorSpace(.sRGB),
              let alphaBlend = representation.colorAt(x: 33, y: 5)?
                  .usingColorSpace(.sRGB) else {
            throw SelfTestError.failure(
                "Could not sample synthetic accessory composition"
            )
        }
        try expect(
            outside.redComponent > 0.95
                && outside.greenComponent > 0.95
                && outside.blueComponent > 0.95
                && toolbarOnly.redComponent > 0.9
                && toolbarOnly.greenComponent < 0.1
                && overlap.blueComponent > 0.9
                && overlap.redComponent < 0.1
                && alphaBlend.redComponent > 0.9
                && (0.4...0.6).contains(alphaBlend.greenComponent)
                && (0.4...0.6).contains(alphaBlend.blueComponent),
            "Expected base -> toolbar -> inspector alpha blending in stable z-order"
        )

        let shadowContent = try makeSolidImage(
            width: 12,
            height: 12,
            color: .black
        )
        guard let shadowSnapshot = CaptureAccessorySnapshotRenderer.snapshot(
            contentImage: shadowContent,
            globalFrame: CGRect(x: 10, y: 10, width: 12, height: 12),
            scaleX: 2,
            scaleY: 2,
            shadow: .inspector
        ) else {
            throw SelfTestError.failure(
                "Could not create inspector shadow snapshot"
            )
        }
        let shadowRepresentation = NSBitmapImageRep(
            cgImage: shadowSnapshot.image
        )
        let padding = Int(CaptureAccessoryShadowStyle.inspector.padding * 2)
        var shadowPixelFound = false
        for y in 0..<shadowRepresentation.pixelsHigh {
            for x in 0..<shadowRepresentation.pixelsWide {
                let insideContent = x >= padding
                    && x < padding + 24
                    && y >= padding
                    && y < padding + 24
                if !insideContent,
                   (shadowRepresentation.colorAt(x: x, y: y)?
                       .alphaComponent ?? 0) > 0.01 {
                    shadowPixelFound = true
                    break
                }
            }
            if shadowPixelFound { break }
        }
        try expect(
            shadowSnapshot.globalFrame
                == CGRect(x: -6, y: -6, width: 44, height: 44)
                && shadowSnapshot.image.width == 88
                && shadowSnapshot.image.height == 88
                && shadowPixelFound,
            "Expected inspector snapshots to include deterministic alpha shadow padding"
        )
    }

    static func testDrawingAccessoryCaptureVisibilityAndSharing() throws {
        let visibleFrame = NSScreen.main?.visibleFrame
            ?? CGRect(x: 0, y: 0, width: 1_200, height: 800)
        let parent = NSWindow(
            contentRect: visibleFrame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        parent.level = .screenSaver
        parent.isReleasedWhenClosed = false
        parent.orderFront(nil)

        let annotationController = AnnotationController()
        annotationController.currentTool = .hand
        let controller = DrawingToolbarController(
            parentWindow: parent,
            annotationController: annotationController,
            toolbarNormalizedPosition: nil,
            commandSink: { _ in },
            restoreCanvasFocus: {},
            toolbarPlacementDidChange: { _ in },
            pointerInteractionChanged: { _ in }
        )
        defer {
            controller.close()
            parent.orderOut(nil)
        }

        try expect(
            controller.captureAccessorySnapshots(
                scaleX: 1,
                scaleY: 1
            ).isEmpty,
            "Expected inactive drawing controls to produce no capture snapshots"
        )
        controller.show()
        RunLoop.current.run(until: Date().addingTimeInterval(0.03))
        let handSnapshots = controller.captureAccessorySnapshots(
            scaleX: 1,
            scaleY: 1
        )
        try expect(
            handSnapshots.count == 1
                && handSnapshots[0].globalFrame
                    == controller.toolbarFrameForTesting
                && controller.toolbarWindowForTesting.sharingType == .readOnly
                && controller.inspectorWindowForTesting.sharingType == .readOnly
                && controller.toolbarWindowForTesting.level.rawValue
                    >= parent.level.rawValue
                && controller.inspectorWindowForTesting.level.rawValue
                    >= controller.toolbarWindowForTesting.level.rawValue
                && controller.toolbarWindowForTesting.parent === parent,
            "Expected the visible stable toolbar to be externally shareable "
                + "without a propertyless inspector (snapshots "
                + "\(handSnapshots.count), toolbar sharing "
                + "\(controller.toolbarWindowForTesting.sharingType.rawValue), "
                + "inspector sharing "
                + "\(controller.inspectorWindowForTesting.sharingType.rawValue), "
                + "levels \(controller.toolbarWindowForTesting.level.rawValue)/"
                + "\(controller.inspectorWindowForTesting.level.rawValue)/"
                + "\(parent.level.rawValue), frame "
                + "\(handSnapshots.first?.globalFrame == controller.toolbarFrameForTesting), "
                + "parents "
                + "\(controller.toolbarWindowForTesting.parent === parent)/"
                + "\(controller.inspectorWindowForTesting.parent === controller.toolbarWindowForTesting))"
        )

        annotationController.currentTool = .rectangle
        controller.updateState(
            DrawingToolbarState(annotationController: annotationController)
        )
        let rectangleSnapshots = controller.captureAccessorySnapshots(
            scaleX: 2,
            scaleY: 2
        )
        try expect(
            rectangleSnapshots.count == 2
                && rectangleSnapshots[0].globalFrame
                    == controller.toolbarFrameForTesting
                && rectangleSnapshots[1].globalFrame.contains(
                    controller.inspectorFrameForTesting
                )
                && controller.inspectorWindowForTesting.parent
                    === controller.toolbarWindowForTesting,
            "Expected ordered toolbar then inspector snapshots only while both "
                + "stable controls are truly shown"
        )

        annotationController.currentTool = .eraser
        controller.updateState(
            DrawingToolbarState(annotationController: annotationController)
        )
        let staleInspectorFrame = controller.inspectorFrameForTesting
        try expect(
            staleInspectorFrame.width > 0
                && controller.captureAccessorySnapshots(
                    scaleX: 1,
                    scaleY: 1
                ).count == 1,
            "Expected a hidden propertyless inspector to stay excluded despite "
                + "its stale nonzero frame"
        )

        controller.hide()
        try expect(
            controller.captureAccessorySnapshots(
                scaleX: 1,
                scaleY: 1
            ).isEmpty,
            "Expected suppressed or hidden stable controls to produce no snapshots"
        )
    }

    static func testZoomCanvasAccessoryCaptureIntegration() throws {
        let displayFrame = CGRect(x: -120, y: 450, width: 40, height: 30)
        let baseImage = try makeSolidImage(
            width: 80,
            height: 60,
            color: NSColor(
                calibratedRed: 0.1,
                green: 0.35,
                blue: 0.15,
                alpha: 1
            )
        )
        let accessoryImage = try makeSolidImage(
            width: 16,
            height: 12,
            color: .magenta
        )
        let capturedFrame = CapturedFrame(
            image: baseImage,
            display: DisplayDescriptor(
                id: 77,
                frame: displayFrame,
                scaleFactor: 2
            ),
            pixelSize: CGSize(width: 80, height: 60),
            timestamp: Date(timeIntervalSince1970: 0)
        )
        let viewportController = ZoomViewportController()
        viewportController.configure(for: capturedFrame, initialZoom: 1)
        var controlsVisible = true
        let accessoryFrame = CGRect(
            x: displayFrame.minX + 4,
            y: displayFrame.maxY - 3 - 6,
            width: 8,
            height: 6
        )
        let canvas = ZoomCanvasView(
            frame: CGRect(origin: .zero, size: displayFrame.size),
            capturedFrame: capturedFrame,
            viewportController: viewportController,
            annotationController: AnnotationController(),
            smoothImage: true,
            userSelectedResourceAccess:
                UserDefaultsUserSelectedResourceAccess(),
            commandSink: { _ in },
            captureCompositor: {
                baseImage,
                displayFrame,
                sourceRegion,
                outputPixelSize in
                CaptureAccessoryCompositor.compose(
                    baseImage: baseImage,
                    displayFrame: displayFrame,
                    sourceRegion: sourceRegion,
                    outputPixelSize: outputPixelSize,
                    accessories: controlsVisible
                        ? [
                            CaptureAccessorySnapshot(
                                globalFrame: accessoryFrame,
                                image: accessoryImage
                            )
                        ]
                        : []
                )
            }
        )

        func containsMagenta(_ image: CGImage) -> Bool {
            let representation = NSBitmapImageRep(cgImage: image)
            for y in 0..<representation.pixelsHigh {
                for x in 0..<representation.pixelsWide {
                    guard let color = representation.colorAt(x: x, y: y)?
                        .usingColorSpace(.sRGB) else {
                        continue
                    }
                    if color.redComponent > 0.8
                        && color.blueComponent > 0.8
                        && color.greenComponent < 0.2 {
                        return true
                    }
                }
            }
            return false
        }

        guard let wholeStill = canvas.captureImageForTesting(
            policy: .stillImage,
            sourceRect: nil,
            outputPixelSize: nil
        ), let fullRecording = canvas.captureImageForTesting(
            policy: .recording,
            sourceRect: nil,
            outputPixelSize: CGSize(width: 83, height: 61)
        ), let regionRecording = canvas.captureImageForTesting(
            policy: .recording,
            sourceRect: CGRect(x: 2, y: 1, width: 12, height: 10),
            outputPixelSize: CGSize(width: 25, height: 21)
        ), let regionWithoutControls = canvas.captureImageForTesting(
            policy: .recording,
            sourceRect: CGRect(x: 20, y: 15, width: 10, height: 10),
            outputPixelSize: CGSize(width: 23, height: 19)
        ) else {
            throw SelfTestError.failure(
                "Could not render integrated canvas capture paths"
            )
        }
        try expect(
            containsMagenta(wholeStill)
                && fullRecording.width == 83
                && fullRecording.height == 61
                && containsMagenta(fullRecording)
                && regionRecording.width == 25
                && regionRecording.height == 21
                && containsMagenta(regionRecording)
                && regionWithoutControls.width == 23
                && regionWithoutControls.height == 19
                && !containsMagenta(regionWithoutControls),
            "Expected whole Copy/Save and exact full/region recording outputs "
                + "to include only intersecting visible stable controls"
        )

        controlsVisible = false
        guard let suppressedSnip = canvas.captureImageForTesting(
            policy: .stillImage,
            sourceRect: CGRect(x: 2, y: 1, width: 12, height: 10),
            outputPixelSize: CGSize(width: 24, height: 20)
        ) else {
            throw SelfTestError.failure(
                "Could not render suppressed in-overlay snip capture"
            )
        }
        try expect(
            !containsMagenta(suppressedSnip),
            "Expected region-selection suppression to omit stable controls from "
                + "the final snip"
        )
    }

    static func testCaptureFeedbackAndRecordingDimensionPolicies() throws {
        try expect(
            OverlayWindowSharingPolicy.sharingType(
                for: .standardWindow
            ) == .readWrite
                && OverlayWindowSharingPolicy.sharingType(
                    for: .staticOverlay
                ) == .readOnly
                && OverlayWindowSharingPolicy.sharingType(
                    for: .liveOverlay
                ) == .readOnly
                && OverlayWindowSharingPolicy.isVisibleToExternalCapture(
                    context: .standardWindow
                )
                && OverlayWindowSharingPolicy.isVisibleToExternalCapture(
                    context: .staticOverlay
                )
                && OverlayWindowSharingPolicy.isVisibleToExternalCapture(
                    context: .liveOverlay
                )
                && LiveCaptureFeedbackPolicy.excludesApplication(
                processID: 42,
                ownProcessID: 42
            )
                && !LiveCaptureFeedbackPolicy.excludesApplication(
                    processID: 41,
                    ownProcessID: 42
                )
                && RecordingFrameReplacementPolicy.source(
                    hasOverlaySnapshot: true
                ) == .overlaySnapshot
                && RecordingFrameReplacementPolicy.source(
                    hasOverlaySnapshot: false
                ) == .screenStream,
            "Expected standard, static, and live windows to remain externally "
                + "capturable, live capture to exclude the whole ZoomIt process, "
                + "and recording to choose exactly one frame source"
        )

        let display = DisplayDescriptor(
            id: 12,
            frame: CGRect(x: -400, y: 900, width: 100, height: 80),
            scaleFactor: 2
        )
        try expect(
            RecordingController.outputPixelSize(
                display: display,
                sourceRect: nil
            ) == CGSize(width: 200, height: 160)
                && RecordingController.outputPixelSize(
                    display: display,
                    sourceRect: CGRect(
                        x: 3.25,
                        y: 4.5,
                        width: 12.75,
                        height: 9.25
                    )
                ) == CGSize(width: 25, height: 18),
            "Expected recording output dimensions to match ScreenCaptureKit's "
                + "full and fractional region pixel sizes exactly"
        )
    }
}
