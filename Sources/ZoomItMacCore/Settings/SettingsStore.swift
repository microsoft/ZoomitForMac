import Foundation

struct DrawingDefaults: Equatable {
    var tool: AnnotationTool
    var strokeColor: AnnotationColorValue
    var regularStrokeColor: AnnotationColorValue?
    var highlighterStrokeColor: AnnotationColorValue?
    var penStrokeWidth: CGFloat?
    var highlighterStrokeWidth: CGFloat?
    var geometryStrokeWidth: CGFloat?
    var penOpacity: CGFloat?
    var geometryOpacity: CGFloat?
    var highlighterOpacity: CGFloat?
    var fillColor: AnnotationColorValue
    var fillStyle: AnnotationFillStyle
    var strokePattern: AnnotationStrokePattern
    var sloppiness: AnnotationSloppiness
    var freehandSloppiness: AnnotationSloppiness
    var outlinedSloppiness: AnnotationSloppiness
    var opacity: CGFloat
    var usesLegacyHighlightCompositing: Bool
    var pressureMode: AnnotationPressureMode
    var smoothingEnabled: Bool
    var smartDrawEnabled: Bool
    var smartDrawSavedPressureMode: AnnotationPressureMode?
    var roundness: CGFloat?
    var lineRoute: AnnotationLinearRoute
    var arrowRoute: AnnotationLinearRoute
    var startArrowhead: AnnotationArrowhead
    var endArrowhead: AnnotationArrowhead
    var arrowheadSize: AnnotationArrowheadSize

    var linearRoute: AnnotationLinearRoute {
        get {
            tool == .arrow ? arrowRoute : lineRoute
        }
        set {
            switch tool {
            case .arrow:
                arrowRoute = newValue
            case .line:
                lineRoute = newValue
            default:
                lineRoute = newValue
                arrowRoute = newValue
            }
        }
    }

    var pressureEnabled: Bool {
        get { pressureMode != .fixed }
        set { pressureMode = newValue ? .tablet : .fixed }
    }

    static let `default` = DrawingDefaults(
        tool: .pen,
        strokeColor: .palette(.red),
        fillColor: .palette(.red),
        fillStyle: .none,
        strokePattern: .solid,
        sloppiness: .artist,
        freehandSloppiness: .artist,
        outlinedSloppiness: .artist,
        opacity: 1,
        pressureMode: .fixed,
        smoothingEnabled: true,
        smartDrawEnabled: false,
        smartDrawSavedPressureMode: nil,
        roundness: nil,
        linearRoute: .straight,
        lineRoute: .straight,
        arrowRoute: .curved,
        startArrowhead: .none,
        endArrowhead: .arrow,
        arrowheadSize: .medium,
        usesLegacyHighlightCompositing: false
    )

    init(
        tool: AnnotationTool,
        strokeColor: AnnotationColorValue,
        regularStrokeColor: AnnotationColorValue? = nil,
        highlighterStrokeColor: AnnotationColorValue? = nil,
        penStrokeWidth: CGFloat? = nil,
        highlighterStrokeWidth: CGFloat? = nil,
        geometryStrokeWidth: CGFloat? = nil,
        penOpacity: CGFloat? = nil,
        geometryOpacity: CGFloat? = nil,
        highlighterOpacity: CGFloat? = nil,
        fillColor: AnnotationColorValue,
        fillStyle: AnnotationFillStyle,
        strokePattern: AnnotationStrokePattern,
        sloppiness: AnnotationSloppiness = .artist,
        freehandSloppiness: AnnotationSloppiness? = nil,
        outlinedSloppiness: AnnotationSloppiness? = nil,
        opacity: CGFloat,
        pressureEnabled: Bool = false,
        pressureMode: AnnotationPressureMode? = nil,
        smoothingEnabled: Bool,
        smartDrawEnabled: Bool,
        smartDrawSavedPressureMode: AnnotationPressureMode? = nil,
        roundness: CGFloat?,
        linearRoute: AnnotationLinearRoute,
        lineRoute: AnnotationLinearRoute? = nil,
        arrowRoute: AnnotationLinearRoute? = nil,
        startArrowhead: AnnotationArrowhead,
        endArrowhead: AnnotationArrowhead,
        arrowheadSize: AnnotationArrowheadSize = .small,
        usesLegacyHighlightCompositing: Bool = false
    ) {
        self.tool = tool
        self.strokeColor = strokeColor
        self.regularStrokeColor = regularStrokeColor
        self.highlighterStrokeColor = highlighterStrokeColor
        self.penStrokeWidth = penStrokeWidth
        self.highlighterStrokeWidth = highlighterStrokeWidth
        self.geometryStrokeWidth = geometryStrokeWidth
        self.penOpacity = penOpacity
        self.geometryOpacity = geometryOpacity
        self.highlighterOpacity = highlighterOpacity
        self.fillColor = fillColor
        self.fillStyle = fillStyle
        self.strokePattern = strokePattern
        self.sloppiness = sloppiness
        self.freehandSloppiness = freehandSloppiness ?? sloppiness
        self.outlinedSloppiness = outlinedSloppiness ?? sloppiness
        self.opacity = opacity
        self.usesLegacyHighlightCompositing = usesLegacyHighlightCompositing
        let requestedPressureMode =
            pressureMode ?? (pressureEnabled ? .tablet : .fixed)
        self.pressureMode = smartDrawEnabled ? .fixed : requestedPressureMode
        self.smoothingEnabled = smoothingEnabled
        self.smartDrawEnabled = smartDrawEnabled
        self.smartDrawSavedPressureMode = smartDrawEnabled
            ? (smartDrawSavedPressureMode ?? (
                requestedPressureMode == .fixed ? nil : requestedPressureMode
            ))
            : nil
        self.roundness = roundness
        self.lineRoute = lineRoute ?? linearRoute
        self.arrowRoute = arrowRoute ?? linearRoute
        self.startArrowhead = startArrowhead
        self.endArrowhead = endArrowhead
        self.arrowheadSize = arrowheadSize
    }

    mutating func selectTool(_ selectedTool: AnnotationTool) {
        setSloppinessForSelectedTool(sloppiness)
        setOpacityForSelectedTool(opacity)
        let arrowheads = AnnotationLinearToolTransition.arrowheads(
            selecting: selectedTool,
            startArrowhead: startArrowhead,
            endArrowhead: endArrowhead
        )
        tool = selectedTool
        sloppiness = scopedSloppiness(for: selectedTool)
        opacity = scopedOpacity(for: selectedTool)
        startArrowhead = arrowheads.start
        endArrowhead = arrowheads.end
    }

    mutating func setSloppinessForSelectedTool(
        _ selectedSloppiness: AnnotationSloppiness
    ) {
        switch tool {
        case .pen:
            freehandSloppiness = selectedSloppiness
            sloppiness = selectedSloppiness
        case .line:
            sloppiness = .architect
        case .rectangle, .diamond, .ellipse, .arrow:
            outlinedSloppiness = selectedSloppiness
            sloppiness = selectedSloppiness
        case .highlighter:
            sloppiness = .architect
        case .hand, .select, .text, .eraser:
            sloppiness = selectedSloppiness
        }
    }

    func scopedSloppiness(for tool: AnnotationTool) -> AnnotationSloppiness {
        switch tool {
        case .pen:
            freehandSloppiness
        case .line:
            .architect
        case .rectangle, .diamond, .ellipse, .arrow:
            outlinedSloppiness
        case .highlighter:
            .architect
        case .hand, .select, .text, .eraser:
            sloppiness
        }
    }

