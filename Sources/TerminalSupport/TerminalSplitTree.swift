import CoreGraphics

/// A window's panes as a backend such as Rex reports them: a binary split
/// tree that fills the window, and floating layers over it, each with its
/// own split tree. Ghosthub draws these trees; it never invents one.
public struct TerminalSplitTree: Equatable, Sendable {
    public enum Axis: Equatable, Sendable {
        /// Side by side: the first child on the left.
        case horizontal
        /// Stacked: the first child on top.
        case vertical
    }

    public indirect enum Node: Equatable, Sendable {
        case pane(String)
        /// `ratio` is the fraction of the space the first child gets.
        case split(id: String, axis: Axis, ratio: Double, first: Node, second: Node)
    }

    /// A layer of panes floating over the window's tiled layout.
    public struct FloatingLayer: Equatable, Sendable {
        public var id: String
        /// Where the layer sits, as fractions of the window's width and
        /// height measured from its top-left corner.
        public var bounds: CGRect
        public var root: Node
        /// Not drawn; its panes keep running.
        public var isMinimized: Bool

        public init(id: String, bounds: CGRect, root: Node, isMinimized: Bool = false) {
            self.id = id
            self.bounds = bounds
            self.root = root
            self.isMinimized = isMinimized
        }
    }

    /// The tiled layout that fills the window, or nil when every pane
    /// floats.
    public var root: Node?
    /// Floating layers, from back to front.
    public var floatingLayers: [FloatingLayer]
    public var focusedPaneID: String?
    /// A pane drawn over the whole window. The others keep running.
    public var zoomedPaneID: String?

    public init(
        root: Node?,
        floatingLayers: [FloatingLayer] = [],
        focusedPaneID: String? = nil,
        zoomedPaneID: String? = nil
    ) {
        self.root = root
        self.floatingLayers = floatingLayers
        self.focusedPaneID = focusedPaneID
        self.zoomedPaneID = zoomedPaneID
    }

    /// Every pane: the tiled layout's, then each floating layer's from back
    /// to front, first child before second.
    public var paneIDs: [String] {
        var ids: [String] = []
        root?.collectPaneIDs(into: &ids)
        for layer in floatingLayers {
            layer.root.collectPaneIDs(into: &ids)
        }
        return ids
    }

    /// The panes on screen: every pane outside a minimized layer.
    public var visiblePaneIDs: [String] {
        var ids: [String] = []
        root?.collectPaneIDs(into: &ids)
        for layer in floatingLayers where !layer.isMinimized {
            layer.root.collectPaneIDs(into: &ids)
        }
        return ids
    }

    /// The floating layer that holds the pane, or nil when it is tiled.
    public func floatingLayer(holding paneID: String) -> FloatingLayer? {
        floatingLayers.first { layer in
            var ids: [String] = []
            layer.root.collectPaneIDs(into: &ids)
            return ids.contains(paneID)
        }
    }
}

extension TerminalSplitTree.Node {
    /// The subtree's panes, first child before second.
    public var paneIDs: [String] {
        var ids: [String] = []
        collectPaneIDs(into: &ids)
        return ids
    }

    func collectPaneIDs(into ids: inout [String]) {
        switch self {
        case let .pane(id):
            ids.append(id)
        case let .split(_, _, _, first, second):
            first.collectPaneIDs(into: &ids)
            second.collectPaneIDs(into: &ids)
        }
    }
}
