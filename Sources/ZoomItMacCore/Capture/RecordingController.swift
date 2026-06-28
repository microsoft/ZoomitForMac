import AVFoundation
import AppKit
import ScreenCaptureKit

/// Wraps a CMSampleBuffer so it can be handed from capture callbacks to the
/// writer queue. CMSampleBuffer is immutable once delivered and the writer
/// serialises all access.
private struct SampleBufferBox: @unchecked Sendable {
    let buffer: CMSampleBuffer
}

/// Owns the AVAssetWriter and serialises all sample appends on its own queue so
/// it can safely receive buffers from the ScreenCaptureKit and microphone
/// capture callbacks (which run on background queues).
private final class RecordingEngine: @unchecked Sendable {
    let url: URL
    private let queue = DispatchQueue(label: "com.zoomitmac.recorder")
    private let writer: AVAssetWriter
    private let videoInput: AVAssetWriterInput
    private let systemAudioInput: AVAssetWriterInput?
    private let micInput: AVAssetWriterInput?
    private var sessionStarted = false
    private var finished = false

    init(url: URL, width: Int, height: Int, systemAudio: Bool, microphone: Bool) throws {
        self.url = url
        writer = try AVAssetWriter(outputURL: url, fileType: .mp4)

        let videoSettings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height
        ]
        videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings)
        videoInput.expectsMediaDataInRealTime = true
        if writer.canAdd(videoInput) { writer.add(videoInput) }

        let audioSettings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVNumberOfChannelsKey: 2,
            AVSampleRateKey: 44_100,
            AVEncoderBitRateKey: 128_000
        ]
        if systemAudio {
            let input = AVAssetWriterInput(mediaType: .audio, outputSettings: audioSettings)
            input.expectsMediaDataInRealTime = true
            systemAudioInput = writer.canAdd(input) ? input : nil
            if let systemAudioInput { writer.add(systemAudioInput) }
        } else {
            systemAudioInput = nil
        }
        if microphone {
            let input = AVAssetWriterInput(mediaType: .audio, outputSettings: audioSettings)
            input.expectsMediaDataInRealTime = true
            micInput = writer.canAdd(input) ? input : nil
            if let micInput { writer.add(micInput) }
        } else {
            micInput = nil
        }
    }

    func startWriting() {
        queue.async {
            self.writer.startWriting()
        }
    }

    func appendVideo(_ box: SampleBufferBox) {
        queue.async {
            guard !self.finished, self.writer.status == .writing else { return }
            if !self.sessionStarted {
                self.sessionStarted = true
                self.writer.startSession(atSourceTime: CMSampleBufferGetPresentationTimeStamp(box.buffer))
            }
            if self.videoInput.isReadyForMoreMediaData {
                self.videoInput.append(box.buffer)
            }
        }
    }

    func appendSystemAudio(_ box: SampleBufferBox) {
        queue.async {
            guard self.sessionStarted, !self.finished, self.writer.status == .writing,
                  let input = self.systemAudioInput, input.isReadyForMoreMediaData else { return }
            input.append(box.buffer)
        }
    }

    func appendMicrophone(_ box: SampleBufferBox) {
        queue.async {
            guard self.sessionStarted, !self.finished, self.writer.status == .writing,
                  let input = self.micInput, input.isReadyForMoreMediaData else { return }
            input.append(box.buffer)
        }
    }

    func finish(completion: @escaping @Sendable (URL?) -> Void) {
        queue.async {
            guard !self.finished, self.writer.status == .writing else {
                completion(nil)
                return
            }
            self.finished = true
            self.videoInput.markAsFinished()
            self.systemAudioInput?.markAsFinished()
            self.micInput?.markAsFinished()
            let url = self.url
            self.writer.finishWriting {
                completion(self.writer.status == .completed ? url : nil)
            }
        }
    }
}

