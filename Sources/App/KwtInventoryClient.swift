import GhosthubTransport
import CryptoKit
import Foundation
import GhosthubTmux
import GhosthubWorkspace

enum WorkspaceInventoryState: Equatable, Sendable {
    case loading
    case loaded
    case failed(String)
}

struct KwtProjectRecord: Decodable, Equatable, Sendable {
    var repository: String
    var name: String
    var path: String
    var lastTouched: String?
    var registrationFingerprint: String

    init(
        repository: String,
        name: String,
        path: String,
        lastTouched: String?,
        registrationFingerprint: String = ""
    ) {
        self.repository = repository
        self.name = name
        self.path = path
        self.lastTouched = lastTouched
        self.registrationFingerprint = registrationFingerprint
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        repository = try container.decode(String.self, forKey: .repository)
        name = try container.decode(String.self, forKey: .name)
        path = try container.decode(String.self, forKey: .path)
        lastTouched = try container.decodeIfPresent(
            String.self,
            forKey: .lastTouched
        )
        registrationFingerprint = try container.decode(
            String.self,
            forKey: .registrationFingerprint
        )
        guard !registrationFingerprint.isEmpty else {
            throw DecodingError.dataCorruptedError(
                forKey: .registrationFingerprint,
                in: container,
                debugDescription:
                "registration_fingerprint must be nonempty"
            )
        }
    }

    private enum CodingKeys: String, CodingKey {
        case repository, name, path
        case lastTouched = "last_touched"
        case registrationFingerprint = "registration_fingerprint"
    }
}

struct KwtWorktreeRecord: Codable, Equatable, Sendable {
    var path: String
    var branch: String
    var commitHash: String
    var isMain: Bool
    var createdAt: String?
    var generation: String?
    var repository: String
    var sessionName: String
    var tmuxSocketName: String?
    var tmuxAttachMode: TmuxAttachMode = .direct

    private enum CodingKeys: String, CodingKey {
        case path, branch, repository
        case commitHash = "commit_hash"
        case isMain = "is_main"
        case createdAt = "created_at"
        case generation
        case sessionName = "session_name"
        case tmuxSocketName = "tmux_socket_name"
        case tmuxAttachMode = "tmux_attach_mode"
    }
}

struct KwtDirectoryWorkspaceRecord: Codable, Equatable, Sendable {
    var name: String
    var path: String
    var sessionName: String
    var sessionLive: Bool
    var tmuxSocketName: String? = nil
    var tmuxAttachMode: TmuxAttachMode = .direct

    private enum CodingKeys: String, CodingKey {
        case name, path
        case sessionName = "session_name"
        case sessionLive = "session_live"
        case tmuxSocketName = "tmux_socket_name"
        case tmuxAttachMode = "tmux_attach_mode"
    }
}

struct KwtProjectInventory: Equatable, Sendable {
    var project: KwtProjectRecord
    var worktrees: [KwtWorktreeRecord]
    var warning: String?
}

struct KwtHostInventory: Equatable, Sendable {
    var projects: [KwtProjectInventory]
    var projectsWarning: String?
    var directoryWorkspaces: [KwtDirectoryWorkspaceRecord]
    var directoryWorkspaceWarning: String?

    init(
        projects: [KwtProjectInventory],
        projectsWarning: String? = nil,
        directoryWorkspaces: [KwtDirectoryWorkspaceRecord] = [],
        directoryWorkspaceWarning: String? = nil
    ) {
        self.projects = projects
        self.projectsWarning = projectsWarning
        self.directoryWorkspaces = directoryWorkspaces
        self.directoryWorkspaceWarning = directoryWorkspaceWarning
    }

