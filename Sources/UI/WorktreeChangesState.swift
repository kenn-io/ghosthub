import Combine
import Foundation
import GhosthubWorkspace

public struct WorktreeChangesIdentity: Hashable, Sendable {
    public let worktreeID: UUID
    public let hostID: UUID
    public let hostRouteKey: String
    public let projectID: UUID
    public let registrationFingerprint: String
    public let repository: String
    public let path: String
    public let generation: String
    public let usesWindowsPaths: Bool

    public static func resolve(
        worktreeID: UUID,
        in snapshot: WorkspaceSnapshot
    ) -> Self? {
        guard let worktree = snapshot.worktree(id: worktreeID) else {
            return nil
        }
        return resolve(
            worktree: worktree,
            host: snapshot.host(id: worktree.hostID),
            project: snapshot.project(id: worktree.projectID)
        )
    }

    static func resolve(
        worktree: WorktreeSummary,
        host: HostSummary?,
        project: ProjectSummary?
    ) -> Self? {
        guard !worktree.isStale,
              let host,
              let project,
              project.hostID == host.id,
              !project.isStale,
              !project.scopedKey.isEmpty,
              let generation = canonicalGeneration(
                  worktree.generation
              ),
              isAbsolutePath(
                  worktree.path,
                  usesWindowsPaths: host.platform == .windows
              ),
              let hostRouteKey = hostRouteKey(for: host)
        else { return nil }
        return Self(
            worktreeID: worktree.id,
            hostID: host.id,
            hostRouteKey: hostRouteKey,
            projectID: project.id,
            registrationFingerprint: project.registrationFingerprint,
            repository: project.scopedKey,
            path: WorktreeChangePath.key(
                worktree.path, usesWindowsPaths: host.platform == .windows
            ),
            generation: generation,
            usesWindowsPaths: host.platform == .windows
        )
    }

    public func matches(
        result: WorktreeFileChanges,
        in snapshot: WorkspaceSnapshot
    ) -> Bool {
        guard Self.resolve(worktreeID: worktreeID, in: snapshot) == self
        else { return false }
        return result.repository == repository
            && WorktreeChangePath.matches(
                result.path,
                path,
                usesWindowsPaths: usesWindowsPaths
            )
            && result.generation == generation
    }

    private static func isAbsolutePath(
        _ path: String,
        usesWindowsPaths: Bool
    ) -> Bool {
        if usesWindowsPaths {
            return path.range(
                of: #"^[A-Za-z]:[\\/]"#,
                options: .regularExpression
            ) != nil
        }
        return path.hasPrefix("/")
    }

    private static func canonicalGeneration(_ value: String?) -> String? {
        guard let value,
              value.range(
                  of: #"^[0-9a-f]{32}$"#,
                  options: .regularExpression
              ) != nil
        else { return nil }
        return value
    }

    private static func hostRouteKey(for host: HostSummary) -> String? {
        let platform = host.platform.rawValue
        guard host.kind == .remote else {
            return "local:\(platform)"
        }
        guard let destination = host.sshDestination?
            .trimmingCharacters(in: .whitespacesAndNewlines),
            !destination.isEmpty
        else { return nil }
        return "ssh:\(platform):\(destination)"
    }
}

public struct WorktreeChangesEntry: Equatable, Sendable {
    public var files: [WorktreeFileChange] = []
    public var hasSuccessfulValue = false
    public var isLoading = false
    public var errorMessage: String?
    public var isStale = false
    public var requiresManualRefresh = false
    public var requiresInventoryRefresh = false
    public var manualRefreshRevision: UInt64 = 0
    public var resumeRevision: UInt64 = 0

    public init() {}

    fileprivate func hasSameMetadata(
        as other: WorktreeChangesEntry
    ) -> Bool {
        hasSuccessfulValue == other.hasSuccessfulValue
            && isLoading == other.isLoading
            && errorMessage == other.errorMessage
            && isStale == other.isStale
            && requiresManualRefresh == other.requiresManualRefresh
            && requiresInventoryRefresh == other.requiresInventoryRefresh
            && manualRefreshRevision == other.manualRefreshRevision
            && resumeRevision == other.resumeRevision
    }
}

enum WorktreeChangesComparison {
    static func filesChanged(
        previous: [WorktreeFileChange],
        current: [WorktreeFileChange]
    ) async -> Bool {
        await Task.detached(priority: .utility) {
            previous != current
        }.value
    }
}

public typealias WorktreeChangesLoader = @Sendable (
    WorktreeSummary
) async throws -> WorktreeFileChanges
public typealias WorktreeChangesSleep = @Sendable (Duration) async throws -> Void

@MainActor
public final class WorktreeChangesStore: ObservableObject {
    private static let collapsedSnapshotLimit = 8

