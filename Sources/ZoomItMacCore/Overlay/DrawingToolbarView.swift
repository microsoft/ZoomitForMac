import AppKit

struct DrawingToolbarShadowMetric: Equatable {
    var opacity: Float
    var blurRadius: CGFloat
    var offset: CGSize
}

enum DrawingToolbarVisualMetrics {
    static let desktopWidth: CGFloat = 648
    static let shellHeight: CGFloat = 54
    static let shellInset: CGFloat = 5
    static let shellCornerRadius: CGFloat = 15
    static let buttonSide: CGFloat = 44
    static let buttonCornerRadius: CGFloat = 10
    static let dragHandleWidth: CGFloat = 24
    static let dragHandleBarWidth: CGFloat = 10
    static let dragHandleBarHeight: CGFloat = 1.5
    static let iconPointSize: CGFloat = 20
    static let numericHintFontSize: CGFloat = 11
    static let numericHintFontDesign = "system-regular"
    static let groupSpacing: CGFloat = 6
    static let shellShadows = [
        DrawingToolbarShadowMetric(
            opacity: 0.17,
            blurRadius: 1,
            offset: .zero
        ),
        DrawingToolbarShadowMetric(
            opacity: 0.08,
            blurRadius: 3,
            offset: .zero
        ),
        DrawingToolbarShadowMetric(
            opacity: 0.05,
            blurRadius: 14,
            offset: CGSize(width: 0, height: 7)
        )
    ]

    static func numericHintOrigin(
        in bounds: CGRect,
        textSize: CGSize,
        isFlipped: Bool
    ) -> CGPoint {
        CGPoint(
            x: bounds.maxX - textSize.width - 4,
            y: isFlipped
                ? bounds.maxY - textSize.height - 4
                : bounds.minY + 4
        )
    }
}

struct DrawingToolbarButtonVisualSnapshot: Equatable {
    var backgroundAlpha: CGFloat
    var borderWidth: CGFloat
    var isSelected: Bool
}

@MainActor
final class DrawingToolbarView: NSVisualEffectView {
    private let commandSink: (AppCommand) -> Void
    private let showOverflow: (NSView) -> Void
    private let beginDragging: (NSEvent) -> Void
    private let scrollView = DrawingToolbarScrollView()
    private let stack = DrawingToolbarStackView()
    private let pathActionsStack = DrawingToolbarStackView()
    private let dragHandle: DrawingToolbarDragHandleView
    private var toolButtons: [AnnotationTool: DrawingToolbarButton] = [:]
    private let finishPathButton: DrawingToolbarButton
    private let cancelPathButton: DrawingToolbarButton
    private var shellShadowLayers: [CALayer] = []
    private var trackingAreaReference: NSTrackingArea?
    private var isConstructingLinearPath = false
    private var shouldResetScrollPosition = true

    var onPointerPresenceChanged: ((Bool) -> Void)?

