import AppKit

extension SelfTestRunner {
    static func testAsyncWaitTimeout() async throws {
        do {
            _ = try await withSelfTestTimeout(
                "timeout self-check",
                after: .milliseconds(1)
            ) {
                try await ContinuousClock().sleep(for: .seconds(1))
            }
            throw SelfTestError.failure(
                "Expected the timeout self-check to fail"
            )
        } catch let error as SelfTestError {
            try expect(
                error.description == "Timed out waiting for timeout self-check",
                "Expected async self-test waits to fail with SelfTestError"
            )
        }
    }

    static func testAppInfoVersionResolution() throws {
        try expect(
            AppInfo.resolveVersion(from: ["CFBundleShortVersionString": "12.2.0"]) == "12.2.0",
            "Expected the settings version to use CFBundleShortVersionString"
        )
        try expect(
            AppInfo.resolveVersion(from: ["CFBundleVersion": "42"]) == "42",
            "Expected the settings version to fall back to CFBundleVersion"
        )
        try expect(
            AppInfo.resolveVersion(from: nil) == "Development",
            "Expected an unbundled development build to identify itself as Development"
        )
    }

    static func testViewportClampsZoom() throws {
        let controller = ZoomViewportController()

        controller.configure(for: try makeFrame(), initialZoom: 100)
        try expect(controller.zoomFactor == 32, "Expected initial zoom to clamp to 32x")

        controller.configure(for: try makeFrame(), initialZoom: 0.25)
        try expect(controller.zoomFactor == 1, "Expected initial zoom to clamp to 1x")
    }

