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
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        guard let captureDisplay = content.displays.first(where: { $0.displayID == display.id }) else {
            throw ScreenCaptureError.displayNotFound
        }

        let filter = SCContentFilter(display: captureDisplay, excludingWindows: [])
        let configuration = SCStreamConfiguration()
        configuration.width = Int(display.frame.width * display.scaleFactor)
        configuration.height = Int(display.frame.height * display.scaleFactor)
        configuration.showsCursor = false

        let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration)
        return CapturedFrame(
            image: image,
            display: display,
            pixelSize: CGSize(width: image.width, height: image.height),
            timestamp: Date()
        )
    }
}