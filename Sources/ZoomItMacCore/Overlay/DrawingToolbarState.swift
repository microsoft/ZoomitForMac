import AppKit

@MainActor
enum DrawingToolShortcuts {
    struct Metadata: Equatable {
        var tool: AnnotationTool
        var numericHint: String?
        var legacyHint: String?

        var keyboardHint: String? {
            let hints = [numericHint, legacyHint].compactMap { $0 }
            return hints.isEmpty ? nil : hints.joined(separator: ", ")
        }

        func toolTip(label: String) -> String {
            keyboardHint.map { "\(label) (\($0))" } ?? label
        }
    }

    static let toolbarMetadata: [Metadata] = [
        Metadata(tool: .hand, numericHint: nil, legacyHint: "Space"),
        Metadata(tool: .select, numericHint: "1", legacyHint: "V"),
        Metadata(tool: .rectangle, numericHint: "2", legacyHint: "Control-drag"),
        Metadata(tool: .diamond, numericHint: "3", legacyHint: nil),
        Metadata(tool: .ellipse, numericHint: "4", legacyHint: "Tab-drag"),
        Metadata(tool: .arrow, numericHint: "5", legacyHint: "A"),
        Metadata(tool: .line, numericHint: "6", legacyHint: "L"),
        Metadata(tool: .pen, numericHint: "7", legacyHint: "F"),
        Metadata(tool: .highlighter, numericHint: nil, legacyHint: "H"),
        Metadata(tool: .text, numericHint: "8", legacyHint: "T"),
        Metadata(tool: .eraser, numericHint: "0", legacyHint: "Shift-E")
    ]
    static let reservedNumericHints = ["9"]

    static func metadata(for tool: AnnotationTool) -> Metadata? {
        toolbarMetadata.first { $0.tool == tool }
    }

    enum DrawingToolbarGroup: Equatable {
        case hand
        case mainTools
        case overflow
    }

    enum DrawingToolbarStructure {
        static let orderedGroups: [DrawingToolbarGroup] = [
            .hand,
            .mainTools,
            .overflow
        ]
    }

    static func numericCommand(
        characters: String?,
        keyCode: UInt16,
        modifierFlags: NSEvent.ModifierFlags,
        isDrawingMode: Bool,
        isTyping: Bool
    ) -> AppCommand? {
        let excludedModifiers: NSEvent.ModifierFlags = [.command, .control, .option]
        guard isDrawingMode,
              !isTyping,
              modifierFlags.intersection(excludedModifiers).isEmpty,
              let character = numberRowCharacter(for: keyCode) ?? characters?.first else {
            return nil
        }

        let tool: AnnotationTool? = switch character {
        case "1": .select
        case "2": .rectangle
        case "3": .diamond
        case "4": .ellipse
        case "5": .arrow
        case "6": .line
        case "7": .pen
        case "8": .text
        case "0": .eraser
        default: nil
        }
        return tool.map { .setTool($0) }
    }

    private static func numberRowCharacter(for keyCode: UInt16) -> Character? {
        switch keyCode {
        case 18: "1"
        case 19: "2"
        case 20: "3"
        case 21: "4"
        case 23: "5"
        case 22: "6"
        case 26: "7"
        case 28: "8"
        case 25: "9"
        case 29: "0"
        default: nil
        }
    }

    static func legacyCommand(characters: String?, shift: Bool) -> AppCommand? {
        guard let key = characters?.lowercased() else { return nil }
        return switch key {
        case "v": .setTool(.select)
        case " ": .setTool(.hand)
        case "f": .setTool(.pen)
        case "l": .setTool(.line)
        case "a": .setTool(.arrow)
        case "e" where shift: .setTool(.eraser)
        case "h": .setTool(.highlighter)
        case "t": .toggleTyping(rightAligned: shift)
        default: nil
        }
    }
}

struct DrawingAccessoryInteractionState: Equatable {
    var pointerOverToolbar = false
    var pointerOverInspector = false
    var controlTracking = false
    var menuOpen = false
    var popoverOpen = false
    var colorPanelOpen = false
    var scrollActive = false
    var toolbarDragActive = false

    var isActive: Bool {
        pointerOverToolbar
            || pointerOverInspector
            || controlTracking
            || menuOpen
            || popoverOpen
            || colorPanelOpen
            || scrollActive
            || toolbarDragActive
    }

    var preventsLifecycleHide: Bool {
        isActive
    }
}

enum DrawingAccessoryEventDispatch {
    static func bracketsControlTracking(_ eventType: NSEvent.EventType) -> Bool {
        switch eventType {
        case .leftMouseDown, .rightMouseDown, .otherMouseDown:
            true
        default:
            false
        }
    }
}

enum DrawingToolbarValue<Value: Equatable>: Equatable {
    case unavailable
    case value(Value)
    case mixed

    static func resolve(_ values: [Value]) -> DrawingToolbarValue<Value> {
        guard let first = values.first else { return .unavailable }
        return values.dropFirst().allSatisfy { $0 == first } ? .value(first) : .mixed
    }

    var value: Value? {
        guard case .value(let value) = self else { return nil }
        return value
    }
}

enum DrawingInspectorPressureOption: CaseIterable, Equatable {
    case constant
    case variable

    var displayName: String {
        switch self {
        case .constant: "Constant"
        case .variable: "Variable"
        }
    }
}

enum DrawingInspectorControlMapping {
    struct LayerAction: Equatable {
        var action: AnnotationArrangeAction
        var label: String
        var shortcut: String

        var toolTip: String {
            "\(label) — \(shortcut)"
        }
    }

