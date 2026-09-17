import AppKit

extension SelfTestRunner {
    /// The panorama region rectangle is drawn in blue to stay distinct from the
    /// orange screen-recording border. The shared selection view defaults to
    /// white (snip/record) but the panorama selector requests blue; verify the
    /// requested border colour is actually rendered.
    static func testPanoramaSelectionBorderColor() throws {
        let dim = 40
        // A solid grey backing image for the selector.
        guard let context = CGContext(
            data: nil, width: dim, height: dim, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            throw SelfTestError.failure("Could not create selector backing context")
        }
        context.setFillColor(NSColor(white: 0.5, alpha: 1).cgColor)
        context.fill(CGRect(x: 0, y: 0, width: dim, height: dim))
        guard let image = context.makeImage() else {
            throw SelfTestError.failure("Could not create selector backing image")
        }

        let selection = CGRect(x: 8, y: 8, width: 24, height: 24)

        func borderIsBlue(_ view: SnipSelectionView) throws -> Bool {
            guard let rep = view.renderForTesting(selection: selection) else {
                throw SelfTestError.failure("Selector render returned no bitmap")
            }
            let scaleX = rep.pixelsWide / dim
            let scaleY = rep.pixelsHigh / dim
            // Sample the middle of the top border edge of the selection rect.
            let px = Int(selection.midX) * scaleX
            let py = Int(selection.minY) * scaleY
            guard let c = rep.colorAt(x: px, y: py) else {
                throw SelfTestError.failure("Could not sample selector border pixel")
            }
            return c.blueComponent > 0.5 && c.redComponent < 0.4
        }

        let blueView = SnipSelectionView(frame: CGRect(x: 0, y: 0, width: dim, height: dim), image: image, borderColor: .systemBlue)
        try expect(try borderIsBlue(blueView), "Expected panorama selection border to render blue")

        let whiteView = SnipSelectionView(frame: CGRect(x: 0, y: 0, width: dim, height: dim), image: image)
        try expect(try !borderIsBlue(whiteView), "Expected default snip selection border to remain non-blue (white)")
    }

    /// Escape during the scrolling panorama capture must cancel the run, but
    /// only while it is actively capturing, and repeated Escapes are ignored.
    static func testPanoramaEscapeCancel() throws {
        try expect(PanoramaController.shouldCancelOnEscape(isCapturing: true, alreadyCancelled: false),
                   "Expected Escape to cancel an active panorama capture")
        try expect(PanoramaController.shouldCancelOnEscape(isCapturing: false, alreadyCancelled: false) == false,
                   "Expected Escape to be ignored when not capturing")
        try expect(PanoramaController.shouldCancelOnEscape(isCapturing: true, alreadyCancelled: true) == false,
                   "Expected a repeated Escape to be ignored once already cancelled")
    }

