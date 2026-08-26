import GhosthubTestSupport
import Testing
@testable import GhosthubApp

@Suite("Tailscale discovery")
struct TailscaleDiscoveryTests {
    @Test("isolated demo never falls back to installed Tailscale paths")
    func isolatesDemoBinary() {
        #expect(TailscaleDiscovery.candidatePaths(environment: [
            "GHOSTHUB_DEMO_ROOT": "/tmp/ghosthub-demo-root",
        ]) == [
            "/tmp/ghosthub-demo-root/bin/tailscale",
        ])
    }

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

    @Test("SSH usernames resolve with bounded concurrency")
    func resolvesSSHUsersConcurrently() async throws {
        let fixture = try TempDirectoryFixture()
        let tailscale = try fixture.createExecutable(
            name: "tailscale",
            content: """
            #!/bin/sh
            printf '%s\n' '{"Peer":{"a":{"ID":"a","HostName":"a","DNSName":"a.tailnet.ts.net.","OS":"linux","Online":true},"b":{"ID":"b","HostName":"b","DNSName":"b.tailnet.ts.net.","OS":"linux","Online":true},"c":{"ID":"c","HostName":"c","DNSName":"c.tailnet.ts.net.","OS":"linux","Online":true},"d":{"ID":"d","HostName":"d","DNSName":"d.tailnet.ts.net.","OS":"linux","Online":true}}}'
            """
        )
        let activity = LockedValue((active: 0, peak: 0))

        let result = await TailscaleDiscovery.discoverPeers(
            tailscalePaths: [tailscale.path],
            environment: [:],
            sshUsernameProvider: { _ in
                activity.withLock {
                    $0.active += 1
                    $0.peak = max($0.peak, $0.active)
                }
                try? await Task.sleep(nanoseconds: 50_000_000)
                activity.withLock { $0.active -= 1 }
                return "deployer"
            },
            maximumConcurrentUsernameResolutions: 2
        )

        let peers = try result.get()
        #expect(activity.load().peak == 2)
        #expect(peers.allSatisfy { $0.sshUsername == "deployer" })
    }

    @Test("SSH username discovery has an overall deadline")
    func boundsSSHUsernameResolutionTime() async throws {
        let fixture = try TempDirectoryFixture()
        let tailscale = try fixture.createExecutable(
            name: "tailscale",
            content: """
            #!/bin/sh
            printf '%s\n' '{"Peer":{"node":{"ID":"node","HostName":"build-node","DNSName":"build-node.tailnet.ts.net.","OS":"linux","Online":true}}}'
            """
        )
        let completions = LockedValue(0)

        let result = await TailscaleDiscovery.discoverPeers(
            tailscalePaths: [tailscale.path],
            environment: [:],
            sshUsernameProvider: { _ in
                await Task.detached {
                    try? await Task.sleep(nanoseconds: 2_000_000_000)
                }.value
                completions.withLock { $0 += 1 }
                return "too-late"
            },
            usernameResolutionTimeoutNanoseconds: 10_000_000
        )

        let peer = try #require(try result.get().first)
        #expect(peer.sshUsername == nil)
        #expect(completions.load() == 0)
    }

    @Test("available workers claim peers after a stalled lookup")
    func workersClaimNextAvailablePeer() async throws {
        let fixture = try TempDirectoryFixture()
        let tailscale = try fixture.createExecutable(
            name: "tailscale",
            content: """
            #!/bin/sh
            printf '%s\n' '{"Peer":{"a":{"ID":"a","HostName":"a","DNSName":"a.tailnet.ts.net.","OS":"linux","Online":true},"b":{"ID":"b","HostName":"b","DNSName":"b.tailnet.ts.net.","OS":"linux","Online":true},"c":{"ID":"c","HostName":"c","DNSName":"c.tailnet.ts.net.","OS":"linux","Online":true},"d":{"ID":"d","HostName":"d","DNSName":"d.tailnet.ts.net.","OS":"linux","Online":true}}}'
            """
        )
        let releaseStalledLookup = AsyncGate()

        let result = await TailscaleDiscovery.discoverPeers(
            tailscalePaths: [tailscale.path],
            environment: [:],
            sshUsernameProvider: { hostname in
                if hostname == "a.tailnet.ts.net" {
                    await releaseStalledLookup.wait()
                    return nil
                }
                releaseStalledLookup.open()
                return "deployer"
            },
            maximumConcurrentUsernameResolutions: 2,
            usernameResolutionTimeoutNanoseconds: .max
        )

        let peers = try result.get()
        #expect(peers.first { $0.hostName == "a" }?.sshUsername == nil)
        #expect(peers.filter { $0.sshUsername == "deployer" }.count == 3)
    }
}