    func retainingFailedProjectWorktrees(
        from previous: KwtHostInventory?,
        excludingWorktrees: [String: Set<KwtWorktreeIdentity>] = [:]
    ) -> KwtHostInventory {
        var retainedProjects = projects
        if projectsWarning != nil,
           retainedProjects.isEmpty,
           let previous {
            retainedProjects = previous.projects
        }
        var retainedDirectories = directoryWorkspaces
        if directoryWorkspaceWarning != nil,
           retainedDirectories.isEmpty,
           let previous {
            retainedDirectories = previous.directoryWorkspaces
        }
        return KwtHostInventory(
            projects: retainedProjects.map { item in
                var retained = item
                if item.warning != nil,
                   let prior = previous?.projects.first(where: {
                       if item.project.repository.isEmpty,
                          $0.project.repository.isEmpty {
                           return $0.project.path == item.project.path
                       }
                       return !item.project.repository.isEmpty
                           && $0.project.repository
                           == item.project.repository
                   }) {
                    let refreshed = retained.worktrees
                    retained.worktrees.append(contentsOf:
                        prior.worktrees.filter { cached in
                            !refreshed.contains { current in
                                current.path == cached.path
                                    || (cached.generation != nil
                                        && current.generation
                                        == cached.generation)
                            }
                        })
                }
                let exclusions =
                    excludingWorktrees[item.project.repository] ?? []
                retained.worktrees.removeAll { worktree in
                    exclusions.contains {
                        $0.matches(
                            path: worktree.path,
                            generation: worktree.generation
                        )
                    }
                }
                return retained
            },
            projectsWarning: projectsWarning,
            directoryWorkspaces: retainedDirectories,
            directoryWorkspaceWarning: directoryWorkspaceWarning
        )
    }

    func removingWorktree(atPath path: String) -> KwtHostInventory {
        KwtHostInventory(
            projects: projects.map { item in
                var updated = item
                updated.worktrees.removeAll { $0.path == path }
                return updated
            },
            projectsWarning: projectsWarning,
            directoryWorkspaces: directoryWorkspaces,
            directoryWorkspaceWarning: directoryWorkspaceWarning
        )
    }
}

struct KwtWorktreeIdentity: Hashable, Sendable {
    let path: String
    let generation: String

    func matches(path: String, generation: String?) -> Bool {
        self.path == path
            && generation.map { self.generation == $0 } ?? true
    }
}

enum KwtInventoryError: Error, Equatable, LocalizedError {
    case commandFailed(host: String, status: Int32)
    case malformedOutput(host: String)
    case sshLeaseRequired(host: String)

    var errorDescription: String? {
        switch self {
        case let .commandFailed(host, status):
            if status == 255 {
                return "Remote kwt inventory could not complete on \(host)."
                    + " Open Host Settings and test the exact SSH"
                    + " destination."
            }
            return "kwt inventory failed on \(host) with status \(status)."
        case let .malformedOutput(host):
            return "kwt returned an invalid inventory on \(host)."
        case let .sshLeaseRequired(host):
            return "Remote kwt inventory on \(host) requires a reviewed SSH connection."
        }
    }
}

/// Reads kwt's supported machine-readable surfaces without interpreting its
/// configuration files. Directory workspaces are independent of project
/// inventory. Project order follows `kwt projects --json`; each project is
/// then asked for its own authoritative worktree/session list.
struct KwtInventoryClient: Sendable {
    typealias LocalRunner = @Sendable (
        _ shell: String, _ command: String
    ) -> (status: Int32, stdout: String)
    typealias RemoteRunner = @Sendable (
        _ host: SSHHostInfo,
        _ sshConnectionArguments: [String],
        _ command: String
    ) -> AccountCommandOutput

    private static let jsonMarker = "GHOSTHUB_KWT_JSON\n"
    private let localRunner: LocalRunner
    private let remoteRunner: RemoteRunner
    private let loginShellProvider: @Sendable () -> String
    private let localBinaryPath: String?
    private let remoteBinaryRevision: String?

    init(
        localRunner: LocalRunner? = nil,
        remoteRunner: RemoteRunner? = nil,
        processTimeout: TimeInterval = 45,
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
        self.remoteRunner = remoteRunner ?? { host, arguments, command in
            return AccountCommandRunner().runRemoteLoginShell(
                host: host,
                connectionArguments: arguments,
                command: command,
                timeout: processTimeout,
                retryPolicy: .idempotent
            )
        }
        self.loginShellProvider = loginShellProvider
        self.localBinaryPath = localBinaryPath
        self.remoteBinaryRevision = remoteBinaryRevision
    }

    func load(from host: CommandHost) async throws -> KwtHostInventory {
        guard case .local = host else {
            let hostLabel = switch host {
            case .local: "this Mac"
            case let .ssh(info): info.displayName
            }
            throw KwtInventoryError.sshLeaseRequired(host: hostLabel)
        }
        return try await load(
            from: host,
            sshConnectionArguments: nil
        )
    }