    init(
        commandSink: @escaping (AppCommand) -> Void,
        showOverflow: @escaping (NSView) -> Void,
        beginDragging: @escaping (NSEvent) -> Void = { _ in }
    ) {
        self.commandSink = commandSink
        self.showOverflow = showOverflow
        self.beginDragging = beginDragging
        finishPathButton = DrawingToolbarButton(
            symbolName: "checkmark.circle.fill",
            label: "Finish Path",
            keyboardHint: "Return"
        )
        cancelPathButton = DrawingToolbarButton(
            symbolName: "xmark.circle",
            label: "Cancel Path",
            keyboardHint: "Escape"
        )
        dragHandle = DrawingToolbarDragHandleView(
            beginDragging: beginDragging
        )
        super.init(frame: .zero)

        material = .hudWindow
        blendingMode = .behindWindow
        state = .active
        wantsLayer = true
        layer?.cornerRadius = DrawingToolbarVisualMetrics.shellCornerRadius
        layer?.masksToBounds = false
        layer?.borderWidth = 0
        configureShellShadows()
        updateShellAppearance()

        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = DrawingToolbarVisualMetrics.groupSpacing
        stack.translatesAutoresizingMaskIntoConstraints = true
        scrollView.borderType = .noBorder
        scrollView.drawsBackground = false
        scrollView.autohidesScrollers = true
        scrollView.scrollerStyle = .overlay
        scrollView.horizontalScrollElasticity = .none
        scrollView.verticalScrollElasticity = .none
        scrollView.documentView = stack
        addSubview(scrollView)

        pathActionsStack.orientation = .horizontal
        pathActionsStack.alignment = .centerY
        pathActionsStack.spacing = 8
        pathActionsStack.translatesAutoresizingMaskIntoConstraints = true
        pathActionsStack.isHidden = true
        addSubview(pathActionsStack)

        stack.addArrangedSubview(dragHandle)
        addSeparator()

        addToolButton(.hand, symbol: "hand.draw", label: "Hand")

        let tools: [(AnnotationTool, String, String)] = [
            (.select, "cursorarrow", "Select"),
            (.rectangle, "rectangle", "Rectangle"),
            (.diamond, "diamond", "Diamond"),
            (.ellipse, "circle", "Ellipse"),
            (.arrow, "arrow.up.right", "Arrow"),
            (.line, "line.diagonal", "Line"),
            (.pen, "pencil.tip", "Pen"),
            (.highlighter, "highlighter", "Highlighter"),
            (.text, "textformat", "Text"),
            (.eraser, "eraser", "Eraser")
        ]
        for (tool, symbol, label) in tools {
            addToolButton(tool, symbol: symbol, label: label)
        }

        finishPathButton.handler = { [weak self] in self?.commandSink(.finishLinearPath) }
        pathActionsStack.addArrangedSubview(finishPathButton)
        cancelPathButton.handler = { [weak self] in self?.commandSink(.cancelLinearPath) }
        pathActionsStack.addArrangedSubview(cancelPathButton)

        addSeparator()
        let overflowButton = DrawingToolbarButton(
            symbolName: "ellipsis.circle",
            label: "More Drawing Actions"
        )
        overflowButton.handler = { [weak self, weak overflowButton] in
            guard let self, let overflowButton else { return }
            self.showOverflow(overflowButton)
        }
        stack.addArrangedSubview(overflowButton)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        true
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        let hit = super.hitTest(point)
        var candidate = hit
        while let view = candidate, view !== self {
            if view is NSControl {
                return view
            }
            if view === dragHandle {
                return dragHandle
            }
            candidate = view.superview
        }
        return self
    }

    override func mouseDown(with event: NSEvent) {
        beginDragging(event)
    }

    override func updateTrackingAreas() {
        if let trackingAreaReference {
            removeTrackingArea(trackingAreaReference)
        }
        let tracking = NSTrackingArea(
            rect: bounds,
            options: [.activeAlways, .mouseEnteredAndExited, .inVisibleRect],
            owner: self
        )
        addTrackingArea(tracking)
        trackingAreaReference = tracking
        super.updateTrackingAreas()
    }

    override func mouseEntered(with event: NSEvent) {
        NSCursor.openHand.set()
        onPointerPresenceChanged?(true)
    }

    override func mouseExited(with event: NSEvent) {
        onPointerPresenceChanged?(false)
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateShellAppearance()
    }

