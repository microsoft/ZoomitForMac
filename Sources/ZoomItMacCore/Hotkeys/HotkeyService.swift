import AppKit
import Carbon.HIToolbox

@MainActor
final class HotkeyService {
    private let settingsStore: SettingsStore
    private let commandHandler: (AppCommand) -> Void
    private var hotKeyRef: EventHotKeyRef?
    private var drawHotKeyRef: EventHotKeyRef?
    private var liveHotKeyRef: EventHotKeyRef?
    private var zoomInNavRef: EventHotKeyRef?
    private var zoomOutNavRef: EventHotKeyRef?
    private var eventHandlerRef: EventHandlerRef?

    init(settingsStore: SettingsStore, commandHandler: @escaping (AppCommand) -> Void) {
        self.settingsStore = settingsStore
        self.commandHandler = commandHandler
    }

    func start() {
        installEventHandlerIfNeeded()
        registerHotKey()
    }

    /// Re-registers the global hotkey from the latest saved settings. Call this
    /// after the user changes the shortcut in the settings dialog.
    func reloadHotkey() {
        registerHotKey()
    }

    func stop() {
        unregisterHotKey()
        endLiveZoomNavigation()
        if let eventHandlerRef {
            RemoveEventHandler(eventHandlerRef)
        }
        eventHandlerRef = nil
    }

    /// Registers Option+Up / Option+Down as global hotkeys for the duration of
    /// live zoom so they zoom in and out. They are registered globally (rather
    /// than handled by the overlay) so they fire even though the overlay is the
    /// key window. Option+arrows is used instead of Control+arrows because macOS
    /// reserves Control+Up/Down for Mission Control / App Exposé and will not
    /// yield them to a registered hotkey.
    func beginLiveZoomNavigation() {
        installEventHandlerIfNeeded()
        let target = GetApplicationEventTarget()
        let signature = fourCharacterCode("ZITM")

        endLiveZoomNavigation()
        RegisterEventHotKey(
            UInt32(kVK_UpArrow),
            UInt32(optionKey),
            EventHotKeyID(signature: signature, id: 4),
            target,
            0,
            &zoomInNavRef
        )
        RegisterEventHotKey(
            UInt32(kVK_DownArrow),
            UInt32(optionKey),
            EventHotKeyID(signature: signature, id: 5),
            target,
            0,
            &zoomOutNavRef
        )
    }

    func endLiveZoomNavigation() {
        if let zoomInNavRef {
            UnregisterEventHotKey(zoomInNavRef)
        }
        zoomInNavRef = nil
        if let zoomOutNavRef {
            UnregisterEventHotKey(zoomOutNavRef)
        }
        zoomOutNavRef = nil
    }

    private func installEventHandlerIfNeeded() {
        guard eventHandlerRef == nil else { return }

        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )
        let selfPointer = Unmanaged.passUnretained(self).toOpaque()

        InstallEventHandler(
            GetApplicationEventTarget(),
            { _, event, userData in
                guard let event, let userData else { return noErr }

                var hotKeyID = EventHotKeyID()
                let parameterStatus = GetEventParameter(
                    event,
                    EventParamName(kEventParamDirectObject),
                    EventParamType(typeEventHotKeyID),
                    nil,
                    MemoryLayout<EventHotKeyID>.size,
                    nil,
                    &hotKeyID
                )
                guard parameterStatus == noErr else { return parameterStatus }

                let command: AppCommand
                switch hotKeyID.id {
                case 1: command = .activateStaticZoom
                case 2: command = .activateDrawWithoutZoom
                case 3: command = .activateLiveZoom
                case 4: command = .zoomIn
                case 5: command = .zoomOutOrExit
                default: return noErr
                }

                let service = Unmanaged<HotkeyService>.fromOpaque(userData).takeUnretainedValue()
                Task { @MainActor in
                    service.commandHandler(command)
                }
                return noErr
            },
            1,
            &eventType,
            selfPointer,
            &eventHandlerRef
        )
    }

    private func registerHotKey() {
        unregisterHotKey()

        let settings = settingsStore.load()
        let target = GetApplicationEventTarget()
        let signature = fourCharacterCode("ZITM")

        let zoomModifiers = NSEvent.ModifierFlags(rawValue: settings.hotKeyModifiers)
        RegisterEventHotKey(
            UInt32(settings.hotKeyCode),
            carbonModifiers(from: zoomModifiers),
            EventHotKeyID(signature: signature, id: 1),
            target,
            0,
            &hotKeyRef
        )

        let drawModifiers = NSEvent.ModifierFlags(rawValue: settings.drawHotKeyModifiers)
        RegisterEventHotKey(
            UInt32(settings.drawHotKeyCode),
            carbonModifiers(from: drawModifiers),
            EventHotKeyID(signature: signature, id: 2),
            target,
            0,
            &drawHotKeyRef
        )

        let liveModifiers = NSEvent.ModifierFlags(rawValue: settings.liveHotKeyModifiers)
        RegisterEventHotKey(
            UInt32(settings.liveHotKeyCode),
            carbonModifiers(from: liveModifiers),
            EventHotKeyID(signature: signature, id: 3),
            target,
            0,
            &liveHotKeyRef
        )
    }

    private func unregisterHotKey() {
        if let hotKeyRef {
            UnregisterEventHotKey(hotKeyRef)
        }
        hotKeyRef = nil
        if let drawHotKeyRef {
            UnregisterEventHotKey(drawHotKeyRef)
        }
        drawHotKeyRef = nil
        if let liveHotKeyRef {
            UnregisterEventHotKey(liveHotKeyRef)
        }
        liveHotKeyRef = nil
    }

    private func carbonModifiers(from flags: NSEvent.ModifierFlags) -> UInt32 {
        var carbon: UInt32 = 0
        if flags.contains(.command) { carbon |= UInt32(cmdKey) }
        if flags.contains(.option) { carbon |= UInt32(optionKey) }
        if flags.contains(.control) { carbon |= UInt32(controlKey) }
        if flags.contains(.shift) { carbon |= UInt32(shiftKey) }
        return carbon
    }
}

private func fourCharacterCode(_ string: String) -> OSType {
    string.utf8.reduce(0) { code, character in
        (code << 8) + OSType(character)
    }
}