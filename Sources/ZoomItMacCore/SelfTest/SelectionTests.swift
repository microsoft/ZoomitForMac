import AppKit

extension SelfTestRunner {
    static func testAnnotationEditorSelectionAndMarquee() throws {
        var style = AnnotationStyle.default
        style.fillStyle = .solid
        let scene = AnnotationScene()
        let back = AnnotationElement(
            geometry: .shape(
                AnnotationShapeGeometry(
                    kind: .rectangle,
                    start: CGPoint(x: 0, y: 0),
                    end: CGPoint(x: 40, y: 40)
                )
            ),
            style: style
        )
        let front = AnnotationElement(
            geometry: .shape(
                AnnotationShapeGeometry(
                    kind: .ellipse,
                    start: CGPoint(x: 10, y: 10),
                    end: CGPoint(x: 50, y: 50)
                )
            ),
            style: style
        )
        scene.append(back)
        scene.append(front)
        let editor = AnnotationEditor(scene: scene)
        let overlap = CGPoint(x: 20, y: 20)

        _ = editor.beginInteraction(
            at: overlap,
            zoomScale: 1,
            modifiers: [],
            clickCount: 1
        )
        editor.endInteraction(at: overlap, modifiers: [])
        try expect(
            editor.selectedElementIDs == [front.id],
            "Expected click selection to choose the topmost overlapping element"
        )

        _ = editor.beginInteraction(
            at: CGPoint(x: 2, y: 2),
            zoomScale: 1,
            modifiers: [.shift],
            clickCount: 1
        )
        editor.endInteraction(at: CGPoint(x: 2, y: 2), modifiers: [.shift])
        try expect(
            editor.selectedElementIDs == [back.id, front.id],
            "Expected Shift-click to add an element to the selection"
        )

        _ = editor.beginInteraction(
            at: overlap,
            zoomScale: 1,
            modifiers: [.command],
            clickCount: 1
        )
        editor.endInteraction(at: overlap, modifiers: [.command])
        try expect(
            editor.selectedElementIDs == [back.id],
            "Expected Command-click to toggle the clicked element"
        )

        _ = editor.beginInteraction(
            at: CGPoint(x: -30, y: -30),
            zoomScale: 1,
            modifiers: [],
            clickCount: 1
        )
        try expect(
            editor.stateKind == .marqueeSelecting,
            "Expected empty-space dragging to enter marquee selection"
        )
        editor.updateInteraction(to: CGPoint(x: 60, y: 60), modifiers: [])
        try expect(
            editor.selectedElementIDs == [back.id, front.id],
            "Expected marquee selection to include intersecting visible elements"
        )
        editor.endInteraction(at: CGPoint(x: 60, y: 60), modifiers: [])
        try expect(editor.stateKind == .idle, "Expected marquee mouse-up to return to idle")
    }

    static func testSelectArrowKeyFallthrough() throws {
        try expect(
            ZoomCanvasView.selectionNudge(
                keyCode: 126,
                shift: false,
                hasMovableSelection: false
            ) == nil,
            "Expected Select-mode Up to fall through to zoom when nothing can move"
        )
        try expect(
            ZoomCanvasView.selectionNudge(
                keyCode: 125,
                shift: true,
                hasMovableSelection: true
            ) == CGPoint(x: 0, y: 10),
            "Expected a movable selection to retain Shift-arrow ten-point nudging"
        )

        let scene = AnnotationScene()
        var locked = AnnotationElement.legacy(
            tool: .rectangle,
            points: [.zero, CGPoint(x: 20, y: 20)],
            style: .default
        )
        locked.metadata.isLocked = true
        scene.append(locked)
        scene.select([locked.id])
        let editor = AnnotationEditor(scene: scene)
        try expect(
            !editor.hasMovableSelection,
            "Expected a locked-only selection not to consume Select-mode arrow keys"
        )
    }

