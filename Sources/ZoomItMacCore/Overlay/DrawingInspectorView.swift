import AppKit

@MainActor
final class DrawingInspectorView: NSVisualEffectView {
    private let propertiesView: NSView
    private let scrollView = DrawingInspectorScrollView()
    private var propertiesContentSize = CGSize(
        width: DrawingInspectorVisualMetrics.contentWidth,
        height: 1
    )
    private var trackingAreaReference: NSTrackingArea?
    private var previousContext: DrawingInspectorContext?
    private var shouldResetScrollPosition = false

    var onPointerPresenceChanged: ((Bool) -> Void)?

    init(propertiesView: NSView) {
        self.propertiesView = propertiesView
        super.init(frame: .zero)

        material = .hudWindow
        blendingMode = .behindWindow
        state = .active
        wantsLayer = true
        layer?.cornerRadius = 12
        layer?.masksToBounds = true
        layer?.borderWidth = 0
        updateCardAppearance()

        scrollView.borderType = .noBorder
        scrollView.drawsBackground = false
        scrollView.autohidesScrollers = true
        scrollView.hasHorizontalScroller = false
        scrollView.hasVerticalScroller = false
        scrollView.scrollerStyle = .overlay
        scrollView.translatesAutoresizingMaskIntoConstraints = true
        scrollView.autoresizingMask = []
        propertiesView.translatesAutoresizingMaskIntoConstraints = true
        propertiesView.autoresizingMask = []
        scrollView.documentView = propertiesView
        addSubview(scrollView)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        true
    }

    override func updateTrackingAreas() {
        if let trackingAreaReference {
            removeTrackingArea(trackingAreaReference)
        }
        let tracking = NSTrackingArea(
            rect: bounds,
            options: [.activeAlways, .mouseEnteredAndExited, .inVisibleRect],
            owner: self
        )
        addTrackingArea(tracking)
        trackingAreaReference = tracking
        super.updateTrackingAreas()
    }

    override func mouseEntered(with event: NSEvent) {
        NSCursor.arrow.set()
        onPointerPresenceChanged?(true)
    }

    override func mouseExited(with event: NSEvent) {
        onPointerPresenceChanged?(false)
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateCardAppearance()
    }

    override func layout() {
        super.layout()
        scrollView.frame = CGRect(
            x: 12,
            y: DrawingInspectorVisualMetrics.attachedVerticalInset,
            width: max(
                0,
                bounds.width - DrawingInspectorVisualMetrics.attachedHorizontalChrome
            ),
            height: max(
                0,
                bounds.height - DrawingInspectorVisualMetrics.attachedVerticalInset * 2
            )
        )
        let documentSize = DrawingInspectorDocumentLayout.documentSize(
            contentSize: propertiesContentSize,
            viewportSize: scrollView.contentSize
        )
        scrollView.hasHorizontalScroller = false
        propertiesView.frame = CGRect(origin: .zero, size: documentSize)
        propertiesView.layoutSubtreeIfNeeded()
        let origin = DrawingInspectorDocumentLayout.clampedScrollOrigin(
            scrollView.contentView.bounds.origin,
            documentSize: documentSize,
            viewportSize: scrollView.contentSize,
            resetsToOrigin: shouldResetScrollPosition
        )
        shouldResetScrollPosition = false
        if scrollView.contentView.bounds.origin != origin {
            scrollView.contentView.scroll(to: origin)
            scrollView.reflectScrolledClipView(scrollView.contentView)
        }
    }

    func update(
        state: DrawingToolbarState,
        contentSize: CGSize
    ) {
        guard propertiesContentSize != contentSize || previousContext != state.inspectorContext else {
            return
        }
        propertiesContentSize = contentSize
        shouldResetScrollPosition =
            DrawingInspectorPresentationPolicy.shouldResetScroll(
                from: previousContext,
                to: state.inspectorContext
            )
        previousContext = state.inspectorContext
        needsLayout = true
        layoutSubtreeIfNeeded()
    }

    var hasChromeForTesting: Bool {
        false
    }

    var hasHorizontalScrollerForTesting: Bool {
        scrollView.hasHorizontalScroller
    }

    var documentSizeForTesting: CGSize {
        propertiesView.frame.size
    }

    var viewportSizeForTesting: CGSize {
        scrollView.contentSize
    }

    private func updateCardAppearance() {
        layer?.backgroundColor = DrawingColorSwatchAppearance.panelBackground(
            for: effectiveAppearance
        ).withAlphaComponent(0.96).cgColor
        layer?.borderWidth = 0
    }
}

enum DrawingInspectorDocumentLayout {
    static func documentSize(contentSize: CGSize, viewportSize: CGSize) -> CGSize {
        CGSize(
            width: min(
                max(1, contentSize.width),
                max(1, viewportSize.width)
            ),
            height: max(1, contentSize.height)
        )
    }

    static func clampedScrollOrigin(
        _ origin: CGPoint,
        documentSize: CGSize,
        viewportSize: CGSize,
        resetsToOrigin: Bool
    ) -> CGPoint {
        guard !resetsToOrigin else { return .zero }
        return CGPoint(
            x: 0,
            y: min(
                max(0, origin.y),
                max(0, documentSize.height - viewportSize.height)
            )
        )
    }
}

@MainActor
private final class DrawingInspectorScrollView: NSScrollView {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        true
    }
}
