import AppKit

@MainActor
final class DrawingPropertiesController: NSViewController {
    private let commandSink: (AppCommand) -> Void
    private let colorPickerCoordinator: DrawingColorPickerCoordinator
    private var latestState: DrawingToolbarState?
    private var isUpdating = false
    private var arrangedSections: [DrawingInspectorSection]?
    private var arrangedWidth: CGFloat?
    private var sections: [DrawingInspectorSection: NSStackView] = [:]
    private var sectionWidthConstraints: [DrawingInspectorSection: NSLayoutConstraint] = [:]
    private var compactableHorizontalStacks: [NSStackView] = []
    private var currentSectionLayout =
        DrawingInspectorSectionMatrix.DrawingToolbarHorizontalSectionLayout(
            rows: [],
            rowWidths: [],
            documentWidth: 1
        )
    private var availableHorizontalWidth =
        DrawingInspectorVisualMetrics.attachedMaximumWidth
            - DrawingInspectorVisualMetrics.attachedHorizontalChrome

    private let emptyStateLabel = NSTextField(
        wrappingLabelWithString: "Select an annotation to inspect its properties."
    )
    private let strokeSwatches = DrawingMixedIndicatorStackView()
    private let backgroundSwatches = DrawingMixedIndicatorStackView()
    private let strokeColorWell = DrawingContinuousColorWell()
    private let backgroundColorWell = DrawingContinuousColorWell()

    private let fillPalette = DrawingInspectorPaletteControl(
        items: DrawingInspectorControlMapping.fillStyles.map {
            DrawingInspectorPaletteItem(
                value: $0,
                label: $0.displayName,
                preview: .fillStyle($0)
            )
        }
    )
    private let widthPalette = DrawingInspectorPaletteControl(
        items: zip(
            DrawingInspectorControlMapping.strokeWidths,
            ["Thin", "Medium", "Bold"]
        ).map {
            DrawingInspectorPaletteItem(
                value: $0.0,
                label: $0.1,
                preview: .strokeWidth($0.0)
            )
        }
    )
    private let strokeStylePalette = DrawingInspectorPaletteControl(
        items: DrawingInspectorControlMapping.strokePatterns.map {
            DrawingInspectorPaletteItem(
                value: $0,
                label: $0.displayName,
                preview: .strokePattern($0)
            )
        }
    )
    private let sloppinessPalette = DrawingInspectorPaletteControl(
        items: DrawingInspectorControlMapping.sloppiness.map {
            DrawingInspectorPaletteItem(
                value: $0,
                label: $0.displayName,
                preview: .sloppiness($0)
            )
        }
    )
    private let pressurePalette = DrawingInspectorPaletteControl(
        items: DrawingInspectorControlMapping.pressureOptions.map {
            DrawingInspectorPaletteItem(
                value: $0,
                label: $0.displayName,
                preview: .pressure($0)
            )
        }
    )
    private let edgePalette = DrawingInspectorPaletteControl(
        items: DrawingInspectorControlMapping.edgeStyles.map {
            DrawingInspectorPaletteItem(
                value: $0,
                label: $0.displayName,
                preview: .edges($0)
            )
        }
    )
    private let routePalette = DrawingInspectorPaletteControl(
        items: zip(
            DrawingInspectorControlMapping.linearRoutes,
            ["Sharp arrow (straight)", "Curved arrow"]
        ).map {
            DrawingInspectorPaletteItem(
                value: $0.0,
                label: $0.1,
                preview: .linearRoute($0.0)
            )
        }
    )
    private let startArrowheadPicker = DrawingInspectorArrowheadPicker(
        label: "Start arrowhead",
        pointsRight: false
    )
    private let endArrowheadPicker = DrawingInspectorArrowheadPicker(
        label: "End arrowhead",
        pointsRight: true
    )
    private let arrowheadSizePalette = DrawingInspectorPaletteControl(
        items: zip(
            DrawingInspectorControlMapping.arrowheadSizes,
            ["S", "M", "L"]
        ).map {
            DrawingInspectorPaletteItem(
                value: $0.0,
                label: $0.0.displayName,
                preview: .arrowheadSize($0.0)
            )
        }
    )
    private let smartDrawButton = DrawingInspectorActionButton(
        preview: .smartDraw,
        label: "Smart Draw: Off"
    )
    private let textFontPalette = DrawingInspectorPaletteControl(
        items: zip(
            DrawingInspectorControlMapping.textFontPresets,
            ["Hand-drawn", "Normal", "Code"]
        ).map {
            DrawingInspectorPaletteItem(
                value: $0.0,
                label: $0.1,
                preview: .textFont($0.0, customFontName: nil)
            )
        }
    )
    private let textFontPicker = DrawingInspectorFontPicker()
    private let textSizePalette = DrawingInspectorPaletteControl(
        items: zip(
            zip(
                DrawingInspectorControlMapping.textSizes,
                ["Small", "Medium", "Large", "Very large"]
            ),
            ["S", "M", "L", "XL"]
        ).map {
            DrawingInspectorPaletteItem(
                value: $0.0.0,
                label: $0.0.1,
                preview: .textSize($0.1)
            )
        }
    )
    private let textAlignmentPalette = DrawingInspectorPaletteControl(
        items: zip(
            DrawingInspectorControlMapping.textAlignments,
            ["Left", "Center", "Right"]
        ).map {
            DrawingInspectorPaletteItem(
                value: $0.0,
                label: $0.1,
                preview: .textAlignment($0.0)
            )
        }
    )

    private let opacitySlider = DrawingContinuousSlider(
        value: 1,
        minValue: 0.05,
        maxValue: 1,
        target: nil,
        action: nil
    )
    private let opacityLabel = NSTextField(labelWithString: "")

