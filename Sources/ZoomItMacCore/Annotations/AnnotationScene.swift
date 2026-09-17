import Foundation

struct AnnotationSelection: Equatable {
    private(set) var elementIDs: Set<AnnotationElementID> = []

    var isEmpty: Bool {
        elementIDs.isEmpty
    }

    func contains(_ elementID: AnnotationElementID) -> Bool {
        elementIDs.contains(elementID)
    }

    mutating func replace(with elementIDs: Set<AnnotationElementID>) {
        self.elementIDs = elementIDs
    }
}

@MainActor
final class AnnotationScene {
    private struct ActiveTransaction {
        var previous: AnnotationSceneSnapshot
        var depth: Int
    }

    private(set) var elements: [AnnotationElement]
    private(set) var selection = AnnotationSelection()
    var currentTool: AnnotationTool {
        didSet { notifyChange() }
    }
    var currentStyle: AnnotationStyle {
        didSet { notifyChange() }
    }
    var onChange: (() -> Void)?

    private var history: AnnotationHistory
    private var activeTransaction: ActiveTransaction?

    init(
        elements: [AnnotationElement] = [],
        currentTool: AnnotationTool = .pen,
        currentStyle: AnnotationStyle = .default
    ) {
        self.elements = elements
        self.currentTool = currentTool
        self.currentStyle = currentStyle
        history = AnnotationHistory()

        sanitizeBindings()
        refreshLinearGeometry(affectedBy: nil, previousElements: [])
    }

    var snapshot: AnnotationSceneSnapshot {
        AnnotationSceneSnapshot(elements: elements)
    }

    var canUndo: Bool {
        history.canUndo
    }

    var canRedo: Bool {
        history.canRedo
    }

    func element(withID elementID: AnnotationElementID) -> AnnotationElement? {
        elements.first { $0.id == elementID }
    }

    func reset() {
        elements.removeAll()
        selection = AnnotationSelection()
        currentTool = .pen
        currentStyle = .default
        activeTransaction = nil
        history.removeAll()
        notifyChange()
    }

    func beginTransaction() {
        if activeTransaction == nil {
            activeTransaction = ActiveTransaction(previous: snapshot, depth: 1)
        } else {
            activeTransaction?.depth += 1
        }
    }

    func commitTransaction() {
        guard var transaction = activeTransaction else { return }
        transaction.depth -= 1
        guard transaction.depth == 0 else {
            activeTransaction = transaction
            return
        }

        activeTransaction = nil

        sanitizeBindings()
        sanitizeSelection()
        history.record(previous: transaction.previous, current: snapshot)
        notifyChange()
    }

    func cancelTransaction() {
        guard let transaction = activeTransaction else { return }
        activeTransaction = nil
        restore(transaction.previous)
        notifyChange()
    }

    @discardableResult
    func append(_ element: AnnotationElement) -> AnnotationElementID {
        performMutation(affectedElementIDs: [element.id]) {
            elements.append(element)
        }
        return element.id
    }

    func append(_ newElements: [AnnotationElement]) {
        let elementIDs = Set(newElements.map(\.id))
        performMutation(affectedElementIDs: elementIDs) {
            elements.append(contentsOf: newElements)
        }
    }

    @discardableResult
    func insert(_ element: AnnotationElement, at index: Int) -> AnnotationElementID {
        performMutation(affectedElementIDs: [element.id]) {
            elements.insert(element, at: min(max(index, 0), elements.count))
        }
        return element.id
    }

    func updateElement(
        withID elementID: AnnotationElementID,
        recordHistory: Bool = true,
        _ update: (inout AnnotationElement) -> Void
    ) {
        if recordHistory {
            performMutation(affectedElementIDs: [elementID]) {
                guard let index = elements.firstIndex(where: { $0.id == elementID }) else { return }
                update(&elements[index])
            }
        } else {
            let previousElements = elements
            guard let index = elements.firstIndex(where: { $0.id == elementID }) else { return }
            update(&elements[index])

            sanitizeBindings()
            refreshLinearGeometry(
                affectedBy: [elementID],
                previousElements: previousElements
            )
            sanitizeSelection()
            notifyChange()
        }
    }

