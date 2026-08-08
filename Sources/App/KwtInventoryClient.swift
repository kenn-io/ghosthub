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

struct KwtProjectRecord: Codable, Equatable, Sendable {
    var repository: String
    var name: String
    var path: String
    var lastTouched: String?

    private enum CodingKeys: String, CodingKey {
        case repository, name, path
        case lastTouched = "last_touched"
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

    private enum CodingKeys: String, CodingKey {
        case path, branch, repository
        case commitHash = "commit_hash"
        case isMain = "is_main"
        case createdAt = "created_at"
        case generation
        case sessionName = "session_name"
        case tmuxSocketName = "tmux_socket_name"
    }
}

struct KwtDirectoryWorkspaceRecord: Codable, Equatable, Sendable {
    var name: String
    var path: String
    var sessionName: String
    var sessionLive: Bool

    private enum CodingKeys: String, CodingKey {
        case name, path
        case sessionName = "session_name"
        case sessionLive = "session_live"
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
        excludingWorktrees: Set<KwtWorktreeIdentity> = []
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
                   item.worktrees.isEmpty,
                   let prior = previous?.projects.first(where: {
                       $0.project.repository == item.project.repository
                           || $0.project.path == item.project.path
                   }) {
                    retained.worktrees = prior.worktrees
                }
                retained.worktrees.removeAll { worktree in
                    excludingWorktrees.contains {
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
        _ host: SSHHostInfo, _ command: String
    ) -> (status: Int32, stdout: String)

    private static let jsonMarker = "GHOSTHUB_KWT_JSON\n"
    private let localRunner: LocalRunner
    private let remoteRunner: RemoteRunner
    private let loginShellProvider: @Sendable () -> String
    private let localBinaryPath: String?
    private let remoteBinaryRevision: String?

    init(
        localRunner: LocalRunner? = nil,
        remoteRunner: RemoteRunner? = nil,
        processTimeout: TimeInterval = 15,
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
        self.remoteRunner = remoteRunner ?? { host, command in
            AccountCommandRunner.runRemoteLoginShell(
                host: host,
                command: command,
                timeout: processTimeout
            )
        }
        self.loginShellProvider = loginShellProvider
        self.localBinaryPath = localBinaryPath
        self.remoteBinaryRevision = remoteBinaryRevision
    }

    func load(from host: CommandHost) async throws -> KwtHostInventory {
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
            command: Self.projectsCommand(
                platform: hostPlatform,
                binaryPrelude: prelude,
                windowsKwtRelativePath: windowsKwtRelativePath
            )
        )
        let directoriesResult = run(
            host: host,
            command: Self.directoryWorkspacesCommand(
                platform: hostPlatform,
                binaryPrelude: prelude,
                windowsKwtRelativePath: windowsKwtRelativePath
            )
        )
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
            throw projectsError
        }