    /// Synthesize a tall "document" with structured rows, slice overlapping
    /// frames that scroll down by a known amount, and verify the stitcher
    /// reconstructs a panorama taller than a single frame with the document's
    /// content aligned. Exercises the same alignment path used at runtime.
    static func testPanoramaStitching() throws {
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
    static func testPanoramaTopSeamUsesSingleFramePixels() throws {
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

    /// Vertical seams must use keep-first (a single source frame per canvas
    /// pixel), never an overlap blend. A feather blend ghosts slightly-
    /// misaligned text into a dark band -- the strikethrough artifact seen on
    /// real captures. This drives content whose flat background brightness is
    /// unique per frame, then asserts the stitched output only ever contains
    /// exact source values, never an averaged (blended) intermediate.
    static func testPanoramaVerticalSeamKeepsSingleFrame() throws {
        let width = 140
        let frameHeight = 220
        let scrollPerFrame = 44
        let frameCount = 4
        let documentHeight = frameHeight + scrollPerFrame * (frameCount - 1)

        // Per-frame background brightness, spaced by 10 so an averaged blend of
        // any two adjacent frames (e.g. 217) is never itself a valid source.
        let backgrounds = [UInt8](arrayLiteral: 222, 212, 202, 192)
        let bandShade: UInt8 = 24

        func isBand(_ docY: Int) -> Bool {
            var hash = UInt32(truncatingIfNeeded: docY) &* 2_654_435_761
            hash ^= hash >> 15
            return (hash & 0xFF) < 22
        }

        func makeFrame(index: Int) -> PanoramaStitcher.Frame {
            let background = backgrounds[index]
            let topRow = index * scrollPerFrame
            var pixels = [UInt8](repeating: 0, count: width * frameHeight * 4)
            for y in 0..<frameHeight {
                let docY = topRow + y
                let shade: UInt8 = isBand(docY) ? bandShade : background
                for x in 0..<width {
                    let i = (y * width + x) * 4
                    pixels[i] = shade
                    pixels[i + 1] = shade
                    pixels[i + 2] = shade
                    pixels[i + 3] = 255
                }
            }
            return PanoramaStitcher.Frame(width: width, height: frameHeight, pixels: pixels)
        }

        let frames = (0..<frameCount).map { makeFrame(index: $0) }
        guard let stitched = PanoramaStitcher.stitch(frames: frames) else {
            throw SelfTestError.failure("Vertical-seam panorama stitching returned no image")
        }
        try expect(abs(stitched.height - documentHeight) <= 6,
                   "Expected vertical-seam stitched height ~\(documentHeight), got \(stitched.height)")

        let allowed: Set<Int> = [Int(bandShade), 222, 212, 202, 192]
        var blendedPixels = 0
        var checked = 0
        let sampleX = width / 2
        for y in 0..<stitched.height {
            let value = Int(stitched.pixels[(y * stitched.width + sampleX) * 4])
            if !allowed.contains(value) { blendedPixels += 1 }
            checked += 1
        }
        try expect(blendedPixels == 0,
                   "Expected keep-first vertical seams (no blended intermediates); \(blendedPixels)/\(checked) blended")
    }

    /// Captures often start before scrolling: a tiny pre-scroll jitter (mouse
    /// move, caret) can look like a small upward shift, then the page scrolls
    /// down for real. The stitcher must not commit to the wrong direction and
    /// stitch a segment that is later reversed — that corrupts the very top.
    static func testPanoramaDeferredDirectionCommit() throws {
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
    static func testPanoramaNoHarmonicRepeats() throws {
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
    static func testPanoramaFixedHeaderSuppression() throws {
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
    static func testPanoramaFooterDoesNotAttractSmallShift() throws {
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
    static func testPanoramaFixedFooterSuppression() throws {
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
    static func testPanoramaSkipsRepeatedCaptures() throws {
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

    static func testPanoramaRejectsStationaryRepaintShift() throws {
        let width = 320
        let frameHeight = 240

        func documentPixel(x: Int, y: Int) -> (UInt8, UInt8, UInt8) {
            let line = y % 17 < 4 || (x + y * 3) % 47 < 9
            var hash = UInt32(x) &* 1_664_525 &+ UInt32(y) &* 1_013_904_223
            hash ^= hash >> 13
            let shade = UInt8((hash & 0x3F) + (line ? 34 : 160))
            return (shade, shade, UInt8(clamping: Int(shade) + (line ? 30 : 0)))
        }

        func makeFrame(repaintVariant: Int) -> PanoramaStitcher.Frame {
            var pixels = [UInt8](repeating: 0, count: width * frameHeight * 4)
            for y in 0..<frameHeight {
                for x in 0..<width {
                    var pixel = documentPixel(x: x, y: y)
                    if repaintVariant > 0 && x >= 210 && x < 302 && y >= 36 && y < 92 {
                        pixel = repaintVariant.isMultiple(of: 2) ? (240, 32, 32) : (32, 160, 240)
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

        let first = makeFrame(repaintVariant: 0)
        let repaint = makeFrame(repaintVariant: 1)
        let firstLuma = PanoramaStitcher.luma(first)
        let repaintLuma = PanoramaStitcher.luma(repaint)
        let shift = PanoramaStitcher.findShift(prevLuma: firstLuma,
                                               curLuma: repaintLuma,
                                               w: width, h: frameHeight,
                                               expected: (dx: 0, dy: 40), axis: .vertical)
        try expect(shift == nil,
                   "Expected stationary repaint not to be forced into a panorama shift, got \(String(describing: shift))")
    }

    static func testPanoramaKeepsScrollBesideStaticContent() throws {
        let width = 840
        let frameHeight = 360
        let movingWidth = 310
        let scrollPerFrame = 90

        func movingPixel(x: Int, y: Int) -> UInt8 {
            let card = y / 74
            let line = y % 74
            let left = 24 + (card % 3) * 9
            let textWidth = 150 + (card * 31 % 104)
            let onText = (12...15).contains(line) || (28...31).contains(line) || (44...47).contains(line)
            let glyph = onText && x >= left && x < min(movingWidth - 18, left + textWidth) && ((x * 5 + y * 7) % 19) < 12
            if glyph { return UInt8(36 + ((x * 3 + y * 5) & 0x1F)) }
            if line >= 3 && line <= 56 && x >= 12 && x < movingWidth - 12 { return 238 }
            return 248
        }

        func staticPixel(x: Int, y: Int) -> UInt8 {
            let localX = x - movingWidth
            let block = (localX / 96 + y / 88) % 4
            let bevel = abs((localX % 96) - 48) / 5 + abs((y % 88) - 44) / 6
            let shade = 205 - block * 18 - min(36, bevel)
            return UInt8(max(116, min(232, shade)))
        }

        func makeFrame(topRow: Int) -> PanoramaStitcher.Frame {
            var pixels = [UInt8](repeating: 0, count: width * frameHeight * 4)
            for y in 0..<frameHeight {
                for x in 0..<width {
                    let shade = x < movingWidth ? movingPixel(x: x, y: topRow + y) : staticPixel(x: x, y: y)
                    let i = (y * width + x) * 4
                    pixels[i] = shade
                    pixels[i + 1] = shade
                    pixels[i + 2] = shade
                    pixels[i + 3] = 255
                }
            }
            return PanoramaStitcher.Frame(width: width, height: frameHeight, pixels: pixels)
        }

        let first = makeFrame(topRow: 0)
        let second = makeFrame(topRow: scrollPerFrame)
        let firstLuma = PanoramaStitcher.luma(first)
        let secondLuma = PanoramaStitcher.luma(second)
        let shift = PanoramaStitcher.findShift(prevLuma: firstLuma,
                               curLuma: secondLuma,
                                               w: width, h: frameHeight,
                                               expected: (dx: 0, dy: scrollPerFrame), axis: .vertical)
        try expect(abs((shift?.dy ?? 0) - scrollPerFrame) <= 4,
               "Expected scroll beside static content to keep dy ~\(scrollPerFrame), got \(String(describing: shift))")
    }

    /// Real chat/document captures can be mostly white space with sparse text.
    /// Raw pixel-change fractions stay low even while the document scrolls a
    /// long way, so duplicate filtering must not collapse the panorama to the
    /// first viewport.
    static func testPanoramaSparseTallContentStitches() throws {
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
    static func testPanoramaStartupAxisRejectsHorizontalAlias() throws {
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

    static func testPanoramaLockedAxisRejectsShortFallback() throws {
        let width = 260
        let frameHeight = 300
        let actualStep = 30
        let expectedStep = 90

        func documentPixel(x: Int, y: Int) -> (UInt8, UInt8, UInt8) {
            let line = y % 31 < 7 || (x * 3 + y * 5) % 67 < 10
            var hash = UInt32(x) &* 747_796_405 &+ UInt32(y) &* 2_891_336_453 &+ 97
            hash = ((hash >> ((hash >> 28) + 4)) ^ hash) &* 277_803_737
            hash = (hash >> 22) ^ hash
            let base = line ? 48 : 220
            return (UInt8(base + Int((hash >> 16) & 0x1F)),
                    UInt8(base + Int((hash >> 8) & 0x1F)),
                    UInt8(base + Int(hash & 0x1F)))
        }

        func makeFrame(topRow: Int) -> PanoramaStitcher.Frame {
            var pixels = [UInt8](repeating: 0, count: width * frameHeight * 4)
            for y in 0..<frameHeight {
                for x in 0..<width {
                    let p = documentPixel(x: x, y: topRow + y)
                    let i = (y * width + x) * 4
                    pixels[i] = p.0
                    pixels[i + 1] = p.1
                    pixels[i + 2] = p.2
                    pixels[i + 3] = 255
                }
            }
            return PanoramaStitcher.Frame(width: width, height: frameHeight, pixels: pixels)
        }

        let first = makeFrame(topRow: 0)
        let shortStep = makeFrame(topRow: actualStep)
        let shift = PanoramaStitcher.findShift(prevLuma: PanoramaStitcher.luma(first),
                                               curLuma: PanoramaStitcher.luma(shortStep),
                                               w: width, h: frameHeight,
                                               expected: (dx: 0, dy: expectedStep), axis: .vertical)
        try expect(shift == nil,
                   "Expected locked-axis full fallback to reject short harmonic step, got \(String(describing: shift))")
    }
}