    private let arrangeButtons = NSStackView()
    private let sendToBackButton = DrawingInspectorActionButton(
        preview: .layer(.sendToBack),
        label: DrawingInspectorControlMapping.layerActions[0].label,
        toolTip: DrawingInspectorControlMapping.layerActions[0].toolTip
    )
    private let sendBackwardButton = DrawingInspectorActionButton(
        preview: .layer(.sendBackward),
        label: DrawingInspectorControlMapping.layerActions[1].label,
        toolTip: DrawingInspectorControlMapping.layerActions[1].toolTip
    )
    private let bringForwardButton = DrawingInspectorActionButton(
        preview: .layer(.bringForward),
        label: DrawingInspectorControlMapping.layerActions[2].label,
        toolTip: DrawingInspectorControlMapping.layerActions[2].toolTip
    )
    private let bringToFrontButton = DrawingInspectorActionButton(
        preview: .layer(.bringToFront),
        label: DrawingInspectorControlMapping.layerActions[3].label,
        toolTip: DrawingInspectorControlMapping.layerActions[3].toolTip
    )
    init(
        commandSink: @escaping (AppCommand) -> Void,
        colorPanelActivityChanged: @escaping (Bool) -> Void,
        popoverActivityChanged: @escaping (Bool) -> Void = { _ in }
    ) {
        self.commandSink = commandSink
        colorPickerCoordinator = DrawingColorPickerCoordinator(
            onBeginTransaction: {
                commandSink(.beginContinuousStyleEdit(.colorPicker))
            },
            onEndTransaction: {
                commandSink(.endContinuousStyleEdit(.colorPicker))
            },
            onActivityChanged: colorPanelActivityChanged
        )
        startArrowheadPicker.onPopoverActivityChanged = popoverActivityChanged
        endArrowheadPicker.onPopoverActivityChanged = popoverActivityChanged
        super.init(nibName: nil, bundle: nil)
        preferredContentSize = CGSize(
            width: DrawingInspectorVisualMetrics.contentWidth,
            height: 1
        )
        configureControlActions()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func loadView() {
        let root = DrawingInspectorRootStackView()
        root.orientation = .vertical
        root.alignment = .leading
        root.spacing = DrawingInspectorVisualMetrics.sectionSpacing
        root.detachesHiddenViews = true
        root.edgeInsets = NSEdgeInsets(top: 0, left: 0, bottom: 0, right: 0)
        root.translatesAutoresizingMaskIntoConstraints = true
        root.frame = CGRect(
            x: 0,
            y: 0,
            width: DrawingInspectorVisualMetrics.contentWidth,
            height: 1
        )
        view = root

        registerCompactableHorizontalStacks()
        configureSections(in: root)
        emptyStateLabel.textColor = .secondaryLabelColor
        emptyStateLabel.maximumNumberOfLines = 3
        emptyStateLabel.preferredMaxLayoutWidth =
            DrawingInspectorVisualMetrics.contentWidth - 16
        root.addArrangedSubview(emptyStateLabel)

        if let latestState {
            update(state: latestState)
        }
    }

    func update(state: DrawingToolbarState) {
        latestState = state
        guard isViewLoaded else { return }
        isUpdating = true
        defer {
            isUpdating = false
            updateSectionLayoutIfNeeded()
        }

        let visibleSections = Set(state.visibleInspectorSections)
        for (section, sectionView) in sections {
            sectionView.isHidden = !visibleSections.contains(section)
        }
        emptyStateLabel.isHidden = !visibleSections.isEmpty
        strokeColorWell.setChannel(
            visibleSections.contains(.textFont) ? .text : .stroke
        )
        if let activeChannel = colorPickerCoordinator.stateSnapshot.activeChannel {
            let remainsAvailable = switch activeChannel {
            case .stroke, .text:
                visibleSections.contains(.strokeColor)
            case .background:
                visibleSections.contains(.background)
            }
            if !remainsAvailable {
                colorPickerCoordinator.dismiss()
            }
        }
        updateStrokePalette(isHighlighter: state.showsHighlighterBehavior)

        updateSwatches(
            strokeSwatches,
            value: state.strokeColor,
            previewOpacity: state.strokePreviewOpacity
        )
        updateColorWell(
            strokeColorWell,
            value: state.strokeColor,
            previewOpacity: state.strokePreviewOpacity,
            isAvailable: visibleSections.contains(.strokeColor)
        )
        updateBackgroundSwatches(
            backgroundSwatches,
            color: state.fillColor,
            fillStyle: state.fillStyle,
            previewOpacity: state.opacity
        )
        updateColorWell(
            backgroundColorWell,
            value: state.fillColor,
            previewOpacity: state.opacity,
            isAvailable: visibleSections.contains(.background)
        )

        fillPalette.update(state.fillStyle)
        updateStrokeWidthPalette(state.strokeWidthOptions)
        widthPalette.update(state.strokeWidth)
        strokeStylePalette.update(state.strokePattern)
        sloppinessPalette.update(state.sloppiness)
        pressurePalette.update(state.pressureOption)
        edgePalette.update(state.edgeStyle)
        routePalette.update(state.linearRoute)
        startArrowheadPicker.update(
            state.startArrowhead,
            size: state.arrowheadSize.value ?? .small,
            appliesToEditableOnly: state.arrowheadChangesApplyToEditableOnly
        )
        endArrowheadPicker.update(
            state.endArrowhead,
            size: state.arrowheadSize.value ?? .small,
            appliesToEditableOnly: state.arrowheadChangesApplyToEditableOnly
        )
        arrowheadSizePalette.update(state.arrowheadSize)
        smartDrawButton.isSelected = state.smartDrawEnabled
        smartDrawButton.isEnabled = state.supportsSmartDraw
        smartDrawButton.update(
            preview: .smartDraw,
            label: state.smartDrawEnabled
                ? "Smart Draw: On"
                : "Smart Draw: Off"
        )
        textFontPalette.update(state.textFontPreset)
        let selectedFontName = state.textFontPreset.value == .typeSetting
            ? state.textFontName.value ?? state.typeSettingFontName
            : state.typeSettingFontName
        textFontPicker.update(
            fontName: selectedFontName,
            preset: state.textFontPreset
        )
        textSizePalette.update(state.textFontSize)
        textAlignmentPalette.update(state.textAlignment)

        updateOpacity(slider: opacitySlider, label: opacityLabel, value: state.opacity)

        for case let button as NSButton in arrangeButtons.arrangedSubviews {
            button.isEnabled = state.canDeleteSelection
        }
    }

    func dismissColorPanel() {
        colorPickerCoordinator.dismiss()
    }

    func dismissTransientUI() {
        colorPickerCoordinator.dismiss()
        startArrowheadPicker.dismissPalette()
        endArrowheadPicker.dismissPalette()
    }

    func setAvailableHorizontalWidth(_ availableWidth: CGFloat) {
        let width = max(1, availableWidth)
        guard self.availableHorizontalWidth != width else { return }
        self.availableHorizontalWidth = width
        guard isViewLoaded else { return }
        updateSectionLayoutIfNeeded()
    }

    var colorPickerStateForTesting: DrawingColorPickerCoordinatorState {
        colorPickerCoordinator.stateSnapshot
    }

    var colorPickerCoordinatorIdentifierForTesting: ObjectIdentifier {
        ObjectIdentifier(colorPickerCoordinator)
    }

    var startArrowheadPickerForTesting: DrawingInspectorArrowheadPicker {
        startArrowheadPicker
    }

    var endArrowheadPickerForTesting: DrawingInspectorArrowheadPicker {
        endArrowheadPicker
    }

    func visibleSectionFramesForTesting() -> [DrawingInspectorSection: CGRect] {
        _ = view
        updatePreferredContentSize()
        return sections.reduce(into: [:]) { result, entry in
            if !entry.value.isHidden {
                result[entry.key] = entry.value.convert(
                    entry.value.bounds,
                    to: view
                )
            }
        }
    }

    var sectionLayoutForTesting:
        DrawingInspectorSectionMatrix.DrawingToolbarHorizontalSectionLayout {
        _ = view
        return currentSectionLayout
    }

    private func configureControlActions() {
        fillPalette.onSelect = { [weak self] in self?.commandSink(.setFillStyle($0)) }
        widthPalette.onSelect = { [weak self] in self?.commandSink(.setStrokeWidth($0)) }
        strokeStylePalette.onSelect = {
            [weak self] in self?.commandSink(.setStrokePattern($0))
        }
        sloppinessPalette.onSelect = { [weak self] in self?.commandSink(.setSloppiness($0)) }
        pressurePalette.onSelect = { [weak self] option in
            guard let self else { return }
            let mode: AnnotationPressureMode = option == .constant
                ? .fixed
                : latestState?.preferredVariablePressureMode ?? .simulated
            commandSink(.setPressureMode(mode))
        }
        edgePalette.onSelect = { [weak self] in self?.commandSink(.setEdgeStyle($0)) }
        routePalette.onSelect = { [weak self] in self?.commandSink(.setLinearRoute($0)) }
        startArrowheadPicker.onSelect = {
            [weak self] in self?.commandSink(.setLinearStartArrowhead($0))
        }
        endArrowheadPicker.onSelect = {
            [weak self] in self?.commandSink(.setLinearEndArrowhead($0))
        }
        arrowheadSizePalette.onSelect = {
            [weak self] in self?.commandSink(.setLinearArrowheadSize($0))
        }
        smartDrawButton.handler = { [weak self] in
            guard let self, let latestState else { return }
            commandSink(.setSmartDrawEnabled(!latestState.smartDrawEnabled))
        }
        textFontPalette.onSelect = {
            [weak self] in self?.commandSink(.setTextFontPreset($0))
        }
        textFontPicker.onSelect = {
            [weak self] in self?.commandSink(.setTextFontName($0))
        }
        textSizePalette.onSelect = { [weak self] in self?.commandSink(.setTextFontSize($0)) }
        textAlignmentPalette.onSelect = {
            [weak self] in self?.commandSink(.setTextAlignment($0))
        }

        sendToBackButton.handler = {
            [weak self] in self?.commandSink(.arrangeSelection(.sendToBack))
        }
        sendBackwardButton.handler = {
            [weak self] in self?.commandSink(.arrangeSelection(.sendBackward))
        }
        bringForwardButton.handler = {
            [weak self] in self?.commandSink(.arrangeSelection(.bringForward))
        }
        bringToFrontButton.handler = {
            [weak self] in self?.commandSink(.arrangeSelection(.bringToFront))
        }
    }

    private func configureSections(in root: NSStackView) {
        configureColorRow(
            swatches: strokeSwatches,
            colorWell: strokeColorWell,
            roleLabel: "Stroke",
            channel: .stroke,
            values: DrawingInspectorControlMapping.strokeColors.map {
                .palette($0)
            },
            action: #selector(setStrokePreset(_:)),
            colorWellAction: #selector(setStrokeColor(_:))
        )
        addSection(.strokeColor, title: DrawingInspectorSection.strokeColor.title, views: [
            colorRow(strokeSwatches, strokeColorWell)
        ], to: root)

        configureColorRow(
            swatches: backgroundSwatches,
            colorWell: backgroundColorWell,
            roleLabel: "Background",
            channel: .background,
            values: [.transparent]
                + DrawingInspectorControlMapping.backgroundColors.map {
                    .palette($0)
                },
            action: #selector(setBackgroundPreset(_:)),
            colorWellAction: #selector(setBackgroundColor(_:))
        )
        addSection(.background, title: DrawingInspectorSection.background.title, views: [
            colorRow(backgroundSwatches, backgroundColorWell)
        ], to: root)
        addSection(.fill, title: DrawingInspectorSection.fill.title, views: [fillPalette], to: root)
        addSection(
            .strokeWidth,
            title: DrawingInspectorSection.strokeWidth.title,
            views: [widthPalette],
            to: root
        )
        addSection(
            .strokeStyle,
            title: DrawingInspectorSection.strokeStyle.title,
            views: [strokeStylePalette],
            to: root
        )
        addSection(
            .sloppiness,
            title: DrawingInspectorSection.sloppiness.title,
            views: [sloppinessPalette],
            to: root
        )
        addSection(
            .smartDraw,
            title: DrawingInspectorSection.smartDraw.title,
            views: [smartDrawButton],
            to: root
        )
        addSection(
            .pressure,
            title: DrawingInspectorSection.pressure.title,
            views: [pressurePalette],
            to: root
        )
        addSection(
            .edges,
            title: DrawingInspectorSection.edges.title,
            views: [edgePalette],
            to: root
        )
        addSection(
            .arrowType,
            title: DrawingInspectorSection.arrowType.title,
            views: [routePalette],
            to: root
        )
        addSection(.arrowheads, title: DrawingInspectorSection.arrowheads.title, views: [
            horizontalRow(startArrowheadPicker, endArrowheadPicker)
        ], to: root)
        addSection(
            .arrowheadSize,
            title: DrawingInspectorSection.arrowheadSize.title,
            views: [arrowheadSizePalette],
            to: root
        )

        addSection(
            .textFont,
            title: DrawingInspectorSection.textFont.title,
            views: [horizontalRow(textFontPalette, textFontPicker)],
            to: root
        )
        addSection(
            .textSize,
            title: DrawingInspectorSection.textSize.title,
            views: [textSizePalette],
            to: root
        )
        addSection(
            .textAlignment,
            title: DrawingInspectorSection.textAlignment.title,
            views: [textAlignmentPalette],
            to: root
        )

        configureOpacityControls(
            slider: opacitySlider,
            label: opacityLabel,
            accessibilityLabel: "Opacity",
            action: #selector(setOpacity(_:))
        )
        addSection(.opacity, title: DrawingInspectorSection.opacity.title, views: [
            horizontalRow(opacitySlider, opacityLabel)
        ], to: root)

        configureButtonRow(
            arrangeButtons,
            buttons: [
                sendToBackButton, sendBackwardButton, bringForwardButton, bringToFrontButton
            ]
        )
        addSection(
            .layers,
            title: DrawingInspectorSection.layers.title,
            views: [arrangeButtons],
            to: root
        )
    }

    private func registerCompactableHorizontalStacks() {
        compactableHorizontalStacks = [
            strokeSwatches,
            backgroundSwatches,
            fillPalette,
            widthPalette,
            strokeStylePalette,
            sloppinessPalette,
            pressurePalette,
            edgePalette,
            routePalette,
            arrowheadSizePalette,
            textFontPalette,
            textSizePalette,
            textAlignmentPalette,
            arrangeButtons
        ]
    }

    private func addSection(
        _ section: DrawingInspectorSection,
        title: String,
        views: [NSView],
        to root: NSStackView
    ) {
        let container = NSStackView()
        container.orientation = .vertical
        container.alignment = .leading
        container.spacing = 7
        container.detachesHiddenViews = true
        container.addArrangedSubview(sectionTitle(title))
        views.forEach(container.addArrangedSubview)
        sections[section] = container
        root.addArrangedSubview(container)
    }

    private func configureColorRow(
        swatches: NSStackView,
        colorWell: DrawingContinuousColorWell,
        roleLabel: String,
        channel: DrawingColorPickerChannel,
        values: [DrawingInspectorColorSwatch],
        action: Selector,
        colorWellAction: Selector
    ) {
        swatches.orientation = .horizontal
        swatches.spacing = DrawingInspectorVisualMetrics.swatchSpacing
        for (index, value) in values.enumerated() {
            let button = DrawingColorSwatchButton(value: value)
            button.tag = index
            button.target = self
            button.action = action
            button.setAccessibilityLabel("\(roleLabel) \(value.displayName)")
            swatches.addArrangedSubview(button)
        }

        colorWell.configure(
            channel: channel,
            coordinator: colorPickerCoordinator
        )
        colorWell.target = self
        colorWell.action = colorWellAction
        colorWell.colorWellStyle = .default
        colorWell.defaultToolTip = "Choose a custom \(roleLabel.lowercased()) color"
        colorWell.toolTip = colorWell.defaultToolTip
        colorWell.setAccessibilityLabel("Custom \(roleLabel.lowercased()) color")
        colorWell.widthAnchor.constraint(
            equalToConstant: DrawingInspectorVisualMetrics.customColorTileSide
        ).isActive = true
        colorWell.heightAnchor.constraint(
            equalToConstant: DrawingInspectorVisualMetrics.customColorTileSide
        ).isActive = true
    }

    private func updateStrokePalette(isHighlighter: Bool) {
        let colors = isHighlighter
            ? DrawingInspectorControlMapping.highlighterColors
            : DrawingInspectorControlMapping.strokeColors
        for (index, button) in strokeSwatches.arrangedSubviews
            .compactMap({ $0 as? DrawingColorSwatchButton })
            .enumerated() where colors.indices.contains(index) {
            let color = colors[index]
            button.update(value: .palette(color))
            button.setAccessibilityLabel("Stroke \(color.displayName)")
        }
    }

    private func updateStrokeWidthPalette(_ widths: [CGFloat]) {
        let labels = ["Thin", "Medium", "Bold"]
        widthPalette.replaceItems(
            zip(widths, labels).map {
                DrawingInspectorPaletteItem(
                    value: $0.0,
                    label: "\($0.1) (\(Self.widthLabel($0.0)))",
                    preview: .strokeWidth($0.0)
                )
            }
        )
    }

    private static func widthLabel(_ width: CGFloat) -> String {
        width.rounded() == width
            ? "\(Int(width)) pt"
            : String(format: "%.1f pt", Double(width))
    }

    private func configureOpacityControls(
        slider: DrawingContinuousSlider,
        label: NSTextField,
        accessibilityLabel: String,
        action: Selector
    ) {
        slider.target = self
        slider.action = action
        slider.isContinuous = true
        slider.onBeginTracking = { [weak self] in
            self?.commandSink(.beginContinuousStyleEdit(.opacitySlider))
        }
        slider.onEndTracking = { [weak self] in
            self?.commandSink(.endContinuousStyleEdit(.opacitySlider))
        }
        slider.setAccessibilityLabel(accessibilityLabel)
        slider.widthAnchor.constraint(equalToConstant: 128).isActive = true
        label.alignment = .right
        label.font = .monospacedDigitSystemFont(
            ofSize: NSFont.smallSystemFontSize,
            weight: .regular
        )
        label.widthAnchor.constraint(equalToConstant: 40).isActive = true
    }

    private func configureButtonRow(
        _ stack: NSStackView,
        buttons: [DrawingInspectorActionButton]
    ) {
        stack.orientation = .horizontal
        stack.spacing = DrawingInspectorVisualMetrics.tileSpacing
        buttons.forEach(stack.addArrangedSubview)
    }

    @objc private func setStrokePreset(_ sender: DrawingColorSwatchButton) {
        guard !isUpdating, case .palette(let color) = sender.value else { return }
        colorPickerCoordinator.synchronizeActiveColor(
            color.nsColor,
            from: strokeColorWell
        )
        commandSink(primaryColorCommand(.palette(color)))
    }

    @objc private func setBackgroundPreset(_ sender: DrawingColorSwatchButton) {
        guard !isUpdating else { return }
        switch sender.value {
        case .transparent:
            colorPickerCoordinator.synchronizeActiveColor(
                .clear,
                from: backgroundColorWell
            )
            commandSink(.setShapeBackground(nil))
        case .palette(let color):
            colorPickerCoordinator.synchronizeActiveColor(
                color.nsColor,
                from: backgroundColorWell
            )
            commandSink(.setShapeBackground(.palette(color)))
        }
    }

    @objc private func setStrokeColor(_ sender: NSColorWell) {
        guard !isUpdating else { return }
        let channel = (sender as? DrawingContinuousColorWell)?.pickerChannel ?? .stroke
        commandSink(colorCommand(Self.colorValue(sender.color), for: channel))
    }

    @objc private func setBackgroundColor(_ sender: NSColorWell) {
        guard !isUpdating else { return }
        commandSink(.setShapeBackground(Self.colorValue(sender.color)))
    }

    @objc private func setOpacity(_ sender: NSSlider) {
        guard !isUpdating else { return }
        commandSink(.setOpacity(CGFloat(sender.doubleValue)))
    }

    private func updateSwatches(
        _ stack: DrawingMixedIndicatorStackView,
        value: DrawingToolbarValue<AnnotationColorValue>,
        previewOpacity: DrawingToolbarValue<CGFloat>
    ) {
        let selected = value.value?.paletteColor
        let isMixed = value == .mixed
        stack.isMixed = isMixed
        for case let button as DrawingColorSwatchButton in stack.arrangedSubviews {
            button.isSelected = !isMixed && button.value.matches(selected)
            button.isMixed = false
            button.isEnabled = value != .unavailable
            button.previewOpacity = previewOpacity.value ?? 1
        }
    }

    private func updateBackgroundSwatches(
        _ stack: DrawingMixedIndicatorStackView,
        color: DrawingToolbarValue<AnnotationColorValue>,
        fillStyle: DrawingToolbarValue<AnnotationFillStyle>,
        previewOpacity: DrawingToolbarValue<CGFloat>
    ) {
        let isTransparent = fillStyle.value == AnnotationFillStyle.none
            || color.value?.isTransparent == true
        let selectedColor = isTransparent ? nil : color.value?.paletteColor
        let isMixed = color == .mixed || fillStyle == .mixed
        let isAvailable = color != .unavailable && fillStyle != .unavailable
        stack.isMixed = isMixed
        for case let button as DrawingColorSwatchButton in stack.arrangedSubviews {
            button.isEnabled = isAvailable
            button.previewOpacity = previewOpacity.value ?? 1
            switch button.value {
            case .transparent:
                button.isSelected = !isMixed && isTransparent
            case .palette:
                button.isSelected = !isMixed
                    && !isTransparent
                    && button.value.matches(selectedColor)
            }
            button.isMixed = false
        }
    }

    private func updateColorWell(
        _ colorWell: DrawingContinuousColorWell,
        value: DrawingToolbarValue<AnnotationColorValue>,
        previewOpacity: DrawingToolbarValue<CGFloat>,
        isAvailable: Bool = true
    ) {
        colorWell.previewOpacity = previewOpacity.value ?? 1
        guard isAvailable else {
            colorWell.color = .clear
            colorWell.isEnabled = false
            colorWell.toolTip = colorWell.defaultToolTip
            colorWell.isSelected = false
            colorWell.isMixed = false
            return
        }
        switch value {
        case .value(let color):
            colorWell.color = color.nsColor
            colorWell.isEnabled = true
            colorWell.toolTip = colorWell.defaultToolTip
            colorWell.isMixed = false
            colorWell.isSelected = colorWell.isActive
        case .mixed:
            colorWell.color = .clear
            colorWell.isEnabled = true
            colorWell.toolTip = "Multiple colors selected"
            colorWell.isSelected = colorWell.isActive
            colorWell.isMixed = false
        case .unavailable:
            colorWell.color = .clear
            colorWell.isEnabled = false
            colorWell.toolTip = colorWell.defaultToolTip
            colorWell.isSelected = false
            colorWell.isMixed = false
        }
        colorPickerCoordinator.synchronizeActiveColor(from: colorWell)
    }

    private func updateOpacity(
        slider: NSSlider,
        label: NSTextField,
        value: DrawingToolbarValue<CGFloat>
    ) {
        slider.doubleValue = Double(value.value ?? 1)
        slider.isEnabled = value != .unavailable
        label.stringValue = display(value: value) { "\(Int(($0 * 100).rounded()))%" }
    }

    private func updatePreferredContentSize() {
        guard let root = view as? NSStackView else { return }
        root.frame.size = CGSize(
            width: currentSectionLayout.documentWidth,
            height: 1
        )
        root.layoutSubtreeIfNeeded()
        let arrangedSubviews = root.arrangedSubviews.filter { !$0.isHidden }
        let fittingHeight = ceil(
            root.edgeInsets.top
                + root.edgeInsets.bottom
                + arrangedSubviews.reduce(CGFloat.zero) { result, subview in
                    subview.layoutSubtreeIfNeeded()
                    return result + subview.fittingSize.height
                }
                + CGFloat(max(0, arrangedSubviews.count - 1)) * root.spacing
        )
        root.frame.size.height = fittingHeight.isFinite
            ? min(max(fittingHeight, 1), 10_000)
            : 1
        root.layoutSubtreeIfNeeded()
        preferredContentSize = CGSize(
            width: currentSectionLayout.documentWidth,
            height: root.frame.height
        )
    }

    private func updateSectionLayoutIfNeeded() {
        let visibleSections = latestState?.visibleInspectorSections ?? []
        guard arrangedSections != visibleSections || arrangedWidth != availableHorizontalWidth else {
            return
        }
        rebuildSectionLayout()
        updatePreferredContentSize()
        arrangedSections = visibleSections
        arrangedWidth = availableHorizontalWidth
    }

    private func rebuildSectionLayout() {
        guard let root = view as? NSStackView else { return }
        for constraint in sectionWidthConstraints.values {
            constraint.isActive = false
        }
        sectionWidthConstraints.removeAll()
        for arrangedSubview in root.arrangedSubviews {
            root.removeArrangedSubview(arrangedSubview)
            arrangedSubview.removeFromSuperview()
        }

        let visibleSections = latestState?.visibleInspectorSections ?? []
        compactSectionContents(to: availableHorizontalWidth)
        root.orientation = .vertical
        root.alignment = .leading
        root.spacing = DrawingInspectorVisualMetrics.attachedRowSpacing
        root.edgeInsets = .init(top: 8, left: 0, bottom: 8, right: 0)
        let sectionWidths = measuredSectionWidths(for: visibleSections)
        currentSectionLayout = DrawingInspectorSectionMatrix
            .DrawingToolbarHorizontalSectionPacker.layout(
            sections: visibleSections,
            availableWidth: availableHorizontalWidth,
            sectionWidths: sectionWidths
        )
        for rowSections in currentSectionLayout.rows {
            let row = NSStackView()
            row.orientation = .horizontal
            row.alignment = .top
            row.spacing = DrawingInspectorVisualMetrics.attachedSectionSpacing
            for section in rowSections {
                guard let sectionView = sections[section] else { continue }
                sectionView.isHidden = false
                let constraint = sectionView.widthAnchor.constraint(
                    equalToConstant: min(
                        sectionWidths[section] ?? 1,
                        availableHorizontalWidth
                    )
                )
                constraint.isActive = true
                sectionWidthConstraints[section] = constraint
                row.addArrangedSubview(sectionView)
            }
            root.addArrangedSubview(row)
        }
        emptyStateLabel.isHidden = true
    }

    private func compactSectionContents(to availableWidth: CGFloat) {
        for stack in compactableHorizontalStacks {
            stack.orientation = .horizontal
            stack.alignment = .centerY
        }
        for stack in compactableHorizontalStacks {
            stack.layoutSubtreeIfNeeded()
            if ceil(stack.fittingSize.width) > availableWidth {
                stack.orientation = .vertical
                stack.alignment = .leading
            }
        }
    }

    private func measuredSectionWidths(
        for visibleSections: [DrawingInspectorSection]
    ) -> [DrawingInspectorSection: CGFloat] {
        Dictionary(
            uniqueKeysWithValues: visibleSections.compactMap { section in
                guard let sectionView = sections[section] else { return nil }
                sectionView.layoutSubtreeIfNeeded()
                return (section, max(1, ceil(sectionView.fittingSize.width)))
            }
        )
    }

    private func display<Value>(
        value: DrawingToolbarValue<Value>,
        formatter: (Value) -> String
    ) -> String {
        switch value {
        case .value(let value): formatter(value)
        case .mixed: "Mixed"
        case .unavailable: "—"
        }
    }

    private func sectionTitle(_ title: String) -> NSTextField {
        let label = NSTextField(labelWithString: title)
        label.font = .systemFont(ofSize: 11, weight: .semibold)
        label.textColor = .secondaryLabelColor
        label.lineBreakMode = .byWordWrapping
        label.maximumNumberOfLines = 2
        label.setContentHuggingPriority(.required, for: .vertical)
        label.setContentCompressionResistancePriority(.required, for: .vertical)
        label.heightAnchor.constraint(greaterThanOrEqualToConstant: 14).isActive = true
        return label
    }

    private func horizontalRow(_ views: NSView...) -> NSStackView {
        let row = NSStackView(views: views)
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 8
        row.detachesHiddenViews = true
        compactableHorizontalStacks.append(row)
        return row
    }

    private func colorRow(_ swatches: NSView, _ colorWell: NSView) -> NSStackView {
        let separator = DrawingColorPaletteDivider()
        separator.widthAnchor.constraint(equalToConstant: 1).isActive = true
        separator.heightAnchor.constraint(equalToConstant: 24).isActive = true
        let row = NSStackView(views: [swatches, separator, colorWell])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 8
        compactableHorizontalStacks.append(row)
        return row
    }

    private static func colorValue(_ color: NSColor) -> AnnotationColorValue {
        let converted = color.usingColorSpace(.sRGB) ?? color
        return .rgba(
            red: converted.redComponent,
            green: converted.greenComponent,
            blue: converted.blueComponent,
            alpha: converted.alphaComponent
        )
    }

    private func primaryColorCommand(_ color: AnnotationColorValue) -> AppCommand {
        colorCommand(color, for: strokeColorWell.pickerChannel)
    }

    private func colorCommand(
        _ color: AnnotationColorValue,
        for channel: DrawingColorPickerChannel
    ) -> AppCommand {
        switch channel {
        case .stroke:
            .setStrokeColor(color)
        case .background:
            .setShapeBackground(color)
        case .text:
            .setTextColor(color)
        }
    }

}

struct DrawingColorSwatchGeometry: Equatable {
    static let cornerRadius: CGFloat = 6
    static let ringCornerRadius: CGFloat = 7

