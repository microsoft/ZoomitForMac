import AppKit

private final class DrawingAccessoryPanel: NSPanel {
    var eventActivityChanged: ((NSEvent.EventType) -> Void)?
    var controlTrackingChanged: ((Bool) -> Void)?

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    override func sendEvent(_ event: NSEvent) {
        let bracketsControlTracking =
            DrawingAccessoryEventDispatch.bracketsControlTracking(event.type)
        if bracketsControlTracking {
            controlTrackingChanged?(true)
        }
        defer {
            if bracketsControlTracking {
                controlTrackingChanged?(false)
            }
        }
        eventActivityChanged?(event.type)
        super.sendEvent(event)
    }
}

@MainActor
final class DrawingToolbarController: NSObject {
    private weak var parentWindow: NSWindow?
    private let annotationController: AnnotationController
    private let commandSink: (AppCommand) -> Void
    private let restoreCanvasFocus: () -> Void
    private let toolbarPlacementDidChange: (CGPoint) -> Void
    private let pointerInteractionChanged: (DrawingAccessoryInteractionState) -> Void
    private let toolbarPanel: DrawingAccessoryPanel
    private let inspectorPanel: DrawingAccessoryPanel
    private var toolbarView: DrawingToolbarView!
    private var inspectorView: DrawingInspectorView!
    private var propertiesController: DrawingPropertiesController!
    private var currentState: DrawingToolbarState
    private var lastAppliedState: DrawingToolbarState?
    private var transientTool: AnnotationTool?
    private var toolbarNormalizedPosition: CGPoint?
    private var interactionState = DrawingAccessoryInteractionState()
    private var isPanelVisible = false
    private var isInspectorOrderedVisible = false
    private var attachedInspectorAlignment: DrawingAttachedInspectorPlacement.Alignment?
    private var scrollTimer: Timer?
    private var screenParametersObserver: NSObjectProtocol?
    private var menuBeginObserver: NSObjectProtocol?
    private var menuEndObserver: NSObjectProtocol?

    var windowNumbers: [Int] {
        [toolbarPanel.windowNumber, inspectorPanel.windowNumber]
    }

    var toolbarFrameForTesting: CGRect {
        toolbarPanel.frame
    }

    var inspectorFrameForTesting: CGRect {
        inspectorPanel.frame
    }

    var propertiesViewIdentifierForTesting: ObjectIdentifier {
        ObjectIdentifier(propertiesController.view)
    }

    var inspectorWindowForTesting: NSWindow {
        inspectorPanel
    }

    var toolbarWindowForTesting: NSWindow {
        toolbarPanel
    }

    var toolbarButtonFramesForTesting: [String: CGRect] {
        toolbarView.buttonFramesForTesting
    }

    var toolbarPrimaryItemOrderForTesting: [String] {
        toolbarView.primaryItemOrderForTesting
    }

    var toolbarPrimaryButtonVisualsForTesting:
        [String: DrawingToolbarButtonVisualSnapshot] {
        toolbarView.primaryButtonVisualsForTesting
    }

    var toolbarIsVisibleForTesting: Bool {
        toolbarPanel.isVisible
    }

    var inspectorIsVisibleForTesting: Bool {
        isInspectorOrderedVisible && inspectorPanel.isVisible
    }

    var colorPickerStateForTesting: DrawingColorPickerCoordinatorState {
        propertiesController.colorPickerStateForTesting
    }

    var colorPickerCoordinatorIdentifierForTesting: ObjectIdentifier {
        propertiesController.colorPickerCoordinatorIdentifierForTesting
    }

    var startArrowheadPickerForTesting: DrawingInspectorArrowheadPicker {
        propertiesController.startArrowheadPickerForTesting
    }

    var endArrowheadPickerForTesting: DrawingInspectorArrowheadPicker {
        propertiesController.endArrowheadPickerForTesting
    }

    var propertiesContentSizeForTesting: CGSize {
        propertiesController.preferredContentSize
    }

    var inspectorHasChromeForTesting: Bool {
        inspectorView.hasChromeForTesting
    }

