import AppKit

enum SmartDrawShapeKind: Equatable {
    case circle
    case ellipse
    case square
    case rectangle
    case diamond
    case arrow

    var displayName: String {
        switch self {
        case .circle: "Circle"
        case .ellipse: "Ellipse"
        case .square: "Square"
        case .rectangle: "Rectangle"
        case .diamond: "Diamond"
        case .arrow: "Arrow"
        }
    }
}

struct SmartDrawCandidate: Equatable {
    var kind: SmartDrawShapeKind
    var geometry: AnnotationElementGeometry
    var rotation: CGFloat
    var confidence: CGFloat
}

struct SmartDrawStabilityTracker {
    static let previewThreshold: CGFloat = 0.64
    static let immediatePreviewThreshold: CGFloat = 0.78
    static let previewReleaseThreshold: CGFloat = 0.54
    static let highConfidenceCommitThreshold: CGFloat = 0.77
    static let mediumConfidenceCommitThreshold: CGFloat = 0.64
    static let requiredConsistentUpdates = 2
    static let requiredSwitchUpdates = 2

    private(set) var previewCandidate: SmartDrawCandidate?
    private(set) var provisionalCandidate: SmartDrawCandidate?
    private var pendingCandidate: SmartDrawCandidate?
    private var pendingCount = 0
    private var previewObservationCount = 0
    private var missingCount = 0

    mutating func reset() {
        previewCandidate = nil
        provisionalCandidate = nil
        pendingCandidate = nil
        pendingCount = 0
        previewObservationCount = 0
        missingCount = 0
    }

    mutating func update(_ candidate: SmartDrawCandidate?) {
        guard let candidate else {
            missingCount += 1
            pendingCandidate = nil
            pendingCount = 0
            if missingCount >= 3 {
                previewCandidate = nil
                provisionalCandidate = nil
                previewObservationCount = 0
            }
            return
        }

        missingCount = 0
        if let previewCandidate {
            if previewCandidate.kind == candidate.kind {
                guard candidate.confidence >= Self.previewReleaseThreshold else {
                    if previewObservationCount <= 1 {
                        self.previewCandidate = nil
                        previewObservationCount = 0
                    }
                    return
                }
                self.previewCandidate = Self.blend(
                    previewCandidate,
                    candidate,
                    fraction: candidate.confidence >= Self.immediatePreviewThreshold ? 0.46 : 0.32
                )
                previewObservationCount += 1
                provisionalCandidate = nil
                pendingCandidate = nil
                pendingCount = 0
                return
            }

            guard candidate.confidence >= Self.previewThreshold,
                  candidate.confidence >= previewCandidate.confidence + 0.045 else {
                pendingCandidate = nil
                pendingCount = 0
                return
            }
            registerPending(candidate, requiredCount: Self.requiredSwitchUpdates)
            return
        }

        guard candidate.confidence >= Self.previewThreshold else {
            provisionalCandidate = nil
            pendingCandidate = nil
            pendingCount = 0
            return
        }
        if candidate.confidence >= Self.immediatePreviewThreshold {
            previewCandidate = candidate
            provisionalCandidate = nil
            previewObservationCount = 1
            pendingCandidate = nil
            pendingCount = 0
        } else {
            provisionalCandidate = candidate
            registerPending(candidate, requiredCount: Self.requiredConsistentUpdates)
        }
    }

    var displayCandidate: SmartDrawCandidate? {
        previewCandidate ?? provisionalCandidate
    }

    func commitCandidate(final candidate: SmartDrawCandidate?) -> SmartDrawCandidate? {
        guard let candidate else { return nil }
        if candidate.confidence >= Self.highConfidenceCommitThreshold {
            return candidate
        }
        guard candidate.confidence >= Self.mediumConfidenceCommitThreshold,
              previewObservationCount >= Self.requiredConsistentUpdates,
              previewCandidate?.kind == candidate.kind else {
            return nil
        }
        return candidate
    }

    private mutating func registerPending(
        _ candidate: SmartDrawCandidate,
        requiredCount: Int
    ) {
        if let pendingCandidate, pendingCandidate.kind == candidate.kind {
            self.pendingCandidate = Self.blend(pendingCandidate, candidate, fraction: 0.5)
            pendingCount += 1
        } else {
            pendingCandidate = candidate
            pendingCount = 1
        }
        if pendingCount >= requiredCount, let pendingCandidate {
            previewCandidate = pendingCandidate
            provisionalCandidate = nil
            previewObservationCount = pendingCount
            self.pendingCandidate = nil
            pendingCount = 0
        }
    }

    private static func blend(
        _ current: SmartDrawCandidate,
        _ update: SmartDrawCandidate,
        fraction: CGFloat
    ) -> SmartDrawCandidate {
        guard current.kind == update.kind else { return update }
        let amount = min(1, max(0, fraction))
        let geometry: AnnotationElementGeometry
        switch (current.geometry, update.geometry) {
        case (.shape(let currentShape), .shape(let updateShape)):
            geometry = .shape(
                AnnotationShapeGeometry(
                    kind: updateShape.kind,
                    start: interpolate(currentShape.start, updateShape.start, amount),
                    end: interpolate(currentShape.end, updateShape.end, amount)
                )
            )
        case (.linear(let currentLinear), .linear(let updateLinear))
            where currentLinear.points.count == updateLinear.points.count:
            var linear = updateLinear
            linear.points = zip(currentLinear.points, updateLinear.points).map {
                interpolate($0.0, $0.1, amount)
            }
            geometry = .linear(linear)
        default:
            geometry = update.geometry
        }
        return SmartDrawCandidate(
            kind: update.kind,
            geometry: geometry,
            rotation: blendAngle(
                current.rotation,
                update.rotation,
                fraction: amount,
                period: .pi
            ),
            confidence: current.confidence
                + (update.confidence - current.confidence) * amount
        )
    }

    private static func interpolate(
        _ start: CGPoint,
        _ end: CGPoint,
        _ fraction: CGFloat
    ) -> CGPoint {
        CGPoint(
            x: start.x + (end.x - start.x) * fraction,
            y: start.y + (end.y - start.y) * fraction
        )
    }

    private static func blendAngle(
        _ start: CGFloat,
        _ end: CGFloat,
        fraction: CGFloat,
        period: CGFloat
    ) -> CGFloat {
        var delta = (end - start).truncatingRemainder(dividingBy: period)
        if delta > period / 2 {
            delta -= period
        } else if delta < -period / 2 {
            delta += period
        }
        return start + delta * fraction
    }
}

struct SmartDrawRecognitionBudget {
    static let maximumInputPointCount = 320
    static let previewInputPointCount = 144
    static let minimumPreviewInterval: TimeInterval = 1.0 / 25.0
    static let minimumPointCount = 5
    static let minimumAdditionalPointCount = 4

    static func shouldRecognizePreview(
        lastRecognitionTime: TimeInterval?,
        lastRecognizedSampleCount: Int,
        timestamp: TimeInterval,
        sampleCount: Int
    ) -> Bool {
        guard sampleCount >= minimumPointCount else {
            return false
        }
        guard let lastRecognitionTime else {
            return sampleCount > lastRecognizedSampleCount
        }
        guard sampleCount - lastRecognizedSampleCount
                >= minimumAdditionalPointCount else {
            return false
        }
        return timestamp - lastRecognitionTime >= minimumPreviewInterval
    }
}

