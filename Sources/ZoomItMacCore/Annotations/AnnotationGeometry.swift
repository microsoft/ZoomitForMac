import AppKit

struct AnnotationInteractionMetrics: Equatable {
    let zoomScale: CGFloat

    init(zoomScale: CGFloat) {
        self.zoomScale = max(zoomScale, 0.001)
    }

    var hitTolerance: CGFloat { 6 / zoomScale }
    var handleSize: CGFloat { 9 / zoomScale }
    var rotationHandleOffset: CGFloat { 24 / zoomScale }
    var decorationLineWidth: CGFloat { 1 / zoomScale }
}

enum AnnotationSelectionHandleKind: CaseIterable, Equatable {
    case topLeading
    case top
    case topTrailing
    case trailing
    case bottomTrailing
    case bottom
    case bottomLeading
    case leading
    case rotation
}

struct AnnotationSelectionHandle: Equatable {
    var kind: AnnotationSelectionHandleKind
    var center: CGPoint
    var bounds: CGRect
}

struct AnnotationSelectionDecoration: Equatable {
    var outline: [CGPoint]
    var rotationConnector: (start: CGPoint, end: CGPoint)
    var handles: [AnnotationSelectionHandle]

    static func == (lhs: AnnotationSelectionDecoration, rhs: AnnotationSelectionDecoration) -> Bool {
        lhs.outline == rhs.outline
            && lhs.rotationConnector.start == rhs.rotationConnector.start
            && lhs.rotationConnector.end == rhs.rotationConnector.end
            && lhs.handles == rhs.handles
    }
}

enum AnnotationLinearControlEnd: Equatable {
    case start
    case end
}

enum AnnotationLinearEditPart: Equatable {
    case point(Int)
    case segment(Int)
    case control(segment: Int, end: AnnotationLinearControlEnd)
}

struct AnnotationLinearLocation: Equatable {
    var segmentIndex: Int
    var parameter: CGFloat
    var point: CGPoint
    var distance: CGFloat
}

enum AnnotationSelectionPresentation {
    static func editableElements(
        from elements: [AnnotationElement],
        selectedElementIDs: Set<AnnotationElementID>
    ) -> [AnnotationElement] {
        elements.filter {
            selectedElementIDs.contains($0.id)
                && $0.metadata.isVisible
                && !$0.metadata.isLocked
        }
    }
}

@MainActor
enum AnnotationGeometry {
    static let maximumPressureInterpolationStepsPerSegment = 16
    static let maximumAdaptiveCubicSegmentsPerCurve = 2_048

    struct LinearApproximation {
        struct Segment {
            var start: CGPoint
            var end: CGPoint
            var segmentIndex: Int
            var lowerParameter: CGFloat
            var upperParameter: CGFloat
        }

        var segments: [Segment]
        var reachedSubdivisionLimit: Bool
        var operationCount: Int
    }

    private struct CubicSubdivision {
        var start: CGPoint
        var control1: CGPoint
        var control2: CGPoint
        var end: CGPoint
        var lowerParameter: CGFloat
        var upperParameter: CGFloat
        var depth: Int
    }

    static func localBounds(of element: AnnotationElement) -> CGRect {
        switch element.geometry {
        case .freehand(let freehand):
            return bounds(of: freehand.samples.map(\.location))
        case .shape(let shape):
            return shape.bounds
        case .linear(let linear):
            return linearBounds(linear, strokeWidth: element.style.strokeWidth)
        case .text(let text):
            return textBounds(text)
        }
    }

    static func worldBounds(of element: AnnotationElement, includingStroke: Bool = true) -> CGRect {
        let local = localBounds(of: element)
        guard !local.isNull else { return .null }

        let transform = worldTransform(for: element)
        let corners = rectCorners(local).map { $0.applying(transform) }
        var result = bounds(of: corners)
        if includingStroke, !result.isNull {
            let strokeWidth = max(0, maximumStrokeWidth(for: element))
            let inset = strokeWidth / 2
                + AnnotationRoughStroke.maximumDestinationDeviation(
                    for: element.effectiveSloppiness,
                    strokeWidth: strokeWidth
                )
            result = result.insetBy(dx: -inset, dy: -inset)
        }
        return result
    }

    static func worldTransform(for element: AnnotationElement) -> CGAffineTransform {
        guard element.metadata.rotation != 0 else { return .identity }
        return rotationTransform(
            angle: element.metadata.rotation,
            around: rotationPivot(for: element)
        )
    }

    static func rotationPivot(for element: AnnotationElement) -> CGPoint {
        if case .linear(let linear) = element.geometry, let rotationPivot = linear.rotationPivot {
            return rotationPivot
        }
        return localBounds(of: element).center
    }

    static func inverseWorldTransform(for element: AnnotationElement) -> CGAffineTransform {
        worldTransform(for: element).inverted()
    }

    static func shapePath(
        _ shape: AnnotationShapeGeometry,
        roundness: CGFloat? = nil
    ) -> CGPath {
        let path = CGMutablePath()
        let bounds = shape.bounds
        switch shape.kind {
        case .rectangle:
            if let roundness, roundness > 0 {
                path.addRoundedRect(
                    in: bounds,
                    cornerWidth: min(roundness, bounds.width / 2),
                    cornerHeight: min(roundness, bounds.height / 2)
                )
            } else {
                path.addRect(bounds)
            }
        case .diamond:
            let vertices = diamondVertices(in: bounds)
            if let roundness, roundness > 0 {
                addRoundedPolygon(
                    vertices,
                    radius: roundness,
                    to: path
                )
            } else {
                path.move(to: vertices[0])
                for vertex in vertices.dropFirst() {
                    path.addLine(to: vertex)
                }
                path.closeSubpath()
            }
        case .ellipse:
            path.addEllipse(in: bounds)
        }
        return path
    }

    static func shapeStrokePinnedPoints(
        _ shape: AnnotationShapeGeometry,
        roundness: CGFloat? = nil
    ) -> [CGPoint] {
        let bounds = shape.bounds
        switch shape.kind {
        case .rectangle:
            let radius = min(
                max(roundness ?? 0, 0),
                min(bounds.width, bounds.height) / 2
            )
            if radius > 0 {
                return [
                    CGPoint(x: bounds.minX + radius, y: bounds.minY),
                    CGPoint(x: bounds.maxX - radius, y: bounds.minY),
                    CGPoint(x: bounds.maxX, y: bounds.minY + radius),
                    CGPoint(x: bounds.maxX, y: bounds.maxY - radius),
                    CGPoint(x: bounds.maxX - radius, y: bounds.maxY),
                    CGPoint(x: bounds.minX + radius, y: bounds.maxY),
                    CGPoint(x: bounds.minX, y: bounds.maxY - radius),
                    CGPoint(x: bounds.minX, y: bounds.minY + radius)
                ]
            }
            return rectCorners(bounds)
        case .diamond:
            let vertices = diamondVertices(in: bounds)
            guard let roundness, roundness > 0 else {
                return vertices
            }
            return roundedPolygonTangentPoints(vertices, radius: roundness)
        case .ellipse:
            return []
        }
    }

    private static func diamondVertices(in bounds: CGRect) -> [CGPoint] {
        [
            CGPoint(x: bounds.midX, y: bounds.minY),
            CGPoint(x: bounds.maxX, y: bounds.midY),
            CGPoint(x: bounds.midX, y: bounds.maxY),
            CGPoint(x: bounds.minX, y: bounds.midY)
        ]
    }

