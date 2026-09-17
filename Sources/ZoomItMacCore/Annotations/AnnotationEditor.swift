import AppKit

struct AnnotationEditorModifiers: OptionSet, Equatable {
    let rawValue: Int

    static let shift = AnnotationEditorModifiers(rawValue: 1 << 0)
    static let command = AnnotationEditorModifiers(rawValue: 1 << 1)
    static let option = AnnotationEditorModifiers(rawValue: 1 << 2)
}

enum AnnotationEditorStateKind: Equatable {
    case idle
    case creating
    case marqueeSelecting
    case moving
    case resizing
    case rotating
    case editingLinearPoints
    case editingText
}

enum AnnotationArrangeAction: Equatable {
    case bringForward
    case bringToFront
    case sendBackward
    case sendToBack
}

enum AnnotationEditorOutcome: Equatable {
    case none
    case beginTextEditing(AnnotationElementID)
}

@MainActor
final class AnnotationEditor {
    private struct MarqueeState {
        var origin: CGPoint
        var current: CGPoint
        var initialSelection: Set<AnnotationElementID>
        var modifiers: AnnotationEditorModifiers
    }

    private struct MovingState {
        var origin: CGPoint
        var originals: [AnnotationElementID: AnnotationElement]
        var duplicateOnDrag: Bool
        var lastPoint: CGPoint
    }

    private struct ResizingState {
        var handle: AnnotationSelectionHandleKind
        var originals: [AnnotationElementID: AnnotationElement]
        var coordinateBounds: CGRect
        var coordinateToWorld: CGAffineTransform
        var preservesAspectRatio: Bool
        var zoomScale: CGFloat
        var lastPoint: CGPoint
        var lastModifiers: AnnotationEditorModifiers
    }

    private struct RotatingState {
        var center: CGPoint
        var startAngle: CGFloat
        var originals: [AnnotationElementID: AnnotationElement]
        var lastPoint: CGPoint
        var lastModifiers: AnnotationEditorModifiers
    }

    private struct LinearPointDrag {
        var origin: CGPoint
        var original: AnnotationElement
        var part: AnnotationLinearEditPart
        var unbindOnDrag: Bool
    }

    private struct LinearEditingState {
        var elementID: AnnotationElementID
        var selectedPointIndices: Set<Int>
        var selectedSegmentIndex: Int?
        var selectedControl: AnnotationLinearEditPart?
        var zoomScale: CGFloat
        var drag: LinearPointDrag?
    }

    private enum State {
        case idle
        case creating(AnnotationTool)
        case marquee(MarqueeState)
        case moving(MovingState)
        case resizing(ResizingState)
        case rotating(RotatingState)
        case editingLinear(LinearEditingState)
        case editingText(AnnotationElementID?)
    }

    private let scene: AnnotationScene
    private var state: State = .idle

    init(scene: AnnotationScene) {
        self.scene = scene
    }

    var stateKind: AnnotationEditorStateKind {
        switch state {
        case .idle: .idle
        case .creating: .creating
        case .marquee: .marqueeSelecting
        case .moving: .moving
        case .resizing: .resizing
        case .rotating: .rotating
        case .editingLinear: .editingLinearPoints
        case .editingText: .editingText
        }
    }

    var selectedElementIDs: Set<AnnotationElementID> {
        scene.selection.elementIDs
    }

    var marqueeBounds: CGRect? {
        guard case .marquee(let marquee) = state else { return nil }
        return rect(from: marquee.origin, to: marquee.current)
    }

    var hasSelection: Bool {
        !scene.selection.isEmpty
    }

    var canDeleteSelection: Bool {
        !editableSelectionIDs.isEmpty
    }

    var canGroupSelection: Bool {
        editableSelectionIDs.count >= 2
    }

    var canUngroupSelection: Bool {
        activeCommonGroupID != nil
    }

    var hasMovableSelection: Bool {
        !editableSelectionIDs.isEmpty
    }

    var selectionIsFullyLocked: Bool {
        !selectedElements.isEmpty && selectedElements.allSatisfy(\.metadata.isLocked)
    }

    var isEditingLinearPoints: Bool {
        if case .editingLinear = state {
            return true
        }
        return false
    }

    var linearPointEditingElement: AnnotationElement? {
        guard case .editingLinear(let editing) = state else { return nil }
        return scene.element(withID: editing.elementID)
    }

    var selectedLinearPointIndices: Set<Int> {
        guard case .editingLinear(let editing) = state else { return [] }
        return editing.selectedPointIndices
    }

    var selectedLinearSegmentIndex: Int? {
        guard case .editingLinear(let editing) = state else { return nil }
        return editing.selectedSegmentIndex
    }

    var selectedLinearControl: AnnotationLinearEditPart? {
        guard case .editingLinear(let editing) = state else { return nil }
        return editing.selectedControl
    }

    func beginCreating(tool: AnnotationTool) {
        cancelInteraction()
        state = .creating(tool)
    }

    func finishCreating() {
        if case .creating = state {
            state = .idle
        }
    }

    func beginTextEditing(elementID: AnnotationElementID?) {
        cancelInteraction()
        if let elementID {
            guard let element = scene.element(withID: elementID),
                  !element.metadata.isLocked,
                  case .text = element.geometry else {
                state = .idle
                return
            }
        }
        state = .editingText(elementID)
    }

    func finishTextEditing() {
        if case .editingText = state {
            state = .idle
        }
    }

    @discardableResult
    func beginLinearPointEditing(elementID: AnnotationElementID? = nil) -> Bool {
        let targetID = elementID ?? scene.selection.elementIDs.first
        guard let targetID,
              scene.selection.elementIDs.count == 1,
              let element = scene.element(withID: targetID),
              !element.metadata.isLocked,
              case .linear = element.geometry else {
            return false
        }
        cancelInteraction()
        scene.select([targetID])
        state = .editingLinear(
            LinearEditingState(
                elementID: targetID,
                selectedPointIndices: [],
                selectedSegmentIndex: nil,
                selectedControl: nil,
                zoomScale: 1,
                drag: nil
            )
        )
        return true
    }

    func finishLinearPointEditing() {
        guard case .editingLinear(let editing) = state else { return }
        if editing.drag != nil {
            scene.commitTransaction()
        }
        state = .idle
    }

    @discardableResult
    func toggleLinearPointEditing() -> Bool {
        if isEditingLinearPoints {
            finishLinearPointEditing()
            return true
        }
        return beginLinearPointEditing()
    }

