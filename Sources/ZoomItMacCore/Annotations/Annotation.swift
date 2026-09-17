import AppKit

enum AnnotationTool: Equatable {
    case hand
    case select
    case pen
    case line
    case rectangle
    case diamond
    case ellipse
    case arrow
    case text
    case highlighter
    case eraser
}

enum AnnotationColor: String, CaseIterable, Equatable {
    case red
    case green
    case blue
    case yellow
    case orange
    case pink
    case white
    case black
    case strokeNeutral
    case strokeCoral
    case strokeGreen
    case strokeBlue
    case strokeOrange
    case backgroundRed
    case backgroundGreen
    case backgroundBlue
    case backgroundYellow
    case highlighterYellow
    case highlighterCyan
    case highlighterPink
    case highlighterGreen
    case highlighterOrange

    var nsColor: NSColor {
        switch self {
        case .red: .systemRed
        case .green: .systemGreen
        case .blue: .systemBlue
        case .yellow: .systemYellow
        case .orange: .systemOrange
        case .pink: .systemPink
        case .white: .white
        case .black: .black
        case .strokeNeutral, .strokeCoral, .strokeGreen, .strokeBlue,
             .strokeOrange, .backgroundRed, .backgroundGreen,
             .backgroundBlue, .backgroundYellow:
            NSColor(name: nil) { appearance in
                resolvedNSColor(for: appearance)
            }
        case .highlighterYellow:
            NSColor(srgbRed: 1, green: 244 / 255, blue: 92 / 255, alpha: 1)
        case .highlighterCyan:
            NSColor(srgbRed: 50 / 255, green: 215 / 255, blue: 1, alpha: 1)
        case .highlighterPink:
            NSColor(srgbRed: 1, green: 92 / 255, blue: 173 / 255, alpha: 1)
        case .highlighterGreen:
            NSColor(srgbRed: 102 / 255, green: 242 / 255, blue: 111 / 255, alpha: 1)
        case .highlighterOrange:
            NSColor(srgbRed: 1, green: 159 / 255, blue: 67 / 255, alpha: 1)
        }
    }

    func resolvedNSColor(for appearance: NSAppearance?) -> NSColor {
        let isDark = appearance?.bestMatch(
            from: [.darkAqua, .aqua]
        ) == .darkAqua
        let rgb: UInt32
        switch (self, isDark) {
        case (.strokeNeutral, false): rgb = 0x1B1B1F
        case (.strokeNeutral, true): rgb = 0xE9ECEF
        case (.strokeCoral, false): rgb = 0xE03131
        case (.strokeCoral, true): rgb = 0xFF8787
        case (.strokeGreen, false): rgb = 0x2F9E44
        case (.strokeGreen, true): rgb = 0x69DB7C
        case (.strokeBlue, false): rgb = 0x1971C2
        case (.strokeBlue, true): rgb = 0x74C0FC
        case (.strokeOrange, false): rgb = 0xE8590C
        case (.strokeOrange, true): rgb = 0xFFA94D
        case (.backgroundRed, false): rgb = 0xFFC9C9
        case (.backgroundRed, true): rgb = 0x5C2B2B
        case (.backgroundGreen, false): rgb = 0xB2F2BB
        case (.backgroundGreen, true): rgb = 0x244A31
        case (.backgroundBlue, false): rgb = 0xA5D8FF
        case (.backgroundBlue, true): rgb = 0x243F5A
        case (.backgroundYellow, false): rgb = 0xFFEC99
        case (.backgroundYellow, true): rgb = 0x5A4A22
        default:
            return nsColor
        }
        return NSColor(
            srgbRed: CGFloat((rgb >> 16) & 0xFF) / 255,
            green: CGFloat((rgb >> 8) & 0xFF) / 255,
            blue: CGFloat(rgb & 0xFF) / 255,
            alpha: 1
        )
    }

    var displayName: String {
        switch self {
        case .red: "Red"
        case .green: "Green"
        case .blue: "Blue"
        case .yellow: "Yellow"
        case .orange: "Orange"
        case .pink: "Pink"
        case .white: "White"
        case .black: "Black"
        case .strokeNeutral: "Neutral"
        case .strokeCoral: "Coral"
        case .strokeGreen: "Green"
        case .strokeBlue: "Light Blue"
        case .strokeOrange: "Orange"
        case .backgroundRed: "Muted Red"
        case .backgroundGreen: "Muted Green"
        case .backgroundBlue: "Muted Blue"
        case .backgroundYellow: "Muted Yellow"
        case .highlighterYellow: "Light Yellow"
        case .highlighterCyan: "Cyan"
        case .highlighterPink: "Pink"
        case .highlighterGreen: "Green"
        case .highlighterOrange: "Orange"
        }
    }
}

enum AnnotationColorValue: Equatable {
    case palette(AnnotationColor)
    case rgba(red: CGFloat, green: CGFloat, blue: CGFloat, alpha: CGFloat)

    var nsColor: NSColor {
        switch self {
        case .palette(let color):
            color.nsColor
        case .rgba(let red, let green, let blue, let alpha):
            NSColor(srgbRed: red, green: green, blue: blue, alpha: alpha)
        }
    }

    var paletteColor: AnnotationColor? {
        guard case .palette(let color) = self else { return nil }
        return color
    }

    var isTransparent: Bool {
        switch self {
        case .palette:
            false
        case .rgba(_, _, _, let alpha):
            alpha <= 0.001
        }
    }
}

@MainActor
enum AnnotationColorResolver {
    static func resolved(
        _ value: AnnotationColorValue,
        opacity: CGFloat,
        highlightMultiplier: CGFloat = 1,
        forceOpaque: Bool = false
    ) -> (color: NSColor, alpha: CGFloat) {
        let source = value.nsColor.usingColorSpace(.sRGB)
            ?? value.nsColor.usingColorSpace(.deviceRGB)
            ?? value.nsColor
        let alpha = forceOpaque
            ? 1
            : source.alphaComponent
                * min(1, max(0, opacity))
                * min(1, max(0, highlightMultiplier))
        return (
            source.withAlphaComponent(1),
            min(1, max(0, alpha))
        )
    }