    private static func roundedPolygonTangentPoints(
        _ vertices: [CGPoint],
        radius: CGFloat
    ) -> [CGPoint] {
        guard vertices.count > 2 else { return vertices }
        return vertices.indices.flatMap { index -> [CGPoint] in
            let previous = vertices[(index - 1 + vertices.count) % vertices.count]
            let vertex = vertices[index]
            let next = vertices[(index + 1) % vertices.count]
            let cornerRadius = min(
                max(radius, 0),
                min(distance(previous, vertex), distance(vertex, next)) / 2
            )
            return [
                point(from: vertex, toward: previous, distance: cornerRadius),
                point(from: vertex, toward: next, distance: cornerRadius)
            ]
        }
    }

    private static func addRoundedPolygon(
        _ vertices: [CGPoint],
        radius: CGFloat,
        to path: CGMutablePath
    ) {
        let tangentPoints = roundedPolygonTangentPoints(vertices, radius: radius)
        guard tangentPoints.count == vertices.count * 2 else { return }
        path.move(to: tangentPoints[0])
        for index in vertices.indices {
            let entry = tangentPoints[index * 2]
            let exit = tangentPoints[index * 2 + 1]
            if index > 0 {
                path.addLine(to: entry)
            }
            path.addQuadCurve(to: exit, control: vertices[index])
        }
        path.addLine(to: tangentPoints[0])
        path.closeSubpath()
    }

    private static func point(
        from start: CGPoint,
        toward end: CGPoint,
        distance: CGFloat
    ) -> CGPoint {
        let length = Self.distance(start, end)
        guard length > 0 else { return start }
        let scale = min(max(distance / length, 0), 1)
        return CGPoint(
            x: start.x + (end.x - start.x) * scale,
            y: start.y + (end.y - start.y) * scale
        )
    }

    private static func distance(_ lhs: CGPoint, _ rhs: CGPoint) -> CGFloat {
        hypot(rhs.x - lhs.x, rhs.y - lhs.y)
    }

    static func linearPath(_ linear: AnnotationLinearGeometry) -> CGPath {
        let path = CGMutablePath()
        guard let first = linear.points.first else { return path }
        path.move(to: first)
        switch linear.route {
        case .straight:
            for point in linear.points.dropFirst() {
                path.addLine(to: point)
            }
        case .curved:
            let controls = bezierControls(for: linear)
            for index in 0..<(linear.points.count - 1) {
                path.addCurve(
                    to: linear.points[index + 1],
                    control1: controls[index].start,
                    control2: controls[index].end
                )
            }
        }
        return path
    }

    static func bezierControls(for linear: AnnotationLinearGeometry) -> [AnnotationBezierControl] {
        guard linear.points.count > 1 else { return [] }
        if linear.bezierControls.count == linear.points.count - 1 {
            return linear.bezierControls
        }

        return (0..<(linear.points.count - 1)).map { index in
            let previous = linear.points[max(0, index - 1)]
            let start = linear.points[index]
            let end = linear.points[index + 1]
            let following = linear.points[min(linear.points.count - 1, index + 2)]
            return AnnotationBezierControl(
                start: start + (end - previous) / 6,
                end: end - (following - start) / 6
            )
        }
    }

    static func linearDisplayPoints(
        _ linear: AnnotationLinearGeometry,
        maximumError: CGFloat = 0.25,
        maximumSegmentsPerCurve: Int = maximumAdaptiveCubicSegmentsPerCurve
    ) -> [CGPoint] {
        guard let first = linear.points.first else { return [] }
        guard linear.points.count > 1 else { return [first] }
        guard linear.route == .curved else { return linear.points }

        var result = [first]
        for segment in linearApproximation(
            linear,
            maximumError: maximumError,
            maximumSegmentsPerCurve: maximumSegmentsPerCurve
        ).segments {
            result.append(segment.end)
        }
        return result
    }

    static func linearDisplayPoints(
        _ linear: AnnotationLinearGeometry,
        subdivisions: Int
    ) -> [CGPoint] {
        guard let first = linear.points.first else { return [] }
        guard linear.points.count > 1 else { return [first] }
        guard linear.route == .curved else { return linear.points }

        let controls = bezierControls(for: linear)
        let steps = max(2, subdivisions)
        var result = [first]
        for index in 0..<(linear.points.count - 1) {
            for step in 1...steps {
                result.append(
                    cubicPoint(
                        from: linear.points[index],
                        control1: controls[index].start,
                        control2: controls[index].end,
                        to: linear.points[index + 1],
                        t: CGFloat(step) / CGFloat(steps)
                    )
                )
            }
        }
        return result
    }

    static func linearApproximation(
        _ linear: AnnotationLinearGeometry,
        maximumError: CGFloat,
        maximumSegmentsPerCurve: Int = maximumAdaptiveCubicSegmentsPerCurve
    ) -> LinearApproximation {
        guard linear.points.count > 1 else {
            return LinearApproximation(
                segments: [],
                reachedSubdivisionLimit: false,
                operationCount: 0
            )
        }
        guard linear.route == .curved else {
            return LinearApproximation(
                segments: zip(
                    linear.points.indices,
                    linear.points.indices.dropFirst()
                ).map { indices in
                    LinearApproximation.Segment(
                        start: linear.points[indices.0],
                        end: linear.points[indices.1],
                        segmentIndex: indices.0,
                        lowerParameter: 0,
                        upperParameter: 1
                    )
                },
                reachedSubdivisionLimit: false,
                operationCount: linear.points.count - 1
            )
        }

        let controls = bezierControls(for: linear)
        var segments: [LinearApproximation.Segment] = []
        var reachedSubdivisionLimit = false
        var operationCount = 0
        for segmentIndex in 0..<(linear.points.count - 1) {
            let flattened = flattenedCubicSegments(
                from: linear.points[segmentIndex],
                control1: controls[segmentIndex].start,
                control2: controls[segmentIndex].end,
                to: linear.points[segmentIndex + 1],
                maximumError: maximumError,
                maximumSegments: maximumSegmentsPerCurve
            )
            segments.append(contentsOf: flattened.segments.map {
                LinearApproximation.Segment(
                    start: $0.start,
                    end: $0.end,
                    segmentIndex: segmentIndex,
                    lowerParameter: $0.lowerParameter,
                    upperParameter: $0.upperParameter
                )
            })
            reachedSubdivisionLimit =
                reachedSubdivisionLimit || flattened.reachedSubdivisionLimit
            operationCount += flattened.operationCount
        }
        return LinearApproximation(
            segments: segments,
            reachedSubdivisionLimit: reachedSubdivisionLimit,
            operationCount: operationCount
        )
    }

    static func closestLinearLocation(
        to point: CGPoint,
        linear: AnnotationLinearGeometry,
        maximumError: CGFloat = 0.25,
        maximumSegmentsPerCurve: Int = maximumAdaptiveCubicSegmentsPerCurve
    ) -> AnnotationLinearLocation? {
        guard linear.points.count > 1 else { return nil }
        var best: AnnotationLinearLocation?
        for segment in linearApproximation(
            linear,
            maximumError: maximumError,
            maximumSegmentsPerCurve: maximumSegmentsPerCurve
        ).segments {
            var location = closestLocation(
                to: point,
                from: segment.start,
                to: segment.end,
                segmentIndex: segment.segmentIndex
            )
            location.parameter = segment.lowerParameter
                + (segment.upperParameter - segment.lowerParameter)
                    * location.parameter
            if best == nil || location.distance < best!.distance {
                best = location
            }
        }
        return best
    }

