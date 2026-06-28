import Foundation

struct AppSettings: Equatable {
    var defaultZoomFactor: CGFloat
    var maximumZoomFactor: CGFloat
    var minimumZoomFactor: CGFloat
    var rootPenWidth: CGFloat
    var animateZoom: Bool
    var smoothImage: Bool
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
        typingFontName: "",
        typingFontSize: 36,
        // Control+1 (kVK_ANSI_1 = 18, NSEvent.ModifierFlags.control = 1 << 18).
        hotKeyCode: 18,
        hotKeyModifiers: 1 << 18,
        // Control+2 (kVK_ANSI_2 = 19) toggles draw-without-zoom.
        drawHotKeyCode: 19,
        drawHotKeyModifiers: 1 << 18
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
        static let typingFontName = "typingFontName"
        static let typingFontSize = "typingFontSize"
        static let hotKeyCode = "hotKeyCode"
        static let hotKeyModifiers = "hotKeyModifiers"
        static let drawHotKeyCode = "drawHotKeyCode"
        static let drawHotKeyModifiers = "drawHotKeyModifiers"
    }

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
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

        return settings
    }

    func save(_ settings: AppSettings) {
        defaults.set(settings.defaultZoomFactor, forKey: Key.defaultZoomFactor)
        defaults.set(settings.maximumZoomFactor, forKey: Key.maximumZoomFactor)
        defaults.set(settings.minimumZoomFactor, forKey: Key.minimumZoomFactor)
        defaults.set(settings.rootPenWidth, forKey: Key.rootPenWidth)
        defaults.set(settings.animateZoom, forKey: Key.animateZoom)
        defaults.set(settings.smoothImage, forKey: Key.smoothImage)
        defaults.set(settings.typingFontName, forKey: Key.typingFontName)
        defaults.set(settings.typingFontSize, forKey: Key.typingFontSize)
        defaults.set(settings.hotKeyCode, forKey: Key.hotKeyCode)
        defaults.set(Int(bitPattern: settings.hotKeyModifiers), forKey: Key.hotKeyModifiers)
        defaults.set(settings.drawHotKeyCode, forKey: Key.drawHotKeyCode)
        defaults.set(Int(bitPattern: settings.drawHotKeyModifiers), forKey: Key.drawHotKeyModifiers)
    }
}