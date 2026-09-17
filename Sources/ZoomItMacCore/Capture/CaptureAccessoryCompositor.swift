import AppKit

struct CaptureAccessorySnapshot {
    let globalFrame: CGRect
    let image: CGImage
}

struct CaptureAccessoryPlacement: Equatable {
    let drawRect: CGRect
    let clipRect: CGRect
}

struct CaptureAccessoryShadowStyle {
    let padding: CGFloat
    let offset: CGSize
    let blurRadius: CGFloat
    let color: CGColor

    static let inspector = CaptureAccessoryShadowStyle(
        padding: 16,
        offset: CGSize(width: 0, height: -2),
        blurRadius: 10,
        color: NSColor.black.withAlphaComponent(0.32).cgColor
    )
}

enum CaptureAccessoryCompositor {
    static func placement(
        accessoryFrame: CGRect,
        displayFrame: CGRect,
        sourceRegion: CGRect,
        outputPixelSize: CGSize
    ) -> CaptureAccessoryPlacement? {
        let source = sourceRegion.standardized
        guard source.width > 0,
              source.height > 0,
              outputPixelSize.width > 0,
              outputPixelSize.height > 0,
              accessoryFrame.width > 0,
              accessoryFrame.height > 0 else {
            return nil
        }

        let localTopLeftFrame = CGRect(
            x: accessoryFrame.minX - displayFrame.minX,
            y: displayFrame.maxY - accessoryFrame.maxY,
            width: accessoryFrame.width,
            height: accessoryFrame.height
        )
        let displayLocalBounds = CGRect(
            origin: .zero,
            size: displayFrame.size
        )
        let visibleFrame = localTopLeftFrame
            .intersection(displayLocalBounds)
            .intersection(source)
        guard !visibleFrame.isNull,
              visibleFrame.width > 0,
              visibleFrame.height > 0 else {
            return nil
        }

        let scaleX = outputPixelSize.width / source.width
        let scaleY = outputPixelSize.height / source.height
        let relativeX = localTopLeftFrame.minX - source.minX
        let relativeY = localTopLeftFrame.minY - source.minY
        let drawRect = CGRect(
            x: relativeX * scaleX,
            y: outputPixelSize.height
                - (relativeY + localTopLeftFrame.height) * scaleY,
            width: localTopLeftFrame.width * scaleX,
            height: localTopLeftFrame.height * scaleY
        )
        let visibleRelativeX = visibleFrame.minX - source.minX
        let visibleRelativeY = visibleFrame.minY - source.minY
        let clipRect = CGRect(
            x: visibleRelativeX * scaleX,
            y: outputPixelSize.height
                - (visibleRelativeY + visibleFrame.height) * scaleY,
            width: visibleFrame.width * scaleX,
            height: visibleFrame.height * scaleY
        )
        return CaptureAccessoryPlacement(
            drawRect: drawRect,
            clipRect: clipRect
        )
    }

    static func compose(
        baseImage: CGImage,
        displayFrame: CGRect,
        sourceRegion: CGRect,
        outputPixelSize: CGSize,
        accessories: [CaptureAccessorySnapshot]
    ) -> CGImage? {
        let source = sourceRegion.standardized
        let width = Int(outputPixelSize.width.rounded())
        let height = Int(outputPixelSize.height.rounded())
        guard source.width > 0,
              source.height > 0,
              width > 0,
              height > 0,
              let context = CGContext(
                  data: nil,
                  width: width,
                  height: height,
                  bitsPerComponent: 8,
                  bytesPerRow: 0,
                  space: CGColorSpaceCreateDeviceRGB(),
                  bitmapInfo: CGBitmapInfo.byteOrder32Little.rawValue
                      | CGImageAlphaInfo.premultipliedFirst.rawValue
              ) else {
            return nil
        }

        let exactOutputSize = CGSize(width: width, height: height)
        let scaleX = exactOutputSize.width / source.width
        let scaleY = exactOutputSize.height / source.height
        context.interpolationQuality = .high
        context.clear(
            CGRect(origin: .zero, size: exactOutputSize)
        )
        context.draw(
            baseImage,
            in: CGRect(
                x: -source.minX * scaleX,
                y: exactOutputSize.height
                    - (displayFrame.height - source.minY) * scaleY,
                width: displayFrame.width * scaleX,
                height: displayFrame.height * scaleY
            )
        )

        for accessory in accessories {
            guard let placement = placement(
                accessoryFrame: accessory.globalFrame,
                displayFrame: displayFrame,
                sourceRegion: source,
                outputPixelSize: exactOutputSize
            ) else {
                continue
            }
            context.saveGState()
            context.clip(to: placement.clipRect)
            context.draw(accessory.image, in: placement.drawRect)
            context.restoreGState()
        }
        return context.makeImage()
    }
}

@MainActor
enum CaptureAccessorySnapshotRenderer {
    static func snapshot(
        view: NSView,
        globalFrame: CGRect,
        scaleX: CGFloat,
        scaleY: CGFloat,
        shadow: CaptureAccessoryShadowStyle? = nil
    ) -> CaptureAccessorySnapshot? {
        guard globalFrame.width > 0,
              globalFrame.height > 0,
              scaleX > 0,
              scaleY > 0 else {
            return nil
        }
        view.layoutSubtreeIfNeeded()
        view.displayIfNeeded()

        let contentPixelWidth = max(
            1,
            Int(ceil(globalFrame.width * scaleX))
        )
        let contentPixelHeight = max(
            1,
            Int(ceil(globalFrame.height * scaleY))
        )
        guard let representation = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: contentPixelWidth,
            pixelsHigh: contentPixelHeight,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ) else {
            return nil
        }
        representation.size = view.bounds.size
        view.cacheDisplay(in: view.bounds, to: representation)
        guard let contentImage = representation.cgImage else { return nil }

        return snapshot(
            contentImage: contentImage,
            globalFrame: globalFrame,
            scaleX: scaleX,
            scaleY: scaleY,
            shadow: shadow
        )
    }

    static func snapshot(
        contentImage: CGImage,
        globalFrame: CGRect,
        scaleX: CGFloat,
        scaleY: CGFloat,
        shadow: CaptureAccessoryShadowStyle?
    ) -> CaptureAccessorySnapshot? {
        guard let shadow else {
            return CaptureAccessorySnapshot(
                globalFrame: globalFrame,
                image: contentImage
            )
        }

        let snapshotFrame = globalFrame.insetBy(
            dx: -shadow.padding,
            dy: -shadow.padding
        )
        let width = max(1, Int(ceil(snapshotFrame.width * scaleX)))
        let height = max(1, Int(ceil(snapshotFrame.height * scaleY)))
        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGBitmapInfo.byteOrder32Little.rawValue
                | CGImageAlphaInfo.premultipliedFirst.rawValue
        ) else {
            return nil
        }

        context.clear(
            CGRect(x: 0, y: 0, width: width, height: height)
        )
        context.setShadow(
            offset: CGSize(
                width: shadow.offset.width * scaleX,
                height: shadow.offset.height * scaleY
            ),
            blur: shadow.blurRadius * max(scaleX, scaleY),
            color: shadow.color
        )
        context.draw(
            contentImage,
            in: CGRect(
                x: shadow.padding * scaleX,
                y: shadow.padding * scaleY,
                width: globalFrame.width * scaleX,
                height: globalFrame.height * scaleY
            )
        )
        guard let image = context.makeImage() else { return nil }
        return CaptureAccessorySnapshot(
            globalFrame: snapshotFrame,
            image: image
        )
    }
}
