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
                createsBranch: false,
                source: "origin/wesm's-fix"
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
        #expect(
            recorder.command?.contains(
                "add --from 'origin/wesm'\\''s-fix' 'wesm'\\''s-fix' --no-launch"
            ) == true
        )
        #expect(recorder.command?.contains("--branch") == false)
    }

    @Test("Windows creation encodes paths and hostile branch names")
    func windowsRemoteCreation() async throws {
        let recorder = CommandRecorder()
        let projectPath = #"C:\code\ghost hub"#
        let branchName = #"x’;iex("attacker-command");#‘&|$()"#
        let revision = String(repeating: "e", count: 40)
        let managedPath = try #require(
            KwtBinaryLocator.windowsRemoteManagedRelativePath(
                revision: revision
            )
        )
        let ssh = SSHHostInfo(
            user: "wesm",
            hostname: "arm-builder",
            port: nil,
            platform: .windows
        )
        let client = KwtWorktreeClient(
            remoteRunner: { host, command in
                recorder.record(host: host, command: command)
                return (0, "")
            },
            remoteBinaryRevision: revision
        )

        try await client.create(
            request: WorktreeCreateRequest(
                projectID: UUID(),
                branchName: branchName,
                createsBranch: true
            ),
            projectPath: projectPath,
            on: .ssh(ssh)
        )

        #expect(recorder.host == ssh)
        #expect(recorder.command?.contains(
            powerShellEncodedArgument(managedPath)
        ) == true)
        #expect(recorder.command?.contains("Get-Command kwt.exe") == false)
        #expect(recorder.command?.contains(
            "Set-Location -LiteralPath "
                + powerShellEncodedArgument(projectPath)
        ) == true)
        #expect(recorder.command?.contains(
            ["add", "--branch", branchName, "--no-launch"]
                .map(powerShellEncodedArgument)
                .joined(separator: " ")
        ) == true)
        #expect(recorder.command?.contains(branchName) == false)
        #expect(recorder.command?.contains("iex(") == false)
        #expect(recorder.command?.contains("’") == false)
        #expect(recorder.command?.contains("‘") == false)
        #expect(recorder.command?.contains("command -v") == false)
    }

    @Test("branch listing decodes kwt candidates")
    func branchListing() async throws {
        let recorder = CommandRecorder()
        let client = KwtWorktreeClient(
            localRunner: { shell, command in
                recorder.record(shell: shell, command: command)
                return (
                    0,
                    """
                    GHOSTHUB_KWT_JSON
                    [
                      {
                        "name": "feature/remote",
                        "source": "origin/feature/remote",
                        "is_remote": true
                      }
                    ]
                    """
                )
            },
            localBinaryPath: "/Applications/Ghosthub.app/Contents/Helpers/kwt",
            loginShellProvider: { "/bin/zsh" }
        )

        let branches = try await client.branches(
            projectPath: "/code/ghosthub",
            on: .local
        )

        #expect(branches == [
            WorktreeBranchCandidate(
                name: "feature/remote",
                source: "origin/feature/remote",
                isRemote: true
            ),
        ])
        #expect(
            recorder.command?.contains(
                "exec \"$ghosthub_kwt_path\" branches --json"
            ) == true
        )
    }

    @Test("Windows branch listing uses the managed helper and decodes CRLF")
    func windowsBranchListing() async throws {
        let recorder = CommandRecorder()
        let revision = String(repeating: "f", count: 40)
        let managedPath = try #require(
            KwtBinaryLocator.windowsRemoteManagedRelativePath(
                revision: revision
            )
        )
        let projectPath = #"C:\code\ghost hub"#
        let ssh = SSHHostInfo(
            user: "wesm",
            hostname: "arm-builder",
            port: nil,
            platform: .windows
        )
        let client = KwtWorktreeClient(
            remoteRunner: { host, command in
                recorder.record(host: host, command: command)
                return (
                    0,
                    "PowerShell noise\r\nGHOSTHUB_KWT_JSON\r\n"
                        + """
                        [{"name":"topic","source":"origin/topic","is_remote":true}]
                        """
                        + "\r\n"
                )
            },
            remoteBinaryRevision: revision
        )

        let branches = try await client.branches(
            projectPath: projectPath,
            on: .ssh(ssh)
        )

        #expect(branches == [
            WorktreeBranchCandidate(
                name: "topic",
                source: "origin/topic",
                isRemote: true
            ),
        ])
        #expect(recorder.host == ssh)
        #expect(recorder.command?.contains(
            powerShellEncodedArgument(managedPath)
        ) == true)
        #expect(recorder.command?.contains(
            "Set-Location -LiteralPath "
                + powerShellEncodedArgument(projectPath)
        ) == true)
        #expect(recorder.command?.contains(
            ["branches", "--json"]
                .map(powerShellEncodedArgument)
                .joined(separator: " ")
        ) == true)
        #expect(recorder.command?.contains(
            "Write-Output "
                + powerShellEncodedArgument("GHOSTHUB_KWT_JSON")
        ) == true)
        #expect(recorder.command?.contains("cd --") == false)
    }

    @Test("local removal delegates the exact worktree path to kwt")
    func localRemoval() async throws {
        let recorder = CommandRecorder()
        let client = KwtWorktreeClient(
            localRunner: { shell, command in
                recorder.record(shell: shell, command: command)
                return (0, "")
            },
            localBinaryPath: "/Applications/Ghost Hub.app/Contents/Helpers/kwt",
            loginShellProvider: { "/bin/zsh" }
        )

        try await client.remove(
            worktreePath: "/worktrees/ghost hub/feature",
            projectPath: "/code/ghost hub",
            on: .local
        )

        #expect(recorder.command?.contains(
            "cd -- '/code/ghost hub'"
        ) == true)
        #expect(recorder.command?.contains(
            "remove '/worktrees/ghost hub/feature'"
        ) == true)
        #expect(recorder.command?.contains("--delete-branch") == false)
        #expect(recorder.command?.contains("--force") == false)
    }

    @Test("Windows removal uses the managed kwt helper")
    func windowsRemoteRemoval() async throws {
        let recorder = CommandRecorder()
        let revision = String(repeating: "e", count: 40)
        let ssh = SSHHostInfo(
            user: "wesm",
            hostname: "arm-builder",
            port: nil,
            platform: .windows
        )
        let client = KwtWorktreeClient(
            remoteRunner: { host, command in
                recorder.record(host: host, command: command)
                return (0, "")
            },
            remoteBinaryRevision: revision
        )

        try await client.remove(
            worktreePath: #"C:\worktrees\ghost hub\feature"#,
            projectPath: #"C:\code\ghost hub"#,
            on: .ssh(ssh)
        )

        #expect(recorder.host == ssh)
        #expect(recorder.command?.contains(
            ["remove", #"C:\worktrees\ghost hub\feature"#]
                .map(powerShellEncodedArgument)
                .joined(separator: " ")
        ) == true)
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