    static func compositedColor(
        _ value: AnnotationColorValue,
        opacity: CGFloat,
        highlightMultiplier: CGFloat = 1,
        over background: NSColor
    ) -> NSColor {
        compositedColor(
            value.nsColor,
            opacity: opacity,
            highlightMultiplier: highlightMultiplier,
            over: background
        )
    }

    static func compositedColor(
        _ color: NSColor,
        opacity: CGFloat,
        highlightMultiplier: CGFloat = 1,
        over background: NSColor
    ) -> NSColor {
        let source = color.usingColorSpace(.sRGB)
            ?? color.usingColorSpace(.deviceRGB)
            ?? color
        let foreground = (
            color: source.withAlphaComponent(1),
            alpha: source.alphaComponent
                * min(1, max(0, opacity))
                * min(1, max(0, highlightMultiplier))
        )
        let resolvedBackground = background.usingColorSpace(.sRGB)
            ?? background.usingColorSpace(.deviceRGB)
            ?? background
        let inverseAlpha = 1 - foreground.alpha
        return NSColor(
            srgbRed: foreground.color.redComponent * foreground.alpha
                + resolvedBackground.redComponent * inverseAlpha,
            green: foreground.color.greenComponent * foreground.alpha
                + resolvedBackground.greenComponent * inverseAlpha,
            blue: foreground.color.blueComponent * foreground.alpha
                + resolvedBackground.blueComponent * inverseAlpha,
            alpha: 1
        )
    }
}

enum AnnotationFillStyle: CaseIterable, Equatable {
    case none
    case hachure
    case crossHatch
    case solid

    var displayName: String {
        switch self {
        case .none: "None"
        case .hachure: "Hachure"
        case .crossHatch: "Cross-hatch"
        case .solid: "Solid"
        }
    }
}

enum AnnotationStrokePattern: Equatable {
    case solid
    case dashed
    case dotted

    var displayName: String {
        switch self {
        case .solid: "Solid"
        case .dashed: "Dashed"
        case .dotted: "Dotted"
        }
    }
}

enum AnnotationSloppiness: Int, CaseIterable, Equatable, Hashable {
    case architect = 0
    case artist = 1
    case cartoonist = 2

    var displayName: String {
        switch self {
        case .architect: "Architect"
        case .artist: "Artist"
        case .cartoonist: "Cartoonist"
        }
    }
}

enum AnnotationEdgeStyle: CaseIterable, Equatable {
    case sharp
    case round

    var displayName: String {
        switch self {
        case .sharp: "Sharp"
        case .round: "Round"
        }
    }
}

enum AnnotationPressureMode: String, CaseIterable, Equatable {
    case fixed
    case tablet
    case simulated

    var displayName: String {
        switch self {
        case .fixed: "Fixed"
        case .tablet: "Tablet"
        case .simulated: "Mouse speed"
        }
    }
}

enum AnnotationLineCap: Equatable {
    case butt
    case round
    case square
}

enum AnnotationLineJoin: Equatable {
    case miter
    case round
    case bevel
}

enum AnnotationStrokeWidthDefaults {
    static let pen: CGFloat = 7
    static let highlighter: CGFloat = 18
    static let geometry: CGFloat = 3
}

struct AnnotationStyle: Equatable {
    var strokeColor: AnnotationColorValue
    var fillColor: AnnotationColorValue
    var fillStyle: AnnotationFillStyle
    var strokeWidth: CGFloat
    var strokePattern: AnnotationStrokePattern
    var sloppiness: AnnotationSloppiness
    var opacity: CGFloat
    var usesLegacyHighlightCompositing: Bool
    var lineCap: AnnotationLineCap
    var lineJoin: AnnotationLineJoin
    var roundness: CGFloat?
    var pressureMode: AnnotationPressureMode
    var smoothingEnabled: Bool

    var pressureEnabled: Bool {
        get { pressureMode != .fixed }
        set { pressureMode = newValue ? .tablet : .fixed }
    }

    /// Compatibility access for existing palette shortcuts.
    var color: AnnotationColor {
        get { strokeColor.paletteColor ?? .red }
        set { strokeColor = .palette(newValue) }
    }

    /// Compatibility access for the existing root pen-width setting.
    var rootWidth: CGFloat {
        get { strokeWidth }
        set { strokeWidth = newValue }
    }

    /// Compatibility access for existing highlight behavior.
    var alpha: CGFloat {
        get { opacity }
        set { opacity = newValue }
    }

    init(
        color: AnnotationColor,
        rootWidth: CGFloat,
        alpha: CGFloat,
        fillColor: AnnotationColorValue? = nil,
        fillStyle: AnnotationFillStyle = .none,
        strokePattern: AnnotationStrokePattern = .solid,
        sloppiness: AnnotationSloppiness = .artist,
        lineCap: AnnotationLineCap = .round,
        lineJoin: AnnotationLineJoin = .round,
        roundness: CGFloat? = nil,
        pressureEnabled: Bool = false,
        pressureMode: AnnotationPressureMode? = nil,
        smoothingEnabled: Bool = true,
        usesLegacyHighlightCompositing: Bool = false
    ) {
        strokeColor = .palette(color)
        self.fillColor = fillColor ?? .palette(color)
        self.fillStyle = fillStyle
        strokeWidth = rootWidth
        self.strokePattern = strokePattern
        self.sloppiness = sloppiness
        opacity = alpha
        self.usesLegacyHighlightCompositing = usesLegacyHighlightCompositing
        self.lineCap = lineCap
        self.lineJoin = lineJoin
        self.roundness = roundness
        self.pressureMode = pressureMode ?? (pressureEnabled ? .tablet : .fixed)
        self.smoothingEnabled = smoothingEnabled
    }

    /// Translucency used for highlighting (Shift+color and the highlighter
    /// tool), matching Windows ZoomIt's g_AlphaBlend (0x80 = 50%).
    static let highlightAlpha: CGFloat = 0.5

    static let `default` = AnnotationStyle(
        color: .red,
        rootWidth: AnnotationStrokeWidthDefaults.pen,
        alpha: 1
    )
}

struct AnnotationElementID: Hashable, Equatable {
    let rawValue: UUID

    init(_ rawValue: UUID = UUID()) {
        self.rawValue = rawValue
    }
}

struct AnnotationGroupID: Hashable, Equatable {
    let rawValue: UUID

    init(_ rawValue: UUID = UUID()) {
        self.rawValue = rawValue
    }
}

