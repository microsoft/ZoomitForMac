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
private final class FlippedBackgroundHostView: NSView {
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
        try testDemoTypeSettingsRoundTrip()
        try testDemoTypeScriptCleaningAndTokens()
        try testDemoTypeScriptDecoding()
        try testDemoTypeTypingDelayRange()
        try testDemoTypeUserDrivenStepStopsAtEnd()
        try testBreakTimerLayout()
        try testBreakTimerBackgroundNotFlipped()
        try testPanoramaSelectionBorderColor()
        try testPanoramaEscapeCancel()
        try testIdleSleepAssertionLifecycle()
        try testStatusMenuOrderMatchesWindows()
        try testClipTransitionUpdatesOnChange()
        try testWebcamOverlayDragOrigin()
        try testTrimSavePreservesOriginal()
        try testSettingsWindowStaysOnTop()
        try testZoomAndLiveZoomAreSeparateTabs()
        try testBlankScreenUsesControlKeys()
        try testTypeTabFontSampleUsesSelectedFont()
        try testMenuBarIconIsPaddedTemplate()
        try testStandardIconIsRoundedSquareWithMargin()
        try testDefaultTypingFontIsSystem20pt()
        try testStaticZoomStaysAtOneX()
        try testPanoramaStitching()
        try testPanoramaTopSeamUsesSingleFramePixels()
        try testPanoramaVerticalSeamKeepsSingleFrame()
        try testPanoramaDeferredDirectionCommit()
        try testPanoramaNoHarmonicRepeats()
        try testPanoramaFixedHeaderSuppression()
        try testPanoramaFooterDoesNotAttractSmallShift()
        try testPanoramaFixedFooterSuppression()
        try testPanoramaSkipsRepeatedCaptures()
        try testPanoramaRejectsStationaryRepaintShift()
        try testPanoramaKeepsScrollBesideStaticContent()
        try testPanoramaSparseTallContentStitches()
        try testPanoramaStartupAxisRejectsHorizontalAlias()
        try testPanoramaLockedAxisRejectsShortFallback()
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
        settings.breakHotKeyCode = 20
        settings.breakHotKeyModifiers = NSEvent.ModifierFlags([.command, .option]).rawValue
        settings.breakDurationMinutes = 25
        settings.breakTextColorRGB = 0x00FF00
        settings.breakBackgroundColorRGB = 0x000000
        settings.breakTimerPosition = 8
        settings.breakOpacity = 70
        settings.breakShowExpiredTime = false
        settings.breakPlaySound = true
        settings.breakSoundFile = "/tmp/break.wav"
        settings.breakBackgroundMode = 2
        settings.breakBackgroundStretch = true
        settings.breakBackgroundFile = "/tmp/break.png"
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

    private static func testDemoTypeSettingsRoundTrip() throws {
        let suiteName = "ZoomItMacSelfTest.DemoType.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            throw SelfTestError.failure("Could not create DemoType test UserDefaults suite")
        }
        let store = UserDefaultsSettingsStore(defaults: defaults)
        var settings = AppSettings.defaults
        settings.demoTypeHotKeyCode = 15
        settings.demoTypeHotKeyModifiers = NSEvent.ModifierFlags([.control, .option]).rawValue
        settings.demoTypeFile = "/tmp/demo-type.txt"
        settings.demoTypeSpeed = 84
        settings.demoTypeUserDriven = true
        store.save(settings)

        let loaded = store.load()
        try expect(loaded.demoTypeHotKeyCode == 15, "Expected DemoType hotkey code to round-trip")
        try expect(loaded.demoTypeHotKeyModifiers == settings.demoTypeHotKeyModifiers, "Expected DemoType hotkey modifiers to round-trip")
        try expect(loaded.demoTypeFile == "/tmp/demo-type.txt", "Expected DemoType file to round-trip")
        try expect(loaded.demoTypeSpeed == 84, "Expected DemoType speed to round-trip")
        try expect(loaded.demoTypeUserDriven, "Expected DemoType user-driven setting to round-trip")

