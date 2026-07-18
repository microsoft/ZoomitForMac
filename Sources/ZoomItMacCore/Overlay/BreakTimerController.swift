import AppKit

private final class BreakTimerWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

enum BreakTimerError: LocalizedError {
    case noDisplay
    case backgroundImageUnavailable(String)

    var errorDescription: String? {
        switch self {
        case .noDisplay:
            "The active display could not be found."
        case .backgroundImageUnavailable(let path):
            "The break timer background image could not be loaded: \(path)"
        }
    }
}

enum BreakTimerLayout {
    nonisolated static func timerText(for seconds: Int) -> String {
        guard seconds > 0 else { return "0:00" }
        return String(format: "%2d:%02d", seconds / 60, seconds % 60)
    }

    nonisolated static func expiredText(for seconds: Int) -> String {
        let elapsed = max(0, -seconds)
        return String(format: "(-%2d:%02d)", elapsed / 60, elapsed % 60)
    }

    nonisolated static func timerOrigin(textSize: CGSize, expiredSize: CGSize, bounds: CGRect, position: Int) -> CGPoint {
        let clampedPosition = min(max(position, 0), 8)
        let row = clampedPosition / 3
        let column = clampedPosition % 3
        let totalHeight = textSize.height + (expiredSize.height > 0 ? expiredSize.height + 10 : 0)

        let x: CGFloat
        switch column {
        case 0:
            x = 50
        case 1:
            x = (bounds.width - textSize.width) / 2
        default:
            x = bounds.width - textSize.width - 50
        }

        let y: CGFloat
        switch row {
        case 0:
            y = 50
        case 1:
            y = (bounds.height - textSize.height) / 2
        default:
            y = bounds.height - totalHeight - 50
        }
        return CGPoint(x: x, y: y)
    }

    /// Draws a background image into the (flipped, top-left origin) break timer
    /// view. The break timer view uses a flipped coordinate system, which would
    /// otherwise render images upside down, so this always passes
    /// `respectFlipped: true` to keep the image right-side up like Windows.
    @MainActor
    static func drawBackground(_ image: NSImage, in rect: CGRect, fraction: CGFloat) {
        image.draw(in: rect, from: .zero, operation: .sourceOver, fraction: fraction,
                   respectFlipped: true, hints: nil)
    }
}

@MainActor
final class BreakTimerController {
    private let displayManager: DisplayManager
    private let captureService: ScreenCaptureService
    private let settingsStore: SettingsStore
    private var window: NSWindow?
    private weak var timerView: BreakTimerView?
    private var onFinished: (() -> Void)?

    init(displayManager: DisplayManager, captureService: ScreenCaptureService, settingsStore: SettingsStore) {
        self.displayManager = displayManager
        self.captureService = captureService
        self.settingsStore = settingsStore
    }

    var isActive: Bool { window != nil }

