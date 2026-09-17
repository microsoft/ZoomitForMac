import CoreGraphics
import Foundation

enum AnnotationRoughStroke {
    private enum Segment {
        case line(CGPoint)
        case quad(control: CGPoint, end: CGPoint)
        case cubic(control1: CGPoint, control2: CGPoint, end: CGPoint)

        var end: CGPoint {
            switch self {
            case .line(let point):
                point
            case .quad(_, let end), .cubic(_, _, let end):
                end
            }
        }

        var isLine: Bool {
            if case .line = self {
                return true
            }
            return false
        }
    }

    private struct Subpath {
        var start: CGPoint
        var segments: [Segment] = []
        var isClosed = false
    }

    private struct Profile {
        var endpointNormal: CGFloat
        var tangentExtension: CGFloat
        var controlNormal: CGFloat
        var cornerCap: CGFloat
        var minimumRandomMagnitude: CGFloat
        var minimumExtensionFraction: CGFloat
        var passNormalBias: CGFloat
    }

    private struct SeededGenerator {
        private var state: UInt64

        init(seed: UInt64) {
            state = seed
        }

        mutating func signedUnit() -> CGFloat {
            state &+= 0x9E37_79B9_7F4A_7C15
            var value = state
            value = (value ^ (value >> 30)) &* 0xBF58_476D_1CE4_E5B9
            value = (value ^ (value >> 27)) &* 0x94D0_49BB_1331_11EB
            value ^= value >> 31
            let unit = Double(value >> 11) / Double(1 << 53)
            return CGFloat(unit * 2 - 1)
        }

        mutating func unit() -> CGFloat {
            (signedUnit() + 1) / 2
        }
    }

    static func paths(
        for canonicalPath: CGPath,
        sloppiness: AnnotationSloppiness,
        elementID: AnnotationElementID,
        strokeWidth: CGFloat,
        salt: UInt64 = 0,
        pinnedPoints: [CGPoint] = [],
        destinationScale: CGFloat = 1,
        passCount: Int? = nil,
        independentClosedCorners: Bool = false,
        maximumDeviation: CGFloat? = nil
    ) -> [CGPath] {
        guard sloppiness != .architect else { return [canonicalPath] }

        let subpaths = parse(canonicalPath)
        guard !subpaths.isEmpty else { return [canonicalPath] }
        let scale = max(destinationScale, 0.001)
        let profile = profile(
            for: sloppiness,
            strokeWidth: strokeWidth,
            maximumDeviation: maximumDeviation
        )
        let resolvedPassCount = max(1, passCount ?? 2)
        let baseSeed = roughSeed(for: elementID)
            ^ mixed(salt)

        return (0..<resolvedPassCount).map { pass in
            let path = CGMutablePath()
            let passProfile = profileForPass(
                profile,
                pass: pass,
                sloppiness: sloppiness,
                strokeWidth: strokeWidth
            )
            for (index, subpath) in subpaths.enumerated() {
                let subpathSeed = baseSeed
                    ^ mixed(UInt64(pass + 1) &* 0xBF58_476D_1CE4_E5B9)
                    ^ mixed(UInt64(index + 1) &* 0x94D0_49BB_1331_11EB)
                if independentClosedCorners,
                   subpath.isClosed,
                   subpath.segments.allSatisfy(\.isLine) {
                    appendIndependentClosedLines(
                        subpath,
                        to: path,
                        profile: passProfile,
                        destinationScale: scale,
                        pinnedPoints: pinnedPoints,
                        seed: subpathSeed
                    )
                } else {
                    appendContinuous(
                        subpath,
                        to: path,
                        profile: passProfile,
                        destinationScale: scale,
                        pinnedPoints: pinnedPoints,
                        seed: subpathSeed
                    )
                }
            }
            return path
        }
    }

