/// A window's panes as a binary split tree, as a backend such as Rex
/// reports it. Ghosthub draws this tree; it never invents one.
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

    public var root: Node
    public var focusedPaneID: String?
    /// A pane drawn over the whole window. The others keep running.
    public var zoomedPaneID: String?

    public init(root: Node, focusedPaneID: String? = nil, zoomedPaneID: String? = nil) {
        self.root = root
        self.focusedPaneID = focusedPaneID
        self.zoomedPaneID = zoomedPaneID
    }

    /// Every pane, first child before second.
    public var paneIDs: [String] {
        var ids: [String] = []
        root.collectPaneIDs(into: &ids)
        return ids
    }
}

extension TerminalSplitTree.Node {
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
