import GhosthubTransport
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
    case removalChangesChanged
    case removalPreflightUnavailable(host: String, message: String)
    case sessionStartedAfterConfirmation(session: String)
    case commandFailed(host: String, status: Int32)
    case removalFailed(host: String, status: Int32)
    case changeStatusFailed(host: String, status: Int32)
    case malformedChangeStatus(host: String)
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
            "The worktree has no stable removal identity. Refresh the"
                + " workspace and try again."
        case .removalTargetChanged:
            "The worktree or its tmux session changed after confirmation."
                + " Review the refreshed workspace and try again."
        case .removalHostChanged:
            "The host destination changed after confirmation. Review the host"
                + " settings and try again."
        case .removalChangesChanged:
            "The worktree gained uncommitted changes after confirmation."
                + " Review the updated removal warning and try again."
        case let .removalPreflightUnavailable(host, message):
            "kwt could not verify the worktree on \(host): \(message)"
        case let .sessionStartedAfterConfirmation(session):
            "Tmux session “\(session)” started after confirmation. Review the"
                + " updated removal warning and try again."
        case let .commandFailed(host, status):
            "kwt could not create the worktree on \(host) (status \(status))."
        case let .removalFailed(host, status):
            "kwt could not remove the worktree on \(host) (status \(status))."
        case let .changeStatusFailed(host, status):
            "kwt could not check the worktree for uncommitted changes on"
                + " \(host) (status \(status))."
        case let .malformedChangeStatus(host):
            "kwt returned an invalid worktree change status on \(host)."
        case let .createdWorktreeMissing(branch):
            "kwt completed, but \(branch) was not present in the refreshed inventory."
        case let .malformedBranches(host):
            "kwt returned an invalid branch list on \(host)."
        }
    }
}

