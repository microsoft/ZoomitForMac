import AppKit

enum AnnotationFreehandPresentationOwner: Equatable {
    case canonicalRenderer
    case immediateLayers
}

private struct SmartDrawCandidateTransfer: @unchecked Sendable {
    var candidate: SmartDrawCandidate?
}

private struct SmartDrawRecognitionRequest: @unchecked Sendable {
    var points: [CGPoint]
    var duration: TimeInterval
    var zoomScale: CGFloat
}

@MainActor
final class AnnotationController {
    private struct LinearConstruction {
        var element: AnnotationElement
        var previewPoint: CGPoint
        var zoomScale: CGFloat
    }

    private let scene: AnnotationScene
    private let editor: AnnotationEditor
    private let renderer = AnnotationRenderer()
    private var inProgress: AnnotationElement?
    private var inProgressShapeAnchor: CGPoint?
    private var inProgressUsesLegacyLinearGesture = false
    private var linearConstruction: LinearConstruction?
    private var recentlyCommittedLinearElementID: AnnotationElementID?
    private var smartDrawTracker = SmartDrawStabilityTracker()
    private var smartDrawStrokeStartTime: TimeInterval?
    private var smartDrawLatestCandidate: SmartDrawCandidate?
    private var smartDrawLastRecognitionTime: TimeInterval?
    private var smartDrawLastRecognizedSampleCount = 0
    private var smartDrawRecognitionGeneration = SmartDrawRecognitionGenerationState()
    private var smartDrawRecognitionWork: Task<SmartDrawCandidateTransfer, Never>?
    private var smartDrawRecognitionDelivery: Task<Void, Never>?
    private var pendingSmartDrawRecognitionRequest: SmartDrawRecognitionRequest?
    private(set) var smartDrawRecognitionSubmissionCountForTesting = 0
    private(set) var smartDrawRejectedRecognitionCountForTesting = 0
    private(set) var smartDrawMaximumConcurrentRecognitionCountForTesting = 0
    private var activeSmartDrawRecognitionCount = 0
    private var lastNotifiedSmartDrawStatusText: String?
    private var simulatedPressureTracker = AnnotationSimulatedPressureTracker()
    private var freehandInputResampler = AnnotationFreehandInputResampler()
    private var rawFreehandInputBuffer = AnnotationRawFreehandInputBuffer()
    private var freehandTailPreviewSample: AnnotationPointSample?
    private var regularStrokeColor: AnnotationColorValue = .palette(.red)
    private var highlighterStrokeColor: AnnotationColorValue = .palette(.highlighterYellow)
    private var penStrokeWidth = AnnotationStrokeWidthDefaults.pen
    private var highlighterStrokeWidth = AnnotationStrokeWidthDefaults.highlighter
    private var geometryStrokeWidth = AnnotationStrokeWidthDefaults.geometry
    private var outlinedStrokePattern: AnnotationStrokePattern = .solid
    private var outlinedSloppiness: AnnotationSloppiness = .artist
    private var geometryFillColor: AnnotationColorValue = .palette(.red)
    private var geometryFillStyle: AnnotationFillStyle = .none
    private var penOpacity: CGFloat = 1
    private var geometryOpacity: CGFloat = 1
    private var highlighterOpacity: CGFloat = 1
    private var freehandSloppiness: AnnotationSloppiness = .artist
    private var penPressureMode: AnnotationPressureMode = .fixed
    private var preferredPenVariablePressureMode: AnnotationPressureMode?
    private var savedPenPressureModeForSmartDraw: AnnotationPressureMode?
    private(set) var hasObservedTabletInput = false
    private var eraserTransactionActive = false
    private var pendingErasureElementIDs: Set<AnnotationElementID> = []
    private var previousEraserPoint: CGPoint?
    private(set) var eraserSweepSampleCountForTesting = 0
    private(set) var eraserHitTestCountForTesting = 0
    private var textAnnotationID: AnnotationElementID?
    private var textTransactionActive = false
    private var continuousStyleTransactionOwners:
        Set<DrawingContinuousStyleEditOwner> = []
    private var insertionPoint = CGPoint(x: 120, y: 120)
    private(set) var insertionPointWriteCountForTesting = 0
    private(set) var currentLineRoute: AnnotationLinearRoute = .straight
    private(set) var currentArrowRoute: AnnotationLinearRoute = .curved
    private(set) var currentStartArrowhead: AnnotationArrowhead = .none
    private(set) var currentEndArrowhead: AnnotationArrowhead = .none
    private(set) var currentArrowheadSize: AnnotationArrowheadSize = .medium
    private(set) var smartDrawEnabled = false
    var onStateChanged: (() -> Void)?

    init(elements: [AnnotationElement] = []) {
        let scene = AnnotationScene(elements: elements)
        self.scene = scene
        editor = AnnotationEditor(scene: scene)
        scene.onChange = { [weak self] in
            guard let self else { return }
            renderer.synchronizeCommittedStrokeCache(with: scene.elements)
            editor.revalidateLinearPointEditing()
            onStateChanged?()
        }
    }

    var currentTool: AnnotationTool {
        get { scene.currentTool }
        set {
            let previousTool = scene.currentTool
            if newValue != scene.currentTool, linearConstruction != nil {
                _ = finishLinearConstruction(
                    commitPreview: false,
                    enterPointEditing: newValue == .select
                )
            }
            if newValue != .select {
                editor.clearSelection()
                recentlyCommittedLinearElementID = nil
            } else if !editor.isEditingLinearPoints,
                      let elementID = recentlyCommittedLinearElementID,
                      scene.element(withID: elementID) != nil {
                scene.select([elementID])
                _ = editor.beginLinearPointEditing(elementID: elementID)
                recentlyCommittedLinearElementID = nil
            }
            let arrowheads = AnnotationLinearToolTransition.arrowheads(
                selecting: newValue,
                startArrowhead: currentStartArrowhead,
                endArrowhead: currentEndArrowhead
            )
            currentStartArrowhead = arrowheads.start
            currentEndArrowhead = arrowheads.end
            if previousTool != newValue {
                transitionCurrentStyle(from: previousTool, to: newValue)
            }
            scene.currentTool = newValue
        }
    }

    var currentStyle: AnnotationStyle {
        get { scene.currentStyle }
        set {
            var normalized = newValue
            switch currentTool {
            case .highlighter:
                highlighterStrokeColor = normalized.strokeColor
                highlighterStrokeWidth = normalized.strokeWidth
                highlighterOpacity = normalized.opacity
                normalizeHighlighterStyle(&normalized)
            case .pen:
                regularStrokeColor = normalized.strokeColor
                penStrokeWidth = normalized.strokeWidth
                penOpacity = normalized.opacity
                freehandSloppiness = normalized.sloppiness
                if smartDrawEnabled, normalized.pressureMode != .fixed {
                    savedPenPressureModeForSmartDraw = normalized.pressureMode
                    preferredPenVariablePressureMode = normalized.pressureMode
                    normalized.pressureMode = .fixed
                }
                penPressureMode = normalized.pressureMode
                if normalized.pressureMode != .fixed {
                    preferredPenVariablePressureMode = normalized.pressureMode
                }
                normalized.strokePattern = .solid
                normalized.lineCap = .round
                normalized.lineJoin = .round
            case .line:
                normalized.sloppiness = .architect
                captureGeometryStyle(normalized, for: currentTool)
            case .rectangle, .diamond, .ellipse, .arrow:
                captureGeometryStyle(normalized, for: currentTool)
            case .hand, .select, .text, .eraser:
                regularStrokeColor = normalized.strokeColor
            }
            scene.currentStyle = normalized
        }
    }

    var drawingDefaultsStyle: AnnotationStyle {
        var style = currentStyle
        style.strokePattern = outlinedStrokePattern
        style.pressureMode = penPressureMode
        return style
    }

    var currentLinearRoute: AnnotationLinearRoute {
        linearRoute(for: currentTool)
    }

    var drawingDefaultsSmartDrawSavedPressureMode: AnnotationPressureMode? {
        savedPenPressureModeForSmartDraw
    }

    var drawingDefaultsRegularStrokeColor: AnnotationColorValue {
        regularStrokeColor
    }

    var drawingDefaultsHighlighterStrokeColor: AnnotationColorValue {
        highlighterStrokeColor
    }

    var drawingDefaultsPenStrokeWidth: CGFloat {
        penStrokeWidth
    }

    var drawingDefaultsHighlighterStrokeWidth: CGFloat {
        highlighterStrokeWidth
    }

    var drawingDefaultsGeometryStrokeWidth: CGFloat {
        geometryStrokeWidth
    }

    var drawingDefaultsGeometryOpacity: CGFloat {
        geometryOpacity
    }

    var drawingDefaultsPenOpacity: CGFloat {
        penOpacity
    }

    var drawingDefaultsHighlighterOpacity: CGFloat {
        highlighterOpacity
    }

    var drawingDefaultsFreehandSloppiness: AnnotationSloppiness {
        freehandSloppiness
    }

    var drawingDefaultsOutlinedSloppiness: AnnotationSloppiness {
        outlinedSloppiness
    }

    // Typing mode state, mirroring ZoomIt's font scaling and justification.
    static let defaultFontSize: CGFloat = 20
    var typingFontSize: CGFloat = AnnotationController.defaultFontSize
    private(set) var typingTextAlignment: AnnotationTextAlignment = .left
    var typingRightAligned: Bool {
        get { typingTextAlignment == .right }
        set { typingTextAlignment = newValue ? .right : .left }
    }
    /// PostScript/font family name used for typing mode. Empty means the
    /// system font. Presets are tracked separately so selecting a native
    /// category never overwrites the custom font chosen in Type settings.
    var typingFontName = ""
    private(set) var typingFontPreset: AnnotationTextFontPreset = .system

    var typingStorageFontName: String {
        typingFontPreset.storageFontName(typeSettingName: typingFontName)
    }

    var preferredVariablePressureMode: AnnotationPressureMode {
        if let savedPenPressureModeForSmartDraw {
            return savedPenPressureModeForSmartDraw
        }
        if penPressureMode != .fixed {
            return penPressureMode
        }
        return preferredPenVariablePressureMode
            ?? (hasObservedTabletInput ? .tablet : .simulated)
    }

    func noteTabletInputAvailable() {
        guard !hasObservedTabletInput else { return }
        hasObservedTabletInput = true
        onStateChanged?()
    }

    var sceneSnapshot: AnnotationSceneSnapshot {
        scene.snapshot
    }

    var elementSnapshot: [AnnotationElement] {
        scene.elements
    }

    var selectedElementSnapshot: [AnnotationElement] {
        scene.elements.filter { scene.selection.contains($0.id) }
    }

    var inProgressElementSnapshot: AnnotationElement? {
        inProgress
    }

    func activeFreehandTailBounds(zoomScale: CGFloat) -> CGRect {
        AnnotationRenderer.activeTailBounds(of: inProgress, destinationScale: zoomScale)
    }

    var committedStrokeCacheCountersForTesting:
        AnnotationCommittedStrokeCacheCounters {
        renderer.committedStrokeCacheCountersForTesting
    }

    var committedStrokeCacheEntryCountForTesting: Int {
        renderer.committedStrokeCacheEntryCountForTesting
    }

    var hasActiveDrawingGesture: Bool {
        inProgress != nil
            || linearConstruction != nil
            || eraserTransactionActive
            || editor.stateKind != .idle
    }

    var hasPendingSmartDrawRecognitionForTesting: Bool {
        smartDrawRecognitionWork != nil
            || smartDrawRecognitionDelivery != nil
            || pendingSmartDrawRecognitionRequest != nil
    }

    var pendingErasureElementIDsForTesting: Set<AnnotationElementID> {
        pendingErasureElementIDs
    }

    var pendingRawFreehandInputCountForTesting: Int {
        rawFreehandInputBuffer.count
    }

    var pendingRawFreehandInputAgeForTesting: TimeInterval {
        guard let oldest = rawFreehandInputBuffer.oldestTimestamp,
              let newest = rawFreehandInputBuffer.last?.timestamp else {
            return 0
        }
        return max(0, newest - oldest)
    }

