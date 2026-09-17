import AppKit

enum SelfTestError: Error, CustomStringConvertible {
    case failure(String)

    var description: String {
        switch self {
        case .failure(let message): message
        }
    }
}

/// A flipped (top-left origin) host view that draws a background image through
/// `BreakTimerLayout.drawBackground`, mirroring the real break timer view. Used
/// to verify images are not rendered upside down in a flipped context.
final class FlippedBackgroundHostView: NSView {
    var image: NSImage?
    override var isFlipped: Bool { true }
    override func draw(_ dirtyRect: NSRect) {
        NSColor.black.setFill()
        bounds.fill()
        if let image {
            BreakTimerLayout.drawBackground(image, in: bounds, fraction: 1)
        }
    }
}

final class SelfTestFocusView: NSView {
    override var acceptsFirstResponder: Bool { true }
}

@MainActor
private final class SelfTestTimeoutState<Value: Sendable> {
    var continuation: CheckedContinuation<Value, Error>?
    var operationTask: Task<Void, Never>?
    var deadlineTask: Task<Void, Never>?

    func resolve(_ result: Result<Value, Error>) {
        guard let continuation else { return }
        self.continuation = nil
        operationTask?.cancel()
        deadlineTask?.cancel()
        operationTask = nil
        deadlineTask = nil
        continuation.resume(with: result)
    }
}

@MainActor
func withSelfTestTimeout<Value: Sendable>(
    _ description: String,
    after timeout: Duration = .seconds(2),
    operation: @escaping @MainActor () async throws -> Value
) async throws -> Value {
    let state = SelfTestTimeoutState<Value>()
    return try await withCheckedThrowingContinuation { continuation in
        state.continuation = continuation
        state.operationTask = Task { @MainActor in
            do {
                state.resolve(.success(try await operation()))
            } catch {
                state.resolve(.failure(error))
            }
        }
        state.deadlineTask = Task { @MainActor in
            do {
                try await ContinuousClock().sleep(for: timeout)
            } catch {
                return
            }
            state.resolve(
                .failure(
                    SelfTestError.failure(
                        "Timed out waiting for \(description)"
                    )
                )
            )
        }
    }
}

@MainActor
final class SelfTestAsyncGate {
    private struct EntryWaiter {
        let count: Int
        let continuation: CheckedContinuation<Void, Never>
    }

    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private var entryWaiters: [EntryWaiter] = []
    private(set) var entryCount = 0

    func wait() async throws {
        entryCount += 1
        resumeSatisfiedEntryWaiters()
        guard !isOpen else { return }
        try await withSelfTestTimeout("self-test gate to open") {
            await withCheckedContinuation { continuation in
                if self.isOpen {
                    continuation.resume()
                } else {
                    self.waiters.append(continuation)
                }
            }
        }
    }

    func waitUntilEntered(_ count: Int = 1) async throws {
        guard entryCount < count else { return }
        try await withSelfTestTimeout("self-test gate entry \(count)") {
            await withCheckedContinuation { continuation in
                if self.entryCount >= count {
                    continuation.resume()
                } else {
                    self.entryWaiters.append(
                        EntryWaiter(count: count, continuation: continuation)
                    )
                }
            }
        }
    }

    func open() {
        guard !isOpen else { return }
        isOpen = true
        let waiters = self.waiters
        self.waiters.removeAll()
        for waiter in waiters {
            waiter.resume()
        }
    }

    private func resumeSatisfiedEntryWaiters() {
        var remaining: [EntryWaiter] = []
        for waiter in entryWaiters {
            if entryCount >= waiter.count {
                waiter.continuation.resume()
            } else {
                remaining.append(waiter)
            }
        }
        entryWaiters = remaining
    }
}

@MainActor
final class SelfTestLiveZoomActivationSession {
    private var isStopped = false
    private(set) var stopCount = 0

    func stop() async {
        guard !isStopped else { return }
        isStopped = true
        stopCount += 1
    }
}