/// Executes only kwt's supported worktree lifecycle surfaces. Ghosthub does
/// not choose a worktree path or launch its own workspace/session
/// implementation.
struct KwtWorktreeClient: Sendable {
    private static let jsonMarker = "GHOSTHUB_KWT_JSON\n"
    typealias LocalRunner = @Sendable (
        _ shell: String, _ command: String
    ) -> (status: Int32, stdout: String)
    typealias RemoteRunner = @Sendable (
        _ host: SSHHostInfo, _ command: String, _ expectedRouteIdentity: String?
    ) async -> AccountCommandOutput

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
            AccountCommandRunner.loginShell
    ) {
        self.localRunner = localRunner ?? { shell, command in
            AccountCommandRunner.runLoginShell(
                shell: shell,
                command: command,
                timeout: processTimeout
            )
        }
        self.remoteRunner = remoteRunner ?? { host, command, expectedRouteIdentity in
            await KwtSSHCommandClient().run(
                on: host,
                command: command,
                timeout: processTimeout,
                expectedRouteIdentity: expectedRouteIdentity
            )
        }
        self.loginShellProvider = loginShellProvider
        self.localBinaryPath = localBinaryPath
        self.remoteBinaryRevision = remoteBinaryRevision
    }

    func create(
        request: WorktreeCreateRequest,
        projectPath: String,
        on host: CommandHost
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
        let result = try await run(command, on: host)
        guard result.status == 0 else {
            throw KwtWorktreeError.commandFailed(
                host: host.displayName,
                status: result.status
            )
        }
    }

    func branches(
        projectPath: String,
        on host: CommandHost
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
        let result = try await run(command, on: host)
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
        force: Bool = false,
        expectedRouteIdentity: String? = nil,
        on host: CommandHost
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
            force: force,
            platform: platform,
            binaryPrelude: binaryPrelude,
            windowsKwtRelativePath: windowsKwtRelativePath
        )
        let result = try await run(
            command,
            on: host,
            expectedRouteIdentity: expectedRouteIdentity
        )
        guard result.status == 0 else {
            throw KwtWorktreeError.removalFailed(
                host: host.displayName,
                status: result.status
            )
        }
    }

    func changes(
        worktreePath: String,
        projectPath: String,
        on host: CommandHost
    ) async throws -> WorktreeChangeSummary {
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
        let command = Self.changesCommand(
            projectPath: projectPath,
            platform: platform,
            binaryPrelude: binaryPrelude,
            windowsKwtRelativePath: windowsKwtRelativePath
        )
        let result = try await run(command, on: host)
        guard result.status == 0 else {
            throw KwtWorktreeError.changeStatusFailed(
                host: host.displayName,
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
            throw KwtWorktreeError.malformedChangeStatus(
                host: host.displayName
            )
        }
        let json = normalizedOutput[markerRange.upperBound...]
        do {
            let records = try JSONDecoder().decode(
                [KwtWorktreeChangeRecord].self,
                from: Data(json.utf8)
            )
            guard let record = records.first(where: {
                $0.path == worktreePath
            }) else {
                return .clean
            }
            return record.gitStatus.summary
        } catch let error as KwtWorktreeError {
            throw error
        } catch {
            throw KwtWorktreeError.malformedChangeStatus(
                host: host.displayName
            )
        }
    }

    private func run(
        _ command: String,
        on host: CommandHost,
        expectedRouteIdentity: String? = nil
    ) async throws -> (status: Int32, stdout: String) {
        let localRunner = localRunner
        let shell = loginShellProvider()
        switch host {
        case .local:
            return await Task.detached(priority: .userInitiated) {
                localRunner(shell, command)
            }.value
        case let .ssh(info):
            let output = await remoteRunner(
                info,
                command,
                expectedRouteIdentity
            )
            return (output.status, output.stdout)
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
        force: Bool,
        platform: SSHHostInfo.Platform,
        binaryPrelude: String,
        windowsKwtRelativePath: String?
    ) -> String {
        if platform == .windows {
            var arguments = ["remove"]
            if force {
                arguments.append("--force")
            }
            arguments += [
                "--if-generation",
                generation,
                worktreePath,
            ]
            return KwtPowerShellCommand.run(
                arguments: arguments,
                workingDirectory: projectPath,
                managedRelativePath: windowsKwtRelativePath
            )
        }
        return binaryPrelude
            + "cd -- \(shellQuotedCommandArgument(projectPath)) || exit $?; "
            + "exec \"$ghosthub_kwt_path\" remove"
            + (force ? " --force" : "")
            + " --if-generation "
            + shellQuotedCommandArgument(generation)
            + " "
            + shellQuotedCommandArgument(worktreePath)
    }

    private static func changesCommand(
        projectPath: String,
        platform: SSHHostInfo.Platform,
        binaryPrelude: String,
        windowsKwtRelativePath: String?
    ) -> String {
        if platform == .windows {
            return KwtPowerShellCommand.run(
                arguments: ["status", "--json", "--no-fetch"],
                workingDirectory: projectPath,
                marker: "GHOSTHUB_KWT_JSON",
                managedRelativePath: windowsKwtRelativePath
            )
        }
        return binaryPrelude
            + "cd -- \(shellQuotedCommandArgument(projectPath)) || exit $?; "
            + "printf 'GHOSTHUB_KWT_JSON\\n'; "
            + "exec \"$ghosthub_kwt_path\" status --json --no-fetch"
    }
}

private struct KwtWorktreeChangeRecord: Decodable {
    let path: String
    let gitStatus: KwtGitStatusRecord

    private enum CodingKeys: String, CodingKey {
        case path
        case gitStatus = "git_status"
    }
}

private struct KwtGitStatusRecord: Decodable {
    let modified: Int
    let added: Int
    let deleted: Int
    let untracked: Int
    let staged: Int
    let conflicts: Int

    var summary: WorktreeChangeSummary {
        WorktreeChangeSummary(
            modified: modified,
            added: added,
            deleted: deleted,
            untracked: untracked,
            staged: staged,
            conflicts: conflicts
        )
    }
}