    func updateElements(
        withIDs elementIDs: Set<AnnotationElementID>,
        recordHistory: Bool = true,
        _ update: (inout AnnotationElement) -> Void
    ) {
        guard !elementIDs.isEmpty else { return }
        if recordHistory {
            performMutation(affectedElementIDs: elementIDs) {
                for index in elements.indices where elementIDs.contains(elements[index].id) {
                    update(&elements[index])
                }
            }
        } else {
            let previousElements = elements
            for index in elements.indices where elementIDs.contains(elements[index].id) {
                update(&elements[index])
            }

            sanitizeBindings()
            refreshLinearGeometry(
                affectedBy: elementIDs,
                previousElements: previousElements
            )
            sanitizeSelection()
            notifyChange()
        }
    }

    func removeElements(withIDs elementIDs: Set<AnnotationElementID>) {
        performMutation(affectedElementIDs: elementIDs) {
            elements.removeAll { elementIDs.contains($0.id) }
        }
    }

    func clear() {
        let removedIDs = Set(elements.map(\.id))
        performMutation(affectedElementIDs: removedIDs) {
            elements.removeAll()
        }
    }

    func moveElements(withIDs elementIDs: Set<AnnotationElementID>, to index: Int) {
        performMutation(affectedElementIDs: []) {
            let moving = elements.filter { elementIDs.contains($0.id) }
            guard !moving.isEmpty else { return }
            elements.removeAll { elementIDs.contains($0.id) }
            elements.insert(contentsOf: moving, at: min(max(index, 0), elements.count))
        }
    }

    func setElementOrder(_ orderedElementIDs: [AnnotationElementID]) {
        let existingIDs = Set(elements.map(\.id))
        guard orderedElementIDs.count == elements.count,
              Set(orderedElementIDs) == existingIDs else {
            return
        }
        performMutation(affectedElementIDs: []) {
            let elementsByID = Dictionary(uniqueKeysWithValues: elements.map { ($0.id, $0) })
            elements = orderedElementIDs.compactMap { elementsByID[$0] }
        }
    }

    @discardableResult
    func groupElements(withIDs elementIDs: Set<AnnotationElementID>) -> AnnotationGroupID? {
        guard elements.filter({ elementIDs.contains($0.id) }).count >= 2 else { return nil }
        let groupID = AnnotationGroupID()
        performMutation(affectedElementIDs: []) {
            for index in elements.indices where elementIDs.contains(elements[index].id) {
                elements[index].metadata.groupIDs.append(groupID)
            }
        }
        return groupID
    }

    func ungroupElements(withIDs elementIDs: Set<AnnotationElementID>, groupID: AnnotationGroupID) {
        performMutation(affectedElementIDs: []) {
            for index in elements.indices where elementIDs.contains(elements[index].id) {
                elements[index].metadata.groupIDs.removeAll { $0 == groupID }
            }
        }
    }

    func setLocked(_ isLocked: Bool, for elementIDs: Set<AnnotationElementID>) {
        performMutation(affectedElementIDs: []) {
            for index in elements.indices where elementIDs.contains(elements[index].id) {
                elements[index].metadata.isLocked = isLocked
            }
        }
    }

    func bindLinearEndpoint(
        elementID: AnnotationElementID,
        atStart: Bool,
        to binding: AnnotationBinding?
    ) {
        performMutation(affectedElementIDs: [elementID]) {
            guard let index = elements.firstIndex(where: { $0.id == elementID }),
                  case .linear(var linear) = elements[index].geometry else {
                return
            }
            if atStart {
                linear.startBinding = binding
            } else {
                linear.endBinding = binding
            }
            elements[index].geometry = .linear(linear)
        }
    }

    func unbindLinearEndpoints(
        elementID: AnnotationElementID,
        start: Bool = true,
        end: Bool = true
    ) {
        performMutation(affectedElementIDs: [elementID]) {
            guard let index = elements.firstIndex(where: { $0.id == elementID }),
                  case .linear(var linear) = elements[index].geometry else {
                return
            }
            if start {
                linear.startBinding = nil
            }
            if end {
                linear.endBinding = nil
            }
            elements[index].geometry = .linear(linear)
        }
    }

    func select(_ elementIDs: Set<AnnotationElementID>) {
        let existingIDs = Set(elements.map(\.id))
        selection.replace(with: elementIDs.intersection(existingIDs))
        notifyChange()
    }