    override var mouseDownCanMoveWindow: Bool { true }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .openHand)
    }

    override func layout() {
        super.layout()
        guard bounds.width.isFinite,
              bounds.height.isFinite,
              bounds.width > 0,
              bounds.height > 0 else {
            return
        }
        updateShellShadowGeometry()
        let pathSize = pathActionsStack.isHidden
            ? .zero
            : Self.finiteSize(pathActionsStack.fittingSize, fallback: .zero)
        let frames = DrawingToolbarLayout.frames(
            in: bounds,
            pathActionsSize: pathSize
        )
        scrollView.frame = frames.scrollFrame
        pathActionsStack.frame = frames.pathActionsFrame

        let fittingSize = Self.finiteSize(
            stack.fittingSize,
            fallback: frames.scrollFrame.size
        )
        stack.frame = CGRect(
            origin: CGPoint(
                x: max(0, (frames.scrollFrame.width - fittingSize.width) / 2),
                y: max(0, (frames.scrollFrame.height - fittingSize.height) / 2)
            ),
            size: CGSize(
                width: fittingSize.width,
                height: fittingSize.height
            )
        )
        scrollView.hasHorizontalScroller = fittingSize.width > frames.scrollFrame.width
        scrollView.hasVerticalScroller = false
        if shouldResetScrollPosition {
            shouldResetScrollPosition = false
            scrollView.contentView.scroll(to: .zero)
            scrollView.reflectScrolledClipView(scrollView.contentView)
        }
    }

    func preferredContentSize(maximumWidth: CGFloat? = nil) -> CGSize {
        var size = DrawingToolbarLayout.preferredSize(
            mainContentSize: Self.finiteSize(
                stack.fittingSize,
                fallback: CGSize(
                    width: DrawingToolbarVisualMetrics.shellHeight,
                    height: DrawingToolbarVisualMetrics.shellHeight
                )
            ),
            pathActionsSize: pathActionsStack.isHidden
                ? .zero
                : Self.finiteSize(pathActionsStack.fittingSize, fallback: .zero),
            maximumWidth: maximumWidth
        )
        size.width = min(
            DrawingToolbarVisualMetrics.desktopWidth,
            maximumWidth ?? DrawingToolbarVisualMetrics.desktopWidth
        )
        return size
    }

    private static func finiteSize(_ size: CGSize, fallback: CGSize) -> CGSize {
        CGSize(
            width: size.width.isFinite && size.width >= 0 ? size.width : fallback.width,
            height: size.height.isFinite && size.height >= 0 ? size.height : fallback.height
        )
    }

    func update(
        state: DrawingToolbarState,
        transientTool: AnnotationTool?
    ) {
        let displayedTool = transientTool ?? state.currentTool
        selectDisplayedTool(displayedTool)
        isConstructingLinearPath = state.isConstructingLinearPath
        finishPathButton.isEnabled = state.canFinishLinearPath
        pathActionsStack.isHidden = !state.isConstructingLinearPath

        needsLayout = true
    }

    func activateTool(_ tool: AnnotationTool) {
        selectDisplayedTool(tool)
        commandSink(.setTool(tool))
    }

    func isToolSelected(_ tool: AnnotationTool) -> Bool {
        toolButtons[tool]?.isSelected == true
    }

    var buttonFramesForTesting: [String: CGRect] {
        let frames = toolButtons.reduce(into: [String: CGRect]()) {
            $0[String(describing: $1.key)] = CGRect(
                origin: $1.value.convert(.zero, to: self),
                size: $1.value.frame.size
            )
        }
        return frames
    }

    var buttonHitPointsForTesting: [String: CGPoint] {
        toolButtons.reduce(into: [:]) {
            $0[String(describing: $1.key)] = $1.value.convert(
                CGPoint(x: $1.value.bounds.midX, y: $1.value.bounds.midY),
                to: self
            )
        }
    }

    var primaryItemOrderForTesting: [String] {
        stack.arrangedSubviews.compactMap {
            if $0 === dragHandle {
                return dragHandle.accessibilityLabel()
            }
            if $0 is DrawingToolbarSeparatorView {
                return "separator"
            }
            return ($0 as? DrawingToolbarButton)?.accessibilityLabel()
        }
    }

    var primaryButtonVisualsForTesting:
        [String: DrawingToolbarButtonVisualSnapshot] {
        stack.arrangedSubviews.reduce(into: [:]) { result, view in
            guard let button = view as? DrawingToolbarButton,
                  let label = button.accessibilityLabel() else {
                return
            }
            result[label] = DrawingToolbarButtonVisualSnapshot(
                backgroundAlpha: button.layer?.backgroundColor?.alpha ?? 0,
                borderWidth: button.layer?.borderWidth ?? 0,
                isSelected: button.isSelected
            )
        }
    }

    var shellShadowMetricsForTesting: [DrawingToolbarShadowMetric] {
        DrawingToolbarVisualMetrics.shellShadows
    }

    var shellShadowLayerCountForTesting: Int {
        shellShadowLayers.count
    }

    var backgroundDragEnabledForTesting: Bool {
        mouseDownCanMoveWindow
            && stack.mouseDownCanMoveWindow
            && scrollView.mouseDownCanMoveWindow
            && !dragHandle.mouseDownCanMoveWindow
            && toolButtons.values.allSatisfy { !$0.mouseDownCanMoveWindow }
    }

    var dragHandleFrameForTesting: CGRect {
        CGRect(
            origin: dragHandle.convert(.zero, to: self),
            size: dragHandle.frame.size
        )
    }

    var dragHandleAccessibilityForTesting: (
        label: String?,
        help: String?
    ) {
        (
            dragHandle.accessibilityLabel(),
            dragHandle.accessibilityHelp()
        )
    }

    func isDragHandleHitForTesting(at point: CGPoint) -> Bool {
        hitTest(point) === dragHandle
    }

    func beginDragFromHandleForTesting(with event: NSEvent) {
        dragHandle.mouseDown(with: event)
    }

    private func selectDisplayedTool(_ tool: AnnotationTool) {
        for (candidate, button) in toolButtons {
            button.isSelected = candidate == tool
        }
    }

    private func addToolButton(
        _ tool: AnnotationTool,
        symbol: String,
        label: String
    ) {
        let shortcutMetadata = DrawingToolShortcuts.metadata(for: tool)
        let button = DrawingToolbarButton(
            symbolName: symbol,
            label: label,
            keyboardHint: shortcutMetadata?.keyboardHint,
            numericHint: shortcutMetadata?.numericHint
        )
        button.handler = { [weak self] in
            self?.activateTool(tool)
        }
        toolButtons[tool] = button
        stack.addArrangedSubview(button)
    }

    private func addSeparator() {
        let separator = DrawingToolbarSeparatorView()
        separator.translatesAutoresizingMaskIntoConstraints = false
        separator.widthAnchor.constraint(equalToConstant: 1).isActive = true
        separator.heightAnchor.constraint(equalToConstant: 20).isActive = true
        stack.addArrangedSubview(separator)
    }

    private func updateShellAppearance() {
        let isDark = effectiveAppearance.bestMatch(
            from: [.darkAqua, .aqua]
        ) == .darkAqua
        layer?.backgroundColor = (
            isDark
                ? NSColor(srgbRed: 0.12, green: 0.12, blue: 0.15, alpha: 0.96)
                : NSColor(srgbRed: 0.98, green: 0.98, blue: 0.99, alpha: 0.96)
        ).cgColor
    }

    private func configureShellShadows() {
        guard let layer else { return }
        shellShadowLayers = DrawingToolbarVisualMetrics.shellShadows.map {
            metric in
            let shadowLayer = CALayer()
            shadowLayer.backgroundColor = NSColor.black
                .withAlphaComponent(0.001)
                .cgColor
            shadowLayer.cornerRadius =
                DrawingToolbarVisualMetrics.shellCornerRadius
            shadowLayer.shadowColor = NSColor.black.cgColor
            shadowLayer.shadowOpacity = metric.opacity
            shadowLayer.shadowRadius = metric.blurRadius / 2
            shadowLayer.shadowOffset = CGSize(
                width: metric.offset.width,
                height: -metric.offset.height
            )
            shadowLayer.zPosition = -1
            layer.addSublayer(shadowLayer)
            return shadowLayer
        }
    }

    private func updateShellShadowGeometry() {
        let path = CGPath(
            roundedRect: bounds,
            cornerWidth: DrawingToolbarVisualMetrics.shellCornerRadius,
            cornerHeight: DrawingToolbarVisualMetrics.shellCornerRadius,
            transform: nil
        )
        for shadowLayer in shellShadowLayers {
            shadowLayer.frame = bounds
            shadowLayer.shadowPath = path
        }
    }
}