    mutating func synchronizeSelectedSloppiness() {
        sloppiness = scopedSloppiness(for: tool)
    }

    mutating func setOpacityForSelectedTool(_ selectedOpacity: CGFloat) {
        let normalizedOpacity = min(max(selectedOpacity, 0.05), 1)
        switch tool {
        case .pen:
            penOpacity = normalizedOpacity
        case .highlighter:
            highlighterOpacity = normalizedOpacity
        case .line, .rectangle, .diamond, .ellipse, .arrow:
            geometryOpacity = normalizedOpacity
        case .hand, .select, .text, .eraser:
            break
        }
        opacity = normalizedOpacity
    }

    func scopedOpacity(for tool: AnnotationTool) -> CGFloat {
        switch tool {
        case .pen:
            penOpacity ?? (self.tool == .pen ? opacity : 1)
        case .highlighter:
            highlighterOpacity ?? (self.tool == .highlighter ? opacity : 1)
        case .line, .rectangle, .diamond, .ellipse, .arrow:
            geometryOpacity ?? (
                Self.isGeometryTool(self.tool) ? opacity : 1
            )
        case .hand, .select, .text, .eraser:
            opacity
        }
    }

    mutating func synchronizeSelectedOpacity() {
        opacity = scopedOpacity(for: tool)
    }

    init(
        tool: AnnotationTool,
        style: AnnotationStyle,
        smartDrawEnabled: Bool,
        linearRoute: AnnotationLinearRoute,
        startArrowhead: AnnotationArrowhead,
        endArrowhead: AnnotationArrowhead,
        lineRoute: AnnotationLinearRoute? = nil,
        arrowRoute: AnnotationLinearRoute? = nil,
        arrowheadSize: AnnotationArrowheadSize = .small,
        smartDrawSavedPressureMode: AnnotationPressureMode? = nil,
        regularStrokeColor: AnnotationColorValue? = nil,
        highlighterStrokeColor: AnnotationColorValue? = nil,
        penStrokeWidth: CGFloat? = nil,
        highlighterStrokeWidth: CGFloat? = nil,
        geometryStrokeWidth: CGFloat? = nil,
        penOpacity: CGFloat? = nil,
        geometryOpacity: CGFloat? = nil,
        highlighterOpacity: CGFloat? = nil,
        freehandSloppiness: AnnotationSloppiness? = nil,
        outlinedSloppiness: AnnotationSloppiness? = nil
    ) {
        self.init(
            tool: tool,
            strokeColor: style.strokeColor,
            regularStrokeColor: regularStrokeColor,
            highlighterStrokeColor: highlighterStrokeColor,
            penStrokeWidth: penStrokeWidth,
            highlighterStrokeWidth: highlighterStrokeWidth,
            geometryStrokeWidth: geometryStrokeWidth,
            penOpacity: penOpacity,
            geometryOpacity: geometryOpacity,
            highlighterOpacity: highlighterOpacity,
            fillColor: style.fillColor,
            fillStyle: style.fillStyle,
            strokePattern: style.strokePattern,
            sloppiness: style.sloppiness,
            freehandSloppiness: freehandSloppiness,
            outlinedSloppiness: outlinedSloppiness,
            opacity: style.opacity,
            pressureEnabled: style.pressureEnabled,
            pressureMode: style.pressureMode,
            smoothingEnabled: style.smoothingEnabled,
            smartDrawEnabled: smartDrawEnabled,
            smartDrawSavedPressureMode: smartDrawSavedPressureMode,
            roundness: style.roundness,
            linearRoute: linearRoute,
            lineRoute: lineRoute,
            arrowRoute: arrowRoute,
            startArrowhead: startArrowhead,
            endArrowhead: endArrowhead,
            arrowheadSize: arrowheadSize,
            usesLegacyHighlightCompositing: style.usesLegacyHighlightCompositing
        )
    }

    mutating func setSmartDrawEnabled(_ isEnabled: Bool) {
        guard smartDrawEnabled != isEnabled else { return }
        if isEnabled {
            if pressureMode != .fixed {
                smartDrawSavedPressureMode = pressureMode
            }
            pressureMode = .fixed
        } else if let savedMode = smartDrawSavedPressureMode {
            pressureMode = savedMode
            smartDrawSavedPressureMode = nil
        }
        smartDrawEnabled = isEnabled
    }

    mutating func normalizeSmartDrawPressure() {
        guard smartDrawEnabled else {
            smartDrawSavedPressureMode = nil
            return
        }
        if pressureMode != .fixed {
            smartDrawSavedPressureMode = pressureMode
        }
        pressureMode = .fixed
    }

    func annotationStyle(strokeWidth: CGFloat) -> AnnotationStyle {
        var style = AnnotationStyle(
            color: strokeColor.paletteColor ?? .red,
            rootWidth: strokeWidth,
            alpha: scopedOpacity(for: tool),
            fillColor: fillColor,
            fillStyle: fillStyle,
            strokePattern: strokePattern,
            sloppiness: scopedSloppiness(for: tool),
            roundness: roundness,
            pressureEnabled: pressureEnabled,
            pressureMode: pressureMode,
            smoothingEnabled: smoothingEnabled,
            usesLegacyHighlightCompositing: usesLegacyHighlightCompositing
        )
        style.strokeColor = strokeColor
        return style
    }

    private static func isGeometryTool(_ tool: AnnotationTool) -> Bool {
        switch tool {
        case .line, .rectangle, .diamond, .ellipse, .arrow:
            true
        case .hand, .select, .pen, .text, .highlighter, .eraser:
            false
        }
    }
}