struct SmartDrawRecognitionToken: Equatable, Sendable {
    var strokeGeneration: Int
    var requestGeneration: Int
}

struct SmartDrawRecognitionGenerationState: Equatable {
    private(set) var strokeGeneration = 0
    private(set) var latestRequestGeneration = 0

    mutating func beginStroke() {
        strokeGeneration &+= 1
        latestRequestGeneration = 0
    }

    mutating func submit() -> SmartDrawRecognitionToken {
        latestRequestGeneration &+= 1
        return SmartDrawRecognitionToken(
            strokeGeneration: strokeGeneration,
            requestGeneration: latestRequestGeneration
        )
    }

    func accepts(_ token: SmartDrawRecognitionToken) -> Bool {
        token.strokeGeneration == strokeGeneration
            && token.requestGeneration == latestRequestGeneration
    }
}

enum SmartDrawRecognitionQuality {
    case preview
    case final
}

enum SmartDrawRecognizer {
    private struct OrientedBounds {
        var center: CGPoint
        var width: CGFloat
        var height: CGFloat
        var angle: CGFloat
        var minX: CGFloat
        var maxX: CGFloat
        var minY: CGFloat
        var maxY: CGFloat
    }

    private struct ClosedGesture {
        var points: [CGPoint]
        var closureDistance: CGFloat
        var closureRatio: CGFloat
        var trimFraction: CGFloat
    }

    private struct CircleFit {
        var center: CGPoint
        var radius: CGFloat
        var residual: CGFloat
    }

    private struct EllipseFit {
        var center: CGPoint
        var radiusX: CGFloat
        var radiusY: CGFloat
        var angle: CGFloat
        var residual: CGFloat
        var angularCoverage: CGFloat
    }

    private struct RectangleFit {
        var bounds: OrientedBounds
        var directionConcentration: CGFloat
        var edgeResidual: CGFloat
        var cornerEvidence: CGFloat
        var edgeOccupancy: CGFloat
        var corners: [CGPoint]
    }

    private struct ArrowMatch {
        var tail: CGPoint
        var tip: CGPoint
        var confidence: CGFloat
    }

    static func recognize(
        points input: [CGPoint],
        duration: TimeInterval,
        zoomScale: CGFloat,
        quality: SmartDrawRecognitionQuality = .final
    ) -> SmartDrawCandidate? {
        let scale = max(zoomScale, 0.001)
        let maximumCount = quality == .preview
            ? SmartDrawRecognitionBudget.previewInputPointCount
            : SmartDrawRecognitionBudget.maximumInputPointCount
        let minimumSpacing = max(0.45 / scale, 0.04)
        var points = boundedPoints(
            deduplicated(input, minimumSpacing: minimumSpacing),
            maximumCount: maximumCount
        )
        guard points.count >= SmartDrawRecognitionBudget.minimumPointCount else {
            return nil
        }
        points = removeIsolatedSpikes(points, zoomScale: scale)

        let robustBounds = quantileBounds(points, lower: 0.02, upper: 0.98)
        let diagonal = hypot(robustBounds.width, robustBounds.height)
        let pathLength = polylineLength(points)
        let minimumSpan = 22 / scale
        guard max(robustBounds.width, robustBounds.height) >= minimumSpan,
              pathLength >= 38 / scale,
              diagonal > 0 else {
            return nil
        }

        if let arrow = recognizeArrow(
            points,
            duration: duration,
            zoomScale: scale,
            diagonal: diagonal
        ) {
            return SmartDrawCandidate(
                kind: .arrow,
                geometry: .linear(
                    AnnotationLinearGeometry(
                        points: [arrow.tail, arrow.tip],
                        route: .straight,
                        startArrowhead: .none,
                        endArrowhead: .arrow,
                        startBinding: nil,
                        endBinding: nil
                    )
                ),
                rotation: 0,
                confidence: arrow.confidence
            )
        }

        guard let closed = closedGesture(
            points,
            diagonal: diagonal,
            zoomScale: scale
        ) else {
            return nil
        }
        let fitCount = quality == .preview ? 72 : 128
        let perimeterPoints = resample(closed.points + [closed.points[0]], count: fitCount)
        let fitPoints = Array(perimeterPoints.dropLast())
        guard fitPoints.count >= 16 else { return nil }

        let simplified = simplify(
            perimeterPoints,
            tolerance: max(diagonal * 0.012, 0.8 / scale)
        )
        guard selfIntersectionCount(
            perimeterPoints,
            closureTolerance: max(2.5 / scale, diagonal * 0.012)
        ) == 0,
        simplified.count <= 34 else {
            return nil
        }

        let area = abs(polygonArea(perimeterPoints))
        guard area >= pow(11 / scale, 2) else { return nil }
        let closedLength = polylineLength(perimeterPoints)
        guard closedLength > 0 else { return nil }

        guard let circleFit = fitCircle(fitPoints),
              let ellipseFit = fitEllipse(fitPoints),
              let rectangleFit = fitRectangle(fitPoints) else {
            return nil
        }

        let aspect = ellipseFit.radiusX / max(ellipseFit.radiusY, 0.001)
        guard aspect <= 8 else { return nil }
        let closureScore = clamp01(1 - closed.closureRatio / 0.46)
        let trimScore = clamp01(1 - closed.trimFraction / 0.32)
        let circleFitScore = clamp01(1 - circleFit.residual / 0.16)
        let ellipseFitScore = clamp01(1 - ellipseFit.residual / 0.15)
        let circleAspectScore = clamp01(1 - (aspect - 1) / 0.28)
        let ellipseAspectEvidence = clamp01((aspect - 1.06) / 0.30)
        let angularCoverageScore = clamp01(
            (ellipseFit.angularCoverage - 0.58) / 0.34
        )
        let rectangleEdgeScore = clamp01(1 - rectangleFit.edgeResidual / 0.105)
        let expectedEllipsePerimeter = ellipsePerimeter(
            radiusX: ellipseFit.radiusX,
            radiusY: ellipseFit.radiusY
        )
        let expectedRectanglePerimeter = 2 * (
            rectangleFit.bounds.width + rectangleFit.bounds.height
        )
        let circlePathScore = perimeterScore(
            actual: closedLength,
            expected: 2 * .pi * circleFit.radius
        )
        let ellipsePathScore = perimeterScore(
            actual: closedLength,
            expected: expectedEllipsePerimeter
        )
        let rectanglePathScore = perimeterScore(
            actual: closedLength,
            expected: expectedRectanglePerimeter
        )

        let circleConfidence = weighted([
            (closureScore, 0.12),
            (trimScore, 0.05),
            (circleFitScore, 0.31),
            (circleAspectScore, 0.24),
            (angularCoverageScore, 0.14),
            (circlePathScore, 0.14)
        ])

        let ellipseConfidence = weighted([
            (closureScore, 0.12),
            (trimScore, 0.05),
            (ellipseFitScore, 0.32),
            (ellipseAspectEvidence, 0.19),
            (angularCoverageScore, 0.16),
            (ellipsePathScore, 0.12),
            (clamp01(1 - rectangleFit.cornerEvidence), 0.04)
        ])

        let rectangleConfidence = weighted([
            (closureScore, 0.11),
            (trimScore, 0.05),
            (rectangleFit.directionConcentration, 0.24),
            (rectangleEdgeScore, 0.27),
            (rectangleFit.cornerEvidence, 0.17),
            (rectangleFit.edgeOccupancy, 0.08),
            (rectanglePathScore, 0.08)
        ])

        var candidates: [SmartDrawCandidate] = []
        if aspect <= 1.30 {
            candidates.append(
                makeCircleCandidate(
                    circleFit: circleFit,
                    ellipseFit: ellipseFit,
                    confidence: circleConfidence
                )
            )
        }
        if aspect >= 1.10 {
            candidates.append(
                makeEllipseCandidate(
                    fit: ellipseFit,
                    confidence: ellipseConfidence
                )
            )
        }
        if rectangleFit.directionConcentration >= 0.34 {
            candidates.append(
                makeRectangleCandidate(
                    fit: rectangleFit,
                    points: fitPoints,
                    confidence: rectangleConfidence
                )
            )
        }
        guard let best = candidates.max(by: { $0.confidence < $1.confidence }) else {
            return nil
        }
        let bestExpectedPerimeter: CGFloat
        switch best.kind {
        case .circle:
            bestExpectedPerimeter = 2 * .pi * circleFit.radius
        case .ellipse:
            bestExpectedPerimeter = expectedEllipsePerimeter
        case .square, .rectangle, .diamond:
            bestExpectedPerimeter = expectedRectanglePerimeter
        case .arrow:
            bestExpectedPerimeter = closedLength
        }
        let bestPerimeterRatio = closedLength / max(bestExpectedPerimeter, 0.001)
        guard (0.56...1.72).contains(bestPerimeterRatio) else {
            return nil
        }
        let runnerUp = candidates
            .filter { $0.kind != best.kind }
            .map(\.confidence)
            .max() ?? 0
        guard best.confidence >= 0.58,
              best.confidence - runnerUp >= 0.025 || best.confidence >= 0.86 else {
            return nil
        }
        return best
    }

