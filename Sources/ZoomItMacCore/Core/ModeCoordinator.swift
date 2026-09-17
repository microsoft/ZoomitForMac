import AppKit

@MainActor
final class ModeActivationCoordinator {
    enum Kind: Equatable {
        case staticZoom
        case liveZoom
        case drawOnly
        case snip
        case breakTimer
        case panorama
        case demoMirror
        case recordingRegion
    }

    enum CommandDisposition: Equatable {
        case allow
        case block
        case cancelCurrent
    }

    struct Token: Equatable {
        fileprivate let generation: Int
        let kind: Kind
    }

    private struct Reservation {
        let token: Token
        var expectedMode: AppMode
    }

    private var reservation: Reservation?
    private var nextGeneration = 0

    var currentKind: Kind? {
        reservation?.token.kind
    }

    func reserve(
        _ kind: Kind,
        expecting expectedMode: AppMode,
        currentMode: AppMode
    ) -> Token? {
        guard reservation == nil, currentMode == expectedMode else { return nil }
        nextGeneration += 1
        let token = Token(generation: nextGeneration, kind: kind)
        reservation = Reservation(token: token, expectedMode: expectedMode)
        return token
    }

    func owns(_ token: Token, currentMode: AppMode) -> Bool {
        guard let reservation else { return false }
        return reservation.token == token
            && reservation.expectedMode == currentMode
    }

    @discardableResult
    func updateExpectedMode(
        for token: Token,
        currentMode: AppMode,
        to nextMode: AppMode
    ) -> Bool {
        guard var reservation,
              reservation.token == token,
              reservation.expectedMode == currentMode else {
            return false
        }
        reservation.expectedMode = nextMode
        self.reservation = reservation
        return true
    }

    @discardableResult
    func finish(_ token: Token) -> Kind? {
        guard reservation?.token == token else { return nil }
        reservation = nil
        return token.kind
    }

    func cancelCurrent() -> Token? {
        guard let token = reservation?.token else { return nil }
        reservation = nil
        return token
    }

    func disposition(
        for command: AppCommand,
        recordingIsActive: Bool
    ) -> CommandDisposition {
        guard let kind = currentKind else { return .allow }

        switch command {
        case .exit:
            switch kind {
            case .staticZoom, .liveZoom, .drawOnly, .breakTimer:
                return .cancelCurrent
            case .snip, .panorama, .demoMirror, .recordingRegion:
                return .block
            }
        case .toggleRecording:
            guard recordingIsActive else { return .block }
            switch kind {
            case .staticZoom, .liveZoom, .drawOnly, .breakTimer:
                return .allow
            case .snip, .panorama, .demoMirror, .recordingRegion:
                return .block
            }
        case .startPanorama:
            return kind == .panorama ? .allow : .block
        case .toggleDemoMirror:
            return kind == .demoMirror ? .allow : .block
        case .activateStaticZoom,
             .activateLiveZoom,
             .activateDrawWithoutZoom,
             .snipRegion,
             .snipOcr,
             .toggleBreakTimer,
             .zoomIn,
             .zoomOutOrExit,
             .toggleTyping,
             .editText:
            return .block
        default:
            return .allow
        }
    }
}

@MainActor
final class LiveZoomActivationResources<Activation: Equatable, Session: AnyObject> {
    struct Cancellation {
        let session: Session?
        let overlayPresented: Bool
        let wasActive: Bool
    }

    private enum State {
        case idle
        case starting(
            activation: Activation,
            session: Session?,
            overlayPresented: Bool
        )
        case active(activation: Activation, session: Session)
    }

    private var state = State.idle

    var isStarting: Bool {
        if case .starting = state {
            return true
        }
        return false
    }

    var session: Session? {
        switch state {
        case .idle:
            nil
        case .starting(_, let session, _):
            session
        case .active(_, let session):
            session
        }
    }

    var activeSession: Session? {
        if case .active(_, let session) = state {
            return session
        }
        return nil
    }

    func begin(_ activation: Activation) -> Bool {
        guard case .idle = state else { return false }
        state = .starting(
            activation: activation,
            session: nil,
            overlayPresented: false
        )
        return true
    }

    func isCurrent(_ activation: Activation) -> Bool {
        switch state {
        case .idle:
            return false
        case .starting(let currentActivation, _, _),
             .active(let currentActivation, _):
            return currentActivation == activation
        }
    }

    @discardableResult
    func markOverlayPresented(for activation: Activation) -> Bool {
        guard case .starting(
            let currentActivation,
            let session,
            false
        ) = state, currentActivation == activation else {
            return false
        }
        state = .starting(
            activation: activation,
            session: session,
            overlayPresented: true
        )
        return true
    }

    @discardableResult
    func attach(_ session: Session, to activation: Activation) -> Bool {
        guard case .starting(
            let currentActivation,
            let currentSession,
            let overlayPresented
        ) = state,
        currentActivation == activation,
        currentSession == nil || currentSession === session else {
            return false
        }
        state = .starting(
            activation: activation,
            session: session,
            overlayPresented: overlayPresented
        )
        return true
    }

    @discardableResult
    func commit(_ session: Session, for activation: Activation) -> Bool {
        guard case .starting(
            let currentActivation,
            let currentSession,
            true
        ) = state,
        currentActivation == activation,
        currentSession === session else {
            return false
        }
        state = .active(activation: activation, session: session)
        return true
    }

    func finish(_ activation: Activation) -> Cancellation? {
        switch state {
        case .idle:
            return nil
        case .starting(
            let currentActivation,
            let session,
            let overlayPresented
        ):
            guard currentActivation == activation else { return nil }
            state = .idle
            return Cancellation(
                session: session,
                overlayPresented: overlayPresented,
                wasActive: false
            )
        case .active:
            return nil
        }
    }

