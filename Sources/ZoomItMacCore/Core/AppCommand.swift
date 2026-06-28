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
    case increasePenWidth
    case decreasePenWidth
    case undo
    case clear
    case snipRegion(save: Bool)
    case captureStill
    case startPanorama
    case toggleRecording(region: Bool)
    case exit
}