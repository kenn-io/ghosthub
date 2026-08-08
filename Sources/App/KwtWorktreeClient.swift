import Foundation
import GhosthubTmux
import GhosthubWorkspace

enum KwtWorktreeError: Error, Equatable, LocalizedError {
    case invalidBranchName
    case projectUnavailable
    case creationInProgress
    case worktreeUnavailable
    case primaryWorktreeCannotBeRemoved
    case removalInProgress
    case removalIdentityUnavailable
    case removalTargetChanged
    case removalHostChanged
    case removalPreflightUnavailable(host: String, message: String)
    case sessionStartedAfterConfirmation(session: String)
    case commandFailed(host: String, status: Int32)
    case removalFailed(host: String, status: Int32)
    case createdWorktreeMissing(branch: String)
    case malformedBranches(host: String)

    var errorDescription: String? {
        switch self {
        case .invalidBranchName:
            "Enter a valid git branch name."
        case .projectUnavailable:
            "The selected kwt project or host is no longer available."
        case .creationInProgress:
            "Another worktree change is already in progress."
        case .worktreeUnavailable:
            "The selected kwt worktree or host is no longer available."
        case .primaryWorktreeCannotBeRemoved:
            "The primary checkout cannot be removed."
        case .removalInProgress:
            "Another worktree change is already in progress."
        case .removalIdentityUnavailable:
            "The worktree has no stable creation identity. Refresh the"
                + " workspace and try again."
        case .removalTargetChanged:
            "The worktree or its tmux session changed after confirmation."
                + " Review the refreshed workspace and try again."
        case .removalHostChanged:
            "The host destination changed after confirmation. Review the host"
                + " settings and try again."
        case let .removalPreflightUnavailable(host, message):
            "kwt could not verify the worktree on \(host): \(message)"
        case let .sessionStartedAfterConfirmation(session):
            "Tmux session “\(session)” started after confirmation. Review the"
                + " updated removal warning and try again."
        case let .commandFailed(host, status):
            "kwt could not create the worktree on \(host) (status \(status))."
        case let .removalFailed(host, status):
            "kwt could not remove the worktree on \(host) (status \(status))."
        case let .createdWorktreeMissing(branch):
            "kwt completed, but \(branch) was not present in the refreshed inventory."
        case let .malformedBranches(host):
            "kwt returned an invalid branch list on \(host)."
        }
    }
}

/// Executes only kwt's supported worktree-creation surface. Ghosthub does not
/// choose a worktree path or launch its own workspace/session implementation.
struct KwtWorktreeClient: Sendable {
    private static let jsonMarker = "GHOSTHUB_KWT_JSON\n"
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
    private let remoteBinaryRevision: String?