    static func preparedPointsForTesting(
        _ input: [CGPoint],
        zoomScale: CGFloat
    ) -> [CGPoint] {
        let scale = max(zoomScale, 0.001)
        return boundedPoints(
            deduplicated(input, minimumSpacing: max(0.45 / scale, 0.04)),
            maximumCount: SmartDrawRecognitionBudget.maximumInputPointCount
        )
    }

    private static func makeCircleCandidate(
        circleFit: CircleFit,
        ellipseFit: EllipseFit,
        confidence: CGFloat
    ) -> SmartDrawCandidate {
        let footprintRadius = sqrt(ellipseFit.radiusX * ellipseFit.radiusY)
        let radius = circleFit.radius * 0.68 + footprintRadius * 0.32
        let center = CGPoint(
            x: circleFit.center.x * 0.72 + ellipseFit.center.x * 0.28,
            y: circleFit.center.y * 0.72 + ellipseFit.center.y * 0.28
        )
        return SmartDrawCandidate(
            kind: .circle,
            geometry: .shape(
                AnnotationShapeGeometry(
                    kind: .ellipse,
                    start: CGPoint(x: center.x - radius, y: center.y - radius),
                    end: CGPoint(x: center.x + radius, y: center.y + radius)
                )
            ),
            rotation: 0,
            confidence: confidence
        )
    }

    private static func makeEllipseCandidate(
        fit: EllipseFit,
        confidence: CGFloat
    ) -> SmartDrawCandidate {
        SmartDrawCandidate(
            kind: .ellipse,
            geometry: .shape(
                AnnotationShapeGeometry(
                    kind: .ellipse,
                    start: CGPoint(
                        x: fit.center.x - fit.radiusX,
                        y: fit.center.y - fit.radiusY
                    ),
                    end: CGPoint(
                        x: fit.center.x + fit.radiusX,
                        y: fit.center.y + fit.radiusY
                    )
                )
            ),
            rotation: fit.angle,
            confidence: confidence
        )
    }

    private static func makeRectangleCandidate(
        fit: RectangleFit,
        points: [CGPoint],
        confidence: CGFloat
    ) -> SmartDrawCandidate {
        let aspect = fit.bounds.width / max(fit.bounds.height, 0.001)
        let axisBounds = quantileBounds(points, lower: 0.025, upper: 0.975)
        let center = fit.bounds.center
        let diamondEvidence = diamondEvidence(
            fit: fit,
            points: points
        )
        if aspect <= 1.32, diamondEvidence >= 0.64 {
            return SmartDrawCandidate(
                kind: .diamond,
                geometry: .shape(
                    AnnotationShapeGeometry(
                        kind: .diamond,
                        start: CGPoint(
                            x: center.x - axisBounds.width / 2,
                            y: center.y - axisBounds.height / 2
                        ),
                        end: CGPoint(
                            x: center.x + axisBounds.width / 2,
                            y: center.y + axisBounds.height / 2
                        )
                    )
                ),
                rotation: 0,
                confidence: confidence * (0.92 + diamondEvidence * 0.08)
            )
        }

        let kind: SmartDrawShapeKind = aspect <= 1.22 ? .square : .rectangle
        let side = (axisBounds.width + axisBounds.height) / 2
        let width = kind == .square ? side : axisBounds.width
        let height = kind == .square ? side : axisBounds.height
        return SmartDrawCandidate(
            kind: kind,
            geometry: .shape(
                AnnotationShapeGeometry(
                    kind: .rectangle,
                    start: CGPoint(
                        x: center.x - width / 2,
                        y: center.y - height / 2
                    ),
                    end: CGPoint(
                        x: center.x + width / 2,
                        y: center.y + height / 2
                    )
                )
            ),
            rotation: 0,
            confidence: confidence
        )
    }

    private static func recognizeArrow(
        _ points: [CGPoint],
        duration: TimeInterval,
        zoomScale: CGFloat,
        diagonal: CGFloat
    ) -> ArrowMatch? {
        guard duration <= 5 else { return nil }
        let count = min(128, max(36, points.count))
        let sampled = resample(points, count: count)
        let forward = arrowMatch(
            sampled,
            zoomScale: zoomScale,
            diagonal: diagonal
        )
        let reverse = arrowMatch(
            Array(sampled.reversed()),
            zoomScale: zoomScale,
            diagonal: diagonal
        )
        return [forward, reverse]
            .compactMap { $0 }
            .max { $0.confidence < $1.confidence }
    }

