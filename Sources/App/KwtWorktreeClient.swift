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
    case changeInspectionFailed(
        host: String,
        status: Int32,
        code: String?,
        message: String?,
        retryable: Bool,
        details: [String: KwtProjectErrorDetail]
    )
    case malformedChangeStatus(host: String)
    case createdWorktreeMissing(branch: String)
    case malformedBranches(host: String)

    var errorDescription: String? {
        switch self {
        case .invalidBranchName:
            return "Enter a valid git branch name."
        case .projectUnavailable:
            return "The selected kwt project or host is no longer available."
        case .creationInProgress:
            return "Another worktree change is already in progress."
        case .worktreeUnavailable:
            return "The selected kwt worktree or host is no longer available."
        case .primaryWorktreeCannotBeRemoved:
            return "The primary checkout cannot be removed."
        case .removalInProgress:
            return "Another worktree change is already in progress."
        case .removalIdentityUnavailable:
            return "The worktree has no stable removal identity. Refresh the"
                + " workspace and try again."
        case .removalTargetChanged:
            return "The worktree or its tmux session changed after confirmation."
                + " Review the refreshed workspace and try again."
        case .removalHostChanged:
            return "The host destination changed after confirmation. Review the host"
                + " settings and try again."
        case .removalChangesChanged:
            return "The worktree gained uncommitted changes after confirmation."
                + " Review the updated removal warning and try again."
        case let .removalPreflightUnavailable(host, message):
            return "kwt could not verify the worktree on \(host): \(message)"
        case let .sessionStartedAfterConfirmation(session):
            return "Tmux session “\(session)” started after confirmation. Review the"
                + " updated removal warning and try again."
        case let .commandFailed(host, status):
            return "kwt could not create the worktree on \(host) (status \(status))."
        case let .removalFailed(host, status):
            return "kwt could not remove the worktree on \(host) (status \(status))."
        case let .changeInspectionFailed(
            host,
            status,
            _,
            message,
            retryable,
            _
        ):
            let detail = message
                ?? "kwt could not inspect worktree changes on \(host)"
                + " (status \(status))."
            return retryable ? "\(detail) Try again." : detail
        case let .malformedChangeStatus(host):
            return "kwt returned an invalid worktree change status on \(host)."
        case let .createdWorktreeMissing(branch):
            return "kwt completed, but \(branch) was not present in the refreshed inventory."
        case let .malformedBranches(host):
            return "kwt returned an invalid branch list on \(host)."
        }
    }
}

extension KwtWorktreeError: WorktreeChangesRetryClassifying {
    var isRetryable: Bool {
        if case let .changeInspectionFailed(
            _, _, _, _, retryable, _
        ) = self {
            return retryable
        }
        return false
    }
}

/// Executes only kwt's supported worktree lifecycle surfaces. Ghosthub does
/// not choose a worktree path or launch its own workspace/session
/// implementation.
struct KwtWorktreeClient: Sendable {
    private static let jsonMarker = "GHOSTHUB_KWT_JSON\n"
    private static let maximumOutputBytes = 16 * 1_024 * 1_024
    typealias LocalRunner = @Sendable (
        _ shell: String, _ command: String
    ) -> (status: Int32, stdout: String)
    typealias RemoteRunner = @Sendable (
        _ host: SSHHostInfo, _ command: String, _ expectedRouteIdentity: String?
    ) async -> AccountCommandOutput

    private let localRunner: LocalRunner
    private let remoteRunner: RemoteRunner
    private let changeLocalRunner: LocalRunner
    private let changeRemoteRunner: RemoteRunner
    private let loginShellProvider: @Sendable () -> String
    private let localBinaryPath: String?
    private let remoteBinaryRevision: String?