    func load(
        from host: CommandHost,
        sshConnectionArguments: [String]
    ) async throws -> KwtHostInventory {
        try await load(
            from: host,
            sshConnectionArguments: Optional(sshConnectionArguments),
            sshConnection: nil
        )
    }

    func load(
        from host: CommandHost,
        sshConnection: KwtSSHConnection
    ) async throws -> KwtHostInventory {
        try await load(
            from: host,
            sshConnectionArguments: sshConnection.arguments,
            sshConnection: sshConnection
        )
    }

    private func load(
        from host: CommandHost,
        sshConnectionArguments: [String]?,
        sshConnection: KwtSSHConnection? = nil
    ) async throws -> KwtHostInventory {
        if case .ssh = host {
            try Task.checkCancellation()
        }
        let hostLabel = switch host {
        case .local: "this Mac"
        case let .ssh(info): info.displayName
        }
        let windowsKwtRelativePath =
            KwtBinaryLocator.windowsRemoteManagedRelativePath(
                revision: remoteBinaryRevision
            )
        let hostPlatform = platform(for: host)
        let prelude = binaryPrelude(for: host)
        let projectsResult = run(
            host: host,
            sshConnectionArguments: sshConnectionArguments,
            command: Self.projectsCommand(
                platform: hostPlatform,
                binaryPrelude: prelude,
                windowsKwtRelativePath: windowsKwtRelativePath
            )
        )
        if case .ssh = host {
            try Task.checkCancellation()
        }
        let directoriesResult = run(
            host: host,
            sshConnectionArguments: sshConnectionArguments,
            command: Self.directoryWorkspacesCommand(
                platform: hostPlatform,
                binaryPrelude: prelude,
                windowsKwtRelativePath: windowsKwtRelativePath
            )
        )
        if case .ssh = host {
            try Task.checkCancellation()
        }
        let topConnectionUnusable = [projectsResult, directoriesResult]
            .contains(where: Self.indicatesUnusableConnection)
        let projects: [KwtProjectRecord]
        let projectsWarning: String?
        let projectsError: Error?
        do {
            projects = try decode(
                projectsResult,
                hostLabel: hostLabel
            )
            projectsWarning = nil
            projectsError = nil
        } catch {
            projects = []
            projectsWarning = error.localizedDescription
            projectsError = error
        }
        let directoryWorkspaces: [KwtDirectoryWorkspaceRecord]
        let directoryWorkspaceWarning: String?
        do {
            directoryWorkspaces = try decode(
                directoriesResult,
                hostLabel: hostLabel
            )
            directoryWorkspaceWarning = nil
        } catch {
            directoryWorkspaces = []
            directoryWorkspaceWarning = error.localizedDescription
        }
        if let projectsError,
           directoryWorkspaceWarning != nil {
            if topConnectionUnusable {
                await sshConnection?.invalidate()
            }
            throw projectsError
        }

        let indexed: [(Int, KwtProjectInventory, Bool)]
        switch host {
        case .local:
            indexed = await withTaskGroup(
                of: (Int, KwtProjectInventory, Bool).self,
                returning: [(Int, KwtProjectInventory, Bool)].self
            ) { group in
                for (index, project) in projects.enumerated() {
                    group.addTask {
                        loadProject(
                            index: index,
                            project: project,
                            host: host,
                            sshConnectionArguments: sshConnectionArguments,
                            hostLabel: hostLabel,
                            windowsKwtRelativePath: windowsKwtRelativePath
                        )
                    }
                }
                var values: [(Int, KwtProjectInventory, Bool)] = []
                for await value in group {
                    values.append(value)
                }
                return values
            }
        case .ssh:
            var values: [(Int, KwtProjectInventory, Bool)] = []
            for (index, project) in projects.enumerated() {
                try Task.checkCancellation()
                let value = loadProject(
                    index: index,
                    project: project,
                    host: host,
                    sshConnectionArguments: sshConnectionArguments,
                    hostLabel: hostLabel,
                    windowsKwtRelativePath: windowsKwtRelativePath
                )
                if value.2 {
                    await sshConnection?.invalidate()
                    try Task.checkCancellation()
                    throw KwtInventoryError.commandFailed(
                        host: hostLabel,
                        status: 255
                    )
                }
                try Task.checkCancellation()
                values.append(value)
            }
            indexed = values
        }
        if topConnectionUnusable || indexed.contains(where: { $0.2 }) {
            await sshConnection?.invalidate()
        }
        return KwtHostInventory(
            projects: indexed.sorted { $0.0 < $1.0 }.map(\.1),
            projectsWarning: projectsWarning,
            directoryWorkspaces: directoryWorkspaces,
            directoryWorkspaceWarning: directoryWorkspaceWarning
        )
    }