    static func testViewportZoomAnimation() throws {
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

    static func testViewportSourceRect() throws {
        let controller = ZoomViewportController()
        controller.configure(for: try makeFrame(), initialZoom: 2)

        let rect = controller.sourceRect(
            for: CGRect(x: 0, y: 0, width: 1000, height: 800),
            cursorLocation: CGPoint(x: 500, y: 400)
        )

        try expect(rect == CGRect(x: 250, y: 200, width: 500, height: 400), "Unexpected centered source rect: \(rect)")
    }

    static func testViewportContentPointMapping() throws {
        let controller = ZoomViewportController()
        controller.configure(for: try makeFrame(), initialZoom: 2)

        let point = controller.contentPoint(
            for: CGPoint(x: 500, y: 400),
            destinationBounds: CGRect(x: 0, y: 0, width: 1000, height: 800),
            cursorLocation: CGPoint(x: 500, y: 400)
        )

        try expect(point == CGPoint(x: 500, y: 400), "Unexpected mapped content point: \(point)")
    }

    static func testViewportContentToDestinationTransform() throws {
        let controller = ZoomViewportController()
        let transform = controller.contentToDestinationTransform(
            source: CGRect(x: 250, y: 200, width: 500, height: 400),
            destinationBounds: CGRect(x: 0, y: 0, width: 1000, height: 800)
        )

        try expect(CGPoint(x: 250, y: 200).applying(transform) == CGPoint(x: 0, y: 0), "Expected source origin to map to destination origin")
        try expect(CGPoint(x: 500, y: 400).applying(transform) == CGPoint(x: 500, y: 400), "Expected source center to map to destination center")
    }

    static func testSettingsRoundTrip() throws {
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
        settings.highlighterWidth = 27
        settings.drawingToolbarNormalizedPosition = CGPoint(x: 0.2, y: 0.8)
        settings.defaultDrawingDefaults = DrawingDefaults(
            tool: .arrow,
            strokeColor: .rgba(red: 0.1, green: 0.2, blue: 0.3, alpha: 0.9),
            regularStrokeColor: .rgba(red: 0.1, green: 0.2, blue: 0.3, alpha: 0.9),
            highlighterStrokeColor: .palette(.highlighterCyan),
            penStrokeWidth: 9,
            highlighterStrokeWidth: 24,
            geometryStrokeWidth: 5,
            penOpacity: 0.55,
            geometryOpacity: 0.65,
            highlighterOpacity: 0.45,
            fillColor: .palette(.yellow),
            fillStyle: .crossHatch,
            strokePattern: .dashed,
            sloppiness: .cartoonist,
            freehandSloppiness: .artist,
            outlinedSloppiness: .cartoonist,
            opacity: 0.65,
            pressureMode: .simulated,
            smoothingEnabled: false,
            smartDrawEnabled: true,
            roundness: 14,
            linearRoute: .curved,
            lineRoute: .straight,
            arrowRoute: .curved,
            startArrowhead: .circle,
            endArrowhead: .triangle,
            arrowheadSize: .large,
            usesLegacyHighlightCompositing: true
        )
        settings.rememberLastDrawingStyle = true
        settings.lastDrawingDefaults = DrawingDefaults(
            tool: .rectangle,
            strokeColor: .palette(.green),
            regularStrokeColor: .palette(.green),
            highlighterStrokeColor: .palette(.highlighterPink),
            penStrokeWidth: 11,
            highlighterStrokeWidth: 28,
            geometryStrokeWidth: 6,
            penOpacity: 0.4,
            geometryOpacity: 0.4,
            highlighterOpacity: 0.3,
            fillColor: .rgba(red: 0.8, green: 0.7, blue: 0.6, alpha: 1),
            fillStyle: .hachure,
            strokePattern: .dotted,
            sloppiness: .architect,
            freehandSloppiness: .cartoonist,
            outlinedSloppiness: .architect,
            opacity: 0.4,
            pressureMode: .tablet,
            smoothingEnabled: true,
            smartDrawEnabled: false,
            roundness: 20,
            linearRoute: .curved,
            lineRoute: .curved,
            arrowRoute: .straight,
            startArrowhead: .bar,
            endArrowhead: .diamond,
            arrowheadSize: .medium
        )
        settings.typingFontName = "Helvetica"
        settings.typingFontPreset = .typeSetting
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

    static func testDrawingSettingsDefaultsAndMigration() throws {
        try expect(
            AppSettings.defaults.drawingToolbarNormalizedPosition == nil,
            "Expected a fresh install to use the native default toolbar placement"
        )
        try expect(
            AppSettings.defaults.defaultDrawingDefaults == .default
                && AppSettings.defaults.rootPenWidth == 7
                && AppSettings.defaults.highlighterWidth == 18
                && AppSettings.defaults.defaultDrawingDefaults.tool == .pen
                && AppSettings.defaults.defaultDrawingDefaults.startArrowhead == .none
                && AppSettings.defaults.defaultDrawingDefaults.endArrowhead == .arrow
                && AppSettings.defaults.defaultDrawingDefaults.lineRoute == .straight
                && AppSettings.defaults.defaultDrawingDefaults.arrowRoute == .curved
                && AppSettings.defaults.defaultDrawingDefaults.arrowheadSize == .medium
                && AppSettings.defaults.defaultDrawingDefaults.sloppiness == .artist
                && AppSettings.defaults.defaultDrawingDefaults.freehandSloppiness
                    == .artist
                && AppSettings.defaults.defaultDrawingDefaults.outlinedSloppiness
                    == .artist
                && !AppSettings.defaults.defaultDrawingDefaults.smartDrawEnabled,
            "Expected the legacy pen workflow, forward Arrow defaults, and opt-in Smart Draw "
                + "behavior to remain the defaults"
        )
        try expect(
            !AppSettings.defaults.rememberLastDrawingStyle
                && AppSettings.defaults.lastDrawingDefaults == nil
                && AppSettings.defaults.defaultDrawingDefaults.regularStrokeColor == nil
                && AppSettings.defaults.defaultDrawingDefaults.highlighterStrokeColor == nil,
            "Expected remembering the last style to remain opt-in"
        )

        let suiteName = "ZoomItMacSelfTest.DrawingMigration.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            throw SelfTestError.failure("Could not create drawing migration UserDefaults suite")
        }
        defaults.set(9.5, forKey: "rootPenWidth")
        defaults.set("Helvetica", forKey: "typingFontName")
        defaults.set(36.0, forKey: "typingFontSize")
        defaults.set(19, forKey: "drawHotKeyCode")
        defaults.set(1 << 18, forKey: "drawHotKeyModifiers")

        let migrated = UserDefaultsSettingsStore(defaults: defaults).load()
        try expect(
            migrated.rootPenWidth == 9.5
                && migrated.highlighterWidth == 18
                && migrated.typingFontName == "Helvetica"
                && migrated.typingFontPreset == .typeSetting
                && migrated.typingFontSize == 36,
            "Expected legacy pen width and typing defaults to survive migration"
        )
        try expect(
            migrated.drawHotKeyCode == 19
                && migrated.drawHotKeyModifiers == UInt(1 << 18),
            "Expected the legacy draw shortcut to survive migration"
        )
        try expect(
            migrated.defaultDrawingDefaults == .default
                && !migrated.defaultDrawingDefaults.smartDrawEnabled
                && !migrated.rememberLastDrawingStyle,
            "Expected released settings to receive the current drawing defaults"
        )

        defaults.set(
            ["x": -0.25, "y": 1.75],
            forKey: "drawingToolbarNormalizedPosition"
        )
        defaults.set(
            [
                "schemaVersion": 1,
                "tool": "unsupported",
                "strokeColor": ["palette": "green"],
                "fillStyle": "solid",
                "strokePattern": "dotted",
                "sloppiness": 99,
                "freehandSloppiness": AnnotationSloppiness.cartoonist.rawValue,
                "outlinedSloppiness": AnnotationSloppiness.architect.rawValue,
                "opacity": 4.0,
                "penStrokeWidth": -4.0,
                "highlighterStrokeWidth": 400.0,
                "geometryStrokeWidth": Double.nan,
                "lineRoute": "elbow",
                "arrowRoute": "elbow",
                "arrowheadSize": "unsupported",
                "endArrowhead": "triangle"
            ],
            forKey: "defaultDrawingDefaults"
        )
        let normalized = UserDefaultsSettingsStore(defaults: defaults).load()
        try expect(
            normalized.drawingToolbarNormalizedPosition == CGPoint(x: 0, y: 1),
            "Expected stored toolbar coordinates to normalize into the display-relative range"
        )
        try expect(
            normalized.defaultDrawingDefaults.tool == .pen
                && normalized.defaultDrawingDefaults.strokeColor == .palette(.green)
                && normalized.defaultDrawingDefaults.fillStyle == .solid
                && normalized.defaultDrawingDefaults.strokePattern == .dotted
                && normalized.defaultDrawingDefaults.sloppiness == .cartoonist
                && normalized.defaultDrawingDefaults.freehandSloppiness == .cartoonist
                && normalized.defaultDrawingDefaults.outlinedSloppiness == .architect
                && normalized.defaultDrawingDefaults.opacity == 1
                && normalized.defaultDrawingDefaults.penStrokeWidth == 1
                && normalized.defaultDrawingDefaults.highlighterStrokeWidth == 64
                && normalized.defaultDrawingDefaults.geometryStrokeWidth == nil
                && normalized.defaultDrawingDefaults.lineRoute == .straight
                && normalized.defaultDrawingDefaults.arrowRoute == .curved
                && normalized.defaultDrawingDefaults.arrowheadSize == .medium
                && normalized.defaultDrawingDefaults.endArrowhead == .triangle,
            "Expected the current drawing schema to clamp finite values and reject malformed fields"
        )

        defaults.set(
            [
                "schemaVersion": 99,
                "tool": "arrow",
                "startArrowhead": "circle",
                "endArrowhead": "diamond"
            ],
            forKey: "defaultDrawingDefaults"
        )
        let unsupportedSchema =
            UserDefaultsSettingsStore(defaults: defaults).load()
        try expect(
            unsupportedSchema.defaultDrawingDefaults == .default,
            "Expected unknown drawing schemas to fall back instead of running unreleased migrations"
        )

        let arrowheads = DrawingInspectorControlMapping.arrowheads
        let store = UserDefaultsSettingsStore(defaults: defaults)
        for startArrowhead in arrowheads {
            for endArrowhead in arrowheads {
                var settings = AppSettings.defaults
                settings.defaultDrawingDefaults.tool = .arrow
                settings.defaultDrawingDefaults.startArrowhead = startArrowhead
                settings.defaultDrawingDefaults.endArrowhead = endArrowhead
                settings.rememberLastDrawingStyle = true
                settings.lastDrawingDefaults = settings.defaultDrawingDefaults
                store.save(settings)

                let reloaded = store.load()
                try expect(
                    reloaded.defaultDrawingDefaults.startArrowhead == startArrowhead
                        && reloaded.defaultDrawingDefaults.endArrowhead == endArrowhead
                        && reloaded.lastDrawingDefaults?.startArrowhead == startArrowhead
                        && reloaded.lastDrawingDefaults?.endArrowhead == endArrowhead,
                    "Expected versioned drawing and remembered defaults to round-trip "
                        + "\(startArrowhead)/\(endArrowhead) arrowheads exactly"
                )
                try expect(
                    (defaults.dictionary(forKey: "defaultDrawingDefaults")?["schemaVersion"]
                        as? NSNumber)?.intValue == 1
                        && (defaults.dictionary(forKey: "lastDrawingDefaults")?["schemaVersion"]
                            as? NSNumber)?.intValue == 1,
                    "Expected saved drawing defaults to include the current schema version"
                )
            }
        }

        defaults.removePersistentDomain(forName: suiteName)
    }

    static func testFirstLaunchFlag() throws {
        let suiteName = "ZoomItMacSelfTest.FirstLaunch.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            throw SelfTestError.failure("Could not create test UserDefaults suite")
        }
        let store = UserDefaultsSettingsStore(defaults: defaults)

        // A fresh store reports first launch so the app opens Settings (issue #21).
        try expect(!store.hasCompletedFirstLaunch, "Expected fresh store to report first launch not completed")

        store.markFirstLaunchCompleted()
        try expect(store.hasCompletedFirstLaunch, "Expected first launch to be marked completed")

        // The flag must persist so subsequent launches do not reopen Settings.
        let reloaded = UserDefaultsSettingsStore(defaults: defaults)
        try expect(reloaded.hasCompletedFirstLaunch, "Expected first-launch completion to persist across store instances")

        defaults.removePersistentDomain(forName: suiteName)

        // Migration: a user upgrading from a build without the flag but with prior
        // ZoomIt preferences must be treated as returning, not a fresh install.
        let legacySuite = "ZoomItMacSelfTest.FirstLaunchLegacy.\(UUID().uuidString)"
        guard let legacyDefaults = UserDefaults(suiteName: legacySuite) else {
            throw SelfTestError.failure("Could not create legacy test UserDefaults suite")
        }
        legacyDefaults.set(11281, forKey: "NSStatusItem Preferred Position com.sysinternals.ZoomIt.statusItem")
        let legacyStore = UserDefaultsSettingsStore(defaults: legacyDefaults)
        try expect(legacyStore.hasCompletedFirstLaunch, "Expected prior status-item position default to count as a completed first launch")
        legacyDefaults.removePersistentDomain(forName: legacySuite)
    }