struct AnnotationPointSample: Equatable {
    var location: CGPoint
    var pressure: CGFloat?
    var timestamp: TimeInterval?

    init(
        location: CGPoint,
        pressure: CGFloat?,
        timestamp: TimeInterval? = nil
    ) {
        self.location = location
        self.pressure = pressure
        self.timestamp = timestamp
    }
}

struct AnnotationRawFreehandInput: Equatable {
    var location: CGPoint
    var pressure: CGFloat?
    var timestamp: TimeInterval
}

struct AnnotationRawFreehandInputBuffer {
    static let defaultCapacity = 32
    static let maximumBufferedDuration: TimeInterval = 1.0 / 30.0

    private var storage: [AnnotationRawFreehandInput] = []
    private let capacity: Int

    init(capacity: Int = defaultCapacity) {
        self.capacity = max(2, capacity)
        storage.reserveCapacity(self.capacity)
    }

    var count: Int {
        storage.count
    }

    var isEmpty: Bool {
        storage.isEmpty
    }

    var last: AnnotationRawFreehandInput? {
        storage.last
    }

    var oldestTimestamp: TimeInterval? {
        storage.first?.timestamp
    }

    mutating func append(_ input: AnnotationRawFreehandInput) {
        if let last, last.location == input.location,
           last.timestamp == input.timestamp {
            storage[storage.count - 1] = input
            return
        }

        if storage.count >= 2,
           Self.canReplaceMiddle(
               previous: storage[storage.count - 2],
               middle: storage[storage.count - 1],
               next: input
           ) {
            storage[storage.count - 1] = input
        } else {
            storage.append(input)
        }

        trimStalePrefix(relativeTo: input.timestamp)
        while storage.count > capacity {
            removeLeastSignificantInteriorSample()
        }
    }

    mutating func popFirst() -> AnnotationRawFreehandInput? {
        guard !storage.isEmpty else { return nil }
        return storage.removeFirst()
    }

    mutating func removeAll() {
        storage.removeAll(keepingCapacity: true)
    }

    private mutating func trimStalePrefix(relativeTo newestTimestamp: TimeInterval) {
        guard newestTimestamp.isFinite else { return }
        let cutoff = newestTimestamp - Self.maximumBufferedDuration
        guard let firstRecent = storage.firstIndex(where: {
            !$0.timestamp.isFinite || $0.timestamp >= cutoff
        }), firstRecent > 1 else {
            return
        }

        // Retain one bridge sample so the canonical path stays connected, then
        // discard obsolete history instead of allowing a seconds-long FIFO.
        storage.removeSubrange(0..<(firstRecent - 1))
    }

    private mutating func removeLeastSignificantInteriorSample() {
        guard storage.count > 2 else {
            storage.removeFirst()
            return
        }
        let removalIndex = (1..<(storage.count - 1)).min { lhs, rhs in
            Self.significance(
                previous: storage[lhs - 1],
                middle: storage[lhs],
                next: storage[lhs + 1]
            ) < Self.significance(
                previous: storage[rhs - 1],
                middle: storage[rhs],
                next: storage[rhs + 1]
            )
        } ?? 1
        storage.remove(at: removalIndex)
    }

    private static func canReplaceMiddle(
        previous: AnnotationRawFreehandInput,
        middle: AnnotationRawFreehandInput,
        next: AnnotationRawFreehandInput
    ) -> Bool {
        let incoming = CGPoint(
            x: middle.location.x - previous.location.x,
            y: middle.location.y - previous.location.y
        )
        let outgoing = CGPoint(
            x: next.location.x - middle.location.x,
            y: next.location.y - middle.location.y
        )
        let incomingLength = hypot(incoming.x, incoming.y)
        let outgoingLength = hypot(outgoing.x, outgoing.y)
        guard incomingLength > 0.000_1, outgoingLength > 0.000_1 else {
            return true
        }
        let cosine = (
            incoming.x * outgoing.x + incoming.y * outgoing.y
        ) / (incomingLength * outgoingLength)
        guard cosine > 0.985 else { return false }
        if isPressureExtremum(previous: previous, middle: middle, next: next) {
            return false
        }
        return perpendicularDistance(
            middle.location,
            from: previous.location,
            to: next.location
        ) <= 0.75
    }

    private static func significance(
        previous: AnnotationRawFreehandInput,
        middle: AnnotationRawFreehandInput,
        next: AnnotationRawFreehandInput
    ) -> CGFloat {
        let incoming = CGPoint(
            x: middle.location.x - previous.location.x,
            y: middle.location.y - previous.location.y
        )
        let outgoing = CGPoint(
            x: next.location.x - middle.location.x,
            y: next.location.y - middle.location.y
        )
        let incomingLength = max(0.000_1, hypot(incoming.x, incoming.y))
        let outgoingLength = max(0.000_1, hypot(outgoing.x, outgoing.y))
        let cosine = min(
            1,
            max(
                -1,
                (incoming.x * outgoing.x + incoming.y * outgoing.y)
                    / (incomingLength * outgoingLength)
            )
        )
        let turn = 1 - cosine
        let pressure = pressureProminence(
            previous: previous,
            middle: middle,
            next: next
        )
        return turn * 8
            + perpendicularDistance(
                middle.location,
                from: previous.location,
                to: next.location
            )
            + pressure * 6
    }

    private static func isPressureExtremum(
        previous: AnnotationRawFreehandInput,
        middle: AnnotationRawFreehandInput,
        next: AnnotationRawFreehandInput
    ) -> Bool {
        pressureProminence(previous: previous, middle: middle, next: next) >= 0.04
    }

    private static func pressureProminence(
        previous: AnnotationRawFreehandInput,
        middle: AnnotationRawFreehandInput,
        next: AnnotationRawFreehandInput
    ) -> CGFloat {
        guard let previousPressure = previous.pressure,
              let middlePressure = middle.pressure,
              let nextPressure = next.pressure else {
            return 0
        }
        let lowerNeighbor = min(previousPressure, nextPressure)
        let upperNeighbor = max(previousPressure, nextPressure)
        if middlePressure < lowerNeighbor {
            return lowerNeighbor - middlePressure
        }
        if middlePressure > upperNeighbor {
            return middlePressure - upperNeighbor
        }
        return 0
    }

