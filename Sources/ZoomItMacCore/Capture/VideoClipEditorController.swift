import AppKit
import AVFoundation
import AVKit

/// Shows ZoomIt's recording in a clip editor before saving, mirroring the
/// Windows trim dialog: preview, a scrub timeline with trim grips, transport
/// controls, append-with-transition, and Save. Styled for macOS.
@MainActor
final class VideoClipEditorController: NSObject, NSWindowDelegate, VideoTimelineViewDelegate {
    enum Transition { case none, fadeBlack, fadeWhite }

    private var window: NSWindow?
    private var playerView: AVPlayerView!
    private var player: AVPlayer?
    private var timeline: VideoTimelineView!
    private var positionLabel: NSTextField!
    private var playButton: NSButton!
    private var volumeButton: NSButton!
    private var volumeSlider: NSSlider!

    /// The clips making up the composition (in order). The first is the
    /// original recording; more are appended by the user.
    private var clips: [AVURLAsset] = []
    private var transitions: [Transition] = []
    private var duration: Double = 0
    private var trimStart: Double = 0
    private var trimEnd: Double = 0
    private var timeObserver: Any?
    private var isPlaying = false
    private var isMuted = false
    private var lastAudibleVolume: Float = 1

    private var onSave: ((URL) -> Void)?
    private var onCancel: (() -> Void)?
    private var suggestedName = "ZoomIt.mp4"
    private var preferredWindowLevel: NSWindow.Level = .normal

    /// Shows the editor for `tempURL`. Calls `onSave` with an exported MP4 of the
    /// edited result, or `onCancel` if dismissed.
    func present(tempURL: URL, suggestedName: String,
                 windowLevel: NSWindow.Level = .normal,
                 onSave: @escaping (URL) -> Void, onCancel: @escaping () -> Void) {
        self.onSave = onSave
        self.onCancel = onCancel
        self.suggestedName = suggestedName
        self.preferredWindowLevel = windowLevel
        let asset = AVURLAsset(url: tempURL)
        clips = [asset]
        transitions = []
        duration = max(asset.duration.seconds, 0.1)
        trimStart = 0
        trimEnd = duration
        buildWindow()
        rebuildPlayer()
    }

