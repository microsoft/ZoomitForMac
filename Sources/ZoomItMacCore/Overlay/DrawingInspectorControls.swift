import AppKit

enum DrawingInspectorVisualMetrics {
    static let contentWidth: CGFloat = 261
    static let tileSide: CGFloat = 32
    static let colorTileSide: CGFloat = 38
    static let customColorTileSide: CGFloat = 26
    static let customColorCornerRadius: CGFloat = 5
    static let tileSpacing: CGFloat = 8
    static let swatchSpacing: CGFloat = 7
    static let sectionSpacing: CGFloat = 16
    static let attachedSectionSpacing: CGFloat = 16
    static let attachedRowSpacing: CGFloat = 12
    static let attachedHorizontalChrome: CGFloat = 24
    static let attachedVerticalInset: CGFloat = 8
    static let attachedMaximumWidth: CGFloat = 780
}

struct DrawingControlColor: Equatable {
    var red: CGFloat
    var green: CGFloat
    var blue: CGFloat
    var alpha: CGFloat = 1

    var nsColor: NSColor {
        NSColor(
            srgbRed: red,
            green: green,
            blue: blue,
            alpha: alpha
        )
    }
}

struct DrawingControlVisualState: Equatable {
    var isHovered = false
    var isPressed = false
    var isSelected = false
    var isMixed = false
    var isFocused = false
    var isEnabled = true
}

struct DrawingResolvedControlAppearance: Equatable {
    var background: DrawingControlColor
    var border: DrawingControlColor
    var content: DrawingControlColor
    var fillOpacity: CGFloat
    var contentOpacity: CGFloat
    var showsMixedIndicator: Bool
}

enum DrawingControlAppearanceResolver {
    private struct Palette {
        var idleBackground: DrawingControlColor
        var idleBorder: DrawingControlColor
        var hoverBackground: DrawingControlColor
        var pressedBackground: DrawingControlColor
        var pressedBorder: DrawingControlColor
        var selectedBackground: DrawingControlColor
        var selectedBorder: DrawingControlColor
        var idleContent: DrawingControlColor
        var selectedContent: DrawingControlColor
    }

    @MainActor
    static func resolve(
        _ state: DrawingControlVisualState,
        appearance: NSAppearance? = NSApp.effectiveAppearance
    ) -> DrawingResolvedControlAppearance {
        let palette = isDark(appearance) ? darkPalette : lightPalette
        let colors: (
            background: DrawingControlColor,
            border: DrawingControlColor,
            content: DrawingControlColor
        )
        if state.isPressed {
            colors = (
                palette.pressedBackground,
                palette.pressedBorder,
                state.isSelected ? palette.selectedContent : palette.idleContent
            )
        } else if state.isSelected {
            colors = (
                palette.selectedBackground,
                palette.selectedBorder,
                palette.selectedContent
            )
        } else if state.isHovered {
            colors = (
                palette.hoverBackground,
                state.isFocused ? palette.selectedBorder : palette.idleBorder,
                palette.idleContent
            )
        } else {
            colors = (
                palette.idleBackground,
                state.isFocused ? palette.selectedBorder : palette.idleBorder,
                palette.idleContent
            )
        }

        return DrawingResolvedControlAppearance(
            background: colors.background,
            border: colors.border,
            content: colors.content,
            fillOpacity: state.isEnabled ? 1 : 0.55,
            contentOpacity: state.isEnabled ? 1 : 0.38,
            showsMixedIndicator: state.isMixed
        )
    }

    @MainActor
    static func resolveAuditedPropertyTile(
        _ state: DrawingControlVisualState,
        appearance: NSAppearance? = NSApp.effectiveAppearance
    ) -> DrawingResolvedControlAppearance {
        let dark = isDark(appearance)
        let idleBackground = dark ? color(0x2E2D39) : color(0xF6F6F9)
        let idleContent = dark ? color(0xE3E3E8) : color(0x1B1B1F)
        let selectedBackground = dark ? color(0x403E6A) : color(0xE0DFFF)
        let selectedContent = dark ? color(0xE0DFFF) : color(0x030064)
        let isEmphasized = state.isSelected || state.isPressed
        let background = isEmphasized ? selectedBackground : idleBackground
        let content = isEmphasized ? selectedContent : idleContent
        return DrawingResolvedControlAppearance(
            background: background,
            border: background,
            content: content,
            fillOpacity: state.isEnabled ? 1 : 0.55,
            contentOpacity: state.isEnabled ? 1 : 0.38,
            showsMixedIndicator: state.isMixed
        )
    }

    @MainActor
    private static func isDark(_ appearance: NSAppearance?) -> Bool {
        appearance?.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
    }

    private static let lightPalette = Palette(
        idleBackground: color(0xFFFFFF, alpha: 0),
        idleBorder: color(0x000000, alpha: 0),
        hoverBackground: color(0xF1F0FF),
        pressedBackground: color(0xECEBFF),
        pressedBorder: color(0x000000, alpha: 0),
        selectedBackground: color(0xE0DFFF),
        selectedBorder: color(0x000000, alpha: 0),
        idleContent: color(0x1D1D22),
        selectedContent: color(0x030064)
    )

    private static let darkPalette = Palette(
        idleBackground: color(0x000000, alpha: 0),
        idleBorder: color(0xFFFFFF, alpha: 0),
        hoverBackground: color(0x2E2D39),
        pressedBackground: color(0x403B5F),
        pressedBorder: color(0xFFFFFF, alpha: 0),
        selectedBackground: color(0x403E6A),
        selectedBorder: color(0xFFFFFF, alpha: 0),
        idleContent: color(0xF1F0FF),
        selectedContent: color(0xE0DFFF)
    )

    private static func color(
        _ rgb: UInt32,
        alpha: CGFloat = 1
    ) -> DrawingControlColor {
        DrawingControlColor(
            red: CGFloat((rgb >> 16) & 0xFF) / 255,
            green: CGFloat((rgb >> 8) & 0xFF) / 255,
            blue: CGFloat(rgb & 0xFF) / 255,
            alpha: alpha
        )
    }
}

