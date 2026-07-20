import AppKit

@MainActor
enum ZoomItAppIcon {
    static func apply() {
        guard let image = loadColorIcon() ?? loadTemplateIcon() else { return }
        image.isTemplate = false
        NSApp.applicationIconImage = image

        let iconView = NSImageView(frame: NSRect(x: 0, y: 0, width: 128, height: 128))
        iconView.image = image
        iconView.imageScaling = .scaleProportionallyUpOrDown
        NSApp.dockTile.contentView = iconView
        NSApp.dockTile.display()
    }

    static func loadTemplateIcon() -> NSImage? {
        loadImage(named: "ZoomItIcon")
    }

    /// A standard macOS-style app icon: the (full-bleed) artwork inset within a
    /// rounded square with a margin, matching the silhouette of other app icons
    /// so it looks right in pickers and the permissions dialog. The margin also
    /// brings the visible top of the icon down to line up with dialog text.
    static func standardIcon(size: CGFloat = 128) -> NSImage? {
        guard let source = loadColorIcon() ?? loadTemplateIcon() else { return nil }
        let canvas = NSSize(width: size, height: size)
        let image = NSImage(size: canvas)
        image.lockFocus()
        // Apple's large-icon grid leaves roughly a 10% margin and uses a
        // continuous-corner radius near 22% of the icon body.
        let margin = (size * 0.10).rounded()
        let body = NSRect(x: margin, y: margin, width: size - 2 * margin, height: size - 2 * margin)
        let radius = body.width * 0.2237
        NSBezierPath(roundedRect: body, xRadius: radius, yRadius: radius).addClip()
        source.draw(in: body, from: .zero, operation: .sourceOver, fraction: 1)
        image.unlockFocus()
        return image
    }

    private static func loadColorIcon() -> NSImage? {
        loadImage(named: "ZoomItColorIcon")
    }

    private static func loadImage(named name: String) -> NSImage? {
        // In the packaged .app the resources are flattened into
        // Contents/Resources and resolved via Bundle.main. Fall back to
        // Bundle.module for local `swift run` / test builds, where the
        // resources live in the SwiftPM-generated resource bundle. Bundle.main
        // is tried first so Bundle.module (which fatal-errors when its bundle
        // is absent) is never touched in the packaged app.
        let url = Bundle.main.url(forResource: name, withExtension: "png")
            ?? Bundle.module.url(forResource: name, withExtension: "png")
        guard let url, let image = NSImage(contentsOf: url) else {
            return nil
        }
        return image
    }
}