    init(
        localRunner: LocalRunner? = nil,
        remoteRunner: RemoteRunner? = nil,
        processTimeout: TimeInterval = 60,
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

    func create(
        request: WorktreeCreateRequest,
        projectPath: String,
        on host: TmuxHost
    ) async throws {
        let binaryPrelude: String
        let windowsKwtRelativePath: String?
        let platform: SSHHostInfo.Platform
        switch host {
        case .local:
            binaryPrelude = KwtBinaryLocator.commandPrelude(
                exactPath: localBinaryPath
            )
            windowsKwtRelativePath = nil
            platform = .posix
        case let .ssh(info):
            binaryPrelude = KwtBinaryLocator.remoteCommandPrelude(
                revision: remoteBinaryRevision
            )
            windowsKwtRelativePath =
                KwtBinaryLocator.windowsRemoteManagedRelativePath(
                    revision: remoteBinaryRevision
                )
            platform = info.platform
        }
        let command = Self.command(
            branchName: request.branchName,
            createsBranch: request.createsBranch,
            source: request.source,
            projectPath: projectPath,
            platform: platform,
            binaryPrelude: binaryPrelude,
            windowsKwtRelativePath: windowsKwtRelativePath
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

    func branches(
        projectPath: String,
        on host: TmuxHost
    ) async throws -> [WorktreeBranchCandidate] {
        let binaryPrelude: String
        let windowsKwtRelativePath: String?
        let platform: SSHHostInfo.Platform
        let hostLabel: String
        switch host {
        case .local:
            binaryPrelude = KwtBinaryLocator.commandPrelude(
                exactPath: localBinaryPath
            )
            windowsKwtRelativePath = nil
            platform = .posix
            hostLabel = "this Mac"
        case let .ssh(info):
            binaryPrelude = KwtBinaryLocator.remoteCommandPrelude(
                revision: remoteBinaryRevision
            )
            windowsKwtRelativePath =
                KwtBinaryLocator.windowsRemoteManagedRelativePath(
                    revision: remoteBinaryRevision
                )
            platform = info.platform
            hostLabel = info.displayName
        }
        let command = Self.branchesCommand(
            projectPath: projectPath,
            platform: platform,
            binaryPrelude: binaryPrelude,
            windowsKwtRelativePath: windowsKwtRelativePath
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
                host: hostLabel,
                status: result.status
            )
        }
        let normalizedOutput = result.stdout.replacingOccurrences(
            of: "\r\n",
            with: "\n"
        )
        guard let markerRange = normalizedOutput.range(
            of: Self.jsonMarker,
            options: .backwards
        ) else {
            throw KwtWorktreeError.malformedBranches(host: hostLabel)
        }
        let json = normalizedOutput[markerRange.upperBound...]
        do {
            return try JSONDecoder().decode(
                [WorktreeBranchCandidate].self,
                from: Data(json.utf8)
            )
        } catch {
            throw KwtWorktreeError.malformedBranches(host: hostLabel)
        }
    }

    func remove(
        worktreePath: String,
        generation: String,
        projectPath: String,
        on host: TmuxHost
    ) async throws {
        let binaryPrelude: String
        let windowsKwtRelativePath: String?
        let platform: SSHHostInfo.Platform
        switch host {
        case .local:
            binaryPrelude = KwtBinaryLocator.commandPrelude(
                exactPath: localBinaryPath
            )
            windowsKwtRelativePath = nil
            platform = .posix
        case let .ssh(info):
            binaryPrelude = KwtBinaryLocator.remoteCommandPrelude(
                revision: remoteBinaryRevision
            )
            windowsKwtRelativePath =
                KwtBinaryLocator.windowsRemoteManagedRelativePath(
                    revision: remoteBinaryRevision
                )
            platform = info.platform
        }
        let command = Self.removeCommand(
            worktreePath: worktreePath,
            generation: generation,
            projectPath: projectPath,
            platform: platform,
            binaryPrelude: binaryPrelude,
            windowsKwtRelativePath: windowsKwtRelativePath
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
            throw KwtWorktreeError.removalFailed(
                host: host.displayName,
                status: result.status
            )
        }
    }

    static func command(
        branchName: String,
        createsBranch: Bool,
        source: String? = nil,
        projectPath: String,
        platform: SSHHostInfo.Platform = .posix,
        binaryPrelude: String,
        windowsKwtRelativePath: String? = nil
    ) -> String {
        if platform == .windows {
            var arguments = ["add"]
            if createsBranch {
                arguments.append("--branch")
            } else if let source, source != branchName {
                arguments += ["--from", source]
            }
            arguments += [branchName, "--no-launch"]
            return KwtPowerShellCommand.run(
                arguments: arguments,
                workingDirectory: projectPath,
                managedRelativePath: windowsKwtRelativePath
            )
        }
        let branchFlags: String
        if createsBranch {
            branchFlags = " --branch"
        } else if let source, source != branchName {
            branchFlags = " --from \(shellQuotedCommandArgument(source))"
        } else {
            branchFlags = ""
        }
        return binaryPrelude
            + "cd -- \(shellQuotedCommandArgument(projectPath)) || exit $?; "
            + "exec \"$ghosthub_kwt_path\" add\(branchFlags) "
            + "\(shellQuotedCommandArgument(branchName)) --no-launch"
    }

    private static func branchesCommand(
        projectPath: String,
        platform: SSHHostInfo.Platform,
        binaryPrelude: String,
        windowsKwtRelativePath: String?
    ) -> String {
        if platform == .windows {
            return KwtPowerShellCommand.run(
                arguments: ["branches", "--json"],
                workingDirectory: projectPath,
                marker: "GHOSTHUB_KWT_JSON",
                managedRelativePath: windowsKwtRelativePath
            )
        }
        return binaryPrelude
            + "cd -- \(shellQuotedCommandArgument(projectPath)) || exit $?; "
            + "printf 'GHOSTHUB_KWT_JSON\\n'; "
            + "exec \"$ghosthub_kwt_path\" branches --json"
    }

    private static func removeCommand(
        worktreePath: String,
        generation: String,
        projectPath: String,
        platform: SSHHostInfo.Platform,
        binaryPrelude: String,
        windowsKwtRelativePath: String?
    ) -> String {
        if platform == .windows {
            return KwtPowerShellCommand.run(
                arguments: [
                    "remove",
                    "--if-generation",
                    generation,
                    worktreePath,
                ],
                workingDirectory: projectPath,
                managedRelativePath: windowsKwtRelativePath
            )
        }
        return binaryPrelude
            + "cd -- \(shellQuotedCommandArgument(projectPath)) || exit $?; "
            + "exec \"$ghosthub_kwt_path\" remove --if-generation "
            + shellQuotedCommandArgument(generation)
            + " "
            + shellQuotedCommandArgument(worktreePath)
    }
}
