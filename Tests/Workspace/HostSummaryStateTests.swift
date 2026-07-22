import Foundation
import GhosthubWorkspace
import Testing

struct HostSummaryStateTests {
    @Test("remote host connection state follows reachability")
    func remoteHostConnectionState() {
        let online = HostSummary.onlineRemoteFixture(
            name: "Build Box",
            sshDestination: "rpi5-ssd"
        )
        #expect(online.connectionState == .online)

        let connecting = HostSummary.fixture(
            name: "Office Studio",
            kind: .remote,
            platform: .macOS,
            sshDestination: "office",
            lastKnownReachable: false,
            lastSeenAt: nil,
            version: nil
        )
        #expect(connecting.connectionState == .connecting)

        let degraded = HostSummary.fixture(
            name: "Office Studio",
            kind: .remote,
            platform: .macOS,
            sshDestination: "office",
            lastKnownReachable: true,
            lastSeenAt: Date(timeIntervalSince1970: 1_700_000_000),
            version: "0.1.0",
            remoteDiagnostics: [.missingGhFixture()]
        )
        #expect(degraded.connectionState == .degraded)
    }

    @Test("local host connection state is local")
    func localHostConnectionState() {
        let host = HostSummary.localFixture()

        #expect(host.connectionState == .local)
    }

    @Test("transientOverride wins over decodedConnectionState")
    func transientOverrideWins() {
        var host = HostSummary.onlineRemoteFixture(
            name: "Build Box"
        )
        host.decodedConnectionState = .online
        host.transientOverride = .degraded

        #expect(host.connectionState == .degraded)
    }

    @Test("decodedConnectionState used as baseline when no override")
    func decodedConnectionStateBaseline() {
        var host = HostSummary.fixture(
            name: "Build Box",
            kind: .remote,
            platform: .linux,
            sshDestination: "rpi5-ssd",
            lastKnownReachable: false
        )
        #expect(host.connectionState == .connecting)

        host.decodedConnectionState = .online
        #expect(host.connectionState == .online)
    }
}