    #if !ZOOMIT_APP_STORE
    static func testDemoTypeSettingsRoundTrip() throws {
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
    #endif

    #if !ZOOMIT_APP_STORE
    static func testDemoTypeScriptCleaningAndTokens() throws {
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
    #endif

    #if !ZOOMIT_APP_STORE
    static func testDemoTypeScriptDecoding() throws {
        try expect(DemoTypeController.decodeForTesting(Data([0xEF, 0xBB, 0xBF]) + Data("utf8".utf8)) == "utf8", "Expected UTF-8 BOM DemoType text")
        try expect(DemoTypeController.decodeForTesting(Data([0xFF, 0xFE, 0x6C, 0x00, 0x65, 0x00])) == "le", "Expected UTF-16LE DemoType text")
        try expect(DemoTypeController.decodeForTesting(Data([0xFE, 0xFF, 0x00, 0x62, 0x00, 0x65])) == "be", "Expected UTF-16BE DemoType text")
    }
    #endif

    #if !ZOOMIT_APP_STORE
    static func testDemoTypeTypingDelayRange() throws {
        try expect(DemoTypeController.typingDelayRangeForTesting(slider: 55) == 1...110, "Expected midpoint DemoType delay to match Windows speed +/- speed")
        try expect(DemoTypeController.typingDelayRangeForTesting(slider: 100) == 1...20, "Expected fastest DemoType delay range")
        try expect(DemoTypeController.typingDelayRangeForTesting(slider: 10) == 1...200, "Expected slowest DemoType delay range")
    }
    #endif

    #if !ZOOMIT_APP_STORE
    static func testDemoTypeUserDrivenStepStopsAtEnd() throws {
        let script = "ab[end]cd[end]"
        let first = DemoTypeController.userDrivenStepForTesting(script, offset: 0)
        try expect(first == DemoTypeController.UserDrivenStepResult(token: .text("a"), ended: false, nextOffset: 1), "Expected one user key to emit one DemoType token")

        let end = DemoTypeController.userDrivenStepForTesting(script, offset: 2)
        try expect(end == DemoTypeController.UserDrivenStepResult(token: .end, ended: true, nextOffset: 7), "Expected [end] to stop the active user-driven DemoType entry")

        try expect(DemoTypeController.completedUserDrivenEntryOffsetForTesting(script, startOffset: 7) == script.count, "Expected final [end] to leave DemoType at EOF instead of wrapping in the active entry")
        try expect(DemoTypeController.completedUserDrivenEntryOffsetForTesting("abc", startOffset: 0) == 0, "Expected scripts without [end] to wrap after EOF")
    }
    #endif

    static func testStaticZoomStaysAtOneX() throws {
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
    static func testBreakTimerBackgroundNotFlipped() throws {
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

    static func testPresentedWindowLifecycleOrdering() throws {
        var events: [String] = []
        OverlayPresentedWindowLifecycle.perform(
            prepareAccessories: {
                events.append("suppress accessories")
                events.append("lower overlay")
            },
            showSystemCursor: {
                events.append("show cursor")
            },
            present: {
                events.append("present")
            },
            restoreAccessories: {
                events.append("restore overlay")
                events.append("restore accessories")
            },
            reapplyCursorPolicy: {
                events.append("reapply cursor policy")
            }
        )
        try expect(
            events == [
                "suppress accessories",
                "lower overlay",
                "show cursor",
                "present",
                "restore overlay",
                "restore accessories",
                "reapply cursor policy"
            ],
            "Expected save presentation to show the cursor only after suppressing accessories, "
                + "then restore accessories before reapplying cursor policy"
        )
    }

    static func testOverlayRegionSnipTeardown() throws {
        let canvas = try makeCanvas(annotationController: AnnotationController())
        var completionCount = 0
        canvas.beginRegionSnip(action: .copyImage) {
            completionCount += 1
        }
        canvas.prepareForClose()
        canvas.prepareForClose()
        try expect(
            completionCount == 1,
            "Expected overlay close preparation to finish an active region snip exactly once"
        )

        canvas.beginRegionSnip(action: .saveImage) {
            completionCount += 1
        }
        canvas.prepareForClose()
        try expect(
            completionCount == 2,
            "Expected region snip state to clear so a later snip can finish independently"
        )
    }

    /// The break timer suppresses the screen saver by holding a display-sleep
    /// assertion. Verify the assertion is acquired once on begin, released on
    /// end, and that both operations are idempotent.
    static func testIdleSleepAssertionLifecycle() throws {
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
    static func testStatusMenuOrderMatchesWindows() throws {
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
    static func testClipTransitionUpdatesOnChange() throws {
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
    static func testWebcamOverlayDragOrigin() throws {
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
    static func testTrimSavePreservesOriginal() throws {
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
    static func testSettingsWindowStaysOnTop() throws {
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

    /// The Options dialog lists its panes in a sidebar, which needs a
    /// resolvable SF Symbol per pane. A typo'd symbol name yields a nil image
    /// and a silently blank icon, so check every pane.
    static func testSettingsPaneSymbolsResolve() throws {
        for title in SettingsWindowController.settingsTabTitles {
            let symbol = SettingsWindowController.paneSymbolName(for: title)
            try expect(
                NSImage(systemSymbolName: symbol, accessibilityDescription: nil) != nil,
                "Expected settings pane \"\(title)\" to have a resolvable SF Symbol, got \"\(symbol)\""
            )
        }
    }

    /// Windows keeps static-zoom and live-zoom settings on separate tabs (the
    /// Zoom tab is static-only). Verify the Mac Options dialog exposes a
    /// distinct "Live Zoom" tab immediately after "Zoom".
    static func testZoomAndLiveZoomAreSeparateTabs() throws {
        let titles = SettingsWindowController.settingsTabTitles
        guard let zoomIndex = titles.firstIndex(of: "Zoom") else {
            throw SelfTestError.failure("Expected a Zoom tab in the Options dialog")
        }
        try expect(titles.contains("Live Zoom"), "Expected a separate Live Zoom tab")
        try expect(titles.firstIndex(of: "Live Zoom") == zoomIndex + 1,
                   "Expected Live Zoom to be its own tab right after Zoom, got \(titles)")
    }

    static func testDistributionSpecificSettingsTabs() throws {
        let hasDemoType = SettingsWindowController.settingsTabTitles.contains("DemoType")
        try expect(
            hasDemoType != DistributionChannel.isAppStore,
            "Expected DemoType to be present only in the Homebrew settings surface"
        )
    }

    static func testModalActivationCommandGating() throws {
        let coordinator = ModeActivationCoordinator()
        guard let activation = coordinator.reserve(
            .liveZoom,
            expecting: .idle,
            currentMode: .idle
        ) else {
            throw SelfTestError.failure(
                "Expected Live Zoom startup to reserve modal ownership"
            )
        }

        let blockedCommands: [AppCommand] = [
            .activateStaticZoom,
            .activateLiveZoom,
            .activateDrawWithoutZoom,
            .snipRegion(save: false),
            .snipRegion(save: true),
            .snipOcr,
            .toggleBreakTimer,
            .startPanorama(save: false),
            .toggleDemoMirror(scope: .screen),
            .zoomIn,
            .zoomOutOrExit,
            .toggleTyping(rightAligned: false)
        ]
        for command in blockedCommands {
            try expect(
                coordinator.disposition(
                    for: command,
                    recordingIsActive: false
                ) == .block,
                "Expected \(command) to be blocked during Live Zoom startup"
            )
        }
        try expect(
            coordinator.disposition(
                for: .toggleRecording(region: false),
                recordingIsActive: false
            ) == .block,
            "Expected a new recording startup to be blocked while modal ownership is reserved"
        )
        try expect(
            coordinator.disposition(
                for: .toggleRecording(region: false),
                recordingIsActive: true
            ) == .allow,
            "Expected stopping an active recording to remain available during cancellable startup"
        )
        try expect(
            coordinator.disposition(
                for: .clear,
                recordingIsActive: false
            ) == .allow,
            "Expected non-activation drawing commands to remain independent"
        )
        try expect(
            coordinator.disposition(
                for: .exit,
                recordingIsActive: false
            ) == .cancelCurrent,
            "Expected Escape to invalidate cancellable Live Zoom startup"
        )
        try expect(
            coordinator.updateExpectedMode(
                for: activation,
                currentMode: .idle,
                to: .liveZoom
            )
                && coordinator.owns(activation, currentMode: .liveZoom)
                && coordinator.disposition(
                    for: .toggleBreakTimer,
                    recordingIsActive: false
                ) == .block,
            "Expected Live Zoom to retain activation ownership after presenting its startup overlay"
        )
    }

    static func testExternalRegionSelectorAccessoryPolicy() throws {
        for flow in ExternalRegionSelectorFlow.allCases {
            try expect(
                ExternalRegionSelectorAccessoryPolicy.shouldRestore(
                    flow: flow,
                    expectedMode: .drawOnly,
                    currentMode: .drawOnly,
                    isOverlayPresented: true
                ),
                "Expected \(flow) completion and cancellation to restore active drawing accessories"
            )
            try expect(
                ExternalRegionSelectorAccessoryPolicy.shouldRestore(
                    flow: flow,
                    expectedMode: .staticZoom,
                    currentMode: .staticZoom,
                    isOverlayPresented: true
                ),
                "Expected stale \(flow) selector teardown to restore when the overlay generation remains active"
            )
            try expect(
                !ExternalRegionSelectorAccessoryPolicy.shouldRestore(
                    flow: flow,
                    expectedMode: .drawOnly,
                    currentMode: .idle,
                    isOverlayPresented: false
                ),
                "Expected \(flow) teardown not to restore after the overlay exits"
            )
            try expect(
                !ExternalRegionSelectorAccessoryPolicy.shouldRestore(
                    flow: flow,
                    expectedMode: .drawOnly,
                    currentMode: .staticZoom,
                    isOverlayPresented: true
                ),
                "Expected \(flow) stale completion not to restore after a mode change"
            )
        }
    }

    static func testModalActivationBreakAndOcrRaces() throws {
        let coordinator = ModeActivationCoordinator()
        guard let liveActivation = coordinator.reserve(
            .liveZoom,
            expecting: .idle,
            currentMode: .idle
        ) else {
            throw SelfTestError.failure("Expected Live Zoom reservation")
        }
        try expect(
            coordinator.reserve(
                .breakTimer,
                expecting: .idle,
                currentMode: .idle
            ) == nil
                && coordinator.disposition(
                    for: .toggleBreakTimer,
                    recordingIsActive: false
                ) == .block,
            "Expected Break Timer to lose deterministically to in-flight Live Zoom"
        )

        _ = coordinator.cancelCurrent()
        guard let breakActivation = coordinator.reserve(
            .breakTimer,
            expecting: .idle,
            currentMode: .idle
        ) else {
            throw SelfTestError.failure(
                "Expected Break Timer to reserve after Live Zoom cancellation"
            )
        }
        var presentedMode = AppMode.idle
        guard coordinator.updateExpectedMode(
            for: breakActivation,
            currentMode: presentedMode,
            to: .breakTimer
        ) else {
            throw SelfTestError.failure(
                "Expected Break Timer to retain ownership through presentation"
            )
        }
        presentedMode = .breakTimer
        if coordinator.owns(liveActivation, currentMode: presentedMode) {
            presentedMode = .liveZoom
        }
        try expect(
            !coordinator.owns(liveActivation, currentMode: .idle)
                && coordinator.finish(liveActivation) == nil
                && coordinator.owns(
                    breakActivation,
                    currentMode: presentedMode
                )
                && presentedMode == .breakTimer,
            "Expected stale Live Zoom completion not to release or overwrite the presented Break Timer mode"
        )
        _ = coordinator.cancelCurrent()

        guard let firstSnip = coordinator.reserve(
            .snip,
            expecting: .idle,
            currentMode: .idle
        ) else {
            throw SelfTestError.failure("Expected OCR snip reservation")
        }
        try expect(
            coordinator.disposition(
                for: .snipRegion(save: false),
                recordingIsActive: false
            ) == .block
                && coordinator.disposition(
                    for: .snipOcr,
                    recordingIsActive: false
                ) == .block,
            "Expected region and OCR snip commands to share one activation gate"
        )
        _ = coordinator.cancelCurrent()
        guard let currentSnip = coordinator.reserve(
            .snip,
            expecting: .idle,
            currentMode: .idle
        ) else {
            throw SelfTestError.failure("Expected replacement OCR snip reservation")
        }
        try expect(
            coordinator.finish(firstSnip) == nil
                && coordinator.owns(currentSnip, currentMode: .idle),
            "Expected stale OCR capture completion not to clear a newer snip reservation"
        )
        _ = coordinator.finish(currentSnip)
    }

    static func testModalActivationStaleCompletionIsolation() async throws {
        let coordinator = ModeActivationCoordinator()
        let resources = LiveZoomActivationResources<
            ModeActivationCoordinator.Token,
            SelfTestLiveZoomActivationSession
        >()
        let staleSuccessGate = SelfTestAsyncGate()
        let staleSession = SelfTestLiveZoomActivationSession()
        guard let staleActivation = coordinator.reserve(
            .liveZoom,
            expecting: .idle,
            currentMode: .idle
        ), resources.begin(staleActivation) else {
            throw SelfTestError.failure(
                "Expected a stale Live Zoom activation reservation"
            )
        }
        try expect(
            resources.markOverlayPresented(for: staleActivation)
                && resources.attach(staleSession, to: staleActivation),
            "Expected the first activation to own its startup resources"
        )
        let staleSuccessTask = Task { @MainActor in
            try await staleSuccessGate.wait()
            let committed = coordinator.owns(
                staleActivation,
                currentMode: .idle
            ) && resources.commit(staleSession, for: staleActivation)
            if !committed {
                await staleSession.stop()
            }
            return committed
        }
        try await staleSuccessGate.waitUntilEntered()

        _ = coordinator.cancelCurrent()
        guard let staleCleanup = resources.finish(staleActivation) else {
            throw SelfTestError.failure(
                "Expected cancellation to detach stale Live Zoom resources"
            )
        }
        if let session = staleCleanup.session {
            await session.stop()
        }

        let currentSession = SelfTestLiveZoomActivationSession()
        guard let currentActivation = coordinator.reserve(
            .liveZoom,
            expecting: .idle,
            currentMode: .idle
        ), resources.begin(currentActivation) else {
            throw SelfTestError.failure(
                "Expected a newer Live Zoom activation after cancellation"
            )
        }
        _ = resources.markOverlayPresented(for: currentActivation)
        _ = resources.attach(currentSession, to: currentActivation)

        staleSuccessGate.open()
        let staleCommitted = try await withSelfTestTimeout(
            "stale Live Zoom completion"
        ) {
            try await staleSuccessTask.value
        }
        try expect(
            !staleCommitted
                && coordinator.owns(currentActivation, currentMode: .idle)
                && resources.isCurrent(currentActivation)
                && resources.session === currentSession
                && staleSession.stopCount >= 1
                && currentSession.stopCount == 0,
            "Expected stale completion to clean only its local session and preserve the newer owner"
        )
        _ = coordinator.finish(currentActivation)
        if let session = resources.cancel()?.session {
            await session.stop()
        }
    }

    static func testLiveZoomExitDuringStartup() async throws {
        let coordinator = ModeActivationCoordinator()
        let resources = LiveZoomActivationResources<
            ModeActivationCoordinator.Token,
            SelfTestLiveZoomActivationSession
        >()
        let startupGate = SelfTestAsyncGate()
        let session = SelfTestLiveZoomActivationSession()
        guard let activation = coordinator.reserve(
            .liveZoom,
            expecting: .idle,
            currentMode: .idle
        ), resources.begin(activation) else {
            throw SelfTestError.failure(
                "Expected an exit-during-startup reservation"
            )
        }
        _ = resources.markOverlayPresented(for: activation)
        _ = resources.attach(session, to: activation)
        let startupTask = Task { @MainActor in
            try await startupGate.wait()
            return coordinator.owns(
                activation,
                currentMode: .idle
            ) && resources.commit(session, for: activation)
        }
        try await startupGate.waitUntilEntered()

        try expect(
            coordinator.disposition(
                for: .exit,
                recordingIsActive: false
            ) == .cancelCurrent,
            "Expected Exit to cancel Live Zoom startup ownership"
        )
        _ = coordinator.cancelCurrent()
        guard let cancellation = resources.finish(activation) else {
            throw SelfTestError.failure(
                "Expected exit to detach the in-flight Live Zoom resources"
            )
        }
        if let ownedSession = cancellation.session {
            await ownedSession.stop()
        }

        try expect(
            cancellation.overlayPresented
                && !cancellation.wasActive
                && !resources.isStarting
                && !resources.isCurrent(activation)
                && resources.session == nil
                && session.stopCount == 1,
            "Expected exit during startup to invalidate ownership and stop its pending session"
        )

        startupGate.open()
        let startupCommitted = try await withSelfTestTimeout(
            "cancelled Live Zoom startup"
        ) {
            try await startupTask.value
        }
        try expect(
            !startupCommitted && session.stopCount == 1,
            "Expected cancelled startup completion not to publish or touch another mode"
        )
    }

    /// The blank-screen sketch pad is triggered with Ctrl+W / Ctrl+K while
    /// drawing (matching the corrected Draw-tab help), leaving plain W/K for the
    /// white/black pen and Shift+W/K for the highlighter.
    static func testBlankScreenUsesControlKeys() throws {
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
    static func testTypeTabFontSampleUsesSelectedFont() throws {
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
    static func testMenuBarIconIsPaddedTemplate() throws {
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
    static func testStandardIconIsRoundedSquareWithMargin() throws {
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
    static func testDefaultTypingFontIsSystem20pt() throws {
        try expect(AppSettings.defaults.typingFontName.isEmpty,
                   "Expected the default typing font name to be empty (the default Mac system font)")
        try expect(
            AppSettings.defaults.typingFontPreset == .system,
            "Expected the default typing font preset to use the native system font"
        )
        try expect(AppSettings.defaults.typingFontSize == 20,
                   "Expected the default typing font size to be 20pt, got \(AppSettings.defaults.typingFontSize)")
        try expect(AnnotationController.defaultFontSize == 20,
                   "Expected the annotation controller default font size to be 20pt")

        // An empty name resolves to the system font at the requested size.
        let resolved = AnnotationController.typingFont(named: "", size: 20)
        let system = NSFont.systemFont(ofSize: 20, weight: .regular)
        try expect(resolved.fontName == system.fontName,
                   "Expected the default typing font to resolve to the regular (non-bold) system font, got \(resolved.fontName)")
        try expect(resolved.pointSize == 20, "Expected the default typing font to be 20pt, got \(resolved.pointSize)")
    }

    static func testBreakTimerLayout() throws {
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
}
