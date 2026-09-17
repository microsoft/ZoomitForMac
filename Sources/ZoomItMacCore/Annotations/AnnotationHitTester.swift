import AppKit

@MainActor
enum AnnotationHitTester {
    enum Part: Equatable {
        case body
        case handle(AnnotationSelectionHandleKind)
    }

    struct Hit: Equatable {
        var elementID: AnnotationElementID
        var part: Part
    }

    struct LinearEditHit: Equatable {
        var part: AnnotationLinearEditPart
        var location: AnnotationLinearLocation?
    }

    struct BodyHitTestResult {
        var elementIDs: Set<AnnotationElementID>
        var testedElementCount: Int
    }

    static func hitTest(
        point: CGPoint,
        elements: [AnnotationElement],
        selection: Set<AnnotationElementID> = [],
        zoomScale: CGFloat
    ) -> Hit? {
        let selectedElements = AnnotationSelectionPresentation.editableElements(
            from: elements,
            selectedElementIDs: selection
        )
        if selectedElements.count > 1,
           let decoration = AnnotationGeometry.selectionDecoration(
               for: selectedElements,
               zoomScale: zoomScale
           ),
           let handle = decoration.handles.reversed().first(where: { $0.bounds.contains(point) }),
           let topmostSelected = selectedElements.last {
            return Hit(elementID: topmostSelected.id, part: .handle(handle.kind))
        }

        for element in selectedElements.reversed() {
            if let decoration = AnnotationGeometry.selectionDecoration(for: element, zoomScale: zoomScale),
               let handle = decoration.handles.reversed().first(where: { $0.bounds.contains(point) }) {
                return Hit(elementID: element.id, part: .handle(handle.kind))
            }
        }

        for element in elements.reversed() where element.metadata.isVisible {
            if contains(point, in: element, zoomScale: zoomScale) {
                return Hit(elementID: element.id, part: .body)
            }
        }
        return nil
    }

    static func bodyHits(
        point: CGPoint,
        elements: [AnnotationElement],
        excluding excludedElementIDs: Set<AnnotationElementID> = [],
        zoomScale: CGFloat
    ) -> BodyHitTestResult {
        var elementIDs: Set<AnnotationElementID> = []
        var testedElementCount = 0
        for element in elements
            where element.metadata.isVisible
                && !excludedElementIDs.contains(element.id) {
            testedElementCount += 1
            if contains(point, in: element, zoomScale: zoomScale) {
                elementIDs.insert(element.id)
            }
        }
        return BodyHitTestResult(
            elementIDs: elementIDs,
            testedElementCount: testedElementCount
        )
    }

    static func contains(_ worldPoint: CGPoint, in element: AnnotationElement, zoomScale: CGFloat) -> Bool {
        let metrics = AnnotationInteractionMetrics(zoomScale: zoomScale)
        let point = worldPoint.applying(AnnotationGeometry.inverseWorldTransform(for: element))
        let tolerance = effectiveHitRadius(
            for: element,
            zoomScale: metrics.zoomScale
        )

        switch element.geometry {
        case .freehand(let freehand):
            let points = element.style.smoothingEnabled
                ? AnnotationGeometry.smoothedFreehandSamples(freehand.samples).map(\.location)
                : freehand.samples.map(\.location)
            return AnnotationGeometry.distance(from: point, toPolyline: points) <= tolerance
        case .linear(let linear):
            let shaft = AnnotationGeometry.linearShaftGeometry(
                linear,
                strokeWidth: element.style.strokeWidth
            )
            if linearShaftContains(
                point,
                linear: shaft,
                tolerance: tolerance
            ) {
                return true
            }
            return arrowheadsContain(
                point,
                linear: linear,
                style: element.style,
                zoomScale: metrics.zoomScale
            )
        case .shape(let shape):
            return shapeContains(point, shape: shape, style: element.style, tolerance: tolerance)
        case .text:
            return AnnotationGeometry.localBounds(of: element)
                .insetBy(dx: -tolerance, dy: -tolerance)
                .contains(point)
        }
    }

