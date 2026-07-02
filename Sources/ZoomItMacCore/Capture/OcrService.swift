import AppKit
import Vision

/// Recognizes text in a captured region using the Vision framework and copies
/// it to the clipboard, mirroring ZoomIt's OCR snip (Windows.Media.Ocr).
@MainActor
enum OcrService {
    /// Recognizes text in `image` and copies it to the general pasteboard as
    /// plain text. Beeps when no text is found, matching ZoomIt's behavior of
    /// only updating the clipboard when recognition produced text.
    static func recognizeAndCopy(_ image: CGImage) {
        Task {
            let text = await recognizeText(in: image)
            if text.isEmpty {
                NSSound.beep()
                return
            }
            let pasteboard = NSPasteboard.general
            pasteboard.clearContents()
            pasteboard.setString(text, forType: .string)
        }
    }

    /// Runs Vision text recognition off the main actor and returns the
    /// recognized text. Lines are joined with newlines, preserving reading
    /// order top-to-bottom.
    static func recognizeText(in image: CGImage) async -> String {
        await withCheckedContinuation { (continuation: CheckedContinuation<String, Never>) in
            // Vision work is CPU-bound; run it off the main thread.
            DispatchQueue.global(qos: .userInitiated).async {
                let request = VNRecognizeTextRequest()
                request.recognitionLevel = .accurate
                request.usesLanguageCorrection = true
                // Use the user's preferred languages when supported so OCR
                // matches the system locale, like ZoomIt's user-profile engine.
                if #available(macOS 13.0, *) {
                    request.automaticallyDetectsLanguage = true
                }

                let handler = VNImageRequestHandler(cgImage: image, options: [:])
                do {
                    try handler.perform([request])
                } catch {
                    continuation.resume(returning: "")
                    return
                }

                let observations = request.results ?? []
                // Vision returns observations in reading order already; take the
                // top candidate for each line.
                let lines = observations.compactMap { $0.topCandidates(1).first?.string }
                continuation.resume(returning: lines.joined(separator: "\n"))
            }
        }
    }
}