/// Forwards ScreenCaptureKit video and system-audio buffers to the engine.
private final class RecordingStreamOutput: NSObject, SCStreamOutput, @unchecked Sendable {
    private let engine: RecordingEngine
    init(engine: RecordingEngine) { self.engine = engine }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard sampleBuffer.isValid else { return }
        switch type {
        case .screen:
            // Skip frames that aren't complete (e.g. idle/blank) so only real
            // updates are encoded.
            guard let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
                  let statusRaw = attachments.first?[.status] as? Int,
                  statusRaw == SCFrameStatus.complete.rawValue else { return }
            engine.appendVideo(SampleBufferBox(buffer: sampleBuffer))
        case .audio:
            engine.appendSystemAudio(SampleBufferBox(buffer: sampleBuffer))
        default:
            // Microphone audio (ScreenCaptureKit, macOS 15+) shares the video
            // clock, so it aligns with the writer session.
            if #available(macOS 15.0, *), type == .microphone {
                engine.appendMicrophone(SampleBufferBox(buffer: sampleBuffer))
            }
        }
    }
}

/// Forwards microphone buffers to the engine.
private final class RecordingMicOutput: NSObject, AVCaptureAudioDataOutputSampleBufferDelegate, @unchecked Sendable {
    private let engine: RecordingEngine
    init(engine: RecordingEngine) { self.engine = engine }

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        engine.appendMicrophone(SampleBufferBox(buffer: sampleBuffer))
    }
}

/// Draws an orange border around the area being recorded (the whole view, or a
/// selected region). It lives in a click-through window excluded from capture so
/// it never appears in the recording.
@MainActor
private final class RecordingBorderView: NSView {
    /// The region being recorded in view points (top-left origin), or nil for
    /// the whole screen.
    var region: CGRect?

    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        let lineWidth: CGFloat = 6
        // Inset by half the line width so the full stroke stays on screen.
        let rect = (region ?? bounds).insetBy(dx: lineWidth / 2, dy: lineWidth / 2)
        context.setStrokeColor(NSColor.systemOrange.cgColor)
        context.setLineWidth(lineWidth)
        context.stroke(rect)
    }
}

/// Records the screen (or a selected region) to an MP4 using ScreenCaptureKit
/// for video and optional system audio, plus an optional microphone via
/// AVCaptureSession, mirroring ZoomIt's recording feature.
@MainActor
final class RecordingController {
    private let captureService: ScreenCaptureService
    private let displayManager: DisplayManager
    private let permissionService: PermissionService
    private let settingsStore: SettingsStore

    private(set) var isRecording = false
    private var onStateChange: ((Bool) -> Void)?
    /// Called right before the Save dialog is shown so any obscuring overlay
    /// (e.g. a zoom overlay at `.screenSaver` level) can be dismissed first.
    var onWillShowSaveDialog: (() -> Void)?

    private var stream: SCStream?
    private var streamOutput: RecordingStreamOutput?
    private var micOutput: RecordingMicOutput?
    private var captureSession: AVCaptureSession?
    private var engine: RecordingEngine?
    private var borderWindow: NSWindow?
    private let sampleQueue = DispatchQueue(label: "com.zoomitmac.recorder.samples")

    init(
        captureService: ScreenCaptureService,
        displayManager: DisplayManager,
        permissionService: PermissionService,
        settingsStore: SettingsStore
    ) {
        self.captureService = captureService
        self.displayManager = displayManager
        self.permissionService = permissionService
        self.settingsStore = settingsStore
    }

    /// Toggles recording. When starting, `region` chooses whole-screen vs. a
    /// dragged region. `onStateChange(true/false)` reports start/stop.
    func toggle(region: Bool, onStateChange: @escaping (Bool) -> Void) {
        if isRecording {
            stop()
        } else {
            self.onStateChange = onStateChange
            start(region: region)
        }
    }

    private func start(region: Bool) {
        guard permissionService.currentState().screenCapture.isGranted else {
            permissionService.requestScreenCaptureAccess()
            return
        }
        guard let display = displayManager.activeDisplay() else {
            NSSound.beep()
            return
        }

        if region {
            selectRegion(on: display) { [weak self] rect in
                guard let self, let rect else { return }
                self.beginCapture(display: display, sourceRect: rect)
            }
        } else {
            beginCapture(display: display, sourceRect: nil)
        }
    }