    static func testAnnotationEditorTransformTransactionsAndLocking() throws {
        var style = AnnotationStyle.default
        style.fillStyle = .solid
        let scene = AnnotationScene()
        let shape = AnnotationElement(
            geometry: .shape(
                AnnotationShapeGeometry(
                    kind: .rectangle,
                    start: CGPoint(x: 10, y: 10),
                    end: CGPoint(x: 50, y: 40)
                )
            ),
            style: style
        )
        scene.append(shape)
        let editor = AnnotationEditor(scene: scene)
        scene.select([shape.id])

        let beforeMove = scene.snapshot
        _ = editor.beginInteraction(
            at: CGPoint(x: 20, y: 20),
            zoomScale: 1,
            modifiers: [],
            clickCount: 1
        )
        try expect(editor.stateKind == .moving, "Expected selected body drag to enter moving")
        editor.updateInteraction(to: CGPoint(x: 25, y: 30), modifiers: [])
        editor.updateInteraction(to: CGPoint(x: 40, y: 50), modifiers: [])
        editor.endInteraction(at: CGPoint(x: 40, y: 50), modifiers: [])
        guard case .shape(let movedShape) = scene.element(withID: shape.id)?.geometry else {
            throw SelfTestError.failure("Expected moved shape geometry")
        }
        try expect(
            movedShape.start == CGPoint(x: 30, y: 40)
                && movedShape.end == CGPoint(x: 70, y: 70),
            "Expected move drag to apply the final total delta"
        )
        try expect(scene.undo(), "Expected move drag to be undoable")
        try expect(
            scene.snapshot == beforeMove,
            "Expected one undo to revert every update in a move drag"
        )
        try expect(scene.redo(), "Expected move drag redo")

        guard let movedElement = scene.element(withID: shape.id),
              let resizeHandle = AnnotationGeometry.selectionDecoration(
                  for: movedElement,
                  zoomScale: 1
              )?.handles.first(where: { $0.kind == .bottomTrailing }) else {
            throw SelfTestError.failure("Expected a resize handle")
        }
        let beforeResize = scene.snapshot
        _ = editor.beginInteraction(
            at: resizeHandle.center,
            zoomScale: 1,
            modifiers: [],
            clickCount: 1
        )
        try expect(editor.stateKind == .resizing, "Expected handle drag to enter resizing")
        editor.updateInteraction(
            to: CGPoint(x: resizeHandle.center.x + 10, y: resizeHandle.center.y + 5),
            modifiers: []
        )
        editor.updateInteraction(
            to: CGPoint(x: resizeHandle.center.x + 20, y: resizeHandle.center.y + 15),
            modifiers: []
        )
        editor.endInteraction(
            at: CGPoint(x: resizeHandle.center.x + 20, y: resizeHandle.center.y + 15),
            modifiers: []
        )
        guard let resizedElement = scene.element(withID: shape.id) else {
            throw SelfTestError.failure("Expected resized element")
        }
        try expect(
            AnnotationGeometry.localBounds(of: resizedElement).width
                > AnnotationGeometry.localBounds(of: movedElement).width,
            "Expected resize drag to enlarge the selected shape"
        )
        try expect(scene.undo(), "Expected resize drag to be undoable")
        try expect(
            scene.snapshot == beforeResize,
            "Expected one undo to revert every update in a resize drag"
        )

        guard let rotationElement = scene.element(withID: shape.id),
              let rotationHandle = AnnotationGeometry.selectionDecoration(
                  for: rotationElement,
                  zoomScale: 1
              )?.handles.first(where: { $0.kind == .rotation }) else {
            throw SelfTestError.failure("Expected a rotation handle")
        }
        let rotationBounds = AnnotationGeometry.worldBounds(
            of: rotationElement,
            includingStroke: false
        )
        let beforeRotate = scene.snapshot
        _ = editor.beginInteraction(
            at: rotationHandle.center,
            zoomScale: 1,
            modifiers: [],
            clickCount: 1
        )
        try expect(editor.stateKind == .rotating, "Expected rotation handle drag to enter rotating")
        editor.endInteraction(
            at: CGPoint(x: rotationBounds.maxX + 30, y: rotationBounds.midY),
            modifiers: [.shift]
        )
        try expect(
            scene.element(withID: shape.id)?.metadata.rotation != 0,
            "Expected rotation drag to update element rotation"
        )
        try expect(scene.undo(), "Expected rotation drag to be undoable")
        try expect(
            scene.snapshot == beforeRotate,
            "Expected one undo to revert the complete rotation drag"
        )

        let beforeOptionDuplicate = scene.snapshot
        _ = editor.beginInteraction(
            at: CGPoint(x: 40, y: 50),
            zoomScale: 1,
            modifiers: [.option],
            clickCount: 1
        )
        editor.updateInteraction(to: CGPoint(x: 45, y: 55), modifiers: [.option])
        editor.endInteraction(at: CGPoint(x: 60, y: 70), modifiers: [.option])
        try expect(
            scene.elements.count == 2
                && editor.selectedElementIDs.count == 1
                && !editor.selectedElementIDs.contains(shape.id),
            "Expected Option-drag to duplicate and select the moved copy"
        )
        try expect(scene.undo(), "Expected Option-drag duplication to be undoable")
        try expect(
            scene.snapshot == beforeOptionDuplicate,
            "Expected one undo to remove the duplicate and its complete drag"
        )

        scene.select([shape.id])
        editor.toggleSelectionLock()
        let lockedSnapshot = scene.snapshot
        _ = editor.beginInteraction(
            at: CGPoint(x: 40, y: 50),
            zoomScale: 1,
            modifiers: [],
            clickCount: 1
        )
        editor.endInteraction(at: CGPoint(x: 80, y: 90), modifiers: [])
        editor.deleteSelection()
        try expect(
            scene.snapshot == lockedSnapshot && scene.element(withID: shape.id) != nil,
            "Expected locked elements to ignore transforms and deletion"
        )
    }