extension SelfTestRunner {
    static func makeCanvas(
        annotationController: AnnotationController
    ) throws -> ZoomCanvasView {
        let frame = try makeFrame()
        let viewportController = ZoomViewportController()
        viewportController.configure(for: frame, initialZoom: 2)
        return ZoomCanvasView(
            frame: CGRect(origin: .zero, size: frame.display.frame.size),
            capturedFrame: frame,
            viewportController: viewportController,
            annotationController: annotationController,
            smoothImage: true,
            userSelectedResourceAccess: UserDefaultsUserSelectedResourceAccess(),
            commandSink: { _ in }
        )
    }

    static func descendantViews<View: NSView>(
        of type: View.Type,
        in root: NSView
    ) -> [View] {
        var result: [View] = []
        if let view = root as? View {
            result.append(view)
        }
        for subview in root.subviews {
            result.append(contentsOf: descendantViews(of: type, in: subview))
        }
        return result
    }

    static func frame(
        _ view: NSView,
        convertedTo ancestor: NSView
    ) -> CGRect {
        guard let superview = view.superview else {
            return view.frame
        }
        let localFrame = view is NSTextField
            ? view.alignmentRect(forFrame: view.frame)
            : view.frame
        return superview.convert(localFrame, to: ancestor)
    }

    static func dispatchPhysicalClick(on button: NSButton) throws {
        try dispatchPhysicalClick(in: button)
    }

    static func dispatchPhysicalClick(in view: NSView) throws {
        let events = try physicalClickEvents(in: view)
        NSApp.postEvent(events.mouseUp, atStart: true)
        NSApp.sendEvent(events.mouseDown)
    }

    static func dispatchPhysicalMouseClick(in view: NSView) throws {
        let events = try physicalClickEvents(in: view)
        NSApp.postEvent(events.mouseUp, atStart: true)
        NSApp.postEvent(events.mouseDown, atStart: true)
        var dispatchedTypes: [NSEvent.EventType] = []
        while let event = NSApp.nextEvent(
            matching: [.leftMouseDown, .leftMouseUp],
            until: Date().addingTimeInterval(0.1),
            inMode: .default,
            dequeue: true
        ) {
            dispatchedTypes.append(event.type)
            NSApp.sendEvent(event)
            if event.type == .leftMouseUp {
                break
            }
        }
        guard dispatchedTypes == [.leftMouseDown, .leftMouseUp] else {
            throw SelfTestError.failure(
                "Expected one queued physical mouse-down/up pair, got \(dispatchedTypes)"
            )
        }
    }

    static func physicalClickEvents(
        in view: NSView
    ) throws -> (mouseDown: NSEvent, mouseUp: NSEvent) {
        view.layoutSubtreeIfNeeded()
        guard let window = view.window else {
            throw SelfTestError.failure(
                "Cannot dispatch a physical click to a detached view"
            )
        }
        let location = view.convert(
            CGPoint(x: view.bounds.midX, y: view.bounds.midY),
            to: nil
        )
        guard let mouseDown = NSEvent.mouseEvent(
            with: .leftMouseDown,
            location: location,
            modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window.windowNumber,
            context: nil,
            eventNumber: 1,
            clickCount: 1,
            pressure: 1
        ), let mouseUp = NSEvent.mouseEvent(
            with: .leftMouseUp,
            location: location,
            modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime + 0.001,
            windowNumber: window.windowNumber,
            context: nil,
            eventNumber: 2,
            clickCount: 1,
            pressure: 0
        ) else {
            throw SelfTestError.failure(
                "Could not synthesize a physical AppKit button click"
            )
        }
        return (mouseDown, mouseUp)
    }

