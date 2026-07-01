import AppKit
import Carbon.HIToolbox

@MainActor
final class DemoTypeController {
    private enum DemoTypeError: Error, LocalizedError {
        case noFileSpecified
        case fileTooLarge
        case unrecognizedContent
        case loadingFailed

        var errorDescription: String? {
            switch self {
            case .noFileSpecified: return "No DemoType file specified"
            case .fileTooLarge: return "Unsupported DemoType file size"
            case .unrecognizedContent: return "Unrecognized DemoType file content"
            case .loadingFailed: return "Error loading DemoType file"
            }
        }
    }

    private enum Token: Equatable {
        case text(String)
        case key(CGKeyCode)
        case pause(Int)
        case end
        case paste(String)
    }

    enum TestToken: Equatable {
        case text(String)
        case key(String)
        case pause(Int)
        case end
        case paste(String)
    }

    private static let maxInputSize = 1_048_576
    private static let minTypingDelayMs = 10
    private static let maxTypingDelayMs = 100
    private static let endControl = "[end]"
    private static let startControl = "[start]"

    private let settingsStore: SettingsStore
    private var text = ""
    private var sourceKey = ""
    private var sourceModifiedDate: Date?
    private var segmentStarts: [String.Index] = []
    private var index: String.Index?
    private var task: Task<Void, Never>?
    private var userKeyContinuation: CheckedContinuation<Bool, Never>?
    private var userKeyMonitor: Any?
    private var userEventTap: CFMachPort?
    private var userEventSource: CFRunLoopSource?

    init(settingsStore: SettingsStore) {
        self.settingsStore = settingsStore
    }

    func startOrStop() {
        if let task, !task.isCancelled {
            cancelActiveTask()
            return
        }

        do {
            let settings = settingsStore.load()
            try loadTextIfNeeded(settings: settings)
            let start = index ?? text.startIndex
            task = Task { [weak self] in
                await self?.run(from: start, settings: settings)
            }
        } catch {
            present(error)
        }
    }

    func reset() {
        if let task, !task.isCancelled {
            cancelActiveTask()
            return
        }
        guard let current = index else {
            index = text.startIndex
            return
        }
        if !segmentStarts.isEmpty, current <= segmentStarts.last! {
            segmentStarts.removeLast()
        }
        index = segmentStarts.last ?? text.startIndex
    }

    private func run(from start: String.Index, settings: AppSettings) async {
        var cursor = start
        let userDriven = settings.demoTypeUserDriven
        let injectionRatio = max(1, min(3, settings.demoTypeSpeed / 30 + 1))
        let delayNanoseconds = UInt64(typingDelayMilliseconds(for: settings.demoTypeSpeed)) * 1_000_000

        await waitForHotKeyRelease()

        while cursor < text.endIndex, !Task.isCancelled {
            if userDriven {
                guard await waitForUserKey() else { break }
                for _ in 0..<injectionRatio where cursor < text.endIndex && !Task.isCancelled {
                    let result = await emitNextToken(startingAt: cursor, userDriven: true)
                    cursor = result.nextIndex
                    if result.ended { break }
                }
            } else {
                let result = await emitNextToken(startingAt: cursor, userDriven: false)
                cursor = result.nextIndex
                if result.ended { break }
                try? await Task.sleep(nanoseconds: delayNanoseconds)
            }
        }

        if cursor >= text.endIndex {
            cursor = text.startIndex
        }
        index = cursor
        task = nil
    }

    private func emitNextToken(startingAt cursor: String.Index, userDriven: Bool) async -> (nextIndex: String.Index, ended: Bool) {
        guard let token = nextToken(startingAt: cursor) else {
            return (text.index(after: cursor), false)
        }

        switch token.value {
        case .text(let string):
            type(string)
        case .key(let keyCode):
            postKey(keyCode)
        case .pause(let seconds):
            if !userDriven, seconds > 0 {
                try? await Task.sleep(nanoseconds: UInt64(seconds) * 1_000_000_000)
            }
        case .paste(let string):
            paste(string)
        case .end:
            segmentStarts.append(token.nextIndex)
            return (token.nextIndex >= text.endIndex ? text.startIndex : token.nextIndex, true)
        }
        return (token.nextIndex, false)
    }

    private func nextToken(startingAt cursor: String.Index) -> (value: Token, nextIndex: String.Index)? {
        guard cursor < text.endIndex else { return nil }
        if text[cursor] == "[" {
            if let token = controlToken(startingAt: cursor) {
                return token
            }
        }
        let next = text.index(after: cursor)
        return (.text(String(text[cursor])), next)
    }

