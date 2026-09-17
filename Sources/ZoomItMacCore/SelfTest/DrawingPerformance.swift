import AppKit

extension SelfTestRunner {
    public static func testDrawingInteractionPerformance() throws {
        guard let session = CGSessionCopyCurrentDictionary() as? [String: Any],
              session[kCGSessionOnConsoleKey as String] as? Bool == true,
              session["CGSSessionScreenIsLocked"] as? Bool != true else {
            throw SelfTestError.failure(
                "Drawing interaction tests require an unlocked, active macOS desktop session"
            )
        }
        try testInspectorUpdatesDuringMovement()
        try testIncrementalPenRepaint()
        try testFreehandDisplayLinkContinuity()
    }

    private static func testInspectorUpdatesDuringMovement() throws {
        var style = AnnotationStyle.default
        style.fillStyle = .solid
        let element = AnnotationElement.legacy(
            tool: .rectangle,
            points: [CGPoint(x: 20, y: 20), CGPoint(x: 100, y: 80)],
            style: style
        )
        let controller = AnnotationController(elements: [element])
        controller.currentTool = .select
        controller.selectAll()
        let inspector = DrawingPropertiesController(
            commandSink: { _ in }, colorPanelActivityChanged: { _ in }
        )
        inspector.update(state: DrawingToolbarState(annotationController: controller))
        _ = inspector.view
        let rows = inspector.view.subviews.map(ObjectIdentifier.init)
        let oldState = DrawingToolbarState(annotationController: controller)
        _ = controller.beginSelectionInteraction(
            at: CGPoint(x: 60, y: 50), zoomScale: 1, modifiers: [], clickCount: 1
        )
        for index in 1...60 {
            controller.updateSelectionInteraction(
                to: CGPoint(x: 60 + CGFloat(index), y: 50), modifiers: []
            )
            let state = DrawingToolbarState(annotationController: controller)
            try expect(state == oldState, "Position-only dragging must not change inspector state")
            inspector.update(state: state)
            try expect(
                inspector.view.subviews.map(ObjectIdentifier.init) == rows,
                "Dragging must not rebuild or reparent inspector rows"
            )
        }
        controller.endSelectionInteraction(at: CGPoint(x: 120, y: 50), modifiers: [])
        controller.setStrokeColor(.palette(.blue))
        let newState = DrawingToolbarState(annotationController: controller)
        try expect(newState != oldState, "A color edit must still refresh inspector controls")
        inspector.update(state: newState)
        try expect(
            inspector.view.subviews.map(ObjectIdentifier.init) == rows,
            "A color edit must not rebuild the unchanged layout"
        )
        controller.setFillStyle(.none)
        inspector.update(state: DrawingToolbarState(annotationController: controller))
        try expect(
            inspector.view.subviews.map(ObjectIdentifier.init) != rows,
            "Removing Fill must still reflow the changed section list"
        )
    }

