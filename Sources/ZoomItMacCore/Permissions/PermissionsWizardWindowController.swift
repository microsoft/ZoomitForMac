import AppKit

/// A short, two-step onboarding wizard shown on first launch (and reachable any
/// time from the menu bar) that (1) plainly explains the one permission ZoomIt
/// requires — Screen Recording — and (2) lets the user grant it on the spot,
/// without burying that explanation inside the denser Settings window.
@MainActor
final class PermissionsWizardWindowController: NSObject, NSWindowDelegate {
    private let permissionService: PermissionService
    private let onFinished: () -> Void

    private var window: NSWindow?
    private var containerView: NSView?
    private var backButton: NSButton?
    private var primaryButton: NSButton?
    private var statusLabel: NSTextField?
    private var grantButton: NSButton?
    private var currentPage = 0
    /// One-shot observer that refreshes the granted status when the user
    /// returns from System Settings, mirroring AppController's pattern.
    private var reactivationObserver: NSObjectProtocol?

    private static let windowSize = NSSize(width: 460, height: 400)
    private static let contentInset: CGFloat = 28
    private static let contentWidth = windowSize.width - contentInset * 2

    init(permissionService: PermissionService, onFinished: @escaping () -> Void = {}) {
        self.permissionService = permissionService
        self.onFinished = onFinished
        super.init()
    }

    func show() {
        if window == nil {
            window = makeWindow()
        }
        currentPage = 0
        renderCurrentPage()
        NSApp.activate(ignoringOtherApps: true)
        window?.center()
        window?.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ notification: Notification) {
        removeReactivationObserver()
        onFinished()
    }

    // MARK: - Window construction