struct AppSettings: Equatable {
    var defaultZoomFactor: CGFloat
    var maximumZoomFactor: CGFloat
    var minimumZoomFactor: CGFloat
    var rootPenWidth: CGFloat
    var highlighterWidth: CGFloat
    var drawingToolbarNormalizedPosition: CGPoint?
    var defaultDrawingDefaults: DrawingDefaults
    var rememberLastDrawingStyle: Bool
    var lastDrawingDefaults: DrawingDefaults?
    var animateZoom: Bool
    var smoothImage: Bool
    /// The user's desired launch-at-login state. The actual macOS login item
    /// can temporarily require approval, so this preference is persisted
    /// separately and reconciled on launch.
    var launchAtLogin: Bool
    var typingFontName: String
    var typingFontPreset: AnnotationTextFontPreset
    var typingFontSize: CGFloat
    /// Virtual key code (kVK_*) and NSEvent modifier-flag raw value for the
    /// global "toggle zoom" hotkey.
    var hotKeyCode: Int
    var hotKeyModifiers: UInt
    /// Virtual key code and modifier-flag raw value for the global "draw without
    /// zooming" hotkey.
    var drawHotKeyCode: Int
    var drawHotKeyModifiers: UInt
    /// Virtual key code and modifier-flag raw value for the global "live zoom"
    /// hotkey, which magnifies the live screen instead of a frozen snapshot.
    var liveHotKeyCode: Int
    var liveHotKeyModifiers: UInt
    /// Virtual key code and modifier-flag raw value for the global region snip
    /// hotkey. The base shortcut copies the selected region to the clipboard;
    /// the same shortcut with Shift toggled saves it to a file instead.
    var snipHotKeyCode: Int
    var snipHotKeyModifiers: UInt
    /// Virtual key code and modifier-flag raw value for the global "OCR snip"
    /// hotkey. Selecting a region recognizes its text and copies it to the
    /// clipboard. A key code of 0 disables the hotkey, matching ZoomIt's
    /// SnipOcrToggleKey behavior.
    var snipOcrHotKeyCode: Int
    var snipOcrHotKeyModifiers: UInt
    var recordHotKeyCode: Int
    var recordHotKeyModifiers: UInt
    /// Virtual key code and modifier-flag raw value for DemoType. A key code of
    /// 0 disables the hotkey, matching ZoomIt's default behavior.
    var demoTypeHotKeyCode: Int
    var demoTypeHotKeyModifiers: UInt
    /// DemoType script file path, typing speed slider value, and whether user
    /// keystrokes should drive output.
    var demoTypeFile: String
    var demoTypeSpeed: Int
    var demoTypeUserDriven: Bool
    /// Virtual key code and modifier-flag raw value for the global panorama
    /// (scrolling) capture hotkey. The base shortcut copies the stitched
    /// panorama to the clipboard; the same shortcut with Shift toggled saves it
    /// to a file instead.
    var panoramaHotKeyCode: Int
    var panoramaHotKeyModifiers: UInt
    /// Virtual key code and modifier-flag raw value for the global DemoMirror
    /// hotkey. The base shortcut mirrors the entire screen; the same shortcut
    /// with Shift toggled selects a region to mirror, and with Option toggled
    /// mirrors the window under the cursor.
    var demoMirrorHotKeyCode: Int
    var demoMirrorHotKeyModifiers: UInt
    /// When mirroring a window, whether DemoMirror tracks the window's screen
    /// region (so ZoomIt zoom/draw overlays show in the mirror) instead of
    /// mirroring the window's surface directly.
    var demoMirrorTrackWindowRegion: Bool
    /// Virtual key code and modifier-flag raw value for the global break timer
    /// hotkey.
    var breakHotKeyCode: Int
    var breakHotKeyModifiers: UInt
    /// Break timer duration in whole minutes, matching ZoomIt's options dialog.
    var breakDurationMinutes: Int
    /// Break timer text and solid background colors as 0xRRGGBB values.
    var breakTextColorRGB: UInt32
    var breakBackgroundColorRGB: UInt32
    /// Nine-position grid index: 0 top-left through 8 bottom-right.
    var breakTimerPosition: Int
    /// Overlay opacity percentage, 10 through 100.
    var breakOpacity: Int
    var breakShowExpiredTime: Bool
    var breakPlaySound: Bool
    var breakSoundFile: String
    /// Background mode: 0 none, 1 faded desktop, 2 image file.
    var breakBackgroundMode: Int
    var breakBackgroundStretch: Bool
    var breakBackgroundFile: String
    /// Whether to capture system audio in recordings.
    var recordSystemAudio: Bool
    /// Whether to capture microphone audio in recordings.
    var recordMicrophone: Bool
    /// Whether to request capture-side microphone noise reduction when available.
    var recordNoiseCancellation: Bool
    /// The unique ID of the microphone device to record, or empty for the
    /// system default input.
    var microphoneDeviceID: String
    /// Whether to overlay the webcam as a picture-in-picture in recordings.
    var webcamEnabled: Bool
    /// The unique ID of the camera device, or empty for the default camera.
    var webcamDeviceID: String
    /// Placement: 0 top-left, 1 top-right, 2 bottom-left, 3 bottom-right, 4 center.
    var webcamPosition: Int
    /// Size preset: 0 small, 1 medium, 2 large, 3 x-large, 4 full screen.
    var webcamSize: Int
    /// Border shape: 0 rectangle, 1 rounded rectangle, 2 rounded square, 3 circle.
    var webcamShape: Int
    /// Whether a snipped/screenshot image is also copied to the clipboard when
    /// it is saved to a file. On by default so a saved snip is always available
    /// to paste.
    var copySnipToClipboardOnSave: Bool
    /// Whether saving a snip/screenshot writes directly to `snipSaveDirectory`
    /// with an auto-generated name instead of presenting a Save dialog.
    var saveSnipToDirectory: Bool
    /// Directory used when `saveSnipToDirectory` is on. Empty means the user's
    /// Documents folder.
    var snipSaveDirectory: String

    /// Initial magnification levels offered on the Zoom settings tab, matching
    /// ZoomIt's g_ZoomLevels slider values.
    static let zoomLevels: [CGFloat] = [1.25, 1.5, 1.75, 2.0, 3.0, 4.0]

    static let defaults = AppSettings(
        defaultZoomFactor: 2,
        maximumZoomFactor: 32,
        minimumZoomFactor: 1,
        rootPenWidth: AnnotationStrokeWidthDefaults.pen,
        highlighterWidth: AnnotationStrokeWidthDefaults.highlighter,
        drawingToolbarNormalizedPosition: nil,
        defaultDrawingDefaults: .default,
        rememberLastDrawingStyle: false,
        lastDrawingDefaults: nil,
        animateZoom: true,
        smoothImage: true,
        launchAtLogin: false,
        typingFontName: "",
        typingFontPreset: .system,
        typingFontSize: 20,
        // Control+1 (kVK_ANSI_1 = 18, NSEvent.ModifierFlags.control = 1 << 18).
        hotKeyCode: 18,
        hotKeyModifiers: 1 << 18,
        // Control+2 (kVK_ANSI_2 = 19) toggles draw-without-zoom.
        drawHotKeyCode: 19,
        drawHotKeyModifiers: 1 << 18,
        // Control+4 (kVK_ANSI_4 = 21) toggles live zoom.
        liveHotKeyCode: 21,
        liveHotKeyModifiers: 1 << 18,
        // Control+6 (kVK_ANSI_6 = 22) snips a region to the clipboard;
        // Control+Shift+6 snips a region to a file.
        snipHotKeyCode: 22,
        snipHotKeyModifiers: 1 << 18,
        // Control+Option+6 (kVK_ANSI_6 = 22) recognizes text in a region and
        // copies it to the clipboard, matching ZoomIt's Ctrl+Alt+6 default.
        snipOcrHotKeyCode: 22,
        snipOcrHotKeyModifiers: (1 << 18) | (1 << 19),
        // Control+5 (kVK_ANSI_5 = 23) records the screen;
        // Control+Shift+5 records a selected region.
        recordHotKeyCode: 23,
        recordHotKeyModifiers: 1 << 18,
        // Control+7 (kVK_ANSI_7 = 26) toggles DemoType;
        // Control+Shift+7 resets to the previous [end] segment.
        demoTypeHotKeyCode: 26,
        demoTypeHotKeyModifiers: 1 << 18,
        demoTypeFile: "",
        demoTypeSpeed: 55,
        demoTypeUserDriven: false,
        // Control+8 (kVK_ANSI_8 = 28) captures a panorama to the clipboard;
        // Control+Shift+8 captures a panorama to a file.
        panoramaHotKeyCode: 28,
        panoramaHotKeyModifiers: 1 << 18,
        // Control+9 (kVK_ANSI_9 = 25) mirrors the whole screen;
        // Control+Shift+9 selects a region to mirror;
        // Control+Option+9 mirrors the window under the cursor.
        demoMirrorHotKeyCode: 25,
        demoMirrorHotKeyModifiers: 1 << 18,
        demoMirrorTrackWindowRegion: true,
        // Control+3 (kVK_ANSI_3 = 20) toggles the break timer.
        breakHotKeyCode: 20,
        breakHotKeyModifiers: 1 << 18,
        breakDurationMinutes: 10,
        breakTextColorRGB: 0xFF0000,
        breakBackgroundColorRGB: 0xFFFFFF,
        breakTimerPosition: 4,
        breakOpacity: 100,
        breakShowExpiredTime: true,
        breakPlaySound: false,
        breakSoundFile: "",
        breakBackgroundMode: 0,
        breakBackgroundStretch: false,
        breakBackgroundFile: "",
        recordSystemAudio: false,
        recordMicrophone: false,
        recordNoiseCancellation: false,
        microphoneDeviceID: "",
        webcamEnabled: false,
        webcamDeviceID: "",
        webcamPosition: 3,
        webcamSize: 1,
        webcamShape: 0,
        copySnipToClipboardOnSave: true,
        saveSnipToDirectory: false,
        snipSaveDirectory: ""
    )
}