    private static func arrowMatch(
        _ points: [CGPoint],
        zoomScale: CGFloat,
        diagonal: CGFloat
    ) -> ArrowMatch? {
        guard points.count >= 12 else { return nil }
        let lowerTipIndex = max(4, Int(CGFloat(points.count) * 0.38))
        let upperTipIndex = min(points.count - 7, Int(CGFloat(points.count) * 0.82))
        guard lowerTipIndex <= upperTipIndex else { return nil }

        var best: ArrowMatch?
        for tipIndex in lowerTipIndex...upperTipIndex {
            let initialTip = points[tipIndex]
            let shaftPoints = Array(points[0...tipIndex])
            guard let line = fitLine(shaftPoints) else { continue }
            var direction = line.direction
            if dot(direction, pointSubtract(initialTip, points[0])) < 0 {
                direction = CGPoint(x: -direction.x, y: -direction.y)
            }

            let shaftProjections = shaftPoints.map {
                dot(pointSubtract($0, line.center), direction)
            }
            let shaftStartProjection = quantile(shaftProjections, 0.015)
            let shaftEndProjection = quantile(shaftProjections, 0.985)
            let fittedTail = pointAdd(
                line.center,
                pointMultiply(direction, shaftStartProjection)
            )
            let fittedShaftEnd = pointAdd(
                line.center,
                pointMultiply(direction, shaftEndProjection)
            )
            let shaftLength = distance(fittedTail, fittedShaftEnd)
            guard shaftLength >= 30 / zoomScale else { continue }

            let shaftResiduals = shaftPoints.map {
                abs(cross(pointSubtract($0, line.center), direction)) / shaftLength
            }
            let shaftResidual = trimmedMean(shaftResiduals, trimUpperFraction: 0.12)
            let shaftStraightness = clamp01(1 - shaftResidual / 0.065)
            guard shaftStraightness > 0.28 else { continue }

            let suffix = Array(points[(tipIndex + 1)...])
            guard suffix.count >= 6 else {
                continue
            }
            let revisitRange = 2..<(suffix.count - 2)
            guard let revisitIndex = revisitRange.min(by: {
                distance(suffix[$0], initialTip) < distance(suffix[$1], initialTip)
            }) else {
                continue
            }
            guard let firstWingIndex = (0..<revisitIndex).max(by: {
                distance(suffix[$0], initialTip) < distance(suffix[$1], initialTip)
            }) else {
                continue
            }
            let firstWing = suffix[firstWingIndex]
            let revisit = suffix[revisitIndex]
            let secondWingRange = (revisitIndex + 1)..<suffix.count
            guard let secondWingIndex = secondWingRange.max(by: {
                distance(suffix[$0], initialTip) < distance(suffix[$1], initialTip)
            }) else {
                continue
            }
            let secondWing = suffix[secondWingIndex]
            let revisitTolerance = max(7 / zoomScale, shaftLength * 0.14)
            let revisitDistance = distance(revisit, initialTip)
            guard revisitDistance <= revisitTolerance else { continue }

            let tip = CGPoint(
                x: initialTip.x * 0.68 + revisit.x * 0.32,
                y: initialTip.y * 0.68 + revisit.y * 0.32
            )
            let firstVector = pointSubtract(firstWing, tip)
            let secondVector = pointSubtract(secondWing, tip)
            let firstLength = hypot(firstVector.x, firstVector.y)
            let secondLength = hypot(secondVector.x, secondVector.y)
            let minimumHead = max(8 / zoomScale, shaftLength * 0.09)
            let maximumHead = shaftLength * 0.58
            guard (minimumHead...maximumHead).contains(firstLength),
                  (minimumHead...maximumHead).contains(secondLength) else {
                continue
            }

            let shaftUnit = unitVector(from: fittedTail, to: tip)
            let firstBackward = -dot(firstVector, shaftUnit)
            let secondBackward = -dot(secondVector, shaftUnit)
            guard firstBackward > firstLength * 0.26,
                  secondBackward > secondLength * 0.26 else {
                continue
            }
            let firstCross = cross(shaftUnit, firstVector)
            let secondCross = cross(shaftUnit, secondVector)
            guard firstCross * secondCross < 0 else { continue }

            let symmetry = clamp01(
                1 - abs(firstLength - secondLength) / max(firstLength, secondLength)
            )
            let revisitScore = clamp01(1 - revisitDistance / revisitTolerance)
            let headAngleScore = (
                arrowWingAngleScore(firstVector, shaftUnit)
                    + arrowWingAngleScore(secondVector, shaftUnit)
            ) / 2
            let shaftDominance = clamp01(
                (shaftLength / max(polylineLength(points), 0.001) - 0.42) / 0.28
            )
            let tipAlignment = clamp01(
                1 - distance(initialTip, fittedShaftEnd) / max(shaftLength * 0.12, 1)
            )
            let confidence = weighted([
                (shaftStraightness, 0.28),
                (revisitScore, 0.20),
                (symmetry, 0.12),
                (headAngleScore, 0.20),
                (shaftDominance, 0.12),
                (tipAlignment, 0.08)
            ])
            guard confidence >= 0.60 else { continue }

            let tailProjection = dot(pointSubtract(points[0], tip), shaftUnit)
            let tail = pointAdd(tip, pointMultiply(shaftUnit, tailProjection))
            let match = ArrowMatch(
                tail: distance(tail, points[0]) <= max(4 / zoomScale, shaftLength * 0.025)
                    ? points[0]
                    : tail,
                tip: tip,
                confidence: confidence
            )
            if best == nil || match.confidence > best!.confidence {
                best = match
            }
        }
        return best
    }

    private static func arrowWingAngleScore(
        _ wing: CGPoint,
        _ shaftUnit: CGPoint
    ) -> CGFloat {
        let length = hypot(wing.x, wing.y)
        guard length > 0 else { return 0 }
        let backward = CGPoint(x: -shaftUnit.x, y: -shaftUnit.y)
        let cosine = min(1, max(-1, dot(wing, backward) / length))
        let angle = acos(cosine)
        return score(angle, ideal: .pi / 5.5, tolerance: .pi / 4.2)
    }

    private static func closedGesture(
        _ points: [CGPoint],
        diagonal: CGFloat,
        zoomScale: CGFloat
    ) -> ClosedGesture? {
        guard points.count >= 8 else { return nil }
        let totalLength = polylineLength(points)
        guard totalLength > 0 else { return nil }
        let maximumTrim = min(24, max(2, points.count / 5))
        var bestRange = 0..<(points.count)
        var bestGap = distance(points[0], points[points.count - 1])
        var bestScore = bestGap / diagonal

        for start in 0...maximumTrim {
            let minimumEnd = max(start + 6, points.count - 1 - maximumTrim)
            guard minimumEnd < points.count else { continue }
            for end in minimumEnd..<points.count {
                let retained = Array(points[start...end])
                let retainedLength = polylineLength(retained)
                guard retainedLength / totalLength >= 0.64 else { continue }
                let gap = distance(points[start], points[end])
                let trimFraction = (totalLength - retainedLength) / totalLength
                let candidateScore = gap / diagonal + trimFraction * 0.42
                if candidateScore < bestScore {
                    bestScore = candidateScore
                    bestGap = gap
                    bestRange = start..<(end + 1)
                }
            }
        }

        let result = Array(points[bestRange])
        let retainedLength = polylineLength(result)
        let trimFraction = clamp01((totalLength - retainedLength) / totalLength)
        let closureLimit = max(diagonal * 0.46, 12 / zoomScale)
        guard bestGap <= closureLimit, result.count >= 8 else { return nil }
        return ClosedGesture(
            points: result,
            closureDistance: bestGap,
            closureRatio: bestGap / diagonal,
            trimFraction: trimFraction
        )
    }