    private func loadProject(
        index: Int,
        project: KwtProjectRecord,
        host: CommandHost,
        sshConnectionArguments: [String]?,
        hostLabel: String,
        windowsKwtRelativePath: String?
    ) -> (Int, KwtProjectInventory, Bool) {
        let result = run(
            host: host,
            sshConnectionArguments: sshConnectionArguments,
            command: Self.worktreesCommand(
                projectPath: project.path,
                platform: platform(for: host),
                binaryPrelude: binaryPrelude(for: host),
                windowsKwtRelativePath: windowsKwtRelativePath
            )
        )
        do {
            let worktrees: [KwtWorktreeRecord] = try decode(
                result,
                hostLabel: hostLabel
            )
            return (
                index,
                KwtProjectInventory(
                    project: project,
                    worktrees: worktrees,
                    warning: nil
                ),
                Self.indicatesUnusableConnection(result)
            )
        } catch {
            return (
                index,
                KwtProjectInventory(
                    project: project,
                    worktrees: [],
                    warning: error.localizedDescription
                ),
                Self.indicatesUnusableConnection(result)
            )
        }
    }

    private func binaryPrelude(for host: CommandHost) -> String {
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
        for host: CommandHost
    ) -> SSHHostInfo.Platform {
        switch host {
        case .local: .posix
        case let .ssh(info): info.platform
        }
    }

    private func run(
        host: CommandHost,
        sshConnectionArguments: [String]?,
        command: String
    ) -> AccountCommandOutput {
        switch host {
        case .local:
            let result = localRunner(loginShellProvider(), command)
            return AccountCommandOutput(
                status: result.status,
                stdout: result.stdout,
                stderr: ""
            )
        case let .ssh(info):
            guard let sshConnectionArguments else {
                preconditionFailure("remote inventory requires an SSH lease")
            }
            return remoteRunner(info, sshConnectionArguments, command)
        }
    }

    private func decode<Value: Decodable>(
        _ result: AccountCommandOutput,
        hostLabel: String
    ) throws -> Value {
        guard result.status == 0 else {
            throw KwtInventoryError.commandFailed(
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
            throw KwtInventoryError.malformedOutput(host: hostLabel)
        }
        let json = normalizedOutput[markerRange.upperBound...]
        do {
            return try JSONDecoder().decode(
                Value.self,
                from: Data(json.utf8)
            )
        } catch {
            throw KwtInventoryError.malformedOutput(host: hostLabel)
        }
    }

    private static func indicatesUnusableConnection(
        _ result: AccountCommandOutput
    ) -> Bool {
        SSHConnectionFailure.indicatesUnusableConnection(
            status: result.status,
            output: result.stderr
        )
    }

    private static func projectsCommand(
        platform: SSHHostInfo.Platform,
        binaryPrelude: String,
        windowsKwtRelativePath: String?
    ) -> String {
        if platform == .windows {
            return KwtPowerShellCommand.run(
                arguments: ["projects", "--json"],
                marker: "GHOSTHUB_KWT_JSON",
                managedRelativePath: windowsKwtRelativePath
            )
        }
        return binaryPrelude
            + "printf 'GHOSTHUB_KWT_JSON\\n'; "
            + "exec \"$ghosthub_kwt_path\" projects --json"
    }

    private static func worktreesCommand(
        projectPath: String,
        platform: SSHHostInfo.Platform,
        binaryPrelude: String,
        windowsKwtRelativePath: String?
    ) -> String {
        if platform == .windows {
            return KwtPowerShellCommand.run(
                arguments: ["list", "--json"],
                workingDirectory: projectPath,
                marker: "GHOSTHUB_KWT_JSON",
                managedRelativePath: windowsKwtRelativePath
            )
        }
        return binaryPrelude
            + "cd -- \(shellQuotedCommandArgument(projectPath)) || exit $?; "
            + "printf 'GHOSTHUB_KWT_JSON\\n'; "
            + "exec \"$ghosthub_kwt_path\" list --json"
    }

    private static func directoryWorkspacesCommand(
        platform: SSHHostInfo.Platform,
        binaryPrelude: String,
        windowsKwtRelativePath: String?
    ) -> String {
        if platform == .windows {
            return KwtPowerShellCommand.run(
                arguments: ["workspace", "list", "--json"],
                marker: "GHOSTHUB_KWT_JSON",
                managedRelativePath: windowsKwtRelativePath
            )
        }
        return binaryPrelude
            + "printf 'GHOSTHUB_KWT_JSON\\n'; "
            + "exec \"$ghosthub_kwt_path\" workspace list --json"
    }
}

enum KwtSnapshotMerger {
    private struct WorktreePathKey: Hashable {
        let projectID: UUID
        let path: String
    }