    var hasPendingTransientAnnotationWorkForTesting: Bool {
        inProgress != nil
            || inProgressShapeAnchor != nil
            || inProgressUsesLegacyLinearGesture
            || linearConstruction != nil
            || recentlyCommittedLinearElementID != nil
            || simulatedPressureTracker != AnnotationSimulatedPressureTracker()
            || freehandInputResampler != AnnotationFreehandInputResampler()
            || !rawFreehandInputBuffer.isEmpty
            || freehandTailPreviewSample != nil
            || smartDrawTracker.displayCandidate != nil
            || smartDrawStrokeStartTime != nil
            || smartDrawLatestCandidate != nil
            || smartDrawLastRecognitionTime != nil
            || smartDrawLastRecognizedSampleCount != 0
            || hasPendingSmartDrawRecognitionForTesting
            || eraserTransactionActive
            || !pendingErasureElementIDs.isEmpty
            || textAnnotationID != nil
            || textTransactionActive
            || hasActiveContinuousStyleEdit
            || editor.stateKind != .idle
            || renderer.hasActiveStrokeCacheForTesting
    }

    var isConstructingLinearPath: Bool {
        linearConstruction != nil
    }

    var canFinishLinearPath: Bool {
        guard let linear = linearConstructionGeometry else { return false }
        return Self.hasMinimumLinearPoints(linear.points)
    }

    var linearConstructionElementSnapshot: AnnotationElement? {
        linearConstruction?.element
    }

    var smartDrawPreviewElementSnapshot: AnnotationElement? {
        guard let inProgress,
              let candidate = smartDrawTracker.displayCandidate else {
            return nil
        }
        return smartDrawElement(from: candidate, replacing: inProgress)
    }

    var smartDrawStatusText: String? {
        guard smartDrawEnabled, currentTool == .pen else { return nil }
        guard currentInProgressTool == .pen else {
            return "Ready for a shape"
        }
        guard let candidate = smartDrawTracker.displayCandidate else {
            return "Analyzing stroke..."
        }
        let percentage = Int((candidate.confidence * 20).rounded()) * 5
        return "\(candidate.kind.displayName) · \(percentage)%"
    }

    var canUndo: Bool {
        scene.canUndo
    }

    var canRedo: Bool {
        scene.canRedo
    }

    var hasActiveContinuousStyleEdit: Bool {
        !continuousStyleTransactionOwners.isEmpty
    }

    var editorStateKind: AnnotationEditorStateKind {
        editor.stateKind
    }

    var selectedElementIDs: Set<AnnotationElementID> {
        editor.selectedElementIDs
    }

    var hasSelection: Bool {
        editor.hasSelection
    }

    var canDeleteSelection: Bool {
        editor.canDeleteSelection
    }

    var canGroupSelection: Bool {
        editor.canGroupSelection
    }

    var canUngroupSelection: Bool {
        editor.canUngroupSelection
    }

    var hasMovableSelection: Bool {
        editor.hasMovableSelection
    }

    var selectionIsFullyLocked: Bool {
        editor.selectionIsFullyLocked
    }

    var isEditingLinearPoints: Bool {
        editor.isEditingLinearPoints
    }

    var canEditLinearPoints: Bool {
        let selected = selectedElementSnapshot
        guard selected.count == 1, let element = selected.first,
              !element.metadata.isLocked,
              case .linear = element.geometry else {
            return false
        }
        return true
    }

    var canInsertLinearPoint: Bool {
        editor.isEditingLinearPoints && editor.selectedLinearSegmentIndex != nil
    }

    var canRemoveLinearPoints: Bool {
        guard editor.isEditingLinearPoints,
              !editor.selectedLinearPointIndices.isEmpty,
              let linear = selectedLinearGeometry else {
            return false
        }
        return linear.points.count - editor.selectedLinearPointIndices.count >= 2
    }

    var canUnbindLinearEndpoints: Bool {
        selectedElementSnapshot.contains { element in
            guard !element.metadata.isLocked,
                  case .linear(let linear) = element.geometry else {
                return false
            }
            return linear.startBinding != nil || linear.endBinding != nil
        }
    }

    var canEditSelectedLinearProperties: Bool {
        selectedElementSnapshot.contains { element in
            guard !element.metadata.isLocked, case .linear = element.geometry else {
                return false
            }
            return true
        }
    }

    var linearPointDecorationElement: AnnotationElement? {
        editor.linearPointEditingElement ?? passiveSelectedLinearElement
    }

    var selectedLinearGeometry: AnnotationLinearGeometry? {
        let selectedID = selectedElementIDs.count == 1 ? selectedElementIDs.first : nil
        guard let selectedID,
              let element = scene.element(withID: selectedID),
              case .linear(let linear) = element.geometry else {
            return nil
        }
        return linear
    }

    /// Builds the typing-mode font for a persisted custom name or native preset.
    static func typingFont(named name: String, size: CGFloat) -> NSFont {
        switch AnnotationTextFontPreset.inferred(fromStorageFontName: name) {
        case .system:
            return NSFont.systemFont(ofSize: size, weight: .regular)
        case .rounded:
            for name in [
                "MarkerFelt-Thin",
                "ChalkboardSE-Regular",
                "Noteworthy-Light"
            ] {
                if let font = NSFont(name: name, size: size) {
                    return font
                }
            }
            let descriptor = NSFont.systemFont(ofSize: size, weight: .regular)
                .fontDescriptor
                .withDesign(.rounded)
            return descriptor.flatMap { NSFont(descriptor: $0, size: size) }
                ?? NSFont.systemFont(ofSize: size, weight: .regular)
        case .serif:
            let descriptor = NSFont.systemFont(ofSize: size, weight: .regular)
                .fontDescriptor
                .withDesign(.serif)
            return descriptor.flatMap { NSFont(descriptor: $0, size: size) }
                ?? NSFont.systemFont(ofSize: size, weight: .regular)
        case .monospaced:
            return NSFont(name: "Menlo-Regular", size: size)
                ?? NSFont.monospacedSystemFont(ofSize: size, weight: .regular)
        case .typeSetting:
            if let font = NSFont(name: name, size: size) {
                return font
            }
            return NSFont.systemFont(ofSize: size, weight: .regular)
        }
    }

    func reset() {
        cancelActiveAnnotationWork()
        scene.reset()
        regularStrokeColor = .palette(.red)
        highlighterStrokeColor = .palette(.highlighterYellow)
        penStrokeWidth = AnnotationStrokeWidthDefaults.pen
        highlighterStrokeWidth = AnnotationStrokeWidthDefaults.highlighter
        geometryStrokeWidth = AnnotationStrokeWidthDefaults.geometry
        outlinedStrokePattern = .solid
        outlinedSloppiness = .artist
        geometryFillColor = .palette(.red)
        geometryFillStyle = .none
        penOpacity = 1
        geometryOpacity = 1
        highlighterOpacity = 1
        freehandSloppiness = .artist
        penPressureMode = .fixed
        preferredPenVariablePressureMode = nil
        savedPenPressureModeForSmartDraw = nil
        insertionPoint = CGPoint(x: 120, y: 120)
        insertionPointWriteCountForTesting = 0
        currentLineRoute = .straight
        currentArrowRoute = .curved
        currentStartArrowhead = .none
        currentEndArrowhead = .none
        currentArrowheadSize = .medium
        smartDrawEnabled = false
        typingFontSize = AnnotationController.defaultFontSize
        typingTextAlignment = .left
        lastNotifiedSmartDrawStatusText = smartDrawStatusText
    }

    func setInsertionPoint(_ point: CGPoint) {
        insertionPointWriteCountForTesting += 1
        insertionPoint = point
        textAnnotationID = nil
    }

    /// Starts a fresh typing session, matching ZoomIt's behaviour when entering
    /// type mode (T enters left-justified, Shift+T right-justified).
    func beginTypingSession(rightAligned: Bool) {
        finishTypingSession()
        currentTool = .text
        typingTextAlignment = rightAligned ? .right : .left
        textAnnotationID = nil
        scene.beginTransaction()
        textTransactionActive = true
        editor.beginTextEditing(elementID: nil)
    }

    @discardableResult
    func beginEditingText(elementID: AnnotationElementID) -> Bool {
        guard let element = scene.element(withID: elementID),
              !element.metadata.isLocked,
              case .text(let text) = element.geometry else {
            return false
        }

        finishTypingSession()
        scene.beginTransaction()
        textTransactionActive = true
        textAnnotationID = elementID
        insertionPoint = text.origin
        typingFontSize = text.fontSize
        typingFontPreset = AnnotationTextFontPreset.inferred(
            fromStorageFontName: text.fontName
        )
        if typingFontPreset == .typeSetting {
            typingFontName = text.fontName
        }
        typingTextAlignment = text.alignment
        scene.select([elementID])
        scene.updateElement(withID: elementID, recordHistory: false) { element in
            guard case .text(var text) = element.geometry else { return }
            text.bounds = nil
            element.geometry = .text(text)
        }
        editor.beginTextEditing(elementID: elementID)
        return true
    }

    func finishTypingSession() {
        if textTransactionActive {
            scene.commitTransaction()
            textTransactionActive = false
        }
        textAnnotationID = nil
        editor.finishTextEditing()
    }

    func increaseFontSize() {
        setTypingFontSize(typingFontSize * 1.1)
    }

    func decreaseFontSize() {
        setTypingFontSize(typingFontSize / 1.1)
    }

    private func setTypingFontSize(_ size: CGFloat) {
        typingFontSize = min(max(size, 10), 600)
        guard let textAnnotationID,
              scene.element(withID: textAnnotationID)?.metadata.isLocked == false else {
            return
        }
        scene.updateElement(withID: textAnnotationID, recordHistory: false) { element in
            guard case .text(var text) = element.geometry else { return }
            text.fontSize = typingFontSize
            element.geometry = .text(text)
        }
    }

    func setTextFontSize(_ size: CGFloat) {
        guard canApplyTextMutationToSelection else { return }
        let clampedSize = min(max(size, 10), 600)
        if shouldUpdateTextCreationDefaults {
            typingFontSize = clampedSize
        }
        applyTextGeometryChange { $0.fontSize = clampedSize }
    }

    func setTextFontPreset(_ preset: AnnotationTextFontPreset) {
        guard canApplyTextMutationToSelection else { return }
        let fontName = preset.storageFontName(typeSettingName: typingFontName)
        if shouldUpdateTextCreationDefaults {
            typingFontPreset = preset
        }
        applyTextGeometryChange { $0.fontName = fontName }
    }

    func setTextFontName(_ fontName: String) {
        guard canApplyTextMutationToSelection else { return }
        if shouldUpdateTextCreationDefaults {
            typingFontName = fontName
            typingFontPreset = .typeSetting
        }
        applyTextGeometryChange { $0.fontName = fontName }
    }

    func setTextAlignment(_ alignment: AnnotationTextAlignment) {
        guard canApplyTextMutationToSelection else { return }
        if shouldUpdateTextCreationDefaults {
            typingTextAlignment = alignment
        }
        applyTextGeometryChange { $0.alignment = alignment }
    }

