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

    /// Saves the image according to the user's snip preferences: optionally
    /// copies it to the clipboard as well, then either writes it directly to the
    /// configured directory or presents a Save dialog. `onWillShowSaveDialog` is
    /// invoked only when the Save dialog is about to appear, so callers can
    /// prepare their UI (e.g. lower an overlay window).
    static func saveImage(
        _ image: CGImage,
        settings: AppSettings,
        onWillShowSaveDialog: (() -> Void)? = nil
    ) {
        if settings.copySnipToClipboardOnSave {
            copyToPasteboard(image)
        }
        if settings.saveSnipToDirectory {
            writeToDirectory(image, directoryPath: settings.snipSaveDirectory)
        } else {
            onWillShowSaveDialog?()
            presentSavePanel(for: image)
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

    /// Writes the image as a timestamped PNG into `directoryPath` (or the user's
    /// Documents folder when it is empty), creating the directory if needed.
    static func writeToDirectory(_ image: CGImage, directoryPath: String) {
        let directoryURL = resolvedSaveDirectory(directoryPath)
        let fileManager = FileManager.default
        do {
            try fileManager.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        } catch {
            NSApp.activate(ignoringOtherApps: true)
            NSAlert(error: error).runModal()
            return
        }

        let url = directoryURL.appendingPathComponent(suggestedFilename())
        let rep = NSBitmapImageRep(cgImage: image)
        guard let png = rep.representation(using: .png, properties: [:]) else { return }
        do {
            try png.write(to: url)
        } catch {
            NSApp.activate(ignoringOtherApps: true)
            NSAlert(error: error).runModal()
        }
    }

    /// The directory used when saving directly: the configured folder, or the
    /// user's Documents folder when unset.
    static func resolvedSaveDirectory(_ directoryPath: String) -> URL {
        let trimmed = directoryPath.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty {
            return defaultSaveDirectory()
        }
        return URL(fileURLWithPath: (trimmed as NSString).expandingTildeInPath, isDirectory: true)
    }

    /// The default save location shown in Settings and used when no directory is
    /// configured: the user's Documents folder.
    static func defaultSaveDirectory() -> URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
    }

    /// "ZoomIt YYYY-MM-DD HHMMSS.png", matching ZoomIt's unique-name scheme.
    static func suggestedFilename() -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HHmmss"
        return "ZoomIt \(formatter.string(from: Date())).png"
    }
}