    static func ellipsePaths(
        in bounds: CGRect,
        sloppiness: AnnotationSloppiness,
        elementID: AnnotationElementID,
        strokeWidth: CGFloat,
        salt: UInt64 = 0,
        destinationScale: CGFloat = 1,
        passCount: Int? = nil,
        maximumDeviation: CGFloat? = nil
    ) -> [CGPath] {
        let canonical = CGMutablePath()
        canonical.addEllipse(in: bounds)
        guard sloppiness != .architect,
              bounds.width > 0,
              bounds.height > 0 else {
            return [canonical]
        }

        let scale = max(destinationScale, 0.001)
        let profile = profile(
            for: sloppiness,
            strokeWidth: strokeWidth,
            maximumDeviation: maximumDeviation
        )
        let count = ellipseSampleCount(in: bounds, destinationScale: scale)
        let radiusX = bounds.width / 2
        let radiusY = bounds.height / 2
        let edgeScale = lengthScale(max(bounds.width, bounds.height) * scale)
        let resolvedPassCount = max(1, passCount ?? 2)
        let baseSeed = roughSeed(for: elementID)
            ^ mixed(salt)

        return (0..<resolvedPassCount).map { pass in
            var generator = SeededGenerator(
                seed: baseSeed ^ mixed(UInt64(pass + 1) &* 0xBF58_476D_1CE4_E5B9)
            )
            let passProfile = profileForPass(
                profile,
                pass: pass,
                sloppiness: sloppiness,
                strokeWidth: strokeWidth
            )
            let normalPhase = generator.unit() * 2 * .pi
            let secondaryPhase = generator.unit() * 2 * .pi
            let tangentPhase = generator.unit() * 2 * .pi
            let primaryNormal = signedMagnitude(
                generator.signedUnit(),
                minimum: passProfile.minimumRandomMagnitude
            ) * passProfile.controlNormal + passProfile.passNormalBias
            let secondaryNormal = signedMagnitude(
                generator.signedUnit(),
                minimum: passProfile.minimumRandomMagnitude * 0.5
            )
                * passProfile.controlNormal
                * 0.45
            let tangentAmplitude = signedMagnitude(
                generator.signedUnit(),
                minimum: passProfile.minimumRandomMagnitude * 0.4
            )
                * passProfile.tangentExtension
                * 0.1
            let points = (0..<count).map { index -> CGPoint in
                let angle = CGFloat(index) * 2 * .pi / CGFloat(count)
                let cosine = cos(angle)
                let sine = sin(angle)
                let point = CGPoint(
                    x: bounds.midX + radiusX * cosine,
                    y: bounds.midY + radiusY * sine
                )
                let gradient = normalized(
                    CGPoint(
                        x: cosine / max(radiusX, 0.001),
                        y: sine / max(radiusY, 0.001)
                    )
                )
                let tangent = CGPoint(x: -gradient.y, y: gradient.x)
                let normalPixels = (
                    sin(angle + normalPhase) * primaryNormal
                        + sin(angle * 2 + secondaryPhase) * secondaryNormal
                ) * edgeScale
                let tangentPixels = sin(angle + tangentPhase)
                    * tangentAmplitude
                    * edgeScale
                let offset = clampedOffset(
                    tangent: tangent * tangentPixels,
                    normal: gradient * normalPixels,
                    cap: passProfile.cornerCap
                ) / scale
                return point + offset
            }
            return smoothClosedPath(through: points)
        }
    }