@MainActor
class DrawingAppearanceButton: NSButton {
    var isSelected = false {
        didSet { refreshDrawingAppearance() }
    }
    var isMixed = false {
        didSet { refreshDrawingAppearance() }
    }
    var drawsMixedIndicator = true {
        didSet { needsDisplay = true }
    }
    var drawingCornerRadius: CGFloat = 12 {
        didSet { refreshDrawingAppearance() }
    }
    var usesAuditedPropertyTilePalette = false {
        didSet { refreshDrawingAppearance() }
    }

    private var trackingAreaReference: NSTrackingArea?
    private(set) var isPointerInside = false

    var resolvedDrawingAppearance: DrawingResolvedControlAppearance {
        let state = DrawingControlVisualState(
            isHovered: isPointerInside,
            isPressed: cell?.isHighlighted == true,
            isSelected: isSelected,
            isMixed: isMixed,
            isFocused: window?.firstResponder === self,
            isEnabled: isEnabled
        )
        return usesAuditedPropertyTilePalette
            ? DrawingControlAppearanceResolver.resolveAuditedPropertyTile(
                state,
                appearance: effectiveAppearance
            )
            : DrawingControlAppearanceResolver.resolve(
                state,
                appearance: effectiveAppearance
            )
    }

    override var isEnabled: Bool {
        didSet { refreshDrawingAppearance() }
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        true
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
        isPointerInside = true
        refreshDrawingAppearance()
    }

    override func mouseExited(with event: NSEvent) {
        isPointerInside = false
        refreshDrawingAppearance()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        refreshDrawingAppearance()
    }

    override func draw(_ dirtyRect: NSRect) {
        applyDrawingAppearance()
        super.draw(dirtyRect)
        guard drawsMixedIndicator, resolvedDrawingAppearance.showsMixedIndicator else {
            return
        }
        drawMixedIndicator(in: bounds)
    }

    func refreshDrawingAppearance() {
        wantsLayer = true
        applyDrawingAppearance()
        needsDisplay = true
    }

    private func applyDrawingAppearance() {
        let resolved = resolvedDrawingAppearance
        layer?.cornerRadius = drawingCornerRadius
        layer?.borderWidth = 1
        layer?.borderColor = resolved.border.nsColor
            .withAlphaComponent(resolved.border.alpha * resolved.fillOpacity)
            .cgColor
        layer?.backgroundColor = resolved.background.nsColor
            .withAlphaComponent(resolved.background.alpha * resolved.fillOpacity)
            .cgColor
        contentTintColor = resolved.content.nsColor.withAlphaComponent(
            resolved.content.alpha * resolved.contentOpacity
        )
        setAccessibilityValue(
            isMixed ? "Mixed" : (isSelected ? "Selected" : "Not selected")
        )
    }
}

@MainActor
class DrawingMixedIndicatorStackView: NSStackView {
    var isMixed = false {
        didSet { needsDisplay = true }
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard isMixed else { return }
        drawMixedIndicator(in: bounds)
    }
}

@MainActor
private func drawMixedIndicator(in bounds: CGRect) {
    let indicatorRect = CGRect(
        x: bounds.midX - 5,
        y: bounds.maxY - 4,
        width: 10,
        height: 2
    )
    let indicator = NSBezierPath(
        roundedRect: indicatorRect,
        xRadius: 1,
        yRadius: 1
    )
    NSColor.secondaryLabelColor.setFill()
    indicator.fill()
}

struct DrawingInspectorPaletteItem<Value: Equatable> {
    var value: Value
    var label: String
    var preview: DrawingInspectorPreview
}

enum DrawingInspectorPreview {
    case fillStyle(AnnotationFillStyle)
    case strokeWidth(CGFloat)
    case strokePattern(AnnotationStrokePattern)
    case sloppiness(AnnotationSloppiness)
    case pressure(DrawingInspectorPressureOption)
    case edges(AnnotationEdgeStyle)
    case linearRoute(AnnotationLinearRoute)
    case arrowhead(AnnotationArrowhead, pointsRight: Bool)
    case sizedArrowhead(
        AnnotationArrowhead,
        pointsRight: Bool,
        size: AnnotationArrowheadSize
    )
    case arrowheadSize(AnnotationArrowheadSize)
    case layer(AnnotationArrangeAction)
    case smartDraw
    case textFont(AnnotationTextFontPreset, customFontName: String?)
    case textSize(String)
    case textAlignment(AnnotationTextAlignment)
}

struct DrawingInspectorArrowheadPreviewGeometry {
    var linear: AnnotationLinearGeometry
    var tip: CGPoint
    var adjacent: CGPoint
}

struct DrawingInspectorEdgePreviewGeometry {
    var bounds: CGRect
    var solidPath: CGPath
    var dottedPath: CGPath
}

@MainActor
final class DrawingInspectorPaletteControl<Value: Equatable>: DrawingMixedIndicatorStackView {
    var onSelect: ((Value) -> Void)?

    private var items: [DrawingInspectorPaletteItem<Value>]
    private var buttons: [DrawingInspectorPaletteButton] = []

    init(items: [DrawingInspectorPaletteItem<Value>]) {
        self.items = items
        super.init(frame: .zero)
        wantsLayer = true
        orientation = .horizontal
        alignment = .centerY
        spacing = DrawingInspectorVisualMetrics.tileSpacing

        for (index, item) in items.enumerated() {
            let button = DrawingInspectorPaletteButton(
                preview: item.preview,
                label: item.label
            )
            button.tag = index
            button.target = self
            button.action = #selector(selectItem(_:))
            buttons.append(button)
            addArrangedSubview(button)
        }
    }

