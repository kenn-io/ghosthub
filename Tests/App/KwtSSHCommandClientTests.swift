import Foundation
import GhosthubTestSupport
import GhosthubTransport
import GhosthubWorkspace
import Synchronization
import Testing
@testable import GhosthubApp

@Suite("kwt SSH command client")
struct KwtSSHCommandClientTests {
    @Test("remote commands use Ghosthub-owned kwt daemon state")
    func isolatesDaemonState() async throws {
        let fixture = try TempDirectoryFixture()
        let kwtHome = StateHome.resolved()
            .appendingPathComponent("ssh", isDirectory: true)
            .appendingPathComponent("kwt", isDirectory: true)
        let helper = try fixture.createExecutable(
            name: "kwt",
            content: """
            #!/bin/sh
            [ "${KWT_HOME:-}" = \(shellQuotedCommandArgument(kwtHome.path)) ] || exit 90
            printf 'inventory\n'
            """
        )
        let client = KwtSSHCommandClient(binaryPath: helper.path)

        let output = await client.run(
            on: SSHHostInfo(
                user: "deploy",
                hostname: "build.example.test",
                port: nil
            ),
            command: "printf inventory",
            timeout: 5
        )

        #expect(output.status == 0)
        #expect(output.stdout == "inventory\n")
    }

    @Test("remote commands pass intent to kwt instead of receiving SSH arguments")
    func runsThroughKwt() async {
        let captured = Mutex<(String, [String], TimeInterval)?>(nil)
        let client = KwtSSHCommandClient(
            runner: { executable, arguments, timeout in
                captured.withLock { $0 = (executable, arguments, timeout) }
                return AccountCommandOutput(
                    status: 0,
                    stdout: "inventory\n",
                    stderr: ""
                )
            },
            binaryPath: "/bundle/kwt"
        )
        let host = SSHHostInfo(
            user: "deploy",
            hostname: "build.example.test",
            port: 2200,
            platform: .posix
        )

        let output = await client.run(
            on: host,
            command: "printf inventory",
            timeout: 17,
            expectedRouteIdentity: "sha256:reviewed-route"
        )

        #expect(output.status == 0)
        #expect(output.stdout == "inventory\n")
        #expect(captured.withLock { $0?.0 } == "/bundle/kwt")
        #expect(captured.withLock { $0?.1 } == [
            "ssh", "exec", "--quiet", "--json",
            "--host-key-policy", "strict",
            "--route-identity", "sha256:reviewed-route",
            "--user", "deploy",
            "--port", "2200",
            "build.example.test",
            "--",
            AccountCommandRunner.remoteLoginCommand(
                host: host,
                command: "printf inventory"
            ),
        ])
        #expect(captured.withLock { $0?.2 } == 17)
    }

    @Test("typed kwt setup failures retain existing recovery classification")
    func preservesTypedFailure() async {
        let client = KwtSSHCommandClient(
            runner: { _, _, _ in
                AccountCommandOutput(
                    status: 1,
                    stdout: #"{"error":{"code":"ssh_interaction_required","message":"SSH interaction is required","retryable":false}}"#,
                    stderr: "kwt ssh exec: ssh_interaction_required: SSH interaction is required\n"
                )
            },
            binaryPath: "/bundle/kwt"
        )

        let output = await client.run(
            on: SSHHostInfo(user: nil, hostname: "build.example.test", port: nil),
            command: "true",
            timeout: 5
        )

        #expect(output.status == 255)
        #expect(output.stdout.isEmpty)
        #expect(output.stderr.hasPrefix(
            SSHConnectionArgumentsSnapshot.failureMarker
                + "ssh_interaction_required\n"
        ))
        #expect(SSHConnectionFailure.classify(
            status: output.status,
            output: output.stderr
        ).kind == .authenticationRequired)
    }

    @Test("Windows commands retain the PowerShell remote shell contract")
    func runsWindowsCommand() async {
        let captured = Mutex<[String]?>(nil)
        let client = KwtSSHCommandClient(
            runner: { _, arguments, _ in
                captured.withLock { $0 = arguments }
                return AccountCommandOutput(status: 0, stdout: "", stderr: "")
            },
            binaryPath: "/bundle/kwt"
        )
        let host = SSHHostInfo(
            user: nil,
            hostname: "windows.example.test",
            port: nil,
            platform: .windows
        )

        _ = await client.run(on: host, command: "Write-Output ready", timeout: 8)

        #expect(captured.withLock { $0?.last } == AccountCommandRunner.remoteLoginCommand(
            host: host,
            command: "Write-Output ready"
        ))
    }

    @Test("canceling a command stops its detached runner")
    func cancellationStopsRunner() async {
        let started = Mutex(false)
        let observedCancellation = Mutex(false)
        let client = KwtSSHCommandClient(
            runner: { _, _, _ in
                started.withLock { $0 = true }
                let deadline = Date().addingTimeInterval(0.5)
                while !Task.isCancelled, Date() < deadline {
                    Thread.sleep(forTimeInterval: 0.005)
                }
                observedCancellation.withLock { $0 = Task.isCancelled }
                return AccountCommandOutput(status: 0, stdout: "late\n", stderr: "")
            },
            binaryPath: "/bundle/kwt"
        )

        let task = Task {
            await client.run(
                on: SSHHostInfo(
                    user: nil,
                    hostname: "build.example.test",
                    port: nil
                ),
                command: "slow mutation",
                timeout: 30
            )
        }
        await waitUntil { started.withLock { $0 } }
        task.cancel()

        let output = await task.value
        #expect(observedCancellation.withLock { $0 })
        #expect(output.status == AccountCommandRunner.cancelledStatus)
        #expect(output.stdout.isEmpty)
    }
}
