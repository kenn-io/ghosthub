import Foundation
import GhosthubTmux
import GhosthubTransport
import GhosthubWorkspace
import Testing
@testable import GhosthubApp

@Suite("kwt project registry")
struct KwtProjectRegistryClientTests {
    @Test(
        "registration rejects relative paths before invoking kwt",
        arguments: [
            CommandHost.local,
            CommandHost.ssh(SSHHostInfo(
                user: "wesm",
                hostname: "spark",
                port: nil
            )),
        ]
    )
    func rejectsRelativeProjectPath(host: CommandHost) async {
        let invoked = LockedValue(false)
        let client = KwtProjectRegistryClient(
            localRunner: { _ in
                invoked.store(true)
                return (0, "")
            },
            remoteRunner: { _, _, _ in
                invoked.store(true)
                return AccountCommandOutput(
                    status: 0,
                    stdout: "",
                    stderr: ""
                )
            },
            localBinaryPath:
            "/Applications/Ghosthub.app/Contents/Helpers/kwt",
            remoteBinaryRevision: String(repeating: "a", count: 40)
        )

        await #expect {
            try await client.register(
                projectPath: "relative/repository",
                on: host
            )
        } throws: { error in
            error as? KwtProjectCommandError == .invalidProjectPath
        }
        #expect(!invoked.load())
    }

    @Test("local registration uses Ghosthub's exact kwt helper")
    func registersLocalProject() async throws {
        let invocation = LockedValue<String?>(nil)
        let client = KwtProjectRegistryClient(
            localRunner: { command in
                invocation.store(command)
                return (
                    0,
                    """
                    GHOSTHUB_KWT_PROJECT_JSON
                    {"status":"registered","project":{"repository":"github.com/acme/widget","name":"widget","path":"/code/widget"}}
                    """
                )
            },
            localBinaryPath: "/Applications/Ghosthub.app/Contents/Helpers/kwt"
        )

        let project = try await client.register(
            projectPath: "/code/widget",
            on: .local
        )

        #expect(invocation.load()?.hasPrefix(
            "ghosthub_kwt_path="
                + "'/Applications/Ghosthub.app/Contents/Helpers/kwt'; "
        ) == true)
        #expect(project.name == "widget")
    }

    @Test(
        "remote registration uses the managed helper and canonical response",
        arguments: [false, true]
    )
    func registersRemoteProject(browsed: Bool) async throws {
        let revision = String(repeating: "a", count: 40)
        let ssh = SSHHostInfo(
            user: "wesm",
            hostname: "spark",
            port: 2222
        )
        let invocation = LockedValue<(SSHHostInfo, String)?>(nil)
        let client = KwtProjectRegistryClient(
            remoteRunner: { host, _, command in
                invocation.store((host, command))
                return AccountCommandOutput(
                    status: 0,
                    stdout: """
                    banner
                    GHOSTHUB_KWT_PROJECT_JSON
                    {"status":"registered","project":{"repository":"github.com/acme/widget","name":"widget","path":"/srv/widget","last_touched":"2026-07-27T11:16:16Z"}}
                    """,
                    stderr: ""
                )
            },
            remoteBinaryRevision: revision
        )

        let project = try await client.register(
            projectPath: "/srv/wesm's widget",
            on: .ssh(ssh),
            expectedRouteIdentity: browsed ? "injected-command-transport" : nil
        )

        #expect(invocation.load()?.0 == ssh)
        let command = try #require(invocation.load()?.1)
        #expect(command.hasPrefix(
            "ghosthub_kwt_path=\"$HOME/.ghosthub/helpers/kwt/"
                + "\(revision)/kwt\";"
        ))
        #expect(command.contains(
            "projects add '/srv/wesm'\\''s widget' --json"
        ))
        #expect(project.repository == "github.com/acme/widget")
        #expect(project.name == "widget")
        #expect(project.path == "/srv/widget")
    }

    @Test("registration preserves kwt's structured error")
    func preservesStructuredError() async {
        let client = KwtProjectRegistryClient(
            remoteRunner: { _, _, _ in
                AccountCommandOutput(
                    status: 2,
                    stdout: """
                    GHOSTHUB_KWT_PROJECT_JSON
                    {"error":{"code":"invalid_repository","message":"/missing is not an accessible Git repository","retryable":false,"details":{"path":"/missing","operation":"add"}}}
                    """,
                    stderr: ""
                )
            },
            remoteBinaryRevision: String(repeating: "b", count: 40)
        )

        await #expect {
            try await client.register(
                projectPath: "/missing",
                on: SSHHostInfo(
                    user: nil,
                    hostname: "spark",
                    port: nil
                )
            )
        } throws: { error in
            error as? KwtProjectCommandError
                == .commandFailed(
                    host: "spark",
                    status: 2,
                    code: "invalid_repository",
                    message:
                    "/missing is not an accessible Git repository",
                    retryable: false,
                    details: [
                        "operation": .string("add"),
                        "path": .string("/missing"),
                    ]
                )
        }
    }

    @Test("remote removal uses the managed helper and canonical response")
    func removesRemoteProject() async throws {
        let revision = String(repeating: "c", count: 40)
        let ssh = SSHHostInfo(
            user: "wesm",
            hostname: "spark",
            port: 2222
        )
        let invocation = LockedValue<String?>(nil)
        let client = KwtProjectRegistryClient(
            remoteRunner: { _, _, command in
                invocation.store(command)
                return AccountCommandOutput(
                    status: 0,
                    stdout: """
                    GHOSTHUB_KWT_PROJECT_JSON
                    {"status":"unregistered","project":{"repository":"github.com/acme/widget","name":"widget","path":"/srv/wesm's widget "}}
                    """,
                    stderr: ""
                )
            },
            remoteBinaryRevision: revision
        )

        let project = try await client.unregister(
            projectPath: "/srv/wesm's widget ",
            expectedRepository: "github.com/acme/widget",
            expectedRegistration: "opaque-registration",
            expectedRouteIdentity: "injected-command-transport",
            on: .ssh(ssh)
        )

        let command = try #require(invocation.load())
        #expect(command.contains(
            "projects remove '/srv/wesm'\\''s widget ' "
                + "--expected-repository 'github.com/acme/widget' "
                + "--expected-registration 'opaque-registration' --json"
        ))
        #expect(project.name == "widget")
        #expect(project.path == "/srv/wesm's widget ")
    }

    @Test("remote removal rejects a changed reviewed route")
    func remoteRemovalRejectsRouteDrift() async {
        let invocations = LockedValue(0)
        let ssh = SSHHostInfo(
            user: "builder",
            hostname: "spark",
            port: 2222
        )
        let client = KwtProjectRegistryClient(
            remoteRunner: { _, _, _ in
                invocations.withLock { $0 += 1 }
                return AccountCommandOutput(
                    status: 0,
                    stdout: "",
                    stderr: ""
                )
            }
        )

        await #expect {
            try await client.unregister(
                projectPath: "/srv/widget",
                expectedRepository: "github.com/acme/widget",
                expectedRegistration: "opaque-registration",
                expectedRouteIdentity: "sha256:reviewed-route",
                on: .ssh(ssh)
            )
        } throws: { error in
            error as? KwtProjectCommandError == .routeChanged(
                host: ssh.displayName
            )
        }
        #expect(invocations.load() == 0)
    }

    @Test("browsed project registration rejects route drift before mutation")
    func browsedRegistrationRoute() async {
        let invocations = LockedValue(0)
        let ssh = SSHHostInfo(user: "builder", hostname: "alias", port: nil)
        let client = KwtProjectRegistryClient(
            remoteRunner: { _, _, _ in
                invocations.withLock { $0 += 1 }
                return AccountCommandOutput(status: 1, stdout: "", stderr: "")
            },
            commandLease: KwtSSHCommandLease { _ in
                KwtSSHConnection(arguments: [], routeIdentity: "new-route", generation: 2)
            }
        )
        await #expect {
            try await client.register(
                projectPath: "/srv/widget", on: .ssh(ssh), expectedRouteIdentity: "observed-route"
            )
        } throws: { error in
            error as? KwtProjectCommandError == .routeChanged(host: ssh.displayName)
        }
        #expect(invocations.load() == 0)
    }

    @Test("removal preserves the authoritative project path exactly")
    func removalPreservesTrailingWhitespace() async throws {
        let invocation = LockedValue<String?>(nil)
        let client = KwtProjectRegistryClient(
            localRunner: { command in
                invocation.store(command)
                return (
                    0,
                    """
                    GHOSTHUB_KWT_PROJECT_JSON
                    {"status":"unregistered","project":{"repository":"github.com/acme/widget","name":"widget","path":"/srv/widget "}}
                    """
                )
            },
            localBinaryPath: "/Applications/Ghosthub.app/Contents/Helpers/kwt"
        )

        _ = try await client.unregister(
            projectPath: "/srv/widget ",
            expectedRepository: "github.com/acme/widget",
            expectedRegistration: "opaque registration ",
            expectedRouteIdentity: nil,
            on: .local
        )

        #expect(invocation.load()?.contains(
            "projects remove '/srv/widget ' "
                + "--expected-repository 'github.com/acme/widget' "
                + "--expected-registration 'opaque registration ' --json"
        ) == true)
    }

    @Test("removal preserves a stale-registration error without retrying")
    func removalPreservesRegistrationChangedError() async {
        let invocations = LockedValue(0)
        let client = KwtProjectRegistryClient(
            localRunner: { _ in
                invocations.withLock { $0 += 1 }
                return (
                    1,
                    """
                    GHOSTHUB_KWT_PROJECT_JSON
                    {"error":{"code":"registration_changed","message":"project registration changed","retryable":true,"details":{"path":"/srv/widget"}}}
                    """
                )
            },
            localBinaryPath: "/Applications/Ghosthub.app/kwt"
        )

        await #expect {
            try await client.unregister(
                projectPath: "/srv/widget",
                expectedRepository: "github.com/acme/widget",
                expectedRegistration: "stale-registration",
                expectedRouteIdentity: nil,
                on: .local
            )
        } throws: { error in
            error as? KwtProjectCommandError == .commandFailed(
                host: "this Mac",
                status: 1,
                code: "registration_changed",
                message: "project registration changed",
                retryable: true,
                details: ["path": .string("/srv/widget")]
            )
        }
        #expect(invocations.load() == 1)
    }

    @Test("remote project commands invalidate a dead pooled connection")
    func remoteProjectCommandInvalidatesDeadConnection() async {
        let invalidations = LockedValue(0)
        let host = SSHHostInfo(
            user: "dev",
            hostname: "builder.example.test",
            port: nil
        )
        let client = KwtProjectRegistryClient(
            remoteRunner: { _, _, _ in
                AccountCommandOutput(
                    status: 255,
                    stdout: "",
                    stderr:
                    "Control socket connect(/tmp/dead.sock): No such file or directory"
                )
            },
            commandLease: KwtSSHCommandLease { _ in
                KwtSSHConnection(
                    arguments: ["-S", "/tmp/dead.sock"],
                    routeIdentity: "reviewed-route",
                    generation: 3,
                    invalidate: {
                        invalidations.withLock { $0 += 1 }
                    }
                )
            }
        )

        await #expect {
            try await client.register(projectPath: "/srv/widget", on: host)
        } throws: { error in
            guard case let KwtProjectCommandError.commandFailed(
                _, status, _, _, _, _
            ) = error else { return false }
            return status == 255
        }
        #expect(invalidations.load() == 1)
    }

    @Test(
        "registration expands ~ and ~/ paths against the target host's HOME",
        arguments: [
            ("~", "\"${HOME:?}\""),
            ("~/code/widget", "\"${HOME:?}\"'/code/widget'"),
            (
                "~/code/alice's $repo $(id)",
                "\"${HOME:?}\"'/code/alice'\\''s $repo $(id)'"
            ),
        ]
    )
    func expandsTildeInRegistrationCommand(
        input: String,
        expectedArgument: String
    ) async throws {
        let localCommand = LockedValue<String?>(nil)
        let remoteCommand = LockedValue<String?>(nil)
        let client = KwtProjectRegistryClient(
            localRunner: { command in
                localCommand.store(command)
                return (
                    0,
                    """
                    GHOSTHUB_KWT_PROJECT_JSON
                    {"status":"registered","project":{"repository":"github.com/acme/widget","name":"widget","path":"/home/alice/code/widget"}}
                    """
                )
            },
            remoteRunner: { _, _, command in
                remoteCommand.store(command)
                return AccountCommandOutput(
                    status: 0,
                    stdout: """
                    GHOSTHUB_KWT_PROJECT_JSON
                    {"status":"registered","project":{"repository":"github.com/acme/widget","name":"widget","path":"/home/alice/code/widget"}}
                    """,
                    stderr: ""
                )
            },
            localBinaryPath: "/Applications/Ghosthub.app/Contents/Helpers/kwt",
            remoteBinaryRevision: String(repeating: "d", count: 40)
        )

        _ = try await client.register(projectPath: input, on: .local)
        _ = try await client.register(
            projectPath: input,
            on: SSHHostInfo(user: "alice", hostname: "builder.example.test", port: nil)
        )

        #expect(localCommand.load()?.contains(
            "projects add \(expectedArgument) --json"
        ) == true)
        #expect(remoteCommand.load()?.contains(
            "projects add \(expectedArgument) --json"
        ) == true)
    }

    @Test("registration rejects other-user tilde paths before invoking kwt")
    func rejectsOtherUserTildePath() async {
        let invoked = LockedValue(false)
        let client = KwtProjectRegistryClient(
            localRunner: { _ in
                invoked.store(true)
                return (0, "")
            }
        )

        await #expect {
            try await client.register(projectPath: "~alice/widget", on: .local)
        } throws: { error in
            error as? KwtProjectCommandError == .invalidProjectPath
        }
        #expect(!invoked.load())
    }

    @Test("removal rejects unexpanded tilde paths")
    func removalRejectsTildePath() async {
        let invoked = LockedValue(false)
        let client = KwtProjectRegistryClient(
            localRunner: { _ in
                invoked.store(true)
                return (0, "")
            }
        )

        await #expect {
            try await client.unregister(
                projectPath: "~/code/widget",
                expectedRepository: "github.com/acme/widget",
                expectedRegistration: "opaque-registration",
                expectedRouteIdentity: nil,
                on: .local
            )
        } throws: { error in
            error as? KwtProjectCommandError == .invalidProjectPath
        }
        #expect(!invoked.load())
    }

    @Test("recovery expands ~ in destination while requiring an absolute project path")
    func recoveryExpandsDestinationTilde() async throws {
        let invocation = LockedValue<String?>(nil)
        let client = KwtProjectRegistryClient(
            localRunner: { command in
                invocation.store(command)
                return (
                    0,
                    """
                    GHOSTHUB_KWT_PROJECT_JSON
                    {"status":"recovered","project":{"repository":"github.com/acme/widget","name":"widget","path":"/home/alice/moved/widget","registration_fingerprint":"fp-1"}}
                    """
                )
            },
            localBinaryPath: "/Applications/Ghosthub.app/Contents/Helpers/kwt"
        )
        let project = ProjectSummary(
            id: UUID(),
            hostID: UUID(),
            scopedKey: "github.com/acme/widget",
            name: "widget",
            rootPath: "/old/widget",
            registrationFingerprint: "fp-1"
        )

        _ = try await client.recover(
            project: project,
            to: "~/moved/widget",
            expectedRouteIdentity: nil,
            on: .local
        )

        #expect(invocation.load()?.contains(
            "projects recover '/old/widget' --to \"${HOME:?}\"'/moved/widget' "
                + "--expected-repository 'github.com/acme/widget' "
                + "--expected-registration 'fp-1' --json"
        ) == true)
    }

    @Test("shell execution expands ~ against target HOME without evaluating suffix metacharacters")
    func shellExecutionExpandsTildeSafely() async throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ghosthub-tilde-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let stubKwt = tempDir.appendingPathComponent("stub-kwt")
        let capturedArgFile = tempDir.appendingPathComponent("captured-arg.txt")
        let script = """
        #!/bin/sh
        printf '%s' "$3" > \(shellQuotedCommandArgument(capturedArgFile.path))
        printf '{"status":"registered","project":{"repository":"github.com/acme/widget","name":"widget","path":"/expanded"}}\n'
        """
        try script.write(to: stubKwt, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o700],
            ofItemAtPath: stubKwt.path
        )

        let fakeHome = tempDir.appendingPathComponent("Alice Home").path
        let client = KwtProjectRegistryClient(
            localRunner: { command in
                Self.runPosixShell(command: command, home: fakeHome)
            },
            localBinaryPath: stubKwt.path
        )

        _ = try await client.register(
            projectPath: "~/code/alice's $USER $(echo nope)",
            on: .local
        )
        let receivedPath = try String(contentsOf: capturedArgFile, encoding: .utf8)
        #expect(receivedPath == "\(fakeHome)/code/alice's $USER $(echo nope)")

        // Empty HOME must fail closed rather than expanding ~/tmp to /tmp.
        let emptyHomeClient = KwtProjectRegistryClient(
            localRunner: { command in
                Self.runPosixShell(command: command, home: "")
            },
            localBinaryPath: stubKwt.path
        )
        await #expect {
            try await emptyHomeClient.register(projectPath: "~/tmp", on: .local)
        } throws: { error in
            guard case KwtProjectCommandError.commandFailed = error else {
                return false
            }
            return true
        }
    }

    private static func runPosixShell(
        command: String,
        home: String
    ) -> (status: Int32, stdout: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", command]
        process.environment = ["HOME": home, "PATH": "/usr/bin:/bin"]
        let stdout = Pipe()
        process.standardOutput = stdout
        process.standardError = Pipe()
        do {
            try process.run()
        } catch {
            return (1, "")
        }
        let data = stdout.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus, String(decoding: data, as: UTF8.self))
    }
}