    required init(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func update(_ state: DrawingToolbarValue<Value>) {
        isMixed = state == .mixed
        for (index, button) in buttons.enumerated() {
            switch state {
            case .value(let value):
                button.isSelected = items[index].value == value
                button.isMixed = false
                button.isEnabled = true
            case .mixed:
                button.isSelected = false
                button.isMixed = false
                button.isEnabled = true
            case .unavailable:
                button.isSelected = false
                button.isMixed = false
                button.isEnabled = false
            }
        }
    }

    func replaceItems(_ items: [DrawingInspectorPaletteItem<Value>]) {
        guard self.items.map(\.value) != items.map(\.value) else { return }
        self.items = items
        for button in buttons {
            removeArrangedSubview(button)
            button.removeFromSuperview()
        }
        buttons.removeAll(keepingCapacity: true)
        for (index, item) in items.enumerated() {
            let button = DrawingInspectorPaletteButton(
                preview: item.preview,
                label: item.label
            )
            button.tag = index
            button.target = self
            button.action = #selector(selectItem(_:))
            buttons.append(button)
            addArrangedSubview(button)
        }
    }

    func updatePreview(
        for value: Value,
        label: String,
        preview: DrawingInspectorPreview
    ) {
        guard let index = items.firstIndex(where: { $0.value == value }) else { return }
        items[index].label = label
        items[index].preview = preview
        buttons[index].update(preview: preview, label: label)
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        true
    }

    @objc private func selectItem(_ sender: NSButton) {
        guard items.indices.contains(sender.tag) else { return }
        onSelect?(items[sender.tag].value)
    }
}

@MainActor
final class DrawingInspectorActionButton: DrawingAppearanceButton {
    var handler: (() -> Void)?

    init(symbolName: String, label: String) {
        super.init(frame: .zero)
        imagePosition = .imageOnly
        bezelStyle = .regularSquare
        isBordered = false
        refusesFirstResponder = true
        wantsLayer = true
        drawingCornerRadius = 8
        target = self
        action = #selector(invoke)
        widthAnchor.constraint(
            equalToConstant: DrawingInspectorVisualMetrics.tileSide
        ).isActive = true
        heightAnchor.constraint(
            equalToConstant: DrawingInspectorVisualMetrics.tileSide
        ).isActive = true
        update(symbolName: symbolName, label: label)
    }

    init(
        preview: DrawingInspectorPreview,
        label: String,
        toolTip: String? = nil
    ) {
        super.init(frame: .zero)
        imagePosition = .imageOnly
        bezelStyle = .regularSquare
        isBordered = false
        refusesFirstResponder = true
        wantsLayer = true
        drawingCornerRadius = 8
        usesAuditedPropertyTilePalette = preview.usesAuditedPropertyTilePalette
        target = self
        action = #selector(invoke)
        widthAnchor.constraint(
            equalToConstant: DrawingInspectorVisualMetrics.tileSide
        ).isActive = true
        heightAnchor.constraint(
            equalToConstant: DrawingInspectorVisualMetrics.tileSide
        ).isActive = true
        update(preview: preview, label: label, toolTip: toolTip)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func update(symbolName: String, label: String) {
        image = NSImage(
            systemSymbolName: symbolName,
            accessibilityDescription: label
        )?.withSymbolConfiguration(
            NSImage.SymbolConfiguration(pointSize: 17, weight: .medium)
        )
        toolTip = label
        setAccessibilityLabel(label)
    }

    func update(
        preview: DrawingInspectorPreview,
        label: String,
        toolTip: String? = nil
    ) {
        image = preview.image
        self.toolTip = toolTip ?? label
        setAccessibilityLabel(label)
    }

    @objc private func invoke() {
        handler?()
    }
}

@MainActor
private final class DrawingArrowheadPalettePanel: NSPanel {
    var cancelHandler: (() -> Void)?

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 {
            cancelHandler?()
            return
        }
        super.keyDown(with: event)
    }

    override func resignKey() {
        super.resignKey()
        if isVisible {
            cancelHandler?()
        }
    }
}

@MainActor
final class DrawingInspectorArrowheadPicker: NSView {
    var onSelect: ((AnnotationArrowhead) -> Void)?
    var onPopoverActivityChanged: ((Bool) -> Void)?

    private let label: String
    private let pointsRight: Bool
    private let button: DrawingInspectorPaletteButton
    private var palettePanel: DrawingArrowheadPalettePanel?
    private var localDismissMonitor: Any?
    private var globalDismissMonitor: Any?
    private var selectedArrowhead: AnnotationArrowhead?
    private var reportsPopoverOpen = false

    var triggerButtonForTesting: NSButton {
        button
    }

    var palettePanelForTesting: NSPanel? {
        palettePanel
    }

    init(label: String, pointsRight: Bool) {
        self.label = label
        self.pointsRight = pointsRight
        button = DrawingInspectorPaletteButton(
            preview: .arrowhead(.none, pointsRight: pointsRight),
            label: "\(label): None"
        )
        super.init(frame: .zero)
        setAccessibilityLabel(label)
        button.target = self
        button.action = #selector(showPalette)
        addSubview(button)
        button.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            button.leadingAnchor.constraint(equalTo: leadingAnchor),
            button.trailingAnchor.constraint(equalTo: trailingAnchor),
            button.topAnchor.constraint(equalTo: topAnchor),
            button.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        true
    }

    func update(
        _ state: DrawingToolbarValue<AnnotationArrowhead>,
        size: AnnotationArrowheadSize = .small,
        appliesToEditableOnly: Bool = false
    ) {
        let scopeSuffix = appliesToEditableOnly
            ? ". Applies to unlocked arrows only"
            : ""
        switch state {
        case .value(let arrowhead):
            selectedArrowhead = arrowhead
            button.update(
                preview: .sizedArrowhead(
                    arrowhead,
                    pointsRight: pointsRight,
                    size: size
                ),
                label: "\(label): \(arrowhead.displayName)\(scopeSuffix)"
            )
            button.isSelected = palettePanel?.isVisible == true
            button.isMixed = false
            button.isEnabled = true
        case .mixed:
            selectedArrowhead = nil
            button.update(
                preview: .arrowhead(.none, pointsRight: pointsRight),
                label: "\(label): Mixed\(scopeSuffix)"
            )
            button.isSelected = palettePanel?.isVisible == true
            button.isMixed = true
            button.isEnabled = true
        case .unavailable:
            closePalette()
            selectedArrowhead = nil
            button.update(
                preview: .arrowhead(.none, pointsRight: pointsRight),
                label: "\(label): Unavailable"
            )
            button.isSelected = false
            button.isMixed = false
            button.isEnabled = false
        }
    }