    static func merge(
        _ inventory: KwtHostInventory,
        hostID: UUID,
        into snapshot: WorkspaceSnapshot,
        normalizePath: (String) -> String = normalizedPath
    ) -> WorkspaceSnapshot {
        var updated = snapshot
        let existingProjects = snapshot.projects.filter { $0.hostID == hostID }
        let existingWorktrees = snapshot.worktrees.filter { $0.hostID == hostID }
        let existingProjectsByRepository = Dictionary(
            grouping: existingProjects.filter { !$0.scopedKey.isEmpty },
            by: \.scopedKey
        )
        let existingProjectsByPath = Dictionary(
            grouping: existingProjects,
            by: { normalizePath($0.rootPath) }
        )
        let existingWorktreesByProject = Dictionary(
            grouping: existingWorktrees,
            by: \.projectID
        )
        let existingWorktreesByProjectAndPath = Dictionary(
            grouping: existingWorktrees,
            by: {
                WorktreePathKey(
                    projectID: $0.projectID,
                    path: normalizePath($0.path)
                )
            }
        )
        var projects: [ProjectSummary] = []
        var worktrees: [WorktreeSummary] = []
        if inventory.projectsWarning != nil,
           inventory.projects.isEmpty {
            projects = existingProjects.map { existing in
                var retained = existing
                retained.isStale = false
                return retained
            }
            worktrees = existingWorktrees.map { existing in
                var retained = existing
                retained.isStale = false
                return retained
            }
        }
        let existingDirectoryWorkspaces = snapshot.directoryWorkspaces.filter {
            $0.hostID == hostID
        }
        let existingDirectoryWorkspacesByPath = Dictionary(
            existingDirectoryWorkspaces.map {
                (normalizePath($0.path), $0)
            },
            uniquingKeysWith: { first, _ in first }
        )
        let directoryRecords = inventory.directoryWorkspaceWarning != nil
            && inventory.directoryWorkspaces.isEmpty
            ? existingDirectoryWorkspaces.map {
                KwtDirectoryWorkspaceRecord(
                    name: $0.name,
                    path: $0.path,
                    sessionName: $0.tmuxSessionName,
                    sessionLive: $0.sessionLive,
                    tmuxSocketName: $0.tmuxSocketName,
                    tmuxAttachMode: $0.tmuxAttachMode
                )
            }
            : inventory.directoryWorkspaces
        let directoryWorkspaces = directoryRecords.map { record in
            let recordPath = normalizePath(record.path)
            let existing = existingDirectoryWorkspacesByPath[recordPath]
            var workspace = existing ?? DirectoryWorkspaceSummary(
                id: stableID(
                    "directory-workspace|\(hostID.uuidString)"
                        + "|\(recordPath)"
                ),
                hostID: hostID,
                name: record.name,
                path: record.path,
                tmuxSessionName: record.sessionName,
                tmuxSocketName: record.tmuxSocketName,
                tmuxAttachMode: record.tmuxAttachMode,
                sessionLive: record.sessionLive
            )
            workspace.hostID = hostID
            workspace.name = record.name
            workspace.path = record.path
            workspace.tmuxSessionName = record.sessionName
            workspace.tmuxSocketName = record.tmuxSocketName
            workspace.tmuxAttachMode = record.tmuxAttachMode
            workspace.sessionLive = record.sessionLive
            return workspace
        }

        let inventoryRepositories = Set(
            inventory.projects.map(\.project.repository)
        )
        var reconciledProjectIDs = Set<UUID>()
        for item in inventory.projects {
            let record = item.project
            let recordPath = normalizePath(record.path)
            let repositoryMatch = record.repository.isEmpty
                ? nil
                : existingProjectsByRepository[record.repository]?.first {
                    !reconciledProjectIDs.contains($0.id)
                }
            // Repository identity survives a move. Path is only a legacy
            // fallback for transitional records or when it does not belong to
            // a different repository, and an existing runtime ID can be
            // consumed at most once.
            let existingProject = repositoryMatch
                ?? existingProjectsByPath[recordPath]?.first { candidate in
                    ((candidate.registryID != nil
                            && !inventoryRepositories.contains(
                                candidate.scopedKey
                            ))
                        || candidate.scopedKey.isEmpty
                        || candidate.scopedKey == record.repository)
                        && !reconciledProjectIDs.contains(candidate.id)
                }
            let projectID = existingProject?.id ?? stableID(
                "project|\(hostID.uuidString)|\(record.repository)|\(record.path)"
            )
            reconciledProjectIDs.insert(projectID)
            var project = existingProject ?? ProjectSummary(
                id: projectID,
                hostID: hostID,
                scopedKey: record.repository,
                name: record.name,
                rootPath: record.path
            )
            project.hostID = hostID
            project.scopedKey = record.repository
            project.registryID = nil
            project.name = record.name
            project.rootPath = record.path
            project.registrationFingerprint = record.registrationFingerprint
            project.isStale = false
            project.kind = .repository
            project.isSynthesized = false
            projects.append(project)

            if item.warning != nil, item.worktrees.isEmpty {
                worktrees.append(
                    contentsOf: (existingProject.flatMap {
                        existingWorktreesByProject[$0.id]
                    } ?? []).map { existing in
                        var retained = existing
                        retained.hostID = hostID
                        retained.projectID = projectID
                        retained.isStale = false
                        return retained
                    }
                )
                continue
            }

            for record in item.worktrees {
                let recordPath = normalizePath(record.path)
                let existing = existingWorktreesByProjectAndPath[
                    WorktreePathKey(
                        projectID: projectID,
                        path: recordPath
                    )
                ]?.first
                let consistentExisting = existing.flatMap { candidate in
                    candidate.branch == record.branch
                        && candidate.isPrimary == record.isMain
                        && candidate.tmuxSessionName == record.sessionName
                        ? candidate : nil
                }
                let worktreeID = existing?.id ?? stableID(
                    "worktree|\(hostID.uuidString)|\(record.repository)|\(record.path)"
                )
                var worktree = existing ?? WorktreeSummary(
                    id: worktreeID,
                    hostID: hostID,
                    projectID: projectID,
                    scopedKey: record.path,
                    name: record.branch,
                    path: record.path,
                    branch: record.branch
                )
                worktree.hostID = hostID
                worktree.projectID = projectID
                worktree.scopedKey = record.path
                worktree.registryID = nil
                worktree.name = record.branch
                worktree.path = record.path
                worktree.branch = record.branch
                worktree.isPrimary = record.isMain
                worktree.isStale = false
                worktree.createdAt = record.createdAt
                worktree.generation = record.generation
                    ?? WorktreeGeneration.canonical(
                        consistentExisting?.generation
                    )
                worktree.tmuxSessionName = record.sessionName
                worktree.tmuxSocketName = record.tmuxSocketName
                worktree.tmuxAttachMode = record.tmuxAttachMode
                worktree.sessionBackend = snapshot.host(id: hostID)?.kind == .remote
                    ? .remoteTmux : .localTmux
                worktrees.append(worktree)
            }
        }

        let removedWorktreeIDs = Set(existingWorktrees.map(\.id))
            .subtracting(worktrees.map(\.id))
        updated.projects.removeAll { $0.hostID == hostID }
        updated.projects.append(contentsOf: projects)
        updated.worktrees.removeAll { $0.hostID == hostID }
        updated.worktrees.append(contentsOf: worktrees)
        updated.directoryWorkspaces.removeAll { $0.hostID == hostID }
        updated.directoryWorkspaces.append(contentsOf: directoryWorkspaces)
        updated.sessions.removeAll {
            $0.hostID == hostID
                && $0.worktreeID.map(removedWorktreeIDs.contains) == true
        }
        return updated
    }

