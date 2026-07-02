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
    func captureDisplay(_ display: DisplayDescriptor, excludingWindowNumbers: [Int]) async throws -> CapturedFrame
}

extension ScreenCaptureService {
    func captureDisplay(_ display: DisplayDescriptor) async throws -> CapturedFrame {
        try await captureDisplay(display, excludingWindowNumbers: [])
    }
}

enum ScreenCaptureError: LocalizedError {
    case displayNotFound
    case imageCreationFailed
    case recordingFailed

    var errorDescription: String? {
        switch self {
        case .displayNotFound:
            "The active display could not be captured."
        case .imageCreationFailed:
            "The display image could not be created."
        case .recordingFailed:
            "The screen recording could not be saved."
        }
    }
}

@MainActor
final class ScreenCaptureKitCaptureService: ScreenCaptureService {
    private let displayManager: DisplayManager

    init(displayManager: DisplayManager) {
        self.displayManager = displayManager
    }

    func captureDisplay(_ display: DisplayDescriptor, excludingWindowNumbers: [Int] = []) async throws -> CapturedFrame {
        let image = try await captureImage(display, excludingWindowNumbers: excludingWindowNumbers)
        return CapturedFrame(
            image: image,
            display: display,
            pixelSize: CGSize(width: image.width, height: image.height),
            timestamp: Date()
        )
    }

    private func captureImage(_ display: DisplayDescriptor, excludingWindowNumbers: [Int]) async throws -> CGImage {
        if excludingWindowNumbers.isEmpty {
            guard let image = CGDisplayCreateImage(display.id) else {
                throw ScreenCaptureError.imageCreationFailed
            }
            return image
        }

        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        guard let captureDisplay = content.displays.first(where: { $0.displayID == display.id }) else {
            throw ScreenCaptureError.displayNotFound
        }

        let excludedWindowIDs = Set(excludingWindowNumbers.map { CGWindowID($0) })
        let excludedWindows = content.windows.filter { excludedWindowIDs.contains($0.windowID) }
        let filter = SCContentFilter(display: captureDisplay, excludingWindows: excludedWindows)

        let configuration = SCStreamConfiguration()
        configuration.width = Int(display.frame.width * display.scaleFactor)
        configuration.height = Int(display.frame.height * display.scaleFactor)
        configuration.showsCursor = false
        configuration.pixelFormat = kCVPixelFormatType_32BGRA

        return try await withCheckedThrowingContinuation { continuation in
            SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration) { image, error in
                if let image {
                    continuation.resume(returning: image)
                } else {
                    continuation.resume(throwing: error ?? ScreenCaptureError.imageCreationFailed)
                }
            }
        }
    }
}