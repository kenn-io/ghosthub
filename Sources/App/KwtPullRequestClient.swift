import Foundation
import GhosthubTmux
import GhosthubWorkspace

enum KwtPullRequestError: Error, Equatable, LocalizedError {
    case projectUnavailable
    case importInProgress
    case importedWorkspaceMissing(path: String)
    case commandFailed(
        host: String,
        status: Int32,
        code: String?,
        message: String?,
        retryable: Bool
    )
    case malformedOutput(host: String)

    var errorDescription: String? {
        switch self {
        case .projectUnavailable:
            return "The selected kwt project or host is no longer available."
        case .importInProgress:
            return "Another pull request is already being imported."
        case let .importedWorkspaceMissing(path):
            return "kwt imported the pull request, but \(path) was not present in workspace inventory."
        case let .commandFailed(
            host,
            status,
            _,
            message,
            retryable
        ):
            let detail = message
                ?? "kwt exited with status \(status) on \(host)."
            return retryable ? "\(detail) Try again." : detail
        case let .malformedOutput(host):
            return "kwt returned an invalid pull request response on \(host)."
        }
    }
}

struct KwtPullRequestImportResult: Equatable, Sendable {
    var status: String
    var pullRequest: PullRequestCandidate
    var workspace: PullRequestWorkspace
}

/// Executes kwt's provider-neutral pull-request automation contract. Ghosthub
/// never calls GitHub, interprets refs, or chooses workspace/session names.
struct KwtPullRequestClient: Sendable {
    typealias LocalRunner = @Sendable (
        _ shell: String, _ command: String
    ) -> (status: Int32, stdout: String)
    typealias RemoteRunner = @Sendable (
        _ host: SSHHostInfo, _ command: String
    ) -> (status: Int32, stdout: String)

    private static let jsonMarker = "GHOSTHUB_KWT_PR_JSON\n"
    private let localRunner: LocalRunner
    private let remoteRunner: RemoteRunner
    private let loginShellProvider: @Sendable () -> String
    private let localBinaryPath: String?
    private let remoteBinaryRevision: String?

    init(
        localRunner: LocalRunner? = nil,
        remoteRunner: RemoteRunner? = nil,
        processTimeout: TimeInterval = 300,
        localBinaryPath: String? = KwtBinaryLocator.bundledPath(),
        remoteBinaryRevision: String? =
            KwtBinaryLocator.bundledRemoteRevision(),
        loginShellProvider: @escaping @Sendable () -> String =
            TmuxBinaryResolver.loginShell
    ) {
        self.localRunner = localRunner ?? { shell, command in
            TmuxBinaryResolver.runLoginShell(
                shell: shell,
                command: command,
                timeout: processTimeout
            )
        }
        self.remoteRunner = remoteRunner ?? { host, command in
            TmuxBinaryResolver.runRemoteLoginShell(
                host: host,
                command: command,
                timeout: processTimeout
            )
        }
        self.loginShellProvider = loginShellProvider
        self.localBinaryPath = localBinaryPath
        self.remoteBinaryRevision = remoteBinaryRevision
    }

    func list(
        projectIdentity: String,
        on host: TmuxHost
    ) async throws -> [PullRequestCandidate] {
        let response: ListResponse = try await execute(
            Self.listCommand(
                projectIdentity: projectIdentity,
                platform: platform(for: host),
                binaryPrelude: binaryPrelude(for: host)
            ),
            on: host
        )
        return response.pullRequests.map(\.candidate)
    }

    func importPullRequest(
        id: String,
        projectIdentity: String,
        on host: TmuxHost
    ) async throws -> KwtPullRequestImportResult {
        let response: ImportResponse = try await execute(
            Self.importCommand(
                id: id,
                projectIdentity: projectIdentity,
                platform: platform(for: host),
                binaryPrelude: binaryPrelude(for: host)
            ),
            on: host
        )
        guard response.workspace.hasValidSocketName,
              response.pullRequest.workspace?.hasValidSocketName != false
        else {
            throw KwtPullRequestError.malformedOutput(
                host: host.displayName
            )
        }
        return KwtPullRequestImportResult(
            status: response.status,
            pullRequest: response.pullRequest.candidate,
            workspace: response.workspace.workspace
        )
    }

    private func execute<Value: Decodable>(
        _ command: String,
        on host: TmuxHost
    ) async throws -> Value {
        let localRunner = localRunner
        let remoteRunner = remoteRunner
        let shell = loginShellProvider()
        let task = Task.detached(priority: .userInitiated) {
            switch host {
            case .local:
                localRunner(shell, command)
            case let .ssh(info):
                remoteRunner(info, command)
            }
        }
        let result = await withTaskCancellationHandler {
            await task.value
        } onCancel: {
            task.cancel()
        }
        return try Self.decode(
            result,
            hostLabel: host.displayName
        )
    }

    private func binaryPrelude(for host: TmuxHost) -> String {
        switch host {
        case .local:
            KwtBinaryLocator.commandPrelude(exactPath: localBinaryPath)
        case .ssh:
            KwtBinaryLocator.remoteCommandPrelude(
                revision: remoteBinaryRevision
            )
        }
    }