    private static func flattenedCubicSegments(
        from start: CGPoint,
        control1: CGPoint,
        control2: CGPoint,
        to end: CGPoint,
        maximumError: CGFloat,
        maximumSegments: Int
    ) -> (
        segments: [CubicSubdivision],
        reachedSubdivisionLimit: Bool,
        operationCount: Int
    ) {
        let error = maximumError.isFinite ? max(0.000_001, maximumError) : 0.25
        let segmentLimit = max(1, maximumSegments)
        let maximumDepth = 24
        var stack = [
            CubicSubdivision(
                start: start,
                control1: control1,
                control2: control2,
                end: end,
                lowerParameter: 0,
                upperParameter: 1,
                depth: 0
            )
        ]
        var result: [CubicSubdivision] = []
        result.reserveCapacity(min(segmentLimit, 64))
        var reachedSubdivisionLimit = false
        var operationCount = 0

        while let cubic = stack.popLast() {
            operationCount += 1
            let isFlat = cubicFlatness(cubic) <= error
            let pendingLeafCount = result.count + stack.count + 1
            let mustStop = cubic.depth >= maximumDepth
                || pendingLeafCount >= segmentLimit
            if isFlat || mustStop {
                if !isFlat {
                    reachedSubdivisionLimit = true
                }
                result.append(cubic)
                continue
            }

            let startControlMidpoint = interpolate(
                cubic.start,
                cubic.control1,
                0.5
            )
            let controlMidpoint = interpolate(
                cubic.control1,
                cubic.control2,
                0.5
            )
            let endControlMidpoint = interpolate(
                cubic.control2,
                cubic.end,
                0.5
            )
            let leftControl = interpolate(
                startControlMidpoint,
                controlMidpoint,
                0.5
            )
            let rightControl = interpolate(
                controlMidpoint,
                endControlMidpoint,
                0.5
            )
            let midpoint = interpolate(leftControl, rightControl, 0.5)
            let parameterMidpoint =
                (cubic.lowerParameter + cubic.upperParameter) / 2

            stack.append(
                CubicSubdivision(
                    start: midpoint,
                    control1: rightControl,
                    control2: endControlMidpoint,
                    end: cubic.end,
                    lowerParameter: parameterMidpoint,
                    upperParameter: cubic.upperParameter,
                    depth: cubic.depth + 1
                )
            )
            stack.append(
                CubicSubdivision(
                    start: cubic.start,
                    control1: startControlMidpoint,
                    control2: leftControl,
                    end: midpoint,
                    lowerParameter: cubic.lowerParameter,
                    upperParameter: parameterMidpoint,
                    depth: cubic.depth + 1
                )
            )
        }

        return (result, reachedSubdivisionLimit, operationCount)
    }

    private static func cubicFlatness(_ cubic: CubicSubdivision) -> CGFloat {
        max(
            distance(
                from: cubic.control1,
                toSegmentFrom: cubic.start,
                to: cubic.end
            ),
            distance(
                from: cubic.control2,
                toSegmentFrom: cubic.start,
                to: cubic.end
            )
        )
    }

    static func insertingPoint(
        into linear: AnnotationLinearGeometry,
        at location: AnnotationLinearLocation
    ) -> AnnotationLinearGeometry {
        guard location.segmentIndex >= 0,
              location.segmentIndex < linear.points.count - 1 else {
            return linear
        }

        var result = linear
        let parameter = min(1, max(0, location.parameter))
        let segmentIndex = location.segmentIndex
        if linear.route == .curved {
            let controls = bezierControls(for: linear)
            let start = linear.points[segmentIndex]
            let control1 = controls[segmentIndex].start
            let control2 = controls[segmentIndex].end
            let end = linear.points[segmentIndex + 1]
            let first = interpolate(start, control1, parameter)
            let second = interpolate(control1, control2, parameter)
            let third = interpolate(control2, end, parameter)
            let fourth = interpolate(first, second, parameter)
            let fifth = interpolate(second, third, parameter)
            let inserted = interpolate(fourth, fifth, parameter)

            result.points.insert(inserted, at: segmentIndex + 1)
            var splitControls = controls
            splitControls[segmentIndex] = AnnotationBezierControl(start: first, end: fourth)
            splitControls.insert(
                AnnotationBezierControl(start: fifth, end: third),
                at: segmentIndex + 1
            )
            result.bezierControls = splitControls
        } else {
            result.points.insert(location.point, at: segmentIndex + 1)
            result.bezierControls = []
        }
        return result
    }

    static func removingLinearPoints(
        _ removedIndices: Set<Int>,
        from linear: AnnotationLinearGeometry
    ) -> AnnotationLinearGeometry {
        let remainingIndices = linear.points.indices.filter {
            !removedIndices.contains($0)
        }
        guard remainingIndices.count >= 2 else { return linear }

        var result = linear
        result.points = remainingIndices.map { linear.points[$0] }
        switch linear.route {
        case .straight:
            result.bezierControls = []
        case .curved:
            let controls = bezierControls(for: linear)
            result.bezierControls = zip(
                remainingIndices,
                remainingIndices.dropFirst()
            ).map { pair in
                let (startIndex, endIndex) = pair
                if endIndex == startIndex + 1 {
                    return controls[startIndex]
                }
                return AnnotationBezierControl(
                    start: controls[startIndex].start,
                    end: controls[endIndex - 1].end
                )
            }
        }
        return result
    }

    static func endpointAdjacentPoint(
        in linear: AnnotationLinearGeometry,
        atStart: Bool
    ) -> CGPoint? {
        guard linear.points.count > 1 else { return nil }
        if linear.route == .curved {
            let controls = bezierControls(for: linear)
            if atStart {
                let control = controls[0].start
                return control == linear.points[0] ? linear.points[1] : control
            }
            let control = controls[controls.count - 1].end
            return control == linear.points[linear.points.count - 1]
                ? linear.points[linear.points.count - 2]
                : control
        }
        return atStart ? linear.points[1] : linear.points[linear.points.count - 2]
    }

    static func smoothedFreehandPath(_ samples: [AnnotationPointSample]) -> CGPath {
        let path = CGMutablePath()
        let points = samples.map(\.location)
        guard let first = points.first else { return path }
        path.move(to: first)

        guard points.count > 1 else { return path }
        if points.count == 2 {
            path.addLine(to: points[1])
            return path
        }

        for index in 0..<(points.count - 1) {
            if let controls = freehandBezierControls(points, segmentIndex: index) {
                path.addCurve(
                    to: points[index + 1],
                    control1: controls.start,
                    control2: controls.end
                )
            } else {
                path.addLine(to: points[index + 1])
            }
        }
        return path
    }