    private static func normalizedPath(_ path: String) -> String {
        guard path.contains("/") else { return path }
        let isAbsolute = path.hasPrefix("/")
        var components: [Substring] = []
        for component in path.split(separator: "/") {
            switch component {
            case ".":
                continue
            case "..":
                if components.last.map({ $0 != ".." }) == true {
                    components.removeLast()
                } else if !isAbsolute {
                    components.append(component)
                }
            default:
                components.append(component)
            }
        }
        let normalized = components.joined(separator: "/")
        if isAbsolute {
            return normalized.isEmpty ? "/" : "/\(normalized)"
        }
        return normalized.isEmpty ? "." : normalized
    }

    private static func stableID(_ material: String) -> UUID {
        var bytes = Array(SHA256.hash(data: Data(material.utf8)).prefix(16))
        bytes[6] = (bytes[6] & 0x0f) | 0x50
        bytes[8] = (bytes[8] & 0x3f) | 0x80
        return UUID(uuid: (
            bytes[0], bytes[1], bytes[2], bytes[3],
            bytes[4], bytes[5], bytes[6], bytes[7],
            bytes[8], bytes[9], bytes[10], bytes[11],
            bytes[12], bytes[13], bytes[14], bytes[15]
        ))
    }
}

enum HostInventoryOverlay {
    static func apply(
        kwtInventoriesByHost: [UUID: KwtHostInventory],
        kwtAvailabilityByHost: [UUID: Bool] = [:],
        tmuxSessionsByHost: [UUID: [TmuxSessionSummary]],
        herdrSessionsByHost: [UUID: [HerdrSessionSummary]] = [:],
        zellijSessionsByHost: [UUID: [ZellijSessionSummary]] = [:],
        herdrAvailabilityByHost: [UUID: Bool] = [:],
        zellijAvailabilityByHost: [UUID: Bool] = [:],
        tmuxReachabilityByHost: [UUID: Bool] = [:],
        tmuxLastSeenByHost: [UUID: Date] = [:],
        tmuxAuthoritativeHostIDs: Set<UUID> = [],
        to source: WorkspaceSnapshot
    ) -> WorkspaceSnapshot {
        let updated = kwtInventoriesByHost.reduce(source) { partial, entry in
            KwtSnapshotMerger.merge(
                entry.value,
                hostID: entry.key,
                into: partial
            )
        }
        return applyHostState(
            kwtAvailabilityByHost: kwtAvailabilityByHost,
            tmuxSessionsByHost: tmuxSessionsByHost,
            herdrSessionsByHost: herdrSessionsByHost,
            zellijSessionsByHost: zellijSessionsByHost,
            herdrAvailabilityByHost: herdrAvailabilityByHost,
            zellijAvailabilityByHost: zellijAvailabilityByHost,
            tmuxReachabilityByHost: tmuxReachabilityByHost,
            tmuxLastSeenByHost: tmuxLastSeenByHost,
            tmuxAuthoritativeHostIDs: tmuxAuthoritativeHostIDs,
            to: updated
        )
    }