    private func beginCapture(display: DisplayDescriptor, sourceRect: CGRect?) {
        // Show the orange recording border first so it's part of our own windows
        // (excluded from capture) before the stream filter is built.
        showBorder(display: display, region: sourceRect)
        Task { @MainActor in
            do {
                try await self.startStreaming(display: display, sourceRect: sourceRect)
                self.isRecording = true
                self.onStateChange?(true)
            } catch {
                self.cleanup()
                self.presentError(error)
                self.onStateChange?(false)
            }
        }
    }

    /// Shows a click-through orange border around the recorded area. The window
    /// is marked non-shareable so it never appears in the recording.
    private func showBorder(display: DisplayDescriptor, region: CGRect?) {
        let window = NSWindow(
            contentRect: display.frame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        // Sit above the zoom/draw overlay (also at `.screenSaver`) so the border
        // stays visible while zoomed and drawing. It's click-through and
        // non-shareable, so it neither blocks input nor appears in the recording.
        window.level = NSWindow.Level(rawValue: NSWindow.Level.screenSaver.rawValue + 1)
        window.backgroundColor = .clear
        window.isOpaque = false
        window.ignoresMouseEvents = true
        window.sharingType = .none
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        window.isReleasedWhenClosed = false

        let view = RecordingBorderView(frame: CGRect(origin: .zero, size: display.frame.size))
        view.region = region
        window.contentView = view
        window.orderFrontRegardless()
        self.borderWindow = window
    }

    private func hideBorder() {
        borderWindow?.orderOut(nil)
        borderWindow = nil
    }

    private func startStreaming(display: DisplayDescriptor, sourceRect: CGRect?) async throws {
        let settings = settingsStore.load()
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        guard let scDisplay = content.displays.first(where: { $0.displayID == display.id }) else {
            throw ScreenCaptureError.displayNotFound
        }

        // Capture the whole display, including ZoomIt's own zoom/draw overlays
        // so annotations made while recording are captured. The orange border
        // is kept out of the recording via its window's `sharingType = .none`.
        let filter = SCContentFilter(display: scDisplay, excludingWindows: [])

        let scale = display.scaleFactor
        let configuration = SCStreamConfiguration()
        let pixelWidth: Int
        let pixelHeight: Int
        if let sourceRect {
            configuration.sourceRect = sourceRect
            pixelWidth = Int(sourceRect.width * scale)
            pixelHeight = Int(sourceRect.height * scale)
        } else {
            pixelWidth = Int(display.frame.width * scale)
            pixelHeight = Int(display.frame.height * scale)
        }
        configuration.width = pixelWidth
        configuration.height = pixelHeight
        configuration.showsCursor = true
        configuration.pixelFormat = kCVPixelFormatType_32BGRA
        configuration.minimumFrameInterval = CMTime(value: 1, timescale: 60)
        configuration.queueDepth = 5

        let wantsSystemAudio = settings.recordSystemAudio
        if wantsSystemAudio {
            configuration.capturesAudio = true
        }
        // Only attempt the microphone when already authorized; requesting access
        // without a bundled usage description would crash the bare executable.
        let wantsMic = settings.recordMicrophone
            && AVCaptureDevice.authorizationStatus(for: .audio) == .authorized

        // Prefer capturing the microphone through ScreenCaptureKit (macOS 15+)
        // so it shares the video clock; fall back to AVCaptureSession on older
        // systems.
        var micViaSCStream = false
        if wantsMic, #available(macOS 15.0, *) {
            configuration.captureMicrophone = true
            if !settings.microphoneDeviceID.isEmpty {
                configuration.microphoneCaptureDeviceID = settings.microphoneDeviceID
            }
            micViaSCStream = true
        }

        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("ZoomIt-\(UUID().uuidString).mp4")
        let engine = try RecordingEngine(
            url: url,
            width: pixelWidth,
            height: pixelHeight,
            systemAudio: wantsSystemAudio,
            microphone: wantsMic
        )
        engine.startWriting()
        self.engine = engine

        let stream = SCStream(filter: filter, configuration: configuration, delegate: nil)
        let output = RecordingStreamOutput(engine: engine)
        try stream.addStreamOutput(output, type: .screen, sampleHandlerQueue: sampleQueue)
        if wantsSystemAudio {
            try stream.addStreamOutput(output, type: .audio, sampleHandlerQueue: sampleQueue)
        }
        if micViaSCStream, #available(macOS 15.0, *) {
            try stream.addStreamOutput(output, type: .microphone, sampleHandlerQueue: sampleQueue)
        }
        self.streamOutput = output
        self.stream = stream