    func selectForTesting(_ arrowhead: AnnotationArrowhead) {
        select(arrowhead)
    }

    @objc private func showPalette() {
        if palettePanel != nil {
            closePalette()
            return
        }
        guard let parentWindow = window else { return }
        let controller = DrawingArrowheadPaletteViewController(
            pointsRight: pointsRight,
            selectedArrowhead: selectedArrowhead
        ) { [weak self] arrowhead in
            self?.select(arrowhead)
        }
        let panel = DrawingArrowheadPalettePanel(
            contentRect: CGRect(origin: .zero, size: controller.preferredContentSize),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.isFloatingPanel = true
        panel.becomesKeyOnlyIfNeeded = false
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.level = NSWindow.Level(rawValue: parentWindow.level.rawValue + 1)
        panel.collectionBehavior = [
            .canJoinAllSpaces,
            .fullScreenAuxiliary,
            .stationary
        ]
        panel.sharingType = .none
        panel.cancelHandler = { [weak self] in
            self?.closePalette()
        }
        panel.contentViewController = controller
        panel.setFrame(
            paletteFrame(
                size: controller.preferredContentSize,
                parentWindow: parentWindow
            ),
            display: false
        )
        parentWindow.addChildWindow(panel, ordered: .above)
        palettePanel = panel
        button.isSelected = true
        setPopoverActivity(true)
        installDismissMonitors()
        panel.makeKeyAndOrderFront(nil)
    }

    private func select(_ arrowhead: AnnotationArrowhead) {
        onSelect?(arrowhead)
        closePalette()
    }

    func dismissPalette() {
        closePalette()
    }

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        if newWindow == nil {
            closePalette()
        }
        super.viewWillMove(toWindow: newWindow)
    }

    private func closePalette() {
        removeDismissMonitors()
        let panel = palettePanel
        palettePanel = nil
        if let panel {
            panel.cancelHandler = nil
            panel.parent?.removeChildWindow(panel)
            panel.orderOut(nil)
        }
        button.isSelected = false
        setPopoverActivity(false)
    }

    private func installDismissMonitors() {
        removeDismissMonitors()
        let paletteWindowNumber = palettePanel?.windowNumber ?? 0
        localDismissMonitor = NSEvent.addLocalMonitorForEvents(
            matching: [
                .leftMouseDown,
                .rightMouseDown,
                .otherMouseDown,
                .keyDown
            ]
        ) { [weak self] event in
            let isEscape = event.type == .keyDown && event.keyCode == 53
            let isOutsideMouseDown = event.type != .keyDown
                && event.windowNumber != paletteWindowNumber
            if isEscape || isOutsideMouseDown {
                Task { @MainActor in
                    self?.closePalette()
                }
            }
            return isEscape ? nil : event
        }
        globalDismissMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]
        ) { [weak self] _ in
            Task { @MainActor in
                self?.closePalette()
            }
        }
    }

    private func removeDismissMonitors() {
        if let localDismissMonitor {
            NSEvent.removeMonitor(localDismissMonitor)
            self.localDismissMonitor = nil
        }
        if let globalDismissMonitor {
            NSEvent.removeMonitor(globalDismissMonitor)
            self.globalDismissMonitor = nil
        }
    }

    private func paletteFrame(
        size: CGSize,
        parentWindow: NSWindow
    ) -> CGRect {
        let buttonInWindow = button.convert(button.bounds, to: nil)
        let anchor = parentWindow.convertToScreen(buttonInWindow)
        let visibleFrame = parentWindow.screen?.visibleFrame
            ?? NSScreen.main?.visibleFrame
            ?? anchor.insetBy(dx: -size.width, dy: -size.height)
        let gap: CGFloat = 6
        var origin = CGPoint(
            x: anchor.maxX + gap,
            y: anchor.midY - size.height / 2
        )
        if origin.x + size.width > visibleFrame.maxX {
            origin.x = anchor.minX - size.width - gap
        }
        origin.x = min(
            max(origin.x, visibleFrame.minX),
            visibleFrame.maxX - size.width
        )
        origin.y = min(
            max(origin.y, visibleFrame.minY),
            visibleFrame.maxY - size.height
        )
        return CGRect(origin: origin, size: size)
    }

    private func setPopoverActivity(_ isOpen: Bool) {
        guard reportsPopoverOpen != isOpen else { return }
        reportsPopoverOpen = isOpen
        onPopoverActivityChanged?(isOpen)
    }
}

@MainActor
final class DrawingInspectorFontPicker: NSView {
    var onSelect: ((String) -> Void)?

    private let button = DrawingInspectorPaletteButton(
        preview: .textFont(.typeSetting, customFontName: nil),
        label: "Choose font"
    )
    private var currentFontName = ""

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setAccessibilityLabel("Font picker")
        button.target = self
        button.action = #selector(showFontMenu)
        button.translatesAutoresizingMaskIntoConstraints = false
        addSubview(button)
        NSLayoutConstraint.activate([
            button.leadingAnchor.constraint(equalTo: leadingAnchor),
            button.trailingAnchor.constraint(equalTo: trailingAnchor),
            button.topAnchor.constraint(equalTo: topAnchor),
            button.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])
    }

    convenience init() {
        self.init(frame: .zero)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        true
    }

    func update(
        fontName: String,
        preset: DrawingToolbarValue<AnnotationTextFontPreset>
    ) {
        currentFontName = fontName
        let displayName = fontName.isEmpty ? "System" : fontName
        button.update(
            preview: .textFont(.typeSetting, customFontName: fontName),
            label: "Choose font (current: \(displayName))"
        )
        switch preset {
        case .value:
            button.isSelected = false
            button.isMixed = false
            button.isEnabled = true
        case .mixed:
            button.isSelected = false
            button.isMixed = true
            button.isEnabled = true
        case .unavailable:
            button.isSelected = false
            button.isMixed = false
            button.isEnabled = false
        }
    }

    func selectForTesting(_ fontName: String) {
        select(fontName)
    }

    @objc private func showFontMenu() {
        button.isSelected = true
        defer { button.isSelected = false }
        let menu = NSMenu(title: "Fonts")
        menu.autoenablesItems = false
        let fontNames = NSFontManager.shared.availableFonts.sorted { lhs, rhs in
            let leftTitle = NSFont(name: lhs, size: 13)?.displayName ?? lhs
            let rightTitle = NSFont(name: rhs, size: 13)?.displayName ?? rhs
            return leftTitle.localizedCaseInsensitiveCompare(rightTitle) == .orderedAscending
        }
        for fontName in fontNames {
            let title = NSFont(name: fontName, size: 13)?.displayName ?? fontName
            let item = DrawingInspectorFontMenuItem(
                title: title,
                fontName: fontName
            ) { [weak self] in
                self?.select(fontName)
            }
            item.state = fontName == currentFontName ? .on : .off
            menu.addItem(item)
        }
        menu.popUp(
            positioning: nil,
            at: CGPoint(x: button.bounds.minX, y: button.bounds.maxY),
            in: button
        )
    }

    private func select(_ fontName: String) {
        currentFontName = fontName
        onSelect?(fontName)
    }
}