    func applyDrawingDefaults(
        _ defaults: DrawingDefaults,
        strokeWidth: CGFloat,
        highlighterWidth: CGFloat? = nil,
        geometryWidth: CGFloat? = nil
    ) {
        regularStrokeColor = defaults.regularStrokeColor
            ?? (defaults.tool == .highlighter ? .palette(.red) : defaults.strokeColor)
        highlighterStrokeColor = defaults.highlighterStrokeColor
            ?? (defaults.tool == .highlighter
                ? defaults.strokeColor
                : .palette(.highlighterYellow))
        penStrokeWidth = min(
            max(defaults.penStrokeWidth ?? strokeWidth, 1),
            64
        )
        highlighterStrokeWidth = min(
            max(
                defaults.highlighterStrokeWidth
                    ?? highlighterWidth
                    ?? (defaults.tool == .highlighter
                        ? strokeWidth
                        : AnnotationStrokeWidthDefaults.highlighter),
                1
            ),
            64
        )
        geometryStrokeWidth = min(
            max(
                defaults.geometryStrokeWidth
                    ?? geometryWidth
                    ?? ([.line, .rectangle, .diamond, .ellipse, .arrow].contains(
                        defaults.tool
                    )
                        ? strokeWidth
                        : AnnotationStrokeWidthDefaults.geometry),
                1
            ),
            64
        )
        outlinedStrokePattern = defaults.strokePattern
        outlinedSloppiness = defaults.outlinedSloppiness
        geometryFillColor = defaults.fillColor
        geometryFillStyle = defaults.fillStyle
        penOpacity = defaults.penOpacity
            ?? (defaults.tool == .pen ? defaults.opacity : 1)
        geometryOpacity = defaults.geometryOpacity
            ?? (Self.toolSupportsStrokePattern(defaults.tool)
                ? defaults.opacity
                : 1)
        highlighterOpacity = defaults.highlighterOpacity
            ?? (defaults.tool == .highlighter ? defaults.opacity : 1)
        freehandSloppiness = defaults.freehandSloppiness
        smartDrawEnabled = defaults.smartDrawEnabled
        savedPenPressureModeForSmartDraw = defaults.smartDrawSavedPressureMode
        if smartDrawEnabled,
           savedPenPressureModeForSmartDraw == nil,
           defaults.pressureMode != .fixed {
            savedPenPressureModeForSmartDraw = defaults.pressureMode
        }
        penPressureMode = smartDrawEnabled ? .fixed : defaults.pressureMode
        preferredPenVariablePressureMode =
            savedPenPressureModeForSmartDraw
                ?? (defaults.pressureMode == .fixed ? nil : defaults.pressureMode)
        let selectedWidth = switch defaults.tool {
        case .pen:
            penStrokeWidth
        case .highlighter:
            highlighterStrokeWidth
        case .line, .rectangle, .diamond, .ellipse, .arrow:
            geometryStrokeWidth
        case .hand, .select, .text, .eraser:
            penStrokeWidth
        }
        var style = defaults.annotationStyle(strokeWidth: selectedWidth)
        if defaults.tool == .highlighter {
            style.strokeColor = highlighterStrokeColor
            style.opacity = highlighterOpacity
            normalizeHighlighterStyle(&style)
        } else if defaults.tool == .pen {
            style.strokeColor = regularStrokeColor
            style.opacity = penOpacity
            style.strokePattern = .solid
            style.pressureMode = penPressureMode
        } else if Self.toolSupportsStrokePattern(defaults.tool) {
            normalizeGeometryStyle(&style)
        } else {
            style.strokeColor = regularStrokeColor
        }
        scene.currentStyle = style
        currentLineRoute = defaults.lineRoute
        currentArrowRoute = defaults.arrowRoute
        currentStartArrowhead = defaults.startArrowhead
        currentEndArrowhead = defaults.endArrowhead
        currentArrowheadSize = defaults.arrowheadSize
        scene.currentTool = defaults.tool
        lastNotifiedSmartDrawStatusText = smartDrawStatusText
    }

    /// Whether text exists at the insertion point and the canvas should render
    /// the editing caret instead of the native pointer I-beam.
    var isTypingLocked: Bool {
        activeTextGeometry != nil
    }

    /// Returns the caret origin (top) and height in content space for the text
    /// currently being typed, or the pending insertion point before text exists.
    func typingCaret() -> (origin: CGPoint, height: CGFloat)? {
        let textGeometry = activeTextGeometry
        let fontSize = textGeometry?.fontSize ?? typingFontSize
        let fontName = textGeometry?.fontName ?? typingStorageFontName
        let font = Self.typingFont(named: fontName, size: fontSize)
        let lineHeight = font.ascender - font.descender + font.leading

        guard let textGeometry else {
            return (insertionPoint, lineHeight)
        }

        let lines = textGeometry.text.components(separatedBy: "\n")
        let lastLine = lines.last ?? ""
        let lastWidth = NSString(string: lastLine).size(withAttributes: [.font: font]).width
        let y = textGeometry.origin.y + CGFloat(lines.count - 1) * lineHeight
        let x = switch textGeometry.alignment {
        case .left: textGeometry.origin.x + lastWidth
        case .center: textGeometry.origin.x + lastWidth / 2
        case .right: textGeometry.origin.x
        }
        return (CGPoint(x: x, y: y), lineHeight)
    }

    func begin(at point: CGPoint) {
        begin(at: point, tool: currentTool, pressure: nil)
    }

    func begin(
        at point: CGPoint,
        pressure: CGFloat?,
        timestamp: TimeInterval? = nil,
        zoomScale: CGFloat = 1
    ) {
        begin(
            at: point,
            tool: currentTool,
            pressure: pressure,
            timestamp: timestamp,
            zoomScale: zoomScale
        )
    }

    func begin(
        at point: CGPoint,
        tool: AnnotationTool,
        pressure: CGFloat? = nil,
        legacyModifierGesture: Bool = false,
        timestamp: TimeInterval? = nil,
        zoomScale: CGFloat = 1
    ) {
        guard tool != .hand, tool != .select, tool != .eraser else { return }
        freehandInputResampler.reset()
        rawFreehandInputBuffer.removeAll()
        freehandTailPreviewSample = nil
        if linearConstruction != nil {
            cancelLinearConstruction()
        }
        recentlyCommittedLinearElementID = nil
        resetSmartDrawStroke()
        editor.beginCreating(tool: tool)
        inProgressUsesLegacyLinearGesture = legacyModifierGesture
        inProgress = AnnotationElement.legacy(
            tool: tool,
            points: [point],
            style: styleForCreation(tool)
        )
        if var element = inProgress, case .shape(let shape) = element.geometry {
            inProgressShapeAnchor = point
            element.geometry = .shape(
                Self.axisAlignedShape(
                    kind: shape.kind,
                    anchor: point,
                    point: point,
                    constrainAspect: false
                )
            )
            element.metadata.rotation = 0
            inProgress = element
        } else {
            inProgressShapeAnchor = nil
        }
        if var element = inProgress, case .linear(var linear) = element.geometry {
            if legacyModifierGesture {
                linear.route = .straight
                linear.bezierControls = []
                linear.startArrowhead = tool == .arrow ? .arrow : .none
                linear.endArrowhead = .none
                linear.arrowheadSize = .small
            } else {
                let route = linearRoute(for: tool)
                linear.route = route
                linear.arrowheadSize = currentArrowheadSize
                if route == .curved {
                    linear.bezierControls = AnnotationGeometry.bezierControls(for: linear)
                }
                linear.startArrowhead = currentStartArrowhead
                linear.endArrowhead = currentEndArrowhead
            }
            element.geometry = .linear(linear)
            inProgress = element
        }
        updateLatestFreehandSample(
            pressure: resolvedFreehandPressure(
                for: inProgress,
                explicitPressure: pressure,
                point: point,
                timestamp: timestamp,
                zoomScale: zoomScale,
                beginsStroke: true
            ),
            timestamp: timestamp
        )
        if let inProgress,
           case .freehand(let freehand) = inProgress.geometry,
           let firstSample = freehand.samples.first {
            freehandInputResampler.begin(with: firstSample)
        }
        if tool == .pen, smartDrawEnabled {
            smartDrawStrokeStartTime = timestamp ?? ProcessInfo.processInfo.systemUptime
            updateSmartDrawCandidate(
                timestamp: timestamp,
                zoomScale: zoomScale
            )
            notifySmartDrawStatusIfNeeded()
        }
    }

    func beginLinearConstructionFromClick(at point: CGPoint, zoomScale: CGFloat) {
        guard var element = inProgress,
              case .linear(var linear) = element.geometry else {
            return
        }
        linear.points = [point]
        linear.bezierControls = []
        element.geometry = .linear(linear)
        inProgress = nil
        inProgressUsesLegacyLinearGesture = false
        linearConstruction = LinearConstruction(
            element: element,
            previewPoint: point,
            zoomScale: max(zoomScale, 0.001)
        )
        onStateChanged?()
    }

    func updateLinearConstructionPreview(at point: CGPoint, zoomScale: CGFloat) {
        guard var construction = linearConstruction else { return }
        construction.previewPoint = point
        construction.zoomScale = max(zoomScale, 0.001)
        linearConstruction = construction
    }

    @discardableResult
    func commitLinearConstructionPoint(at point: CGPoint, zoomScale: CGFloat) -> Bool {
        guard var construction = linearConstruction,
              case .linear(var linear) = construction.element.geometry else {
            return false
        }
        construction.previewPoint = point
        construction.zoomScale = max(zoomScale, 0.001)
        let previousCount = linear.points.count
        appendConstructionPoint(point, to: &linear)
        guard linear.points.count > previousCount else {
            linearConstruction = construction
            return false
        }
        construction.element.geometry = .linear(linear)
        linearConstruction = construction
        onStateChanged?()
        return true
    }

    @discardableResult
    func finishLinearConstruction(
        commitPreview: Bool,
        enterPointEditing: Bool = false
    ) -> Bool {
        guard var construction = linearConstruction,
              case .linear(var linear) = construction.element.geometry else {
            return false
        }
        if commitPreview {
            appendConstructionPoint(construction.previewPoint, to: &linear)
        }
        guard Self.hasMinimumLinearPoints(linear.points) else {
            cancelLinearConstruction()
            return false
        }

        construction.element.geometry = .linear(linear)
        let committed = elementByApplyingEndpointBindings(
            to: construction.element,
            zoomScale: construction.zoomScale
        )
        let elementID = scene.append(committed)
        recentlyCommittedLinearElementID = elementID
        linearConstruction = nil
        editor.finishCreating()
        if enterPointEditing {
            scene.select([elementID])
            _ = editor.beginLinearPointEditing(elementID: elementID)
            recentlyCommittedLinearElementID = nil
        }
        onStateChanged?()
        return true
    }

    func cancelLinearConstruction() {
        guard linearConstruction != nil else { return }
        linearConstruction = nil
        editor.finishCreating()
        onStateChanged?()
    }

    func resolveLinearConstructionForExit() {
        guard linearConstruction != nil else { return }
        _ = finishLinearConstruction(commitPreview: false)
    }

    func isLinearConstructionFinishHandle(at point: CGPoint, zoomScale: CGFloat) -> Bool {
        guard canFinishLinearPath,
              let endpoint = linearConstructionGeometry?.points.last else {
            return false
        }
        let radius = 10 / max(zoomScale, 0.001)
        return hypot(point.x - endpoint.x, point.y - endpoint.y) <= radius
    }

    func update(
        at point: CGPoint,
        pressure: CGFloat? = nil,
        timestamp: TimeInterval? = nil,
        zoomScale: CGFloat = 1,
        constrainShapeAspect: Bool = false
    ) {
        guard var element = inProgress else { return }
        switch element.geometry {
        case .freehand:
            updateFreehand(
                inputs: [
                    AnnotationRawFreehandInput(
                        location: point,
                        pressure: pressure,
                        timestamp: timestamp
                            ?? ProcessInfo.processInfo.systemUptime
                    )
                ],
                zoomScale: zoomScale
            )
            return
        case .shape(var shape):
            let anchor = inProgressShapeAnchor ?? shape.start
            shape = Self.axisAlignedShape(
                kind: shape.kind,
                anchor: anchor,
                point: point,
                constrainAspect: constrainShapeAspect
            )
            element.geometry = .shape(shape)
            element.metadata.rotation = 0
        case .linear(var linear):
            if linear.points.count == 1 {
                linear.points.append(point)
            } else if linear.points.isEmpty {
                linear.points = [point]
            } else {
                linear.points[linear.points.count - 1] = point
            }
            if linear.route == .curved {
                linear.bezierControls = AnnotationGeometry.bezierControls(for: linear)
            }
            element.geometry = .linear(linear)
        case .text:
            break
        }
        inProgress = element
        updateSmartDrawCandidate(timestamp: timestamp, zoomScale: zoomScale)
    }

    func updateFreehand(
        inputs: [AnnotationRawFreehandInput],
        zoomScale: CGFloat
    ) {
        enqueueFreehandInputs(inputs)
        _ = drainFreehandInput(zoomScale: zoomScale)
    }