    static let strokeColors: [AnnotationColor] = [
        .strokeNeutral,
        .strokeCoral,
        .strokeGreen,
        .strokeBlue,
        .strokeOrange
    ]
    static let highlighterColors: [AnnotationColor] = [
        .highlighterYellow,
        .highlighterCyan,
        .highlighterPink,
        .highlighterGreen,
        .highlighterOrange
    ]
    static let backgroundColors: [AnnotationColor] = [
        .backgroundRed,
        .backgroundGreen,
        .backgroundBlue,
        .backgroundYellow
    ]
    static let fillStyles: [AnnotationFillStyle] = [.hachure, .crossHatch, .solid]
    static let strokeWidths: [CGFloat] = [1, 3, 6]
    static let penStrokeWidths: [CGFloat] = [3, 7, 11]
    static let highlighterStrokeWidths: [CGFloat] = [10, 18, 28]
    static let strokePatterns: [AnnotationStrokePattern] = [.solid, .dashed, .dotted]
    static let sloppiness = AnnotationSloppiness.allCases
    static let pressureOptions = DrawingInspectorPressureOption.allCases
    static let edgeStyles = AnnotationEdgeStyle.allCases
    static let linearRoutes = AnnotationLinearRoute.userSelectableRoutes
    static let arrowheadSizes = AnnotationArrowheadSize.allCases
    static let arrowheads: [AnnotationArrowhead] = [
        .none,
        .arrow,
        .triangleOutline,
        .triangle,
        .circleOutline,
        .circle,
        .diamondOutline,
        .diamond,
        .bar,
        .crowFoot,
        .oneOrMany,
        .zeroOrOne,
        .zeroOrMany
    ]
    static let layerActions: [LayerAction] = [
        LayerAction(
            action: .sendToBack,
            label: "Send to back",
            shortcut: "Cmd+Option+["
        ),
        LayerAction(
            action: .sendBackward,
            label: "Send backward",
            shortcut: "Cmd+["
        ),
        LayerAction(
            action: .bringForward,
            label: "Bring forward",
            shortcut: "Cmd+]"
        ),
        LayerAction(
            action: .bringToFront,
            label: "Bring to front",
            shortcut: "Cmd+Option+]"
        )
    ]
    static let textFontPresets: [AnnotationTextFontPreset] = [
        .rounded,
        .system,
        .monospaced
    ]
    static let textSizes: [CGFloat] = [20, 32, 48, 72]
    static let textAlignments: [AnnotationTextAlignment] = [.left, .center, .right]

    static func fillStyleCommand(at index: Int) -> AppCommand? {
        fillStyles.indices.contains(index) ? .setFillStyle(fillStyles[index]) : nil
    }

    static func startArrowheadCommand(at index: Int) -> AppCommand? {
        arrowheads.indices.contains(index)
            ? .setLinearStartArrowhead(arrowheads[index])
            : nil
    }

    static func endArrowheadCommand(at index: Int) -> AppCommand? {
        arrowheads.indices.contains(index)
            ? .setLinearEndArrowhead(arrowheads[index])
            : nil
    }

    static func textFontPresetCommand(at index: Int) -> AppCommand? {
        textFontPresets.indices.contains(index)
            ? .setTextFontPreset(textFontPresets[index])
            : nil
    }

    static func textSizeCommand(at index: Int) -> AppCommand? {
        textSizes.indices.contains(index) ? .setTextFontSize(textSizes[index]) : nil
    }
}

enum DrawingInspectorSection: CaseIterable, Hashable {
    case strokeColor
    case background
    case fill
    case strokeWidth
    case strokeStyle
    case sloppiness
    case edges
    case arrowType
    case arrowheads
    case arrowheadSize
    case smartDraw
    case pressure
    case textFont
    case textSize
    case textAlignment
    case opacity
    case layers

    var title: String {
        switch self {
        case .strokeColor: "Stroke"
        case .background: "Background"
        case .fill: "Fill"
        case .strokeWidth: "Stroke width"
        case .strokeStyle: "Stroke style"
        case .sloppiness: "Sloppiness"
        case .edges: "Edges"
        case .arrowType: "Arrow type"
        case .arrowheads: "Arrowheads"
        case .arrowheadSize: "Arrowhead size"
        case .smartDraw: "Smart Draw"
        case .pressure: "Pressure"
        case .textFont: "Font family"
        case .textSize: "Font size"
        case .textAlignment: "Text align"
        case .opacity: "Opacity"
        case .layers: "Layers"
        }
    }
}

enum DrawingInspectorSectionMatrix {
    static func sections(for tool: AnnotationTool) -> [DrawingInspectorSection] {
        switch tool {
        case .rectangle, .diamond:
            [
                .strokeColor,
                .background,
                .strokeWidth,
                .strokeStyle,
                .sloppiness,
                .edges,
                .opacity,
                .layers
            ]
        case .ellipse:
            [
                .strokeColor,
                .background,
                .strokeWidth,
                .strokeStyle,
                .sloppiness,
                .opacity,
                .layers
            ]
        case .arrow:
            [
                .strokeColor,
                .strokeWidth,
                .strokeStyle,
                .sloppiness,
                .arrowType,
                .arrowheads,
                .arrowheadSize,
                .opacity,
                .layers
            ]
        case .line:
            [
                .strokeColor,
                .strokeWidth,
                .strokeStyle,
                .edges,
                .opacity,
                .layers
            ]
        case .pen:
            [
                .strokeColor,
                .strokeWidth,
                .smartDraw,
                .pressure,
                .opacity
            ]
        case .highlighter:
            [
                .strokeColor,
                .strokeWidth,
                .opacity
            ]
        case .text:
            [
                .strokeColor,
                .textFont,
                .textSize,
                .textAlignment,
                .opacity,
                .layers
            ]
        case .hand, .select, .eraser:
            []
        }
    }

    static func tool(for element: AnnotationElement) -> AnnotationTool {
        switch element.geometry {
        case .freehand(let freehand):
            freehand.isHighlighter ? .highlighter : .pen
        case .shape(let shape):
            switch shape.kind {
            case .rectangle: .rectangle
            case .diamond: .diamond
            case .ellipse: .ellipse
            }
        case .linear(let linear):
            linear.isHeadless ? .line : .arrow
        case .text:
            .text
        }
    }

    struct DrawingToolbarHorizontalSectionLayout: Equatable {
        var rows: [[DrawingInspectorSection]]
        var rowWidths: [CGFloat]
        var documentWidth: CGFloat
    }

