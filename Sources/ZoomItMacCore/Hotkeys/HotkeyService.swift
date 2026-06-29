import AppKit
import Carbon.HIToolbox

@MainActor
final class HotkeyService {
    private let settingsStore: SettingsStore
    private let commandHandler: (AppCommand) -> Void
    private var hotKeyRef: EventHotKeyRef?
    private var drawHotKeyRef: EventHotKeyRef?
    private var liveHotKeyRef: EventHotKeyRef?
    private var snipCopyHotKeyRef: EventHotKeyRef?
    private var snipSaveHotKeyRef: EventHotKeyRef?
    private var snipOcrHotKeyRef: EventHotKeyRef?
    private var recordHotKeyRef: EventHotKeyRef?
    private var recordRegionHotKeyRef: EventHotKeyRef?
    private var panoramaCopyHotKeyRef: EventHotKeyRef?
    private var panoramaSaveHotKeyRef: EventHotKeyRef?
    private var breakHotKeyRef: EventHotKeyRef?
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
                case 6: command = .snipRegion(save: false)
                case 7: command = .snipRegion(save: true)
                case 8: command = .toggleRecording(region: false)
                case 9: command = .toggleRecording(region: true)
                case 10: command = .startPanorama(save: false)
                case 11: command = .startPanorama(save: true)
                case 12: command = .toggleBreakTimer
                case 13: command = .snipOcr
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

        // Region snip: the base shortcut copies the region; the same shortcut
        // with Shift toggled saves it to a file.
        let snipModifiers = NSEvent.ModifierFlags(rawValue: settings.snipHotKeyModifiers)
        RegisterEventHotKey(
            UInt32(settings.snipHotKeyCode),
            carbonModifiers(from: snipModifiers),
            EventHotKeyID(signature: signature, id: 6),
            target,
            0,
            &snipCopyHotKeyRef
        )

        let snipSaveModifiers = NSEvent.ModifierFlags(rawValue: settings.snipHotKeyModifiers ^ NSEvent.ModifierFlags.shift.rawValue)
        RegisterEventHotKey(
            UInt32(settings.snipHotKeyCode),
            carbonModifiers(from: snipSaveModifiers),
            EventHotKeyID(signature: signature, id: 7),
            target,
            0,
            &snipSaveHotKeyRef
        )

        // OCR snip: recognizes text in the selected region and copies it to the
        // clipboard. A key code of 0 disables the hotkey, matching ZoomIt.
        if settings.snipOcrHotKeyCode != 0 {
            let snipOcrModifiers = NSEvent.ModifierFlags(rawValue: settings.snipOcrHotKeyModifiers)
            RegisterEventHotKey(
                UInt32(settings.snipOcrHotKeyCode),
                carbonModifiers(from: snipOcrModifiers),
                EventHotKeyID(signature: signature, id: 13),
                target,
                0,
                &snipOcrHotKeyRef
            )
        }

        // Recording: the base shortcut records the whole screen; the same
        // shortcut with Shift toggled records a selected region.
        let recordModifiers = NSEvent.ModifierFlags(rawValue: settings.recordHotKeyModifiers)
        RegisterEventHotKey(
            UInt32(settings.recordHotKeyCode),
            carbonModifiers(from: recordModifiers),
            EventHotKeyID(signature: signature, id: 8),
            target,
            0,
            &recordHotKeyRef
        )

        let recordRegionModifiers = NSEvent.ModifierFlags(rawValue: settings.recordHotKeyModifiers ^ NSEvent.ModifierFlags.shift.rawValue)
        RegisterEventHotKey(
            UInt32(settings.recordHotKeyCode),
            carbonModifiers(from: recordRegionModifiers),
            EventHotKeyID(signature: signature, id: 9),
            target,
            0,
            &recordRegionHotKeyRef
        )

        // Panorama: the base shortcut copies the stitched panorama to the
        // clipboard; the same shortcut with Shift toggled saves it to a file.
        let panoramaModifiers = NSEvent.ModifierFlags(rawValue: settings.panoramaHotKeyModifiers)
        RegisterEventHotKey(
            UInt32(settings.panoramaHotKeyCode),
            carbonModifiers(from: panoramaModifiers),
            EventHotKeyID(signature: signature, id: 10),
            target,
            0,
            &panoramaCopyHotKeyRef
        )

        let panoramaSaveModifiers = NSEvent.ModifierFlags(rawValue: settings.panoramaHotKeyModifiers ^ NSEvent.ModifierFlags.shift.rawValue)
        RegisterEventHotKey(
            UInt32(settings.panoramaHotKeyCode),
            carbonModifiers(from: panoramaSaveModifiers),
            EventHotKeyID(signature: signature, id: 11),
            target,
            0,
            &panoramaSaveHotKeyRef
        )

        let breakModifiers = NSEvent.ModifierFlags(rawValue: settings.breakHotKeyModifiers)
        RegisterEventHotKey(
            UInt32(settings.breakHotKeyCode),
            carbonModifiers(from: breakModifiers),
            EventHotKeyID(signature: signature, id: 12),
            target,
            0,
            &breakHotKeyRef
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
        if let snipCopyHotKeyRef {
            UnregisterEventHotKey(snipCopyHotKeyRef)
        }
        snipCopyHotKeyRef = nil
        if let snipSaveHotKeyRef {
            UnregisterEventHotKey(snipSaveHotKeyRef)
        }
        snipSaveHotKeyRef = nil
        if let snipOcrHotKeyRef {
            UnregisterEventHotKey(snipOcrHotKeyRef)
        }
        snipOcrHotKeyRef = nil
        if let recordHotKeyRef {
            UnregisterEventHotKey(recordHotKeyRef)
        }
        recordHotKeyRef = nil
        if let recordRegionHotKeyRef {
            UnregisterEventHotKey(recordRegionHotKeyRef)
        }
        recordRegionHotKeyRef = nil
        if let panoramaCopyHotKeyRef {
            UnregisterEventHotKey(panoramaCopyHotKeyRef)
        }
        panoramaCopyHotKeyRef = nil
        if let panoramaSaveHotKeyRef {
            UnregisterEventHotKey(panoramaSaveHotKeyRef)
        }
        panoramaSaveHotKeyRef = nil
        if let breakHotKeyRef {
            UnregisterEventHotKey(breakHotKeyRef)
        }
        breakHotKeyRef = nil
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