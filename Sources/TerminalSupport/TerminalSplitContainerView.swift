import AppKit
import QuartzCore

/// Draws a window's panes as cards: a split tree with draggable gaps that
/// fills the view, and floating windows over it. The trees come from the
/// backend; a drag reports a ratio or a floating window's bounds and leaves
/// the trees to the backend's next view.
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

    /// Which edges of a floating window a drag moves. None moves the whole
    /// window.
    struct Edges: OptionSet {
        let rawValue: Int
        static let left = Edges(rawValue: 1)
        static let right = Edges(rawValue: 2)
        static let top = Edges(rawValue: 4)
        static let bottom = Edges(rawValue: 8)
    }

    private enum Drag {
        case divider(TerminalSplitDivider, ratio: Double)
        /// `start` is the window's frame and `origin` the pointer when the
        /// drag began; `frame` is where the window is now.
        case layer(id: String, edges: Edges, start: CGRect, origin: CGPoint, frame: CGRect)
    }

    /// How far outside a floating window its edges can be grabbed.
    static let edgeGrip: CGFloat = 5

    public var metrics = TerminalSplitMetrics() {
        didSet { needsLayout = true }
    }

    /// Holds terminal resizing while something outside the container
    /// animates its size, such as the sidebar.
    public var defersContentResize = false {
        didSet {
            if defersContentResize != oldValue, drag == nil {
                setContentResizeDeferred(defersContentResize)
            }
        }
    }

    /// A drag ended at a new ratio.
    public var onResizeCommitted: ((TerminalSplitDivider, Double) -> Void)?
    /// A floating window was moved or resized to these fractional bounds.
    public var onLayerBoundsCommitted: ((String, CGRect) -> Void)?
    /// A minimized floating window's capsule was clicked.
    public var onLayerRestored: ((String) -> Void)?
    /// A pane's header was clicked.
    public var onPaneClicked: ((String) -> Void)?
    public var onHeaderAction: ((String, TerminalSplitHeaderAction) -> Void)?
    /// A pane's Reconnect button was pressed.
    public var onPaneReconnect: ((String) -> Void)?

    public private(set) var paneViews: [String: TerminalSplitPaneView] = [:]
    public private(set) var dividers: [TerminalSplitDivider] = []
    /// The floating windows on screen, from back to front.
    public private(set) var floatingLayerFrames: [TerminalSplitLayoutResult.LayerFrame] = []
    /// The capsules of minimized floating windows by layer ID.
    public private(set) var capsules: [String: NSButton] = [:]
    private var tree: TerminalSplitTree?
    /// Ratios the user set that the backend has not reported yet, with the
    /// ratio the backend reported when the drag started.
    private var committedRatios: [String: (start: Double, ratio: Double)] = [:]
    /// Floating window bounds the user set that the backend has not
    /// reported yet, with the bounds it reported when the drag started.
    private var committedBounds: [String: (start: CGRect, bounds: CGRect)] = [:]
    private var drag: Drag?
    private var backdrops: [String: FloatingLayerBackdrop] = [:]
    private var dividerElements: [NSAccessibilityElement] = []

    override public var isFlipped: Bool { true }

    /// Shows `tree`. A pane that was already shown keeps its card and
    /// content view, so only its frame changes.
    public func apply(tree: TerminalSplitTree?, panes: [Pane]) {
        self.tree = tree
        let reported = tree.map(ratios(in:)) ?? [:]
        committedRatios = committedRatios.filter { splitID, committed in
            reported[splitID] == committed.start
        }
        let reportedBounds = Dictionary(
            (tree?.floatingLayers ?? []).map { ($0.id, $0.bounds) }
        ) { first, _ in first }
        committedBounds = committedBounds.filter { layerID, committed in
            reportedBounds[layerID] == committed.start
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
            view.actions = tree.map { Self.actions(for: pane.id, in: $0) }
                ?? TerminalSplitHeaderAction.tiledActions
            if view.content !== pane.content, defersContentResize || drag != nil {
                pane.content?.setResizeDeferred(true)
            }
            view.setContent(pane.content)
        }
        updateCapsules(titles: Dictionary(panes.map { ($0.id, $0.title) }) { a, _ in a })
        needsLayout = true
    }

    /// A pane's header buttons. A floating pane can return to the tiled
    /// layout only when there is one, and its window can be minimized only
    /// while another pane stays in view, as Rex requires.
    public static func actions(
        for paneID: String,
        in tree: TerminalSplitTree
    ) -> [TerminalSplitHeaderAction] {
        guard tree.floatingLayer(holding: paneID) != nil else {
            return TerminalSplitHeaderAction.tiledActions
        }
        let othersShown = tree.root != nil || tree.floatingLayers.count { !$0.isMinimized } > 1
        return TerminalSplitHeaderAction.floatingActions.filter { action in
            switch action {
            case .tile: tree.root != nil
            case .minimize: othersShown
            default: true
            }
        }
    }

    /// Forgets a ratio the backend refused, so the divider returns to the
    /// backend's ratio.
    public func discardCommittedRatio(splitID: String) {
        guard committedRatios.removeValue(forKey: splitID) != nil else { return }
        needsLayout = true
    }

    /// Forgets bounds the backend refused, so the floating window returns
    /// to the backend's bounds.
    public func discardCommittedBounds(layerID: String) {
        guard committedBounds.removeValue(forKey: layerID) != nil else { return }
        needsLayout = true
    }

    override public func layout() {
        super.layout()
        guard let tree else {
            dividers = []
            floatingLayerFrames = []
            for backdrop in backdrops.values {
                backdrop.removeFromSuperview()
            }
            backdrops = [:]
            return
        }
        var ratios = committedRatios.mapValues(\.ratio)
        var layerBounds = committedBounds.mapValues(\.bounds)
        switch drag {
        case let .divider(divider, ratio):
            ratios[divider.splitID] = ratio
        case let .layer(id, _, _, _, frame):
            layerBounds[id] = TerminalSplitLayout.fraction(of: frame, in: bounds)
        case nil:
            break
        }
        let result = TerminalSplitLayout.layout(
            tree, in: bounds, metrics: metrics,
            scale: window?.backingScaleFactor ?? 2,
            ratioOverrides: ratios,
            layerBoundsOverrides: layerBounds
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
        let shown = Set(result.floatingLayers.map(\.id))
        for (id, backdrop) in backdrops where !shown.contains(id) {
            backdrop.removeFromSuperview()
            backdrops[id] = nil
        }
        for layer in result.floatingLayers {
            let backdrop = backdrops[layer.id] ?? makeBackdrop(layer.id)
            backdrop.frame = layer.frame.insetBy(dx: -Self.edgeGrip, dy: -Self.edgeGrip)
        }
        layoutCapsules()
        CATransaction.commit()
        floatingLayerFrames = result.floatingLayers
        orderSubviews(tree)
        if result.dividers != dividers {
            dividers = result.dividers
            window?.invalidateCursorRects(for: self)
            for backdrop in backdrops.values {
                window?.invalidateCursorRects(for: backdrop)
            }
            dividerElements = []
        }
    }

    /// A floating window's edges take clicks before the panes inside it,
    /// so a window that fills the view can still be resized. Capsules stay
    /// in front of every window.
    override public func hitTest(_ point: NSPoint) -> NSView? {
        let local = convert(point, from: superview)
        if !capsules.values.contains(where: { $0.frame.contains(local) }),
           let layer = floatingLayerFrames.last(where: {
               $0.frame.insetBy(dx: -Self.edgeGrip, dy: -Self.edgeGrip).contains(local)
           }), !Self.edges(of: layer.frame, at: local).isEmpty,
           bounds.contains(local), let backdrop = backdrops[layer.id] {
            return backdrop
        }
        return super.hitTest(point)
    }

    override public func resetCursorRects() {
        for divider in dividers where divider.layerID == nil {
            addCursorRect(divider.hitRect, cursor: Self.cursor(for: divider))
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

    /// Starts a drag at a point in this view: a floating window's edge or a
    /// divider, whichever is in front there.
    func beginDrag(at point: CGPoint) -> Bool {
        guard drag == nil else { return false }
        for layer in floatingLayerFrames.reversed() {
            let grip = layer.frame.insetBy(dx: -Self.edgeGrip, dy: -Self.edgeGrip)
            guard grip.contains(point) else { continue }
            let edges = Self.edges(of: layer.frame, at: point)
            if !edges.isEmpty {
                begin(.layer(
                    id: layer.id, edges: edges, start: layer.frame, origin: point,
                    frame: layer.frame
                ))
                return true
            }
            if let divider = dividers.last(where: {
                $0.layerID == layer.id && $0.hitRect.contains(point)
            }) {
                begin(.divider(divider, ratio: divider.ratio))
                return true
            }
            return false
        }
        guard let divider = dividers.last(where: {
            $0.layerID == nil && $0.hitRect.contains(point)
        }) else { return false }
        begin(.divider(divider, ratio: divider.ratio))
        return true
    }

    /// Starts moving the floating window that holds `paneID`, as a drag on
    /// the pane's header does.
    func beginMove(paneID: String, at point: CGPoint) -> Bool {
        guard drag == nil, let layer = tree?.floatingLayer(holding: paneID),
              let frame = floatingLayerFrames.first(where: { $0.id == layer.id })?.frame
        else { return false }
        begin(.layer(id: layer.id, edges: [], start: frame, origin: point, frame: frame))
        return true
    }

    func moveDrag(to point: CGPoint) {
        switch drag {
        case let .divider(divider, _):
            drag = .divider(
                divider, ratio: TerminalSplitLayout.ratio(
                    at: point,
                    along: divider,
                    metrics: metrics
                )
            )
        case let .layer(id, edges, start, origin, _):
            drag = .layer(
                id: id, edges: edges, start: start, origin: origin,
                frame: draggedFrame(id: id, edges: edges, start: start, by: CGSize(
                    width: point.x - origin.x, height: point.y - origin.y
                ))
            )
        case nil:
            return
        }
        needsLayout = true
        layoutSubtreeIfNeeded()
    }

    func endDrag() {
        guard let ended = drag else { return }
        drag = nil
        var commit: (() -> Void)?
        switch ended {
        case let .divider(divider, ratio):
            if ratio != divider.ratio {
                let start = tree.flatMap { ratios(in: $0)[divider.splitID] } ?? divider.ratio
                committedRatios[divider.splitID] = (start, ratio)
                commit = { [weak self] in self?.onResizeCommitted?(divider, ratio) }
            }
        case let .layer(id, _, start, _, frame):
            if frame != start, let reported = tree?.floatingLayers.first(where: { $0.id == id }) {
                let fraction = TerminalSplitLayout.fraction(of: frame, in: bounds)
                committedBounds[id] = (reported.bounds, fraction)
                commit = { [weak self] in self?.onLayerBoundsCommitted?(id, fraction) }
            }
        }
        needsLayout = true
        layoutSubtreeIfNeeded()
        if !defersContentResize {
            setContentResizeDeferred(false)
        }
        commit?()
    }

    private func begin(_ newDrag: Drag) {
        drag = newDrag
        if !defersContentResize {
            setContentResizeDeferred(true)
        }
    }

    /// A floating window's frame after a drag by `offset`, kept inside the
    /// view and, when resized, no smaller than its panes need at their
    /// current split ratios.
    private func draggedFrame(
        id: String,
        edges: Edges,
        start: CGRect,
        by offset: CGSize
    ) -> CGRect {
        if edges.isEmpty {
            let x = min(max(start.minX + offset.width, bounds.minX), bounds.maxX - start.width)
            let y = min(max(start.minY + offset.height, bounds.minY), bounds.maxY - start.height)
            return CGRect(origin: CGPoint(x: x, y: y), size: start.size)
        }
        let root = tree?.floatingLayers.first { $0.id == id }?.root
        let ratios = committedRatios.mapValues(\.ratio)
        func minimum(along axis: TerminalSplitTree.Axis) -> CGFloat {
            root?.minimumLength(
                along: axis, metrics: metrics, overrides: ratios, keepingRatios: true
            ) ?? 0
        }
        let minWidth = min(minimum(along: .horizontal), bounds.width)
        let minHeight = min(minimum(along: .vertical), bounds.height)
        var minX = start.minX, maxX = start.maxX, minY = start.minY, maxY = start.maxY
        if edges.contains(.left) {
            minX = min(max(minX + offset.width, bounds.minX), maxX - minWidth)
        }
        if edges.contains(.right) {
            maxX = max(min(maxX + offset.width, bounds.maxX), minX + minWidth)
        }
        if edges.contains(.top) {
            minY = min(max(minY + offset.height, bounds.minY), maxY - minHeight)
        }
        if edges.contains(.bottom) {
            maxY = max(min(maxY + offset.height, bounds.maxY), minY + minHeight)
        }
        return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }

    /// The edges of `frame` within grabbing distance of `point`.
    static func edges(of frame: CGRect, at point: CGPoint) -> Edges {
        var edges: Edges = []
        if abs(point.x - frame.minX) <= edgeGrip {
            edges.insert(.left)
        }
        if abs(point.x - frame.maxX) <= edgeGrip {
            edges.insert(.right)
        }
        if abs(point.y - frame.minY) <= edgeGrip {
            edges.insert(.top)
        }
        if abs(point.y - frame.maxY) <= edgeGrip {
            edges.insert(.bottom)
        }
        return edges
    }

    private func setContentResizeDeferred(_ deferred: Bool) {
        for view in paneViews.values {
            view.content?.setResizeDeferred(deferred)
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
        view.onHeaderDrag = { [weak self] location, ended in
            guard let self else { return }
            let point = convert(location, from: nil)
            if ended {
                endDrag()
            } else if drag != nil || beginMove(paneID: id, at: point) {
                moveDrag(to: point)
            }
        }
        view.onReconnect = { [weak self] in self?.onPaneReconnect?(id) }
        paneViews[id] = view
        addSubview(view)
        return view
    }

    private func makeBackdrop(_ id: String) -> FloatingLayerBackdrop {
        let backdrop = FloatingLayerBackdrop(owner: self)
        backdrops[id] = backdrop
        addSubview(backdrop)
        return backdrop
    }

    /// Keeps cards in the backend's order: the tiled panes, then each
    /// floating window's backdrop and panes from back to front, then the
    /// capsules. Sorting moves no view out of the window, so a terminal
    /// keeps keyboard focus.
    private func orderSubviews(_ tree: TerminalSplitTree) {
        var rank: [ObjectIdentifier: Int] = [:]
        var next = 1
        func place(_ view: NSView?) {
            guard let view else { return }
            rank[ObjectIdentifier(view)] = next
            next += 1
        }
        var tiled: [String] = []
        tree.root?.collectPaneIDs(into: &tiled)
        tiled.forEach { place(paneViews[$0]) }
        for layer in tree.floatingLayers {
            place(backdrops[layer.id])
            var ids: [String] = []
            layer.root.collectPaneIDs(into: &ids)
            ids.forEach { place(paneViews[$0]) }
        }
        capsules.values.sorted { $0.tag < $1.tag }.forEach(place)
        let current = subviews.map { rank[ObjectIdentifier($0)] ?? 0 }
        guard current != current.sorted() else { return }
        let order = SubviewOrder(rank)
        withExtendedLifetime(order) {
            sortSubviews({ a, b, context in
                let order = Unmanaged<SubviewOrder>.fromOpaque(context!).takeUnretainedValue()
                let ra = order.rank[ObjectIdentifier(a)] ?? 0
                let rb = order.rank[ObjectIdentifier(b)] ?? 0
                return ra < rb ? .orderedAscending : ra > rb ? .orderedDescending : .orderedSame
            }, context: Unmanaged.passUnretained(order).toOpaque())
        }
    }

    private final class SubviewOrder {
        let rank: [ObjectIdentifier: Int]
        init(_ rank: [ObjectIdentifier: Int]) {
            self.rank = rank
        }
    }

    /// One capsule per minimized floating window, named by its first pane.
    private func updateCapsules(titles: [String: String]) {
        let minimized = (tree?.floatingLayers ?? []).filter(\.isMinimized)
        let ids = Set(minimized.map(\.id))
        for (id, capsule) in capsules where !ids.contains(id) {
            capsule.removeFromSuperview()
            capsules[id] = nil
        }
        for (index, layer) in minimized.enumerated() {
            let capsule = capsules[layer.id] ?? makeCapsule(layer.id)
            var paneIDs: [String] = []
            layer.root.collectPaneIDs(into: &paneIDs)
            let title = paneIDs.first.flatMap { titles[$0] } ?? layer.id
            capsule.title = title
            capsule.toolTip = "Show Floating Window: \(title)"
            capsule.setAccessibilityLabel("Show Floating Window: \(title)")
            capsule.tag = index
        }
    }

    private func makeCapsule(_ id: String) -> NSButton {
        let capsule = NSButton(title: "", target: nil, action: nil)
        capsule.bezelStyle = .push
        capsule.controlSize = .small
        capsule.image = NSImage(systemSymbolName: "macwindow", accessibilityDescription: nil)
        capsule.imagePosition = .imageLeading
        capsule.lineBreakMode = .byTruncatingMiddle
        capsule.target = self
        capsule.action = #selector(capsulePressed(_:))
        capsule.identifier = NSUserInterfaceItemIdentifier(id)
        capsules[id] = capsule
        addSubview(capsule)
        return capsule
    }

    /// Lines up the capsules from the bottom-right corner, leftward, and
    /// starts a row above when one is full, so every capsule stays in view.
    private func layoutCapsules() {
        let margin: CGFloat = 8, spacing: CGFloat = 6
        var trailing = bounds.maxX - margin
        var bottom = bounds.maxY - margin
        var rowHeight: CGFloat = 0
        for capsule in capsules.values.sorted(by: { $0.tag < $1.tag }) {
            let size = capsule.fittingSize
            let width = min(size.width, 200, max(bounds.width - 2 * margin, 0))
            if trailing - width < bounds.minX + margin, rowHeight > 0 {
                trailing = bounds.maxX - margin
                bottom -= rowHeight + spacing
                rowHeight = 0
            }
            trailing -= width
            capsule.frame = CGRect(
                x: trailing, y: bottom - size.height, width: width, height: size.height
            )
            trailing -= spacing
            rowHeight = max(rowHeight, size.height)
        }
    }

    @objc private func capsulePressed(_ sender: NSButton) {
        guard let id = sender.identifier?.rawValue else { return }
        onLayerRestored?(id)
    }

    private func ratios(in tree: TerminalSplitTree) -> [String: Double] {
        var result = tree.root.map(ratios(in:)) ?? [:]
        for layer in tree.floatingLayers {
            result.merge(ratios(in: layer.root)) { a, _ in a }
        }
        return result
    }

    private func ratios(in node: TerminalSplitTree.Node) -> [String: Double] {
        guard case let .split(id, _, ratio, first, second) = node else { return [:] }
        return ratios(in: first).merging(ratios(in: second)) { a, _ in a }
            .merging([id: ratio]) { a, _ in a }
    }

    static func cursor(for divider: TerminalSplitDivider) -> NSCursor {
        divider.axis == .horizontal ? .resizeLeftRight : .resizeUpDown
    }

    fileprivate func backdropCursorRects(_ backdrop: FloatingLayerBackdrop) {
        guard let id = backdrops.first(where: { $0.value === backdrop })?.key,
              let frame = floatingLayerFrames.first(where: { $0.id == id })?.frame
        else { return }
        func local(_ rect: CGRect) -> CGRect {
            backdrop.convert(rect, from: self)
        }
        let grip = Self.edgeGrip
        let outer = frame.insetBy(dx: -grip, dy: -grip)
        let horizontal = NSCursor.resizeLeftRight, vertical = NSCursor.resizeUpDown
        backdrop.addCursorRect(local(CGRect(
            x: outer.minX, y: outer.minY, width: 2 * grip, height: outer.height
        )), cursor: horizontal)
        backdrop.addCursorRect(local(CGRect(
            x: frame.maxX - grip, y: outer.minY, width: 2 * grip, height: outer.height
        )), cursor: horizontal)
        backdrop.addCursorRect(local(CGRect(
            x: outer.minX, y: outer.minY, width: outer.width, height: 2 * grip
        )), cursor: vertical)
        backdrop.addCursorRect(local(CGRect(
            x: outer.minX, y: frame.maxY - grip, width: outer.width, height: 2 * grip
        )), cursor: vertical)
        for divider in dividers where divider.layerID == id {
            backdrop.addCursorRect(local(divider.hitRect), cursor: Self.cursor(for: divider))
        }
    }
}

/// Sits behind a floating window's panes: draws its shadow and takes the
/// clicks between and around them, for its dividers and edges.
@MainActor
private final class FloatingLayerBackdrop: NSView {
    private weak var owner: TerminalSplitContainerView?

    init(owner: TerminalSplitContainerView) {
        self.owner = owner
        super.init(frame: .zero)
        wantsLayer = true
        layer?.shadowOpacity = 0.35
        layer?.shadowRadius = 12
        layer?.shadowOffset = CGSize(width: 0, height: -4)
        setAccessibilityElement(false)
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override var isFlipped: Bool { true }

    override func layout() {
        super.layout()
        let grip = TerminalSplitContainerView.edgeGrip
        layer?.shadowPath = CGPath(
            roundedRect: bounds.insetBy(dx: grip, dy: grip),
            cornerWidth: 8, cornerHeight: 8, transform: nil
        )
    }

    override func resetCursorRects() {
        owner?.backdropCursorRects(self)
    }

    override func mouseDown(with event: NSEvent) {
        guard let owner else { return }
        _ = owner.beginDrag(at: owner.convert(event.locationInWindow, from: nil))
    }

    override func mouseDragged(with event: NSEvent) {
        guard let owner else { return }
        owner.moveDrag(to: owner.convert(event.locationInWindow, from: nil))
    }

    override func mouseUp(with _: NSEvent) {
        owner?.endDrag()
    }
}