    func enqueueFreehandInputs(_ inputs: [AnnotationRawFreehandInput]) {
        guard !inputs.isEmpty,
              let inProgress,
              case .freehand = inProgress.geometry else {
            return
        }
        for input in inputs {
            rawFreehandInputBuffer.append(input)
        }
        if let latest = rawFreehandInputBuffer.last {
            freehandTailPreviewSample = AnnotationPointSample(
                location: latest.location,
                pressure: normalizedPressure(latest.pressure),
                timestamp: latest.timestamp
            )
        }
    }

    var hasPendingFreehandInput: Bool {
        !rawFreehandInputBuffer.isEmpty || freehandInputResampler.hasPendingSamples
    }

    @discardableResult
    func drainFreehandInput(
        zoomScale: CGFloat,
        budget: AnnotationFreehandDrainBudget = .frame
    ) -> AnnotationFreehandDrainStats {
        guard var element = inProgress,
              case .freehand(var freehand) = element.geometry else {
            return AnnotationFreehandDrainStats()
        }
        let maximumRawEvents = max(1, budget.maximumRawEvents)
        let maximumGeneratedSamples = max(1, budget.maximumGeneratedSamples)
        let spacingScale = max(
            budget.spacingScale,
            rawFreehandInputBuffer.count > 8
                ? min(
                    2.6,
                    1 + CGFloat(rawFreehandInputBuffer.count - 8) / 16
                )
                : 1
        )
        var stats = AnnotationFreehandDrainStats()

        func append(_ result: AnnotationFreehandResampleResult) {
            if result.removesTrailingPreview, !freehand.samples.isEmpty {
                freehand.samples.removeLast()
            }
            freehand.samples.append(contentsOf: result.samples)
            stats.generatedSamples += result.samples.count
        }

        while stats.generatedSamples < maximumGeneratedSamples {
            let remainingSamples = maximumGeneratedSamples - stats.generatedSamples
            if freehandInputResampler.hasPendingSamples {
                let result = freehandInputResampler.drainPending(
                    maximumSamples: remainingSamples
                )
                append(result)
                if result.samples.isEmpty {
                    break
                }
                continue
            }
            guard stats.rawEvents < maximumRawEvents,
                  let input = rawFreehandInputBuffer.popFirst() else {
                break
            }
            stats.rawEvents += 1
            let inputSamples = resolvedFreehandSamples(
                for: element,
                explicitPressure: input.pressure,
                point: input.location,
                timestamp: input.timestamp,
                zoomScale: zoomScale
            )
            for sample in inputSamples {
                let remainingSamples =
                    maximumGeneratedSamples - stats.generatedSamples
                guard remainingSamples > 0 else { break }
                let resampled = freehandInputResampler.append(
                    sample,
                    zoomScale: zoomScale,
                    spacingScale: spacingScale,
                    maximumSamples: remainingSamples
                )
                append(resampled)
                if freehandInputResampler.hasPendingSamples
                    || stats.generatedSamples >= maximumGeneratedSamples {
                    break
                }
            }
        }
        element.geometry = .freehand(freehand)
        inProgress = element
        if hasPendingFreehandInput {
            freehandTailPreviewSample = rawFreehandInputBuffer.last.map {
                AnnotationPointSample(
                    location: $0.location,
                    pressure: normalizedPressure($0.pressure),
                    timestamp: $0.timestamp
                )
            } ?? freehandInputResampler.pendingTargetSample
        } else {
            freehandTailPreviewSample = nil
        }
        updateSmartDrawCandidate(
            timestamp: freehand.samples.last?.timestamp,
            zoomScale: zoomScale
        )
        stats.hasPendingWork = hasPendingFreehandInput
        return stats
    }

    func end(
        at point: CGPoint,
        pressure: CGFloat? = nil,
        timestamp: TimeInterval? = nil,
        zoomScale: CGFloat = 1,
        constrainShapeAspect: Bool = false
    ) {
        if let inProgress, case .freehand = inProgress.geometry {
            enqueueFreehandInputs([
                AnnotationRawFreehandInput(
                    location: point,
                    pressure: pressure,
                    timestamp: timestamp ?? ProcessInfo.processInfo.systemUptime
                )
            ])
            drainAllFreehandInput(zoomScale: zoomScale)
            _ = finishInProgressGesture(
                endingPressure: pressure,
                timestamp: timestamp,
                zoomScale: zoomScale
            )
            return
        }
        update(
            at: point,
            pressure: pressure,
            timestamp: timestamp,
            zoomScale: zoomScale,
            constrainShapeAspect: constrainShapeAspect
        )
        _ = finishInProgressGesture(
            endingPressure: pressure,
            timestamp: timestamp,
            zoomScale: zoomScale
        )
    }

    @discardableResult
    func finishQueuedFreehand(
        endingPressure: CGFloat?,
        timestamp: TimeInterval?,
        zoomScale: CGFloat
    ) -> Bool {
        guard !hasPendingFreehandInput else { return false }
        return finishInProgressGesture(
            endingPressure: endingPressure,
            timestamp: timestamp,
            zoomScale: zoomScale
        )
    }

    @discardableResult
    func finishQueuedFreehandBounded(
        endingPressure: CGFloat?,
        timestamp: TimeInterval?,
        zoomScale: CGFloat,
        maximumGeneratedSamples: Int = 512
    ) -> Bool {
        guard let inProgress,
              case .freehand = inProgress.geometry else {
            return false
        }
        let latestInput = rawFreehandInputBuffer.last
            ?? freehandInputResampler.pendingTargetSample.map {
                AnnotationRawFreehandInput(
                    location: $0.location,
                    pressure: $0.pressure,
                    timestamp: $0.timestamp
                        ?? timestamp
                        ?? ProcessInfo.processInfo.systemUptime
                )
            }
        var generatedSamples = 0
        while hasPendingFreehandInput,
              generatedSamples < max(1, maximumGeneratedSamples) {
            let remaining = max(1, maximumGeneratedSamples - generatedSamples)
            let stats = drainFreehandInput(
                zoomScale: zoomScale,
                budget: AnnotationFreehandDrainBudget(
                    maximumRawEvents: AnnotationRawFreehandInputBuffer.defaultCapacity,
                    maximumGeneratedSamples: min(128, remaining),
                    spacingScale: rawFreehandInputBuffer.count > 16 ? 2 : 1
                )
            )
            generatedSamples += stats.generatedSamples
            if stats.rawEvents == 0, stats.generatedSamples == 0 {
                break
            }
        }
        if hasPendingFreehandInput, let latestInput {
            appendFinalFreehandEndpoint(
                latestInput,
                zoomScale: zoomScale
            )
        }
        rawFreehandInputBuffer.removeAll()
        freehandInputResampler.reset()
        freehandTailPreviewSample = nil
        return finishInProgressGesture(
            endingPressure: endingPressure,
            timestamp: timestamp,
            zoomScale: zoomScale
        )
    }

    @discardableResult
    func resolveActiveGestureForExit(zoomScale: CGFloat = 1) -> Bool {
        var committedVisibleGesture = false
        if inProgress != nil {
            drainAllFreehandInput(zoomScale: zoomScale)
            committedVisibleGesture = finishInProgressGesture(
                endingPressure: nil,
                timestamp: nil,
                zoomScale: zoomScale
            )
        }
        if linearConstruction != nil {
            committedVisibleGesture =
                finishLinearConstruction(commitPreview: false)
                || committedVisibleGesture
        }
        if eraserTransactionActive {
            cancelErasing()
        }
        cancelActiveAnnotationWork()
        return committedVisibleGesture
    }

    @discardableResult
    private func finishInProgressGesture(
        endingPressure: CGFloat?,
        timestamp: TimeInterval?,
        zoomScale: CGFloat
    ) -> Bool {
        guard var annotation = inProgress else {
            clearActiveCreationState()
            return false
        }
        guard Self.hasVisibleGestureGeometry(
            annotation,
            zoomScale: zoomScale
        ) else {
            clearActiveCreationState()
            notifySmartDrawStatusIfNeeded()
            return false
        }
        updateSmartDrawCandidate(
            timestamp: timestamp,
            zoomScale: zoomScale,
            force: true
        )
        if !inProgressUsesLegacyLinearGesture, case .linear = annotation.geometry {
            annotation = elementByApplyingEndpointBindings(
                to: annotation,
                zoomScale: zoomScale
            )
        }
        if case .freehand(var freehand) = annotation.geometry,
           annotation.style.pressureMode == .simulated,
           endingPressure == nil {
            AnnotationSimulatedPressureTracker.applyEndTaper(
                to: &freehand.samples,
                zoomScale: zoomScale,
                minimumPressure: freehand.isHighlighter
                    ? AnnotationSimulatedPressureTracker.highlighterMinimumPressure
                    : AnnotationSimulatedPressureTracker.minimumPressure
            )
            annotation.geometry = .freehand(freehand)
        }
        if let candidate = smartDrawTracker.commitCandidate(final: smartDrawLatestCandidate) {
            scene.append(smartDrawElement(from: candidate, replacing: annotation))
        } else {
            renderer.promoteActiveStrokeCache(
                for: annotation,
                destinationPointScale: zoomScale
            )
            let elementID = scene.append(annotation)
            if !inProgressUsesLegacyLinearGesture, case .linear = annotation.geometry {
                recentlyCommittedLinearElementID = elementID
            }
        }
        clearActiveCreationState()
        notifySmartDrawStatusIfNeeded()
        return true
    }

    func undo() {
        if linearConstruction != nil {
            cancelLinearConstruction()
            return
        }
        finishTypingSession()
        _ = scene.undo()
        textAnnotationID = nil
        recentlyCommittedLinearElementID = nil
    }

    func redo() {
        finishTypingSession()
        _ = scene.redo()
        textAnnotationID = nil
        recentlyCommittedLinearElementID = nil
    }

    func clear() {
        cancelActiveAnnotationWork()
        scene.clear()
    }

    func beginErasing(at point: CGPoint, zoomScale: CGFloat) {
        cancelErasing()
        eraserTransactionActive = true
        pendingErasureElementIDs = []
        previousEraserPoint = point
        eraserSweepSampleCountForTesting = 0
        eraserHitTestCountForTesting = 0
        if stageErasure(from: nil, to: point, zoomScale: zoomScale) {
            onStateChanged?()
        }
    }

    func continueErasing(at point: CGPoint, zoomScale: CGFloat) {
        guard eraserTransactionActive else { return }
        let previousPoint = previousEraserPoint
        previousEraserPoint = point
        if stageErasure(
            from: previousPoint,
            to: point,
            zoomScale: zoomScale
        ) {
            onStateChanged?()
        }
    }

    func endErasing() {
        guard eraserTransactionActive else { return }
        eraserTransactionActive = false
        previousEraserPoint = nil
        let elementIDs = pendingErasureElementIDs
        pendingErasureElementIDs = []
        guard !elementIDs.isEmpty else { return }
        scene.removeElements(withIDs: elementIDs)
    }

    func cancelErasing() {
        guard eraserTransactionActive else { return }
        let hadPendingErasure = !pendingErasureElementIDs.isEmpty
        eraserTransactionActive = false
        previousEraserPoint = nil
        pendingErasureElementIDs = []
        if hadPendingErasure {
            onStateChanged?()
        }
    }

    func insertText(_ text: String) {
        if let textAnnotationID {
            guard let element = scene.element(withID: textAnnotationID),
                  !element.metadata.isLocked,
                  case .text = element.geometry else {
                return
            }
            scene.updateElement(withID: textAnnotationID, recordHistory: false) { element in
                guard case .text(var textGeometry) = element.geometry else { return }
                textGeometry.text.append(contentsOf: text)
                element.geometry = .text(textGeometry)
            }
            return
        }

        let element = AnnotationElement.legacy(
            tool: .text,
            points: [insertionPoint],
            style: currentStyle,
            text: text,
            fontSize: typingFontSize,
            fontName: typingStorageFontName,
            textAlignment: typingTextAlignment
        )
        textAnnotationID = element.id
        scene.append(element)
    }

