import Foundation
import GhosthubTerminalSupport
import GhosthubWorkspace

/// Herdr Core terminals on one host, with the Herdr desktop app's tabs
/// that hold them.
public struct HerdrCoreListing: Equatable, Sendable {
    /// A row for each desktop tab, then one for each terminal in no tab.
    public var rows: [BackendTerminalSummary]
    public var tabs: [HerdrCoreTab]
    /// Each live terminal's name and working directory, for pane headers.
    public var paneNames: [String: String]
    public var paneDirectories: [String: String]

    public init(
        rows: [BackendTerminalSummary],
        tabs: [HerdrCoreTab],
        paneNames: [String: String],
        paneDirectories: [String: String]
    ) {
        self.rows = rows
        self.tabs = tabs
        self.paneNames = paneNames
        self.paneDirectories = paneDirectories
    }
}

/// One tab of the Herdr desktop app: its split layout of terminals.
public struct HerdrCoreTab: Equatable, Sendable {
    /// `tab:` and the desktop app's tab ID.
    public var address: String
    public var name: String
    public var spaceName: String
    public var root: TerminalSplitTree.Node

    public init(address: String, name: String, spaceName: String, root: TerminalSplitTree.Node) {
        self.address = address
        self.name = name
        self.spaceName = spaceName
        self.root = root
    }
}

/// Reads the layout document the Herdr desktop app keeps in the core
/// (`doc.get {name: "herdr-app"}`). The core never interprets it; its shape
/// is the desktop app's: spaces hold tabs, and each tab's root is a tree of
/// rows, columns, stacks, and blocks, where a block can show a terminal.
enum HerdrCoreLayout {
    /// The desktop tabs that show at least one of `live`, in document order.
    /// Anything that does not decode counts as no layout.
    static func tabs(reply: Data, live: Set<String>) -> [HerdrCoreTab] {
        guard let reply = try? JSONDecoder().decode(Reply.self, from: reply),
              let document = reply.result?.value
        else { return [] }
        return document.spaces.flatMap { space in
            space.tabs.compactMap { tab -> HerdrCoreTab? in
                let address = "tab:\(tab.id)"
                guard HerdrCoreInventory.isTabAddress(address),
                      let root = tab.root?.splitNode(live: live)
                else { return nil }
                return HerdrCoreTab(
                    address: address, name: tab.name ?? "",
                    spaceName: space.name ?? "", root: root
                )
            }
        }
    }

    private struct Reply: Decodable {
        var result: Result?

        struct Result: Decodable {
            var value: Document?
        }
    }

    private struct Document: Decodable {
        var spaces: [Space]
    }

    private struct Space: Decodable {
        var name: String?
        var tabs: [Tab]
    }

    private struct Tab: Decodable {
        var id: String
        var name: String?
        var root: Node?
    }

    private struct Node: Decodable {
        var id: String?
        var type: String
        var children: [Node]?
        var content: Content?
        var size: Size?
        var hidden: Bool?
        /// The child a stack shows.
        var active: String?

        struct Content: Decodable {
            var terminal: String?
        }

        struct Size: Decodable {
            var weight: Double?
        }

        /// The panes this node shows as a binary split tree, or nil when it
        /// shows no live terminal. A row or column of several children
        /// nests: the first child against the rest, sized by the weights.
        func splitNode(live: Set<String>) -> TerminalSplitTree.Node? {
            guard hidden != true else { return nil }
            switch type {
            case "block":
                guard let terminal = content?.terminal, live.contains(terminal) else { return nil }
                return .pane(terminal)
            case "stack":
                let children = (children ?? []).filter { $0.hidden != true }
                let shown = children.first { $0.id != nil && $0.id == active } ?? children.first
                return shown?.splitNode(live: live)
            case "row", "column":
                let parts = (children ?? []).compactMap { child in
                    child.splitNode(live: live).map { (node: $0, weight: child.weight) }
                }
                return Self.nest(
                    parts[...], id: id ?? "", axis: type == "row" ? .horizontal : .vertical,
                    index: 0
                )
            default:
                return nil
            }
        }

        /// A child without a weight, or with a fixed size, takes one share.
        private var weight: Double {
            guard let weight = size?.weight, weight > 0, weight.isFinite else { return 1 }
            return weight
        }

        private static func nest(
            _ parts: ArraySlice<(node: TerminalSplitTree.Node, weight: Double)>,
            id: String,
            axis: TerminalSplitTree.Axis,
            index: Int
        ) -> TerminalSplitTree.Node? {
            guard let first = parts.first else { return nil }
            let rest = parts.dropFirst()
            guard let second = nest(rest, id: id, axis: axis, index: index + 1) else {
                return first.node
            }
            let total = parts.reduce(0) { $0 + $1.weight }
            return .split(
                id: "\(id)#\(index)", axis: axis, ratio: first.weight / total,
                first: first.node, second: second
            )
        }
    }
}
