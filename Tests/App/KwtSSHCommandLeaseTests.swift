import Foundation
import GhosthubTransport
import Testing
@testable import GhosthubApp

@Suite("kwt SSH command leases")
struct KwtSSHCommandLeaseTests {
    @Test("an abandoned attachment releases its lease")
    func abandonedAttachmentReleasesLease() async {
        let releases = LockedValue(0)
        var connection: KwtSSHConnection? =
            KwtSSHConnection(
                arguments: ["-F", "/dev/null"],
                routeIdentity: "sha256:route",
                generation: 4,
                release: { releases.withLock { $0 += 1 } }
            )

        connection = nil
        _ = connection

        await waitUntil { releases.load() == 1 }
    }

    @Test("remote command groups use one lease and release it")
    func releasesSuccessfulCommandGroup() async throws {
        let releases = LockedValue(0)
        let arguments = ["-F", "/dev/null", "-S", "/tmp/kwt.sock"]
        let lease = KwtSSHCommandLease { _ in
            KwtSSHConnection(
                arguments: arguments,
                routeIdentity: "sha256:route",
                generation: 4,
                release: { releases.withLock { $0 += 1 } }
            )
        }

        let observed = try await lease.withArguments(
            on: .ssh(Self.host)
        ) { $0 }

        #expect(observed == arguments)
        #expect(releases.load() == 1)
    }

    @Test("remote demo inventory uses the isolated fixture transport")
    func demoInventoryUsesIsolationArguments() async throws {
        let scratch = "/tmp/ghosthub-demo"
        let environment = [
            "GHOSTHUB_DEMO_SCRATCH": scratch,
            "GHOSTHUB_DEMO_SSH_DIR": "\(scratch)/ssh",
        ]
        let expectedArguments = demoSSHIsolationArguments(
            environment: environment
        )
        let lease = KwtSSHCommandLease(environment: environment)
        let client = KwtInventoryClient(
            remoteRunner: { host, arguments, command in
                #expect(host == Self.host)
                #expect(arguments == expectedArguments)
                if command.contains("workspace list --json") {
                    return AccountCommandOutput(
                        status: 0,
                        stdout: "GHOSTHUB_KWT_JSON\n"
                            +
                            #"[{"name":"demo","path":"/srv/demo","session_name":"demo-session","session_live":true}]"#,
                        stderr: ""
                    )
                }
                return AccountCommandOutput(
                    status: 0,
                    stdout: "GHOSTHUB_KWT_JSON\n[]",
                    stderr: ""
                )
            }
        )

        let inventory = try await lease.withArguments(
            on: .ssh(Self.host)
        ) { arguments in
            try await client.load(
                from: .ssh(Self.host),
                sshConnectionArguments: try #require(arguments)
            )
        }

        #expect(inventory.directoryWorkspaces.map(\.name) == ["demo"])
    }

    @Test("failed command groups still release their lease")
    func releasesFailedCommandGroup() async {
        let releases = LockedValue(0)
        let lease = KwtSSHCommandLease { _ in
            KwtSSHConnection(
                arguments: ["-F", "/dev/null"],
                routeIdentity: "sha256:route",
                generation: 4,
                release: { releases.withLock { $0 += 1 } }
            )
        }

        await #expect(throws: TestFailure.self) {
            try await lease.withArguments(on: .ssh(Self.host)) { _ in
                throw TestFailure()
            }
        }
        #expect(releases.load() == 1)
    }

    @Test("release failures are not reported as successful inventory")
    func reportsReleaseFailure() async {
        let lease = KwtSSHCommandLease { _ in
            KwtSSHConnection(
                arguments: ["-F", "/dev/null"],
                routeIdentity: "sha256:route",
                generation: 4,
                release: { throw KwtSSHLeaseError.cleanupFailed }
            )
        }

        await #expect(throws: KwtSSHLeaseError.cleanupFailed) {
            try await lease.withArguments(on: .ssh(Self.host)) { _ in
                "inventory"
            }
        }
    }

    @Test("SCP uses the leased control path and port")
    func translatesLeaseArgumentsForSCP() {
        #expect(KwtSSHCommandLease.scpArguments(from: [
            "-F", "/dev/null",
            "-S", "/tmp/kwt control.sock",
            "-p", "2200",
            "-o", "BatchMode=yes",
        ]) == [
            "-F", "/dev/null",
            "-o", "ControlPath=/tmp/kwt control.sock",
            "-P", "2200",
            "-o", "BatchMode=yes",
        ])
    }

    @Test("local command groups do not acquire SSH")
    func localBypassesLease() async throws {
        let acquisitions = LockedValue(0)
        let lease = KwtSSHCommandLease { _ in
            acquisitions.withLock { $0 += 1 }
            throw TestFailure()
        }

        let arguments = try await lease.withArguments(on: .local) { $0 }

        #expect(arguments == nil)
        #expect(acquisitions.load() == 0)
    }

    @Test("a lost daemon master invalidates the pooled lease")
    func runCommandInvalidatesUnusableConnection() async throws {
        let acquireCount = LockedValue(0)
        let route = KwtSSHRouteSnapshot.fixture()
        let pool = KwtSSHConnectionPool { route, _ in
            acquireCount.withLock { $0 += 1 }
            return KwtSSHTestLease(
                routeIdentity: route.routeIdentity,
                generation: UInt64(acquireCount.load())
            )
        }
        let lease = KwtSSHCommandLease { _ in
            try await pool.acquire(route: route, prompt: { _ in "" })
        }

        let holder = try await lease.acquire(on: Self.host)
        let healthy = try await lease.runCommand(on: Self.host) { _ in
            AccountCommandOutput(status: 1, stdout: "", stderr: "not found")
        }
        #expect(healthy.status == 1)
        #expect(await pool.isConnected(routeIdentity: route.routeIdentity))

        let lost = try await lease.runCommand(on: Self.host) { _ in
            AccountCommandOutput(
                status: 255,
                stdout: "",
                stderr: "Connection closed by UNKNOWN port 65535"
            )
        }
        #expect(lost.status == 255)
        await waitUntil {
            await pool.isConnected(
                routeIdentity: route.routeIdentity
            ) == false
        }

        let replacement = try await lease.acquire(on: Self.host)
        #expect(replacement.generation == 2)
        try await holder.release()
        try await replacement.release()
    }

    private struct TestFailure: Error {}

    private static let host = SSHHostInfo(
        user: "tester",
        hostname: "builder.example.test",
        port: 22
    )
}