    func begin(settings: AppSettings, onFinished: @escaping () -> Void) async throws {
        close(notify: false)

        guard let display = displayManager.activeDisplay() else {
            throw BreakTimerError.noDisplay
        }

        let backgroundImage = try await makeBackgroundImage(settings: settings, display: display)
        let window = BreakTimerWindow(
            contentRect: display.frame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.level = .screenSaver
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        window.backgroundColor = .clear
        window.isOpaque = false
        window.alphaValue = CGFloat(min(max(settings.breakOpacity, 10), 100)) / 100
        window.acceptsMouseMovedEvents = true
        window.isReleasedWhenClosed = false
        window.sharingType = .readOnly

        let timerView = BreakTimerView(
            frame: CGRect(origin: .zero, size: display.frame.size),
            settings: settings,
            backgroundImage: backgroundImage,
            onSettingsChanged: { [weak self] updated in
                self?.persistRuntimeSettings(updated)
            },
            onClose: { [weak self] in
                self?.close()
            }
        )
        window.contentView = timerView
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        window.makeKey()
        window.makeFirstResponder(timerView)

        self.window = window
        self.timerView = timerView
        self.onFinished = onFinished
        timerView.start()
    }

    func close() {
        close(notify: true)
    }

    private func close(notify: Bool) {
        timerView?.prepareForClose()
        guard let window else { return }

        window.orderOut(nil)
        self.window = nil
        timerView = nil
        let completion = onFinished
        onFinished = nil
        DispatchQueue.main.async {
            window.close()
        }
        if notify {
            completion?()
        }
    }

    private func makeBackgroundImage(settings: AppSettings, display: DisplayDescriptor) async throws -> NSImage? {
        switch settings.breakBackgroundMode {
        case 1:
            let frame = try await captureService.captureDisplay(display)
            let image = NSImage(cgImage: frame.image, size: display.frame.size)
            image.isTemplate = false
            return image
        case 2:
            guard !settings.breakBackgroundFile.isEmpty,
                  let image = NSImage(contentsOfFile: settings.breakBackgroundFile) else {
                throw BreakTimerError.backgroundImageUnavailable(settings.breakBackgroundFile)
            }
            image.isTemplate = false
            return image
        default:
            return nil
        }
    }

    private func persistRuntimeSettings(_ updated: AppSettings) {
        var settings = settingsStore.load()
        settings.breakTextColorRGB = updated.breakTextColorRGB
        settings.breakBackgroundColorRGB = updated.breakBackgroundColorRGB
        settingsStore.save(settings)
    }
}

@MainActor
private final class BreakTimerView: NSView {
    private var settings: AppSettings
    private let backgroundImage: NSImage?
    private let onSettingsChanged: (AppSettings) -> Void
    private let onClose: () -> Void
    private var timer: Timer?
    private var remainingSeconds: Int
    private var playedSoundAtZero = false

    override var acceptsFirstResponder: Bool { true }
    override var isFlipped: Bool { true }

    init(
        frame frameRect: NSRect,
        settings: AppSettings,
        backgroundImage: NSImage?,
        onSettingsChanged: @escaping (AppSettings) -> Void,
        onClose: @escaping () -> Void
    ) {
        self.settings = settings
        self.backgroundImage = backgroundImage
        self.onSettingsChanged = onSettingsChanged
        self.onClose = onClose
        self.remainingSeconds = max(1, min(settings.breakDurationMinutes, 99)) * 60
        super.init(frame: frameRect)
        wantsLayer = true
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func start() {
        timer?.invalidate()
        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.tick()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
        needsDisplay = true
    }

    func prepareForClose() {
        timer?.invalidate()
        timer = nil
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        let bounds = self.bounds

        NSColor(rgb: settings.breakBackgroundColorRGB).setFill()
        bounds.fill()

        if let backgroundImage {
            drawBackgroundImage(backgroundImage, in: bounds)
        }

        drawTimer(in: bounds)
    }

    override func keyDown(with event: NSEvent) {
        switch Int(event.keyCode) {
        case 53:
            onClose()
            return
        case 126:
            adjustByMinutes(1)
            return
        case 125:
            adjustByMinutes(-1)
            return
        case 124:
            adjustBySeconds(10)
            return
        case 123:
            adjustBySeconds(-10)
            return
        default:
            break
        }

        guard let character = event.charactersIgnoringModifiers?.uppercased().first else { return }
        if event.modifierFlags.contains(.control), character == "W" || character == "K" {
            settings.breakBackgroundColorRGB = character == "K" ? 0x000000 : 0xFFFFFF
            onSettingsChanged(settings)
            needsDisplay = true
            return
        }

        if let color = Self.colorRGB(for: character) {
            settings.breakTextColorRGB = color
            onSettingsChanged(settings)
            needsDisplay = true
        }
    }

    override func rightMouseDown(with event: NSEvent) {
        onClose()
    }

    override func scrollWheel(with event: NSEvent) {
        let delta = event.scrollingDeltaY == 0 ? event.deltaY : event.scrollingDeltaY
        if delta > 0 {
            adjustByMinutes(1)
        } else if delta < 0 {
            adjustByMinutes(-1)
        }
    }

    private func tick() {
        remainingSeconds -= 1
        if remainingSeconds == 0, settings.breakPlaySound, !playedSoundAtZero {
            playedSoundAtZero = true
            if !settings.breakSoundFile.isEmpty {
                NSSound(contentsOfFile: settings.breakSoundFile, byReference: true)?.play()
            } else {
                NSSound.beep()
            }
        }
        needsDisplay = true
    }

    private func drawBackgroundImage(_ image: NSImage, in bounds: CGRect) {
        // This view is flipped (top-left origin), so the image must be drawn
        // with flip awareness or it renders upside down (matches Windows).
        if settings.breakBackgroundMode == 1 {
            BreakTimerLayout.drawBackground(image, in: bounds, fraction: 0.31)
            return
        }

        if settings.breakBackgroundStretch {
            BreakTimerLayout.drawBackground(image, in: bounds, fraction: 1)
        } else {
            let size = image.size
            let origin = CGPoint(x: (bounds.width - size.width) / 2, y: (bounds.height - size.height) / 2)
            BreakTimerLayout.drawBackground(image, in: CGRect(origin: origin, size: size), fraction: 1)
        }
    }

    private func drawTimer(in bounds: CGRect) {
        let text = BreakTimerLayout.timerText(for: remainingSeconds)
        let font = NSFont.monospacedDigitSystemFont(ofSize: max(24, bounds.height / 5), weight: .regular)
        let attributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: NSColor(rgb: settings.breakTextColorRGB)
        ]
        let attributed = NSAttributedString(string: text, attributes: attributes)
        let textSize = attributed.size()

        let expiredAttributed = makeExpiredAttributedString()
        let expiredSize = expiredAttributed?.size() ?? .zero
        let origin = BreakTimerLayout.timerOrigin(
            textSize: textSize,
            expiredSize: expiredSize,
            bounds: bounds,
            position: settings.breakTimerPosition
        )
        attributed.draw(at: origin)

        guard let expiredAttributed else { return }
        let expiredOrigin = CGPoint(
            x: origin.x + (textSize.width - expiredSize.width) / 2,
            y: origin.y + textSize.height + 10
        )
        expiredAttributed.draw(at: expiredOrigin)
    }