    func deleteBackward() {
        guard let textAnnotationID else {
            undo()
            return
        }
        guard let element = scene.element(withID: textAnnotationID),
              !element.metadata.isLocked,
              case .text(let textGeometry) = element.geometry else {
            return
        }

        if textGeometry.text.isEmpty {
            scene.removeElements(withIDs: [textAnnotationID])
            self.textAnnotationID = nil
        } else {
            scene.updateElement(withID: textAnnotationID, recordHistory: false) { element in
                guard case .text(var text) = element.geometry else { return }
                text.text.removeLast()
                element.geometry = .text(text)
            }
        }
    }

    func render(
        in context: CGContext,
        bounds: CGRect,
        destinationPointScale: CGFloat = 1,
        includeSmartDrawPreview: Bool = true,
        includeInProgress: Bool = true,
        includeEditorChrome: Bool = true,
        includeTransientEraserFeedback: Bool = true,
        freehandPresentationOwner: AnnotationFreehandPresentationOwner =
            .canonicalRenderer
    ) {
        let activeElement = activeElementForRendering(
            includeInProgress: includeInProgress,
            freehandPresentationOwner: freehandPresentationOwner
        )
        renderer.render(
            elements: scene.elements,
            activeElement: activeElement,
            destinationPointScale: destinationPointScale,
            pendingErasureElementIDs: includeTransientEraserFeedback
                ? pendingErasureElementIDs
                : [],
            in: context
        )
        if includeInProgress,
           freehandPresentationOwner == .canonicalRenderer,
           let inProgress,
           case .freehand(let freehand) = inProgress.geometry,
           let start = freehand.samples.last,
           let end = freehandTailPreviewSample {
            renderer.renderFreehandTail(
                from: start,
                to: end,
                style: inProgress.style,
                isHighlighter: freehand.isHighlighter,
                in: context
            )
        }
        if includeInProgress, let construction = linearConstruction {
            renderer.renderLinearConstruction(
                element: construction.element,
                previewPoint: construction.previewPoint,
                canFinish: canFinishLinearPath && includeEditorChrome,
                zoomScale: construction.zoomScale,
                in: context
            )
        }
        if includeSmartDrawPreview,
           let preview = smartDrawPreviewElementSnapshot {
            renderer.renderGhost(
                preview,
                opacityMultiplier: smartDrawTracker.previewCandidate == nil
                    ? 0.28
                    : 0.58,
                destinationPointScale: destinationPointScale,
                in: context
            )
        }
    }

    func renderSelectionDecorations(in context: CGContext, zoomScale: CGFloat) {
        let visibleLinearElement = linearPointDecorationElement
        let decoratedSelection = visibleLinearElement.map {
            scene.selection.elementIDs.subtracting([$0.id])
        } ?? scene.selection.elementIDs
        renderer.renderSelectionDecorations(
            for: scene.elements,
            selectedElementIDs: decoratedSelection,
            zoomScale: zoomScale,
            in: context
        )
        if let visibleLinearElement {
            renderer.renderLinearPointEditing(
                for: visibleLinearElement,
                selectedPointIndices: editor.selectedLinearPointIndices,
                selectedSegmentIndex: editor.selectedLinearSegmentIndex,
                selectedControl: editor.selectedLinearControl,
                zoomScale: zoomScale,
                in: context
            )
        }
        if let marqueeBounds = editor.marqueeBounds {
            renderer.renderMarquee(marqueeBounds, zoomScale: zoomScale, in: context)
        }
    }

    private var passiveSelectedLinearElement: AnnotationElement? {
        guard currentTool == .select,
              scene.selection.elementIDs.count == 1,
              let elementID = scene.selection.elementIDs.first,
              let element = scene.element(withID: elementID),
              !element.metadata.isLocked,
              case .linear = element.geometry else {
            return nil
        }
        return element
    }

    func beginSelectionInteraction(
        at point: CGPoint,
        zoomScale: CGFloat,
        modifiers: AnnotationEditorModifiers,
        clickCount: Int
    ) -> AnnotationEditorOutcome {
        editor.beginInteraction(
            at: point,
            zoomScale: zoomScale,
            modifiers: modifiers,
            clickCount: clickCount
        )
    }

    func updateSelectionInteraction(
        to point: CGPoint,
        modifiers: AnnotationEditorModifiers
    ) {
        editor.updateInteraction(to: point, modifiers: modifiers)
    }

    func endSelectionInteraction(
        at point: CGPoint,
        modifiers: AnnotationEditorModifiers
    ) {
        editor.endInteraction(at: point, modifiers: modifiers)
    }

    func cancelSelectionInteraction() {
        editor.cancelInteraction()
    }

    func prepareContextSelection(at point: CGPoint, zoomScale: CGFloat) -> Bool {
        editor.prepareContextSelection(at: point, zoomScale: zoomScale)
    }

    func selectAll() {
        editor.selectAll()
    }

    func clearSelection() {
        editor.clearSelection()
    }

    func deleteSelection() {
        editor.deleteSelection()
    }

    func duplicateSelection(offset: CGPoint) {
        editor.duplicateSelection(offset: offset)
    }

    func moveSelection(by delta: CGPoint) {
        editor.moveSelection(by: delta)
    }

    func arrangeSelection(_ action: AnnotationArrangeAction) {
        editor.arrangeSelection(action)
    }

    func groupSelection() {
        editor.groupSelection()
    }

    func ungroupSelection() {
        editor.ungroupSelection()
    }

    func toggleSelectionLock() {
        editor.toggleSelectionLock()
    }

    func setStrokeColor(_ color: AnnotationColorValue) {
        applyStyleChange { $0.strokeColor = color }
    }

    func setTextColor(_ color: AnnotationColorValue) {
        applyStyleChange(where: Self.isText) { $0.strokeColor = color }
    }

    func setLegacyColor(_ color: AnnotationColor, highlighted: Bool) {
        applyStyleChange {
            $0.strokeColor = .palette(color)
            $0.opacity = highlighted ? AnnotationStyle.highlightAlpha : 1
            $0.usesLegacyHighlightCompositing = highlighted
        }
    }

    func setFillColor(_ color: AnnotationColorValue) {
        applyStyleChange(where: Self.isShape) { $0.fillColor = color }
    }

    func setShapeBackground(_ color: AnnotationColorValue?) {
        applyStyleChange(where: Self.isShape) { style in
            guard let color, !color.isTransparent else {
                style.fillStyle = .none
                return
            }
            style.fillColor = color
            if style.fillStyle == .none {
                style.fillStyle = .hachure
            }
        }
    }

    func setFillStyle(_ fillStyle: AnnotationFillStyle) {
        applyStyleChange(where: Self.isShape) { $0.fillStyle = fillStyle }
    }

    func setStrokeWidth(_ width: CGFloat) {
        let normalizedWidth = min(max(width, 1), 64)
        if selectedElementSnapshot.isEmpty {
            switch currentTool {
            case .pen:
                penStrokeWidth = normalizedWidth
            case .highlighter:
                highlighterStrokeWidth = normalizedWidth
            case .line, .rectangle, .diamond, .ellipse, .arrow:
                geometryStrokeWidth = normalizedWidth
            case .hand, .select, .text, .eraser:
                break
            }
        }
        applyStyleChange(where: Self.supportsStrokeWidth) {
            $0.strokeWidth = normalizedWidth
        }
    }

    func setStrokePattern(_ pattern: AnnotationStrokePattern) {
        let selected = selectedElementSnapshot
        if selected.isEmpty, !Self.toolSupportsStrokePattern(currentTool) {
            return
        }
        applyStyleChange(where: Self.supportsStrokePattern) {
            $0.strokePattern = pattern
        }
    }

    func setSloppiness(_ sloppiness: AnnotationSloppiness) {
        let selected = selectedElementSnapshot
        if selected.isEmpty,
           currentTool != .pen,
           !Self.toolSupportsSloppiness(currentTool) {
            return
        }
        applyStyleChange(where: Self.supportsSloppiness) {
            $0.sloppiness = sloppiness
        }
    }

    func setOpacity(_ opacity: CGFloat) {
        applyStyleChange {
            $0.opacity = min(max(opacity, 0.05), 1)
            $0.usesLegacyHighlightCompositing = false
        }
    }

    func setTextOpacity(_ opacity: CGFloat) {
        applyStyleChange(where: Self.isText) {
            $0.opacity = min(max(opacity, 0.05), 1)
            $0.usesLegacyHighlightCompositing = false
        }
    }

    func beginContinuousStyleEdit(owner: DrawingContinuousStyleEditOwner) {
        guard continuousStyleTransactionOwners.insert(owner).inserted,
              continuousStyleTransactionOwners.count == 1 else {
            return
        }
        scene.beginTransaction()
    }

    @discardableResult
    func endContinuousStyleEdit(
        owner: DrawingContinuousStyleEditOwner
    ) -> Bool {
        guard continuousStyleTransactionOwners.remove(owner) != nil,
              continuousStyleTransactionOwners.isEmpty else {
            return false
        }
        scene.commitTransaction()
        return true
    }

    func setPressureEnabled(_ isEnabled: Bool) {
        setPressureMode(isEnabled ? .tablet : .fixed)
    }

    func setPressureMode(_ mode: AnnotationPressureMode) {
        let selected = selectedElementSnapshot
        let targetIDs = Set(
            selected
                .filter {
                    !$0.metadata.isLocked
                        && Self.isPressureCapableFreehand($0)
                }
                .map(\.id)
        )
        if selected.isEmpty, currentTool != .pen {
            return
        }
        guard selected.isEmpty || !targetIDs.isEmpty else { return }

        let targetElements = selected.filter { targetIDs.contains($0.id) }
        if selected.isEmpty
            || selectionMatchesCurrentCreationTool(targetElements) {
            if selected.isEmpty, smartDrawEnabled {
                if mode != .fixed {
                    savedPenPressureModeForSmartDraw = mode
                    preferredPenVariablePressureMode = mode
                }
                return
            }
            var style = currentStyle
            style.pressureMode = mode
            currentStyle = style
        }

        guard !targetIDs.isEmpty else { return }
        scene.beginTransaction()
        scene.updateElements(withIDs: targetIDs) { element in
            element.style.pressureMode = mode
            guard mode != .fixed,
                  case .freehand(var freehand) = element.geometry,
                  AnnotationPressureBackfill.needsSimulatedPressure(
                      freehand.samples
                  ) else {
                return
            }
            freehand.samples = AnnotationPressureBackfill.simulatedSamples(
                from: freehand.samples,
                minimumPressure: freehand.isHighlighter
                    ? AnnotationSimulatedPressureTracker.highlighterMinimumPressure
                    : AnnotationSimulatedPressureTracker.minimumPressure
            )
            element.geometry = .freehand(freehand)
        }
        scene.commitTransaction()
    }

    func setSmoothingEnabled(_ isEnabled: Bool) {
        applyStyleChange(where: Self.isFreehand) { $0.smoothingEnabled = isEnabled }
    }

    func setSmartDrawEnabled(_ isEnabled: Bool) {
        guard currentTool == .pen, selectedElementSnapshot.isEmpty else { return }
        guard smartDrawEnabled != isEnabled else { return }
        var style = currentStyle
        if isEnabled {
            if penPressureMode != .fixed {
                savedPenPressureModeForSmartDraw = penPressureMode
                preferredPenVariablePressureMode = penPressureMode
            }
            penPressureMode = .fixed
            style.pressureMode = .fixed
        } else {
            let restoredMode = savedPenPressureModeForSmartDraw ?? .fixed
            savedPenPressureModeForSmartDraw = nil
            penPressureMode = restoredMode
            style.pressureMode = restoredMode
        }
        smartDrawEnabled = isEnabled
        currentStyle = style
        if !isEnabled {
            resetSmartDrawStroke()
        }
        lastNotifiedSmartDrawStatusText = smartDrawStatusText
        onStateChanged?()
    }

    func setRoundness(_ roundness: CGFloat?) {
        applyStyleChange(where: Self.supportsRoundness) {
            $0.roundness = roundness.map { max(0, $0) }
        }
    }