    enum DrawingToolbarHorizontalSectionPacker {
        static func sectionWidth(_ section: DrawingInspectorSection) -> CGFloat {
            switch section {
            case .strokeColor, .background:
                261
            case .opacity:
                176
            case .fill, .strokeWidth, .strokeStyle, .sloppiness, .arrowType,
                 .arrowheadSize, .textAlignment:
                112
            case .pressure, .edges, .arrowheads, .smartDraw:
                72
            case .textFont, .textSize, .layers:
                152
            }
        }

        static func layout(
            sections: [DrawingInspectorSection],
            availableWidth: CGFloat,
            sectionWidths: [DrawingInspectorSection: CGFloat] = [:]
        ) -> DrawingToolbarHorizontalSectionLayout {
            guard !sections.isEmpty else {
                return DrawingToolbarHorizontalSectionLayout(
                    rows: [],
                    rowWidths: [],
                    documentWidth: 1
                )
            }

            let safeWidth = max(1, availableWidth)
            let resolvedWidths = Dictionary(
                uniqueKeysWithValues: sections.map {
                    (
                        $0,
                        min(
                            max(1, sectionWidths[$0] ?? sectionWidth($0)),
                            safeWidth
                        )
                    )
                }
            )
            let rows = packedRows(
                sections: sections,
                width: safeWidth,
                sectionWidths: resolvedWidths
            )
            let rowWidths = rows.map {
                totalWidth($0, sectionWidths: resolvedWidths)
            }

            return DrawingToolbarHorizontalSectionLayout(
                rows: rows,
                rowWidths: rowWidths,
                documentWidth: min(safeWidth, ceil(rowWidths.max() ?? 1))
            )
        }

        private static func packedRows(
            sections: [DrawingInspectorSection],
            width: CGFloat,
            sectionWidths: [DrawingInspectorSection: CGFloat]
        ) -> [[DrawingInspectorSection]] {
            var rows: [[DrawingInspectorSection]] = [[]]
            var rowWidth = CGFloat.zero
            for section in sections {
                let itemWidth = sectionWidths[section] ?? sectionWidth(section)
                let proposed = rows[rows.count - 1].isEmpty
                    ? itemWidth
                    : rowWidth
                        + DrawingInspectorVisualMetrics.attachedSectionSpacing
                        + itemWidth
                if proposed > width, !rows[rows.count - 1].isEmpty {
                    rows.append([section])
                    rowWidth = itemWidth
                } else {
                    rows[rows.count - 1].append(section)
                    rowWidth = proposed
                }
            }
            return rows
        }

        private static func totalWidth(
            _ sections: [DrawingInspectorSection],
            sectionWidths: [DrawingInspectorSection: CGFloat]
        ) -> CGFloat {
            sections.reduce(CGFloat.zero) {
                $0 + (sectionWidths[$1] ?? sectionWidth($1))
            }
                + CGFloat(max(0, sections.count - 1))
                    * DrawingInspectorVisualMetrics.attachedSectionSpacing
        }
    }

    static func sections(
        for selected: [AnnotationElement],
        currentTool: AnnotationTool,
        showsFill: Bool
    ) -> [DrawingInspectorSection] {
        var baseSections: [DrawingInspectorSection]
        if selected.isEmpty {
            baseSections = sections(for: currentTool)
        } else {
            let matrices = selected.map(selectionSections(for:))
            guard let first = matrices.first else { return [] }
            baseSections = first.filter { section in
                matrices.dropFirst().allSatisfy { $0.contains(section) }
            }
            let selectedTools = selected.map(tool(for:))
            if selectedTools.contains(.line),
               selectedTools.contains(.arrow),
               !baseSections.contains(.arrowType) {
                let insertionIndex = baseSections.firstIndex(of: .arrowheads)
                    ?? baseSections.firstIndex(of: .opacity)
                    ?? baseSections.endIndex
                baseSections.insert(.arrowType, at: insertionIndex)
            }
        }
        guard showsFill,
              let backgroundIndex = baseSections.firstIndex(of: .background) else {
            return baseSections
        }
        var result = baseSections
        result.insert(.fill, at: backgroundIndex + 1)
        return result
    }

    private static func selectionSections(
        for element: AnnotationElement
    ) -> [DrawingInspectorSection] {
        var result = sections(for: tool(for: element))
        guard case .linear(let linear) = element.geometry,
              linear.isHeadless,
              let insertionIndex = result.firstIndex(of: .opacity) else {
            return result
        }
        result.insert(
            contentsOf: [.arrowheads, .arrowheadSize],
            at: insertionIndex
        )
        return result
    }
}

struct DrawingInspectorContext: Equatable {
    var tool: AnnotationTool
    var hasSelection: Bool
    var sections: [DrawingInspectorSection]
}

enum DrawingInspectorPresentationPolicy {
    static func shouldShow(hasContent: Bool) -> Bool {
        hasContent
    }

    static func shouldResetScroll(
        from previous: DrawingInspectorContext?,
        to current: DrawingInspectorContext
    ) -> Bool {
        previous != current
    }
}