    func cancel() -> Cancellation? {
        switch state {
        case .idle:
            return nil
        case .starting(
            _,
            let session,
            let overlayPresented
        ):
            state = .idle
            return Cancellation(
                session: session,
                overlayPresented: overlayPresented,
                wasActive: false
            )
        case .active(_, let session):
            state = .idle
            return Cancellation(
                session: session,
                overlayPresented: true,
                wasActive: true
            )
        }
    }
}

enum ExternalRegionSelectorFlow: CaseIterable {
    case recording
    case panorama
    case demoMirror
}

enum ExternalRegionSelectorAccessoryPolicy {
    static func shouldRestore(
        flow: ExternalRegionSelectorFlow,
        expectedMode: AppMode,
        currentMode: AppMode,
        isOverlayPresented: Bool
    ) -> Bool {
        switch flow {
        case .recording, .panorama, .demoMirror:
            isOverlayPresented && expectedMode == currentMode
        }
    }
}

@MainActor
final class ModeCoordinator {
    private struct ExternalRegionSelectorSuppression {
        let flow: ExternalRegionSelectorFlow
        let expectedMode: AppMode
        let token: DrawingAccessorySuppressionToken
    }

    private let settingsStore: SettingsStore
    private let permissionService: PermissionService
    private let displayManager: DisplayManager
    private let captureService: ScreenCaptureService
    private let overlayController: OverlayWindowController
    private let annotationController: AnnotationController
    private let viewportController: ZoomViewportController
    private let userSelectedResourceAccess: UserSelectedResourceAccess

    private(set) var mode: AppMode = .idle
    private var isExiting = false
    private var recordingIsActive = false
    /// The mode to restore when leaving typing mode (zoom vs. draw-without-zoom).
    private var modeBeforeTyping: AppMode = .staticZoom
    private let activationCoordinator = ModeActivationCoordinator()
    private let liveZoomActivation = LiveZoomActivationResources<
        ModeActivationCoordinator.Token,
        LiveCaptureSession
    >()
    /// The current startup or active stream. The activation resources only
    /// publish changes for the coordinator generation that created them.
    private var liveCaptureSession: LiveCaptureSession? {
        liveZoomActivation.session
    }
    /// Drives the region snip (Control+6 / Control+Shift+6).
    private lazy var snipController = SnipController(
        captureService: captureService,
        displayManager: displayManager,
        permissionService: permissionService,
        settingsStore: settingsStore,
        userSelectedResourceAccess: userSelectedResourceAccess
    )
    /// Drives screen recording (Control+5 / Control+Shift+5).
    private lazy var recordingController = RecordingController(
        captureService: captureService,
        displayManager: displayManager,
        permissionService: permissionService,
        settingsStore: settingsStore
    )
    /// Drives panorama (scrolling) capture (Control+8 / Control+Shift+8).
    private lazy var panoramaController = PanoramaController(
        displayManager: displayManager,
        permissionService: permissionService,
        settingsStore: settingsStore,
        userSelectedResourceAccess: userSelectedResourceAccess
    )
    #if !ZOOMIT_APP_STORE
    /// Drives DemoType text synthesis from a file or [start]-prefixed clipboard.
    private lazy var demoTypeController = DemoTypeController(settingsStore: settingsStore)
    #endif
    /// Drives the full-screen break timer (Control+3).
    private lazy var breakTimerController = BreakTimerController(
        displayManager: displayManager,
        captureService: captureService,
        settingsStore: settingsStore,
        userSelectedResourceAccess: userSelectedResourceAccess
    )
    /// Drives DemoMirror (Control+9 / Shift for a region / Option for a window).
    private lazy var demoMirrorController = DemoMirrorController(
        displayManager: displayManager,
        permissionService: permissionService,
        settingsStore: settingsStore
    )
    /// Notified when recording starts/stops so the UI (menu-bar icon) can react.
    var onRecordingStateChanged: ((Bool) -> Void)?
    /// Invoked when live zoom starts/stops so global Control+Up/Down zoom
    /// hotkeys can be registered only while live zoom is active.
    var onBeginLiveZoomNavigation: (() -> Void)?
    var onEndLiveZoomNavigation: (() -> Void)?

    init(
        settingsStore: SettingsStore,
        permissionService: PermissionService,
        displayManager: DisplayManager,
        captureService: ScreenCaptureService,
        overlayController: OverlayWindowController,
        annotationController: AnnotationController,
        viewportController: ZoomViewportController,
        userSelectedResourceAccess: UserSelectedResourceAccess,
        initialMode: AppMode = .idle
    ) {
        self.settingsStore = settingsStore
        self.permissionService = permissionService
        self.displayManager = displayManager
        self.captureService = captureService
        self.overlayController = overlayController
        self.annotationController = annotationController
        self.viewportController = viewportController
        self.userSelectedResourceAccess = userSelectedResourceAccess
        mode = initialMode
    }