    private static func perpendicularDistance(
        _ point: CGPoint,
        from start: CGPoint,
        to end: CGPoint
    ) -> CGFloat {
        let delta = CGPoint(x: end.x - start.x, y: end.y - start.y)
        let length = hypot(delta.x, delta.y)
        guard length > 0.000_1 else {
            return hypot(point.x - start.x, point.y - start.y)
        }
        return abs(
            delta.y * point.x
                - delta.x * point.y
                + end.x * start.y
                - end.y * start.x
        ) / length
    }
}

struct AnnotationFreehandResampleResult: Equatable {
    var removesTrailingPreview: Bool
    var samples: [AnnotationPointSample]
    var consumedInput = true
    var hasPendingSamples = false
}

struct AnnotationFreehandInputResampler: Equatable {
    static let screenSpacing: CGFloat = 2.5
    static let maximumPressureStep: CGFloat = 0.06
    static let maximumGeneratedSamplesPerDrain = 128

    private struct PendingInterpolation: Equatable {
        var start: AnnotationPointSample
        var end: AnnotationPointSample
        var nextStep: Int
        var stepCount: Int
        var removesTrailingPreview: Bool
    }

    private(set) var previousCommittedSample: AnnotationPointSample?
    private(set) var committedSample: AnnotationPointSample?
    private(set) var previewSample: AnnotationPointSample?
    private var pendingInterpolation: PendingInterpolation?

    var hasPendingSamples: Bool {
        pendingInterpolation != nil
    }

    var pendingTargetSample: AnnotationPointSample? {
        pendingInterpolation?.end
    }

    mutating func reset() {
        previousCommittedSample = nil
        committedSample = nil
        previewSample = nil
        pendingInterpolation = nil
    }

    mutating func begin(with sample: AnnotationPointSample) {
        previousCommittedSample = nil
        committedSample = sample
        previewSample = nil
    }

    mutating func append(
        _ sample: AnnotationPointSample,
        zoomScale: CGFloat,
        spacingScale: CGFloat = 1,
        maximumSamples: Int = maximumGeneratedSamplesPerDrain
    ) -> AnnotationFreehandResampleResult {
        if pendingInterpolation != nil {
            return drainPending(maximumSamples: maximumSamples)
        }
        guard var anchor = committedSample else {
            begin(with: sample)
            return AnnotationFreehandResampleResult(
                removesTrailingPreview: false,
                samples: [sample]
            )
        }

        var removesTrailingPreview = previewSample != nil
        if let previewSample,
           Self.shouldPreserveCorner(
               previous: previousCommittedSample ?? anchor,
               corner: previewSample,
               next: sample,
               zoomScale: zoomScale,
               spacingScale: spacingScale
           ) {
            previousCommittedSample = anchor
            anchor = previewSample
            committedSample = previewSample
            self.previewSample = nil
            removesTrailingPreview = false
        }

        let distance = hypot(
            sample.location.x - anchor.location.x,
            sample.location.y - anchor.location.y
        )
        guard distance > 0.000_1 else {
            committedSample = sample
            previewSample = nil
            return AnnotationFreehandResampleResult(
                removesTrailingPreview: true,
                samples: [sample]
            )
        }

        let spacing = Self.screenSpacing
            * max(1, spacingScale)
            / max(zoomScale, 0.001)
        let pressureDistance = abs(
            (sample.pressure ?? 1) - (anchor.pressure ?? 1)
        )
        if distance <= spacing,
           pressureDistance <= Self.maximumPressureStep {
            previewSample = sample
            return AnnotationFreehandResampleResult(
                removesTrailingPreview: removesTrailingPreview,
                samples: [sample]
            )
        }

        let stepCount = Self.interpolationStepCount(
            from: anchor,
            to: sample,
            zoomScale: zoomScale,
            spacingScale: spacingScale
        )
        previewSample = nil
        pendingInterpolation = PendingInterpolation(
            start: anchor,
            end: sample,
            nextStep: 1,
            stepCount: stepCount,
            removesTrailingPreview: removesTrailingPreview
        )
        return drainPending(maximumSamples: maximumSamples)
    }

    mutating func drainPending(
        maximumSamples: Int = maximumGeneratedSamplesPerDrain
    ) -> AnnotationFreehandResampleResult {
        guard var pendingInterpolation else {
            return AnnotationFreehandResampleResult(
                removesTrailingPreview: false,
                samples: [],
                consumedInput: false,
                hasPendingSamples: false
            )
        }
        let limit = max(0, maximumSamples)
        guard limit > 0 else {
            return AnnotationFreehandResampleResult(
                removesTrailingPreview: false,
                samples: [],
                consumedInput: false,
                hasPendingSamples: true
            )
        }
        let finalStep = min(
            pendingInterpolation.stepCount,
            pendingInterpolation.nextStep + limit - 1
        )
        var result: [AnnotationPointSample] = []
        result.reserveCapacity(finalStep - pendingInterpolation.nextStep + 1)
        for step in pendingInterpolation.nextStep...finalStep {
            result.append(
                Self.interpolate(
                    from: pendingInterpolation.start,
                    to: pendingInterpolation.end,
                    fraction: CGFloat(step) / CGFloat(pendingInterpolation.stepCount)
                )
            )
        }
        let removesTrailingPreview = pendingInterpolation.removesTrailingPreview
            && pendingInterpolation.nextStep == 1
        if let last = result.last {
            previousCommittedSample = result.count > 1
                ? result[result.count - 2]
                : committedSample
            committedSample = last
        }
        pendingInterpolation.nextStep = finalStep + 1
        let isComplete = pendingInterpolation.nextStep > pendingInterpolation.stepCount
        if isComplete {
            committedSample = pendingInterpolation.end
            self.pendingInterpolation = nil
        } else {
            self.pendingInterpolation = pendingInterpolation
        }
        return AnnotationFreehandResampleResult(
            removesTrailingPreview: removesTrailingPreview,
            samples: result,
            consumedInput: isComplete,
            hasPendingSamples: !isComplete
        )
    }

