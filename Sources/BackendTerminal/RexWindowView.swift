import Foundation
import GhosthubTerminalSupport

/// One line from `kwt rex control WINDOW_ID`.
public enum RexControlMessage: Equatable, Sendable {
    /// The session's layout, written at start and after each change.
    case view(RexControlView)
    /// The answer to the request with this ID, with the session's revision
    /// after it when Rex reports one.
    case reply(id: Int, revision: Int?, error: RexControlError?)
    /// The session is gone.
    case ended

    public static func decode(line: Data) throws -> RexControlMessage {
        let wire = try JSONDecoder().decode(Wire.self, from: line)
        switch wire.type {
        case "view":
            guard let view = wire.view else { throw RexControlError.malformed }
            return try .view(RexControlView(view, terminals: wire.terminals ?? [:]))
        case "reply":
            guard let id = wire.id else { throw RexControlError.malformed }
            return .reply(id: id, revision: wire.result?.revision, error: wire.error)
        case "ended":
            return .ended
        default:
            throw RexControlError.malformed
        }
    }

    private struct Wire: Decodable {
        var type: String
        var id: Int?
        var error: RexControlError?
        var result: Result?
        var view: SessionView?
        var terminals: [String: Terminal]?
    }

    struct Terminal: Decodable {
        var name: String
        var cwd: String?
    }

    struct Result: Decodable {
        var revision: Int?
    }
}

public struct RexControlError: Error, Equatable, Sendable, Decodable {
    public var code: String
    public var message: String

    public init(code: String, message: String) {
        self.code = code
        self.message = message
    }

    static let malformed = RexControlError(
        code: "malformed_line",
        message: "kwt rex control wrote a line Ghosthub cannot read"
    )
}

/// A Rex session's windows, as `kwt rex control` reports them.
public struct RexControlView: Equatable, Sendable {
    public struct Window: Equatable, Sendable {
        public var id: String
        public var label: String
        /// The window's panes, tiled and floating, or nil when it has none.
        public var tree: TerminalSplitTree?

        public init(id: String, label: String, tree: TerminalSplitTree?) {
            self.id = id
            self.label = label
            self.tree = tree
        }
    }

    public var revision: Int
    public var sessionID: String
    public var sessionLabel: String
    public var windows: [Window]
    /// Each pane's display name by block ID: the terminal's name from kwt,
    /// else the block's Rex label.
    public var paneNames: [String: String]
    /// Each terminal pane's working directory on the Rex host, when known.
    public var paneDirectories: [String: String]

    public init(
        revision: Int,
        sessionID: String,
        sessionLabel: String,
        windows: [Window],
        paneNames: [String: String],
        paneDirectories: [String: String]
    ) {
        self.revision = revision
        self.sessionID = sessionID
        self.sessionLabel = sessionLabel
        self.windows = windows
        self.paneNames = paneNames
        self.paneDirectories = paneDirectories
    }

    fileprivate init(
        _ view: SessionView,
        terminals: [String: RexControlMessage.Terminal]
    ) throws {
        revision = view.revision
        sessionID = view.sessionID
        sessionLabel = view.label ?? ""
        var names: [String: String] = [:]
        windows = try view.windows.map { window in
            for block in window.layers.flatMap({ $0.blocks ?? [] }) {
                names[block.blockID] = terminals[block.blockID]?.name ?? block.label
            }
            // Rex draws a layer of a kind it does not know as floating.
            let tiled = window.layers.first { $0.kind == "tiled" }
            let floating = try window.layers.filter { $0.kind != "tiled" }.compactMap { layer in
                try layer.floatingLayer()
            }
            let root = try tiled?.layout?.node()
            return Window(
                id: window.windowID,
                label: window.label ?? "",
                tree: root == nil && floating.isEmpty ? nil : TerminalSplitTree(
                    root: root,
                    floatingLayers: floating,
                    focusedPaneID: window.focusedBlockID,
                    zoomedPaneID: window.zoomedBlockID
                )
            )
        }
        paneNames = names
        paneDirectories = terminals.compactMapValues { terminal in
            terminal.cwd.flatMap { $0.isEmpty ? nil : $0 }
        }
    }
}

private struct SessionView: Decodable {
    var revision: Int
    var sessionID: String
    var label: String?
    var windows: [Window]

    struct Window: Decodable {
        var windowID: String
        var label: String?
        var focusedBlockID: String?
        var zoomedBlockID: String?
        var layers: [Layer]

        enum CodingKeys: String, CodingKey {
            case windowID = "window_id"
            case label
            case focusedBlockID = "focused_block_id"
            case zoomedBlockID = "zoomed_block_id"
            case layers
        }
    }

    struct Layer: Decodable {
        var kind: String
        var layerID: String?
        var bounds: [Double]?
        var state: String?
        var layout: Layout?
        var blocks: [Block]?

        /// The layer as a floating layer, or nil when it holds no panes.
        func floatingLayer() throws -> TerminalSplitTree.FloatingLayer? {
            guard let layout else { return nil }
            guard let layerID, let bounds, bounds.count == 4 else {
                throw RexControlError.malformed
            }
            return try TerminalSplitTree.FloatingLayer(
                id: layerID,
                bounds: CGRect(x: bounds[0], y: bounds[1], width: bounds[2], height: bounds[3]),
                root: layout.node(),
                isMinimized: state == "minimized"
            )
        }

        enum CodingKeys: String, CodingKey {
            case kind
            case layerID = "layer_id"
            case bounds, state, layout, blocks
        }
    }

    struct Block: Decodable {
        var blockID: String
        var label: String

        enum CodingKeys: String, CodingKey {
            case blockID = "block_id"
            case label
        }
    }

    final class Layout: Decodable {
        var blockID: String?
        var split: Split?

        func node() throws -> TerminalSplitTree.Node {
            if let blockID {
                return .pane(blockID)
            }
            guard let split else { throw RexControlError.malformed }
            return try .split(
                id: split.splitID,
                axis: split.direction == "vertical" ? .vertical : .horizontal,
                ratio: split.ratio,
                first: split.before.node(),
                second: split.after.node()
            )
        }

        enum CodingKeys: String, CodingKey {
            case blockID = "block_id"
            case split
        }
    }

    struct Split: Decodable {
        var splitID: String
        var direction: String
        var ratio: Double
        var before: Layout
        var after: Layout

        enum CodingKeys: String, CodingKey {
            case splitID = "split_id"
            case direction, ratio, before, after
        }
    }

    enum CodingKeys: String, CodingKey {
        case revision
        case sessionID = "session_id"
        case label, windows
    }
}