    private static func testIncrementalPenRepaint() throws {
        func bitmap(scale: Int) throws -> CGContext {
            guard let context = CGContext(
                data: nil, width: 800 * scale, height: 400 * scale,
                bitsPerComponent: 8, bytesPerRow: 0,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else { throw SelfTestError.failure("Could not create dirty-repaint bitmap") }
            context.scaleBy(x: CGFloat(scale), y: CGFloat(scale))
            return context
        }
        let sceneBounds = CGRect(x: 0, y: 0, width: 800, height: 400)
        var backgroundStyle = AnnotationStyle.default
        backgroundStyle.fillColor = .palette(.blue)
        backgroundStyle.fillStyle = .solid
        let background = AnnotationElement.legacy(
            tool: .rectangle, points: [.zero, CGPoint(x: 800, y: 400)], style: backgroundStyle
        )
        for scale in [1, 2] {
            for tool: AnnotationTool in [.pen, .highlighter] {
                for sloppiness in AnnotationSloppiness.allCases {
                    let controller = AnnotationController(elements: [background])
                    controller.currentTool = tool
                    var style = controller.currentStyle
                    style.opacity = 0.5
                    style.sloppiness = sloppiness
                    if tool == .pen { style.pressureMode = .tablet }
                    controller.currentStyle = style
                    controller.begin(at: CGPoint(x: 30, y: 160), pressure: 0.6, timestamp: 0, zoomScale: 1)
                    for index in 1...800 {
                        controller.update(
                            at: CGPoint(x: 30 + CGFloat(index) * 0.65, y: 160 + sin(CGFloat(index) * 0.015) * 80),
                            pressure: 0.6, timestamp: Double(index) / 240
                        )
                    }
                    let incremental = try bitmap(scale: scale)
                    controller.render(in: incremental, bounds: sceneBounds, destinationPointScale: 1)
                    // Includes replacing a short trailing preview, crossing chunk
                    // boundaries, and revisiting older ink at a different alpha.
                    for index in 801...850 {
                        let oldBounds = controller.activeFreehandTailBounds(zoomScale: 1)
                        controller.update(
                            at: CGPoint(x: 550 + CGFloat(index - 801) * 0.3, y: 120 + CGFloat(index - 801)),
                            pressure: 0.4, timestamp: Double(index) / 240
                        )
                        let dirty = oldBounds.union(controller.activeFreehandTailBounds(zoomScale: 1))
                            .integral.intersection(sceneBounds)
                        incremental.saveGState()
                        incremental.clip(to: dirty)
                        incremental.clear(dirty)
                        controller.render(in: incremental, bounds: sceneBounds, destinationPointScale: 1)
                        incremental.restoreGState()
                    }
                    let full = try bitmap(scale: scale)
                    controller.render(in: full, bounds: sceneBounds, destinationPointScale: 1)
                    guard let actual = incremental.data, let expected = full.data else {
                        throw SelfTestError.failure("Missing dirty-repaint pixels")
                    }
                    let bytes = full.bytesPerRow * full.height
                    let lhs = actual.assumingMemoryBound(to: UInt8.self)
                    let rhs = expected.assumingMemoryBound(to: UInt8.self)
                    var maximumDifference = 0
                    for index in 0..<bytes {
                        maximumDifference = max(maximumDifference, abs(Int(lhs[index]) - Int(rhs[index])))
                    }
                    try expect(
                        maximumDifference <= 2,
                        "Incremental \(tool)/\(sloppiness) repaint must match full rendering at \(scale)x (delta \(maximumDifference))"
                    )
                }
            }
        }

        let renderer = AnnotationRenderer()
        let context = try bitmap(scale: 1)
        let points = (0..<4096).map { CGPoint(x: CGFloat($0) * 0.17, y: 200) }
        let element = AnnotationElement.legacy(tool: .highlighter, points: points, style: .default)
        renderer.render(elements: [], activeElement: element, destinationPointScale: 1, in: context)
        let before = renderer.activeStrokeCacheCountersForTesting
        context.saveGState()
        context.clip(to: CGRect(x: 670, y: 180, width: 30, height: 40))
        renderer.render(elements: [], activeElement: element, destinationPointScale: 1, in: context)
        context.restoreGState()
        let after = renderer.activeStrokeCacheCountersForTesting
        try expect(after.rebuiltChunks == before.rebuiltChunks, "An unchanged clipped stroke must reuse geometry")
        try expect(
            (1...4).contains(after.drawnChunks - before.drawnChunks),
            "Clipped rendering must submit only the visible tail chunks, including horizontal paths"
        )
    }

    private static func testFreehandDisplayLinkContinuity() throws {
        guard let context = CGContext(
            data: nil, width: 640, height: 480, bitsPerComponent: 8,
            bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ), let image = context.makeImage() else {
            throw SelfTestError.failure("Could not allocate frame")
        }
        let frame = CapturedFrame(
            image: image,
            display: DisplayDescriptor(id: 1, frame: CGRect(x: 0, y: 0, width: 640, height: 480), scaleFactor: 1),
            pixelSize: CGSize(width: 640, height: 480),
            timestamp: Date(timeIntervalSince1970: 0)
        )
        let viewport = ZoomViewportController()
        viewport.configure(for: frame, initialZoom: 1)
        let controller = AnnotationController()
        let canvas = ZoomCanvasView(
            frame: frame.display.frame, capturedFrame: frame,
            viewportController: viewport, annotationController: controller, smoothImage: false,
            userSelectedResourceAccess: UserDefaultsUserSelectedResourceAccess(), commandSink: { _ in }
        )
        let host = NSWindow(contentRect: frame.display.frame, styleMask: .borderless, backing: .buffered, defer: false)
        host.isReleasedWhenClosed = false
        host.contentView = canvas
        host.orderFront(nil)
        defer { canvas.prepareForClose(); host.close() }
        canvas.interactionMode = .drawOnly
        func event(_ type: NSEvent.EventType, _ x: CGFloat, _ time: TimeInterval) throws -> NSEvent {
            guard let event = NSEvent.mouseEvent(
                with: type, location: CGPoint(x: x, y: 300), modifierFlags: [],
                timestamp: time, windowNumber: host.windowNumber,
                context: nil, eventNumber: 0, clickCount: 1, pressure: 0
            ) else { throw SelfTestError.failure("Could not create pointer event") }
            return event
        }
        canvas.mouseDown(with: try event(.leftMouseDown, 30, 1))
        canvas.mouseDragged(with: try event(.leftMouseDragged, 40, 1.01))
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while controller.hasPendingFreehandInput && ContinuousClock.now < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.01))
        }
        try expect(
            !controller.hasPendingFreehandInput,
            "Display link must drain queued input (visible: \(host.isVisible), "
                + "occlusion: \(host.occlusionState.rawValue), "
                + "clock: \(canvas.hasActiveFreehandDrainTimerForTesting))"
        )
        try expect(
            canvas.hasActiveFreehandDrainTimerForTesting,
            "Briefly empty input must not restart the frame clock in the middle of a stroke"
        )
        canvas.mouseUp(with: try event(.leftMouseUp, 45, 1.02))
        try expect(
            !canvas.hasActiveFreehandDrainTimerForTesting && controller.inProgressElementSnapshot == nil,
            "Mouse-up must still stop the frame clock and commit the exact endpoint"
        )
    }

    /// Opt-in wall-clock diagnostics; correctness tests must not depend on timing.
    public static func benchmarkDrawing() {
        func measure(_ label: String, iterations: Int = 120, _ operation: (Int) -> Void) {
            for index in 0..<3 { operation(index) }
            var milliseconds: [Double] = []
            for index in 0..<iterations {
                let start = DispatchTime.now().uptimeNanoseconds
                operation(index + 3)
                milliseconds.append(Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000)
            }
            milliseconds.sort()
            print(String(
                format: "%@: mean %.3f ms, p95 %.3f ms",
                label,
                milliseconds.reduce(0, +) / Double(milliseconds.count),
                milliseconds[Int(Double(milliseconds.count - 1) * 0.95)]
            ))
        }

        let elements = (0..<100).map { index in
            var style = AnnotationStyle.default
            style.fillStyle = .solid
            let x = CGFloat(index % 10) * 65 + 20
            let y = CGFloat(index / 10) * 50 + 20
            return AnnotationElement.legacy(
                tool: .rectangle,
                points: [CGPoint(x: x, y: y), CGPoint(x: x + 40, y: y + 30)],
                style: style
            )
        }
        let controller = AnnotationController(elements: elements)
        controller.currentTool = .select
        _ = controller.beginSelectionInteraction(
            at: CGPoint(x: 40, y: 35), zoomScale: 1, modifiers: [], clickCount: 1
        )
        measure("Move one shape in a 100-shape scene, without inspector") { index in
            controller.updateSelectionInteraction(
                to: CGPoint(x: 40 + CGFloat(index) * 0.1, y: 35),
                modifiers: []
            )
        }
        controller.endSelectionInteraction(at: CGPoint(x: 55, y: 35), modifiers: [])

        let host = NSWindow(
            contentRect: CGRect(x: 0, y: 0, width: 1024, height: 768),
            styleMask: .borderless, backing: .buffered, defer: false
        )
        host.isReleasedWhenClosed = false
        let toolbar = DrawingToolbarController(
            parentWindow: host,
            annotationController: controller,
            toolbarNormalizedPosition: nil,
            commandSink: { _ in },
            restoreCanvasFocus: {},
            toolbarPlacementDidChange: { _ in },
            pointerInteractionChanged: { _ in }
        )
        defer { toolbar.close(); host.close() }
        toolbar.show()
        controller.onStateChanged = {
            toolbar.updateState(DrawingToolbarState(annotationController: controller))
        }
        _ = controller.beginSelectionInteraction(
            at: CGPoint(x: 55, y: 35), zoomScale: 1, modifiers: [], clickCount: 1
        )
        measure("Move one shape in a 100-shape scene, with inspector") { index in
            controller.updateSelectionInteraction(
                to: CGPoint(x: 55 + CGFloat(index) * 0.1, y: 35),
                modifiers: []
            )
        }
        controller.endSelectionInteraction(at: CGPoint(x: 70, y: 35), modifiers: [])

        guard let context = CGContext(
            data: nil, width: 1024, height: 768, bitsPerComponent: 8,
            bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            print("Could not allocate drawing benchmark bitmap.")
            return
        }
        let pen = AnnotationController()
        pen.begin(at: CGPoint(x: 10, y: 300), pressure: nil, timestamp: 0, zoomScale: 1)
        for index in 1...4000 {
            pen.update(
                at: CGPoint(x: CGFloat(index) * 0.12 + 10, y: 300 + sin(CGFloat(index) * 0.03) * 80),
                timestamp: Double(index) / 240,
                zoomScale: 1
            )
        }
        measure("Append and render a long Pen stroke") { index in
            pen.update(
                at: CGPoint(x: 490 + CGFloat(index) * 0.4, y: 300 + sin(CGFloat(index) * 0.03) * 80),
                timestamp: Double(index + 4001) / 240, zoomScale: 1
            )
            context.clear(CGRect(x: 0, y: 0, width: 1024, height: 768))
            pen.render(in: context, bounds: CGRect(x: 0, y: 0, width: 1024, height: 768))
        }
        measure("Append and render only the changed Pen tail") { index in
            let oldBounds = pen.activeFreehandTailBounds(zoomScale: 1)
            pen.update(
                at: CGPoint(x: 545 + CGFloat(index) * 0.4, y: 300 + sin(CGFloat(index) * 0.03) * 80),
                timestamp: Double(index + 4200) / 240, zoomScale: 1
            )
            let dirtyBounds = oldBounds.union(pen.activeFreehandTailBounds(zoomScale: 1))
            context.saveGState()
            context.clip(to: dirtyBounds)
            context.clear(dirtyBounds)
            pen.render(in: context, bounds: CGRect(x: 0, y: 0, width: 1024, height: 768))
            context.restoreGState()
        }
    }
}
