import Foundation
import GhosthubTmux
import GhosthubWorkspace
import Testing
@testable import GhosthubApp

@Suite("kwt worktree creation")
struct KwtWorktreeClientTests {
    @Test("local creation delegates path and session creation to kwt")
    func localCreation() async throws {
        let recorder = CommandRecorder()
        let client = KwtWorktreeClient(
            localRunner: { shell, command in
                recorder.record(shell: shell, command: command)
                return (0, "")
            },
            localBinaryPath: "/Applications/Ghost Hub.app/Contents/Helpers/kwt",
            loginShellProvider: { "/bin/zsh" }
        )

        try await client.create(
            request: WorktreeCreateRequest(
                projectID: UUID(),
                branchName: "feature/native-tmux",
                createsBranch: true
            ),
            projectPath: "/code/ghost hub",
            on: .local
        )

        #expect(recorder.shell == "/bin/zsh")
        #expect(recorder.command?.hasPrefix(
            "ghosthub_kwt_path='/Applications/Ghost Hub.app/Contents/Helpers/kwt';"
        ) == true)
        #expect(recorder.command?.contains("cd -- '/code/ghost hub'") == true)
        #expect(
            recorder.command?.contains(
                "add --branch 'feature/native-tmux' --no-launch"
            ) == true
        )
        #expect(recorder.command?.contains("--layout") == false)
    }

    @Test("remote creation uses the configured SSH host and quotes input")
    func remoteCreation() async throws {
        let recorder = CommandRecorder()
        let ssh = SSHHostInfo(
            user: "wesm",
            hostname: "builder",
            port: 2222
        )
        let revision = String(repeating: "b", count: 40)
        let client = KwtWorktreeClient(
            remoteRunner: { host, command in
                recorder.record(host: host, command: command)
                return (0, "")
            },
            localBinaryPath: "/Applications/Ghosthub.app/Contents/Helpers/kwt",
            remoteBinaryRevision: revision
        )

        try await client.create(
            request: WorktreeCreateRequest(
                projectID: UUID(),
                branchName: "wesm's-fix",
                createsBranch: false
            ),
            projectPath: "/srv/project",
            on: .ssh(ssh)
        )

        #expect(recorder.host == ssh)
        #expect(recorder.command?.hasPrefix(
            "ghosthub_kwt_path=\"$HOME/.ghosthub/helpers/kwt/"
                + "\(revision)/kwt\";"
        ) == true)
        #expect(recorder.command?.contains("/Applications/Ghosthub.app") == false)
        #expect(recorder.command?.contains("add 'wesm'\\''s-fix' --no-launch") == true)
        #expect(recorder.command?.contains("--branch") == false)
    }

    @Test("a nonzero kwt exit is reported")
    func reportsFailure() async {
        let client = KwtWorktreeClient(
            localRunner: { _, _ in (23, "") }
        )

        await #expect(throws: KwtWorktreeError.self) {
            try await client.create(
                request: WorktreeCreateRequest(
                    projectID: UUID(),
                    branchName: "feature/failure",
                    createsBranch: true
                ),
                projectPath: "/code/project",
                on: .local
            )
        }
    }
}

private final class CommandRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var storedShell: String?
    private var storedCommand: String?
    private var storedHost: SSHHostInfo?

    var shell: String? { lock.withLock { storedShell } }
    var command: String? { lock.withLock { storedCommand } }
    var host: SSHHostInfo? { lock.withLock { storedHost } }

    func record(shell: String, command: String) {
        lock.withLock {
            storedShell = shell
            storedCommand = command
        }
    }

    func record(host: SSHHostInfo, command: String) {
        lock.withLock {
            storedHost = host
            storedCommand = command
        }
    }
}
