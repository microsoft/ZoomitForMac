import AppKit

extension SelfTestRunner {
    static func testActiveGestureExitLifecycle() throws {
        let creationTools: [AnnotationTool] = [
            .pen,
            .highlighter,
            .rectangle,
            .diamond,
            .ellipse,
            .line,
            .arrow
        ]
        for tool in creationTools {
            let controller = AnnotationController()
            controller.currentTool = tool
            controller.begin(
                at: CGPoint(x: 10, y: 10),
                tool: tool,
                timestamp: 0,
                zoomScale: 1
            )
            controller.update(
                at: CGPoint(x: 70, y: 50),
                timestamp: 0.1,
                zoomScale: 1
            )
            try expect(
                controller.resolveActiveGestureForExit(zoomScale: 1),
                "Expected exit to commit a visible \(tool) gesture"
            )
            try expect(
                controller.elementSnapshot.count == 1
                    && controller.inProgressElementSnapshot == nil
                    && !controller.isConstructingLinearPath
                    && controller.editorStateKind == .idle
                    && !controller.hasActiveDrawingGesture,
                "Expected \(tool) exit to clear every transient creation state"
            )
            controller.undo()
            try expect(
                controller.elementSnapshot.isEmpty && !controller.canUndo,
                "Expected one undo to remove the complete exited \(tool) gesture"
            )
            controller.redo()
            try expect(
                controller.elementSnapshot.count == 1,
                "Expected redo to restore the complete exited \(tool) gesture"
            )
        }

        for tool in [AnnotationTool.rectangle, .diamond, .ellipse, .line, .arrow] {
            let controller = AnnotationController()
            controller.currentTool = tool
            controller.begin(at: CGPoint(x: 20, y: 20), tool: tool)
            try expect(
                !controller.resolveActiveGestureForExit(zoomScale: 1)
                    && controller.elementSnapshot.isEmpty
                    && controller.inProgressElementSnapshot == nil
                    && controller.editorStateKind == .idle
                    && !controller.canUndo,
                "Expected exit to cancel a degenerate \(tool) gesture without history"
            )
        }

        let constructedController = AnnotationController()
        constructedController.currentTool = .line
        constructedController.begin(at: .zero, tool: .line)
        constructedController.beginLinearConstructionFromClick(
            at: .zero,
            zoomScale: 1
        )
        _ = constructedController.commitLinearConstructionPoint(
            at: CGPoint(x: 60, y: 20),
            zoomScale: 1
        )
        try expect(
            constructedController.resolveActiveGestureForExit(zoomScale: 1)
                && constructedController.elementSnapshot.count == 1
                && !constructedController.isConstructingLinearPath
                && constructedController.editorStateKind == .idle,
            "Expected exit to finalize a valid multi-click linear construction"
        )

        let degenerateConstructionController = AnnotationController()
        degenerateConstructionController.currentTool = .arrow
        degenerateConstructionController.begin(at: .zero, tool: .arrow)
        degenerateConstructionController.beginLinearConstructionFromClick(
            at: .zero,
            zoomScale: 1
        )
        try expect(
            !degenerateConstructionController.resolveActiveGestureForExit(
                zoomScale: 1
            )
                && degenerateConstructionController.elementSnapshot.isEmpty
                && !degenerateConstructionController.isConstructingLinearPath
                && degenerateConstructionController.editorStateKind == .idle,
            "Expected exit to cancel a one-anchor linear construction"
        )

        let eraserController = AnnotationController()
        eraserController.currentTool = .rectangle
        eraserController.begin(at: CGPoint(x: 10, y: 10))
        eraserController.end(at: CGPoint(x: 70, y: 70))
        eraserController.beginErasing(
            at: CGPoint(x: 10, y: 40),
            zoomScale: 1
        )
        eraserController.resolveActiveGestureForExit(zoomScale: 1)
        try expect(
            eraserController.elementSnapshot.count == 1
                && eraserController.pendingErasureElementIDsForTesting.isEmpty
                && eraserController.editorStateKind == .idle
                && !eraserController.hasActiveDrawingGesture,
            "Expected exit to cancel staged erasure without deleting content"
        )
        eraserController.undo()
        try expect(
            eraserController.elementSnapshot.isEmpty,
            "Expected eraser exit to add no history beyond the original annotation"
        )

        let selectionController = AnnotationController()
        selectionController.currentTool = .rectangle
        selectionController.begin(at: CGPoint(x: 10, y: 10))
        selectionController.end(at: CGPoint(x: 70, y: 70))
        let originalElement = selectionController.elementSnapshot[0]
        selectionController.currentTool = .select
        _ = selectionController.beginSelectionInteraction(
            at: CGPoint(x: 10, y: 40),
            zoomScale: 1,
            modifiers: [],
            clickCount: 1
        )
        selectionController.updateSelectionInteraction(
            to: CGPoint(x: 35, y: 40),
            modifiers: []
        )
        selectionController.resolveActiveGestureForExit(zoomScale: 1)
        try expect(
            selectionController.elementSnapshot[0] == originalElement
                && selectionController.editorStateKind == .idle
                && !selectionController.hasActiveDrawingGesture,
            "Expected exit to cancel an active editor drag and restore its transaction"
        )

        func makeActiveCanvas(
            tool: AnnotationTool
        ) throws -> (AnnotationController, ZoomCanvasView) {
            let controller = AnnotationController()
            let canvas = try makeCanvas(annotationController: controller)
            canvas.interactionMode = .drawOnly
            controller.currentTool = tool
            controller.begin(
                at: CGPoint(x: 12, y: 16),
                tool: tool,
                timestamp: 0,
                zoomScale: 1
            )
            controller.update(
                at: CGPoint(x: 84, y: 58),
                timestamp: 0.1,
                zoomScale: 1
            )
            return (controller, canvas)
        }

        let (toggleController, toggleCanvas) = try makeActiveCanvas(tool: .pen)
        toggleCanvas.toggleDrawingMode()
        try expect(
            toggleController.elementSnapshot.count == 1
                && !toggleController.hasActiveDrawingGesture,
            "Expected the external drawing toggle to resolve an active pen"
        )
        toggleCanvas.prepareForClose()

        let (typingController, typingCanvas) = try makeActiveCanvas(
            tool: .highlighter
        )
        typingCanvas.interactionMode = .typing
        try expect(
            typingController.elementSnapshot.count == 1
                && !typingController.hasActiveDrawingGesture,
            "Expected typing entry to resolve an active highlighter"
        )
        typingCanvas.prepareForClose()

        let escapeController = AnnotationController()
        let escapeCanvas = try makeCanvas(annotationController: escapeController)
        escapeCanvas.interactionMode = .liveZoom
        escapeCanvas.toggleDrawingMode()
        escapeController.currentTool = .rectangle
        escapeController.begin(
            at: CGPoint(x: 12, y: 16),
            tool: .rectangle,
            timestamp: 0,
            zoomScale: 1
        )
        escapeController.update(
            at: CGPoint(x: 84, y: 58),
            timestamp: 0.1,
            zoomScale: 1
        )
        guard let escape = NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: [],
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            characters: "\u{1b}",
            charactersIgnoringModifiers: "\u{1b}",
            isARepeat: false,
            keyCode: 53
        ) else {
            throw SelfTestError.failure("Could not create an active-gesture Escape event")
        }
        escapeCanvas.keyDown(with: escape)
        try expect(
            escapeController.elementSnapshot.count == 1
                && !escapeController.hasActiveDrawingGesture,
            "Expected Escape to resolve an active shape before leaving drawing"
        )
        escapeCanvas.prepareForClose()

        let (rightClickController, rightClickCanvas) = try makeActiveCanvas(
            tool: .line
        )
        guard let rightClick = NSEvent.mouseEvent(
            with: .rightMouseDown,
            location: CGPoint(x: 84, y: 58),
            modifierFlags: [],
            timestamp: 0.2,
            windowNumber: 0,
            context: nil,
            eventNumber: 1,
            clickCount: 1,
            pressure: 0
        ) else {
            throw SelfTestError.failure("Could not create an active-gesture right click")
        }
        rightClickCanvas.rightMouseDown(with: rightClick)
        try expect(
            rightClickController.elementSnapshot.count == 1
                && !rightClickController.hasActiveDrawingGesture,
            "Expected right click to resolve an active dragged line"
        )
        rightClickCanvas.prepareForClose()

        let (closeController, closeCanvas) = try makeActiveCanvas(tool: .ellipse)
        closeCanvas.prepareForClose()
        try expect(
            closeController.elementSnapshot.count == 1
                && !closeController.hasActiveDrawingGesture,
            "Expected overlay close to resolve an active shape"
        )
    }
}
