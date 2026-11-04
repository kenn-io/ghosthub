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
    @Test(
        "both backends share the SSH route and preserve healthy inventory on partial failure",
        arguments: [nil, HerdrBackend.tui, .core]
    )
    func independentBackends(failedBackend: HerdrBackend?) async {
        let commands = HerdrCommandRecorder()
        let client = HerdrInventoryClient(
            commandRunner: AccountCommandRunner(processRunner: { executable, arguments, _, _ in
                let command = arguments.last ?? ""
                commands.append(.init(executable: executable, command: command))
                if command.contains("command -v herdr-core") {
                    return .init(
                        status: 0,
                        stdout: "GHOSTHUB_HC_PATH\n/opt/test/herdr-core\n",
                        stderr: ""
                    )
                }
                if command.contains("command -v herdr") {
                    return .init(
                        status: 0,
                        stdout: "GHOSTHUB_HERDR_PATH\n/opt/test/herdr\n",
                        stderr: ""
                    )
                }
                if command.contains("GHOSTHUB_HC_JSON") {
                    if failedBackend == .core {
                        return .init(status: 1, stdout: "", stderr: "backend unavailable")
                    }
                    return .init(
                        status: 0,
                        stdout: "GHOSTHUB_HC_JSON\n{\"terminals\":[{\"address\":\"t7\",\"state\":\"live\"}]}",
                        stderr: ""
                    )
                }
                if failedBackend == .tui {
                    return .init(status: 1, stdout: "", stderr: "backend unavailable")
                }
                return .init(
                    status: 0,
                    stdout: "GHOSTHUB_HERDR_JSON\n{\"sessions\":[{\"name\":\"t7\",\"default\":false,\"running\":true,\"session_dir\":\"/tmp/test\",\"socket_path\":\"/tmp/test/socket\"}]}",
                    stderr: ""
                )
            }, loginShellProvider: { "/bin/account-shell" }),
            connectionArgumentsProvider: { _ in ["-F", "/tmp/test-route"] }
        )
        let host = SSHHostInfo(user: "dev", hostname: "build.example", port: nil)
        guard case let .available(sessions, tuiAvailable, failures) = await client
            .discover(on: .ssh(host)) else {
            Issue.record("Healthy backend inventory was lost")
            return
        }
        #expect(sessions.map(\.backend) == [HerdrBackend.tui, .core].filter { $0 != failedBackend })
        #expect(tuiAvailable == (failedBackend != .tui))
        #expect(failures == failedBackend.map { [$0: .commandFailed(
            status: 1,
            stderr: "backend unavailable"
        )] } ?? [:])
        #expect(commands.snapshot.count == 4)
        #expect(commands.snapshot.allSatisfy { $0.command.contains("/tmp/test-route") })
    }

    @Test(
        "attachment discovery never invokes the other backend",
        arguments: [HerdrBackend.tui, .core]
    )
    func selectedBackend(_ backend: HerdrBackend) {
        let commands = HerdrCommandRecorder()
        let client = HerdrInventoryClient(
            commandRunner: AccountCommandRunner(processRunner: { executable, arguments, _, _ in
                let command = arguments.last ?? ""
                commands.append(.init(executable: executable, command: command))
                let isCore = command.contains("GHOSTHUB_HC_")
                guard isCore == (backend == .core) else {
                    Issue.record("Attachment queried the unrelated backend")
                    return .init(status: 1, stdout: "", stderr: "unrelated backend failed")
                }
                if command.contains("command -v") {
                    return .init(
                        status: 0,
                        stdout: isCore
                            ? "GHOSTHUB_HC_PATH\n/opt/test/herdr-core\n"
                            : "GHOSTHUB_HERDR_PATH\n/opt/test/herdr\n",
                        stderr: ""
                    )
                }
                return .init(
                    status: 0,
                    stdout: isCore
                        ? "GHOSTHUB_HC_JSON\n{\"terminals\":[{\"address\":\"t7\",\"state\":\"live\"}]}"
                        :
                        "GHOSTHUB_HERDR_JSON\n{\"sessions\":[{\"name\":\"t7\",\"default\":false,\"running\":true,\"session_dir\":\"/tmp/test\",\"socket_path\":\"/tmp/test/socket\"}]}",
                    stderr: ""
                )
            }, loginShellProvider: { "/bin/account-shell" }),
            connectionArgumentsProvider: { _ in [] }
        )
        let host = SSHHostInfo(user: "dev", hostname: "build.example.test", port: nil)
        let result = client.discover(
            on: .ssh(host),
            sshConnectionArguments: ["-F", "/tmp/test-route"],
            backend: backend
        )
        #expect(HerdrSessionProbeOutcome
            .exact(name: "t7", backend: backend, discovery: result) == .present)
        #expect(commands.snapshot.count == 2)
        #expect(commands.snapshot.allSatisfy { $0.command.contains("/tmp/test-route") })
    }

    @Test("core terminals are discovered when the TUI is not installed")
    func coreWithoutTUI() async {
        let client = HerdrInventoryClient(
            commandRunner: AccountCommandRunner(
                processRunner: { _, arguments, _, _ in
                    let command = arguments.last ?? ""
                    if command.contains("command -v herdr-core") {
                        return AccountCommandOutput(
                            status: 0,
                            stdout: "GHOSTHUB_HC_PATH\n/opt/test/bin/hc\n",
                            stderr: ""
                        )
                    }
                    if command.contains("'/opt/test/bin/hc'") {
                        return AccountCommandOutput(
                            status: 0,
                            stdout: "GHOSTHUB_HC_JSON\n{\"terminals\":[{\"address\":\"t7\",\"name\":\"review\",\"state\":\"live\"}]}",
                            stderr: ""
                        )
                    }
                    return AccountCommandOutput(status: 127, stdout: "", stderr: "")
                },
                loginShellProvider: { "/bin/account-shell" }
            ),
            connectionArgumentsProvider: { _ in [] }
        )
        let result = await client.discover(on: .local)
        guard case let .available(sessions, _, _) = result else {
            Issue.record("Expected core terminals, received \(result)")
            return
        }
        #expect(sessions.map(\.name) == ["t7"])
    }

    @Test("local discovery resolves Herdr before listing running sessions")
    func localDiscovery() async {
        let commands = HerdrCommandRecorder()
        let client = HerdrInventoryClient(
            commandRunner: commandRunner(capturing: commands),
            connectionArgumentsProvider: { _ in [] }
        )

        let result = await client.discover(on: .local)

        #expect(result == .available([
            HerdrSessionSummary(name: "api", isDefault: true, state: .running),
        ]))
        let captured = commands.snapshot
        #expect(captured.count == 3)
        #expect(captured[0].executable == "/bin/account-shell")
        #expect(captured[0].command.contains("command -v herdr"))
        #expect(captured[1].command.contains("'/opt/homebrew/bin/herdr' 'session' 'list' '--json'"))
    }

    @Test("remote discovery uses injected SSH routing in an account login shell")
    func remoteDiscovery() async {
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

        #expect(await client.discover(on: .ssh(host)) == .available([
            HerdrSessionSummary(name: "api", isDefault: true, state: .running),
        ]))
        let captured = commands.snapshot
        #expect(routeSamples.withLock { $0 } == 1)
        #expect(captured.count == 3)
        #expect(captured.allSatisfy { $0.executable == "/bin/account-shell" })
        #expect(captured.allSatisfy { $0.command.contains("/usr/bin/ssh") })
        #expect(captured.allSatisfy { $0.command.contains("/tmp/ghosthub ssh config") })
        #expect(captured.allSatisfy { $0.command.contains("dev@build.example") })
    }

    @Test("Windows hosts are unavailable without starting a process")
    func windowsUnavailable() async {
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

        #expect(await client.discover(on: .ssh(host)) == .unavailable)
        #expect(calls.withLock { $0 } == 0)
        #expect(routeSamples.withLock { $0 } == 0)
    }

    @Test("exit 127 is silent unavailability")
    func missingExecutable() async {
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

        #expect(await client.discover(on: .local) == .unavailable)
    }

    @Test("malformed inventory remains a warning-producing failure")
    func malformedInventory() async {
        let runner = AccountCommandRunner(
            processRunner: { _, arguments, _, _ in
                let command = arguments.last ?? ""
                if command.contains("command -v herdr-core") {
                    return AccountCommandOutput(status: 127, stdout: "", stderr: "")
                }
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

        #expect(await client.discover(on: .local) == .failure(.malformedJSON))
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
                if command.contains("command -v herdr-core") {
                    return AccountCommandOutput(status: 127, stdout: "", stderr: "")
                }
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
