import CryptoKit
import Foundation
import GhosthubTestSupport
import Testing
@testable import GhosthubApp

@Suite("Pinned kwt contract", .serialized)
struct PinnedKwtContractTests {
    enum RemovalGuard: CaseIterable, Sendable {
        case repositoryMismatch
        case liveProtectedSession
    }

    private func initializeRepository(_ repository: URL) throws {
        for arguments in [
            ["-C", repository.path, "init", "--quiet"],
            [
                "-C", repository.path, "config", "user.email",
                "contract@example.com",
            ],
            [
                "-C", repository.path, "config", "user.name",
                "Contract Test",
            ],
            [
                "-C", repository.path, "commit", "--allow-empty", "--quiet",
                "-m", "initial",
            ],
        ] {
            let result = AccountCommandRunner.runProcess(
                executable: "/usr/bin/git",
                arguments: arguments,
                timeout: 10
            )
            try #require(
                result.status == 0,
                Comment(rawValue: result.stderr)
            )
        }
    }

    @Test("exact helper round-trips project lifecycle through daemon inventory")
    func projectLifecycle() async throws {
        guard ProcessInfo.processInfo.environment[
            "GHOSTHUB_RUN_PINNED_KWT_CONTRACT_TESTS"
        ] == "1" else { return }
        let binary = try #require(
            ProcessInfo.processInfo.environment[
                "GHOSTHUB_KWT_CONTRACT_BINARY"
            ]
        )
        #expect(FileManager.default.isExecutableFile(atPath: binary))

        let fixture = try TempDirectoryFixture(shortPath: true)
        let kwtHome = try fixture.createSubdirectory("kwt-home")
        let repository = try fixture.createSubdirectory("widget")
        let movedRepository = fixture.childURL("widget-moved")
        let environment = ["KWT_HOME": kwtHome.path]
        let timeout: TimeInterval = 45
        let runKwtCommand: KwtProjectRegistryClient.LocalRunner = { command in
            AccountCommandRunner.runLoginShell(
                shell: "/bin/zsh",
                command: command,
                timeout: timeout,
                environmentOverrides: environment
            )
        }
        let runKwtInventory: KwtInventoryClient.LocalRunner = { shell, command in
            AccountCommandRunner.runLoginShell(
                shell: shell,
                command: command,
                timeout: timeout,
                environmentOverrides: environment
            )
        }
        defer {
            _ = AccountCommandRunner.runProcess(
                executable: binary,
                arguments: ["daemon", "stop"],
                timeout: 10,
                environmentOverrides: environment
            )
        }

        try initializeRepository(repository)

        let registry = KwtProjectRegistryClient(
            localRunner: runKwtCommand,
            localBinaryPath: binary
        )
        let inventoryClient = KwtInventoryClient(
            localRunner: runKwtInventory,
            localBinaryPath: binary,
            loginShellProvider: { "/bin/zsh" }
        )
        let registered = try await registry.register(
            projectPath: repository.path,
            on: .local
        )

        let initialInventory = try await inventoryClient.load(from: .local)
        let project = try #require(initialInventory.projects.first)
        let primaryRecord = project.worktrees.first { $0.isMain }
        let primary = try #require(primaryRecord)
        #expect(project.project.path == registered.path)
        #expect(primary.path == registered.path)
        #expect(!primary.repository.isEmpty)
        #expect(!primary.sessionName.isEmpty)

        try FileManager.default.moveItem(
            at: repository,
            to: movedRepository
        )
        let removed = try await registry.unregister(
            projectPath: project.project.path,
            expectedRepository: project.project.repository,
            on: .local
        )
        #expect(removed.path == project.project.path)
        #expect(FileManager.default.fileExists(atPath: movedRepository.path))

        let finalInventory = try await inventoryClient.load(from: .local)
        #expect(finalInventory.projects.isEmpty)
    }

    @Test(
        "project removal preserves checkout, linked worktree, and live session"
    )
    func projectRemovalPreservesResources() async throws {
        guard ProcessInfo.processInfo.environment[
            "GHOSTHUB_RUN_PINNED_KWT_CONTRACT_TESTS"
        ] == "1" else { return }
        let binary = try #require(
            ProcessInfo.processInfo.environment[
                "GHOSTHUB_KWT_CONTRACT_BINARY"
            ]
        )
        #expect(FileManager.default.isExecutableFile(atPath: binary))

        let fixture = try TempDirectoryFixture(shortPath: true)
        let kwtHome = try fixture.createSubdirectory("kwt-home")
        let repository = try fixture.createSubdirectory(
            "widget-\(UUID().uuidString.prefix(8).lowercased())"
        )
        let linkedWorktree = fixture.childURL("widget-linked")
        let repositorySentinel = repository.appendingPathComponent(
            "repository-sentinel.txt"
        )
        let linkedSentinel = linkedWorktree.appendingPathComponent(
            "linked-sentinel.txt"
        )
        let environment = ["KWT_HOME": kwtHome.path]
        let timeout: TimeInterval = 45
        let runKwtCommand: KwtProjectRegistryClient.LocalRunner = { command in
            AccountCommandRunner.runLoginShell(
                shell: "/bin/zsh",
                command: command,
                timeout: timeout,
                environmentOverrides: environment
            )
        }
        let runKwtInventory: KwtInventoryClient.LocalRunner = { shell, command in
            AccountCommandRunner.runLoginShell(
                shell: shell,
                command: command,
                timeout: timeout,
                environmentOverrides: environment
            )
        }
        defer {
            _ = AccountCommandRunner.runProcess(
                executable: binary,
                arguments: ["daemon", "stop"],
                timeout: 10,
                environmentOverrides: environment
            )
        }

        try initializeRepository(repository)
        try Data("repository sentinel".utf8).write(
            to: repositorySentinel
        )
        let addSentinel = AccountCommandRunner.runProcess(
            executable: "/usr/bin/git",
            arguments: [
                "-C", repository.path, "add", repositorySentinel.lastPathComponent,
            ],
            timeout: 10
        )
        try #require(
            addSentinel.status == 0,
            Comment(rawValue: addSentinel.stderr)
        )
        let commitSentinel = AccountCommandRunner.runProcess(
            executable: "/usr/bin/git",
            arguments: [
                "-C", repository.path, "commit", "--quiet", "-m", "sentinel",
            ],
            timeout: 10
        )
        try #require(
            commitSentinel.status == 0,
            Comment(rawValue: commitSentinel.stderr)
        )
        let addWorktree = AccountCommandRunner.runProcess(
            executable: "/usr/bin/git",
            arguments: [
                "-C", repository.path, "worktree", "add", "--quiet", "-b",
                "feature/preserved", linkedWorktree.path,
            ],
            timeout: 10
        )
        try #require(
            addWorktree.status == 0,
            Comment(rawValue: addWorktree.stderr)
        )
        try Data("linked sentinel".utf8).write(to: linkedSentinel)

        let registry = KwtProjectRegistryClient(
            localRunner: runKwtCommand,
            localBinaryPath: binary
        )
        let inventoryClient = KwtInventoryClient(
            localRunner: runKwtInventory,
            localBinaryPath: binary,
            loginShellProvider: { "/bin/zsh" }
        )
        _ = try await registry.register(
            projectPath: repository.path,
            on: .local
        )
        let registeredInventory = try await inventoryClient.load(from: .local)
        let registeredProject = try #require(
            registeredInventory.projects.first
        )
        let primary = try #require(
            registeredProject.worktrees.first { $0.isMain }
        )
        #expect(primary.tmuxSocketName == nil)
        let tmuxPath = try TmuxBinaryResolver().resolveTmuxPath().get()
        let startSession = AccountCommandRunner.runProcess(
            executable: tmuxPath,
            arguments: [
                "-f", "/dev/null", "-L", "default",
                "new-session", "-d", "-s", primary.sessionName,
            ],
            timeout: 10
        )
        try #require(
            startSession.status == 0,
            Comment(rawValue: startSession.stderr)
        )
        defer {
            _ = AccountCommandRunner.runProcess(
                executable: tmuxPath,
                arguments: [
                    "-L", "default", "kill-session",
                    "-t", "=\(primary.sessionName):",
                ],
                timeout: 10
            )
        }
        _ = try await registry.unregister(
            projectPath: registeredProject.project.path,
            expectedRepository: registeredProject.project.repository,
            on: .local
        )

        #expect(FileManager.default.fileExists(atPath: repository.path))
        #expect(FileManager.default.fileExists(
            atPath: repository.appendingPathComponent(".git").path
        ))
        #expect(try Data(contentsOf: repositorySentinel)
            == Data("repository sentinel".utf8))
        #expect(FileManager.default.fileExists(atPath: linkedWorktree.path))
        #expect(FileManager.default.fileExists(
            atPath: linkedWorktree.appendingPathComponent(".git").path
        ))
        #expect(try Data(contentsOf: linkedSentinel)
            == Data("linked sentinel".utf8))
        let liveSession = AccountCommandRunner.runProcess(
            executable: tmuxPath,
            arguments: [
                "-L", "default", "has-session",
                "-t", "=\(primary.sessionName):",
            ],
            timeout: 10
        )
        #expect(
            liveSession.status == 0,
            Comment(rawValue: liveSession.stderr)
        )

        let finalInventory = try await inventoryClient.load(from: .local)
        #expect(finalInventory.projects.isEmpty)
    }

    @Test(
        "guarded removal preserves rejected projects and resources",
        arguments: RemovalGuard.allCases
    )
    func guardedRemovalPreservesProject(
        guardCase: RemovalGuard
    ) async throws {
        guard ProcessInfo.processInfo.environment[
            "GHOSTHUB_RUN_PINNED_KWT_CONTRACT_TESTS"
        ] == "1" else { return }
        let binary = try #require(
            ProcessInfo.processInfo.environment[
                "GHOSTHUB_KWT_CONTRACT_BINARY"
            ]
        )
        #expect(FileManager.default.isExecutableFile(atPath: binary))

        let fixture = try TempDirectoryFixture(shortPath: true)
        let kwtHome = try fixture.createSubdirectory("kwt-home")
        let repository = try fixture.createSubdirectory(
            "guarded-\(UUID().uuidString.prefix(8).lowercased())"
        )
        let sentinel = repository.appendingPathComponent("sentinel.txt")
        let environment = ["KWT_HOME": kwtHome.path]
        let timeout: TimeInterval = 45
        let runKwtCommand: KwtProjectRegistryClient.LocalRunner = { command in
            AccountCommandRunner.runLoginShell(
                shell: "/bin/zsh",
                command: command,
                timeout: timeout,
                environmentOverrides: environment
            )
        }
        let runKwtInventory: KwtInventoryClient.LocalRunner = { shell, command in
            AccountCommandRunner.runLoginShell(
                shell: shell,
                command: command,
                timeout: timeout,
                environmentOverrides: environment
            )
        }
        defer {
            _ = AccountCommandRunner.runProcess(
                executable: binary,
                arguments: ["daemon", "stop"],
                timeout: 10,
                environmentOverrides: environment
            )
        }

        try initializeRepository(repository)
        let addRemote = AccountCommandRunner.runProcess(
            executable: "/usr/bin/git",
            arguments: [
                "-C", repository.path, "remote", "add", "origin",
                "git@github.com:acme/\(repository.lastPathComponent).git",
            ],
            timeout: 10
        )
        try #require(
            addRemote.status == 0,
            Comment(rawValue: addRemote.stderr)
        )
        try Data("sentinel".utf8).write(to: sentinel)
        let registry = KwtProjectRegistryClient(
            localRunner: runKwtCommand,
            localBinaryPath: binary
        )
        let inventoryClient = KwtInventoryClient(
            localRunner: runKwtInventory,
            localBinaryPath: binary,
            loginShellProvider: { "/bin/zsh" }
        )
        let registered = try await registry.register(
            projectPath: repository.path,
            on: .local
        )
        let initialInventory = try await inventoryClient.load(from: .local)
        let initialProject = try #require(initialInventory.projects.first)
        let primary = try #require(
            initialProject.worktrees.first { $0.isMain }
        )

        var expectedRepository = registered.repository
        var protectedSession: (
            tmux: String,
            socket: String,
            session: String
        )?
        defer {
            if let protectedSession {
                _ = AccountCommandRunner.runProcess(
                    executable: protectedSession.tmux,
                    arguments: [
                        "-L", protectedSession.socket,
                        "kill-session", "-t",
                        "=\(protectedSession.session):",
                    ],
                    timeout: 10
                )
            }
        }
        if guardCase == .repositoryMismatch {
            expectedRepository = "github.com/acme/replacement"
        } else {
            let generation = try #require(primary.generation)
            let session = "guarded-pr-\(UUID().uuidString.prefix(8))"
            let pullRequestID = "github:\(registered.repository)#1"
            let provenance: [String: Any] = [
                "version": 1,
                "imports": [
                    pullRequestID: [
                        "pull_request_id": pullRequestID,
                        "provider": "github",
                        "repository": registered.repository,
                        "number": 1,
                        "url": "https://example.invalid/pull/1",
                        "head_sha": String(repeating: "a", count: 40),
                        "source_repository": registered.repository,
                        "source_branch": "feature/guarded-removal",
                        "project": [
                            "identity": registered.repository,
                            "name": registered.name,
                            "path": registered.path,
                        ],
                        "workspace": [
                            "id": "guarded-pr-1",
                            "repository": registered.repository,
                            "branch": primary.branch,
                            "path": primary.path,
                            "generation": generation,
                            "state": "active",
                            "session_name": session,
                        ],
                    ],
                ],
            ]
            let provenanceData = try JSONSerialization.data(
                withJSONObject: provenance,
                options: [.prettyPrinted, .sortedKeys]
            )
            try provenanceData.write(
                to: kwtHome.appendingPathComponent("pull-requests.json")
            )
            let socketDigest = SHA256.hash(
                data: Data("\(session)\0\(primary.path)".utf8)
            )
            let socket = "kwt-pr-" + socketDigest.prefix(8).map {
                String(format: "%02x", $0)
            }.joined()
            let tmux = try TmuxBinaryResolver().resolveTmuxPath().get()
            let startSession = AccountCommandRunner.runProcess(
                executable: tmux,
                arguments: [
                    "-f", "/dev/null", "-L", socket,
                    "new-session", "-d", "-s", session,
                ],
                timeout: 10
            )
            try #require(
                startSession.status == 0,
                Comment(rawValue: startSession.stderr)
            )
            protectedSession = (tmux, socket, session)
        }

        await #expect {
            try await registry.unregister(
                projectPath: registered.path,
                expectedRepository: expectedRepository,
                on: .local
            )
        } throws: { error in
            guard case let .commandFailed(
                _, status, code, _, retryable
            ) = error as? KwtProjectCommandError else { return false }
            switch guardCase {
            case .repositoryMismatch:
                return status == 1
                    && code == "registration_changed"
                    && retryable
            case .liveProtectedSession:
                return status == 1
                    && code == "protected_session_live"
                    && !retryable
            }
        }

        let retainedInventory = try await inventoryClient.load(from: .local)
        #expect(retainedInventory.projects.count == 1)
        #expect(
            retainedInventory.projects.first?.project.repository
                == registered.repository
        )
        #expect(
            retainedInventory.projects.first?.project.path == registered.path
        )
        #expect(try Data(contentsOf: sentinel) == Data("sentinel".utf8))
        if let protectedSession {
            let liveSession = AccountCommandRunner.runProcess(
                executable: protectedSession.tmux,
                arguments: [
                    "-L", protectedSession.socket,
                    "has-session", "-t", "=\(protectedSession.session):",
                ],
                timeout: 10
            )
            #expect(
                liveSession.status == 0,
                Comment(rawValue: liveSession.stderr)
            )
        }
    }
}
