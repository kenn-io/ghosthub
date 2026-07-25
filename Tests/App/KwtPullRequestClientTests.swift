import Foundation
import GhosthubTmux
import Testing
@testable import GhosthubApp

@Suite("kwt pull request automation")
struct KwtPullRequestClientTests {
    @Test("local listing uses the bundled kwt contract")
    func localListing() async throws {
        let recorder = PullRequestCommandRecorder()
        let client = KwtPullRequestClient(
            localRunner: { shell, command in
                recorder.record(shell: shell, command: command)
                return (0, Self.listResponse)
            },
            localBinaryPath:
                "/Applications/Ghosthub.app/Contents/Helpers/kwt",
            loginShellProvider: { "/bin/zsh" }
        )

        let candidates = try await client.list(
            projectIdentity: "github.com/kenn-io/ghosthub",
            on: .local
        )

        #expect(recorder.shell == "/bin/zsh")
        #expect(recorder.command?.contains(
            "pr list --project 'github.com/kenn-io/ghosthub' --state open --json"
        ) == true)
        let candidate = try #require(candidates.first)
        #expect(candidate.id == "github:github.com/kenn-io/ghosthub#32")
        #expect(candidate.number == 32)
        #expect(candidate.sourceBranch == "feature/pr-import")
        #expect(!candidate.isImported)
    }

    @Test("remote import returns kwt workspace identity unchanged")
    func remoteImport() async throws {
        let recorder = PullRequestCommandRecorder()
        let ssh = SSHHostInfo(
            user: "wesm",
            hostname: "builder",
            port: 2222
        )
        let client = KwtPullRequestClient(
            remoteRunner: { host, command in
                recorder.record(host: host, command: command)
                return (0, Self.importResponse)
            }
        )

        let result = try await client.importPullRequest(
            id: "github:github.com/kenn-io/ghosthub#32",
            projectIdentity: "github.com/kenn-io/ghosthub",
            on: .ssh(ssh)
        )

        #expect(recorder.host == ssh)
        #expect(recorder.command?.hasPrefix(
            "ghosthub_kwt_path=$(command -v kwt) || exit 127;"
        ) == true)
        #expect(recorder.command?.contains(
            "pr import 'github:github.com/kenn-io/ghosthub#32'"
        ) == true)
        #expect(recorder.command?.contains(
            "--start-session"
        ) == false)
        #expect(recorder.command?.hasSuffix("--json") == true)
        #expect(result.status == "created")
        #expect(result.workspace.path == "/tmp/ghosthub-pr-32")
        #expect(result.workspace.sessionName == "kwt-workspace-pr-32")
        #expect(
            result.workspace.tmuxSocketName
                == "kwt-pr-0123456789abcdef"
        )
        #expect(
            result.pullRequest.workspace?.tmuxSocketName
                == "kwt-pr-0123456789abcdef"
        )
        #expect(result.pullRequest.isImported)
    }

    @Test("session startup failure remains a successful imported result")
    func partialSessionFailure() async throws {
        let response = Self.importResponse.replacingOccurrences(
            of: #""status": "created","#,
            with: """
            "status": "created",
              "session_start_error": {
                "code": "workspace_creation_failed",
                "message": "tmux could not start",
                "retryable": false
              },
            """
        )
        let client = KwtPullRequestClient(
            localRunner: { _, _ in (0, response) }
        )

        let result = try await client.importPullRequest(
            id: "github:github.com/kenn-io/ghosthub#32",
            projectIdentity: "github.com/kenn-io/ghosthub",
            on: .local
        )

        #expect(result.status == "created")
        #expect(
            result.sessionStartError
                == KwtPullRequestSessionStartError(
                    code: "workspace_creation_failed",
                    message: "tmux could not start",
                    retryable: false
                )
        )
        #expect(result.workspace.path == "/tmp/ghosthub-pr-32")
    }

    @Test(
        "successful imports require an isolated tmux socket",
        arguments: [false, true]
    )
    func importRequiresSocketName(omitSocket: Bool) async {
        let socketField =
            #""tmux_socket_name": "kwt-pr-0123456789abcdef""#
        let replacement = omitSocket
            ? ""
            : #""tmux_socket_name": "   ""#
        let response = Self.importResponse.replacingOccurrences(
            of: socketField,
            with: replacement
        )
        let client = KwtPullRequestClient(
            localRunner: { _, _ in (0, response) }
        )

        await #expect {
            try await client.importPullRequest(
                id: "github:github.com/kenn-io/ghosthub#32",
                projectIdentity: "github.com/kenn-io/ghosthub",
                on: .local
            )
        } throws: { error in
            error as? KwtPullRequestError
                == .malformedOutput(host: "localhost")
        }
    }

    @Test("kwt failure preserves its machine-readable diagnostic")
    func reportsTypedFailure() async {
        let client = KwtPullRequestClient(
            localRunner: { _, _ in
                (
                    8,
                    """
                    banner
                    GHOSTHUB_KWT_PR_JSON
                    {"error":{"code":"network_failure","message":"GitHub is unavailable","retryable":true}}
                    """
                )
            }
        )

        await #expect {
            try await client.list(
                projectIdentity: "github.com/kenn-io/ghosthub",
                on: .local
            )
        } throws: { error in
            guard case let KwtPullRequestError.commandFailed(
                _,
                status,
                code,
                message,
                retryable
            ) = error else {
                return false
            }
            return status == 8
                && code == "network_failure"
                && message == "GitHub is unavailable"
                && retryable
        }
    }

    private static let listResponse = """
        login banner
        GHOSTHUB_KWT_PR_JSON
        {
          "pull_requests": [{
            "id": "github:github.com/kenn-io/ghosthub#32",
            "provider": "github",
            "repository": {
              "provider": "github",
              "identity": "github.com/kenn-io/ghosthub",
              "host": "github.com",
              "owner": "kenn-io",
              "name": "ghosthub"
            },
            "number": 32,
            "url": "https://github.com/kenn-io/ghosthub/pull/32",
            "title": "Import pull requests",
            "author": "wesm",
            "source": {
              "branch": "feature/pr-import",
              "repository": {
                "provider": "github",
                "identity": "github.com/wesm/ghosthub",
                "host": "github.com",
                "owner": "wesm",
                "name": "ghosthub"
              },
              "is_fork": true
            },
            "target": {
              "branch": "main",
              "repository": {
                "provider": "github",
                "identity": "github.com/kenn-io/ghosthub",
                "host": "github.com",
                "owner": "kenn-io",
                "name": "ghosthub"
              },
              "is_fork": false
            },
            "draft": false,
            "state": "open",
            "head_sha": "0123456789012345678901234567890123456789",
            "imported": false
          }]
        }
        """

    private static let importResponse = """
        GHOSTHUB_KWT_PR_JSON
        {
          "status": "created",
          "pull_request": {
            "id": "github:github.com/kenn-io/ghosthub#32",
            "provider": "github",
            "repository": {
              "provider": "github",
              "identity": "github.com/kenn-io/ghosthub",
              "host": "github.com",
              "owner": "kenn-io",
              "name": "ghosthub"
            },
            "number": 32,
            "url": "https://github.com/kenn-io/ghosthub/pull/32",
            "title": "Import pull requests",
            "author": "wesm",
            "source": {
              "branch": "feature/pr-import",
              "repository": {
                "provider": "github",
                "identity": "github.com/wesm/ghosthub",
                "host": "github.com",
                "owner": "wesm",
                "name": "ghosthub"
              },
              "is_fork": true
            },
            "target": {
              "branch": "main",
              "repository": {
                "provider": "github",
                "identity": "github.com/kenn-io/ghosthub",
                "host": "github.com",
                "owner": "kenn-io",
                "name": "ghosthub"
              },
              "is_fork": false
            },
            "draft": false,
            "state": "open",
            "head_sha": "0123456789012345678901234567890123456789",
            "imported": true,
            "workspace": {
              "id": "workspace-32",
              "repository": "github.com/kenn-io/ghosthub",
              "branch": "pr-32-feature-pr-import",
              "path": "/tmp/ghosthub-pr-32",
              "state": "ready",
              "session_name": "kwt-workspace-pr-32",
              "tmux_socket_name": "kwt-pr-0123456789abcdef"
            }
          },
          "project": {
            "identity": "github.com/kenn-io/ghosthub",
            "name": "ghosthub",
            "path": "/code/ghosthub"
          },
          "workspace": {
            "id": "workspace-32",
            "repository": "github.com/kenn-io/ghosthub",
            "branch": "pr-32-feature-pr-import",
            "path": "/tmp/ghosthub-pr-32",
            "state": "ready",
            "session_name": "kwt-workspace-pr-32",
            "tmux_socket_name": "kwt-pr-0123456789abcdef"
          }
        }
        """
}

private final class PullRequestCommandRecorder: @unchecked Sendable {
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
