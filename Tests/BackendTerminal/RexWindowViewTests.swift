import Foundation
import GhosthubTerminalSupport
import Testing
@testable import GhosthubBackendTerminal

@Suite("Rex window view")
struct RexWindowViewTests {
    /// A view line from `kwt rex control`, built around the view Rex 0.1.0
    /// reported for a window split right, then split down on the right with
    /// 60% above. The third pane has no terminal detail.
    private let viewLine = #"""
    {"type":"view","terminals":{"block:01a1e691-b0a2-78ed-9a36-4e3d6256cf0b":{"name":"vim notes.md","title":"vim notes.md","program":"vim","cwd":"/home/user-a"},"block:01a1e691-c0e2-7d81-b501-f5efd04cc274":{"name":"zsh ~/src/app","program":"zsh","cwd":"/home/user-a/src/app"}},"view":{"revision":5,"session_id":"session:01a1e691-b0a2-77db-b0d3-4e4c0ece1d3e","label":"split-probe","active_window_id":"window:01a1e691-b0bd-7524-a45f-d42a01e1abb2","windows":[{"window_id":"window:01a1e691-b0bd-7524-a45f-d42a01e1abb2","label":"Window 01e1abb2","focused_block_id":"block:01a1e691-c130-7b75-9807-cf7c76e0381d","layers":[{"layer_id":"layer:01a1e691-b0bd-7b55-9d42-7e1cbaa5f0f1","kind":"tiled","bounds":[0,0,1,1],"layout":{"rect":[0,0,1,1],"split":{"split_id":"split:01a1e691-c0f3-7850-93a3-c0882f370a42","direction":"horizontal","ratio":0.5,"before":{"rect":[0,0,0.5,1],"block_id":"block:01a1e691-b0a2-78ed-9a36-4e3d6256cf0b"},"after":{"rect":[0.5,0,0.5,1],"split":{"split_id":"split:01a1e691-c13b-791f-af6b-0c95857e319a","direction":"vertical","ratio":0.6,"before":{"rect":[0.5,0,0.5,0.6],"block_id":"block:01a1e691-c0e2-7d81-b501-f5efd04cc274"},"after":{"rect":[0.5,0.6,0.5,0.4],"block_id":"block:01a1e691-c130-7b75-9807-cf7c76e0381d"}}}}},"blocks":[{"block_id":"block:01a1e691-b0a2-78ed-9a36-4e3d6256cf0b","label":"shell","creator_name":"com.superlogical.terminal","flavor":"com.superlogical.terminal.shell","host_id":"00000000-0000-0000-0000-000000000000","owner":"client:00000000-0000-0000-0000-000000000000"},{"block_id":"block:01a1e691-c0e2-7d81-b501-f5efd04cc274","label":"shell","creator_name":"com.superlogical.terminal","flavor":"com.superlogical.terminal.shell","host_id":"00000000-0000-0000-0000-000000000000","owner":"client:00000000-0000-0000-0000-000000000000"},{"block_id":"block:01a1e691-c130-7b75-9807-cf7c76e0381d","label":"shell","creator_name":"com.superlogical.terminal","flavor":"com.superlogical.terminal.shell","host_id":"00000000-0000-0000-0000-000000000000","owner":"client:00000000-0000-0000-0000-000000000000"}]}]}]}}
    """#

    private func decode(_ line: String) throws -> RexControlMessage {
        try RexControlMessage.decode(line: Data(line.utf8))
    }

    @Test("a view line becomes the window's split tree and pane names")
    func view() throws {
        guard case let .view(view) = try decode(viewLine) else {
            Issue.record("expected a view")
            return
        }
        let a = "block:01a1e691-b0a2-78ed-9a36-4e3d6256cf0b"
        let b = "block:01a1e691-c0e2-7d81-b501-f5efd04cc274"
        let c = "block:01a1e691-c130-7b75-9807-cf7c76e0381d"
        #expect(view.revision == 5)
        #expect(view.sessionID == "session:01a1e691-b0a2-77db-b0d3-4e4c0ece1d3e")
        #expect(view.sessionLabel == "split-probe")
        #expect(view.windows.map(\.id) == ["window:01a1e691-b0bd-7524-a45f-d42a01e1abb2"])
        #expect(view.windows.first?.label == "Window 01e1abb2")
        #expect(view.windows.first?.tree == TerminalSplitTree(
            root: .split(
                id: "split:01a1e691-c0f3-7850-93a3-c0882f370a42",
                axis: .horizontal, ratio: 0.5,
                first: .pane(a),
                second: .split(
                    id: "split:01a1e691-c13b-791f-af6b-0c95857e319a",
                    axis: .vertical, ratio: 0.6,
                    first: .pane(b), second: .pane(c)
                )
            ),
            focusedPaneID: c
        ))
        #expect(view.paneNames == [a: "vim notes.md", b: "zsh ~/src/app", c: "shell"])
    }

    @Test("a zoomed pane and an empty window come through")
    func zoomAndEmpty() throws {
        let line = #"""
        {"type":"view","terminals":{},"view":{"revision":2,"session_id":"session:s","label":"","windows":[
          {"window_id":"window:1","label":"build","focused_block_id":"block:a","zoomed_block_id":"block:a",
           "layers":[{"kind":"floating","layout":{"block_id":"block:f"},"blocks":[]},
                     {"kind":"tiled","layout":{"block_id":"block:a"},
                      "blocks":[{"block_id":"block:a","label":"notes","creator_name":"com.example.notes"}]}]},
          {"window_id":"window:2","label":"empty","layers":[]}]}}
        """#
        guard case let .view(view) = try decode(line) else {
            Issue.record("expected a view")
            return
        }
        #expect(view.windows.first?.tree == TerminalSplitTree(
            root: .pane("block:a"), focusedPaneID: "block:a", zoomedPaneID: "block:a"
        ))
        #expect(view.windows.last?.tree == nil)
        #expect(view.paneNames == ["block:a": "notes"])
    }

    @Test("a split in a direction Rex has not named yet is drawn side by side")
    func unknownDirection() throws {
        let line = #"""
        {"type":"view","terminals":{},"view":{"revision":1,"session_id":"session:s","label":"s","windows":[
          {"window_id":"window:1","label":"w","layers":[{"kind":"tiled","layout":{"split":{
            "split_id":"split:1","direction":"diagonal","ratio":0.25,
            "before":{"block_id":"block:a"},"after":{"block_id":"block:b"}}},"blocks":[]}]}]}}
        """#
        guard case let .view(view) = try decode(line) else {
            Issue.record("expected a view")
            return
        }
        #expect(view.windows.first?.tree?.root == .split(
            id: "split:1", axis: .horizontal, ratio: 0.25,
            first: .pane("block:a"), second: .pane("block:b")
        ))
    }

    @Test("replies carry their request ID, the session's revision, and any Rex error")
    func replies() throws {
        #expect(try decode(#"{"type":"reply","id":7,"result":{"revision":42}}"#)
            == .reply(id: 7, revision: 42, error: nil))
        #expect(try decode(#"{"type":"reply","id":9,"result":{"ok":true}}"#)
            == .reply(id: 9, revision: nil, error: nil))
        #expect(try decode(
            #"{"type":"reply","id":8,"error":{"code":"method_not_allowed","message":"no"}}"#
        ) == .reply(
            id: 8,
            revision: nil,
            error: RexControlError(code: "method_not_allowed", message: "no")
        ))
    }

    @Test("the end of the session is reported")
    func ended() throws {
        #expect(try decode(#"{"type":"ended"}"#) == .ended)
    }

    @Test("lines that are not control messages are refused", arguments: [
        "not json",
        #"{"type":"bogus"}"#,
        #"{"type":"view","view":{"revision":1}}"#,
        #"{"type":"reply"}"#,
        #"{"type":"view","terminals":{},"view":{"revision":1,"session_id":"s","windows":[{"window_id":"w","layers":[{"kind":"tiled","layout":{"rect":[0,0,1,1]}}]}]}}"#,
    ])
    func malformed(line: String) {
        #expect(throws: (any Error).self) { try decode(line) }
    }
}
