import AppKit

struct AnnotationActiveStrokeCacheCounters: Equatable {
    var rebuiltChunks = 0
    var drawnChunks = 0
}

struct AnnotationCommittedStrokeCacheCounters: Equatable {
    var rebuiltElements = 0
    var cacheHits = 0
    var promotedElements = 0
    var evictedEntries = 0
}

@MainActor
final class AnnotationRenderer {
    private enum ActiveChunkKind {
        case stroke
        case fill
    }

    private struct ActiveChunk {
        var index: Int
        var paths: [CGPath]
        var kind: ActiveChunkKind
        var bounds: CGRect

        init(index: Int, paths: [CGPath], kind: ActiveChunkKind) {
            self.index = index
            self.paths = paths
            self.kind = kind
            bounds = paths.reduce(CGRect.null) { $0.union($1.boundingBoxOfPath) }
        }
    }

    private struct ActiveFreehandCache {
        var elementID: AnnotationElementID
        var style: AnnotationStyle
        var isHighlighter: Bool
        var destinationScale: CGFloat
        var freehand: AnnotationFreehandGeometry
        var sampleCount: Int
        var lastSample: AnnotationPointSample
        var penultimateSample: AnnotationPointSample?
        var cumulativeArcLengths: [CGFloat]
        var chunks: [ActiveChunk]
    }

    private struct CommittedFreehandContentKey: Equatable {
        var freehand: AnnotationFreehandGeometry
        var style: AnnotationStyle
        var rotation: CGFloat

        static func == (
            lhs: CommittedFreehandContentKey,
            rhs: CommittedFreehandContentKey
        ) -> Bool {
            lhs.style == rhs.style
                && lhs.rotation == rhs.rotation
                && renderGeometryMatches(lhs.freehand, rhs.freehand)
        }

        static func renderGeometryMatches(
            _ lhs: AnnotationFreehandGeometry,
            _ rhs: AnnotationFreehandGeometry
        ) -> Bool {
            lhs.isHighlighter == rhs.isHighlighter
                && lhs.samples.count == rhs.samples.count
                && zip(lhs.samples, rhs.samples).allSatisfy {
                    $0.location == $1.location
                        && $0.pressure == $1.pressure
                }
        }
    }

    private struct CommittedFreehandRenderData {
        var paths: [CGPath]
        var kind: ActiveChunkKind
        var lineWidth: CGFloat
        var combinesOpacity: Bool
        var isHighlighter: Bool
    }

    private struct CommittedFreehandCacheEntry {
        var contentKey: CommittedFreehandContentKey
        var destinationScale: CGFloat
        var data: CommittedFreehandRenderData
        var estimatedCost: Int
        var lastAccess: UInt64
    }

    private struct RenderItem {
        var element: AnnotationElement
        var isActive: Bool
        var usesCommittedCache: Bool
        var presentationOpacity: CGFloat
    }

    private static let activeChunkSampleCount = 128
    private static let activeChunkOverlap = 4

    /// Smoothing can change the preceding chunk as well as the current tail.
    /// Invalidate their full extent, including the prior tail before an append.
    static func activeTailBounds(
        of element: AnnotationElement?,
        destinationScale: CGFloat
    ) -> CGRect {
        guard let element, case .freehand(let freehand) = element.geometry,
              let last = freehand.samples.last else { return .null }
        let scale = max(0.001, destinationScale)
        let firstIndex = max(0, (freehand.samples.count - 1 - activeChunkOverlap)
            / activeChunkSampleCount * activeChunkSampleCount - activeChunkOverlap)
        var minX = last.location.x, maxX = minX
        var minY = last.location.y, maxY = minY
        for sample in freehand.samples[firstIndex...] {
            minX = min(minX, sample.location.x)
            maxX = max(maxX, sample.location.x)
            minY = min(minY, sample.location.y)
            maxY = max(maxY, sample.location.y)
        }
        let padding = element.style.strokeWidth
            + (AnnotationRoughStroke.maximumDestinationDeviation(
                for: element.effectiveSloppiness,
                strokeWidth: element.style.strokeWidth
            ) + 2) / scale
        return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
            .applying(AnnotationGeometry.worldTransform(for: element))
            .insetBy(dx: -padding, dy: -padding)
    }
    private static let defaultCommittedStrokeCacheCostLimit = 32 * 1_024 * 1_024
    private static let defaultCommittedStrokeCacheEntryLimit = 512
    private static let committedScaleVariantLimit = 2

    private var activeFreehandCache: ActiveFreehandCache?
    private var committedFreehandCache:
        [AnnotationElementID: [CommittedFreehandCacheEntry]] = [:]
    private var committedStrokeCacheEstimatedCost = 0
    private var committedStrokeCacheAccess: UInt64 = 0
    private let committedStrokeCacheCostLimit: Int
    private let committedStrokeCacheEntryLimit: Int
    private(set) var activeStrokeCacheCountersForTesting =
        AnnotationActiveStrokeCacheCounters()
    private(set) var committedStrokeCacheCountersForTesting =
        AnnotationCommittedStrokeCacheCounters()

    init(
        committedStrokeCacheCostLimit: Int =
            AnnotationRenderer.defaultCommittedStrokeCacheCostLimit,
        committedStrokeCacheEntryLimit: Int =
            AnnotationRenderer.defaultCommittedStrokeCacheEntryLimit
    ) {
        self.committedStrokeCacheCostLimit = max(1, committedStrokeCacheCostLimit)
        self.committedStrokeCacheEntryLimit = max(1, committedStrokeCacheEntryLimit)
    }

    var hasActiveStrokeCacheForTesting: Bool {
        activeFreehandCache != nil
    }

    var committedStrokeCacheEntryCountForTesting: Int {
        committedFreehandCache.values.reduce(0) { $0 + $1.count }
    }

    var committedStrokeCacheEstimatedCostForTesting: Int {
        committedStrokeCacheEstimatedCost
    }

    func committedStrokeCacheScaleVariantCountForTesting(
        elementID: AnnotationElementID
    ) -> Int {
        committedFreehandCache[elementID]?.count ?? 0
    }

    func hasCommittedStrokeCacheForTesting(
        elementID: AnnotationElementID
    ) -> Bool {
        committedFreehandCache[elementID]?.isEmpty == false
    }

    func resetActiveStrokeCache() {
        activeFreehandCache = nil
    }

    func synchronizeCommittedStrokeCache(with elements: [AnnotationElement]) {
        let freehandElementIDs = Set(elements.compactMap { element in
            if case .freehand = element.geometry {
                return element.id
            }
            return nil
        })
        let staleElementIDs = committedFreehandCache.keys.filter {
            !freehandElementIDs.contains($0)
        }
        for elementID in staleElementIDs {
            removeCommittedEntries(for: elementID)
        }
    }

    func promoteActiveStrokeCache(
        for element: AnnotationElement,
        destinationPointScale: CGFloat
    ) {
        guard case .freehand(let freehand) = element.geometry,
              freehand.samples.count > 1,
              let active = activeFreehandCache,
              active.elementID == element.id,
              active.style == element.style,
              active.isHighlighter == freehand.isHighlighter,
              active.destinationScale == max(0.001, destinationPointScale),
              CommittedFreehandContentKey.renderGeometryMatches(
                  active.freehand,
                  freehand
              ),
              active.chunks.count == 1,
              freehand.isHighlighter || element.style.sloppiness == .architect,
              let chunk = active.chunks.first else {
            return
        }

        let usesPressure = !freehand.isHighlighter
            && element.style.pressureEnabled
            && freehand.samples.contains { $0.pressure != nil }
        let data = CommittedFreehandRenderData(
            paths: chunk.paths,
            kind: chunk.kind,
            lineWidth: max(
                1.25 / max(destinationPointScale, 0.001),
                element.style.strokeWidth
            ),
            combinesOpacity: usesPressure,
            isHighlighter: freehand.isHighlighter
        )
        let contentKey = CommittedFreehandContentKey(
            freehand: freehand,
            style: element.style,
            rotation: element.metadata.rotation
        )
        storeCommittedFreehandData(
            data,
            for: element.id,
            contentKey: contentKey,
            freehand: freehand,
            style: element.style,
            destinationScale: max(0.001, destinationPointScale)
        )
        committedStrokeCacheCountersForTesting.promotedElements += 1
    }