protocol SettingsStore {
    func load() -> AppSettings
    func save(_ settings: AppSettings)
}

final class UserDefaultsSettingsStore: SettingsStore {
    private static let drawingDefaultsSchemaVersion = 1

    private enum Key {
        static let defaultZoomFactor = "defaultZoomFactor"
        static let maximumZoomFactor = "maximumZoomFactor"
        static let minimumZoomFactor = "minimumZoomFactor"
        static let rootPenWidth = "rootPenWidth"
        static let highlighterWidth = "highlighterWidth"
        static let drawingToolbarNormalizedPosition = "drawingToolbarNormalizedPosition"
        static let defaultDrawingDefaults = "defaultDrawingDefaults"
        static let rememberLastDrawingStyle = "rememberLastDrawingStyle"
        static let lastDrawingDefaults = "lastDrawingDefaults"
        static let animateZoom = "animateZoom"
        static let smoothImage = "smoothImage"
        static let launchAtLogin = "launchAtLogin"
        static let typingFontName = "typingFontName"
        static let typingFontPreset = "typingFontPreset"
        static let typingFontSize = "typingFontSize"
        static let hotKeyCode = "hotKeyCode"
        static let hotKeyModifiers = "hotKeyModifiers"
        static let drawHotKeyCode = "drawHotKeyCode"
        static let drawHotKeyModifiers = "drawHotKeyModifiers"
        static let liveHotKeyCode = "liveHotKeyCode"
        static let liveHotKeyModifiers = "liveHotKeyModifiers"
        static let snipHotKeyCode = "snipHotKeyCode"
        static let snipHotKeyModifiers = "snipHotKeyModifiers"
        static let snipOcrHotKeyCode = "snipOcrHotKeyCode"
        static let snipOcrHotKeyModifiers = "snipOcrHotKeyModifiers"
        static let recordHotKeyCode = "recordHotKeyCode"
        static let recordHotKeyModifiers = "recordHotKeyModifiers"
        static let demoTypeHotKeyCode = "demoTypeHotKeyCode"
        static let demoTypeHotKeyModifiers = "demoTypeHotKeyModifiers"
        static let demoTypeFile = "demoTypeFile"
        static let demoTypeSpeed = "demoTypeSpeed"
        static let demoTypeUserDriven = "demoTypeUserDriven"
        static let panoramaHotKeyCode = "panoramaHotKeyCode"
        static let panoramaHotKeyModifiers = "panoramaHotKeyModifiers"
        static let demoMirrorHotKeyCode = "demoMirrorHotKeyCode"
        static let demoMirrorHotKeyModifiers = "demoMirrorHotKeyModifiers"
        static let demoMirrorTrackWindowRegion = "demoMirrorTrackWindowRegion"
        static let breakHotKeyCode = "breakHotKeyCode"
        static let breakHotKeyModifiers = "breakHotKeyModifiers"
        static let breakDurationMinutes = "breakDurationMinutes"
        static let breakTextColorRGB = "breakTextColorRGB"
        static let breakBackgroundColorRGB = "breakBackgroundColorRGB"
        static let breakTimerPosition = "breakTimerPosition"
        static let breakOpacity = "breakOpacity"
        static let breakShowExpiredTime = "breakShowExpiredTime"
        static let breakPlaySound = "breakPlaySound"
        static let breakSoundFile = "breakSoundFile"
        static let breakBackgroundMode = "breakBackgroundMode"
        static let breakBackgroundStretch = "breakBackgroundStretch"
        static let breakBackgroundFile = "breakBackgroundFile"
        static let recordSystemAudio = "recordSystemAudio"
        static let recordMicrophone = "recordMicrophone"
        static let recordNoiseCancellation = "recordNoiseCancellation"
        static let microphoneDeviceID = "microphoneDeviceID"
        static let webcamEnabled = "webcamEnabled"
        static let webcamDeviceID = "webcamDeviceID"
        static let webcamPosition = "webcamPosition"
        static let webcamSize = "webcamSize"
        static let webcamShape = "webcamShape"
        static let copySnipToClipboardOnSave = "copySnipToClipboardOnSave"
        static let saveSnipToDirectory = "saveSnipToDirectory"
        static let snipSaveDirectory = "snipSaveDirectory"
        static let hasCompletedFirstLaunch = "hasCompletedFirstLaunch"
    }

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    var hasLaunchAtLoginPreference: Bool {
        defaults.object(forKey: Key.launchAtLogin) != nil
    }

    /// Default key AppKit used to persist the status-item slot in builds that set
    /// an `autosaveName`. It reliably indicates the app has run before, so it
    /// doubles as a first-launch migration sentinel for upgrading users even
    /// though current builds no longer set it.
    private static let legacyStatusItemPositionKey =
        "NSStatusItem Preferred Position com.sysinternals.ZoomIt.statusItem"

    /// True once the app has run at least once. Used to show the Settings dialog
    /// on a fresh install so the user has a clear entry point instead of a silent
    /// menu-bar-only launch. Upgrading users who predate this flag are detected
    /// via any pre-existing ZoomIt preference so they don't get an unexpected
    /// Settings pop-up on their first run of a new build.
    var hasCompletedFirstLaunch: Bool {
        if defaults.bool(forKey: Key.hasCompletedFirstLaunch) { return true }
        return hasAnyExistingPreference
    }

    private var hasAnyExistingPreference: Bool {
        defaults.object(forKey: Self.legacyStatusItemPositionKey) != nil ||
            defaults.object(forKey: Key.launchAtLogin) != nil
    }

    func markFirstLaunchCompleted() {
        defaults.set(true, forKey: Key.hasCompletedFirstLaunch)
    }