    var bounds: CGRect

    var swatchRect: CGRect {
        bounds.insetBy(dx: 1.5, dy: 1.5)
    }

    var ringRect: CGRect {
        bounds.insetBy(dx: 0.5, dy: 0.5)
    }
}

struct DrawingCustomColorTileGeometry: Equatable {
    static let cornerRadius =
        DrawingInspectorVisualMetrics.customColorCornerRadius
    static let ringCornerRadius: CGFloat = 6

    var bounds: CGRect

    var swatchRect: CGRect {
        bounds.insetBy(dx: 0.5, dy: 0.5)
    }

    var ringRect: CGRect {
        bounds.insetBy(dx: 0.25, dy: 0.25)
    }
}

@MainActor
enum DrawingColorSwatchAppearance {
    static func isDark(_ appearance: NSAppearance?) -> Bool {
        appearance?.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
    }

    static func panelBackground(for appearance: NSAppearance?) -> NSColor {
        isDark(appearance)
            ? NSColor(srgbRed: 0.12, green: 0.12, blue: 0.15, alpha: 1)
            : NSColor(srgbRed: 0.98, green: 0.98, blue: 0.99, alpha: 1)
    }

    static func ringColor(
        isSelected: Bool,
        isHovered: Bool,
        appearance: NSAppearance?
    ) -> NSColor? {
        if isSelected {
            return isDark(appearance)
                ? NSColor(srgbRed: 0.66, green: 0.64, blue: 1, alpha: 1)
                : NSColor(srgbRed: 0.37, green: 0.35, blue: 0.84, alpha: 1)
        }
        if isHovered {
            return isDark(appearance)
                ? NSColor(srgbRed: 0.43, green: 0.41, blue: 0.65, alpha: 0.9)
                : NSColor(srgbRed: 0.82, green: 0.81, blue: 1, alpha: 0.9)
        }
        return nil
    }

