import CoreGraphics

public struct TerminalSplitMetrics: Equatable, Sendable {
    /// Space between panes. The gap is also the divider.
    public var gap: CGFloat
    /// The smallest a pane can be dragged.
    public var minimumPaneSize: CGSize

    public init(
        gap: CGFloat = 8,
        minimumPaneSize: CGSize = CGSize(width: 80, height: 60)
    ) {
        self.gap = gap
        self.minimumPaneSize = minimumPaneSize
    }
}

/// The border between a split's two children.
public struct TerminalSplitDivider: Equatable, Sendable {
    public var splitID: String
    public var axis: TerminalSplitTree.Axis
    public var ratio: Double
    /// Where the pointer can grab the divider: the gap, widened to at least
    /// `minimumHitThickness`.
    public var hitRect: CGRect
    /// The whole space the split divides.
    public var splitRect: CGRect
    /// The ratios that keep every pane on both sides at its minimum size.
    public var ratioRange: ClosedRange<Double>
    /// The panes touching the divider on each side, nearest the start of
    /// the divider. Rex names a border by one pane on each side of it.
    public var firstPaneID: String
    public var secondPaneID: String
    /// The floating layer the divider is in, or nil in the tiled layout.
    public var layerID: String?
}

public struct TerminalSplitLayoutResult: Equatable, Sendable {
    /// Where a floating layer is drawn.
    public struct LayerFrame: Equatable, Sendable {
        public var id: String
        public var frame: CGRect
    }

    public var panes: [String: CGRect]
    /// Dividers from back to front: the tiled layout's, then each floating
    /// layer's.
    public var dividers: [TerminalSplitDivider]
    /// The floating layers on screen, from back to front.
    public var floatingLayers: [LayerFrame] = []
}

/// Places a split tree's panes. Frames use a top-left origin, so a view
/// that applies them is flipped.
public enum TerminalSplitLayout {
    public static let minimumHitThickness: CGFloat = 6

    public static func layout(
        _ tree: TerminalSplitTree,
        in bounds: CGRect,
        metrics: TerminalSplitMetrics,
        scale: CGFloat,
        ratioOverrides: [String: Double] = [:],
        layerBoundsOverrides: [String: CGRect] = [:]
    ) -> TerminalSplitLayoutResult {
        if let zoomed = tree.zoomedPaneID, tree.visiblePaneIDs.contains(zoomed) {
            return TerminalSplitLayoutResult(panes: [zoomed: bounds], dividers: [])
        }
        let scale = max(scale, 1)
        var result = TerminalSplitLayoutResult(panes: [:], dividers: [])
        if let root = tree.root {
            place(
                root, in: bounds, layerID: nil, metrics: metrics,
                scale: scale, overrides: ratioOverrides, into: &result
            )
        }
        for layer in tree.floatingLayers where !layer.isMinimized {
            let frame = Self.frame(
                of: layerBoundsOverrides[layer.id] ?? layer.bounds, in: bounds, scale: scale
            )
            result.floatingLayers.append(.init(id: layer.id, frame: frame))
            place(
                layer.root, in: frame, layerID: layer.id, metrics: metrics,
                scale: scale, overrides: ratioOverrides, into: &result
            )
        }
        return result
    }

    /// A floating layer's frame from its fractional bounds, on whole device
    /// pixels.
    public static func frame(of fraction: CGRect, in bounds: CGRect, scale: CGFloat) -> CGRect {
        let scale = max(scale, 1)
        func align(_ value: CGFloat) -> CGFloat {
            (value * scale).rounded() / scale
        }
        let minX = align(bounds.minX + fraction.minX * bounds.width)
        let minY = align(bounds.minY + fraction.minY * bounds.height)
        let maxX = align(bounds.minX + fraction.maxX * bounds.width)
        let maxY = align(bounds.minY + fraction.maxY * bounds.height)
        return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }

    /// A frame's bounds as fractions of `bounds`, the form a backend takes.
    public static func fraction(of frame: CGRect, in bounds: CGRect) -> CGRect {
        guard bounds.width > 0, bounds.height > 0 else { return .zero }
        return CGRect(
            x: (frame.minX - bounds.minX) / bounds.width,
            y: (frame.minY - bounds.minY) / bounds.height,
            width: frame.width / bounds.width,
            height: frame.height / bounds.height
        )
    }

