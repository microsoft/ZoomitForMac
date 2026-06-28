import AppKit

/// A tabbed preferences window modeled on the Windows ZoomIt options dialog,
/// exposing the Zoom, Draw, and Type settings that ZoomIt supports. Each tab
/// carries the same kind of descriptive help text the Windows dialog shows.
@MainActor
final class SettingsWindowController: NSObject, NSWindowDelegate {
    private let settingsStore: SettingsStore
    private let onHotKeyChange: () -> Void
    private let onSuspendHotkeys: () -> Void
    private let onResumeHotkeys: () -> Void
    private var settings: AppSettings

    private static let homepageURLString = "http://www.sysinternals.com"

    private var window: NSWindow?

    // Draw tab controls that need live updates.
    private weak var penWidthLabel: NSTextField?

    // Type tab controls.
    private weak var fontSampleLabel: NSTextField?

    // General tab controls.
    private weak var launchAtLoginCheckbox: NSButton?

    // Hotkey recorders.
    private enum HotKeyTarget {
        case zoom
        case draw
        case live
    }
    private weak var hotKeyButton: NSButton?
    private weak var drawHotKeyButton: NSButton?
    private weak var liveHotKeyButton: NSButton?
    private var hotKeyMonitor: Any?
    private var recordingTarget: HotKeyTarget?

    init(
        settingsStore: SettingsStore,
        onHotKeyChange: @escaping () -> Void,
        onSuspendHotkeys: @escaping () -> Void,
        onResumeHotkeys: @escaping () -> Void
    ) {
        self.settingsStore = settingsStore
        self.onHotKeyChange = onHotKeyChange
        self.onSuspendHotkeys = onSuspendHotkeys
        self.onResumeHotkeys = onResumeHotkeys
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
        launchAtLoginCheckbox?.state = LaunchAtLogin.isEnabled ? .on : .off
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
        let contentWidth: CGFloat = 452
        let tabs: [(String, NSView)] = [
            ("General", makeGeneralTab()),
            ("Zoom", makeZoomTab()),
            ("Draw", makeDrawTab()),
            ("Type", makeTypeTab())
        ]

        var maxContentHeight: CGFloat = 0
        for (_, content) in tabs {
            content.translatesAutoresizingMaskIntoConstraints = false
            let widthConstraint = content.widthAnchor.constraint(equalToConstant: contentWidth)
            widthConstraint.isActive = true
            content.layoutSubtreeIfNeeded()
            maxContentHeight = max(maxContentHeight, content.fittingSize.height)
            widthConstraint.isActive = false
        }

        let tabView = NSTabView()
        tabView.translatesAutoresizingMaskIntoConstraints = false
        for (label, content) in tabs {
            // Pin the content to the top of a fixed-height holder so shorter
            // tabs leave empty space at the bottom rather than centering.
            let holder = NSView()
            holder.translatesAutoresizingMaskIntoConstraints = false
            content.translatesAutoresizingMaskIntoConstraints = false
            holder.addSubview(content)
            NSLayoutConstraint.activate([
                content.topAnchor.constraint(equalTo: holder.topAnchor),
                content.leadingAnchor.constraint(equalTo: holder.leadingAnchor),
                content.trailingAnchor.constraint(equalTo: holder.trailingAnchor),
                holder.heightAnchor.constraint(equalToConstant: maxContentHeight)
            ])
            tabView.addTabViewItem(makeTabItem(label: label, view: holder))
        }

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

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 480, height: 480),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "ZoomIt Settings"
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
        let button = NSButton(title: title, target: self, action: #selector(openHomepage(_:)))
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

    private func makeColumn(_ rows: [NSView]) -> NSView {
        let stack = NSStackView(views: rows)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 14
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.edgeInsets = NSEdgeInsets(top: 8, left: 16, bottom: 24, right: 16)
        return stack
    }

    private func makeLabel(_ text: String, wraps: Bool = false) -> NSTextField {
        let field = NSTextField(labelWithString: text)
        field.translatesAutoresizingMaskIntoConstraints = false
        if wraps {
            field.lineBreakMode = .byWordWrapping
            field.maximumNumberOfLines = 0
            field.preferredMaxLayoutWidth = 420
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

    // MARK: - General tab

    private func makeGeneralTab() -> NSView {
        let help = makeLabel(
            "ZoomIt runs in the menu bar. Use the Zoom and Draw tabs to set the keyboard shortcuts that activate it.",
            wraps: true
        )

        let launchCheck = NSButton(checkboxWithTitle: "Launch ZoomIt when I log in", target: self, action: #selector(toggleLaunchAtLogin(_:)))
        launchCheck.state = LaunchAtLogin.isEnabled ? .on : .off
        launchAtLoginCheckbox = launchCheck

        return makeColumn([help, launchCheck])
    }

    @objc private func toggleLaunchAtLogin(_ sender: NSButton) {
        let enable = sender.state == .on
        do {
            try LaunchAtLogin.setEnabled(enable)
        } catch {
            // Revert the checkbox and explain why it could not be changed.
            sender.state = enable ? .off : .on
            let alert = NSAlert()
            alert.messageText = "Couldn’t update the login item"
            alert.informativeText = error.localizedDescription
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
                conflictsWithLive(code: newCode, modifiers: newModifiers) {
                NSSound.beep()
                return nil
            }
            settings.hotKeyCode = newCode
            settings.hotKeyModifiers = newModifiers
        case .draw:
            if conflictsWithZoom(code: newCode, modifiers: newModifiers) ||
                conflictsWithLive(code: newCode, modifiers: newModifiers) {
                NSSound.beep()
                return nil
            }
            settings.drawHotKeyCode = newCode
            settings.drawHotKeyModifiers = newModifiers
        case .live:
            if conflictsWithZoom(code: newCode, modifiers: newModifiers) ||
                conflictsWithDraw(code: newCode, modifiers: newModifiers) {
                NSSound.beep()
                return nil
            }
            settings.liveHotKeyCode = newCode
            settings.liveHotKeyModifiers = newModifiers
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

    private func finishRecording() {
        if let hotKeyMonitor {
            NSEvent.removeMonitor(hotKeyMonitor)
        }
        hotKeyMonitor = nil
        recordingTarget = nil
        hotKeyButton?.title = zoomHotKeyDisplayString()
        drawHotKeyButton?.title = drawHotKeyDisplayString()
        liveHotKeyButton?.title = liveHotKeyDisplayString()
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

    // MARK: - Draw tab

    private func makeDrawTab() -> NSView {
        let help = makeLabel(
            """
            Once zoomed, enter drawing mode by pressing the left mouse button; exit drawing mode by pressing the right mouse button.

            Colors: press R, G, B, O, Y, P, W or K for red, green, blue, orange, yellow, pink, white or black. Hold Shift with a color key for a translucent highlighter.

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