    static func previewColor(
        _ value: AnnotationColorValue,
        opacity: CGFloat,
        appearance: NSAppearance?
    ) -> NSColor {
        let source: NSColor = switch value {
        case .palette(let color):
            color.resolvedNSColor(for: appearance)
        case .rgba:
            value.nsColor
        }
        return AnnotationColorResolver.compositedColor(
            source,
            opacity: opacity,
            over: panelBackground(for: appearance)
        )
    }
}

@MainActor
final class DrawingColorPaletteDivider: NSView {
    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        NSColor.separatorColor.withAlphaComponent(0.35).setFill()
        NSBezierPath(rect: bounds).fill()
    }
}

@MainActor
private final class DrawingContinuousSlider: NSSlider {
    var onBeginTracking: (() -> Void)?
    var onEndTracking: (() -> Void)?

    override func mouseDown(with event: NSEvent) {
        onBeginTracking?()
        defer { onEndTracking?() }
        super.mouseDown(with: event)
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        true
    }
}

enum DrawingColorPickerChannel: Equatable {
    case stroke
    case background
    case text
}

enum DrawingColorPickerActivation: Equatable {
    case started
    case switched
    case unchanged
}

struct DrawingColorPickerCoordinatorState: Equatable {
    private(set) var activeChannel: DrawingColorPickerChannel?
    private(set) var transactionActive = false