    func load() -> AppSettings {
        var settings = AppSettings.defaults

        if defaults.object(forKey: Key.defaultZoomFactor) != nil {
            settings.defaultZoomFactor = defaults.double(forKey: Key.defaultZoomFactor)
        }

        if defaults.object(forKey: Key.maximumZoomFactor) != nil {
            settings.maximumZoomFactor = defaults.double(forKey: Key.maximumZoomFactor)
        }

        if defaults.object(forKey: Key.minimumZoomFactor) != nil {
            settings.minimumZoomFactor = defaults.double(forKey: Key.minimumZoomFactor)
        }

        if let width = Self.finiteCGFloat(defaults.object(forKey: Key.rootPenWidth)) {
            settings.rootPenWidth = min(max(width, 1), 64)
        }
        if defaults.object(forKey: Key.highlighterWidth) != nil {
            let width = defaults.double(forKey: Key.highlighterWidth)
            if width.isFinite {
                settings.highlighterWidth = min(max(width, 1), 64)
            }
        }

        if let storedPosition = defaults.dictionary(forKey: Key.drawingToolbarNormalizedPosition) {
            settings.drawingToolbarNormalizedPosition = Self.decodeNormalizedPosition(storedPosition)
        }

        if let storedDefaults = defaults.dictionary(forKey: Key.defaultDrawingDefaults) {
            settings.defaultDrawingDefaults = Self.decodeDrawingDefaults(
                storedDefaults,
                fallback: settings.defaultDrawingDefaults
            )
        }

        if defaults.object(forKey: Key.rememberLastDrawingStyle) != nil {
            settings.rememberLastDrawingStyle = defaults.bool(forKey: Key.rememberLastDrawingStyle)
        }

        if let storedDefaults = defaults.dictionary(forKey: Key.lastDrawingDefaults) {
            settings.lastDrawingDefaults = Self.decodeDrawingDefaults(
                storedDefaults,
                fallback: settings.defaultDrawingDefaults
            )
        }

        if defaults.object(forKey: Key.animateZoom) != nil {
            settings.animateZoom = defaults.bool(forKey: Key.animateZoom)
        }

        if defaults.object(forKey: Key.smoothImage) != nil {
            settings.smoothImage = defaults.bool(forKey: Key.smoothImage)
        }

        if defaults.object(forKey: Key.launchAtLogin) != nil {
            settings.launchAtLogin = defaults.bool(forKey: Key.launchAtLogin)
        }

        if let name = defaults.string(forKey: Key.typingFontName) {
            settings.typingFontName = name
        }

        if let name = defaults.string(forKey: Key.typingFontPreset),
           let preset = AnnotationTextFontPreset(rawValue: name) {
            settings.typingFontPreset = preset
        } else {
            settings.typingFontPreset = AnnotationTextFontPreset.inferred(
                fromStorageFontName: settings.typingFontName
            )
        }

        if defaults.object(forKey: Key.typingFontSize) != nil {
            settings.typingFontSize = defaults.double(forKey: Key.typingFontSize)
        }

        if defaults.object(forKey: Key.hotKeyCode) != nil {
            settings.hotKeyCode = defaults.integer(forKey: Key.hotKeyCode)
        }

        if defaults.object(forKey: Key.hotKeyModifiers) != nil {
            settings.hotKeyModifiers = UInt(bitPattern: defaults.integer(forKey: Key.hotKeyModifiers))
        }

        if defaults.object(forKey: Key.drawHotKeyCode) != nil {
            settings.drawHotKeyCode = defaults.integer(forKey: Key.drawHotKeyCode)
        }

        if defaults.object(forKey: Key.drawHotKeyModifiers) != nil {
            settings.drawHotKeyModifiers = UInt(bitPattern: defaults.integer(forKey: Key.drawHotKeyModifiers))
        }

        if defaults.object(forKey: Key.liveHotKeyCode) != nil {
            settings.liveHotKeyCode = defaults.integer(forKey: Key.liveHotKeyCode)
        }

        if defaults.object(forKey: Key.liveHotKeyModifiers) != nil {
            settings.liveHotKeyModifiers = UInt(bitPattern: defaults.integer(forKey: Key.liveHotKeyModifiers))
        }

        if defaults.object(forKey: Key.snipHotKeyCode) != nil {
            settings.snipHotKeyCode = defaults.integer(forKey: Key.snipHotKeyCode)
        }

        if defaults.object(forKey: Key.snipHotKeyModifiers) != nil {
            settings.snipHotKeyModifiers = UInt(bitPattern: defaults.integer(forKey: Key.snipHotKeyModifiers))
        }

        if defaults.object(forKey: Key.snipOcrHotKeyCode) != nil {
            settings.snipOcrHotKeyCode = defaults.integer(forKey: Key.snipOcrHotKeyCode)
        }

        if defaults.object(forKey: Key.snipOcrHotKeyModifiers) != nil {
            settings.snipOcrHotKeyModifiers = UInt(bitPattern: defaults.integer(forKey: Key.snipOcrHotKeyModifiers))
        }

        if defaults.object(forKey: Key.recordHotKeyCode) != nil {
            settings.recordHotKeyCode = defaults.integer(forKey: Key.recordHotKeyCode)
        }

        if defaults.object(forKey: Key.recordHotKeyModifiers) != nil {
            settings.recordHotKeyModifiers = UInt(bitPattern: defaults.integer(forKey: Key.recordHotKeyModifiers))
        }

        if defaults.object(forKey: Key.demoTypeHotKeyCode) != nil {
            settings.demoTypeHotKeyCode = defaults.integer(forKey: Key.demoTypeHotKeyCode)
        }

        if defaults.object(forKey: Key.demoTypeHotKeyModifiers) != nil {
            settings.demoTypeHotKeyModifiers = UInt(bitPattern: defaults.integer(forKey: Key.demoTypeHotKeyModifiers))
        }

        if let demoTypeFile = defaults.string(forKey: Key.demoTypeFile) {
            settings.demoTypeFile = demoTypeFile
        }

        if defaults.object(forKey: Key.demoTypeSpeed) != nil {
            settings.demoTypeSpeed = min(max(defaults.integer(forKey: Key.demoTypeSpeed), 10), 100)
        }

        if defaults.object(forKey: Key.demoTypeUserDriven) != nil {
            settings.demoTypeUserDriven = defaults.bool(forKey: Key.demoTypeUserDriven)
        }

        if defaults.object(forKey: Key.panoramaHotKeyCode) != nil {
            settings.panoramaHotKeyCode = defaults.integer(forKey: Key.panoramaHotKeyCode)
        }

        if defaults.object(forKey: Key.panoramaHotKeyModifiers) != nil {
            settings.panoramaHotKeyModifiers = UInt(bitPattern: defaults.integer(forKey: Key.panoramaHotKeyModifiers))
        }

        if defaults.object(forKey: Key.demoMirrorHotKeyCode) != nil {
            settings.demoMirrorHotKeyCode = defaults.integer(forKey: Key.demoMirrorHotKeyCode)
        }

        if defaults.object(forKey: Key.demoMirrorHotKeyModifiers) != nil {
            settings.demoMirrorHotKeyModifiers = UInt(bitPattern: defaults.integer(forKey: Key.demoMirrorHotKeyModifiers))
        }

        if defaults.object(forKey: Key.demoMirrorTrackWindowRegion) != nil {
            settings.demoMirrorTrackWindowRegion = defaults.bool(forKey: Key.demoMirrorTrackWindowRegion)
        }

        if defaults.object(forKey: Key.breakHotKeyCode) != nil {
            settings.breakHotKeyCode = defaults.integer(forKey: Key.breakHotKeyCode)
        }

        if defaults.object(forKey: Key.breakHotKeyModifiers) != nil {
            settings.breakHotKeyModifiers = UInt(bitPattern: defaults.integer(forKey: Key.breakHotKeyModifiers))
        }

        if defaults.object(forKey: Key.breakDurationMinutes) != nil {
            settings.breakDurationMinutes = defaults.integer(forKey: Key.breakDurationMinutes)
        }

        if defaults.object(forKey: Key.breakTextColorRGB) != nil {
            settings.breakTextColorRGB = UInt32(defaults.integer(forKey: Key.breakTextColorRGB))
        }

        if defaults.object(forKey: Key.breakBackgroundColorRGB) != nil {
            settings.breakBackgroundColorRGB = UInt32(defaults.integer(forKey: Key.breakBackgroundColorRGB))
        }

        if defaults.object(forKey: Key.breakTimerPosition) != nil {
            settings.breakTimerPosition = defaults.integer(forKey: Key.breakTimerPosition)
        }

        if defaults.object(forKey: Key.breakOpacity) != nil {
            settings.breakOpacity = defaults.integer(forKey: Key.breakOpacity)
        }

        if defaults.object(forKey: Key.breakShowExpiredTime) != nil {
            settings.breakShowExpiredTime = defaults.bool(forKey: Key.breakShowExpiredTime)
        }

        if defaults.object(forKey: Key.breakPlaySound) != nil {
            settings.breakPlaySound = defaults.bool(forKey: Key.breakPlaySound)
        }

        if let soundFile = defaults.string(forKey: Key.breakSoundFile) {
            settings.breakSoundFile = soundFile
        }

        if defaults.object(forKey: Key.breakBackgroundMode) != nil {
            settings.breakBackgroundMode = defaults.integer(forKey: Key.breakBackgroundMode)
        }

        if defaults.object(forKey: Key.breakBackgroundStretch) != nil {
            settings.breakBackgroundStretch = defaults.bool(forKey: Key.breakBackgroundStretch)
        }

        if let backgroundFile = defaults.string(forKey: Key.breakBackgroundFile) {
            settings.breakBackgroundFile = backgroundFile
        }

        if defaults.object(forKey: Key.recordSystemAudio) != nil {
            settings.recordSystemAudio = defaults.bool(forKey: Key.recordSystemAudio)
        }

        if defaults.object(forKey: Key.recordMicrophone) != nil {
            settings.recordMicrophone = defaults.bool(forKey: Key.recordMicrophone)
        }

        if defaults.object(forKey: Key.recordNoiseCancellation) != nil {
            settings.recordNoiseCancellation = defaults.bool(forKey: Key.recordNoiseCancellation)
        }

        if let micID = defaults.string(forKey: Key.microphoneDeviceID) {
            settings.microphoneDeviceID = micID
        }

        if defaults.object(forKey: Key.webcamEnabled) != nil {
            settings.webcamEnabled = defaults.bool(forKey: Key.webcamEnabled)
        }

        if let webcamID = defaults.string(forKey: Key.webcamDeviceID) {
            settings.webcamDeviceID = webcamID
        }

        if defaults.object(forKey: Key.webcamPosition) != nil {
            settings.webcamPosition = defaults.integer(forKey: Key.webcamPosition)
        }

        if defaults.object(forKey: Key.webcamSize) != nil {
            settings.webcamSize = defaults.integer(forKey: Key.webcamSize)
        }

        if defaults.object(forKey: Key.webcamShape) != nil {
            settings.webcamShape = defaults.integer(forKey: Key.webcamShape)
        }

        if defaults.object(forKey: Key.copySnipToClipboardOnSave) != nil {
            settings.copySnipToClipboardOnSave = defaults.bool(forKey: Key.copySnipToClipboardOnSave)
        }

        if defaults.object(forKey: Key.saveSnipToDirectory) != nil {
            settings.saveSnipToDirectory = defaults.bool(forKey: Key.saveSnipToDirectory)
        }

        if let snipSaveDirectory = defaults.string(forKey: Key.snipSaveDirectory) {
            settings.snipSaveDirectory = snipSaveDirectory
        }

        return settings
    }