    func render(
        elements: [AnnotationElement],
        activeElement: AnnotationElement?,
        destinationPointScale: CGFloat? = nil,
        pendingErasureElementIDs: Set<AnnotationElementID> = [],
        pendingErasureOpacity: CGFloat = 0.28,
        in context: CGContext
    ) {
        synchronizeCommittedStrokeCache(with: elements)
        let all = elements.filter(\.metadata.isVisible).map {
            RenderItem(
                element: $0,
                isActive: false,
                usesCommittedCache: true,
                presentationOpacity: pendingErasureElementIDs.contains($0.id)
                    ? min(1, max(0, pendingErasureOpacity))
                    : 1
            )
        } + (activeElement.map {
            [
                RenderItem(
                    element: $0,
                    isActive: true,
                    usesCommittedCache: false,
                    presentationOpacity: 1
                )
            ]
        } ?? []).filter(\.element.metadata.isVisible)
        var index = all.startIndex
        while index < all.endIndex {
            let presentationOpacity = all[index].presentationOpacity
            let runStart = index
            repeat {
                index = all.index(after: index)
            } while index < all.endIndex
                && abs(all[index].presentationOpacity - presentationOpacity) < 0.0001

            let run = all[runStart..<index]
            if presentationOpacity < 0.9999 {
                context.saveGState()
                context.setAlpha(presentationOpacity)
                context.beginTransparencyLayer(auxiliaryInfo: nil)
                renderItems(
                    run,
                    destinationPointScale: destinationPointScale,
                    in: context
                )
                context.endTransparencyLayer()
                context.restoreGState()
            } else {
                renderItems(
                    run,
                    destinationPointScale: destinationPointScale,
                    in: context
                )
            }
        }
    }

    private func renderItems(
        _ items: ArraySlice<RenderItem>,
        destinationPointScale: CGFloat?,
        in context: CGContext
    ) {
        var index = items.startIndex
        while index < items.endIndex {
            if isNonDarkeningHighlight(items[index].element) {
                let runOpacity = nonDarkeningHighlightOpacity(items[index].element)
                let runStart = index
                repeat {
                    index = items.index(after: index)
                } while index < items.endIndex
                    && isNonDarkeningHighlight(items[index].element)
                    && abs(
                        nonDarkeningHighlightOpacity(items[index].element)
                            - runOpacity
                    ) < 0.0001

                context.saveGState()
                context.setAlpha(runOpacity)
                context.beginTransparencyLayer(auxiliaryInfo: nil)
                for item in items[runStart..<index] {
                    render(
                        item.element,
                        destinationPointScale: destinationPointScale,
                        in: context,
                        forceOpaque: true,
                        isActive: item.isActive,
                        usesCommittedCache: item.usesCommittedCache
                    )
                }
                context.endTransparencyLayer()
                context.restoreGState()
            } else {
                let item = items[index]
                render(
                    item.element,
                    destinationPointScale: destinationPointScale,
                    in: context,
                    isActive: item.isActive,
                    usesCommittedCache: item.usesCommittedCache
                )
                index = items.index(after: index)
            }
        }
    }

    func renderGhost(
        _ element: AnnotationElement,
        opacityMultiplier: CGFloat = 0.58,
        destinationPointScale: CGFloat? = nil,
        in context: CGContext
    ) {
        var ghost = element
        ghost.style.opacity *= min(1, max(0, opacityMultiplier))
        ghost.style.fillStyle = .none
        ghost.style.strokePattern = .dashed
        ghost.style.usesLegacyHighlightCompositing = false

        context.saveGState()
        context.setShadow(
            offset: .zero,
            blur: max(2, ghost.style.strokeWidth * 0.8),
            color: ghost.style.strokeColor.nsColor.withAlphaComponent(0.45).cgColor
        )
        render(
            ghost,
            destinationPointScale: destinationPointScale,
            in: context,
            usesCommittedCache: false
        )
        context.restoreGState()
    }

    func renderFreehandTail(
        from start: AnnotationPointSample,
        to end: AnnotationPointSample,
        style: AnnotationStyle,
        isHighlighter: Bool,
        in context: CGContext
    ) {
        guard start.location != end.location else { return }
        let effectiveOpacity = style.opacity
            * (isHighlighter ? AnnotationStyle.highlightAlpha : 1)
        let color = resolvedColor(
            style.strokeColor,
            opacity: effectiveOpacity,
            forceOpaque: false
        )
        context.saveGState()
        context.setStrokeColor(color.cgColor)
        context.setLineWidth(max(1, style.strokeWidth))
        context.setLineCap(isHighlighter ? .butt : .round)
        context.setLineJoin(isHighlighter ? .bevel : .round)
        context.setLineDash(phase: 0, lengths: [])
        context.beginPath()
        context.move(to: start.location)
        context.addLine(to: end.location)
        context.strokePath()
        context.restoreGState()
    }

    func renderLinearConstruction(
        element: AnnotationElement,
        previewPoint: CGPoint,
        canFinish: Bool,
        zoomScale: CGFloat,
        in context: CGContext
    ) {
        guard case .linear(let committed) = element.geometry,
              let endpoint = committed.points.last else {
            return
        }

        let preview = constructionPreview(for: committed, pointer: previewPoint)
        if committed.points.count > 1 {
            var body = committed
            body.endArrowhead = .none
            if body.route == .curved {
                body.bezierControls = Array(
                    preview.bezierControls.prefix(max(0, body.points.count - 1))
                )
            }
            var bodyElement = element
            bodyElement.geometry = .linear(body)
            render(
                bodyElement,
                destinationPointScale: zoomScale,
                in: context,
                usesCommittedCache: false
            )
        }

        if preview.points.count > committed.points.count {
            let ghostStartIndex = committed.points.count - 1
            var ghost = preview
            ghost.points = Array(preview.points[ghostStartIndex...])
            ghost.startArrowhead = .none
            if ghost.route == .curved {
                ghost.bezierControls = [preview.bezierControls[ghostStartIndex]]
            } else {
                ghost.bezierControls = []
            }
            var ghostElement = element
            ghostElement.geometry = .linear(ghost)
            renderGhost(
                ghostElement,
                destinationPointScale: zoomScale,
                in: context
            )
        }

        guard canFinish else { return }
        let metrics = AnnotationInteractionMetrics(zoomScale: zoomScale)
        let radius = metrics.handleSize * 0.72
        let bounds = CGRect(
            x: endpoint.x - radius,
            y: endpoint.y - radius,
            width: radius * 2,
            height: radius * 2
        )
        context.saveGState()
        context.concatenate(AnnotationGeometry.worldTransform(for: element))
        context.setFillColor(NSColor.controlAccentColor.withAlphaComponent(0.18).cgColor)
        context.setStrokeColor(NSColor.controlAccentColor.cgColor)
        context.setLineWidth(max(metrics.decorationLineWidth * 2, 1 / metrics.zoomScale))
        context.fillEllipse(in: bounds)
        context.strokeEllipse(in: bounds)
        context.restoreGState()
    }

    func renderSelectionDecorations(
        for elements: [AnnotationElement],
        selectedElementIDs: Set<AnnotationElementID>,
        zoomScale: CGFloat,
        in context: CGContext
    ) {
        let selectedElements = AnnotationSelectionPresentation.editableElements(
            from: elements,
            selectedElementIDs: selectedElementIDs
        )
        guard !selectedElements.isEmpty else { return }

        let metrics = AnnotationInteractionMetrics(zoomScale: zoomScale)
        context.saveGState()
        context.setStrokeColor(NSColor.controlAccentColor.cgColor)
        context.setFillColor(NSColor.windowBackgroundColor.cgColor)
        context.setLineWidth(metrics.decorationLineWidth)
        context.setLineDash(phase: 0, lengths: [4 / metrics.zoomScale, 3 / metrics.zoomScale])

        let decorations: [AnnotationSelectionDecoration]
        if selectedElements.count > 1 {
            decorations = AnnotationGeometry.selectionDecoration(
                for: selectedElements,
                zoomScale: zoomScale
            ).map { [$0] } ?? []
        } else {
            decorations = selectedElements.compactMap {
                AnnotationGeometry.selectionDecoration(for: $0, zoomScale: zoomScale)
            }
        }

        for decoration in decorations {
            guard let first = decoration.outline.first else { continue }
            context.beginPath()
            context.move(to: first)
            for point in decoration.outline.dropFirst() {
                context.addLine(to: point)
            }
            context.closePath()
            context.strokePath()

            context.setLineDash(phase: 0, lengths: [])
            context.beginPath()
            context.move(to: decoration.rotationConnector.start)
            context.addLine(to: decoration.rotationConnector.end)
            context.strokePath()

            for handle in decoration.handles {
                if handle.kind == .rotation {
                    context.fillEllipse(in: handle.bounds)
                    context.strokeEllipse(in: handle.bounds)
                } else {
                    context.fill(handle.bounds)
                    context.stroke(handle.bounds)
                }
            }
            context.setLineDash(phase: 0, lengths: [4 / metrics.zoomScale, 3 / metrics.zoomScale])
        }
        context.restoreGState()
    }

