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
}