    static func interpolationStepCount(
        from start: AnnotationPointSample,
        to end: AnnotationPointSample,
        zoomScale: CGFloat,
        spacingScale: CGFloat = 1
    ) -> Int {
        let screenDistance = hypot(
            end.location.x - start.location.x,
            end.location.y - start.location.y
        ) * max(zoomScale, 0.001)
        let pressureDistance = abs(
            (end.pressure ?? 1) - (start.pressure ?? 1)
        )
        return max(
            1,
            min(
                1_000_000,
                Int(
                    ceil(
                        max(
                            screenDistance
                                / (screenSpacing * max(1, spacingScale)),
                            pressureDistance / maximumPressureStep
                        )
                    )
                )
            )
        )
    }

    private static func shouldPreserveCorner(
        previous: AnnotationPointSample,
        corner: AnnotationPointSample,
        next: AnnotationPointSample,
        zoomScale: CGFloat,
        spacingScale: CGFloat
    ) -> Bool {
        let incoming = CGPoint(
            x: corner.location.x - previous.location.x,
            y: corner.location.y - previous.location.y
        )
        let outgoing = CGPoint(
            x: next.location.x - corner.location.x,
            y: next.location.y - corner.location.y
        )
        let incomingLength = hypot(incoming.x, incoming.y)
        let outgoingLength = hypot(outgoing.x, outgoing.y)
        let minimumLeg = screenSpacing
            * max(1, spacingScale)
            * 1.1
            / max(zoomScale, 0.001)
        guard incomingLength >= minimumLeg, outgoingLength >= minimumLeg else {
            return false
        }
        let cosine = (
            incoming.x * outgoing.x + incoming.y * outgoing.y
        ) / (incomingLength * outgoingLength)
        return cosine < 0.42
    }

    private static func interpolate(
        from start: AnnotationPointSample,
        to end: AnnotationPointSample,
        fraction: CGFloat
    ) -> AnnotationPointSample {
        let pressure: CGFloat?
        if start.pressure == nil, end.pressure == nil {
            pressure = nil
        } else {
            let startPressure = start.pressure ?? 1
            let endPressure = end.pressure ?? 1
            pressure = startPressure + (endPressure - startPressure) * fraction
        }
        let timestamp: TimeInterval?
        if let startTimestamp = start.timestamp,
           let endTimestamp = end.timestamp,
           startTimestamp.isFinite,
           endTimestamp.isFinite {
            timestamp = startTimestamp
                + (endTimestamp - startTimestamp) * Double(fraction)
        } else {
            timestamp = end.timestamp ?? start.timestamp
        }
        return AnnotationPointSample(
            location: CGPoint(
                x: start.location.x
                    + (end.location.x - start.location.x) * fraction,
                y: start.location.y
                    + (end.location.y - start.location.y) * fraction
            ),
            pressure: pressure,
            timestamp: timestamp
        )
    }
}

struct AnnotationFreehandDrainBudget: Equatable {
    var maximumRawEvents = 8
    var maximumGeneratedSamples = 128
    var spacingScale: CGFloat = 1

    static let frame = AnnotationFreehandDrainBudget()
}

struct AnnotationFreehandDrainStats: Equatable {
    var rawEvents = 0
    var generatedSamples = 0
    var hasPendingWork = false
}

struct AnnotationFreehandGeometry: Equatable {
    var samples: [AnnotationPointSample]
    var isHighlighter: Bool
}

enum AnnotationHighlighterGeometry {
    static func stampRect(center: CGPoint, strokeWidth: CGFloat) -> CGRect {
        let height = max(1, strokeWidth)
        let width = max(1, strokeWidth * 0.68)
        return CGRect(
            x: center.x - width / 2,
            y: center.y - height / 2,
            width: width,
            height: height
        )
    }
}

enum AnnotationShapeKind: Equatable {
    case rectangle
    case diamond
    case ellipse
}

struct AnnotationShapeGeometry: Equatable {
    var kind: AnnotationShapeKind
    var start: CGPoint
    var end: CGPoint

    var bounds: CGRect {
        CGRect(
            origin: start,
            size: CGSize(width: end.x - start.x, height: end.y - start.y)
        ).standardized
    }
}

enum AnnotationLinearRoute: Equatable {
    case straight
    case curved

    static let userSelectableRoutes: [AnnotationLinearRoute] = [
        .straight,
        .curved
    ]

    static func route(forOptionShortcut key: String?) -> AnnotationLinearRoute? {
        switch key {
        case "1": .straight
        case "2": .curved
        default: nil
        }
    }

    var displayName: String {
        switch self {
        case .straight: "Straight"
        case .curved: "Curved"
        }
    }
}

enum AnnotationArrowhead: Equatable {
    case none
    case arrow
    case triangle
    case triangleOutline
    case circle
    case circleOutline
    case bar
    case diamond
    case diamondOutline
    case crowFoot
    case oneOrMany
    case zeroOrOne
    case zeroOrMany

    var isFilled: Bool {
        switch self {
        case .triangle, .circle, .diamond:
            true
        default:
            false
        }
    }

    var displayName: String {
        switch self {
        case .none: "None"
        case .arrow: "Open arrow"
        case .triangle: "Filled triangle"
        case .triangleOutline: "Triangle"
        case .circle: "Filled circle"
        case .circleOutline: "Circle"
        case .bar: "Bar / one"
        case .diamond: "Filled diamond"
        case .diamondOutline: "Diamond"
        case .crowFoot: "Crow-foot / many"
        case .oneOrMany: "One or many"
        case .zeroOrOne: "Zero or one"
        case .zeroOrMany: "Zero or many"
        }
    }
}

enum AnnotationArrowheadSize: String, CaseIterable, Equatable {
    case small
    case medium
    case large

    var scale: CGFloat {
        switch self {
        case .small: 1
        case .medium: 1.35
        case .large: 1.75
        }
    }

    var displayName: String {
        switch self {
        case .small: "Small"
        case .medium: "Medium"
        case .large: "Large"
        }
    }
}

struct AnnotationSimulatedPressureTracker: Equatable {
    static let minimumPressure: CGFloat = 0.3
    static let highlighterMinimumPressure: CGFloat = 0.62
    static let resampleDistance: CGFloat = 2.5
    static let resampleInterval: TimeInterval = 1.0 / 90.0
    static let endTaperLength: CGFloat = 24
    static let maximumSamplesPerEvent = 16

    private(set) var lastPoint: CGPoint?
    private(set) var lastTimestamp: TimeInterval?
    private(set) var smoothedPressure: CGFloat?
    private(set) var filteredSpeed: CGFloat?
    private(set) var outputPressure: CGFloat = minimumPressure
    private(set) var totalScreenDistance: CGFloat = 0
    private(set) var elapsedStrokeTime: TimeInterval = 0

