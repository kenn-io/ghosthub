import GhosthubWorkspace
import Testing
@testable import GhosthubSettings

struct TailscalePeerTests {
    @Test("uses the MagicDNS short hostname for SSH")
    func usesShortHostnameForSSH() {
        let peer = TailscalePeer(
            id: "x",
            hostName: "box",
            dnsName: "box.tailnet.ts.net.",
            os: "linux",
            isOnline: true
        )

        #expect(peer.sshAddress == "box")
    }

    @Test("does not depend on DNS name formatting")
    func ignoresDNSNameFormatting() {
        let peer = TailscalePeer(
            id: "x",
            hostName: "box",
            dnsName: "box.tailnet.ts.net",
            os: "linux",
            isOnline: true
        )

        #expect(peer.sshAddress == "box")
    }

    @Test("maps supported operating systems to host platforms")
    func mapsSupportedPlatforms() {
        #expect(peer(os: "macOS").platform == .macOS)
        #expect(peer(os: "linux").platform == .linux)
        #expect(peer(os: "windows").platform == .windows)
        #expect(peer(os: "ios").platform == .linux)
    }

    @Test("marks desktop peers as SSH capable")
    func sshCapability() {
        #expect(peer(os: "linux").isSSHCapable)
        #expect(peer(os: "macOS").isSSHCapable)
        #expect(peer(os: "windows").isSSHCapable)
        #expect(!peer(os: "ios").isSSHCapable)
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