    /// The ratio that puts `splitID`'s divider under `point`, kept within
    /// the divider's range.
    public static func ratio(
        at point: CGPoint,
        along divider: TerminalSplitDivider,
        metrics: TerminalSplitMetrics
    ) -> Double {
        let rect = divider.splitRect
        let (offset, length) = switch divider.axis {
        case .horizontal: (point.x - rect.minX, rect.width)
        case .vertical: (point.y - rect.minY, rect.height)
        }
        let available = length - metrics.gap
        guard available > 0 else { return 0.5 }
        let ratio = Double((offset - metrics.gap / 2) / available)
        return min(max(ratio, divider.ratioRange.lowerBound), divider.ratioRange.upperBound)
    }

    private static func place(
        _ node: TerminalSplitTree.Node,
        in rect: CGRect,
        layerID: String?,
        metrics: TerminalSplitMetrics,
        scale: CGFloat,
        overrides: [String: Double],
        into result: inout TerminalSplitLayoutResult
    ) {
        guard case let .split(id, axis, treeRatio, first, second) = node else {
            if case let .pane(id) = node {
                result.panes[id] = rect
            }
            return
        }
        let length = axis == .horizontal ? rect.width : rect.height
        let available = max(0, length - metrics.gap)
        let ratio = min(max(overrides[id] ?? treeRatio, 0), 1)
        let firstLength = min(
            (CGFloat(Double(available) * ratio) * scale).rounded(.down) / scale,
            available
        )
        let firstRect: CGRect
        let secondRect: CGRect
        let gapRect: CGRect
        switch axis {
        case .horizontal:
            firstRect = CGRect(x: rect.minX, y: rect.minY, width: firstLength, height: rect.height)
            gapRect = CGRect(
                x: firstRect.maxX,
                y: rect.minY,
                width: metrics.gap,
                height: rect.height
            )
            secondRect = CGRect(
                x: gapRect.maxX, y: rect.minY,
                width: available - firstLength, height: rect.height
            )
        case .vertical:
            firstRect = CGRect(x: rect.minX, y: rect.minY, width: rect.width, height: firstLength)
            gapRect = CGRect(
                x: rect.minX,
                y: firstRect.maxY,
                width: rect.width,
                height: metrics.gap
            )
            secondRect = CGRect(
                x: rect.minX, y: gapRect.maxY,
                width: rect.width, height: available - firstLength
            )
        }
        // Keep each nested split at its current ratio when there is room
        // for that; otherwise keep at least every pane's own minimum.
        var ratioRange = ratio ... ratio
        for keepsRatios in [true, false] {
            let firstMinimum = first.minimumLength(
                along: axis, metrics: metrics, overrides: overrides, keepingRatios: keepsRatios
            )
            let secondMinimum = second.minimumLength(
                along: axis, metrics: metrics, overrides: overrides, keepingRatios: keepsRatios
            )
            if available > 0, firstMinimum + secondMinimum <= available {
                // When the minimums fill the space exactly, rounding can
                // put the bounds a hair out of order.
                let lower = Double(firstMinimum / available)
                ratioRange = lower ... max(lower, Double(1 - secondMinimum / available))
                break
            }
        }
        result.dividers.append(TerminalSplitDivider(
            splitID: id,
            axis: axis,
            ratio: ratio,
            hitRect: widened(gapRect, axis: axis),
            splitRect: rect,
            ratioRange: ratioRange,
            firstPaneID: first.edgePane(facing: axis, trailing: true),
            secondPaneID: second.edgePane(facing: axis, trailing: false),
            layerID: layerID
        ))
        place(
            first,
            in: firstRect,
            layerID: layerID,
            metrics: metrics,
            scale: scale,
            overrides: overrides,
            into: &result
        )
        place(
            second,
            in: secondRect,
            layerID: layerID,
            metrics: metrics,
            scale: scale,
            overrides: overrides,
            into: &result
        )
    }