    mutating func activate(
        _ channel: DrawingColorPickerChannel
    ) -> DrawingColorPickerActivation {
        guard activeChannel != channel else { return .unchanged }
        let activation: DrawingColorPickerActivation =
            activeChannel == nil ? .started : .switched
        activeChannel = channel
        transactionActive = true
        return activation
    }

    mutating func deactivate(_ channel: DrawingColorPickerChannel) -> Bool {
        guard activeChannel == channel else { return false }
        return close()
    }

    mutating func close() -> Bool {
        guard transactionActive else {
            activeChannel = nil
            return false
        }
        activeChannel = nil
        transactionActive = false
        return true
    }
}

@MainActor
private struct DrawingSharedColorPanelState {
    let parent: NSWindow?
    let level: NSWindow.Level
    let sharingType: NSWindow.SharingType
    let isVisible: Bool
    let isContinuous: Bool
    let showsAlpha: Bool

    init(panel: NSColorPanel) {
        parent = panel.parent
        level = panel.level
        sharingType = panel.sharingType
        isVisible = panel.isVisible
        isContinuous = panel.isContinuous
        showsAlpha = panel.showsAlpha
    }

    func restore(_ panel: NSColorPanel, panelIsClosing: Bool) {
        panel.isContinuous = isContinuous
        panel.showsAlpha = showsAlpha
        if panel.parent !== parent {
            panel.parent?.removeChildWindow(panel)
            parent?.addChildWindow(panel, ordered: .above)
        }
        panel.level = level
        panel.sharingType = sharingType
        if isVisible {
            if panelIsClosing {
                DispatchQueue.main.async {
                    panel.orderFront(nil)
                }
            } else {
                panel.orderFront(nil)
            }
        } else if !panelIsClosing {
            panel.orderOut(nil)
        }
    }
}

