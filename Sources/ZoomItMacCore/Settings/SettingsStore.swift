import Foundation

struct AppSettings: Equatable {
    var defaultZoomFactor: CGFloat
    var maximumZoomFactor: CGFloat
    var minimumZoomFactor: CGFloat
    var rootPenWidth: CGFloat
    var animateZoom: Bool
    var smoothImage: Bool
    /// The user's desired launch-at-login state. The actual macOS login item
    /// can temporarily require approval, so this preference is persisted
    /// separately and reconciled on launch.
    var launchAtLogin: Bool
    var typingFontName: String
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
    /// Virtual key code and modifier-flag raw value for the global screen
    /// recording hotkey. The base shortcut records the whole screen; the same
    /// shortcut with Shift toggled records a selected region.
    var recordHotKeyCode: Int
    var recordHotKeyModifiers: UInt
    /// Virtual key code and modifier-flag raw value for the global panorama
    /// (scrolling) capture hotkey. The base shortcut copies the stitched
    /// panorama to the clipboard; the same shortcut with Shift toggled saves it
    /// to a file instead.
    var panoramaHotKeyCode: Int
    var panoramaHotKeyModifiers: UInt
    /// Whether to capture system audio in recordings.
    var recordSystemAudio: Bool
    /// Whether to capture microphone audio in recordings.
    var recordMicrophone: Bool
    /// The unique ID of the microphone device to record, or empty for the
    /// system default input.
    var microphoneDeviceID: String
    /// Whether to overlay the webcam as a picture-in-picture in recordings.
    var webcamEnabled: Bool
    /// The unique ID of the camera device, or empty for the default camera.
    var webcamDeviceID: String
    /// Corner placement: 0 top-left, 1 top-right, 2 bottom-left, 3 bottom-right.
    var webcamPosition: Int
    /// Size preset: 0 small, 1 medium, 2 large, 3 x-large, 4 full screen.
    var webcamSize: Int
    /// Border shape: 0 rectangle, 1 rounded rectangle, 2 rounded square, 3 circle.
    var webcamShape: Int

    /// Initial magnification levels offered on the Zoom settings tab, matching
    /// ZoomIt's g_ZoomLevels slider values.
    static let zoomLevels: [CGFloat] = [1.25, 1.5, 1.75, 2.0, 3.0, 4.0]

    static let defaults = AppSettings(
        defaultZoomFactor: 2,
        maximumZoomFactor: 32,
        minimumZoomFactor: 1,
        rootPenWidth: 5,
        animateZoom: true,
        smoothImage: true,
        launchAtLogin: false,
        typingFontName: "",
        typingFontSize: 36,
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
        // Control+5 (kVK_ANSI_5 = 23) records the screen;
        // Control+Shift+5 records a selected region.
        recordHotKeyCode: 23,
        recordHotKeyModifiers: 1 << 18,
        // Control+8 (kVK_ANSI_8 = 28) captures a panorama to the clipboard;
        // Control+Shift+8 captures a panorama to a file.
        panoramaHotKeyCode: 28,
        panoramaHotKeyModifiers: 1 << 18,
        recordSystemAudio: false,
        recordMicrophone: false,
        microphoneDeviceID: "",
        webcamEnabled: false,
        webcamDeviceID: "",
        webcamPosition: 3,
        webcamSize: 1,
        webcamShape: 0
    )
}

protocol SettingsStore {
    func load() -> AppSettings
    func save(_ settings: AppSettings)
}