    func setEdgeStyle(_ edgeStyle: AnnotationEdgeStyle) {
        let roundness: CGFloat? = edgeStyle == .round ? 20 : nil
        let route: AnnotationLinearRoute = edgeStyle == .round ? .curved : .straight
        let selected = selectedElementSnapshot
        let editableEdgeElements = selected.filter {
            !$0.metadata.isLocked && Self.supportsEdgeStyle($0)
        }
        guard selected.isEmpty || !editableEdgeElements.isEmpty else { return }
        let editableShapeElements = editableEdgeElements.filter {
            guard case .shape(let shape) = $0.geometry else { return false }
            return shape.kind == .rectangle || shape.kind == .diamond
        }
        let editableLinearElements = editableEdgeElements.filter {
            guard case .linear(let linear) = $0.geometry else { return false }
            return linear.startArrowhead == .none && linear.endArrowhead == .none
        }
        let updatesShapeDefaults = selected.isEmpty
            ? currentTool == .rectangle || currentTool == .diamond
            : selectionMatchesCurrentCreationTool(editableShapeElements)
        let updatesLinearDefaults = selected.isEmpty
            ? currentTool == .line
            : selectionMatchesCurrentCreationTool(editableLinearElements)

        if updatesShapeDefaults {
            var style = currentStyle
            style.roundness = roundness
            currentStyle = style
        }
        if updatesLinearDefaults {
            currentLineRoute = route
            if var construction = linearConstruction,
               case .linear(var linear) = construction.element.geometry,
               linear.startArrowhead == .none,
               linear.endArrowhead == .none {
                Self.apply(edgeStyle: edgeStyle, to: &linear)
                construction.element.geometry = .linear(linear)
                linearConstruction = construction
            }
        }

        let editableIDs = Set(editableEdgeElements.map(\.id))
        guard !editableIDs.isEmpty else {
            onStateChanged?()
            return
        }

        scene.beginTransaction()
        scene.updateElements(withIDs: editableIDs) { element in
            switch element.geometry {
            case .shape:
                element.style.roundness = roundness
            case .linear(var linear):
                Self.apply(edgeStyle: edgeStyle, to: &linear)
                element.geometry = .linear(linear)
            case .freehand, .text:
                break
            }
        }
        scene.commitTransaction()
        onStateChanged?()
    }

    @discardableResult
    func toggleLinearPointEditing() -> Bool {
        editor.toggleLinearPointEditing()
    }

    func insertLinearPoint() {
        editor.insertLinearPoint()
    }

    func removeLinearPoints() {
        editor.removeSelectedLinearPoints()
    }

    func setLinearRoute(_ route: AnnotationLinearRoute) {
        guard canApplyLinearMutationToSelection else { return }
        let updatesCreationDefaults = shouldUpdateLinearCreationDefaults
        if updatesCreationDefaults {
            setCurrentLinearRoute(route)
            if var construction = linearConstruction,
               case .linear(var linear) = construction.element.geometry {
                linear.route = route
                switch route {
                case .straight:
                    linear.bezierControls = []
                case .curved:
                    linear.bezierControls = []
                    linear.bezierControls = AnnotationGeometry.bezierControls(
                        for: linear
                    )
                }
                construction.element.geometry = .linear(linear)
                linearConstruction = construction
            }
        }
        editor.setLinearRoute(route)
        onStateChanged?()
    }

    func setLinearArrowheads(start: AnnotationArrowhead, end: AnnotationArrowhead) {
        guard canApplyLinearMutationToSelection else { return }
        if shouldUpdateLinearCreationDefaults {
            currentStartArrowhead = start
            currentEndArrowhead = end
            updateLinearConstructionArrowheads(start: start, end: end)
        }
        editor.setLinearArrowheads(start: start, end: end)
        onStateChanged?()
    }

    func setLinearStartArrowhead(_ arrowhead: AnnotationArrowhead) {
        guard canApplyLinearMutationToSelection else { return }
        if shouldUpdateLinearCreationDefaults {
            currentStartArrowhead = arrowhead
            updateLinearConstructionArrowheads(start: arrowhead, end: nil)
        }
        editor.setLinearStartArrowhead(arrowhead)
        onStateChanged?()
    }

    func setLinearEndArrowhead(_ arrowhead: AnnotationArrowhead) {
        guard canApplyLinearMutationToSelection else { return }
        if shouldUpdateLinearCreationDefaults {
            currentEndArrowhead = arrowhead
            updateLinearConstructionArrowheads(start: nil, end: arrowhead)
        }
        editor.setLinearEndArrowhead(arrowhead)
        onStateChanged?()
    }

    func setLinearArrowheadSize(_ size: AnnotationArrowheadSize) {
        guard canApplyLinearMutationToSelection else { return }
        if shouldUpdateLinearCreationDefaults {
            currentArrowheadSize = size
            if var construction = linearConstruction,
               case .linear(var linear) = construction.element.geometry {
                linear.arrowheadSize = size
                construction.element.geometry = .linear(linear)
                linearConstruction = construction
            }
        }
        editor.setLinearArrowheadSize(size)
        onStateChanged?()
    }

    func unbindLinearEndpoints() {
        editor.unbindLinearEndpoints()
    }

    private var activeTextGeometry: AnnotationTextGeometry? {
        guard let textAnnotationID,
              let element = scene.element(withID: textAnnotationID),
              !element.metadata.isLocked,
              case .text(let text) = element.geometry else {
            return nil
        }
        return text
    }

    private func applyStyleChange(
        where predicate: (AnnotationElement) -> Bool = { _ in true },
        _ update: (inout AnnotationStyle) -> Void
    ) {
        let selected = selectedElementSnapshot
        var targetElements = selected.filter {
            !$0.metadata.isLocked && predicate($0)
        }
        let editableIDs = Set(targetElements.map(\.id))
        var targetIDs = editableIDs
        if textTransactionActive,
           let textAnnotationID,
           let activeText = scene.element(withID: textAnnotationID),
           !activeText.metadata.isLocked,
           predicate(activeText) {
            targetIDs.insert(textAnnotationID)
            if !targetElements.contains(where: { $0.id == textAnnotationID }) {
                targetElements.append(activeText)
            }
        }
        guard selected.isEmpty || !targetIDs.isEmpty else { return }

        if selected.isEmpty || selectionMatchesCurrentCreationTool(targetElements) {
            var style = currentStyle
            update(&style)
            currentStyle = style
            if var construction = linearConstruction {
                construction.element.style = style
                linearConstruction = construction
            }
        }

        guard !targetIDs.isEmpty else { return }

        if textTransactionActive {
            scene.updateElements(withIDs: targetIDs, recordHistory: false) { element in
                update(&element.style)
            }
            return
        }

        scene.beginTransaction()
        scene.updateElements(withIDs: targetIDs) { element in
            update(&element.style)
        }
        scene.commitTransaction()
    }

    private func applyTextGeometryChange(
        _ update: (inout AnnotationTextGeometry) -> Void
    ) {
        var editableTextIDs = Set(
            selectedElementSnapshot.compactMap { element -> AnnotationElementID? in
                guard !element.metadata.isLocked, case .text = element.geometry else {
                    return nil
                }
                return element.id
            }
        )
        if let textAnnotationID,
           let element = scene.element(withID: textAnnotationID),
           !element.metadata.isLocked,
           case .text = element.geometry {
            editableTextIDs.insert(textAnnotationID)
        }

        if textTransactionActive, let textAnnotationID,
           editableTextIDs.contains(textAnnotationID) {
            scene.updateElement(withID: textAnnotationID, recordHistory: false) { element in
                guard case .text(var text) = element.geometry else { return }
                update(&text)
                element.geometry = .text(text)
            }
            return
        }

        guard !editableTextIDs.isEmpty else {
            onStateChanged?()
            return
        }
        scene.beginTransaction()
        scene.updateElements(withIDs: editableTextIDs) { element in
            guard case .text(var text) = element.geometry else { return }
            update(&text)
            element.geometry = .text(text)
        }
        scene.commitTransaction()
    }

    private static func isShape(_ element: AnnotationElement) -> Bool {
        if case .shape = element.geometry { return true }
        return false
    }

    private static func isText(_ element: AnnotationElement) -> Bool {
        if case .text = element.geometry { return true }
        return false
    }

    private static func isFreehand(_ element: AnnotationElement) -> Bool {
        if case .freehand = element.geometry { return true }
        return false
    }

    private static func supportsStrokeWidth(_ element: AnnotationElement) -> Bool {
        switch element.geometry {
        case .freehand, .shape, .linear:
            true
        case .text:
            false
        }
    }

    private static func supportsStrokePattern(_ element: AnnotationElement) -> Bool {
        switch element.geometry {
        case .shape, .linear:
            true
        case .freehand, .text:
            false
        }
    }

    private static func supportsRoundness(_ element: AnnotationElement) -> Bool {
        guard case .shape(let shape) = element.geometry else { return false }
        return shape.kind == .rectangle || shape.kind == .diamond
    }

    private static func supportsEdgeStyle(_ element: AnnotationElement) -> Bool {
        switch element.geometry {
        case .shape(let shape):
            return shape.kind == .rectangle || shape.kind == .diamond
        case .linear(let linear):
            return linear.startArrowhead == .none && linear.endArrowhead == .none
        case .freehand, .text:
            return false
        }
    }

    private static func apply(
        edgeStyle: AnnotationEdgeStyle,
        to linear: inout AnnotationLinearGeometry
    ) {
        switch edgeStyle {
        case .sharp:
            linear.route = .straight
            linear.bezierControls = []
        case .round:
            linear.route = .curved
            linear.bezierControls = AnnotationGeometry.bezierControls(for: linear)
        }
    }

    private static func supportsSloppiness(_ element: AnnotationElement) -> Bool {
        switch element.geometry {
        case .freehand, .shape:
            true
        case .linear(let linear):
            !linear.isHeadless
        case .text:
            false
        }
    }

    private func selectionMatchesCurrentCreationTool(
        _ elements: [AnnotationElement]
    ) -> Bool {
        !elements.isEmpty
        && elements.allSatisfy {
            Self.creationTool(for: $0) == currentTool
        }
    }

    private static func creationTool(
        for element: AnnotationElement
    ) -> AnnotationTool {
        switch element.geometry {
        case .freehand(let freehand):
        return freehand.isHighlighter ? .highlighter : .pen
        case .shape(let shape):
        return switch shape.kind {
        case .rectangle: .rectangle
        case .diamond: .diamond
        case .ellipse: .ellipse
        }
        case .linear(let linear):
        return linear.startArrowhead == .none && linear.endArrowhead == .none
            ? .line
            : .arrow
        case .text:
        return .text
        }
    }

    private var canApplyLinearMutationToSelection: Bool {
        let selected = selectedElementSnapshot
        return selected.isEmpty || canEditSelectedLinearProperties
    }

    private var shouldUpdateLinearCreationDefaults: Bool {
        let selected = selectedElementSnapshot
        guard !selected.isEmpty else { return true }
        let editableLinearElements = selected.filter {
            guard !$0.metadata.isLocked, case .linear = $0.geometry else {
                return false
            }
            return true
        }
        return selectionMatchesCurrentCreationTool(editableLinearElements)
    }

    private var canApplyTextMutationToSelection: Bool {
        let selected = selectedElementSnapshot
        guard !selected.isEmpty else { return true }
        if selected.contains(where: {
            guard !$0.metadata.isLocked, case .text = $0.geometry else {
                return false
            }
            return true
        }) {
            return true
        }
        guard let textAnnotationID,
              let activeText = scene.element(withID: textAnnotationID),
              !activeText.metadata.isLocked,
              case .text = activeText.geometry else {
            return false
        }
        return true
    }

    private var shouldUpdateTextCreationDefaults: Bool {
        let selected = selectedElementSnapshot
        guard !selected.isEmpty else { return true }
        let editableTextElements = selected.filter {
            guard !$0.metadata.isLocked, case .text = $0.geometry else {
                return false
            }
            return true
        }
        return selectionMatchesCurrentCreationTool(editableTextElements)
    }