private final class DrawingColorPanelObservers: @unchecked Sendable {
    let closeObserver: NSObjectProtocol
    let colorObserver: NSObjectProtocol

    init(
        closeObserver: NSObjectProtocol,
        colorObserver: NSObjectProtocol
    ) {
        self.closeObserver = closeObserver
        self.colorObserver = colorObserver
    }

    deinit {
        NotificationCenter.default.removeObserver(closeObserver)
        NotificationCenter.default.removeObserver(colorObserver)
    }
}

@MainActor
final class DrawingColorPickerCoordinator: NSObject {
    private struct PanelSession {
        let panel: NSColorPanel
        let previousState: DrawingSharedColorPanelState
    }

    private let onBeginTransaction: () -> Void
    private let onEndTransaction: () -> Void
    private let onActivityChanged: (Bool) -> Void
    private var state = DrawingColorPickerCoordinatorState()
    private weak var activeWell: DrawingContinuousColorWell?
    private var panelSession: PanelSession?
    private var panelObservers: DrawingColorPanelObservers?
    private var isSynchronizingPanelColor = false
    private var suppressesNextPanelNotification = false
    private var synchronizedPanelColor: NSColor?
    private var lastDispatchedPanelColor: NSColor?

    var stateSnapshot: DrawingColorPickerCoordinatorState {
        state
    }

    init(
        onBeginTransaction: @escaping () -> Void,
        onEndTransaction: @escaping () -> Void,
        onActivityChanged: @escaping (Bool) -> Void
    ) {
        self.onBeginTransaction = onBeginTransaction
        self.onEndTransaction = onEndTransaction
        self.onActivityChanged = onActivityChanged
        super.init()
    }

    fileprivate func prepareActivation(
        channel: DrawingColorPickerChannel,
        well: DrawingContinuousColorWell
    ) -> DrawingColorPickerActivation {
        let activation = state.activate(channel)
        if activeWell !== well {
            activeWell?.deactivateFromCoordinator()
            activeWell = well
            return activation == .unchanged ? .switched : activation
        }
        activeWell = well
        return activation
    }

    fileprivate func completeActivation(
        _ activation: DrawingColorPickerActivation,
        well: DrawingContinuousColorWell
    ) {
        guard activation == .started else { return }
        onBeginTransaction()
        onActivityChanged(true)
    }

