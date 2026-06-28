import AppKit

enum SelfTestError: Error, CustomStringConvertible {
    case failure(String)

    var description: String {
        switch self {
        case .failure(let message): message
        }
    }
}

@MainActor
public enum SelfTestRunner {
    public static func run() throws {
        try testViewportClampsZoom()
        try testViewportZoomAnimation()
        try testViewportSourceRect()
        try testViewportContentPointMapping()
        try testViewportContentToDestinationTransform()
        try testFreehandAnnotationLifecycle()
        try testShapeAnnotationEndpointReplacement()
        try testUndoAndClear()
        try testTypingAnnotations()
        try testAnnotationRenderingTouchesPixels()
        try testSettingsRoundTrip()
    }

    private static func testViewportClampsZoom() throws {
        let controller = ZoomViewportController()

        controller.configure(for: try makeFrame(), initialZoom: 100)
        try expect(controller.zoomFactor == 32, "Expected initial zoom to clamp to 32x")

        controller.configure(for: try makeFrame(), initialZoom: 0.25)
        try expect(controller.zoomFactor == 1, "Expected initial zoom to clamp to 1x")
    }

    private static func testViewportZoomAnimation() throws {
        let controller = ZoomViewportController()
        controller.configure(for: try makeFrame(), initialZoom: 2)

        controller.beginZoomInAnimation()
        try expect(controller.zoomFactor == 1, "Expected telescope to start at 1x")
        try expect(controller.isAnimatingZoom, "Expected zoom-in to be animating")

        var steps = 0
        while controller.advanceZoomAnimation() {
            steps += 1
            try expect(steps < 1000, "Zoom-in animation did not converge")
        }
        try expect(controller.zoomFactor == 2, "Expected telescope to reach 2x, got \(controller.zoomFactor)")
        try expect(!controller.isAnimatingZoom, "Expected animation to stop at target")

        controller.animateZoom(to: 1)
        try expect(controller.isAnimatingZoom, "Expected zoom-out to be animating")
        steps = 0
        while controller.advanceZoomAnimation() {
            steps += 1
            try expect(steps < 1000, "Zoom-out animation did not converge")
        }
        try expect(controller.zoomFactor == 1, "Expected telescope to reach 1x, got \(controller.zoomFactor)")
    }

    private static func testViewportSourceRect() throws {
        let controller = ZoomViewportController()
        controller.configure(for: try makeFrame(), initialZoom: 2)

        let rect = controller.sourceRect(
            for: CGRect(x: 0, y: 0, width: 1000, height: 800),
            cursorLocation: CGPoint(x: 500, y: 400)
        )

        try expect(rect == CGRect(x: 250, y: 200, width: 500, height: 400), "Unexpected centered source rect: \(rect)")
    }

    private static func testViewportContentPointMapping() throws {
        let controller = ZoomViewportController()
        controller.configure(for: try makeFrame(), initialZoom: 2)

        let point = controller.contentPoint(
            for: CGPoint(x: 500, y: 400),
            destinationBounds: CGRect(x: 0, y: 0, width: 1000, height: 800),
            cursorLocation: CGPoint(x: 500, y: 400)
        )

        try expect(point == CGPoint(x: 500, y: 400), "Unexpected mapped content point: \(point)")
    }

    private static func testViewportContentToDestinationTransform() throws {
        let controller = ZoomViewportController()
        let transform = controller.contentToDestinationTransform(
            source: CGRect(x: 250, y: 200, width: 500, height: 400),
            destinationBounds: CGRect(x: 0, y: 0, width: 1000, height: 800)
        )

        try expect(CGPoint(x: 250, y: 200).applying(transform) == CGPoint(x: 0, y: 0), "Expected source origin to map to destination origin")
        try expect(CGPoint(x: 500, y: 400).applying(transform) == CGPoint(x: 500, y: 400), "Expected source center to map to destination center")
    }

    private static func testFreehandAnnotationLifecycle() throws {
        let controller = AnnotationController()

        controller.begin(at: CGPoint(x: 1, y: 2))
        controller.update(at: CGPoint(x: 3, y: 4))
        controller.update(at: CGPoint(x: 5, y: 6))
        controller.end(at: CGPoint(x: 7, y: 8))

        try expect(controller.annotationSnapshot.count == 1, "Expected one freehand annotation")
        try expect(controller.annotationSnapshot[0].tool == .pen, "Expected freehand tool to be pen")
        try expect(controller.annotationSnapshot[0].points == [
            CGPoint(x: 1, y: 2),
            CGPoint(x: 3, y: 4),
            CGPoint(x: 5, y: 6),
            CGPoint(x: 7, y: 8)
        ], "Unexpected freehand points")
    }

