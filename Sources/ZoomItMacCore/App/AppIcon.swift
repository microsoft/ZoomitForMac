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