@MainActor
private final class DrawingInspectorFontMenuItem: NSMenuItem {
    private let handler: () -> Void

    init(title: String, fontName: String, handler: @escaping () -> Void) {
        self.handler = handler
        super.init(title: title, action: nil, keyEquivalent: "")
        representedObject = fontName
        target = self
        action = #selector(invoke)
    }

    required init(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    @objc private func invoke() {
        handler()
    }
}

@MainActor
private final class DrawingArrowheadPaletteViewController: NSViewController {
    private let pointsRight: Bool
    private let selectedArrowhead: AnnotationArrowhead?
    private let onSelect: (AnnotationArrowhead) -> Void

    init(
        pointsRight: Bool,
        selectedArrowhead: AnnotationArrowhead?,
        onSelect: @escaping (AnnotationArrowhead) -> Void
    ) {
        self.pointsRight = pointsRight
        self.selectedArrowhead = selectedArrowhead
        self.onSelect = onSelect
        super.init(nibName: nil, bundle: nil)
        let side = DrawingInspectorVisualMetrics.tileSide * 4
            + DrawingInspectorVisualMetrics.tileSpacing * 3
            + 16
        preferredContentSize = CGSize(width: side, height: side)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func loadView() {
        let root = NSView()
        root.wantsLayer = true
        root.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
        root.layer?.cornerRadius = 12
        let grid = NSGridView()
        grid.rowSpacing = DrawingInspectorVisualMetrics.tileSpacing
        grid.columnSpacing = DrawingInspectorVisualMetrics.tileSpacing
        grid.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(grid)

        let arrowheads = DrawingInspectorControlMapping.arrowheads
        for rowStart in stride(from: 0, to: arrowheads.count, by: 4) {
            var row: [NSView] = []
            for index in rowStart..<min(rowStart + 4, arrowheads.count) {
                let arrowhead = arrowheads[index]
                let button = DrawingInspectorPaletteButton(
                    preview: .arrowhead(arrowhead, pointsRight: pointsRight),
                    label: arrowhead.displayName
                )
                button.isSelected = arrowhead == selectedArrowhead
                button.handler = { [weak self] in self?.onSelect(arrowhead) }
                row.append(button)
            }
            while row.count < 4 {
                let spacer = NSView()
                spacer.widthAnchor.constraint(
                    equalToConstant: DrawingInspectorVisualMetrics.tileSide
                ).isActive = true
                row.append(spacer)
            }
            grid.addRow(with: row)
        }

        NSLayoutConstraint.activate([
            grid.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 8),
            grid.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -8),
            grid.topAnchor.constraint(equalTo: root.topAnchor, constant: 8),
            grid.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -8)
        ])
        view = root
    }
}

@MainActor
final class DrawingInspectorPaletteButton: DrawingAppearanceButton {
    var handler: (() -> Void)? {
        didSet {
            if handler != nil {
                target = self
                action = #selector(invoke)
            }
        }
    }
    init(preview: DrawingInspectorPreview, label: String) {
        super.init(frame: .zero)
        title = ""
        imagePosition = .imageOnly
        bezelStyle = .regularSquare
        isBordered = false
        refusesFirstResponder = true
        wantsLayer = true
        drawingCornerRadius = 8
        usesAuditedPropertyTilePalette = preview.usesAuditedPropertyTilePalette
        update(preview: preview, label: label)
        widthAnchor.constraint(
            equalToConstant: DrawingInspectorVisualMetrics.tileSide
        ).isActive = true
        heightAnchor.constraint(
            equalToConstant: DrawingInspectorVisualMetrics.tileSide
        ).isActive = true
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func update(preview: DrawingInspectorPreview, label: String) {
        usesAuditedPropertyTilePalette = preview.usesAuditedPropertyTilePalette
        image = preview.image
        toolTip = label
        setAccessibilityLabel(label)
    }

    @objc private func invoke() {
        handler?()
    }
}

@MainActor
extension DrawingInspectorPreview {
    var usesAuditedPropertyTilePalette: Bool {
        switch self {
        case .sloppiness, .layer:
            true
        default:
            false
        }
    }

    var image: NSImage {
        let image = NSImage(size: CGSize(width: 26, height: 26), flipped: true) { rect in
            NSGraphicsContext.current?.imageInterpolation = .high
            draw(in: rect.insetBy(dx: 2, dy: 2))
            return true
        }
        image.isTemplate = true
        return image
    }