    func handle(_ command: AppCommand) {
        var shouldRememberDrawingStyle = false

        switch activationCoordinator.disposition(
            for: command,
            recordingIsActive: recordingIsActive
        ) {
        case .allow:
            break
        case .block:
            return
        case .cancelCurrent:
            cancelCurrentActivation()
            return
        }

        switch command {
        case .activateStaticZoom:
            if mode == .liveZoom {
                toggleLiveZoomDrawing()
            } else {
                activateStaticZoom()
            }
        case .activateLiveZoom:
            activateLiveZoom()
        case .activateDrawWithoutZoom:
            if mode == .liveZoom {
                toggleLiveZoomDrawing()
            } else {
                activateDrawWithoutZoom()
            }
        case .zoomIn:
            zoomIn()
        case .zoomOutOrExit:
            zoomOutOrExit()
        case .exit:
            if mode == .breakTimer {
                stopBreakTimer()
            } else {
                animateExit()
            }
        case .undo:
            annotationController.undo()
            overlayController.requestRedraw()
        case .redo:
            annotationController.redo()
            overlayController.requestRedraw()
        case .clear:
            annotationController.clear()
            overlayController.requestRedraw()
        case .snipRegion(let save):
            startSnip(action: save ? .saveImage : .copyImage)
        case .snipOcr:
            startSnip(action: .recognizeText)
        case .toggleRecording(let region):
            toggleRecording(region: region)
        case .startPanorama(let save):
            togglePanorama(save: save)
        #if !ZOOMIT_APP_STORE
        case .startDemoType:
            demoTypeController.startOrStop()
        case .resetDemoType:
            demoTypeController.reset()
        #endif
        case .toggleBreakTimer:
            toggleBreakTimer()
        case .toggleDemoMirror(let scope):
            toggleDemoMirror(scope: scope)
        case .setTool(let tool):
            Self.applyDrawingToolSelection(
                tool,
                annotationController: annotationController,
                finishTypingIfNeeded: { [self] in
                    finishTypingIfNeeded()
                }
            )
            overlayController.requestRedraw()
            shouldRememberDrawingStyle = true
        case .setColor(let color):
            annotationController.setLegacyColor(color, highlighted: false)
            overlayController.requestRedraw()
            shouldRememberDrawingStyle = true
        case .setHighlightColor(let color):
            // Shift+color: translucent highlighter of that color.
            annotationController.setLegacyColor(color, highlighted: true)
            overlayController.requestRedraw()
            shouldRememberDrawingStyle = true
        case .setStrokeColor(let color):
            annotationController.setStrokeColor(color)
            overlayController.requestRedraw()
            shouldRememberDrawingStyle = true
        case .setTextColor(let color):
            annotationController.setTextColor(color)
            overlayController.requestRedraw()
            shouldRememberDrawingStyle = true
        case .setShapeBackground(let color):
            annotationController.setShapeBackground(color)
            overlayController.requestRedraw()
            shouldRememberDrawingStyle = true
        case .setFillStyle(let fillStyle):
            annotationController.setFillStyle(fillStyle)
            overlayController.requestRedraw()
            shouldRememberDrawingStyle = true
        case .setStrokeWidth(let width):
            annotationController.setStrokeWidth(width)
            overlayController.requestRedraw()
            shouldRememberDrawingStyle = true
        case .setStrokePattern(let pattern):
            annotationController.setStrokePattern(pattern)
            overlayController.requestRedraw()
            shouldRememberDrawingStyle = true
        case .setSloppiness(let sloppiness):
            annotationController.setSloppiness(sloppiness)
            overlayController.requestRedraw()
            shouldRememberDrawingStyle = true
        case .setOpacity(let opacity):
            annotationController.setOpacity(opacity)
            overlayController.requestRedraw()
            shouldRememberDrawingStyle = true
        case .beginContinuousStyleEdit(let owner):
            annotationController.beginContinuousStyleEdit(owner: owner)
        case .endContinuousStyleEdit(let owner):
            shouldRememberDrawingStyle =
                annotationController.endContinuousStyleEdit(owner: owner)
        case .setPressureMode(let mode):
            annotationController.setPressureMode(mode)
            overlayController.requestRedraw()
            shouldRememberDrawingStyle = true
        case .setSmartDrawEnabled(let isEnabled):
            annotationController.setSmartDrawEnabled(isEnabled)
            persistSmartDrawEnabled(isEnabled)
            overlayController.requestRedraw()
        case .setEdgeStyle(let edgeStyle):
            annotationController.setEdgeStyle(edgeStyle)
            overlayController.requestRedraw()
            shouldRememberDrawingStyle = true
        case .setTextFontPreset(let preset):
            annotationController.setTextFontPreset(preset)
            saveCurrentTypingFontPreset()
            overlayController.requestRedraw()
        case .setTextFontName(let fontName):
            annotationController.setTextFontName(fontName)
            saveCurrentTypingFontSelection()
            overlayController.requestRedraw()
        case .setTextFontSize(let fontSize):
            annotationController.setTextFontSize(fontSize)
            saveCurrentTypingFontSize()
            overlayController.requestRedraw()
        case .setTextAlignment(let alignment):
            annotationController.setTextAlignment(alignment)
            overlayController.requestRedraw()
        case .increasePenWidth:
            annotationController.setStrokeWidth(annotationController.currentStyle.rootWidth + 1)
            overlayController.requestRedraw()
            shouldRememberDrawingStyle = true
        case .decreasePenWidth:
            annotationController.setStrokeWidth(annotationController.currentStyle.rootWidth - 1)
            overlayController.requestRedraw()
            shouldRememberDrawingStyle = true
        case .selectAllAnnotations:
            annotationController.selectAll()
            overlayController.requestRedraw()
        case .duplicateSelection(let destinationOffset):
            annotationController.duplicateSelection(
                offset: overlayController.annotationContentOffset(
                    forDestinationOffset: destinationOffset
                )
            )
            overlayController.requestRedraw()
        case .deleteSelection:
            annotationController.deleteSelection()
            overlayController.requestRedraw()
        case .arrangeSelection(let action):
            annotationController.arrangeSelection(action)
            overlayController.requestRedraw()
        case .groupSelection:
            annotationController.groupSelection()
            overlayController.requestRedraw()
        case .ungroupSelection:
            annotationController.ungroupSelection()
            overlayController.requestRedraw()
        case .toggleSelectionLock:
            annotationController.toggleSelectionLock()
            overlayController.requestRedraw()
        case .toggleLinearPointEditing:
            _ = annotationController.toggleLinearPointEditing()
            overlayController.requestRedraw()
        case .insertLinearPoint:
            annotationController.insertLinearPoint()
            overlayController.requestRedraw()
        case .removeLinearPoints:
            annotationController.removeLinearPoints()
            overlayController.requestRedraw()
        case .setLinearRoute(let route):
            annotationController.setLinearRoute(route)
            overlayController.requestRedraw()
            shouldRememberDrawingStyle = true
        case .setLinearArrowheads(let start, let end):
            annotationController.setLinearArrowheads(start: start, end: end)
            overlayController.requestRedraw()
            shouldRememberDrawingStyle = true
        case .setLinearStartArrowhead(let arrowhead):
            annotationController.setLinearStartArrowhead(arrowhead)
            overlayController.requestRedraw()
            shouldRememberDrawingStyle = true
        case .setLinearEndArrowhead(let arrowhead):
            annotationController.setLinearEndArrowhead(arrowhead)
            overlayController.requestRedraw()
            shouldRememberDrawingStyle = true
        case .setLinearArrowheadSize(let size):
            annotationController.setLinearArrowheadSize(size)
            overlayController.requestRedraw()
            shouldRememberDrawingStyle = true
        case .unbindLinearEndpoints:
            annotationController.unbindLinearEndpoints()
            overlayController.requestRedraw()
        case .finishLinearPath:
            _ = annotationController.finishLinearConstruction(commitPreview: true)
            overlayController.requestRedraw()
        case .cancelLinearPath:
            annotationController.cancelLinearConstruction()
            overlayController.requestRedraw()
        case .toggleTyping(let rightAligned, let explicitInsertionPoint):
            if mode == .typing {
                finishTypingIfNeeded()
            } else {
                let insertionPoint = explicitInsertionPoint
                    ?? overlayController.typingInsertionPointForCurrentPointer()
                if let insertionPoint {
                    annotationController.setInsertionPoint(insertionPoint)
                }
                modeBeforeTyping = mode
                annotationController.beginTypingSession(
                    rightAligned: rightAligned
                )
                mode = .typing
                overlayController.updateInteractionMode(mode)
            }
            overlayController.requestRedraw()
        case .editText(let elementID):
            guard mode != .typing else { break }
            let targetElementID = elementID
            let previousMode = mode
            let previousModeBeforeTyping = modeBeforeTyping
            modeBeforeTyping = previousMode
            mode = .typing
            overlayController.updateInteractionMode(mode)
            guard annotationController.beginEditingText(
                elementID: targetElementID
            ) else {
                modeBeforeTyping = previousModeBeforeTyping
                mode = previousMode
                overlayController.updateInteractionMode(mode)
                break
            }
            overlayController.requestRedraw()
        case .increaseFontSize:
            annotationController.increaseFontSize()
            saveCurrentTypingFontSize()
            overlayController.requestRedraw()
        case .decreaseFontSize:
            annotationController.decreaseFontSize()
            saveCurrentTypingFontSize()
            overlayController.requestRedraw()
        }

        if shouldRememberDrawingStyle
            && !annotationController.hasActiveContinuousStyleEdit {
            rememberCurrentDrawingStyleIfNeeded()
        }
    }