    var inspectorHasHorizontalScrollerForTesting: Bool {
        inspectorView.hasHorizontalScrollerForTesting
    }

    var inspectorDocumentSizeForTesting: CGSize {
        inspectorView.documentSizeForTesting
    }

    var inspectorViewportSizeForTesting: CGSize {
        inspectorView.viewportSizeForTesting
    }

    var propertiesFittingHeightForTesting: CGFloat {
        ceil(propertiesController.view.fittingSize.height)
    }

    func captureAccessorySnapshots(
        scaleX: CGFloat,
        scaleY: CGFloat
    ) -> [CaptureAccessorySnapshot] {
        guard isPanelVisible,
              toolbarPanel.isVisible,
              toolbarPanel.frame.width > 0,
              toolbarPanel.frame.height > 0,
              let toolbarContentView = toolbarPanel.contentView else {
            return []
        }

        var snapshots: [CaptureAccessorySnapshot] = []
        if let toolbarSnapshot = CaptureAccessorySnapshotRenderer.snapshot(
            view: toolbarContentView,
            globalFrame: toolbarPanel.frame,
            scaleX: scaleX,
            scaleY: scaleY
        ) {
            snapshots.append(toolbarSnapshot)
        }

        if currentState.hasInspectorContent,
           isInspectorOrderedVisible,
           inspectorPanel.isVisible,
           inspectorPanel.frame.width > 0,
           inspectorPanel.frame.height > 0,
           let inspectorContentView = inspectorPanel.contentView,
           let inspectorSnapshot = CaptureAccessorySnapshotRenderer.snapshot(
               view: inspectorContentView,
               globalFrame: inspectorPanel.frame,
               scaleX: scaleX,
               scaleY: scaleY,
               shadow: .inspector
           ) {
            snapshots.append(inspectorSnapshot)
        }
        return snapshots
    }

    func applyDragSampleForTesting(
        proposedOrigin: CGPoint,
        visibleFrame: CGRect
    ) {
        applyDragSample(
            proposedOrigin: proposedOrigin,
            visibleFrame: visibleFrame
        )
    }

    func persistCurrentToolbarPositionForTesting(visibleFrame: CGRect) {
        persistToolbarPosition(
            origin: toolbarPanel.frame.origin,
            visibleFrame: visibleFrame
        )
    }