@MainActor
private final class DrawingToolbarDragHandleView: NSView {
    private let beginDragging: (NSEvent) -> Void

    init(beginDragging: @escaping (NSEvent) -> Void) {
        self.beginDragging = beginDragging
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        widthAnchor.constraint(
            equalToConstant: DrawingToolbarVisualMetrics.dragHandleWidth
        ).isActive = true
        heightAnchor.constraint(
            equalToConstant: DrawingToolbarVisualMetrics.buttonSide
        ).isActive = true
        setAccessibilityElement(true)
        setAccessibilityRole(.handle)
        setAccessibilityLabel("Move Drawing Toolbar")
        setAccessibilityHelp(
            "Drag to move the drawing toolbar and attached inspector"
        )
        toolTip = "Drag to move the drawing toolbar"
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        true
    }

    override var mouseDownCanMoveWindow: Bool { false }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .openHand)
    }

    override func mouseEntered(with event: NSEvent) {
        NSCursor.openHand.set()
    }

    override func mouseDown(with event: NSEvent) {
        NSCursor.closedHand.set()
        defer { NSCursor.openHand.set() }
        beginDragging(event)
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        let barWidth = DrawingToolbarVisualMetrics.dragHandleBarWidth
        let barHeight = DrawingToolbarVisualMetrics.dragHandleBarHeight
        let x = bounds.midX - barWidth / 2
        let centerY = bounds.midY
        NSColor.secondaryLabelColor.withAlphaComponent(0.58).setFill()
        for offset in [-4, 0, 4] as [CGFloat] {
            NSBezierPath(
                roundedRect: CGRect(
                    x: x,
                    y: centerY + offset - barHeight / 2,
                    width: barWidth,
                    height: barHeight
                ),
                xRadius: barHeight / 2,
                yRadius: barHeight / 2
            ).fill()
        }
    }
}