    private func controlToken(startingAt cursor: String.Index) -> (value: Token, nextIndex: String.Index)? {
        guard let close = text[cursor...].firstIndex(of: "]") else { return nil }
        let afterClose = text.index(after: close)
        let control = String(text[cursor..<afterClose]).lowercased()

        switch control {
        case "[end]": return (.end, afterClose)
        case "[enter]": return (.key(CGKeyCode(kVK_Return)), afterClose)
        case "[up]": return (.key(CGKeyCode(kVK_UpArrow)), afterClose)
        case "[down]": return (.key(CGKeyCode(kVK_DownArrow)), afterClose)
        case "[left]": return (.key(CGKeyCode(kVK_LeftArrow)), afterClose)
        case "[right]": return (.key(CGKeyCode(kVK_RightArrow)), afterClose)
        case "[paste]":
            guard let endRange = text.range(of: "[/paste]", range: afterClose..<text.endIndex) else { return nil }
            return (.paste(String(text[afterClose..<endRange.lowerBound])), endRange.upperBound)
        default:
            if control.hasPrefix("[pause:"), control.hasSuffix("]") {
                let value = control.dropFirst(7).dropLast()
                if let seconds = Int(value) {
                    return (.pause(seconds), afterClose)
                }
            }
            return nil
        }
    }