    mutating func reset() {
        lastPoint = nil
        lastTimestamp = nil
        smoothedPressure = nil
        filteredSpeed = nil
        outputPressure = Self.minimumPressure
        totalScreenDistance = 0
        elapsedStrokeTime = 0
    }

    mutating func begin(at point: CGPoint, timestamp: TimeInterval) -> CGFloat {
        reset()
        lastPoint = point
        lastTimestamp = timestamp
        return outputPressure
    }

    mutating func sample(
        at point: CGPoint,
        timestamp: TimeInterval,
        zoomScale: CGFloat
    ) -> CGFloat {
        resampledSamples(
            at: point,
            timestamp: timestamp,
            zoomScale: zoomScale
        ).last?.pressure ?? outputPressure
    }

    mutating func resampledSamples(
        at point: CGPoint,
        timestamp: TimeInterval,
        zoomScale: CGFloat
    ) -> [AnnotationPointSample] {
        guard let lastPoint, let lastTimestamp else {
            return [
                AnnotationPointSample(
                    location: point,
                    pressure: begin(at: point, timestamp: timestamp),
                    timestamp: timestamp
                )
            ]
        }

        let rawElapsed = timestamp - lastTimestamp
        let hasValidTimestamp = rawElapsed.isFinite && rawElapsed > 0
        let measuredElapsed = hasValidTimestamp
            ? rawElapsed
            : 1.0 / 120.0
        let filterElapsed = min(max(measuredElapsed, 1.0 / 240.0), 0.12)
        let resolvedTimestamp = hasValidTimestamp
            ? timestamp
            : lastTimestamp + measuredElapsed
        let worldDistance = hypot(point.x - lastPoint.x, point.y - lastPoint.y)
        guard worldDistance > 0.000_1 else {
            self.lastPoint = point
            self.lastTimestamp = resolvedTimestamp
            return []
        }

        let screenDistance = worldDistance * max(zoomScale, 0.001)
        let distanceSteps = screenDistance / Self.resampleDistance
        let timeSteps = filterElapsed / Self.resampleInterval
        let stepCount = min(
            Self.maximumSamplesPerEvent,
            max(1, Int(ceil(max(distanceSteps, timeSteps))))
        )
        let measuredStepElapsed = measuredElapsed / Double(stepCount)
        let filterStepElapsed = filterElapsed / Double(stepCount)
        let stepScreenDistance = screenDistance / CGFloat(stepCount)
        let rawSpeed = stepScreenDistance / CGFloat(measuredStepElapsed)
        var samples: [AnnotationPointSample] = []
        samples.reserveCapacity(stepCount)

        for step in 1...stepCount {
            let fraction = CGFloat(step) / CGFloat(stepCount)
            let location = CGPoint(
                x: lastPoint.x + (point.x - lastPoint.x) * fraction,
                y: lastPoint.y + (point.y - lastPoint.y) * fraction
            )
            totalScreenDistance += stepScreenDistance
            elapsedStrokeTime += measuredStepElapsed
            let filteredPressure = nextPressure(
                rawSpeed: rawSpeed,
                elapsed: filterStepElapsed
            )
            let startEnvelope = Self.startEnvelope(
                distance: totalScreenDistance,
                elapsed: elapsedStrokeTime
            )
            let desiredPressure = max(
                Self.minimumPressure,
                filteredPressure * startEnvelope
            )
            outputPressure = min(1, desiredPressure)
            samples.append(
                AnnotationPointSample(
                    location: location,
                    pressure: outputPressure,
                    timestamp: lastTimestamp + measuredStepElapsed * Double(step)
                )
            )
        }

        self.lastPoint = point
        self.lastTimestamp = resolvedTimestamp
        return samples
    }

    static func applyEndTaper(
        to samples: inout [AnnotationPointSample],
        zoomScale: CGFloat,
        minimumPressure: CGFloat = Self.minimumPressure
    ) {
        guard samples.count > 1 else { return }
        let scale = max(zoomScale, 0.001)
        var distanceFromEnd = CGFloat.zero
        for index in stride(from: samples.count - 1, through: 0, by: -1) {
            if index < samples.count - 1 {
                distanceFromEnd += hypot(
                    samples[index + 1].location.x - samples[index].location.x,
                    samples[index + 1].location.y - samples[index].location.y
                ) * scale
            }
            guard distanceFromEnd <= endTaperLength else { break }
            let progress = min(1, distanceFromEnd / endTaperLength)
            let eased = progress * progress * (3 - 2 * progress)
            let factor = 0.3 + 0.7 * eased
            if let pressure = samples[index].pressure {
                samples[index].pressure = max(
                    minimumPressure,
                    pressure * factor
                )
            }
        }
    }

    static func pressure(forSpeed speed: CGFloat) -> CGFloat {
        guard speed.isFinite else { return minimumPressure }
        if speed <= 40 {
            return 0.98
        }
        if speed >= 1_800 {
            return minimumPressure
        }
        let normalized = pow((speed - 40) / 1_760, 0.8)
        let smoothstep = normalized * normalized * (3 - 2 * normalized)
        return minimumPressure + 0.68 * (1 - smoothstep)
    }

    private mutating func nextPressure(
        rawSpeed: CGFloat,
        elapsed: TimeInterval
    ) -> CGFloat {
        let clampedRawSpeed = min(1_800, max(0, rawSpeed))
        let dt = CGFloat(elapsed)
        if let filteredSpeed {
            let timeConstant: CGFloat = clampedRawSpeed > filteredSpeed
                ? 0.010
                : 0.025
            let blend = 1 - exp(-dt / timeConstant)
            self.filteredSpeed = filteredSpeed
                + (clampedRawSpeed - filteredSpeed) * blend
        } else {
            filteredSpeed = clampedRawSpeed
        }

        let target = Self.pressure(forSpeed: filteredSpeed ?? clampedRawSpeed)
        guard let smoothedPressure else {
            self.smoothedPressure = target
            return target
        }
        let timeConstant: CGFloat = target < smoothedPressure ? 0.012 : 0.028
        let blend = 1 - exp(-dt / timeConstant)
        let next = smoothedPressure + (target - smoothedPressure) * blend
        self.smoothedPressure = min(1, max(Self.minimumPressure, next))
        return self.smoothedPressure ?? target
    }