@MainActor
private final class DrawingToolbarStackView: NSStackView {
    override var isFlipped: Bool { true }
    override var mouseDownCanMoveWindow: Bool { true }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .openHand)
    }
}

@MainActor
private final class DrawingToolbarScrollView: NSScrollView {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        true
    }

    override var mouseDownCanMoveWindow: Bool { true }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .openHand)
    }
}

@MainActor
private final class DrawingToolbarSeparatorView: NSView {
    override var mouseDownCanMoveWindow: Bool { true }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .openHand)
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        NSColor.separatorColor.withAlphaComponent(0.28).setFill()
        NSBezierPath(rect: bounds).fill()
    }
}

@MainActor
private final class DrawingToolbarButton: DrawingAppearanceButton {
    var handler: (() -> Void)?
    private let numericHint: String?
    override var alignmentRectInsets: NSEdgeInsets {
        NSEdgeInsets(top: 0, left: 0, bottom: 0, right: 0)
    }

    init(
        symbolName: String,
        label: String,
        keyboardHint: String? = nil,
        numericHint: String? = nil
    ) {
        self.numericHint = numericHint
        super.init(frame: .zero)
        setSymbol(symbolName, accessibilityDescription: label)
        imagePosition = .imageOnly
        bezelStyle = .shadowlessSquare
        isBordered = false
        showsBorderOnlyWhileMouseInside = false
        focusRingType = .none
        refusesFirstResponder = true
        setAccessibilityLabel(label)
        toolTip = keyboardHint.map { "\(label) (\($0))" } ?? label
        setAccessibilityHelp(toolTip)
        target = self
        action = #selector(invoke)
        drawingCornerRadius = DrawingToolbarVisualMetrics.buttonCornerRadius
        translatesAutoresizingMaskIntoConstraints = false
        widthAnchor.constraint(
            equalToConstant: DrawingToolbarVisualMetrics.buttonSide
        ).isActive = true
        heightAnchor.constraint(
            equalToConstant: DrawingToolbarVisualMetrics.buttonSide
        ).isActive = true
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var mouseDownCanMoveWindow: Bool { false }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .arrow)
    }

    override func mouseEntered(with event: NSEvent) {
        super.mouseEntered(with: event)
        NSCursor.arrow.set()
    }

    override func refreshDrawingAppearance() {
        super.refreshDrawingAppearance()
        layer?.borderWidth = 0
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        layer?.borderWidth = 0
        guard let numericHint else { return }

        let resolved = resolvedDrawingAppearance
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(
                ofSize: DrawingToolbarVisualMetrics.numericHintFontSize,
                weight: .regular
            ),
            .foregroundColor: resolved.content.nsColor.withAlphaComponent(
                resolved.contentOpacity * (isSelected ? 0.78 : 0.62)
            )
        ]
        let size = numericHint.size(withAttributes: attributes)
        numericHint.draw(
            at: DrawingToolbarVisualMetrics.numericHintOrigin(
                in: bounds,
                textSize: size,
                isFlipped: isFlipped
            ),
            withAttributes: attributes
        )
    }

    func setSymbol(_ symbolName: String, accessibilityDescription: String) {
        image = NSImage(
            systemSymbolName: symbolName,
            accessibilityDescription: accessibilityDescription
        )?.withSymbolConfiguration(
            NSImage.SymbolConfiguration(
                pointSize: DrawingToolbarVisualMetrics.iconPointSize,
                weight: .regular
            )
        )
    }

    @objc private func invoke() {
        handler?()
    }
}
