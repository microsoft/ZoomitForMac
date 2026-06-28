import AppKit

@MainActor
final class AnnotationController {
    var currentTool: AnnotationTool = .pen
    var currentStyle: AnnotationStyle = .default

    // Typing mode state, mirroring ZoomIt's font scaling and justification.
    static let defaultFontSize: CGFloat = 36
    var typingFontSize: CGFloat = AnnotationController.defaultFontSize
    var typingRightAligned: Bool = false
    /// PostScript/font family name used for typing mode. Empty means the
    /// system font, matching the default appearance.
    var typingFontName: String = ""

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

    /// Builds the typing-mode font for the given name and size, falling back to
    /// the semibold system font when no custom font is configured or available.
    static func typingFont(named name: String, size: CGFloat) -> NSFont {
        if !name.isEmpty, let font = NSFont(name: name, size: size) {
            return font
        }
        return NSFont.systemFont(ofSize: size, weight: .semibold)
    }

    func reset() {
        annotations.removeAll()
        inProgress = nil
        textAnnotationIndex = nil
        insertionPoint = CGPoint(x: 120, y: 120)
        currentTool = .pen
        currentStyle = .default
        typingFontSize = AnnotationController.defaultFontSize
        typingRightAligned = false
    }

    func setInsertionPoint(_ point: CGPoint) {
        insertionPoint = point
        textAnnotationIndex = nil
    }

    /// Starts a fresh typing session, matching ZoomIt's behaviour when entering
    /// type mode (T enters left-justified, Shift+T right-justified).
    func beginTypingSession(rightAligned: Bool) {
        typingRightAligned = rightAligned
        textAnnotationIndex = nil
    }

    func increaseFontSize() {
        setTypingFontSize(typingFontSize * 1.1)
    }

    func decreaseFontSize() {
        setTypingFontSize(typingFontSize / 1.1)
    }

    private func setTypingFontSize(_ size: CGFloat) {
        typingFontSize = min(max(size, 10), 600)
        // Live-resize the text currently being typed, like ZoomIt.
        if let textAnnotationIndex, annotations.indices.contains(textAnnotationIndex),
           annotations[textAnnotationIndex].tool == .text {
            annotations[textAnnotationIndex].fontSize = typingFontSize
        }
    }

    /// Whether the typing caret is locked in place. ZoomIt lets the caret
    /// follow the mouse until the first character is typed, then locks it.
    var isTypingLocked: Bool {
        if let textAnnotationIndex, annotations.indices.contains(textAnnotationIndex),
           annotations[textAnnotationIndex].tool == .text {
            return true
        }
        return false
    }

    /// Returns the caret origin (top) and height in content space for the text
    /// currently being typed, or the insertion point when no text exists yet.
    func typingCaret() -> (origin: CGPoint, height: CGFloat)? {
        let activeAnnotation: Annotation?
        if let textAnnotationIndex, annotations.indices.contains(textAnnotationIndex),
           annotations[textAnnotationIndex].tool == .text {
            activeAnnotation = annotations[textAnnotationIndex]
        } else {
            activeAnnotation = nil
        }

        let fontSize = activeAnnotation?.fontSize ?? typingFontSize
        let fontName = activeAnnotation?.fontName ?? typingFontName
        let font = Self.typingFont(named: fontName, size: fontSize)
        let lineHeight = font.ascender - font.descender + font.leading

        guard let annotation = activeAnnotation, let point = annotation.points.first else {
            return (insertionPoint, lineHeight)
        }

        let lines = annotation.text.components(separatedBy: "\n")
        let lastLine = lines.last ?? ""
        let lastWidth = NSString(string: lastLine).size(withAttributes: [.font: font]).width
        let y = point.y + CGFloat(lines.count - 1) * lineHeight
        // Right-justified text grows to the left, so the caret stays at the
        // insertion point's x; left-justified text trails the last line.
        let x = annotation.rightAligned ? point.x : point.x + lastWidth
        return (CGPoint(x: x, y: y), lineHeight)
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

        let annotation = Annotation(tool: .text, points: [insertionPoint], style: currentStyle, text: text, fontSize: typingFontSize, fontName: typingFontName, rightAligned: typingRightAligned)
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
            // Only draw the arrowhead once the mouse has actually moved, so the
            // direction of the arrow is unambiguous; before then show a plain
            // line (the shaft) without a tip.
            let hasMoved = annotation.points.count >= 2 && (last.x != first.x || last.y != first.y)
            if annotation.tool == .arrow && hasMoved {
                // The arrowhead sits at the moving end and points in the
                // direction of the line as measured from the start point.
                drawArrow(tail: first, tip: last, width: annotation.style.rootWidth, color: color, in: context)
            } else {
                context.move(to: first)
                context.addLine(to: last)
                context.strokePath()
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

        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = annotation.rightAligned ? .right : .left
        let attributes: [NSAttributedString.Key: Any] = [
            .font: Self.typingFont(named: annotation.fontName, size: annotation.fontSize),
            .foregroundColor: annotation.style.color.nsColor.withAlphaComponent(annotation.style.alpha),
            .paragraphStyle: paragraph
        ]
        let string = NSString(string: annotation.text)
        if annotation.rightAligned {
            // Anchor the right edge of the text at the insertion point so the
            // text grows to the left as ZoomIt's right-justified mode does.
            let size = string.size(withAttributes: attributes)
            let rect = CGRect(x: point.x - size.width, y: point.y, width: size.width, height: size.height)
            string.draw(in: rect, withAttributes: attributes)
        } else {
            string.draw(at: point, withAttributes: attributes)
        }
    }

    private func drawArrow(tail: CGPoint, tip: CGPoint, width: CGFloat, color: NSColor, in context: CGContext) {
        let dx = tip.x - tail.x
        let dy = tip.y - tail.y
        let length = hypot(dx, dy)
        let ux: CGFloat = length > 0 ? dx / length : 1
        let uy: CGFloat = length > 0 ? dy / length : 0

        // Slightly larger than ZoomIt's head (penWidth * 2.5 / 1.5) for a more
        // visible arrowhead.
        let headLength = width * 3.5
        let headHalfWidth = width * 2.0

        // Base midpoint, backed off from the tip along the shaft.
        let baseX = tip.x - ux * headLength
        let baseY = tip.y - uy * headLength
        // Wings perpendicular to the shaft.
        let left = CGPoint(x: baseX - uy * headHalfWidth, y: baseY + ux * headHalfWidth)
        let right = CGPoint(x: baseX + uy * headHalfWidth, y: baseY - ux * headHalfWidth)
        // Indented base center for a concave (nicer) arrowhead.
        let mid = CGPoint(x: tip.x - ux * headLength / 2, y: tip.y - uy * headLength / 2)

        // Shaft runs from the tail to the indented base of the head.
        context.move(to: tail)
        context.addLine(to: mid)
        context.strokePath()

        // Filled arrowhead: tip -> left wing -> indented mid -> right wing.
        context.setFillColor(color.cgColor)
        context.beginPath()
        context.move(to: tip)
        context.addLine(to: left)
        context.addLine(to: mid)
        context.addLine(to: right)
        context.closePath()
        context.fillPath()
    }
}