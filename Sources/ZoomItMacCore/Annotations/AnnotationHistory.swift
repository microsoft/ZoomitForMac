struct AnnotationSceneSnapshot: Equatable {
    var elements: [AnnotationElement]
}

struct AnnotationHistory {
    private let capacity: Int
    private var undoStack: [AnnotationSceneSnapshot] = []
    private var redoStack: [AnnotationSceneSnapshot] = []

    init(capacity: Int = 100) {
        self.capacity = max(1, capacity)
    }

    var canUndo: Bool {
        !undoStack.isEmpty
    }

    var canRedo: Bool {
        !redoStack.isEmpty
    }

    mutating func record(previous: AnnotationSceneSnapshot, current: AnnotationSceneSnapshot) {
        guard previous != current else { return }
        undoStack.append(previous)
        if undoStack.count > capacity {
            undoStack.removeFirst(undoStack.count - capacity)
        }
        redoStack.removeAll()
    }

    mutating func undo(current: AnnotationSceneSnapshot) -> AnnotationSceneSnapshot? {
        guard let previous = undoStack.popLast() else { return nil }
        redoStack.append(current)
        return previous
    }

    mutating func redo(current: AnnotationSceneSnapshot) -> AnnotationSceneSnapshot? {
        guard let next = redoStack.popLast() else { return nil }
        undoStack.append(current)
        return next
    }

    mutating func removeAll() {
        undoStack.removeAll()
        redoStack.removeAll()
    }
}