    func draw(in rect: CGRect) {
        NSColor.labelColor.setStroke()
        NSColor.labelColor.setFill()

        switch self {
        case .fillStyle(let style):
            drawFillStyle(style, in: rect)
        case .strokeWidth(let width):
            let path = NSBezierPath()
            path.lineWidth = max(1, min(8, width * 0.62))
            path.lineCapStyle = .round
            path.move(to: CGPoint(x: rect.minX + 3, y: rect.midY))
            path.line(to: CGPoint(x: rect.maxX - 3, y: rect.midY))
            path.stroke()
        case .strokePattern(let pattern):
            let path = NSBezierPath()
            path.lineWidth = 2.4
            path.lineCapStyle = .round
            switch pattern {
            case .solid:
                break
            case .dashed:
                path.setLineDash([7, 4], count: 2, phase: 0)
            case .dotted:
                path.setLineDash([0.5, 4.5], count: 2, phase: 0)
            }
            path.move(to: CGPoint(x: rect.minX + 2, y: rect.midY))
            path.line(to: CGPoint(x: rect.maxX - 2, y: rect.midY))
            path.stroke()
        case .sloppiness(let sloppiness):
            drawSloppiness(sloppiness, in: rect)
        case .pressure(let option):
            drawPressure(option, in: rect)
        case .edges(let edgeStyle):
            drawEdges(edgeStyle, in: rect)
        case .linearRoute(let route):
            drawLinearRoute(route, in: rect)
        case .arrowhead(let arrowhead, let pointsRight):
            drawArrowhead(
                arrowhead,
                pointsRight: pointsRight,
                size: .small,
                in: rect
            )
        case .sizedArrowhead(let arrowhead, let pointsRight, let size):
            drawArrowhead(
                arrowhead,
                pointsRight: pointsRight,
                size: size,
                in: rect
            )
        case .arrowheadSize(let size):
            drawCenteredText(
                size == .small ? "S" : (size == .medium ? "M" : "L"),
                font: .systemFont(ofSize: 13, weight: .semibold),
                in: rect
            )
        case .layer(let action):
            drawLayerAction(action, in: rect)
        case .smartDraw:
            drawSmartDraw(in: rect)
        case .textFont(let preset, let customFontName):
            drawTextFont(preset, customFontName: customFontName, in: rect)
        case .textSize(let label):
            drawCenteredText(label, font: .systemFont(ofSize: 14, weight: .semibold), in: rect)
        case .textAlignment(let alignment):
            drawTextAlignment(alignment, in: rect)
        }
    }

    func drawFillStyle(_ style: AnnotationFillStyle, in rect: CGRect) {
        let bounds = rect.insetBy(dx: 5, dy: 5)
        let outline = NSBezierPath(roundedRect: bounds, xRadius: 3, yRadius: 3)
        outline.lineWidth = 1.6
        outline.stroke()
        switch style {
        case .none:
            let slash = NSBezierPath()
            slash.lineWidth = 1.8
            slash.move(to: CGPoint(x: bounds.minX + 2, y: bounds.maxY - 2))
            slash.line(to: CGPoint(x: bounds.maxX - 2, y: bounds.minY + 2))
            slash.stroke()
        case .hachure, .crossHatch:
            NSGraphicsContext.saveGraphicsState()
            outline.addClip()
            drawHatch(in: bounds, rising: false)
            if style == .crossHatch {
                drawHatch(in: bounds, rising: true)
            }
            NSGraphicsContext.restoreGraphicsState()
        case .solid:
            NSColor.labelColor.withAlphaComponent(0.62).setFill()
            outline.fill()
        }
    }

    func drawHatch(in rect: CGRect, rising: Bool) {
        let hatch = NSBezierPath()
        hatch.lineWidth = 1.2
        var x = rect.minX - rect.height
        while x <= rect.maxX {
            if rising {
                hatch.move(to: CGPoint(x: x, y: rect.minY))
                hatch.line(to: CGPoint(x: x + rect.height, y: rect.maxY))
            } else {
                hatch.move(to: CGPoint(x: x, y: rect.maxY))
                hatch.line(to: CGPoint(x: x + rect.height, y: rect.minY))
            }
            x += 5
        }
        hatch.stroke()
    }

    func drawSloppiness(_ sloppiness: AnnotationSloppiness, in rect: CGRect) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        let paths = Self.sloppinessPreviewPaths(sloppiness, in: rect)
        context.saveGState()
        context.setStrokeColor(NSColor.labelColor.cgColor)
        context.setLineWidth(1)
        context.setLineCap(.round)
        context.setLineJoin(.round)
        for path in paths {
            context.addPath(path)
            context.strokePath()
        }
        context.restoreGState()
    }

    static func sloppinessPreviewPaths(
        _ sloppiness: AnnotationSloppiness,
        in rect: CGRect
    ) -> [CGPath] {
        let bounds = CGRect(
            x: rect.midX - 8,
            y: rect.midY - 8,
            width: 16,
            height: 16
        )
        func path(
            start: CGPoint,
            control1: CGPoint,
            control2: CGPoint,
            end: CGPoint
        ) -> CGPath {
            let result = CGMutablePath()
            result.move(
                to: CGPoint(x: bounds.minX + start.x, y: bounds.minY + start.y)
            )
            result.addCurve(
                to: CGPoint(x: bounds.minX + end.x, y: bounds.minY + end.y),
                control1: CGPoint(
                    x: bounds.minX + control1.x,
                    y: bounds.minY + control1.y
                ),
                control2: CGPoint(
                    x: bounds.minX + control2.x,
                    y: bounds.minY + control2.y
                )
            )
            return result
        }
        switch sloppiness {
        case .architect:
            return [
                path(
                    start: CGPoint(x: 1, y: 10.5),
                    control1: CGPoint(x: 4.6, y: 2.8),
                    control2: CGPoint(x: 10.8, y: 13.2),
                    end: CGPoint(x: 15, y: 5.5)
                )
            ]
        case .artist:
            return [
                path(
                    start: CGPoint(x: 1, y: 10.4),
                    control1: CGPoint(x: 4.4, y: 2.9),
                    control2: CGPoint(x: 10.7, y: 13.1),
                    end: CGPoint(x: 15, y: 5.6)
                ),
                path(
                    start: CGPoint(x: 1.2, y: 10.8),
                    control1: CGPoint(x: 4.8, y: 3.2),
                    control2: CGPoint(x: 10.5, y: 12.7),
                    end: CGPoint(x: 14.8, y: 5.2)
                )
            ]
        case .cartoonist:
            return [
                path(
                    start: CGPoint(x: 0.7, y: 11.8),
                    control1: CGPoint(x: 3.2, y: 1.2),
                    control2: CGPoint(x: 11.8, y: 14.8),
                    end: CGPoint(x: 15.4, y: 4.1)
                ),
                path(
                    start: CGPoint(x: 1.5, y: 8.9),
                    control1: CGPoint(x: 6.1, y: 5.2),
                    control2: CGPoint(x: 8.7, y: 11.1),
                    end: CGPoint(x: 14.4, y: 7.2)
                )
            ]
        }
    }