    init(
        parentWindow: NSWindow,
        annotationController: AnnotationController,
        toolbarNormalizedPosition: CGPoint?,
        commandSink: @escaping (AppCommand) -> Void,
        restoreCanvasFocus: @escaping () -> Void,
        toolbarPlacementDidChange: @escaping (CGPoint) -> Void,
        pointerInteractionChanged: @escaping (DrawingAccessoryInteractionState) -> Void
    ) {
        self.parentWindow = parentWindow
        self.annotationController = annotationController
        self.toolbarNormalizedPosition = toolbarNormalizedPosition
        self.commandSink = commandSink
        self.restoreCanvasFocus = restoreCanvasFocus
        self.toolbarPlacementDidChange = toolbarPlacementDidChange
        self.pointerInteractionChanged = pointerInteractionChanged
        currentState = DrawingToolbarState(annotationController: annotationController)

        toolbarPanel = DrawingAccessoryPanel(
            contentRect: .zero,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        inspectorPanel = DrawingAccessoryPanel(
            contentRect: .zero,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        super.init()

        let propertiesController = DrawingPropertiesController(
            commandSink: { [weak self] command in
                self?.send(command)
            },
            colorPanelActivityChanged: { [weak self] isActive in
                guard let self else { return }
                interactionState.colorPanelOpen = isActive
                interactionStateDidChange()
            },
            popoverActivityChanged: { [weak self] isActive in
                guard let self else { return }
                interactionState.popoverOpen = isActive
                interactionStateDidChange()
            }
        )
        self.propertiesController = propertiesController
        _ = propertiesController.view
        propertiesController.setAvailableHorizontalWidth(
            DrawingInspectorVisualMetrics.attachedMaximumWidth
                - DrawingInspectorVisualMetrics.attachedHorizontalChrome
        )

        let toolbarView = DrawingToolbarView(
            commandSink: { [weak self] command in self?.send(command) },
            showOverflow: { [weak self] sender in self?.showOverflow(relativeTo: sender) },
            beginDragging: { [weak self] event in self?.dragToolbar(with: event) }
        )
        self.toolbarView = toolbarView
        toolbarPanel.contentView = toolbarView

        let inspectorView = DrawingInspectorView(propertiesView: propertiesController.view)
        self.inspectorView = inspectorView
        inspectorPanel.contentView = inspectorView

        configure(panel: toolbarPanel, parentWindow: parentWindow, isToolbar: true)
        configure(panel: inspectorPanel, parentWindow: toolbarPanel, isToolbar: false)

        toolbarPanel.eventActivityChanged = { [weak self] eventType in
            self?.handlePanelEvent(eventType)
        }
        inspectorPanel.eventActivityChanged = { [weak self] eventType in
            self?.handlePanelEvent(eventType)
        }
        toolbarPanel.controlTrackingChanged = { [weak self] isTracking in
            self?.setControlTracking(isTracking)
        }
        inspectorPanel.controlTrackingChanged = { [weak self] isTracking in
            self?.setControlTracking(isTracking)
        }
        toolbarView.onPointerPresenceChanged = { [weak self] isInside in
            guard let self else { return }
            interactionState.pointerOverToolbar = isInside
            interactionStateDidChange()
        }
        inspectorView.onPointerPresenceChanged = { [weak self] isInside in
            guard let self else { return }
            interactionState.pointerOverInspector = isInside
            interactionStateDidChange()
        }

        screenParametersObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.screenGeometryDidChange()
            }
        }
        menuBeginObserver = NotificationCenter.default.addObserver(
            forName: NSMenu.didBeginTrackingNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self,
                      self.isPanelVisible,
                      self.interactionState.pointerOverToolbar
                        || self.interactionState.pointerOverInspector
                        || self.interactionState.controlTracking else {
                    return
                }
                self.interactionState.menuOpen = true
                self.interactionStateDidChange()
            }
        }
        menuEndObserver = NotificationCenter.default.addObserver(
            forName: NSMenu.didEndTrackingNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.interactionState.menuOpen else { return }
                self.interactionState.menuOpen = false
                self.interactionStateDidChange()
            }
        }

        updateState(currentState)
    }

    func show() {
        guard !isPanelVisible else { return }
        isPanelVisible = true
        lastAppliedState = nil
        applyToolbarFrame(animated: false)
        toolbarPanel.orderFront(nil)
        updateState(DrawingToolbarState(annotationController: annotationController))
    }

    func hide() {
        guard isPanelVisible else { return }
        isPanelVisible = false
        scrollTimer?.invalidate()
        scrollTimer = nil
        propertiesController.dismissTransientUI()
        interactionState = DrawingAccessoryInteractionState()
        pointerInteractionChanged(interactionState)
        toolbarPanel.orderOut(nil)
        orderInspectorOut()
    }

    func close() {
        hide()
        toolbarPanel.removeChildWindow(inspectorPanel)
        if let parentWindow {
            parentWindow.removeChildWindow(toolbarPanel)
        }
        for observer in [
            screenParametersObserver,
            menuBeginObserver,
            menuEndObserver
        ].compactMap({ $0 }) {
            NotificationCenter.default.removeObserver(observer)
        }
        screenParametersObserver = nil
        menuBeginObserver = nil
        menuEndObserver = nil
        toolbarPanel.close()
        inspectorPanel.close()
    }

    func updateState(_ state: DrawingToolbarState) {
        guard lastAppliedState != state else { return }
        lastAppliedState = state
        currentState = state
        propertiesController.update(state: state)
        updateViews()
        guard isPanelVisible else { return }
        applyToolbarFrame(animated: false, preservingCurrentOrigin: true)
        applyInspectorFrame()
    }

    func setTransientTool(_ tool: AnnotationTool?) {
        transientTool = tool
        updateViews()
    }

    func dismissTransientUI() {
        propertiesController.dismissTransientUI()
    }

    private func configure(
        panel: DrawingAccessoryPanel,
        parentWindow: NSWindow,
        isToolbar: Bool
    ) {
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = !isToolbar
        panel.isMovable = false
        panel.isMovableByWindowBackground = false
        panel.isFloatingPanel = true
        panel.becomesKeyOnlyIfNeeded = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.acceptsMouseMovedEvents = true
        panel.minSize = .zero
        panel.contentMinSize = .zero
        panel.level = NSWindow.Level(rawValue: parentWindow.level.rawValue + 1)
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.sharingType = .readOnly
        parentWindow.addChildWindow(panel, ordered: .above)
    }

    private func updateViews() {
        toolbarView.update(
            state: currentState,
            transientTool: transientTool
        )
        inspectorView.update(
            state: currentState,
            contentSize: propertiesController.preferredContentSize
        )
    }

    private func dragToolbar(with initialEvent: NSEvent) {
        guard initialEvent.type == .leftMouseDown else { return }

        let initialPointerLocation = NSEvent.mouseLocation
        let initialOrigin = toolbarPanel.frame.origin
        let eventMask: NSEvent.EventTypeMask = [.leftMouseDragged, .leftMouseUp]
        var finalPointerLocation = initialPointerLocation
        interactionState.toolbarDragActive = true
        interactionStateDidChange()
        defer {
            interactionState.toolbarDragActive = false
            finishToolbarDragging(at: finalPointerLocation)
            interactionStateDidChange()
        }

        while let event = NSApp.nextEvent(
            matching: eventMask,
            until: .distantFuture,
            inMode: .eventTracking,
            dequeue: true
        ) {
            finalPointerLocation = NSEvent.mouseLocation
            if event.type == .leftMouseUp {
                break
            }

            let proposedOrigin = DrawingToolbarPlacement.draggedOrigin(
                initialOrigin: initialOrigin,
                initialPointerScreenLocation: initialPointerLocation,
                currentPointerScreenLocation: finalPointerLocation
            )
            let activeScreen = screen(containing: finalPointerLocation)
                ?? bestScreen(for: CGRect(origin: proposedOrigin, size: toolbarPanel.frame.size))
            guard let activeScreen else { continue }
            applyDragSample(
                proposedOrigin: proposedOrigin,
                visibleFrame: activeScreen.visibleFrame
            )
            NSCursor.closedHand.set()
        }
    }

    private func applyDragSample(
        proposedOrigin: CGPoint,
        visibleFrame: CGRect
    ) {
        guard let inspectorFrame = presentedInspectorFrame else {
            toolbarPanel.setFrameOrigin(
                DrawingToolbarPlacement.clampedOrigin(
                    proposedOrigin,
                    panelSize: toolbarPanel.frame.size,
                    visibleFrame: visibleFrame
                )
            )
            return
        }

        let inspectorOffset = CGPoint(
            x: inspectorFrame.minX - toolbarPanel.frame.minX,
            y: inspectorFrame.minY - toolbarPanel.frame.minY
        )
        let toolbarOrigin = DrawingAttachedInspectorDragLock
            .clampedToolbarOrigin(
                proposedOrigin,
                toolbarSize: toolbarPanel.frame.size,
                inspectorOffset: inspectorOffset,
                inspectorSize: inspectorFrame.size,
                visibleFrame: visibleFrame
            )
        toolbarPanel.setFrameOrigin(toolbarOrigin)
        inspectorPanel.setFrameOrigin(
            DrawingAttachedInspectorDragLock.inspectorOrigin(
                toolbarOrigin: toolbarOrigin,
                inspectorOffset: inspectorOffset
            )
        )
    }

    private var presentedInspectorFrame: CGRect? {
        guard isInspectorOrderedVisible,
              inspectorPanel.isVisible,
              inspectorPanel.frame.width > 0,
              inspectorPanel.frame.height > 0 else {
            return nil
        }
        return inspectorPanel.frame
    }

    private func finishToolbarDragging(at pointerLocation: CGPoint) {
        guard let activeScreen = screen(containing: pointerLocation)
            ?? bestScreen(for: toolbarPanel.frame) else {
            return
        }
        applyToolbarFrame(
            animated: false,
            preservingCurrentOrigin: true,
            screen: activeScreen
        )
        applyInspectorFrame(screen: activeScreen)
        persistToolbarPosition(
            origin: toolbarPanel.frame.origin,
            visibleFrame: activeScreen.visibleFrame
        )
    }

    private func persistToolbarPosition(origin: CGPoint, visibleFrame: CGRect) {
        toolbarNormalizedPosition = DrawingToolbarPlacement.normalizedPosition(
            origin: origin,
            panelSize: toolbarPanel.frame.size,
            visibleFrame: visibleFrame
        )
        toolbarPlacementDidChange(
            toolbarNormalizedPosition ?? CGPoint(x: 0.5, y: 0.95)
        )
    }

    private func send(_ command: AppCommand) {
        commandSink(command)
        updateState(DrawingToolbarState(annotationController: annotationController))
    }

    private func showOverflow(relativeTo view: NSView) {
        let menu = NSMenu(title: "Drawing Actions")
        menu.autoenablesItems = false
        let actionEnabled = DrawingToolbarOverflowActionAvailability.enabledStates(
            for: currentState
        )

        addMenuItem("Undo", command: .undo, to: menu).isEnabled = currentState.canUndo
        addMenuItem("Redo", command: .redo, to: menu).isEnabled = currentState.canRedo
        menu.addItem(.separator())
        addMenuItem(
            currentState.smartDrawEnabled ? "Disable Smart Draw" : "Enable Smart Draw",
            command: .setSmartDrawEnabled(!currentState.smartDrawEnabled),
            to: menu
        ).isEnabled = currentState.supportsSmartDraw
        addMenuItem("Clear All", command: .clear, to: menu).isEnabled = true
        menu.addItem(.separator())
        addMenuItem("Select All", command: .selectAllAnnotations, to: menu).isEnabled = true
        addMenuItem(
            DrawingToolbarOverflowActionTitle.duplicate,
            command: .duplicateSelection(
                destinationOffset: AppCommand.defaultDuplicateDestinationOffset
            ),
            to: menu
        ).isEnabled = actionEnabled[DrawingToolbarOverflowActionTitle.duplicate] == true
        addMenuItem(
            DrawingToolbarOverflowActionTitle.delete,
            command: .deleteSelection,
            to: menu
        )
            .isEnabled = actionEnabled[DrawingToolbarOverflowActionTitle.delete] == true
        menu.addItem(.separator())
        addMenuItem(
            DrawingToolbarOverflowActionTitle.bringToFront,
            command: .arrangeSelection(.bringToFront),
            to: menu
        )
            .isEnabled = actionEnabled[DrawingToolbarOverflowActionTitle.bringToFront] == true
        addMenuItem(
            DrawingToolbarOverflowActionTitle.bringForward,
            command: .arrangeSelection(.bringForward),
            to: menu
        )
            .isEnabled = actionEnabled[DrawingToolbarOverflowActionTitle.bringForward] == true
        addMenuItem(
            DrawingToolbarOverflowActionTitle.sendBackward,
            command: .arrangeSelection(.sendBackward),
            to: menu
        )
            .isEnabled = actionEnabled[DrawingToolbarOverflowActionTitle.sendBackward] == true
        addMenuItem(
            DrawingToolbarOverflowActionTitle.sendToBack,
            command: .arrangeSelection(.sendToBack),
            to: menu
        )
            .isEnabled = actionEnabled[DrawingToolbarOverflowActionTitle.sendToBack] == true
        menu.addItem(.separator())
        addMenuItem(
            DrawingToolbarOverflowActionTitle.group,
            command: .groupSelection,
            to: menu
        )
            .isEnabled = actionEnabled[DrawingToolbarOverflowActionTitle.group] == true
        addMenuItem(
            DrawingToolbarOverflowActionTitle.ungroup,
            command: .ungroupSelection,
            to: menu
        )
            .isEnabled = actionEnabled[DrawingToolbarOverflowActionTitle.ungroup] == true
        let lockTitle = currentState.selectionIsFullyLocked
            ? DrawingToolbarOverflowActionTitle.unlock
            : DrawingToolbarOverflowActionTitle.lock
        addMenuItem(
            lockTitle,
            command: .toggleSelectionLock,
            to: menu
        ).isEnabled = actionEnabled[lockTitle] == true
        menu.addItem(.separator())
        let editPointsTitle = currentState.isEditingLinearPoints
            ? DrawingToolbarOverflowActionTitle.finishPointEditing
            : DrawingToolbarOverflowActionTitle.editPoints
        addMenuItem(
            editPointsTitle,
            command: .toggleLinearPointEditing,
            to: menu
        ).isEnabled = actionEnabled[editPointsTitle] == true
        addMenuItem(
            DrawingToolbarOverflowActionTitle.insertPoint,
            command: .insertLinearPoint,
            to: menu
        )
            .isEnabled = actionEnabled[DrawingToolbarOverflowActionTitle.insertPoint] == true
        addMenuItem(
            DrawingToolbarOverflowActionTitle.removePoints,
            command: .removeLinearPoints,
            to: menu
        )
            .isEnabled = actionEnabled[DrawingToolbarOverflowActionTitle.removePoints] == true
        addMenuItem(
            DrawingToolbarOverflowActionTitle.unbindEndpoints,
            command: .unbindLinearEndpoints,
            to: menu
        )
            .isEnabled = actionEnabled[DrawingToolbarOverflowActionTitle.unbindEndpoints] == true

        interactionState.menuOpen = true
        interactionStateDidChange()
        defer {
            interactionState.menuOpen = false
            interactionStateDidChange()
        }
        menu.popUp(
            positioning: nil,
            at: CGPoint(x: view.bounds.midX, y: view.bounds.minY),
            in: view
        )
    }

    @discardableResult
    private func addMenuItem(
        _ title: String,
        command: AppCommand,
        to menu: NSMenu
    ) -> NSMenuItem {
        let item = DrawingToolbarMenuItem(title: title, command: command) { [weak self] command in
            self?.send(command)
        }
        menu.addItem(item)
        return item
    }

    private func handlePanelEvent(_ eventType: NSEvent.EventType) {
        switch eventType {
        case .scrollWheel:
            interactionState.scrollActive = true
            scrollTimer?.invalidate()
            let timer = Timer(timeInterval: 0.25, repeats: false) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.interactionState.scrollActive = false
                    self.interactionStateDidChange()
                }
            }
            RunLoop.main.add(timer, forMode: .common)
            scrollTimer = timer
        default:
            break
        }
        interactionStateDidChange()
    }

    private func setControlTracking(_ isTracking: Bool) {
        interactionState.controlTracking = isTracking
        interactionStateDidChange()
    }

    private func interactionStateDidChange() {
        pointerInteractionChanged(interactionState)
        if !interactionState.isActive {
            restoreCanvasFocus()
        }
    }

    private func applyToolbarFrame(
        animated: Bool,
        preservingCurrentOrigin: Bool = false,
        screen explicitScreen: NSScreen? = nil
    ) {
        let targetScreen = explicitScreen
            ?? bestScreen(for: toolbarPanel.frame)
            ?? parentWindow?.screen
        guard let targetScreen else { return }
        let size = toolbarView.preferredContentSize(
            maximumWidth: max(
                44,
                targetScreen.visibleFrame.width - DrawingToolbarLayout.screenMargin * 2
            )
        )
        let origin: CGPoint
        if preservingCurrentOrigin, !toolbarPanel.frame.isEmpty {
            origin = DrawingToolbarPlacement.clampedOrigin(
                toolbarPanel.frame.origin,
                panelSize: size,
                visibleFrame: targetScreen.visibleFrame
            )
        } else {
            origin = toolbarNormalizedPosition.map {
                DrawingToolbarPlacement.origin(
                    normalizedPosition: $0,
                    panelSize: size,
                    visibleFrame: targetScreen.visibleFrame
                )
            } ?? DrawingToolbarPlacement.defaultOrigin(
                panelSize: size,
                visibleFrame: targetScreen.visibleFrame
            )
        }
        setFrame(
            CGRect(origin: origin, size: size),
            for: toolbarPanel,
            animated: animated,
            isToolbar: true
        )
    }

    private func applyInspectorFrame(
        screen explicitScreen: NSScreen? = nil
    ) {
        guard isPanelVisible else { return }
        guard DrawingInspectorPresentationPolicy.shouldShow(
            hasContent: currentState.hasInspectorContent
        ) else {
            orderInspectorOut()
            return
        }
        guard let targetScreen = explicitScreen
            ?? bestScreen(for: toolbarPanel.frame)
            ?? parentWindow?.screen
            ?? NSScreen.main else {
            return
        }
        let safeWidth = max(
            1,
            targetScreen.visibleFrame.width
                - DrawingAttachedInspectorPlacement.screenMargin * 2
        )
        let panelWidth = min(
            DrawingInspectorVisualMetrics.attachedMaximumWidth,
            safeWidth
        )
        propertiesController.setAvailableHorizontalWidth(
            max(
                1,
                panelWidth
                    - DrawingInspectorVisualMetrics.attachedHorizontalChrome
            )
        )
        inspectorView.update(
            state: currentState,
            contentSize: propertiesController.preferredContentSize
        )
        let placement = DrawingAttachedInspectorPlacement.result(
            toolbarFrame: toolbarPanel.frame,
            contentSize: propertiesController.preferredContentSize,
            visibleFrame: targetScreen.visibleFrame,
            previousAlignment: attachedInspectorAlignment
        )
        attachedInspectorAlignment = placement.alignment
        if inspectorPanel.frame != placement.frame {
            inspectorPanel.setFrame(placement.frame, display: true)
        }
        if !isInspectorOrderedVisible { orderInspectorFront() }
    }

    private func orderInspectorFront() {
        if inspectorPanel.parent !== toolbarPanel {
            toolbarPanel.addChildWindow(inspectorPanel, ordered: .above)
        }
        inspectorPanel.orderFront(nil)
        isInspectorOrderedVisible = true
    }

    private func orderInspectorOut() {
        inspectorPanel.orderOut(nil)
        isInspectorOrderedVisible = false
    }

    private func setFrame(
        _ frame: CGRect,
        for panel: NSPanel,
        animated: Bool,
        isToolbar: Bool
    ) {
        guard panel.frame != frame else { return }
        if animated && panel.isVisible {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.16
                panel.animator().setFrame(frame, display: true)
            }
        } else {
            panel.setFrame(frame, display: true)
        }
        _ = isToolbar
    }

    private func screenGeometryDidChange() {
        guard isPanelVisible else { return }
        applyToolbarFrame(animated: false)
        applyInspectorFrame()
    }

    private func setToolbarOriginIfNeeded(_ origin: CGPoint) {
        guard origin != toolbarPanel.frame.origin else { return }
        toolbarPanel.setFrameOrigin(origin)
    }

    private func screen(containing point: CGPoint) -> NSScreen? {
        NSScreen.screens.first { NSMouseInRect(point, $0.frame, false) }
    }

    private func bestScreen(for frame: CGRect) -> NSScreen? {
        let intersecting = NSScreen.screens.max {
            $0.frame.intersection(frame).area < $1.frame.intersection(frame).area
        }
        if let intersecting, intersecting.frame.intersects(frame) {
            return intersecting
        }
        return parentWindow?.screen ?? NSScreen.main
    }
}

private extension CGRect {
    var area: CGFloat {
        guard !isNull else { return 0 }
        return width * height
    }
}

@MainActor
private final class DrawingToolbarMenuItem: NSMenuItem {
    private let command: AppCommand
    private let handler: (AppCommand) -> Void

    init(title: String, command: AppCommand, handler: @escaping (AppCommand) -> Void) {
        self.command = command
        self.handler = handler
        super.init(title: title, action: nil, keyEquivalent: "")
        target = self
        action = #selector(invoke)
    }

    required init(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    @objc private func invoke() {
        handler(command)
    }
}