    static func makeFrame(
        displayFrame: CGRect = CGRect(
            x: 0,
            y: 0,
            width: 1_000,
            height: 800
        ),
        scaleFactor: CGFloat = 2
    ) throws -> CapturedFrame {
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
            display: DisplayDescriptor(
                id: 1,
                frame: displayFrame,
                scaleFactor: scaleFactor
            ),
            pixelSize: CGSize(width: image.width, height: image.height),
            timestamp: Date(timeIntervalSince1970: 0)
        )
    }

    static func makeSolidImage(
        width: Int,
        height: Int,
        color: NSColor
    ) throws -> CGImage {
        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGBitmapInfo.byteOrder32Little.rawValue
                | CGImageAlphaInfo.premultipliedFirst.rawValue
        ) else {
            throw SelfTestError.failure("Could not create solid test image")
        }
        context.setFillColor(color.cgColor)
        context.fill(
            CGRect(x: 0, y: 0, width: width, height: height)
        )
        guard let image = context.makeImage() else {
            throw SelfTestError.failure("Could not finalize solid test image")
        }
        return image
    }

    struct RenderPixel: Equatable {
        var red: UInt8
        var green: UInt8
        var blue: UInt8
        var alpha: UInt8
    }

    struct ImageAlphaSignature: Hashable {
        var width: Int
        var height: Int
        var painted: [Bool]

        var paintedCentroidX: CGFloat {
            var totalX: CGFloat = 0
            var count: CGFloat = 0
            for y in 0..<height {
                for x in 0..<width where painted[y * width + x] {
                    totalX += CGFloat(x)
                    count += 1
                }
            }
            return count > 0 ? totalX / count : CGFloat(width - 1) / 2
        }

        func horizontallyMirrored() -> ImageAlphaSignature {
            var mirrored = painted
            for y in 0..<height {
                for x in 0..<width {
                    mirrored[y * width + x] = painted[y * width + (width - 1 - x)]
                }
            }
            return ImageAlphaSignature(width: width, height: height, painted: mirrored)
        }
    }

    static func previewAlphaSignature(
        _ preview: DrawingInspectorPreview
    ) throws -> ImageAlphaSignature {
        guard let data = preview.image.tiffRepresentation,
              let representation = NSBitmapImageRep(data: data) else {
            throw SelfTestError.failure("Could not rasterize an inspector preview image")
        }
        let width = representation.pixelsWide
        let height = representation.pixelsHigh
        let painted = (0..<height).flatMap { y in
            (0..<width).map { x in
                (representation.colorAt(x: x, y: y)?.alphaComponent ?? 0) > 0.05
            }
        }
        return ImageAlphaSignature(width: width, height: height, painted: painted)
    }

    static func renderBitmap(
        width: Int,
        height: Int,
        backingScale: Int = 1,
        antialias: Bool = false,
        draw: (CGContext) throws -> Void
    ) throws -> [UInt8] {
        let scale = max(1, backingScale)
        let pixelWidth = width * scale
        let pixelHeight = height * scale
        let bytesPerPixel = 4
        var pixels = [UInt8](
            repeating: 0,
            count: pixelWidth * pixelHeight * bytesPerPixel
        )
        try pixels.withUnsafeMutableBytes { bytes in
            guard let context = CGContext(
                data: bytes.baseAddress,
                width: pixelWidth,
                height: pixelHeight,
                bitsPerComponent: 8,
                bytesPerRow: pixelWidth * bytesPerPixel,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else {
                throw SelfTestError.failure("Could not create annotation render bitmap")
            }
            context.setAllowsAntialiasing(antialias)
            context.setShouldAntialias(antialias)
            context.scaleBy(x: CGFloat(scale), y: CGFloat(scale))
            try draw(context)
            context.flush()
        }
        return pixels
    }

    static func renderPixels(
        elements: [AnnotationElement],
        renderer: AnnotationRenderer,
        activeElement: AnnotationElement? = nil,
        pendingErasureElementIDs: Set<AnnotationElementID> = [],
        decorationElements: [AnnotationElement] = [],
        selectedElementIDs: Set<AnnotationElementID> = [],
        zoomScale: CGFloat = 1,
        width: Int = 96,
        height: Int = 96,
        backgroundColor: NSColor? = nil,
        destinationPointScale: CGFloat = 1,
        backingScale: Int = 1
    ) throws -> [UInt8] {
        try renderBitmap(width: width, height: height, backingScale: backingScale) { context in
            if let backgroundColor {
                let resolvedBackground = backgroundColor.usingColorSpace(.sRGB)
                    ?? backgroundColor
                context.setFillColor(resolvedBackground.cgColor)
                context.fill(
                    CGRect(
                        x: 0,
                        y: 0,
                        width: CGFloat(width),
                        height: CGFloat(height)
                    )
                )
            }
            renderer.render(
                elements: elements,
                activeElement: activeElement,
                destinationPointScale: destinationPointScale,
                pendingErasureElementIDs: pendingErasureElementIDs,
                in: context
            )
            renderer.renderSelectionDecorations(
                for: decorationElements,
                selectedElementIDs: selectedElementIDs,
                zoomScale: zoomScale,
                in: context
            )
        }
    }

    static func renderArrowheadPixels(
        _ arrowhead: AnnotationArrowhead,
        size: AnnotationArrowheadSize,
        strokeWidth: CGFloat,
        width: Int = 128,
        height: Int = 128
    ) throws -> [UInt8] {
        try renderBitmap(width: width, height: height, antialias: true) { context in
            guard let path = AnnotationGeometry.arrowheadPath(
                arrowhead,
                tip: CGPoint(x: 100, y: 64),
                adjacent: CGPoint(x: 20, y: 64),
                strokeWidth: strokeWidth,
                size: size
            ) else {
                throw SelfTestError.failure(
                    "Could not create arrowhead render bitmap"
                )
            }
            context.setStrokeColor(NSColor.black.cgColor)
            context.setFillColor(NSColor.black.cgColor)
            context.setLineWidth(strokeWidth)
            context.setLineCap(.round)
            context.setLineJoin(.round)
            context.addPath(path)
            arrowhead.isFilled ? context.fillPath() : context.strokePath()
        }
    }

    static func renderControllerPixels(
        _ controller: AnnotationController,
        freehandPresentationOwner: AnnotationFreehandPresentationOwner,
        includeTransientEraserFeedback: Bool = true,
        width: Int,
        height: Int
    ) throws -> [UInt8] {
        try renderBitmap(width: width, height: height) { context in
            controller.render(
                in: context,
                bounds: CGRect(
                    x: 0,
                    y: 0,
                    width: CGFloat(width),
                    height: CGFloat(height)
                ),
                includeSmartDrawPreview: false,
                includeInProgress: true,
                includeEditorChrome: false,
                includeTransientEraserFeedback:
                    includeTransientEraserFeedback,
                freehandPresentationOwner: freehandPresentationOwner
            )
        }
    }

    static func renderSelectionPixels(
        annotationController: AnnotationController,
        width: Int,
        height: Int
    ) throws -> [UInt8] {
        try renderBitmap(width: width, height: height) { context in
            annotationController.renderSelectionDecorations(in: context, zoomScale: 1)
        }
    }

    static func pixel(_ pixels: [UInt8], width: Int, x: Int, y: Int) -> RenderPixel {
        let height = pixels.count / (width * 4)
        let index = ((height - 1 - y) * width + x) * 4
        return RenderPixel(
            red: pixels[index],
            green: pixels[index + 1],
            blue: pixels[index + 2],
            alpha: pixels[index + 3]
        )
    }

    static func alpha(_ pixels: [UInt8], width: Int, x: Int, y: Int) -> UInt8 {
        pixel(pixels, width: width, x: x, y: y).alpha
    }

    static func paintedRuns(
        _ pixels: [UInt8],
        width: Int,
        y: Int,
        xRange: Range<Int>
    ) -> Int {
        var runs = 0
        var wasPainted = false
        for x in xRange {
            let isPainted = alpha(pixels, width: width, x: x, y: y) > 0
            if isPainted && !wasPainted {
                runs += 1
            }
            wasPainted = isPainted
        }
        return runs
    }

    static func paintedVerticalRuns(
        _ pixels: [UInt8],
        width: Int,
        x: Int,
        yRange: Range<Int>
    ) -> Int {
        var runs = 0
        var wasPainted = false
        for y in yRange {
            let isPainted = alpha(pixels, width: width, x: x, y: y) > 0
            if isPainted && !wasPainted {
                runs += 1
            }
            wasPainted = isPainted
        }
        return runs
    }

    static func paintedPixelCount(_ pixels: [UInt8]) -> Int {
        stride(from: 3, to: pixels.count, by: 4).reduce(into: 0) {
            if pixels[$1] > 0 {
                $0 += 1
            }
        }
    }

    static func pixelDifferenceCount(_ lhs: [UInt8], _ rhs: [UInt8]) -> Int {
        guard lhs.count == rhs.count else { return max(lhs.count, rhs.count) }
        return zip(lhs, rhs).reduce(into: 0) { count, pair in
            if pair.0 != pair.1 {
                count += 1
            }
        }
    }

    static func alphaMaskSymmetricDifferenceRatio(
        _ lhs: [UInt8],
        _ rhs: [UInt8]
    ) -> CGFloat {
        guard lhs.count == rhs.count else { return 1 }
        var union = 0
        var difference = 0
        for index in stride(from: 3, to: lhs.count, by: 4) {
            let left = lhs[index] > 0
            let right = rhs[index] > 0
            if left || right {
                union += 1
                if left != right {
                    difference += 1
                }
            }
        }
        return union > 0 ? CGFloat(difference) / CGFloat(union) : 0
    }

    static func expectRaster(
        _ actual: [UInt8],
        uniformlyScaling expectedSource: [UInt8],
        by multiplier: CGFloat,
        context: String
    ) throws {
        try expect(
            actual.count == expectedSource.count
                && expectedSource.contains(where: { $0 > 0 }),
            "Expected comparable nonempty rasters for \(context)"
        )
        var maximumError = 0
        var mismatchedBytes = 0
        for (actualByte, sourceByte) in zip(actual, expectedSource) {
            let expectedByte = Int(
                (CGFloat(sourceByte) * multiplier).rounded()
            )
            let error = abs(Int(actualByte) - expectedByte)
            maximumError = max(maximumError, error)
            if error > 2 {
                mismatchedBytes += 1
            }
        }
        try expect(
            mismatchedBytes == 0,
            "Expected complete \(context) raster to equal the normal composite "
                + "uniformly multiplied by \(multiplier); max error "
                + "\(maximumError), mismatched bytes \(mismatchedBytes)"
        )
    }

    static func pixelDifferenceCount(
        _ lhs: [UInt8],
        _ rhs: [UInt8],
        width: Int,
        xRange: Range<Int>,
        yRange: Range<Int>
    ) -> Int {
        guard lhs.count == rhs.count else { return max(lhs.count, rhs.count) }
        return yRange.reduce(into: 0) { count, y in
            for x in xRange {
                let left = pixel(lhs, width: width, x: x, y: y)
                let right = pixel(rhs, width: width, x: x, y: y)
                if left != right {
                    count += 1
                }
            }
        }
    }

    static func meanHorizontalDeviation(
        _ paths: [CGPath],
        canonicalY: CGFloat
    ) -> CGFloat {
        let deviations = paths.flatMap {
            AnnotationRoughStroke.sampledPoints(on: $0).map {
                abs($0.y - canonicalY)
            }
        }
        guard !deviations.isEmpty else { return 0 }
        return deviations.reduce(0, +) / CGFloat(deviations.count)
    }

    static func meanHorizontalWaviness(_ paths: [CGPath]) -> CGFloat {
        let waviness = paths.map { path -> CGFloat in
            let points = AnnotationRoughStroke.sampledPoints(on: path)
            guard let minimum = points.map(\.y).min(),
                  let maximum = points.map(\.y).max() else {
                return 0
            }
            return maximum - minimum
        }
        guard !waviness.isEmpty else { return 0 }
        return waviness.reduce(0, +) / CGFloat(waviness.count)
    }

    static func maximumHorizontalDeviation(
        _ paths: [CGPath],
        canonicalY: CGFloat
    ) -> CGFloat {
        paths.flatMap {
            AnnotationRoughStroke.sampledPoints(on: $0).map {
                abs($0.y - canonicalY)
            }
        }.max() ?? 0
    }

    static func meanPathSeparation(
        _ first: CGPath,
        _ second: CGPath
    ) -> CGFloat {
        let firstPoints = AnnotationRoughStroke.sampledPoints(on: first)
        let secondPoints = AnnotationRoughStroke.sampledPoints(on: second)
        let distances = zip(firstPoints, secondPoints).map {
            hypot($0.x - $1.x, $0.y - $1.y)
        }
        guard !distances.isEmpty else { return 0 }
        return distances.reduce(0, +) / CGFloat(distances.count)
    }

    static func hasPaintedPixel(
        _ pixels: [UInt8],
        width: Int,
        height: Int,
        near point: CGPoint,
        radius: Int
    ) -> Bool {
        let centerX = Int(point.x.rounded())
        let centerY = Int(point.y.rounded())
        let xRange = max(0, centerX - radius)...min(width - 1, centerX + radius)
        let yRange = max(0, centerY - radius)...min(height - 1, centerY + radius)
        return yRange.contains { y in
            xRange.contains { x in
                alpha(pixels, width: width, x: x, y: y) > 0
            }
        }
    }

    static func paintedVerticalSpan(
        _ pixels: [UInt8],
        width: Int,
        height: Int,
        x: Int
    ) -> Int {
        let paintedRows = (0..<height).filter { alpha(pixels, width: width, x: x, y: $0) > 0 }
        guard let first = paintedRows.first, let last = paintedRows.last else { return 0 }
        return last - first + 1
    }

    static func paintedBounds(
        _ pixels: [UInt8],
        width: Int,
        height: Int
    ) -> CGRect? {
        var painted: [CGPoint] = []
        for y in 0..<height {
            for x in 0..<width where alpha(pixels, width: width, x: x, y: y) > 0 {
                painted.append(CGPoint(x: x, y: y))
            }
        }
        guard let first = painted.first else { return nil }
        return painted.dropFirst().reduce(
            CGRect(x: first.x, y: first.y, width: 0, height: 0)
        ) { bounds, point in
            bounds.union(CGRect(x: point.x, y: point.y, width: 0, height: 0))
        }
    }

    static func noisyEllipsePoints(
        center: CGPoint,
        radiusX: CGFloat,
        radiusY: CGFloat,
        rotation: CGFloat,
        count: Int
    ) -> [CGPoint] {
        let cosine = cos(rotation)
        let sine = sin(rotation)
        return (0..<count).map { index in
            let angle = CGFloat(index) * 2 * .pi / CGFloat(count - 1)
            let noise = sin(CGFloat(index) * 1.73) * 1.15
            let localX = (radiusX + noise) * cos(angle)
            let localY = (radiusY + noise * 0.7) * sin(angle)
            return CGPoint(
                x: center.x + localX * cosine - localY * sine,
                y: center.y + localX * sine + localY * cosine
            )
        }
    }

    static func imperfectEllipsePoints(
        center: CGPoint,
        radiusX: CGFloat,
        radiusY: CGFloat,
        rotation: CGFloat,
        startAngle: CGFloat,
        endAngle: CGFloat,
        count: Int,
        unevenPower: CGFloat
    ) -> [CGPoint] {
        let cosine = cos(rotation)
        let sine = sin(rotation)
        return (0..<count).map { index in
            let linear = CGFloat(index) / CGFloat(max(count - 1, 1))
            let fraction = pow(linear, unevenPower)
            let angle = startAngle + (endAngle - startAngle) * fraction
            let noise = sin(CGFloat(index) * 1.57) * 1.35
            let localX = (radiusX + noise) * cos(angle)
            let localY = (radiusY + noise * 0.65) * sin(angle)
            return CGPoint(
                x: center.x + localX * cosine - localY * sine,
                y: center.y + localX * sine + localY * cosine
            )
        }
    }

    static func rotatedRectangleCorners(
        center: CGPoint,
        width: CGFloat,
        height: CGFloat,
        rotation: CGFloat
    ) -> [CGPoint] {
        let cosine = cos(rotation)
        let sine = sin(rotation)
        return [
            CGPoint(x: -width / 2, y: -height / 2),
            CGPoint(x: width / 2, y: -height / 2),
            CGPoint(x: width / 2, y: height / 2),
            CGPoint(x: -width / 2, y: height / 2)
        ].map { point in
            CGPoint(
                x: center.x + point.x * cosine - point.y * sine,
                y: center.y + point.x * sine + point.y * cosine
            )
        }
    }

    static func unevenPolygonPoints(
        corners: [CGPoint],
        samplesPerEdge: [Int],
        close: Bool
    ) -> [CGPoint] {
        guard corners.count >= 3, samplesPerEdge.count == corners.count else {
            return corners
        }
        var result: [CGPoint] = []
        for index in corners.indices {
            let start = corners[index]
            let end = corners[(index + 1) % corners.count]
            let count = max(2, samplesPerEdge[index])
            let vector = CGPoint(x: end.x - start.x, y: end.y - start.y)
            let length = max(hypot(vector.x, vector.y), 1)
            let normal = CGPoint(x: -vector.y / length, y: vector.x / length)
            for sample in 0..<count {
                let fraction = CGFloat(sample) / CGFloat(count)
                let noise = sin(CGFloat(index * 31 + sample) * 1.23) * 1.1
                result.append(
                    CGPoint(
                        x: start.x + vector.x * fraction + normal.x * noise,
                        y: start.y + vector.y * fraction + normal.y * noise
                    )
                )
            }
        }
        if close {
            result.append(corners[0])
        }
        return result
    }

    static func angleDifferenceModulo(
        _ lhs: CGFloat,
        _ rhs: CGFloat,
        period: CGFloat
    ) -> CGFloat {
        var difference = (lhs - rhs).truncatingRemainder(dividingBy: period)
        if difference > period / 2 {
            difference -= period
        } else if difference < -period / 2 {
            difference += period
        }
        return abs(difference)
    }

    static func noisyPolygonPoints(
        corners: [CGPoint],
        samplesPerEdge: Int
    ) -> [CGPoint] {
        guard corners.count >= 3 else { return corners }
        var result: [CGPoint] = []
        for index in corners.indices {
            let start = corners[index]
            let end = corners[(index + 1) % corners.count]
            let dx = end.x - start.x
            let dy = end.y - start.y
            let length = max(hypot(dx, dy), 1)
            let normal = CGPoint(x: -dy / length, y: dx / length)
            for sample in 0..<samplesPerEdge {
                let fraction = CGFloat(sample) / CGFloat(samplesPerEdge)
                let noise = sin(CGFloat(index * samplesPerEdge + sample) * 1.31) * 0.9
                result.append(
                    CGPoint(
                        x: start.x + dx * fraction + normal.x * noise,
                        y: start.y + dy * fraction + normal.y * noise
                    )
                )
            }
        }
        result.append(corners[0])
        return result
    }

    static func interpolatedPoints(
        from start: CGPoint,
        to end: CGPoint,
        count: Int,
        droppingFirst: Bool = false
    ) -> [CGPoint] {
        let points = (0..<count).map { index in
            let fraction = CGFloat(index) / CGFloat(max(count - 1, 1))
            return CGPoint(
                x: start.x + (end.x - start.x) * fraction,
                y: start.y + (end.y - start.y) * fraction
            )
        }
        return droppingFirst ? Array(points.dropFirst()) : points
    }

    static func distance(_ lhs: CGPoint, _ rhs: CGPoint) -> CGFloat {
        hypot(lhs.x - rhs.x, lhs.y - rhs.y)
    }

    static func approximatelyEqual(
        _ lhs: CGFloat,
        _ rhs: CGFloat,
        tolerance: CGFloat = 0.001
    ) -> Bool {
        abs(lhs - rhs) <= tolerance
    }

    static func approximatelyEqual(
        _ lhs: CGPoint,
        _ rhs: CGPoint,
        tolerance: CGFloat = 0.001
    ) -> Bool {
        abs(lhs.x - rhs.x) <= tolerance && abs(lhs.y - rhs.y) <= tolerance
    }

    static func approximatelyEqual(
        _ lhs: CGRect,
        _ rhs: CGRect,
        tolerance: CGFloat = 0.001
    ) -> Bool {
        approximatelyEqual(lhs.origin, rhs.origin, tolerance: tolerance)
            && abs(lhs.width - rhs.width) <= tolerance
            && abs(lhs.height - rhs.height) <= tolerance
    }

    static func colorsMatch(
        _ lhs: NSColor,
        _ rhs: NSColor,
        tolerance: CGFloat = 0.001
    ) -> Bool {
        guard let left = lhs.usingColorSpace(.sRGB),
              let right = rhs.usingColorSpace(.sRGB) else {
            return lhs.isEqual(rhs)
        }
        return abs(left.redComponent - right.redComponent) <= tolerance
            && abs(left.greenComponent - right.greenComponent) <= tolerance
            && abs(left.blueComponent - right.blueComponent) <= tolerance
            && abs(left.alphaComponent - right.alphaComponent) <= tolerance
    }

    static func expect(_ condition: Bool, _ message: String) throws {
        if !condition {
            throw SelfTestError.failure(message)
        }
    }
}

extension AnnotationElement {
    var textGeometryForTesting: AnnotationTextGeometry? {
        guard case .text(let text) = geometry else { return nil }
        return text
    }
}