    fileprivate func presentColorPanel(for well: DrawingContinuousColorWell) {
        let panel = NSColorPanel.shared
        if panelSession == nil {
            let previousState = DrawingSharedColorPanelState(panel: panel)
            let closeObserver = NotificationCenter.default.addObserver(
                forName: NSWindow.willCloseNotification,
                object: panel,
                queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.finishColorPanelSession(panelIsClosing: true)
                }
            }
            let colorObserver = NotificationCenter.default.addObserver(
                forName: NSColorPanel.colorDidChangeNotification,
                object: panel,
                queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.colorPanelColorDidChange(NSColorPanel.shared)
                }
            }
            panelSession = PanelSession(
                panel: panel,
                previousState: previousState
            )
            panelObservers = DrawingColorPanelObservers(
                closeObserver: closeObserver,
                colorObserver: colorObserver
            )
            panel.isContinuous = true
            panel.showsAlpha = true
            panel.sharingType = .none
        }

        if let ownerWindow = well.window {
            if panel.parent !== ownerWindow {
                panel.parent?.removeChildWindow(panel)
                ownerWindow.addChildWindow(panel, ordered: .above)
            }
            panel.level = NSWindow.Level(rawValue: ownerWindow.level.rawValue + 1)
        }
        synchronizePanelColor(well.color)
        panel.makeKeyAndOrderFront(nil)
    }

    fileprivate func switchChannel(
        to channel: DrawingColorPickerChannel,
        well: DrawingContinuousColorWell
    ) {
        guard activeWell === well else { return }
        _ = state.activate(channel)
        synchronizePanelColor(well.color)
    }

    fileprivate func synchronizeActiveColor(from well: DrawingContinuousColorWell) {
        synchronizeActiveColor(well.color, from: well)
    }

    fileprivate func synchronizeActiveColor(
        _ color: NSColor,
        from well: DrawingContinuousColorWell
    ) {
        guard activeWell === well, panelSession != nil else { return }
        synchronizePanelColor(color)
    }

    func dismiss() {
        guard state.transactionActive || panelSession != nil else { return }
        finishColorPanelSession(panelIsClosing: false)
    }

    private func colorPanelColorDidChange(_ panel: NSColorPanel) {
        guard !isSynchronizingPanelColor else { return }
        if suppressesNextPanelNotification {
            suppressesNextPanelNotification = false
            return
        }
        let color = panel.color
        if let synchronizedPanelColor,
           Self.colorsMatch(color, synchronizedPanelColor) {
            self.synchronizedPanelColor = nil
            return
        }
        synchronizedPanelColor = nil
        guard let activeWell,
              !Self.colorsMatch(color, lastDispatchedPanelColor) else {
            return
        }
        activeWell.color = color
        lastDispatchedPanelColor = color
        guard let action = activeWell.action else { return }
        _ = activeWell.sendAction(action, to: activeWell.target)
    }

    private func synchronizePanelColor(_ color: NSColor) {
        guard let panel = panelSession?.panel else { return }
        guard !Self.colorsMatch(panel.color, color) else {
            lastDispatchedPanelColor = panel.color
            synchronizedPanelColor = nil
            return
        }
        isSynchronizingPanelColor = true
        suppressesNextPanelNotification = true
        panel.color = color
        isSynchronizingPanelColor = false
        lastDispatchedPanelColor = panel.color
        synchronizedPanelColor = panel.color
        DispatchQueue.main.async { [weak self] in
            guard let self,
                  let synchronizedPanelColor = self.synchronizedPanelColor,
                  Self.colorsMatch(synchronizedPanelColor, color) else {
                return
            }
            self.synchronizedPanelColor = nil
            self.suppressesNextPanelNotification = false
        }
    }

    private static func colorsMatch(_ lhs: NSColor?, _ rhs: NSColor?) -> Bool {
        guard let lhs, let rhs else { return lhs == nil && rhs == nil }
        guard let left = lhs.usingColorSpace(.sRGB),
              let right = rhs.usingColorSpace(.sRGB) else {
            return lhs.isEqual(rhs)
        }
        return abs(left.redComponent - right.redComponent) < 0.000_001
            && abs(left.greenComponent - right.greenComponent) < 0.000_001
            && abs(left.blueComponent - right.blueComponent) < 0.000_001
            && abs(left.alphaComponent - right.alphaComponent) < 0.000_001
    }

    private func finishColorPanelSession(panelIsClosing: Bool) {
        if let panelSession {
            panelObservers = nil
            self.panelSession = nil
            panelSession.previousState.restore(
                panelSession.panel,
                panelIsClosing: panelIsClosing
            )
        }
        synchronizedPanelColor = nil
        lastDispatchedPanelColor = nil
        isSynchronizingPanelColor = false
        suppressesNextPanelNotification = false
        activeWell?.deactivateFromCoordinator()
        activeWell = nil
        guard state.close() else { return }
        onEndTransaction()
        onActivityChanged(false)
    }
}

@MainActor
private final class DrawingContinuousColorWell: NSColorWell {
    var defaultToolTip: String?
    var previewOpacity: CGFloat = 1 {
        didSet { needsDisplay = true }
    }
    var isSelected = false {
        didSet { updateAppearance() }
    }
    var isMixed = false {
        didSet { updateAppearance() }
    }
    private weak var coordinator: DrawingColorPickerCoordinator?
    private var channel: DrawingColorPickerChannel = .stroke
    private var activeChannel: DrawingColorPickerChannel?
    private var isPickerPresented = false
    private var trackingAreaReference: NSTrackingArea?
    private var isPointerInside = false
    private var isPressed = false
    var pickerChannel: DrawingColorPickerChannel { channel }
    override var isActive: Bool { isPickerPresented }
    override var alignmentRectInsets: NSEdgeInsets {
        NSEdgeInsets(top: 0, left: 0, bottom: 0, right: 0)
    }
    override var allowsVibrancy: Bool { false }
    override var mouseDownCanMoveWindow: Bool { false }

    private var resolvedDrawingAppearance: DrawingResolvedControlAppearance {
        DrawingControlAppearanceResolver.resolve(
            DrawingControlVisualState(
                isHovered: isPointerInside,
                isPressed: isPressed,
                isSelected: isSelected,
                isMixed: isMixed,
                isFocused: window?.firstResponder === self,
                isEnabled: isEnabled
            ),
            appearance: effectiveAppearance
        )
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        isBordered = false
        focusRingType = .none
        updateAppearance()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func configure(
        channel: DrawingColorPickerChannel,
        coordinator: DrawingColorPickerCoordinator
    ) {
        self.coordinator = coordinator
        setChannel(channel)
    }

    func setChannel(_ channel: DrawingColorPickerChannel) {
        self.channel = channel
        guard isActive else { return }
        activeChannel = channel
        coordinator?.switchChannel(to: channel, well: self)
    }

    override func activate(_ exclusive: Bool) {
        if !NSApp.isActive {
            NSApp.activate(ignoringOtherApps: true)
        }
        guard let coordinator else {
            return
        }
        let activation = coordinator.prepareActivation(
            channel: channel,
            well: self
        )
        if activation == .unchanged, isPickerPresented {
            return
        }
        activeChannel = channel
        isPickerPresented = true
        isSelected = true
        coordinator.presentColorPanel(for: self)
        coordinator.completeActivation(activation, well: self)
    }

    override func deactivate() {
        guard isPickerPresented else { return }
        coordinator?.dismiss()
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
        updateAppearance()
    }

    override func mouseExited(with event: NSEvent) {
        isPointerInside = false
        updateAppearance()
    }

    override func mouseDown(with event: NSEvent) {
        guard isEnabled, event.type == .leftMouseDown else { return }
        isPressed = true
        updateAppearance()
        defer {
            isPressed = false
            updateAppearance()
        }
        activate(true)
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateAppearance()
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        context.clear(bounds)
        NSGraphicsContext.saveGraphicsState()
        context.setAlpha(resolvedDrawingAppearance.contentOpacity)
        defer { NSGraphicsContext.restoreGraphicsState() }
        let geometry = DrawingCustomColorTileGeometry(bounds: bounds)
        if let ringColor = DrawingColorSwatchAppearance.ringColor(
            isSelected: isSelected,
            isHovered: isPointerInside,
            appearance: effectiveAppearance
        ) {
            let ring = NSBezierPath(
                roundedRect: geometry.ringRect,
                xRadius: DrawingCustomColorTileGeometry.ringCornerRadius,
                yRadius: DrawingCustomColorTileGeometry.ringCornerRadius
            )
            ring.lineWidth = 1
            ringColor.setStroke()
            ring.stroke()
        }
        let swatch = NSBezierPath(
            roundedRect: geometry.swatchRect,
            xRadius: DrawingCustomColorTileGeometry.cornerRadius,
            yRadius: DrawingCustomColorTileGeometry.cornerRadius
        )
        let panelBackground = DrawingColorSwatchAppearance.panelBackground(
            for: effectiveAppearance
        )
        panelBackground.setFill()
        swatch.fill()
        let convertedColor = color.usingColorSpace(.sRGB) ?? color
        DrawingColorSwatchAppearance.previewColor(
            .rgba(
                red: convertedColor.redComponent,
                green: convertedColor.greenComponent,
                blue: convertedColor.blueComponent,
                alpha: convertedColor.alphaComponent
            ),
            opacity: previewOpacity,
            appearance: effectiveAppearance
        ).setFill()
        swatch.fill()
        if isMixed {
            let mixed = NSBezierPath(
                roundedRect: CGRect(
                    x: bounds.midX - 5,
                    y: bounds.midY - 1,
                    width: 10,
                    height: 2
                ),
                xRadius: 1,
                yRadius: 1
            )
            NSColor.secondaryLabelColor.setFill()
            mixed.fill()
        }
    }

    fileprivate func deactivateFromCoordinator() {
        isPickerPresented = false
        activeChannel = nil
        isSelected = false
    }

    private func updateAppearance() {
        layer?.cornerRadius = DrawingCustomColorTileGeometry.cornerRadius
        layer?.borderWidth = 0
        layer?.backgroundColor = NSColor.clear.cgColor
        setAccessibilityValue(isMixed ? "Mixed" : (isSelected ? "Selected" : "Not selected"))
        needsDisplay = true
    }
}

private enum DrawingInspectorColorSwatch: Equatable {
    case transparent
    case palette(AnnotationColor)