struct DrawingToolbarState: Equatable {
    var currentTool: AnnotationTool
    var canUndo: Bool
    var canRedo: Bool
    var hasSelection: Bool
    var canDeleteSelection: Bool
    var canGroupSelection: Bool
    var canUngroupSelection: Bool
    var selectionIsFullyLocked: Bool
    var selectionLock: DrawingToolbarValue<Bool>
    var strokeColor: DrawingToolbarValue<AnnotationColorValue>
    var fillColor: DrawingToolbarValue<AnnotationColorValue>
    var fillStyle: DrawingToolbarValue<AnnotationFillStyle>
    var strokeWidth: DrawingToolbarValue<CGFloat>
    var strokePattern: DrawingToolbarValue<AnnotationStrokePattern>
    var sloppiness: DrawingToolbarValue<AnnotationSloppiness>
    var opacity: DrawingToolbarValue<CGFloat>
    var strokePreviewOpacity: DrawingToolbarValue<CGFloat>
    var pressureEnabled: DrawingToolbarValue<Bool>
    var pressureMode: DrawingToolbarValue<AnnotationPressureMode>
    var pressureOption: DrawingToolbarValue<DrawingInspectorPressureOption>
    var preferredVariablePressureMode: AnnotationPressureMode
    var smoothingEnabled: DrawingToolbarValue<Bool>
    var smartDrawEnabled: Bool
    var smartDrawStatusText: String?
    var roundness: DrawingToolbarValue<CGFloat?>
    var edgeStyle: DrawingToolbarValue<AnnotationEdgeStyle>
    var linearRoute: DrawingToolbarValue<AnnotationLinearRoute>
    var startArrowhead: DrawingToolbarValue<AnnotationArrowhead>
    var endArrowhead: DrawingToolbarValue<AnnotationArrowhead>
    var arrowheadSize: DrawingToolbarValue<AnnotationArrowheadSize>
    var arrowheadChangesApplyToEditableOnly: Bool
    var textColor: DrawingToolbarValue<AnnotationColorValue>
    var textOpacity: DrawingToolbarValue<CGFloat>
    var textFontPreset: DrawingToolbarValue<AnnotationTextFontPreset>
    var textFontName: DrawingToolbarValue<String>
    var typeSettingFontName: String
    var textFontSize: DrawingToolbarValue<CGFloat>
    var textAlignment: DrawingToolbarValue<AnnotationTextAlignment>
    var supportsStrokeOptions: Bool
    var supportsFill: Bool
    var supportsSloppiness: Bool
    var supportsFreehandOptions: Bool
    var supportsSmartDraw: Bool
    var supportsRoundness: Bool
    var supportsLinearOptions: Bool
    var supportsTextOptions: Bool
    var showsHighlighterBehavior: Bool
    var isEditingLinearPoints: Bool
    var canEditLinearPoints: Bool
    var canInsertLinearPoint: Bool
    var canRemoveLinearPoints: Bool
    var canUnbindLinearEndpoints: Bool
    var showsLinearPointHandles: Bool
    var isConstructingLinearPath: Bool
    var canFinishLinearPath: Bool
    var hasInspectorContent: Bool {
        !visibleInspectorSections.isEmpty
    }
    var inspectorContext: DrawingInspectorContext {
        DrawingInspectorContext(
            tool: currentTool,
            hasSelection: hasSelection,
            sections: visibleInspectorSections
        )
    }
    var inspectorTitle: String {
        if hasSelection {
            return "Selection Inspector"
        }
        return switch currentTool {
        case .hand: "Hand"
        case .select: "Selection"
        case .pen: "Pen"
        case .line: "Line"
        case .rectangle: "Rectangle"
        case .diamond: "Diamond"
        case .ellipse: "Ellipse"
        case .arrow: "Arrow"
        case .text: "Text"
        case .highlighter: "Highlighter"
        case .eraser: "Eraser"
        }
    }

    // Store only presentation data. Retaining selected geometry here both copies
    // growing strokes and makes a position-only drag appear to change the UI.
    private(set) var visibleInspectorSections: [DrawingInspectorSection]
    private(set) var strokeWidthOptions: [CGFloat]