    func insertLinearPoint() {
        guard case .editingLinear(var editing) = state else { return }
        guard let element = revalidatedLinearElement(for: editing),
              case .linear(let linear) = element.geometry,
              let segmentIndex = editing.selectedSegmentIndex,
              segmentIndex >= 0,
              segmentIndex < linear.points.count - 1 else {
            return
        }
        let location = midpointLocation(segmentIndex: segmentIndex, linear: linear)
        scene.updateElement(withID: editing.elementID) { element in
            guard case .linear(let current) = element.geometry else { return }
            element.geometry = .linear(
                AnnotationGeometry.insertingPoint(into: current, at: location)
            )
        }
        editing.selectedPointIndices = [segmentIndex + 1]
        editing.selectedSegmentIndex = nil
        editing.selectedControl = nil
        state = .editingLinear(editing)
    }

    func removeSelectedLinearPoints() {
        guard case .editingLinear(var editing) = state else { return }
        guard let element = revalidatedLinearElement(for: editing),
              case .linear(let linear) = element.geometry,
              !editing.selectedPointIndices.isEmpty else {
            return
        }
        let remaining = linear.points.indices.filter {
            !editing.selectedPointIndices.contains($0)
        }
        guard remaining.count >= 2 else { return }

        scene.updateElement(withID: editing.elementID) { element in
            guard case .linear(let current) = element.geometry else { return }
            var updated = AnnotationGeometry.removingLinearPoints(
                editing.selectedPointIndices,
                from: current
            )
            if editing.selectedPointIndices.contains(0) {
                updated.startBinding = nil
            }
            if editing.selectedPointIndices.contains(linear.points.count - 1) {
                updated.endBinding = nil
            }
            element.geometry = .linear(updated)
        }
        editing.selectedPointIndices = []
        editing.selectedSegmentIndex = nil
        editing.selectedControl = nil
        state = .editingLinear(editing)
    }

    func setLinearRoute(_ route: AnnotationLinearRoute) {
        let ids = selectedEditableLinearIDs
        guard !ids.isEmpty else { return }
        scene.updateElements(withIDs: ids) { element in
            guard case .linear(var linear) = element.geometry else { return }
            linear.route = route
            switch route {
            case .straight:
                linear.bezierControls = []
            case .curved:
                linear.bezierControls = AnnotationGeometry.bezierControls(for: linear)
            }
            element.geometry = .linear(linear)
        }
    }

    func setLinearArrowheads(start: AnnotationArrowhead, end: AnnotationArrowhead) {
        let ids = selectedEditableLinearIDs
        guard !ids.isEmpty else { return }
        scene.updateElements(withIDs: ids) { element in
            guard case .linear(var linear) = element.geometry else { return }
            linear.startArrowhead = start
            linear.endArrowhead = end
            element.geometry = .linear(linear)
        }
    }

    func setLinearStartArrowhead(_ arrowhead: AnnotationArrowhead) {
        setLinearArrowhead(atStart: true, to: arrowhead)
    }

    func setLinearEndArrowhead(_ arrowhead: AnnotationArrowhead) {
        setLinearArrowhead(atStart: false, to: arrowhead)
    }

    func setLinearArrowheadSize(_ size: AnnotationArrowheadSize) {
        let ids = selectedEditableLinearIDs
        guard !ids.isEmpty else { return }
        scene.updateElements(withIDs: ids) { element in
            guard case .linear(var linear) = element.geometry else { return }
            linear.arrowheadSize = size
            element.geometry = .linear(linear)
        }
    }

    private func setLinearArrowhead(
        atStart: Bool,
        to arrowhead: AnnotationArrowhead
    ) {
        let ids = selectedEditableLinearIDs
        guard !ids.isEmpty else { return }
        scene.updateElements(withIDs: ids) { element in
            guard case .linear(var linear) = element.geometry else { return }
            if atStart {
                linear.startArrowhead = arrowhead
            } else {
                linear.endArrowhead = arrowhead
            }
            element.geometry = .linear(linear)
        }
    }

    func unbindLinearEndpoints() {
        let ids = selectedEditableLinearIDs
        guard !ids.isEmpty else { return }
        scene.updateElements(withIDs: ids) { element in
            guard case .linear(var linear) = element.geometry else { return }
            linear.startBinding = nil
            linear.endBinding = nil
            element.geometry = .linear(linear)
        }
    }

    func beginInteraction(
        at point: CGPoint,
        zoomScale: CGFloat,
        modifiers: AnnotationEditorModifiers,
        clickCount: Int
    ) -> AnnotationEditorOutcome {
        if case .editingLinear(let editing) = state {
            return beginLinearInteraction(
                editing: editing,
                at: point,
                zoomScale: zoomScale,
                modifiers: modifiers,
                clickCount: clickCount
            )
        }

        if scene.selection.elementIDs.count == 1,
           let elementID = scene.selection.elementIDs.first,
           let element = scene.element(withID: elementID),
           !element.metadata.isLocked,
           case .linear = element.geometry,
           let linearHit = AnnotationHitTester.linearEditHitTest(
               point: point,
               in: element,
               zoomScale: zoomScale
           ) {
            switch linearHit.part {
            case .point, .control:
                if beginLinearPointEditing(elementID: elementID),
                   case .editingLinear(let editing) = state {
                    return beginLinearInteraction(
                        editing: editing,
                        at: point,
                        zoomScale: zoomScale,
                        modifiers: modifiers,
                        clickCount: clickCount
                    )
                }
            case .segment:
                break
            }
        }

        cancelInteraction()

        var hit = AnnotationHitTester.hitTest(
            point: point,
            elements: scene.elements,
            selection: scene.selection.elementIDs,
            zoomScale: zoomScale
        )
        if (modifiers.contains(.shift) || modifiers.contains(.command)),
           case .handle = hit?.part {
            hit = AnnotationHitTester.hitTest(
                point: point,
                elements: scene.elements,
                selection: [],
                zoomScale: zoomScale
            )
        }

        if clickCount >= 2,
           let hit,
           case .body = hit.part,
           let element = scene.element(withID: hit.elementID) {
            switch element.geometry {
            case .text where !element.metadata.isLocked:
                scene.select(expandedSelection(for: hit.elementID))
                state = .editingText(hit.elementID)
                return .beginTextEditing(hit.elementID)
            case .linear where !element.metadata.isLocked:
                scene.select([hit.elementID])
                _ = beginLinearPointEditing(elementID: hit.elementID)
                return .none
            default:
                break
            }
        }

        if let hit,
           case .handle(let handle) = hit.part,
           !modifiers.contains(.shift),
           !modifiers.contains(.command) {
            let editable = editableSelectionIDs
            guard !editable.isEmpty else { return .none }
            let originals = elementsByID(editable)
            guard let bounds = selectionBounds(of: Array(originals.values)) else { return .none }

            scene.beginTransaction()
            if handle == .rotation {
                state = .rotating(
                    RotatingState(
                        center: CGPoint(x: bounds.midX, y: bounds.midY),
                        startAngle: angle(from: CGPoint(x: bounds.midX, y: bounds.midY), to: point),
                        originals: originals,
                        lastPoint: point,
                        lastModifiers: modifiers
                    )
                )
            } else {
                let coordinateBounds: CGRect
                let coordinateToWorld: CGAffineTransform
                if originals.count == 1, let original = originals.values.first {
                    coordinateBounds = AnnotationGeometry.localBounds(of: original)
                    coordinateToWorld = AnnotationGeometry.worldTransform(for: original)
                } else {
                    coordinateBounds = bounds
                    coordinateToWorld = .identity
                }
                state = .resizing(
                    ResizingState(
                        handle: handle,
                        originals: originals,
                        coordinateBounds: coordinateBounds,
                        coordinateToWorld: coordinateToWorld,
                        preservesAspectRatio: originals.values.contains {
                            if case .text = $0.geometry { return true }
                            return false
                        },
                        zoomScale: zoomScale,
                        lastPoint: point,
                        lastModifiers: modifiers
                    )
                )
            }
            return .none
        }

        if let hit, case .body = hit.part {
            let clickedIDs = expandedSelection(for: hit.elementID)
            let current = scene.selection.elementIDs
            let next: Set<AnnotationElementID>
            if modifiers.contains(.command) {
                next = current.symmetricDifference(clickedIDs)
            } else if modifiers.contains(.shift) {
                next = current.union(clickedIDs)
            } else if current.contains(hit.elementID) {
                next = current
            } else {
                next = clickedIDs
            }
            scene.select(next)

            guard next.contains(hit.elementID) else { return .none }
            let editable = editableSelectionIDs
            guard !editable.isEmpty else { return .none }
            scene.beginTransaction()
            state = .moving(
                MovingState(
                    origin: point,
                    originals: elementsByID(editable),
                    duplicateOnDrag: modifiers.contains(.option),
                    lastPoint: point
                )
            )
            return .none
        }

        let initialSelection = scene.selection.elementIDs
        if !modifiers.contains(.shift) && !modifiers.contains(.command) {
            scene.select([])
        }
        state = .marquee(
            MarqueeState(
                origin: point,
                current: point,
                initialSelection: initialSelection,
                modifiers: modifiers
            )
        )
        return .none
    }

