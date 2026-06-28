import AppKit
import Carbon.HIToolbox

@MainActor
final class HotkeyService {
    private let settingsStore: SettingsStore
    private let commandHandler: (AppCommand) -> Void
    private var hotKeyRef: EventHotKeyRef?
    private var drawHotKeyRef: EventHotKeyRef?
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
        if let eventHandlerRef {
            RemoveEventHandler(eventHandlerRef)
        }
        eventHandlerRef = nil
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