    private static func fitCircle(_ points: [CGPoint]) -> CircleFit? {
        guard points.count >= 6 else { return nil }
        var weights = Array(repeating: CGFloat(1), count: points.count)
        var center = averagePoint(points)
        var radius: CGFloat = 0

        for _ in 0..<4 {
            var matrix = Array(
                repeating: Array(repeating: CGFloat.zero, count: 3),
                count: 3
            )
            var vector = Array(repeating: CGFloat.zero, count: 3)
            for (index, point) in points.enumerated() {
                let row = [2 * point.x, 2 * point.y, CGFloat(1)]
                let target = point.x * point.x + point.y * point.y
                let weight = weights[index]
                for rowIndex in 0..<3 {
                    vector[rowIndex] += weight * row[rowIndex] * target
                    for columnIndex in 0..<3 {
                        matrix[rowIndex][columnIndex] +=
                            weight * row[rowIndex] * row[columnIndex]
                    }
                }
            }
            guard let solution = solve(matrix, vector) else { return nil }
            center = CGPoint(x: solution[0], y: solution[1])
            let radiusSquared = solution[2]
                + center.x * center.x
                + center.y * center.y
            guard radiusSquared > 0, radiusSquared.isFinite else { return nil }
            radius = sqrt(radiusSquared)

            let residuals = points.map { distance($0, center) - radius }
            let scale = max(
                median(residuals.map { abs($0) }) * 1.4826,
                radius * 0.008
            )
            weights = residuals.map {
                huberWeight(residual: $0, scale: scale, cutoff: 1.6)
            }
        }

        guard radius > 0, radius.isFinite else { return nil }
        let normalizedResiduals = points.map {
            abs(distance($0, center) / radius - 1)
        }
        return CircleFit(
            center: center,
            radius: median(points.map { distance($0, center) }),
            residual: trimmedMean(normalizedResiduals, trimUpperFraction: 0.12)
        )
    }

    private static func fitEllipse(_ points: [CGPoint]) -> EllipseFit? {
        guard points.count >= 8 else { return nil }
        let mean = averagePoint(points)
        var covarianceXX: CGFloat = 0
        var covarianceXY: CGFloat = 0
        var covarianceYY: CGFloat = 0
        for point in points {
            let offset = pointSubtract(point, mean)
            covarianceXX += offset.x * offset.x
            covarianceXY += offset.x * offset.y
            covarianceYY += offset.y * offset.y
        }
        let initialAngle = 0.5 * atan2(
            2 * covarianceXY,
            covarianceXX - covarianceYY
        )
        let initialBounds = orientedBounds(
            points,
            angle: initialAngle,
            lowerQuantile: 0.025,
            upperQuantile: 0.975
        )
        guard initialBounds.width > 0, initialBounds.height > 0 else { return nil }

        var parameters = [
            initialBounds.center.x,
            initialBounds.center.y,
            log(max(initialBounds.width / 2, 0.001)),
            log(max(initialBounds.height / 2, 0.001)),
            initialAngle
        ]
        let minimumRadius = max(
            min(initialBounds.width, initialBounds.height) * 0.22,
            0.5
        )
        let maximumRadius = max(initialBounds.width, initialBounds.height) * 1.2
        let centerLimitX = initialBounds.width * 0.28
        let centerLimitY = initialBounds.height * 0.28

        for _ in 0..<9 {
            let residuals = points.map { ellipseResidual(parameters, point: $0) }
            let robustScale = max(
                median(residuals.map { abs($0) }) * 1.4826,
                0.012
            )
            var matrix = Array(
                repeating: Array(repeating: CGFloat.zero, count: 5),
                count: 5
            )
            var vector = Array(repeating: CGFloat.zero, count: 5)
            let steps: [CGFloat] = [
                max(initialBounds.width * 0.0008, 0.02),
                max(initialBounds.height * 0.0008, 0.02),
                0.0008,
                0.0008,
                0.0008
            ]
            for (pointIndex, point) in points.enumerated() {
                let residual = residuals[pointIndex]
                let weight = huberWeight(
                    residual: residual,
                    scale: robustScale,
                    cutoff: 1.7
                )
                var jacobian = Array(repeating: CGFloat.zero, count: 5)
                for parameterIndex in 0..<5 {
                    var changed = parameters
                    changed[parameterIndex] += steps[parameterIndex]
                    jacobian[parameterIndex] =
                        (ellipseResidual(changed, point: point) - residual)
                        / steps[parameterIndex]
                }
                for row in 0..<5 {
                    vector[row] -= weight * jacobian[row] * residual
                    for column in 0..<5 {
                        matrix[row][column] +=
                            weight * jacobian[row] * jacobian[column]
                    }
                }
            }
            for index in 0..<5 {
                matrix[index][index] += index < 2 ? 0.000_01 : 0.000_1
            }
            guard let delta = solve(matrix, vector) else { break }
            parameters[0] += min(
                initialBounds.width * 0.08,
                max(-initialBounds.width * 0.08, delta[0])
            )
            parameters[1] += min(
                initialBounds.height * 0.08,
                max(-initialBounds.height * 0.08, delta[1])
            )
            parameters[2] += min(0.10, max(-0.10, delta[2]))
            parameters[3] += min(0.10, max(-0.10, delta[3]))
            parameters[4] += min(0.07, max(-0.07, delta[4]))

            parameters[0] = min(
                initialBounds.center.x + centerLimitX,
                max(initialBounds.center.x - centerLimitX, parameters[0])
            )
            parameters[1] = min(
                initialBounds.center.y + centerLimitY,
                max(initialBounds.center.y - centerLimitY, parameters[1])
            )
            parameters[2] = log(
                min(maximumRadius, max(minimumRadius, exp(parameters[2])))
            )
            parameters[3] = log(
                min(maximumRadius, max(minimumRadius, exp(parameters[3])))
            )
        }

        var radiusX = exp(parameters[2])
        var radiusY = exp(parameters[3])
        var angle = parameters[4]
        if radiusY > radiusX {
            swap(&radiusX, &radiusY)
            angle += .pi / 2
        }
        angle = normalizedHalfTurnAngle(angle)
        let center = CGPoint(x: parameters[0], y: parameters[1])
        let normalized = [center.x, center.y, log(radiusX), log(radiusY), angle]
        let residuals = points.map {
            abs(ellipseResidual(normalized, point: $0))
        }
        return EllipseFit(
            center: center,
            radiusX: radiusX,
            radiusY: radiusY,
            angle: angle,
            residual: trimmedMean(residuals, trimUpperFraction: 0.12),
            angularCoverage: angularCoverage(
                points,
                center: center,
                radiusX: radiusX,
                radiusY: radiusY,
                angle: angle
            )
        )
    }

    private static func ellipseResidual(
        _ parameters: [CGFloat],
        point: CGPoint
    ) -> CGFloat {
        let center = CGPoint(x: parameters[0], y: parameters[1])
        let radiusX = max(exp(parameters[2]), 0.001)
        let radiusY = max(exp(parameters[3]), 0.001)
        let local = rotate(
            pointSubtract(point, center),
            by: -parameters[4]
        )
        return sqrt(
            local.x * local.x / (radiusX * radiusX)
                + local.y * local.y / (radiusY * radiusY)
        ) - 1
    }