    private func platform(
        for host: TmuxHost
    ) -> SSHHostInfo.Platform {
        switch host {
        case .local: .posix
        case let .ssh(info): info.platform
        }
    }

    private static func decode<Value: Decodable>(
        _ result: (status: Int32, stdout: String),
        hostLabel: String
    ) throws -> Value {
        guard let markerRange = result.stdout.range(
            of: jsonMarker,
            options: .backwards
        ) else {
            if result.status != 0 {
                throw KwtPullRequestError.commandFailed(
                    host: hostLabel,
                    status: result.status,
                    code: nil,
                    message: nil,
                    retryable: false
                )
            }
            throw KwtPullRequestError.malformedOutput(host: hostLabel)
        }
        let data = Data(result.stdout[markerRange.upperBound...].utf8)
        guard result.status == 0 else {
            let envelope = try? JSONDecoder().decode(
                ErrorEnvelope.self,
                from: data
            )
            throw KwtPullRequestError.commandFailed(
                host: hostLabel,
                status: result.status,
                code: envelope?.error.code,
                message: envelope?.error.message,
                retryable: envelope?.error.retryable ?? false
            )
        }
        do {
            return try JSONDecoder().decode(Value.self, from: data)
        } catch {
            throw KwtPullRequestError.malformedOutput(host: hostLabel)
        }
    }

    static func listCommand(
        projectIdentity: String,
        platform: SSHHostInfo.Platform = .posix,
        binaryPrelude: String
    ) -> String {
        if platform == .windows {
            return KwtPowerShellCommand.run(
                arguments: [
                    "pr", "list", "--project", projectIdentity,
                    "--state", "open", "--json",
                ],
                marker: "GHOSTHUB_KWT_PR_JSON"
            )
        }
        return commandPrelude(binaryPrelude: binaryPrelude)
            + "exec \"$ghosthub_kwt_path\" pr list --project "
            + shellQuotedCommandArgument(projectIdentity)
            + " --state open --json"
    }

    static func importCommand(
        id: String,
        projectIdentity: String,
        platform: SSHHostInfo.Platform = .posix,
        binaryPrelude: String
    ) -> String {
        if platform == .windows {
            return KwtPowerShellCommand.run(
                arguments: [
                    "pr", "import", id, "--project", projectIdentity,
                    "--json",
                ],
                marker: "GHOSTHUB_KWT_PR_JSON"
            )
        }
        return commandPrelude(binaryPrelude: binaryPrelude)
            + "exec \"$ghosthub_kwt_path\" pr import "
            + shellQuotedCommandArgument(id)
            + " --project "
            + shellQuotedCommandArgument(projectIdentity)
            + " --json"
    }

    private static func commandPrelude(
        binaryPrelude: String
    ) -> String {
        binaryPrelude + "printf 'GHOSTHUB_KWT_PR_JSON\\n'; "
    }
}

private struct ListResponse: Decodable {
    var pullRequests: [PullRequestDTO]

    private enum CodingKeys: String, CodingKey {
        case pullRequests = "pull_requests"
    }
}

private struct ImportResponse: Decodable {
    var status: String
    var pullRequest: PullRequestDTO
    var workspace: PullRequestWorkspaceDTO

    private enum CodingKeys: String, CodingKey {
        case status, workspace
        case pullRequest = "pull_request"
    }
}

private struct PullRequestDTO: Decodable {
    var id: String
    var number: Int
    var url: String
    var title: String
    var author: String
    var source: BranchDTO
    var target: BranchDTO
    var draft: Bool
    var state: String
    var imported: Bool
    var workspace: PullRequestWorkspaceDTO?

    var candidate: PullRequestCandidate {
        PullRequestCandidate(
            id: id,
            number: number,
            url: url,
            title: title,
            author: author,
            sourceBranch: source.branch,
            targetBranch: target.branch,
            isDraft: draft,
            state: state,
            isImported: imported,
            workspace: workspace?.workspace
        )
    }
}

private struct BranchDTO: Decodable {
    var branch: String
}

private struct PullRequestWorkspaceDTO: Decodable {
    var id: String
    var repository: String
    var branch: String
    var path: String
    var state: String
    var sessionName: String
    var tmuxSocketName: String

    private enum CodingKeys: String, CodingKey {
        case id, repository, branch, path, state
        case sessionName = "session_name"
        case tmuxSocketName = "tmux_socket_name"
    }

    var hasValidSocketName: Bool {
        !tmuxSocketName
            .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var workspace: PullRequestWorkspace {
        PullRequestWorkspace(
            id: id,
            repository: repository,
            branch: branch,
            path: path,
            state: state,
            sessionName: sessionName,
            tmuxSocketName: tmuxSocketName
        )
    }
}

private struct ErrorEnvelope: Decodable {
    var error: ErrorDTO
}

private struct ErrorDTO: Decodable {
    var code: String
    var message: String
    var retryable: Bool
}
