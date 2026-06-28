import AppKit

@MainActor
final class AnnotationController {
    var currentTool: AnnotationTool = .pen
    var currentStyle: AnnotationStyle = .default

    private var annotations: [Annotation] = []
    private var inProgress: Annotation?
    private var textAnnotationIndex: Int?
    private var insertionPoint: CGPoint = CGPoint(x: 120, y: 120)

    var annotationSnapshot: [Annotation] {
        annotations
    }

    var inProgressSnapshot: Annotation? {
        inProgress
    }

    func reset() {
        annotations.removeAll()
        inProgress = nil
        textAnnotationIndex = nil
        insertionPoint = CGPoint(x: 120, y: 120)
        currentTool = .pen
        currentStyle = .default
    }

    func setInsertionPoint(_ point: CGPoint) {
        insertionPoint = point
        textAnnotationIndex = nil
    }

    func begin(at point: CGPoint) {
        inProgress = Annotation(tool: currentTool, points: [point], style: currentStyle)
    }

    func begin(at point: CGPoint, tool: AnnotationTool) {
        inProgress = Annotation(tool: tool, points: [point], style: currentStyle)
    }

    func update(at point: CGPoint) {
        guard let tool = inProgress?.tool else { return }

        if tool == .pen || tool == .highlighter {
            inProgress?.points.append(point)
        } else if inProgress?.points.count == 1 {
            inProgress?.points.append(point)
        } else {
            inProgress?.points[1] = point
        }
    }

    func end(at point: CGPoint) {
        update(at: point)
        guard let annotation = inProgress else { return }
        annotations.append(annotation)
        inProgress = nil
    }

    func undo() {
        _ = annotations.popLast()
        textAnnotationIndex = nil
    }

    func clear() {
        annotations.removeAll()
        inProgress = nil
        textAnnotationIndex = nil
    }

    func insertText(_ text: String) {
        if let textAnnotationIndex, annotations.indices.contains(textAnnotationIndex), annotations[textAnnotationIndex].tool == .text {
            annotations[textAnnotationIndex].text.append(contentsOf: text)
            return
        }

        let annotation = Annotation(tool: .text, points: [insertionPoint], style: currentStyle, text: text)
        annotations.append(annotation)
        textAnnotationIndex = annotations.indices.last
    }

    func deleteBackward() {
        guard let textAnnotationIndex, annotations.indices.contains(textAnnotationIndex), annotations[textAnnotationIndex].tool == .text else {
            undo()
            return
        }

        if annotations[textAnnotationIndex].text.isEmpty {
            annotations.remove(at: textAnnotationIndex)
            self.textAnnotationIndex = nil
        } else {
            annotations[textAnnotationIndex].text.removeLast()
        }
    }

    func render(in context: CGContext, bounds: CGRect) {
        for annotation in annotations + Array(inProgress.map { [$0] } ?? []) {
            render(annotation, in: context)
        }
    }

    private func render(_ annotation: Annotation, in context: CGContext) {
        guard let first = annotation.points.first else { return }

        let color = annotation.style.color.nsColor.withAlphaComponent(annotation.tool == .highlighter ? 0.35 : annotation.style.alpha)
        context.setStrokeColor(color.cgColor)
        context.setFillColor(NSColor.clear.cgColor)
        context.setLineWidth(annotation.style.rootWidth)
        context.setLineCap(.round)
        context.setLineJoin(.round)

        switch annotation.tool {
        case .pen, .highlighter:
            let path = CGMutablePath()
            path.move(to: first)
            for point in annotation.points.dropFirst() {
                path.addLine(to: point)
            }
            context.addPath(path)
            context.strokePath()
        case .line, .arrow:
            guard let last = annotation.points.last else { return }
            context.move(to: first)
            context.addLine(to: last)
            context.strokePath()
            if annotation.tool == .arrow {
                drawArrowHead(from: first, to: last, width: annotation.style.rootWidth, color: color, in: context)
            }
        case .rectangle:
            guard let last = annotation.points.last else { return }
            context.stroke(CGRect(origin: first, size: CGSize(width: last.x - first.x, height: last.y - first.y)).standardized)
        case .ellipse:
            guard let last = annotation.points.last else { return }
            context.strokeEllipse(in: CGRect(origin: first, size: CGSize(width: last.x - first.x, height: last.y - first.y)).standardized)
        case .text:
            drawText(annotation)
        }
    }

    private func drawText(_ annotation: Annotation) {
        guard let point = annotation.points.first else { return }

        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: max(12, annotation.style.rootWidth * 5), weight: .semibold),
            .foregroundColor: annotation.style.color.nsColor.withAlphaComponent(annotation.style.alpha)
        ]
        NSString(string: annotation.text).draw(at: point, withAttributes: attributes)
    }

    private func drawArrowHead(from start: CGPoint, to end: CGPoint, width: CGFloat, color: NSColor, in context: CGContext) {
        let dx = end.x - start.x
        let dy = end.y - start.y
        let length = hypot(dx, dy)
        guard length > 0.1 else { return }

        let ux = dx / length
        let uy = dy / length
        let headLength = max(12, width * 3)
        let headWidth = max(8, width * 2.5)
        let baseX = end.x - ux * headLength
        let baseY = end.y - uy * headLength
        let perpX = -uy
        let perpY = ux
        let left = CGPoint(x: baseX + perpX * headWidth / 2, y: baseY + perpY * headWidth / 2)
        let right = CGPoint(x: baseX - perpX * headWidth / 2, y: baseY - perpY * headWidth / 2)

        context.setFillColor(color.cgColor)
        context.beginPath()
        context.move(to: end)
        context.addLine(to: left)
        context.addLine(to: right)
        context.closePath()
        context.fillPath()
    }
}