    @Published public private(set) var expandedWorktreeIDs: Set<UUID> = []
    @Published public private(set) var entries:
        [WorktreeChangesIdentity: WorktreeChangesEntry] = [:]
    private var activeRequestByWorktreeID: [UUID: UUID] = [:]
    private var restartAfterInFlight: Set<WorktreeChangesIdentity> = []
    private var manualRestartAfterInFlight: Set<WorktreeChangesIdentity> = []
    private var collapsedWorktreeIDs: [UUID] = []

    public init() {}

    public func isExpanded(_ worktreeID: UUID) -> Bool {
        expandedWorktreeIDs.contains(worktreeID)
    }

    public func setExpanded(_ expanded: Bool, worktreeID: UUID) {
        if expanded {
            expandedWorktreeIDs.insert(worktreeID)
            collapsedWorktreeIDs.removeAll { $0 == worktreeID }
        } else {
            expandedWorktreeIDs.remove(worktreeID)
            collapsedWorktreeIDs.removeAll { $0 == worktreeID }
            collapsedWorktreeIDs.append(worktreeID)
            while collapsedWorktreeIDs.count
                > Self.collapsedSnapshotLimit {
                let evictedID = collapsedWorktreeIDs.removeFirst()
                entries = entries.filter { $0.key.worktreeID != evictedID }
            }
        }
    }

    public func entry(for identity: WorktreeChangesIdentity) -> WorktreeChangesEntry {
        entries[identity] ?? WorktreeChangesEntry()
    }

    func successfulFiles(
        for identity: WorktreeChangesIdentity
    ) -> [WorktreeFileChange]? {
        guard let entry = entries[identity], entry.hasSuccessfulValue
        else { return nil }
        return entry.files
    }

    public func beginRequest(for identity: WorktreeChangesIdentity) -> UUID? {
        var entry = entry(for: identity)
        guard activeRequestByWorktreeID[identity.worktreeID] == nil else {
            return nil
        }
        let requestID = UUID()
        activeRequestByWorktreeID[identity.worktreeID] = requestID
        if !entry.hasSuccessfulValue {
            entry.isLoading = true
            entry.errorMessage = nil
            if entries[identity] != entry {
                entries[identity] = entry
            }
        }
        return requestID
    }

    public func requestRestartAfterInFlight(for identity: WorktreeChangesIdentity) {
        restartAfterInFlight.insert(identity)
    }

    public func finishRequest(
        _ requestID: UUID,
        for identity: WorktreeChangesIdentity,
        result: Result<WorktreeFileChanges, Error>,
        publishResult: Bool,
        filesChanged: Bool
    ) {
        guard activeRequestByWorktreeID[identity.worktreeID] == requestID
        else { return }
        activeRequestByWorktreeID.removeValue(
            forKey: identity.worktreeID
        )
        let waitingIdentities = restartAfterInFlight.filter {
            $0.worktreeID == identity.worktreeID
        }
        if let existingEntry = entries[identity] {
            var completedEntry = existingEntry
            var publishesFiles = false
            completedEntry.isLoading = existingEntry.isLoading
                && !waitingIdentities.isEmpty
            if publishResult {
                switch result {
                case let .success(value):
                    if filesChanged {
                        completedEntry.files = value.files
                        publishesFiles = true
                    }
                    completedEntry.hasSuccessfulValue = true
                    completedEntry.errorMessage = nil
                    completedEntry.isStale = false
                    completedEntry.requiresManualRefresh = false
                    completedEntry.requiresInventoryRefresh = false
                case let .failure(error):
                    completedEntry.errorMessage = error.localizedDescription
                    completedEntry.isStale = completedEntry.hasSuccessfulValue
                    completedEntry.requiresInventoryRefresh = (
                        error as? any WorktreeChangesRetryClassifying
                    )?.requiresInventoryRefresh ?? false
                    if completedEntry.requiresInventoryRefresh {
                        completedEntry.isLoading = false
                    }
                    completedEntry.requiresManualRefresh = !(
                        (error as? any WorktreeChangesRetryClassifying)?
                            .isRetryable ?? true
                    )
                }
            }
            if publishesFiles
                || !existingEntry.hasSameMetadata(as: completedEntry) {
                entries[identity] = completedEntry
            }
        }
        for waitingIdentity in waitingIdentities {
            restartAfterInFlight.remove(waitingIdentity)
            var waitingEntry = entry(for: waitingIdentity)
            if manualRestartAfterInFlight.remove(waitingIdentity) != nil,
               !waitingEntry.requiresInventoryRefresh {
                waitingEntry.requiresManualRefresh = false
            }
            waitingEntry.resumeRevision &+= 1
            entries[waitingIdentity] = waitingEntry
        }
    }