    private func makeExpiredAttributedString() -> NSAttributedString? {
        guard settings.breakShowExpiredTime, remainingSeconds < 0 else { return nil }
        let font = NSFont.monospacedDigitSystemFont(ofSize: max(18, bounds.height / 8), weight: .regular)
        return NSAttributedString(
            string: BreakTimerLayout.expiredText(for: remainingSeconds),
            attributes: [
                .font: font,
                .foregroundColor: NSColor(rgb: settings.breakTextColorRGB)
            ]
        )
    }

    private func adjustByMinutes(_ delta: Int) {
        guard remainingSeconds > 0 || delta > 0 else { return }
        if remainingSeconds < 0 { remainingSeconds = 0 }
        var minuteDelta = delta
        if remainingSeconds % 60 != 0 {
            remainingSeconds += 60 - (remainingSeconds % 60)
            minuteDelta -= 1
        }
        remainingSeconds = max(0, remainingSeconds + minuteDelta * 60)
        playedSoundAtZero = remainingSeconds != 0 && playedSoundAtZero
        needsDisplay = true
    }

    private func adjustBySeconds(_ delta: Int) {
        guard remainingSeconds > 0 || delta > 0 else { return }
        if remainingSeconds < 0 { remainingSeconds = 0 }
        remainingSeconds = max(0, remainingSeconds + delta)
        remainingSeconds -= remainingSeconds % 10
        playedSoundAtZero = remainingSeconds != 0 && playedSoundAtZero
        needsDisplay = true
    }

    private static func colorRGB(for character: Character) -> UInt32? {
        switch character {
        case "R": 0xFF0000
        case "G": 0x00FF00
        case "B": 0x0000FF
        case "Y": 0xFFFF00
        case "O": 0xFFA500
        case "P": 0xFF69B4
        case "W": 0xFFFFFF
        case "K": 0x000000
        default: nil
        }
    }
}

private extension NSColor {
    convenience init(rgb: UInt32) {
        self.init(
            calibratedRed: CGFloat((rgb >> 16) & 0xFF) / 255,
            green: CGFloat((rgb >> 8) & 0xFF) / 255,
            blue: CGFloat(rgb & 0xFF) / 255,
            alpha: 1
        )
    }
}