    @discardableResult
    func undo() -> Bool {
        finishActiveTransaction()
        guard let previous = history.undo(current: snapshot) else { return false }
        restore(previous)
        notifyChange()
        return true
    }

    @discardableResult
    func redo() -> Bool {
        finishActiveTransaction()
        guard let next = history.redo(current: snapshot) else { return false }
        restore(next)
        notifyChange()
        return true
    }

    private func performMutation(
        affectedElementIDs: Set<AnnotationElementID>?,
        _ mutation: () -> Void
    ) {
        let previousElements = elements
        if activeTransaction != nil {
            mutation()

            sanitizeBindings()
            refreshLinearGeometry(
                affectedBy: affectedElementIDs,
                previousElements: previousElements
            )
            sanitizeSelection()
            notifyChange()
            return
        }

        let previous = snapshot
        mutation()

        sanitizeBindings()
        refreshLinearGeometry(
            affectedBy: affectedElementIDs,
            previousElements: previousElements
        )
        sanitizeSelection()
        history.record(previous: previous, current: snapshot)
        notifyChange()
    }

    private func finishActiveTransaction() {
        guard activeTransaction != nil else { return }
        activeTransaction?.depth = 1
        commitTransaction()
    }

    private func restore(_ snapshot: AnnotationSceneSnapshot) {
        elements = snapshot.elements

        sanitizeBindings()
        refreshLinearGeometry(affectedBy: nil, previousElements: [])
        let existingIDs = Set(elements.map(\.id))
        selection.replace(with: selection.elementIDs.intersection(existingIDs))
    }

    private func notifyChange() {
        onChange?()
    }

    private func sanitizeBindings() {
        let bindableIDs = Set(elements.compactMap { element -> AnnotationElementID? in
            guard case .shape = element.geometry else { return nil }
            return element.id
        })

        for index in elements.indices {
            guard case .linear(var linear) = elements[index].geometry else { continue }
            if let binding = linear.startBinding,
               binding.targetElementID == elements[index].id || !bindableIDs.contains(binding.targetElementID) {
                linear.startBinding = nil
            }
            if let binding = linear.endBinding,
               binding.targetElementID == elements[index].id || !bindableIDs.contains(binding.targetElementID) {
                linear.endBinding = nil
            }
            elements[index].geometry = .linear(linear)
        }
    }

    private func refreshLinearGeometry(
        affectedBy changedElementIDs: Set<AnnotationElementID>?,
        previousElements: [AnnotationElement]
    ) {
        if changedElementIDs?.isEmpty == true {
            return
        }
        let shapeElements = elements.filter {
            if case .shape = $0.geometry {
                return $0.metadata.isVisible
            }
            return false
        }
        let shapesByID = Dictionary(uniqueKeysWithValues: shapeElements.map { ($0.id, $0) })
        let previousByID = Dictionary(uniqueKeysWithValues: previousElements.map { ($0.id, $0) })
        let bindingChangedIDs = changedElementIDs.map { changedIDs in
            Set(changedIDs.filter { elementID in
                bindingGeometryChanged(
                    from: previousByID[elementID],
                    to: element(withID: elementID)
                )
            })
        }
        if bindingChangedIDs?.isEmpty == true {
            return
        }

        for index in elements.indices {
            guard case .linear(var linear) = elements[index].geometry,
                  !linear.points.isEmpty else {
                continue
            }
            let elementID = elements[index].id
            let previousLinear: AnnotationLinearGeometry? = {
                guard let previous = previousByID[elementID],
                      case .linear(let geometry) = previous.geometry else {
                    return nil
                }
                return geometry
            }()
            let boundTargetIDs = Set(
                [
                    linear.startBinding?.targetElementID,
                    linear.endBinding?.targetElementID,
                    previousLinear?.startBinding?.targetElementID,
                    previousLinear?.endBinding?.targetElementID
                ].compactMap { $0 }
            )
            let refreshEndpoints = bindingChangedIDs == nil
                || bindingChangedIDs?.contains(elementID) == true
                || bindingChangedIDs?.isDisjoint(with: boundTargetIDs) == false
            guard refreshEndpoints else { continue }
            let originalPoints = linear.points
            if elements[index].metadata.rotation == 0 {
                linear.rotationPivot = nil
            } else if linear.rotationPivot == nil {
                let bounds = AnnotationGeometry.localBounds(of: elements[index])
                linear.rotationPivot = CGPoint(x: bounds.midX, y: bounds.midY)
            }
            var transformElement = elements[index]
            transformElement.geometry = .linear(linear)
            let linearTransform = AnnotationGeometry.worldTransform(for: transformElement)
            let inverseLinearTransform = linearTransform.inverted()

            if let binding = linear.startBinding,
               let target = shapesByID[binding.targetElementID] {
                let neighbor = linear.points.count > 1 ? linear.points[1] : linear.points[0]
                let worldNeighbor = neighbor.applying(linearTransform)
                if let worldPoint = AnnotationGeometry.bindingPoint(
                    for: binding,
                    on: target,
                    toward: worldNeighbor
                ) {
                    linear.points[0] = worldPoint.applying(inverseLinearTransform)
                }
            }
            if let binding = linear.endBinding,
               let target = shapesByID[binding.targetElementID] {
                let neighborIndex = max(0, linear.points.count - 2)
                let worldNeighbor = linear.points[neighborIndex].applying(linearTransform)
                if let worldPoint = AnnotationGeometry.bindingPoint(
                    for: binding,
                    on: target,
                    toward: worldNeighbor
                ) {
                    linear.points[linear.points.count - 1] =
                        worldPoint.applying(inverseLinearTransform)
                }
            }
            updateCurvedEndpointControls(
                &linear,
                oldStart: originalPoints.first,
                oldEnd: originalPoints.last
            )
            elements[index].geometry = .linear(linear)
        }
    }

