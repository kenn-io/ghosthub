import Foundation
import GhosthubTerminalSupport
import GhosthubWorkspace
import Testing
@testable import GhosthubBackendTerminal

@Suite("Herdr desktop tabs")
struct HerdrCoreLayoutTests {
    /// What the listing command prints: `ls --json`, then the core's reply
    /// to `doc.get` for the desktop app's layout document.
    private func output(terminals: String, document: String?) -> String {
        var lines = ["Login banner", "GHOSTHUB_HC_JSON", "{\"terminals\":[\(terminals)]}"]
        if let document {
            lines += [
                "GHOSTHUB_HC_DOC",
                "{\"id\":1,\"jsonrpc\":\"2.0\",\"result\":{\"value\":\(document),\"version\":3}}",
            ]
        }
        return lines.joined(separator: "\n")
    }

    private func block(_ terminal: String, weight: Double? = nil) -> String {
        let size = weight.map { ",\"size\":{\"weight\":\($0)}" } ?? ""
        return "{\"id\":\"p\(terminal)\",\"type\":\"block\",\"content\":{\"terminal\":\"\(terminal)\"}\(size)}"
    }

    private func document(tabs: [(id: String, name: String, root: String)]) -> String {
        let tabs = tabs.map { "{\"id\":\"\($0.id)\",\"name\":\"\($0.name)\",\"root\":\($0.root)}" }
        return """
        {"spaces":[{"id":"sp1","name":"Checkout review","folder":"/src","tabs":[\(tabs.joined(separator: ","))]}]}
        """
    }

    private func listing(_ stdout: String) throws -> HerdrCoreListing {
        try HerdrCoreInventory.parseListing(status: 0, stdout: stdout, stderr: "").get()
    }

    private let terminals = """
    {"address":"t1","agent":"sh","cwd":"/src/a","where":"Checkout review / ready","state":"live"},
    {"address":"t2","name":"build-watch","agent":"sh","where":"Checkout review / ready","state":"live"},
    {"address":"t3","agent":"Codex","where":"Checkout review / ready","state":"live"},
    {"address":"t4","name":"loose","state":"live"}
    """