    func renderMarquee(
        _ bounds: CGRect,
        zoomScale: CGFloat,
        in context: CGContext
    ) {
        guard bounds.width > 0 || bounds.height > 0 else { return }
        let metrics = AnnotationInteractionMetrics(zoomScale: zoomScale)
        context.saveGState()
        context.setFillColor(NSColor.controlAccentColor.withAlphaComponent(0.08).cgColor)
        context.setStrokeColor(NSColor.controlAccentColor.cgColor)
        context.setLineWidth(metrics.decorationLineWidth)
        context.setLineDash(
            phase: 0,
            lengths: [4 / metrics.zoomScale, 3 / metrics.zoomScale]
        )
        context.fill(bounds)
        context.stroke(bounds)
        context.restoreGState()
    }

    func renderLinearPointEditing(
        for element: AnnotationElement,
        selectedPointIndices: Set<Int>,
        selectedSegmentIndex: Int?,
        selectedControl: AnnotationLinearEditPart?,
        zoomScale: CGFloat,
        in context: CGContext
    ) {
        guard case .linear(let linear) = element.geometry else { return }
        let metrics = AnnotationInteractionMetrics(zoomScale: zoomScale)
        let handleSize = metrics.handleSize

        context.saveGState()
        context.concatenate(AnnotationGeometry.worldTransform(for: element))
        context.setLineWidth(metrics.decorationLineWidth)
        context.setStrokeColor(NSColor.controlAccentColor.cgColor)
        context.setFillColor(NSColor.windowBackgroundColor.cgColor)

        if linear.route == .curved {
            let controls = AnnotationGeometry.bezierControls(for: linear)
            context.setLineDash(phase: 0, lengths: [3 / metrics.zoomScale, 3 / metrics.zoomScale])
            for index in controls.indices {
                context.beginPath()
                context.move(to: linear.points[index])
                context.addLine(to: controls[index].start)
                context.move(to: linear.points[index + 1])
                context.addLine(to: controls[index].end)
                context.strokePath()
            }
            context.setLineDash(phase: 0, lengths: [])
            for index in controls.indices {
                for (end, point) in [
                    (AnnotationLinearControlEnd.start, controls[index].start),
                    (.end, controls[index].end)
                ] {
                    let bounds = CGRect(
                        x: point.x - handleSize * 0.4,
                        y: point.y - handleSize * 0.4,
                        width: handleSize * 0.8,
                        height: handleSize * 0.8
                    )
                    let isSelected = selectedControl
                        == .control(segment: index, end: end)
                    context.setFillColor(
                        (isSelected ? NSColor.controlAccentColor : NSColor.windowBackgroundColor).cgColor
                    )
                    context.fillEllipse(in: bounds)
                    context.strokeEllipse(in: bounds)
                }
            }
        }

        if let selectedSegmentIndex,
           selectedSegmentIndex >= 0,
           selectedSegmentIndex < linear.points.count - 1 {
            context.saveGState()
            context.setStrokeColor(NSColor.controlAccentColor.cgColor)
            context.setLineWidth(max(metrics.decorationLineWidth * 3, element.style.strokeWidth))
            context.beginPath()
            context.move(to: linear.points[selectedSegmentIndex])
            if linear.route == .curved {
                let control = AnnotationGeometry.bezierControls(for: linear)[selectedSegmentIndex]
                context.addCurve(
                    to: linear.points[selectedSegmentIndex + 1],
                    control1: control.start,
                    control2: control.end
                )
            } else {
                context.addLine(to: linear.points[selectedSegmentIndex + 1])
            }
            context.strokePath()
            context.restoreGState()
        }

        for index in linear.points.indices {
            let point = linear.points[index]
            let bounds = CGRect(
                x: point.x - handleSize / 2,
                y: point.y - handleSize / 2,
                width: handleSize,
                height: handleSize
            )
            context.setFillColor(
                (selectedPointIndices.contains(index)
                    ? NSColor.controlAccentColor
                    : NSColor.windowBackgroundColor).cgColor
            )
            context.fillEllipse(in: bounds)
            context.strokeEllipse(in: bounds)
        }
        context.restoreGState()
    }

    private func render(
        _ element: AnnotationElement,
        destinationPointScale: CGFloat?,
        in context: CGContext,
        forceOpaque: Bool = false,
        isActive: Bool = false,
        usesCommittedCache: Bool = false
    ) {
        var renderingStyle = element.style
        renderingStyle.sloppiness = element.effectiveSloppiness
        context.saveGState()
        context.concatenate(AnnotationGeometry.worldTransform(for: element))
        configureStroke(for: renderingStyle, in: context, forceOpaque: forceOpaque)
        let resolvedDestinationScale = max(
            0.001,
            destinationPointScale ?? destinationScale(in: context)
        )

        switch element.geometry {
        case .freehand(let freehand):
            drawFreehand(
                freehand,
                style: renderingStyle,
                elementID: element.id,
                rotation: element.metadata.rotation,
                destinationScale: resolvedDestinationScale,
                isActive: isActive,
                usesCommittedCache: usesCommittedCache,
                in: context,
                forceOpaque: forceOpaque
            )
        case .shape(let shape):
            drawShape(
                shape,
                style: renderingStyle,
                elementID: element.id,
                destinationScale: resolvedDestinationScale,
                in: context,
                forceOpaque: forceOpaque
            )
        case .linear(let linear):
            drawLinear(
                linear,
                style: renderingStyle,
                elementID: element.id,
                destinationScale: resolvedDestinationScale,
                in: context,
                forceOpaque: forceOpaque
            )
        case .text(let text):
            drawText(text, style: renderingStyle, in: context, forceOpaque: forceOpaque)
        }
        context.restoreGState()
    }

    private func constructionPreview(
        for committed: AnnotationLinearGeometry,
        pointer: CGPoint
    ) -> AnnotationLinearGeometry {
        guard let endpoint = committed.points.last,
              hypot(pointer.x - endpoint.x, pointer.y - endpoint.y) > 0.5 else {
            return committed
        }

        var preview = committed
        switch committed.route {
        case .straight:
            preview.points.append(pointer)
            preview.bezierControls = []
        case .curved:
            preview.points.append(pointer)
            preview.bezierControls = []
            preview.bezierControls = AnnotationGeometry.bezierControls(for: preview)
        }
        return preview
    }

    private func drawFreehand(
        _ freehand: AnnotationFreehandGeometry,
        style: AnnotationStyle,
        elementID: AnnotationElementID,
        rotation: CGFloat,
        destinationScale: CGFloat,
        isActive: Bool,
        usesCommittedCache: Bool,
        in context: CGContext,
        forceOpaque: Bool
    ) {
        guard !freehand.samples.isEmpty else { return }
        if isActive, freehand.samples.count > 1 {
            drawCachedActiveFreehand(
                freehand,
                style: style,
                elementID: elementID,
                destinationScale: destinationScale,
                in: context,
                forceOpaque: forceOpaque
            )
            return
        }
        let data: CommittedFreehandRenderData
        if usesCommittedCache {
            data = committedFreehandData(
                for: freehand,
                style: style,
                elementID: elementID,
                rotation: rotation,
                destinationScale: destinationScale
            )
        } else {
            data = makeCommittedFreehandData(
                for: freehand,
                style: style,
                elementID: elementID,
                destinationScale: destinationScale
            )
        }
        drawCommittedFreehandData(
            data,
            style: style,
            in: context,
            forceOpaque: forceOpaque
        )
    }