    func save(_ settings: AppSettings) {
        defaults.set(settings.defaultZoomFactor, forKey: Key.defaultZoomFactor)
        defaults.set(settings.maximumZoomFactor, forKey: Key.maximumZoomFactor)
        defaults.set(settings.minimumZoomFactor, forKey: Key.minimumZoomFactor)
        defaults.set(settings.rootPenWidth, forKey: Key.rootPenWidth)
        defaults.set(settings.highlighterWidth, forKey: Key.highlighterWidth)
        if let position = settings.drawingToolbarNormalizedPosition {
            defaults.set(
                ["x": Double(position.x), "y": Double(position.y)],
                forKey: Key.drawingToolbarNormalizedPosition
            )
        } else {
            defaults.removeObject(forKey: Key.drawingToolbarNormalizedPosition)
        }
        defaults.set(
            Self.encodeDrawingDefaults(settings.defaultDrawingDefaults),
            forKey: Key.defaultDrawingDefaults
        )
        defaults.set(settings.rememberLastDrawingStyle, forKey: Key.rememberLastDrawingStyle)
        if let lastDrawingDefaults = settings.lastDrawingDefaults {
            defaults.set(
                Self.encodeDrawingDefaults(lastDrawingDefaults),
                forKey: Key.lastDrawingDefaults
            )
        } else {
            defaults.removeObject(forKey: Key.lastDrawingDefaults)
        }
        defaults.set(settings.animateZoom, forKey: Key.animateZoom)
        defaults.set(settings.smoothImage, forKey: Key.smoothImage)
        defaults.set(settings.launchAtLogin, forKey: Key.launchAtLogin)
        defaults.set(settings.typingFontName, forKey: Key.typingFontName)
        defaults.set(settings.typingFontPreset.rawValue, forKey: Key.typingFontPreset)
        defaults.set(settings.typingFontSize, forKey: Key.typingFontSize)
        defaults.set(settings.hotKeyCode, forKey: Key.hotKeyCode)
        defaults.set(Int(bitPattern: settings.hotKeyModifiers), forKey: Key.hotKeyModifiers)
        defaults.set(settings.drawHotKeyCode, forKey: Key.drawHotKeyCode)
        defaults.set(Int(bitPattern: settings.drawHotKeyModifiers), forKey: Key.drawHotKeyModifiers)
        defaults.set(settings.liveHotKeyCode, forKey: Key.liveHotKeyCode)
        defaults.set(Int(bitPattern: settings.liveHotKeyModifiers), forKey: Key.liveHotKeyModifiers)
        defaults.set(settings.snipHotKeyCode, forKey: Key.snipHotKeyCode)
        defaults.set(Int(bitPattern: settings.snipHotKeyModifiers), forKey: Key.snipHotKeyModifiers)
        defaults.set(settings.snipOcrHotKeyCode, forKey: Key.snipOcrHotKeyCode)
        defaults.set(Int(bitPattern: settings.snipOcrHotKeyModifiers), forKey: Key.snipOcrHotKeyModifiers)
        defaults.set(settings.recordHotKeyCode, forKey: Key.recordHotKeyCode)
        defaults.set(Int(bitPattern: settings.recordHotKeyModifiers), forKey: Key.recordHotKeyModifiers)
        defaults.set(settings.demoTypeHotKeyCode, forKey: Key.demoTypeHotKeyCode)
        defaults.set(Int(bitPattern: settings.demoTypeHotKeyModifiers), forKey: Key.demoTypeHotKeyModifiers)
        defaults.set(settings.demoTypeFile, forKey: Key.demoTypeFile)
        defaults.set(settings.demoTypeSpeed, forKey: Key.demoTypeSpeed)
        defaults.set(settings.demoTypeUserDriven, forKey: Key.demoTypeUserDriven)
        defaults.set(settings.panoramaHotKeyCode, forKey: Key.panoramaHotKeyCode)
        defaults.set(Int(bitPattern: settings.panoramaHotKeyModifiers), forKey: Key.panoramaHotKeyModifiers)
        defaults.set(settings.demoMirrorHotKeyCode, forKey: Key.demoMirrorHotKeyCode)
        defaults.set(Int(bitPattern: settings.demoMirrorHotKeyModifiers), forKey: Key.demoMirrorHotKeyModifiers)
        defaults.set(settings.demoMirrorTrackWindowRegion, forKey: Key.demoMirrorTrackWindowRegion)
        defaults.set(settings.breakHotKeyCode, forKey: Key.breakHotKeyCode)
        defaults.set(Int(bitPattern: settings.breakHotKeyModifiers), forKey: Key.breakHotKeyModifiers)
        defaults.set(settings.breakDurationMinutes, forKey: Key.breakDurationMinutes)
        defaults.set(Int(settings.breakTextColorRGB), forKey: Key.breakTextColorRGB)
        defaults.set(Int(settings.breakBackgroundColorRGB), forKey: Key.breakBackgroundColorRGB)
        defaults.set(settings.breakTimerPosition, forKey: Key.breakTimerPosition)
        defaults.set(settings.breakOpacity, forKey: Key.breakOpacity)
        defaults.set(settings.breakShowExpiredTime, forKey: Key.breakShowExpiredTime)
        defaults.set(settings.breakPlaySound, forKey: Key.breakPlaySound)
        defaults.set(settings.breakSoundFile, forKey: Key.breakSoundFile)
        defaults.set(settings.breakBackgroundMode, forKey: Key.breakBackgroundMode)
        defaults.set(settings.breakBackgroundStretch, forKey: Key.breakBackgroundStretch)
        defaults.set(settings.breakBackgroundFile, forKey: Key.breakBackgroundFile)
        defaults.set(settings.recordSystemAudio, forKey: Key.recordSystemAudio)
        defaults.set(settings.recordMicrophone, forKey: Key.recordMicrophone)
        defaults.set(settings.recordNoiseCancellation, forKey: Key.recordNoiseCancellation)
        defaults.set(settings.microphoneDeviceID, forKey: Key.microphoneDeviceID)
        defaults.set(settings.webcamEnabled, forKey: Key.webcamEnabled)
        defaults.set(settings.webcamDeviceID, forKey: Key.webcamDeviceID)
        defaults.set(settings.webcamPosition, forKey: Key.webcamPosition)
        defaults.set(settings.webcamSize, forKey: Key.webcamSize)
        defaults.set(settings.webcamShape, forKey: Key.webcamShape)
        defaults.set(settings.copySnipToClipboardOnSave, forKey: Key.copySnipToClipboardOnSave)
        defaults.set(settings.saveSnipToDirectory, forKey: Key.saveSnipToDirectory)
        defaults.set(settings.snipSaveDirectory, forKey: Key.snipSaveDirectory)
    }