    func updateInteraction(
        to point: CGPoint,
        modifiers: AnnotationEditorModifiers
    ) {
        switch state {
        case .marquee(var marquee):
            marquee.current = point
            marquee.modifiers = modifiers
            state = .marquee(marquee)
            updateMarqueeSelection(marquee)
        case .moving(var moving):
            let delta = CGPoint(x: point.x - moving.origin.x, y: point.y - moving.origin.y)
            if moving.duplicateOnDrag,
               hypot(delta.x, delta.y) >= 1 {
                let duplicates = duplicateElements(withIDs: Set(moving.originals.keys))
                moving.originals = elementsByID(duplicates)
                moving.duplicateOnDrag = false
                scene.select(duplicates)
                state = .moving(moving)
            }
            replaceElements(
                moving.originals,
                applying: CGAffineTransform(translationX: delta.x, y: delta.y)
            )
            moving.lastPoint = point
            state = .moving(moving)
        case .resizing(var resizing):
            let coordinatePoint = point.applying(resizing.coordinateToWorld.inverted())
            let minimumSize = 1 / max(resizing.zoomScale, 0.001)
            let newBounds = if resizing.preservesAspectRatio {
                uniformlyResizedBounds(
                    from: resizing.coordinateBounds,
                    handle: resizing.handle,
                    to: coordinatePoint,
                    fromCenter: modifiers.contains(.option),
                    minimumSize: minimumSize
                )
            } else {
                resizedBounds(
                    from: resizing.coordinateBounds,
                    handle: resizing.handle,
                    to: coordinatePoint,
                    modifiers: modifiers,
                    minimumSize: minimumSize
                )
            }
            let coordinateResize = transform(
                from: resizing.coordinateBounds,
                to: newBounds
            )
            let worldResize = resizing.coordinateToWorld.inverted()
                .concatenating(coordinateResize)
                .concatenating(resizing.coordinateToWorld)
            replaceResizedElements(
                resizing.originals,
                applyingWorldTransform: worldResize,
                coordinateBounds: resizing.coordinateBounds,
                coordinateToWorld: resizing.coordinateToWorld,
                handle: resizing.handle,
                modifiers: modifiers
            )
            resizing.lastPoint = point
            resizing.lastModifiers = modifiers
            state = .resizing(resizing)
        case .rotating(var rotating):
            var delta = angle(from: rotating.center, to: point) - rotating.startAngle
            if modifiers.contains(.shift) {
                let increment = CGFloat.pi / 12
                delta = (delta / increment).rounded() * increment
            }
            replaceRotatedElements(rotating.originals, around: rotating.center, angle: delta)
            rotating.lastPoint = point
            rotating.lastModifiers = modifiers
            state = .rotating(rotating)
        case .editingLinear(var editing):
            guard revalidatedLinearElement(for: editing) != nil else { break }
            guard let drag = editing.drag else { break }
            updateLinearDrag(&editing, drag: drag, to: point, modifiers: modifiers)
            state = .editingLinear(editing)
        case .idle, .creating, .editingText:
            break
        }
    }

    func endInteraction(
        at point: CGPoint,
        modifiers: AnnotationEditorModifiers
    ) {
        switch state {
        case .moving(let moving) where moving.lastPoint != point:
            updateInteraction(to: point, modifiers: modifiers)
        case .resizing(let resizing)
            where resizing.lastPoint != point || resizing.lastModifiers != modifiers:
            updateInteraction(to: point, modifiers: modifiers)
        case .rotating(let rotating)
            where rotating.lastPoint != point || rotating.lastModifiers != modifiers:
            updateInteraction(to: point, modifiers: modifiers)
        case .editingLinear:
            updateInteraction(to: point, modifiers: modifiers)
        default:
            break
        }
        switch state {
        case .moving, .resizing, .rotating:
            scene.commitTransaction()
            state = .idle
        case .editingLinear(var editing):
            guard revalidatedLinearElement(for: editing) != nil else { break }
            if let drag = editing.drag {
                finishLinearDrag(&editing, drag: drag, at: point, modifiers: modifiers)
                scene.commitTransaction()
                editing.drag = nil
            }
            state = .editingLinear(editing)
        default:
            state = .idle
            break
        }
    }

    func cancelInteraction() {
        switch state {
        case .moving, .resizing, .rotating:
            scene.cancelTransaction()
        case .editingLinear(let editing) where editing.drag != nil:
            scene.cancelTransaction()
        case .marquee(let marquee):
            scene.select(marquee.initialSelection)
        default:
            break
        }
        state = .idle
    }