        let indexed = await withTaskGroup(
            of: (Int, KwtProjectInventory).self,
            returning: [(Int, KwtProjectInventory)].self
        ) { group in
            for (index, project) in projects.enumerated() {
                group.addTask {
                    let result = run(
                        host: host,
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
                            )
                        )
                    } catch {
                        return (
                            index,
                            KwtProjectInventory(
                                project: project,
                                worktrees: [],
                                warning: error.localizedDescription
                            )
                        )
                    }
                }
            }
            var values: [(Int, KwtProjectInventory)] = []
            for await value in group {
                values.append(value)
            }
            return values
        }
        return KwtHostInventory(
            projects: indexed.sorted { $0.0 < $1.0 }.map(\.1),
            projectsWarning: projectsWarning,
            directoryWorkspaces: directoryWorkspaces,
            directoryWorkspaceWarning: directoryWorkspaceWarning
        )
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
        command: String
    ) -> (status: Int32, stdout: String) {
        switch host {
        case .local:
            return localRunner(loginShellProvider(), command)
        case let .ssh(info):
            return remoteRunner(info, command)
        }
    }

    private func decode<Value: Decodable>(
        _ result: (status: Int32, stdout: String),
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
    static func merge(
        _ inventory: KwtHostInventory,
        hostID: UUID,
        into snapshot: WorkspaceSnapshot
    ) -> WorkspaceSnapshot {
        var updated = snapshot
        let existingProjects = snapshot.projects.filter { $0.hostID == hostID }
        let existingWorktrees = snapshot.worktrees.filter { $0.hostID == hostID }
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
        let directoryRecords = inventory.directoryWorkspaceWarning != nil
            && inventory.directoryWorkspaces.isEmpty
            ? existingDirectoryWorkspaces.map {
                KwtDirectoryWorkspaceRecord(
                    name: $0.name,
                    path: $0.path,
                    sessionName: $0.tmuxSessionName,
                    sessionLive: $0.sessionLive
                )
            }
            : inventory.directoryWorkspaces
        let directoryWorkspaces = directoryRecords.map { record in
            let existing = existingDirectoryWorkspaces.first {
                normalizedPath($0.path) == normalizedPath(record.path)
            }
            var workspace = existing ?? DirectoryWorkspaceSummary(
                id: stableID(
                    "directory-workspace|\(hostID.uuidString)"
                        + "|\(normalizedPath(record.path))"
                ),
                hostID: hostID,
                name: record.name,
                path: record.path,
                tmuxSessionName: record.sessionName,
                sessionLive: record.sessionLive
            )
            workspace.hostID = hostID
            workspace.name = record.name
            workspace.path = record.path
            workspace.tmuxSessionName = record.sessionName
            workspace.sessionLive = record.sessionLive
            return workspace
        }

        for item in inventory.projects {
            let record = item.project
            let existingProject = existingProjects.first {
                normalizedPath($0.rootPath) == normalizedPath(record.path)
                    || (!$0.scopedKey.isEmpty
                        && $0.scopedKey == record.repository)
            }
            let projectID = existingProject?.id ?? stableID(
                "project|\(hostID.uuidString)|\(record.repository)|\(record.path)"
            )
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
            project.isStale = false
            project.kind = .repository
            project.isSynthesized = false
            projects.append(project)

            if item.warning != nil, item.worktrees.isEmpty {
                worktrees.append(
                    contentsOf: existingWorktrees.filter {
                        $0.projectID == existingProject?.id
                    }.map { existing in
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
                let existing = existingWorktrees.first {
                    normalizedPath($0.path) == normalizedPath(record.path)
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
                worktree.tmuxSessionName = record.sessionName
                // The protected socket is a fail-closed marker: it keeps
                // contributor-authored terminal configuration out of the app
                // config and routes attachment through kwt's protected
                // command. A refresh that omits it is never evidence that the
                // workspace stopped being protected, so it cannot clear it.
                // Deleting the workspace drops the record entirely, which is
                // how a protected marker is actually retired.
                worktree.tmuxSocketName = record.tmuxSocketName
                    ?? existing?.tmuxSocketName
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
        URL(fileURLWithPath: path).standardizedFileURL.path
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
        herdrAvailabilityByHost: [UUID: Bool] = [:],
        tmuxReachabilityByHost: [UUID: Bool] = [:],
        tmuxLastSeenByHost: [UUID: Date] = [:],
        to source: WorkspaceSnapshot
    ) -> WorkspaceSnapshot {
        var updated = kwtInventoriesByHost.reduce(source) { partial, entry in
            KwtSnapshotMerger.merge(
                entry.value,
                hostID: entry.key,
                into: partial
            )
        }
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
        for (hostID, isAvailable) in herdrAvailabilityByHost {
            guard let index = updated.hosts.firstIndex(where: {
                $0.id == hostID
            }) else { continue }
            updated.hosts[index].herdrAvailable = isAvailable
        }
        for (hostID, isAvailable) in kwtAvailabilityByHost {
            guard let index = updated.hosts.firstIndex(where: {
                $0.id == hostID
            }) else { continue }
            updated.hosts[index].remoteDiagnostics.removeAll {
                $0.code == .missingKwt
            }
            if !isAvailable {
                updated.hosts[index].remoteDiagnostics.append(
                    .missingKwtCapability
                )
            }
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