    static func minimumEffectiveHitRadius(
        for elements: [AnnotationElement],
        zoomScale: CGFloat
    ) -> CGFloat {
        let normalizedZoom = max(zoomScale, 0.001)
        return elements.lazy.map {
            effectiveHitRadius(for: $0, zoomScale: normalizedZoom)
        }.min() ?? AnnotationInteractionMetrics(
            zoomScale: normalizedZoom
        ).hitTolerance
    }

    static func linearEditHitTest(
        point worldPoint: CGPoint,
        in element: AnnotationElement,
        zoomScale: CGFloat
    ) -> LinearEditHit? {
        guard case .linear(let linear) = element.geometry else { return nil }
        let metrics = AnnotationInteractionMetrics(zoomScale: zoomScale)
        let point = worldPoint.applying(AnnotationGeometry.inverseWorldTransform(for: element))
        let handleRadius = metrics.handleSize * 0.75

        if linear.route == .curved {
            let controls = AnnotationGeometry.bezierControls(for: linear)
            for index in controls.indices.reversed() {
                if hypot(point.x - controls[index].end.x, point.y - controls[index].end.y) <= handleRadius {
                    return LinearEditHit(part: .control(segment: index, end: .end), location: nil)
                }
                if hypot(point.x - controls[index].start.x, point.y - controls[index].start.y) <= handleRadius {
                    return LinearEditHit(part: .control(segment: index, end: .start), location: nil)
                }
            }
        }

        for index in linear.points.indices.reversed() {
            let vertex = linear.points[index]
            if hypot(point.x - vertex.x, point.y - vertex.y) <= handleRadius {
                return LinearEditHit(part: .point(index), location: nil)
            }
        }

        let tolerance = metrics.hitTolerance + element.style.strokeWidth / 2
        guard let location = AnnotationGeometry.closestLinearLocation(
            to: point,
            linear: linear,
            maximumError: tolerance / 4
        ),
              location.distance <= tolerance else {
            return nil
        }
        return LinearEditHit(part: .segment(location.segmentIndex), location: location)
    }

    private static func shapeContains(
        _ point: CGPoint,
        shape: AnnotationShapeGeometry,
        style: AnnotationStyle,
        tolerance: CGFloat
    ) -> Bool {
        let bounds = shape.bounds
        guard bounds.width > 0 || bounds.height > 0 else {
            return hypot(point.x - bounds.midX, point.y - bounds.midY) <= tolerance
        }

        let path = AnnotationGeometry.shapePath(
            shape,
            roundness: style.roundness
        )
        if style.usesLegacyHighlightCompositing {
            let legacyFillAlpha = AnnotationColorResolver.resolved(
                style.strokeColor,
                opacity: style.opacity
            ).alpha
            if legacyFillAlpha > 0, path.contains(point) {
                return true
            }
        }
        let fillAlpha = AnnotationColorResolver.resolved(
            style.fillColor,
            opacity: style.opacity
        ).alpha
        if style.fillStyle != .none, fillAlpha > 0, path.contains(point) {
            return true
        }

        let hitPath = path.copy(
            strokingWithWidth: max(0.000_001, tolerance * 2),
            lineCap: .round,
            lineJoin: .round,
            miterLimit: 10
        )
        if hitPath.contains(point) {
            return true
        }

        let nonzeroDimensions = [bounds.width, bounds.height].filter { $0 > 0 }
        guard let minimumDimension = nonzeroDimensions.min(),
              tolerance > minimumDimension / 2 else {
            return false
        }
        return boundaryDistance(from: point, to: path) <= tolerance
    }