    private static func fitRectangle(_ points: [CGPoint]) -> RectangleFit? {
        guard points.count >= 8 else { return nil }
        var directions: [(angle: CGFloat, length: CGFloat)] = []
        for (start, end) in zip(points, points.dropFirst() + [points[0]]) {
            let vector = pointSubtract(end, start)
            let length = hypot(vector.x, vector.y)
            if length > 0.001 {
                directions.append((atan2(vector.y, vector.x), length))
            }
        }
        guard !directions.isEmpty else { return nil }
        let lengthCap = max(
            quantile(directions.map(\.length), 0.80) * 1.8,
            0.001
        )
        var cosineSum: CGFloat = 0
        var sineSum: CGFloat = 0
        var totalWeight: CGFloat = 0
        for direction in directions {
            let weight = min(direction.length, lengthCap)
            cosineSum += cos(direction.angle * 4) * weight
            sineSum += sin(direction.angle * 4) * weight
            totalWeight += weight
        }
        guard totalWeight > 0 else { return nil }
        var angle = atan2(sineSum, cosineSum) / 4
        var bounds = orientedBounds(
            points,
            angle: angle,
            lowerQuantile: 0.025,
            upperQuantile: 0.975
        )
        if bounds.height > bounds.width {
            angle += .pi / 2
            bounds = orientedBounds(
                points,
                angle: angle,
                lowerQuantile: 0.025,
                upperQuantile: 0.975
            )
        }
        angle = normalizedHalfTurnAngle(angle)
        bounds = orientedBounds(
            points,
            angle: angle,
            lowerQuantile: 0.025,
            upperQuantile: 0.975
        )
        let concentration = hypot(cosineSum, sineSum) / totalWeight
        let corners = worldCorners(bounds)
        let diagonal = hypot(bounds.width, bounds.height)
        let cornerEvidence = corners.reduce(CGFloat.zero) { result, corner in
            let nearest = points.map { distance($0, corner) }.min() ?? diagonal
            return result + clamp01(1 - nearest / max(diagonal * 0.16, 0.001))
        } / 4

        let cosine = cos(bounds.angle)
        let sine = sin(bounds.angle)
        let normalizer = max(min(bounds.width, bounds.height), 0.001)
        var residuals: [CGFloat] = []
        var edgeCounts = Array(repeating: 0, count: 4)
        for point in points {
            let x = point.x * cosine + point.y * sine
            let y = -point.x * sine + point.y * cosine
            let distances = [
                abs(x - bounds.minX),
                abs(bounds.maxX - x),
                abs(y - bounds.minY),
                abs(bounds.maxY - y)
            ]
            let edge = distances.indices.min {
                distances[$0] < distances[$1]
            } ?? 0
            edgeCounts[edge] += 1
            residuals.append(distances[edge] / normalizer)
        }
        let minimumEdgeFraction = CGFloat(edgeCounts.min() ?? 0)
            / CGFloat(max(points.count, 1))
        return RectangleFit(
            bounds: bounds,
            directionConcentration: concentration,
            edgeResidual: trimmedMean(residuals, trimUpperFraction: 0.10),
            cornerEvidence: cornerEvidence,
            edgeOccupancy: clamp01(minimumEdgeFraction / 0.13),
            corners: corners
        )
    }

    private static func diamondEvidence(
        fit: RectangleFit,
        points: [CGPoint]
    ) -> CGFloat {
        let angleDistance = angleDistanceModulo(
            fit.bounds.angle,
            target: .pi / 4,
            period: .pi / 2
        )
        let angleEvidence = clamp01(1 - angleDistance / (.pi / 11))
        let center = fit.bounds.center
        let cardinalAngles: [CGFloat] = [0, .pi / 2, .pi, -.pi / 2]
        let cornerAngles = fit.corners.map {
            atan2($0.y - center.y, $0.x - center.x)
        }
        let cardinalEvidence = cardinalAngles.reduce(CGFloat.zero) { result, target in
            let nearest = cornerAngles.map {
                angleDistanceModulo($0, target: target, period: 2 * .pi)
            }.min() ?? .pi
            return result + clamp01(1 - nearest / (.pi / 9))
        } / 4

        let axisBounds = quantileBounds(points, lower: 0.025, upper: 0.975)
        let axisCorners = [
            CGPoint(x: axisBounds.minX, y: axisBounds.minY),
            CGPoint(x: axisBounds.maxX, y: axisBounds.minY),
            CGPoint(x: axisBounds.maxX, y: axisBounds.maxY),
            CGPoint(x: axisBounds.minX, y: axisBounds.maxY)
        ]
        let diagonal = max(hypot(axisBounds.width, axisBounds.height), 0.001)
        let axisCornerAbsence = axisCorners.reduce(CGFloat.zero) { result, corner in
            let nearest = points.map { distance($0, corner) }.min() ?? 0
            return result + clamp01(nearest / (diagonal * 0.22))
        } / 4
        return weighted([
            (angleEvidence, 0.40),
            (cardinalEvidence, 0.23),
            (fit.cornerEvidence, 0.22),
            (axisCornerAbsence, 0.15)
        ])
    }

    private static func orientedBounds(
        _ points: [CGPoint],
        angle: CGFloat,
        lowerQuantile: CGFloat,
        upperQuantile: CGFloat
    ) -> OrientedBounds {
        let cosine = cos(angle)
        let sine = sin(angle)
        let projectedX = points.map { $0.x * cosine + $0.y * sine }
        let projectedY = points.map { -$0.x * sine + $0.y * cosine }
        let minX = quantile(projectedX, lowerQuantile)
        let maxX = quantile(projectedX, upperQuantile)
        let minY = quantile(projectedY, lowerQuantile)
        let maxY = quantile(projectedY, upperQuantile)
        let localCenter = CGPoint(x: (minX + maxX) / 2, y: (minY + maxY) / 2)
        let center = CGPoint(
            x: localCenter.x * cosine - localCenter.y * sine,
            y: localCenter.x * sine + localCenter.y * cosine
        )
        return OrientedBounds(
            center: center,
            width: maxX - minX,
            height: maxY - minY,
            angle: angle,
            minX: minX,
            maxX: maxX,
            minY: minY,
            maxY: maxY
        )
    }

    private static func worldCorners(_ bounds: OrientedBounds) -> [CGPoint] {
        let cosine = cos(bounds.angle)
        let sine = sin(bounds.angle)
        return [
            CGPoint(x: bounds.minX, y: bounds.minY),
            CGPoint(x: bounds.maxX, y: bounds.minY),
            CGPoint(x: bounds.maxX, y: bounds.maxY),
            CGPoint(x: bounds.minX, y: bounds.maxY)
        ].map { point in
            CGPoint(
                x: point.x * cosine - point.y * sine,
                y: point.x * sine + point.y * cosine
            )
        }
    }

    private static func angularCoverage(
        _ points: [CGPoint],
        center: CGPoint,
        radiusX: CGFloat,
        radiusY: CGFloat,
        angle: CGFloat
    ) -> CGFloat {
        let angles = points.map { point -> CGFloat in
            let local = rotate(pointSubtract(point, center), by: -angle)
            return atan2(local.y / radiusY, local.x / radiusX)
        }.sorted()
        guard angles.count >= 2 else { return 0 }
        var maximumGap: CGFloat = 0
        for index in 0..<(angles.count - 1) {
            maximumGap = max(maximumGap, angles[index + 1] - angles[index])
        }
        maximumGap = max(maximumGap, angles[0] + 2 * .pi - angles[angles.count - 1])
        return clamp01(1 - maximumGap / (2 * .pi))
    }