    private static func encodeDrawingDefaults(_ drawingDefaults: DrawingDefaults) -> [String: Any] {
        var drawingDefaults = drawingDefaults
        drawingDefaults.normalizeSmartDrawPressure()
        var encoded: [String: Any] = [
            "schemaVersion": drawingDefaultsSchemaVersion,
            "tool": toolName(drawingDefaults.tool),
            "strokeColor": encodeColor(drawingDefaults.strokeColor),
            "fillColor": encodeColor(drawingDefaults.fillColor),
            "fillStyle": fillStyleName(drawingDefaults.fillStyle),
            "strokePattern": strokePatternName(drawingDefaults.strokePattern),
            "sloppiness": drawingDefaults.scopedSloppiness(
                for: drawingDefaults.tool
            ).rawValue,
            "freehandSloppiness": drawingDefaults.freehandSloppiness.rawValue,
            "outlinedSloppiness": drawingDefaults.outlinedSloppiness.rawValue,
            "opacity": Double(
                drawingDefaults.scopedOpacity(for: drawingDefaults.tool)
            ),
            "usesLegacyHighlightCompositing": drawingDefaults.usesLegacyHighlightCompositing,
            "pressureMode": drawingDefaults.pressureMode.rawValue,
            "smoothingEnabled": drawingDefaults.smoothingEnabled,
            "smartDrawEnabled": drawingDefaults.smartDrawEnabled,
            "lineRoute": linearRouteName(drawingDefaults.lineRoute),
            "arrowRoute": linearRouteName(drawingDefaults.arrowRoute),
            "startArrowhead": arrowheadName(drawingDefaults.startArrowhead),
            "endArrowhead": arrowheadName(drawingDefaults.endArrowhead),
            "arrowheadSize": drawingDefaults.arrowheadSize.rawValue
        ]
        if let savedPressureMode = drawingDefaults.smartDrawSavedPressureMode {
            encoded["smartDrawSavedPressureMode"] = savedPressureMode.rawValue
        }
        if let regularStrokeColor = drawingDefaults.regularStrokeColor {
            encoded["regularStrokeColor"] = encodeColor(regularStrokeColor)
        }
        if let highlighterStrokeColor = drawingDefaults.highlighterStrokeColor {
            encoded["highlighterStrokeColor"] = encodeColor(highlighterStrokeColor)
        }
        if let penStrokeWidth = drawingDefaults.penStrokeWidth {
            encoded["penStrokeWidth"] = Double(penStrokeWidth)
        }
        if let highlighterStrokeWidth = drawingDefaults.highlighterStrokeWidth {
            encoded["highlighterStrokeWidth"] = Double(highlighterStrokeWidth)
        }
        if let geometryStrokeWidth = drawingDefaults.geometryStrokeWidth {
            encoded["geometryStrokeWidth"] = Double(geometryStrokeWidth)
        }
        if let penOpacity = drawingDefaults.penOpacity {
            encoded["penOpacity"] = Double(penOpacity)
        }
        if let geometryOpacity = drawingDefaults.geometryOpacity {
            encoded["geometryOpacity"] = Double(geometryOpacity)
        }
        if let highlighterOpacity = drawingDefaults.highlighterOpacity {
            encoded["highlighterOpacity"] = Double(highlighterOpacity)
        }
        if let roundness = drawingDefaults.roundness {
            encoded["roundness"] = Double(roundness)
        }
        return encoded
    }

    private static func decodeDrawingDefaults(
        _ encoded: [String: Any],
        fallback: DrawingDefaults
    ) -> DrawingDefaults {
        guard (encoded["schemaVersion"] as? NSNumber)?.intValue
            == drawingDefaultsSchemaVersion else {
            return fallback
        }

        var decoded = fallback
        if let name = encoded["tool"] as? String, let tool = tool(named: name) {
            decoded.tool = tool
        }
        if let color = decodeColor(encoded["strokeColor"]) {
            decoded.strokeColor = color
        }
        decoded.regularStrokeColor = decodeColor(encoded["regularStrokeColor"])
        decoded.highlighterStrokeColor = decodeColor(encoded["highlighterStrokeColor"])
        decoded.penStrokeWidth = finiteCGFloat(encoded["penStrokeWidth"]).map {
            min(max($0, 1), 64)
        }
        decoded.highlighterStrokeWidth = finiteCGFloat(
            encoded["highlighterStrokeWidth"]
        ).map {
            min(max($0, 1), 64)
        }
        decoded.geometryStrokeWidth = finiteCGFloat(
            encoded["geometryStrokeWidth"]
        ).map {
            min(max($0, 1), 64)
        }
        decoded.penOpacity = finiteCGFloat(encoded["penOpacity"]).map {
            min(max($0, 0.05), 1)
        }
        decoded.geometryOpacity = finiteCGFloat(encoded["geometryOpacity"]).map {
            min(max($0, 0.05), 1)
        }
        decoded.highlighterOpacity = finiteCGFloat(
            encoded["highlighterOpacity"]
        ).map {
            min(max($0, 0.05), 1)
        }
        if let color = decodeColor(encoded["fillColor"]) {
            decoded.fillColor = color
        }
        if let name = encoded["fillStyle"] as? String, let fillStyle = fillStyle(named: name) {
            decoded.fillStyle = fillStyle
        }
        if let name = encoded["strokePattern"] as? String,
           let strokePattern = strokePattern(named: name) {
            decoded.strokePattern = strokePattern
        }
        decoded.sloppiness = annotationSloppiness(encoded["sloppiness"])
            ?? decoded.sloppiness
        decoded.freehandSloppiness = annotationSloppiness(
            encoded["freehandSloppiness"]
        ) ?? decoded.freehandSloppiness
        decoded.outlinedSloppiness = annotationSloppiness(
            encoded["outlinedSloppiness"]
        ) ?? decoded.outlinedSloppiness
        decoded.synchronizeSelectedSloppiness()
        if let opacity = finiteCGFloat(encoded["opacity"]) {
            decoded.opacity = min(max(opacity, 0.05), 1)
        }
        decoded.synchronizeSelectedOpacity()
        if let usesLegacyHighlightCompositing =
            (encoded["usesLegacyHighlightCompositing"] as? NSNumber)?.boolValue {
            decoded.usesLegacyHighlightCompositing = usesLegacyHighlightCompositing
        }
        if let name = encoded["pressureMode"] as? String,
           let pressureMode = AnnotationPressureMode(rawValue: name) {
            decoded.pressureMode = pressureMode
        }
        if let smoothingEnabled = (encoded["smoothingEnabled"] as? NSNumber)?.boolValue {
            decoded.smoothingEnabled = smoothingEnabled
        }
        if let smartDrawEnabled = (encoded["smartDrawEnabled"] as? NSNumber)?.boolValue {
            decoded.smartDrawEnabled = smartDrawEnabled
        }
        if let name = encoded["smartDrawSavedPressureMode"] as? String,
           let savedMode = AnnotationPressureMode(rawValue: name),
           savedMode != .fixed {
            decoded.smartDrawSavedPressureMode = savedMode
        }
        decoded.roundness = finiteCGFloat(encoded["roundness"]).map {
            max($0, 0)
        }
        if let name = encoded["lineRoute"] as? String,
           let route = linearRoute(named: name) {
            decoded.lineRoute = route
        }
        if let name = encoded["arrowRoute"] as? String,
           let route = linearRoute(named: name) {
            decoded.arrowRoute = route
        }
        if let name = encoded["startArrowhead"] as? String,
           let arrowhead = arrowhead(named: name) {
            decoded.startArrowhead = arrowhead
        }
        if let name = encoded["endArrowhead"] as? String,
           let arrowhead = arrowhead(named: name) {
            decoded.endArrowhead = arrowhead
        }
        if let name = encoded["arrowheadSize"] as? String,
           let size = AnnotationArrowheadSize(rawValue: name) {
            decoded.arrowheadSize = size
        }
        decoded.normalizeSmartDrawPressure()
        return decoded
    }