    private func committedFreehandData(
        for freehand: AnnotationFreehandGeometry,
        style: AnnotationStyle,
        elementID: AnnotationElementID,
        rotation: CGFloat,
        destinationScale: CGFloat
    ) -> CommittedFreehandRenderData {
        let contentKey = CommittedFreehandContentKey(
            freehand: freehand,
            style: style,
            rotation: rotation
        )
        if let entries = committedFreehandCache[elementID],
           entries.first?.contentKey != contentKey {
            removeCommittedEntries(for: elementID)
        }
        if var entries = committedFreehandCache[elementID],
           let index = entries.firstIndex(where: {
               $0.contentKey == contentKey
                   && $0.destinationScale == destinationScale
           }) {
            committedStrokeCacheAccess &+= 1
            entries[index].lastAccess = committedStrokeCacheAccess
            let data = entries[index].data
            committedFreehandCache[elementID] = entries
            committedStrokeCacheCountersForTesting.cacheHits += 1
            return data
        }

        let data = makeCommittedFreehandData(
            for: freehand,
            style: style,
            elementID: elementID,
            destinationScale: destinationScale
        )
        committedStrokeCacheCountersForTesting.rebuiltElements += 1
        storeCommittedFreehandData(
            data,
            for: elementID,
            contentKey: contentKey,
            freehand: freehand,
            style: style,
            destinationScale: destinationScale
        )
        return data
    }

    private func makeCommittedFreehandData(
        for freehand: AnnotationFreehandGeometry,
        style: AnnotationStyle,
        elementID: AnnotationElementID,
        destinationScale: CGFloat
    ) -> CommittedFreehandRenderData {
        guard let first = freehand.samples.first else {
            return CommittedFreehandRenderData(
                paths: [],
                kind: .stroke,
                lineWidth: 0,
                combinesOpacity: false,
                isHighlighter: freehand.isHighlighter
            )
        }
        if freehand.isHighlighter {
            if freehand.samples.count == 1 {
                let path = CGMutablePath()
                path.addRect(
                    AnnotationHighlighterGeometry.stampRect(
                        center: first.location,
                        strokeWidth: style.strokeWidth
                    )
                )
                return CommittedFreehandRenderData(
                    paths: [path],
                    kind: .fill,
                    lineWidth: max(1, style.strokeWidth),
                    combinesOpacity: false,
                    isHighlighter: true
                )
            }
            let path = style.smoothingEnabled
                ? AnnotationGeometry.smoothedFreehandPath(freehand.samples)
                : rawFreehandPath(freehand.samples)
            return CommittedFreehandRenderData(
                paths: [path],
                kind: .stroke,
                lineWidth: max(1, style.strokeWidth),
                combinesOpacity: false,
                isHighlighter: true
            )
        }

        let lineWidth = max(
            1.25 / max(destinationScale, 0.001),
            style.strokeWidth
        )
        if freehand.samples.count == 1 {
            let width = max(
                1.25 / max(destinationScale, 0.001),
                style.strokeWidth * (
                    style.pressureEnabled
                        ? AnnotationGeometry.pressureScale(first.pressure)
                        : 1
                )
            )
            let path = CGMutablePath()
            path.addEllipse(
                in: CGRect(
                    x: first.location.x - width / 2,
                    y: first.location.y - width / 2,
                    width: width,
                    height: width
                )
            )
            return CommittedFreehandRenderData(
                paths: [path],
                kind: .fill,
                lineWidth: lineWidth,
                combinesOpacity: false,
                isHighlighter: false
            )
        }

        let usesPressure = style.pressureEnabled
            && freehand.samples.contains { $0.pressure != nil }
        if usesPressure {
            let geometrySamples = style.smoothingEnabled
                ? AnnotationGeometry.smoothedFreehandSamples(
                    freehand.samples,
                    subdivisions: 2
                )
                : freehand.samples
            let samples = AnnotationGeometry.pressureInterpolatedFreehandSamples(
                geometrySamples
            )
            return CommittedFreehandRenderData(
                paths: AnnotationRoughStroke.pressurePaths(
                    samples: samples,
                    baseWidth: style.strokeWidth,
                    sloppiness: style.sloppiness,
                    elementID: elementID,
                    salt: 0x4652_4545_4841_4E44,
                    destinationScale: destinationScale
                ),
                kind: .fill,
                lineWidth: lineWidth,
                combinesOpacity: true,
                isHighlighter: false
            )
        }

        let canonical = style.smoothingEnabled
            ? AnnotationGeometry.smoothedFreehandPath(freehand.samples)
            : rawFreehandPath(freehand.samples)
        let paths = AnnotationRoughStroke.paths(
            for: canonical,
            sloppiness: style.sloppiness,
            elementID: elementID,
            strokeWidth: style.strokeWidth,
            salt: 0x4652_4545_4841_4E44,
            destinationScale: destinationScale,
            passCount: Self.strokePassCount(for: style)
        )
        return CommittedFreehandRenderData(
            paths: paths,
            kind: .stroke,
            lineWidth: lineWidth,
            combinesOpacity: paths.count > 1,
            isHighlighter: false
        )
    }

    private func drawCommittedFreehandData(
        _ data: CommittedFreehandRenderData,
        style: AnnotationStyle,
        in context: CGContext,
        forceOpaque: Bool
    ) {
        guard !data.paths.isEmpty else { return }
        context.setLineDash(phase: 0, lengths: [])
        context.setLineWidth(data.lineWidth)
        if data.isHighlighter {
            context.setLineCap(.butt)
            context.setLineJoin(.bevel)
        }

        switch data.kind {
        case .stroke:
            if data.combinesOpacity {
                withCombinedStrokeOpacity(
                    style: style,
                    forceOpaque: forceOpaque,
                    in: context
                ) {
                    for path in data.paths {
                        context.addPath(path)
                        context.strokePath()
                    }
                }
            } else {
                context.setStrokeColor(
                    resolvedColor(
                        style.strokeColor,
                        opacity: style.opacity,
                        forceOpaque: forceOpaque
                    ).cgColor
                )
                for path in data.paths {
                    context.addPath(path)
                    context.strokePath()
                }
            }
        case .fill:
            if data.combinesOpacity {
                fillRoughPaths(
                    data.paths,
                    color: style.strokeColor,
                    opacity: style.opacity,
                    forceOpaque: forceOpaque,
                    in: context
                )
            } else {
                context.setFillColor(
                    resolvedColor(
                        style.strokeColor,
                        opacity: style.opacity,
                        forceOpaque: forceOpaque
                    ).cgColor
                )
                for path in data.paths {
                    context.addPath(path)
                    context.fillPath()
                }
            }
        }
    }

    private func rawFreehandPath(
        _ samples: [AnnotationPointSample]
    ) -> CGPath {
        let path = CGMutablePath()
        guard let first = samples.first else { return path }
        path.move(to: first.location)
        for sample in samples.dropFirst() {
            path.addLine(to: sample.location)
        }
        return path
    }

    private func drawCachedActiveFreehand(
            _ freehand: AnnotationFreehandGeometry,
            style: AnnotationStyle,
            elementID: AnnotationElementID,
            destinationScale: CGFloat,
            in context: CGContext,
            forceOpaque: Bool
        ) {
            let chunks = activeChunks(
                for: freehand,
                style: style,
                elementID: elementID,
                destinationScale: destinationScale
            )
            guard let kind = chunks.first?.kind else { return }
            let resolved = opaqueColorAndAlpha(
                style.strokeColor,
                opacity: style.opacity,
                forceOpaque: forceOpaque
            )
            let clipBounds = context.boundingBoxOfClipPath
            let strokePadding = max(style.strokeWidth, 2 / max(destinationScale, 0.001))
            context.saveGState()
            context.setAlpha(resolved.alpha)
            context.beginTransparencyLayer(auxiliaryInfo: nil)
            context.setStrokeColor(resolved.color.cgColor)
            context.setFillColor(resolved.color.cgColor)
            context.setLineDash(phase: 0, lengths: [])
            switch kind {
            case .stroke:
                context.setLineWidth(
                    max(
                        1.25 / max(destinationScale, 0.001),
                        style.strokeWidth
                    )
                )
                context.setLineCap(freehand.isHighlighter ? .butt : .round)
                context.setLineJoin(freehand.isHighlighter ? .bevel : .round)
                for chunk in chunks where chunk.bounds.insetBy(
                    dx: -strokePadding, dy: -strokePadding
                ).intersects(clipBounds) {
                    activeStrokeCacheCountersForTesting.drawnChunks += 1
                    for path in chunk.paths {
                        context.addPath(path)
                        context.strokePath()
                    }
                }
            case .fill:
                for chunk in chunks where chunk.bounds.insetBy(
                    dx: -strokePadding, dy: -strokePadding
                ).intersects(clipBounds) {
                    activeStrokeCacheCountersForTesting.drawnChunks += 1
                    for path in chunk.paths {
                        context.addPath(path)
                        context.fillPath()
                    }
                }
            }
            context.endTransparencyLayer()
            context.restoreGState()
        }

