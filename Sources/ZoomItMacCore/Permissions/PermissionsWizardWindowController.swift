import AppKit

/// A short, three-step onboarding wizard shown on first launch (and reachable any
/// time via the "Run Welcome…" button in the Check Permissions dialog) that
/// (1) plainly explains the one required permission — Screen Recording,
/// (2) explains that Microphone and Camera are optional, and (3) lets the user
/// grant Screen Recording on the spot, without burying that explanation inside
/// the denser Settings window.
@MainActor
final class PermissionsWizardWindowController: NSObject, NSWindowDelegate {
    private let permissionService: PermissionService
    private let settingsStore: SettingsStore
    private let onFinished: () -> Void

    private var window: NSWindow?
    private var containerView: NSView?
    private var backButton: NSButton?
    private var primaryButton: NSButton?
    private var statusLabel: NSTextField?
    private var grantButton: NSButton?
    private var relaunchButton: NSButton?
    private var currentPage = 0
    private static let lastPageIndex = 2
    /// Fires once when ZoomIt regains focus after the user is sent to grant
    /// Screen Recording, so the app can relaunch itself automatically instead
    /// of making the user do it — see relaunchApp() for why a relaunch is
    /// unavoidable.
    private var autoRelaunchObserver: NSObjectProtocol?

    private static let windowSize = NSSize(width: 460, height: 440)
    private static let contentInset: CGFloat = 28
    private static let contentWidth = windowSize.width - contentInset * 2
    private static let footerHeight: CGFloat = 56
    private static let pageAreaHeight = windowSize.height - footerHeight