    private func buildWindow() {
        let win = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 720, height: 560),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered, defer: false
        )
        win.title = "ZoomIt: Edit Recording"
        win.delegate = self
        win.center()
        win.isReleasedWhenClosed = false
        // A normal-level window with a Dock tile: the user can switch away and
        // return to it through the Dock or Cmd-Tab, so it is not pinned above
        // other apps.
        win.level = preferredWindowLevel
        win.hidesOnDeactivate = false

        let content = NSView()
        win.contentView = content

        playerView = AVPlayerView()
        playerView.controlsStyle = .none
        playerView.videoGravity = .resizeAspect
        playerView.wantsLayer = true
        playerView.layer?.backgroundColor = NSColor.black.cgColor
        playerView.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(playerView)

        timeline = VideoTimelineView()
        timeline.delegate = self
        timeline.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(timeline)

        positionLabel = NSTextField(labelWithString: "0:00.00")
        positionLabel.font = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        positionLabel.textColor = .secondaryLabelColor

        let skipStart = transportButton("backward.end.fill", #selector(skipStart))
        let back = transportButton("backward.fill", #selector(stepBack))
        playButton = transportButton("play.fill", #selector(togglePlay))
        let forward = transportButton("forward.fill", #selector(stepForward))
        let skipEnd = transportButton("forward.end.fill", #selector(skipEnd))

        volumeButton = transportButton("speaker.wave.2.fill", #selector(toggleMute))
        volumeButton.contentTintColor = .secondaryLabelColor
        volumeButton.toolTip = "Mute"
        volumeSlider = NSSlider(value: 1, minValue: 0, maxValue: 1, target: self, action: #selector(volumeChanged))
        volumeSlider.widthAnchor.constraint(equalToConstant: 80).isActive = true

        // Centered transport controls; time on the left, volume on the right.
        let controls = NSStackView(views: [skipStart, back, playButton, forward, skipEnd])
        controls.spacing = 14
        controls.alignment = .centerY
        let volume = NSStackView(views: [volumeButton, volumeSlider])
        volume.spacing = 6
        volume.alignment = .centerY
        let transport = NSView()
        transport.translatesAutoresizingMaskIntoConstraints = false
        controls.translatesAutoresizingMaskIntoConstraints = false
        positionLabel.translatesAutoresizingMaskIntoConstraints = false
        volume.translatesAutoresizingMaskIntoConstraints = false
        transport.addSubview(positionLabel)
        transport.addSubview(controls)
        transport.addSubview(volume)
        content.addSubview(transport)

        let append = NSButton(title: "Append…", target: self, action: #selector(appendClip))
        append.bezelStyle = .rounded
        let cancel = NSButton(title: "Cancel", target: self, action: #selector(cancel))
        cancel.bezelStyle = .rounded
        cancel.keyEquivalent = "\u{1b}"
        let save = NSButton(title: "Save…", target: self, action: #selector(save))
        save.bezelStyle = .rounded
        save.keyEquivalent = "\r"
        let bottom = NSStackView(views: [append, NSView(), cancel, save])
        bottom.spacing = 12
        bottom.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(bottom)

        NSLayoutConstraint.activate([
            playerView.topAnchor.constraint(equalTo: content.topAnchor, constant: 16),
            playerView.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 16),
            playerView.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -16),
            timeline.topAnchor.constraint(equalTo: playerView.bottomAnchor, constant: 12),
            timeline.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 16),
            timeline.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -16),
            timeline.heightAnchor.constraint(equalToConstant: 70),
            transport.topAnchor.constraint(equalTo: timeline.bottomAnchor, constant: 8),
            transport.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 16),
            transport.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -16),
            transport.heightAnchor.constraint(equalToConstant: 32),
            positionLabel.leadingAnchor.constraint(equalTo: transport.leadingAnchor),
            positionLabel.centerYAnchor.constraint(equalTo: transport.centerYAnchor),
            controls.centerXAnchor.constraint(equalTo: transport.centerXAnchor),
            controls.centerYAnchor.constraint(equalTo: transport.centerYAnchor),
            volume.trailingAnchor.constraint(equalTo: transport.trailingAnchor),
            volume.centerYAnchor.constraint(equalTo: transport.centerYAnchor),
            bottom.topAnchor.constraint(equalTo: transport.bottomAnchor, constant: 16),
            bottom.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 16),
            bottom.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -16),
            bottom.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -16)
        ])

        self.window = win
        // Become a regular app while editing so the window appears in the Dock
        // and Cmd-Tab, letting the user switch away and return; restored to
        // accessory on close. Switching from .accessory needs a runloop hop to
        // make the Dock tile appear reliably.
        win.makeKeyAndOrderFront(nil)
        DispatchQueue.main.async {
            ZoomItAppIcon.apply()
            NSApp.setActivationPolicy(.regular)
            ZoomItAppIcon.apply()
            win.makeKeyAndOrderFront(nil)
        }
        syncTimeline()
    }

    private func transportButton(_ symbol: String, _ action: Selector) -> NSButton {
        let b = HoverButton(image: NSImage(systemSymbolName: symbol, accessibilityDescription: nil) ?? NSImage(),
                            target: self, action: action)
        b.bezelStyle = .regularSquare
        b.isBordered = false
        b.contentTintColor = .labelColor
        b.widthAnchor.constraint(equalToConstant: 30).isActive = true
        b.heightAnchor.constraint(equalToConstant: 28).isActive = true
        return b
    }

    // MARK: - Player

    private func rebuildPlayer() {
        if let observer = timeObserver { player?.removeTimeObserver(observer); timeObserver = nil }
        let comp = buildComposition()
        duration = max(comp.composition.duration.seconds, 0.1)
        if trimEnd <= 0 || trimEnd > duration { trimEnd = duration }
        let item = AVPlayerItem(asset: comp.composition)
        item.videoComposition = comp.videoComposition
        let p = AVPlayer(playerItem: item)
        p.volume = volumeSlider?.floatValue ?? 1
        p.isMuted = isMuted
        player = p
        playerView.player = p
        timeObserver = p.addPeriodicTimeObserver(forInterval: CMTime(value: 1, timescale: 30), queue: .main) { [weak self] t in
            MainActor.assumeIsolated { self?.tick(t.seconds) }
        }
        seek(trimStart)
        syncVolumeButton()
        syncTimeline()
    }

    private func tick(_ pos: Double) {
        timeline.position = pos
        positionLabel.stringValue = VideoTimelineView.format(pos - trimStart)
        if isPlaying && pos >= trimEnd - 0.02 { seek(trimStart); pause() }
    }

    private func seek(_ t: Double) {
        let clamped = max(0, min(t, duration))
        player?.seek(to: CMTime(seconds: clamped, preferredTimescale: 600),
                     toleranceBefore: .zero, toleranceAfter: .zero)
        timeline.position = clamped
        positionLabel.stringValue = VideoTimelineView.format(clamped - trimStart)
    }

    private func syncTimeline() {
        timeline.duration = duration
        timeline.trimStart = trimStart
        timeline.trimEnd = trimEnd
        var bound = 0.0; var marks: [Double] = []
        for c in clips.dropLast() { bound += c.duration.seconds; marks.append(bound) }
        timeline.clipBoundaries = marks
    }

    @objc private func togglePlay() { isPlaying ? pause() : play() }
    private func play() {
        if (player?.currentTime().seconds ?? 0) >= trimEnd - 0.02 { seek(trimStart) }
        player?.play(); isPlaying = true
        playButton.image = NSImage(systemSymbolName: "pause.fill", accessibilityDescription: nil)
    }
    private func pause() {
        player?.pause(); isPlaying = false
        playButton.image = NSImage(systemSymbolName: "play.fill", accessibilityDescription: nil)
    }
    @objc private func skipStart() { pause(); seek(trimStart) }
    @objc private func skipEnd() { pause(); seek(trimEnd) }
    @objc private func stepBack() { pause(); seek(max(trimStart, (player?.currentTime().seconds ?? 0) - 2)) }
    @objc private func stepForward() { pause(); seek(min(trimEnd, (player?.currentTime().seconds ?? 0) + 2)) }
    @objc private func volumeChanged() {
        let volume = volumeSlider.floatValue
        player?.volume = volume
        if volume > 0 {
            lastAudibleVolume = volume
            isMuted = false
        } else {
            isMuted = true
        }
        player?.isMuted = isMuted
        syncVolumeButton()
    }

    @objc private func toggleMute() {
        if isMuted || volumeSlider.floatValue <= 0 {
            isMuted = false
            if volumeSlider.floatValue <= 0 {
                volumeSlider.floatValue = max(lastAudibleVolume, 0.5)
            }
        } else {
            lastAudibleVolume = volumeSlider.floatValue
            isMuted = true
        }
        player?.volume = volumeSlider.floatValue
        player?.isMuted = isMuted
        syncVolumeButton()
    }

    private func syncVolumeButton() {
        guard let volumeButton else { return }
        let effectiveVolume = volumeSlider?.floatValue ?? 0
        let muted = isMuted || effectiveVolume <= 0
        let symbol = muted ? "speaker.slash.fill" : (effectiveVolume < 0.5 ? "speaker.wave.1.fill" : "speaker.wave.2.fill")
        volumeButton.image = NSImage(systemSymbolName: symbol, accessibilityDescription: muted ? "Unmute" : "Mute")
        volumeButton.toolTip = muted ? "Unmute" : "Mute"
        volumeButton.contentTintColor = muted ? .secondaryLabelColor : .labelColor
        volumeSlider?.isEnabled = !muted
    }

    // MARK: - Timeline delegate

    func timelineDidChangeSelection(start: Double, end: Double) { trimStart = start; trimEnd = end }
    func timelineDidScrub(to position: Double, scrubbing: Bool) { pause(); seek(position) }

    // MARK: - Append

    @objc private func appendClip() {
        pause()
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.mpeg4Movie, .quickTimeMovie]
        panel.title = "Select Video to Append"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let alert = NSAlert()
        alert.messageText = "Append Video"
        alert.informativeText = "Choose a transition between the current clip and the appended video."
        alert.addButton(withTitle: "No Transition")
        alert.addButton(withTitle: "Fade to Black")
        alert.addButton(withTitle: "Fade to White")
        alert.addButton(withTitle: "Cancel")
        let transition: Transition
        switch alert.runModal() {
        case .alertSecondButtonReturn: transition = .fadeBlack
        case .alertThirdButtonReturn: transition = .fadeWhite
        case .alertFirstButtonReturn: transition = .none
        default: return
        }
        clips.append(AVURLAsset(url: url))
        transitions.append(transition)
        trimEnd = .greatestFiniteMagnitude // rebuild clamps to the new full duration
        rebuildPlayer()
        trimEnd = duration
        seek(trimStart)
        syncTimeline()
    }

    // MARK: - Save / Cancel

    @objc private func cancel() { closeWindow(); onCancel?() }

    @objc private func save() {
        pause()
        export { [weak self] url in
            self?.closeWindow()
            if let url { self?.onSave?(url) } else { self?.onCancel?() }
        }
    }

    func windowWillClose(_ notification: Notification) {
        if let observer = timeObserver { player?.removeTimeObserver(observer); timeObserver = nil }
        pause()
        window = nil
        NSApp.setActivationPolicy(.accessory)
        onCancel?(); onCancel = nil; onSave = nil
    }

    private func closeWindow() { window?.orderOut(nil); window = nil; NSApp.setActivationPolicy(.accessory) }

    // MARK: - Composition

    private struct Built { let composition: AVMutableComposition; let videoComposition: AVMutableVideoComposition? }

    private func buildComposition() -> Built {
        let comp = AVMutableComposition()
        guard let vTrack = comp.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid) else {
            return Built(composition: comp, videoComposition: nil)
        }
        // One composition audio track per source audio track so system audio
        // and microphone (separate tracks) both play and mix.
        var aTracks: [AVMutableCompositionTrack] = []
        var cursor = CMTime.zero
        var boundaries: [CMTime] = []
        var segments: [(start: CMTime, size: CGSize)] = []
        var renderSize = CGSize(width: 1280, height: 720)
        for (index, asset) in clips.enumerated() {
            let range = CMTimeRange(start: .zero, duration: asset.duration)
            if let v = asset.tracks(withMediaType: .video).first {
                try? vTrack.insertTimeRange(range, of: v, at: cursor)
                // Account for the track's preferred transform so rotated clips
                // report their displayed size.
                let s = v.naturalSize.applying(v.preferredTransform)
                let size = CGSize(width: abs(s.width), height: abs(s.height))
                segments.append((cursor, size))
                if index == 0 { renderSize = size }
                renderSize.width = max(renderSize.width, size.width)
                renderSize.height = max(renderSize.height, size.height)
            }
            for (audioIndex, a) in asset.tracks(withMediaType: .audio).enumerated() {
                if audioIndex >= aTracks.count,
                   let t = comp.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) {
                    aTracks.append(t)
                }
                if audioIndex < aTracks.count {
                    try? aTracks[audioIndex].insertTimeRange(range, of: a, at: cursor)
                }
            }
            cursor = CMTimeAdd(cursor, asset.duration)
            if index < clips.count - 1 { boundaries.append(cursor) }
        }

        // Nothing to scale and no fades: play the single clip as-is.
        let fades = zip(boundaries, transitions).filter { $0.1 != .none }
        let needsScaling = segments.contains { abs($0.size.width - renderSize.width) > 1 || abs($0.size.height - renderSize.height) > 1 }
        guard !fades.isEmpty || needsScaling else { return Built(composition: comp, videoComposition: nil) }

        let fadeDur = CMTime(seconds: 0.75, preferredTimescale: 600)
        let layer = AVMutableVideoCompositionLayerInstruction(assetTrack: vTrack)
        // Aspect-fill each clip into the (largest) render size, centered, so
        // smaller segments magnify to fill instead of leaving blank borders.
        for seg in segments {
            let scale = max(renderSize.width / seg.size.width, renderSize.height / seg.size.height)
            let tx = (renderSize.width - seg.size.width * scale) / 2
            let ty = (renderSize.height - seg.size.height * scale) / 2
            let transform = CGAffineTransform(scaleX: scale, y: scale).concatenating(CGAffineTransform(translationX: tx, y: ty))
            layer.setTransform(transform, at: seg.start)
        }
        for (time, kind) in fades where kind != .none {
            let outRange = CMTimeRange(start: CMTimeSubtract(time, fadeDur), duration: fadeDur)
            let inRange = CMTimeRange(start: time, duration: fadeDur)
            layer.setOpacityRamp(fromStartOpacity: 1, toEndOpacity: 0, timeRange: outRange)
            layer.setOpacityRamp(fromStartOpacity: 0, toEndOpacity: 1, timeRange: inRange)
        }
        let instruction = AVMutableVideoCompositionInstruction()
        instruction.timeRange = CMTimeRange(start: .zero, duration: comp.duration)
        instruction.layerInstructions = [layer]
        // Use an explicit sRGB color; NSColor.white.cgColor is in a gray color
        // space that AVFoundation can misinterpret (greenish/black fades).
        let wantsWhite = fades.contains { $0.1 == .fadeWhite }
        instruction.backgroundColor = CGColor(srgbRed: wantsWhite ? 1 : 0,
                                              green: wantsWhite ? 1 : 0,
                                              blue: wantsWhite ? 1 : 0, alpha: 1)
        let vc = AVMutableVideoComposition()
        vc.instructions = [instruction]
        vc.renderSize = renderSize
        vc.frameDuration = CMTime(value: 1, timescale: 30)
        return Built(composition: comp, videoComposition: vc)
    }

    private func export(completion: @escaping (URL?) -> Void) {
        let built = buildComposition()
        let range = CMTimeRange(
            start: CMTime(seconds: trimStart, preferredTimescale: 600),
            end: CMTime(seconds: trimEnd, preferredTimescale: 600)
        )
        let out = FileManager.default.temporaryDirectory.appendingPathComponent("ZoomIt-edit-\(UUID().uuidString).mp4")
        guard let session = AVAssetExportSession(asset: built.composition, presetName: AVAssetExportPresetHighestQuality) else {
            completion(nil); return
        }
        session.outputURL = out
        session.outputFileType = .mp4
        session.timeRange = range
        session.videoComposition = built.videoComposition
        nonisolated(unsafe) let unsafeSession = session
        nonisolated(unsafe) let cb = completion
        session.exportAsynchronously {
            let ok = unsafeSession.status == .completed
            Task { @MainActor in cb(ok ? out : nil) }
        }
    }
}
