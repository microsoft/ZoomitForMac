import AppKit
import AVFoundation
import AVKit

@MainActor
private final class VideoEditorWindow: NSWindow {
    weak var editorController: VideoClipEditorController?

    override func keyDown(with event: NSEvent) {
        if editorController?.handleEditorKey(event) == true { return }
        super.keyDown(with: event)
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if editorController?.handleEditorKey(event) == true { return true }
        return super.performKeyEquivalent(with: event)
    }
}

/// Shows ZoomIt's recording in a clip editor before saving, mirroring the
/// Windows trim dialog: preview, a scrub timeline with trim grips, transport
/// controls, append-with-transition, and Save. Styled for macOS.
@MainActor
final class VideoClipEditorController: NSObject, NSWindowDelegate, VideoTimelineViewDelegate {
    enum Transition: CaseIterable {
        case fadeBlack, none, fadeWhite

        var title: String {
            switch self {
            case .fadeBlack: "Fade to Black"
            case .none: "No Transition"
            case .fadeWhite: "Fade to White"
            }
        }
    }

    private enum JoinKind { case append, delete }

    private struct EditorSnapshot {
        let segments: [ClipSegment]
        let joinTransitions: [Transition]
        let joinKinds: [JoinKind]
        let trimStart: Double
        let trimEnd: Double
        let seekPosition: Double
    }

    private struct ClipSegment {
        var asset: AVURLAsset
        var range: CMTimeRange

        var duration: CMTime { range.duration }
        var durationSeconds: Double { max(range.duration.seconds, 0) }
    }

    private var window: NSWindow?
    private var playerView: AVPlayerView!
    private var player: AVPlayer?
    private var timeline: VideoTimelineView!
    private var positionLabel: NSTextField!
    private var playButton: NSButton!
    private var volumeButton: NSButton!
    private var volumeSlider: NSSlider!
    private var transitionPopup: NSPopUpButton!
    private var deleteButton: NSButton!

    /// The segments making up the composition (in order). The first starts as
    /// the original recording; more are appended or split by delete edits.
    private var segments: [ClipSegment] = []
    private var joinTransitions: [Transition] = []
    private var joinKinds: [JoinKind] = []
    private var selectedTransition: Transition = .fadeBlack
    private var duration: Double = 0
    private var trimStart: Double = 0
    private var trimEnd: Double = 0
    private var timeObserver: Any?
    private var isPlaying = false
    private var isMuted = false
    private var lastAudibleVolume: Float = 1
    private var pendingDeleteStart: Double?
    private var pendingDeleteEnd: Double?
    private var undoStack: [EditorSnapshot] = []

    private var onSave: ((URL) -> Void)?
    private var onCancel: (() -> Void)?
    private var suggestedName = "ZoomIt.mp4"
    private var preferredWindowLevel: NSWindow.Level = .normal
    private var originalURL: URL?

    /// Shows the editor for `tempURL`. Calls `onSave` with an exported MP4 of the
    /// edited result, or `onCancel` if dismissed.
    func present(tempURL: URL, suggestedName: String,
                 windowLevel: NSWindow.Level = .normal,
                 onSave: @escaping (URL) -> Void, onCancel: @escaping () -> Void) {
        self.onSave = onSave
        self.onCancel = onCancel
        self.suggestedName = suggestedName
        self.preferredWindowLevel = windowLevel
        self.originalURL = tempURL
        let asset = AVURLAsset(url: tempURL)
        segments = [ClipSegment(asset: asset, range: CMTimeRange(start: .zero, duration: asset.duration))]
        joinTransitions = []
        joinKinds = []
        selectedTransition = .fadeBlack
        duration = max(asset.duration.seconds, 0.1)
        trimStart = 0
        trimEnd = duration
        pendingDeleteStart = nil
        pendingDeleteEnd = nil
        undoStack = []
        buildWindow()
        rebuildPlayer()
    }

