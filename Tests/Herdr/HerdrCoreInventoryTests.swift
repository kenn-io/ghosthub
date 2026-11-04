import Foundation
import GhosthubWorkspace
import Testing
@testable import GhosthubHerdr

@Suite("Herdr core inventory")
struct HerdrCoreInventoryTests {
    @Test("live local terminal addresses survive display name changes")
    func localTerminals() {
        let result = HerdrCoreInventory.parse(status: 0, stdout: """
        Login banner
        GHOSTHUB_HC_JSON
        {"terminals":[
          {"address":"t7","name":"review","state":"live","agent":"Claude"},
          {"address":"t8","state":"live","agent":"Codex"},
          {"address":"t9","state":"finished"},
          {"address":"remote/t7","name":"remote-review","state":"live"}
        ],"hidden_finished":1,"machines":[]}
        """, stderr: "")
        guard case let .available(sessions, tuiAvailable, failures) = result else {
            Issue.record("Expected core inventory, received \(result)")
            return
        }
        #expect(!tuiAvailable)
        #expect(failures.isEmpty)
        #expect(sessions.map(\.name) == ["t7", "t8"])
        #expect(sessions.map(\.title) == ["review", "Codex"])
        #expect(sessions.allSatisfy { $0.backend == .core && $0.state == .running })
        let hostID = UUID()
        #expect(sessions[0].matches(.init(hostID: hostID, name: "t7", backend: .core)))
        #expect(!sessions[0].matches(.init(hostID: hostID, name: "t7")))
    }

    @Test("invalid or duplicate local addresses cannot become attachment targets", arguments: [
        "{\"terminals\":[{\"address\":\"--help\",\"state\":\"live\"}]}",
        "{\"terminals\":[{\"address\":\"t1\",\"state\":\"live\"},{\"address\":\"t1\",\"state\":\"live\"}]}",
        "{\"sessions\":[]}",
    ])
    func invalidInventory(_ json: String) {
        #expect(HerdrCoreInventory.parse(
            status: 0, stdout: "GHOSTHUB_HC_JSON\n\(json)", stderr: ""
        ) == .failure(.malformedJSON))
    }

    @Test("failed and unframed inventory is reported")
    func failures() {
        #expect(HerdrCoreInventory.parse(status: 1, stdout: "", stderr: "core unavailable")
            == .failure(.commandFailed(status: 1, stderr: "core unavailable")))
        #expect(HerdrCoreInventory.parse(status: 0, stdout: "{\"terminals\":[]}", stderr: "")
            == .failure(.missingMarker))
    }
}