    @MainActor
    init(annotationController: AnnotationController) {
        let selected = annotationController.selectedElementSnapshot
        let editableSelected = selected.filter { !$0.metadata.isLocked }
        let styles = selected.isEmpty
            ? [annotationController.currentStyle]
            : editableSelected.map(\.style)
        let shapes = editableSelected.filter {
            if case .shape = $0.geometry { return true }
            return false
        }
        let roundedShapes = editableSelected.filter {
            guard case .shape(let shape) = $0.geometry else { return false }
            return shape.kind == .rectangle || shape.kind == .diamond
        }
        let freehands = editableSelected.filter {
            if case .freehand = $0.geometry { return true }
            return false
        }
        let nonTextElements = editableSelected.filter {
            if case .text = $0.geometry { return false }
            return true
        }
        let strokePatternElements = editableSelected.filter {
            switch $0.geometry {
            case .shape, .linear:
                true
            case .freehand, .text:
                false
            }
        }
        let sloppinessElements = editableSelected.filter {
            switch $0.geometry {
            case .freehand, .shape:
                true
            case .linear(let linear):
                !linear.isHeadless
            case .text:
                false
            }
        }
        let selectedLinearCount = selected.reduce(into: 0) { count, element in
            if case .linear = element.geometry {
                count += 1
            }
        }
        let linearElements = editableSelected.filter {
            if case .linear = $0.geometry { return true }
            return false
        }
        let linears = linearElements.compactMap { element -> AnnotationLinearGeometry? in
            guard case .linear(let linear) = element.geometry else { return nil }
            return linear
        }
        let texts = editableSelected.compactMap {
            element -> (AnnotationTextGeometry, AnnotationStyle)? in
            guard case .text(let text) = element.geometry else { return nil }
            return (text, element.style)
        }
        let edgeStyles = editableSelected.compactMap { element -> AnnotationEdgeStyle? in
            switch element.geometry {
            case .shape(let shape)
                where shape.kind == .rectangle || shape.kind == .diamond:
                return element.style.roundness.map { $0 > 0 ? .round : .sharp } ?? .sharp
            case .linear(let linear)
                where linear.startArrowhead == .none && linear.endArrowhead == .none:
                return linear.route == .curved ? .round : .sharp
            case .freehand, .shape, .linear, .text:
                return nil
            }
        }

        let displayedElements = editableSelected.isEmpty ? selected : editableSelected
        currentTool = annotationController.currentTool
        canUndo = annotationController.canUndo
        canRedo = annotationController.canRedo
        hasSelection = annotationController.hasSelection
        canDeleteSelection = annotationController.canDeleteSelection
        canGroupSelection = annotationController.canGroupSelection
        canUngroupSelection = annotationController.canUngroupSelection
        selectionIsFullyLocked = annotationController.selectionIsFullyLocked
        selectionLock = .resolve(selected.map(\.metadata.isLocked))
        strokeColor = .resolve(styles.map(\.strokeColor))
        fillColor = shapes.isEmpty
            ? (selected.isEmpty ? .value(annotationController.currentStyle.fillColor) : .unavailable)
            : .resolve(shapes.map(\.style.fillColor))
        fillStyle = shapes.isEmpty
            ? (selected.isEmpty ? .value(annotationController.currentStyle.fillStyle) : .unavailable)
            : .resolve(shapes.map(\.style.fillStyle))
        strokeWidth = nonTextElements.isEmpty
            ? (
                selected.isEmpty
                    ? .value(annotationController.currentStyle.strokeWidth)
                    : .unavailable
            )
            : .resolve(nonTextElements.map(\.style.strokeWidth))
        strokePattern = selected.isEmpty
            && [.pen, .highlighter].contains(currentTool)
            ? .unavailable
            : strokePatternElements.isEmpty
            ? (
                selected.isEmpty
                    ? .value(annotationController.currentStyle.strokePattern)
                    : .unavailable
            )
            : .resolve(strokePatternElements.map(\.style.strokePattern))
        sloppiness = sloppinessElements.isEmpty
            ? (
                selected.isEmpty && currentTool != .line
                    ? .value(annotationController.currentStyle.sloppiness)
                    : .unavailable
            )
            : .resolve(sloppinessElements.map(\.style.sloppiness))
        opacity = .resolve(styles.map(\.opacity))
        let previewOpacities = selected.isEmpty
            ? [
                annotationController.currentStyle.opacity * (
                    currentTool == .highlighter
                        && !annotationController.currentStyle.usesLegacyHighlightCompositing
                        ? AnnotationStyle.highlightAlpha
                        : 1
                )
            ]
            : editableSelected.map { element in
                let highlighterMultiplier: CGFloat
                if case .freehand(let freehand) = element.geometry,
                   freehand.isHighlighter,
                   !element.style.usesLegacyHighlightCompositing {
                    highlighterMultiplier = AnnotationStyle.highlightAlpha
                } else {
                    highlighterMultiplier = 1
                }
                return element.style.opacity * highlighterMultiplier
            }
        strokePreviewOpacity = .resolve(previewOpacities)
        pressureEnabled = freehands.isEmpty
            ? (selected.isEmpty ? .value(annotationController.currentStyle.pressureEnabled) : .unavailable)
            : .resolve(freehands.map(\.style.pressureEnabled))
        pressureMode = freehands.isEmpty
            ? (
                selected.isEmpty
                    ? .value(annotationController.currentStyle.pressureMode)
                    : .unavailable
            )
            : .resolve(freehands.map(\.style.pressureMode))
        let resolvedPressureOptions = freehands.map {
            $0.style.pressureMode == .fixed
                ? DrawingInspectorPressureOption.constant
                : .variable
        }
        pressureOption = freehands.isEmpty
            ? (
                selected.isEmpty
                    ? .value(
                        annotationController.currentStyle.pressureMode == .fixed
                            ? .constant
                            : .variable
                    )
                    : .unavailable
            )
            : .resolve(resolvedPressureOptions)
        preferredVariablePressureMode = annotationController.preferredVariablePressureMode
        smoothingEnabled = freehands.isEmpty
            ? (selected.isEmpty ? .value(annotationController.currentStyle.smoothingEnabled) : .unavailable)
            : .resolve(freehands.map(\.style.smoothingEnabled))
        smartDrawEnabled = annotationController.smartDrawEnabled
        smartDrawStatusText = annotationController.smartDrawStatusText
        roundness = roundedShapes.isEmpty
            ? (selected.isEmpty ? .value(annotationController.currentStyle.roundness) : .unavailable)
            : .resolve(roundedShapes.map(\.style.roundness))
        if selected.isEmpty {
            edgeStyle = switch currentTool {
            case .rectangle, .diamond:
                .value(
                    (annotationController.currentStyle.roundness ?? 0) > 0
                        ? .round
                        : .sharp
                )
            case .line:
                .value(annotationController.currentLinearRoute == .curved ? .round : .sharp)
            default:
                .unavailable
            }
        } else {
            edgeStyle = .resolve(edgeStyles)
        }
        linearRoute = linears.isEmpty
            ? (selected.isEmpty ? .value(annotationController.currentLinearRoute) : .unavailable)
            : .resolve(linears.map(\.route))
        startArrowhead = linears.isEmpty
            ? (selected.isEmpty ? .value(annotationController.currentStartArrowhead) : .unavailable)
            : .resolve(linears.map(\.startArrowhead))
        endArrowhead = linears.isEmpty
            ? (selected.isEmpty ? .value(annotationController.currentEndArrowhead) : .unavailable)
            : .resolve(linears.map(\.endArrowhead))
        arrowheadSize = linears.isEmpty
            ? (
                selected.isEmpty
                    ? .value(annotationController.currentArrowheadSize)
                    : .unavailable
            )
            : .resolve(linears.map(\.arrowheadSize))
        arrowheadChangesApplyToEditableOnly =
            !linears.isEmpty && linears.count < selectedLinearCount
        textColor = texts.isEmpty
            ? (
                selected.isEmpty
                    ? .value(annotationController.currentStyle.strokeColor)
                    : .unavailable
            )
            : .resolve(texts.map { $0.1.strokeColor })
        textOpacity = texts.isEmpty
            ? (
                selected.isEmpty
                    ? .value(annotationController.currentStyle.opacity)
                    : .unavailable
            )
            : .resolve(texts.map { $0.1.opacity })
        textFontPreset = texts.isEmpty
            ? (
                selected.isEmpty
                    ? .value(annotationController.typingFontPreset)
                    : .unavailable
            )
            : .resolve(
                texts.map {
                    AnnotationTextFontPreset.inferred(
                        fromStorageFontName: $0.0.fontName
                    )
                }
            )
        textFontName = texts.isEmpty
            ? (
                selected.isEmpty
                    ? .value(annotationController.typingStorageFontName)
                    : .unavailable
            )
            : .resolve(texts.map { $0.0.fontName })
        typeSettingFontName = annotationController.typingFontName
        textFontSize = texts.isEmpty
            ? (
                selected.isEmpty
                    ? .value(annotationController.typingFontSize)
                    : .unavailable
            )
            : .resolve(texts.map { $0.0.fontSize })
        textAlignment = texts.isEmpty
            ? (
                selected.isEmpty
                    ? .value(annotationController.typingTextAlignment)
                    : .unavailable
            )
            : .resolve(texts.map { $0.0.alignment })

        if selected.isEmpty {
            supportsStrokeOptions = [
                .pen, .line, .rectangle, .diamond, .ellipse, .arrow, .highlighter
            ].contains(currentTool)
            supportsFill = [.rectangle, .diamond, .ellipse].contains(currentTool)
            supportsSloppiness = [
                .rectangle, .diamond, .ellipse, .arrow
            ].contains(currentTool)
            supportsFreehandOptions = currentTool == .pen
            supportsSmartDraw = currentTool == .pen
            supportsRoundness = [.rectangle, .diamond].contains(currentTool)
            supportsLinearOptions = [.line, .arrow].contains(currentTool)
            supportsTextOptions = currentTool == .text
            showsHighlighterBehavior = currentTool == .highlighter
        } else {
            supportsStrokeOptions = !nonTextElements.isEmpty
            supportsFill = !shapes.isEmpty
            supportsSloppiness = !sloppinessElements.isEmpty
            supportsFreehandOptions = !freehands.isEmpty
            supportsSmartDraw = false
            supportsRoundness = !roundedShapes.isEmpty
            supportsLinearOptions = !linears.isEmpty
            supportsTextOptions = !texts.isEmpty
            showsHighlighterBehavior = freehands.contains {
                guard case .freehand(let freehand) = $0.geometry else { return false }
                return freehand.isHighlighter
            }
        }
        isEditingLinearPoints = annotationController.isEditingLinearPoints
        canEditLinearPoints = annotationController.canEditLinearPoints
        canInsertLinearPoint = annotationController.canInsertLinearPoint
        canRemoveLinearPoints = annotationController.canRemoveLinearPoints
        canUnbindLinearEndpoints = annotationController.canUnbindLinearEndpoints
        showsLinearPointHandles = annotationController.linearPointDecorationElement != nil
        isConstructingLinearPath = annotationController.isConstructingLinearPath
        canFinishLinearPath = annotationController.canFinishLinearPath
        let showsFill: Bool
        switch fillStyle {
        case .value(let style):
            showsFill = style != .none && fillColor.value?.isTransparent != true
        case .mixed:
            showsFill = true
        case .unavailable:
            showsFill = displayedElements.contains {
                guard case .shape = $0.geometry else { return false }
                return $0.style.fillStyle != .none && !$0.style.fillColor.isTransparent
            }
        }
        var sections = DrawingInspectorSectionMatrix.sections(
            for: displayedElements, currentTool: currentTool, showsFill: showsFill
        )
        if !supportsSmartDraw { sections.removeAll { $0 == .smartDraw } }
        if smartDrawEnabled, displayedElements.isEmpty, currentTool == .pen {
            sections.removeAll { $0 == .pressure }
        }
        visibleInspectorSections = sections
        let widthTools = displayedElements.isEmpty
            ? [currentTool]
            : displayedElements.map(DrawingInspectorSectionMatrix.tool(for:))
        if widthTools.allSatisfy({ $0 == .highlighter }) {
            strokeWidthOptions = DrawingInspectorControlMapping.highlighterStrokeWidths
        } else if widthTools.allSatisfy({ $0 == .pen }) {
            strokeWidthOptions = DrawingInspectorControlMapping.penStrokeWidths
        } else {
            strokeWidthOptions = DrawingInspectorControlMapping.strokeWidths
        }
    }
}