    static func pressurePaths(
        samples: [AnnotationPointSample],
        baseWidth: CGFloat,
        sloppiness: AnnotationSloppiness,
        elementID: AnnotationElementID,
        salt: UInt64,
        destinationScale: CGFloat,
        startingArcLength: CGFloat = 0,
        passCount: Int? = nil
    ) -> [CGPath] {
        guard samples.count > 1 else { return [] }
        let scale = max(destinationScale, 0.001)
        let count = max(
            1,
            passCount ?? (sloppiness == .architect ? 1 : 2)
        )
        let sourceLocations = samples.map(\.location)
        let profile = profile(
            for: sloppiness,
            strokeWidth: baseWidth,
            maximumDeviation: nil
        )
        let distances = cumulativeDistances(sourceLocations)
        let baseSeed = roughSeed(for: elementID)
            ^ mixed(salt)

        return (0..<count).map { pass in
            var generator = SeededGenerator(
                seed: baseSeed ^ mixed(UInt64(pass + 1) &* 0xBF58_476D_1CE4_E5B9)
            )
            let passProfile = profileForPass(
                profile,
                pass: pass,
                sloppiness: sloppiness,
                strokeWidth: baseWidth
            )
            let normalPhase = generator.unit() * 2 * .pi
            let secondaryPhase = generator.unit() * 2 * .pi
            let tangentPhase = generator.unit() * 2 * .pi
            let primaryNormal = signedMagnitude(
                generator.signedUnit(),
                minimum: passProfile.minimumRandomMagnitude
            ) * passProfile.controlNormal + passProfile.passNormalBias
            let secondaryNormal = signedMagnitude(
                generator.signedUnit(),
                minimum: passProfile.minimumRandomMagnitude * 0.5
            )
                * passProfile.controlNormal
                * 0.35
            let tangentAmplitude = signedMagnitude(
                generator.signedUnit(),
                minimum: passProfile.minimumRandomMagnitude * 0.4
            )
                * passProfile.tangentExtension
                * 0.06
            let locations: [CGPoint]
            if sloppiness == .architect {
                locations = sourceLocations
            } else {
                locations = samples.indices.map { index in
                    let point = samples[index].location
                    let tangent = sampleTangent(
                        locations: sourceLocations,
                        at: index
                    )
                    let normal = CGPoint(x: -tangent.y, y: tangent.x)
                    let absoluteDistance = (startingArcLength + distances[index]) * scale
                    let edgeScale = lengthScale(
                        min(180, absoluteDistance + 24)
                    )
                    let angle = absoluteDistance * .pi / 90
                    let normalPixels = (
                        sin(angle + normalPhase) * primaryNormal
                            + sin(angle * 2 + secondaryPhase) * secondaryNormal
                    ) * edgeScale
                    let tangentPixels = sin(angle + tangentPhase)
                        * tangentAmplitude
                        * edgeScale
                    let offset = clampedOffset(
                        tangent: tangent * tangentPixels,
                        normal: normal * normalPixels,
                        cap: passProfile.cornerCap
                    ) / scale
                    return point + offset
                }
            }
            return pressureOutlinePath(
                locations: locations,
                pressures: samples.map(\.pressure),
                baseWidth: baseWidth,
                destinationScale: scale
            )
        }
    }

    static func endpoints(of path: CGPath) -> (start: CGPoint, end: CGPoint)? {
        guard let subpath = parse(path).first,
              !subpath.isClosed,
              let end = subpath.segments.last?.end else {
            return nil
        }
        return (subpath.start, end)
    }

    static func maximumDestinationDeviation(
        for sloppiness: AnnotationSloppiness
    ) -> CGFloat {
        switch sloppiness {
        case .architect: 0
        case .artist: 5.5
        case .cartoonist: 11
        }
    }

    static func maximumDestinationDeviation(
        for sloppiness: AnnotationSloppiness,
        strokeWidth: CGFloat
    ) -> CGFloat {
        let widthScale = profileWidthScale(strokeWidth)
        return switch sloppiness {
        case .architect: 0
        case .artist: 5.5 * widthScale
        case .cartoonist: 11 * widthScale
        }
    }

    static func ellipseSampleCount(
        in bounds: CGRect,
        destinationScale: CGFloat
    ) -> Int {
        let radiusX = max(bounds.width / 2, 0)
        let radiusY = max(bounds.height / 2, 0)
        guard radiusX > 0, radiusY > 0 else { return 0 }
        let h = pow(radiusX - radiusY, 2) / pow(radiusX + radiusY, 2)
        let perimeter = .pi * (radiusX + radiusY)
            * (1 + 3 * h / (10 + sqrt(max(0, 4 - 3 * h))))
            * max(destinationScale, 0.001)
        return max(12, min(48, Int(ceil(perimeter / 24))))
    }

    static func pathElementCount(_ path: CGPath) -> Int {
        var count = 0
        path.applyWithBlock { _ in count += 1 }
        return count
    }

    static func pathMoveCount(_ path: CGPath) -> Int {
        var count = 0
        path.applyWithBlock {
            if $0.pointee.type == .moveToPoint {
                count += 1
            }
        }
        return count
    }

