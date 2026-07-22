import GhosthubWorkspace
import Testing
@testable import GhosthubSettings

struct TailscalePeerTests {
    @Test("strips trailing dot from DNS name")
    func stripsDotFromDNS() {
        let peer = TailscalePeer(
            id: "x",
            hostName: "box",
            dnsName: "box.tailnet.ts.net.",
            os: "linux",
            isOnline: true
        )

        #expect(peer.sshAddress == "box.tailnet.ts.net")
    }

    @Test("preserves DNS name without trailing dot")
    func preservesDNSWithoutDot() {
        let peer = TailscalePeer(
            id: "x",
            hostName: "box",
            dnsName: "box.tailnet.ts.net",
            os: "linux",
            isOnline: true
        )

        #expect(peer.sshAddress == "box.tailnet.ts.net")
    }

    @Test("maps supported operating systems to host platforms")
    func mapsSupportedPlatforms() {
        #expect(peer(os: "macOS").platform == .macOS)
        #expect(peer(os: "linux").platform == .linux)
        #expect(peer(os: "ios").platform == .linux)
    }

    @Test("marks only linux and macOS peers as SSH capable")
    func sshCapability() {
        #expect(peer(os: "linux").isSSHCapable)
        #expect(peer(os: "macOS").isSSHCapable)
        #expect(!peer(os: "windows").isSSHCapable)
    }

    private func peer(os: String) -> TailscalePeer {
        TailscalePeer(
            id: os,
            hostName: os,
            dnsName: "\(os).tailnet.ts.net.",
            os: os,
            isOnline: true
        )
    }
}