    init(permissionService: PermissionService, settingsStore: SettingsStore, onFinished: @escaping () -> Void = {}) {
        self.permissionService = permissionService
        self.settingsStore = settingsStore
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
        removeAutoRelaunchObserver()
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
    /// shown before. The wizard only has three pages, so a full rebuild per page
    /// keeps this simple instead of maintaining hidden/visible view state.
    private func renderCurrentPage() {
        guard let containerView else { return }
        containerView.subviews.forEach { $0.removeFromSuperview() }
        removeAutoRelaunchObserver()

        let page: NSView
        switch currentPage {
        case 0: page = makeWelcomePage()
        case 1: page = makeMicrophoneCameraPage()
        default: page = makePermissionPage()
        }
        page.frame = NSRect(x: 0, y: Self.footerHeight, width: Self.windowSize.width, height: Self.pageAreaHeight)
        containerView.addSubview(page)
        containerView.addSubview(makeFooter())
    }

    // MARK: - Page 1: explain the required permission

    private func makeWelcomePage() -> NSView {
        let view = NSView(frame: NSRect(x: 0, y: 0, width: Self.windowSize.width, height: Self.pageAreaHeight))

        let icon = NSImageView(frame: NSRect(x: (Self.windowSize.width - 64) / 2, y: Self.pageAreaHeight - 84, width: 64, height: 64))
        icon.image = ZoomItAppIcon.standardIcon(size: 64)
        icon.imageScaling = .scaleProportionallyUpOrDown

        let title = makeCenteredTitle("Welcome to ZoomIt", topY: icon.frame.minY - 12)

        let body = makeBodyLabel("""
        ZoomIt needs just one system permission to work: Screen Recording.

        macOS requires this for any app that draws a zoom lens, annotations, or a recording overlay on top of your screen. ZoomIt only uses it to show Live Zoom, take snips, and record the video you start — nothing is captured or sent anywhere on its own.
        """, topY: title.frame.minY - 10)

        view.addSubview(icon)
        view.addSubview(title)
        view.addSubview(body)
        return view
    }

    // MARK: - Page 2: explain the optional permissions

    private func makeMicrophoneCameraPage() -> NSView {
        let view = NSView(frame: NSRect(x: 0, y: 0, width: Self.windowSize.width, height: Self.pageAreaHeight))

        let iconSize: CGFloat = 48
        let iconGap: CGFloat = 20
        let iconsTop = Self.pageAreaHeight - 68
        let pairWidth = iconSize * 2 + iconGap
        let micIcon = makeSymbolIcon("mic.fill", frame: NSRect(x: (Self.windowSize.width - pairWidth) / 2, y: iconsTop - iconSize, width: iconSize, height: iconSize))
        let camIcon = makeSymbolIcon("video.fill", frame: NSRect(x: (Self.windowSize.width - pairWidth) / 2 + iconSize + iconGap, y: iconsTop - iconSize, width: iconSize, height: iconSize))

        let title = makeCenteredTitle("Microphone and Camera", topY: iconsTop - iconSize - 12)

        let body = makeBodyLabel("""
        These two permissions are optional. ZoomIt only asks for them if you turn on voice narration or webcam overlay while recording, in Settings.

        You can skip this for now — nothing else in ZoomIt needs them, and you'll only be prompted the first time you actually turn one of those options on.
        """, topY: title.frame.minY - 10)

        view.addSubview(micIcon)
        view.addSubview(camIcon)
        view.addSubview(title)
        view.addSubview(body)
        return view
    }

    // MARK: - Page 3: grant the permission

    private func makePermissionPage() -> NSView {
        let view = NSView(frame: NSRect(x: 0, y: 0, width: Self.windowSize.width, height: Self.pageAreaHeight))

        let title = makeCenteredTitle("Allow Screen Recording", topY: Self.pageAreaHeight - 30)

        let body = makeBodyLabel("""
        Click Grant Screen Recording to open the macOS permission prompt or System \
        Settings, then turn it on there. ZoomIt detects when you switch back and \
        relaunches itself automatically — macOS requires that for a new grant to \
        take effect, so you don't have to quit and reopen it yourself.
        """, topY: title.frame.minY - 10)

        let status = makeBodyLabel("", topY: body.frame.minY - 4, maxHeight: 20)
        status.alignment = .center
        statusLabel = status

        let granted = permissionService.currentState().screenCapture.isGranted
        // Once macOS has shown the system prompt once, calling
        // requestScreenCaptureAccess() again is a silent no-op if the user
        // dismissed or denied it — so from that point on, the button must
        // send the user to System Settings instead of "re-requesting".
        let alreadyPrompted = settingsStore.hasRequestedScreenCaptureAccess

        let grant = NSButton(title: grantButtonTitle(granted: granted, alreadyPrompted: alreadyPrompted), target: self, action: #selector(grantTapped))
        grant.bezelStyle = .rounded
        grant.frame = NSRect(x: (Self.windowSize.width - 220) / 2, y: 64, width: 220, height: 32)
        grantButton = grant

        // Fallback for the rare case ZoomIt doesn't detect the return from
        // System Settings on its own (see observeReturnForAutoRelaunch).
        let relaunch = NSButton(title: "Relaunch ZoomIt Now", target: self, action: #selector(relaunchTapped))
        relaunch.bezelStyle = .rounded
        relaunch.frame = NSRect(x: (Self.windowSize.width - 220) / 2, y: 16, width: 220, height: 32)
        relaunch.isHidden = granted
        relaunchButton = relaunch

        view.addSubview(title)
        view.addSubview(body)
        view.addSubview(status)
        view.addSubview(grant)
        view.addSubview(relaunch)
        updateStatusLabel(granted: granted)
        return view
    }

    /// The button reads "Grant…" only the very first time — once macOS has
    /// shown the prompt (whether granted, denied, or dismissed), it always
    /// reads "Open Settings…" since re-requesting can no longer show anything.
    private func grantButtonTitle(granted: Bool, alreadyPrompted: Bool) -> String {
        (granted || alreadyPrompted) ? "Open Screen Recording Settings…" : "Grant Screen Recording…"
    }

    private func updateStatusLabel(granted: Bool) {
        statusLabel?.stringValue = granted ? "Status: Granted" : "Status: Not granted yet"
        statusLabel?.textColor = granted ? .systemGreen : .secondaryLabelColor
    }

    @objc private func grantTapped() {
        let state = permissionService.currentState()
        if state.screenCapture.isGranted || settingsStore.hasRequestedScreenCaptureAccess {
            // Either already granted, or macOS already showed the one-time
            // prompt before (denied/dismissed) — requesting again would
            // silently do nothing, so send the user to Settings instead.
            permissionService.openSystemSettings()
        } else {
            settingsStore.markScreenCaptureAccessRequested()
            _ = permissionService.requestScreenCaptureAccess()
        }
        // Screen Recording's grant is cached per-process by macOS, so this
        // window can never observe it flip to granted on its own. Instead,
        // relaunch automatically the moment the user switches back to ZoomIt —
        // that's the point at which they've either granted it in System
        // Settings or dismissed the prompt, so it's safe to just reload.
        relaunchButton?.isHidden = false
        observeReturnForAutoRelaunch()
    }

    @objc private func relaunchTapped() {
        relaunchApp()
    }

    /// Auto-relaunches ZoomIt the next time it becomes active again, so
    /// granting Screen Recording feels like a single step instead of asking
    /// the user to quit and reopen the app themselves. One-shot: only the
    /// first return after tapping Grant triggers it, so switching back and
    /// forth afterward (e.g. to double-check Settings) doesn't keep
    /// relaunching the app.
    private func observeReturnForAutoRelaunch() {
        removeAutoRelaunchObserver()
        autoRelaunchObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.removeAutoRelaunchObserver()
                self.statusLabel?.stringValue = "Applying permission — relaunching ZoomIt…"
                self.statusLabel?.textColor = .secondaryLabelColor
                // A short delay lets the window finish becoming key before the
                // app quits, so the transition doesn't look like a glitch.
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
                    self?.relaunchApp()
                }
            }
        }
    }

