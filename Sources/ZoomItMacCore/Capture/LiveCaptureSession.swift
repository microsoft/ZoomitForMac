import CoreImage
import CoreMedia
import ScreenCaptureKit

/// A CGImage that is safe to hand across concurrency domains. CGImage is an
/// immutable, thread-safe Core Foundation type, but it is not formally Sendable,
/// so this box carries it from the capture queue to the main actor.
struct SendableCGImage: @unchecked Sendable {
    let image: CGImage
}

/// Streams a live, continuously updating image of a display via ScreenCaptureKit.
///
/// macOS has no public third-party magnification API equivalent to Windows'
/// `magnification.dll`, so live zoom is implemented by capturing the screen with
/// `SCStream` and magnifying each delivered frame in the overlay. The session
/// excludes ZoomIt's own process so the magnified overlay is never captured
/// back into itself.
final class LiveCaptureSession: NSObject, SCStreamOutput, @unchecked Sendable {
    private var stream: SCStream?
    private let ciContext = CIContext(options: [.useSoftwareRenderer: false])
    private let sampleQueue = DispatchQueue(label: "com.zoomitmac.livecapture")
    private let frameHandler: @MainActor (CGImage) -> Void

    /// - Parameter frameHandler: invoked on the main actor with each new frame.
    init(frameHandler: @escaping @MainActor (CGImage) -> Void) {
        self.frameHandler = frameHandler
        super.init()
    }

    @MainActor
    func start(display: DisplayDescriptor, excludingWindowNumber: Int? = nil) async throws {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        guard let captureDisplay = content.displays.first(where: { $0.displayID == display.id }) else {
            throw ScreenCaptureError.displayNotFound
        }

        // Exclude every window owned by our own process (the magnified overlay,
        // the menu-bar item, etc.) so the live stream never captures the overlay
        // back into itself. Without this, each captured frame contains the
        // already-magnified overlay, which is then magnified again, tunnelling in
        // infinitely until the screen degrades to a solid color. The overlay is
        // also matched by window number directly in case its owning application
        // is not reported for the screen-saver-level window.
        let ownPID = getpid()
        let excludedWindowID = excludingWindowNumber.map { CGWindowID($0) }
        let ownWindows = content.windows.filter { window in
            window.owningApplication?.processID == ownPID || window.windowID == excludedWindowID
        }
        let filter = SCContentFilter(display: captureDisplay, excludingWindows: ownWindows)

        let configuration = SCStreamConfiguration()
        configuration.width = Int(display.frame.width * display.scaleFactor)
        configuration.height = Int(display.frame.height * display.scaleFactor)
        configuration.showsCursor = false
        configuration.pixelFormat = kCVPixelFormatType_32BGRA
        configuration.queueDepth = 3
        configuration.minimumFrameInterval = CMTime(value: 1, timescale: 60)

        let stream = SCStream(filter: filter, configuration: configuration, delegate: nil)
        try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: sampleQueue)
        try await stream.startCapture()
        self.stream = stream
    }

    func stop() async {
        guard let stream else { return }
        self.stream = nil
        try? await stream.stopCapture()
    }

    // MARK: - SCStreamOutput

    nonisolated func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen,
              sampleBuffer.isValid,
              let pixelBuffer = sampleBuffer.imageBuffer else { return }

        let ciImage = CIImage(cvPixelBuffer: pixelBuffer)
        guard let cgImage = ciContext.createCGImage(ciImage, from: ciImage.extent) else { return }

        let boxed = SendableCGImage(image: cgImage)
        let handler = frameHandler
        Task { @MainActor in
            handler(boxed.image)
        }
    }
}