    private func finishTypingIfNeeded() {
        guard mode == .typing else { return }
        mode = modeBeforeTyping
        overlayController.updateInteractionMode(mode)
        annotationController.finishTypingSession()
    }

    static func applyDrawingToolSelection(
        _ tool: AnnotationTool,
        annotationController: AnnotationController,
        finishTypingIfNeeded: () -> Void
    ) {
        finishTypingIfNeeded()
        annotationController.currentTool = tool
    }

    private func saveCurrentTypingFontSize() {
        var settings = settingsStore.load()
        settings.typingFontSize = annotationController.typingFontSize
        settingsStore.save(settings)
    }

    private func saveCurrentTypingFontPreset() {
        var settings = settingsStore.load()
        settings.typingFontPreset = annotationController.typingFontPreset
        settingsStore.save(settings)
    }

    private func saveCurrentTypingFontSelection() {
        var settings = settingsStore.load()
        settings.typingFontName = annotationController.typingFontName
        settings.typingFontPreset = annotationController.typingFontPreset
        settingsStore.save(settings)
    }

    private func configureAnnotationDefaults(from settings: AppSettings) {
        let useRememberedStyle = settings.rememberLastDrawingStyle
            && settings.lastDrawingDefaults != nil
        let drawingDefaults = useRememberedStyle
            ? settings.lastDrawingDefaults ?? settings.defaultDrawingDefaults
            : settings.defaultDrawingDefaults
        let penWidth = drawingDefaults.penStrokeWidth
            ?? settings.rootPenWidth
        let highlighterWidth = drawingDefaults.highlighterStrokeWidth
            ?? settings.highlighterWidth
        let geometryWidth = drawingDefaults.geometryStrokeWidth
            ?? AnnotationStrokeWidthDefaults.geometry

        annotationController.applyDrawingDefaults(
            drawingDefaults,
            strokeWidth: penWidth,
            highlighterWidth: highlighterWidth,
            geometryWidth: geometryWidth
        )
        annotationController.typingFontName = settings.typingFontName
        annotationController.setTextFontPreset(settings.typingFontPreset)
        annotationController.typingFontSize = settings.typingFontSize
    }

    private func rememberCurrentDrawingStyleIfNeeded() {
        var settings = settingsStore.load()
        guard settings.rememberLastDrawingStyle else { return }
        settings.lastDrawingDefaults = DrawingDefaults(
            tool: annotationController.currentTool,
            style: annotationController.drawingDefaultsStyle,
            smartDrawEnabled: annotationController.smartDrawEnabled,
            linearRoute: annotationController.currentLinearRoute,
            startArrowhead: annotationController.currentStartArrowhead,
            endArrowhead: annotationController.currentEndArrowhead,
            lineRoute: annotationController.currentLineRoute,
            arrowRoute: annotationController.currentArrowRoute,
            arrowheadSize: annotationController.currentArrowheadSize,
            smartDrawSavedPressureMode:
                annotationController.drawingDefaultsSmartDrawSavedPressureMode,
            regularStrokeColor: annotationController.drawingDefaultsRegularStrokeColor,
            highlighterStrokeColor: annotationController
                .drawingDefaultsHighlighterStrokeColor,
            penStrokeWidth: annotationController.drawingDefaultsPenStrokeWidth,
            highlighterStrokeWidth: annotationController
                .drawingDefaultsHighlighterStrokeWidth,
            geometryStrokeWidth: annotationController
                .drawingDefaultsGeometryStrokeWidth,
            penOpacity: annotationController.drawingDefaultsPenOpacity,
            geometryOpacity: annotationController
                .drawingDefaultsGeometryOpacity,
            highlighterOpacity: annotationController
                .drawingDefaultsHighlighterOpacity,
            freehandSloppiness: annotationController
                .drawingDefaultsFreehandSloppiness,
            outlinedSloppiness: annotationController
                .drawingDefaultsOutlinedSloppiness
        )
        settingsStore.save(settings)
    }