    private func activeChunks(
            for freehand: AnnotationFreehandGeometry,
            style: AnnotationStyle,
            elementID: AnnotationElementID,
            destinationScale: CGFloat
        ) -> [ActiveChunk] {
            guard let lastSample = freehand.samples.last else { return [] }
            let previous = activeFreehandCache
            let keyMatches = previous?.elementID == elementID
                && previous?.style == style
                && previous?.isHighlighter == freehand.isHighlighter
                && previous?.destinationScale == destinationScale
            if keyMatches,
               let previous,
               previous.sampleCount == freehand.samples.count,
               previous.lastSample == lastSample {
                return previous.chunks
            }

            let stableAppend = keyMatches
                && (previous?.sampleCount ?? 0) > 0
                && freehand.samples.count >= (previous?.sampleCount ?? 0)
                && freehand.samples[(previous?.sampleCount ?? 1) - 1]
                    == previous?.lastSample
            let stableTailMutation = keyMatches
                && (previous?.sampleCount ?? 0) > 1
                && freehand.samples.count >= (previous?.sampleCount ?? 0) - 1
                && freehand.samples[(previous?.sampleCount ?? 2) - 2]
                    == previous?.penultimateSample
            let reusesPrefix = stableAppend || stableTailMutation
            let firstChangedSample = stableAppend
                ? previous?.sampleCount ?? 0
                : max(1, (previous?.sampleCount ?? 1) - 1)
            let firstChunkToRebuild: Int
            if reusesPrefix {
                firstChunkToRebuild = max(
                    0,
                    (firstChangedSample - Self.activeChunkOverlap)
                        / Self.activeChunkSampleCount
                )
            } else {
                firstChunkToRebuild = 0
            }

            var cumulativeArcLengths: [CGFloat]
            var retainedChunks: [ActiveChunk]
            if reusesPrefix, let previous {
                cumulativeArcLengths = previous.cumulativeArcLengths
                let retainedSampleCount = stableAppend
                    ? previous.sampleCount
                    : max(1, previous.sampleCount - 1)
                if cumulativeArcLengths.count > retainedSampleCount {
                    cumulativeArcLengths.removeSubrange(
                        retainedSampleCount..<cumulativeArcLengths.count
                    )
                }
                if cumulativeArcLengths.count > freehand.samples.count {
                    cumulativeArcLengths.removeSubrange(
                        freehand.samples.count..<cumulativeArcLengths.count
                    )
                }
                retainedChunks = previous.chunks.filter {
                    $0.index < firstChunkToRebuild
                }
            } else {
                cumulativeArcLengths = []
                retainedChunks = []
            }
            if cumulativeArcLengths.isEmpty {
                cumulativeArcLengths = [0]
            }
            while cumulativeArcLengths.count < freehand.samples.count {
                let index = cumulativeArcLengths.count
                let previousPoint = freehand.samples[index - 1].location
                let point = freehand.samples[index].location
                cumulativeArcLengths.append(
                    cumulativeArcLengths[index - 1]
                        + hypot(point.x - previousPoint.x, point.y - previousPoint.y)
                )
            }

            let chunkCount = Int(
                ceil(
                    Double(freehand.samples.count)
                        / Double(Self.activeChunkSampleCount)
                )
            )
            var rebuiltChunks: [ActiveChunk] = []
            if firstChunkToRebuild < chunkCount {
                for chunkIndex in firstChunkToRebuild..<chunkCount {
                    let lowerBound = max(
                        0,
                        chunkIndex * Self.activeChunkSampleCount
                            - Self.activeChunkOverlap
                    )
                    let upperBound = min(
                        freehand.samples.count,
                        (chunkIndex + 1) * Self.activeChunkSampleCount
                            + Self.activeChunkOverlap
                    )
                    let samples = Array(freehand.samples[lowerBound..<upperBound])
                    rebuiltChunks.append(
                        makeActiveChunk(
                            index: chunkIndex,
                            samples: samples,
                            startingArcLength: cumulativeArcLengths[lowerBound],
                            freehand: freehand,
                            style: style,
                            elementID: elementID,
                            destinationScale: destinationScale
                        )
                    )
                }
            }
            activeStrokeCacheCountersForTesting.rebuiltChunks += rebuiltChunks.count
            let chunks = retainedChunks + rebuiltChunks
            activeFreehandCache = ActiveFreehandCache(
                elementID: elementID,
                style: style,
                isHighlighter: freehand.isHighlighter,
                destinationScale: destinationScale,
                freehand: freehand,
                sampleCount: freehand.samples.count,
                lastSample: lastSample,
                penultimateSample: freehand.samples.dropLast().last,
                cumulativeArcLengths: cumulativeArcLengths,
                chunks: chunks
            )
            return chunks
        }

    private func makeActiveChunk(
            index: Int,
            samples: [AnnotationPointSample],
            startingArcLength: CGFloat,
            freehand: AnnotationFreehandGeometry,
            style: AnnotationStyle,
            elementID: AnnotationElementID,
            destinationScale: CGFloat
        ) -> ActiveChunk {
            if freehand.isHighlighter {
                let path = style.smoothingEnabled
                    ? AnnotationGeometry.smoothedFreehandPath(samples)
                    : rawFreehandPath(samples)
                return ActiveChunk(index: index, paths: [path], kind: .stroke)
            }
            let usesPressure = style.pressureEnabled
                && samples.contains { $0.pressure != nil }
            if usesPressure {
                let geometrySamples = style.smoothingEnabled
                    ? AnnotationGeometry.smoothedFreehandSamples(samples, subdivisions: 2)
                    : samples
                let pressureSamples = AnnotationGeometry.pressureInterpolatedFreehandSamples(
                    geometrySamples
                )
                return ActiveChunk(
                    index: index,
                    paths: AnnotationRoughStroke.pressurePaths(
                        samples: pressureSamples,
                        baseWidth: style.strokeWidth,
                        sloppiness: style.sloppiness,
                        elementID: elementID,
                        salt: 0x4652_4545_4841_4E44,
                        destinationScale: destinationScale,
                        startingArcLength: startingArcLength,
                        passCount: 1
                    ),
                    kind: .fill
                )
            }
            let canonical = style.smoothingEnabled
                ? AnnotationGeometry.smoothedFreehandPath(samples)
                : rawFreehandPath(samples)
            return ActiveChunk(
                index: index,
                paths: AnnotationRoughStroke.paths(
                    for: canonical,
                    sloppiness: style.sloppiness,
                    elementID: elementID,
                    strokeWidth: style.strokeWidth,
                    salt: 0x4652_4545_4841_4E44,
                    destinationScale: destinationScale,
                    passCount: 1
                ),
                kind: .stroke
            )
        }

