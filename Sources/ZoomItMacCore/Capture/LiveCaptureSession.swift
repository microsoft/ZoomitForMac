import CoreImage
import CoreMedia
@preconcurrency import ScreenCaptureKit

/// A CGImage that is safe to hand across concurrency domains. CGImage is an
/// immutable, thread-safe Core Foundation type, but it is not formally Sendable,
/// so this box carries it from the capture queue to the main actor.
struct SendableCGImage: @unchecked Sendable {
    let image: CGImage
}

enum LiveCaptureFeedbackPolicy {
    static func excludesApplication(
        processID: pid_t,
        ownProcessID: pid_t
    ) -> Bool {
        processID == ownProcessID
    }
}

/// Streams a live, continuously updating image of a display via ScreenCaptureKit.
///
/// macOS has no public third-party magnification API equivalent to Windows'
/// `magnification.dll`, so live zoom is implemented by capturing the screen with
/// `SCStream` and magnifying each delivered frame in the overlay. The filter
/// excludes ZoomIt's whole process, including overlays created after startup,
/// so neither the live overlay nor the recording webcam can feed back.
final class LiveCaptureSession: NSObject, SCStreamOutput, @unchecked Sendable {
    private var stream: SCStream?
    private var stopRequested = false
    private let ciContext = CIContext(options: [.useSoftwareRenderer: false])
    private let sampleQueue = DispatchQueue(label: "com.zoomitmac.livecapture")
    private let frameHandler: @MainActor (CGImage) -> Void

    /// - Parameter frameHandler: invoked on the main actor with each new frame.
    init(frameHandler: @escaping @MainActor (CGImage) -> Void) {
        self.frameHandler = frameHandler
        super.init()
    }

    @MainActor
    func start(display: DisplayDescriptor) async throws {
        stopRequested = false
        let content = try await SCShareableContent.excludingDesktopWindows(
            false,
            onScreenWindowsOnly: true
        )
        guard let captureDisplay = content.displays.first(where: {
            $0.displayID == display.id
        }) else {
            throw ScreenCaptureError.displayNotFound
        }

        let ownApplications = content.applications.filter {
            LiveCaptureFeedbackPolicy.excludesApplication(
                processID: $0.processID,
                ownProcessID: ProcessInfo.processInfo.processIdentifier
            )
        }
        let filter = SCContentFilter(
            display: captureDisplay,
            excludingApplications: ownApplications,
            exceptingWindows: []
        )

        let configuration = SCStreamConfiguration()
        configuration.width = Int(display.frame.width * display.scaleFactor)
        configuration.height = Int(display.frame.height * display.scaleFactor)
        configuration.showsCursor = false
        configuration.pixelFormat = kCVPixelFormatType_32BGRA
        configuration.queueDepth = 3
        configuration.minimumFrameInterval = CMTime(value: 1, timescale: 60)

        let stream = SCStream(
            filter: filter,
            configuration: configuration,
            delegate: nil
        )
        try stream.addStreamOutput(
            self,
            type: .screen,
            sampleHandlerQueue: sampleQueue
        )
        try await stream.startCapture()
        if stopRequested {
            try? await stream.stopCapture()
            return
        }
        self.stream = stream
    }

    @MainActor
    func stop() async {
        stopRequested = true
        guard let stream else { return }
        self.stream = nil
        try? await stream.stopCapture()
    }

    // MARK: - SCStreamOutput

    nonisolated func stream(
        _ stream: SCStream,
        didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
        of type: SCStreamOutputType
    ) {
        guard type == .screen,
              sampleBuffer.isValid,
              let pixelBuffer = sampleBuffer.imageBuffer else {
            return
        }

        let ciImage = CIImage(cvPixelBuffer: pixelBuffer)
        guard let cgImage = ciContext.createCGImage(
            ciImage,
            from: ciImage.extent
        ) else {
            return
        }

        let boxed = SendableCGImage(image: cgImage)
        let handler = frameHandler
        Task { @MainActor in
            handler(boxed.image)
        }
    }
}