    private func loadTextIfNeeded(settings: AppSettings) throws {
        if let clipboardText = readClipboardDemoText() {
            sourceKey = "clipboard"
            sourceModifiedDate = nil
            text = Self.clean(clipboardText)
            index = text.startIndex
            segmentStarts = []
            guard !text.isEmpty else { throw DemoTypeError.unrecognizedContent }
            return
        }

        guard !settings.demoTypeFile.isEmpty else { throw DemoTypeError.noFileSpecified }
        let url = URL(fileURLWithPath: settings.demoTypeFile)
        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
        let modified = attributes?[.modificationDate] as? Date
        if sourceKey == url.path, sourceModifiedDate == modified, !text.isEmpty {
            return
        }

        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            throw DemoTypeError.loadingFailed
        }
        guard !data.isEmpty, data.count <= Self.maxInputSize else { throw DemoTypeError.fileTooLarge }
        guard let loaded = Self.decode(data) else { throw DemoTypeError.unrecognizedContent }
        let cleaned = Self.clean(loaded)
        guard !cleaned.isEmpty else { throw DemoTypeError.unrecognizedContent }
        sourceKey = url.path
        sourceModifiedDate = modified
        text = cleaned
        index = text.startIndex
        segmentStarts = []
    }

    private func readClipboardDemoText() -> String? {
        guard let clipboard = NSPasteboard.general.string(forType: .string), clipboard.hasPrefix(Self.startControl) else {
            return nil
        }
        let start = clipboard.index(clipboard.startIndex, offsetBy: Self.startControl.count)
        return String(clipboard[start...])
    }

    static func decodeForTesting(_ data: Data) -> String? {
        decode(data)
    }

    static func cleanForTesting(_ input: String) -> String {
        clean(input)
    }

    static func tokensForTesting(_ input: String) -> [TestToken] {
        let controller = DemoTypeController(settingsStore: UserDefaultsSettingsStore(defaults: UserDefaults(suiteName: "ZoomItMac.DemoTypeController.Test") ?? .standard))
        controller.text = clean(input)
        var cursor = controller.text.startIndex
        var tokens: [TestToken] = []
        while cursor < controller.text.endIndex, let token = controller.nextToken(startingAt: cursor) {
            switch token.value {
            case .text(let string): tokens.append(.text(string))
            case .key(let keyCode): tokens.append(.key(keyNameForTesting(keyCode)))
            case .pause(let seconds): tokens.append(.pause(seconds))
            case .end: tokens.append(.end)
            case .paste(let string): tokens.append(.paste(string))
            }
            cursor = token.nextIndex
        }
        return tokens
    }

    private static func decode(_ data: Data) -> String? {
        if data.starts(with: [0xFF, 0xFE]) {
            return String(data: data.dropFirst(2), encoding: .utf16LittleEndian)
        }
        if data.starts(with: [0xFE, 0xFF]) {
            return String(data: data.dropFirst(2), encoding: .utf16BigEndian)
        }
        if data.starts(with: [0xEF, 0xBB, 0xBF]) {
            return String(data: data.dropFirst(3), encoding: .utf8)
        }
        return String(data: data, encoding: .utf8)
    }

    private static func clean(_ input: String) -> String {
        var output = input.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
        output.removeAll { character in
            character != "\n" && character != "\t" && character.unicodeScalars.allSatisfy { scalar in
                scalar.properties.generalCategory == .control
            }
        }
        if output.first == "\n" {
            output.removeFirst()
        }
        output = trimNewline(around: "[end]", in: output, trimLeft: true, trimRight: true)
        output = trimNewline(around: "[paste]", in: output, trimLeft: false, trimRight: true)
        output = trimNewline(around: "[/paste]", in: output, trimLeft: true, trimRight: false)
        if let lastEnd = output.range(of: Self.endControl, options: .backwards) {
            let tail = output[lastEnd.upperBound...]
            if tail.allSatisfy({ $0 == " " || $0 == "\t" || $0 == "\n" }) {
                output.removeSubrange(lastEnd.upperBound..<output.endIndex)
            }
        }
        return output
    }

    private static func trimNewline(around control: String, in input: String, trimLeft: Bool, trimRight: Bool) -> String {
        var output = input
        var searchStart = output.startIndex
        while let range = output.range(of: control, range: searchStart..<output.endIndex) {
            var nextSearchStart = range.upperBound
            if trimLeft, range.lowerBound > output.startIndex {
                let previous = output.index(before: range.lowerBound)
                if output[previous] == "\n" {
                    output.remove(at: previous)
                    nextSearchStart = output.index(range.upperBound, offsetBy: -1)
                }
            }
            if trimRight, nextSearchStart < output.endIndex, output[nextSearchStart] == "\n" {
                output.remove(at: nextSearchStart)
            }
            searchStart = nextSearchStart
        }
        return output
    }

    private func typingDelayMilliseconds(for slider: Int) -> Int {
        let clamped = min(max(slider, Self.minTypingDelayMs), Self.maxTypingDelayMs)
        return (Self.minTypingDelayMs + Self.maxTypingDelayMs) - clamped
    }

    private func waitForHotKeyRelease() async {
        let hotKeyModifierMask: CGEventFlags = [.maskCommand, .maskControl, .maskAlternate, .maskShift]
        for _ in 0..<100 {
            if Task.isCancelled { return }
            let flags = CGEventSource.flagsState(.combinedSessionState)
            if flags.intersection(hotKeyModifierMask).isEmpty {
                try? await Task.sleep(nanoseconds: 30_000_000)
                return
            }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
    }

    private static func keyNameForTesting(_ keyCode: CGKeyCode) -> String {
        switch Int(keyCode) {
        case kVK_Return: return "enter"
        case kVK_UpArrow: return "up"
        case kVK_DownArrow: return "down"
        case kVK_LeftArrow: return "left"
        case kVK_RightArrow: return "right"
        default: return "key-\(keyCode)"
        }
    }

    private func waitForUserKey() async -> Bool {
        await withCheckedContinuation { continuation in
            userKeyContinuation = continuation
            if installBlockingUserKeyTap() {
                return
            }
            userKeyMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.keyUp]) { [weak self] event in
                Task { @MainActor in
                    self?.completeUserKeyWait(shouldContinue: event.keyCode != kVK_Escape)
                }
            }
        }
    }

    private func installBlockingUserKeyTap() -> Bool {
        let mask = CGEventMask(1 << CGEventType.keyDown.rawValue) | CGEventMask(1 << CGEventType.keyUp.rawValue)
        let selfPointer = Unmanaged.passUnretained(self).toOpaque()
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: { _, type, event, userInfo in
                guard let userInfo else { return Unmanaged.passUnretained(event) }
                if type == .keyUp {
                    let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
                    let controller = Unmanaged<DemoTypeController>.fromOpaque(userInfo).takeUnretainedValue()
                    Task { @MainActor in
                        controller.completeUserKeyWait(shouldContinue: keyCode != kVK_Escape)
                    }
                }
                return nil
            },
            userInfo: selfPointer
        ) else {
            return false
        }

        guard let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0) else {
            CFMachPortInvalidate(tap)
            return false
        }
        userEventTap = tap
        userEventSource = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        return true
    }

    private func completeUserKeyWait(shouldContinue: Bool) {
        let continuation = userKeyContinuation
        clearUserKeyWait()
        continuation?.resume(returning: shouldContinue)
    }

    private func cancelActiveTask() {
        task?.cancel()
        task = nil
        completeUserKeyWait(shouldContinue: false)
    }

    private func clearUserKeyWait() {
        if let userKeyMonitor {
            NSEvent.removeMonitor(userKeyMonitor)
        }
        userKeyMonitor = nil
        if let userEventSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), userEventSource, .commonModes)
        }
        userEventSource = nil
        if let userEventTap {
            CGEvent.tapEnable(tap: userEventTap, enable: false)
            CFMachPortInvalidate(userEventTap)
        }
        userEventTap = nil
        userKeyContinuation = nil
    }

    private func type(_ string: String) {
        for scalar in string.unicodeScalars {
            let source = CGEventSource(stateID: .combinedSessionState)
            let down = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: true)
            var value = UniChar(scalar.value)
            down?.keyboardSetUnicodeString(stringLength: 1, unicodeString: &value)
            let up = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: false)
            up?.keyboardSetUnicodeString(stringLength: 1, unicodeString: &value)
            down?.post(tap: .cghidEventTap)
            up?.post(tap: .cghidEventTap)
        }
    }

    private func postKey(_ keyCode: CGKeyCode) {
        let source = CGEventSource(stateID: .combinedSessionState)
        CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: true)?.post(tap: .cghidEventTap)
        CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: false)?.post(tap: .cghidEventTap)
    }

    private func paste(_ string: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(string, forType: .string)
        let source = CGEventSource(stateID: .combinedSessionState)
        let keyCode = CGKeyCode(kVK_ANSI_V)
        let down = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: true)
        down?.flags = .maskCommand
        let up = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: false)
        up?.flags = .maskCommand
        down?.post(tap: .cghidEventTap)
        up?.post(tap: .cghidEventTap)
    }

    private func present(_ error: Error) {
        let alert = NSAlert(error: error)
        alert.runModal()
    }
}