    private static func startEnvelope(
        distance: CGFloat,
        elapsed: TimeInterval
    ) -> CGFloat {
        let distanceProgress = distance / 12
        let timeProgress = CGFloat(elapsed / 0.05)
        let progress = min(1, max(distanceProgress, timeProgress))
        let eased = progress * progress * (3 - 2 * progress)
        return 0.35 + 0.65 * eased
    }
}

enum AnnotationPressureBackfill {
    static func needsSimulatedPressure(_ samples: [AnnotationPointSample]) -> Bool {
        !samples.contains { sample in
            guard let pressure = sample.pressure, pressure.isFinite else {
                return false
            }
            return abs(min(1, max(0, pressure)) - 1) > 0.001
        }
    }

    static func simulatedSamples(
        from samples: [AnnotationPointSample],
        zoomScale: CGFloat = 1,
        minimumPressure: CGFloat = AnnotationSimulatedPressureTracker.minimumPressure
    ) -> [AnnotationPointSample] {
        guard !samples.isEmpty else { return [] }
        if hasUsableTimestamps(samples) {
            return timestampBasedSamples(
                from: samples,
                zoomScale: zoomScale,
                minimumPressure: minimumPressure
            )
        }
        return distanceBasedSamples(
            from: samples,
            minimumPressure: minimumPressure
        )
    }

    private static func hasUsableTimestamps(
        _ samples: [AnnotationPointSample]
    ) -> Bool {
        let timestamps = samples.compactMap(\.timestamp)
        guard timestamps.count == samples.count,
              timestamps.allSatisfy(\.isFinite) else {
            return false
        }
        var hasElapsedTime = false
        for (current, next) in zip(timestamps, timestamps.dropFirst()) {
            guard next >= current else { return false }
            hasElapsedTime = hasElapsedTime || next > current
        }
        return samples.count == 1 || hasElapsedTime
    }

    private static func timestampBasedSamples(
        from samples: [AnnotationPointSample],
        zoomScale: CGFloat,
        minimumPressure: CGFloat
    ) -> [AnnotationPointSample] {
        guard let first = samples.first,
              let firstTimestamp = first.timestamp else {
            return distanceBasedSamples(
                from: samples,
                minimumPressure: minimumPressure
            )
        }
        var result = samples
        var tracker = AnnotationSimulatedPressureTracker()
        result[0].pressure = max(
            minimumPressure,
            tracker.begin(
                at: first.location,
                timestamp: firstTimestamp
            )
        )
        for index in result.indices.dropFirst() {
            guard let timestamp = result[index].timestamp else {
                return distanceBasedSamples(
                    from: samples,
                    minimumPressure: minimumPressure
                )
            }
            result[index].pressure = max(
                minimumPressure,
                tracker.sample(
                    at: result[index].location,
                    timestamp: timestamp,
                    zoomScale: zoomScale
                )
            )
        }
        AnnotationSimulatedPressureTracker.applyEndTaper(
            to: &result,
            zoomScale: zoomScale,
            minimumPressure: minimumPressure
        )
        return result
    }

    private static func distanceBasedSamples(
        from samples: [AnnotationPointSample],
        minimumPressure: CGFloat
    ) -> [AnnotationPointSample] {
        guard samples.count > 1 else {
            return samples.map {
                var sample = $0
                sample.pressure = max(minimumPressure, 0.55)
                return sample
            }
        }

        var cumulativeDistances = [CGFloat](repeating: 0, count: samples.count)
        for index in 1..<samples.count {
            cumulativeDistances[index] = cumulativeDistances[index - 1] + hypot(
                samples[index].location.x - samples[index - 1].location.x,
                samples[index].location.y - samples[index - 1].location.y
            )
        }
        let totalDistance = cumulativeDistances.last ?? 0
        guard totalDistance > 0.000_1 else {
            return samples.map {
                var sample = $0
                sample.pressure = max(minimumPressure, 0.55)
                return sample
            }
        }

        return zip(samples, cumulativeDistances).map { sample, distance in
            let fraction = distance / totalDistance
            let bodyPressure = 0.62 + 0.3 * sin(.pi * fraction)
            let startEnvelope = smoothstep(min(1, distance / 12))
            let endEnvelope = smoothstep(
                min(1, (totalDistance - distance) / 24)
            )
            let envelope = min(
                0.3 + 0.7 * startEnvelope,
                0.3 + 0.7 * endEnvelope
            )
            var resolved = sample
            resolved.pressure = max(
                minimumPressure,
                min(1, bodyPressure * envelope)
            )
            return resolved
        }
    }

    private static func smoothstep(_ value: CGFloat) -> CGFloat {
        value * value * (3 - 2 * value)
    }
}

enum AnnotationLinearToolTransition {
    static func arrowheads(
        selecting tool: AnnotationTool,
        startArrowhead: AnnotationArrowhead,
        endArrowhead: AnnotationArrowhead
    ) -> (start: AnnotationArrowhead, end: AnnotationArrowhead) {
        if tool == .line,
           startArrowhead == .none,
           endArrowhead == .arrow {
            return (.none, .none)
        }
        if tool == .arrow,
           startArrowhead == .none,
           endArrowhead == .none {
            return (.none, .arrow)
        }
        return (startArrowhead, endArrowhead)
    }
}

enum AnnotationBindingSide: Equatable {
    case automatic
    case top
    case trailing
    case bottom
    case leading
}

struct AnnotationBinding: Equatable {
    var targetElementID: AnnotationElementID
    var normalizedAnchor: CGPoint
    var gap: CGFloat
    var focus: CGFloat?
    var side: AnnotationBindingSide

    init(
        targetElementID: AnnotationElementID,
        normalizedAnchor: CGPoint = CGPoint(x: 0.5, y: 0.5),
        gap: CGFloat = 0,
        focus: CGFloat? = nil,
        side: AnnotationBindingSide = .automatic
    ) {
        self.targetElementID = targetElementID
        self.normalizedAnchor = normalizedAnchor
        self.gap = gap
        self.focus = focus
        self.side = side
    }
}

struct AnnotationBezierControl: Equatable {
    var start: CGPoint
    var end: CGPoint
}