    private func persistSmartDrawEnabled(_ isEnabled: Bool) {
        var settings = settingsStore.load()
        settings.defaultDrawingDefaults.smartDrawEnabled = isEnabled
        settings.defaultDrawingDefaults.pressureMode =
            annotationController.drawingDefaultsStyle.pressureMode
        settings.defaultDrawingDefaults.smartDrawSavedPressureMode =
            annotationController.drawingDefaultsSmartDrawSavedPressureMode
        settings.defaultDrawingDefaults.normalizeSmartDrawPressure()
        if settings.rememberLastDrawingStyle,
           var lastDrawingDefaults = settings.lastDrawingDefaults {
            lastDrawingDefaults.smartDrawEnabled = isEnabled
            lastDrawingDefaults.pressureMode =
                annotationController.drawingDefaultsStyle.pressureMode
            lastDrawingDefaults.smartDrawSavedPressureMode =
                annotationController.drawingDefaultsSmartDrawSavedPressureMode
            lastDrawingDefaults.normalizeSmartDrawPressure()
            settings.lastDrawingDefaults = lastDrawingDefaults
        }
        settingsStore.save(settings)
    }

    private func saveDrawingToolbarPlacement(_ position: CGPoint) {
        var settings = settingsStore.load()
        settings.drawingToolbarNormalizedPosition = position
        settingsStore.save(settings)
    }

    private func activateStaticZoom() {
        guard mode == .idle else {
            animateExit()
            return
        }

        guard ScreenRecordingPrompt.ensureGranted(permissionService) else {
            return
        }

        guard let display = displayManager.activeDisplay() else {
            NSSound.beep()
            return
        }

        guard let activation = activationCoordinator.reserve(
            .staticZoom,
            expecting: .idle,
            currentMode: mode
        ) else {
            return
        }

        Task { @MainActor in
            do {
                let frame = try await captureDisplayForOverlay(display)
                guard activationCoordinator.owns(
                    activation,
                    currentMode: mode
                ) else {
                    _ = activationCoordinator.finish(activation)
                    return
                }

                let settings = settingsStore.load()
                viewportController.configure(for: frame, initialZoom: settings.defaultZoomFactor)
                annotationController.reset()
                // Apply persisted drawing/typing defaults from the settings dialog.
                configureAnnotationDefaults(from: settings)
                if settings.animateZoom {
                    // Start fully zoomed out so the overlay telescopes in to the
                    // target zoom, matching Windows ZoomIt.
                    viewportController.beginZoomInAnimation()
                }
                guard activationCoordinator.owns(
                    activation,
                    currentMode: mode
                ) else {
                    _ = activationCoordinator.finish(activation)
                    return
                }
                overlayController.show(
                    frame: frame,
                    viewportController: viewportController,
                    annotationController: annotationController,
                    smoothImage: settings.smoothImage,
                    drawingToolbarNormalizedPosition: settings.drawingToolbarNormalizedPosition,
                    drawingToolbarPlacementDidChange: { [weak self] position in
                        self?.saveDrawingToolbarPlacement(position)
                    },
                    commandSink: { [weak self] command in self?.handle(command) }
                )
                mode = .staticZoom
                _ = activationCoordinator.finish(activation)
                if settings.animateZoom {
                    overlayController.runZoomAnimation()
                }
            } catch {
                guard activationCoordinator.finish(activation) != nil else {
                    return
                }
                presentError(error)
            }
        }
    }

    private func activateLiveZoom() {
        guard mode == .idle else {
            animateExit()
            return
        }

        guard ScreenRecordingPrompt.ensureGranted(permissionService) else {
            return
        }

        guard let display = displayManager.activeDisplay() else {
            NSSound.beep()
            return
        }

        guard let activation = activationCoordinator.reserve(
            .liveZoom,
            expecting: .idle,
            currentMode: mode
        ), liveZoomActivation.begin(activation) else {
            return
        }
        Task { @MainActor [weak self] in
            await self?.runLiveZoomActivation(
                display: display,
                activation: activation
            )
        }
    }

