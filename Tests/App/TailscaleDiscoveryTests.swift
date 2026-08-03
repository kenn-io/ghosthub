import GhosthubTestSupport
import Testing
@testable import GhosthubApp

@Suite("Tailscale discovery")
struct TailscaleDiscoveryTests {
    @Test("forces the macOS application binary into CLI mode")
    func forcesCLIEnvironment() async throws {
        let fixture = try TempDirectoryFixture()
        let tailscale = try fixture.createExecutable(
            name: "tailscale",
            content: """
            #!/bin/sh
            if [ "${TAILSCALE_BE_CLI:-}" != "1" ]; then
              printf 'launched application instead of CLI'
              exit 0
            fi
            printf '{"Peer":{}}\n'
            """
        )

        let result = await TailscaleDiscovery.discoverPeers(
            tailscalePaths: [tailscale.path],
            environment: [:]
        )

        #expect(try result.get().isEmpty)
    }

    @Test("imports use the effective OpenSSH user")
    func resolvesEffectiveSSHUser() async throws {
        let fixture = try TempDirectoryFixture()
        let tailscale = try fixture.createExecutable(
            name: "tailscale",
            content: """
            #!/bin/sh
            printf '%s\n' '{"Peer":{"node":{"ID":"node","HostName":"build-node","DNSName":"build-node.tailnet.ts.net.","OS":"linux","Online":true}}}'
            """
        )

        let result = await TailscaleDiscovery.discoverPeers(
            tailscalePaths: [tailscale.path],
            environment: [:],
            sshUsernameProvider: { hostname in
                #expect(hostname == "build-node.tailnet.ts.net")
                return "deployer"
            }
        )

        let peer = try #require(try result.get().first)
        #expect(peer.sshUsername == "deployer")
    }
}