    private func storeCommittedFreehandData(
        _ data: CommittedFreehandRenderData,
        for elementID: AnnotationElementID,
        contentKey: CommittedFreehandContentKey,
        freehand: AnnotationFreehandGeometry,
        style: AnnotationStyle,
        destinationScale: CGFloat
    ) {
        if let entries = committedFreehandCache[elementID],
           entries.first?.contentKey != contentKey {
            removeCommittedEntries(for: elementID)
        }

        var entries = committedFreehandCache[elementID] ?? []
        if let index = entries.firstIndex(where: {
            $0.contentKey == contentKey
                && $0.destinationScale == destinationScale
        }) {
            committedStrokeCacheEstimatedCost -= entries[index].estimatedCost
            entries.remove(at: index)
        }
        committedStrokeCacheAccess &+= 1
        let estimatedCost = estimatedCommittedFreehandCost(
            freehand: freehand,
            style: style,
            pathCount: data.paths.count
        )
        entries.append(
            CommittedFreehandCacheEntry(
                contentKey: contentKey,
                destinationScale: destinationScale,
                data: data,
                estimatedCost: estimatedCost,
                lastAccess: committedStrokeCacheAccess
            )
        )
        committedStrokeCacheEstimatedCost += estimatedCost

        while entries.count > Self.committedScaleVariantLimit {
            guard let leastRecentIndex = entries.indices.min(by: {
                entries[$0].lastAccess < entries[$1].lastAccess
            }) else {
                break
            }
            committedStrokeCacheEstimatedCost -= entries[leastRecentIndex].estimatedCost
            entries.remove(at: leastRecentIndex)
            committedStrokeCacheCountersForTesting.evictedEntries += 1
        }
        committedFreehandCache[elementID] = entries
        enforceCommittedStrokeCacheLimits()
    }

    private func estimatedCommittedFreehandCost(
        freehand: AnnotationFreehandGeometry,
        style: AnnotationStyle,
        pathCount: Int
    ) -> Int {
        let usesPressure = !freehand.isHighlighter
            && style.pressureEnabled
            && freehand.samples.contains { $0.pressure != nil }
        let geometryExpansion = usesPressure
            ? (style.smoothingEnabled ? 8 : 4)
            : (style.smoothingEnabled ? 4 : 1)
        return 384 + freehand.samples.count
            * 32
            * geometryExpansion
            * max(1, pathCount)
    }

    private func enforceCommittedStrokeCacheLimits() {
        while committedStrokeCacheEntryCountForTesting
                > committedStrokeCacheEntryLimit
            || committedStrokeCacheEstimatedCost
                > committedStrokeCacheCostLimit {
            let leastRecent = committedFreehandCache.flatMap { elementID, entries in
                entries.map { (elementID: elementID, access: $0.lastAccess) }
            }.min { $0.access < $1.access }
            guard let leastRecent else { break }
            removeCommittedEntry(
                elementID: leastRecent.elementID,
                lastAccess: leastRecent.access
            )
        }
    }

    private func removeCommittedEntry(
        elementID: AnnotationElementID,
        lastAccess: UInt64
    ) {
        guard var entries = committedFreehandCache[elementID],
              let index = entries.firstIndex(where: {
                  $0.lastAccess == lastAccess
              }) else {
            return
        }
        committedStrokeCacheEstimatedCost -= entries[index].estimatedCost
        entries.remove(at: index)
        if entries.isEmpty {
            committedFreehandCache.removeValue(forKey: elementID)
        } else {
            committedFreehandCache[elementID] = entries
        }
        committedStrokeCacheCountersForTesting.evictedEntries += 1
    }

    private func removeCommittedEntries(
        for elementID: AnnotationElementID
    ) {
        guard let entries = committedFreehandCache.removeValue(
            forKey: elementID
        ) else {
            return
        }
        committedStrokeCacheEstimatedCost -= entries.reduce(0) {
            $0 + $1.estimatedCost
        }
        committedStrokeCacheCountersForTesting.evictedEntries += entries.count
    }

    private func drawShape(
        _ shape: AnnotationShapeGeometry,
        style: AnnotationStyle,
        elementID: AnnotationElementID,
        destinationScale: CGFloat,
        in context: CGContext,
        forceOpaque: Bool
    ) {
        let path = AnnotationGeometry.shapePath(shape, roundness: style.roundness)
        let isSharpPolygon = shape.kind != .ellipse
            && (style.roundness ?? 0) <= 0
        let hasIndependentCorners = isSharpPolygon
            && style.sloppiness != .architect
        let pinnedPoints = hasIndependentCorners
            ? []
            : AnnotationGeometry.shapeStrokePinnedPoints(
                shape,
                roundness: style.roundness
            )
        let ellipseBounds = shape.kind == .ellipse ? shape.bounds : nil
        if style.usesLegacyHighlightCompositing {
            fill(
                path,
                color: style.strokeColor,
                style: style,
                elementID: elementID,
                salt: 0x5348_4150_4546_494C,
                pinnedPoints: pinnedPoints,
                destinationScale: destinationScale,
                ellipseBounds: ellipseBounds,
                in: context,
                forceOpaque: forceOpaque
            )
            return
        }

        switch style.fillStyle {
        case .none:
            break
        case .hachure:
            drawPatternFill(
                path,
                style: style,
                elementID: elementID,
                crossHatch: false,
                destinationScale: destinationScale,
                in: context,
                forceOpaque: forceOpaque
            )
        case .crossHatch:
            drawPatternFill(
                path,
                style: style,
                elementID: elementID,
                crossHatch: true,
                destinationScale: destinationScale,
                in: context,
                forceOpaque: forceOpaque
            )
        case .solid:
            context.setFillColor(resolvedColor(style.fillColor, opacity: style.opacity, forceOpaque: forceOpaque).cgColor)
            context.addPath(path)
            context.fillPath()
        }
        stroke(
            path,
            style: style,
            elementID: elementID,
            salt: 0x5348_4150_4553_5452,
            pinnedPoints: pinnedPoints,
            destinationScale: destinationScale,
            independentClosedCorners: hasIndependentCorners,
            ellipseBounds: ellipseBounds,
            in: context,
            forceOpaque: forceOpaque
        )
    }

    private func drawPatternFill(
        _ path: CGPath,
        style: AnnotationStyle,
        elementID: AnnotationElementID,
        crossHatch: Bool,
        destinationScale: CGFloat,
        in context: CGContext,
        forceOpaque: Bool
    ) {
        let bounds = path.boundingBoxOfPath
        guard bounds.width > 0, bounds.height > 0 else { return }

        let resolved = opaqueColorAndAlpha(
            style.fillColor,
            opacity: style.opacity,
            forceOpaque: forceOpaque
        )
        let spacing = max(6, min(14, style.strokeWidth * 2.2))
        let lineWidth = max(0.8, min(2.4, style.strokeWidth * 0.42))
        let phase = deterministicPatternPhase(
            elementID: elementID,
            spacing: spacing,
            salt: crossHatch ? 0x4352_4F53_5348_4154 : 0x4841_4348_5552_4521
        )

        context.saveGState()
        context.addPath(path)
        context.clip()
        context.setAlpha(resolved.alpha)
        context.beginTransparencyLayer(auxiliaryInfo: nil)
        context.setStrokeColor(resolved.color.cgColor)
        context.setLineWidth(lineWidth)
        context.setLineCap(.butt)
        context.setLineDash(phase: 0, lengths: [])

        strokeHachureLines(
            in: bounds,
            spacing: spacing,
            phase: phase,
            rising: false,
            style: style,
            elementID: elementID,
            strokeWidth: lineWidth,
            destinationScale: destinationScale,
            salt: 0x4841_4348_5552_4531,
            context: context
        )
        if crossHatch {
            strokeHachureLines(
                in: bounds,
                spacing: spacing,
                phase: phase * 0.5,
                rising: true,
                style: style,
                elementID: elementID,
                strokeWidth: lineWidth,
                destinationScale: destinationScale,
                salt: 0x4841_4348_5552_4532,
                context: context
            )
        }

        context.endTransparencyLayer()
        context.restoreGState()
    }

    private func strokeHachureLines(
        in bounds: CGRect,
        spacing: CGFloat,
        phase: CGFloat,
        rising: Bool,
        style: AnnotationStyle,
        elementID: AnnotationElementID,
        strokeWidth: CGFloat,
        destinationScale: CGFloat,
        salt: UInt64,
        context: CGContext
    ) {
        let first = floor((bounds.minX - bounds.height - phase) / spacing) * spacing + phase
        let last = bounds.maxX + bounds.height
        var offset = first
        let canonical = CGMutablePath()
        while offset <= last {
            if rising {
                canonical.move(to: CGPoint(x: offset, y: bounds.minY))
                canonical.addLine(to: CGPoint(x: offset + bounds.height, y: bounds.maxY))
            } else {
                canonical.move(to: CGPoint(x: offset, y: bounds.maxY))
                canonical.addLine(to: CGPoint(x: offset + bounds.height, y: bounds.minY))
            }
            offset += spacing
        }
        for roughPath in AnnotationRoughStroke.paths(
            for: canonical,
            sloppiness: style.sloppiness,
            elementID: elementID,
            strokeWidth: strokeWidth,
            salt: salt,
            destinationScale: destinationScale
        ) {
            context.addPath(roughPath)
            context.strokePath()
        }
    }