    @discardableResult
    func prepareContextSelection(at point: CGPoint, zoomScale: CGFloat) -> Bool {
        if let hit = AnnotationHitTester.hitTest(
            point: point,
            elements: scene.elements,
            selection: scene.selection.elementIDs,
            zoomScale: zoomScale
        ) {
            if !scene.selection.contains(hit.elementID) {
                scene.select(expandedSelection(for: hit.elementID))
            }
        }
        return hasSelection
    }

    func selectAll() {
        cancelInteraction()
        scene.select(Set(scene.elements.filter(\.metadata.isVisible).map(\.id)))
    }

    func clearSelection() {
        cancelInteraction()
        scene.select([])
    }

    func deleteSelection() {
        cancelInteraction()
        let deletable = editableSelectionIDs
        guard !deletable.isEmpty else { return }
        scene.removeElements(withIDs: deletable)
    }

    func duplicateSelection(offset: CGPoint) {
        cancelInteraction()
        let duplicatable = editableSelectionIDs
        guard !duplicatable.isEmpty else { return }
        scene.beginTransaction()
        let duplicates = duplicateElements(withIDs: duplicatable)
        replaceElements(
            elementsByID(duplicates),
            applying: CGAffineTransform(translationX: offset.x, y: offset.y)
        )
        scene.select(duplicates)
        scene.commitTransaction()
    }

    func moveSelection(by delta: CGPoint) {
        cancelInteraction()
        let movable = editableSelectionIDs
        guard !movable.isEmpty else { return }
        scene.beginTransaction()
        replaceElements(
            elementsByID(movable),
            applying: CGAffineTransform(translationX: delta.x, y: delta.y)
        )
        scene.commitTransaction()
    }

    func arrangeSelection(_ action: AnnotationArrangeAction) {
        cancelInteraction()
        let selected = editableSelectionIDs
        guard !selected.isEmpty else { return }
        var ordered = scene.elements.map(\.id)

        switch action {
        case .bringToFront:
            ordered = ordered.filter { !selected.contains($0) }
                + ordered.filter { selected.contains($0) }
        case .sendToBack:
            ordered = ordered.filter { selected.contains($0) }
                + ordered.filter { !selected.contains($0) }
        case .bringForward:
            guard ordered.count > 1 else { return }
            for index in stride(from: ordered.count - 2, through: 0, by: -1)
                where selected.contains(ordered[index]) && !selected.contains(ordered[index + 1]) {
                ordered.swapAt(index, index + 1)
            }
        case .sendBackward:
            guard ordered.count > 1 else { return }
            for index in 1..<ordered.count
                where selected.contains(ordered[index]) && !selected.contains(ordered[index - 1]) {
                ordered.swapAt(index, index - 1)
            }
        }
        scene.setElementOrder(ordered)
    }

    func groupSelection() {
        cancelInteraction()
        let groupable = editableSelectionIDs
        guard groupable.count >= 2 else { return }
        _ = scene.groupElements(withIDs: groupable)
    }

    func ungroupSelection() {
        cancelInteraction()
        let editable = editableSelectionIDs
        guard !editable.isEmpty, let groupID = activeCommonGroupID else { return }
        scene.ungroupElements(withIDs: editable, groupID: groupID)
    }

    func toggleSelectionLock() {
        cancelInteraction()
        let selected = scene.selection.elementIDs
        guard !selected.isEmpty else { return }
        scene.setLocked(!selectionIsFullyLocked, for: selected)
    }

    private func beginLinearInteraction(
        editing originalEditing: LinearEditingState,
        at point: CGPoint,
        zoomScale: CGFloat,
        modifiers: AnnotationEditorModifiers,
        clickCount: Int
    ) -> AnnotationEditorOutcome {
        guard let element = revalidatedLinearElement(for: originalEditing) else {
            return .none
        }

        var editing = originalEditing
        editing.zoomScale = zoomScale
        guard let hit = AnnotationHitTester.linearEditHitTest(
            point: point,
            in: element,
            zoomScale: zoomScale
        ) else {
            state = .idle
            return beginInteraction(
                at: point,
                zoomScale: zoomScale,
                modifiers: modifiers,
                clickCount: clickCount
            )
        }

        switch hit.part {
        case .point(let index):
            if modifiers.contains(.shift) || modifiers.contains(.command) {
                if editing.selectedPointIndices.contains(index) {
                    editing.selectedPointIndices.remove(index)
                } else {
                    editing.selectedPointIndices.insert(index)
                }
            } else if !editing.selectedPointIndices.contains(index) {
                editing.selectedPointIndices = [index]
            }
            editing.selectedSegmentIndex = nil
            editing.selectedControl = nil
            scene.beginTransaction()
            if modifiers.contains(.option), isEndpoint(index, in: element) {
                scene.unbindLinearEndpoints(
                    elementID: editing.elementID,
                    start: index == 0,
                    end: isLastPoint(index, in: element)
                )
            }
            guard let dragElement = scene.element(withID: editing.elementID) else {
                scene.cancelTransaction()
                return .none
            }
            editing.drag = LinearPointDrag(
                origin: point,
                original: dragElement,
                part: .point(index),
                unbindOnDrag: modifiers.contains(.option)
            )
        case .segment(let segmentIndex):
            editing.selectedPointIndices = []
            editing.selectedSegmentIndex = segmentIndex
            editing.selectedControl = nil
            scene.beginTransaction()
            var dragPart: AnnotationLinearEditPart = .segment(segmentIndex)
            if clickCount >= 2, let location = hit.location {
                scene.updateElement(withID: editing.elementID) { element in
                    guard case .linear(let linear) = element.geometry else { return }
                    element.geometry = .linear(
                        AnnotationGeometry.insertingPoint(into: linear, at: location)
                    )
                }
                let insertedIndex = segmentIndex + 1
                editing.selectedPointIndices = [insertedIndex]
                editing.selectedSegmentIndex = nil
                dragPart = .point(insertedIndex)
            }
            guard let dragElement = scene.element(withID: editing.elementID) else {
                scene.cancelTransaction()
                return .none
            }
            editing.drag = LinearPointDrag(
                origin: point,
                original: dragElement,
                part: dragPart,
                unbindOnDrag: false
            )
        case .control:
            editing.selectedPointIndices = []
            editing.selectedSegmentIndex = nil
            editing.selectedControl = hit.part
            scene.beginTransaction()
            guard let dragElement = scene.element(withID: editing.elementID) else {
                scene.cancelTransaction()
                return .none
            }
            editing.drag = LinearPointDrag(
                origin: point,
                original: dragElement,
                part: hit.part,
                unbindOnDrag: false
            )
        }
        state = .editingLinear(editing)
        return .none
    }