    static func sampledPoints(
        on path: CGPath,
        curveSubdivisions: Int = 8
    ) -> [CGPoint] {
        let steps = max(2, curveSubdivisions)
        var points: [CGPoint] = []
        var current = CGPoint.zero
        var subpathStart = CGPoint.zero
        path.applyWithBlock { pointer in
            let element = pointer.pointee
            switch element.type {
            case .moveToPoint:
                current = element.points[0]
                subpathStart = current
                points.append(current)
            case .addLineToPoint:
                current = element.points[0]
                points.append(current)
            case .addQuadCurveToPoint:
                let start = current
                let control = element.points[0]
                let end = element.points[1]
                for step in 1...steps {
                    let t = CGFloat(step) / CGFloat(steps)
                    let oneMinusT = 1 - t
                    points.append(
                        start * (oneMinusT * oneMinusT)
                            + control * (2 * oneMinusT * t)
                            + end * (t * t)
                    )
                }
                current = end
            case .addCurveToPoint:
                let start = current
                let control1 = element.points[0]
                let control2 = element.points[1]
                let end = element.points[2]
                for step in 1...steps {
                    let t = CGFloat(step) / CGFloat(steps)
                    let oneMinusT = 1 - t
                    points.append(
                        start * (oneMinusT * oneMinusT * oneMinusT)
                            + control1 * (3 * oneMinusT * oneMinusT * t)
                            + control2 * (3 * oneMinusT * t * t)
                            + end * (t * t * t)
                    )
                }
                current = end
            case .closeSubpath:
                current = subpathStart
                points.append(current)
            @unknown default:
                break
            }
        }
        return points
    }

    static func roughSeed(for elementID: AnnotationElementID) -> UInt64 {
        elementID.rawValue.uuidString.utf8.reduce(0xCBF2_9CE4_8422_2325) {
            ($0 ^ UInt64($1)) &* 0x0000_0100_0000_01B3
        }
    }

    private static func appendContinuous(
        _ subpath: Subpath,
        to path: CGMutablePath,
        profile: Profile,
        destinationScale: CGFloat,
        pinnedPoints: [CGPoint],
        seed: UInt64
    ) {
        guard let firstSegment = subpath.segments.first else {
            path.move(to: subpath.start)
            return
        }

        var firstGenerator = SeededGenerator(seed: seed ^ mixed(1))
        let firstTangent = normalized(firstSegment.end - subpath.start)
        let roughStart = roughEndpoint(
            subpath.start,
            tangent: firstTangent,
            edgeScale: lengthScale(
                distance(subpath.start, firstSegment.end) * destinationScale
            ),
            profile: profile,
            destinationScale: destinationScale,
            preserve: isPinned(subpath.start, in: pinnedPoints),
            tangentExtensionDirection: subpath.isClosed ? 0 : -1,
            generator: &firstGenerator
        )
        path.move(to: roughStart)
        var current = roughStart
        var canonicalStart = subpath.start

        for (index, segment) in subpath.segments.enumerated() {
            var generator = SeededGenerator(
                seed: seed ^ mixed(UInt64(index + 1) &* 0x9E37_79B9_7F4A_7C15)
            )
            let canonicalEnd = segment.end
            let edgeLength = distance(canonicalStart, canonicalEnd)
            let edgeScale = lengthScale(edgeLength * destinationScale)
            let tangent = normalized(canonicalEnd - canonicalStart)
            let isFinalOpenEndpoint = !subpath.isClosed
                && index == subpath.segments.count - 1
            let roughEnd = roughEndpoint(
                canonicalEnd,
                tangent: tangent,
                edgeScale: edgeScale,
                profile: profile,
                destinationScale: destinationScale,
                preserve: isPinned(canonicalEnd, in: pinnedPoints),
                tangentExtensionDirection: isFinalOpenEndpoint ? 1 : 0,
                generator: &generator
            )

            switch segment {
            case .line:
                appendRoughLine(
                    from: current,
                    to: roughEnd,
                    canonicalStart: canonicalStart,
                    canonicalEnd: canonicalEnd,
                    profile: profile,
                    edgeScale: edgeScale,
                    destinationScale: destinationScale,
                    generator: &generator,
                    to: path
                )
            case .quad(let control, _):
                let roughControl = roughCurveControl(
                    control,
                    canonicalStart: canonicalStart,
                    canonicalEnd: canonicalEnd,
                    profile: profile,
                    edgeScale: edgeScale,
                    destinationScale: destinationScale,
                    preserve: isPinned(control, in: pinnedPoints),
                    generator: &generator
                )
                path.addQuadCurve(to: roughEnd, control: roughControl)
            case .cubic(let control1, let control2, _):
                let roughControl1 = roughCurveControl(
                    control1,
                    canonicalStart: canonicalStart,
                    canonicalEnd: canonicalEnd,
                    profile: profile,
                    edgeScale: edgeScale,
                    destinationScale: destinationScale,
                    preserve: isPinned(control1, in: pinnedPoints),
                    generator: &generator
                )
                let roughControl2 = roughCurveControl(
                    control2,
                    canonicalStart: canonicalStart,
                    canonicalEnd: canonicalEnd,
                    profile: profile,
                    edgeScale: edgeScale,
                    destinationScale: destinationScale,
                    preserve: isPinned(control2, in: pinnedPoints),
                    generator: &generator
                )
                path.addCurve(
                    to: roughEnd,
                    control1: roughControl1,
                    control2: roughControl2
                )
            }
            current = roughEnd
            canonicalStart = canonicalEnd
        }

        if subpath.isClosed {
            let canonicalEnd = subpath.start
            let edgeLength = distance(canonicalStart, canonicalEnd)
            if edgeLength > 0.000_1 {
                var generator = SeededGenerator(
                    seed: seed ^ mixed(UInt64(subpath.segments.count + 1)
                        &* 0x9E37_79B9_7F4A_7C15)
                )
                appendRoughLine(
                    from: current,
                    to: roughStart,
                    canonicalStart: canonicalStart,
                    canonicalEnd: canonicalEnd,
                    profile: profile,
                    edgeScale: lengthScale(edgeLength * destinationScale),
                    destinationScale: destinationScale,
                    generator: &generator,
                    to: path
                )
            }
            path.closeSubpath()
        }
    }