    var displayName: String {
        switch self {
        case .transparent: "Transparent"
        case .palette(let color): color.displayName
        }
    }

    var paletteColor: AnnotationColor? {
        guard case .palette(let color) = self else { return nil }
        return color
    }

    func matches(_ color: AnnotationColor?) -> Bool {
        guard let color, let paletteColor else { return false }
        if paletteColor == color { return true }
        return switch paletteColor {
        case .strokeNeutral:
            color == .black
        case .strokeCoral:
            color == .red || color == .pink
        case .strokeGreen:
            color == .green
        case .strokeBlue:
            color == .blue
        case .strokeOrange:
            color == .orange
        case .backgroundRed:
            color == .pink || color == .red
        case .backgroundGreen:
            color == .green
        case .backgroundBlue:
            color == .blue
        case .backgroundYellow:
            color == .yellow
        default:
            false
        }
    }
}

@MainActor
private final class DrawingColorSwatchButton: DrawingAppearanceButton {
    private(set) var value: DrawingInspectorColorSwatch
    var previewOpacity: CGFloat = 1 {
        didSet { needsDisplay = true }
    }
    override var alignmentRectInsets: NSEdgeInsets {
        NSEdgeInsets(top: 0, left: 0, bottom: 0, right: 0)
    }
    override var allowsVibrancy: Bool { false }

    init(value: DrawingInspectorColorSwatch) {
        self.value = value
        super.init(frame: .zero)
        title = ""
        bezelStyle = .shadowlessSquare
        isBordered = false
        showsBorderOnlyWhileMouseInside = false
        focusRingType = .none
        refusesFirstResponder = true
        wantsLayer = true
        drawingCornerRadius = 8
        toolTip = value.displayName
        setAccessibilityLabel(value.displayName)
        widthAnchor.constraint(
            equalToConstant: DrawingInspectorVisualMetrics.colorTileSide
        ).isActive = true
        heightAnchor.constraint(
            equalToConstant: DrawingInspectorVisualMetrics.colorTileSide
        ).isActive = true
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func update(value: DrawingInspectorColorSwatch) {
        self.value = value
        toolTip = value.displayName
        setAccessibilityLabel(value.displayName)
        needsDisplay = true
    }

    override func refreshDrawingAppearance() {
        super.refreshDrawingAppearance()
        layer?.borderWidth = 0
        layer?.backgroundColor = NSColor.clear.cgColor
    }

    override func draw(_ dirtyRect: NSRect) {
        layer?.borderWidth = 0
        layer?.backgroundColor = NSColor.clear.cgColor
        let contentOpacity = resolvedDrawingAppearance.contentOpacity
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current?.cgContext.setAlpha(contentOpacity)
        defer { NSGraphicsContext.restoreGraphicsState() }
        let geometry = DrawingColorSwatchGeometry(bounds: bounds)
        if let ringColor = DrawingColorSwatchAppearance.ringColor(
            isSelected: isSelected,
            isHovered: isPointerInside,
            appearance: effectiveAppearance
        ) {
            let ring = NSBezierPath(
                roundedRect: geometry.ringRect,
                xRadius: DrawingColorSwatchGeometry.ringCornerRadius,
                yRadius: DrawingColorSwatchGeometry.ringCornerRadius
            )
            ring.lineWidth = 1
            ringColor.setStroke()
            ring.stroke()
        }
        let swatch = NSBezierPath(
            roundedRect: geometry.swatchRect,
            xRadius: DrawingColorSwatchGeometry.cornerRadius,
            yRadius: DrawingColorSwatchGeometry.cornerRadius
        )
        let panelBackground = DrawingColorSwatchAppearance.panelBackground(
            for: effectiveAppearance
        )
        switch value {
        case .transparent:
            drawTransparencyChecker(
                in: geometry.swatchRect,
                clip: swatch,
                appearance: effectiveAppearance
            )
        case .palette(let color):
            panelBackground.setFill()
            swatch.fill()
            DrawingColorSwatchAppearance.previewColor(
                .palette(color),
                opacity: previewOpacity,
                appearance: effectiveAppearance
            ).setFill()
            swatch.fill()
        }
    }

    private func drawTransparencyChecker(
        in rect: CGRect,
        clip: NSBezierPath,
        appearance: NSAppearance?
    ) {
        let isDark = DrawingColorSwatchAppearance.isDark(appearance)
        let colors = isDark
            ? (
                NSColor(srgbRed: 0.14, green: 0.14, blue: 0.17, alpha: 1),
                NSColor(srgbRed: 0.24, green: 0.24, blue: 0.29, alpha: 1)
            )
            : (
                NSColor(srgbRed: 0.86, green: 0.86, blue: 0.89, alpha: 1),
                NSColor.white
            )
        NSGraphicsContext.saveGraphicsState()
        clip.addClip()
        let cell: CGFloat = 5
        var row = 0
        var y = rect.minY
        while y < rect.maxY {
            var column = 0
            var x = rect.minX
            while x < rect.maxX {
                ((row + column).isMultiple(of: 2) ? colors.0 : colors.1).setFill()
                NSBezierPath(
                    rect: CGRect(
                        x: x,
                        y: y,
                        width: min(cell, rect.maxX - x),
                        height: min(cell, rect.maxY - y)
                    )
                ).fill()
                column += 1
                x += cell
            }
            row += 1
            y += cell
        }
        NSGraphicsContext.restoreGraphicsState()
    }
}

@MainActor
private final class DrawingInspectorRootStackView: NSStackView {
    override var isFlipped: Bool { true }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        true
    }
}