enum DrawingToolbarOverflowActionTitle {
    static let duplicate = "Duplicate"
    static let delete = "Delete"
    static let bringToFront = "Bring to Front"
    static let bringForward = "Bring Forward"
    static let sendBackward = "Send Backward"
    static let sendToBack = "Send to Back"
    static let group = "Group"
    static let ungroup = "Ungroup"
    static let lock = "Lock Selection"
    static let unlock = "Unlock Selection"
    static let editPoints = "Edit Points"
    static let finishPointEditing = "Finish Point Editing"
    static let insertPoint = "Insert Point"
    static let removePoints = "Remove Selected Points"
    static let unbindEndpoints = "Unbind Arrow Endpoints"

    static let relocatedSelectionActions = [
        duplicate,
        delete,
        bringToFront,
        bringForward,
        sendBackward,
        sendToBack,
        group,
        ungroup,
        lock
    ]
}

enum DrawingToolbarOverflowActionAvailability {
    static func enabledStates(
        for state: DrawingToolbarState
    ) -> [String: Bool] {
        let lockTitle = state.selectionIsFullyLocked
            ? DrawingToolbarOverflowActionTitle.unlock
            : DrawingToolbarOverflowActionTitle.lock
        let editPointsTitle = state.isEditingLinearPoints
            ? DrawingToolbarOverflowActionTitle.finishPointEditing
            : DrawingToolbarOverflowActionTitle.editPoints
        return [
            DrawingToolbarOverflowActionTitle.duplicate: state.canDeleteSelection,
            DrawingToolbarOverflowActionTitle.delete: state.canDeleteSelection,
            DrawingToolbarOverflowActionTitle.bringToFront: state.canDeleteSelection,
            DrawingToolbarOverflowActionTitle.bringForward: state.canDeleteSelection,
            DrawingToolbarOverflowActionTitle.sendBackward: state.canDeleteSelection,
            DrawingToolbarOverflowActionTitle.sendToBack: state.canDeleteSelection,
            DrawingToolbarOverflowActionTitle.group: state.canGroupSelection,
            DrawingToolbarOverflowActionTitle.ungroup: state.canUngroupSelection,
            lockTitle: state.hasSelection,
            editPointsTitle: state.canEditLinearPoints,
            DrawingToolbarOverflowActionTitle.insertPoint: state.canInsertLinearPoint,
            DrawingToolbarOverflowActionTitle.removePoints: state.canRemoveLinearPoints,
            DrawingToolbarOverflowActionTitle.unbindEndpoints:
                state.canUnbindLinearEndpoints
        ]
    }
}