    private static func fitLine(
        _ points: [CGPoint]
    ) -> (center: CGPoint, direction: CGPoint)? {
        guard points.count >= 2 else { return nil }
        let center = averagePoint(points)
        var xx: CGFloat = 0
        var xy: CGFloat = 0
        var yy: CGFloat = 0
        for point in points {
            let offset = pointSubtract(point, center)
            xx += offset.x * offset.x
            xy += offset.x * offset.y
            yy += offset.y * offset.y
        }
        let angle = 0.5 * atan2(2 * xy, xx - yy)
        return (center, CGPoint(x: cos(angle), y: sin(angle)))
    }

    private static func removeIsolatedSpikes(
        _ points: [CGPoint],
        zoomScale: CGFloat
    ) -> [CGPoint] {
        guard points.count >= 5 else { return points }
        var result = points
        for _ in 0..<2 {
            let bounds = quantileBounds(result, lower: 0.02, upper: 0.98)
            let diagonal = max(hypot(bounds.width, bounds.height), 1)
            let segmentLengths = zip(result, result.dropFirst()).map(distance)
            let typicalSpacing = max(median(segmentLengths), 0.1)
            var filtered = [result[0]]
            for index in 1..<(result.count - 1) {
                let previous = result[index - 1]
                let point = result[index]
                let next = result[index + 1]
                let chord = distance(previous, next)
                let detour = distance(previous, point) + distance(point, next)
                let deviation = distanceToSegment(point, start: previous, end: next)
                let threshold = max(
                    3 / zoomScale,
                    max(diagonal * 0.075, typicalSpacing * 5)
                )
                if deviation > threshold,
                   detour > max(chord * 2.25, typicalSpacing * 8) {
                    continue
                }
                filtered.append(point)
            }
            filtered.append(result[result.count - 1])
            if filtered.count == result.count {
                break
            }
            result = filtered
        }
        return result
    }

    private static func quantileBounds(
        _ points: [CGPoint],
        lower: CGFloat,
        upper: CGFloat
    ) -> CGRect {
        guard !points.isEmpty else { return .null }
        let minimumX = quantile(points.map(\.x), lower)
        let maximumX = quantile(points.map(\.x), upper)
        let minimumY = quantile(points.map(\.y), lower)
        let maximumY = quantile(points.map(\.y), upper)
        return CGRect(
            x: minimumX,
            y: minimumY,
            width: maximumX - minimumX,
            height: maximumY - minimumY
        )
    }

    private static func resample(_ points: [CGPoint], count: Int) -> [CGPoint] {
        guard points.count >= 2, count >= 2 else { return points }
        let totalLength = polylineLength(points)
        guard totalLength > 0 else { return [points[0]] }
        let interval = totalLength / CGFloat(count - 1)
        var result = [points[0]]
        var accumulated: CGFloat = 0
        var segmentStart = points[0]
        var index = 1

        while index < points.count && result.count < count - 1 {
            let segmentEnd = points[index]
            let segmentLength = distance(segmentStart, segmentEnd)
            if accumulated + segmentLength >= interval {
                let remainder = interval - accumulated
                let fraction = segmentLength > 0 ? remainder / segmentLength : 0
                let point = CGPoint(
                    x: segmentStart.x + (segmentEnd.x - segmentStart.x) * fraction,
                    y: segmentStart.y + (segmentEnd.y - segmentStart.y) * fraction
                )
                result.append(point)
                segmentStart = point
                accumulated = 0
            } else {
                accumulated += segmentLength
                segmentStart = segmentEnd
                index += 1
            }
        }
        result.append(points[points.count - 1])
        return result
    }

    private static func boundedPoints(
        _ points: [CGPoint],
        maximumCount: Int
    ) -> [CGPoint] {
        guard points.count > maximumCount else { return points }
        return resample(points, count: maximumCount)
    }

    private static func simplify(
        _ points: [CGPoint],
        tolerance: CGFloat
    ) -> [CGPoint] {
        guard points.count > 2 else { return points }
        var maximumDistance: CGFloat = 0
        var maximumIndex = 0
        for index in 1..<(points.count - 1) {
            let candidateDistance = distanceToSegment(
                points[index],
                start: points[0],
                end: points[points.count - 1]
            )
            if candidateDistance > maximumDistance {
                maximumDistance = candidateDistance
                maximumIndex = index
            }
        }
        if maximumDistance <= tolerance {
            return [points[0], points[points.count - 1]]
        }
        let first = simplify(
            Array(points[0...maximumIndex]),
            tolerance: tolerance
        )
        let second = simplify(
            Array(points[maximumIndex...]),
            tolerance: tolerance
        )
        return first.dropLast() + second
    }

    private static func selfIntersectionCount(
        _ points: [CGPoint],
        closureTolerance: CGFloat
    ) -> Int {
        guard points.count >= 5 else { return 0 }
        var count = 0
        for firstIndex in 0..<(points.count - 3) {
            for secondIndex in (firstIndex + 2)..<(points.count - 1) {
                if firstIndex == 0 && secondIndex == points.count - 2 {
                    continue
                }
                if segmentsIntersect(
                    points[firstIndex],
                    points[firstIndex + 1],
                    points[secondIndex],
                    points[secondIndex + 1],
                    tolerance: closureTolerance
                ) {
                    count += 1
                }
            }
        }
        return count
    }

    private static func segmentsIntersect(
        _ a: CGPoint,
        _ b: CGPoint,
        _ c: CGPoint,
        _ d: CGPoint,
        tolerance: CGFloat
    ) -> Bool {
        if min(distance(a, c), distance(a, d), distance(b, c), distance(b, d))
            <= tolerance {
            return false
        }
        let abC = orientation(a, b, c)
        let abD = orientation(a, b, d)
        let cdA = orientation(c, d, a)
        let cdB = orientation(c, d, b)
        return abC * abD < 0 && cdA * cdB < 0
    }

    private static func orientation(
        _ a: CGPoint,
        _ b: CGPoint,
        _ c: CGPoint
    ) -> CGFloat {
        cross(pointSubtract(b, a), pointSubtract(c, a))
    }

    private static func polygonArea(_ points: [CGPoint]) -> CGFloat {
        guard points.count >= 3 else { return 0 }
        var result: CGFloat = 0
        for index in points.indices {
            let next = points[(index + 1) % points.count]
            result += points[index].x * next.y - next.x * points[index].y
        }
        return result / 2
    }

    private static func deduplicated(
        _ points: [CGPoint],
        minimumSpacing: CGFloat
    ) -> [CGPoint] {
        guard let first = points.first else { return [] }
        var result = [first]
        for point in points.dropFirst()
            where distance(result[result.count - 1], point) >= minimumSpacing {
            result.append(point)
        }
        if let last = points.last, result.last != last {
            result.append(last)
        }
        return result
    }

    private static func averagePoint(_ points: [CGPoint]) -> CGPoint {
        guard !points.isEmpty else { return .zero }
        let total = points.reduce(CGPoint.zero) {
            CGPoint(x: $0.x + $1.x, y: $0.y + $1.y)
        }
        return CGPoint(
            x: total.x / CGFloat(points.count),
            y: total.y / CGFloat(points.count)
        )
    }

    private static func polylineLength(_ points: [CGPoint]) -> CGFloat {
        zip(points, points.dropFirst()).reduce(0) {
            $0 + distance($1.0, $1.1)
        }
    }