    private static func appendIndependentClosedLines(
        _ subpath: Subpath,
        to path: CGMutablePath,
        profile: Profile,
        destinationScale: CGFloat,
        pinnedPoints: [CGPoint],
        seed: UInt64
    ) {
        let vertices = [subpath.start] + subpath.segments.map(\.end)
        guard vertices.count > 1 else { return }
        let sideCount = vertices.count
        for index in 0..<sideCount {
            let canonicalStart = vertices[index]
            let canonicalEnd = vertices[(index + 1) % sideCount]
            let edgeLength = distance(canonicalStart, canonicalEnd)
            guard edgeLength > 0.000_1 else { continue }
            let edgeScale = lengthScale(edgeLength * destinationScale)
            let tangent = normalized(canonicalEnd - canonicalStart)
            let normal = CGPoint(x: -tangent.y, y: tangent.x)
            var generator = SeededGenerator(
                seed: seed ^ mixed(UInt64(index + 1) &* 0xDB4F_0B91_75AE_2165)
            )
            let startOvershoot = unitMagnitude(
                generator.unit(),
                minimum: profile.minimumExtensionFraction
            )
                * profile.tangentExtension
                * edgeScale
            let endOvershoot = unitMagnitude(
                generator.unit(),
                minimum: profile.minimumExtensionFraction
            )
                * profile.tangentExtension
                * edgeScale
            let startNormal = signedMagnitude(
                generator.signedUnit(),
                minimum: profile.minimumRandomMagnitude
            )
                * profile.endpointNormal
                * edgeScale
                + profile.passNormalBias * 0.6 * edgeScale
            let endNormal = signedMagnitude(
                generator.signedUnit(),
                minimum: profile.minimumRandomMagnitude
            )
                * profile.endpointNormal
                * edgeScale
                - profile.passNormalBias * 0.35 * edgeScale
            let startOffset = clampedOffset(
                tangent: tangent * -startOvershoot,
                normal: normal * startNormal,
                cap: profile.cornerCap
            ) / destinationScale
            let endOffset = clampedOffset(
                tangent: tangent * endOvershoot,
                normal: normal * endNormal,
                cap: profile.cornerCap
            ) / destinationScale
            let roughStart = isPinned(canonicalStart, in: pinnedPoints)
                ? canonicalStart
                : canonicalStart + startOffset
            let roughEnd = isPinned(canonicalEnd, in: pinnedPoints)
                ? canonicalEnd
                : canonicalEnd + endOffset

            path.move(to: roughStart)
            appendRoughLine(
                from: roughStart,
                to: roughEnd,
                canonicalStart: canonicalStart,
                canonicalEnd: canonicalEnd,
                profile: profile,
                edgeScale: edgeScale,
                destinationScale: destinationScale,
                generator: &generator,
                to: path
            )
        }
    }