    private func updateLinearDrag(
        _ editing: inout LinearEditingState,
        drag: LinearPointDrag,
        to worldPoint: CGPoint,
        modifiers: AnnotationEditorModifiers
    ) {
        guard case .linear(let originalLinear) = drag.original.geometry else { return }
        let inverse = AnnotationGeometry.inverseWorldTransform(for: drag.original)
        let localOrigin = drag.origin.applying(inverse)
        let localPoint = worldPoint.applying(inverse)
        var delta = localPoint - localOrigin
        if modifiers.contains(.shift), case .point = drag.part {
            if abs(delta.x) >= abs(delta.y) {
                delta.y = 0
            } else {
                delta.x = 0
            }
        }

        if case .point(let index) = drag.part,
           endpointBinding(for: index, in: originalLinear) != nil,
           !drag.unbindOnDrag,
           let binding = endpointBinding(for: index, in: originalLinear),
           let target = scene.element(withID: binding.targetElementID),
           let updatedBinding = AnnotationGeometry.binding(
               to: target,
               near: worldPoint,
               gap: binding.gap
           ) {
            scene.bindLinearEndpoint(
                elementID: editing.elementID,
                atStart: index == 0,
                to: updatedBinding
            )
            return
        }

        scene.updateElement(withID: editing.elementID) { element in
            guard case .linear(var linear) = drag.original.geometry else { return }
            if linear.route == .curved {
                linear.bezierControls = AnnotationGeometry.bezierControls(for: linear)
            }
            switch drag.part {
            case .point(let index):
                let indices = editing.selectedPointIndices.isEmpty
                    ? Set([index])
                    : editing.selectedPointIndices
                moveLinearPoints(indices, by: delta, linear: &linear)
            case .segment(let segmentIndex):
                moveLinearPoints(
                    [segmentIndex, segmentIndex + 1],
                    by: delta,
                    linear: &linear
                )
            case .control(let segmentIndex, let end):
                guard segmentIndex >= 0,
                      segmentIndex < linear.bezierControls.count else {
                    return
                }
                switch end {
                case .start:
                    linear.bezierControls[segmentIndex].start = localPoint
                case .end:
                    linear.bezierControls[segmentIndex].end = localPoint
                }
                if !modifiers.contains(.option) {
                    mirrorOppositeControl(
                        from: .control(segment: segmentIndex, end: end),
                        equalLength: modifiers.contains(.command),
                        linear: &linear
                    )
                }
            }
            element.geometry = .linear(linear)
        }
    }

    private func finishLinearDrag(
        _ editing: inout LinearEditingState,
        drag: LinearPointDrag,
        at worldPoint: CGPoint,
        modifiers: AnnotationEditorModifiers
    ) {
        guard case .point(let index) = drag.part,
              !modifiers.contains(.option),
              let element = revalidatedLinearElement(for: editing),
              case .linear(let linear) = element.geometry,
              index == 0 || index == linear.points.count - 1,
              endpointBinding(for: index, in: linear) == nil,
              let candidate = bindingCandidate(
                  near: worldPoint,
                  excluding: editing.elementID,
                  tolerance: 16 / max(editing.zoomScale, 0.001)
              ),
              let binding = AnnotationGeometry.binding(to: candidate, near: worldPoint) else {
            return
        }
        scene.bindLinearEndpoint(
            elementID: editing.elementID,
            atStart: index == 0,
            to: binding
        )
    }

    private func moveLinearPoints(
        _ indices: Set<Int>,
        by delta: CGPoint,
        linear: inout AnnotationLinearGeometry
    ) {
        for index in indices where linear.points.indices.contains(index) {
            linear.points[index] = linear.points[index] + delta
            if linear.route == .curved {
                if index > 0 {
                    linear.bezierControls[index - 1].end =
                        linear.bezierControls[index - 1].end + delta
                }
                if index < linear.bezierControls.count {
                    linear.bezierControls[index].start =
                        linear.bezierControls[index].start + delta
                }
            }
            if index == 0 {
                linear.startBinding = nil
            }
            if index == linear.points.count - 1 {
                linear.endBinding = nil
            }
        }
    }

    private func mirrorOppositeControl(
        from part: AnnotationLinearEditPart,
        equalLength: Bool,
        linear: inout AnnotationLinearGeometry
    ) {
        guard case .control(let segmentIndex, let end) = part else { return }

        let anchorIndex: Int
        let movedControl: CGPoint
        let oppositeSegmentIndex: Int
        let oppositeEnd: AnnotationLinearControlEnd
        switch end {
        case .start:
            anchorIndex = segmentIndex
            movedControl = linear.bezierControls[segmentIndex].start
            oppositeSegmentIndex = segmentIndex - 1
            oppositeEnd = .end
        case .end:
            anchorIndex = segmentIndex + 1
            movedControl = linear.bezierControls[segmentIndex].end
            oppositeSegmentIndex = segmentIndex + 1
            oppositeEnd = .start
        }
        guard linear.points.indices.contains(anchorIndex),
              linear.bezierControls.indices.contains(oppositeSegmentIndex) else {
            return
        }

        let anchor = linear.points[anchorIndex]
        let reflected = anchor - movedControl
        let reflectedLength = hypot(reflected.x, reflected.y)
        guard reflectedLength > 0.001 else { return }

        let existingOpposite = switch oppositeEnd {
        case .start: linear.bezierControls[oppositeSegmentIndex].start
        case .end: linear.bezierControls[oppositeSegmentIndex].end
        }
        let targetLength = equalLength
            ? reflectedLength
            : max(0.001, hypot(existingOpposite.x - anchor.x, existingOpposite.y - anchor.y))
        let mirrored = CGPoint(
            x: anchor.x + reflected.x * targetLength / reflectedLength,
            y: anchor.y + reflected.y * targetLength / reflectedLength
        )
        switch oppositeEnd {
        case .start:
            linear.bezierControls[oppositeSegmentIndex].start = mirrored
        case .end:
            linear.bezierControls[oppositeSegmentIndex].end = mirrored
        }
    }

    private func bindingCandidate(
        near point: CGPoint,
        excluding elementID: AnnotationElementID,
        tolerance: CGFloat
    ) -> AnnotationElement? {
        scene.elements
            .filter { element in
                guard element.id != elementID,
                      element.metadata.isVisible,
                      !element.metadata.isLocked else {
                    return false
                }
                if case .shape = element.geometry {
                    return true
                }
                return false
            }
            .min {
                AnnotationGeometry.distanceFromShapeBoundary(point, to: $0)
                    < AnnotationGeometry.distanceFromShapeBoundary(point, to: $1)
            }
            .flatMap {
                AnnotationGeometry.distanceFromShapeBoundary(point, to: $0) <= tolerance
                    ? $0
                    : nil
            }
    }