    func drawLayerAction(_ action: AnnotationArrangeAction, in rect: CGRect) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        context.saveGState()
        context.setStrokeColor(NSColor.labelColor.cgColor)
        context.setLineWidth(1)
        context.setLineCap(.round)
        context.setLineJoin(.round)
        context.addPath(Self.layerActionPath(action, in: rect))
        context.strokePath()
        context.restoreGState()
    }

    static func layerActionPath(
        _ action: AnnotationArrangeAction,
        in rect: CGRect
    ) -> CGPath {
        let bounds = CGRect(
            x: rect.midX - 8,
            y: rect.midY - 8,
            width: 16,
            height: 16
        )
        let isForward = action == .bringForward || action == .bringToFront
        let isTerminal = action == .sendToBack || action == .bringToFront
        func point(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
            let resolvedY = isForward ? y : 16 - y
            return CGPoint(x: bounds.minX + x, y: bounds.minY + resolvedY)
        }
        let path = CGMutablePath()
        if isTerminal {
            path.move(to: point(2.7, 2.7))
            path.addLine(to: point(13.3, 2.7))
            path.move(to: point(8, 6.7))
            path.addLine(to: point(8, 13.3))
            path.move(to: point(8, 6.7))
            path.addLine(to: point(5.3, 9.4))
            path.move(to: point(8, 6.7))
            path.addLine(to: point(10.7, 9.4))
        } else {
            path.move(to: point(8, 3.3))
            path.addLine(to: point(8, 12.7))
            path.move(to: point(8, 3.3))
            path.addLine(to: point(5.3, 6))
            path.move(to: point(8, 3.3))
            path.addLine(to: point(10.7, 6))
        }
        return path
    }

    func drawSmartDraw(in rect: CGRect) {
        let bounds = CGRect(
            x: rect.midX - 8,
            y: rect.midY - 8,
            width: 16,
            height: 16
        )
        NSImage(
            systemSymbolName: "wand.and.stars",
            accessibilityDescription: "Smart Draw"
        )?
            .withSymbolConfiguration(
                NSImage.SymbolConfiguration(pointSize: 16, weight: .regular)
            )?
            .draw(in: bounds)
    }

    func drawPressure(_ option: DrawingInspectorPressureOption, in rect: CGRect) {
        switch option {
        case .constant:
            let path = NSBezierPath()
            path.lineWidth = 3
            path.lineCapStyle = .round
            path.move(to: CGPoint(x: rect.minX + 2, y: rect.midY))
            path.line(to: CGPoint(x: rect.maxX - 2, y: rect.midY))
            path.stroke()
        case .variable:
            let samples: [CGFloat] = [0.3, 0.55, 0.95, 0.45]
            let segmentWidth = (rect.width - 4) / CGFloat(samples.count)
            for (index, pressure) in samples.enumerated() {
                let path = NSBezierPath()
                path.lineWidth = max(1, pressure * 6)
                path.lineCapStyle = .round
                let startX = rect.minX + 2 + CGFloat(index) * segmentWidth
                path.move(to: CGPoint(x: startX, y: rect.midY))
                path.line(to: CGPoint(x: startX + segmentWidth + 0.5, y: rect.midY))
                path.stroke()
            }
        }
    }

    func drawEdges(_ edgeStyle: AnnotationEdgeStyle, in rect: CGRect) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        let geometry = Self.edgePreviewGeometry(edgeStyle, in: rect)
        context.saveGState()
        context.setStrokeColor(NSColor.labelColor.cgColor)
        context.setLineWidth(1.8)
        context.setLineCap(.round)
        context.setLineJoin(.round)
        context.addPath(geometry.solidPath)
        context.strokePath()
        context.setLineDash(phase: 0, lengths: [0.5, 3])
        context.addPath(geometry.dottedPath)
        context.strokePath()
        context.restoreGState()
    }

    static func edgePreviewGeometry(
        _ edgeStyle: AnnotationEdgeStyle,
        in rect: CGRect
    ) -> DrawingInspectorEdgePreviewGeometry {
        let bounds = CGRect(
            x: rect.midX - 8,
            y: rect.midY - 8,
            width: 16,
            height: 16
        )
        let solid = CGMutablePath()
        solid.move(to: CGPoint(x: bounds.maxX, y: bounds.minY))
        switch edgeStyle {
        case .sharp:
            solid.addLine(to: CGPoint(x: bounds.minX, y: bounds.minY))
            solid.addLine(to: CGPoint(x: bounds.minX, y: bounds.maxY))
        case .round:
            solid.addQuadCurve(
                to: CGPoint(x: bounds.minX, y: bounds.maxY),
                control: CGPoint(x: bounds.minX, y: bounds.minY)
            )
        }
        let dotted = CGMutablePath()
        dotted.move(to: CGPoint(x: bounds.maxX, y: bounds.minY))
        dotted.addLine(to: CGPoint(x: bounds.maxX, y: bounds.maxY))
        dotted.addLine(to: CGPoint(x: bounds.minX, y: bounds.maxY))
        return DrawingInspectorEdgePreviewGeometry(
            bounds: bounds,
            solidPath: solid,
            dottedPath: dotted
        )
    }

    func drawLinearRoute(_ route: AnnotationLinearRoute, in rect: CGRect) {
        drawCGPath(
            AnnotationGeometry.linearPath(Self.linearRouteGeometry(route, in: rect)),
            lineWidth: 2
        )
    }

    static func linearRouteGeometry(
        _ route: AnnotationLinearRoute,
        in rect: CGRect
    ) -> AnnotationLinearGeometry {
        let start = CGPoint(x: rect.minX + 2, y: rect.maxY - 5)
        let end = CGPoint(x: rect.maxX - 2, y: rect.minY + 5)
        let points: [CGPoint]
        let bezierControls: [AnnotationBezierControl]
        switch route {
        case .straight:
            points = [start, end]
            bezierControls = []
        case .curved:
            points = [start, end]
            bezierControls = [
                AnnotationBezierControl(
                    start: CGPoint(
                        x: rect.minX + rect.width * 0.22,
                        y: rect.minY + 2
                    ),
                    end: CGPoint(
                        x: rect.maxX - rect.width * 0.22,
                        y: rect.minY + 2
                    )
                )
            ]
        }
        return AnnotationLinearGeometry(
            points: points,
            route: route,
            startArrowhead: .none,
            endArrowhead: .none,
            startBinding: nil,
            endBinding: nil,
            bezierControls: bezierControls
        )
    }

    func drawArrowhead(
        _ arrowhead: AnnotationArrowhead,
        pointsRight: Bool,
        size: AnnotationArrowheadSize = .small,
        in rect: CGRect
    ) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        let preview = Self.arrowheadGeometry(
            arrowhead,
            pointsRight: pointsRight,
            size: size,
            in: rect
        )
        let shaft = AnnotationGeometry.linearShaftGeometry(preview.linear, strokeWidth: 1.8)
        let shaftPath = AnnotationGeometry.linearPath(shaft)
        let arrowheadPath = AnnotationGeometry.arrowheadPath(
            arrowhead,
            tip: preview.tip,
            adjacent: preview.adjacent,
            strokeWidth: 1.8,
            size: preview.linear.arrowheadSize
        )
        var drawingBounds = shaftPath.boundingBoxOfPath
        if let arrowheadPath {
            drawingBounds = drawingBounds.union(arrowheadPath.boundingBoxOfPath)
        }
        drawingBounds = drawingBounds.insetBy(dx: -0.9, dy: -0.9)
        let targetBounds = rect.insetBy(dx: 3, dy: 3)
        let previewScale = min(
            1,
            min(
                targetBounds.width / max(drawingBounds.width, 0.001),
                targetBounds.height / max(drawingBounds.height, 0.001)
            )
        )
        context.saveGState()
        context.translateBy(x: targetBounds.midX, y: targetBounds.midY)
        context.scaleBy(x: previewScale, y: previewScale)
        context.translateBy(x: -drawingBounds.midX, y: -drawingBounds.midY)
        context.setStrokeColor(NSColor.labelColor.cgColor)
        context.setFillColor(NSColor.labelColor.cgColor)
        context.setLineWidth(1.8)
        context.setLineCap(.round)
        context.setLineJoin(.round)
        context.addPath(shaftPath)
        context.strokePath()
        if let arrowheadPath {
            context.addPath(arrowheadPath)
            arrowhead.isFilled ? context.fillPath() : context.strokePath()
        }
        context.restoreGState()
    }

    static func arrowheadGeometry(
        _ arrowhead: AnnotationArrowhead,
        pointsRight: Bool,
        size: AnnotationArrowheadSize = .small,
        in rect: CGRect
    ) -> DrawingInspectorArrowheadPreviewGeometry {
        let start = CGPoint(x: rect.minX + 2, y: rect.midY)
        let end = CGPoint(x: rect.maxX - 2, y: rect.midY)
        let linear = AnnotationLinearGeometry(
            points: [start, end],
            route: .straight,
            startArrowhead: pointsRight ? .none : arrowhead,
            endArrowhead: pointsRight ? arrowhead : .none,
            arrowheadSize: size,
            startBinding: nil,
            endBinding: nil
        )
        return DrawingInspectorArrowheadPreviewGeometry(
            linear: linear,
            tip: pointsRight ? end : start,
            adjacent: pointsRight ? start : end
        )
    }

    func drawTextFont(
        _ preset: AnnotationTextFontPreset,
        customFontName: String?,
        in rect: CGRect
    ) {
        let storageName = preset.storageFontName(typeSettingName: customFontName ?? "")
        let font = AnnotationController.typingFont(named: storageName, size: 18)
        drawCenteredText("A", font: font, in: rect)
    }

    func drawTextAlignment(_ alignment: AnnotationTextAlignment, in rect: CGRect) {
        let widths: [CGFloat] = [22, 15, 19]
        let x: (CGFloat) -> CGFloat = { width in
            switch alignment {
            case .left: rect.minX + 3
            case .center: rect.midX - width / 2
            case .right: rect.maxX - width - 3
            }
        }
        for (index, width) in widths.enumerated() {
            let y = rect.minY + 7 + CGFloat(index) * 7
            let line = NSBezierPath()
            line.lineWidth = 2
            line.lineCapStyle = .round
            line.move(to: CGPoint(x: x(width), y: y))
            line.line(to: CGPoint(x: x(width) + width, y: y))
            line.stroke()
        }
    }

    func drawSymbol(_ symbolName: String, in rect: CGRect) {
        guard let symbol = NSImage(
            systemSymbolName: symbolName,
            accessibilityDescription: nil
        )?.withSymbolConfiguration(
            NSImage.SymbolConfiguration(pointSize: 18, weight: .medium)
        ) else {
            return
        }
        symbol.draw(
            in: CGRect(
                x: rect.midX - 10,
                y: rect.midY - 10,
                width: 20,
                height: 20
            )
        )
    }

    func drawCenteredText(_ text: String, font: NSFont, in rect: CGRect) {
        let attributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: NSColor.labelColor
        ]
        let size = NSString(string: text).size(withAttributes: attributes)
        NSString(string: text).draw(
            at: CGPoint(x: rect.midX - size.width / 2, y: rect.midY - size.height / 2),
            withAttributes: attributes
        )
    }

    func drawCGPath(_ path: CGPath, lineWidth: CGFloat) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        context.saveGState()
        context.setStrokeColor(NSColor.labelColor.cgColor)
        context.setLineWidth(lineWidth)
        context.setLineCap(.round)
        context.setLineJoin(.round)
        context.addPath(path)
        context.strokePath()
        context.restoreGState()
    }
}