    private func runLiveZoomActivation(
        display: DisplayDescriptor,
        activation: ModeActivationCoordinator.Token
    ) async {
        var localSession: LiveCaptureSession?

        do {
            // Capture one still frame for the initial display, then let the
            // live stream keep refreshing the magnified content.
            let frame = try await captureDisplayForOverlay(display)
            guard activationCoordinator.owns(
                activation,
                currentMode: mode
            ), liveZoomActivation.isCurrent(activation) else {
                _ = activationCoordinator.finish(activation)
                _ = liveZoomActivation.finish(activation)
                return
            }

            let settings = settingsStore.load()
            viewportController.configure(
                for: frame,
                initialZoom: settings.defaultZoomFactor
            )
            annotationController.reset()
            configureAnnotationDefaults(from: settings)
            if settings.animateZoom {
                viewportController.beginZoomInAnimation()
            }
            guard activationCoordinator.updateExpectedMode(
                for: activation,
                currentMode: mode,
                to: .liveZoom
            ), liveZoomActivation.isCurrent(activation) else {
                _ = activationCoordinator.finish(activation)
                _ = liveZoomActivation.finish(activation)
                return
            }
            overlayController.show(
                frame: frame,
                viewportController: viewportController,
                annotationController: annotationController,
                smoothImage: settings.smoothImage,
                excludeFromScreenCapture: true,
                drawingToolbarNormalizedPosition: settings.drawingToolbarNormalizedPosition,
                drawingToolbarPlacementDidChange: { [weak self] position in
                    self?.saveDrawingToolbarPlacement(position)
                },
                commandSink: { [weak self] command in self?.handle(command) }
            )
            mode = .liveZoom
            overlayController.updateInteractionMode(.liveZoom)
            guard liveZoomActivation.markOverlayPresented(for: activation) else {
                _ = activationCoordinator.finish(activation)
                _ = liveZoomActivation.finish(activation)
                overlayController.close()
                annotationController.reset()
                mode = .idle
                isExiting = false
                return
            }

            // Keep the stream local until this generation is registered. A
            // stale completion can then stop only its own stream.
            let session = LiveCaptureSession { [weak self] image in
                guard let self,
                      self.liveZoomActivation.isCurrent(activation),
                      self.mode == .liveZoom || self.isExiting else {
                    return
                }
                self.overlayController.updateLiveImage(image)
            }
            localSession = session
            guard liveZoomActivation.attach(session, to: activation) else {
                await session.stop()
                let ownedActivation = activationCoordinator.finish(activation) != nil
                if ownedActivation,
                   let cleanup = liveZoomActivation.finish(activation) {
                    dismissFailedLiveZoomActivation(cleanup)
                }
                return
            }

            try await session.start(display: display)

            guard activationCoordinator.owns(
                activation,
                currentMode: mode
            ) else {
                if let cleanup = liveZoomActivation.finish(activation),
                   let ownedSession = cleanup.session {
                    await ownedSession.stop()
                    dismissFailedLiveZoomActivation(cleanup)
                }
                return
            }
            guard liveZoomActivation.commit(session, for: activation) else {
                _ = activationCoordinator.finish(activation)
                await session.stop()
                return
            }
            _ = activationCoordinator.finish(activation)

            // Enable Control+Up/Down zoom while live zoom is on screen.
            onBeginLiveZoomNavigation?()

            if settings.animateZoom {
                overlayController.runZoomAnimation()
            }
        } catch {
            let ownedActivation = activationCoordinator.finish(activation) != nil
            let cleanup = liveZoomActivation.finish(activation)
            if let cleanup {
                if let session = cleanup.session ?? localSession {
                    await session.stop()
                }
                if ownedActivation {
                    dismissFailedLiveZoomActivation(cleanup)
                    presentError(error)
                }
            }
        }
    }

    private func cancelLiveZoomStartup(
        activation: ModeActivationCoordinator.Token
    ) {
        guard let cancellation = liveZoomActivation.finish(activation) else {
            return
        }
        if let session = cancellation.session {
            Task { await session.stop() }
        }
        if cancellation.overlayPresented {
            overlayController.close()
            annotationController.reset()
            mode = .idle
            isExiting = false
        }
    }

    private func dismissFailedLiveZoomActivation(
        _ cancellation: LiveZoomActivationResources<
            ModeActivationCoordinator.Token,
            LiveCaptureSession
        >.Cancellation
    ) {
        if cancellation.wasActive {
            onEndLiveZoomNavigation?()
        }
        guard cancellation.overlayPresented else { return }
        overlayController.close()
        annotationController.reset()
        mode = .idle
        isExiting = false
    }

    /// While live zoomed, the draw/zoom hotkeys toggle drawing on the live view
    /// without changing magnification or exiting. Annotations live in stable
    /// screen-content coordinates, so the live image keeps updating beneath them.
    private func toggleLiveZoomDrawing() {
        guard mode == .liveZoom else { return }
        overlayController.toggleDrawingMode()
    }

    private func activateDrawWithoutZoom() {
        guard mode == .idle else {
            animateExit()
            return
        }

        guard ScreenRecordingPrompt.ensureGranted(permissionService) else {
            return
        }

        guard let display = displayManager.activeDisplay() else {
            NSSound.beep()
            return
        }

        guard let activation = activationCoordinator.reserve(
            .drawOnly,
            expecting: .idle,
            currentMode: mode
        ) else {
            return
        }

        Task { @MainActor in
            do {
                let frame = try await captureDisplayForOverlay(display)
                guard activationCoordinator.owns(
                    activation,
                    currentMode: mode
                ) else {
                    _ = activationCoordinator.finish(activation)
                    return
                }

                let settings = settingsStore.load()
                // Draw-without-zoom freezes the screen at 1x and goes straight
                // into drawing mode; there is no magnification or animation.
                viewportController.configure(for: frame, initialZoom: 1)
                annotationController.reset()
                configureAnnotationDefaults(from: settings)
                guard activationCoordinator.owns(
                    activation,
                    currentMode: mode
                ) else {
                    _ = activationCoordinator.finish(activation)
                    return
                }
                overlayController.show(
                    frame: frame,
                    viewportController: viewportController,
                    annotationController: annotationController,
                    smoothImage: settings.smoothImage,
                    drawingToolbarNormalizedPosition: settings.drawingToolbarNormalizedPosition,
                    drawingToolbarPlacementDidChange: { [weak self] position in
                        self?.saveDrawingToolbarPlacement(position)
                    },
                    commandSink: { [weak self] command in self?.handle(command) }
                )
                mode = .drawOnly
                _ = activationCoordinator.finish(activation)
                // Arm drawing mode immediately so the first click starts a stroke.
                overlayController.updateInteractionMode(.drawOnly)
            } catch {
                guard activationCoordinator.finish(activation) != nil else {
                    return
                }
                presentError(error)
            }
        }
    }

    /// At the zoom-out floor (1x), decides whether the overlay should exit.
    /// Matches Windows ZoomIt: static zoom stays active at 1x, while live zoom
    /// (and its typing sub-mode) still exits when zoomed all the way out.
    static func exitsOnZoomOutFloor(mode: AppMode) -> Bool {
        mode != .staticZoom
    }