    private func buildWindow() {
        let win = VideoEditorWindow(
            contentRect: NSRect(x: 0, y: 0, width: 720, height: 560),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered, defer: false
        )
        win.editorController = self
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
        deleteButton = NSButton(title: "Delete Region", target: self, action: #selector(commitPendingDelete))
        deleteButton.bezelStyle = .rounded
        deleteButton.image = NSImage(systemSymbolName: "trash", accessibilityDescription: nil)
        deleteButton.imagePosition = .imageLeading
        deleteButton.contentTintColor = .systemRed
        deleteButton.toolTip = "Delete selected timeline region (Delete). Undo with Command-Z."
        deleteButton.isEnabled = false
        let transitionLabel = NSTextField(labelWithString: "Transition:")
        transitionLabel.textColor = .secondaryLabelColor
        transitionPopup = NSPopUpButton()
        transitionPopup.addItems(withTitles: Transition.allCases.map(\.title))
        transitionPopup.selectItem(at: Transition.allCases.firstIndex(of: selectedTransition) ?? 0)
        transitionPopup.target = self
        transitionPopup.action = #selector(transitionChanged)
        let cancel = NSButton(title: "Cancel", target: self, action: #selector(cancel))
        cancel.bezelStyle = .rounded
        let save = NSButton(title: "Save…", target: self, action: #selector(save))
        save.bezelStyle = .rounded
        save.keyEquivalent = "\r"
        let transitionControls = NSStackView(views: [transitionLabel, transitionPopup])
        transitionControls.spacing = 6
        transitionControls.alignment = .centerY
        let bottom = NSStackView(views: [append, deleteButton, transitionControls, NSView(), cancel, save])
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
        // make the Dock tile appear reliably. Bring the editor to the front once
        // when it first appears (it stays a normal-level window afterwards, so
        // it can be sent behind other apps).
        win.makeKeyAndOrderFront(nil)
        DispatchQueue.main.async {
            ZoomItAppIcon.apply()
            NSApp.setActivationPolicy(.regular)
            ZoomItAppIcon.apply()
            NSApp.activate(ignoringOtherApps: true)
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
        item.audioMix = comp.audioMix
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
        var bound = 0.0; var appendMarks: [Double] = []; var deleteMarks: [Double] = []
        for index in 0..<max(0, segments.count - 1) {
            bound += segments[index].durationSeconds
            switch joinKinds[index] {
            case .append: appendMarks.append(bound)
            case .delete: deleteMarks.append(bound)
            }
        }
        timeline.clipBoundaries = appendMarks
        timeline.deleteJoinMarkers = deleteMarks
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
    func timelineDidChangePendingDelete(start: Double, end: Double) {
        pendingDeleteStart = start
        pendingDeleteEnd = end
        syncDeleteButton()
    }
    func timelineDidCommitDeleteSelection() { commitPendingDelete() }
    func timelineDidRequestUndo() { undoLastEdit() }

    fileprivate func handleEditorKey(_ event: NSEvent) -> Bool {
        if event.modifierFlags.intersection(.deviceIndependentFlagsMask).contains(.command),
           event.charactersIgnoringModifiers?.lowercased() == "z" {
            undoLastEdit()
            return true
        }
        if event.keyCode == 51 || event.keyCode == 117 {
            commitPendingDelete()
            return true
        }
        return false
    }

    @objc private func transitionChanged() {
        let index = transitionPopup.indexOfSelectedItem
        guard Transition.allCases.indices.contains(index) else { return }
        selectedTransition = Transition.allCases[index]
        // The popup is a single global control. Apply the newly chosen
        // transition to the existing append boundaries and rebuild the preview
        // so switching (e.g. Fade to Black -> Fade to White) takes effect
        // immediately instead of keeping the transition captured at append time.
        guard !joinTransitions.isEmpty else { return }
        let isAppendJoin = joinKinds.map { kind -> Bool in
            if case .append = kind { return true }
            return false
        }
        let updated = Self.updatedJoinTransitions(current: joinTransitions,
                                                  isAppendJoin: isAppendJoin,
                                                  newTransition: selectedTransition)
        guard updated != joinTransitions else { return }
        pushUndoSnapshot()
        joinTransitions = updated
        rebuildPlayer()
        syncTimeline()
    }

    /// Recomputes join transitions when the (global) transition popup changes:
    /// every append boundary adopts the newly chosen transition, while
    /// delete-seam joins keep their existing transition.
    static func updatedJoinTransitions(current: [Transition], isAppendJoin: [Bool], newTransition: Transition) -> [Transition] {
        zip(current, isAppendJoin).map { $0.1 ? newTransition : $0.0 }
    }

    private func syncDeleteButton() {
        let selectedDuration = (pendingDeleteEnd ?? 0) - (pendingDeleteStart ?? 0)
        deleteButton?.isEnabled = selectedDuration >= 0.05
    }

    // MARK: - Append

    @objc private func appendClip() {
        pause()
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.mpeg4Movie, .quickTimeMovie]
        panel.title = "Select Video to Append"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let asset = AVURLAsset(url: url)
        segments.append(ClipSegment(asset: asset, range: CMTimeRange(start: .zero, duration: asset.duration)))
        joinTransitions.append(selectedTransition)
        joinKinds.append(.append)
        trimEnd = .greatestFiniteMagnitude // rebuild clamps to the new full duration
        rebuildPlayer()
        trimEnd = duration
        seek(trimStart)
        syncTimeline()
    }

    @objc private func commitPendingDelete() {
        guard let pendingDeleteStart, let pendingDeleteEnd else { return }
        deleteRange(start: pendingDeleteStart, end: pendingDeleteEnd)
    }

    private func deleteRange(start: Double, end: Double) {
        let deleteStart = max(0, min(start, duration))
        let deleteEnd = max(0, min(end, duration))
        let deleteDuration = deleteEnd - deleteStart
        guard deleteDuration >= 0.05, duration - deleteDuration >= 0.05 else { return }
        pushUndoSnapshot()
        let oldJoinTransitions = joinTransitions
        let oldJoinKinds = joinKinds
        let oldTrimStart = trimStart
        let oldTrimEnd = trimEnd

        struct Piece {
            var segment: ClipSegment
            var index: Int
            var oldStart: Double
            var oldEnd: Double
            var segmentOldStart: Double
            var segmentOldEnd: Double
        }

        var pieces: [Piece] = []
        var cursor = 0.0
        for (index, segment) in segments.enumerated() {
            let segmentStart = cursor
            let segmentEnd = cursor + segment.durationSeconds
            let leftEnd = min(segmentEnd, deleteStart)
            if leftEnd > segmentStart {
                let keptDuration = leftEnd - segmentStart
                pieces.append(Piece(
                    segment: ClipSegment(asset: segment.asset, range: CMTimeRange(start: segment.range.start, duration: cmTime(keptDuration))),
                    index: index,
                    oldStart: segmentStart,
                    oldEnd: leftEnd,
                    segmentOldStart: segmentStart,
                    segmentOldEnd: segmentEnd
                ))
            }
            let rightStart = max(segmentStart, deleteEnd)
            if rightStart < segmentEnd {
                let sourceOffset = rightStart - segmentStart
                let keptDuration = segmentEnd - rightStart
                pieces.append(Piece(
                    segment: ClipSegment(
                        asset: segment.asset,
                        range: CMTimeRange(start: CMTimeAdd(segment.range.start, cmTime(sourceOffset)), duration: cmTime(keptDuration))
                    ),
                    index: index,
                    oldStart: rightStart,
                    oldEnd: segmentEnd,
                    segmentOldStart: segmentStart,
                    segmentOldEnd: segmentEnd
                ))
            }
            cursor = segmentEnd
        }

        segments = pieces.map(\.segment)
        joinTransitions = []
        joinKinds = []
        for index in 1..<pieces.count {
            let previous = pieces[index - 1]
            let current = pieces[index]
            if current.oldStart - previous.oldEnd > 0.001 {
                joinTransitions.append(selectedTransition)
                joinKinds.append(.delete)
            } else if previous.index + 1 == current.index,
                      abs(previous.oldEnd - previous.segmentOldEnd) <= 0.001,
                      abs(current.oldStart - current.segmentOldStart) <= 0.001,
                      oldJoinTransitions.indices.contains(previous.index) {
                joinTransitions.append(oldJoinTransitions[previous.index])
                joinKinds.append(oldJoinKinds[previous.index])
            } else {
                joinTransitions.append(.none)
                joinKinds.append(.append)
            }
        }

        func mappedTimeAfterDelete(_ time: Double) -> Double {
            if time <= deleteStart { return time }
            if time >= deleteEnd { return time - deleteDuration }
            return deleteStart
        }

        trimStart = mappedTimeAfterDelete(oldTrimStart)
        trimEnd = max(trimStart + 0.05, mappedTimeAfterDelete(oldTrimEnd))
        rebuildPlayer()
        trimEnd = min(trimEnd, duration)
        seek(min(deleteStart, duration))
        pendingDeleteStart = nil
        pendingDeleteEnd = nil
        timeline.clearPendingDeleteSelection()
        syncDeleteButton()
        syncTimeline()
    }

    private func pushUndoSnapshot() {
        undoStack.append(EditorSnapshot(
            segments: segments,
            joinTransitions: joinTransitions,
            joinKinds: joinKinds,
            trimStart: trimStart,
            trimEnd: trimEnd,
            seekPosition: player?.currentTime().seconds ?? trimStart
        ))
    }

    private func undoLastEdit() {
        guard let snapshot = undoStack.popLast() else { return }
        segments = snapshot.segments
        joinTransitions = snapshot.joinTransitions
        joinKinds = snapshot.joinKinds
        trimStart = snapshot.trimStart
        trimEnd = snapshot.trimEnd
        pendingDeleteStart = nil
        pendingDeleteEnd = nil
        timeline.clearPendingDeleteSelection()
        rebuildPlayer()
        trimEnd = min(trimEnd, duration)
        seek(min(snapshot.seekPosition, duration))
        syncDeleteButton()
        syncTimeline()
    }

    // MARK: - Save / Cancel

    @objc private func cancel() { closeWindow(); onCancel?() }

    @objc private func save() {
        pause()
        if canSaveOriginalWithoutExport(), let originalURL {
            closeWindow()
            onSave?(originalURL)
            return
        }
        export { [weak self] url in
            self?.closeWindow()
            if let url { self?.onSave?(url) } else { self?.onCancel?() }
        }
    }

    private func canSaveOriginalWithoutExport() -> Bool {
        guard segments.count == 1, joinTransitions.isEmpty else { return false }
        guard abs(segments[0].range.start.seconds) <= 1.0 / 600.0,
              abs(segments[0].range.duration.seconds - duration) <= 1.0 / 600.0 else { return false }
        let tolerance = 1.0 / 600.0
        return trimStart <= tolerance && abs(trimEnd - duration) <= tolerance
    }

    func windowWillClose(_ notification: Notification) {
        tearDownPlayback()
        window = nil
        NSApp.setActivationPolicy(.accessory)
        onCancel?(); onCancel = nil; onSave = nil
    }

    private func closeWindow() {
        tearDownPlayback()
        window?.orderOut(nil)
        window = nil
        NSApp.setActivationPolicy(.accessory)
    }

    private func tearDownPlayback() {
        if let observer = timeObserver {
            player?.removeTimeObserver(observer)
            timeObserver = nil
        }
        player?.pause()
        playerView?.player = nil
        player = nil
        isPlaying = false
        playButton?.image = NSImage(systemSymbolName: "play.fill", accessibilityDescription: nil)
    }

    // MARK: - Composition

    private struct Built {
        let composition: AVMutableComposition
        let videoComposition: AVMutableVideoComposition?
        let audioMix: AVMutableAudioMix?
    }

    private struct AudioSegment {
        let track: AVMutableCompositionTrack
        let start: CMTime
        let end: CMTime
    }

    private func cmTime(_ seconds: Double) -> CMTime {
        CMTime(seconds: seconds, preferredTimescale: 600)
    }

    private func buildComposition() -> Built {
        let comp = AVMutableComposition()
        guard let vTrack = comp.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid) else {
            return Built(composition: comp, videoComposition: nil, audioMix: nil)
        }
        var audioSegments: [AudioSegment] = []
        var cursor = CMTime.zero
        var boundaries: [CMTime] = []
        var segments: [(start: CMTime, size: CGSize)] = []
        var renderSize = CGSize(width: 1280, height: 720)
        for (index, segment) in self.segments.enumerated() {
            if let v = segment.asset.tracks(withMediaType: .video).first {
                try? vTrack.insertTimeRange(segment.range, of: v, at: cursor)
                // Account for the track's preferred transform so rotated clips
                // report their displayed size.
                let s = v.naturalSize.applying(v.preferredTransform)
                let size = CGSize(width: abs(s.width), height: abs(s.height))
                segments.append((cursor, size))
                if index == 0 { renderSize = size }
                renderSize.width = max(renderSize.width, size.width)
                renderSize.height = max(renderSize.height, size.height)
            }
            for a in segment.asset.tracks(withMediaType: .audio) {
                if let track = comp.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) {
                    try? track.insertTimeRange(segment.range, of: a, at: cursor)
                    audioSegments.append(AudioSegment(track: track, start: cursor, end: CMTimeAdd(cursor, segment.duration)))
                }
            }
            cursor = CMTimeAdd(cursor, segment.duration)
            if index < self.segments.count - 1 { boundaries.append(cursor) }
        }

        // Nothing to scale and no fades: play the single clip as-is.
        let fades = zip(boundaries, joinTransitions).filter { $0.1 != .none }
        let needsScaling = segments.contains { abs($0.size.width - renderSize.width) > 1 || abs($0.size.height - renderSize.height) > 1 }
        guard !fades.isEmpty || needsScaling else { return Built(composition: comp, videoComposition: nil, audioMix: nil) }

        let fadeDur = CMTime(seconds: 1, preferredTimescale: 600)
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
        // Opacity ramps for all fades live on a single layer instruction, so
        // adjacent fades must not overlap or `setOpacityRamp` throws. Clamp each
        // fade against its neighbouring faded boundaries (splitting the gap so
        // ramps meet at the midpoint) and against the composition edges.
        for (index, entry) in fades.enumerated() {
            let time = entry.0
            let previousBoundary = index > 0 ? fades[index - 1].0 : nil
            let nextBoundary = index < fades.count - 1 ? fades[index + 1].0 : nil
            let ranges = transitionRanges(at: time, fadeDuration: fadeDur, compositionDuration: comp.duration,
                                          previousBoundary: previousBoundary, nextBoundary: nextBoundary)
            if let outRange = ranges.out {
                layer.setOpacityRamp(fromStartOpacity: 1, toEndOpacity: 0, timeRange: outRange)
            }
            if let inRange = ranges.in {
                layer.setOpacityRamp(fromStartOpacity: 0, toEndOpacity: 1, timeRange: inRange)
            }
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
        let audioMix = buildAudioMix(for: audioSegments, fades: fades, fadeDuration: fadeDur)
        return Built(composition: comp, videoComposition: vc, audioMix: audioMix)
    }

    private func transitionRanges(at time: CMTime, fadeDuration: CMTime, compositionDuration: CMTime,
                                  previousBoundary: CMTime? = nil, nextBoundary: CMTime? = nil) -> (out: CMTimeRange?, in: CMTimeRange?) {
        let timescale = fadeDuration.timescale
        // Available space before this boundary: to the composition start, or to
        // the midpoint with the previous faded boundary so the two ramps meet
        // instead of overlapping.
        let spaceBefore: Double
        if let previousBoundary {
            spaceBefore = max(0, (time.seconds - previousBoundary.seconds) / 2)
        } else {
            spaceBefore = max(0, time.seconds)
        }
        let spaceAfter: Double
        if let nextBoundary {
            spaceAfter = max(0, (nextBoundary.seconds - time.seconds) / 2)
        } else {
            spaceAfter = max(0, compositionDuration.seconds - time.seconds)
        }
        let outSeconds = min(fadeDuration.seconds, spaceBefore)
        let inSeconds = min(fadeDuration.seconds, spaceAfter)
        let outDuration = CMTime(seconds: outSeconds, preferredTimescale: timescale)
        let inDuration = CMTime(seconds: inSeconds, preferredTimescale: timescale)
        let outRange = outSeconds > 0 ? CMTimeRange(start: CMTimeSubtract(time, outDuration), duration: outDuration) : nil
        let inRange = inSeconds > 0 ? CMTimeRange(start: time, duration: inDuration) : nil
        return (outRange, inRange)
    }

    private func buildAudioMix(for audioSegments: [AudioSegment], fades: [(CMTime, Transition)], fadeDuration: CMTime) -> AVMutableAudioMix? {
        guard !audioSegments.isEmpty, !fades.isEmpty else { return nil }
        let parameters = audioSegments.map { audioSegment in
            let parameter = AVMutableAudioMixInputParameters(track: audioSegment.track)
            parameter.setVolume(1, at: .zero)
            for (time, _) in fades {
                if sameTime(audioSegment.end, time) {
                    let duration = min(fadeDuration.seconds, max(0, CMTimeSubtract(audioSegment.end, audioSegment.start).seconds))
                    if duration > 0 {
                        let fade = CMTime(seconds: duration, preferredTimescale: fadeDuration.timescale)
                        let fadeStart = CMTimeSubtract(audioSegment.end, fade)
                        parameter.setVolume(1, at: fadeStart)
                        parameter.setVolumeRamp(
                            fromStartVolume: 1,
                            toEndVolume: 0,
                            timeRange: CMTimeRange(start: fadeStart, duration: fade)
                        )
                        parameter.setVolume(0, at: audioSegment.end)
                    }
                }
                if sameTime(audioSegment.start, time) {
                    let duration = min(fadeDuration.seconds, max(0, CMTimeSubtract(audioSegment.end, audioSegment.start).seconds))
                    if duration > 0 {
                        let fade = CMTime(seconds: duration, preferredTimescale: fadeDuration.timescale)
                        parameter.setVolume(0, at: audioSegment.start)
                        parameter.setVolumeRamp(
                            fromStartVolume: 0,
                            toEndVolume: 1,
                            timeRange: CMTimeRange(start: audioSegment.start, duration: fade)
                        )
                        parameter.setVolume(1, at: CMTimeAdd(audioSegment.start, fade))
                    }
                }
            }
            return parameter
        }
        let mix = AVMutableAudioMix()
        mix.inputParameters = parameters
        return mix
    }

    private func sameTime(_ lhs: CMTime, _ rhs: CMTime) -> Bool {
        abs(lhs.seconds - rhs.seconds) <= 1.0 / 600.0
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
        session.audioMix = built.audioMix
        nonisolated(unsafe) let unsafeSession = session
        nonisolated(unsafe) let cb = completion
        session.exportAsynchronously {
            let ok = unsafeSession.status == .completed
            Task { @MainActor in cb(ok ? out : nil) }
        }
    }
}
