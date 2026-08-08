import GhosthubTransport
import Foundation
import GhosthubTestSupport
import GhosthubTmux
import GhosthubWorkspace
import Testing
@testable import GhosthubApp

struct CommandHostResolverTests {
    @Test("local hosts resolve to the local tmux server")
    func localHost() {
        #expect(CommandHostResolver.resolve(.fixture()) == .local)
    }

    @Test("SSH destinations resolve user host and port")
    func remoteHost() {
        let host = HostSummary.fixture(
            kind: .remote,
            sshDestination: "wesm@build-box:2222"
        )
        #expect(
            CommandHostResolver.resolve(host)
                == .ssh(SSHHostInfo(
                    user: "wesm",
                    hostname: "build-box",
                    port: 2222
                ))
        )
    }

    @Test("remote hosts without an SSH destination cannot attach")
    func missingDestination() {
        #expect(CommandHostResolver.resolve(.fixture(kind: .remote)) == nil)
    }

    @Test("Windows hosts preserve their native command platform")
    func windowsRemoteHost() {
        let host = HostSummary.fixture(
            kind: .remote,
            platform: .windows,
            sshDestination: "wesm@arm-builder"
        )

        #expect(
            CommandHostResolver.resolve(host)
                == .ssh(SSHHostInfo(
                    user: "wesm",
                    hostname: "arm-builder",
                    port: nil,
                    platform: .windows
                ))
        )
    }

    @Test("raw IPv6 destinations use the default SSH port")
    func rawIPv6Destination() {
        #expect(
            CommandHostResolver.parseSSHDestination("2001:db8::42")
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
            CommandHostResolver.parseSSHDestination(
                "wesm@[2001:db8::42]:2222"
            ) == SSHHostInfo(
                user: "wesm",
                hostname: "2001:db8::42",
                port: 2222
            )
        )
    }
}