    private func removeAutoRelaunchObserver() {
        if let autoRelaunchObserver {
            NotificationCenter.default.removeObserver(autoRelaunchObserver)
            self.autoRelaunchObserver = nil
        }
    }

    /// Quits ZoomIt and immediately reopens its app bundle. A Screen Recording
    /// grant only takes effect for a freshly launched process — this is a
    /// macOS TCC restriction that in-process code cannot detect or bypass, so
    /// relaunching automatically spares the user from doing it manually via
    /// the menu bar or Force Quit.
    private func relaunchApp() {
        let bundleURL = Bundle.main.bundleURL
        guard bundleURL.pathExtension == "app" else {
            // Running as a bare SwiftPM binary (development only); there's no
            // app bundle to reopen, so just ask the user to restart it.
            let alert = NSAlert()
            alert.messageText = "Relaunch ZoomIt"
            alert.informativeText = "Quit and run ZoomIt again to apply the new permission."
            alert.runModal()
            return
        }

        let relaunch = Process()
        relaunch.executableURL = URL(fileURLWithPath: "/bin/sh")
        // The short delay lets this process fully exit — and release the
        // single-instance lock in SingleInstance.swift — before the new one
        // launches and claims it; otherwise the new instance would find the
        // lock still held and immediately give up.
        relaunch.arguments = ["-c", "sleep 0.5; /usr/bin/open \"\(bundleURL.path)\""]
        try? relaunch.run()

        NSApplication.shared.terminate(nil)
    }

    // MARK: - Shared footer (Back / Next / Finish)

    private func makeFooter() -> NSView {
        let footer = NSView(frame: NSRect(x: 0, y: 0, width: Self.windowSize.width, height: Self.footerHeight))

        let back = NSButton(title: "Back", target: self, action: #selector(backTapped))
        back.bezelStyle = .rounded
        back.frame = NSRect(x: Self.contentInset, y: 12, width: 90, height: 32)
        back.isHidden = currentPage == 0
        backButton = back

        let primaryTitle = currentPage == Self.lastPageIndex ? "Finish" : "Continue"
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
        if currentPage < Self.lastPageIndex {
            currentPage += 1
            renderCurrentPage()
        } else {
            window?.close()
        }
    }

    // MARK: - Label helpers

    private func makeCenteredTitle(_ text: String, topY: CGFloat) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.font = .systemFont(ofSize: 18, weight: .semibold)
        label.alignment = .center
        let height: CGFloat = 26
        label.frame = NSRect(x: Self.contentInset, y: topY - height, width: Self.contentWidth, height: height)
        return label
    }

    private func makeSymbolIcon(_ symbolName: String, frame: NSRect) -> NSImageView {
        let view = NSImageView(frame: frame)
        let config = NSImage.SymbolConfiguration(pointSize: frame.height * 0.6, weight: .regular)
        view.image = NSImage(systemSymbolName: symbolName, accessibilityDescription: nil)?
            .withSymbolConfiguration(config)
        view.contentTintColor = .secondaryLabelColor
        view.imageScaling = .scaleProportionallyUpOrDown
        return view
    }

    /// Builds a wrapping label positioned with its *top* edge at `topY`, sized
    /// to exactly fit `text` at `contentWidth` (capped at `maxHeight`). Sizing
    /// to the actual text — rather than a hardcoded height guess — is what
    /// guarantees the full message is always visible, however long it is.
    private func makeBodyLabel(_ text: String, topY: CGFloat, maxHeight: CGFloat = 220) -> NSTextField {
        let label = NSTextField(wrappingLabelWithString: text)
        label.font = .systemFont(ofSize: 13)
        label.textColor = .labelColor
        label.alignment = .center
        label.preferredMaxLayoutWidth = Self.contentWidth

        let fittingHeight: CGFloat
        if text.isEmpty {
            fittingHeight = maxHeight
        } else {
            let fitting = label.sizeThatFits(NSSize(width: Self.contentWidth, height: .greatestFiniteMagnitude))
            fittingHeight = min(fitting.height, maxHeight)
        }
        label.frame = NSRect(x: Self.contentInset, y: topY - fittingHeight, width: Self.contentWidth, height: fittingHeight)
        return label
    }
}
