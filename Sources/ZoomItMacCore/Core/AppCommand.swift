import CoreGraphics

enum DrawingContinuousStyleEditOwner: Hashable {
    case colorPicker
    case opacitySlider
}

enum AppCommand: Equatable {
    static let defaultDuplicateDestinationOffset = CGPoint(x: 10, y: 10)

    case activateStaticZoom
    case activateLiveZoom
    case activateDrawWithoutZoom
    case zoomIn
    case zoomOutOrExit
    case toggleTyping(rightAligned: Bool, insertionPoint: CGPoint? = nil)
    case editText(AnnotationElementID)
    case increaseFontSize
    case decreaseFontSize
    case setTool(AnnotationTool)
    case setColor(AnnotationColor)
    case setHighlightColor(AnnotationColor)
    case setStrokeColor(AnnotationColorValue)
    case setTextColor(AnnotationColorValue)
    case setShapeBackground(AnnotationColorValue?)
    case setFillStyle(AnnotationFillStyle)
    case setStrokeWidth(CGFloat)
    case setStrokePattern(AnnotationStrokePattern)
    case setSloppiness(AnnotationSloppiness)
    case setOpacity(CGFloat)
    case beginContinuousStyleEdit(DrawingContinuousStyleEditOwner)
    case endContinuousStyleEdit(DrawingContinuousStyleEditOwner)
    case setPressureMode(AnnotationPressureMode)
    case setSmartDrawEnabled(Bool)
    case setEdgeStyle(AnnotationEdgeStyle)
    case setTextFontPreset(AnnotationTextFontPreset)
    case setTextFontName(String)
    case setTextFontSize(CGFloat)
    case setTextAlignment(AnnotationTextAlignment)
    case increasePenWidth
    case decreasePenWidth
    case selectAllAnnotations
    case duplicateSelection(destinationOffset: CGPoint)
    case deleteSelection
    case arrangeSelection(AnnotationArrangeAction)
    case groupSelection
    case ungroupSelection
    case toggleSelectionLock
    case toggleLinearPointEditing
    case insertLinearPoint
    case removeLinearPoints
    case setLinearRoute(AnnotationLinearRoute)
    case setLinearArrowheads(start: AnnotationArrowhead, end: AnnotationArrowhead)
    case setLinearStartArrowhead(AnnotationArrowhead)
    case setLinearEndArrowhead(AnnotationArrowhead)
    case setLinearArrowheadSize(AnnotationArrowheadSize)
    case unbindLinearEndpoints
    case finishLinearPath
    case cancelLinearPath
    case undo
    case redo
    case clear
    case snipRegion(save: Bool)
    case snipOcr
    case startPanorama(save: Bool)
    case toggleRecording(region: Bool)
    #if !ZOOMIT_APP_STORE
    case startDemoType
    case resetDemoType
    #endif
    case toggleBreakTimer
    case toggleDemoMirror(scope: DemoMirrorScope)
    case exit
}

/// What DemoMirror mirrors onto the second monitor: the entire source screen,
/// a user-selected region of it, or the window under the cursor.
enum DemoMirrorScope: Equatable {
    case screen
    case region
    case window
}