    public func requestManualRefresh(
        for identity: WorktreeChangesIdentity,
        refreshInventory: () -> Void
    ) {
        var entry = entry(for: identity)
        guard !entry.requiresInventoryRefresh else {
            refreshInventory()
            return
        }
        entry.isLoading = true
        entry.requiresManualRefresh = false
        guard activeRequestByWorktreeID[identity.worktreeID] == nil else {
            entries[identity] = entry
            manualRestartAfterInFlight.insert(identity)
            requestRestartAfterInFlight(for: identity)
            return
        }
        entry.manualRefreshRevision &+= 1
        entries[identity] = entry
    }

    public func prune(keeping identities: Set<WorktreeChangesIdentity>) {
        let worktreeIDs = Set(identities.map(\.worktreeID))
        let retainedEntries = entries.filter {
            identities.contains($0.key)
        }
        if retainedEntries.count != entries.count {
            entries = retainedEntries
        }
        let retainedExpandedIDs = expandedWorktreeIDs.intersection(
            worktreeIDs
        )
        if retainedExpandedIDs != expandedWorktreeIDs {
            expandedWorktreeIDs = retainedExpandedIDs
        }
        activeRequestByWorktreeID = activeRequestByWorktreeID.filter {
            worktreeIDs.contains($0.key)
        }
        restartAfterInFlight.formIntersection(identities)
        manualRestartAfterInFlight.formIntersection(identities)
        collapsedWorktreeIDs.removeAll { !worktreeIDs.contains($0) }
    }
}

public enum WorktreeChangesPollingPolicy {
    public static let interval: Duration = .seconds(5)

    public static func retryDelay(
        after failureCount: Int,
        identity: WorktreeChangesIdentity
    ) -> Duration {
        let exponent = min(max(0, failureCount - 1), 3)
        let seconds = 5 * (1 << exponent)
        let scalarSum = identity.worktreeID.uuidString.unicodeScalars
            .reduce(0) { $0 + Int($1.value) }
        let jitterMilliseconds = 250 + scalarSum % 750
        return .seconds(seconds) + .milliseconds(jitterMilliseconds)
    }
}

public enum WorktreeChangesPollingEligibility {
    public static func isEligible(
        sidebarVisible: Bool,
        applicationActive: Bool,
        permitsBackgroundDemoControl: Bool
    ) -> Bool {
        sidebarVisible
            && (applicationActive || permitsBackgroundDemoControl)
    }
}

public enum WorktreeChangesPollLoop {
    @MainActor
    public static func run(
        identity: WorktreeChangesIdentity,
        worktree: WorktreeSummary,
        store: WorktreeChangesStore,
        currentSnapshot: @escaping @MainActor () -> WorkspaceSnapshot,
        isEligible: @escaping @MainActor () -> Bool,
        load: @escaping WorktreeChangesLoader,
        sleep: @escaping WorktreeChangesSleep
    ) async {
        var consecutiveFailureCount = 0
        while !Task.isCancelled,
              store.isExpanded(identity.worktreeID),
              !store.entry(for: identity).requiresManualRefresh,
              isEligible() {
            guard let requestID = store.beginRequest(for: identity) else {
                store.requestRestartAfterInFlight(for: identity)
                return
            }
            let previousFiles = store.successfulFiles(for: identity)
            let result: Result<WorktreeFileChanges, Error>
            let filesChanged: Bool
            do {
                let value = try await load(worktree)
                if let previousFiles {
                    filesChanged = await WorktreeChangesComparison.filesChanged(
                        previous: previousFiles,
                        current: value.files
                    )
                } else {
                    filesChanged = true
                }
                result = .success(value)
            } catch {
                result = .failure(error)
                filesChanged = false
            }
            let publishResult: Bool
            switch result {
            case let .success(value):
                publishResult = !Task.isCancelled
                    && store.isExpanded(identity.worktreeID)
                    && isEligible()
                    && identity.matches(
                        result: value,
                        in: currentSnapshot()
                    )
            case .failure:
                publishResult = !Task.isCancelled
                    && store.isExpanded(identity.worktreeID)
                    && isEligible()
                    && WorktreeChangesIdentity.resolve(
                        worktreeID: identity.worktreeID,
                        in: currentSnapshot()
                    ) == identity
            }
            store.finishRequest(
                requestID,
                for: identity,
                result: result,
                publishResult: publishResult,
                filesChanged: filesChanged
            )
            guard !Task.isCancelled, publishResult else { return }
            let delay: Duration
            switch result {
            case .success:
                consecutiveFailureCount = 0
                delay = WorktreeChangesPollingPolicy.interval
            case let .failure(error):
                let isRetryable = (
                    error as? any WorktreeChangesRetryClassifying
                )?.isRetryable ?? true
                guard isRetryable else { return }
                consecutiveFailureCount += 1
                delay = WorktreeChangesPollingPolicy.retryDelay(
                    after: consecutiveFailureCount,
                    identity: identity
                )
            }
            do {
                try await sleep(delay)
            } catch {
                return
            }
        }
    }
}