    private func endpointBinding(
        for index: Int,
        in linear: AnnotationLinearGeometry
    ) -> AnnotationBinding? {
        if index == 0 {
            return linear.startBinding
        }
        if index == linear.points.count - 1 {
            return linear.endBinding
        }
        return nil
    }

    private func isEndpoint(_ index: Int, in element: AnnotationElement) -> Bool {
        guard case .linear(let linear) = element.geometry else { return false }
        return index == 0 || index == linear.points.count - 1
    }

    private func isLastPoint(_ index: Int, in element: AnnotationElement) -> Bool {
        guard case .linear(let linear) = element.geometry else { return false }
        return index == linear.points.count - 1
    }

    private func midpointLocation(
        segmentIndex: Int,
        linear: AnnotationLinearGeometry
    ) -> AnnotationLinearLocation {
        let start = linear.points[segmentIndex]
        let end = linear.points[segmentIndex + 1]
        return AnnotationLinearLocation(
            segmentIndex: segmentIndex,
            parameter: 0.5,
            point: CGPoint(x: (start.x + end.x) / 2, y: (start.y + end.y) / 2),
            distance: 0
        )
    }

    func revalidateLinearPointEditing() {
        guard case .editingLinear(let editing) = state,
              validatedLinearElement(for: editing) == nil else {
            return
        }
        abandonLinearPointEditing(editing)
    }

    private func revalidatedLinearElement(
        for editing: LinearEditingState
    ) -> AnnotationElement? {
        guard let element = validatedLinearElement(for: editing) else {
            abandonLinearPointEditing(editing)
            return nil
        }
        return element
    }

    private func validatedLinearElement(
        for editing: LinearEditingState
    ) -> AnnotationElement? {
        guard scene.selection.contains(editing.elementID),
              let element = scene.element(withID: editing.elementID),
              !element.metadata.isLocked,
              case .linear = element.geometry else {
            return nil
        }
        return element
    }

    private func abandonLinearPointEditing(_ editing: LinearEditingState) {
        state = .idle
        if editing.drag != nil {
            scene.cancelTransaction()
        }
    }

    private var selectedEditableLinearIDs: Set<AnnotationElementID> {
        if case .editingLinear(let editing) = state {
            guard scene.selection.contains(editing.elementID),
                  let element = scene.element(withID: editing.elementID),
                  !element.metadata.isLocked,
                  case .linear = element.geometry else {
                return []
            }
            return [editing.elementID]
        }
        return Set(selectedElements.compactMap { element in
            guard !element.metadata.isLocked, case .linear = element.geometry else { return nil }
            return element.id
        })
    }

    private var selectedElements: [AnnotationElement] {
        scene.elements.filter { scene.selection.contains($0.id) }
    }

    private var editableSelectionIDs: Set<AnnotationElementID> {
        Set(selectedElements.filter { !$0.metadata.isLocked }.map(\.id))
    }

    private var activeCommonGroupID: AnnotationGroupID? {
        let editable = selectedElements.filter { !$0.metadata.isLocked }
        guard let first = editable.first, !first.metadata.groupIDs.isEmpty else {
            return nil
        }
        let common = editable.dropFirst().reduce(Set(first.metadata.groupIDs)) {
            $0.intersection($1.metadata.groupIDs)
        }
        return first.metadata.groupIDs.reversed().first { common.contains($0) }
    }

    private func expandedSelection(for elementID: AnnotationElementID) -> Set<AnnotationElementID> {
        guard let element = scene.element(withID: elementID),
              let groupID = element.metadata.groupIDs.last else {
            return [elementID]
        }
        return Set(
            scene.elements
                .filter { $0.metadata.groupIDs.contains(groupID) }
                .map(\.id)
        )
    }

    private func updateMarqueeSelection(_ marquee: MarqueeState) {
        let bounds = rect(from: marquee.origin, to: marquee.current)
        let enclosed = Set(scene.elements.compactMap { element -> AnnotationElementID? in
            guard element.metadata.isVisible else { return nil }
            let elementBounds = AnnotationGeometry.worldBounds(of: element)
            return !elementBounds.isNull && bounds.intersects(elementBounds) ? element.id : nil
        })
        let expanded = enclosed.reduce(into: Set<AnnotationElementID>()) { result, elementID in
            result.formUnion(expandedSelection(for: elementID))
        }

        if marquee.modifiers.contains(.command) {
            scene.select(marquee.initialSelection.symmetricDifference(expanded))
        } else if marquee.modifiers.contains(.shift) {
            scene.select(marquee.initialSelection.union(expanded))
        } else {
            scene.select(expanded)
        }
    }

    private func duplicateElements(
        withIDs elementIDs: Set<AnnotationElementID>
    ) -> Set<AnnotationElementID> {
        let sourceElements = scene.elements.filter { elementIDs.contains($0.id) }
        let idMap = Dictionary(
            uniqueKeysWithValues: sourceElements.map { ($0.id, AnnotationElementID()) }
        )
        let sourceGroupIDs = Set(sourceElements.flatMap(\.metadata.groupIDs))
        let groupMap = Dictionary(
            uniqueKeysWithValues: sourceGroupIDs.map { ($0, AnnotationGroupID()) }
        )
        var duplicates: [AnnotationElement] = []

        for source in sourceElements {
            guard let duplicateID = idMap[source.id] else { continue }
            var geometry = source.geometry
            if case .linear(var linear) = geometry {
                if let binding = linear.startBinding,
                   let duplicateTargetID = idMap[binding.targetElementID] {
                    linear.startBinding?.targetElementID = duplicateTargetID
                }
                if let binding = linear.endBinding,
                   let duplicateTargetID = idMap[binding.targetElementID] {
                    linear.endBinding?.targetElementID = duplicateTargetID
                }
                geometry = .linear(linear)
            }
            var metadata = source.metadata
            metadata.groupIDs = metadata.groupIDs.compactMap { groupMap[$0] }
            let duplicate = AnnotationElement(
                id: duplicateID,
                geometry: geometry,
                style: source.style,
                metadata: metadata
            )
            duplicates.append(duplicate)
        }
        scene.append(duplicates)
        return Set(duplicates.map(\.id))
    }

    private func replaceElements(
        _ originals: [AnnotationElementID: AnnotationElement],
        applying transform: CGAffineTransform
    ) {
        let replacements = originals.mapValues {
            transformedElement($0, applying: transform)
        }
        scene.updateElements(withIDs: Set(replacements.keys)) { element in
            if let transformed = replacements[element.id] {
                element.geometry = transformed.geometry
                element.style = transformed.style
                element.metadata = transformed.metadata
            }
        }
    }

