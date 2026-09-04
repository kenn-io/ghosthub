import GhosthubTransport
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
            remoteRunner: { host, command, _ in
                recorder.record(host: host, command: command)
                return AccountCommandOutput(
                    status: 0,
                    stdout: "",
                    stderr: ""
                )
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
            remoteRunner: { host, command, _ in
                recorder.record(host: host, command: command)
                return AccountCommandOutput(
                    status: 0,
                    stdout: "",
                    stderr: ""
                )
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
            remoteRunner: { host, command, _ in
                recorder.record(host: host, command: command)
                return AccountCommandOutput(
                    status: 0,
                    stdout: "PowerShell noise\r\nGHOSTHUB_KWT_JSON\r\n"
                        + """
                        [{"name":"topic","source":"origin/topic","is_remote":true}]
                        """
                        + "\r\n",
                    stderr: ""
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
            generation: "0123456789abcdef0123456789abcdef",
            projectPath: "/code/ghost hub",
            on: .local
        )

        #expect(recorder.command?.contains(
            "cd -- '/code/ghost hub'"
        ) == true)
        #expect(recorder.command?.contains(
            "remove --if-generation "
                + "'0123456789abcdef0123456789abcdef' "
                + "'/worktrees/ghost hub/feature'"
        ) == true)
        #expect(recorder.command?.contains("--delete-branch") == false)
        #expect(recorder.command?.contains("--force") == false)
    }

    @Test("worktree changes preserve the exact kwt inspection contract")
    func worktreeChanges() async throws {
        let recorder = CommandRecorder()
        let generation = "0123456789abcdef0123456789abcdef"
        let client = KwtWorktreeClient(
            localRunner: { shell, command in
                recorder.record(shell: shell, command: command)
                return (
                    0,
                    """
                    shell startup noise
                    GHOSTHUB_KWT_JSON
                    {
                      "worktree": {
                        "repository": "github.com/acme/ghosthub",
                        "path": "/worktrees/ghost hub/feature",
                        "generation": "0123456789abcdef0123456789abcdef"
                      },
                      "changes": {
                        "state": "staged",
                        "summary": {
                          "modified": 2,
                          "added": 1,
                          "deleted": 3,
                          "untracked": 4,
                          "staged": 5,
                          "conflicts": 8
                        },
                        "files": [
                          {
                            "path": "notes.txt",
                            "worktree": "untracked"
                          },
                          {
                            "path": "Sources/New.swift",
                            "original_path": "Sources/Old.swift",
                            "index": "renamed",
                            "worktree": "modified"
                          }
                        ]
                      },
                      "observed_at": "2026-08-25T15:04:05.123456789Z"
                    }
                    """
                )
            },
            localBinaryPath: "/Applications/Ghost Hub.app/Contents/Helpers/kwt",
            loginShellProvider: { "/bin/zsh" }
        )

        let changes = try await client.changes(
            worktreePath: "/worktrees/ghost hub/feature",
            expectedRepository: "github.com/acme/ghosthub",
            expectedGeneration: generation,
            on: .local
        )

        #expect(changes.repository == "github.com/acme/ghosthub")
        #expect(changes.path == "/worktrees/ghost hub/feature")
        #expect(changes.generation == generation)
        #expect(changes.state == .staged)
        #expect(changes.summary == WorktreeChangeSummary(
            modified: 2,
            added: 1,
            deleted: 3,
            untracked: 4,
            staged: 5,
            conflicts: 8
        ))
        #expect(changes.files == [
            WorktreeFileChange(
                path: "Sources/New.swift",
                originalPath: "Sources/Old.swift",
                index: .renamed,
                worktree: .modified
            ),
            WorktreeFileChange(
                path: "notes.txt",
                originalPath: nil,
                index: nil,
                worktree: .untracked
            ),
        ])
        #expect(changes.observedAt == "2026-08-25T15:04:05.123456789Z")
        #expect(
            recorder.command?.contains(
                "exec \"$ghosthub_kwt_path\" changes "
                    + "'/worktrees/ghost hub/feature' "
                    + "--expected-repository 'github.com/acme/ghosthub' "
                    + "--expected-generation '\(generation)' --json"
            ) == true
        )
        #expect(recorder.command?.contains(" status ") == false)
    }

    @Test("force removal passes explicit force authority to kwt")
    func forceRemoval() async throws {
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
            generation: "0123456789abcdef0123456789abcdef",
            projectPath: "/code/ghost hub",
            force: true,
            on: .local
        )

        #expect(recorder.command?.contains(
            "remove --force --if-generation "
                + "'0123456789abcdef0123456789abcdef' "
                + "'/worktrees/ghost hub/feature'"
        ) == true)
    }

    @Test("worktree inspection preserves kwt's structured error")
    func worktreeChangesStructuredError() async {
        let client = KwtWorktreeClient(
            localRunner: { _, _ in
                (
                    1,
                    """
                    GHOSTHUB_KWT_JSON
                    {"error":{"code":"registration_changed","message":"worktree registration changed","retryable":true,"details":{"path":"/worktrees/removed"}}}
                    """
                )
            }
        )

        await #expect {
            try await client.changes(
                worktreePath: "/worktrees/removed",
                expectedRepository: "github.com/acme/project",
                expectedGeneration:
                "0123456789abcdef0123456789abcdef",
                on: .local
            )
        } throws: { error in
            error as? KwtWorktreeError == .changeInspectionFailed(
                host: "localhost",
                status: 1,
                code: "registration_changed",
                message: "worktree registration changed",
                retryable: true,
                details: ["path": .string("/worktrees/removed")]
            )
        }
    }

    @Test(
        "marked malformed transport failures remain retryable",
        arguments: [Int32(255), AccountCommandRunner.timedOutStatus]
    )
    func worktreeChangesMarkedTransportFailure(status: Int32) async {
        let client = KwtWorktreeClient(
            localRunner: { _, _ in
                (status, "GHOSTHUB_KWT_JSON\ntruncated")
            }
        )

        await #expect {
            try await client.changes(
                worktreePath: "/worktrees/remote",
                expectedRepository: "github.com/acme/project",
                expectedGeneration:
                "0123456789abcdef0123456789abcdef",
                on: .local
            )
        } throws: { error in
            error as? KwtWorktreeError == .changeInspectionFailed(
                host: "localhost",
                status: status,
                code: nil,
                message: nil,
                retryable: true,
                details: [:]
            )
        }
    }

    @Test("worktree inspection preserves a structured output-limit error")
    func worktreeChangesOutputLimitError() async {
        let client = KwtWorktreeClient(
            localRunner: { _, _ in
                (AccountCommandRunner.outputExceededStatus, "")
            }
        )

        await #expect {
            try await client.changes(
                worktreePath: "/worktrees/large",
                expectedRepository: "github.com/acme/project",
                expectedGeneration:
                "0123456789abcdef0123456789abcdef",
                on: .local
            )
        } throws: { error in
            error as? KwtWorktreeError == .changeInspectionFailed(
                host: "localhost",
                status: AccountCommandRunner.outputExceededStatus,
                code: "response_too_large",
                message: "kwt returned too many changed files to display.",
                retryable: false,
                details: [:]
            )
        }
    }

    @Test("transport failures remain retryable without a kwt envelope")
    func worktreeChangesTransportFailure() async {
        let client = KwtWorktreeClient(
            localRunner: { _, _ in (255, "") }
        )

        await #expect {
            try await client.changes(
                worktreePath: "/worktrees/remote",
                expectedRepository: "github.com/acme/project",
                expectedGeneration:
                "0123456789abcdef0123456789abcdef",
                on: .local
            )
        } throws: { error in
            error as? KwtWorktreeError == .changeInspectionFailed(
                host: "localhost",
                status: 255,
                code: nil,
                message: nil,
                retryable: true,
                details: [:]
            )
        }
    }

    @Test(
        "unstructured command failures wait for manual retry",
        arguments: [
            Int32(1), Int32(2), Int32(64), Int32(126), Int32(127),
            AccountCommandRunner.cancelledStatus,
        ]
    )
    func worktreeChangesUnstructuredFailureIsNotRetryable(
        status: Int32
    ) async {
        let client = KwtWorktreeClient(
            localRunner: { _, _ in (status, "") }
        )

        await #expect {
            try await client.changes(
                worktreePath: "/worktrees/missing",
                expectedRepository: "github.com/acme/project",
                expectedGeneration:
                "0123456789abcdef0123456789abcdef",
                on: .local
            )
        } throws: { error in
            error as? KwtWorktreeError == .changeInspectionFailed(
                host: "localhost",
                status: status,
                code: nil,
                message: nil,
                retryable: false,
                details: [:]
            )
        }
    }

    @Test("worktree inspection uses its shorter process deadline")
    func worktreeChangesUsesInspectionTimeout() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ghosthub-kwt-changes-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: directory) }
        let helper = directory.appendingPathComponent("kwt")
        try "#!/bin/sh\nexec /bin/sleep 10\n".write(
            to: helper,
            atomically: true,
            encoding: .utf8
        )
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: helper.path
        )
        let client = KwtWorktreeClient(
            processTimeout: 5,
            changeInspectionTimeout: 0.05,
            localBinaryPath: helper.path,
            loginShellProvider: { "/bin/sh" }
        )
        let started = Date()

        do {
            _ = try await client.changes(
                worktreePath: directory.path,
                expectedRepository: "github.com/acme/project",
                expectedGeneration:
                "0123456789abcdef0123456789abcdef",
                on: .local
            )
            Issue.record("expected changed-file inspection to time out")
        } catch {}

        #expect(Date().timeIntervalSince(started) < 3)
    }

    @Test("canceling inspection cancels its detached command task")
    func worktreeChangesCancellation() async {
        let probe = DetachedCancellationProbe()
        let client = KwtWorktreeClient(localRunner: { _, _ in
            probe.run()
        })
        let task = Task {
            try await client.changes(
                worktreePath: "/worktrees/slow",
                expectedRepository: "github.com/acme/project",
                expectedGeneration:
                "0123456789abcdef0123456789abcdef",
                on: .local
            )
        }

        await probe.waitUntilStarted()
        task.cancel()
        _ = await task.result
        await probe.waitUntilFinished()

        #expect(probe.observedCancellation)
    }

    @Test("successful inspection rejects mismatched worktree identity")
    func worktreeChangesRejectIdentityMismatch() async {
        let expectedRepository = "github.com/acme/ghosthub"
        let expectedPath = "/worktrees/ghosthub/feature"
        let expectedGeneration = "0123456789abcdef0123456789abcdef"
        let mismatches = [
            ("github.com/acme/other", expectedPath, expectedGeneration),
            (expectedRepository, "/worktrees/ghosthub/other", expectedGeneration),
            (expectedRepository, expectedPath, "fedcba9876543210fedcba9876543210"),
        ]

        for (repository, path, generation) in mismatches {
            let client = KwtWorktreeClient(
                localRunner: { _, _ in
                    (
                        0,
                        """
                        GHOSTHUB_KWT_JSON
                        {"worktree":{"repository":"\(repository)","path":"\(path)","generation":"\(
                            generation
                        )"},"changes":{"state":"clean","summary":{"modified":0,"added":0,"deleted":0,"untracked":0,"staged":0,"conflicts":0},"files":[]},"observed_at":"2026-08-25T15:04:05Z"}
                        """
                    )
                }
            )

            await #expect {
                try await client.changes(
                    worktreePath: expectedPath,
                    expectedRepository: expectedRepository,
                    expectedGeneration: expectedGeneration,
                    on: .local
                )
            } throws: { error in
                error as? KwtWorktreeError == .malformedChangeStatus(
                    host: "localhost"
                )
            }
        }
    }

    @Test("Windows inspection uses the managed helper and identity guards")
    func windowsRemoteChanges() async throws {
        let recorder = CommandRecorder()
        let revision = String(repeating: "f", count: 40)
        let generation = "0123456789abcdef0123456789abcdef"
        let path = #"C:\worktrees\ghost hub\feature"#
        let repository = "github.com/acme/ghosthub"
        let ssh = SSHHostInfo(
            user: "ci-user",
            hostname: "windows-builder.example",
            port: nil,
            platform: .windows
        )
        let client = KwtWorktreeClient(
            remoteRunner: { host, command, _ in
                recorder.record(host: host, command: command)
                return AccountCommandOutput(
                    status: 0,
                    stdout: """
                    GHOSTHUB_KWT_JSON\r
                    {"worktree":{"repository":"github.com/acme/ghosthub","path":"C:\\\\worktrees\\\\ghost hub\\\\feature","generation":"0123456789abcdef0123456789abcdef"},"changes":{"state":"clean","summary":{"modified":0,"added":0,"deleted":0,"untracked":0,"staged":0,"conflicts":0},"files":[]},"observed_at":"2026-08-25T15:04:05Z"}\r
                    """,
                    stderr: ""
                )
            },
            remoteBinaryRevision: revision
        )

        let changes = try await client.changes(
            worktreePath: path,
            expectedRepository: repository,
            expectedGeneration: generation,
            on: .ssh(ssh)
        )

        #expect(changes.state == .clean)
        #expect(recorder.host == ssh)
        #expect(recorder.command?.contains(
            [
                "changes", path,
                "--expected-repository", repository,
                "--expected-generation", generation,
                "--json",
            ]
            .map(powerShellEncodedArgument)
            .joined(separator: " ")
        ) == true)
        #expect(recorder.command?.contains("Set-Location") == false)
    }

    @Test("Windows removal uses the managed kwt helper")
    func windowsRemoteRemoval() async throws {
        let recorder = CommandRecorder()
        let reviewedRoute = LockedValue<String?>(nil)
        let revision = String(repeating: "e", count: 40)
        let ssh = SSHHostInfo(
            user: "wesm",
            hostname: "arm-builder",
            port: nil,
            platform: .windows
        )
        let client = KwtWorktreeClient(
            remoteRunner: { host, command, routeIdentity in
                recorder.record(host: host, command: command)
                reviewedRoute.withLock { $0 = routeIdentity }
                return AccountCommandOutput(
                    status: 0,
                    stdout: "",
                    stderr: ""
                )
            },
            remoteBinaryRevision: revision
        )

        try await client.remove(
            worktreePath: #"C:\worktrees\ghost hub\feature"#,
            generation: "0123456789abcdef0123456789abcdef",
            projectPath: #"C:\code\ghost hub"#,
            expectedRouteIdentity: "sha256:reviewed-route",
            on: CommandHost.ssh(ssh)
        )

        #expect(recorder.host == ssh)
        #expect(reviewedRoute.load() == "sha256:reviewed-route")
        #expect(recorder.command?.contains(
            [
                "remove",
                "--if-generation",
                "0123456789abcdef0123456789abcdef",
                #"C:\worktrees\ghost hub\feature"#,
            ]
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

private final class DetachedCancellationProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var started = false
    private var finished = false
    private var canceled = false

    var observedCancellation: Bool { lock.withLock { canceled } }

    func run() -> (status: Int32, stdout: String) {
        lock.withLock { started = true }
        let deadline = Date().addingTimeInterval(0.5)
        while Date() < deadline {
            if withUnsafeCurrentTask(body: { $0?.isCancelled == true }) {
                lock.withLock {
                    canceled = true
                    finished = true
                }
                return (AccountCommandRunner.cancelledStatus, "")
            }
            usleep(1_000)
        }
        lock.withLock { finished = true }
        return (0, "")
    }

    func waitUntilStarted() async {
        while !lock.withLock({ started }) {
            await Task.yield()
        }
    }

    func waitUntilFinished() async {
        while !lock.withLock({ finished }) {
            await Task.yield()
        }
    }
}