    private static func appendRoughLine(
        from start: CGPoint,
        to end: CGPoint,
        canonicalStart: CGPoint,
        canonicalEnd: CGPoint,
        profile: Profile,
        edgeScale: CGFloat,
        destinationScale: CGFloat,
        generator: inout SeededGenerator,
        to path: CGMutablePath
    ) {
        let tangent = normalized(canonicalEnd - canonicalStart)
        guard tangent != .zero else {
            path.addLine(to: end)
            return
        }
        let normal = CGPoint(x: -tangent.y, y: tangent.x)
        let firstNormal = signedMagnitude(
            generator.signedUnit(),
            minimum: profile.minimumRandomMagnitude
        )
            * profile.controlNormal
            * edgeScale
            + profile.passNormalBias * edgeScale
        let secondNormal = signedMagnitude(
            generator.signedUnit(),
            minimum: profile.minimumRandomMagnitude
        )
            * profile.controlNormal
            * edgeScale
            - profile.passNormalBias * 0.45 * edgeScale
        let firstOffset = clampedOffset(
            tangent: .zero,
            normal: normal * firstNormal,
            cap: profile.cornerCap
        ) / destinationScale
        let secondOffset = clampedOffset(
            tangent: .zero,
            normal: normal * secondNormal,
            cap: profile.cornerCap
        ) / destinationScale
        path.addCurve(
            to: end,
            control1: interpolate(start, end, 0.32) + firstOffset,
            control2: interpolate(start, end, 0.68) + secondOffset
        )
    }

    private static func roughEndpoint(
        _ point: CGPoint,
        tangent: CGPoint,
        edgeScale: CGFloat,
        profile: Profile,
        destinationScale: CGFloat,
        preserve: Bool,
        tangentExtensionDirection: CGFloat,
        generator: inout SeededGenerator
    ) -> CGPoint {
        guard !preserve, tangent != .zero else { return point }
        let normal = CGPoint(x: -tangent.y, y: tangent.x)
        let normalPixels = signedMagnitude(
            generator.signedUnit(),
            minimum: profile.minimumRandomMagnitude
        )
            * profile.endpointNormal
            * edgeScale
            + profile.passNormalBias * 0.6 * edgeScale
        let tangentPixels = unitMagnitude(
            generator.unit(),
            minimum: profile.minimumExtensionFraction
        )
            * profile.tangentExtension
            * edgeScale
            * tangentExtensionDirection
        let offset = clampedOffset(
            tangent: tangent * tangentPixels,
            normal: normal * normalPixels,
            cap: profile.cornerCap
        ) / destinationScale
        return point + offset
    }

    private static func roughCurveControl(
        _ point: CGPoint,
        canonicalStart: CGPoint,
        canonicalEnd: CGPoint,
        profile: Profile,
        edgeScale: CGFloat,
        destinationScale: CGFloat,
        preserve: Bool,
        generator: inout SeededGenerator
    ) -> CGPoint {
        guard !preserve else { return point }
        let tangent = normalized(canonicalEnd - canonicalStart)
        guard tangent != .zero else { return point }
        let normal = CGPoint(x: -tangent.y, y: tangent.x)
        let normalPixels = signedMagnitude(
            generator.signedUnit(),
            minimum: profile.minimumRandomMagnitude
        )
            * profile.controlNormal
            * edgeScale
            + profile.passNormalBias * edgeScale
        let offset = clampedOffset(
            tangent: .zero,
            normal: normal * normalPixels,
            cap: profile.cornerCap
        ) / destinationScale
        return point + offset
    }

    private static func profile(
        for sloppiness: AnnotationSloppiness,
        strokeWidth: CGFloat,
        maximumDeviation: CGFloat?
    ) -> Profile {
        let widthScale = profileWidthScale(strokeWidth)
        var result: Profile
        switch sloppiness {
        case .architect:
            result = Profile(
                endpointNormal: 0,
                tangentExtension: 0,
                controlNormal: 0,
                cornerCap: 0,
                minimumRandomMagnitude: 0,
                minimumExtensionFraction: 0,
                passNormalBias: 0
            )
        case .artist:
            result = Profile(
                endpointNormal: 2 * widthScale,
                tangentExtension: 3.2 * widthScale,
                controlNormal: 3 * widthScale,
                cornerCap: 5.5 * widthScale,
                minimumRandomMagnitude: 0.35,
                minimumExtensionFraction: 0.25,
                passNormalBias: 0
            )
        case .cartoonist:
            result = Profile(
                endpointNormal: 4.5 * widthScale,
                tangentExtension: 8 * widthScale,
                controlNormal: 6 * widthScale,
                cornerCap: 11 * widthScale,
                minimumRandomMagnitude: 0.65,
                minimumExtensionFraction: 0.65,
                passNormalBias: 0
            )
        }
        if let maximumDeviation {
            result.cornerCap = min(result.cornerCap, max(0, maximumDeviation))
        }
        return result
    }

