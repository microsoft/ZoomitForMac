import AVFoundation
import AppKit
import ScreenCaptureKit

/// Wraps a CMSampleBuffer so it can be handed from capture callbacks to the
/// writer queue. CMSampleBuffer is immutable once delivered and the writer
/// serialises all access.
private struct SampleBufferBox: @unchecked Sendable {
    let buffer: CMSampleBuffer
}

private let recordingSyntheticFrameDuration = CMTime(value: 1, timescale: 10)

private struct RecordingImageFrame: @unchecked Sendable {
    let image: CGImage
    let presentationTime: CMTime
    let duration: CMTime

    init(image: CGImage, presentationTime: CMTime, duration: CMTime = recordingSyntheticFrameDuration) {
        self.image = image
        self.presentationTime = presentationTime
        self.duration = duration
    }
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
    private let videoSettings: [String: Any]
    private let width: Int
    private let height: Int
    private var sourceStartTime: CMTime?
    private var sessionStarted = false
    private var hasVideoSample = false
    private var lastVideoPresentationTime: CMTime?
    private var lastVideoDuration = recordingSyntheticFrameDuration
    private var finished = false

    init(url: URL, width: Int, height: Int, systemAudio: Bool, microphone: Bool) throws {
        self.url = url
        self.width = width
        self.height = height
        writer = try AVAssetWriter(outputURL: url, fileType: .mp4)

        videoSettings = [
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

    func startWriting() async {
        await withCheckedContinuation { continuation in
            queue.async {
                self.writer.startWriting()
                continuation.resume()
            }
        }
    }

    func appendVideo(_ box: SampleBufferBox) {
        queue.async {
            guard !self.finished, self.writer.status == .writing,
                  let sampleBuffer = self.retimedVideoSampleBuffer(box.buffer) else { return }
            self.appendVideoOnQueue(sampleBuffer)
        }
    }

    func appendVideoImage(_ frame: RecordingImageFrame) {
        queue.async {
            guard !self.finished, self.writer.status == .writing else { return }
            let presentationTime = self.monotonicVideoPresentationTime(for: frame.presentationTime)
            guard let sampleBuffer = self.makeSampleBuffer(from: frame.image, presentationTime: presentationTime, duration: frame.duration) else { return }
            self.appendVideoOnQueue(sampleBuffer)
        }
    }

    func appendVideoImageIfNeeded(_ frame: RecordingImageFrame) {
        queue.async {
            guard !self.hasVideoSample, !self.finished, self.writer.status == .writing else { return }
            let presentationTime = self.monotonicVideoPresentationTime(for: frame.presentationTime)
            guard let sampleBuffer = self.makeSampleBuffer(from: frame.image, presentationTime: presentationTime, duration: frame.duration) else { return }
            self.appendVideoOnQueue(sampleBuffer)
        }
    }

    func appendVideoImageAtEnd(_ frame: RecordingImageFrame) {
        queue.async {
            guard !self.finished, self.writer.status == .writing else { return }
            let presentationTime = self.monotonicVideoPresentationTime(for: frame.presentationTime)
            guard let sampleBuffer = self.makeSampleBuffer(
                from: frame.image,
                presentationTime: presentationTime,
                duration: frame.duration
            ) else { return }
            self.appendVideoOnQueue(sampleBuffer)
        }
    }

    func appendBlackVideoFrameIfNeeded(presentationTime: CMTime) {
        queue.async {
            guard !self.hasVideoSample, !self.finished, self.writer.status == .writing,
                  let image = self.makeBlackImage(),
                  let sampleBuffer = self.makeSampleBuffer(from: image, presentationTime: self.monotonicVideoPresentationTime(for: presentationTime), duration: recordingSyntheticFrameDuration) else { return }
            self.appendVideoOnQueue(sampleBuffer)
        }
    }

    func waitForQueuedAppends() async {
        await withCheckedContinuation { continuation in
            queue.async {
                continuation.resume()
            }
        }
    }

    func appendSystemAudio(_ box: SampleBufferBox) {
        queue.async {
            guard self.sessionStarted, !self.finished, self.writer.status == .writing,
                  let input = self.systemAudioInput, input.isReadyForMoreMediaData,
                  let sampleBuffer = self.retimedSampleBuffer(box.buffer) else { return }
            input.append(sampleBuffer)
        }
    }

    func appendMicrophone(_ box: SampleBufferBox) {
        queue.async {
            guard self.sessionStarted, !self.finished, self.writer.status == .writing,
                  let input = self.micInput, input.isReadyForMoreMediaData,
                  let sampleBuffer = self.retimedSampleBuffer(box.buffer) else { return }
            input.append(sampleBuffer)
        }
    }

    func finish(completion: @escaping @Sendable (URL?) -> Void) {
        queue.async {
            guard !self.finished, self.writer.status == .writing else {
                self.writeFallbackMovie(completion: completion)
                return
            }
            self.finished = true
            if let endTime = self.endSessionTime() {
                self.writer.endSession(atSourceTime: endTime)
            }
            self.videoInput.markAsFinished()
            self.systemAudioInput?.markAsFinished()
            self.micInput?.markAsFinished()
            let url = self.url
            self.writer.finishWriting {
                if self.writer.status == .completed {
                    completion(url)
                } else {
                    self.writeFallbackMovie(completion: completion)
                }
            }
        }
    }

    private func appendVideoOnQueue(_ sampleBuffer: CMSampleBuffer) {
        if !sessionStarted {
            sessionStarted = true
            writer.startSession(atSourceTime: .zero)
        }
        if videoInput.isReadyForMoreMediaData, videoInput.append(sampleBuffer) {
            hasVideoSample = true
            lastVideoPresentationTime = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
            lastVideoDuration = effectiveDuration(for: sampleBuffer)
        }
    }

    private func normalizedPresentationTime(for sourceTime: CMTime) -> CMTime {
        let validSourceTime = sourceTime.isValid && sourceTime.isNumeric ? sourceTime : (sourceStartTime ?? .zero)
        guard let start = sourceStartTime else {
            sourceStartTime = validSourceTime
            return .zero
        }
        let relativeTime = CMTimeSubtract(validSourceTime, start)
        if relativeTime.isValid, relativeTime.isNumeric, CMTimeCompare(relativeTime, .zero) >= 0 {
            return relativeTime
        }
        return .zero
    }

    private func nextVideoPresentationTime() -> CMTime {
        guard let lastVideoPresentationTime else { return .zero }
        return CMTimeAdd(lastVideoPresentationTime, lastVideoDuration)
    }

    private func monotonicVideoPresentationTime(for sourceTime: CMTime) -> CMTime {
        let normalizedTime = normalizedPresentationTime(for: sourceTime)
        guard let lastVideoPresentationTime else { return normalizedTime }
        return CMTimeCompare(normalizedTime, lastVideoPresentationTime) > 0 ? normalizedTime : nextVideoPresentationTime()
    }

    private func retimedVideoSampleBuffer(_ sampleBuffer: CMSampleBuffer) -> CMSampleBuffer? {
        retimedSampleBuffer(sampleBuffer, presentationTime: monotonicVideoPresentationTime(for: CMSampleBufferGetPresentationTimeStamp(sampleBuffer)))
    }

    private func retimedSampleBuffer(_ sampleBuffer: CMSampleBuffer) -> CMSampleBuffer? {
        retimedSampleBuffer(sampleBuffer, presentationTime: normalizedPresentationTime(for: CMSampleBufferGetPresentationTimeStamp(sampleBuffer)))
    }

    private func retimedSampleBuffer(_ sampleBuffer: CMSampleBuffer, presentationTime: CMTime) -> CMSampleBuffer? {
        var timing = CMSampleTimingInfo(
            duration: effectiveDuration(for: sampleBuffer),
            presentationTimeStamp: presentationTime,
            decodeTimeStamp: .invalid
        )
        var retimed: CMSampleBuffer?
        guard CMSampleBufferCreateCopyWithNewTiming(
            allocator: kCFAllocatorDefault,
            sampleBuffer: sampleBuffer,
            sampleTimingEntryCount: 1,
            sampleTimingArray: &timing,
            sampleBufferOut: &retimed
        ) == noErr else { return nil }
        return retimed
    }

    private func effectiveDuration(for sampleBuffer: CMSampleBuffer) -> CMTime {
        let duration = CMSampleBufferGetDuration(sampleBuffer)
        if duration.isValid, duration.isNumeric, CMTimeCompare(duration, .zero) > 0 {
            return duration
        }
        return recordingSyntheticFrameDuration
    }

    private func endSessionTime() -> CMTime? {
        guard let lastVideoPresentationTime else { return nil }
        let endTime = CMTimeAdd(lastVideoPresentationTime, lastVideoDuration)
        return endTime.isValid && endTime.isNumeric ? endTime : nil
    }

    private func makeSampleBuffer(from image: CGImage, presentationTime: CMTime, duration: CMTime = .invalid) -> CMSampleBuffer? {
        let attributes: [CFString: Any] = [
            kCVPixelBufferCGImageCompatibilityKey: true,
            kCVPixelBufferCGBitmapContextCompatibilityKey: true,
            kCVPixelBufferIOSurfacePropertiesKey: [:]
        ]
        var pixelBuffer: CVPixelBuffer?
        guard CVPixelBufferCreate(
            kCFAllocatorDefault,
            width,
            height,
            kCVPixelFormatType_32BGRA,
            attributes as CFDictionary,
            &pixelBuffer
        ) == kCVReturnSuccess, let pixelBuffer else { return nil }

        CVPixelBufferLockBaseAddress(pixelBuffer, [])
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, []) }

        guard let base = CVPixelBufferGetBaseAddress(pixelBuffer) else { return nil }
        let bytesPerRow = CVPixelBufferGetBytesPerRow(pixelBuffer)
        let bitmapInfo = CGBitmapInfo.byteOrder32Little.rawValue | CGImageAlphaInfo.premultipliedFirst.rawValue
        guard let context = CGContext(
            data: base,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: bytesPerRow,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: bitmapInfo
        ) else { return nil }

        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))

        var description: CMVideoFormatDescription?
        guard CMVideoFormatDescriptionCreateForImageBuffer(
            allocator: kCFAllocatorDefault,
            imageBuffer: pixelBuffer,
            formatDescriptionOut: &description
        ) == noErr, let description else { return nil }

        var timing = CMSampleTimingInfo(
            duration: duration,
            presentationTimeStamp: presentationTime,
            decodeTimeStamp: .invalid
        )
        var sampleBuffer: CMSampleBuffer?
        guard CMSampleBufferCreateReadyWithImageBuffer(
            allocator: kCFAllocatorDefault,
            imageBuffer: pixelBuffer,
            formatDescription: description,
            sampleTiming: &timing,
            sampleBufferOut: &sampleBuffer
        ) == noErr else { return nil }
        return sampleBuffer
    }

    private func makeBlackImage() -> CGImage? {
        let bitmapInfo = CGBitmapInfo.byteOrder32Little.rawValue | CGImageAlphaInfo.premultipliedFirst.rawValue
        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: bitmapInfo
        ) else { return nil }
        context.setFillColor(NSColor.black.cgColor)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage()
    }

    private func writeFallbackMovie(completion: @escaping @Sendable (URL?) -> Void) {
        try? FileManager.default.removeItem(at: url)
        do {
            let fallbackWriter = try AVAssetWriter(outputURL: url, fileType: .mp4)
            let input = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings)
            input.expectsMediaDataInRealTime = false
            guard fallbackWriter.canAdd(input), let image = makeBlackImage() else {
                completion(nil)
                return
            }
            fallbackWriter.add(input)
            fallbackWriter.startWriting()
            fallbackWriter.startSession(atSourceTime: .zero)
            guard let sampleBuffer = makeSampleBuffer(
                from: image,
                presentationTime: .zero,
                duration: CMTime(value: 1, timescale: 10)
            ), input.append(sampleBuffer) else {
                fallbackWriter.cancelWriting()
                completion(nil)
                return
            }
            fallbackWriter.endSession(atSourceTime: recordingSyntheticFrameDuration)
            input.markAsFinished()
            nonisolated(unsafe) let writerForCompletion = fallbackWriter
            fallbackWriter.finishWriting {
                completion(writerForCompletion.status == .completed ? self.url : nil)
            }
        } catch {
            completion(nil)
        }
    }
}