    static func smoothedFreehandSamples(
        _ samples: [AnnotationPointSample],
        subdivisions: Int = 4
    ) -> [AnnotationPointSample] {
        guard samples.count > 1 else { return samples }
        let stepCount = max(1, subdivisions)
        var result = [samples[0]]
        let points = samples.map(\.location)

        for index in 0..<(samples.count - 1) {
            let current = samples[index]
            let next = samples[index + 1]
            let controls = freehandBezierControls(
                points,
                segmentIndex: index
            )

            for step in 1...stepCount {
                let t = CGFloat(step) / CGFloat(stepCount)
                let location = if let controls {
                    cubicPoint(
                        from: current.location,
                        control1: controls.start,
                        control2: controls.end,
                        to: next.location,
                        t: t
                    )
                } else {
                    CGPoint(
                        x: current.location.x
                            + (next.location.x - current.location.x) * t,
                        y: current.location.y
                            + (next.location.y - current.location.y) * t
                    )
                }
                result.append(
                    AnnotationPointSample(
                        location: location,
                        pressure: interpolatedPressure(
                            from: current.pressure,
                            to: next.pressure,
                            t: t
                        ),
                        timestamp: interpolatedTimestamp(
                            from: current.timestamp,
                            to: next.timestamp,
                            t: t
                        )
                    )
                )
            }
        }
        return result
    }

    private static func freehandBezierControls(
        _ points: [CGPoint],
        segmentIndex: Int
    ) -> AnnotationBezierControl? {
        let current = points[segmentIndex]
        let next = points[segmentIndex + 1]
        let previous = points[max(0, segmentIndex - 1)]
        let following = points[min(points.count - 1, segmentIndex + 2)]
        let segmentLength = distance(current, next)
        guard segmentLength > 0.000_1 else { return nil }
        if isSharpFreehandTurn(previous: previous, corner: current, next: next)
            || isSharpFreehandTurn(previous: current, corner: next, next: following) {
            return nil
        }
        let startDirection = freehandTangentDirection(
            previous: previous,
            current: current,
            next: next
        )
        let endDirection = freehandTangentDirection(
            previous: current,
            current: next,
            next: following
        )
        let startLength = min(
            segmentLength * 0.34,
            max(segmentLength * 0.12, distance(previous, current) * 0.28)
        )
        let endLength = min(
            segmentLength * 0.34,
            max(segmentLength * 0.12, distance(next, following) * 0.28)
        )
        return AnnotationBezierControl(
            start: clampedFreehandControl(
                current + startDirection * startLength,
                anchor: current,
                toward: next
            ),
            end: clampedFreehandControl(
                next - endDirection * endLength,
                anchor: next,
                toward: current
            )
        )
    }

    private static func freehandTangentDirection(
        previous: CGPoint,
        current: CGPoint,
        next: CGPoint
    ) -> CGPoint {
        let incoming = current - previous
        let outgoing = next - current
        let incomingLength = hypot(incoming.x, incoming.y)
        let outgoingLength = hypot(outgoing.x, outgoing.y)
        if incomingLength < 0.000_1 {
            return normalizedFreehandVector(outgoing)
        }
        if outgoingLength < 0.000_1 {
            return normalizedFreehandVector(incoming)
        }
        let weightedIncoming = incoming / sqrt(incomingLength)
        let weightedOutgoing = outgoing / sqrt(outgoingLength)
        return normalizedFreehandVector(weightedIncoming + weightedOutgoing)
    }

    private static func isSharpFreehandTurn(
        previous: CGPoint,
        corner: CGPoint,
        next: CGPoint
    ) -> Bool {
        let incoming = corner - previous
        let outgoing = next - corner
        let incomingLength = hypot(incoming.x, incoming.y)
        let outgoingLength = hypot(outgoing.x, outgoing.y)
        guard incomingLength > 0.000_1, outgoingLength > 0.000_1 else {
            return false
        }
        let cosine = (
            incoming.x * outgoing.x + incoming.y * outgoing.y
        ) / (incomingLength * outgoingLength)
        return cosine < 0.35
    }

    private static func clampedFreehandControl(
        _ control: CGPoint,
        anchor: CGPoint,
        toward endpoint: CGPoint
    ) -> CGPoint {
        let segment = endpoint - anchor
        let segmentLength = hypot(segment.x, segment.y)
        guard segmentLength > 0.000_1 else { return anchor }
        let direction = segment / segmentLength
        let delta = control - anchor
        let rawProjection = delta.x * direction.x + delta.y * direction.y
        let projection = min(segmentLength * 0.45, max(0, rawProjection))
        let perpendicular = delta - direction * rawProjection
        let perpendicularLength = hypot(perpendicular.x, perpendicular.y)
        let maximumPerpendicular = segmentLength * 0.2
        let clampedPerpendicular = if perpendicularLength > maximumPerpendicular {
            perpendicular * (maximumPerpendicular / perpendicularLength)
        } else {
            perpendicular
        }
        return anchor + direction * projection + clampedPerpendicular
    }

    private static func normalizedFreehandVector(_ vector: CGPoint) -> CGPoint {
        let length = hypot(vector.x, vector.y)
        guard length > 0.000_1 else { return .zero }
        return vector / length
    }

    static func pressureInterpolatedFreehandSamples(
        _ samples: [AnnotationPointSample],
        maximumPressureStep: CGFloat = 0.06,
        maximumDistance: CGFloat = 4
    ) -> [AnnotationPointSample] {
        guard samples.count > 1 else { return samples }
        let pressureStep = max(0.001, maximumPressureStep)
        let distanceStep = max(0.1, maximumDistance)
        var result = [samples[0]]

        for (current, next) in zip(samples, samples.dropFirst()) {
            let distance = hypot(
                next.location.x - current.location.x,
                next.location.y - current.location.y
            )
            let startPressure = current.pressure ?? 1
            let endPressure = next.pressure ?? 1
            let pressureDistance = abs(endPressure - startPressure)
            let stepCount = min(
                maximumPressureInterpolationStepsPerSegment,
                max(
                    1,
                    Int(
                        ceil(
                            max(
                                distance / distanceStep,
                                pressureDistance / pressureStep
                            )
                        )
                    )
                )
            )
            for step in 1...stepCount {
                let fraction = CGFloat(step) / CGFloat(stepCount)
                result.append(
                    AnnotationPointSample(
                        location: CGPoint(
                            x: current.location.x
                                + (next.location.x - current.location.x) * fraction,
                            y: current.location.y
                                + (next.location.y - current.location.y) * fraction
                        ),
                        pressure: interpolatedPressure(
                            from: current.pressure,
                            to: next.pressure,
                            t: fraction
                        ),
                        timestamp: interpolatedTimestamp(
                            from: current.timestamp,
                            to: next.timestamp,
                            t: fraction
                        )
                    )
                )
            }
        }
        return result
    }