    private func replaceRotatedElements(
        _ originals: [AnnotationElementID: AnnotationElement],
        around center: CGPoint,
        angle: CGFloat
    ) {
        let transform = CGAffineTransform(translationX: center.x, y: center.y)
            .rotated(by: angle)
            .translatedBy(x: -center.x, y: -center.y)
        var replacements: [AnnotationElementID: AnnotationElement] = [:]

        for (elementID, original) in originals {
            let oldPivot = AnnotationGeometry.rotationPivot(for: original)
            let newPivot = oldPivot.applying(transform)
            let translation = CGAffineTransform(
                translationX: newPivot.x - oldPivot.x,
                y: newPivot.y - oldPivot.y
            )
            var transformed = transformedElement(original, applying: translation)
            if case .linear(var linear) = transformed.geometry {
                linear.rotationPivot = newPivot
                transformed.geometry = .linear(linear)
            }
            transformed.metadata.rotation = original.metadata.rotation + angle
            replacements[elementID] = transformed
        }
        scene.updateElements(withIDs: Set(replacements.keys)) { element in
            if let transformed = replacements[element.id] {
                element.geometry = transformed.geometry
                element.metadata = transformed.metadata
            }
        }
    }

    private func replaceResizedElements(
        _ originals: [AnnotationElementID: AnnotationElement],
        applyingWorldTransform worldTransform: CGAffineTransform,
        coordinateBounds: CGRect,
        coordinateToWorld: CGAffineTransform,
        handle: AnnotationSelectionHandleKind,
        modifiers: AnnotationEditorModifiers
    ) {
        var replacements = originals.mapValues {
            transformedElementPreservingRotation(
                $0,
                applyingWorldTransform: worldTransform,
                setsTextBounds: true
            )
        }
        let anchorKind = modifiers.contains(.option) ? nil : oppositeHandle(to: handle)
        let expectedAnchor = selectionAnchor(
            in: coordinateBounds,
            handle: anchorKind
        ).applying(coordinateToWorld)
        let actualAnchor: CGPoint? = {
            if replacements.count == 1, let replacement = replacements.values.first {
                if let anchorKind {
                    return AnnotationGeometry.selectionDecoration(
                        for: replacement,
                        zoomScale: 1
                    )?.handles.first(where: { $0.kind == anchorKind })?.center
                }
                let localBounds = AnnotationGeometry.localBounds(of: replacement)
                return localBounds.center.applying(
                    AnnotationGeometry.worldTransform(for: replacement)
                )
            }
            guard let bounds = selectionBounds(of: Array(replacements.values)) else {
                return nil
            }
            return selectionAnchor(in: bounds, handle: anchorKind)
        }()

        if let actualAnchor {
            let correction = expectedAnchor - actualAnchor
            if correction != .zero {
                let translation = CGAffineTransform(
                    translationX: correction.x,
                    y: correction.y
                )
                replacements = replacements.mapValues {
                    transformedElement($0, applying: translation)
                }
            }
        }

        scene.updateElements(withIDs: Set(replacements.keys)) { element in
            if let transformed = replacements[element.id] {
                element.geometry = transformed.geometry
                element.style = transformed.style
                element.metadata = transformed.metadata
            }
        }
    }

    private func transformedElementPreservingRotation(
        _ element: AnnotationElement,
        applyingWorldTransform worldTransform: CGAffineTransform,
        setsTextBounds: Bool = false
    ) -> AnnotationElement {
        let oldPivot = AnnotationGeometry.rotationPivot(for: element)
        let targetPivot = oldPivot.applying(worldTransform)
        let oldRotation = AnnotationGeometry.worldTransform(for: element)
        let targetRotation = rotationTransform(
            angle: element.metadata.rotation,
            around: targetPivot
        )
        let localTransform = oldRotation
            .concatenating(worldTransform)
            .concatenating(targetRotation.inverted())
        var transformed = transformedElement(
            element,
            applying: localTransform,
            setsTextBounds: setsTextBounds
        )
        if case .linear(var linear) = transformed.geometry {
            linear.rotationPivot = targetPivot
            transformed.geometry = .linear(linear)
        }
        transformed.metadata.rotation = element.metadata.rotation
        return transformed
    }

    private func transformedElement(
        _ element: AnnotationElement,
        applying transform: CGAffineTransform,
        setsTextBounds: Bool = false
    ) -> AnnotationElement {
        var result = element
        switch result.geometry {
        case .freehand(var freehand):
            for index in freehand.samples.indices {
                freehand.samples[index].location = freehand.samples[index].location.applying(transform)
            }
            result.geometry = .freehand(freehand)
        case .shape(var shape):
            shape.start = shape.start.applying(transform)
            shape.end = shape.end.applying(transform)
            result.geometry = .shape(shape)
        case .linear(var linear):
            linear.points = linear.points.map { $0.applying(transform) }
            linear.bezierControls = linear.bezierControls.map {
                AnnotationBezierControl(
                    start: $0.start.applying(transform),
                    end: $0.end.applying(transform)
                )
            }
            linear.rotationPivot = linear.rotationPivot?.applying(transform)
            result.geometry = .linear(linear)
        case .text(var text):
            let sourceBounds = AnnotationGeometry.localBounds(of: element)
            text.origin = text.origin.applying(transform)
            if setsTextBounds {
                text.bounds = transformedBounds(sourceBounds, applying: transform)
            } else if let bounds = text.bounds {
                text.bounds = transformedBounds(bounds, applying: transform)
            }
            let scale = sqrt(abs(transform.a * transform.d - transform.b * transform.c))
            if scale.isFinite, scale > 0 {
                text.fontSize *= scale
            }
            result.geometry = .text(text)
        }
        return result
    }