    private func deterministicPatternPhase(
        elementID: AnnotationElementID,
        spacing: CGFloat,
        salt: UInt64
    ) -> CGFloat {
        var hash = UInt64(14_695_981_039_346_656_037) ^ salt
        for byte in elementID.rawValue.uuidString.utf8 {
            hash ^= UInt64(byte)
            hash &*= 1_099_511_628_211
        }
        return CGFloat(hash % 10_000) / 10_000 * spacing
    }

    private func drawLinear(
        _ linear: AnnotationLinearGeometry,
        style: AnnotationStyle,
        elementID: AnnotationElementID,
        destinationScale: CGFloat,
        in context: CGContext,
        forceOpaque: Bool
    ) {
        guard let first = linear.points.first else { return }
        guard linear.points.count > 1 else {
            context.fillEllipse(
                in: CGRect(
                    x: first.x - style.strokeWidth / 2,
                    y: first.y - style.strokeWidth / 2,
                    width: style.strokeWidth,
                    height: style.strokeWidth
                )
            )
            return
        }

        let color = resolvedColor(style.strokeColor, opacity: style.opacity, forceOpaque: forceOpaque)
        let last = linear.points[linear.points.count - 1]
        let headLength = AnnotationGeometry.arrowheadMetrics(
            strokeWidth: style.strokeWidth,
            size: linear.arrowheadSize
        ).length
        let isLegacyArrow = linear.points.count == 2
            && linear.route == .straight
            && linear.startArrowhead == .arrow
            && linear.endArrowhead == .none
            && linear.arrowheadSize == .small
            && linear.startBinding == nil
            && linear.endBinding == nil
        if isLegacyArrow, hypot(last.x - first.x, last.y - first.y) >= headLength {
            drawLegacyArrow(
                tail: last,
                tip: first,
                style: style,
                elementID: elementID,
                destinationScale: destinationScale,
                forceOpaque: forceOpaque,
                in: context
            )
            return
        }

        context.setStrokeColor(color.cgColor)
        context.setFillColor(color.cgColor)
        let shaft = AnnotationGeometry.linearShaftGeometry(
            linear,
            strokeWidth: style.strokeWidth
        )
        var pinnedPoints: [CGPoint] = []
        if linear.startBinding != nil, let first = shaft.points.first {
            pinnedPoints.append(first)
        }
        if linear.endBinding != nil, let last = shaft.points.last {
            pinnedPoints.append(last)
        }
        stroke(
            AnnotationGeometry.linearPath(shaft),
            style: style,
            elementID: elementID,
            salt: 0x4C49_4E45_4152_5348,
            pinnedPoints: pinnedPoints,
            destinationScale: destinationScale,
            in: context,
            forceOpaque: forceOpaque
        )
        drawArrowhead(
            linear.startArrowhead,
            tip: first,
            adjacent: AnnotationGeometry.endpointAdjacentPoint(in: linear, atStart: true)
                ?? linear.points[1],
            style: style,
            size: linear.arrowheadSize,
            elementID: elementID,
            salt: 0x4152_524F_5753_5441,
            destinationScale: destinationScale,
            forceOpaque: forceOpaque,
            in: context
        )
        drawArrowhead(
            linear.endArrowhead,
            tip: last,
            adjacent: AnnotationGeometry.endpointAdjacentPoint(in: linear, atStart: false)
                ?? linear.points[linear.points.count - 2],
            style: style,
            size: linear.arrowheadSize,
            elementID: elementID,
            salt: 0x4152_524F_5745_4E44,
            destinationScale: destinationScale,
            forceOpaque: forceOpaque,
            in: context
        )
    }

