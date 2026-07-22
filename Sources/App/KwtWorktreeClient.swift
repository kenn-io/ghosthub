import Foundation
import GhosthubTmux
import GhosthubWorkspace

enum KwtWorktreeError: Error, Equatable, LocalizedError {
    case invalidBranchName
    case projectUnavailable
    case creationInProgress
    case commandFailed(host: String, status: Int32)
    case createdWorktreeMissing(branch: String)

    var errorDescription: String? {
        switch self {
        case .invalidBranchName:
            "Enter a valid git branch name."
        case .projectUnavailable:
            "The selected kwt project or host is no longer available."
        case .creationInProgress:
            "Another worktree is already being created."
        case let .commandFailed(host, status):
            "kwt could not create the worktree on \(host) (status \(status))."
        case let .createdWorktreeMissing(branch):
            "kwt completed, but \(branch) was not present in the refreshed inventory."
        }
    }
}

/// Executes only kwt's supported worktree-creation surface. Ghosthub does not
/// choose a worktree path or launch its own workspace/session implementation.
struct KwtWorktreeClient: Sendable {
    typealias LocalRunner = @Sendable (
        _ shell: String, _ command: String
    ) -> (status: Int32, stdout: String)
    typealias RemoteRunner = @Sendable (
        _ host: SSHHostInfo, _ command: String
    ) -> (status: Int32, stdout: String)

    private let localRunner: LocalRunner
    private let remoteRunner: RemoteRunner
    private let loginShellProvider: @Sendable () -> String
    private let localBinaryPath: String?

    init(
        localRunner: LocalRunner? = nil,
        remoteRunner: RemoteRunner? = nil,
        processTimeout: TimeInterval = 60,
        localBinaryPath: String? = KwtBinaryLocator.bundledPath(),
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
    }

    func create(
        request: WorktreeCreateRequest,
        projectPath: String,
        on host: TmuxHost
    ) async throws {
        let selectedBinaryPath: String?
        switch host {
        case .local:
            selectedBinaryPath = localBinaryPath
        case .ssh:
            selectedBinaryPath = nil
        }
        let command = Self.command(
            branchName: request.branchName,
            createsBranch: request.createsBranch,
            projectPath: projectPath,
            localBinaryPath: selectedBinaryPath
        )
        let localRunner = localRunner
        let remoteRunner = remoteRunner
        let shell = loginShellProvider()
        let result = await Task.detached(priority: .userInitiated) {
            switch host {
            case .local:
                localRunner(shell, command)
            case let .ssh(info):
                remoteRunner(info, command)
            }
        }.value
        guard result.status == 0 else {
            throw KwtWorktreeError.commandFailed(
                host: host.displayName,
                status: result.status
            )
        }
    }

    static func command(
        branchName: String,
        createsBranch: Bool,
        projectPath: String,
        localBinaryPath: String? = nil
    ) -> String {
        let branchFlag = createsBranch ? " --branch" : ""
        return KwtBinaryLocator.commandPrelude(exactPath: localBinaryPath)
            + "cd -- \(shellQuotedCommandArgument(projectPath)) || exit $?; "
            + "exec \"$ghosthub_kwt_path\" add\(branchFlag) "
            + "\(shellQuotedCommandArgument(branchName)) --no-launch"
    }
}
