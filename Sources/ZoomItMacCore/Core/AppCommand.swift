enum AppCommand: Equatable {
    case activateStaticZoom
    case activateLiveZoom
    case activateDrawWithoutZoom
    case zoomIn
    case zoomOutOrExit
    case toggleTyping(rightAligned: Bool)
    case increaseFontSize
    case decreaseFontSize
    case setTool(AnnotationTool)
    case setColor(AnnotationColor)
    case setHighlightColor(AnnotationColor)
    case increasePenWidth
    case decreasePenWidth
    case undo
    case clear
    case snipRegion(save: Bool)
    case snipPreviousRegion(save: Bool)
    case snipOcr
    case startPanorama(save: Bool)
    case toggleRecording(region: Bool)
    case startDemoType
    case resetDemoType
    case toggleBreakTimer
    case exit
}