    private static func distanceToSegment(
        _ point: CGPoint,
        start: CGPoint,
        end: CGPoint
    ) -> CGFloat {
        let segment = pointSubtract(end, start)
        let lengthSquared = dot(segment, segment)
        guard lengthSquared > 0 else { return distance(point, start) }
        let offset = pointSubtract(point, start)
        let parameter = min(1, max(0, dot(offset, segment) / lengthSquared))
        let projection = CGPoint(
            x: start.x + segment.x * parameter,
            y: start.y + segment.y * parameter
        )
        return distance(point, projection)
    }

    private static func ellipsePerimeter(
        radiusX: CGFloat,
        radiusY: CGFloat
    ) -> CGFloat {
        let sum = radiusX + radiusY
        guard sum > 0 else { return 0 }
        let h = pow((radiusX - radiusY) / sum, 2)
        return .pi * sum * (
            1 + 3 * h / (10 + sqrt(max(4 - 3 * h, 0.001)))
        )
    }

    private static func perimeterScore(
        actual: CGFloat,
        expected: CGFloat
    ) -> CGFloat {
        guard expected > 0 else { return 0 }
        return score(actual / expected, ideal: 1, tolerance: 0.62)
    }

    private static func quantile(
        _ values: [CGFloat],
        _ fraction: CGFloat
    ) -> CGFloat {
        guard !values.isEmpty else { return 0 }
        let sorted = values.sorted()
        let position = min(1, max(0, fraction)) * CGFloat(sorted.count - 1)
        let lower = Int(floor(position))
        let upper = Int(ceil(position))
        guard lower != upper else { return sorted[lower] }
        let amount = position - CGFloat(lower)
        return sorted[lower] + (sorted[upper] - sorted[lower]) * amount
    }

    private static func median(_ values: [CGFloat]) -> CGFloat {
        quantile(values, 0.5)
    }

    private static func trimmedMean(
        _ values: [CGFloat],
        trimUpperFraction: CGFloat
    ) -> CGFloat {
        guard !values.isEmpty else { return 0 }
        let sorted = values.sorted()
        let retainedCount = max(
            1,
            sorted.count - Int(CGFloat(sorted.count) * trimUpperFraction)
        )
        return sorted.prefix(retainedCount).reduce(0, +) / CGFloat(retainedCount)
    }

    private static func huberWeight(
        residual: CGFloat,
        scale: CGFloat,
        cutoff: CGFloat
    ) -> CGFloat {
        let normalized = abs(residual) / max(scale * cutoff, 0.000_001)
        return normalized <= 1 ? 1 : 1 / normalized
    }

    private static func solve(
        _ inputMatrix: [[CGFloat]],
        _ inputVector: [CGFloat]
    ) -> [CGFloat]? {
        let count = inputVector.count
        guard inputMatrix.count == count,
              inputMatrix.allSatisfy({ $0.count == count }) else {
            return nil
        }
        var matrix = inputMatrix
        var vector = inputVector
        for column in 0..<count {
            guard let pivotRow = (column..<count).max(by: {
                abs(matrix[$0][column]) < abs(matrix[$1][column])
            }), abs(matrix[pivotRow][column]) > 0.000_000_001 else {
                return nil
            }
            if pivotRow != column {
                matrix.swapAt(pivotRow, column)
                vector.swapAt(pivotRow, column)
            }
            let pivot = matrix[column][column]
            for row in (column + 1)..<count {
                let factor = matrix[row][column] / pivot
                guard factor.isFinite else { return nil }
                for innerColumn in column..<count {
                    matrix[row][innerColumn] -= factor * matrix[column][innerColumn]
                }
                vector[row] -= factor * vector[column]
            }
        }

        var result = Array(repeating: CGFloat.zero, count: count)
        for row in stride(from: count - 1, through: 0, by: -1) {
            var value = vector[row]
            if row + 1 < count {
                for column in (row + 1)..<count {
                    value -= matrix[row][column] * result[column]
                }
            }
            guard abs(matrix[row][row]) > 0.000_000_001 else { return nil }
            result[row] = value / matrix[row][row]
            guard result[row].isFinite else { return nil }
        }
        return result
    }

    private static func angleDistanceModulo(
        _ angle: CGFloat,
        target: CGFloat,
        period: CGFloat
    ) -> CGFloat {
        var delta = (angle - target).truncatingRemainder(dividingBy: period)
        if delta > period / 2 {
            delta -= period
        } else if delta < -period / 2 {
            delta += period
        }
        return abs(delta)
    }

    private static func normalizedHalfTurnAngle(_ angle: CGFloat) -> CGFloat {
        var value = angle.truncatingRemainder(dividingBy: .pi)
        if value >= .pi / 2 {
            value -= .pi
        } else if value < -.pi / 2 {
            value += .pi
        }
        return value
    }

    private static func rotate(_ point: CGPoint, by angle: CGFloat) -> CGPoint {
        let cosine = cos(angle)
        let sine = sin(angle)
        return CGPoint(
            x: point.x * cosine - point.y * sine,
            y: point.x * sine + point.y * cosine
        )
    }

    private static func unitVector(
        from start: CGPoint,
        to end: CGPoint
    ) -> CGPoint {
        let vector = pointSubtract(end, start)
        let length = hypot(vector.x, vector.y)
        guard length > 0 else { return CGPoint(x: 1, y: 0) }
        return CGPoint(x: vector.x / length, y: vector.y / length)
    }

    private static func pointAdd(_ lhs: CGPoint, _ rhs: CGPoint) -> CGPoint {
        CGPoint(x: lhs.x + rhs.x, y: lhs.y + rhs.y)
    }

    private static func pointSubtract(_ lhs: CGPoint, _ rhs: CGPoint) -> CGPoint {
        CGPoint(x: lhs.x - rhs.x, y: lhs.y - rhs.y)
    }

    private static func pointMultiply(
        _ point: CGPoint,
        _ value: CGFloat
    ) -> CGPoint {
        CGPoint(x: point.x * value, y: point.y * value)
    }

    private static func dot(_ lhs: CGPoint, _ rhs: CGPoint) -> CGFloat {
        lhs.x * rhs.x + lhs.y * rhs.y
    }

    private static func cross(_ lhs: CGPoint, _ rhs: CGPoint) -> CGFloat {
        lhs.x * rhs.y - lhs.y * rhs.x
    }

    private static func distance(_ lhs: CGPoint, _ rhs: CGPoint) -> CGFloat {
        hypot(lhs.x - rhs.x, lhs.y - rhs.y)
    }

    private static func score(
        _ value: CGFloat,
        ideal: CGFloat,
        tolerance: CGFloat
    ) -> CGFloat {
        clamp01(1 - abs(value - ideal) / max(tolerance, 0.001))
    }

    private static func weighted(
        _ values: [(CGFloat, CGFloat)]
    ) -> CGFloat {
        let weight = values.reduce(CGFloat.zero) { $0 + $1.1 }
        guard weight > 0 else { return 0 }
        return values.reduce(CGFloat.zero) { $0 + $1.0 * $1.1 } / weight
    }

    private static func clamp01(_ value: CGFloat) -> CGFloat {
        min(1, max(0, value))
    }
}