    static func testDestinationSpaceDuplicateOffset() throws {
        let destinationOffset = AppCommand.defaultDuplicateDestinationOffset
        for zoomScale in [CGFloat(1), 2, 4, 8] {
            let contentOffset = ZoomCanvasView.annotationContentOffset(
                forDestinationOffset: destinationOffset,
                zoomScale: zoomScale
            )
            try expect(
                approximatelyEqual(
                    CGPoint(
                        x: contentOffset.x * zoomScale,
                        y: contentOffset.y * zoomScale
                    ),
                    destinationOffset
                ),
                "Expected duplicate actions to retain a 10-point destination-space offset at \(zoomScale)x"
            )
        }
    }

    static func testRotatedResizeCoordinateSpaces() throws {
        var style = AnnotationStyle.default
        style.fillStyle = .solid
        var rotated = AnnotationElement.legacy(
            tool: .rectangle,
            points: [CGPoint(x: 20, y: 20), CGPoint(x: 80, y: 50)],
            style: style
        )
        rotated.metadata.rotation = .pi / 4
        let singleScene = AnnotationScene(elements: [rotated])
        let singleEditor = AnnotationEditor(scene: singleScene)
        singleScene.select([rotated.id])
        guard let singleBefore = AnnotationGeometry.selectionDecoration(
            for: rotated,
            zoomScale: 1
        ),
        let draggedHandle = singleBefore.handles.first(where: { $0.kind == .bottomTrailing }),
        let fixedHandle = singleBefore.handles.first(where: { $0.kind == .topLeading }) else {
            throw SelfTestError.failure("Expected rotated single-selection resize handles")
        }

        _ = singleEditor.beginInteraction(
            at: draggedHandle.center,
            zoomScale: 1,
            modifiers: [],
            clickCount: 1
        )
        singleEditor.endInteraction(
            at: CGPoint(x: draggedHandle.center.x + 24, y: draggedHandle.center.y + 18),
            modifiers: []
        )
        guard let resizedSingle = singleScene.element(withID: rotated.id),
              let singleAfter = AnnotationGeometry.selectionDecoration(
                  for: resizedSingle,
                  zoomScale: 1
              ),
              let fixedAfter = singleAfter.handles.first(where: { $0.kind == .topLeading }) else {
            throw SelfTestError.failure("Expected resized rotated single selection")
        }
        try expect(
            approximatelyEqual(fixedAfter.center, fixedHandle.center),
            "Expected inverse/forward rotation composition to keep the opposite single handle fixed"
        )

        var first = AnnotationElement.legacy(
            tool: .rectangle,
            points: [CGPoint(x: 20, y: 90), CGPoint(x: 70, y: 120)],
            style: style
        )
        first.metadata.rotation = .pi / 6
        var second = AnnotationElement.legacy(
            tool: .ellipse,
            points: [CGPoint(x: 110, y: 80), CGPoint(x: 160, y: 130)],
            style: style
        )
        second.metadata.rotation = -.pi / 5
        let multiScene = AnnotationScene(elements: [first, second])
        let multiEditor = AnnotationEditor(scene: multiScene)
        multiScene.select([first.id, second.id])
        guard let multiBefore = AnnotationGeometry.selectionDecoration(
            for: [first, second],
            zoomScale: 1
        ),
        let multiDragged = multiBefore.handles.first(where: { $0.kind == .bottomTrailing }),
        let multiFixed = multiBefore.handles.first(where: { $0.kind == .topLeading }) else {
            throw SelfTestError.failure("Expected rotated multi-selection resize handles")
        }

        _ = multiEditor.beginInteraction(
            at: multiDragged.center,
            zoomScale: 1,
            modifiers: [],
            clickCount: 1
        )
        multiEditor.endInteraction(
            at: CGPoint(x: multiDragged.center.x + 35, y: multiDragged.center.y + 25),
            modifiers: []
        )
        let resizedMulti = multiScene.elements.filter {
            [first.id, second.id].contains($0.id)
        }
        guard let multiAfter = AnnotationGeometry.selectionDecoration(
            for: resizedMulti,
            zoomScale: 1
        ),
        let multiFixedAfter = multiAfter.handles.first(where: { $0.kind == .topLeading }) else {
            throw SelfTestError.failure("Expected resized rotated multi selection")
        }
        try expect(
            approximatelyEqual(multiFixedAfter.center, multiFixed.center),
            "Expected rotated multi-selection resize to keep the opposite group handle fixed"
        )
    }