        defaults.set(250, forKey: "demoTypeSpeed")
        try expect(store.load().demoTypeSpeed == 100, "Expected DemoType speed to clamp to the Windows slider maximum")

        defaults.removePersistentDomain(forName: suiteName)
    }

    private static func testDemoTypeScriptCleaningAndTokens() throws {
        let cleaned = DemoTypeController.cleanForTesting("\u{0001}\nhello\n[end]\nworld\n[paste]\nchunk\n[/paste]\n[end]\n   ")
        try expect(cleaned == "hello[end]world\n[paste]chunk[/paste][end]", "Unexpected DemoType cleaned script: \(cleaned)")

        let tokens = DemoTypeController.tokensForTesting("a[pause:2][enter][up][down][left][right][paste]hi[/paste][end]")
        try expect(tokens == [
            .text("a"),
            .pause(2),
            .key("enter"),
            .key("up"),
            .key("down"),
            .key("left"),
            .key("right"),
            .paste("hi"),
            .end
        ], "Unexpected DemoType tokens: \(tokens)")
    }

    private static func testDemoTypeScriptDecoding() throws {
        try expect(DemoTypeController.decodeForTesting(Data([0xEF, 0xBB, 0xBF]) + Data("utf8".utf8)) == "utf8", "Expected UTF-8 BOM DemoType text")
        try expect(DemoTypeController.decodeForTesting(Data([0xFF, 0xFE, 0x6C, 0x00, 0x65, 0x00])) == "le", "Expected UTF-16LE DemoType text")
        try expect(DemoTypeController.decodeForTesting(Data([0xFE, 0xFF, 0x00, 0x62, 0x00, 0x65])) == "be", "Expected UTF-16BE DemoType text")
    }

    private static func testDemoTypeTypingDelayRange() throws {
        try expect(DemoTypeController.typingDelayRangeForTesting(slider: 55) == 1...110, "Expected midpoint DemoType delay to match Windows speed +/- speed")
        try expect(DemoTypeController.typingDelayRangeForTesting(slider: 100) == 1...20, "Expected fastest DemoType delay range")
        try expect(DemoTypeController.typingDelayRangeForTesting(slider: 10) == 1...200, "Expected slowest DemoType delay range")
    }

    private static func testDemoTypeUserDrivenStepStopsAtEnd() throws {
        let script = "ab[end]cd[end]"
        let first = DemoTypeController.userDrivenStepForTesting(script, offset: 0)
        try expect(first == DemoTypeController.UserDrivenStepResult(token: .text("a"), ended: false, nextOffset: 1), "Expected one user key to emit one DemoType token")

        let end = DemoTypeController.userDrivenStepForTesting(script, offset: 2)
        try expect(end == DemoTypeController.UserDrivenStepResult(token: .end, ended: true, nextOffset: 7), "Expected [end] to stop the active user-driven DemoType entry")

        try expect(DemoTypeController.completedUserDrivenEntryOffsetForTesting(script, startOffset: 7) == script.count, "Expected final [end] to leave DemoType at EOF instead of wrapping in the active entry")
        try expect(DemoTypeController.completedUserDrivenEntryOffsetForTesting("abc", startOffset: 0) == 0, "Expected scripts without [end] to wrap after EOF")
    }

    private static func testStaticZoomStaysAtOneX() throws {
        // Windows ZoomIt keeps static zoom active when the user zooms all the
        // way out to 1x; only Esc/right-click exits. Live zoom still exits at
        // the floor.
        try expect(ModeCoordinator.exitsOnZoomOutFloor(mode: .staticZoom) == false,
                   "Expected static zoom to stay active at 1x instead of exiting")
        try expect(ModeCoordinator.exitsOnZoomOutFloor(mode: .liveZoom),
                   "Expected live zoom to exit when zoomed out to 1x")
        try expect(ModeCoordinator.exitsOnZoomOutFloor(mode: .typing),
                   "Expected typing (live zoom sub-mode) to exit when zoomed out to 1x")
    }

    /// The break timer view uses a flipped coordinate system. Drawing a
    /// background image there without flip awareness renders it upside down.
    /// Verify BreakTimerLayout.drawBackground keeps a vertically asymmetric
    /// image right-side up when drawn through a real flipped view.
    private static func testBreakTimerBackgroundNotFlipped() throws {
        let dim = 16
        // Source image: top half red, bottom half blue in its natural (image)
        // orientation. NSImage.lockFocus uses a bottom-left origin, so the red
        // upper half is filled at the higher y range.
        let source = NSImage(size: NSSize(width: dim, height: dim))
        source.lockFocus()
        NSColor.red.setFill()
        NSRect(x: 0, y: dim / 2, width: dim, height: dim / 2).fill()
        NSColor.blue.setFill()
        NSRect(x: 0, y: 0, width: dim, height: dim / 2).fill()
        source.unlockFocus()

        let host = FlippedBackgroundHostView(frame: NSRect(x: 0, y: 0, width: dim, height: dim))
        host.image = source
        guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else {
            throw SelfTestError.failure("Could not create caching bitmap for flipped host view")
        }
        host.cacheDisplay(in: host.bounds, to: rep)

        // Sample in the rep's real pixel space (it may be Retina 2x). Row 0 is
        // the top of the rendered view. With flip-aware drawing the top of the
        // image (red) must appear at the top; a regression would show blue there.
        let midX = rep.pixelsWide / 2
        guard let top = rep.colorAt(x: midX, y: 1),
              let bottom = rep.colorAt(x: midX, y: rep.pixelsHigh - 2) else {
            throw SelfTestError.failure("Could not sample break timer background pixels")
        }
        try expect(top.redComponent > 0.5 && top.blueComponent < 0.5,
                   "Expected break timer background top to stay red (right-side up), got \(top)")
        try expect(bottom.blueComponent > 0.5 && bottom.redComponent < 0.5,
                   "Expected break timer background bottom to stay blue (right-side up), got \(bottom)")
    }

    /// Windows ZoomIt draws the panorama region rectangle in yellow. The shared
    /// selection view defaults to white (snip/record) but the panorama selector
    /// requests yellow; verify the requested border colour is actually rendered.
    private static func testPanoramaSelectionBorderColor() throws {
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

        func borderIsYellow(_ view: SnipSelectionView) throws -> Bool {
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
            return c.redComponent > 0.5 && c.greenComponent > 0.5 && c.blueComponent < 0.4
        }

        let yellowView = SnipSelectionView(frame: CGRect(x: 0, y: 0, width: dim, height: dim), image: image, borderColor: .yellow)
        try expect(try borderIsYellow(yellowView), "Expected panorama selection border to render yellow")

        let whiteView = SnipSelectionView(frame: CGRect(x: 0, y: 0, width: dim, height: dim), image: image)
        try expect(try !borderIsYellow(whiteView), "Expected default snip selection border to remain non-yellow (white)")
    }

    /// Escape during the scrolling panorama capture must cancel the run, but
    /// only while it is actively capturing, and repeated Escapes are ignored.
    private static func testPanoramaEscapeCancel() throws {
        try expect(PanoramaController.shouldCancelOnEscape(isCapturing: true, alreadyCancelled: false),
                   "Expected Escape to cancel an active panorama capture")
        try expect(PanoramaController.shouldCancelOnEscape(isCapturing: false, alreadyCancelled: false) == false,
                   "Expected Escape to be ignored when not capturing")
        try expect(PanoramaController.shouldCancelOnEscape(isCapturing: true, alreadyCancelled: true) == false,
                   "Expected a repeated Escape to be ignored once already cancelled")
    }

    /// The break timer suppresses the screen saver by holding a display-sleep
    /// assertion. Verify the assertion is acquired once on begin, released on
    /// end, and that both operations are idempotent.
    private static func testIdleSleepAssertionLifecycle() throws {
        var created = 0
        var released = 0
        let assertion = IdleSleepAssertion(
            create: { _ in created += 1; return IOPMAssertionID(created) },
            release: { _ in released += 1 }
        )

        try expect(assertion.isActive == false, "Expected assertion to start inactive")

        assertion.begin(reason: "test")
        try expect(assertion.isActive, "Expected assertion active after begin")
        try expect(created == 1, "Expected exactly one assertion created")

        // begin is idempotent: a second begin must not create another.
        assertion.begin(reason: "test")
        try expect(created == 1, "Expected begin to be idempotent (no second create)")

        assertion.end()
        try expect(assertion.isActive == false, "Expected assertion inactive after end")
        try expect(released == 1, "Expected exactly one assertion released")

        // end is idempotent: a second end must not release again.
        assertion.end()
        try expect(released == 1, "Expected end to be idempotent (no second release)")
    }

    /// The menu-bar menu broadly follows the Windows ZoomIt tray order (Options
    /// first, modes, then Check Permissions and Quit), with Panorama as a
    /// macOS-only extra after Record and the Break Timer placed below Panorama
    /// Capture.
    private static func testStatusMenuOrderMatchesWindows() throws {
        let titles = AppDelegate.statusMenuEntries()
            .filter { !$0.isSeparator }
            .map(\.title)

        // Confirm the items appear in the expected relative order.
        let expectedOrder = [
            "Settings…",        // Options
            "Draw",
            "Static Zoom",      // Zoom
            "Live Zoom",
            "Record Screen",    // Record
            "Panorama Capture", // macOS-only, after Record
            "Break Timer",      // moved below Panorama Capture
            "Check Permissions",
            "Quit"
        ]

        let positions = expectedOrder.map { titles.firstIndex(of: $0) }
        for (label, index) in zip(expectedOrder, positions) {
            try expect(index != nil, "Expected status menu to contain '\(label)'")
        }
        let resolved = positions.compactMap { $0 }
        try expect(resolved == resolved.sorted(),
                   "Expected status menu items to follow the expected order, got \(titles)")

        // Break Timer must come after Panorama Capture.
        if let breakIndex = titles.firstIndex(of: "Break Timer"),
           let panoramaIndex = titles.firstIndex(of: "Panorama Capture") {
            try expect(breakIndex > panoramaIndex,
                       "Expected Break Timer to be below Panorama Capture, got \(titles)")
        } else {
            throw SelfTestError.failure("Expected both Break Timer and Panorama Capture menu items")
        }

        // Options must be first and Quit last, as on Windows.
        try expect(titles.first == "Settings…", "Expected Options/Settings to be the first menu item")
        try expect(titles.last == "Quit", "Expected Quit to be the last menu item")
    }

    /// Changing the clip transition popup from Fade to Black to Fade to White
    /// must update the existing append boundary (previously it stayed black
    /// because the transition was captured only at append time). Delete-seam
    /// joins keep their own transition.
    private static func testClipTransitionUpdatesOnChange() throws {
        typealias Transition = VideoClipEditorController.Transition

        // One append boundary starting as Fade to Black; switch to Fade to White.
        let updated = VideoClipEditorController.updatedJoinTransitions(
            current: [.fadeBlack],
            isAppendJoin: [true],
            newTransition: .fadeWhite
        )
        try expect(updated == [.fadeWhite], "Expected append boundary to switch to Fade to White, got \(updated)")

        // Mixed: an append boundary adopts the new transition, a delete seam
        // (not an append) keeps its existing value.
        let mixed = VideoClipEditorController.updatedJoinTransitions(
            current: [.fadeBlack, Transition.none],
            isAppendJoin: [true, false],
            newTransition: .fadeWhite
        )
        try expect(mixed == [.fadeWhite, Transition.none],
                   "Expected only the append boundary to change, got \(mixed)")
    }

    /// Dragging the webcam picture-in-picture must keep the grabbed point under
    /// the cursor: the new window origin is the cursor position minus the grab
    /// offset within the window.
    private static func testWebcamOverlayDragOrigin() throws {
        // Window was at origin (100, 200) with size 160x120; the user grabbed a
        // point 40,30 inside it, so grabOffset = (40, 30). Grab point on screen
        // was (140, 230).
        let grabOffset = CGSize(width: 40, height: 30)

        // No movement: cursor still at the original grab point -> origin unchanged.
        let unchanged = WebcamOverlayController.draggedWindowOrigin(mouseOnScreen: CGPoint(x: 140, y: 230), grabOffset: grabOffset)
        try expect(unchanged == CGPoint(x: 100, y: 200), "Expected unchanged origin when cursor hasn't moved, got \(unchanged)")

        // Move the cursor by (+50, -70); the window origin should move the same.
        let moved = WebcamOverlayController.draggedWindowOrigin(mouseOnScreen: CGPoint(x: 190, y: 160), grabOffset: grabOffset)
        try expect(moved == CGPoint(x: 150, y: 130), "Expected dragged origin to track the cursor, got \(moved)")
    }

    /// Trimming an existing video and saving under a new name must NOT delete
    /// the user's original file (it did, because the source was moved). When no
    /// edits were made the editor returns the original URL and we copy it;
    /// otherwise it returns an exported temp file that we move.
    private static func testTrimSavePreservesOriginal() throws {
        let original = URL(fileURLWithPath: "/tmp/original.mp4")

        // No edits: editor hands back the original URL -> copy (preserve source).
        try expect(RecordingController.trimSaveAction(editedURL: original, originalURL: original) == .copy,
                   "Expected an unedited trim save to copy the original, preserving it")

        // Edited: editor exported a temp file -> move it (original untouched).
        let exported = URL(fileURLWithPath: "/tmp/ZoomIt-edit-1234.mp4")
        try expect(RecordingController.trimSaveAction(editedURL: exported, originalURL: original) == .move,
                   "Expected an edited trim save to move the exported temp file")
    }

    /// The Settings dialog must stay on top like the Windows Options dialog so
    /// it can't get hidden behind other windows (which would leave ZoomIt's
    /// hotkeys suspended and the app apparently unresponsive).
    private static func testSettingsWindowStaysOnTop() throws {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 100, height: 100),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: true
        )
        // Sanity: a normal window is at the normal level and hides on deactivate
        // is off by default; ensure our configuration changes the level.
        SettingsWindowController.configureAlwaysOnTop(window)
        try expect(window.level == .floating, "Expected settings window to float above other windows")
        try expect(window.hidesOnDeactivate == false, "Expected settings window not to hide when the app deactivates")
    }

    /// Windows keeps static-zoom and live-zoom settings on separate tabs (the
    /// Zoom tab is static-only). Verify the Mac Options dialog exposes a
    /// distinct "Live Zoom" tab immediately after "Zoom".
    private static func testZoomAndLiveZoomAreSeparateTabs() throws {
        let titles = SettingsWindowController.settingsTabTitles
        guard let zoomIndex = titles.firstIndex(of: "Zoom") else {
            throw SelfTestError.failure("Expected a Zoom tab in the Options dialog")
        }
        try expect(titles.contains("Live Zoom"), "Expected a separate Live Zoom tab")
        try expect(titles.firstIndex(of: "Live Zoom") == zoomIndex + 1,
                   "Expected Live Zoom to be its own tab right after Zoom, got \(titles)")
    }

    /// The blank-screen sketch pad is triggered with Ctrl+W / Ctrl+K while
    /// drawing (matching the corrected Draw-tab help), leaving plain W/K for the
    /// white/black pen and Shift+W/K for the highlighter.
    private static func testBlankScreenUsesControlKeys() throws {
        typealias Action = ZoomCanvasView.WhiteBlackKeyAction
        try expect(ZoomCanvasView.whiteBlackKeyAction(control: true, shift: false, isDrawingMode: true) == .blankScreen,
                   "Expected Ctrl+W/Ctrl+K to blank the screen while drawing")
        try expect(ZoomCanvasView.whiteBlackKeyAction(control: false, shift: false, isDrawingMode: true) == .penColor,
                   "Expected plain W/K to select the pen colour, not blank the screen")
        try expect(ZoomCanvasView.whiteBlackKeyAction(control: false, shift: true, isDrawingMode: true) == .highlightColor,
                   "Expected Shift+W/K to select the highlighter")
        try expect(ZoomCanvasView.whiteBlackKeyAction(control: true, shift: false, isDrawingMode: false) == .penColor,
                   "Expected Ctrl+W/K outside drawing mode to fall back to the pen colour")
    }

    /// The Type tab's "Sample" preview must render in the selected typing font
    /// (it previously always used the system font, so font changes weren't
    /// visible). Also verify the preview size is clamped to a legible range.
    private static func testTypeTabFontSampleUsesSelectedFont() throws {
        // A concrete named font should be reflected in the preview font.
        let courier = SettingsWindowController.fontSamplePreviewFont(name: "Courier", size: 24)
        try expect(courier.fontName.lowercased().contains("courier"),
                   "Expected the font sample preview to use the selected font, got \(courier.fontName)")

        // Preview size clamps: very large selections shrink to <= 36pt, very
        // small ones grow to >= 12pt, so the sample stays legible.
        let big = SettingsWindowController.fontSamplePreviewFont(name: "Courier", size: 200)
        try expect(big.pointSize <= 36, "Expected large font preview to clamp to 36pt, got \(big.pointSize)")
        let small = SettingsWindowController.fontSamplePreviewFont(name: "Courier", size: 4)
        try expect(small.pointSize >= 12, "Expected small font preview to clamp to 12pt, got \(small.pointSize)")
    }

    /// The menu-bar icon was a full-bleed image, making it look larger than and
    /// misaligned with system icons. It must now render into a padded, square
    /// template image so the glyph carries interior padding and stays centered.
    private static func testMenuBarIconIsPaddedTemplate() throws {
        // A fully-filled opaque source glyph (edge to edge).
        let dim = 32
        let source = NSImage(size: NSSize(width: dim, height: dim))
        source.lockFocus()
        NSColor.black.setFill()
        NSRect(x: 0, y: 0, width: dim, height: dim).fill()
        source.unlockFocus()

        let icon = AppDelegate.menuBarImage(from: source)
        try expect(icon.isTemplate, "Expected the menu-bar icon to be a template image so it tints with the menu bar")
        try expect(icon.size == NSSize(width: AppDelegate.menuBarIconCanvas, height: AppDelegate.menuBarIconCanvas),
                   "Expected the menu-bar icon to use the padded canvas size, got \(icon.size)")
        // The glyph must be inset (smaller than the canvas), giving it padding.
        try expect(AppDelegate.menuBarIconGlyph < AppDelegate.menuBarIconCanvas,
                   "Expected the glyph to be inset within the canvas for padding")

        // The canvas corners should be transparent padding even though the
        // source filled its bounds edge to edge.
        guard let tiff = icon.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff) else {
            throw SelfTestError.failure("Could not rasterize menu-bar icon")
        }
        let corner = rep.colorAt(x: 0, y: 0)
        try expect((corner?.alphaComponent ?? 1) < 0.01,
                   "Expected the menu-bar icon corner to be transparent padding, got alpha \(corner?.alphaComponent ?? -1)")
        // The centre should carry the glyph (opaque).
        let center = rep.colorAt(x: rep.pixelsWide / 2, y: rep.pixelsHigh / 2)
        try expect((center?.alphaComponent ?? 0) > 0.5,
                   "Expected the menu-bar icon centre to contain the glyph, got alpha \(center?.alphaComponent ?? -1)")
    }

    /// The permissions-dialog / picker icon must be a standard macOS-style
    /// rounded square with a margin (the raw artwork is full-bleed edge to
    /// edge, which looks oversized and misaligns the dialog text). Verify the
    /// produced icon is square, has transparent margin/corners, and an opaque
    /// centre.
    private static func testStandardIconIsRoundedSquareWithMargin() throws {
        let size: CGFloat = 128
        guard let icon = ZoomItAppIcon.standardIcon(size: size) else {
            throw SelfTestError.failure("Expected a standard icon to be produced")
        }
        try expect(icon.size == NSSize(width: size, height: size),
                   "Expected a square standard icon of \(size)pt, got \(icon.size)")

        guard let tiff = icon.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff) else {
            throw SelfTestError.failure("Could not rasterize standard icon")
        }
        // Corner should be transparent (rounded + margin), unlike the full-bleed
        // source artwork which reaches every edge.
        let corner = rep.colorAt(x: 0, y: 0)
        try expect((corner?.alphaComponent ?? 1) < 0.01,
                   "Expected standard icon corner to be transparent margin, got alpha \(corner?.alphaComponent ?? -1)")
        // The centre must carry the artwork.
        let center = rep.colorAt(x: rep.pixelsWide / 2, y: rep.pixelsHigh / 2)
        try expect((center?.alphaComponent ?? 0) > 0.5,
                   "Expected standard icon centre to contain artwork, got alpha \(center?.alphaComponent ?? -1)")
    }

    /// The default typing font should be the default Mac font (an empty font
    /// name resolves to the system font) at 20pt.
    private static func testDefaultTypingFontIsSystem20pt() throws {
        try expect(AppSettings.defaults.typingFontName.isEmpty,
                   "Expected the default typing font name to be empty (the default Mac system font)")
        try expect(AppSettings.defaults.typingFontSize == 20,
                   "Expected the default typing font size to be 20pt, got \(AppSettings.defaults.typingFontSize)")
        try expect(AnnotationController.defaultFontSize == 20,
                   "Expected the annotation controller default font size to be 20pt")

        // An empty name resolves to the system font at the requested size.
        let resolved = AnnotationController.typingFont(named: "", size: 20)
        let system = NSFont.systemFont(ofSize: 20, weight: .semibold)
        try expect(resolved.fontName == system.fontName,
                   "Expected the default typing font to resolve to the system font, got \(resolved.fontName)")
        try expect(resolved.pointSize == 20, "Expected the default typing font to be 20pt, got \(resolved.pointSize)")
    }

    private static func testBreakTimerLayout() throws {
        try expect(BreakTimerLayout.timerText(for: 601) == "10:01", "Expected positive break timer text to format as minutes and seconds")
        try expect(BreakTimerLayout.timerText(for: 0) == "0:00", "Expected zero break timer text")
        try expect(BreakTimerLayout.timerText(for: -3) == "0:00", "Expected expired break timer main text to stay at zero")
        try expect(BreakTimerLayout.expiredText(for: -75) == "(- 1:15)", "Expected expired break timer overrun text")

        let bounds = CGRect(x: 0, y: 0, width: 1000, height: 800)
        let textSize = CGSize(width: 200, height: 100)
        let expiredSize = CGSize(width: 120, height: 60)
        try expect(BreakTimerLayout.timerOrigin(textSize: textSize, expiredSize: .zero, bounds: bounds, position: 0) == CGPoint(x: 50, y: 50), "Expected top-left break timer placement")
        try expect(BreakTimerLayout.timerOrigin(textSize: textSize, expiredSize: .zero, bounds: bounds, position: 4) == CGPoint(x: 400, y: 350), "Expected centered break timer placement")
        try expect(BreakTimerLayout.timerOrigin(textSize: textSize, expiredSize: expiredSize, bounds: bounds, position: 8) == CGPoint(x: 750, y: 580), "Expected bottom-right placement to reserve expired-time height")
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

    /// Vertical seams must use keep-first (a single source frame per canvas
    /// pixel), never an overlap blend. A feather blend ghosts slightly-
    /// misaligned text into a dark band -- the strikethrough artifact seen on
    /// real captures. This drives content whose flat background brightness is
    /// unique per frame, then asserts the stitched output only ever contains
    /// exact source values, never an averaged (blended) intermediate.
    private static func testPanoramaVerticalSeamKeepsSingleFrame() throws {
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

    private static func testPanoramaRejectsStationaryRepaintShift() throws {
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

    private static func testPanoramaKeepsScrollBesideStaticContent() throws {
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

    private static func testPanoramaLockedAxisRejectsShortFallback() throws {
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