    private static func arrowheadsContain(
        _ point: CGPoint,
        linear: AnnotationLinearGeometry,
        style: AnnotationStyle,
        zoomScale: CGFloat
    ) -> Bool {
        guard linear.points.count >= 2 else { return false }
        let metrics = AnnotationInteractionMetrics(zoomScale: zoomScale)
        let roughDeviation: CGFloat = switch style.sloppiness {
        case .architect:
            0
        case .artist:
            2 / metrics.zoomScale
        case .cartoonist:
            3.5 / metrics.zoomScale
        }
        let edgeTolerance = metrics.hitTolerance + roughDeviation
        let outlineRadius = max(0.5, style.strokeWidth) / 2
            + edgeTolerance
        let heads: [(AnnotationArrowhead, CGPoint, CGPoint)] = [
            (
                linear.startArrowhead,
                linear.points[0],
                AnnotationGeometry.endpointAdjacentPoint(in: linear, atStart: true) ?? linear.points[1]
            ),
            (
                linear.endArrowhead,
                linear.points[linear.points.count - 1],
                AnnotationGeometry.endpointAdjacentPoint(in: linear, atStart: false)
                    ?? linear.points[linear.points.count - 2]
            )
        ]

        return heads.contains { arrowhead, tip, adjacent in
            guard let path = AnnotationGeometry.arrowheadPath(
                arrowhead,
                tip: tip,
                adjacent: adjacent,
                strokeWidth: style.strokeWidth,
                size: linear.arrowheadSize
            ) else {
                return false
            }
            if arrowhead.isFilled, path.contains(point) {
                return true
            }
            let hitRadius = arrowhead.isFilled
                ? edgeTolerance
                : outlineRadius
            guard hitRadius > 0 else { return false }
            let hitPath = path.copy(
                strokingWithWidth: hitRadius * 2,
                lineCap: .round,
                lineJoin: .round,
                miterLimit: 10
            )
            return hitPath.contains(point)
        }
    }

    private static func linearShaftContains(
        _ point: CGPoint,
        linear: AnnotationLinearGeometry,
        tolerance: CGFloat
    ) -> Bool {
        let maximumError = max(0.000_001, tolerance / 4)
        let approximation = AnnotationGeometry.linearApproximation(
            linear,
            maximumError: maximumError
        )
        if approximation.segments.contains(where: {
            AnnotationGeometry.distance(
                from: point,
                toSegmentFrom: $0.start,
                to: $0.end
            ) <= tolerance
        }) {
            return true
        }
        guard approximation.reachedSubdivisionLimit else { return false }
        let hitPath = AnnotationGeometry.linearPath(linear).copy(
            strokingWithWidth: max(0.000_001, tolerance * 2),
            lineCap: .round,
            lineJoin: .round,
            miterLimit: 10
        )
        return hitPath.contains(point)
    }

    private static func effectiveHitRadius(
        for element: AnnotationElement,
        zoomScale: CGFloat
    ) -> CGFloat {
        let strokeWidth = max(0, AnnotationGeometry.maximumStrokeWidth(for: element))
        let roughDisplacement =
            AnnotationRoughStroke.maximumDestinationDeviation(
                for: element.effectiveSloppiness,
                strokeWidth: strokeWidth
            ) / zoomScale
        return AnnotationInteractionMetrics(zoomScale: zoomScale).hitTolerance
            + strokeWidth / 2
            + roughDisplacement
    }

    private static func boundaryDistance(
        from point: CGPoint,
        to path: CGPath
    ) -> CGFloat {
        let points = AnnotationRoughStroke.sampledPoints(
            on: path,
            curveSubdivisions: 24
        )
        guard let first = points.first else { return .infinity }
        var minimum = CGFloat.infinity
        var previous = first
        for current in points.dropFirst() {
            minimum = min(
                minimum,
                AnnotationGeometry.distance(
                    from: point,
                    toSegmentFrom: previous,
                    to: current
                )
            )
            previous = current
        }
        return min(
            minimum,
            AnnotationGeometry.distance(
                from: point,
                toSegmentFrom: previous,
                to: first
            )
        )
    }

}
