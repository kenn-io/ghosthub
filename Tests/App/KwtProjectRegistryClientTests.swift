import GhosthubTransport
import Foundation
import GhosthubTmux
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
            remoteRunner: { _, _ in
                invoked.store(true)
                return (0, "")
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

    @Test("remote registration uses the managed helper and canonical response")
    func registersRemoteProject() async throws {
        let revision = String(repeating: "a", count: 40)
        let ssh = SSHHostInfo(
            user: "wesm",
            hostname: "spark",
            port: 2222
        )
        let invocation = LockedValue<(SSHHostInfo, String)?>(nil)
        let client = KwtProjectRegistryClient(
            remoteRunner: { host, command in
                invocation.store((host, command))
                return (
                    0,
                    """
                    banner
                    GHOSTHUB_KWT_PROJECT_JSON
                    {"status":"registered","project":{"repository":"github.com/acme/widget","name":"widget","path":"/srv/widget","last_touched":"2026-07-27T11:16:16Z"}}
                    """
                )
            },
            remoteBinaryRevision: revision
        )

        let project = try await client.register(
            projectPath: "/srv/wesm's widget",
            on: ssh
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
            remoteRunner: { _, _ in
                (
                    2,
                    """
                    GHOSTHUB_KWT_PROJECT_JSON
                    {"error":{"code":"invalid_repository","message":"/missing is not an accessible Git repository","retryable":false,"details":{"path":"/missing","operation":"add"}}}
                    """
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
            remoteRunner: { _, command in
                invocation.store(command)
                return (
                    0,
                    """
                    GHOSTHUB_KWT_PROJECT_JSON
                    {"status":"unregistered","project":{"repository":"github.com/acme/widget","name":"widget","path":"/srv/wesm's widget "}}
                    """
                )
            },
            remoteBinaryRevision: revision
        )

        let project = try await client.unregister(
            projectPath: "/srv/wesm's widget ",
            expectedRepository: "github.com/acme/widget",
            expectedRegistration: "opaque-registration",
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
}