    static func arrowheadPath(
        _ arrowhead: AnnotationArrowhead,
        tip: CGPoint,
        adjacent: CGPoint,
        strokeWidth: CGFloat,
        size: AnnotationArrowheadSize = .small
    ) -> CGPath? {
        guard arrowhead != .none else { return nil }
        let direction = unitVector(from: adjacent, to: tip)
        let perpendicular = CGPoint(x: -direction.y, y: direction.x)
        let metrics = arrowheadMetrics(
            strokeWidth: strokeWidth,
            size: size
        )
        let length = metrics.length
        let halfWidth = metrics.halfWidth
        let compoundSpacing = max(2, strokeWidth) * size.scale
        let base = tip - direction * length
        let left = base + perpendicular * halfWidth
        let right = base - perpendicular * halfWidth
        let path = CGMutablePath()

        switch arrowhead {
        case .none:
            return nil
        case .arrow:
            path.move(to: tip)
            path.addLine(to: left)
            path.move(to: tip)
            path.addLine(to: right)
        case .triangleOutline:
            path.move(to: tip)
            path.addLine(to: left)
            path.addLine(to: right)
            path.closeSubpath()
        case .triangle:
            path.move(to: tip)
            path.addLine(to: left)
            path.addLine(to: right)
            path.closeSubpath()
        case .circle, .circleOutline:
            let radius = halfWidth
            path.addEllipse(
                in: CGRect(
                    x: tip.x - direction.x * radius - radius,
                    y: tip.y - direction.y * radius - radius,
                    width: radius * 2,
                    height: radius * 2
                )
            )
        case .bar:
            path.move(to: tip + perpendicular * halfWidth)
            path.addLine(to: tip - perpendicular * halfWidth)
        case .diamond, .diamondOutline:
            let middle = tip - direction * (length / 2)
            path.move(to: tip)
            path.addLine(to: middle + perpendicular * halfWidth)
            path.addLine(to: tip - direction * length)
            path.addLine(to: middle - perpendicular * halfWidth)
            path.closeSubpath()
        case .crowFoot:
            addCrowFoot(
                to: path,
                apex: tip,
                direction: direction,
                perpendicular: perpendicular,
                length: length * 0.72,
                halfWidth: halfWidth
            )
        case .oneOrMany:
            let crowLength = length * 0.72
            let crowBase = tip - direction * crowLength
            let barCenter = tip - direction * (length * 0.92)
            addCrowFoot(
                to: path,
                apex: tip,
                direction: direction,
                perpendicular: perpendicular,
                length: crowLength,
                halfWidth: halfWidth
            )
            addArrowheadBar(
                to: path,
                center: barCenter,
                perpendicular: perpendicular,
                halfWidth: halfWidth
            )
            path.move(to: barCenter)
            path.addLine(to: crowBase)
        case .zeroOrOne:
            let radius = halfWidth * 0.72
            let center = tip - direction * radius
            let circleRear = tip - direction * (radius * 2)
            let barCenter = tip - direction * (radius * 2 + compoundSpacing)
            path.addEllipse(
                in: CGRect(
                    x: center.x - radius,
                    y: center.y - radius,
                    width: radius * 2,
                    height: radius * 2
                )
            )
            addArrowheadBar(
                to: path,
                center: barCenter,
                perpendicular: perpendicular,
                halfWidth: halfWidth
            )
            path.move(to: circleRear)
            path.addLine(to: barCenter)
        case .zeroOrMany:
            let radius = halfWidth * 0.72
            let center = tip - direction * radius
            let circleRear = tip - direction * (radius * 2)
            let crowApex = tip - direction * (radius * 2 + compoundSpacing)
            path.addEllipse(
                in: CGRect(
                    x: center.x - radius,
                    y: center.y - radius,
                    width: radius * 2,
                    height: radius * 2
                )
            )
            addCrowFoot(
                to: path,
                apex: crowApex,
                direction: direction,
                perpendicular: perpendicular,
                length: length * 0.68,
                halfWidth: halfWidth
            )
            path.move(to: circleRear)
            path.addLine(to: crowApex)
        }
        return path
    }

    static func arrowheadMetrics(
        strokeWidth: CGFloat,
        size: AnnotationArrowheadSize = .small
    ) -> (length: CGFloat, halfWidth: CGFloat) {
        let width = max(0.1, strokeWidth)
        let scale = size.scale
        return (
            length: max(23, width * 3) * scale,
            halfWidth: max(13.5, width * 2) * scale
        )
    }

    static func arrowheadShaftInset(
        _ arrowhead: AnnotationArrowhead,
        strokeWidth: CGFloat,
        size: AnnotationArrowheadSize = .small
    ) -> CGFloat {
        let metrics = arrowheadMetrics(
            strokeWidth: strokeWidth,
            size: size
        )
        let compoundSpacing = max(2, strokeWidth) * size.scale
        switch arrowhead {
        case .none, .arrow, .bar, .crowFoot:
            return 0
        case .triangle, .triangleOutline, .diamond, .diamondOutline:
            return metrics.length
        case .circle, .circleOutline:
            return metrics.halfWidth * 2
        case .oneOrMany:
            return metrics.length * 0.92
        case .zeroOrOne:
            return metrics.halfWidth * 1.44 + compoundSpacing
        case .zeroOrMany:
            return metrics.halfWidth * 1.44
                + compoundSpacing
                + metrics.length * 0.68
        }
    }

    static func linearShaftGeometry(
        _ linear: AnnotationLinearGeometry,
        strokeWidth: CGFloat
    ) -> AnnotationLinearGeometry {
        guard linear.points.count > 1 else { return linear }
        var result = linear
        var startInset = arrowheadShaftInset(
            linear.startArrowhead,
            strokeWidth: strokeWidth,
            size: linear.arrowheadSize
        )
        var endInset = arrowheadShaftInset(
            linear.endArrowhead,
            strokeWidth: strokeWidth,
            size: linear.arrowheadSize
        )

        let startAdjacent = endpointAdjacentPoint(in: linear, atStart: true)
            ?? linear.points[1]
        let endAdjacent = endpointAdjacentPoint(in: linear, atStart: false)
            ?? linear.points[linear.points.count - 2]
        let startDirection = unitVector(from: linear.points[0], to: startAdjacent)
        let endDirection = unitVector(
            from: linear.points[linear.points.count - 1],
            to: endAdjacent
        )
        startInset = min(
            startInset,
            maximumEndpointShaftInset(
                endpoint: linear.points[0],
                neighboringAnchor: linear.points[1],
                direction: startDirection
            )
        )
        endInset = min(
            endInset,
            maximumEndpointShaftInset(
                endpoint: linear.points[linear.points.count - 1],
                neighboringAnchor: linear.points[linear.points.count - 2],
                direction: endDirection
            )
        )

        if linear.points.count == 2 {
            let length = hypot(
                linear.points[1].x - linear.points[0].x,
                linear.points[1].y - linear.points[0].y
            )
            let maximumCombinedInset = max(0, length - max(1, strokeWidth * 0.5))
            let combinedInset = startInset + endInset
            if combinedInset > maximumCombinedInset, combinedInset > 0 {
                let scale = maximumCombinedInset / combinedInset
                startInset *= scale
                endInset *= scale
            }
        }

        let startDelta = startDirection * startInset
        let endDelta = endDirection * endInset
        result.points[0] = result.points[0] + startDelta
        result.points[result.points.count - 1] =
            result.points[result.points.count - 1] + endDelta

        if linear.route == .curved {
            var controls = bezierControls(for: linear)
            controls[0].start = controls[0].start + startDelta
            controls[controls.count - 1].end =
                controls[controls.count - 1].end + endDelta
            result.bezierControls = controls
        }
        return result
    }

    private static func maximumEndpointShaftInset(
        endpoint: CGPoint,
        neighboringAnchor: CGPoint,
        direction: CGPoint
    ) -> CGFloat {
        let anchorOffset = neighboringAnchor - endpoint
        return max(0, anchorOffset.x * direction.x + anchorOffset.y * direction.y)
    }