    static func applyRuntimeSessions(
        tmuxSessionsByHost: [UUID: [TmuxSessionSummary]],
        herdrSessionsByHost: [UUID: [HerdrSessionSummary]] = [:],
        zellijSessionsByHost: [UUID: [ZellijSessionSummary]] = [:],
        herdrAvailabilityByHost: [UUID: Bool] = [:],
        zellijAvailabilityByHost: [UUID: Bool] = [:],
        tmuxReachabilityByHost: [UUID: Bool] = [:],
        tmuxLastSeenByHost: [UUID: Date] = [:],
        tmuxAuthoritativeHostIDs: Set<UUID> = [],
        to source: WorkspaceSnapshot
    ) -> WorkspaceSnapshot {
        applyHostState(
            kwtAvailabilityByHost: [:],
            tmuxSessionsByHost: tmuxSessionsByHost,
            herdrSessionsByHost: herdrSessionsByHost,
            zellijSessionsByHost: zellijSessionsByHost,
            herdrAvailabilityByHost: herdrAvailabilityByHost,
            zellijAvailabilityByHost: zellijAvailabilityByHost,
            tmuxReachabilityByHost: tmuxReachabilityByHost,
            tmuxLastSeenByHost: tmuxLastSeenByHost,
            tmuxAuthoritativeHostIDs: tmuxAuthoritativeHostIDs,
            to: source
        )
    }

