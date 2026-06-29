import AppKit

/// A borderless icon button that highlights with a subtle rounded background
/// when hovered or pressed, matching macOS transport control styling.
@MainActor
final class HoverButton: NSButton {
    private var tracking: NSTrackingArea?
    private var hovering = false { didSet { needsDisplay = true } }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeInActiveApp], owner: self, userInfo: nil)
        addTrackingArea(area)
        tracking = area
    }

    override func mouseEntered(with event: NSEvent) { hovering = true }
    override func mouseExited(with event: NSEvent) { hovering = false }

    override func draw(_ dirtyRect: NSRect) {
        let r = bounds.insetBy(dx: 1, dy: 1)
        if isHighlighted {
            NSColor(white: 0.5, alpha: 0.45).setFill()
            NSBezierPath(roundedRect: r, xRadius: 6, yRadius: 6).fill()
        } else if hovering {
            NSColor(white: 0.5, alpha: 0.28).setFill()
            NSBezierPath(roundedRect: r, xRadius: 6, yRadius: 6).fill()
        }
        super.draw(dirtyRect)
    }
}

/// Receives interactive timeline changes from `VideoTimelineView`.
@MainActor
protocol VideoTimelineViewDelegate: AnyObject {
    /// The trim selection or playhead changed because the user dragged a grip
    /// or scrubbed. `scrubbing` is true while a drag is in flight.
    func timelineDidChangeSelection(start: Double, end: Double)
    func timelineDidScrub(to position: Double, scrubbing: Bool)
}

/// A custom scrub bar mirroring ZoomIt's trim timeline: a full-duration track
/// with a blue active selection, muted ends, draggable start/end grips, a
/// playhead with a circular knob, tick labels, and markers for appended-clip
/// boundaries. Styled for macOS dark UI rather than the Win32 look.
@MainActor
final class VideoTimelineView: NSView {
    weak var delegate: VideoTimelineViewDelegate?

    /// Total media duration in seconds.
    var duration: Double = 1 { didSet { needsDisplay = true } }
    /// Trim selection bounds (seconds).
    var trimStart: Double = 0 { didSet { needsDisplay = true } }
    var trimEnd: Double = 1 { didSet { needsDisplay = true } }
    /// Current playhead (seconds).
    var position: Double = 0 { didSet { needsDisplay = true } }
    /// Boundary times (seconds) of appended clips, drawn as markers.
    var clipBoundaries: [Double] = [] { didSet { needsDisplay = true } }

    private enum Drag { case none, start, end, playhead }
    private var drag: Drag = .none