    private static func addArrowheadBar(
        to path: CGMutablePath,
        center: CGPoint,
        perpendicular: CGPoint,
        halfWidth: CGFloat
    ) {
        path.move(to: center + perpendicular * halfWidth)
        path.addLine(to: center - perpendicular * halfWidth)
    }

    private static func addCrowFoot(
        to path: CGMutablePath,
        apex: CGPoint,
        direction: CGPoint,
        perpendicular: CGPoint,
        length: CGFloat,
        halfWidth: CGFloat
    ) {
        let base = apex - direction * length
        path.move(to: apex)
        path.addLine(to: base + perpendicular * halfWidth)
        path.move(to: apex)
        path.addLine(to: base)
        path.move(to: apex)
        path.addLine(to: base - perpendicular * halfWidth)
    }

    static func binding(
        to target: AnnotationElement,
        near worldPoint: CGPoint,
        gap: CGFloat = 0
    ) -> AnnotationBinding? {
        guard case .shape(let shape) = target.geometry else { return nil }
        let localPoint = worldPoint.applying(inverseWorldTransform(for: target))
        let boundary = nearestBoundaryPoint(to: localPoint, shape: shape)
        let bounds = shape.bounds
        let normalized = CGPoint(
            x: bounds.width > 0 ? (boundary.point.x - bounds.minX) / bounds.width : 0.5,
            y: bounds.height > 0 ? (boundary.point.y - bounds.minY) / bounds.height : 0.5
        )
        return AnnotationBinding(
            targetElementID: target.id,
            normalizedAnchor: normalized,
            gap: max(0, gap),
            focus: boundary.focus,
            side: boundary.side
        )
    }

    static func bindingPoint(
        for binding: AnnotationBinding,
        on target: AnnotationElement,
        toward worldPoint: CGPoint
    ) -> CGPoint? {
        guard case .shape(let shape) = target.geometry else { return nil }
        let targetTransform = worldTransform(for: target)
        let localToward = worldPoint.applying(targetTransform.inverted())
        let localPoint: CGPoint

        if binding.side == .automatic {
            localPoint = boundaryPoint(
                on: shape,
                from: shape.bounds.center,
                toward: localToward
            )
        } else {
            localPoint = boundaryPoint(
                on: shape,
                side: binding.side,
                focus: binding.focus ?? focusFromNormalizedAnchor(binding.normalizedAnchor, side: binding.side)
            )
        }

        let worldBoundary = localPoint.applying(targetTransform)
        guard binding.gap > 0 else { return worldBoundary }
        let worldCenter = shape.bounds.center.applying(targetTransform)
        return worldBoundary + unitVector(from: worldCenter, to: worldBoundary) * binding.gap
    }

    static func distanceFromShapeBoundary(
        _ worldPoint: CGPoint,
        to target: AnnotationElement
    ) -> CGFloat {
        guard case .shape(let shape) = target.geometry else { return .infinity }
        let transform = inverseWorldTransform(for: target)
        let localPoint = worldPoint.applying(transform)
        let boundary = nearestBoundaryPoint(to: localPoint, shape: shape).point
        return hypot(localPoint.x - boundary.x, localPoint.y - boundary.y)
    }

    static func selectionDecoration(
        for element: AnnotationElement,
        zoomScale: CGFloat
    ) -> AnnotationSelectionDecoration? {
        let local = selectionLocalBounds(
            of: element,
            zoomScale: zoomScale
        )
        guard !local.isNull else { return nil }
        let handleKinds: [AnnotationSelectionHandleKind]
        if case .text = element.geometry {
            handleKinds = textSelectionHandleKinds
        } else {
            handleKinds = AnnotationSelectionHandleKind.allCases
        }

        return selectionDecoration(
            bounds: local,
            handleBounds: localBounds(of: element),
            transform: worldTransform(for: element),
            zoomScale: zoomScale,
            handleKinds: handleKinds
        )
    }

    static func selectionDecoration(
        for elements: [AnnotationElement],
        zoomScale: CGFloat
    ) -> AnnotationSelectionDecoration? {
        let visible = elements.filter(\.metadata.isVisible)
        guard let first = visible.first else { return nil }
        if visible.count == 1 {
            return selectionDecoration(for: first, zoomScale: zoomScale)
        }

        let bounds = visible.reduce(CGRect.null) { partial, element in
            let local = selectionLocalBounds(
                of: element,
                zoomScale: zoomScale
            )
            guard !local.isNull else { return partial }
            let transform = worldTransform(for: element)
            return partial.union(
                Self.bounds(
                    of: rectCorners(local).map { $0.applying(transform) }
                )
            )
        }
        let handleBounds = visible.reduce(CGRect.null) { partial, element in
            partial.union(worldBounds(of: element, includingStroke: false))
        }
        guard !bounds.isNull else { return nil }
        let containsText = visible.contains {
            if case .text = $0.geometry { return true }
            return false
        }
        return selectionDecoration(
            bounds: bounds,
            handleBounds: handleBounds,
            transform: .identity,
            zoomScale: zoomScale,
            handleKinds: containsText
                ? textSelectionHandleKinds
                : AnnotationSelectionHandleKind.allCases
        )
    }

    private static func selectionDecoration(
        bounds local: CGRect,
        handleBounds: CGRect,
        transform: CGAffineTransform,
        zoomScale: CGFloat,
        handleKinds: [AnnotationSelectionHandleKind]
    ) -> AnnotationSelectionDecoration {
        let metrics = AnnotationInteractionMetrics(zoomScale: zoomScale)
        let topLeading = CGPoint(x: local.minX, y: local.minY).applying(transform)
        let topTrailing = CGPoint(x: local.maxX, y: local.minY).applying(transform)
        let bottomTrailing = CGPoint(x: local.maxX, y: local.maxY).applying(transform)
        let bottomLeading = CGPoint(x: local.minX, y: local.maxY).applying(transform)
        let top = CGPoint(x: local.midX, y: local.minY).applying(transform)
        let handleTopLeading = CGPoint(
            x: handleBounds.minX,
            y: handleBounds.minY
        ).applying(transform)
        let handleTop = CGPoint(
            x: handleBounds.midX,
            y: handleBounds.minY
        ).applying(transform)
        let handleTopTrailing = CGPoint(
            x: handleBounds.maxX,
            y: handleBounds.minY
        ).applying(transform)
        let handleTrailing = CGPoint(
            x: handleBounds.maxX,
            y: handleBounds.midY
        ).applying(transform)
        let handleBottomTrailing = CGPoint(
            x: handleBounds.maxX,
            y: handleBounds.maxY
        ).applying(transform)
        let handleBottom = CGPoint(
            x: handleBounds.midX,
            y: handleBounds.maxY
        ).applying(transform)
        let handleBottomLeading = CGPoint(
            x: handleBounds.minX,
            y: handleBounds.maxY
        ).applying(transform)
        let handleLeading = CGPoint(
            x: handleBounds.minX,
            y: handleBounds.midY
        ).applying(transform)
        let rotation = CGPoint(
            x: local.midX,
            y: local.minY - metrics.rotationHandleOffset
        ).applying(transform)

        let centers: [(AnnotationSelectionHandleKind, CGPoint)] = [
            (.topLeading, handleTopLeading),
            (.top, handleTop),
            (.topTrailing, handleTopTrailing),
            (.trailing, handleTrailing),
            (.bottomTrailing, handleBottomTrailing),
            (.bottom, handleBottom),
            (.bottomLeading, handleBottomLeading),
            (.leading, handleLeading),
            (.rotation, rotation)
        ]
        let handles = centers.compactMap { kind, center -> AnnotationSelectionHandle? in
            guard handleKinds.contains(kind) else { return nil }
            return AnnotationSelectionHandle(
                kind: kind,
                center: center,
                bounds: CGRect(
                    x: center.x - metrics.handleSize / 2,
                    y: center.y - metrics.handleSize / 2,
                    width: metrics.handleSize,
                    height: metrics.handleSize
                )
            )
        }

        return AnnotationSelectionDecoration(
            outline: [topLeading, topTrailing, bottomTrailing, bottomLeading],
            rotationConnector: (start: top, end: rotation),
            handles: handles
        )
    }

