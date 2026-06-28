import AppKit
import UniformTypeIdentifiers

/// Shared helpers for exporting a captured image: copying it to the clipboard
/// or saving it to a PNG file, mirroring ZoomIt's Ctrl+C / Ctrl+S behaviour.
@MainActor
enum ImageExporter {
    /// Copies the image to the general pasteboard as PNG and TIFF so it can be
    /// pasted into the widest range of apps.
    static func copyToPasteboard(_ image: CGImage) {
        let rep = NSBitmapImageRep(cgImage: image)
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        if let png = rep.representation(using: .png, properties: [:]) {
            pasteboard.setData(png, forType: .png)
        }
        if let tiff = rep.tiffRepresentation {
            pasteboard.setData(tiff, forType: .tiff)
        }
    }

    /// Presents a Save dialog defaulting to a timestamped PNG name and writes
    /// the image as PNG.
    static func presentSavePanel(for image: CGImage) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = suggestedFilename()
        panel.allowedContentTypes = [.png]
        panel.canCreateDirectories = true
        NSApp.activate(ignoringOtherApps: true)

        guard panel.runModal() == .OK, let url = panel.url else { return }
        let rep = NSBitmapImageRep(cgImage: image)
        guard let png = rep.representation(using: .png, properties: [:]) else { return }
        do {
            try png.write(to: url)
        } catch {
            let alert = NSAlert(error: error)
            alert.runModal()
        }
    }

    /// "ZoomIt YYYY-MM-DD HHMMSS.png", matching ZoomIt's unique-name scheme.
    static func suggestedFilename() -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HHmmss"
        return "ZoomIt \(formatter.string(from: Date())).png"
    }
}
