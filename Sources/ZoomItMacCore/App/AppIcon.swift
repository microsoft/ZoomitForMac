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
        guard let url = Bundle.module.url(forResource: name, withExtension: "png"),
              let image = NSImage(contentsOf: url) else {
            return nil
        }
        return image
    }
}