        // macOS 14 fallback: capture the microphone via AVCaptureSession.
        if wantsMic, !micViaSCStream, let device = AudioDevices.microphone(forID: settings.microphoneDeviceID) {
            try? setupMicrophone(device: device, engine: engine)
        }

        try await stream.startCapture()
    }

    private func setupMicrophone(device: AVCaptureDevice, engine: RecordingEngine) throws {
        let session = AVCaptureSession()
        let input = try AVCaptureDeviceInput(device: device)
        if session.canAddInput(input) { session.addInput(input) }
        let output = AVCaptureAudioDataOutput()
        let micOut = RecordingMicOutput(engine: engine)
        output.setSampleBufferDelegate(micOut, queue: sampleQueue)
        if session.canAddOutput(output) { session.addOutput(output) }
        session.startRunning()
        self.captureSession = session
        self.micOutput = micOut
    }

    private func stop() {
        guard isRecording else { return }
        isRecording = false
        hideBorder()

        captureSession?.stopRunning()
        captureSession = nil
        micOutput = nil

        let engine = self.engine
        let stream = self.stream
        self.stream = nil
        self.streamOutput = nil

        Task { @MainActor in
            try? await stream?.stopCapture()
            engine?.finish { url in
                Task { @MainActor in
                    self.engine = nil
                    self.onStateChange?(false)
                    if let url {
                        self.presentSave(tempURL: url)
                    }
                }
            }
        }
    }

    private func presentSave(tempURL: URL) {
        // Dismiss any zoom overlay first so the dialog isn't hidden behind it.
        onWillShowSaveDialog?()

        let panel = NSSavePanel()
        panel.nameFieldStringValue = suggestedFilename()
        panel.allowedContentTypes = [.mpeg4Movie]
        panel.canCreateDirectories = true
        NSApp.activate(ignoringOtherApps: true)

        if panel.runModal() == .OK, let destination = panel.url {
            try? FileManager.default.removeItem(at: destination)
            do {
                try FileManager.default.moveItem(at: tempURL, to: destination)
            } catch {
                let alert = NSAlert(error: error)
                alert.runModal()
            }
        } else {
            try? FileManager.default.removeItem(at: tempURL)
        }
    }

    private func suggestedFilename() -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HHmmss"
        return "ZoomIt \(formatter.string(from: Date())).mp4"
    }

    private func selectRegion(on display: DisplayDescriptor, completion: @escaping (CGRect?) -> Void) {
        Task { @MainActor in
            do {
                let frame = try await captureService.captureDisplay(display)
                let window = SnipWindow(
                    contentRect: frame.display.frame,
                    styleMask: [.borderless],
                    backing: .buffered,
                    defer: false
                )
                window.level = .screenSaver
                window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
                window.backgroundColor = .clear
                window.isOpaque = false
                window.isReleasedWhenClosed = false

                let view = SnipSelectionView(
                    frame: CGRect(origin: .zero, size: frame.display.frame.size),
                    image: frame.image
                )
                var holder: NSWindow? = window
                view.onComplete = { rect in
                    holder?.orderOut(nil)
                    holder = nil
                    completion(rect)
                }
                window.contentView = view
                window.makeKeyAndOrderFront(nil)
                NSApp.activate(ignoringOtherApps: true)
                window.makeFirstResponder(view)
            } catch {
                completion(nil)
            }
        }
    }

    private func cleanup() {
        captureSession?.stopRunning()
        captureSession = nil
        micOutput = nil
        stream = nil
        streamOutput = nil
        engine = nil
        hideBorder()
        isRecording = false
    }

    private func presentError(_ error: Error) {
        let alert = NSAlert(error: error)
        alert.runModal()
    }
}
