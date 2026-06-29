import AppKit
import ScreenCaptureKit

struct CapturedFrame {
    var image: CGImage
    var display: DisplayDescriptor
    var pixelSize: CGSize
    var timestamp: Date
}

@MainActor
protocol ScreenCaptureService {
    func captureDisplay(_ display: DisplayDescriptor) async throws -> CapturedFrame
}

enum ScreenCaptureError: LocalizedError {
    case displayNotFound
    case imageCreationFailed

    var errorDescription: String? {
        switch self {
        case .displayNotFound:
            "The active display could not be captured."
        case .imageCreationFailed:
            "The display image could not be created."
        }
    }
}

@MainActor
final class ScreenCaptureKitCaptureService: ScreenCaptureService {
    private let displayManager: DisplayManager

    init(displayManager: DisplayManager) {
        self.displayManager = displayManager
    }

    func captureDisplay(_ display: DisplayDescriptor) async throws -> CapturedFrame {
        guard let image = CGDisplayCreateImage(display.id) else {
            throw ScreenCaptureError.imageCreationFailed
        }
        return CapturedFrame(
            image: image,
            display: display,
            pixelSize: CGSize(width: image.width, height: image.height),
            timestamp: Date()
        )
    }
}