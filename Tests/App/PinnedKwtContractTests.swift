import CryptoKit
import Foundation
import GhosthubTestSupport
import GhosthubTransport
import Testing
@testable import GhosthubApp

@Suite("Pinned kwt contract", .serialized)
struct PinnedKwtContractTests {
    enum RemovalGuard: CaseIterable, Sendable {
        case repositoryMismatch
        case liveProtectedSession
        case incompleteLegacyProvenance
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

    @Test("exact helper resolves the SSH route snapshot consumed by Ghosthub")
    func sshRouteSnapshot() throws {
        guard ProcessInfo.processInfo.environment[
            "GHOSTHUB_RUN_PINNED_KWT_CONTRACT_TESTS"
        ] == "1" else { return }
        let binary = try #require(
            ProcessInfo.processInfo.environment[
                "GHOSTHUB_KWT_CONTRACT_BINARY"
            ]
        )
        let fixture = try TempDirectoryFixture(shortPath: true)
        let kwtHome = try fixture.createSubdirectory("kwt-home")
        let home = try fixture.createSubdirectory("account-home")
        let sshDirectory = try fixture.createSubdirectory("account-home/.ssh")
        let identity = fixture.childURL("identity key")
        FileManager.default.createFile(
            atPath: identity.path,
            contents: Data()
        )
        let config = sshDirectory.appendingPathComponent("config")
        try """
        Host relay-v6
            HostName 2001:db8::42
            User jump
            Port 2201
            StrictHostKeyChecking yes

        Host tailscale-build
            HostName 100.64.0.8
            User operator
            Port 2222
            ProxyJump relay-v6
            HostKeyAlias build-key.example.test
            StrictHostKeyChecking accept-new
            IdentityFile "\(identity.path)"
        """.write(to: config, atomically: true, encoding: .utf8)
        let binaryDirectory = try fixture.createSubdirectory("bin")
        let sshWrapper = binaryDirectory.appendingPathComponent("ssh")
        try """
        #!/bin/sh
        exec /usr/bin/ssh -F \(shellQuotedCommandArgument(config.path)) "$@"
        """.write(to: sshWrapper, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o700],
            ofItemAtPath: sshWrapper.path
        )
        let environment = [
            "HOME": home.path,
            "KWT_HOME": kwtHome.path,
            "PATH": binaryDirectory.path + ":"
                + (ProcessInfo.processInfo.environment["PATH"] ?? ""),
        ]
        defer {
            _ = AccountCommandRunner.runProcess(
                executable: binary,
                arguments: ["daemon", "stop"],
                timeout: 10,
                environmentOverrides: environment
            )
        }
        let client = KwtSSHRouteClient(
            runner: { executable, arguments, timeout in
                let output = AccountCommandRunner.runProcess(
                    executable: executable,
                    arguments: arguments,
                    timeout: timeout,
                    environmentOverrides: environment
                )
                #expect(
                    output.status == 0,
                    Comment(rawValue: output.stderr)
                )
                return output
            },
            binaryPath: binary
        )

        let snapshot = try client.resolve(SSHHostInfo(
            user: nil,
            hostname: "tailscale-build",
            port: nil
        ))

        #expect(snapshot.logicalTarget.hostname == "tailscale-build")
        #expect(snapshot.targets.map(\.logicalTarget.hostname) == [
            "relay-v6", "tailscale-build",
        ])
        let targets = try #require(
            snapshot.targets.count == 2 ? snapshot.targets : nil
        )
        #expect(targets[0].effectiveTarget == KwtSSHTarget(
            hostname: "2001:db8::42",
            user: "jump",
            port: 2201
        ))
        #expect(targets[1].effectiveTarget == KwtSSHTarget(
            hostname: "100.64.0.8",
            user: "operator",
            port: 2222
        ))
        #expect(targets[1].hostKeyAlias == "build-key.example.test")
        #expect(targets[1].strictHostKeyChecking == "accept-new")
        #expect(targets[1].projection.privateConfig.contains(
            "IdentityFile \"\(identity.path)\""
        ))
        #expect(!snapshot.routeIdentity.isEmpty)
        #expect(snapshot.projectionPolicy ==
            KwtSSHRouteClient.supportedProjectionPolicy)
    }

    @Test("exact helper rejects a stale SSH lease through its operation stream")
    func staleSSHLease() async throws {
        guard ProcessInfo.processInfo.environment[
            "GHOSTHUB_RUN_PINNED_KWT_CONTRACT_TESTS"
        ] == "1" else { return }
        let binary = try #require(
            ProcessInfo.processInfo.environment[
                "GHOSTHUB_KWT_CONTRACT_BINARY"
            ]
        )
        let fixture = try TempDirectoryFixture(shortPath: true)
        let kwtHome = try fixture.createSubdirectory("kwt-home")
        let home = try fixture.createSubdirectory("account-home")
        let sshDirectory = try fixture.createSubdirectory("account-home/.ssh")
        let config = sshDirectory.appendingPathComponent("config")
        try """
        Host changing-build
            HostName 100.64.0.8
            User operator
            StrictHostKeyChecking yes
        """.write(to: config, atomically: true, encoding: .utf8)
        let binaryDirectory = try fixture.createSubdirectory("bin")
        let sshWrapper = binaryDirectory.appendingPathComponent("ssh")
        try """
        #!/bin/sh
        exec /usr/bin/ssh -F \(shellQuotedCommandArgument(config.path)) "$@"
        """.write(to: sshWrapper, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o700],
            ofItemAtPath: sshWrapper.path
        )
        let environment = ProcessInfo.processInfo.environment.merging([
            "HOME": home.path,
            "KWT_HOME": kwtHome.path,
            "PATH": binaryDirectory.path + ":"
                + (ProcessInfo.processInfo.environment["PATH"] ?? ""),
        ]) { _, fixture in fixture }
        defer {
            _ = AccountCommandRunner.runProcess(
                executable: binary,
                arguments: ["daemon", "stop"],
                timeout: 10,
                environmentOverrides: environment
            )
        }
        let routeClient = KwtSSHRouteClient(
            runner: { executable, arguments, timeout in
                AccountCommandRunner.runProcess(
                    executable: executable,
                    arguments: arguments,
                    timeout: timeout,
                    environmentOverrides: environment
                )
            },
            binaryPath: binary
        )
        let host = SSHHostInfo(
            user: nil,
            hostname: "changing-build",
            port: nil
        )
        let snapshot = try routeClient.resolve(host)
        try """
        Host changing-build
            HostName 100.64.0.9
            User operator
            StrictHostKeyChecking yes
        """.write(to: config, atomically: true, encoding: .utf8)

        await #expect {
            _ = try await KwtSSHLeaseClient(
                binaryPath: binary,
                environment: environment
            ).acquire(
                route: snapshot,
                prompt: { _ in
                    Issue.record("A stale route must fail before prompting")
                    return ""
                }
            )
        } throws: { error in
            error as? KwtSSHLeaseError == .routeChanged
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
        #expect(!project.project.registrationFingerprint.isEmpty)
        #expect(project.project.path == registered.path)
        #expect(primary.path == registered.path)
        #expect(!primary.repository.isEmpty)
        #expect(!primary.sessionName.isEmpty)
        #expect(primary.sessionName.hasPrefix("kwt-wt-widget-"))

        try FileManager.default.moveItem(
            at: repository,
            to: movedRepository
        )
        let removed = try await registry.unregister(
            projectPath: project.project.path,
            expectedRepository: project.project.repository,
            expectedRegistration:
            project.project.registrationFingerprint,
            expectedRouteIdentity: nil,
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
        let tmuxServer = try TestTmuxServer(
            tmuxPath: tmuxPath,
            socket: .productContract(name: "default")
        )
        defer { tmuxServer.stop() }
        try tmuxServer.createSession(primary.sessionName)
        _ = try await registry.unregister(
            projectPath: registeredProject.project.path,
            expectedRepository: registeredProject.project.repository,
            expectedRegistration:
            registeredProject.project.registrationFingerprint,
            expectedRouteIdentity: nil,
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
        var preservedProvenance: (url: URL, data: Data)?
        var protectedSession: (
            server: TestTmuxServer,
            tmux: String,
            session: String
        )?
        defer { protectedSession?.server.stop() }
        if guardCase == .repositoryMismatch {
            expectedRepository = "github.com/acme/replacement"
        } else {
            let generation = try #require(primary.generation)
            let session = "guarded-pr-\(UUID().uuidString.prefix(8))"
            let pullRequestID = "github:\(registered.repository)#1"
            var workspace: [String: Any] = [
                "id": "guarded-pr-1",
                "repository": registered.repository,
                "branch": primary.branch,
                "path": primary.path,
                "state": "active",
                "session_name": session,
            ]
            if guardCase == .liveProtectedSession {
                workspace["generation"] = generation
            }
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
                        "workspace": workspace,
                    ],
                ],
            ]
            let provenanceData = try JSONSerialization.data(
                withJSONObject: provenance,
                options: [.prettyPrinted, .sortedKeys]
            )
            let provenanceURL = kwtHome.appendingPathComponent(
                "pull-requests.json"
            )
            try provenanceData.write(to: provenanceURL)
            preservedProvenance = (provenanceURL, provenanceData)
            if guardCase == .liveProtectedSession {
                let socketDigest = SHA256.hash(
                    data: Data("\(session)\0\(primary.path)".utf8)
                )
                let socket = "kwt-pr-" + socketDigest.prefix(8).map {
                    String(format: "%02x", $0)
                }.joined()
                let tmux = try TmuxBinaryResolver().resolveTmuxPath().get()
                let server = try TestTmuxServer(
                    tmuxPath: tmux,
                    socket: .productContract(name: socket)
                )
                try server.createSession(session)
                protectedSession = (server, tmux, session)
            }
        }

        await #expect {
            try await registry.unregister(
                projectPath: registered.path,
                expectedRepository: expectedRepository,
                expectedRegistration:
                initialProject.project.registrationFingerprint,
                expectedRouteIdentity: nil,
                on: .local
            )
        } throws: { error in
            guard case let .commandFailed(
                _, status, code, _, retryable, _
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
            case .incompleteLegacyProvenance:
                return status == 1
                    && code == "protected_endpoint_inventory_incomplete"
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
        if let preservedProvenance {
            #expect(
                try Data(contentsOf: preservedProvenance.url)
                    == preservedProvenance.data
            )
        }
        if let protectedSession {
            let liveSession = AccountCommandRunner.runProcess(
                executable: protectedSession.tmux,
                arguments: [
                    "-L", protectedSession.server.socketName,
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

    @Test("registration mutation invalidates an observed removal tuple")
    func registrationMutationInvalidatesRemoval() async throws {
        guard ProcessInfo.processInfo.environment[
            "GHOSTHUB_RUN_PINNED_KWT_CONTRACT_TESTS"
        ] == "1" else { return }
        let binary = try #require(
            ProcessInfo.processInfo.environment[
                "GHOSTHUB_KWT_CONTRACT_BINARY"
            ]
        )
        let fixture = try TempDirectoryFixture(shortPath: true)
        let kwtHome = try fixture.createSubdirectory("kwt-home")
        let repository = try fixture.createSubdirectory("changed-widget")
        let environment = ["KWT_HOME": kwtHome.path]
        let timeout: TimeInterval = 45
        let registry = KwtProjectRegistryClient(
            localRunner: { command in
                AccountCommandRunner.runLoginShell(
                    shell: "/bin/zsh",
                    command: command,
                    timeout: timeout,
                    environmentOverrides: environment
                )
            },
            localBinaryPath: binary
        )
        let inventoryClient = KwtInventoryClient(
            localRunner: { shell, command in
                AccountCommandRunner.runLoginShell(
                    shell: shell,
                    command: command,
                    timeout: timeout,
                    environmentOverrides: environment
                )
            },
            localBinaryPath: binary,
            loginShellProvider: { "/bin/zsh" }
        )
        defer {
            _ = AccountCommandRunner.runProcess(
                executable: binary,
                arguments: ["daemon", "stop"],
                timeout: 10,
                environmentOverrides: environment
            )
        }

        try initializeRepository(repository)
        _ = try await registry.register(
            projectPath: repository.path,
            on: .local
        )
        let observed = try #require(
            try await inventoryClient.load(from: .local).projects.first
        ).project
        try await Task.sleep(for: .seconds(1))
        _ = try await registry.register(
            projectPath: repository.path,
            on: .local
        )
        let changed = try #require(
            try await inventoryClient.load(from: .local).projects.first
        ).project
        #expect(changed.registrationFingerprint
            != observed.registrationFingerprint)

        await #expect {
            try await registry.unregister(
                projectPath: observed.path,
                expectedRepository: observed.repository,
                expectedRegistration: observed.registrationFingerprint,
                expectedRouteIdentity: nil,
                on: .local
            )
        } throws: { error in
            guard case let .commandFailed(
                _, status, code, _, retryable, _
            ) = error as? KwtProjectCommandError else { return false }
            return status == 1
                && code == "registration_changed"
                && retryable
        }

        let retained = try await inventoryClient.load(from: .local)
        #expect(retained.projects.count == 1)
        #expect(
            retained.projects.first?.project.registrationFingerprint
                == changed.registrationFingerprint
        )
    }
}