    init(
        localRunner: LocalRunner? = nil,
        remoteRunner: RemoteRunner? = nil,
        processTimeout: TimeInterval = 60,
        changeInspectionTimeout: TimeInterval = 15,
        localBinaryPath: String? = KwtBinaryLocator.bundledPath(),
        remoteBinaryRevision: String? =
            KwtBinaryLocator.bundledRemoteRevision(),
        loginShellProvider: @escaping @Sendable () -> String =
            AccountCommandRunner.loginShell
    ) {
        let maximumOutputBytes = Self.maximumOutputBytes
        self.localRunner = localRunner ?? { shell, command in
            AccountCommandRunner.runLoginShell(
                shell: shell,
                command: command,
                timeout: processTimeout,
                maximumOutputBytes: maximumOutputBytes
            )
        }
        self.remoteRunner = remoteRunner ?? { host, command, expectedRouteIdentity in
            await KwtSSHCommandClient(
                maximumOutputBytes: maximumOutputBytes
            ).run(
                on: host,
                command: command,
                timeout: processTimeout,
                expectedRouteIdentity: expectedRouteIdentity
            )
        }
        changeLocalRunner = localRunner ?? { shell, command in
            AccountCommandRunner.runLoginShell(
                shell: shell,
                command: command,
                timeout: changeInspectionTimeout,
                maximumOutputBytes: maximumOutputBytes
            )
        }
        changeRemoteRunner = remoteRunner ?? {
            host, command, expectedRouteIdentity in
            await KwtSSHCommandClient(
                maximumOutputBytes: maximumOutputBytes
            ).run(
                on: host,
                command: command,
                timeout: changeInspectionTimeout,
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
        expectedRepository: String,
        expectedGeneration: String,
        expectedRouteIdentity: String? = nil,
        on host: CommandHost
    ) async throws -> WorktreeFileChanges {
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
            worktreePath: worktreePath,
            expectedRepository: expectedRepository,
            expectedGeneration: expectedGeneration,
            platform: platform,
            binaryPrelude: binaryPrelude,
            windowsKwtRelativePath: windowsKwtRelativePath
        )
        let result = await runChanges(
            command,
            on: host,
            expectedRouteIdentity: expectedRouteIdentity
        )
        let normalizedOutput = result.stdout.replacingOccurrences(
            of: "\r\n",
            with: "\n"
        )
        if result.status == AccountCommandRunner.outputExceededStatus {
            throw KwtWorktreeError.changeInspectionFailed(
                host: host.displayName,
                status: result.status,
                code: "response_too_large",
                message: "kwt returned too many changed files to display.",
                retryable: false,
                details: [:]
            )
        }
        guard let markerRange = normalizedOutput.range(
            of: Self.jsonMarker,
            options: .backwards
        ) else {
            if result.status != 0 {
                throw KwtWorktreeError.changeInspectionFailed(
                    host: host.displayName,
                    status: result.status,
                    code: nil,
                    message: nil,
                    retryable: Self.isRetryableChangeInspectionStatus(
                        result.status
                    ),
                    details: [:]
                )
            }
            throw KwtWorktreeError.malformedChangeStatus(
                host: host.displayName
            )
        }
        let data = Data(normalizedOutput[markerRange.upperBound...].utf8)
        guard result.status == 0 else {
            let envelope = try? JSONDecoder().decode(
                KwtChangeInspectionErrorEnvelope.self,
                from: data
            )
            throw KwtWorktreeError.changeInspectionFailed(
                host: host.displayName,
                status: result.status,
                code: envelope?.error.code,
                message: envelope?.error.message,
                retryable: envelope?.error.retryable
                    ?? Self.isRetryableChangeInspectionStatus(result.status),
                details: envelope?.error.details ?? [:]
            )
        }
        do {
            let response = try JSONDecoder().decode(
                KwtChangeInspectionResponse.self,
                from: data
            )
            guard response.worktree.repository == expectedRepository,
                  Self.worktreePath(
                      response.worktree.path,
                      matches: worktreePath,
                      platform: platform
                  ),
                  response.worktree.generation == expectedGeneration,
                  WorktreeGeneration.isCanonical(response.worktree.generation)
            else {
                throw KwtWorktreeError.malformedChangeStatus(
                    host: host.displayName
                )
            }
            return response.value.sortedForPresentation()
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

    private func runChanges(
        _ command: String,
        on host: CommandHost,
        expectedRouteIdentity: String?
    ) async -> (status: Int32, stdout: String) {
        let localRunner = changeLocalRunner
        let remoteRunner = changeRemoteRunner
        let shell = loginShellProvider()
        switch host {
        case .local:
            return await BlockingTask.run(priority: .userInitiated) {
                localRunner(shell, command)
            }
        case let .ssh(info):
            let output = await remoteRunner(
                info,
                command,
                expectedRouteIdentity
            )
            return (output.status, output.stdout)
        }
    }

    private static func worktreePath(
        _ actual: String,
        matches expected: String,
        platform: SSHHostInfo.Platform
    ) -> Bool {
        switch platform {
        case .posix:
            actual == expected
        case .windows:
            actual.replacingOccurrences(of: "/", with: "\\")
                .caseInsensitiveCompare(
                    expected.replacingOccurrences(of: "/", with: "\\")
                ) == .orderedSame
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
        worktreePath: String,
        expectedRepository: String,
        expectedGeneration: String,
        platform: SSHHostInfo.Platform,
        binaryPrelude: String,
        windowsKwtRelativePath: String?
    ) -> String {
        if platform == .windows {
            return KwtPowerShellCommand.run(
                arguments: [
                    "changes",
                    worktreePath,
                    "--expected-repository",
                    expectedRepository,
                    "--expected-generation",
                    expectedGeneration,
                    "--json",
                ],
                marker: "GHOSTHUB_KWT_JSON",
                managedRelativePath: windowsKwtRelativePath
            )
        }
        return binaryPrelude
            + "printf 'GHOSTHUB_KWT_JSON\\n'; "
            + "exec \"$ghosthub_kwt_path\" changes "
            + shellQuotedCommandArgument(worktreePath)
            + " --expected-repository "
            + shellQuotedCommandArgument(expectedRepository)
            + " --expected-generation "
            + shellQuotedCommandArgument(expectedGeneration)
            + " --json"
    }

    private static func isRetryableChangeInspectionStatus(
        _ status: Int32
    ) -> Bool {
        status == 255 || status == AccountCommandRunner.timedOutStatus
    }
}

private struct KwtChangeInspectionResponse: Decodable {
    let worktree: KwtChangeInspectionIdentity
    let changes: KwtChangeSet
    let observedAt: String

    var value: WorktreeFileChanges {
        WorktreeFileChanges(
            repository: worktree.repository,
            path: worktree.path,
            generation: worktree.generation,
            state: changes.state,
            summary: changes.summary.value,
            files: changes.files,
            observedAt: observedAt
        )
    }

    private enum CodingKeys: String, CodingKey {
        case worktree
        case changes
        case observedAt = "observed_at"
    }
}

private struct KwtChangeInspectionIdentity: Decodable {
    let repository: String
    let path: String
    let generation: String
}

private struct KwtChangeSet: Decodable {
    let state: WorktreeChangeState
    let summary: KwtChangeSummary
    let files: [WorktreeFileChange]
}

private struct KwtChangeSummary: Decodable {
    let modified: Int
    let added: Int
    let deleted: Int
    let untracked: Int
    let staged: Int
    let conflicts: Int

    var value: WorktreeChangeSummary {
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

private struct KwtChangeInspectionErrorEnvelope: Decodable {
    let error: KwtChangeInspectionError
}

private struct KwtChangeInspectionError: Decodable {
    let code: String
    let message: String
    let retryable: Bool
    let details: [String: KwtProjectErrorDetail]?
}