    static func testAnnotationEditorCommandsAndGrouping() throws {
        var style = AnnotationStyle.default
        style.fillStyle = .solid
        let scene = AnnotationScene()
        let first = AnnotationElement.legacy(
            tool: .rectangle,
            points: [.zero, CGPoint(x: 20, y: 20)],
            style: style
        )
        let second = AnnotationElement.legacy(
            tool: .ellipse,
            points: [CGPoint(x: 30, y: 0), CGPoint(x: 50, y: 20)],
            style: style
        )
        let third = AnnotationElement.legacy(
            tool: .diamond,
            points: [CGPoint(x: 60, y: 0), CGPoint(x: 80, y: 20)],
            style: style
        )
        scene.append(first)
        scene.append(second)
        scene.append(third)
        let editor = AnnotationEditor(scene: scene)
        scene.select([first.id, second.id])

        editor.groupSelection()
        guard let sourceGroup = scene.element(withID: first.id)?.metadata.groupIDs.last else {
            throw SelfTestError.failure("Expected group command to assign group metadata")
        }
        try expect(
            scene.element(withID: second.id)?.metadata.groupIDs.last == sourceGroup,
            "Expected grouped selection to share a group ID"
        )

        editor.duplicateSelection(offset: CGPoint(x: 10, y: 10))
        try expect(scene.elements.count == 5, "Expected duplicate to copy every selected element")
        let duplicateIDs = editor.selectedElementIDs
        let duplicateGroups = Set(
            scene.elements
                .filter { duplicateIDs.contains($0.id) }
                .flatMap(\.metadata.groupIDs)
        )
        try expect(
            duplicateIDs.count == 2
                && duplicateGroups.count == 1
                && !duplicateGroups.contains(sourceGroup),
            "Expected duplicated groups to retain grouping without sharing the source group ID"
        )

        editor.ungroupSelection()
        try expect(
            scene.elements
                .filter { duplicateIDs.contains($0.id) }
                .allSatisfy(\.metadata.groupIDs.isEmpty),
            "Expected ungroup to remove group metadata from the selection"
        )

        editor.toggleSelectionLock()
        try expect(
            scene.elements
                .filter { duplicateIDs.contains($0.id) }
                .allSatisfy(\.metadata.isLocked),
            "Expected lock command to lock the selection"
        )
        editor.toggleSelectionLock()

        scene.select([first.id])
        editor.arrangeSelection(.bringToFront)
        try expect(
            scene.elements.last?.id == first.id,
            "Expected bring-to-front to move selection to the top of z-order"
        )
        editor.arrangeSelection(.sendToBack)
        try expect(
            scene.elements.first?.id == first.id,
            "Expected send-to-back to move selection to the bottom of z-order"
        )

        scene.select(duplicateIDs)
        editor.deleteSelection()
        try expect(scene.elements.count == 3, "Expected delete to remove unlocked selected elements")
        try expect(scene.undo(), "Expected delete command to be undoable")
        try expect(scene.elements.count == 5, "Expected undo to restore deleted duplicates")
    }

    static func testNestedUngroupPreservesInnerGroup() throws {
        let scene = AnnotationScene()
        let first = AnnotationElement.legacy(
            tool: .rectangle,
            points: [.zero, CGPoint(x: 20, y: 20)],
            style: .default
        )
        let second = AnnotationElement.legacy(
            tool: .ellipse,
            points: [CGPoint(x: 30, y: 0), CGPoint(x: 50, y: 20)],
            style: .default
        )
        let third = AnnotationElement.legacy(
            tool: .diamond,
            points: [CGPoint(x: 60, y: 0), CGPoint(x: 80, y: 20)],
            style: .default
        )
        scene.append([first, second, third])
        guard let innerGroup = scene.groupElements(withIDs: [first.id, second.id]),
              let outerGroup = scene.groupElements(withIDs: [first.id, second.id, third.id]) else {
            throw SelfTestError.failure("Expected nested group setup")
        }
        scene.select([first.id, second.id, third.id])
        let editor = AnnotationEditor(scene: scene)
        editor.ungroupSelection()

        try expect(
            scene.element(withID: first.id)?.metadata.groupIDs == [innerGroup]
                && scene.element(withID: second.id)?.metadata.groupIDs == [innerGroup]
                && scene.element(withID: third.id)?.metadata.groupIDs.isEmpty == true,
            "Expected ungroup to remove only the active common outer group"
        )
        try expect(
            scene.elements.allSatisfy { !$0.metadata.groupIDs.contains(outerGroup) },
            "Expected the active outer group ID to be removed from the full selection"
        )
    }
}
