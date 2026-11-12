import Foundation
import GhosthubWorkspace
import Testing
@testable import GhosthubBackendTerminal

@Suite("Herdr core inventory")
struct HerdrCoreInventoryTests {
    @Test("desktop space and tab names identify terminals without changing their address")
    func desktopTerminalNames() {
        for location in ["Checkout review / desktop-review", "Checkout review / ready"] {
            let result = HerdrCoreInventory.parse(status: 0, stdout: """
            GHOSTHUB_HC_JSON
            {"terminals":[
              {"address":"t1","agent":"sh","where":"\(location)","state":"live"},
              {"address":"t2","name":"build-watch","agent":"sh","where":"\(location)","state":"live"},
              {"address":"t3","agent":"Codex","where":"  ","state":"live"}
            ]}
            """, stderr: "")
            guard case let .available(terminals) = result else {
                Issue.record("Expected desktop terminals, received \(result)")
                return
            }
            #expect(terminals.map(\.address) == ["t1", "t2", "t3"])
            #expect(terminals.map(\.title) == [location, "build-watch", "Codex"])
        }
    }

    @Test("live local terminal addresses survive display name changes")
    func localTerminals() {
        let result = HerdrCoreInventory.parse(status: 0, stdout: """
        Login banner
        GHOSTHUB_HC_JSON
        {"terminals":[
          {"address":"t7","name":"review","state":"live","agent":"Claude"},
          {"address":"t8","state":"live","agent":"Codex"},
          {"address":"t9","state":"finished"},
          {"address":"t10","state":"live"},
          {"address":"remote/t7","name":"remote-review","state":"live"}
        ],"hidden_finished":1,"machines":[]}
        """, stderr: "")
        guard case let .available(terminals) = result else {
            Issue.record("Expected core inventory, received \(result)")
            return
        }
        #expect(terminals.map(\.address) == ["t7", "t8", "t10"])
        #expect(terminals.map(\.title) == ["review", "Codex", "t10"])
        #expect(terminals.allSatisfy { $0.kind == .herdrCore })
        let hostID = UUID()
        #expect(terminals[0].matches(.init(hostID: hostID, kind: .herdrCore, address: "t7")))
        #expect(!terminals[0].matches(.init(hostID: hostID, kind: .rex, address: "t7")))
    }

    @Test("invalid or duplicate local addresses cannot become attachment targets", arguments: [
        "{\"terminals\":[{\"address\":\"--help\",\"state\":\"live\"}]}",
        "{\"terminals\":[{\"address\":\"t1\",\"state\":\"live\"},{\"address\":\"t1\",\"state\":\"live\"}]}",
        "{\"sessions\":[]}",
    ])
    func invalidInventory(_ json: String) {
        #expect(HerdrCoreInventory.parse(
            status: 0, stdout: "GHOSTHUB_HC_JSON\n\(json)", stderr: ""
        ) == .failure(.malformedJSON(.herdrCore)))
    }

    @Test("failed and unframed inventory is reported")
    func failures() {
        #expect(HerdrCoreInventory.parse(status: 1, stdout: "", stderr: "core unavailable")
            == .failure(.commandFailed(.herdrCore, status: 1, stderr: "core unavailable")))
        #expect(HerdrCoreInventory.parse(status: 0, stdout: "{\"terminals\":[]}", stderr: "")
            == .failure(.missingMarker(.herdrCore)))
    }
}