    private static func selectionLocalBounds(
        of element: AnnotationElement,
        zoomScale: CGFloat
    ) -> CGRect {
        let local = localBounds(of: element)
        guard !local.isNull else { return local }
        let scale = max(zoomScale, 0.001)
        if case .text = element.geometry {
            let padding = 2 / scale
            return local.insetBy(dx: -padding, dy: -padding)
        }
        let strokeWidth = max(0, maximumStrokeWidth(for: element))
        let roughDeviation = AnnotationRoughStroke.maximumDestinationDeviation(
            for: element.effectiveSloppiness,
            strokeWidth: strokeWidth
        ) / scale
        let padding = strokeWidth / 2 + roughDeviation + 2 / scale
        return local.insetBy(dx: -padding, dy: -padding)
    }

    private static let textSelectionHandleKinds: [AnnotationSelectionHandleKind] = [
        .topLeading,
        .topTrailing,
        .bottomTrailing,
        .bottomLeading,
        .rotation
    ]

    static func maximumStrokeWidth(for element: AnnotationElement) -> CGFloat {
        element.style.strokeWidth
    }

    static func pressureScale(_ pressure: CGFloat?) -> CGFloat {
        guard let pressure else { return 1 }
        return max(0.15, min(1, pressure))
    }

    static func distance(from point: CGPoint, toSegmentFrom start: CGPoint, to end: CGPoint) -> CGFloat {
        let dx = end.x - start.x
        let dy = end.y - start.y
        let lengthSquared = dx * dx + dy * dy
        guard lengthSquared > 0 else {
            return hypot(point.x - start.x, point.y - start.y)
        }
        let projection = min(
            1,
            max(0, ((point.x - start.x) * dx + (point.y - start.y) * dy) / lengthSquared)
        )
        let closest = CGPoint(x: start.x + projection * dx, y: start.y + projection * dy)
        return hypot(point.x - closest.x, point.y - closest.y)
    }

    static func distance(from point: CGPoint, toPolyline points: [CGPoint]) -> CGFloat {
        guard let first = points.first else { return .infinity }
        guard points.count > 1 else { return hypot(point.x - first.x, point.y - first.y) }
        return zip(points, points.dropFirst()).reduce(.infinity) { current, pair in
            min(current, distance(from: point, toSegmentFrom: pair.0, to: pair.1))
        }
    }

    static func segmentIntersection(
        from firstStart: CGPoint,
        to firstEnd: CGPoint,
        with secondStart: CGPoint,
        to secondEnd: CGPoint
    ) -> CGPoint? {
        let firstDelta = firstEnd - firstStart
        let secondDelta = secondEnd - secondStart
        let denominator = cross(firstDelta, secondDelta)
        let offset = secondStart - firstStart

        if abs(denominator) < 0.000_001 {
            guard abs(cross(offset, firstDelta)) < 0.000_001 else { return nil }
            for point in [firstStart, firstEnd, secondStart, secondEnd] {
                if distance(from: point, toSegmentFrom: firstStart, to: firstEnd) < 0.000_001,
                   distance(from: point, toSegmentFrom: secondStart, to: secondEnd) < 0.000_001 {
                    return point
                }
            }
            return nil
        }

        let firstParameter = cross(offset, secondDelta) / denominator
        let secondParameter = cross(offset, firstDelta) / denominator
        guard (-0.000_001...1.000_001).contains(firstParameter),
              (-0.000_001...1.000_001).contains(secondParameter) else {
            return nil
        }
        return firstStart + firstDelta * firstParameter
    }

    static func rectCorners(_ rect: CGRect) -> [CGPoint] {
        [
            CGPoint(x: rect.minX, y: rect.minY),
            CGPoint(x: rect.maxX, y: rect.minY),
            CGPoint(x: rect.maxX, y: rect.maxY),
            CGPoint(x: rect.minX, y: rect.maxY)
        ]
    }

    private static func linearBounds(_ linear: AnnotationLinearGeometry, strokeWidth: CGFloat) -> CGRect {
        var result = linearPath(linear).boundingBoxOfPath
        if result.isNull {
            result = bounds(of: linear.points)
        }
        guard linear.points.count >= 2 else { return result }

        if let adjacent = endpointAdjacentPoint(in: linear, atStart: true),
           let startPath = arrowheadPath(
            linear.startArrowhead,
            tip: linear.points[0],
            adjacent: adjacent,
            strokeWidth: strokeWidth,
            size: linear.arrowheadSize
        ) {
            result = result.union(startPath.boundingBoxOfPath)
        }
        if let adjacent = endpointAdjacentPoint(in: linear, atStart: false),
           let endPath = arrowheadPath(
            linear.endArrowhead,
            tip: linear.points[linear.points.count - 1],
            adjacent: adjacent,
            strokeWidth: strokeWidth,
            size: linear.arrowheadSize
        ) {
            result = result.union(endPath.boundingBoxOfPath)
        }
        return result
    }

    private static func textBounds(_ text: AnnotationTextGeometry) -> CGRect {
        if let bounds = text.bounds {
            return bounds.standardized
        }

        let paragraph = NSMutableParagraphStyle()
        switch text.alignment {
        case .left: paragraph.alignment = .left
        case .center: paragraph.alignment = .center
        case .right: paragraph.alignment = .right
        }
        let size = NSString(string: text.text).size(
            withAttributes: [
                .font: AnnotationController.typingFont(named: text.fontName, size: text.fontSize),
                .paragraphStyle: paragraph
            ]
        )
        let x: CGFloat
        switch text.alignment {
        case .left:
            x = text.origin.x
        case .center:
            x = text.origin.x - size.width / 2
        case .right:
            x = text.origin.x - size.width
        }
        return CGRect(origin: CGPoint(x: x, y: text.origin.y), size: size)
    }

    private static func bounds(of points: [CGPoint]) -> CGRect {
        guard let first = points.first else { return .null }
        var minX = first.x
        var minY = first.y
        var maxX = first.x
        var maxY = first.y
        for point in points.dropFirst() {
            minX = min(minX, point.x)
            minY = min(minY, point.y)
            maxX = max(maxX, point.x)
            maxY = max(maxY, point.y)
        }
        return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }

    private static func rotationTransform(angle: CGFloat, around center: CGPoint) -> CGAffineTransform {
        guard angle != 0, center.x.isFinite, center.y.isFinite else { return .identity }
        return CGAffineTransform(translationX: center.x, y: center.y)
            .rotated(by: angle)
            .translatedBy(x: -center.x, y: -center.y)
    }

