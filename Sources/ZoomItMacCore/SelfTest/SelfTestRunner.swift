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
        try testPanoramaStitching()
        try testPanoramaTopSeamUsesSingleFramePixels()
        try testPanoramaDeferredDirectionCommit()
        try testPanoramaNoHarmonicRepeats()
        try testPanoramaFixedHeaderSuppression()
        try testPanoramaFooterDoesNotAttractSmallShift()
        try testPanoramaFixedFooterSuppression()
        try testPanoramaSkipsRepeatedCaptures()
        try testPanoramaSparseTallContentStitches()
        try testPanoramaStartupAxisRejectsHorizontalAlias()
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
        settings.liveHotKeyCode = 23
        settings.liveHotKeyModifiers = NSEvent.ModifierFlags([.control, .shift]).rawValue
        settings.snipHotKeyCode = 22
        settings.snipHotKeyModifiers = NSEvent.ModifierFlags([.control, .option]).rawValue
        settings.recordHotKeyCode = 23
        settings.recordHotKeyModifiers = NSEvent.ModifierFlags([.control, .command]).rawValue
        settings.panoramaHotKeyCode = 28
        settings.panoramaHotKeyModifiers = NSEvent.ModifierFlags([.control, .shift]).rawValue
        settings.recordSystemAudio = true
        settings.recordMicrophone = true
        settings.microphoneDeviceID = "test-mic-id"
        settings.webcamEnabled = true
        settings.webcamDeviceID = "test-cam-id"
        settings.webcamPosition = 1
        settings.webcamSize = 2
        settings.webcamShape = 3
        store.save(settings)

        try expect(store.load() == settings, "Expected saved settings to round-trip through the store")

        defaults.removePersistentDomain(forName: suiteName)
    }

    /// Synthesize a tall "document" with structured rows, slice overlapping
    /// frames that scroll down by a known amount, and verify the stitcher
    /// reconstructs a panorama taller than a single frame with the document's
    /// content aligned. Exercises the same alignment path used at runtime.
    private static func testPanoramaStitching() throws {
        let width = 320
        let frameHeight = 240
        let scrollPerFrame = 40
        let frameCount = 8
        let documentHeight = frameHeight + scrollPerFrame * (frameCount - 1)

        // Build a deterministic document: each row has a distinctive horizontal
        // pattern derived from its y so alignment has structure to lock onto.
        func documentPixel(x: Int, y: Int) -> (UInt8, UInt8, UInt8) {
            let stripe = ((y / 7) % 2 == 0) ? 40 : 210
            let edge = ((x + y) % 23 < 3) ? 255 : 0
            let r = UInt8(clamping: stripe ^ (y & 0x3F))
            let g = UInt8(clamping: (x * 13 + y * 7) & 0xFF)
            let b = UInt8(clamping: edge)
            return (r, g, b)
        }

        func makeSliceFrame(topRow: Int) -> PanoramaStitcher.Frame {
            var pixels = [UInt8](repeating: 0, count: width * frameHeight * 4)
            for y in 0..<frameHeight {
                let docY = topRow + y
                for x in 0..<width {
                    let (r, g, b) = documentPixel(x: x, y: docY)
                    let i = (y * width + x) * 4
                    pixels[i] = r
                    pixels[i + 1] = g
                    pixels[i + 2] = b
                    pixels[i + 3] = 255
                }
            }
            return PanoramaStitcher.Frame(width: width, height: frameHeight, pixels: pixels)
        }

        var frames: [PanoramaStitcher.Frame] = []
        for f in 0..<frameCount {
            frames.append(makeSliceFrame(topRow: f * scrollPerFrame))
        }

        guard let stitched = PanoramaStitcher.stitch(frames: frames) else {
            throw SelfTestError.failure("Panorama stitching returned no image")
        }

        try expect(stitched.width == width, "Expected stitched width \(width), got \(stitched.width)")
        // The stitched height should reconstruct close to the full document
        // height (allow a few px of alignment slack).
        try expect(abs(stitched.height - documentHeight) <= 4,
                   "Expected stitched height ~\(documentHeight), got \(stitched.height)")

        // Spot-check that a sample of stitched pixels matches the source
        // document, confirming the frames were aligned (not merely concatenated).
        func stitchedPixel(x: Int, y: Int) -> (UInt8, UInt8, UInt8) {
            let i = (y * stitched.width + x) * 4
            return (stitched.pixels[i], stitched.pixels[i + 1], stitched.pixels[i + 2])
        }

        var mismatches = 0
        let samples = [(20, 10), (100, 90), (200, 180), (300, 260), (50, documentHeight - 20)]
        for (x, y) in samples where y < stitched.height && x < stitched.width {
            let expected = documentPixel(x: x, y: y)
            let actual = stitchedPixel(x: x, y: y)
            let close = abs(Int(expected.0) - Int(actual.0)) <= 6 &&
                        abs(Int(expected.1) - Int(actual.1)) <= 6 &&
                        abs(Int(expected.2) - Int(actual.2)) <= 6
            if !close { mismatches += 1 }
        }
        try expect(mismatches <= 1, "Expected stitched content to align with the document, \(mismatches) sample mismatches")
    }

    /// The top of a panorama is overlapped by many frames. Early frames are
    /// often motion-blurred (still settling); later frames of the same region
    /// are sharp. The compositor must show the LATEST capture of each pixel so
    /// the top is sharp, not the first blurry one.
    private static func testPanoramaTopSeamUsesSingleFramePixels() throws {
        let width = 160
        let frameHeight = 240
        let scrollPerFrame = 40
        let frameCount = 6
        let documentHeight = frameHeight + scrollPerFrame * (frameCount - 1)

        func sharpPixel(x: Int, y: Int) -> (UInt8, UInt8, UInt8) {
            var hash = UInt32(x) &* 747_796_405 &+ UInt32(y) &* 2_891_336_453 &+ 97
            hash = ((hash >> ((hash >> 28) + 4)) ^ hash) &* 277_803_737
            hash = (hash >> 22) ^ hash
            let edge = (x + y * 3) % 17 < 5 ? 70 : 0
            return (UInt8(30 + Int((hash >> 16) & 0x7F) / 2 + edge),
                    UInt8(40 + Int((hash >> 8) & 0x7F) / 2 + edge),
                    UInt8(50 + Int(hash & 0x7F) / 2 + edge))
        }

        // Earlier frames are blurry (tinted) for the same document position;
        // the last frame to cover a row is the sharp one. variant 0 == sharp.
        func makeFrame(topRow: Int, blur: Int) -> PanoramaStitcher.Frame {
            var pixels = [UInt8](repeating: 0, count: width * frameHeight * 4)
            for y in 0..<frameHeight {
                for x in 0..<width {
                    let p = sharpPixel(x: x, y: topRow + y)
                    let i = (y * width + x) * 4
                    pixels[i] = UInt8(clamping: Int(p.0) + blur)
                    pixels[i + 1] = UInt8(clamping: Int(p.1) + blur)
                    pixels[i + 2] = UInt8(clamping: Int(p.2) + blur)
                    pixels[i + 3] = 255
                }
            }
            return PanoramaStitcher.Frame(width: width, height: frameHeight, pixels: pixels)
        }

        // First frame establishes the top; later frames only add new content
        // below. Keep-first must preserve frame0's pixels (no tiling/overwrite).
        var frames = [makeFrame(topRow: 0, blur: 0)]
        for f in 1..<frameCount { frames.append(makeFrame(topRow: f * scrollPerFrame, blur: 0)) }
        guard let stitched = PanoramaStitcher.stitch(frames: frames) else {
            throw SelfTestError.failure("Top-blur panorama stitching returned no image")
        }
        try expect(abs(stitched.height - documentHeight) <= 8,
                   "Expected top-blur stitched height ~\(documentHeight), got \(stitched.height)")

        func stitchedPixel(x: Int, y: Int) -> (UInt8, UInt8, UInt8) {
            let i = (y * stitched.width + x) * 4
            return (stitched.pixels[i], stitched.pixels[i + 1], stitched.pixels[i + 2])
        }

        var blurryTop = 0
        var checked = 0
        for y in stride(from: 2, to: frameHeight, by: 8) {
            var x = 8
            while x < width - 8 {
                let actual = stitchedPixel(x: x, y: y)
                let sharp = sharpPixel(x: x, y: y)
                if abs(Int(actual.0) - Int(sharp.0)) > 5 { blurryTop += 1 }
                checked += 1
                x += 11
            }
        }
        try expect(blurryTop == 0,
                   "Expected sharp top from single frame; \(blurryTop)/\(checked) off")
    }

    /// Captures often start before scrolling: a tiny pre-scroll jitter (mouse
    /// move, caret) can look like a small upward shift, then the page scrolls
    /// down for real. The stitcher must not commit to the wrong direction and
    /// stitch a segment that is later reversed — that corrupts the very top.
    private static func testPanoramaDeferredDirectionCommit() throws {
        let width = 160
        let frameHeight = 240
        let scrollPerFrame = 40
        let realFrames = 6
        let documentHeight = frameHeight + scrollPerFrame * (realFrames - 1)

        func documentPixel(x: Int, y: Int) -> (UInt8, UInt8, UInt8) {
            var hash = UInt32(x) &* 747_796_405 &+ UInt32(y) &* 2_891_336_453 &+ 97
            hash = ((hash >> ((hash >> 28) + 4)) ^ hash) &* 277_803_737
            hash = (hash >> 22) ^ hash
            let line = y % 19 < 4 || (x + y * 5) % 53 < 7
            return (UInt8(30 + Int((hash >> 16) & 0x7F) / 2 + (line ? 80 : 0)),
                    UInt8(40 + Int((hash >> 8) & 0x7F) / 2 + (line ? 60 : 0)),
                    UInt8(50 + Int(hash & 0x7F) / 2 + (line ? 50 : 0)))
        }

        func makeFrame(topRow: Int) -> PanoramaStitcher.Frame {
            var pixels = [UInt8](repeating: 0, count: width * frameHeight * 4)
            for y in 0..<frameHeight {
                for x in 0..<width {
                    let p = documentPixel(x: x, y: topRow + y)
                    let i = (y * width + x) * 4
                    pixels[i] = p.0; pixels[i + 1] = p.1; pixels[i + 2] = p.2; pixels[i + 3] = 255
                }
            }
            return PanoramaStitcher.Frame(width: width, height: frameHeight, pixels: pixels)
        }

        // A reverse jitter first, then a steady downward scroll.
        var frames = [makeFrame(topRow: 16)]
        for f in 0..<realFrames { frames.append(makeFrame(topRow: f * scrollPerFrame)) }
        guard let stitched = PanoramaStitcher.stitch(frames: frames) else {
            throw SelfTestError.failure("Deferred-direction stitching returned no image")
        }
        try expect(abs(stitched.height - documentHeight) <= 8,
                   "Expected deferred-direction height ~\(documentHeight), got \(stitched.height)")

        func stitchedPixel(x: Int, y: Int) -> (UInt8, UInt8, UInt8) {
            let i = (y * stitched.width + x) * 4
            return (stitched.pixels[i], stitched.pixels[i + 1], stitched.pixels[i + 2])
        }
        var mismatches = 0, checked = 0
        for y in stride(from: 4, to: documentHeight - 4, by: 16) {
            var x = 8
            while x < width - 8 {
                let e = documentPixel(x: x, y: y)
                let a = stitchedPixel(x: x, y: y)
                if abs(Int(e.0) - Int(a.0)) > 6 { mismatches += 1 }
                checked += 1
                x += 17
            }
        }
        try expect(mismatches * 20 < checked, "Expected aligned document after jitter; \(mismatches)/\(checked) off")
    }

    /// Repeated content (e.g. code with similar indentation) tempts the matcher
    /// into tiny harmonic shifts, tiling the same band over and over. The accept
    /// loop must reject sub-progress and spike steps so output height ≈ document.
    private static func testPanoramaNoHarmonicRepeats() throws {
        let width = 200
        let frameHeight = 240
        let step = 40
        let frameCount = 8
        let documentHeight = frameHeight + step * (frameCount - 1)

        func pixel(x: Int, y: Int) -> (UInt8, UInt8, UInt8) {
            // Strong horizontal periodicity (lines every 16px) to bait harmonics.
            let line = y % 16 < 6
            var hash = UInt32(x) &* 2_654_435_761 &+ UInt32(y / 16) &* 40_503
            hash ^= hash >> 13
            return (line ? 30 : 200, line ? 40 : 205, UInt8(Int(hash & 0x3F) + 180))
        }
        func makeFrame(topRow: Int) -> PanoramaStitcher.Frame {
            var px = [UInt8](repeating: 0, count: width * frameHeight * 4)
            for y in 0..<frameHeight { for x in 0..<width {
                let p = pixel(x: x, y: topRow + y); let i = (y * width + x) * 4
                px[i] = p.0; px[i+1] = p.1; px[i+2] = p.2; px[i+3] = 255
            } }
            return PanoramaStitcher.Frame(width: width, height: frameHeight, pixels: px)
        }
        let frames = (0..<frameCount).map { makeFrame(topRow: $0 * step) }
        guard let s = PanoramaStitcher.stitch(frames: frames) else {
            throw SelfTestError.failure("Harmonic-repeat stitch returned nil")
        }
        try expect(s.height <= documentHeight + 16,
                   "Expected no tiling; height \(s.height) vs doc \(documentHeight)")
    }

    /// Sticky app/browser headers remain fixed at local y=0 while the document
    /// underneath scrolls. The stitcher should keep that header from the first
    /// frame only; otherwise it gets stamped repeatedly down the panorama.
    private static func testPanoramaFixedHeaderSuppression() throws {
        let width = 320
        let frameHeight = 240
        let headerHeight = 42
        let scrollPerFrame = 40
        let frameCount = 8
        let documentHeight = frameHeight - headerHeight + scrollPerFrame * (frameCount - 1)
        let expectedHeight = headerHeight + documentHeight

        func headerPixel(x: Int, y: Int) -> (UInt8, UInt8, UInt8) {
            if y == headerHeight - 1 { return (20, 20, 20) }
            if x % 53 < 18 || y % 17 < 4 { return (230, 32, 190) }
            return (32, 34, 40)
        }

        func documentPixel(x: Int, y: Int) -> (UInt8, UInt8, UInt8) {
            var hash = UInt32(x / 4) &* 1_103_515_245 &+ UInt32(y) &* 2_654_435_761 &+ 12_345
            hash ^= hash >> 16
            hash &*= 2_246_822_519
            hash ^= hash >> 13
            let textLine = y % 19 < 3 || (x + y * 7) % 47 < 6
            let r = UInt8((hash >> 16) & 0x7F) &+ (textLine ? 80 : 25)
            let g = UInt8((hash >> 8) & 0x7F) &+ (textLine ? 70 : 35)
            let b = UInt8(hash & 0x7F) &+ (textLine ? 60 : 45)
            return (r, g, b)
        }

        func makeFrame(topRow: Int) -> PanoramaStitcher.Frame {
            var pixels = [UInt8](repeating: 0, count: width * frameHeight * 4)
            for y in 0..<frameHeight {
                for x in 0..<width {
                    let pixel = y < headerHeight
                        ? headerPixel(x: x, y: y)
                        : documentPixel(x: x, y: topRow + y - headerHeight)
                    let i = (y * width + x) * 4
                    pixels[i] = pixel.0
                    pixels[i + 1] = pixel.1
                    pixels[i + 2] = pixel.2
                    pixels[i + 3] = 255
                }
            }
            return PanoramaStitcher.Frame(width: width, height: frameHeight, pixels: pixels)
        }

        let frames = (0..<frameCount).map { makeFrame(topRow: $0 * scrollPerFrame) }
        guard let stitched = PanoramaStitcher.stitch(frames: frames) else {
            throw SelfTestError.failure("Panorama fixed-header stitching returned no image")
        }

        try expect(stitched.width == width, "Expected fixed-header stitched width \(width), got \(stitched.width)")
        try expect(abs(stitched.height - expectedHeight) <= 4,
                   "Expected fixed-header stitched height ~\(expectedHeight), got \(stitched.height)")

        func stitchedPixel(x: Int, y: Int) -> (UInt8, UInt8, UInt8) {
            let i = (y * stitched.width + x) * 4
            return (stitched.pixels[i], stitched.pixels[i + 1], stitched.pixels[i + 2])
        }

        var repeatedHeaderPixels = 0
        var sampledPixels = 0
        for y in headerHeight..<stitched.height {
            var x = 0
            while x < width {
                let pixel = stitchedPixel(x: x, y: y)
                if pixel.0 > 210 && pixel.1 < 60 && pixel.2 > 160 {
                    repeatedHeaderPixels += 1
                }
                sampledPixels += 1
                x += 8
            }
        }
        try expect(repeatedHeaderPixels * 100 < max(1, sampledPixels),
                   "Expected fixed header not to repeat below the top; saw \(repeatedHeaderPixels) repeated header samples")

        var mismatches = 0
        let samples = [(24, headerHeight + 5), (120, headerHeight + 90), (260, headerHeight + 180), (80, expectedHeight - 24)]
        for (x, y) in samples where y < stitched.height && x < stitched.width {
            let expected = documentPixel(x: x, y: y - headerHeight)
            let actual = stitchedPixel(x: x, y: y)
            let close = abs(Int(expected.0) - Int(actual.0)) <= 8 &&
                        abs(Int(expected.1) - Int(actual.1)) <= 8 &&
                        abs(Int(expected.2) - Int(actual.2)) <= 8
            if !close { mismatches += 1 }
        }
        try expect(mismatches <= 1, "Expected fixed-header stitched content to align, \(mismatches) sample mismatches")
    }

    /// A sticky bottom toolbar can dominate the overlap if it is left in the
    /// matcher: tiny shifts preserve the toolbar while the true scroll step
    /// moves it out of the overlap. The stitcher must ignore that fixed footer
    /// and recover the actual document motion.
    private static func testPanoramaFooterDoesNotAttractSmallShift() throws {
        let width = 320
        let frameHeight = 240
        let footerHeight = 56
        let scrollPerFrame = 64

        func documentPixel(x: Int, y: Int) -> (UInt8, UInt8, UInt8) {
            let band = y / 17
            var hash = UInt32(band) &* 1_664_525 &+ 1_013_904_223
            hash ^= UInt32(y) &* 2_246_822_519
            let left = 18 + Int(hash % 72)
            let textWidth = 70 + Int((hash >> 9) % 180)
            let rowPhase = Int((hash >> 17) % 11)
            let onText = ((y + rowPhase) % 17) < 4 && (hash & 0x7) != 0
            let inRun = x >= left && x < min(width - 18, left + textWidth) && ((x * 7 + y * 5 + Int(hash & 0x1F)) % 23) < 14
            if onText && inRun {
                let shade = UInt8(32 + Int((hash >> 24) & 0x1F) + ((x * 7 + y * 11) & 0x1F))
                return (shade, shade, shade)
            }
            return (247, 247, 247)
        }

        func footerPixel(x: Int, y: Int) -> (UInt8, UInt8, UInt8) {
            if y == 0 { return (40, 40, 40) }
            if (x / 9 + y / 5).isMultiple(of: 2) { return (18, 92, 180) }
            if x % 47 < 15 { return (238, 238, 238) }
            return (34, 36, 42)
        }

        func makeFrame(topRow: Int) -> PanoramaStitcher.Frame {
            var pixels = [UInt8](repeating: 0, count: width * frameHeight * 4)
            for y in 0..<frameHeight {
                for x in 0..<width {
                    let pixel = y >= frameHeight - footerHeight
                        ? footerPixel(x: x, y: y - (frameHeight - footerHeight))
                        : documentPixel(x: x, y: topRow + y)
                    let i = (y * width + x) * 4
                    pixels[i] = pixel.0
                    pixels[i + 1] = pixel.1
                    pixels[i + 2] = pixel.2
                    pixels[i + 3] = 255
                }
            }
            return PanoramaStitcher.Frame(width: width, height: frameHeight, pixels: pixels)
        }

        let first = makeFrame(topRow: 0)
        let second = makeFrame(topRow: scrollPerFrame)
        let firstLuma = PanoramaStitcher.luma(first)
        let secondLuma = PanoramaStitcher.luma(second)
        let detectedTopRows = PanoramaStitcher.stationaryTopRows(firstLuma, secondLuma, width, frameHeight)
        let detectedBottomRows = PanoramaStitcher.stationaryBottomRows(firstLuma, secondLuma, width, frameHeight)
        try expect(detectedTopRows == 0,
                   "Sparse document whitespace should not be treated as a fixed header; detected \(detectedTopRows) rows")
        try expect(detectedBottomRows >= footerHeight,
                   "Expected sticky footer rows to be detected before matching")
        guard let shift = PanoramaStitcher.findShift(prevLuma: firstLuma,
                                                     curLuma: secondLuma,
                                                     w: width, h: frameHeight,
                                                     expected: nil, axis: nil) else {
            throw SelfTestError.failure("Footer-distracted panorama shift returned no result")
        }
        try expect(shift.axis == .vertical, "Expected footer-distracted shift to stay vertical, got \(shift.axis)")
        try expect(abs(shift.dy - scrollPerFrame) <= 2,
                   "Expected fixed footer to be ignored by matcher; got dy=\(shift.dy), expected \(scrollPerFrame)")
    }

    /// Sticky bottom controls should be locked to the final viewport only. If
    /// earlier frame footers are composited, their toolbar pixels appear as
    /// repeated bands through the document body.
    private static func testPanoramaFixedFooterSuppression() throws {
        let width = 320
        let frameHeight = 240
        let footerHeight = 48
        let scrollPerFrame = 44
        let frameCount = 8
        let documentHeight = frameHeight - footerHeight + scrollPerFrame * (frameCount - 1)
        let expectedHeight = documentHeight + footerHeight

        func documentPixel(x: Int, y: Int) -> (UInt8, UInt8, UInt8) {
            var hash = UInt32(x / 3) &* 747_796_405 &+ UInt32(y) &* 2_891_336_453 &+ 97
            hash = ((hash >> ((hash >> 28) + 4)) ^ hash) &* 277_803_737
            hash = (hash >> 22) ^ hash
            let line = y % 23 < 4 || (x + y * 5) % 61 < 7
            return (
                UInt8((hash >> 16) & 0x7F) &+ (line ? 90 : 30),
                UInt8((hash >> 8) & 0x7F) &+ (line ? 70 : 35),
                UInt8(hash & 0x7F) &+ (line ? 55 : 40)
            )
        }

        func footerPixel(x: Int, y: Int) -> (UInt8, UInt8, UInt8) {
            if y == 0 { return (12, 12, 12) }
            if x % 59 < 20 || y % 13 < 4 { return (18, 108, 235) }
            return (24, 26, 34)
        }

        func makeFrame(topRow: Int) -> PanoramaStitcher.Frame {
            var pixels = [UInt8](repeating: 0, count: width * frameHeight * 4)
            for y in 0..<frameHeight {
                for x in 0..<width {
                    let pixel = y >= frameHeight - footerHeight
                        ? footerPixel(x: x, y: y - (frameHeight - footerHeight))
                        : documentPixel(x: x, y: topRow + y)
                    let i = (y * width + x) * 4
                    pixels[i] = pixel.0
                    pixels[i + 1] = pixel.1
                    pixels[i + 2] = pixel.2
                    pixels[i + 3] = 255
                }
            }
            return PanoramaStitcher.Frame(width: width, height: frameHeight, pixels: pixels)
        }

        let frames = (0..<frameCount).map { makeFrame(topRow: $0 * scrollPerFrame) }
        guard let stitched = PanoramaStitcher.stitch(frames: frames) else {
            throw SelfTestError.failure("Panorama fixed-footer stitching returned no image")
        }

        try expect(stitched.width == width, "Expected fixed-footer stitched width \(width), got \(stitched.width)")
        try expect(abs(stitched.height - expectedHeight) <= 4,
                   "Expected fixed-footer stitched height ~\(expectedHeight), got \(stitched.height)")

        func stitchedPixel(x: Int, y: Int) -> (UInt8, UInt8, UInt8) {
            let i = (y * stitched.width + x) * 4
            return (stitched.pixels[i], stitched.pixels[i + 1], stitched.pixels[i + 2])
        }

        var repeatedFooterPixels = 0
        var sampledPixels = 0
        for y in 0..<max(0, stitched.height - footerHeight) {
            var x = 0
            while x < width {
                let pixel = stitchedPixel(x: x, y: y)
                if pixel.0 < 45 && pixel.1 > 80 && pixel.2 > 180 {
                    repeatedFooterPixels += 1
                }
                sampledPixels += 1
                x += 8
            }
        }
        try expect(repeatedFooterPixels * 100 < max(1, sampledPixels),
                   "Expected fixed footer not to repeat above the bottom; saw \(repeatedFooterPixels) repeated footer samples")

        var footerMatches = 0
        var footerSamples = 0
        let footerTop = stitched.height - footerHeight
        for y in footerTop..<stitched.height {
            var x = 0
            while x < width {
                let expected = footerPixel(x: x, y: y - footerTop)
                let actual = stitchedPixel(x: x, y: y)
                if abs(Int(expected.0) - Int(actual.0)) <= 4 &&
                   abs(Int(expected.1) - Int(actual.1)) <= 4 &&
                   abs(Int(expected.2) - Int(actual.2)) <= 4 {
                    footerMatches += 1
                }
                footerSamples += 1
                x += 8
            }
        }
        try expect(footerMatches * 100 >= footerSamples * 95,
                   "Expected final footer to be locked at bottom; matched \(footerMatches)/\(footerSamples) samples")
    }

    /// Capture can produce several frames from the same scroll position with a
    /// tiny dynamic change (caret blink, hover repaint, loading spinner). Those
    /// frames must not be forced into non-zero shifts and stamped repeatedly.
    private static func testPanoramaSkipsRepeatedCaptures() throws {
        let width = 320
        let frameHeight = 240
        let scrollPerFrame = 40
        let scrollPositions = [0, 40, 80, 120, 160, 200, 240]
        let documentHeight = frameHeight + scrollPerFrame * (scrollPositions.count - 1)

        func documentPixel(x: Int, y: Int) -> (UInt8, UInt8, UInt8) {
            var hash = UInt32(x) &* 747_796_405 &+ UInt32(y) &* 2_891_336_453 &+ 97
            hash = ((hash >> ((hash >> 28) + 4)) ^ hash) &* 277_803_737
            hash = (hash >> 22) ^ hash
            let line = y % 23 < 4 || (x + y * 5) % 61 < 7
            return (
                UInt8((hash >> 16) & 0x7F) &+ (line ? 90 : 30),
                UInt8((hash >> 8) & 0x7F) &+ (line ? 70 : 35),
                UInt8(hash & 0x7F) &+ (line ? 55 : 40)
            )
        }

        func makeFrame(topRow: Int, variant: Int) -> PanoramaStitcher.Frame {
            var pixels = [UInt8](repeating: 0, count: width * frameHeight * 4)
            for y in 0..<frameHeight {
                let docY = topRow + y
                for x in 0..<width {
                    var pixel = documentPixel(x: x, y: docY)
                    if variant > 0 && x >= 260 && x < 292 && y >= 32 && y < 56 {
                        pixel = variant.isMultiple(of: 2) ? (250, 20, 20) : (20, 180, 250)
                    }
                    let i = (y * width + x) * 4
                    pixels[i] = pixel.0
                    pixels[i + 1] = pixel.1
                    pixels[i + 2] = pixel.2
                    pixels[i + 3] = 255
                }
            }
            return PanoramaStitcher.Frame(width: width, height: frameHeight, pixels: pixels)
        }

        var frames: [PanoramaStitcher.Frame] = []
        for (index, topRow) in scrollPositions.enumerated() {
            frames.append(makeFrame(topRow: topRow, variant: 0))
            if index < scrollPositions.count - 1 {
                frames.append(makeFrame(topRow: topRow, variant: index + 1))
                frames.append(makeFrame(topRow: topRow, variant: index + 2))
            }
        }

        guard let stitched = PanoramaStitcher.stitch(frames: frames) else {
            throw SelfTestError.failure("Panorama repeated-capture stitching returned no image")
        }

        try expect(stitched.width == width, "Expected repeated-capture stitched width \(width), got \(stitched.width)")
        try expect(abs(stitched.height - documentHeight) <= 4,
                   "Expected repeated-capture stitched height ~\(documentHeight), got \(stitched.height)")
    }

    /// Real chat/document captures can be mostly white space with sparse text.
    /// Raw pixel-change fractions stay low even while the document scrolls a
    /// long way, so duplicate filtering must not collapse the panorama to the
    /// first viewport.
    private static func testPanoramaSparseTallContentStitches() throws {
        let width = 360
        let frameHeight = 260
        let scrollPerFrame = 80
        let frameCount = 7
        let documentHeight = frameHeight + scrollPerFrame * (frameCount - 1)

        func documentPixel(x: Int, y: Int) -> (UInt8, UInt8, UInt8) {
            let paragraph = y / 53
            let lineInParagraph = y % 53
            let left = 28 + (paragraph % 3) * 12
            let textWidth = 120 + (paragraph * 37 % 110)
            let onTextLine = (6...8).contains(lineInParagraph) ||
                             (18...20).contains(lineInParagraph) ||
                             (30...31).contains(lineInParagraph)
            let inTextRun = x >= left && x < min(width - 24, left + textWidth) && ((x + y * 3) % 17) < 10
            if onTextLine && inTextRun {
                let shade = UInt8(38 + ((x * 5 + y * 7) & 0x1F))
                return (shade, shade, shade)
            }
            if lineInParagraph == 0 && x >= left && x < left + 46 {
                return (88, 88, 88)
            }
            return (248, 248, 248)
        }

        func makeFrame(topRow: Int) -> PanoramaStitcher.Frame {
            var pixels = [UInt8](repeating: 0, count: width * frameHeight * 4)
            for y in 0..<frameHeight {
                let docY = topRow + y
                for x in 0..<width {
                    let pixel = documentPixel(x: x, y: docY)
                    let i = (y * width + x) * 4
                    pixels[i] = pixel.0
                    pixels[i + 1] = pixel.1
                    pixels[i + 2] = pixel.2
                    pixels[i + 3] = 255
                }
            }
            return PanoramaStitcher.Frame(width: width, height: frameHeight, pixels: pixels)
        }

        let frames = (0..<frameCount).map { makeFrame(topRow: $0 * scrollPerFrame) }
        try expect(!PanoramaStitcher.isNearDuplicate(frames[0], frames[1]),
                   "Sparse real-scroll frames should not be filtered as duplicates during capture")

        var captureFilteredFrames: [PanoramaStitcher.Frame] = []
        for frame in frames {
            if captureFilteredFrames.isEmpty || !PanoramaStitcher.isNearDuplicate(captureFilteredFrames[captureFilteredFrames.count - 1], frame) {
                captureFilteredFrames.append(frame)
            }
        }
        try expect(captureFilteredFrames.count == frameCount,
                   "Expected capture duplicate filter to keep all sparse scroll frames, kept \(captureFilteredFrames.count)/\(frameCount)")

        guard let stitched = PanoramaStitcher.stitch(frames: frames) else {
            throw SelfTestError.failure("Sparse panorama stitching returned no image")
        }

        try expect(stitched.width == width, "Expected sparse stitched width \(width), got \(stitched.width)")
        try expect(abs(stitched.height - documentHeight) <= 8,
                   "Expected sparse stitched height ~\(documentHeight), got \(stitched.height)")
    }

    /// Tall captures of text-heavy content can produce deceptively good
    /// horizontal matches from repeated glyph/column structure. Startup axis
    /// detection should keep those ambiguous portrait captures vertical so the
    /// panorama grows down instead of smearing sideways.
    private static func testPanoramaStartupAxisRejectsHorizontalAlias() throws {
        let width = 140
        let frameHeight = 320
        let scrollPerFrame = 34
        let frameCount = 6
        let documentHeight = frameHeight + scrollPerFrame * (frameCount - 1)

        func documentShade(x: Int, y: Int) -> UInt8 {
            let paragraph = y / 47
            let line = y % 47
            let left = 18 + (paragraph % 4) * 7
            let textWidth = 74 + (paragraph * 19 % 38)
            let onTextLine = (7...9).contains(line) ||
                             (18...20).contains(line) ||
                             (30...31).contains(line)
            let glyph = x >= left && x < min(width - 12, left + textWidth) && ((x + paragraph * 5 + y) % 13) < 8
            if onTextLine && glyph { return UInt8(36 + ((x * 3 + y * 5) & 0x1F)) }
            if line == 0 && x >= left && x < left + 28 { return 94 }
            return 248
        }

        func makeFrame(topRow: Int, phase: Int) -> PanoramaStitcher.Frame {
            var pixels = [UInt8](repeating: 0, count: width * frameHeight * 4)
            for y in 0..<frameHeight {
                for x in 0..<width {
                    var shade = Int(documentShade(x: x, y: topRow + y))
                    let localStripe = (x + (y / 5) * 3) % 24
                    if localStripe < 9 { shade = (shade * 3 + 220) / 4 }
                    if (x + 6) % 32 < 3 { shade = min(shade, 208) }
                    if (x * 13 + y * 7 + phase) % 101 == 0 { shade = max(0, shade - 8) }
                    let i = (y * width + x) * 4
                    pixels[i] = UInt8(shade)
                    pixels[i + 1] = UInt8(shade)
                    pixels[i + 2] = UInt8(shade)
                    pixels[i + 3] = 255
                }
            }
            return PanoramaStitcher.Frame(width: width, height: frameHeight, pixels: pixels)
        }

        let first = makeFrame(topRow: 0, phase: 0)
        let second = makeFrame(topRow: scrollPerFrame, phase: 17)
        let axisDecision = PanoramaStitcher.axisScan(prev: PanoramaStitcher.luma(first),
                                                     cur: PanoramaStitcher.luma(second),
                                                     w: width, h: frameHeight,
                                                     ignoreTopRows: 0)
        try expect(axisDecision?.axis == .vertical,
                   "Expected portrait startup axis scan to choose vertical, got \(String(describing: axisDecision?.axis))")

        let frames = (0..<frameCount).map { makeFrame(topRow: $0 * scrollPerFrame, phase: $0 * 17) }
        guard let stitched = PanoramaStitcher.stitch(frames: frames) else {
            throw SelfTestError.failure("Horizontal-alias panorama stitching returned no image")
        }

        try expect(stitched.width == width, "Expected horizontal-alias stitched width \(width), got \(stitched.width)")
        try expect(abs(stitched.height - documentHeight) <= 8,
                   "Expected horizontal-alias stitched height ~\(documentHeight), got \(stitched.height)")
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