final class UserDefaultsSettingsStore: SettingsStore {
    private enum Key {
        static let defaultZoomFactor = "defaultZoomFactor"
        static let maximumZoomFactor = "maximumZoomFactor"
        static let minimumZoomFactor = "minimumZoomFactor"
        static let rootPenWidth = "rootPenWidth"
        static let animateZoom = "animateZoom"
        static let smoothImage = "smoothImage"
        static let launchAtLogin = "launchAtLogin"
        static let typingFontName = "typingFontName"
        static let typingFontSize = "typingFontSize"
        static let hotKeyCode = "hotKeyCode"
        static let hotKeyModifiers = "hotKeyModifiers"
        static let drawHotKeyCode = "drawHotKeyCode"
        static let drawHotKeyModifiers = "drawHotKeyModifiers"
        static let liveHotKeyCode = "liveHotKeyCode"
        static let liveHotKeyModifiers = "liveHotKeyModifiers"
        static let snipHotKeyCode = "snipHotKeyCode"
        static let snipHotKeyModifiers = "snipHotKeyModifiers"
        static let recordHotKeyCode = "recordHotKeyCode"
        static let recordHotKeyModifiers = "recordHotKeyModifiers"
        static let panoramaHotKeyCode = "panoramaHotKeyCode"
        static let panoramaHotKeyModifiers = "panoramaHotKeyModifiers"
        static let recordSystemAudio = "recordSystemAudio"
        static let recordMicrophone = "recordMicrophone"
        static let microphoneDeviceID = "microphoneDeviceID"
        static let webcamEnabled = "webcamEnabled"
        static let webcamDeviceID = "webcamDeviceID"
        static let webcamPosition = "webcamPosition"
        static let webcamSize = "webcamSize"
        static let webcamShape = "webcamShape"
    }

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    var hasLaunchAtLoginPreference: Bool {
        defaults.object(forKey: Key.launchAtLogin) != nil
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

        if defaults.object(forKey: Key.rootPenWidth) != nil {
            settings.rootPenWidth = defaults.double(forKey: Key.rootPenWidth)
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

        if defaults.object(forKey: Key.recordHotKeyCode) != nil {
            settings.recordHotKeyCode = defaults.integer(forKey: Key.recordHotKeyCode)
        }

        if defaults.object(forKey: Key.recordHotKeyModifiers) != nil {
            settings.recordHotKeyModifiers = UInt(bitPattern: defaults.integer(forKey: Key.recordHotKeyModifiers))
        }

        if defaults.object(forKey: Key.panoramaHotKeyCode) != nil {
            settings.panoramaHotKeyCode = defaults.integer(forKey: Key.panoramaHotKeyCode)
        }

        if defaults.object(forKey: Key.panoramaHotKeyModifiers) != nil {
            settings.panoramaHotKeyModifiers = UInt(bitPattern: defaults.integer(forKey: Key.panoramaHotKeyModifiers))
        }

        if defaults.object(forKey: Key.recordSystemAudio) != nil {
            settings.recordSystemAudio = defaults.bool(forKey: Key.recordSystemAudio)
        }

        if defaults.object(forKey: Key.recordMicrophone) != nil {
            settings.recordMicrophone = defaults.bool(forKey: Key.recordMicrophone)
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

        return settings
    }

    func save(_ settings: AppSettings) {
        defaults.set(settings.defaultZoomFactor, forKey: Key.defaultZoomFactor)
        defaults.set(settings.maximumZoomFactor, forKey: Key.maximumZoomFactor)
        defaults.set(settings.minimumZoomFactor, forKey: Key.minimumZoomFactor)
        defaults.set(settings.rootPenWidth, forKey: Key.rootPenWidth)
        defaults.set(settings.animateZoom, forKey: Key.animateZoom)
        defaults.set(settings.smoothImage, forKey: Key.smoothImage)
        defaults.set(settings.launchAtLogin, forKey: Key.launchAtLogin)
        defaults.set(settings.typingFontName, forKey: Key.typingFontName)
        defaults.set(settings.typingFontSize, forKey: Key.typingFontSize)
        defaults.set(settings.hotKeyCode, forKey: Key.hotKeyCode)
        defaults.set(Int(bitPattern: settings.hotKeyModifiers), forKey: Key.hotKeyModifiers)
        defaults.set(settings.drawHotKeyCode, forKey: Key.drawHotKeyCode)
        defaults.set(Int(bitPattern: settings.drawHotKeyModifiers), forKey: Key.drawHotKeyModifiers)
        defaults.set(settings.liveHotKeyCode, forKey: Key.liveHotKeyCode)
        defaults.set(Int(bitPattern: settings.liveHotKeyModifiers), forKey: Key.liveHotKeyModifiers)
        defaults.set(settings.snipHotKeyCode, forKey: Key.snipHotKeyCode)
        defaults.set(Int(bitPattern: settings.snipHotKeyModifiers), forKey: Key.snipHotKeyModifiers)
        defaults.set(settings.recordHotKeyCode, forKey: Key.recordHotKeyCode)
        defaults.set(Int(bitPattern: settings.recordHotKeyModifiers), forKey: Key.recordHotKeyModifiers)
        defaults.set(settings.panoramaHotKeyCode, forKey: Key.panoramaHotKeyCode)
        defaults.set(Int(bitPattern: settings.panoramaHotKeyModifiers), forKey: Key.panoramaHotKeyModifiers)
        defaults.set(settings.recordSystemAudio, forKey: Key.recordSystemAudio)
        defaults.set(settings.recordMicrophone, forKey: Key.recordMicrophone)
        defaults.set(settings.microphoneDeviceID, forKey: Key.microphoneDeviceID)
        defaults.set(settings.webcamEnabled, forKey: Key.webcamEnabled)
        defaults.set(settings.webcamDeviceID, forKey: Key.webcamDeviceID)
        defaults.set(settings.webcamPosition, forKey: Key.webcamPosition)
        defaults.set(settings.webcamSize, forKey: Key.webcamSize)
        defaults.set(settings.webcamShape, forKey: Key.webcamShape)
    }
}