    private func resizedBounds(
        from bounds: CGRect,
        handle: AnnotationSelectionHandleKind,
        to point: CGPoint,
        modifiers: AnnotationEditorModifiers,
        minimumSize: CGFloat
    ) -> CGRect {
        var minX = bounds.minX
        var maxX = bounds.maxX
        var minY = bounds.minY
        var maxY = bounds.maxY
        let changesLeading = handle == .topLeading || handle == .leading || handle == .bottomLeading
        let changesTrailing = handle == .topTrailing || handle == .trailing || handle == .bottomTrailing
        let changesTop = handle == .topLeading || handle == .top || handle == .topTrailing
        let changesBottom = handle == .bottomLeading || handle == .bottom || handle == .bottomTrailing

        if modifiers.contains(.option) {
            if changesLeading || changesTrailing {
                let halfWidth = max(minimumSize / 2, abs(point.x - bounds.midX))
                minX = bounds.midX - halfWidth
                maxX = bounds.midX + halfWidth
            }
            if changesTop || changesBottom {
                let halfHeight = max(minimumSize / 2, abs(point.y - bounds.midY))
                minY = bounds.midY - halfHeight
                maxY = bounds.midY + halfHeight
            }
        } else {
            if changesLeading {
                minX = min(point.x, maxX - minimumSize)
            } else if changesTrailing {
                maxX = max(point.x, minX + minimumSize)
            }
            if changesTop {
                minY = min(point.y, maxY - minimumSize)
            } else if changesBottom {
                maxY = max(point.y, minY + minimumSize)
            }
        }

        if modifiers.contains(.shift),
           (changesLeading || changesTrailing),
           (changesTop || changesBottom),
           bounds.width > 0,
           bounds.height > 0 {
            let aspect = bounds.width / bounds.height
            var width = maxX - minX
            var height = maxY - minY
            if width / max(height, minimumSize) > aspect {
                height = width / aspect
            } else {
                width = height * aspect
            }

            if modifiers.contains(.option) {
                minX = bounds.midX - width / 2
                maxX = bounds.midX + width / 2
                minY = bounds.midY - height / 2
                maxY = bounds.midY + height / 2
            } else {
                if changesLeading {
                    minX = maxX - width
                } else {
                    maxX = minX + width
                }
                if changesTop {
                    minY = maxY - height
                } else {
                    maxY = minY + height
                }
            }
        }

        return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }

    private func uniformlyResizedBounds(
        from bounds: CGRect,
        handle: AnnotationSelectionHandleKind,
        to point: CGPoint,
        fromCenter: Bool,
        minimumSize: CGFloat
    ) -> CGRect {
        let anchorKind = fromCenter ? nil : oppositeHandle(to: handle)
        let anchor = selectionAnchor(in: bounds, handle: anchorKind)
        let originalHandle = selectionAnchor(in: bounds, handle: handle)
        let originalVector = originalHandle - anchor
        let requestedVector = point - anchor
        let squaredLength = originalVector.x * originalVector.x
            + originalVector.y * originalVector.y
        guard squaredLength > 0 else { return bounds }

        let projectedScale = (
            requestedVector.x * originalVector.x
                + requestedVector.y * originalVector.y
        ) / squaredLength
        let minimumScale = max(
            bounds.width > 0 ? minimumSize / bounds.width : 1,
            bounds.height > 0 ? minimumSize / bounds.height : 1
        )
        let scale = max(minimumScale, projectedScale)
        let transform = CGAffineTransform(translationX: anchor.x, y: anchor.y)
            .scaledBy(x: scale, y: scale)
            .translatedBy(x: -anchor.x, y: -anchor.y)
        return transformedBounds(bounds, applying: transform)
    }

    private func transform(from source: CGRect, to destination: CGRect) -> CGAffineTransform {
        let scaleX = source.width > 0 ? destination.width / source.width : 1
        let scaleY = source.height > 0 ? destination.height / source.height : 1
        return CGAffineTransform(
            a: scaleX,
            b: 0,
            c: 0,
            d: scaleY,
            tx: destination.minX - source.minX * scaleX,
            ty: destination.minY - source.minY * scaleY
        )
    }

    private func oppositeHandle(
        to handle: AnnotationSelectionHandleKind
    ) -> AnnotationSelectionHandleKind? {
        switch handle {
        case .topLeading: .bottomTrailing
        case .top: .bottom
        case .topTrailing: .bottomLeading
        case .trailing: .leading
        case .bottomTrailing: .topLeading
        case .bottom: .top
        case .bottomLeading: .topTrailing
        case .leading: .trailing
        case .rotation: nil
        }
    }

    private func selectionAnchor(
        in bounds: CGRect,
        handle: AnnotationSelectionHandleKind?
    ) -> CGPoint {
        guard let handle else { return bounds.center }
        return switch handle {
        case .topLeading: CGPoint(x: bounds.minX, y: bounds.minY)
        case .top: CGPoint(x: bounds.midX, y: bounds.minY)
        case .topTrailing: CGPoint(x: bounds.maxX, y: bounds.minY)
        case .trailing: CGPoint(x: bounds.maxX, y: bounds.midY)
        case .bottomTrailing: CGPoint(x: bounds.maxX, y: bounds.maxY)
        case .bottom: CGPoint(x: bounds.midX, y: bounds.maxY)
        case .bottomLeading: CGPoint(x: bounds.minX, y: bounds.maxY)
        case .leading: CGPoint(x: bounds.minX, y: bounds.midY)
        case .rotation: bounds.center
        }
    }

    private func rotationTransform(angle: CGFloat, around center: CGPoint) -> CGAffineTransform {
        CGAffineTransform(translationX: center.x, y: center.y)
            .rotated(by: angle)
            .translatedBy(x: -center.x, y: -center.y)
    }

    private func elementsByID(
        _ elementIDs: Set<AnnotationElementID>
    ) -> [AnnotationElementID: AnnotationElement] {
        Dictionary(
            uniqueKeysWithValues: scene.elements
                .filter { elementIDs.contains($0.id) }
                .map { ($0.id, $0) }
        )
    }

    private func selectionBounds(of elements: [AnnotationElement]) -> CGRect? {
        guard let first = elements.first else { return nil }
        let bounds = elements.dropFirst().reduce(
            AnnotationGeometry.worldBounds(of: first, includingStroke: false)
        ) { partial, element in
            partial.union(AnnotationGeometry.worldBounds(of: element, includingStroke: false))
        }
        return bounds.isNull ? nil : bounds
    }

    private func rect(from start: CGPoint, to end: CGPoint) -> CGRect {
        CGRect(
            x: min(start.x, end.x),
            y: min(start.y, end.y),
            width: abs(end.x - start.x),
            height: abs(end.y - start.y)
        )
    }

    private func transformedBounds(
        _ bounds: CGRect,
        applying transform: CGAffineTransform
    ) -> CGRect {
        let corners = AnnotationGeometry.rectCorners(bounds).map { $0.applying(transform) }
        guard let first = corners.first else { return .zero }
        return corners.dropFirst().reduce(CGRect(origin: first, size: .zero)) { partial, point in
            partial.union(CGRect(origin: point, size: .zero))
        }
    }

    private func angle(from start: CGPoint, to end: CGPoint) -> CGFloat {
        atan2(end.y - start.y, end.x - start.x)
    }
}

private func + (lhs: CGPoint, rhs: CGPoint) -> CGPoint {
    CGPoint(x: lhs.x + rhs.x, y: lhs.y + rhs.y)
}

private func - (lhs: CGPoint, rhs: CGPoint) -> CGPoint {
    CGPoint(x: lhs.x - rhs.x, y: lhs.y - rhs.y)
}

private extension CGRect {
    var center: CGPoint {
        CGPoint(x: midX, y: midY)
    }
}