    private static func profileForPass(
        _ profile: Profile,
        pass: Int,
        sloppiness: AnnotationSloppiness,
        strokeWidth: CGFloat
    ) -> Profile {
        var result = profile
        let direction: CGFloat = pass.isMultiple(of: 2) ? -1 : 1
        result.passNormalBias = switch sloppiness {
        case .architect:
            0
        case .artist:
            direction * 0.7 * profileWidthScale(strokeWidth)
        case .cartoonist:
            direction * 4.2 * profileWidthScale(strokeWidth)
        }
        return result
    }

    private static func profileWidthScale(_ strokeWidth: CGFloat) -> CGFloat {
        let normalizedWidth = max(CGFloat(1), strokeWidth)
        let growth = (sqrt(normalizedWidth) - CGFloat(1)) * 0.18
        return 1 + min(CGFloat(0.35), max(CGFloat.zero, growth))
    }

    private static func signedMagnitude(
        _ value: CGFloat,
        minimum: CGFloat
    ) -> CGFloat {
        let sign: CGFloat = value < 0 ? -1 : 1
        return sign * max(abs(value), min(max(minimum, 0), 1))
    }

    private static func unitMagnitude(
        _ value: CGFloat,
        minimum: CGFloat
    ) -> CGFloat {
        max(value, min(max(minimum, 0), 1))
    }

    private static func lengthScale(_ destinationLength: CGFloat) -> CGFloat {
        min(1, sqrt(max(0, destinationLength) / 180))
    }

    private static func clampedOffset(
        tangent: CGPoint,
        normal: CGPoint,
        cap: CGFloat
    ) -> CGPoint {
        let combined = tangent + normal
        let length = hypot(combined.x, combined.y)
        guard length > cap, length > 0 else { return combined }
        return combined * (cap / length)
    }

    private static func pressureOutlinePath(
        locations: [CGPoint],
        pressures: [CGFloat?],
        baseWidth: CGFloat,
        destinationScale: CGFloat
    ) -> CGPath {
        let path = CGMutablePath()
        guard locations.count > 1, locations.count == pressures.count else {
            return path
        }

        var left: [CGPoint] = []
        var right: [CGPoint] = []
        left.reserveCapacity(locations.count)
        right.reserveCapacity(locations.count)
        var firstTangent = CGPoint.zero
        var lastTangent = CGPoint.zero
        var firstHalfWidth = CGFloat.zero
        var lastHalfWidth = CGFloat.zero

        for index in locations.indices {
            let tangent = sampleTangent(locations: locations, at: index)
            let normal = CGPoint(x: -tangent.y, y: tangent.x)
            let pressure = max(0.15, min(1, pressures[index] ?? 1))
            let halfWidth = max(
                0.625 / max(destinationScale, 0.001),
                baseWidth * pressure / 2
            )
            if index == locations.startIndex {
                firstTangent = tangent
                firstHalfWidth = halfWidth
            }
            if index == locations.index(before: locations.endIndex) {
                lastTangent = tangent
                lastHalfWidth = halfWidth
            }
            left.append(locations[index] + normal * halfWidth)
            right.append(locations[index] - normal * halfWidth)
        }

        path.move(to: left[0])
        for point in left.dropFirst() {
            path.addLine(to: point)
        }
        let last = locations.count - 1
        let endCapControl = lastTangent * (lastHalfWidth * 4 / 3)
        path.addCurve(
            to: right[last],
            control1: left[last] + endCapControl,
            control2: right[last] + endCapControl
        )
        for point in right.dropLast().reversed() {
            path.addLine(to: point)
        }
        let startCapControl = firstTangent * (-firstHalfWidth * 4 / 3)
        path.addCurve(
            to: left[0],
            control1: right[0] + startCapControl,
            control2: left[0] + startCapControl
        )
        path.closeSubpath()
        return path
    }