    private func bindingGeometryChanged(
        from previous: AnnotationElement?,
        to current: AnnotationElement?
    ) -> Bool {
        guard let previous, let current else {
            return isBindingRelevant(previous) || isBindingRelevant(current)
        }
        guard isBindingRelevant(previous) || isBindingRelevant(current) else {
            return false
        }
        if previous.metadata.rotation != current.metadata.rotation
            || previous.metadata.isVisible != current.metadata.isVisible {
            return true
        }

        switch (previous.geometry, current.geometry) {
        case (.shape(let previousShape), .shape(let currentShape)):
            return previousShape != currentShape
        case (.linear(let previousLinear), .linear(let currentLinear)):
            return linearBindingGeometryChanged(
                from: previousLinear,
                to: currentLinear
            )
        default:
            return previous.geometry != current.geometry
        }
    }

    private func isBindingRelevant(_ element: AnnotationElement?) -> Bool {
        guard let element else { return false }
        return switch element.geometry {
        case .shape, .linear:
            true
        case .freehand, .text:
            false
        }
    }

    private func linearBindingGeometryChanged(
        from previous: AnnotationLinearGeometry,
        to current: AnnotationLinearGeometry
    ) -> Bool {
        previous.points != current.points
            || previous.route != current.route
            || previous.startBinding != current.startBinding
            || previous.endBinding != current.endBinding
            || previous.rotationPivot != current.rotationPivot
    }

    private func updateCurvedEndpointControls(
        _ linear: inout AnnotationLinearGeometry,
        oldStart: CGPoint?,
        oldEnd: CGPoint?
    ) {
        guard linear.route == .curved,
              linear.bezierControls.count == linear.points.count - 1,
              let oldStart,
              let oldEnd,
              let newStart = linear.points.first,
              let newEnd = linear.points.last else {
            return
        }
        let startDelta = newStart - oldStart
        let endDelta = newEnd - oldEnd
        linear.bezierControls[0].start = linear.bezierControls[0].start + startDelta
        linear.bezierControls[linear.bezierControls.count - 1].end =
            linear.bezierControls[linear.bezierControls.count - 1].end + endDelta
    }

    private func sanitizeSelection() {
        let existingIDs = Set(elements.map(\.id))
        selection.replace(with: selection.elementIDs.intersection(existingIDs))
    }

}

private func + (lhs: CGPoint, rhs: CGPoint) -> CGPoint {
    CGPoint(x: lhs.x + rhs.x, y: lhs.y + rhs.y)
}

private func - (lhs: CGPoint, rhs: CGPoint) -> CGPoint {
    CGPoint(x: lhs.x - rhs.x, y: lhs.y - rhs.y)
}