/// Forwards ScreenCaptureKit video and system-audio buffers to the engine.
private final class RecordingStreamOutput: NSObject, SCStreamOutput, @unchecked Sendable {
    private let engine: RecordingEngine
    private let overlayFrameProvider: (@MainActor @Sendable () -> CGImage?)?
    private let stateLock = NSLock()
    private var overlayActive = false
    private var overlayFramePending = false
    private var lastOverlayProbeTime: CMTime?
    private var lastOverlayFrameTime: CMTime?

    private static let overlayFrameInterval = CMTime(value: 1, timescale: 10)
    private static let inactiveOverlayProbeInterval = CMTime(value: 1, timescale: 4)

    init(engine: RecordingEngine, overlayFrameProvider: (@MainActor @Sendable () -> CGImage?)?) {
        self.engine = engine
        self.overlayFrameProvider = overlayFrameProvider
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard sampleBuffer.isValid else { return }
        switch type {
        case .screen:
            // Skip frames that aren't complete (e.g. idle/blank) so only real
            // updates are encoded.
            guard let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
                  let statusRaw = attachments.first?[.status] as? Int,
                  statusRaw == SCFrameStatus.complete.rawValue else { return }
            let box = SampleBufferBox(buffer: sampleBuffer)
            guard let overlayFrameProvider else {
                engine.appendVideo(box)
                return
            }
            let presentationTime = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
            handleScreenFrame(box, presentationTime: presentationTime, overlayFrameProvider: overlayFrameProvider)
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

    private func handleScreenFrame(
        _ box: SampleBufferBox,
        presentationTime: CMTime,
        overlayFrameProvider: @escaping @MainActor @Sendable () -> CGImage?
    ) {
        stateLock.lock()
        let isOverlayActive = overlayActive

        if !isOverlayActive {
            let shouldProbe = !overlayFramePending && shouldProbeInactiveOverlay(at: presentationTime)
            if shouldProbe {
                overlayFramePending = true
                lastOverlayProbeTime = presentationTime
            }
            stateLock.unlock()

            if shouldProbe {
                Task { @MainActor in
                    let image = overlayFrameProvider()
                    self.finishOverlayFrame(image: image, fallback: box, presentationTime: presentationTime)
                }
            } else {
                engine.appendVideo(box)
            }
            return
        }

        if overlayFramePending || shouldSkipOverlayFrame(at: presentationTime) {
            stateLock.unlock()
            return
        }

        overlayFramePending = true
        stateLock.unlock()

        Task { @MainActor in
            let image = overlayFrameProvider()
            self.finishOverlayFrame(image: image, fallback: box, presentationTime: presentationTime)
        }
    }

    private func shouldProbeInactiveOverlay(at presentationTime: CMTime) -> Bool {
        guard let lastOverlayProbeTime else { return true }
        return CMTimeCompare(CMTimeSubtract(presentationTime, lastOverlayProbeTime), Self.inactiveOverlayProbeInterval) >= 0
    }

    private func shouldSkipOverlayFrame(at presentationTime: CMTime) -> Bool {
        guard let lastOverlayFrameTime else { return false }
        return CMTimeCompare(CMTimeSubtract(presentationTime, lastOverlayFrameTime), Self.overlayFrameInterval) < 0
    }

    private func finishOverlayFrame(image: CGImage?, fallback: SampleBufferBox, presentationTime: CMTime) {
        if let image {
            engine.appendVideoImage(RecordingImageFrame(image: image, presentationTime: presentationTime))
        } else {
            engine.appendVideo(fallback)
        }

        stateLock.lock()
        overlayActive = image != nil
        overlayFramePending = false
        if image != nil {
            lastOverlayFrameTime = presentationTime
        }
        stateLock.unlock()
    }

    func waitForPendingOverlayFrame() async {
        guard overlayFrameProvider != nil else { return }
        for _ in 0..<60 {
            if !hasPendingOverlayFrame() { return }
            await Task.yield()
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
    }

    @MainActor
    func appendFinalOverlayFrameIfNeeded(presentationTime: CMTime) {
        guard let overlayFrameProvider, let image = overlayFrameProvider() else { return }
        engine.appendVideoImageIfNeeded(RecordingImageFrame(image: image, presentationTime: presentationTime))
    }

    private func hasPendingOverlayFrame() -> Bool {
        stateLock.lock()
        let pending = overlayFramePending
        stateLock.unlock()
        return pending
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
    private var isFinalizingRecording = false
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
    private var recordingDisplay: DisplayDescriptor?
    private var recordingSourceRect: CGRect?
    private let webcam: WebcamOverlayController
    private let sampleQueue = DispatchQueue(label: "com.zoomitmac.recorder.samples")
    private var clipEditor: VideoClipEditorController?
    var overlayFrameProvider: (@MainActor @Sendable (CGRect?) -> CGImage?)?
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
        self.webcam = WebcamOverlayController(permissionService: permissionService)
    }

    /// Toggles recording. When starting, `region` chooses whole-screen vs. a
    /// dragged region. `onStateChange(true/false)` reports start/stop.
    func toggle(region: Bool, onStateChange: @escaping (Bool) -> Void) {
        if isRecording {
            stop()
        } else if isFinalizingRecording || clipEditor != nil {
            NSSound.beep()
        } else {
            self.onStateChange = onStateChange
            start(region: region)
        }
    }

    var webcamWindowNumberForScreenCaptureExclusion: Int? {
        webcam.windowNumber
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
            beginCapture(display: display, sourceRect: fullDisplaySourceRect(for: display))
        }
    }

    private func fullDisplaySourceRect(for display: DisplayDescriptor) -> CGRect {
        CGRect(origin: .zero, size: display.frame.size)
    }

    private func beginCapture(display: DisplayDescriptor, sourceRect: CGRect?) {
        recordingDisplay = display
        recordingSourceRect = sourceRect
        // Show the orange recording border first so it's part of our own windows
        // (excluded from capture) before the stream filter is built.
        showBorder(display: display, region: sourceRect)
        // Show the webcam picture-in-picture overlay (if enabled), positioned
        // inside the recorded area so it appears within the recording. When a
        // ZoomIt overlay is active, the webcam stays visually fixed and is
        // composited into overlay frames instead of being captured as screen
        // content.
        Task { @MainActor in
            do {
                await self.webcam.start(settings: self.settingsStore.load(), area: self.recordedArea(display: display, region: sourceRect))
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

    /// The recorded area in global (bottom-left origin) screen coordinates: the
    /// region for a region recording, or the whole display otherwise. `region`
    /// is in display points with a top-left origin, so its Y is flipped.
    private func recordedArea(display: DisplayDescriptor, region: CGRect?) -> CGRect {
        guard let region else { return display.frame }
        return CGRect(
            x: display.frame.minX + region.minX,
            y: display.frame.minY + display.frame.height - region.maxY,
            width: region.width,
            height: region.height
        )
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
        let overlayFrameProvider = self.overlayFrameProvider
        configuration.minimumFrameInterval = CMTime(value: 1, timescale: overlayFrameProvider == nil ? 60 : 30)
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
        await engine.startWriting()
        self.engine = engine

        let stream = SCStream(filter: filter, configuration: configuration, delegate: nil)
        let output = RecordingStreamOutput(engine: engine, overlayFrameProvider: overlayFrameProvider.map { provider in
            { @MainActor @Sendable in
                guard let overlayImage = provider(sourceRect) else { return nil }
                guard let webcamFrame = self.webcam.recordingSnapshot() else { return overlayImage }
                return self.composite(webcamFrame, over: overlayImage, display: display, sourceRect: sourceRect)
            }
        })
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

    private func composite(_ webcamFrame: WebcamRecordingFrame, over overlayImage: CGImage, display: DisplayDescriptor, sourceRect: CGRect?) -> CGImage {
        let width = overlayImage.width
        let height = overlayImage.height
        let bitmapInfo = CGBitmapInfo.byteOrder32Little.rawValue | CGImageAlphaInfo.premultipliedFirst.rawValue
        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: bitmapInfo
        ) else { return overlayImage }

        context.interpolationQuality = .high
        context.draw(overlayImage, in: CGRect(x: 0, y: 0, width: width, height: height))

        let scale = CGFloat(width) / (sourceRect?.width ?? display.frame.width)
        let source = sourceRect ?? CGRect(origin: .zero, size: display.frame.size)
        let frame = webcamFrame.frame
        let x = (frame.minX - display.frame.minX - source.minX) * scale
        let topY = (display.frame.maxY - frame.maxY - source.minY) * scale
        let webcamWidth = frame.width * scale
        let webcamHeight = frame.height * scale
        let drawRect = CGRect(x: x, y: CGFloat(height) - topY - webcamHeight, width: webcamWidth, height: webcamHeight).integral
        guard drawRect.intersects(CGRect(x: 0, y: 0, width: width, height: height)) else { return overlayImage }

        context.saveGState()
        let clipped = drawRect.intersection(CGRect(x: 0, y: 0, width: width, height: height))
        let path = CGPath(roundedRect: clipped, cornerWidth: webcamFrame.cornerRadius * scale, cornerHeight: webcamFrame.cornerRadius * scale, transform: nil)
        context.addPath(path)
        context.clip()

        let imageSize = CGSize(width: webcamFrame.image.width, height: webcamFrame.image.height)
        let imageAspect = imageSize.width / imageSize.height
        let rectAspect = drawRect.width / drawRect.height
        var imageRect = drawRect
        if imageAspect > rectAspect {
            imageRect.size.width = drawRect.height * imageAspect
            imageRect.origin.x = drawRect.midX - imageRect.width / 2
        } else {
            imageRect.size.height = drawRect.width / imageAspect
            imageRect.origin.y = drawRect.midY - imageRect.height / 2
        }
        context.draw(webcamFrame.image, in: imageRect)
        context.restoreGState()

        return context.makeImage() ?? overlayImage
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
        isFinalizingRecording = true
        hideBorder()

        captureSession?.stopRunning()
        captureSession = nil
        micOutput = nil

        let engine = self.engine
        let stream = self.stream
        let streamOutput = self.streamOutput
        let recordingDisplay = self.recordingDisplay
        let recordingSourceRect = self.recordingSourceRect
        self.stream = nil
        self.streamOutput = nil
        self.recordingDisplay = nil
        self.recordingSourceRect = nil

        Task { @MainActor in
            try? await stream?.stopCapture()
            await streamOutput?.waitForPendingOverlayFrame()
            streamOutput?.appendFinalOverlayFrameIfNeeded(presentationTime: CMClockGetTime(CMClockGetHostTimeClock()))
            if let recordingDisplay,
               let image = try? await self.captureFallbackFrame(display: recordingDisplay, sourceRect: recordingSourceRect) {
                engine?.appendVideoImageAtEnd(RecordingImageFrame(image: image, presentationTime: CMClockGetTime(CMClockGetHostTimeClock())))
            }
            engine?.appendBlackVideoFrameIfNeeded(presentationTime: CMClockGetTime(CMClockGetHostTimeClock()))
            self.webcam.stop()
            await engine?.waitForQueuedAppends()
            engine?.finish { url in
                Task { @MainActor in
                    self.engine = nil
                    self.onStateChange?(false)
                    if let url {
                        self.presentSave(tempURL: url)
                    } else {
                        self.isFinalizingRecording = false
                        self.presentError(ScreenCaptureError.recordingFailed)
                    }
                }
            }
        }
    }

    private func captureFallbackFrame(display: DisplayDescriptor, sourceRect: CGRect?) async throws -> CGImage {
        let frame = try await captureService.captureDisplay(display)
        guard let sourceRect else { return frame.image }
        let scale = display.scaleFactor
        let pixelRect = CGRect(
            x: sourceRect.minX * scale,
            y: sourceRect.minY * scale,
            width: sourceRect.width * scale,
            height: sourceRect.height * scale
        ).integral
        return frame.image.cropping(to: pixelRect) ?? frame.image
    }

    private func presentSave(tempURL: URL) {
        // Dismiss any zoom overlay first so the editor isn't hidden behind it.
        onWillShowSaveDialog?()
        DispatchQueue.main.async { [weak self] in
            self?.presentClipEditor(tempURL: tempURL)
        }
    }

    private func presentClipEditor(tempURL: URL) {
        // Show the clip editor (preview, trim, append) before saving, mirroring
        // ZoomIt on Windows. The editor exports an edited MP4, which we then
        // move to the chosen destination.
        NSApp.activate(ignoringOtherApps: true)
        let editor = VideoClipEditorController()
        self.clipEditor = editor
        let editorLevel = NSWindow.Level(rawValue: NSWindow.Level.screenSaver.rawValue + 2)
        editor.present(tempURL: tempURL, suggestedName: suggestedFilename(), windowLevel: editorLevel, onSave: { [weak self] editedURL in
            self?.clipEditor = nil
            try? FileManager.default.removeItem(at: tempURL)
            self?.savePanel(for: editedURL)
        }, onCancel: { [weak self] in
            self?.clipEditor = nil
            self?.isFinalizingRecording = false
            try? FileManager.default.removeItem(at: tempURL)
        })
    }

    private func savePanel(for tempURL: URL) {
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
        isFinalizingRecording = false
    }

    private func suggestedFilename() -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HHmmss"
        return "ZoomIt \(formatter.string(from: Date())).mp4"
    }

    /// Opens an existing video file in the clip editor (trim, append, save),
    /// mirroring ZoomIt's standalone "Trim" workflow. The edited result is
    /// exported and the user picks where to save it.
    func openForTrim() {
        let open = NSOpenPanel()
        open.title = "Trim Video"
        open.allowedContentTypes = [.mpeg4Movie, .quickTimeMovie]
        open.canChooseDirectories = false
        open.allowsMultipleSelection = false
        NSApp.activate(ignoringOtherApps: true)
        guard open.runModal() == .OK, let url = open.url else { return }
        let editor = VideoClipEditorController()
        self.clipEditor = editor
        editor.present(tempURL: url, suggestedName: suggestedFilename(), onSave: { [weak self] editedURL in
            self?.clipEditor = nil
            self?.savePanel(for: editedURL)
        }, onCancel: { [weak self] in
            self?.clipEditor = nil
        })
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
                var cursorLease: CrosshairCursorLease?
                view.onComplete = { rect in
                    cursorLease?.invalidate()
                    cursorLease = nil
                    holder?.orderOut(nil)
                    holder = nil
                    completion(rect)
                }
                window.contentView = view
                window.makeKeyAndOrderFront(nil)
                NSApp.activate(ignoringOtherApps: true)
                window.makeFirstResponder(view)
                cursorLease = CrosshairCursorLease(window: window)
                cursorLease?.activate()
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
        recordingDisplay = nil
        recordingSourceRect = nil
        isFinalizingRecording = false
        hideBorder()
        webcam.stop()
        isRecording = false
    }

    private func presentError(_ error: Error) {
        let alert = NSAlert(error: error)
        alert.runModal()
    }
}