    private static func widened(_ gap: CGRect, axis: TerminalSplitTree.Axis) -> CGRect {
        switch axis {
        case .horizontal where gap.width < minimumHitThickness:
            gap.insetBy(dx: -(minimumHitThickness - gap.width) / 2, dy: 0)
        case .vertical where gap.height < minimumHitThickness:
            gap.insetBy(dx: 0, dy: -(minimumHitThickness - gap.height) / 2)
        default:
            gap
        }
    }
}

extension TerminalSplitTree.Node {
    /// The least space this subtree needs along `axis`. With
    /// `keepingRatios`, each split in that direction keeps its ratio, so the
    /// smaller share must still hold its side's minimum.
    func minimumLength(
        along axis: TerminalSplitTree.Axis,
        metrics: TerminalSplitMetrics,
        overrides: [String: Double] = [:],
        keepingRatios: Bool = false
    ) -> CGFloat {
        switch self {
        case .pane:
            let size = metrics.minimumPaneSize
            return axis == .horizontal ? size.width : size.height
        case let .split(id, splitAxis, treeRatio, first, second):
            let a = first.minimumLength(
                along: axis, metrics: metrics, overrides: overrides, keepingRatios: keepingRatios
            )
            let b = second.minimumLength(
                along: axis, metrics: metrics, overrides: overrides, keepingRatios: keepingRatios
            )
            guard splitAxis == axis else { return max(a, b) }
            let ratio = CGFloat(min(max(overrides[id] ?? treeRatio, 0), 1))
            guard keepingRatios, ratio > 0, ratio < 1 else { return a + metrics.gap + b }
            return metrics.gap + max(a / ratio, b / (1 - ratio))
        }
    }

    /// The pane touching a divider along `axis`: the subtree's last pane in
    /// that direction when `trailing`, else its first.
    func edgePane(facing axis: TerminalSplitTree.Axis, trailing: Bool) -> String {
        switch self {
        case let .pane(id):
            return id
        case let .split(_, splitAxis, _, first, second):
            if splitAxis == axis, trailing {
                return second.edgePane(facing: axis, trailing: trailing)
            }
            return first.edgePane(facing: axis, trailing: trailing)
        }
    }
}

public enum TerminalSplitFocusMove: Equatable, Sendable {
    case left, right, up, down, next, previous
}

extension TerminalSplitLayout {
    /// The pane that focus moves to from the tree's focused pane, or nil
    /// when no pane lies that way. Next and previous follow layout order and
    /// wrap. A direction picks the nearest pane on that side that shares
    /// some of the focused pane's span, preferring the one that shares most.
    public static func pane(
        _ move: TerminalSplitFocusMove,
        from tree: TerminalSplitTree,
        in bounds: CGRect,
        metrics: TerminalSplitMetrics
    ) -> String? {
        let ids = tree.visiblePaneIDs
        guard let focused = tree.focusedPaneID, let index = ids.firstIndex(of: focused),
              ids.count > 1
        else { return nil }
        switch move {
        case .next:
            return ids[(index + 1) % ids.count]
        case .previous:
            return ids[(index + ids.count - 1) % ids.count]
        case .left, .right, .up, .down:
            var unzoomed = tree
            unzoomed.zoomedPaneID = nil
            let frames = layout(unzoomed, in: bounds, metrics: metrics, scale: 1).panes
            guard let origin = frames[focused] else { return nil }
            let horizontal = move == .left || move == .right
            return frames.compactMap { id, frame -> (String, CGFloat, CGFloat)? in
                let distance: CGFloat = switch move {
                case .left: origin.minX - frame.maxX
                case .right: frame.minX - origin.maxX
                case .up: origin.minY - frame.maxY
                default: frame.minY - origin.maxY
                }
                let overlap = horizontal
                    ? min(origin.maxY, frame.maxY) - max(origin.minY, frame.minY)
                    : min(origin.maxX, frame.maxX) - max(origin.minX, frame.minX)
                guard id != focused, distance >= 0, overlap > 0 else { return nil }
                return (id, distance, overlap)
            }
            .min { a, b in a.1 != b.1 ? a.1 < b.1 : a.2 > b.2 }?.0
        }
    }
}
