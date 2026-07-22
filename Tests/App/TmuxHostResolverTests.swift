import Foundation
import GhosthubTestSupport
import GhosthubTmux
import GhosthubWorkspace
import Testing
@testable import GhosthubApp

struct TmuxHostResolverTests {
    @Test("local hosts resolve to the local tmux server")
    func localHost() {
        #expect(TmuxHostResolver.resolve(.fixture()) == .local)
    }

    @Test("SSH destinations resolve user host and port")
    func remoteHost() {
        let host = HostSummary.fixture(
            kind: .remote,
            sshDestination: "wesm@build-box:2222"
        )
        #expect(
            TmuxHostResolver.resolve(host)
                == .ssh(SSHHostInfo(
                    user: "wesm",
                    hostname: "build-box",
                    port: 2222
                ))
        )
    }

    @Test("remote hosts without an SSH destination cannot attach")
    func missingDestination() {
        #expect(TmuxHostResolver.resolve(.fixture(kind: .remote)) == nil)
    }

    @Test("raw IPv6 destinations use the default SSH port")
    func rawIPv6Destination() {
        #expect(
            TmuxHostResolver.parseSSHDestination("2001:db8::42")
                == SSHHostInfo(
                    user: nil,
                    hostname: "2001:db8::42",
                    port: nil
                )
        )
    }

    @Test("bracketed IPv6 destinations accept user and port")
    func bracketedIPv6Destination() {
        #expect(
            TmuxHostResolver.parseSSHDestination(
                "wesm@[2001:db8::42]:2222"
            ) == SSHHostInfo(
                user: "wesm",
                hostname: "2001:db8::42",
                port: 2222
            )
        )
    }
}