    private static func smoothClosedPath(through points: [CGPoint]) -> CGPath {
        let path = CGMutablePath()
        guard points.count > 2 else { return path }
        path.move(to: points[0])
        for index in points.indices {
            let previous = points[(index - 1 + points.count) % points.count]
            let current = points[index]
            let next = points[(index + 1) % points.count]
            let following = points[(index + 2) % points.count]
            path.addCurve(
                to: next,
                control1: current + (next - previous) / 6,
                control2: next - (following - current) / 6
            )
        }
        path.closeSubpath()
        return path
    }

    private static func cumulativeDistances(_ points: [CGPoint]) -> [CGFloat] {
        guard let first = points.first else { return [] }
        var distances = [CGFloat.zero]
        distances.reserveCapacity(points.count)
        var previous = first
        for point in points.dropFirst() {
            distances.append((distances.last ?? 0) + distance(previous, point))
            previous = point
        }
        return distances
    }

    private static func sampleTangent(
        locations: [CGPoint],
        at index: Int
    ) -> CGPoint {
        let previous = locations[max(0, index - 1)]
        let next = locations[min(locations.count - 1, index + 1)]
        let tangent = normalized(next - previous)
        if tangent != .zero {
            return tangent
        }
        if index + 1 < locations.count {
            return normalized(locations[index + 1] - locations[index])
        }
        return normalized(locations[index] - locations[index - 1])
    }

    private static func parse(_ path: CGPath) -> [Subpath] {
        var subpaths: [Subpath] = []
        var current: Subpath?

        path.applyWithBlock { pointer in
            let element = pointer.pointee
            switch element.type {
            case .moveToPoint:
                if let current {
                    subpaths.append(current)
                }
                current = Subpath(start: element.points[0])
            case .addLineToPoint:
                current?.segments.append(.line(element.points[0]))
            case .addQuadCurveToPoint:
                current?.segments.append(
                    .quad(control: element.points[0], end: element.points[1])
                )
            case .addCurveToPoint:
                current?.segments.append(
                    .cubic(
                        control1: element.points[0],
                        control2: element.points[1],
                        end: element.points[2]
                    )
                )
            case .closeSubpath:
                if var closed = current {
                    closed.isClosed = true
                    subpaths.append(closed)
                    current = nil
                }
            @unknown default:
                break
            }
        }
        if let current {
            subpaths.append(current)
        }
        return subpaths
    }

    private static func isPinned(_ point: CGPoint, in pinnedPoints: [CGPoint]) -> Bool {
        pinnedPoints.contains {
            distance($0, point) <= 0.001
        }
    }

    private static func normalized(_ point: CGPoint) -> CGPoint {
        let length = hypot(point.x, point.y)
        guard length > 0.000_1 else { return .zero }
        return point / length
    }

    private static func distance(_ lhs: CGPoint, _ rhs: CGPoint) -> CGFloat {
        hypot(rhs.x - lhs.x, rhs.y - lhs.y)
    }

    private static func interpolate(
        _ start: CGPoint,
        _ end: CGPoint,
        _ fraction: CGFloat
    ) -> CGPoint {
        start + (end - start) * fraction
    }

    private static func mixed(_ value: UInt64) -> UInt64 {
        var value = value &+ 0x9E37_79B9_7F4A_7C15
        value = (value ^ (value >> 30)) &* 0xBF58_476D_1CE4_E5B9
        value = (value ^ (value >> 27)) &* 0x94D0_49BB_1331_11EB
        return value ^ (value >> 31)
    }
}

private extension CGPoint {
    static func + (lhs: CGPoint, rhs: CGPoint) -> CGPoint {
        CGPoint(x: lhs.x + rhs.x, y: lhs.y + rhs.y)
    }

    static func - (lhs: CGPoint, rhs: CGPoint) -> CGPoint {
        CGPoint(x: lhs.x - rhs.x, y: lhs.y - rhs.y)
    }

    static func * (lhs: CGPoint, rhs: CGFloat) -> CGPoint {
        CGPoint(x: lhs.x * rhs, y: lhs.y * rhs)
    }

    static func / (lhs: CGPoint, rhs: CGFloat) -> CGPoint {
        CGPoint(x: lhs.x / rhs, y: lhs.y / rhs)
    }
}
