import Foundation
import GhosthubTransport
import GhosthubWorkspace
import GhosthubZellij
import Synchronization
import Testing
@testable import GhosthubApp

private struct CapturedZellijCommand: Equatable, Sendable {
    var executable: String
    var command: String
}

private final class ZellijCommandRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var commands = [CapturedZellijCommand]()

    func append(_ command: CapturedZellijCommand) {
        lock.withLock { commands.append(command) }
    }

    var snapshot: [CapturedZellijCommand] {
        lock.withLock { commands }
    }
}

@Suite("Zellij inventory client")
struct ZellijInventoryClientTests {
    @Test("local discovery resolves Zellij and excludes exited sessions")
    func localDiscovery() {
        let commands = ZellijCommandRecorder()
        let client = ZellijInventoryClient(
            commandRunner: commandRunner(capturing: commands),
            connectionArgumentsProvider: { _ in [] }
        )

        #expect(client.discover(on: .local) == .available(["api"]))
        let captured = commands.snapshot
        #expect(captured.count == 2)
        #expect(captured[0].executable == "/bin/account-shell")
        #expect(captured[0].command.contains("command -v zellij"))
        #expect(captured[1].command.contains(
            "'/opt/homebrew/bin/zellij' 'list-sessions' '--no-formatting'"
        ))
    }

    @Test("remote discovery samples SSH routing once")
    func remoteDiscovery() {
        let commands = ZellijCommandRecorder()
        let routeSamples = Mutex(0)
        let host = SSHHostInfo(
            user: "dev",
            hostname: "build.example",
            port: 2222
        )
        let client = ZellijInventoryClient(
            commandRunner: commandRunner(capturing: commands),
            connectionArgumentsProvider: { suppliedHost in
                #expect(suppliedHost == host)
                return routeSamples.withLock { samples in
                    samples += 1
                    return samples == 1
                        ? ["-F", "/tmp/ghosthub ssh config"]
                        : ["-F", "/tmp/changed ssh config"]
                }
            }
        )

        #expect(client.discover(on: .ssh(host)) == .available(["api"]))
        let captured = commands.snapshot
        #expect(routeSamples.withLock { $0 } == 1)
        #expect(captured.count == 2)
        #expect(captured.allSatisfy { $0.command.contains("/usr/bin/ssh") })
        #expect(captured.allSatisfy {
            $0.command.contains("/tmp/ghosthub ssh config")
        })
        #expect(captured.allSatisfy {
            $0.command.contains("dev@build.example")
        })
    }

    @Test("missing Zellij is a silent optional capability")
    func missingExecutable() {
        let runner = AccountCommandRunner(
            processRunner: { _, _, _, _ in
                AccountCommandOutput(
                    status: 127,
                    stdout: "",
                    stderr: "zellij: command not found"
                )
            }
        )
        let client = ZellijInventoryClient(
            commandRunner: runner,
            connectionArgumentsProvider: { _ in [] }
        )

        #expect(client.discover(on: .local) == .unavailable)
    }

    @Test("Windows hosts are unavailable without starting a process")
    func windowsUnavailable() {
        let calls = Mutex(0)
        let runner = AccountCommandRunner(
            processRunner: { _, _, _, _ in
                calls.withLock { $0 += 1 }
                return AccountCommandOutput(status: 0, stdout: "", stderr: "")
            }
        )
        let client = ZellijInventoryClient(
            commandRunner: runner,
            connectionArgumentsProvider: { _ in [] }
        )
        let host = SSHHostInfo(
            user: nil,
            hostname: "windows.example",
            port: nil,
            platform: .windows
        )

        #expect(client.discover(on: .ssh(host)) == .unavailable)
        #expect(calls.withLock { $0 } == 0)
    }

    private func commandRunner(
        capturing commands: ZellijCommandRecorder
    ) -> AccountCommandRunner {
        AccountCommandRunner(
            processRunner: { executable, arguments, _, _ in
                let command = arguments.last ?? ""
                commands.append(CapturedZellijCommand(
                    executable: executable,
                    command: command
                ))
                if command.contains("command -v zellij") {
                    return AccountCommandOutput(
                        status: 0,
                        stdout: "GHOSTHUB_ZELLIJ_PATH\n/opt/homebrew/bin/zellij\n",
                        stderr: ""
                    )
                }
                return AccountCommandOutput(
                    status: 0,
                    stdout: """
                    shell startup output
                    GHOSTHUB_ZELLIJ_SESSIONS
                    api [Created 4m 3s ago]
                    archived [Created 2d 1h ago] (EXITED - attach to resurrect)

                    """,
                    stderr: ""
                )
            },
            loginShellProvider: { "/bin/account-shell" }
        )
    }
}
