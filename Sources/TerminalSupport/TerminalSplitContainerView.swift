import AppKit
import QuartzCore

/// Draws a split tree of panes as cards with draggable gaps between them.
/// The tree comes from the backend; a drag reports a ratio and leaves the
/// tree to the backend's next view.
@MainActor
public final class TerminalSplitContainerView: NSView {
    public struct Pane {
        public var id: String
        public var title: String
        /// Covers the pane's content, such as when its terminal is gone.
        public var overlayMessage: String?
        /// Shows a Reconnect button under the overlay message.
        public var offersReconnect: Bool
        public var content: (any TerminalSplitPaneContent)?

        public init(
            id: String,
            title: String,
            overlayMessage: String? = nil,
            offersReconnect: Bool = false,
            content: (any TerminalSplitPaneContent)?
        ) {
            self.id = id
            self.title = title
            self.overlayMessage = overlayMessage
            self.offersReconnect = offersReconnect
            self.content = content
        }
    }

    public var metrics = TerminalSplitMetrics() {
        didSet { needsLayout = true }
    }

    /// A drag ended at a new ratio.
    public var onResizeCommitted: ((TerminalSplitDivider, Double) -> Void)?
    /// A pane's header was clicked.
    public var onPaneClicked: ((String) -> Void)?
    public var onHeaderAction: ((String, TerminalSplitHeaderAction) -> Void)?
    /// A pane's Reconnect button was pressed.
    public var onPaneReconnect: ((String) -> Void)?

    public private(set) var paneViews: [String: TerminalSplitPaneView] = [:]
    public private(set) var dividers: [TerminalSplitDivider] = []
    private var tree: TerminalSplitTree?
    /// Ratios the user set that the backend has not reported yet, with the
    /// ratio the backend reported when the drag started.
    private var committedRatios: [String: (start: Double, ratio: Double)] = [:]
    private var drag: (divider: TerminalSplitDivider, ratio: Double)?
    private var dividerElements: [NSAccessibilityElement] = []

    override public var isFlipped: Bool { true }

    /// Shows `tree`. A pane that was already shown keeps its card and
    /// content view, so only its frame changes.
    public func apply(tree: TerminalSplitTree?, panes: [Pane]) {
        self.tree = tree
        let reported = tree.map { ratios(in: $0.root) } ?? [:]
        committedRatios = committedRatios.filter { splitID, committed in
            reported[splitID] == committed.start
        }

        let ids = Set(panes.map(\.id))
        for (id, view) in paneViews where !ids.contains(id) {
            view.removeFromSuperview()
            paneViews[id] = nil
        }
        for pane in panes {
            let view = paneViews[pane.id] ?? makePaneView(pane.id)
            view.title = pane.title
            view.overlayMessage = pane.overlayMessage
            view.offersReconnect = pane.offersReconnect && pane.overlayMessage != nil
            view.isFocused = pane.id == tree?.focusedPaneID
            view.setContent(pane.content)
        }
        needsLayout = true
    }

    /// Forgets a ratio the backend refused, so the divider returns to the
    /// backend's ratio.
    public func discardCommittedRatio(splitID: String) {
        guard committedRatios.removeValue(forKey: splitID) != nil else { return }
        needsLayout = true
    }

    override public func layout() {
        super.layout()
        guard let tree else {
            dividers = []
            return
        }
        var overrides = committedRatios.mapValues(\.ratio)
        if let drag {
            overrides[drag.divider.splitID] = drag.ratio
        }
        let result = TerminalSplitLayout.layout(
            tree, in: bounds, metrics: metrics,
            scale: window?.backingScaleFactor ?? 2,
            ratioOverrides: overrides
        )
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for (id, view) in paneViews {
            if let frame = result.panes[id] {
                view.frame = frame
                view.isHidden = false
            } else {
                view.isHidden = true
            }
        }
        CATransaction.commit()
        if result.dividers != dividers {
            dividers = result.dividers
            window?.invalidateCursorRects(for: self)
            dividerElements = []
        }
    }

    override public func resetCursorRects() {
        for divider in dividers {
            addCursorRect(
                divider.hitRect,
                cursor: divider.axis == .horizontal ? .resizeLeftRight : .resizeUpDown
            )
        }
    }

    // MARK: Dragging

    override public func mouseDown(with event: NSEvent) {
        if !beginDrag(at: convert(event.locationInWindow, from: nil)) {
            super.mouseDown(with: event)
        }
    }

    override public func mouseDragged(with event: NSEvent) {
        moveDrag(to: convert(event.locationInWindow, from: nil))
    }

    override public func mouseUp(with _: NSEvent) {
        endDrag()
    }

    func beginDrag(at point: CGPoint) -> Bool {
        guard drag == nil,
              let divider = dividers.last(where: { $0.hitRect.contains(point) })
        else { return false }
        drag = (divider, divider.ratio)
        for view in paneViews.values {
            view.content?.setResizeDeferred(true)
        }
        return true
    }

    func moveDrag(to point: CGPoint) {
        guard let divider = drag?.divider else { return }
        drag?.ratio = TerminalSplitLayout.ratio(at: point, along: divider, metrics: metrics)
        needsLayout = true
        layoutSubtreeIfNeeded()
    }

    func endDrag() {
        guard let (divider, ratio) = drag else { return }
        drag = nil
        if ratio != divider.ratio {
            let start = tree.flatMap { ratios(in: $0.root)[divider.splitID] } ?? divider.ratio
            committedRatios[divider.splitID] = (start, ratio)
        }
        needsLayout = true
        layoutSubtreeIfNeeded()
        for view in paneViews.values {
            view.content?.setResizeDeferred(false)
        }
        if ratio != divider.ratio {
            onResizeCommitted?(divider, ratio)
        }
    }

    // MARK: Accessibility

    override public func accessibilityChildren() -> [Any]? {
        if dividerElements.count != dividers.count {
            dividerElements = dividers.map { divider in
                let element = NSAccessibilityElement()
                element.setAccessibilityRole(.splitter)
                element.setAccessibilityParent(self)
                element.setAccessibilityFrameInParentSpace(divider.hitRect)
                element.setAccessibilityOrientation(
                    divider.axis == .horizontal ? .vertical : .horizontal
                )
                let first = paneViews[divider.firstPaneID]?.title ?? divider.firstPaneID
                let second = paneViews[divider.secondPaneID]?.title ?? divider.secondPaneID
                element.setAccessibilityLabel("Divider between \(first) and \(second)")
                element.setAccessibilityValue(divider.ratio)
                return element
            }
        }
        return (super.accessibilityChildren() ?? []) + dividerElements
    }

    // MARK: Helpers

    private func makePaneView(_ id: String) -> TerminalSplitPaneView {
        let view = TerminalSplitPaneView(paneID: id)
        view.onAction = { [weak self] action in self?.onHeaderAction?(id, action) }
        view.onHeaderClick = { [weak self] in self?.onPaneClicked?(id) }
        view.onReconnect = { [weak self] in self?.onPaneReconnect?(id) }
        paneViews[id] = view
        addSubview(view)
        return view
    }

    private func ratios(in node: TerminalSplitTree.Node) -> [String: Double] {
        guard case let .split(id, _, ratio, first, second) = node else { return [:] }
        return ratios(in: first).merging(ratios(in: second)) { a, _ in a }
            .merging([id: ratio]) { a, _ in a }
    }
}