    @Test("a desktop tab's terminals become one row that holds their split layout")
    func tabRow() throws {
        let root = """
        {"id":"r","type":"row","children":[\(block("t1", weight: 2)),
          {"id":"c","type":"column","size":{"weight":1},"children":[\(block("t2")),\(block("t3"))]}]}
        """
        let result = try listing(output(
            terminals: terminals, document: document(tabs: [("tb01ab", "ready", root)])
        ))

        #expect(result.rows == [
            BackendTerminalSummary(
                kind: .herdrCore, address: "tab:tb01ab", title: "ready",
                detail: "Checkout review · 3 panes"
            ),
            BackendTerminalSummary(kind: .herdrCore, address: "t4", title: "loose"),
        ])
        #expect(result.tabs.map(\.address) == ["tab:tb01ab"])
        #expect(result.tabs.first?.root == .split(
            id: "r#0", axis: .horizontal, ratio: 2.0 / 3.0,
            first: .pane("t1"),
            second: .split(
                id: "c#0",
                axis: .vertical,
                ratio: 0.5,
                first: .pane("t2"),
                second: .pane("t3")
            )
        ))
        #expect(result.paneNames["t1"] == "sh")
        #expect(result.paneNames["t2"] == "build-watch")
        #expect(result.paneDirectories["t1"] == "/src/a")
    }

    @Test("a tab named by its space, or after it, names the space once", arguments: [
        ("", "Review", "Review", "2 panes"),
        ("Review", "Review", "Review", "2 panes"),
        ("ready", "Review", "ready", "Review · 2 panes"),
        ("ready", "", "ready", "2 panes"),
    ])
    func tabRowNames(_ name: String, space: String, title: String, detail: String) {
        let row = HerdrCoreInventory.tabRow(
            address: "tab:tb01", name: name, spaceName: space, paneCount: 2
        )
        #expect(row.title == title)
        #expect(row.detail == detail)
    }

    @Test("a row of three panes keeps each pane's share of the space")
    func threeWayRow() throws {
        let root = """
        {"id":"r","type":"row","children":[\(block("t1")),\(block("t2")),\(block("t3", weight: 2))]}
        """
        let result = try listing(output(
            terminals: terminals, document: document(tabs: [("tb1", "ready", root)])
        ))

        #expect(result.tabs.first?.root == .split(
            id: "r#0", axis: .horizontal, ratio: 0.25,
            first: .pane("t1"),
            second: .split(
                id: "r#1",
                axis: .horizontal,
                ratio: 1.0 / 3.0,
                first: .pane("t2"),
                second: .pane("t3")
            )
        ))
    }

    @Test("only the live terminals a tab shows become its panes")
    func shownPanes() throws {
        let root = """
        {"id":"r","type":"row","children":[
          {"id":"s","type":"stack","active":"pt2","children":[\(block("t1")),\(block("t2"))]},
          {"id":"h","type":"block","hidden":true,"content":{"terminal":"t3"}},
          {"id":"m","type":"block","content":{"mod":"agents"}},
          \(block("t9")),
          \(block("rohan/t4"))
        ]}
        """
        let finished = terminals + ",{\"address\":\"t9\",\"state\":\"finished\"}"
        let result = try listing(output(
            terminals: finished, document: document(tabs: [("tb1", "ready", root)])
        ))

        #expect(result.tabs.first?.root == .pane("t2"))
        #expect(result.rows.map(\.address) == ["tab:tb1", "t1", "t3", "t4"])
        #expect(result.rows.first?.detail == "Checkout review · 1 pane")
    }

    @Test("a tab without live terminals, or with an unusable ID, lists none")
    func tabsWithoutRows() throws {
        let result = try listing(output(terminals: terminals, document: document(tabs: [
            ("tb1", "empty", "{\"id\":\"r\",\"type\":\"row\",\"children\":[\(block("t9"))]}"),
            ("tb 2", "odd", "{\"id\":\"r\",\"type\":\"row\",\"children\":[\(block("t1"))]}"),
        ])))

        #expect(result.tabs.isEmpty)
        #expect(result.rows.map(\.address) == ["t1", "t2", "t3", "t4"])
    }

    @Test("terminals keep their own rows when the core has no desktop layout", arguments: [
        nil,
        "null",
        "{\"spaces\":\"unexpected\"}",
    ])
    func withoutLayout(_ document: String?) throws {
        let result = try listing(output(terminals: terminals, document: document))

        #expect(result.tabs.isEmpty)
        #expect(result.rows.map(\.address) == ["t1", "t2", "t3", "t4"])
        #expect(result.rows.first?.title == "Checkout review / ready")
    }

    @Test("a core that refuses the document request still lists its terminals")
    func refusedDocument() throws {
        let stdout = """
        GHOSTHUB_HC_JSON
        {"terminals":[\(terminals)]}
        GHOSTHUB_HC_DOC
        {"error":{"code":-32601,"message":"no method doc.get"},"id":1,"jsonrpc":"2.0"}
        """

        #expect(try listing(stdout).rows.map(\.address) == ["t1", "t2", "t3", "t4"])
    }

    @Test("a tab's address is told apart from a terminal's")
    func addresses() {
        #expect(HerdrCoreInventory.isTabAddress("tab:tb01ab"))
        #expect(!HerdrCoreInventory.isTabAddress("tb01ab"))
        #expect(!HerdrCoreInventory.isTabAddress("tab:"))
        #expect(!HerdrCoreInventory.isTabAddress("tab:-x"))
        #expect(WorkspaceBackendTerminalSelection(
            hostID: UUID(),
            kind: .herdrCore,
            address: "tab:tb1"
        ).showsWindow)
        #expect(!WorkspaceBackendTerminalSelection(hostID: UUID(), kind: .herdrCore, address: "t1")
            .showsWindow)
        #expect(WorkspaceBackendTerminalSelection(hostID: UUID(), kind: .rex, address: "window:1")
            .showsWindow)
    }
}