    private func zoomIn() {
        guard mode == .staticZoom || mode == .liveZoom || mode == .typing, !isExiting else { return }
        let settings = settingsStore.load()
        let current = viewportController.targetZoomFactor
        guard current < settings.maximumZoomFactor else { return }

        // ZoomIt's mouse-wheel zoom-in steps: snap to 2x, then keep doubling.
        let target = current < 2 ? 2 : min(settings.maximumZoomFactor, current * 2)
        applyZoom(to: target, animate: settings.animateZoom)
    }

    private func zoomOutOrExit() {
        guard mode == .staticZoom || mode == .liveZoom || mode == .typing, !isExiting else { return }
        let settings = settingsStore.load()
        let current = viewportController.targetZoomFactor
        // At 1x there is nothing left to zoom out of.
        guard current > settings.minimumZoomFactor else {
            // Static zoom matches Windows ZoomIt: it stays active at 1x instead
            // of exiting when the user zooms all the way out. Only Esc (or right
            // click) exits static zoom. Live zoom still exits at 1x.
            if Self.exitsOnZoomOutFloor(mode: mode) {
                animateExit()
            }
            return
        }

        // ZoomIt's zoom-out steps: halve while above 2x, then ease out by 0.75
        // down to the 1x minimum.
        let target = current <= 2
            ? max(settings.minimumZoomFactor, current * 0.75)
            : current / 2
        applyZoom(to: target, animate: settings.animateZoom)
    }

    private func applyZoom(to target: CGFloat, animate: Bool) {
        if animate {
            viewportController.animateZoom(to: target)
            overlayController.runZoomAnimation()
        } else {
            viewportController.setZoomFactor(target)
            overlayController.requestRedraw()
        }
    }

    private func captureDisplayForOverlay(_ display: DisplayDescriptor) async throws -> CapturedFrame {
        let excludedWindowNumbers = recordingController.webcamWindowNumberForScreenCaptureExclusion.map { [$0] } ?? []
        return try await captureService.captureDisplay(display, excludingWindowNumbers: excludedWindowNumbers)
    }

    private func animateExit() {
        guard mode != .idle, !isExiting else { return }
        isExiting = true
        // Telescope back out to 1x before tearing down the overlay.
        viewportController.animateZoom(to: 1)
        overlayController.runZoomAnimation { [weak self] in
            self?.exitActiveMode()
        }
    }

    private func exitActiveMode() {
        if mode == .breakTimer {
            stopBreakTimer()
            return
        }
        stopLiveCapture()
        overlayController.close()
        annotationController.reset()
        mode = .idle
        isExiting = false
    }

    /// Starts a region snip. From idle it captures the screen; while zoomed it
    /// selects within the current viewport so ZoomIt's own overlay is reused
    /// rather than captured.
    private func startSnip(action: SnipAction) {
        switch mode {
        case .idle, .staticZoom, .liveZoom, .drawOnly, .typing:
            break
        default:
            NSSound.beep()
            return
        }

        let expectedMode = mode
        guard let activation = activationCoordinator.reserve(
            .snip,
            expecting: expectedMode,
            currentMode: mode
        ) else {
            NSSound.beep()
            return
        }

        let finish: () -> Void = { [weak self] in
            _ = self?.activationCoordinator.finish(activation)
        }

        switch mode {
        case .idle:
            snipController.begin(
                action: action,
                shouldPresent: { [weak self] in
                    guard let self else { return false }
                    return self.activationCoordinator.owns(
                        activation,
                        currentMode: self.mode
                    )
                },
                onFinished: finish
            )
        case .staticZoom, .liveZoom, .drawOnly, .typing:
            guard activationCoordinator.owns(
                activation,
                currentMode: mode
            ) else {
                _ = activationCoordinator.finish(activation)
                return
            }
            overlayController.beginRegionSnip(
                action: action,
                onFinished: finish
            )
        default:
            _ = activationCoordinator.finish(activation)
        }
    }

    /// Opens an existing video in the clip editor (trim/append/save) without
    /// recording, mirroring ZoomIt's standalone Trim workflow.
    func openTrimEditor() {
        guard activationCoordinator.currentKind == nil else {
            NSSound.beep()
            return
        }
        recordingController.openForTrim()
    }

    /// Starts/stops screen recording. Recording runs independently of the zoom
    /// overlay so the user can zoom and draw (and have those captured) while a
    /// recording is in progress.
    private func toggleRecording(region: Bool) {
        var activation: ModeActivationCoordinator.Token?
        var accessorySuppression: ExternalRegionSelectorSuppression?
        if region && !recordingIsActive {
            guard recordingController.canStartRecording else {
                NSSound.beep()
                return
            }
            guard let reserved = activationCoordinator.reserve(
                .recordingRegion,
                expecting: mode,
                currentMode: mode
            ) else {
                return
            }
            activation = reserved
            accessorySuppression = beginExternalRegionSelectorSuppression(
                flow: .recording
            )
        }

        // Make sure the Save dialog (shown after stopping) isn't hidden behind a
        // zoom overlay by dismissing any active overlay first.
        recordingController.overlayFrameProvider = {
            [weak self] displayID, sourceRect, outputPixelSize in
            self?.overlayController.captureFrameForRecording(
                displayID: displayID,
                sourceRect: sourceRect,
                outputPixelSize: outputPixelSize
            )
        }
        recordingController.onWillShowSaveDialog = { [weak self] in
            guard let self else { return }
            switch self.activationCoordinator.currentKind {
            case .staticZoom, .liveZoom, .drawOnly, .breakTimer:
                self.cancelCurrentActivation()
            case .snip, .panorama, .demoMirror, .recordingRegion, nil:
                break
            }
            self.overlayController.prepareForPresentedWindow()
            self.exitActiveMode()
        }
        recordingController.toggle(
            region: region,
            shouldPresentRegionSelection: { [weak self] in
                guard let self, let activation else {
                    return !region
                }
                return self.activationCoordinator.owns(
                    activation,
                    currentMode: self.mode
                )
            },
            onRegionSelectionFinished: { [weak self] in
                if let accessorySuppression {
                    self?.finishExternalRegionSelectorSuppression(
                        accessorySuppression
                    )
                }
                guard let activation else { return }
                _ = self?.activationCoordinator.finish(activation)
            }
        ) { [weak self] recording in
            self?.recordingIsActive = recording
            self?.onRecordingStateChanged?(recording)
        }
    }

