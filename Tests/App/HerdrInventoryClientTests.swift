import Foundation
import GhosthubHerdr
import GhosthubTransport
import GhosthubWorkspace
import Synchronization
import Testing
@testable import GhosthubApp

private struct CapturedHerdrCommand: Equatable, Sendable {
    var executable: String
    var command: String
}

private final class HerdrCommandRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var commands = [CapturedHerdrCommand]()

    func append(_ command: CapturedHerdrCommand) {
        lock.withLock { commands.append(command) }
    }

    var snapshot: [CapturedHerdrCommand] {
        lock.withLock { commands }
    }
}

@Suite("Herdr inventory client")
struct HerdrInventoryClientTests {
    @Test("local discovery resolves Herdr before listing running sessions")
    func localDiscovery() {
        let commands = HerdrCommandRecorder()
        let client = HerdrInventoryClient(
            commandRunner: commandRunner(capturing: commands),
            connectionArgumentsProvider: { _ in [] }
        )

        let result = client.discover(on: .local)

        #expect(result == .available([
            HerdrSessionSummary(name: "api", isDefault: true, state: .running),
        ]))
        let captured = commands.snapshot
        #expect(captured.count == 2)
        #expect(captured[0].executable == "/bin/account-shell")
        #expect(captured[0].command.contains("command -v herdr"))
        #expect(captured[1].command.contains("'/opt/homebrew/bin/herdr' 'session' 'list' '--json'"))
    }

    @Test("remote discovery uses injected SSH routing in an account login shell")
    func remoteDiscovery() {
        let commands = HerdrCommandRecorder()
        let routeSamples = Mutex(0)
        let host = SSHHostInfo(
            user: "dev",
            hostname: "build.example",
            port: 2222
        )
        let client = HerdrInventoryClient(
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

        #expect(client.discover(on: .ssh(host)) == .available([
            HerdrSessionSummary(name: "api", isDefault: true, state: .running),
        ]))
        let captured = commands.snapshot
        #expect(routeSamples.withLock { $0 } == 1)
        #expect(captured.count == 2)
        #expect(captured.allSatisfy { $0.executable == "/bin/account-shell" })
        #expect(captured.allSatisfy { $0.command.contains("/usr/bin/ssh") })
        #expect(captured.allSatisfy { $0.command.contains("/tmp/ghosthub ssh config") })
        #expect(captured.allSatisfy { $0.command.contains("dev@build.example") })
    }

    @Test("Windows hosts are unavailable without starting a process")
    func windowsUnavailable() {
        let calls = Mutex(0)
        let routeSamples = Mutex(0)
        let runner = AccountCommandRunner(
            processRunner: { _, _, _, _ in
                calls.withLock { $0 += 1 }
                return AccountCommandOutput(status: 0, stdout: "", stderr: "")
            }
        )
        let host = SSHHostInfo(
            user: nil,
            hostname: "windows.example",
            port: nil,
            platform: .windows
        )
        let client = HerdrInventoryClient(
            commandRunner: runner,
            connectionArgumentsProvider: { _ in
                routeSamples.withLock { $0 += 1 }
                return []
            }
        )

        #expect(client.discover(on: .ssh(host)) == .unavailable)
        #expect(calls.withLock { $0 } == 0)
        #expect(routeSamples.withLock { $0 } == 0)
    }

    @Test("exit 127 is silent unavailability")
    func missingExecutable() {
        let runner = AccountCommandRunner(
            processRunner: { _, _, _, _ in
                AccountCommandOutput(
                    status: 127,
                    stdout: "",
                    stderr: "herdr: command not found"
                )
            }
        )
        let client = HerdrInventoryClient(
            commandRunner: runner,
            connectionArgumentsProvider: { _ in [] }
        )

        #expect(client.discover(on: .local) == .unavailable)
    }

    @Test("malformed inventory remains a warning-producing failure")
    func malformedInventory() {
        let runner = AccountCommandRunner(
            processRunner: { _, arguments, _, _ in
                let command = arguments.last ?? ""
                if command.contains("command -v herdr") {
                    return executableOutput()
                }
                return AccountCommandOutput(
                    status: 0,
                    stdout: "GHOSTHUB_HERDR_JSON\nnot-json",
                    stderr: ""
                )
            },
            loginShellProvider: { "/bin/account-shell" }
        )
        let client = HerdrInventoryClient(
            commandRunner: runner,
            connectionArgumentsProvider: { _ in [] }
        )

        #expect(client.discover(on: .local) == .failure(.malformedJSON))
    }

    private func commandRunner(
        capturing commands: HerdrCommandRecorder
    ) -> AccountCommandRunner {
        AccountCommandRunner(
            processRunner: { executable, arguments, _, _ in
                let command = arguments.last ?? ""
                commands.append(CapturedHerdrCommand(
                    executable: executable,
                    command: command
                ))
                if command.contains("command -v herdr") {
                    return executableOutput()
                }
                return sessionOutput()
            },
            loginShellProvider: { "/bin/account-shell" }
        )
    }
}

private func executableOutput() -> AccountCommandOutput {
    AccountCommandOutput(
        status: 0,
        stdout: "login banner\nGHOSTHUB_HERDR_PATH\n/opt/homebrew/bin/herdr\n",
        stderr: ""
    )
}

private func sessionOutput() -> AccountCommandOutput {
    AccountCommandOutput(
        status: 0,
        stdout: """
        profile startup
        GHOSTHUB_HERDR_JSON
        {"sessions":[{"name":"api","default":true,"running":true,"session_dir":"/tmp/herdr","socket_path":"/tmp/herdr/herdr.sock"}]}
        """,
        stderr: ""
    )
}