    private func makeWindow() -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: Self.windowSize),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "Welcome to ZoomIt"
        window.isReleasedWhenClosed = false
        window.delegate = self

        let container = NSView(frame: NSRect(origin: .zero, size: Self.windowSize))
        window.contentView = container
        containerView = container
        return window
    }

    /// Rebuilds the window's content for `currentPage`, replacing whatever was
    /// shown before. The wizard only has two pages, so a full rebuild per page
    /// keeps this simple instead of maintaining hidden/visible view state.
    private func renderCurrentPage() {
        guard let containerView else { return }
        containerView.subviews.forEach { $0.removeFromSuperview() }

        let page = currentPage == 0 ? makeWelcomePage() : makePermissionPage()
        page.frame = NSRect(x: 0, y: 56, width: Self.windowSize.width, height: Self.windowSize.height - 56)
        containerView.addSubview(page)
        containerView.addSubview(makeFooter())
    }

    // MARK: - Page 1: explain the permission

    private func makeWelcomePage() -> NSView {
        let icon = NSImageView(frame: NSRect(x: (Self.windowSize.width - 64) / 2, y: 210, width: 64, height: 64))
        icon.image = ZoomItAppIcon.standardIcon(size: 64)
        icon.imageScaling = .scaleProportionallyUpOrDown

        let title = makeCenteredTitle("Welcome to ZoomIt", y: 178)

        let body = makeBodyLabel("""
        ZoomIt needs just one system permission to work: Screen Recording.

        macOS requires this for any app that draws a zoom lens, annotations, or a recording overlay on top of your screen. ZoomIt only uses it to show Live Zoom, take snips, and record the video you start — nothing is captured or sent anywhere on its own.

        Microphone and Camera are optional and are only requested later if you turn on voice or webcam recording in Settings.
        """, y: 20, height: 150)

        let view = NSView(frame: NSRect(x: 0, y: 0, width: Self.windowSize.width, height: Self.windowSize.height - 56))
        view.addSubview(icon)
        view.addSubview(title)
        view.addSubview(body)
        return view
    }

    // MARK: - Page 2: grant the permission

    private func makePermissionPage() -> NSView {
        let title = makeCenteredTitle("Allow Screen Recording", y: 238)

        let body = makeBodyLabel("""
        Click Grant Screen Recording to open the macOS permission prompt. If you've \
        already responded to it before, this instead opens System Settings so you can \
        turn it on there.

        Newly granted access takes effect the next time you relaunch ZoomIt.
        """, y: 110, height: 120)

        let status = makeBodyLabel("", y: 78, height: 20)
        status.alignment = .center
        statusLabel = status

        let granted = permissionService.currentState().screenCapture.isGranted
        let grant = NSButton(title: grantButtonTitle(granted: granted), target: self, action: #selector(grantTapped))
        grant.bezelStyle = .rounded
        grant.frame = NSRect(x: (Self.windowSize.width - 220) / 2, y: 40, width: 220, height: 32)
        grantButton = grant

        let view = NSView(frame: NSRect(x: 0, y: 0, width: Self.windowSize.width, height: Self.windowSize.height - 56))
        view.addSubview(title)
        view.addSubview(body)
        view.addSubview(status)
        view.addSubview(grant)
        updateStatusLabel(granted: granted)
        return view
    }

    private func grantButtonTitle(granted: Bool) -> String {
        granted ? "Open Screen Recording Settings…" : "Grant Screen Recording…"
    }

    private func updateStatusLabel(granted: Bool) {
        statusLabel?.stringValue = granted ? "Status: Granted" : "Status: Not granted"
        statusLabel?.textColor = granted ? .systemGreen : .secondaryLabelColor
    }

    @objc private func grantTapped() {
        let state = permissionService.currentState()
        if state.screenCapture.isGranted {
            permissionService.openSystemSettings()
            observeReactivation()
        } else {
            _ = permissionService.requestScreenCaptureAccess()
            observeReactivation()
        }
    }

    /// Refreshes the status label the next time ZoomIt becomes active again,
    /// which covers both returning from System Settings and dismissing the
    /// inline TCC prompt.
    private func observeReactivation() {
        removeReactivationObserver()
        reactivationObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.removeReactivationObserver()
                let granted = self.permissionService.currentState().screenCapture.isGranted
                self.updateStatusLabel(granted: granted)
                self.grantButton?.title = self.grantButtonTitle(granted: granted)
            }
        }
    }

    private func removeReactivationObserver() {
        if let reactivationObserver {
            NotificationCenter.default.removeObserver(reactivationObserver)
            self.reactivationObserver = nil
        }
    }

    // MARK: - Shared footer (Back / Next / Finish)

    private func makeFooter() -> NSView {
        let footer = NSView(frame: NSRect(x: 0, y: 0, width: Self.windowSize.width, height: 56))

        let back = NSButton(title: "Back", target: self, action: #selector(backTapped))
        back.bezelStyle = .rounded
        back.frame = NSRect(x: Self.contentInset, y: 12, width: 90, height: 32)
        back.isHidden = currentPage == 0
        backButton = back

        let primaryTitle = currentPage == 0 ? "Continue" : "Finish"
        let primary = NSButton(title: primaryTitle, target: self, action: #selector(primaryTapped))
        primary.bezelStyle = .rounded
        primary.keyEquivalent = "\r"
        primary.frame = NSRect(x: Self.windowSize.width - Self.contentInset - 90, y: 12, width: 90, height: 32)
        primaryButton = primary

        footer.addSubview(back)
        footer.addSubview(primary)
        return footer
    }

    @objc private func backTapped() {
        currentPage = max(0, currentPage - 1)
        renderCurrentPage()
    }

    @objc private func primaryTapped() {
        if currentPage == 0 {
            currentPage = 1
            renderCurrentPage()
        } else {
            window?.close()
        }
    }

    // MARK: - Label helpers

    private func makeCenteredTitle(_ text: String, y: CGFloat) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.font = .systemFont(ofSize: 18, weight: .semibold)
        label.alignment = .center
        label.frame = NSRect(x: Self.contentInset, y: y, width: Self.contentWidth, height: 26)
        return label
    }

    private func makeBodyLabel(_ text: String, y: CGFloat, height: CGFloat) -> NSTextField {
        let label = NSTextField(wrappingLabelWithString: text)
        label.font = .systemFont(ofSize: 13)
        label.textColor = .labelColor
        label.alignment = .center
        label.frame = NSRect(x: Self.contentInset, y: y, width: Self.contentWidth, height: height)
        return label
    }
}
