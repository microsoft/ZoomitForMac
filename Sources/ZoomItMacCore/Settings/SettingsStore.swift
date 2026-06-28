import Foundation

struct AppSettings: Equatable {
    var defaultZoomFactor: CGFloat
    var maximumZoomFactor: CGFloat
    var minimumZoomFactor: CGFloat
    var rootPenWidth: CGFloat

    static let defaults = AppSettings(
        defaultZoomFactor: 2,
        maximumZoomFactor: 32,
        minimumZoomFactor: 1,
        rootPenWidth: 5
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

        return settings
    }

    func save(_ settings: AppSettings) {
        defaults.set(settings.defaultZoomFactor, forKey: Key.defaultZoomFactor)
        defaults.set(settings.maximumZoomFactor, forKey: Key.maximumZoomFactor)
        defaults.set(settings.minimumZoomFactor, forKey: Key.minimumZoomFactor)
        defaults.set(settings.rootPenWidth, forKey: Key.rootPenWidth)
    }
}