    private func drawText(
        _ text: AnnotationTextGeometry,
        style: AnnotationStyle,
        in context: CGContext,
        forceOpaque: Bool
    ) {
        let paragraph = NSMutableParagraphStyle()
        switch text.alignment {
        case .left: paragraph.alignment = .left
        case .center: paragraph.alignment = .center
        case .right: paragraph.alignment = .right
        }
        let attributes: [NSAttributedString.Key: Any] = [
            .font: AnnotationController.typingFont(named: text.fontName, size: text.fontSize),
            .foregroundColor: resolvedColor(style.strokeColor, opacity: style.opacity, forceOpaque: forceOpaque),
            .paragraphStyle: paragraph
        ]
        let string = NSString(string: text.text)
        let size = string.size(withAttributes: attributes)
        let x: CGFloat
        switch text.alignment {
        case .left:
            x = text.origin.x
        case .center:
            x = text.origin.x - size.width / 2
        case .right:
            x = text.origin.x - size.width
        }
        let naturalRect = CGRect(
            x: x,
            y: text.origin.y,
            width: size.width,
            height: size.height
        )

        context.saveGState()
        if let bounds = text.bounds,
           naturalRect.width > 0,
           naturalRect.height > 0 {
            context.translateBy(x: bounds.minX, y: bounds.minY)
            context.scaleBy(
                x: bounds.width / naturalRect.width,
                y: bounds.height / naturalRect.height
            )
            context.translateBy(x: -naturalRect.minX, y: -naturalRect.minY)
        }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: true)
        string.draw(in: naturalRect, withAttributes: attributes)
        NSGraphicsContext.restoreGraphicsState()
        context.restoreGState()
    }

    private func drawArrowhead(
        _ arrowhead: AnnotationArrowhead,
        tip: CGPoint,
        adjacent: CGPoint,
        style: AnnotationStyle,
        size: AnnotationArrowheadSize,
        elementID: AnnotationElementID,
        salt: UInt64,
        destinationScale: CGFloat,
        forceOpaque: Bool,
        in context: CGContext
    ) {
        guard let path = AnnotationGeometry.arrowheadPath(
            arrowhead,
            tip: tip,
            adjacent: adjacent,
            strokeWidth: style.strokeWidth,
            size: size
        ) else {
            return
        }
        context.setLineDash(phase: 0, lengths: [])
        context.setLineWidth(max(1, style.strokeWidth))
        context.setLineCap(.round)
        context.setLineJoin(.round)
        let maximumDeviation: CGFloat = style.sloppiness == .cartoonist ? 3.5 : 2
        if arrowhead.isFilled {
            fill(
                path,
                color: style.strokeColor,
                style: style,
                elementID: elementID,
                salt: salt,
                pinnedPoints: [tip],
                destinationScale: destinationScale,
                maximumDeviation: maximumDeviation,
                in: context,
                forceOpaque: forceOpaque
            )
        } else {
            stroke(
                path,
                style: style,
                elementID: elementID,
                salt: salt,
                pinnedPoints: [tip],
                destinationScale: destinationScale,
                maximumDeviation: maximumDeviation,
                in: context,
                forceOpaque: forceOpaque,
                configureDash: false
            )
        }
        configureLineDash(style.strokePattern, width: style.strokeWidth, in: context)
    }

    private func drawLegacyArrow(
        tail: CGPoint,
        tip: CGPoint,
        style: AnnotationStyle,
        elementID: AnnotationElementID,
        destinationScale: CGFloat,
        forceOpaque: Bool,
        in context: CGContext
    ) {
        let shaft = CGMutablePath()
        shaft.move(to: tail)
        shaft.addLine(to: tip)
        stroke(
            shaft,
            style: style,
            elementID: elementID,
            salt: 0x4C45_4741_4359_5348,
            destinationScale: destinationScale,
            in: context,
            forceOpaque: forceOpaque
        )

        drawArrowhead(
            .arrow,
            tip: tip,
            adjacent: tail,
            style: style,
            size: .small,
            elementID: elementID,
            salt: 0x4C45_4741_4359_4844,
            destinationScale: destinationScale,
            forceOpaque: forceOpaque,
            in: context
        )
    }

    private func stroke(
        _ canonicalPath: CGPath,
        style: AnnotationStyle,
        elementID: AnnotationElementID,
        salt: UInt64,
        pinnedPoints: [CGPoint] = [],
        destinationScale: CGFloat,
        independentClosedCorners: Bool = false,
        maximumDeviation: CGFloat? = nil,
        ellipseBounds: CGRect? = nil,
        in context: CGContext,
        forceOpaque: Bool,
        configureDash: Bool = true
    ) {
        let passCount = Self.strokePassCount(for: style)
        let paths = ellipseBounds.map {
            AnnotationRoughStroke.ellipsePaths(
                in: $0,
                sloppiness: style.sloppiness,
                elementID: elementID,
                strokeWidth: style.strokeWidth,
                salt: salt,
                destinationScale: destinationScale,
                passCount: passCount,
                maximumDeviation: maximumDeviation
            )
        } ?? AnnotationRoughStroke.paths(
            for: canonicalPath,
            sloppiness: style.sloppiness,
            elementID: elementID,
            strokeWidth: style.strokeWidth,
            salt: salt,
            pinnedPoints: pinnedPoints,
            destinationScale: destinationScale,
            passCount: passCount,
            independentClosedCorners: independentClosedCorners,
            maximumDeviation: maximumDeviation
        )
        let lineWidth = style.strokeWidth * Self.strokeWidthCompensation(for: style)
        context.setLineWidth(max(0.1, lineWidth))
        guard paths.count > 1 else {
            context.setStrokeColor(
                resolvedColor(
                    style.strokeColor,
                    opacity: style.opacity,
                    forceOpaque: forceOpaque
                ).cgColor
            )
            if !configureDash {
                context.setLineDash(phase: 0, lengths: [])
            }
            context.addPath(paths[0])
            context.strokePath()
            return
        }

        withCombinedStrokeOpacity(style: style, forceOpaque: forceOpaque, in: context) {
            if !configureDash {
                context.setLineDash(phase: 0, lengths: [])
            }
            for path in paths {
                context.addPath(path)
                context.strokePath()
            }
        }
    }

    private func fill(
        _ canonicalPath: CGPath,
        color: AnnotationColorValue,
        style: AnnotationStyle,
        elementID: AnnotationElementID,
        salt: UInt64,
        pinnedPoints: [CGPoint] = [],
        destinationScale: CGFloat,
        maximumDeviation: CGFloat? = nil,
        ellipseBounds: CGRect? = nil,
        in context: CGContext,
        forceOpaque: Bool
    ) {
        let paths = ellipseBounds.map {
            AnnotationRoughStroke.ellipsePaths(
                in: $0,
                sloppiness: style.sloppiness,
                elementID: elementID,
                strokeWidth: style.strokeWidth,
                salt: salt,
                destinationScale: destinationScale,
                maximumDeviation: maximumDeviation
            )
        } ?? AnnotationRoughStroke.paths(
            for: canonicalPath,
            sloppiness: style.sloppiness,
            elementID: elementID,
            strokeWidth: style.strokeWidth,
            salt: salt,
            pinnedPoints: pinnedPoints,
            destinationScale: destinationScale,
            maximumDeviation: maximumDeviation
        )
        fillRoughPaths(
            paths,
            color: color,
            opacity: style.opacity,
            forceOpaque: forceOpaque,
            in: context
        )
    }

    private func fillRoughPaths(
        _ paths: [CGPath],
        color: AnnotationColorValue,
        opacity: CGFloat,
        forceOpaque: Bool,
        in context: CGContext
    ) {
        guard !paths.isEmpty else { return }
        let resolved = opaqueColorAndAlpha(
            color,
            opacity: opacity,
            forceOpaque: forceOpaque
        )
        context.saveGState()
        context.setAlpha(resolved.alpha)
        context.beginTransparencyLayer(auxiliaryInfo: nil)
        context.setFillColor(resolved.color.cgColor)
        for path in paths {
            context.addPath(path)
            context.fillPath()
        }
        context.endTransparencyLayer()
        context.restoreGState()
    }

    static func strokePassCount(for style: AnnotationStyle) -> Int {
        style.sloppiness == .architect ? 1 : 2
    }

    static func strokeWidthCompensation(for style: AnnotationStyle) -> CGFloat {
        _ = style
        return 1
    }

    private func withCombinedStrokeOpacity(
        style: AnnotationStyle,
        forceOpaque: Bool,
        in context: CGContext,
        _ draw: () -> Void
    ) {
        let resolved = opaqueColorAndAlpha(
            style.strokeColor,
            opacity: style.opacity,
            forceOpaque: forceOpaque
        )
        context.saveGState()
        context.setAlpha(resolved.alpha)
        context.beginTransparencyLayer(auxiliaryInfo: nil)
        context.setStrokeColor(resolved.color.cgColor)
        draw()
        context.endTransparencyLayer()
        context.restoreGState()
    }

    private func opaqueColorAndAlpha(
        _ value: AnnotationColorValue,
        opacity: CGFloat,
        forceOpaque: Bool
    ) -> (color: NSColor, alpha: CGFloat) {
        AnnotationColorResolver.resolved(
            value,
            opacity: opacity,
            forceOpaque: forceOpaque
        )
    }

    private func configureStroke(
        for style: AnnotationStyle,
        in context: CGContext,
        forceOpaque: Bool
    ) {
        context.setStrokeColor(resolvedColor(style.strokeColor, opacity: style.opacity, forceOpaque: forceOpaque).cgColor)
        context.setFillColor(resolvedColor(style.fillColor, opacity: style.opacity, forceOpaque: forceOpaque).cgColor)
        context.setLineWidth(max(0.1, style.strokeWidth))
        context.setLineCap(style.lineCap.cgLineCap)
        context.setLineJoin(style.lineJoin.cgLineJoin)
        configureLineDash(style.strokePattern, width: style.strokeWidth, in: context)
    }

    private func configureLineDash(
        _ pattern: AnnotationStrokePattern,
        width: CGFloat,
        in context: CGContext
    ) {
        switch pattern {
        case .solid:
            context.setLineDash(phase: 0, lengths: [])
        case .dashed:
            context.setLineDash(
                phase: 0,
                lengths: [max(8, width * 4), max(6, width * 3)]
            )
        case .dotted:
            context.setLineCap(.round)
            context.setLineDash(
                phase: 0,
                lengths: [max(0.1, width * 0.05), max(4, width * 2)]
            )
        }
    }

    private func destinationScale(in context: CGContext) -> CGFloat {
        let transform = context.ctm
        return max(
            0.001,
            sqrt(abs(transform.a * transform.d - transform.b * transform.c))
        )
    }

    private func resolvedColor(
        _ value: AnnotationColorValue,
        opacity: CGFloat,
        forceOpaque: Bool
    ) -> NSColor {
        let resolved = AnnotationColorResolver.resolved(
            value,
            opacity: opacity,
            forceOpaque: forceOpaque
        )
        return resolved.color.withAlphaComponent(resolved.alpha)
    }

    private func isNonDarkeningHighlight(_ element: AnnotationElement) -> Bool {
        switch element.geometry {
        case .freehand(let freehand):
            return freehand.isHighlighter
                || element.style.usesLegacyHighlightCompositing
        case .shape, .linear:
            return element.style.usesLegacyHighlightCompositing
        case .text:
            return false
        }
    }

    private func nonDarkeningHighlightOpacity(_ element: AnnotationElement) -> CGFloat {
        let highlightMultiplier: CGFloat
        if case .freehand(let freehand) = element.geometry,
           freehand.isHighlighter,
           !element.style.usesLegacyHighlightCompositing {
            highlightMultiplier = AnnotationStyle.highlightAlpha
        } else {
            highlightMultiplier = 1
        }
        return AnnotationColorResolver.resolved(
            element.style.strokeColor,
            opacity: element.style.opacity,
            highlightMultiplier: highlightMultiplier
        ).alpha
    }
}

private extension AnnotationLineCap {
    var cgLineCap: CGLineCap {
        switch self {
        case .butt: .butt
        case .round: .round
        case .square: .square
        }
    }
}

private extension AnnotationLineJoin {
    var cgLineJoin: CGLineJoin {
        switch self {
        case .miter: .miter
        case .round: .round
        case .bevel: .bevel
        }
    }
}