    private var linearConstructionGeometry: AnnotationLinearGeometry? {
        guard let construction = linearConstruction,
              case .linear(let linear) = construction.element.geometry else {
            return nil
        }
        return linear
    }

    private func updateLinearConstructionArrowheads(
        start: AnnotationArrowhead?,
        end: AnnotationArrowhead?
    ) {
        guard var construction = linearConstruction,
              case .linear(var linear) = construction.element.geometry else {
            return
        }
        if let start {
            linear.startArrowhead = start
        }
        if let end {
            linear.endArrowhead = end
        }
        construction.element.geometry = .linear(linear)
        linearConstruction = construction
    }

    private func linearRoute(for tool: AnnotationTool) -> AnnotationLinearRoute {
        tool == .arrow ? currentArrowRoute : currentLineRoute
    }

    private func setCurrentLinearRoute(_ route: AnnotationLinearRoute) {
        if currentTool == .arrow {
            currentArrowRoute = route
        } else {
            currentLineRoute = route
        }
    }

    private func appendConstructionPoint(
        _ point: CGPoint,
        to linear: inout AnnotationLinearGeometry
    ) {
        guard let last = linear.points.last else {
            linear.points = [point]
            return
        }
        guard hypot(point.x - last.x, point.y - last.y) > 0.5 else { return }

        switch linear.route {
        case .straight:
            linear.points.append(point)
            linear.bezierControls = []
        case .curved:
            linear.points.append(point)
            var generated = linear
            generated.bezierControls = []
            linear.bezierControls = AnnotationGeometry.bezierControls(for: generated)
        }
    }

    private static func hasMinimumLinearPoints(_ points: [CGPoint]) -> Bool {
        guard let first = points.first else { return false }
        return points.dropFirst().contains {
            hypot($0.x - first.x, $0.y - first.y) > 0.5
        }
    }

    private static func hasVisibleGestureGeometry(
        _ element: AnnotationElement,
        zoomScale: CGFloat
    ) -> Bool {
        guard element.metadata.isVisible else { return false }
        let scale = max(zoomScale, 0.001)
        switch element.geometry {
        case .freehand(let freehand):
            return !freehand.samples.isEmpty
                && element.style.strokeWidth * scale > 0.5
        case .shape(let shape):
            return shape.bounds.width * scale > 0.5
                && shape.bounds.height * scale > 0.5
        case .linear(let linear):
            return zip(linear.points, linear.points.dropFirst()).contains {
                hypot(
                    $1.x - $0.x,
                    $1.y - $0.y
                ) * scale > 0.5
            }
        case .text:
            return false
        }
    }

    private func clearActiveCreationState() {
        inProgress = nil
        inProgressShapeAnchor = nil
        inProgressUsesLegacyLinearGesture = false
        simulatedPressureTracker.reset()
        freehandInputResampler.reset()
        rawFreehandInputBuffer.removeAll()
        freehandTailPreviewSample = nil
        resetSmartDrawStroke()
        renderer.resetActiveStrokeCache()
        editor.finishCreating()
    }

    private func cancelActiveAnnotationWork() {
        inProgress = nil
        inProgressShapeAnchor = nil
        inProgressUsesLegacyLinearGesture = false
        linearConstruction = nil
        recentlyCommittedLinearElementID = nil
        simulatedPressureTracker.reset()
        freehandInputResampler.reset()
        rawFreehandInputBuffer.removeAll()
        freehandTailPreviewSample = nil
        resetSmartDrawStroke()
        eraserTransactionActive = false
        pendingErasureElementIDs = []
        previousEraserPoint = nil
        eraserSweepSampleCountForTesting = 0
        eraserHitTestCountForTesting = 0
        textAnnotationID = nil
        textTransactionActive = false
        continuousStyleTransactionOwners.removeAll()
        renderer.resetActiveStrokeCache()

        editor.cancelInteraction()
        scene.cancelTransaction()
        lastNotifiedSmartDrawStatusText = smartDrawStatusText
        onStateChanged?()
    }

    private func drainAllFreehandInput(zoomScale: CGFloat) {
        while hasPendingFreehandInput {
            let stats = drainFreehandInput(zoomScale: zoomScale)
            if stats.rawEvents == 0, stats.generatedSamples == 0 {
                break
            }
        }
    }

    private func appendFinalFreehandEndpoint(
        _ input: AnnotationRawFreehandInput,
        zoomScale: CGFloat
    ) {
        guard var element = inProgress,
              case .freehand(var freehand) = element.geometry else {
            return
        }
        let resolved = resolvedFreehandSamples(
            for: element,
            explicitPressure: input.pressure,
            point: input.location,
            timestamp: input.timestamp,
            zoomScale: zoomScale
        ).last ?? AnnotationPointSample(
            location: input.location,
            pressure: normalizedPressure(input.pressure),
            timestamp: input.timestamp
        )
        if freehand.samples.last?.location == resolved.location {
            freehand.samples[freehand.samples.count - 1] = resolved
        } else {
            freehand.samples.append(resolved)
        }
        element.geometry = .freehand(freehand)
        inProgress = element
    }

