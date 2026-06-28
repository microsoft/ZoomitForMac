import CoreGraphics

@MainActor
final class ZoomViewportController {
    private(set) var zoomFactor: CGFloat = 1
    private(set) var targetZoomFactor: CGFloat = 2
    private var telescopeStep: CGFloat = 0
    private(set) var capturedFrame: CapturedFrame?

    // Matches ZoomIt's ZOOM_LEVEL_STEP_IN / ZOOM_LEVEL_STEP_OUT telescope factors.
    private static let stepIn: CGFloat = 1.1
    private static let stepOut: CGFloat = 0.8

    func configure(for frame: CapturedFrame, initialZoom: CGFloat) {
        capturedFrame = frame
        targetZoomFactor = Self.clampZoom(initialZoom)
        zoomFactor = targetZoomFactor
        telescopeStep = 0
    }

    func setZoomFactor(_ factor: CGFloat) {
        zoomFactor = Self.clampZoom(factor)
        targetZoomFactor = zoomFactor
        telescopeStep = 0
    }

    /// Restarts the displayed zoom at 1x so it can telescope back in to the
    /// configured target, matching ZoomIt's zoom-in animation on activation.
    func beginZoomInAnimation() {
        zoomFactor = 1
        telescopeStep = targetZoomFactor > 1 ? Self.stepIn : 0
    }

    /// Sets a new target and chooses the telescope direction for animation.
    func animateZoom(to factor: CGFloat) {
        targetZoomFactor = Self.clampZoom(factor)
        if targetZoomFactor > zoomFactor {
            telescopeStep = Self.stepIn
        } else if targetZoomFactor < zoomFactor {
            telescopeStep = Self.stepOut
        } else {
            telescopeStep = 0
        }
    }

    var isAnimatingZoom: Bool { telescopeStep != 0 }

    /// Advances the telescope by one step. Returns `true` while still animating.
    @discardableResult
    func advanceZoomAnimation() -> Bool {
        guard telescopeStep != 0 else { return false }

        zoomFactor *= telescopeStep
        if (telescopeStep > 1 && zoomFactor >= targetZoomFactor) ||
            (telescopeStep < 1 && zoomFactor <= targetZoomFactor) {
            zoomFactor = targetZoomFactor
            telescopeStep = 0
            return false
        }
        return true
    }

    private static func clampZoom(_ factor: CGFloat) -> CGFloat {
        min(max(factor, 1), 32)
    }

    // Matches ZoomIt's LIVEZOOM_MOVE_REGIONS so panning reaches the screen edges.
    private static let moveRegions: CGFloat = 8

    func sourceRect(for destinationBounds: CGRect, cursorLocation: CGPoint?) -> CGRect {
        guard let frame = capturedFrame else { return destinationBounds }

        let width = destinationBounds.width
        let height = destinationBounds.height
        let sourceWidth = width / zoomFactor
        let sourceHeight = height / zoomFactor
        let localCursor = cursorLocation.map { point in
            CGPoint(x: point.x - frame.display.frame.minX, y: frame.display.frame.maxY - point.y)
        } ?? CGPoint(x: width / 2, y: height / 2)

        // Position the zoom box so the content under the cursor stays anchored
        // under the cursor (ZoomIt's GetZoomedTopLeftCoordinates), which avoids
        // the view jumping when the mouse first moves after activation.
        var originX = min(max(localCursor.x - (localCursor.x / width) * sourceWidth, 0), max(width - sourceWidth, 0))
        originX = adjustToMoveBoundary(coordinate: originX, cursor: localCursor.x, size: sourceWidth, max: width)
        var originY = min(max(localCursor.y - (localCursor.y / height) * sourceHeight, 0), max(height - sourceHeight, 0))
        originY = adjustToMoveBoundary(coordinate: originY, cursor: localCursor.y, size: sourceHeight, max: height)

        return CGRect(x: originX, y: originY, width: sourceWidth, height: sourceHeight)
    }

    private func adjustToMoveBoundary(coordinate: CGFloat, cursor: CGFloat, size: CGFloat, max maxValue: CGFloat) -> CGFloat {
        let diff = size / ZoomViewportController.moveRegions
        if cursor - coordinate < diff {
            return Swift.max(0, cursor - diff)
        } else if (coordinate + size) - cursor < diff {
            return Swift.min(cursor + diff - size, maxValue - size)
        }
        return coordinate
    }

    func contentPoint(for viewPoint: CGPoint, destinationBounds: CGRect, cursorLocation: CGPoint?) -> CGPoint {
        let source = sourceRect(for: destinationBounds, cursorLocation: cursorLocation)
        return CGPoint(
            x: source.minX + (viewPoint.x / destinationBounds.width) * source.width,
            y: source.minY + (viewPoint.y / destinationBounds.height) * source.height
        )
    }

    func contentToDestinationTransform(source: CGRect, destinationBounds: CGRect) -> CGAffineTransform {
        let scaleX = destinationBounds.width / source.width
        let scaleY = destinationBounds.height / source.height

        return CGAffineTransform(
            a: scaleX,
            b: 0,
            c: 0,
            d: scaleY,
            tx: destinationBounds.minX - source.minX * scaleX,
            ty: destinationBounds.minY - source.minY * scaleY
        )
    }
}