    private static func applyHostState(
        kwtAvailabilityByHost: [UUID: Bool],
        tmuxSessionsByHost: [UUID: [TmuxSessionSummary]],
        herdrSessionsByHost: [UUID: [HerdrSessionSummary]],
        zellijSessionsByHost: [UUID: [ZellijSessionSummary]],
        herdrAvailabilityByHost: [UUID: Bool],
        zellijAvailabilityByHost: [UUID: Bool],
        tmuxReachabilityByHost: [UUID: Bool],
        tmuxLastSeenByHost: [UUID: Date],
        tmuxAuthoritativeHostIDs: Set<UUID>,
        to source: WorkspaceSnapshot
    ) -> WorkspaceSnapshot {
        var updated = source
        for (hostID, sessions) in tmuxSessionsByHost {
            guard let index = updated.hosts.firstIndex(where: {
                $0.id == hostID
            }) else { continue }
            updated.hosts[index].tmuxSessions = sessions
        }
        for (hostID, sessions) in herdrSessionsByHost {
            guard let index = updated.hosts.firstIndex(where: {
                $0.id == hostID
            }) else { continue }
            updated.hosts[index].herdrSessions = sessions
        }
        for (hostID, sessions) in zellijSessionsByHost {
            guard let index = updated.hosts.firstIndex(where: {
                $0.id == hostID
            }) else { continue }
            updated.hosts[index].zellijSessions = sessions
        }
        for (hostID, isAvailable) in herdrAvailabilityByHost {
            guard let index = updated.hosts.firstIndex(where: {
                $0.id == hostID
            }) else { continue }
            updated.hosts[index].herdrAvailable = isAvailable
        }
        for (hostID, isAvailable) in zellijAvailabilityByHost {
            guard let index = updated.hosts.firstIndex(where: {
                $0.id == hostID
            }) else { continue }
            updated.hosts[index].zellijAvailable = isAvailable
        }
        for (hostID, isAvailable) in kwtAvailabilityByHost {
            guard let index = updated.hosts.firstIndex(where: {
                $0.id == hostID
            }) else { continue }
            updated.hosts[index].remoteDiagnostics.removeAll {
                $0.code == .missingKwt
            }
            if !isAvailable,
               updated.hosts[index].platform == .windows {
                updated.hosts[index].remoteDiagnostics.append(
                    .missingKwtCapability
                )
            }
        }
        let tmuxStateHostIDs = Set(tmuxSessionsByHost.keys)
            .union(tmuxReachabilityByHost.keys)
            .union(tmuxAuthoritativeHostIDs)
        for hostID in tmuxStateHostIDs {
            guard let index = updated.hosts.firstIndex(where: {
                $0.id == hostID
            }) else { continue }
            updated.hosts[index].tmuxInventoryIsAuthoritative =
                tmuxAuthoritativeHostIDs.contains(hostID)
        }
        for (hostID, isReachable) in tmuxReachabilityByHost {
            guard let index = updated.hosts.firstIndex(where: {
                $0.id == hostID
            }) else { continue }
            updated.hosts[index].lastKnownReachable = isReachable
            guard updated.hosts[index].kind == .remote else { continue }
            updated.hosts[index].remoteDiagnostics.removeAll {
                $0.code == .probeFailure
            }
            if !isReachable {
                updated.hosts[index].remoteDiagnostics.append(
                    .tmuxDiscoveryUnavailable
                )
            }
        }
        for (hostID, reachedAt) in tmuxLastSeenByHost {
            guard let index = updated.hosts.firstIndex(where: {
                $0.id == hostID
            }) else { continue }
            if updated.hosts[index].lastSeenAt.map({ $0 < reachedAt }) ?? true {
                updated.hosts[index].lastSeenAt = reachedAt
            }
        }
        return updated
    }
}
