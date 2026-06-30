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
    private static let contentWidth: CGFloat = 504
    private static let panelHorizontalInset: CGFloat = 28
    private static let wrappedLabelWidth: CGFloat = contentWidth - panelHorizontalInset * 2

    private var window: NSWindow?

    // Draw tab controls that need live updates.
    private weak var penWidthLabel: NSTextField?

    // Type tab controls.
    private weak var fontSampleLabel: NSTextField?

    // General tab controls.
    private weak var launchAtLoginCheckbox: NSButton?

    // Record tab controls.
    private weak var microphonePopup: NSPopUpButton?

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
        case panorama
    }
    private weak var hotKeyButton: NSButton?
    private weak var drawHotKeyButton: NSButton?
    private weak var liveHotKeyButton: NSButton?
    private weak var breakHotKeyButton: NSButton?
    private weak var snipHotKeyButton: NSButton?
    private weak var snipOcrHotKeyButton: NSButton?
    private weak var recordHotKeyButton: NSButton?
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
        panoramaHotKeyButton?.title = panoramaHotKeyDisplayString()
        launchAtLoginCheckbox?.state = settings.launchAtLogin ? .on : .off
        // Suspend the global hotkeys while the dialog is open so the user can
        // record a new shortcut without it firing; they resume on close.
        onSuspendHotkeys()
        NSApp.activate(ignoringOtherApps: true)
        window.center()
        window.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ notification: Notification) {
        // Cancel any in-progress recording and re-enable the global hotkeys.
        finishRecording()
        onResumeHotkeys()
    }

    // MARK: - Window construction

    private func makeWindow() -> NSWindow {
        // Build each tab's content and measure the tallest one so every tab can
        // share a single height. Equal-height tabs keep the tab view a constant
        // size, which in turn keeps the footer anchored near the bottom no
        // matter which tab is selected.
        let tabs: [(String, NSView)] = [
            ("General", makeGeneralTab()),
            ("Zoom", makeZoomTab()),
            ("Draw", makeDrawTab()),
            ("Type", makeTypeTab()),
            ("Break", makeBreakTab()),
            ("Snip", makeSnipTab()),
            ("Record", makeRecordTab()),
            ("Panorama", makePanoramaTab())
        ]

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

        // Size the window to fit the (now equal-height) tabs plus the footer.
        container.layoutSubtreeIfNeeded()
        let fitting = container.fittingSize
        window.setContentSize(NSSize(width: max(fitting.width, 480), height: max(fitting.height, 360)))
        return window
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

    private func makeRow(_ views: [NSView]) -> NSView {
        let stack = NSStackView(views: views)
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 8
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
        let hotKeyRow = makeRow([makeLabel("Zoom toggle:"), hotKeyButton])

        let liveHelp = makeLabel(
            "Live zoom magnifies the live screen so motion and updates stay visible while zoomed. Use the same zoom and pan controls.",
            wraps: true
        )

        let liveHotKeyButton = NSButton(title: liveHotKeyDisplayString(), target: self, action: #selector(toggleLiveHotKeyRecording(_:)))
        liveHotKeyButton.bezelStyle = .rounded
        liveHotKeyButton.setButtonType(.momentaryPushIn)
        liveHotKeyButton.widthAnchor.constraint(greaterThanOrEqualToConstant: 140).isActive = true
        self.liveHotKeyButton = liveHotKeyButton
        let liveHotKeyRow = makeRow([makeLabel("Live zoom toggle:"), liveHotKeyButton])

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

        let animateCheck = NSButton(checkboxWithTitle: "Animate zoom in and zoom out", target: self, action: #selector(animateZoomChanged(_:)))
        animateCheck.state = settings.animateZoom ? .on : .off

        let smoothCheck = NSButton(checkboxWithTitle: "Smooth zoomed image", target: self, action: #selector(smoothImageChanged(_:)))
        smoothCheck.state = settings.smoothImage ? .on : .off

        return makeColumn([help, hotKeyRow, liveHelp, liveHotKeyRow, magHelp, magRow, animateCheck, smoothCheck])
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
                conflictsWithBreak(code: newCode, modifiers: newModifiers) {
                NSSound.beep()
                return nil
            }
            settings.hotKeyCode = newCode
            settings.hotKeyModifiers = newModifiers
        case .draw:
            if conflictsWithZoom(code: newCode, modifiers: newModifiers) ||
                conflictsWithLive(code: newCode, modifiers: newModifiers) ||
                conflictsWithBreak(code: newCode, modifiers: newModifiers) {
                NSSound.beep()
                return nil
            }
            settings.drawHotKeyCode = newCode
            settings.drawHotKeyModifiers = newModifiers
        case .live:
            if conflictsWithZoom(code: newCode, modifiers: newModifiers) ||
                conflictsWithDraw(code: newCode, modifiers: newModifiers) ||
                conflictsWithBreak(code: newCode, modifiers: newModifiers) {
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
                conflictsWithBreak(code: newCode, modifiers: newModifiers) {
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
                conflictsWithSnip(code: newCode, modifiers: newModifiers) {
                NSSound.beep()
                return nil
            }
            settings.snipOcrHotKeyCode = newCode
            settings.snipOcrHotKeyModifiers = newModifiers
        case .record:
            if conflictsWithZoom(code: newCode, modifiers: newModifiers) ||
                conflictsWithDraw(code: newCode, modifiers: newModifiers) ||
                conflictsWithLive(code: newCode, modifiers: newModifiers) ||
                conflictsWithBreak(code: newCode, modifiers: newModifiers) {
                NSSound.beep()
                return nil
            }
            settings.recordHotKeyCode = newCode
            settings.recordHotKeyModifiers = newModifiers
        case .panorama:
            if conflictsWithZoom(code: newCode, modifiers: newModifiers) ||
                conflictsWithDraw(code: newCode, modifiers: newModifiers) ||
                conflictsWithLive(code: newCode, modifiers: newModifiers) ||
                conflictsWithBreak(code: newCode, modifiers: newModifiers) {
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

    private func conflictsWithPanorama(code: Int, modifiers: UInt) -> Bool {
        code == settings.panoramaHotKeyCode && modifiers == settings.panoramaHotKeyModifiers
    }

    private func finishRecording() {
        if let hotKeyMonitor {
            NSEvent.removeMonitor(hotKeyMonitor)
        }
        hotKeyMonitor = nil
        recordingTarget = nil
        hotKeyButton?.title = zoomHotKeyDisplayString()
        drawHotKeyButton?.title = drawHotKeyDisplayString()
        liveHotKeyButton?.title = liveHotKeyDisplayString()
        breakHotKeyButton?.title = breakHotKeyDisplayString()
        snipHotKeyButton?.title = snipHotKeyDisplayString()
        snipOcrHotKeyButton?.title = snipOcrHotKeyDisplayString()
        recordHotKeyButton?.title = recordHotKeyDisplayString()
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

    private func panoramaHotKeyDisplayString() -> String {
        Self.describe(keyCode: settings.panoramaHotKeyCode, modifiers: NSEvent.ModifierFlags(rawValue: settings.panoramaHotKeyModifiers))
    }

    // MARK: - Draw tab

    private func makeDrawTab() -> NSView {
        let help = makeLabel(
            """
            Once zoomed, enter drawing mode by pressing the left mouse button; exit drawing mode by pressing the right mouse button.

            Colors: press R, G, B, O, Y, P, W or K for red, green, blue, orange, yellow, pink, white or black. Hold Shift with a color key (for example Shift+R) to draw with a translucent highlighter of that color (50% opacity). Press the color key again without Shift to return to a solid pen.

            Shapes: hold Shift for a line, Control for a rectangle, Tab for an ellipse, or Shift+Control for an arrow while dragging.

            Pen: change the width with the mouse wheel, the [ and ] keys, or Shift with the up and down arrow keys. Undo the last drawing with Ctrl+Z and erase everything by pressing E.

            Screen: press W or K to blank the screen white or black as a sketch pad.
            """,
            wraps: true
        )

        let slider = NSSlider(value: Double(settings.rootPenWidth), minValue: 1, maxValue: 20, target: self, action: #selector(penWidthChanged(_:)))
        slider.translatesAutoresizingMaskIntoConstraints = false
        slider.numberOfTickMarks = 20
        slider.allowsTickMarkValuesOnly = true
        slider.widthAnchor.constraint(equalToConstant: 200).isActive = true

        let widthValue = makeLabel("\(Int(settings.rootPenWidth))")
        penWidthLabel = widthValue
        let widthRow = makeRow([makeLabel("Default pen width:"), slider, widthValue])

        let drawHotKeyButton = NSButton(title: drawHotKeyDisplayString(), target: self, action: #selector(toggleDrawHotKeyRecording(_:)))
        drawHotKeyButton.bezelStyle = .rounded
        drawHotKeyButton.setButtonType(.momentaryPushIn)
        drawHotKeyButton.widthAnchor.constraint(greaterThanOrEqualToConstant: 140).isActive = true
        self.drawHotKeyButton = drawHotKeyButton
        let drawHotKeyRow = makeRow([makeLabel("Draw w/out zoom:"), drawHotKeyButton])

        return makeColumn([help, drawHotKeyRow, widthRow])
    }

    @objc private func penWidthChanged(_ sender: NSSlider) {
        settings.rootPenWidth = CGFloat(sender.intValue)
        penWidthLabel?.stringValue = "\(sender.intValue)"
        persist()
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
        let timerRow = makeRow([makeLabel("Break timer:"), hotKeyButton, makeLabel("Duration:"), durationStepper, durationLabel])

        let expiredCheck = NSButton(checkboxWithTitle: "Show expired time after 0:00", target: self, action: #selector(breakShowExpiredChanged(_:)))
        expiredCheck.state = settings.breakShowExpiredTime ? .on : .off

        let textColorPopup = makeColorPopup(selected: settings.breakTextColorRGB, action: #selector(breakTextColorChanged(_:)))
        let backgroundColorPopup = makeColorPopup(selected: settings.breakBackgroundColorRGB, action: #selector(breakBackgroundColorChanged(_:)))
        let colorRow = makeRow([makeLabel("Timer color:"), textColorPopup, makeLabel("Background:"), backgroundColorPopup])

        let positionPopup = makeIndexedPopup(
            titles: ["Top-left", "Top", "Top-right", "Left", "Center", "Right", "Bottom-left", "Bottom", "Bottom-right"],
            selected: settings.breakTimerPosition,
            action: #selector(breakPositionChanged(_:))
        )
        positionPopup.widthAnchor.constraint(equalToConstant: 130).isActive = true
        let opacityPopup = NSPopUpButton(frame: .zero, pullsDown: false)
        opacityPopup.translatesAutoresizingMaskIntoConstraints = false
        for value in stride(from: 10, through: 100, by: 10) {
            opacityPopup.addItem(withTitle: "\(value)%")
            opacityPopup.lastItem?.representedObject = value
        }
        opacityPopup.selectItem(withTitle: "\(min(max(settings.breakOpacity, 10), 100))%")
        opacityPopup.target = self
        opacityPopup.action = #selector(breakOpacityChanged(_:))
        let layoutRow = makeRow([makeLabel("Position:"), positionPopup, makeLabel("Opacity:"), opacityPopup])

        let soundCheck = NSButton(checkboxWithTitle: "Play sound at 0:00", target: self, action: #selector(breakPlaySoundChanged(_:)))
        soundCheck.state = settings.breakPlaySound ? .on : .off
    let behaviorRow = makeRow([expiredCheck, soundCheck])
        let soundField = makePathField(settings.breakSoundFile)
        breakSoundFileField = soundField
        let soundBrowse = NSButton(title: "Browse…", target: self, action: #selector(chooseBreakSoundFile(_:)))
        soundBrowse.bezelStyle = .rounded
    let soundFileRow = makeRow([makeLabel("Sound:"), soundField, soundBrowse])

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
        let stretchCheck = NSButton(checkboxWithTitle: "Stretch image", target: self, action: #selector(breakBackgroundStretchChanged(_:)))
        stretchCheck.state = settings.breakBackgroundStretch ? .on : .off
        breakBackgroundStretchCheckbox = stretchCheck
        let backgroundModeRow = makeRow([makeLabel("Background:"), backgroundModePopup, stretchCheck])
        let backgroundFileRow = makeRow([makeLabel("Image file:"), backgroundField, backgroundBrowse])

        updateBreakBackgroundControlsEnabled()
        return makeColumn([
            help,
            timerRow,
            behaviorRow,
            colorRow,
            layoutRow,
            soundFileRow,
            backgroundModeRow,
            backgroundFileRow
        ], spacing: 8)
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
        let snipHotKeyRow = makeRow([makeLabel("Snip region:"), snipHotKeyButton])

        let snipOcrHotKeyButton = NSButton(title: snipOcrHotKeyDisplayString(), target: self, action: #selector(toggleSnipOcrHotKeyRecording(_:)))
        snipOcrHotKeyButton.bezelStyle = .rounded
        snipOcrHotKeyButton.setButtonType(.momentaryPushIn)
        snipOcrHotKeyButton.widthAnchor.constraint(greaterThanOrEqualToConstant: 140).isActive = true
        self.snipOcrHotKeyButton = snipOcrHotKeyButton
        let snipOcrHotKeyRow = makeRow([makeLabel("OCR region to text:"), snipOcrHotKeyButton])

        return makeColumn([help, snipHotKeyRow, snipOcrHotKeyRow])
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
        let recordHotKeyRow = makeRow([makeLabel("Record:"), recordHotKeyButton])

        let systemAudioCheck = NSButton(checkboxWithTitle: "Capture system audio", target: self, action: #selector(recordSystemAudioChanged(_:)))
        systemAudioCheck.state = settings.recordSystemAudio ? .on : .off

        let micCheck = NSButton(checkboxWithTitle: "Capture microphone", target: self, action: #selector(recordMicrophoneChanged(_:)))
        micCheck.state = settings.recordMicrophone ? .on : .off

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
        let micDeviceRow = makeRow([makeLabel("Device:"), micPopup])
        let micOptions = makeIndentedColumn([micDeviceRow])

        let trimButton = NSButton(title: "Trim…", target: self, action: #selector(openTrimEditor(_:)))
        trimButton.bezelStyle = .rounded
        let trimRow = makeRow([makeLabel("Edit existing video:"), trimButton])

        return makeColumn([help, recordHotKeyRow, systemAudioCheck, micCheck, micOptions, trimRow] + makeWebcamRows(), spacing: 10)
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
        let panoramaHotKeyRow = makeRow([makeLabel("Panorama:"), panoramaHotKeyButton])

        return makeColumn([help, panoramaHotKeyRow])
    }

    @objc private func recordSystemAudioChanged(_ sender: NSButton) {
        settings.recordSystemAudio = (sender.state == .on)
        persist()
    }

    @objc private func recordMicrophoneChanged(_ sender: NSButton) {
        settings.recordMicrophone = (sender.state == .on)
        microphonePopup?.isEnabled = settings.recordMicrophone
        persist()
        // Trigger the microphone permission prompt the first time it's enabled.
        if settings.recordMicrophone {
            onRequestMicrophone()
        }
    }

    @objc private func microphoneChanged(_ sender: NSPopUpButton) {
        settings.microphoneDeviceID = (sender.selectedItem?.representedObject as? String) ?? ""
        persist()
    }

    @objc private func openTrimEditor(_ sender: NSButton) {
        onOpenTrimEditor()
    }

    // MARK: - Webcam controls

    private func makeWebcamRows() -> [NSView] {
        let heading = makeLabel("Webcam overlay:")
        heading.font = NSFont.systemFont(ofSize: NSFont.systemFontSize, weight: .semibold)

        let enableCheck = NSButton(checkboxWithTitle: "Show webcam in recordings", target: self, action: #selector(webcamEnabledChanged(_:)))
        enableCheck.state = settings.webcamEnabled ? .on : .off

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

        let positionPopup = makeIndexedPopup(
            titles: ["Top-left", "Top-right", "Bottom-left", "Bottom-right"],
            selected: settings.webcamPosition,
            action: #selector(webcamPositionChanged(_:))
        )
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
        let webcamPlacementRow = makeRow([
            makeLabel("Camera:"), devicePopup,
            makeLabel("Position:"), positionPopup
        ])
        let webcamAppearanceRow = makeRow([
            makeLabel("Size:"), sizePopup,
            makeLabel("Shape:"), shapePopup
        ])

        updateWebcamControlsEnabled()
        return [webcamEnableRow, webcamPlacementRow, webcamAppearanceRow]
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
        settings.webcamPosition = sender.indexOfSelectedItem
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
        let font = currentTypingFont()
        fontSampleLabel?.font = NSFont.systemFont(ofSize: 18)
        fontSampleLabel?.stringValue = "Sample — \(font.displayName ?? font.fontName) \(Int(settings.typingFontSize))pt"
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
