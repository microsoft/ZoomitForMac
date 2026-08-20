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