    /// Starts/stops panorama (scrolling) capture. Like recording, it runs
    /// independently of the zoom overlay so the Save dialog isn't hidden behind
    /// an active overlay.
    private func togglePanorama(save: Bool) {
        if activationCoordinator.currentKind == .panorama {
            panoramaController.requestStop()
            return
        }

        guard let activation = activationCoordinator.reserve(
            .panorama,
            expecting: mode,
            currentMode: mode
        ) else {
            return
        }
        let accessorySuppression = beginExternalRegionSelectorSuppression(
            flow: .panorama
        )

        panoramaController.onWillShowSaveDialog = { [weak self] in
            guard let self, self.mode != .idle else { return }
            self.exitActiveMode()
        }
        panoramaController.begin(
            save: save,
            activationIsCurrent: { [weak self] in
                guard let self else { return false }
                return self.activationCoordinator.owns(
                    activation,
                    currentMode: self.mode
                )
            },
            onRegionSelectionFinished: { [weak self] in
                self?.finishExternalRegionSelectorSuppression(
                    accessorySuppression
                )
            },
            onStateChange: { _ in },
            onFinished: { [weak self] in
                self?.finishExternalRegionSelectorSuppression(
                    accessorySuppression
                )
                _ = self?.activationCoordinator.finish(activation)
            }
        )
    }

    private func toggleDemoMirror(scope: DemoMirrorScope) {
        if activationCoordinator.currentKind == .demoMirror {
            demoMirrorController.stop()
            return
        }
        if demoMirrorController.isActive {
            demoMirrorController.stop()
            return
        }

        guard let activation = activationCoordinator.reserve(
            .demoMirror,
            expecting: mode,
            currentMode: mode
        ) else {
            return
        }
        let accessorySuppression = scope == .region
            ? beginExternalRegionSelectorSuppression(flow: .demoMirror)
            : nil
        demoMirrorController.toggle(
            scope: scope,
            activationIsCurrent: { [weak self] in
                guard let self else { return false }
                return self.activationCoordinator.owns(
                    activation,
                    currentMode: self.mode
                )
            },
            onRegionSelectionFinished: { [weak self] in
                guard let accessorySuppression else { return }
                self?.finishExternalRegionSelectorSuppression(
                    accessorySuppression
                )
            },
            onActivationFinished: { [weak self] in
                if let accessorySuppression {
                    self?.finishExternalRegionSelectorSuppression(
                        accessorySuppression
                    )
                }
                _ = self?.activationCoordinator.finish(activation)
            }
        )
    }

    private func toggleBreakTimer() {
        if mode == .breakTimer {
            stopBreakTimer()
            return
        }

        guard mode == .idle else {
            animateExit()
            return
        }

        guard let activation = activationCoordinator.reserve(
            .breakTimer,
            expecting: .idle,
            currentMode: mode
        ) else {
            return
        }

        let settings = settingsStore.load()
        Task { @MainActor in
            do {
                let presented = try await breakTimerController.begin(
                    settings: settings,
                    shouldPresent: { [weak self] in
                        guard let self else { return false }
                        return self.activationCoordinator.owns(
                            activation,
                            currentMode: self.mode
                        )
                    }
                ) { [weak self] in
                    guard let self, self.mode == .breakTimer else { return }
                    self.mode = .idle
                }
                guard presented,
                      activationCoordinator.owns(
                          activation,
                          currentMode: mode
                      ) else {
                    if presented {
                        breakTimerController.close()
                    }
                    _ = activationCoordinator.finish(activation)
                    return
                }
                mode = .breakTimer
                _ = activationCoordinator.finish(activation)
            } catch {
                guard activationCoordinator.finish(activation) != nil else {
                    return
                }
                presentError(error)
            }
        }
    }

    private func stopBreakTimer() {
        breakTimerController.close()
        mode = .idle
        isExiting = false
    }

    private func cancelCurrentActivation() {
        guard let activation = activationCoordinator.cancelCurrent() else {
            return
        }
        switch activation.kind {
        case .liveZoom:
            cancelLiveZoomStartup(activation: activation)
        case .breakTimer:
            breakTimerController.close()
        case .staticZoom, .drawOnly:
            break
        case .snip, .panorama, .demoMirror, .recordingRegion:
            break
        }
    }

    private func beginExternalRegionSelectorSuppression(
        flow: ExternalRegionSelectorFlow
    ) -> ExternalRegionSelectorSuppression {
        ExternalRegionSelectorSuppression(
            flow: flow,
            expectedMode: mode,
            token: overlayController.suppressDrawingAccessories()
        )
    }

    private func finishExternalRegionSelectorSuppression(
        _ suppression: ExternalRegionSelectorSuppression
    ) {
        let shouldRestore = ExternalRegionSelectorAccessoryPolicy.shouldRestore(
            flow: suppression.flow,
            expectedMode: suppression.expectedMode,
            currentMode: mode,
            isOverlayPresented: overlayController.isOverlayPresented
        )
        overlayController.finishDrawingAccessorySuppression(
            suppression.token,
            restoreIfOverlayActive: shouldRestore
        )
    }

    /// Tears down the live capture stream, if any, when leaving live zoom.
    private func stopLiveCapture() {
        guard let cancellation = liveZoomActivation.cancel() else { return }
        if cancellation.wasActive {
            onEndLiveZoomNavigation?()
        }
        if let session = cancellation.session {
            Task { await session.stop() }
        }
    }

    private func presentError(_ error: Error) {
        let alert = NSAlert(error: error)
        alert.runModal()
    }
}