    private static func testShapeAnnotationEndpointReplacement() throws {
        let controller = AnnotationController()
        controller.currentTool = .rectangle

        controller.begin(at: CGPoint(x: 10, y: 20))
        controller.update(at: CGPoint(x: 30, y: 40))
        controller.update(at: CGPoint(x: 50, y: 60))
        controller.end(at: CGPoint(x: 70, y: 80))

        try expect(controller.annotationSnapshot.count == 1, "Expected one rectangle annotation")
        try expect(controller.annotationSnapshot[0].points == [CGPoint(x: 10, y: 20), CGPoint(x: 70, y: 80)], "Shape should keep start and final endpoint")
    }

    private static func testUndoAndClear() throws {
        let controller = AnnotationController()

        controller.begin(at: .zero)
        controller.end(at: CGPoint(x: 1, y: 1))
        controller.begin(at: CGPoint(x: 2, y: 2))
        controller.end(at: CGPoint(x: 3, y: 3))

        try expect(controller.annotationSnapshot.count == 2, "Expected two annotations before undo")
        controller.undo()
        try expect(controller.annotationSnapshot.count == 1, "Expected one annotation after undo")
        controller.clear()
        try expect(controller.annotationSnapshot.isEmpty, "Expected no annotations after clear")
    }

    private static func testTypingAnnotations() throws {
        let controller = AnnotationController()
        controller.setInsertionPoint(CGPoint(x: 20, y: 30))

        controller.insertText("H")
        controller.insertText("i")

        try expect(controller.annotationSnapshot.count == 1, "Expected one text annotation")
        try expect(controller.annotationSnapshot[0].tool == .text, "Expected text annotation tool")
        try expect(controller.annotationSnapshot[0].points == [CGPoint(x: 20, y: 30)], "Unexpected text insertion point")
        try expect(controller.annotationSnapshot[0].text == "Hi", "Expected text to append")

        controller.deleteBackward()

        try expect(controller.annotationSnapshot[0].text == "H", "Expected deleteBackward to remove one character")
    }

    private static func testAnnotationRenderingTouchesPixels() throws {
        let width = 64
        let height = 64
        let bytesPerPixel = 4
        var pixels = [UInt8](repeating: 0, count: width * height * bytesPerPixel)

        guard let context = CGContext(
            data: &pixels,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * bytesPerPixel,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            throw SelfTestError.failure("Could not create render test context")
        }

        let controller = AnnotationController()
        controller.currentStyle = AnnotationStyle(color: .red, rootWidth: 8, alpha: 1)
        controller.begin(at: CGPoint(x: 8, y: 32))
        controller.update(at: CGPoint(x: 56, y: 32))
        controller.end(at: CGPoint(x: 56, y: 32))
        controller.render(in: context, bounds: CGRect(x: 0, y: 0, width: width, height: height))

        let touchedPixel = pixels.chunked(into: bytesPerPixel).contains { pixel in
            pixel[0] > 0 || pixel[1] > 0 || pixel[2] > 0 || pixel[3] > 0
        }

        try expect(touchedPixel, "Expected annotation rendering to modify offscreen bitmap pixels")
    }

    private static func testSettingsRoundTrip() throws {
        let suiteName = "ZoomItMacSelfTest.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            throw SelfTestError.failure("Could not create test UserDefaults suite")
        }
        let store = UserDefaultsSettingsStore(defaults: defaults)

        // An unset store returns the documented options-dialog defaults.
        try expect(store.load() == AppSettings.defaults, "Expected unset store to return default settings")

        var settings = AppSettings.defaults
        settings.defaultZoomFactor = 4
        settings.animateZoom = false
        settings.smoothImage = false
        settings.rootPenWidth = 12
        settings.typingFontName = "Helvetica"
        settings.typingFontSize = 48
        settings.hotKeyCode = 19
        settings.hotKeyModifiers = NSEvent.ModifierFlags([.command, .shift]).rawValue
        settings.drawHotKeyCode = 20
        settings.drawHotKeyModifiers = NSEvent.ModifierFlags([.control, .option]).rawValue
        store.save(settings)

        try expect(store.load() == settings, "Expected saved settings to round-trip through the store")

        defaults.removePersistentDomain(forName: suiteName)
    }

    private static func makeFrame() throws -> CapturedFrame {
        guard let context = CGContext(
            data: nil,
            width: 10,
            height: 10,
            bitsPerComponent: 8,
            bytesPerRow: 40,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ), let image = context.makeImage() else {
            throw SelfTestError.failure("Could not create test image")
        }

        return CapturedFrame(
            image: image,
            display: DisplayDescriptor(id: 1, frame: CGRect(x: 0, y: 0, width: 1000, height: 800), scaleFactor: 2),
            pixelSize: CGSize(width: image.width, height: image.height),
            timestamp: Date(timeIntervalSince1970: 0)
        )
    }

    private static func expect(_ condition: Bool, _ message: String) throws {
        if !condition {
            throw SelfTestError.failure(message)
        }
    }
}

private extension Array {
    func chunked(into size: Int) -> [[Element]] {
        stride(from: 0, to: count, by: size).map { start in
            Array(self[start..<Swift.min(start + size, count)])
        }
    }
}