struct AnnotationLinearGeometry: Equatable {
    var points: [CGPoint]
    var route: AnnotationLinearRoute
    var startArrowhead: AnnotationArrowhead
    var endArrowhead: AnnotationArrowhead
    var arrowheadSize: AnnotationArrowheadSize
    var startBinding: AnnotationBinding?
    var endBinding: AnnotationBinding?
    var bezierControls: [AnnotationBezierControl]
    var rotationPivot: CGPoint?

    var isHeadless: Bool {
        startArrowhead == .none && endArrowhead == .none
    }

    init(
        points: [CGPoint],
        route: AnnotationLinearRoute,
        startArrowhead: AnnotationArrowhead,
        endArrowhead: AnnotationArrowhead,
        arrowheadSize: AnnotationArrowheadSize = .small,
        startBinding: AnnotationBinding?,
        endBinding: AnnotationBinding?,
        bezierControls: [AnnotationBezierControl] = [],
        rotationPivot: CGPoint? = nil
    ) {
        self.points = points
        self.route = route
        self.startArrowhead = startArrowhead
        self.endArrowhead = endArrowhead
        self.arrowheadSize = arrowheadSize
        self.startBinding = startBinding
        self.endBinding = endBinding
        self.bezierControls = bezierControls
        self.rotationPivot = rotationPivot
    }
}

enum AnnotationTextAlignment: Equatable {
    case left
    case center
    case right

    var displayName: String {
        switch self {
        case .left: "Align Left"
        case .center: "Align Center"
        case .right: "Align Right"
        }
    }
}

enum AnnotationTextFontPreset: String, CaseIterable, Equatable {
    case system
    case rounded
    case serif
    case monospaced
    case typeSetting

    static let roundedStorageName = "com.microsoft.ZoomIt.font-preset.rounded"
    static let serifStorageName = "com.microsoft.ZoomIt.font-preset.serif"
    static let monospacedStorageName = "com.microsoft.ZoomIt.font-preset.monospaced"

    var displayName: String {
        switch self {
        case .system: "Normal"
        case .rounded: "Hand-drawn"
        case .serif: "Serif"
        case .monospaced: "Code"
        case .typeSetting: "Type"
        }
    }

    func storageFontName(typeSettingName: String) -> String {
        switch self {
        case .system:
            ""
        case .rounded:
            Self.roundedStorageName
        case .serif:
            Self.serifStorageName
        case .monospaced:
            Self.monospacedStorageName
        case .typeSetting:
            typeSettingName
        }
    }

    static func inferred(fromStorageFontName fontName: String) -> AnnotationTextFontPreset {
        switch fontName {
        case "":
            .system
        case roundedStorageName:
            .rounded
        case serifStorageName:
            .serif
        case monospacedStorageName:
            .monospaced
        default:
            .typeSetting
        }
    }
}

struct AnnotationTextGeometry: Equatable {
    var origin: CGPoint
    var bounds: CGRect?
    var text: String
    var fontSize: CGFloat
    var fontName: String
    var alignment: AnnotationTextAlignment
}

enum AnnotationElementGeometry: Equatable {
    case freehand(AnnotationFreehandGeometry)
    case shape(AnnotationShapeGeometry)
    case linear(AnnotationLinearGeometry)
    case text(AnnotationTextGeometry)
}

struct AnnotationElementMetadata: Equatable {
    var groupIDs: [AnnotationGroupID]
    var isLocked: Bool
    var rotation: CGFloat
    var isVisible: Bool
    var wasSmartDrawRecognized: Bool

    static let `default` = AnnotationElementMetadata(
        groupIDs: [],
        isLocked: false,
        rotation: 0,
        isVisible: true,
        wasSmartDrawRecognized: false
    )
}

struct AnnotationElement: Equatable {
    let id: AnnotationElementID
    var geometry: AnnotationElementGeometry
    var style: AnnotationStyle
    var metadata: AnnotationElementMetadata

    var effectiveSloppiness: AnnotationSloppiness {
        if case .linear(let linear) = geometry, linear.isHeadless {
            return .architect
        }
        return style.sloppiness
    }

    init(
        id: AnnotationElementID = AnnotationElementID(),
        geometry: AnnotationElementGeometry,
        style: AnnotationStyle,
        metadata: AnnotationElementMetadata = .default
    ) {
        self.id = id
        self.geometry = geometry
        self.style = style
        self.metadata = metadata
    }

    static func legacy(
        id: AnnotationElementID = AnnotationElementID(),
        tool: AnnotationTool,
        points: [CGPoint],
        style: AnnotationStyle,
        text: String = "",
        fontSize: CGFloat = 36,
        fontName: String = "",
        rightAligned: Bool = false,
        textAlignment: AnnotationTextAlignment? = nil
    ) -> AnnotationElement {
        let geometry: AnnotationElementGeometry
        switch tool {
        case .hand, .select, .eraser:
            preconditionFailure("The hand, selection, and eraser tools do not create annotation elements")
        case .pen, .highlighter:
            geometry = .freehand(
                AnnotationFreehandGeometry(
                    samples: points.map { AnnotationPointSample(location: $0, pressure: nil) },
                    isHighlighter: tool == .highlighter
                )
            )
        case .rectangle, .diamond, .ellipse:
            let start = points.first ?? .zero
            let end = points.last ?? start
            let kind: AnnotationShapeKind
            switch tool {
            case .rectangle: kind = .rectangle
            case .diamond: kind = .diamond
            case .ellipse: kind = .ellipse
            default: kind = .rectangle
            }
            geometry = .shape(
                AnnotationShapeGeometry(
                    kind: kind,
                    start: start,
                    end: end
                )
            )
        case .line, .arrow:
            geometry = .linear(
                AnnotationLinearGeometry(
                    points: points,
                    route: .straight,
                    startArrowhead: tool == .arrow ? .arrow : .none,
                    endArrowhead: .none,
                    startBinding: nil,
                    endBinding: nil
                )
            )
        case .text:
            geometry = .text(
                AnnotationTextGeometry(
                    origin: points.first ?? .zero,
                    bounds: nil,
                    text: text,
                    fontSize: fontSize,
                    fontName: fontName,
                    alignment: textAlignment ?? (rightAligned ? .right : .left)
                )
            )
        }
        return AnnotationElement(id: id, geometry: geometry, style: style)
    }

}