enum DrawingToolbarLifecycle {
    static func shouldShow(
        isOverlayPresented: Bool,
        isDrawingAccessoryActive: Bool,
        interactionState: DrawingAccessoryInteractionState = DrawingAccessoryInteractionState()
    ) -> Bool {
        isOverlayPresented
            && (isDrawingAccessoryActive || interactionState.preventsLifecycleHide)
    }
}

struct DrawingAccessorySuppressionToken: Hashable {
    fileprivate let identifier: Int
}

struct DrawingAccessorySuppressionLifecycle {
    private var nextIdentifier = 0
    private var activeTokens: Set<DrawingAccessorySuppressionToken> = []

    var isSuppressed: Bool {
        !activeTokens.isEmpty
    }

    mutating func begin() -> DrawingAccessorySuppressionToken {
        nextIdentifier += 1
        let token = DrawingAccessorySuppressionToken(identifier: nextIdentifier)
        activeTokens.insert(token)
        return token
    }

    @discardableResult
    mutating func finish(_ token: DrawingAccessorySuppressionToken) -> Bool {
        activeTokens.remove(token) != nil
    }

    mutating func reset() {
        activeTokens.removeAll(keepingCapacity: true)
    }
}

enum DrawingAccessoryLifecycle {
    static func isActive(
        interactionMode: AppMode,
        isDrawingMode: Bool,
        resumesDrawingAfterTyping: Bool
    ) -> Bool {
        isDrawingMode || (interactionMode == .typing && resumesDrawingAfterTyping)
    }
}

struct DrawingToolbarLayoutFrames: Equatable {
    var scrollFrame: CGRect
    var pathActionsFrame: CGRect
}

enum DrawingToolbarLayout {
    static let contentInset = DrawingToolbarVisualMetrics.shellInset
    static let sectionSpacing: CGFloat = 4
    static let screenMargin: CGFloat = 12

    static func preferredSize(
        mainContentSize: CGSize,
        pathActionsSize: CGSize,
        maximumWidth: CGFloat?
    ) -> CGSize {
        let hasPathActions = pathActionsSize.width > 0 && pathActionsSize.height > 0
        let naturalWidth = mainContentSize.width
            + (hasPathActions ? sectionSpacing + pathActionsSize.width : 0)
            + contentInset * 2
        let width = min(naturalWidth, maximumWidth ?? naturalWidth)
        let naturalHeight = max(mainContentSize.height, pathActionsSize.height)
            + contentInset * 2
        return CGSize(
            width: max(width, DrawingToolbarVisualMetrics.shellHeight),
            height: max(DrawingToolbarVisualMetrics.shellHeight, naturalHeight)
        )
    }

    static func frames(
        in bounds: CGRect,
        pathActionsSize: CGSize
    ) -> DrawingToolbarLayoutFrames {
        let inner = bounds.insetBy(dx: contentInset, dy: contentInset)
        let hasPathActions = pathActionsSize.width > 0 && pathActionsSize.height > 0
        guard hasPathActions else {
            return DrawingToolbarLayoutFrames(
                scrollFrame: inner,
                pathActionsFrame: .zero
            )
        }

        let pathWidth = min(pathActionsSize.width, inner.width)
        let pathFrame = CGRect(
            x: inner.maxX - pathWidth,
            y: inner.midY - min(pathActionsSize.height, inner.height) / 2,
            width: pathWidth,
            height: min(pathActionsSize.height, inner.height)
        )
        return DrawingToolbarLayoutFrames(
            scrollFrame: CGRect(
                x: inner.minX,
                y: inner.minY,
                width: max(0, pathFrame.minX - sectionSpacing - inner.minX),
                height: inner.height
            ),
            pathActionsFrame: pathFrame
        )
    }
}

enum DrawingCursorPresentation: Equatable {
    case hidden
    case arrow
    case iBeam
    case openHand
    case closedHand
}

enum DrawingCursorPolicy {
    static func presentation(
        interactionMode: AppMode,
        isDrawingMode: Bool,
        tool: AnnotationTool,
        isAccessoryInteractionActive: Bool,
        isHandPanning: Bool,
        isLiveZoomInteractive: Bool,
        isTextInsertionActive: Bool = false
    ) -> DrawingCursorPresentation {
        if isAccessoryInteractionActive {
            return .arrow
        }
        if interactionMode == .typing {
            return isTextInsertionActive ? .hidden : .iBeam
        }
        if isLiveZoomInteractive {
            return .arrow
        }
        guard isDrawingMode else {
            return .hidden
        }
        return switch tool {
        case .hand:
            isHandPanning ? .closedHand : .openHand
        case .select, .eraser:
            .arrow
        case .text:
            .iBeam
        default:
            .hidden
        }
    }
}

enum DrawingTextCaretPolicy {
    static func shouldDrawInsertionCaret(
        interactionMode: AppMode,
        isTextInsertionActive: Bool,
        isAccessoryInteractionActive: Bool
    ) -> Bool {
        interactionMode == .typing
            && isTextInsertionActive
            && !isAccessoryInteractionActive
    }
}

enum DrawingToolbarPlacement {
    static func draggedOrigin(
        initialOrigin: CGPoint,
        initialPointerScreenLocation: CGPoint,
        currentPointerScreenLocation: CGPoint
    ) -> CGPoint {
        CGPoint(
            x: initialOrigin.x
                + currentPointerScreenLocation.x
                - initialPointerScreenLocation.x,
            y: initialOrigin.y
                + currentPointerScreenLocation.y
                - initialPointerScreenLocation.y
        )
    }

    static func clampedOrigin(
        _ proposedOrigin: CGPoint,
        panelSize: CGSize,
        visibleFrame: CGRect,
        margin: CGFloat = 12
    ) -> CGPoint {
        let available = visibleFrame.insetBy(dx: margin, dy: margin)
        let maximumX = max(available.minX, available.maxX - panelSize.width)
        let maximumY = max(available.minY, available.maxY - panelSize.height)
        return CGPoint(
            x: min(max(proposedOrigin.x, available.minX), maximumX),
            y: min(max(proposedOrigin.y, available.minY), maximumY)
        )
    }

