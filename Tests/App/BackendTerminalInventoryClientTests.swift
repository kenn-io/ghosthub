import Foundation
import GhosthubBackendTerminal
import GhosthubTransport
import GhosthubWorkspace
import Testing
@testable import GhosthubApp

private final class CommandRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var commands = [String]()

    func append(_ command: String) {
        lock.withLock { commands.append(command) }
    }

    var snapshot: [String] {
        lock.withLock { commands }
    }
}

@Suite("Backend terminal inventory client")
struct BackendTerminalInventoryClientTests {
    private static let coreListing =
        "GHOSTHUB_HC_JSON\n{\"terminals\":[{\"address\":\"t7\",\"name\":\"review\",\"state\":\"live\"}]}"
    private static let rexListing = """
    GHOSTHUB_REX_JSON
    {"status":"running","terminals":[{"session_id":"session:a","session_label":"work",\
    "window_id":"window:1","window_label":"editor","window_index":1,\
    "block_id":"block:01aa","label":"shell","title":"vim"}]}
    """

    private func client(
        commands: CommandRecorder,
        failing: BackendTerminalKind? = nil,
        rexStatus: String? = nil
    ) -> BackendTerminalInventoryClient {
        BackendTerminalInventoryClient(
            commandRunner: AccountCommandRunner(processRunner: { _, arguments, _, _ in
                let command = arguments.last ?? ""
                commands.append(command)
                if command.contains("command -v herdr-core") {
                    return .init(
                        status: 0,
                        stdout: "GHOSTHUB_HC_PATH\n/opt/test/herdr-core\n",
                        stderr: ""
                    )
                }
                if command.contains("'/opt/test/herdr-core'") {
                    return failing == .herdrCore
                        ? .init(status: 1, stdout: "", stderr: "core unavailable")
                        : .init(status: 0, stdout: Self.coreListing, stderr: "")
                }
                if command.contains("rex ls --json") {
                    if failing == .rex {
                        return .init(status: 1, stdout: "", stderr: "rex unavailable")
                    }
                    if let rexStatus {
                        return .init(
                            status: 0,
                            stdout: "GHOSTHUB_REX_JSON\n{\"status\":\"\(rexStatus)\",\"terminals\":[]}",
                            stderr: ""
                        )
                    }
                    return .init(status: 0, stdout: Self.rexListing, stderr: "")
                }
                return .init(status: 127, stdout: "", stderr: "")
            }, loginShellProvider: { "/bin/account-shell" }),
            connectionArgumentsProvider: { _ in ["-F", "/tmp/test-route"] },
            localKwtPath: "/Apps/Ghosthub.app/Contents/Helpers/kwt",
            remoteKwtRevision: "0123456789abcdef0123456789abcdef01234567"
        )
    }

    @Test(
        "every backend shares the SSH route and one failure keeps the others",
        arguments: [nil, BackendTerminalKind.herdrCore, .rex]
    )
    func independentBackends(failing: BackendTerminalKind?) async {
        let commands = CommandRecorder()
        let host = SSHHostInfo(user: "dev", hostname: "build.example", port: nil)
        let results = await client(commands: commands, failing: failing)
            .discover(on: .ssh(host))

        let core = results[.herdrCore]
        let rex = results[.rex]
        if failing == .herdrCore {
            #expect(core == .failure(.commandFailed(
                .herdrCore, status: 1, stderr: "core unavailable"
            )))
        } else {
            #expect(core == .available([
                BackendTerminalSummary(kind: .herdrCore, address: "t7", title: "review"),
            ]))
        }
        if failing == .rex {
            #expect(rex == .failure(.commandFailed(
                .rex, status: 1, stderr: "rex unavailable"
            )))
        } else {
            #expect(rex == .available([
                BackendTerminalSummary(
                    kind: .rex, address: "block:01aa", title: "vim", detail: "work / editor"
                ),
            ]))
        }
        #expect(commands.snapshot.count == 3)
        #expect(commands.snapshot.allSatisfy { $0.contains("/tmp/test-route") })
    }

    @Test("Rex on a remote host runs Ghosthub's managed kwt for this build")
    func remoteRexUsesManagedKwt() {
        let commands = CommandRecorder()
        let host = SSHHostInfo(user: "dev", hostname: "build.example", port: nil)
        _ = client(commands: commands).discover(
            .rex, on: .ssh(host), sshConnectionArguments: ["-F", "/tmp/test-route"]
        )
        let command = commands.snapshot.joined()
        #expect(command
            .contains(".ghosthub/helpers/kwt/0123456789abcdef0123456789abcdef01234567/kwt"))
    }

    @Test("a host with Rex stopped or absent lists no Rex terminals", arguments: [
        "not_running", "not_installed",
    ])
    func stoppedRex(_ status: String) {
        let result = client(commands: CommandRecorder(), rexStatus: status)
            .discover(.rex, on: .local, sshConnectionArguments: nil)
        #expect(result == .unavailable)
    }

    @Test("Herdr core terminals are discovered without the Herdr TUI")
    func coreWithoutTUI() {
        let result = client(commands: CommandRecorder())
            .discover(.herdrCore, on: .local, sshConnectionArguments: nil)
        #expect(result == .available([
            BackendTerminalSummary(kind: .herdrCore, address: "t7", title: "review"),
        ]))
    }

    @Test("Windows hosts are not probed")
    func windowsHost() async {
        let commands = CommandRecorder()
        let host = SSHHostInfo(
            user: "dev", hostname: "win.example", port: nil, platform: .windows
        )
        #expect(await client(commands: commands).discover(on: .ssh(host)).isEmpty)
        #expect(commands.snapshot.isEmpty)
    }
}
