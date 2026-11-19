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
        /// A tiled pane dragged by its header, and where it would land.
        /// `moved` turns true once the pointer leaves the starting spot.
        case pane(id: String, origin: CGPoint, moved: Bool, drop: TerminalSplitPaneDrop?)
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

    /// False when the layout cannot change here, such as a Herdr desktop
    /// tab: dividers stay where the backend put them and headers offer only
    /// Zoom.
    public var isLayoutEditable = true {
        didSet {
            guard isLayoutEditable != oldValue else { return }
            window?.invalidateCursorRects(for: self)
        }
    }

    /// A drag ended at a new ratio.
    public var onResizeCommitted: ((TerminalSplitDivider, Double) -> Void)?
    /// A floating window was moved or resized to these fractional bounds.
    public var onLayerBoundsCommitted: ((String, CGRect) -> Void)?
    /// A tiled pane was dragged by its header and dropped beside or on
    /// another pane.
    public var onPaneDropped: ((String, TerminalSplitPaneDrop) -> Void)?
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
    /// Shown when the capsules do not all fit; it lists the hidden ones.
    public private(set) var capsuleOverflow: NSButton?
    private var tree: TerminalSplitTree?
    /// Ratios the user set that the backend has not reported yet, with the
    /// ratio the backend reported when the drag started.
    private var committedRatios: [String: (start: Double, ratio: Double)] = [:]
    /// Floating window bounds the user set that the backend has not
    /// reported yet, with the bounds it reported when the drag started.
    private var committedBounds: [String: (start: CGRect, bounds: CGRect)] = [:]
    private var drag: Drag?
    private var backdrops: [String: FloatingLayerBackdrop] = [:]
    private var dropHighlight: PaneDropHighlight?
    private var escapeMonitor: Any?
    /// Escape cancelled a header drag; the rest of it does nothing.
    private var headerDragCancelled = false
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
            view.actions = !isLayoutEditable ? [.zoom]
                : tree.map { Self.actions(for: pane.id, in: $0) }
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
        case .pane, nil:
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
        let buttons = capsules.values.filter { !$0.isHidden } + [capsuleOverflow].compactMap(\.self)
        if !buttons.contains(where: { $0.frame.contains(local) }),
           let layer = floatingLayerFrames.last(where: {
               $0.frame.insetBy(dx: -Self.edgeGrip, dy: -Self.edgeGrip).contains(local)
           }), !Self.edges(of: layer.frame, at: local).isEmpty,
           bounds.contains(local), let backdrop = backdrops[layer.id] {
            return backdrop
        }
        return super.hitTest(point)
    }

    override public func resetCursorRects() {
        guard isLayoutEditable else { return }
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
        guard drag == nil, isLayoutEditable else { return false }
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

    /// Starts dragging a tiled pane by its header, toward a place beside or
    /// on another tiled pane. A zoomed pane, a floating one, and the only
    /// tiled pane have nowhere to go, and nothing moves in a layout that
    /// cannot change here.
    func beginPaneDrag(paneID: String, at point: CGPoint) -> Bool {
        guard drag == nil, isLayoutEditable, let tree, tree.zoomedPaneID == nil,
              let tiled = tree.root?.paneIDs, tiled.count > 1, tiled.contains(paneID)
        else { return false }
        drag = .pane(id: paneID, origin: point, moved: false, drop: nil)
        escapeMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard event.keyCode == 53, let self else { return event }
            cancelDrag()
            return nil
        }
        return true
    }

    /// Ends a pane drag without dropping the pane.
    func cancelDrag() {
        guard case .pane = drag else { return }
        drag = nil
        headerDragCancelled = true
        finishPaneDrag()
    }

    func moveDrag(to point: CGPoint) {
        switch drag {
        case let .pane(id, origin, moved, _):
            let moved = moved || hypot(point.x - origin.x, point.y - origin.y) >= 4
            let drop = moved ? paneDrop(at: point, from: id) : nil
            drag = .pane(id: id, origin: origin, moved: moved, drop: drop)
            showDrop(drop)
            return
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
        headerDragCancelled = false
        guard let ended = drag else { return }
        drag = nil
        var commit: (() -> Void)?
        switch ended {
        case let .pane(id, _, _, drop):
            finishPaneDrag()
            if let drop {
                onPaneDropped?(id, drop)
            }
            return
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

    /// The tiled pane under `point`, other than the dragged one, and the
    /// part of it there: its middle, or the half by its nearest edge. A
    /// floating window over the pane hides it.
    private func paneDrop(at point: CGPoint, from source: String) -> TerminalSplitPaneDrop? {
        guard !floatingLayerFrames.contains(where: { $0.frame.contains(point) }),
              let target = tree?.root?.paneIDs.first(where: {
                  $0 != source && paneViews[$0]?.frame.contains(point) == true
              }),
              let frame = paneViews[target]?.frame, frame.width > 0, frame.height > 0
        else { return nil }
        let x = (point.x - frame.minX) / frame.width
        let y = (point.y - frame.minY) / frame.height
        let zone: TerminalSplitPaneDrop.Zone
        if (0.25 ... 0.75).contains(x), (0.25 ... 0.75).contains(y) {
            zone = .center
        } else {
            let distances: [(CGFloat, TerminalSplitPaneDrop.Zone)] = [
                (x, .left), (1 - x, .right), (y, .top), (1 - y, .bottom),
            ]
            zone = distances.min { $0.0 < $1.0 }?.1 ?? .center
        }
        return TerminalSplitPaneDrop(paneID: target, zone: zone)
    }

    /// Where the highlight for `drop` goes, in this view.
    var paneDropFrame: CGRect? {
        dropHighlight?.frame
    }

    private func showDrop(_ drop: TerminalSplitPaneDrop?) {
        guard let drop, let frame = paneViews[drop.paneID]?.frame else {
            dropHighlight?.removeFromSuperview()
            dropHighlight = nil
            return
        }
        let (left, right) = frame.divided(atDistance: frame.width / 2, from: .minXEdge)
        let (top, bottom) = frame.divided(atDistance: frame.height / 2, from: .minYEdge)
        let highlight = dropHighlight ?? {
            let view = PaneDropHighlight()
            dropHighlight = view
            addSubview(view)
            return view
        }()
        highlight.frame = switch drop.zone {
        case .left: left
        case .right: right
        case .top: top
        case .bottom: bottom
        case .center: frame
        }
    }

    private func finishPaneDrag() {
        showDrop(nil)
        if let escapeMonitor {
            NSEvent.removeMonitor(escapeMonitor)
        }
        escapeMonitor = nil
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
            } else if headerDragCancelled {
                return
            } else if drag != nil || beginMove(paneID: id, at: point)
                || beginPaneDrag(paneID: id, at: point) {
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
        place(capsuleOverflow)
        place(dropHighlight)
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

    /// Shows as many capsules as fit, and a menu button for the rest.
    private func layoutCapsules() {
        let ordered = capsules.values.sorted { $0.tag < $1.tag }
        var shown = placeInRows(ordered)
        if shown < ordered.count {
            let more = capsuleOverflow ?? makeCapsuleOverflow()
            shown = placeInRows([more] + ordered) - 1
        } else if let more = capsuleOverflow {
            more.removeFromSuperview()
            capsuleOverflow = nil
        }
        for (index, capsule) in ordered.enumerated() {
            capsule.isHidden = index >= shown
        }
    }

    /// Lines up `buttons` from the bottom-right corner, leftward, and starts
    /// a row above when one is full. Returns how many fit in the view; the
    /// first always counts.
    private func placeInRows(_ buttons: [NSButton]) -> Int {
        let margin: CGFloat = 8, spacing: CGFloat = 6
        var trailing = bounds.maxX - margin
        var bottom = bounds.maxY - margin
        var rowHeight: CGFloat = 0
        for (index, button) in buttons.enumerated() {
            let size = button.fittingSize
            let width = min(size.width, 200, max(bounds.width - 2 * margin, 0))
            if trailing - width < bounds.minX + margin, rowHeight > 0 {
                trailing = bounds.maxX - margin
                bottom -= rowHeight + spacing
                rowHeight = 0
            }
            if index > 0, bottom - size.height < bounds.minY + margin {
                return index
            }
            trailing -= width
            button.frame = CGRect(
                x: trailing, y: bottom - size.height, width: width, height: size.height
            )
            trailing -= spacing
            rowHeight = max(rowHeight, size.height)
        }
        return buttons.count
    }

    private func makeCapsuleOverflow() -> NSButton {
        let more = NSButton(title: "", target: self, action: #selector(capsuleOverflowPressed(_:)))
        more.bezelStyle = .push
        more.controlSize = .small
        more.image = NSImage(systemSymbolName: "ellipsis", accessibilityDescription: nil)
        more.toolTip = "More Floating Windows"
        more.setAccessibilityLabel("More Floating Windows")
        capsuleOverflow = more
        addSubview(more)
        return more
    }

    /// The minimized floating windows whose capsules do not fit.
    func capsuleOverflowMenu() -> NSMenu {
        let menu = NSMenu()
        for capsule in capsules.values.sorted(by: { $0.tag < $1.tag }) where capsule.isHidden {
            let item = NSMenuItem(
                title: capsule.title, action: #selector(capsulePressed(_:)), keyEquivalent: ""
            )
            item.target = self
            item.identifier = capsule.identifier
            menu.addItem(item)
        }
        return menu
    }

    @objc private func capsuleOverflowPressed(_ sender: NSButton) {
        capsuleOverflowMenu().popUp(
            positioning: nil, at: CGPoint(x: sender.bounds.minX, y: sender.bounds.maxY), in: sender
        )
    }

    @objc private func capsulePressed(_ sender: NSUserInterfaceItemIdentification) {
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

/// Where a dragged pane was dropped: in a half of another pane, to sit
/// beside it there, or in its middle, to trade places with it.
public struct TerminalSplitPaneDrop: Equatable, Sendable {
    public enum Zone: Equatable, Sendable {
        case left, right, top, bottom, center
    }

    public var paneID: String
    public var zone: Zone

    public init(paneID: String, zone: Zone) {
        self.paneID = paneID
        self.zone = zone
    }
}

/// Shows where a dragged pane would land. It takes no clicks.
private final class PaneDropHighlight: NSView {
    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.cornerRadius = 6
        layer?.borderWidth = 2
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        layer?.backgroundColor = NSColor.controlAccentColor.withAlphaComponent(0.2).cgColor
        layer?.borderColor = NSColor.controlAccentColor.cgColor
    }

    override func hitTest(_: NSPoint) -> NSView? {
        nil
    }
}
