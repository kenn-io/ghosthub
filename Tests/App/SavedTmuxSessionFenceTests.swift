import Foundation
import Testing
@testable import GhosthubApp

@Suite("Saved tmux session kill fences")
struct SavedTmuxSessionFenceTests {
    @MainActor
    @Test("a kill on another tmux server leaves the default server's session free to restore")
    func fenceIsPerServer() {
        let restores = SavedTmuxSessionRestores()
        let host = UUID()
        restores.fence(session: "api", socketName: "kwt", hostID: host)
        #expect(!restores.isFenced(session: "api", socketName: nil, hostID: host))

        restores.fence(session: "api", socketName: nil, hostID: host)
        #expect(restores.isFenced(session: "api", socketName: nil, hostID: host))
        restores.lift(session: "api", socketName: "kwt", hostID: host)
        #expect(restores.isFenced(session: "api", socketName: nil, hostID: host))
    }
}