    static func defaultOrigin(panelSize: CGSize, visibleFrame: CGRect) -> CGPoint {
        clampedOrigin(
            CGPoint(
                x: visibleFrame.midX - panelSize.width / 2,
                y: visibleFrame.maxY - panelSize.height - 18
            ),
            panelSize: panelSize,
            visibleFrame: visibleFrame
        )
    }

    static func normalizedPosition(
        origin: CGPoint,
        panelSize: CGSize,
        visibleFrame: CGRect
    ) -> CGPoint {
        let travelX = max(visibleFrame.width - panelSize.width, 1)
        let travelY = max(visibleFrame.height - panelSize.height, 1)
        return CGPoint(
            x: min(max((origin.x - visibleFrame.minX) / travelX, 0), 1),
            y: min(max((origin.y - visibleFrame.minY) / travelY, 0), 1)
        )
    }

    static func origin(
        normalizedPosition: CGPoint,
        panelSize: CGSize,
        visibleFrame: CGRect
    ) -> CGPoint {
        let travelX = max(visibleFrame.width - panelSize.width, 0)
        let travelY = max(visibleFrame.height - panelSize.height, 0)
        return clampedOrigin(
            CGPoint(
                x: visibleFrame.minX + min(max(normalizedPosition.x, 0), 1) * travelX,
                y: visibleFrame.minY + min(max(normalizedPosition.y, 0), 1) * travelY
            ),
            panelSize: panelSize,
            visibleFrame: visibleFrame
        )
    }
}

enum DrawingAttachedInspectorPlacement {
    enum Alignment: Equatable {
        case below
        case above
    }

    struct Result: Equatable {
        var frame: CGRect
        var alignment: Alignment
    }

    static let gap: CGFloat = 6
    static let screenMargin: CGFloat = 12
    static let verticalFlipHysteresis: CGFloat = 24

    static func result(
        toolbarFrame: CGRect,
        contentSize: CGSize,
        visibleFrame: CGRect,
        previousAlignment: Alignment? = nil
    ) -> Result {
        let available = visibleFrame.insetBy(
            dx: screenMargin,
            dy: screenMargin
        )
        let idealSize = CGSize(
            width: min(
                contentSize.width
                    + DrawingInspectorVisualMetrics.attachedHorizontalChrome,
                min(
                    DrawingInspectorVisualMetrics.attachedMaximumWidth,
                    available.width
                )
            ),
            height: contentSize.height
                + DrawingInspectorVisualMetrics.attachedVerticalInset * 2
        )
        let belowSpace = max(0, toolbarFrame.minY - gap - available.minY)
        let aboveSpace = max(0, available.maxY - toolbarFrame.maxY - gap)

        var alignment = preferredVerticalAlignment(
            naturalHeight: idealSize.height,
            belowSpace: belowSpace,
            aboveSpace: aboveSpace
        )
        if let previousAlignment,
           previousAlignment != alignment {
            let previousSpace = previousAlignment == .below ? belowSpace : aboveSpace
            let preferredSpace = alignment == .below ? belowSpace : aboveSpace
            let previousStillUsable = previousSpace >= idealSize.height
                && min(preferredSpace, idealSize.height)
                    <= min(previousSpace, idealSize.height) + verticalFlipHysteresis
            if previousStillUsable {
                alignment = previousAlignment
            }
        }

        let size = idealSize
        let alignsLeft = toolbarFrame.midX <= available.midX
        let proposedX = alignsLeft
            ? toolbarFrame.minX
            : toolbarFrame.maxX - size.width
        let x = min(
            max(proposedX, available.minX),
            max(available.minX, available.maxX - size.width)
        )
        let y = alignment == .below
            ? toolbarFrame.minY - gap - size.height
            : toolbarFrame.maxY + gap
        return Result(
            frame: CGRect(origin: CGPoint(x: x, y: y), size: size),
            alignment: alignment
        )
    }

    static func frame(
        toolbarFrame: CGRect,
        contentSize: CGSize,
        visibleFrame: CGRect,
        previousAlignment: Alignment? = nil
    ) -> CGRect {
        result(
            toolbarFrame: toolbarFrame,
            contentSize: contentSize,
            visibleFrame: visibleFrame,
            previousAlignment: previousAlignment
        ).frame
    }

    private static func preferredVerticalAlignment(
        naturalHeight: CGFloat,
        belowSpace: CGFloat,
        aboveSpace: CGFloat
    ) -> Alignment {
        if belowSpace >= naturalHeight {
            return .below
        }
        if aboveSpace >= naturalHeight {
            return .above
        }
        return belowSpace >= aboveSpace ? .below : .above
    }

}

enum DrawingAttachedInspectorDragLock {
    static func inspectorOrigin(
        toolbarOrigin: CGPoint,
        inspectorOffset: CGPoint
    ) -> CGPoint {
        CGPoint(
            x: toolbarOrigin.x + inspectorOffset.x,
            y: toolbarOrigin.y + inspectorOffset.y
        )
    }

    static func clampedToolbarOrigin(
        _ proposedOrigin: CGPoint,
        toolbarSize: CGSize,
        inspectorOffset: CGPoint,
        inspectorSize: CGSize,
        visibleFrame: CGRect,
        margin: CGFloat = DrawingAttachedInspectorPlacement.screenMargin
    ) -> CGPoint {
        let toolbarRect = CGRect(origin: .zero, size: toolbarSize)
        let inspectorRect = CGRect(origin: inspectorOffset, size: inspectorSize)
        let combined = toolbarRect.union(inspectorRect)
        let available = visibleFrame.insetBy(dx: margin, dy: margin)
        let minimumX = available.minX - combined.minX
        let maximumX = max(minimumX, available.maxX - combined.maxX)
        let minimumY = available.minY - combined.minY
        let maximumY = max(minimumY, available.maxY - combined.maxY)
        return CGPoint(
            x: min(max(proposedOrigin.x, minimumX), maximumX),
            y: min(max(proposedOrigin.y, minimumY), maximumY)
        )
    }
}
