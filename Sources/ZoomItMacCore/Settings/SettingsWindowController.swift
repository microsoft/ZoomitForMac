import AppKit
import UniformTypeIdentifiers

@MainActor
private final class SettingsWindow: NSWindow {
    override func cancelOperation(_ sender: Any?) {
        close()
    }
}

@MainActor
private final class LinkButton: NSButton {
    override func resetCursorRects() {
        super.resetCursorRects()
        addCursorRect(bounds, cursor: .pointingHand)
    }
}

/// A tabbed preferences window modeled on the Windows ZoomIt options dialog,
/// exposing the Zoom, Draw, and Type settings that ZoomIt supports. Each tab
/// carries the same kind of descriptive help text the Windows dialog shows.
@MainActor
final class SettingsWindowController: NSObject, NSWindowDelegate {
    private let settingsStore: SettingsStore
    private let onHotKeyChange: () -> Void
    private let onSuspendHotkeys: () -> Void
    private let onResumeHotkeys: () -> Void
    private let onRequestMicrophone: () -> Void
    private let onRequestCamera: () -> Void
    private let onOpenTrimEditor: () -> Void
    private var settings: AppSettings

    private static let homepageURLString = "http://www.sysinternals.com"
    private static let contentWidth: CGFloat = 620
    private static let panelHorizontalInset: CGFloat = 28
    private static let wrappedLabelWidth: CGFloat = contentWidth - panelHorizontalInset * 2

    private var window: NSWindow?

    // Type tab controls.
    private weak var fontSampleLabel: NSTextField?

    // General tab controls.
    private weak var launchAtLoginCheckbox: NSButton?

    // Record tab controls.
    private weak var microphonePopup: NSPopUpButton?
    private weak var noiseCancellationCheckbox: NSButton?

    // Snip tab controls.
    private weak var snipSaveDirectoryField: NSTextField?
    private weak var snipSaveDirectoryBrowseButton: NSButton?

    // DemoType tab controls.
    private weak var demoTypeFileField: NSTextField?

    // Webcam controls.
    private weak var webcamDevicePopup: NSPopUpButton?
    private weak var webcamPositionPopup: NSPopUpButton?
    private weak var webcamSizePopup: NSPopUpButton?
    private weak var webcamShapePopup: NSPopUpButton?

    // Break tab controls.
    private weak var breakDurationLabel: NSTextField?
    private weak var breakSoundFileField: NSTextField?
    private weak var breakBackgroundModePopup: NSPopUpButton?
    private weak var breakBackgroundFileField: NSTextField?
    private weak var breakBackgroundBrowseButton: NSButton?
    private weak var breakBackgroundStretchCheckbox: NSButton?

    // Hotkey recorders.
    private enum HotKeyTarget {
        case zoom
        case draw
        case live
        case breakTimer
        case snip
        case snipOcr
        case record
        case demoType
        case panorama
    }
    private weak var hotKeyButton: NSButton?
    private weak var drawHotKeyButton: NSButton?
    private weak var liveHotKeyButton: NSButton?
    private weak var breakHotKeyButton: NSButton?
    private weak var snipHotKeyButton: NSButton?
    private weak var snipOcrHotKeyButton: NSButton?
    private weak var recordHotKeyButton: NSButton?
    private weak var demoTypeHotKeyButton: NSButton?
    private weak var panoramaHotKeyButton: NSButton?
    private var hotKeyMonitor: Any?
    private var recordingTarget: HotKeyTarget?

    init(
        settingsStore: SettingsStore,
        onHotKeyChange: @escaping () -> Void,
        onSuspendHotkeys: @escaping () -> Void,
        onResumeHotkeys: @escaping () -> Void,
        onRequestMicrophone: @escaping () -> Void,
        onRequestCamera: @escaping () -> Void,
        onOpenTrimEditor: @escaping () -> Void
    ) {
        self.settingsStore = settingsStore
        self.onHotKeyChange = onHotKeyChange
        self.onSuspendHotkeys = onSuspendHotkeys
        self.onResumeHotkeys = onResumeHotkeys
        self.onRequestMicrophone = onRequestMicrophone
        self.onRequestCamera = onRequestCamera
        self.onOpenTrimEditor = onOpenTrimEditor
        self.settings = settingsStore.load()
        super.init()
    }

    func show() {
        // Always reflect the latest persisted values when re-opening.
        settings = settingsStore.load()

        if window == nil {
            window = makeWindow()
        }

        guard let window else { return }
        hotKeyButton?.title = zoomHotKeyDisplayString()
        drawHotKeyButton?.title = drawHotKeyDisplayString()
        liveHotKeyButton?.title = liveHotKeyDisplayString()
        breakHotKeyButton?.title = breakHotKeyDisplayString()
        snipHotKeyButton?.title = snipHotKeyDisplayString()
        snipOcrHotKeyButton?.title = snipOcrHotKeyDisplayString()
        recordHotKeyButton?.title = recordHotKeyDisplayString()
        demoTypeHotKeyButton?.title = demoTypeHotKeyDisplayString()
        panoramaHotKeyButton?.title = panoramaHotKeyDisplayString()
        launchAtLoginCheckbox?.state = settings.launchAtLogin ? .on : .off
        NSApp.activate(ignoringOtherApps: true)
        window.center()
        window.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ notification: Notification) {
        // Cancel any in-progress recording (which resumes the global hotkeys if
        // they were suspended for capture).
        finishRecording()
    }

    // MARK: - Window construction

    /// The Options dialog tabs, in order. Zoom and Live Zoom are separate tabs
    /// (matching Windows ZoomIt, whose Zoom tab holds static-zoom settings only).
    static let settingsTabTitles = [
        "General", "Zoom", "Live Zoom", "Draw", "Type",
        "DemoType", "Break", "Snip", "Record", "Panorama"
    ]

    private func viewForTab(_ title: String) -> NSView {
        switch title {
        case "General": return makeGeneralTab()
        case "Zoom": return makeZoomTab()
        case "Live Zoom": return makeLiveZoomTab()
        case "Draw": return makeDrawTab()
        case "Type": return makeTypeTab()
        case "DemoType": return makeDemoTypeTab()
        case "Break": return makeBreakTab()
        case "Snip": return makeSnipTab()
        case "Record": return makeRecordTab()
        case "Panorama": return makePanoramaTab()
        default: return NSView()
        }
    }

