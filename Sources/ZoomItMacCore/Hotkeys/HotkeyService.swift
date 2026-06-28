import AppKit
import Carbon.HIToolbox

@MainActor
final class HotkeyService {
    private let settingsStore: SettingsStore
    private let commandHandler: (AppCommand) -> Void
    private var localMonitor: Any?
    private var globalMonitor: Any?
    private var hotKeyRef: EventHotKeyRef?
    private var eventHandlerRef: EventHandlerRef?

    init(settingsStore: SettingsStore, commandHandler: @escaping (AppCommand) -> Void) {
        self.settingsStore = settingsStore
        self.commandHandler = commandHandler
    }

    func start() {
        registerSystemHotkey()

        localMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown]) { [weak self] event in
            guard let self else { return event }
            return self.handle(event) ? nil : event
        }

        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.keyDown]) { [weak self] event in
            _ = self?.handle(event)
        }
    }

    func stop() {
        if let hotKeyRef {
            UnregisterEventHotKey(hotKeyRef)
        }
        if let eventHandlerRef {
            RemoveEventHandler(eventHandlerRef)
        }
        if let localMonitor {
            NSEvent.removeMonitor(localMonitor)
        }
        if let globalMonitor {
            NSEvent.removeMonitor(globalMonitor)
        }
        localMonitor = nil
        globalMonitor = nil
        hotKeyRef = nil
        eventHandlerRef = nil
    }

    private func registerSystemHotkey() {
        guard hotKeyRef == nil, eventHandlerRef == nil else { return }

        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )
        let selfPointer = Unmanaged.passUnretained(self).toOpaque()

        let handlerStatus = InstallEventHandler(
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
                guard parameterStatus == noErr, hotKeyID.id == 1 else { return parameterStatus }

                let service = Unmanaged<HotkeyService>.fromOpaque(userData).takeUnretainedValue()
                Task { @MainActor in
                    service.commandHandler(.activateStaticZoom)
                }
                return noErr
            },
            1,
            &eventType,
            selfPointer,
            &eventHandlerRef
        )
        guard handlerStatus == noErr else { return }

        let hotKeyID = EventHotKeyID(signature: fourCharacterCode("ZITM"), id: 1)
        let registerStatus = RegisterEventHotKey(
            UInt32(kVK_ANSI_1),
            UInt32(cmdKey | shiftKey),
            hotKeyID,
            GetApplicationEventTarget(),
            0,
            &hotKeyRef
        )

        if registerStatus != noErr {
            if let eventHandlerRef {
                RemoveEventHandler(eventHandlerRef)
            }
            self.eventHandlerRef = nil
        }
    }

    private func handle(_ event: NSEvent) -> Bool {
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        guard modifiers.contains([.command, .shift]) else {
            return false
        }

        switch event.charactersIgnoringModifiers?.lowercased() {
        case "1":
            commandHandler(.activateStaticZoom)
            return true
        default:
            return false
        }
    }
}

private func fourCharacterCode(_ string: String) -> OSType {
    string.utf8.reduce(0) { code, character in
        (code << 8) + OSType(character)
    }
}