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
    var repository: String
    var sessionName: String

    private enum CodingKeys: String, CodingKey {
        case path, branch, repository
        case commitHash = "commit_hash"
        case isMain = "is_main"
        case createdAt = "created_at"
        case sessionName = "session_name"
    }
}

struct KwtProjectInventory: Equatable, Sendable {
    var project: KwtProjectRecord
    var worktrees: [KwtWorktreeRecord]
    var warning: String?
}

struct KwtHostInventory: Equatable, Sendable {
    var projects: [KwtProjectInventory]

    func retainingFailedProjectWorktrees(
        from previous: KwtHostInventory?
    ) -> KwtHostInventory {
        guard let previous else { return self }
        return KwtHostInventory(projects: projects.map { item in
            guard item.warning != nil,
                  item.worktrees.isEmpty,
                  let prior = previous.projects.first(where: {
                      $0.project.repository == item.project.repository
                          || $0.project.path == item.project.path
                  })
            else { return item }
            var retained = item
            retained.worktrees = prior.worktrees
            return retained
        })
    }
}

enum KwtInventoryError: Error, Equatable, LocalizedError {
    case commandFailed(host: String, status: Int32)
    case malformedOutput(host: String)

    var errorDescription: String? {
        switch self {
        case let .commandFailed(host, status):
            return "kwt inventory failed on \(host) with status \(status)."
        case let .malformedOutput(host):
            return "kwt returned an invalid inventory on \(host)."
        }
    }
}

/// Reads kwt's supported machine-readable surfaces without interpreting its
/// configuration files. Project order follows `kwt projects --json`; each
/// project is then asked for its own authoritative worktree/session list.
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

    init(
        localRunner: LocalRunner? = nil,
        remoteRunner: RemoteRunner? = nil,
        processTimeout: TimeInterval = 15,
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

    func load(from host: TmuxHost) async throws -> KwtHostInventory {
        let hostLabel = switch host {
        case .local: "this Mac"
        case let .ssh(info): info.displayName
        }
        let projects: [KwtProjectRecord] = try decode(
            run(
                host: host,
                command: Self.projectsCommand(
                    localBinaryPath: binaryPath(for: host)
                )
            ),
            hostLabel: hostLabel
        )

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
                            localBinaryPath: binaryPath(for: host)
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
            projects: indexed.sorted { $0.0 < $1.0 }.map(\.1)
        )
    }

    private func binaryPath(for host: TmuxHost) -> String? {
        switch host {
        case .local: localBinaryPath
        case .ssh: nil
        }
    }

    private func run(
        host: TmuxHost,
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
        guard let markerRange = result.stdout.range(
            of: Self.jsonMarker,
            options: .backwards
        ) else {
            throw KwtInventoryError.malformedOutput(host: hostLabel)
        }
        let json = result.stdout[markerRange.upperBound...]
        do {
            return try JSONDecoder().decode(
                Value.self,
                from: Data(json.utf8)
            )
        } catch {
            throw KwtInventoryError.malformedOutput(host: hostLabel)
        }
    }

    private static func projectsCommand(localBinaryPath: String?) -> String {
        KwtBinaryLocator.commandPrelude(exactPath: localBinaryPath)
            + "printf 'GHOSTHUB_KWT_JSON\\n'; "
            + "exec \"$ghosthub_kwt_path\" projects --json"
    }

    private static func worktreesCommand(
        projectPath: String,
        localBinaryPath: String?
    ) -> String {
        KwtBinaryLocator.commandPrelude(exactPath: localBinaryPath)
            + "cd -- \(shellQuotedCommandArgument(projectPath)) || exit $?; "
            + "printf 'GHOSTHUB_KWT_JSON\\n'; "
            + "exec \"$ghosthub_kwt_path\" list --json"
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
                worktree.tmuxSessionName = record.sessionName
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
