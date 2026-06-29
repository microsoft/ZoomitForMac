import AVFoundation
import AppKit

private final class WebcamReadinessProbe: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Void, Never>?
    private var isReady = false

    func waitForFirstFrame(timeoutNanoseconds: UInt64) async -> Bool {
        await withTaskGroup(of: Bool.self) { group in
            group.addTask {
                await self.waitForFirstFrame()
                return true
            }
            group.addTask {
                try? await Task.sleep(nanoseconds: timeoutNanoseconds)
                return false
            }
            let receivedFrame = await group.next() ?? false
            group.cancelAll()
            resolve()
            return receivedFrame
        }
    }

    private func waitForFirstFrame() async {
        await withCheckedContinuation { continuation in
            var resumeNow = false
            lock.lock()
            if isReady {
                resumeNow = true
            } else {
                self.continuation = continuation
            }
            lock.unlock()

            if resumeNow {
                continuation.resume()
            }
        }
    }

    private func resolve() {
        let continuation: CheckedContinuation<Void, Never>?
        lock.lock()
        if isReady {
            continuation = nil
        } else {
            isReady = true
            continuation = self.continuation
            self.continuation = nil
        }
        lock.unlock()
        continuation?.resume()
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard sampleBuffer.isValid else { return }
        resolve()
    }
}

/// Shows the webcam as a picture-in-picture overlay during recording. The
/// overlay is a normal (capturable) window so it appears in the recording, and
/// is click-through so it never blocks interaction.
@MainActor
final class WebcamOverlayController {
    /// Corner placement options (matching the settings order).
    enum Position: Int {
        case topLeft, topRight, bottomLeft, bottomRight
    }

    /// Size presets (matching the settings order).
    enum Size: Int {
        case small, medium, large, xLarge, fullScreen

        /// Height of the overlay in points, or nil for full screen.
        var height: CGFloat? {
            switch self {
            case .small: return 180
            case .medium: return 260
            case .large: return 360
            case .xLarge: return 480
            case .fullScreen: return nil
            }
        }
    }

    /// Border shape options (matching the settings order).
    enum Shape: Int {
        case rectangle, roundedRectangle, roundedSquare, circle

        var isSquare: Bool { self == .roundedSquare || self == .circle }
    }

    private let permissionService: PermissionService
    private var window: NSWindow?
    private var session: AVCaptureSession?
    private var readinessProbe: WebcamReadinessProbe?
    private let readinessQueue = DispatchQueue(label: "com.zoomitmac.webcam.readiness")

    init(permissionService: PermissionService) {
        self.permissionService = permissionService
    }

    /// Starts the webcam overlay positioned within `area` (the recorded region,
    /// or the full display) if it's enabled and the camera is authorized. Safe
    /// to call when disabled (it does nothing).
    func start(settings: AppSettings, area: CGRect) async {
        guard settings.webcamEnabled,
              permissionService.cameraStatus() == .granted,
              let camera = VideoDevices.camera(forID: settings.webcamDeviceID) else { return }

        let position = Position(rawValue: settings.webcamPosition) ?? .bottomRight
        let size = Size(rawValue: settings.webcamSize) ?? .medium
        let shape = Shape(rawValue: settings.webcamShape) ?? .rectangle

        let session = AVCaptureSession()
        session.sessionPreset = .high
        guard let input = try? AVCaptureDeviceInput(device: camera), session.canAddInput(input) else { return }
        session.addInput(input)

        let readinessProbe = WebcamReadinessProbe()
        let readinessOutput = AVCaptureVideoDataOutput()
        readinessOutput.alwaysDiscardsLateVideoFrames = true
        readinessOutput.setSampleBufferDelegate(readinessProbe, queue: readinessQueue)
        let canWaitForFirstFrame = session.canAddOutput(readinessOutput)
        if canWaitForFirstFrame {
            session.addOutput(readinessOutput)
        }

        let previewLayer = AVCaptureVideoPreviewLayer(session: session)
        previewLayer.videoGravity = .resizeAspectFill

        let frame = overlayFrame(area: area, position: position, size: size, shape: shape)

        let window = NSWindow(contentRect: frame, styleMask: [.borderless], backing: .buffered, defer: false)
        // Above the zoom overlay so it stays visible (and recorded) while zoomed,
        // click-through, and capturable (default sharingType) so it's recorded.
        window.level = NSWindow.Level(rawValue: NSWindow.Level.screenSaver.rawValue + 1)
        window.backgroundColor = .clear
        window.isOpaque = false
        window.ignoresMouseEvents = true
        window.hasShadow = false
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        window.isReleasedWhenClosed = false

        let contentView = NSView(frame: CGRect(origin: .zero, size: frame.size))
        contentView.wantsLayer = true
        previewLayer.frame = contentView.bounds
        applyShape(shape, to: previewLayer, size: size, bounds: contentView.bounds)
        contentView.layer?.addSublayer(previewLayer)
        window.contentView = contentView

        window.orderFrontRegardless()
        session.startRunning()

        self.window = window
        self.session = session
        self.readinessProbe = readinessProbe

        if canWaitForFirstFrame {
            let receivedFrame = await readinessProbe.waitForFirstFrame(timeoutNanoseconds: 2_000_000_000)
            if receivedFrame {
                await settlePreview(window: window, contentView: contentView)
            }
        }
    }

    func stop() {
        session?.stopRunning()
        session = nil
        readinessProbe = nil
        window?.orderOut(nil)
        window = nil
    }

    private func applyShape(_ shape: Shape, to layer: CALayer, size: Size, bounds: CGRect) {
        layer.masksToBounds = true
        switch shape {
        case .rectangle:
            layer.cornerRadius = 0
        case .roundedRectangle, .roundedSquare:
            layer.cornerRadius = min(bounds.width, bounds.height) * 0.12
        case .circle:
            layer.cornerRadius = min(bounds.width, bounds.height) / 2
        }
        // Full screen ignores shape.
        if size == .fullScreen {
            layer.cornerRadius = 0
        }
    }

    private func settlePreview(window: NSWindow, contentView: NSView) async {
        contentView.displayIfNeeded()
        window.displayIfNeeded()
        await Task.yield()
        contentView.displayIfNeeded()
        window.displayIfNeeded()
        try? await Task.sleep(nanoseconds: 250_000_000)
    }

    private func overlayFrame(area: CGRect, position: Position, size: Size, shape: Shape) -> CGRect {
        guard let presetHeight = size.height else {
            return area // full screen fills the recorded area
        }
        let margin: CGFloat = 24
        var height = presetHeight
        var width = shape.isSquare ? height : height * (16.0 / 9.0)
        // Clamp to fit within the recorded area (minus margins) for small regions.
        let maxWidth = max(1, area.width - 2 * margin)
        let maxHeight = max(1, area.height - 2 * margin)
        if width > maxWidth || height > maxHeight {
            let scale = min(maxWidth / width, maxHeight / height, 1)
            width *= scale
            height *= scale
        }

        let x: CGFloat
        let y: CGFloat
        switch position {
        case .topLeft:
            x = area.minX + margin
            y = area.maxY - margin - height
        case .topRight:
            x = area.maxX - margin - width
            y = area.maxY - margin - height
        case .bottomLeft:
            x = area.minX + margin
            y = area.minY + margin
        case .bottomRight:
            x = area.maxX - margin - width
            y = area.minY + margin
        }
        return CGRect(x: x, y: y, width: width, height: height)
    }
}
