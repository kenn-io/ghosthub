import Foundation
import Testing
@testable import GhosthubWorkspace

@Suite("Herdr session models")
struct HerdrSessionModelsTests {
    @Test("selection identity is scoped by host and exact session name")
    func selectionIdentity() {
        let hostID = UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!
        let selection = WorkspaceHerdrSessionSelection(
            hostID: hostID,
            name: "review"
        )

        #expect(selection.id == "\(hostID.uuidString):review")
    }

    @Test("host inventory carries Herdr session summaries")
    func hostInventory() {
        let session = HerdrSessionSummary(
            name: "default",
            isDefault: true,
            state: .running
        )
        let host = HostSummary(
            id: UUID(),
            name: "This Mac",
            kind: .selfHost,
            platform: .macOS,
            herdrSessions: [session],
            herdrAvailable: true
        )

        #expect(host.herdrSessions == [session])
        #expect(host.herdrAvailable)
    }
}