    private func makeWindow() -> NSWindow {
        // Build each tab's content and measure the tallest one so every tab can
        // share a single height. Equal-height tabs keep the tab view a constant
        // size, which in turn keeps the footer anchored near the bottom no
        // matter which tab is selected.
        let tabs: [(String, NSView)] = Self.settingsTabTitles.map { title in
            (title, viewForTab(title))
        }

        var maxContentHeight: CGFloat = 0
        for (_, content) in tabs {
            content.translatesAutoresizingMaskIntoConstraints = false
            let widthConstraint = content.widthAnchor.constraint(equalToConstant: Self.contentWidth)
            widthConstraint.isActive = true
            content.layoutSubtreeIfNeeded()
            maxContentHeight = max(maxContentHeight, content.fittingSize.height)
            widthConstraint.isActive = false
        }

        // Add only a small cushion beyond the tallest tab; the tab contents
        // already carry their own bottom inset.
        let tabContentHeight = maxContentHeight + 4

        let tabView = NSTabView()
        tabView.translatesAutoresizingMaskIntoConstraints = false
        for (label, content) in tabs {
            // The holder is frame-managed so NSTabView resizes it to fill the
            // content area; the content is pinned to the holder's top so every
            // tab shares the same top margin regardless of window position.
            let holder = NSView()
            holder.translatesAutoresizingMaskIntoConstraints = true
            holder.autoresizingMask = [.width, .height]
            holder.frame = NSRect(x: 0, y: 0, width: Self.contentWidth, height: tabContentHeight)
            content.translatesAutoresizingMaskIntoConstraints = false
            holder.addSubview(content)
            NSLayoutConstraint.activate([
                content.topAnchor.constraint(equalTo: holder.topAnchor),
                content.leadingAnchor.constraint(equalTo: holder.leadingAnchor),
                content.trailingAnchor.constraint(equalTo: holder.trailingAnchor)
            ])
            tabView.addTabViewItem(makeTabItem(label: label, view: holder))
        }

        // Fix the tab view's size so its content area is exactly
        // contentWidth × tabContentHeight on every tab. The chrome (tab strip and
        // borders) is measured from a probe frame.
        tabView.frame = NSRect(x: 0, y: 0, width: Self.contentWidth + 24, height: tabContentHeight + 60)
        tabView.layoutSubtreeIfNeeded()
        let measuredChromeWidth = tabView.frame.width - tabView.contentRect.width
        let measuredChromeHeight = tabView.frame.height - tabView.contentRect.height
        let chromeWidth = measuredChromeWidth > 0 ? measuredChromeWidth : 14
        let chromeHeight = measuredChromeHeight > 4 ? measuredChromeHeight : 34
        NSLayoutConstraint.activate([
            tabView.widthAnchor.constraint(equalToConstant: Self.contentWidth + chromeWidth),
            tabView.heightAnchor.constraint(equalToConstant: tabContentHeight + chromeHeight)
        ])

        let outer = NSStackView(views: [tabView, makeFooter()])
        outer.orientation = .vertical
        outer.alignment = .centerX
        outer.spacing = 12
        outer.edgeInsets = NSEdgeInsets(top: 16, left: 16, bottom: 12, right: 16)
        outer.translatesAutoresizingMaskIntoConstraints = false

        let container = NSView()
        container.addSubview(outer)
        NSLayoutConstraint.activate([
            outer.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            outer.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            outer.topAnchor.constraint(equalTo: container.topAnchor),
            outer.bottomAnchor.constraint(equalTo: container.bottomAnchor)
        ])

        let window = SettingsWindow(
            contentRect: NSRect(x: 0, y: 0, width: 480, height: 480),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "ZoomIt - Sysinternals: www.sysinternals.com"
        window.contentView = container
        window.isReleasedWhenClosed = false
        window.delegate = self
        Self.configureAlwaysOnTop(window)

        // Size the window to fit the (now equal-height) tabs plus the footer.
        container.layoutSubtreeIfNeeded()
        let fitting = container.fittingSize
        window.setContentSize(NSSize(width: max(fitting.width, 480), height: max(fitting.height, 360)))
        return window
    }

    /// Configures the settings window to behave like the Windows Options dialog:
    /// it floats above other windows so it can never get lost behind them. If it
    /// did, ZoomIt's hotkeys (suspended while the dialog is open) would stay
    /// suspended and the app would appear broken with no obvious way to recover.
    static func configureAlwaysOnTop(_ window: NSWindow) {
        window.level = .floating
        window.hidesOnDeactivate = false
    }

    private func makeTabItem(label: String, view: NSView) -> NSTabViewItem {
        let item = NSTabViewItem(identifier: label)
        item.label = label
        item.view = view
        return item
    }

    private func makeFooter() -> NSView {
        let title = makeLabel("\(AppInfo.productName) \(AppInfo.version)")
        title.font = NSFont.systemFont(ofSize: 11, weight: .semibold)
        title.textColor = .secondaryLabelColor
        title.alignment = .center

        let copyright = makeLabel(AppInfo.copyright)
        copyright.font = NSFont.systemFont(ofSize: 11)
        copyright.textColor = .secondaryLabelColor
        copyright.alignment = .center

        let link = makeLink(title: "www.sysinternals.com")

        let stack = NSStackView(views: [title, copyright, link])
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 2
        return stack
    }

    /// Builds a borderless button styled as a web hyperlink to the Sysinternals
    /// home page.
    private func makeLink(title: String) -> NSButton {
        let button = LinkButton(title: title, target: self, action: #selector(openHomepage(_:)))
        button.isBordered = false
        button.bezelStyle = .inline
        button.attributedTitle = NSAttributedString(
            string: title,
            attributes: [
                .foregroundColor: NSColor.linkColor,
                .underlineStyle: NSUnderlineStyle.single.rawValue,
                .font: NSFont.systemFont(ofSize: 11)
            ]
        )
        button.toolTip = SettingsWindowController.homepageURLString
        button.setAccessibilityRole(.link)
        return button
    }

    @objc private func openHomepage(_ sender: Any?) {
        guard let url = URL(string: SettingsWindowController.homepageURLString) else { return }
        NSWorkspace.shared.open(url)
    }

    private func makeColumn(_ rows: [NSView], spacing: CGFloat = 14) -> NSView {
        let stack = NSStackView(views: rows)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = spacing
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.edgeInsets = NSEdgeInsets(top: 8, left: Self.panelHorizontalInset, bottom: 12, right: Self.panelHorizontalInset)
        return stack
    }

    private func makeLabel(_ text: String, wraps: Bool = false) -> NSTextField {
        let field = NSTextField(labelWithString: text)
        field.translatesAutoresizingMaskIntoConstraints = false
        if wraps {
            field.lineBreakMode = .byWordWrapping
            field.maximumNumberOfLines = 0
            field.preferredMaxLayoutWidth = Self.wrappedLabelWidth
        }
        return field
    }

    private func makeSectionLabel(_ text: String) -> NSTextField {
        let field = makeLabel(text)
        field.font = NSFont.systemFont(ofSize: NSFont.systemFontSize, weight: .semibold)
        return field
    }

    private func makeRow(_ views: [NSView]) -> NSView {
        let stack = NSStackView(views: views)
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 8
        return stack
    }

    /// Creates a checkbox styled like the Windows ZoomIt options dialog, where
    /// the caption sits to the left of the box (BS_LEFTTEXT). Grouping several
    /// of these in a `makeCheckboxColumn` lines their boxes up in a single
    /// right-hand column, matching the Windows layout.
    private func makeCheckbox(_ title: String, action: Selector, state: Bool) -> NSButton {
        let button = NSButton(checkboxWithTitle: title, target: self, action: action)
        button.imagePosition = .imageRight
        button.state = state ? .on : .off
        return button
    }

    /// Stacks Windows-style checkboxes so their boxes align in a right-hand
    /// column, the way the ZoomIt options dialog aligns them.
    private func makeCheckboxColumn(_ checkboxes: [NSView], spacing: CGFloat = 6) -> NSView {
        let stack = NSStackView(views: checkboxes)
        stack.orientation = .vertical
        stack.alignment = .trailing
        stack.spacing = spacing
        return stack
    }

    private func makeIndentedColumn(_ rows: [NSView], indent: CGFloat = 18, spacing: CGFloat = 6) -> NSView {
        let stack = NSStackView(views: rows)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = spacing
        stack.edgeInsets = NSEdgeInsets(top: 0, left: indent, bottom: 0, right: 0)
        return stack
    }

    /// Lays out label/control rows in a grid so the leading labels form a
    /// right-aligned column and the controls line up in consistent columns.
    /// Rows may have differing numbers of cells; trailing cells are left empty.
    private func makeFormGrid(_ rows: [[NSView]], rowSpacing: CGFloat = 10, columnSpacing: CGFloat = 8) -> NSGridView {
        let grid = NSGridView(views: rows)
        grid.translatesAutoresizingMaskIntoConstraints = false
        grid.rowSpacing = rowSpacing
        grid.columnSpacing = columnSpacing
        // Center controls vertically within each row so labels line up with
        // popups, steppers and checkboxes regardless of their heights.
        grid.rowAlignment = .none
        for r in 0..<grid.numberOfRows {
            for c in 0..<grid.numberOfColumns {
                grid.cell(atColumnIndex: c, rowIndex: r).yPlacement = .center
            }
        }
        if grid.numberOfColumns > 0 {
            // Right-align the leading label column so the controls in column 1
            // share a common left edge.
            grid.column(at: 0).xPlacement = .trailing
        }
        return grid
    }

    // MARK: - General tab

    private func makeGeneralTab() -> NSView {
        let help = makeLabel(
            "ZoomIt runs in the menu bar. Use the Zoom and Draw tabs to set the keyboard shortcuts that activate it.",
            wraps: true
        )

        let launchCheck = NSButton(checkboxWithTitle: "Launch ZoomIt when I log in", target: self, action: #selector(toggleLaunchAtLogin(_:)))
        launchCheck.state = settings.launchAtLogin ? .on : .off
        launchCheck.isEnabled = LaunchAtLogin.isAvailable
        if !LaunchAtLogin.isAvailable {
            launchCheck.toolTip = "Launch at login requires running ZoomIt from ZoomIt.app."
        }
        launchAtLoginCheckbox = launchCheck

        return makeColumn([help, launchCheck])
    }

    @objc private func toggleLaunchAtLogin(_ sender: NSButton) {
        let enable = sender.state == .on
        settings.launchAtLogin = enable
        persist()
        do {
            try LaunchAtLogin.setEnabled(enable)
        } catch {
            let alert = NSAlert()
            alert.messageText = "Couldn’t update the login item"
            alert.informativeText = "ZoomIt saved your startup preference and will try again next launch. macOS reported: \(error.localizedDescription)"
            alert.addButton(withTitle: "OK")
            alert.runModal()
        }
    }

    // MARK: - Zoom tab

    private func makeZoomTab() -> NSView {
        let help = makeLabel(
            "After toggling ZoomIt you can zoom in and out with the mouse wheel or Option+Up and Option+Down, and pan by moving the mouse. Exit zoom mode with Escape or by pressing the right mouse button.",
            wraps: true
        )

        let hotKeyButton = NSButton(title: zoomHotKeyDisplayString(), target: self, action: #selector(toggleZoomHotKeyRecording(_:)))
        hotKeyButton.bezelStyle = .rounded
        hotKeyButton.setButtonType(.momentaryPushIn)
        hotKeyButton.widthAnchor.constraint(greaterThanOrEqualToConstant: 140).isActive = true
        self.hotKeyButton = hotKeyButton
        let hotKeyRow = makeRow([makeLabel("Zoom Toggle:"), hotKeyButton])

        let magHelp = makeLabel("Specify the initial level of magnification when zooming in:", wraps: true)

        let magPopup = NSPopUpButton(frame: .zero, pullsDown: false)
        magPopup.translatesAutoresizingMaskIntoConstraints = false
        for level in AppSettings.zoomLevels {
            magPopup.addItem(withTitle: String(format: "%gx", level))
        }
        let selectedIndex = AppSettings.zoomLevels.firstIndex(where: {
            abs($0 - settings.defaultZoomFactor) < 0.001
        }) ?? AppSettings.zoomLevels.firstIndex(of: 2.0) ?? 0
        magPopup.selectItem(at: selectedIndex)
        magPopup.target = self
        magPopup.action = #selector(zoomLevelChanged(_:))
        let magRow = makeRow([makeLabel("Initial magnification:"), magPopup])

        let animateCheck = makeCheckbox("Animate zoom in and zoom out:", action: #selector(animateZoomChanged(_:)), state: settings.animateZoom)
        let smoothCheck = makeCheckbox("Smooth zoomed image:", action: #selector(smoothImageChanged(_:)), state: settings.smoothImage)

        return makeColumn([help, hotKeyRow, magHelp, magRow, makeCheckboxColumn([animateCheck, smoothCheck])])
    }

    // MARK: - Live Zoom tab

    /// Live zoom lives on its own tab so the Zoom tab holds only static-zoom
    /// settings, matching the Windows ZoomIt options dialog.
    private func makeLiveZoomTab() -> NSView {
        let liveHelp = makeLabel(
            "Live zoom magnifies the live screen so motion and updates stay visible while zoomed. Use the same zoom and pan controls.",
            wraps: true
        )

        let liveHotKeyButton = NSButton(title: liveHotKeyDisplayString(), target: self, action: #selector(toggleLiveHotKeyRecording(_:)))
        liveHotKeyButton.bezelStyle = .rounded
        liveHotKeyButton.setButtonType(.momentaryPushIn)
        liveHotKeyButton.widthAnchor.constraint(greaterThanOrEqualToConstant: 140).isActive = true
        self.liveHotKeyButton = liveHotKeyButton
        let liveHotKeyRow = makeRow([makeLabel("LiveZoom Toggle:"), liveHotKeyButton])

        return makeColumn([liveHelp, liveHotKeyRow])
    }

    @objc private func zoomLevelChanged(_ sender: NSPopUpButton) {
        let index = sender.indexOfSelectedItem
        guard AppSettings.zoomLevels.indices.contains(index) else { return }
        settings.defaultZoomFactor = AppSettings.zoomLevels[index]
        persist()
    }

    @objc private func animateZoomChanged(_ sender: NSButton) {
        settings.animateZoom = (sender.state == .on)
        persist()
    }

    @objc private func smoothImageChanged(_ sender: NSButton) {
        settings.smoothImage = (sender.state == .on)
        persist()
    }

    // MARK: - Hotkey recorder

    @objc private func toggleZoomHotKeyRecording(_ sender: NSButton) {
        beginRecording(target: .zoom, sender: sender)
    }

    @objc private func toggleDrawHotKeyRecording(_ sender: NSButton) {
        beginRecording(target: .draw, sender: sender)
    }

    @objc private func toggleLiveHotKeyRecording(_ sender: NSButton) {
        beginRecording(target: .live, sender: sender)
    }

    @objc private func toggleBreakHotKeyRecording(_ sender: NSButton) {
        beginRecording(target: .breakTimer, sender: sender)
    }

    @objc private func toggleSnipHotKeyRecording(_ sender: NSButton) {
        beginRecording(target: .snip, sender: sender)
    }

    @objc private func toggleSnipOcrHotKeyRecording(_ sender: NSButton) {
        beginRecording(target: .snipOcr, sender: sender)
    }

    @objc private func toggleRecordHotKeyRecording(_ sender: NSButton) {
        beginRecording(target: .record, sender: sender)
    }

    @objc private func toggleDemoTypeHotKeyRecording(_ sender: NSButton) {
        beginRecording(target: .demoType, sender: sender)
    }

    @objc private func togglePanoramaHotKeyRecording(_ sender: NSButton) {
        beginRecording(target: .panorama, sender: sender)
    }

    private func beginRecording(target: HotKeyTarget, sender: NSButton) {
        if recordingTarget != nil {
            // A recording is already in progress; clicking any recorder stops it.
            finishRecording()
            return
        }
        recordingTarget = target
        // Suspend the global hotkeys only while actively capturing a shortcut so
        // the pressed keys are recorded instead of triggering their action. They
        // resume as soon as recording finishes, so shortcuts like the Zoom toggle
        // keep working while the Settings dialog is merely open (issue #22).
        onSuspendHotkeys()
        sender.title = "Type shortcut… (Esc cancels)"
        hotKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown]) { [weak self] event in
            guard let self else { return event }
            return self.captureHotKey(event)
        }
    }

    private func captureHotKey(_ event: NSEvent) -> NSEvent? {
        if event.keyCode == 53 { // Escape cancels recording.
            finishRecording()
            return nil
        }

        let modifiers = event.modifierFlags.intersection([.command, .control, .option, .shift])
        guard !modifiers.isEmpty else {
            // A global hotkey needs at least one modifier.
            NSSound.beep()
            return nil
        }

        let newCode = Int(event.keyCode)
        let newModifiers = modifiers.rawValue

        switch recordingTarget {
        case .zoom:
            // Reject a shortcut already assigned to another ZoomIt hotkey.
            if conflictsWithDraw(code: newCode, modifiers: newModifiers) ||
                conflictsWithLive(code: newCode, modifiers: newModifiers) ||
                conflictsWithBreak(code: newCode, modifiers: newModifiers) ||
                conflictsWithDemoType(code: newCode, modifiers: newModifiers) {
                NSSound.beep()
                return nil
            }
            settings.hotKeyCode = newCode
            settings.hotKeyModifiers = newModifiers
        case .draw:
            if conflictsWithZoom(code: newCode, modifiers: newModifiers) ||
                conflictsWithLive(code: newCode, modifiers: newModifiers) ||
                conflictsWithBreak(code: newCode, modifiers: newModifiers) ||
                conflictsWithDemoType(code: newCode, modifiers: newModifiers) {
                NSSound.beep()
                return nil
            }
            settings.drawHotKeyCode = newCode
            settings.drawHotKeyModifiers = newModifiers
        case .live:
            if conflictsWithZoom(code: newCode, modifiers: newModifiers) ||
                conflictsWithDraw(code: newCode, modifiers: newModifiers) ||
                conflictsWithBreak(code: newCode, modifiers: newModifiers) ||
                conflictsWithDemoType(code: newCode, modifiers: newModifiers) {
                NSSound.beep()
                return nil
            }
            settings.liveHotKeyCode = newCode
            settings.liveHotKeyModifiers = newModifiers
        case .breakTimer:
            if conflictsWithZoom(code: newCode, modifiers: newModifiers) ||
                conflictsWithDraw(code: newCode, modifiers: newModifiers) ||
                conflictsWithLive(code: newCode, modifiers: newModifiers) ||
                conflictsWithSnip(code: newCode, modifiers: newModifiers) ||
                conflictsWithRecord(code: newCode, modifiers: newModifiers) ||
                conflictsWithDemoType(code: newCode, modifiers: newModifiers) ||
                conflictsWithPanorama(code: newCode, modifiers: newModifiers) {
                NSSound.beep()
                return nil
            }
            settings.breakHotKeyCode = newCode
            settings.breakHotKeyModifiers = newModifiers
        case .snip:
            if conflictsWithZoom(code: newCode, modifiers: newModifiers) ||
                conflictsWithDraw(code: newCode, modifiers: newModifiers) ||
                conflictsWithLive(code: newCode, modifiers: newModifiers) ||
                conflictsWithBreak(code: newCode, modifiers: newModifiers) ||
                conflictsWithDemoType(code: newCode, modifiers: newModifiers) {
                NSSound.beep()
                return nil
            }
            settings.snipHotKeyCode = newCode
            settings.snipHotKeyModifiers = newModifiers
        case .snipOcr:
            if conflictsWithZoom(code: newCode, modifiers: newModifiers) ||
                conflictsWithDraw(code: newCode, modifiers: newModifiers) ||
                conflictsWithLive(code: newCode, modifiers: newModifiers) ||
                conflictsWithBreak(code: newCode, modifiers: newModifiers) ||
                conflictsWithSnip(code: newCode, modifiers: newModifiers) ||
                conflictsWithDemoType(code: newCode, modifiers: newModifiers) {
                NSSound.beep()
                return nil
            }
            settings.snipOcrHotKeyCode = newCode
            settings.snipOcrHotKeyModifiers = newModifiers
        case .record:
            if conflictsWithZoom(code: newCode, modifiers: newModifiers) ||
                conflictsWithDraw(code: newCode, modifiers: newModifiers) ||
                conflictsWithLive(code: newCode, modifiers: newModifiers) ||
                conflictsWithBreak(code: newCode, modifiers: newModifiers) ||
                conflictsWithDemoType(code: newCode, modifiers: newModifiers) {
                NSSound.beep()
                return nil
            }
            settings.recordHotKeyCode = newCode
            settings.recordHotKeyModifiers = newModifiers
        case .demoType:
            if conflictsWithZoom(code: newCode, modifiers: newModifiers) ||
                conflictsWithDraw(code: newCode, modifiers: newModifiers) ||
                conflictsWithLive(code: newCode, modifiers: newModifiers) ||
                conflictsWithBreak(code: newCode, modifiers: newModifiers) ||
                conflictsWithSnip(code: newCode, modifiers: newModifiers) ||
                conflictsWithSnipOcr(code: newCode, modifiers: newModifiers) ||
                conflictsWithRecord(code: newCode, modifiers: newModifiers) ||
                conflictsWithPanorama(code: newCode, modifiers: newModifiers) {
                NSSound.beep()
                return nil
            }
            settings.demoTypeHotKeyCode = newCode
            settings.demoTypeHotKeyModifiers = newModifiers
        case .panorama:
            if conflictsWithZoom(code: newCode, modifiers: newModifiers) ||
                conflictsWithDraw(code: newCode, modifiers: newModifiers) ||
                conflictsWithLive(code: newCode, modifiers: newModifiers) ||
                conflictsWithBreak(code: newCode, modifiers: newModifiers) ||
                conflictsWithDemoType(code: newCode, modifiers: newModifiers) {
                NSSound.beep()
                return nil
            }
            settings.panoramaHotKeyCode = newCode
            settings.panoramaHotKeyModifiers = newModifiers
        case nil:
            return nil
        }
        persist()
        finishRecording()
        onHotKeyChange()
        return nil
    }

    private func conflictsWithZoom(code: Int, modifiers: UInt) -> Bool {
        code == settings.hotKeyCode && modifiers == settings.hotKeyModifiers
    }

    private func conflictsWithDraw(code: Int, modifiers: UInt) -> Bool {
        code == settings.drawHotKeyCode && modifiers == settings.drawHotKeyModifiers
    }

    private func conflictsWithLive(code: Int, modifiers: UInt) -> Bool {
        code == settings.liveHotKeyCode && modifiers == settings.liveHotKeyModifiers
    }

    private func conflictsWithBreak(code: Int, modifiers: UInt) -> Bool {
        code == settings.breakHotKeyCode && modifiers == settings.breakHotKeyModifiers
    }

    private func conflictsWithSnip(code: Int, modifiers: UInt) -> Bool {
        code == settings.snipHotKeyCode && modifiers == settings.snipHotKeyModifiers
    }

    private func conflictsWithSnipOcr(code: Int, modifiers: UInt) -> Bool {
        settings.snipOcrHotKeyCode != 0 &&
            code == settings.snipOcrHotKeyCode && modifiers == settings.snipOcrHotKeyModifiers
    }

    private func conflictsWithRecord(code: Int, modifiers: UInt) -> Bool {
        code == settings.recordHotKeyCode && modifiers == settings.recordHotKeyModifiers
    }

    private func conflictsWithDemoType(code: Int, modifiers: UInt) -> Bool {
        settings.demoTypeHotKeyCode != 0 &&
            code == settings.demoTypeHotKeyCode && modifiers == settings.demoTypeHotKeyModifiers
    }

    private func conflictsWithPanorama(code: Int, modifiers: UInt) -> Bool {
        code == settings.panoramaHotKeyCode && modifiers == settings.panoramaHotKeyModifiers
    }

    private func finishRecording() {
        // Resume the global hotkeys only if a capture was actually in progress,
        // keeping the suspend/resume balanced no matter how recording ends
        // (successful capture, Esc, toggling the button, or window close).
        let wasRecording = recordingTarget != nil
        if let hotKeyMonitor {
            NSEvent.removeMonitor(hotKeyMonitor)
        }
        hotKeyMonitor = nil
        recordingTarget = nil
        if wasRecording {
            onResumeHotkeys()
        }
        hotKeyButton?.title = zoomHotKeyDisplayString()
        drawHotKeyButton?.title = drawHotKeyDisplayString()
        liveHotKeyButton?.title = liveHotKeyDisplayString()
        breakHotKeyButton?.title = breakHotKeyDisplayString()
        snipHotKeyButton?.title = snipHotKeyDisplayString()
        snipOcrHotKeyButton?.title = snipOcrHotKeyDisplayString()
        recordHotKeyButton?.title = recordHotKeyDisplayString()
        demoTypeHotKeyButton?.title = demoTypeHotKeyDisplayString()
        panoramaHotKeyButton?.title = panoramaHotKeyDisplayString()
    }

    private func zoomHotKeyDisplayString() -> String {
        Self.describe(keyCode: settings.hotKeyCode, modifiers: NSEvent.ModifierFlags(rawValue: settings.hotKeyModifiers))
    }

    private func drawHotKeyDisplayString() -> String {
        Self.describe(keyCode: settings.drawHotKeyCode, modifiers: NSEvent.ModifierFlags(rawValue: settings.drawHotKeyModifiers))
    }

    private func liveHotKeyDisplayString() -> String {
        Self.describe(keyCode: settings.liveHotKeyCode, modifiers: NSEvent.ModifierFlags(rawValue: settings.liveHotKeyModifiers))
    }

    private func breakHotKeyDisplayString() -> String {
        Self.describe(keyCode: settings.breakHotKeyCode, modifiers: NSEvent.ModifierFlags(rawValue: settings.breakHotKeyModifiers))
    }

    private func snipHotKeyDisplayString() -> String {
        Self.describe(keyCode: settings.snipHotKeyCode, modifiers: NSEvent.ModifierFlags(rawValue: settings.snipHotKeyModifiers))
    }

    private func snipOcrHotKeyDisplayString() -> String {
        guard settings.snipOcrHotKeyCode != 0 else { return "None" }
        return Self.describe(keyCode: settings.snipOcrHotKeyCode, modifiers: NSEvent.ModifierFlags(rawValue: settings.snipOcrHotKeyModifiers))
    }

    private func recordHotKeyDisplayString() -> String {
        Self.describe(keyCode: settings.recordHotKeyCode, modifiers: NSEvent.ModifierFlags(rawValue: settings.recordHotKeyModifiers))
    }

    private func demoTypeHotKeyDisplayString() -> String {
        guard settings.demoTypeHotKeyCode != 0 else { return "None" }
        return Self.describe(keyCode: settings.demoTypeHotKeyCode, modifiers: NSEvent.ModifierFlags(rawValue: settings.demoTypeHotKeyModifiers))
    }

    private func panoramaHotKeyDisplayString() -> String {
        Self.describe(keyCode: settings.panoramaHotKeyCode, modifiers: NSEvent.ModifierFlags(rawValue: settings.panoramaHotKeyModifiers))
    }

    // MARK: - Draw tab

    private func makeDrawTab() -> NSView {
        let help = makeLabel(
            "Once zoomed, enter drawing mode by pressing the left mouse button; exit drawing mode by pressing the right mouse button. Undo with Command-Z or Ctrl+Z and erase all drawing by pressing E.",
            wraps: true
        )

        let penSection = makeSectionLabel("Pen Control")
        let penHelp = makeLabel(
            "Change the pen width with the mouse wheel, the [ and ] keys, or Shift with the up and down arrow keys.",
            wraps: true
        )

        let colorsSection = makeSectionLabel("Colors")
        let colorsHelp = makeLabel(
            "Change the pen color by pressing R, G, B, O, Y, P, W or K for red, green, blue, orange, yellow, pink, white or black.",
            wraps: true
        )

        let highlightSection = makeSectionLabel("Highlight")
        let highlightHelp = makeLabel(
            "Hold Shift with a color key, for example Shift+R, to draw with a translucent highlighter of that color. Press the color key again without Shift to return to a solid pen.",
            wraps: true
        )

        let shapesSection = makeSectionLabel("Shapes")
        let shapesHelp = makeLabel(
            "Hold Shift for a line, Control for a rectangle, Tab for an ellipse, or Shift+Control for an arrow while dragging.",
            wraps: true
        )

        let screenSection = makeSectionLabel("Screen")
        let screenHelp = makeLabel(
            "Press Ctrl+W or Ctrl+K to blank the screen white or black as a sketch pad.",
            wraps: true
        )

        let drawHotKeyButton = NSButton(title: drawHotKeyDisplayString(), target: self, action: #selector(toggleDrawHotKeyRecording(_:)))
        drawHotKeyButton.bezelStyle = .rounded
        drawHotKeyButton.setButtonType(.momentaryPushIn)
        drawHotKeyButton.widthAnchor.constraint(greaterThanOrEqualToConstant: 140).isActive = true
        self.drawHotKeyButton = drawHotKeyButton
        let drawHotKeyRow = makeRow([makeLabel("Draw w/out Zoom:"), drawHotKeyButton])

        return makeColumn([
            help,
            penSection,
            makeIndentedColumn([penHelp]),
            colorsSection,
            makeIndentedColumn([colorsHelp]),
            highlightSection,
            makeIndentedColumn([highlightHelp]),
            shapesSection,
            makeIndentedColumn([shapesHelp]),
            screenSection,
            makeIndentedColumn([screenHelp]),
            drawHotKeyRow
        ], spacing: 6)
    }

    // MARK: - Type tab

    private func makeTypeTab() -> NSView {
        let help = makeLabel(
            """
            Once in drawing mode, press T to enter typing mode or Shift+T to enter typing mode with right-aligned input. Exit typing mode by pressing Escape or the left mouse button. Use the mouse wheel or the up and down arrow keys to change the font size.

            The text color is the current drawing color.
            """,
            wraps: true
        )

        let sample = makeLabel("")
        fontSampleLabel = sample
        updateFontSample()

        let fontButton = NSButton(title: "Select Font…", target: self, action: #selector(selectFont(_:)))
        fontButton.bezelStyle = .rounded

        let fontRow = makeRow([makeLabel("Typing font:"), fontButton])

        return makeColumn([help, fontRow, sample])
    }

    // MARK: - Break tab

    private func makeBreakTab() -> NSView {
        let help = makeLabel(
            "Press the break timer shortcut to show a full-screen countdown. Use the arrow keys or mouse wheel to adjust time, color keys to change timer color, and Escape or right-click to exit.",
            wraps: true
        )

        let hotKeyButton = NSButton(title: breakHotKeyDisplayString(), target: self, action: #selector(toggleBreakHotKeyRecording(_:)))
        hotKeyButton.bezelStyle = .rounded
        hotKeyButton.setButtonType(.momentaryPushIn)
        hotKeyButton.widthAnchor.constraint(greaterThanOrEqualToConstant: 140).isActive = true
        breakHotKeyButton = hotKeyButton

        let durationStepper = NSStepper()
        durationStepper.minValue = 1
        durationStepper.maxValue = 99
        durationStepper.integerValue = settings.breakDurationMinutes
        durationStepper.increment = 1
        durationStepper.target = self
        durationStepper.action = #selector(breakDurationChanged(_:))
        let durationLabel = makeLabel("")
        breakDurationLabel = durationLabel
        updateBreakDurationLabel()
        let durationControls = makeRow([durationStepper, durationLabel])

        let expiredCheck = makeCheckbox("Show Time Elapsed After Expiration:", action: #selector(breakShowExpiredChanged(_:)), state: settings.breakShowExpiredTime)

        let textColorPopup = makeColorPopup(selected: settings.breakTextColorRGB, action: #selector(breakTextColorChanged(_:)))
        let backgroundColorPopup = makeColorPopup(selected: settings.breakBackgroundColorRGB, action: #selector(breakBackgroundColorChanged(_:)))

        let positionPopup = makeIndexedPopup(
            titles: ["Top-left", "Top", "Top-right", "Left", "Center", "Right", "Bottom-left", "Bottom", "Bottom-right"],
            selected: settings.breakTimerPosition,
            action: #selector(breakPositionChanged(_:))
        )
        positionPopup.widthAnchor.constraint(equalToConstant: 150).isActive = true
        let opacityPopup = NSPopUpButton(frame: .zero, pullsDown: false)
        opacityPopup.translatesAutoresizingMaskIntoConstraints = false
        for value in stride(from: 10, through: 100, by: 10) {
            opacityPopup.addItem(withTitle: "\(value)%")
            opacityPopup.lastItem?.representedObject = value
        }
        opacityPopup.selectItem(withTitle: "\(min(max(settings.breakOpacity, 10), 100))%")
        opacityPopup.target = self
        opacityPopup.action = #selector(breakOpacityChanged(_:))

        let soundCheck = makeCheckbox("Play Sound on Expiration:", action: #selector(breakPlaySoundChanged(_:)), state: settings.breakPlaySound)
        let soundField = makePathField(settings.breakSoundFile)
        breakSoundFileField = soundField
        let soundBrowse = NSButton(title: "Browse…", target: self, action: #selector(chooseBreakSoundFile(_:)))
        soundBrowse.bezelStyle = .rounded

        let backgroundModePopup = makeIndexedPopup(
            titles: ["No image", "Faded desktop", "Image file"],
            selected: settings.breakBackgroundMode,
            action: #selector(breakBackgroundModeChanged(_:))
        )
        breakBackgroundModePopup = backgroundModePopup
        backgroundModePopup.widthAnchor.constraint(equalToConstant: 150).isActive = true
        let backgroundField = makePathField(settings.breakBackgroundFile)
        breakBackgroundFileField = backgroundField
        let backgroundBrowse = NSButton(title: "Browse…", target: self, action: #selector(chooseBreakBackgroundFile(_:)))
        backgroundBrowse.bezelStyle = .rounded
        breakBackgroundBrowseButton = backgroundBrowse
        let stretchCheck = makeCheckbox("Scale to screen:", action: #selector(breakBackgroundStretchChanged(_:)), state: settings.breakBackgroundStretch)
        breakBackgroundStretchCheckbox = stretchCheck

        // A single grid keeps every label/control pair in aligned columns:
        // column 0 = right-aligned labels, column 1 = primary control,
        // column 2 = secondary label, column 3 = secondary control.
        let grid = makeFormGrid([
            [makeLabel("Start Timer:"), hotKeyButton, makeLabel("Duration:"), durationControls],
            [makeLabel("Timer color:"), textColorPopup, makeLabel("Background:"), backgroundColorPopup],
            [makeLabel("Position:"), positionPopup, makeLabel("Opacity:"), opacityPopup],
            [makeLabel("Backdrop:"), backgroundModePopup, stretchCheck],
            [makeLabel("Image file:"), backgroundField, backgroundBrowse],
            [makeLabel("Sound:"), soundField, soundBrowse]
        ])

        updateBreakBackgroundControlsEnabled()
        return makeColumn([
            help,
            grid,
            makeCheckboxColumn([expiredCheck, soundCheck])
        ], spacing: 12)
    }

    private func updateBreakDurationLabel() {
        breakDurationLabel?.stringValue = "\(settings.breakDurationMinutes) minutes"
    }

    private func makePathField(_ path: String) -> NSTextField {
        let field = NSTextField(labelWithString: path.isEmpty ? "No file selected" : path)
        field.translatesAutoresizingMaskIntoConstraints = false
        field.lineBreakMode = .byTruncatingMiddle
        field.widthAnchor.constraint(equalToConstant: 220).isActive = true
        return field
    }

    private func makeColorPopup(selected: UInt32, action: Selector) -> NSPopUpButton {
        let popup = NSPopUpButton(frame: .zero, pullsDown: false)
        popup.translatesAutoresizingMaskIntoConstraints = false
        for option in Self.breakColorOptions {
            popup.addItem(withTitle: option.name)
            popup.lastItem?.representedObject = Int(option.rgb)
        }
        let selectedIndex = Self.breakColorOptions.firstIndex { $0.rgb == selected } ?? 0
        popup.selectItem(at: selectedIndex)
        popup.target = self
        popup.action = action
        return popup
    }

    private func updateBreakBackgroundControlsEnabled() {
        let usesImageFile = settings.breakBackgroundMode == 2
        breakBackgroundFileField?.isEnabled = usesImageFile
        breakBackgroundBrowseButton?.isEnabled = usesImageFile
        breakBackgroundStretchCheckbox?.isEnabled = usesImageFile
    }

    @objc private func breakDurationChanged(_ sender: NSStepper) {
        settings.breakDurationMinutes = min(max(sender.integerValue, 1), 99)
        updateBreakDurationLabel()
        persist()
    }

    @objc private func breakShowExpiredChanged(_ sender: NSButton) {
        settings.breakShowExpiredTime = sender.state == .on
        persist()
    }

    @objc private func breakTextColorChanged(_ sender: NSPopUpButton) {
        settings.breakTextColorRGB = UInt32((sender.selectedItem?.representedObject as? Int) ?? Int(settings.breakTextColorRGB))
        persist()
    }

    @objc private func breakBackgroundColorChanged(_ sender: NSPopUpButton) {
        settings.breakBackgroundColorRGB = UInt32((sender.selectedItem?.representedObject as? Int) ?? Int(settings.breakBackgroundColorRGB))
        persist()
    }

    @objc private func breakPositionChanged(_ sender: NSPopUpButton) {
        settings.breakTimerPosition = sender.indexOfSelectedItem
        persist()
    }

    @objc private func breakOpacityChanged(_ sender: NSPopUpButton) {
        settings.breakOpacity = (sender.selectedItem?.representedObject as? Int) ?? settings.breakOpacity
        persist()
    }

    @objc private func breakPlaySoundChanged(_ sender: NSButton) {
        settings.breakPlaySound = sender.state == .on
        persist()
    }

    @objc private func chooseBreakSoundFile(_ sender: NSButton) {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [.audio]
        panel.title = "ZoomIt: Specify Sound File"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        settings.breakSoundFile = url.path
        breakSoundFileField?.stringValue = url.path
        persist()
    }

    @objc private func breakBackgroundModeChanged(_ sender: NSPopUpButton) {
        settings.breakBackgroundMode = sender.indexOfSelectedItem
        updateBreakBackgroundControlsEnabled()
        persist()
    }

    @objc private func chooseBreakBackgroundFile(_ sender: NSButton) {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [.image]
        panel.title = "ZoomIt: Specify Background File"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        settings.breakBackgroundFile = url.path
        breakBackgroundFileField?.stringValue = url.path
        persist()
    }

    @objc private func breakBackgroundStretchChanged(_ sender: NSButton) {
        settings.breakBackgroundStretch = sender.state == .on
        persist()
    }

    private static let breakColorOptions: [(name: String, rgb: UInt32)] = [
        ("Red", 0xFF0000),
        ("Green", 0x00FF00),
        ("Blue", 0x0000FF),
        ("Orange", 0xFFA500),
        ("Yellow", 0xFFFF00),
        ("Pink", 0xFF69B4),
        ("White", 0xFFFFFF),
        ("Black", 0x000000)
    ]

    // MARK: - Snip tab

    private func makeSnipTab() -> NSView {
        let help = makeLabel(
            """
            While zoomed, press Command+S to save the entire viewport to a file or Command+C to copy it to the clipboard.

            To capture part of the screen at any time, press the snip shortcut and drag a rectangle. Releasing the drag copies the selected region to the clipboard. Hold Shift with the shortcut to save the region to a file instead. Press Escape to cancel.

            The OCR shortcut works the same way, but recognizes the text in the selected region and copies that text to the clipboard.

            Saved images are PNG files named with the current date and time.
            """,
            wraps: true
        )

        let snipHotKeyButton = NSButton(title: snipHotKeyDisplayString(), target: self, action: #selector(toggleSnipHotKeyRecording(_:)))
        snipHotKeyButton.bezelStyle = .rounded
        snipHotKeyButton.setButtonType(.momentaryPushIn)
        snipHotKeyButton.widthAnchor.constraint(greaterThanOrEqualToConstant: 140).isActive = true
        self.snipHotKeyButton = snipHotKeyButton
        let snipHotKeyRow = makeRow([makeLabel("Snip Toggle:"), snipHotKeyButton])

        let snipOcrHotKeyButton = NSButton(title: snipOcrHotKeyDisplayString(), target: self, action: #selector(toggleSnipOcrHotKeyRecording(_:)))
        snipOcrHotKeyButton.bezelStyle = .rounded
        snipOcrHotKeyButton.setButtonType(.momentaryPushIn)
        snipOcrHotKeyButton.widthAnchor.constraint(greaterThanOrEqualToConstant: 140).isActive = true
        self.snipOcrHotKeyButton = snipOcrHotKeyButton
        let snipOcrHotKeyRow = makeRow([makeLabel("Text Toggle:"), snipOcrHotKeyButton])

        let copyOnSaveCheck = makeCheckbox(
            "Also copy to clipboard when saving to a file:",
            action: #selector(copySnipToClipboardOnSaveChanged(_:)),
            state: settings.copySnipToClipboardOnSave
        )

        let saveToDirectoryCheck = makeCheckbox(
            "Save to a folder instead of asking each time:",
            action: #selector(saveSnipToDirectoryChanged(_:)),
            state: settings.saveSnipToDirectory
        )

        let directoryField = NSTextField(labelWithString: snipSaveDirectoryDisplayPath())
        directoryField.translatesAutoresizingMaskIntoConstraints = false
        directoryField.lineBreakMode = .byTruncatingMiddle
        directoryField.widthAnchor.constraint(equalToConstant: 380).isActive = true
        snipSaveDirectoryField = directoryField
        let directoryBrowse = NSButton(title: "Browse…", target: self, action: #selector(chooseSnipSaveDirectory(_:)))
        directoryBrowse.bezelStyle = .rounded
        snipSaveDirectoryBrowseButton = directoryBrowse
        let directoryRow = makeIndentedColumn([makeRow([makeLabel("Folder:"), directoryField, directoryBrowse])])

        updateSnipSaveDirectoryControlsEnabled()

        return makeColumn([help, snipHotKeyRow, snipOcrHotKeyRow, makeCheckboxColumn([copyOnSaveCheck, saveToDirectoryCheck]), directoryRow])
    }

    private func snipSaveDirectoryDisplayPath() -> String {
        if settings.snipSaveDirectory.trimmingCharacters(in: .whitespaces).isEmpty {
            return ImageExporter.defaultSaveDirectory().path
        }
        return settings.snipSaveDirectory
    }

    private func updateSnipSaveDirectoryControlsEnabled() {
        snipSaveDirectoryField?.isEnabled = settings.saveSnipToDirectory
        snipSaveDirectoryBrowseButton?.isEnabled = settings.saveSnipToDirectory
    }

    @objc private func copySnipToClipboardOnSaveChanged(_ sender: NSButton) {
        settings.copySnipToClipboardOnSave = (sender.state == .on)
        persist()
    }

    @objc private func saveSnipToDirectoryChanged(_ sender: NSButton) {
        settings.saveSnipToDirectory = (sender.state == .on)
        updateSnipSaveDirectoryControlsEnabled()
        persist()
    }

    @objc private func chooseSnipSaveDirectory(_ sender: NSButton) {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "Choose"
        panel.title = "ZoomIt: Choose Snip Folder"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        settings.snipSaveDirectory = url.path
        snipSaveDirectoryField?.stringValue = url.path
        persist()
    }

    // MARK: - Record tab

    private func makeRecordTab() -> NSView {
        let help = makeLabel(
            """
            Press the record shortcut to record the whole screen to an MP4 file; hold Shift with the shortcut to drag a rectangle and record just that region. Press the shortcut again to stop, then choose where to save the recording.

            Enable system audio to capture what you hear, and choose a microphone to also record your voice. Microphone recording requires the bundled app and microphone permission.
            """,
            wraps: true
        )

        let recordHotKeyButton = NSButton(title: recordHotKeyDisplayString(), target: self, action: #selector(toggleRecordHotKeyRecording(_:)))
        recordHotKeyButton.bezelStyle = .rounded
        recordHotKeyButton.setButtonType(.momentaryPushIn)
        recordHotKeyButton.widthAnchor.constraint(greaterThanOrEqualToConstant: 140).isActive = true
        self.recordHotKeyButton = recordHotKeyButton
        let recordHotKeyRow = makeRow([makeLabel("Record Toggle:"), recordHotKeyButton])

        let systemAudioCheck = makeCheckbox("Capture system audio:", action: #selector(recordSystemAudioChanged(_:)), state: settings.recordSystemAudio)

        let micCheck = makeCheckbox("Capture audio input:", action: #selector(recordMicrophoneChanged(_:)), state: settings.recordMicrophone)

        let windNoiseCheck = makeCheckbox("Noise cancellation:", action: #selector(recordNoiseCancellationChanged(_:)), state: settings.recordNoiseCancellation)
        noiseCancellationCheckbox = windNoiseCheck

        let micPopup = NSPopUpButton(frame: .zero, pullsDown: false)
        micPopup.translatesAutoresizingMaskIntoConstraints = false
        let microphones = AudioDevices.availableMicrophones()
        var selectedIndex = 0
        for (index, device) in microphones.enumerated() {
            micPopup.addItem(withTitle: device.name)
            micPopup.lastItem?.representedObject = device.id
            if device.id == settings.microphoneDeviceID {
                selectedIndex = index
            }
        }
        micPopup.selectItem(at: selectedIndex)
        micPopup.target = self
        micPopup.action = #selector(microphoneChanged(_:))
        micPopup.isEnabled = settings.recordMicrophone
        micPopup.widthAnchor.constraint(equalToConstant: 220).isActive = true
        microphonePopup = micPopup
        let micDeviceRow = makeRow([makeLabel("Microphone:"), micPopup])
        let micOptions = makeIndentedColumn([windNoiseCheck, micDeviceRow])
        updateMicrophoneOptionControls()

        let trimButton = NSButton(title: "Trim…", target: self, action: #selector(openTrimEditor(_:)))
        trimButton.bezelStyle = .rounded
        let trimRow = makeRow([makeLabel("Edit existing video:"), trimButton])

        return makeColumn([help, recordHotKeyRow, makeCheckboxColumn([systemAudioCheck, micCheck]), micOptions] + makeWebcamRows() + [trimRow], spacing: 10)
    }

    // MARK: - Panorama tab

    private func makePanoramaTab() -> NSView {
        let help = makeLabel(
            """
            Press the panorama shortcut and drag a rectangle over scrollable content (for example a long web page or document). ZoomIt then captures the region repeatedly while you scroll.

            Scroll smoothly in one direction — vertically or horizontally — and press the shortcut again to finish. The captured frames are aligned and stitched into a single tall (or wide) image.

            The base shortcut copies the stitched panorama to the clipboard; hold Shift with the shortcut to save it to a PNG file instead.
            """,
            wraps: true
        )

        let panoramaHotKeyButton = NSButton(title: panoramaHotKeyDisplayString(), target: self, action: #selector(togglePanoramaHotKeyRecording(_:)))
        panoramaHotKeyButton.bezelStyle = .rounded
        panoramaHotKeyButton.setButtonType(.momentaryPushIn)
        panoramaHotKeyButton.widthAnchor.constraint(greaterThanOrEqualToConstant: 140).isActive = true
        self.panoramaHotKeyButton = panoramaHotKeyButton
        let panoramaHotKeyRow = makeRow([makeLabel("Panorama Toggle:"), panoramaHotKeyButton])

        return makeColumn([help, panoramaHotKeyRow])
    }

    @objc private func recordSystemAudioChanged(_ sender: NSButton) {
        settings.recordSystemAudio = (sender.state == .on)
        persist()
    }

    @objc private func recordMicrophoneChanged(_ sender: NSButton) {
        settings.recordMicrophone = (sender.state == .on)
        updateMicrophoneOptionControls()
        persist()
        // Trigger the microphone permission prompt the first time it's enabled.
        if settings.recordMicrophone {
            onRequestMicrophone()
        }
    }

    @objc private func microphoneChanged(_ sender: NSPopUpButton) {
        settings.microphoneDeviceID = (sender.selectedItem?.representedObject as? String) ?? ""
        updateMicrophoneOptionControls()
        persist()
    }

    @objc private func recordNoiseCancellationChanged(_ sender: NSButton) {
        settings.recordNoiseCancellation = (sender.state == .on)
        persist()
    }

    private func updateMicrophoneOptionControls() {
        microphonePopup?.isEnabled = settings.recordMicrophone
        let supported = settings.recordMicrophone && AudioDevices.supportsWindNoiseRemoval(deviceID: settings.microphoneDeviceID)
        noiseCancellationCheckbox?.title = supported ? "Noise cancellation:" : "Noise cancellation (not supported by selected microphone):"
        noiseCancellationCheckbox?.isEnabled = supported
        noiseCancellationCheckbox?.state = (settings.recordNoiseCancellation && supported) ? .on : .off
        noiseCancellationCheckbox?.toolTip = supported
            ? "Uses AVFoundation wind noise removal for the selected microphone."
            : "Wind noise removal requires macOS 15 and a microphone that supports it."
    }

    @objc private func openTrimEditor(_ sender: NSButton) {
        onOpenTrimEditor()
    }

    // MARK: - Webcam controls

    private func makeWebcamRows() -> [NSView] {
        let heading = makeLabel("Webcam overlay:")
        heading.font = NSFont.systemFont(ofSize: NSFont.systemFontSize, weight: .semibold)

        let enableCheck = makeCheckbox("", action: #selector(webcamEnabledChanged(_:)), state: settings.webcamEnabled)

        let devicePopup = NSPopUpButton(frame: .zero, pullsDown: false)
        devicePopup.translatesAutoresizingMaskIntoConstraints = false
        var selectedDevice = 0
        for (index, camera) in VideoDevices.availableCameras().enumerated() {
            devicePopup.addItem(withTitle: camera.name)
            devicePopup.lastItem?.representedObject = camera.id
            if camera.id == settings.webcamDeviceID { selectedDevice = index }
        }
        devicePopup.selectItem(at: selectedDevice)
        devicePopup.target = self
        devicePopup.action = #selector(webcamDeviceChanged(_:))
        webcamDevicePopup = devicePopup

        let positionPopup = NSPopUpButton(frame: .zero, pullsDown: false)
        positionPopup.translatesAutoresizingMaskIntoConstraints = false
        for item in [
            ("Top-left", 0),
            ("Top-right", 1),
            ("Center", 4),
            ("Bottom-left", 2),
            ("Bottom-right", 3)
        ] {
            positionPopup.addItem(withTitle: item.0)
            positionPopup.lastItem?.representedObject = item.1
            if item.1 == settings.webcamPosition {
                positionPopup.select(positionPopup.lastItem)
            }
        }
        positionPopup.target = self
        positionPopup.action = #selector(webcamPositionChanged(_:))
        webcamPositionPopup = positionPopup

        let sizePopup = makeIndexedPopup(
            titles: ["Small", "Medium", "Large", "X-Large", "Full screen"],
            selected: settings.webcamSize,
            action: #selector(webcamSizeChanged(_:))
        )
        webcamSizePopup = sizePopup

        let shapePopup = makeIndexedPopup(
            titles: ["Rectangle", "Rounded rectangle", "Rounded square", "Circle"],
            selected: settings.webcamShape,
            action: #selector(webcamShapeChanged(_:))
        )
        webcamShapePopup = shapePopup

        devicePopup.widthAnchor.constraint(equalToConstant: 185).isActive = true
        positionPopup.widthAnchor.constraint(equalToConstant: 120).isActive = true
        sizePopup.widthAnchor.constraint(equalToConstant: 115).isActive = true
        shapePopup.widthAnchor.constraint(equalToConstant: 165).isActive = true

        let webcamEnableRow = makeRow([heading, enableCheck])
        // A grid keeps the two placement/appearance columns aligned so the
        // Position and Shape labels (and their popups) line up vertically.
        let webcamGrid = makeFormGrid([
            [makeLabel("Camera:"), devicePopup, makeLabel("Position:"), positionPopup],
            [makeLabel("Size:"), sizePopup, makeLabel("Shape:"), shapePopup]
        ])

        updateWebcamControlsEnabled()
        return [webcamEnableRow, webcamGrid]
    }

    /// Builds a popup whose item indices map directly to a settings integer.
    private func makeIndexedPopup(titles: [String], selected: Int, action: Selector) -> NSPopUpButton {
        let popup = NSPopUpButton(frame: .zero, pullsDown: false)
        popup.translatesAutoresizingMaskIntoConstraints = false
        for title in titles {
            popup.addItem(withTitle: title)
        }
        popup.selectItem(at: min(max(selected, 0), titles.count - 1))
        popup.target = self
        popup.action = action
        return popup
    }

    private func updateWebcamControlsEnabled() {
        let enabled = settings.webcamEnabled
        webcamDevicePopup?.isEnabled = enabled
        webcamPositionPopup?.isEnabled = enabled
        webcamSizePopup?.isEnabled = enabled
        // Shape doesn't apply to full screen.
        webcamShapePopup?.isEnabled = enabled && settings.webcamSize != 4
    }

    @objc private func webcamEnabledChanged(_ sender: NSButton) {
        settings.webcamEnabled = (sender.state == .on)
        updateWebcamControlsEnabled()
        persist()
        if settings.webcamEnabled {
            onRequestCamera()
        }
    }

    @objc private func webcamDeviceChanged(_ sender: NSPopUpButton) {
        settings.webcamDeviceID = (sender.selectedItem?.representedObject as? String) ?? ""
        persist()
    }

    @objc private func webcamPositionChanged(_ sender: NSPopUpButton) {
        settings.webcamPosition = (sender.selectedItem?.representedObject as? Int) ?? 3
        persist()
    }

    @objc private func webcamSizeChanged(_ sender: NSPopUpButton) {
        settings.webcamSize = sender.indexOfSelectedItem
        updateWebcamControlsEnabled()
        persist()
    }

    @objc private func webcamShapeChanged(_ sender: NSPopUpButton) {
        settings.webcamShape = sender.indexOfSelectedItem
        persist()
    }

    private func currentTypingFont() -> NSFont {
        AnnotationController.typingFont(named: settings.typingFontName, size: settings.typingFontSize)
    }

    private func updateFontSample() {
        let font = Self.fontSamplePreviewFont(name: settings.typingFontName, size: settings.typingFontSize)
        // Render the sample in the actually-selected font so choosing a new font
        // is reflected immediately (it previously always used the system font).
        fontSampleLabel?.font = font
        fontSampleLabel?.stringValue = "Sample — \(font.displayName ?? font.fontName) \(Int(settings.typingFontSize))pt"
    }

    /// Font used for the Type tab's live "Sample" preview. Uses the selected
    /// typing font, clamped to a legible on-screen preview size.
    static func fontSamplePreviewFont(name: String, size: CGFloat) -> NSFont {
        let previewSize = min(max(size, 12), 36)
        return AnnotationController.typingFont(named: name, size: previewSize)
    }

    @objc private func selectFont(_ sender: NSButton) {
        let manager = NSFontManager.shared
        manager.target = self
        manager.action = #selector(changeFont(_:))
        manager.setSelectedFont(currentTypingFont(), isMultiple: false)
        guard let window else { return }
        window.makeFirstResponder(window)
        manager.orderFrontFontPanel(sender)
    }

    @objc func changeFont(_ sender: Any?) {
        let manager = sender as? NSFontManager ?? NSFontManager.shared
        let newFont = manager.convert(currentTypingFont())
        settings.typingFontName = newFont.fontName
        settings.typingFontSize = newFont.pointSize
        updateFontSample()
        persist()
    }

    // MARK: - DemoType tab

    private func makeDemoTypeTab() -> NSView {
        let help = makeLabel(
            "DemoType has ZoomIt type text specified in the input file when you enter the DemoType toggle. Simply separate snippets with the [end] keyword, or you can insert text from the clipboard if it is prefixed with the [start].",
            wraps: true
        )

        let controlsHelp = makeLabel(
            """
            - Insert pauses with the [pause:n] keyword where 'n' is seconds.
            - Send text via the clipboard with [paste] and [/paste].
            - Send keystrokes with [enter], [up], [down], [left], and [right].

            You can have ZoomIt send text automatically, or select the option to drive input with typing. When driving input, your key releases advance the script. Press Escape to stop.

            When you reach the end of the file, ZoomIt reloads the file and starts at the beginning. Enter the hotkey with Shift toggled to step back to the last [end].
            """,
            wraps: true
        )

        let demoTypeHotKeyButton = NSButton(title: demoTypeHotKeyDisplayString(), target: self, action: #selector(toggleDemoTypeHotKeyRecording(_:)))
        demoTypeHotKeyButton.bezelStyle = .rounded
        demoTypeHotKeyButton.setButtonType(.momentaryPushIn)
        demoTypeHotKeyButton.widthAnchor.constraint(greaterThanOrEqualToConstant: 140).isActive = true
        self.demoTypeHotKeyButton = demoTypeHotKeyButton
        let hotKeyRow = makeRow([makeLabel("DemoType toggle:"), demoTypeHotKeyButton])

        let fileField = makePathField(settings.demoTypeFile)
        demoTypeFileField = fileField
        let browseButton = NSButton(title: "...", target: self, action: #selector(chooseDemoTypeFile(_:)))
        browseButton.bezelStyle = .rounded
        let fileRow = makeRow([makeLabel("Input file:"), fileField, browseButton])

        let speedSlider = NSSlider(value: Double(min(max(settings.demoTypeSpeed, 10), 100)), minValue: 10, maxValue: 100, target: self, action: #selector(demoTypeSpeedChanged(_:)))
        speedSlider.translatesAutoresizingMaskIntoConstraints = false
        speedSlider.widthAnchor.constraint(equalToConstant: 240).isActive = true
        let speedRow = makeRow([makeLabel("DemoType typing speed:"), makeLabel("Slow"), speedSlider, makeLabel("Fast")])

        let userDrivenCheck = makeCheckbox("Drive input with typing:", action: #selector(demoTypeUserDrivenChanged(_:)), state: settings.demoTypeUserDriven)

        return makeColumn([help, controlsHelp, hotKeyRow, fileRow, speedRow, userDrivenCheck], spacing: 8)
    }

    @objc private func chooseDemoTypeFile(_ sender: NSButton) {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.title = "ZoomIt: Specify DemoType File"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        settings.demoTypeFile = url.path
        demoTypeFileField?.stringValue = url.path
        persist()
    }

    @objc private func demoTypeSpeedChanged(_ sender: NSSlider) {
        settings.demoTypeSpeed = min(max(sender.integerValue, 10), 100)
        persist()
    }

    @objc private func demoTypeUserDrivenChanged(_ sender: NSButton) {
        settings.demoTypeUserDriven = sender.state == .on
        persist()
    }

    // MARK: - Persistence

    private func persist() {
        settingsStore.save(settings)
    }

    // MARK: - Key formatting

    static func describe(keyCode: Int, modifiers: NSEvent.ModifierFlags) -> String {
        var result = ""
        if modifiers.contains(.control) { result += "⌃" }
        if modifiers.contains(.option) { result += "⌥" }
        if modifiers.contains(.shift) { result += "⇧" }
        if modifiers.contains(.command) { result += "⌘" }
        result += keyName(forKeyCode: keyCode)
        return result
    }

    private static func keyName(forKeyCode code: Int) -> String {
        keyNames[code] ?? "Key \(code)"
    }

    private static let keyNames: [Int: String] = [
        0: "A", 1: "S", 2: "D", 3: "F", 4: "H", 5: "G", 6: "Z", 7: "X", 8: "C",
        9: "V", 11: "B", 12: "Q", 13: "W", 14: "E", 15: "R", 16: "Y", 17: "T",
        18: "1", 19: "2", 20: "3", 21: "4", 22: "6", 23: "5", 24: "=", 25: "9",
        26: "7", 27: "-", 28: "8", 29: "0", 30: "]", 31: "O", 32: "U", 33: "[",
        34: "I", 35: "P", 36: "Return", 37: "L", 38: "J", 39: "'", 40: "K",
        41: ";", 42: "\\", 43: ",", 44: "/", 45: "N", 46: "M", 47: ".",
        48: "Tab", 49: "Space", 50: "`", 51: "Delete", 53: "Escape",
        123: "←", 124: "→", 125: "↓", 126: "↑"
    ]
}