    private static func cubicPoint(
        from start: CGPoint,
        control1: CGPoint,
        control2: CGPoint,
        to end: CGPoint,
        t: CGFloat
    ) -> CGPoint {
        let inverse = 1 - t
        let inverseSquared = inverse * inverse
        let tSquared = t * t
        return CGPoint(
            x: inverseSquared * inverse * start.x
                + 3 * inverseSquared * t * control1.x
                + 3 * inverse * tSquared * control2.x
                + tSquared * t * end.x,
            y: inverseSquared * inverse * start.y
                + 3 * inverseSquared * t * control1.y
                + 3 * inverse * tSquared * control2.y
                + tSquared * t * end.y
        )
    }

    private static func interpolatedPressure(
        from start: CGFloat?,
        to end: CGFloat?,
        t: CGFloat
    ) -> CGFloat? {
        guard start != nil || end != nil else { return nil }
        let startValue = start ?? 1
        let endValue = end ?? 1
        return startValue + (endValue - startValue) * t
    }

    private static func interpolatedTimestamp(
        from start: TimeInterval?,
        to end: TimeInterval?,
        t: CGFloat
    ) -> TimeInterval? {
        guard let start, let end, start.isFinite, end.isFinite else {
            return end ?? start
        }
        return start + (end - start) * Double(t)
    }

    private static func unitVector(from start: CGPoint, to end: CGPoint) -> CGPoint {
        let dx = end.x - start.x
        let dy = end.y - start.y
        let length = hypot(dx, dy)
        guard length > 0 else { return CGPoint(x: 1, y: 0) }
        return CGPoint(x: dx / length, y: dy / length)
    }

    private static func closestLocation(
        to point: CGPoint,
        from start: CGPoint,
        to end: CGPoint,
        segmentIndex: Int
    ) -> AnnotationLinearLocation {
        let dx = end.x - start.x
        let dy = end.y - start.y
        let lengthSquared = dx * dx + dy * dy
        let parameter: CGFloat
        if lengthSquared > 0 {
            parameter = min(
                1,
                max(0, ((point.x - start.x) * dx + (point.y - start.y) * dy) / lengthSquared)
            )
        } else {
            parameter = 0
        }
        let closest = interpolate(start, end, parameter)
        return AnnotationLinearLocation(
            segmentIndex: segmentIndex,
            parameter: parameter,
            point: closest,
            distance: hypot(point.x - closest.x, point.y - closest.y)
        )
    }

    private static func interpolate(_ start: CGPoint, _ end: CGPoint, _ parameter: CGFloat) -> CGPoint {
        start + (end - start) * parameter
    }

    private static func cross(_ lhs: CGPoint, _ rhs: CGPoint) -> CGFloat {
        lhs.x * rhs.y - lhs.y * rhs.x
    }

    private static func nearestBoundaryPoint(
        to point: CGPoint,
        shape: AnnotationShapeGeometry
    ) -> (point: CGPoint, side: AnnotationBindingSide, focus: CGFloat) {
        let bounds = shape.bounds
        let center = bounds.center
        guard bounds.width > 0, bounds.height > 0 else {
            return (center, .automatic, 0)
        }

        let boundary = boundaryPoint(on: shape, from: center, toward: point)
        let dx = abs(boundary.x - bounds.minX)
        let trailing = abs(boundary.x - bounds.maxX)
        let dy = abs(boundary.y - bounds.minY)
        let bottom = abs(boundary.y - bounds.maxY)
        let minimum = min(dx, trailing, dy, bottom)
        let side: AnnotationBindingSide
        if minimum == dy {
            side = .top
        } else if minimum == trailing {
            side = .trailing
        } else if minimum == bottom {
            side = .bottom
        } else {
            side = .leading
        }
        let focus: CGFloat
        switch side {
        case .top, .bottom:
            focus = ((boundary.x - bounds.midX) / max(bounds.width / 2, 0.001))
        case .leading, .trailing:
            focus = ((boundary.y - bounds.midY) / max(bounds.height / 2, 0.001))
        case .automatic:
            focus = 0
        }
        return (boundary, side, min(1, max(-1, focus)))
    }

    private static func boundaryPoint(
        on shape: AnnotationShapeGeometry,
        from center: CGPoint,
        toward point: CGPoint
    ) -> CGPoint {
        let bounds = shape.bounds
        var direction = point - center
        if hypot(direction.x, direction.y) < 0.001 {
            direction = CGPoint(x: 1, y: 0)
        }
        let halfWidth = max(bounds.width / 2, 0.001)
        let halfHeight = max(bounds.height / 2, 0.001)
        let scale: CGFloat
        switch shape.kind {
        case .rectangle:
            scale = 1 / max(abs(direction.x) / halfWidth, abs(direction.y) / halfHeight)
        case .diamond:
            scale = 1 / (abs(direction.x) / halfWidth + abs(direction.y) / halfHeight)
        case .ellipse:
            scale = 1 / sqrt(
                direction.x * direction.x / (halfWidth * halfWidth)
                    + direction.y * direction.y / (halfHeight * halfHeight)
            )
        }
        return center + direction * scale
    }

    private static func boundaryPoint(
        on shape: AnnotationShapeGeometry,
        side: AnnotationBindingSide,
        focus: CGFloat
    ) -> CGPoint {
        let bounds = shape.bounds
        let clampedFocus = min(1, max(-1, focus))
        let target: CGPoint
        switch side {
        case .top:
            target = CGPoint(x: bounds.midX + clampedFocus * bounds.width / 2, y: bounds.minY)
        case .trailing:
            target = CGPoint(x: bounds.maxX, y: bounds.midY + clampedFocus * bounds.height / 2)
        case .bottom:
            target = CGPoint(x: bounds.midX + clampedFocus * bounds.width / 2, y: bounds.maxY)
        case .leading:
            target = CGPoint(x: bounds.minX, y: bounds.midY + clampedFocus * bounds.height / 2)
        case .automatic:
            target = CGPoint(x: bounds.maxX, y: bounds.midY)
        }
        return boundaryPoint(on: shape, from: bounds.center, toward: target)
    }

    private static func focusFromNormalizedAnchor(
        _ anchor: CGPoint,
        side: AnnotationBindingSide
    ) -> CGFloat {
        switch side {
        case .top, .bottom:
            anchor.x * 2 - 1
        case .leading, .trailing:
            anchor.y * 2 - 1
        case .automatic:
            0
        }
    }
}

private extension CGRect {
    var center: CGPoint {
        CGPoint(x: midX, y: midY)
    }
}

private func + (lhs: CGPoint, rhs: CGPoint) -> CGPoint {
    CGPoint(x: lhs.x + rhs.x, y: lhs.y + rhs.y)
}

private func - (lhs: CGPoint, rhs: CGPoint) -> CGPoint {
    CGPoint(x: lhs.x - rhs.x, y: lhs.y - rhs.y)
}

private func * (lhs: CGPoint, rhs: CGFloat) -> CGPoint {
    CGPoint(x: lhs.x * rhs, y: lhs.y * rhs)
}

private func / (lhs: CGPoint, rhs: CGFloat) -> CGPoint {
    CGPoint(x: lhs.x / rhs, y: lhs.y / rhs)
}