    private let pad: CGFloat = 14
    private let trackHeight: CGFloat = 10
    private let gripHalf: CGFloat = 7
    private let gripHeight: CGFloat = 26

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }

    private var trackRect: CGRect {
        CGRect(x: pad, y: bounds.midY - trackHeight / 2,
               width: bounds.width - pad * 2, height: trackHeight)
    }

    private func x(for t: Double) -> CGFloat {
        let track = trackRect
        guard duration > 0 else { return track.minX }
        return track.minX + CGFloat(t / duration) * track.width
    }

    private func time(forX px: CGFloat) -> Double {
        let track = trackRect
        guard track.width > 0 else { return 0 }
        let frac = max(0, min(1, (px - track.minX) / track.width))
        return frac * duration
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        let track = trackRect
        let startX = x(for: trimStart)
        let endX = x(for: trimEnd)

        // Base track.
        let radius = trackHeight / 2
        ctx.setFillColor(NSColor(white: 0.28, alpha: 1).cgColor)
        ctx.addPath(CGPath(roundedRect: track, cornerWidth: radius, cornerHeight: radius, transform: nil))
        ctx.fillPath()

        // Active selection.
        let active = CGRect(x: startX, y: track.minY, width: max(0, endX - startX), height: track.height)
        ctx.setFillColor(NSColor.controlAccentColor.cgColor)
        ctx.addPath(CGPath(roundedRect: active, cornerWidth: radius, cornerHeight: radius, transform: nil))
        ctx.fillPath()

        // Appended-clip boundary markers.
        ctx.setStrokeColor(NSColor(white: 0.05, alpha: 0.9).cgColor)
        ctx.setLineWidth(2)
        for b in clipBoundaries where b > 0 && b < duration {
            let bx = x(for: b)
            ctx.move(to: CGPoint(x: bx, y: track.minY))
            ctx.addLine(to: CGPoint(x: bx, y: track.maxY))
            ctx.strokePath()
        }

        // Tick labels.
        drawTicks(in: track)

        // Grips.
        drawGrip(at: startX, in: track)
        drawGrip(at: endX, in: track)

        // Playhead.
        let px = x(for: position)
        ctx.setStrokeColor(NSColor.systemBlue.cgColor)
        ctx.setLineWidth(2)
        ctx.move(to: CGPoint(x: px, y: track.minY - 12))
        ctx.addLine(to: CGPoint(x: px, y: track.maxY + 12))
        ctx.strokePath()
        ctx.setFillColor(NSColor.systemBlue.cgColor)
        ctx.fillEllipse(in: CGRect(x: px - 6, y: track.maxY + 8, width: 12, height: 12))
    }

    private func drawGrip(at gx: CGFloat, in track: CGRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        let rect = CGRect(x: gx - gripHalf, y: track.midY - gripHeight / 2,
                          width: gripHalf * 2, height: gripHeight)
        ctx.setFillColor(NSColor(white: 0.78, alpha: 1).cgColor)
        ctx.addPath(CGPath(roundedRect: rect, cornerWidth: 4, cornerHeight: 4, transform: nil))
        ctx.fillPath()
        ctx.setStrokeColor(NSColor(white: 0.4, alpha: 1).cgColor)
        ctx.setLineWidth(2)
        ctx.move(to: CGPoint(x: gx, y: rect.minY + 6))
        ctx.addLine(to: CGPoint(x: gx, y: rect.maxY - 6))
        ctx.strokePath()
    }

    private func drawTicks(in track: CGRect) {
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 9),
            .foregroundColor: NSColor.secondaryLabelColor
        ]
        for frac in [0.0, 0.25, 0.5, 0.75, 1.0] {
            let t = frac * duration
            let tx = x(for: t)
            let text = Self.format(t) as NSString
            let size = text.size(withAttributes: attrs)
            var ox = tx - size.width / 2
            ox = max(0, min(bounds.width - size.width, ox))
            text.draw(at: CGPoint(x: ox, y: track.maxY + 16), withAttributes: attrs)
        }
    }

    static func format(_ seconds: Double) -> String {
        let s = max(0, seconds)
        let m = Int(s) / 60
        let sec = Int(s) % 60
        let cs = Int((s - floor(s)) * 100)
        return String(format: "%d:%02d.%02d", m, sec, cs)
    }

    override func mouseDown(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        let startX = x(for: trimStart), endX = x(for: trimEnd), pos = x(for: position)
        let dStart = abs(p.x - startX), dEnd = abs(p.x - endX), dPos = abs(p.x - pos)
        // Prefer the playhead when it is within reach, even when sitting on top
        // of a grip, so it can always be dragged away. Otherwise pick the
        // nearest grip.
        if dPos <= 8 {
            drag = .playhead
        } else if dStart <= gripHalf + 4 || dEnd <= gripHalf + 4 {
            drag = dStart <= dEnd ? .start : .end
        } else {
            drag = .playhead
            position = time(forX: p.x)
            delegate?.timelineDidScrub(to: position, scrubbing: true)
        }
        handleDrag(p)
    }

    override func mouseDragged(with event: NSEvent) {
        handleDrag(convert(event.locationInWindow, from: nil))
    }

    override func mouseUp(with event: NSEvent) {
        if drag == .playhead { delegate?.timelineDidScrub(to: position, scrubbing: false) }
        drag = .none
    }

    private func handleDrag(_ p: CGPoint) {
        let t = time(forX: p.x)
        switch drag {
        case .start:
            trimStart = min(t, trimEnd - 0.05)
            position = trimStart
            delegate?.timelineDidChangeSelection(start: trimStart, end: trimEnd)
            delegate?.timelineDidScrub(to: position, scrubbing: true)
        case .end:
            trimEnd = max(t, trimStart + 0.05)
            position = trimEnd
            delegate?.timelineDidChangeSelection(start: trimStart, end: trimEnd)
            delegate?.timelineDidScrub(to: position, scrubbing: true)
        case .playhead:
            position = t
            delegate?.timelineDidScrub(to: position, scrubbing: true)
        case .none:
            break
        }
    }
}
