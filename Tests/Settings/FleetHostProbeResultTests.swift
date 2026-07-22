import Foundation
import GhosthubWorkspace
import Testing
@testable import GhosthubSettings

struct SSHHostProbeResultTests {
    @Test("saved snapshot hosts map directly to probe summaries")
    func snapshotHostSummaryMapping() {
        let host = HostSummary(
            id: UUID(),
            configKey: "mini",
            name: "Mac Mini",
            kind: .remote,
            platform: .macOS,
            sshDestination: "mini.local",
            lastKnownReachable: true
        )

        let summary = HostProbeSummary.fromHostSummary(host)

        #expect(summary.host == host)
        #expect(summary.reachabilityKnown)
        #expect(summary.name == "Mac Mini")
        #expect(summary.hostname == "mini.local")
        #expect(summary.subtitle == "mini.local · macOS")
    }

    @Test("probe errors expose display text")
    func probeErrorDisplayText() {
        let error = HostProbeError.message("SSH unavailable.")

        #expect(error.displayMessage == "SSH unavailable.")
    }
}
