enum AppCommand: Equatable {
    case activateStaticZoom
    case activateLiveZoom
    case zoomIn
    case zoomOutOrExit
    case toggleTyping
    case setTool(AnnotationTool)
    case setColor(AnnotationColor)
    case increasePenWidth
    case decreasePenWidth
    case undo
    case clear
    case captureStill
    case startPanorama
    case toggleRecording
    case exit
}