    private func elementByApplyingEndpointBindings(
        to element: AnnotationElement,
        zoomScale: CGFloat
    ) -> AnnotationElement {
        guard case .linear(var linear) = element.geometry,
              let first = linear.points.first,
              let last = linear.points.last else {
            return element
        }
        let tolerance = 16 / max(zoomScale, 0.001)
        if let target = bindingCandidate(near: first, excluding: element.id, tolerance: tolerance) {
            linear.startBinding = AnnotationGeometry.binding(to: target, near: first)
        }
        if let target = bindingCandidate(near: last, excluding: element.id, tolerance: tolerance) {
            linear.endBinding = AnnotationGeometry.binding(to: target, near: last)
        }
        var result = element
        result.geometry = .linear(linear)
        return result
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

    private func stageErasure(
        from previousPoint: CGPoint?,
        to point: CGPoint,
        zoomScale: CGFloat
    ) -> Bool {
        let candidates = scene.elements.filter {
            $0.metadata.isVisible
                && !$0.metadata.isLocked
                && !pendingErasureElementIDs.contains($0.id)
        }
        let start = previousPoint ?? point
        let distance = hypot(point.x - start.x, point.y - start.y)
        let spacing = max(
            0.001,
            AnnotationHitTester.minimumEffectiveHitRadius(
                for: candidates,
                zoomScale: zoomScale
            )
        )
        let stepCount = previousPoint == nil
            ? 1
            : max(1, Int(ceil(distance / spacing)))
        var changed = false
        var stagedDuringSweep: Set<AnnotationElementID> = []

        for step in 1...stepCount {
            eraserSweepSampleCountForTesting += 1
            let fraction = previousPoint == nil
                ? 1
                : CGFloat(step) / CGFloat(stepCount)
            let sample = CGPoint(
                x: start.x + (point.x - start.x) * fraction,
                y: start.y + (point.y - start.y) * fraction
            )
            let hits = AnnotationHitTester.bodyHits(
                point: sample,
                elements: candidates,
                excluding: stagedDuringSweep,
                zoomScale: zoomScale
            )
            eraserHitTestCountForTesting += hits.testedElementCount
            stagedDuringSweep.formUnion(hits.elementIDs)
            for elementID in hits.elementIDs {
                changed = pendingErasureElementIDs.insert(elementID).inserted
                    || changed
            }
        }
        return changed
    }

    private func updateLatestFreehandSample(
        pressure: CGFloat?,
        timestamp: TimeInterval?
    ) {
        guard var element = inProgress,
              case .freehand(var freehand) = element.geometry,
              !freehand.samples.isEmpty else {
            return
        }
        freehand.samples[freehand.samples.count - 1].pressure = normalizedPressure(pressure)
        freehand.samples[freehand.samples.count - 1].timestamp = timestamp
        element.geometry = .freehand(freehand)
        inProgress = element
    }

    private func normalizedPressure(_ pressure: CGFloat?) -> CGFloat? {
        guard let pressure, pressure.isFinite else { return nil }
        return min(1, max(0, pressure))
    }

    private func resolvedFreehandSamples(
        for element: AnnotationElement,
        explicitPressure: CGFloat?,
        point: CGPoint,
        timestamp: TimeInterval?,
        zoomScale: CGFloat
    ) -> [AnnotationPointSample] {
        guard case .freehand = element.geometry else { return [] }
        if element.style.pressureMode == .simulated, explicitPressure == nil {
            let resolvedTimestamp = timestamp
                ?? ((simulatedPressureTracker.lastTimestamp ?? (-1.0 / 60)) + 1.0 / 60)
            guard var sample = simulatedPressureTracker.resampledSamples(
                at: point,
                timestamp: resolvedTimestamp,
                zoomScale: zoomScale
            ).last else {
                return []
            }
            sample.pressure = max(
                simulatedPressureFloor(for: element),
                sample.pressure ?? 0
            )
            return [sample]
        }
        return [
            AnnotationPointSample(
                location: point,
                pressure: resolvedFreehandPressure(
                    for: element,
                    explicitPressure: explicitPressure,
                    point: point,
                    timestamp: timestamp,
                    zoomScale: zoomScale,
                    beginsStroke: false
                ),
                timestamp: timestamp
            )
        ]
    }

    private func resolvedFreehandPressure(
        for element: AnnotationElement?,
        explicitPressure: CGFloat?,
        point: CGPoint,
        timestamp: TimeInterval?,
        zoomScale: CGFloat,
        beginsStroke: Bool
    ) -> CGFloat? {
        guard let element, case .freehand = element.geometry else { return nil }
        switch element.style.pressureMode {
        case .fixed:
            return nil
        case .tablet:
            return normalizedPressure(explicitPressure)
        case .simulated:
            if let explicitPressure = normalizedPressure(explicitPressure) {
                return explicitPressure
            }
            let resolvedTimestamp = timestamp
                ?? ((simulatedPressureTracker.lastTimestamp ?? (-1.0 / 60)) + 1.0 / 60)
            if beginsStroke {
                return max(
                    simulatedPressureFloor(for: element),
                    simulatedPressureTracker.begin(
                        at: point,
                        timestamp: resolvedTimestamp
                    )
                )
            }
            return max(
                simulatedPressureFloor(for: element),
                simulatedPressureTracker.sample(
                    at: point,
                    timestamp: resolvedTimestamp,
                    zoomScale: zoomScale
                )
            )
        }
    }

    private func simulatedPressureFloor(
        for element: AnnotationElement
    ) -> CGFloat {
        guard case .freehand(let freehand) = element.geometry,
              freehand.isHighlighter else {
            return AnnotationSimulatedPressureTracker.minimumPressure
        }
        return AnnotationSimulatedPressureTracker.highlighterMinimumPressure
    }

    private func updateSmartDrawCandidate(
        timestamp: TimeInterval?,
        zoomScale: CGFloat,
        force: Bool = false
    ) {
        guard smartDrawEnabled,
              currentInProgressTool == .pen,
              let inProgress,
              case .freehand(let freehand) = inProgress.geometry,
              let startTime = smartDrawStrokeStartTime else {
            return
        }
        let currentTime = timestamp ?? ProcessInfo.processInfo.systemUptime
        if !force {
            guard SmartDrawRecognitionBudget.shouldRecognizePreview(
                lastRecognitionTime: smartDrawLastRecognitionTime,
                lastRecognizedSampleCount: smartDrawLastRecognizedSampleCount,
                timestamp: currentTime,
                sampleCount: freehand.samples.count
            ) else {
                return
            }
        }
        let duration = max(0, currentTime - startTime)
        let maximumPointCount = force
            ? SmartDrawRecognitionBudget.maximumInputPointCount
            : SmartDrawRecognitionBudget.previewInputPointCount
        let points = Self.boundedSmartDrawLocations(
            from: freehand.samples,
            maximumCount: maximumPointCount
        )
        smartDrawLastRecognitionTime = currentTime
        smartDrawLastRecognizedSampleCount = freehand.samples.count
        if force {
            smartDrawRecognitionWork?.cancel()
            smartDrawRecognitionDelivery?.cancel()
            smartDrawRecognitionWork = nil
            smartDrawRecognitionDelivery = nil
            pendingSmartDrawRecognitionRequest = nil
            let candidate = SmartDrawRecognizer.recognize(
                points: points,
                duration: duration,
                zoomScale: zoomScale,
                quality: .final
            )
            smartDrawLatestCandidate = candidate
            smartDrawTracker.update(candidate)
            notifySmartDrawStatusIfNeeded()
            return
        }

        enqueueSmartDrawRecognition(
            SmartDrawRecognitionRequest(
                points: points,
                duration: duration,
                zoomScale: zoomScale
            )
        )
    }

    private func enqueueSmartDrawRecognition(
        _ request: SmartDrawRecognitionRequest
    ) {
        guard smartDrawRecognitionWork == nil,
              smartDrawRecognitionDelivery == nil else {
            pendingSmartDrawRecognitionRequest = request
            return
        }
        startSmartDrawRecognition(request)
    }

    private func startSmartDrawRecognition(
        _ request: SmartDrawRecognitionRequest
    ) {
        let token = smartDrawRecognitionGeneration.submit()
        smartDrawRecognitionSubmissionCountForTesting += 1
        activeSmartDrawRecognitionCount += 1
        smartDrawMaximumConcurrentRecognitionCountForTesting = max(
            smartDrawMaximumConcurrentRecognitionCountForTesting,
            activeSmartDrawRecognitionCount
        )
        let work = Task.detached(priority: .userInitiated) {
            SmartDrawCandidateTransfer(
                candidate: SmartDrawRecognizer.recognize(
                    points: request.points,
                    duration: request.duration,
                    zoomScale: request.zoomScale,
                    quality: .preview
                )
            )
        }
        smartDrawRecognitionWork = work
        smartDrawRecognitionDelivery = Task { [weak self] in
            let transfer = await work.value
            guard !Task.isCancelled, let self else { return }
            finishSmartDrawRecognition(transfer.candidate, token: token)
        }
    }

    private func finishSmartDrawRecognition(
        _ candidate: SmartDrawCandidate?,
        token: SmartDrawRecognitionToken
    ) {
        smartDrawRecognitionWork = nil
        smartDrawRecognitionDelivery = nil
        activeSmartDrawRecognitionCount = max(
            0,
            activeSmartDrawRecognitionCount - 1
        )
        applySmartDrawRecognition(candidate, token: token)
        guard let pending = pendingSmartDrawRecognitionRequest,
              currentInProgressTool == .pen else {
            pendingSmartDrawRecognitionRequest = nil
            return
        }
        pendingSmartDrawRecognitionRequest = nil
        startSmartDrawRecognition(pending)
    }

    static func boundedSmartDrawLocations(
        from samples: [AnnotationPointSample],
        maximumCount: Int
    ) -> [CGPoint] {
        let limit = max(2, maximumCount)
        guard samples.count > limit else {
            return samples.map(\.location)
        }
        let denominator = Double(limit - 1)
        let lastIndex = Double(samples.count - 1)
        return (0..<limit).map { index in
            let sourceIndex = Int(
                (Double(index) * lastIndex / denominator).rounded()
            )
            return samples[sourceIndex].location
        }
    }

    private var currentInProgressTool: AnnotationTool? {
        guard let inProgress else { return nil }
        switch inProgress.geometry {
        case .freehand(let freehand):
            return freehand.isHighlighter ? .highlighter : .pen
        case .shape(let shape):
            return switch shape.kind {
            case .rectangle: .rectangle
            case .diamond: .diamond
            case .ellipse: .ellipse
            }
        case .linear(let linear):
            return linear.startArrowhead != .none || linear.endArrowhead != .none
                ? .arrow
                : .line
        case .text:
            return .text
        }
    }

    private func smartDrawElement(
        from candidate: SmartDrawCandidate,
        replacing annotation: AnnotationElement
    ) -> AnnotationElement {
        var metadata = annotation.metadata
        metadata.rotation = candidate.rotation
        metadata.wasSmartDrawRecognized = true
        var geometry = candidate.geometry
        if case .linear(var linear) = geometry {
            linear.arrowheadSize = currentArrowheadSize
            geometry = .linear(linear)
        }
        return AnnotationElement(
            id: annotation.id,
            geometry: geometry,
            style: annotation.style,
            metadata: metadata
        )
    }

    private static func axisAlignedShape(
        kind: AnnotationShapeKind,
        anchor: CGPoint,
        point: CGPoint,
        constrainAspect: Bool
    ) -> AnnotationShapeGeometry {
        var resolvedPoint = point
        if constrainAspect, kind == .rectangle || kind == .diamond {
            let deltaX = point.x - anchor.x
            let deltaY = point.y - anchor.y
            let side = max(abs(deltaX), abs(deltaY))
            resolvedPoint = CGPoint(
                x: anchor.x + (deltaX < 0 ? -side : side),
                y: anchor.y + (deltaY < 0 ? -side : side)
            )
        }
        return AnnotationShapeGeometry(
            kind: kind,
            start: CGPoint(
                x: min(anchor.x, resolvedPoint.x),
                y: min(anchor.y, resolvedPoint.y)
            ),
            end: CGPoint(
                x: max(anchor.x, resolvedPoint.x),
                y: max(anchor.y, resolvedPoint.y)
            )
        )
    }

    private func resetSmartDrawStroke() {
        smartDrawRecognitionWork?.cancel()
        smartDrawRecognitionDelivery?.cancel()
        smartDrawRecognitionWork = nil
        smartDrawRecognitionDelivery = nil
        pendingSmartDrawRecognitionRequest = nil
        activeSmartDrawRecognitionCount = 0
        smartDrawRecognitionGeneration.beginStroke()
        smartDrawTracker.reset()
        smartDrawStrokeStartTime = nil
        smartDrawLatestCandidate = nil
        smartDrawLastRecognitionTime = nil
        smartDrawLastRecognizedSampleCount = 0
    }

    private func applySmartDrawRecognition(
        _ candidate: SmartDrawCandidate?,
        token: SmartDrawRecognitionToken
    ) {
        guard smartDrawRecognitionGeneration.accepts(token),
              currentInProgressTool == .pen else {
            smartDrawRejectedRecognitionCountForTesting += 1
            return
        }
        let previousPreview = smartDrawTracker.displayCandidate
        smartDrawLatestCandidate = candidate
        smartDrawTracker.update(candidate)
        // Geometry can change while its rounded confidence label stays the same.
        // Invalidate the old ghost too, not just the newly painted Pen tail.
        notifySmartDrawStatusIfNeeded(
            forceRedraw: previousPreview != smartDrawTracker.displayCandidate
        )
    }

    private func notifySmartDrawStatusIfNeeded(forceRedraw: Bool = false) {
        let status = smartDrawStatusText
        guard forceRedraw || status != lastNotifiedSmartDrawStatusText else { return }
        lastNotifiedSmartDrawStatusText = status
        onStateChanged?()
    }

    private func transitionCurrentStyle(
        from previousTool: AnnotationTool,
        to newTool: AnnotationTool
    ) {
        var style = scene.currentStyle
        if previousTool == .highlighter {
            highlighterStrokeColor = style.strokeColor
            highlighterStrokeWidth = style.strokeWidth
            highlighterOpacity = style.opacity
        } else if previousTool == .pen {
            regularStrokeColor = style.strokeColor
            penStrokeWidth = style.strokeWidth
            penOpacity = style.opacity
            penPressureMode = style.pressureMode
            if style.pressureMode != .fixed {
                preferredPenVariablePressureMode = style.pressureMode
            }
        } else if Self.toolSupportsStrokePattern(previousTool) {
            captureGeometryStyle(style, for: previousTool)
        } else if previousTool == .text {
            regularStrokeColor = style.strokeColor
        }
        if previousTool == .pen {
            freehandSloppiness = style.sloppiness
        }

        if newTool == .highlighter {
            style.strokeColor = highlighterStrokeColor
            style.strokeWidth = highlighterStrokeWidth
            style.opacity = highlighterOpacity
            normalizeHighlighterStyle(&style)
        } else {
            style.strokeColor = regularStrokeColor
            if Self.toolSupportsStrokePattern(newTool) {
                normalizeGeometryStyle(&style)
                if newTool == .line {
                    style.sloppiness = .architect
                }
            } else if newTool == .pen {
                style.strokeWidth = penStrokeWidth
                style.opacity = penOpacity
                style.strokePattern = .solid
                style.sloppiness = freehandSloppiness
                style.pressureMode = penPressureMode
                style.lineCap = .round
                style.lineJoin = .round
            }
        }
        scene.currentStyle = style
    }

    private func styleForCreation(_ tool: AnnotationTool) -> AnnotationStyle {
        var style = currentStyle
        switch tool {
        case .pen:
            style.strokeWidth = penStrokeWidth
            style.opacity = penOpacity
            style.strokePattern = .solid
            style.sloppiness = freehandSloppiness
            style.pressureMode = penPressureMode
            style.lineCap = .round
            style.lineJoin = .round
        case .highlighter:
            style.strokeWidth = highlighterStrokeWidth
            style.opacity = highlighterOpacity
            normalizeHighlighterStyle(&style)
        case .line:
            normalizeGeometryStyle(&style)
            style.sloppiness = .architect
        case .rectangle, .diamond, .ellipse, .arrow:
            normalizeGeometryStyle(&style)
        case .hand, .select, .text, .eraser:
            break
        }
        return style
    }

    private func captureGeometryStyle(
        _ style: AnnotationStyle,
        for tool: AnnotationTool
    ) {
        regularStrokeColor = style.strokeColor
        geometryStrokeWidth = style.strokeWidth
        outlinedStrokePattern = style.strokePattern
        if tool != .line {
            outlinedSloppiness = style.sloppiness
        }
        geometryOpacity = style.opacity
        if Self.isShapeTool(tool) {
            geometryFillColor = style.fillColor
            geometryFillStyle = style.fillStyle
        }
    }

    private func normalizeGeometryStyle(_ style: inout AnnotationStyle) {
        style.strokeColor = regularStrokeColor
        style.strokeWidth = geometryStrokeWidth
        style.strokePattern = outlinedStrokePattern
        style.sloppiness = outlinedSloppiness
        style.opacity = geometryOpacity
        style.usesLegacyHighlightCompositing = false
        style.lineCap = .round
        style.lineJoin = .round
        style.pressureMode = .fixed
        style.fillColor = geometryFillColor
        style.fillStyle = geometryFillStyle
    }

    private func normalizeHighlighterStyle(_ style: inout AnnotationStyle) {
        style.strokePattern = .solid
        style.sloppiness = .architect
        style.pressureMode = .fixed
        style.lineCap = .butt
        style.lineJoin = .bevel
        style.usesLegacyHighlightCompositing = false
    }

    private func activeElementForRendering(
        includeInProgress: Bool,
        freehandPresentationOwner: AnnotationFreehandPresentationOwner
    ) -> AnnotationElement? {
        guard includeInProgress, let inProgress else { return nil }
        guard freehandPresentationOwner == .immediateLayers,
              case .freehand(let freehand) = inProgress.geometry,
              freehand.samples.count == 1 else {
            return inProgress
        }
        return nil
    }

    private static func toolSupportsStrokePattern(_ tool: AnnotationTool) -> Bool {
        switch tool {
        case .line, .rectangle, .diamond, .ellipse, .arrow:
            true
        case .hand, .select, .pen, .text, .highlighter, .eraser:
            false
        }
    }

    private static func toolSupportsSloppiness(_ tool: AnnotationTool) -> Bool {
        switch tool {
        case .pen, .rectangle, .diamond, .ellipse, .arrow:
            true
        case .hand, .select, .line, .text, .highlighter, .eraser:
            false
        }
    }

    private static func isShapeTool(_ tool: AnnotationTool) -> Bool {
        switch tool {
        case .rectangle, .diamond, .ellipse:
            true
        case .hand, .select, .pen, .line, .arrow, .text, .highlighter, .eraser:
            false
        }
    }

    private static func isPressureCapableFreehand(_ element: AnnotationElement) -> Bool {
        guard case .freehand(let freehand) = element.geometry else { return false }
        return !freehand.isHighlighter
    }
}