    private static func annotationSloppiness(
        _ value: Any?
    ) -> AnnotationSloppiness? {
        guard let rawValue = (value as? NSNumber)?.intValue else {
            return nil
        }
        return AnnotationSloppiness(rawValue: rawValue)
    }

    private static func encodeColor(_ color: AnnotationColorValue) -> [String: Any] {
        switch color {
        case .palette(let palette):
            return ["palette": palette.rawValue]
        case .rgba(let red, let green, let blue, let alpha):
            return [
                "red": Double(red),
                "green": Double(green),
                "blue": Double(blue),
                "alpha": Double(alpha)
            ]
        }
    }

    private static func decodeColor(_ value: Any?) -> AnnotationColorValue? {
        guard let encoded = value as? [String: Any] else { return nil }
        if let name = encoded["palette"] as? String, let palette = AnnotationColor(rawValue: name) {
            return .palette(palette)
        }
        guard let red = finiteCGFloat(encoded["red"]),
              let green = finiteCGFloat(encoded["green"]),
              let blue = finiteCGFloat(encoded["blue"]),
              let alpha = finiteCGFloat(encoded["alpha"]) else {
            return nil
        }
        return .rgba(
            red: min(max(red, 0), 1),
            green: min(max(green, 0), 1),
            blue: min(max(blue, 0), 1),
            alpha: min(max(alpha, 0), 1)
        )
    }

    private static func decodeNormalizedPosition(_ encoded: [String: Any]) -> CGPoint? {
        guard let x = finiteCGFloat(encoded["x"]), let y = finiteCGFloat(encoded["y"]) else {
            return nil
        }
        return CGPoint(x: min(max(x, 0), 1), y: min(max(y, 0), 1))
    }

    private static func finiteCGFloat(_ value: Any?) -> CGFloat? {
        guard let number = value as? NSNumber else { return nil }
        let result = CGFloat(number.doubleValue)
        return result.isFinite ? result : nil
    }

    private static func toolName(_ tool: AnnotationTool) -> String {
        switch tool {
        case .hand: "hand"
        case .select: "select"
        case .pen: "pen"
        case .line: "line"
        case .rectangle: "rectangle"
        case .diamond: "diamond"
        case .ellipse: "ellipse"
        case .arrow: "arrow"
        case .text: "text"
        case .highlighter: "highlighter"
        case .eraser: "eraser"
        }
    }

    private static func tool(named name: String) -> AnnotationTool? {
        switch name {
        case "hand": .hand
        case "select": .select
        case "pen": .pen
        case "line": .line
        case "rectangle": .rectangle
        case "diamond": .diamond
        case "ellipse": .ellipse
        case "arrow": .arrow
        case "text": .text
        case "highlighter": .highlighter
        case "eraser": .eraser
        default: nil
        }
    }

    private static func fillStyleName(_ fillStyle: AnnotationFillStyle) -> String {
        switch fillStyle {
        case .none: "none"
        case .hachure: "hachure"
        case .crossHatch: "crossHatch"
        case .solid: "solid"
        }
    }

    private static func fillStyle(named name: String) -> AnnotationFillStyle? {
        switch name {
        case "none": AnnotationFillStyle.none
        case "hachure": .hachure
        case "crossHatch", "cross-hatch": .crossHatch
        case "solid": .solid
        default: nil
        }
    }

    private static func strokePatternName(_ pattern: AnnotationStrokePattern) -> String {
        switch pattern {
        case .solid: "solid"
        case .dashed: "dashed"
        case .dotted: "dotted"
        }
    }

    private static func strokePattern(named name: String) -> AnnotationStrokePattern? {
        switch name {
        case "solid": .solid
        case "dashed": .dashed
        case "dotted": .dotted
        default: nil
        }
    }

    private static func linearRouteName(_ route: AnnotationLinearRoute) -> String {
        switch route {
        case .straight: "straight"
        case .curved: "curved"
        }
    }

    private static func linearRoute(named name: String) -> AnnotationLinearRoute? {
        switch name {
        case "straight": .straight
        case "curved": .curved
        default: nil
        }
    }

    private static func arrowheadName(_ arrowhead: AnnotationArrowhead) -> String {
        switch arrowhead {
        case .none: "none"
        case .arrow: "arrow"
        case .triangle: "triangle"
        case .triangleOutline: "triangleOutline"
        case .circle: "circle"
        case .circleOutline: "circleOutline"
        case .bar: "bar"
        case .diamond: "diamond"
        case .diamondOutline: "diamondOutline"
        case .crowFoot: "crowFoot"
        case .oneOrMany: "oneOrMany"
        case .zeroOrOne: "zeroOrOne"
        case .zeroOrMany: "zeroOrMany"
        }
    }

    private static func arrowhead(named name: String) -> AnnotationArrowhead? {
        switch name {
        case "none": AnnotationArrowhead.none
        case "arrow": .arrow
        case "triangle": .triangle
        case "triangleOutline", "triangle-outline": .triangleOutline
        case "circle": .circle
        case "circleOutline", "circle-outline": .circleOutline
        case "bar": .bar
        case "diamond": .diamond
        case "diamondOutline", "diamond-outline": .diamondOutline
        case "crowFoot", "crow-foot", "many": .crowFoot
        case "oneOrMany", "one-or-many": .oneOrMany
        case "zeroOrOne", "zero-or-one": .zeroOrOne
        case "zeroOrMany", "zero-or-many": .zeroOrMany
        default: nil
        }
    }
}