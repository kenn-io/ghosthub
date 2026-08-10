@preconcurrency import Combine
import Foundation
import OSLog
import GhosthubPersistence
import GhosthubTerminal
import GhosthubWorkspace

enum ControlModeProcessRoot: Equatable {
    case local(pid_t)
    /// The surface is control-mode owned, but no process on this Mac can be
    /// sampled (an SSH pane, or a local pane whose metadata is still loading).
    case unavailable
}

/// Manages resource monitoring (CPU/memory sampling, agent session
/// state, process activity) and output flush / idle detection.
/// Extracted from WorkspaceSceneModel -- all WSM dependencies are
/// supplied via closures at init time.
@MainActor
final class ActivityMonitoringController: ObservableObject {
    private static let resourceLogger = Logger(
        subsystem: "com.ghosthub",
        category: "resources"
    )

    static let outputFlushIntervalSeconds: TimeInterval = 1
    static let runningCPUThreshold = 0.5

    // MARK: - Published state

    @Published private(set) var workspaceResourceSummary =
        WorkspaceResourceSummary.empty
    @Published private(set) var paneResourceSamples:
        [UUID: WorkspaceResourceSample] = [:]
    @Published private(set) var paneAgentActivities:
        [UUID: PaneAgentActivity] = [:]
    @Published private(set) var activatedWorktreeIDs: Set<UUID> = []
    @Published private(set) var activeAgentWorktreeIDs: Set<UUID> = []
    @Published private(set) var activeProcessWorktreeIDs: Set<UUID> = []
    private(set) var activityReferenceDate = Date()

    // MARK: - Private stored state

    private var resourceSamplingCoordinator:
        ResourceSamplingCoordinator?
    private var latestProcessTreeSnapshot: ProcessTreeSnapshot?
    private var outputFlushTask: Task<Void, Never>?
    private var activeProcessLeafIDs: Set<UUID> = []
    private(set) var recognizedAgentBySessionID:
        [UUID: WorkspaceKnownAgent] = [:]
    private(set) var currentRecognizedAgentSessionIDs: Set<UUID> = []
    private var agentSessionIDsByWorktreeID: [UUID: Set<UUID>] = [:]
    private var activeAgentLeafIDs: Set<UUID> = []
    private var notifiedIdleWorktreeIDs: Set<UUID> = []

    // MARK: - Dependencies (no back-reference to WSM)

    private let notificationService: NotificationService
    private let snapshotProvider: () -> WorkspaceSnapshot
    private let selectionProvider: () -> WorkspaceSelection
    private let workspaceConfigurationProvider:
        () -> WorkspaceConfiguration
    private let persistedSessionRecordsByIDProvider:
        () -> [UUID: TerminalSessionRecord]
    private let defaultIdleThresholdSecondsProvider: () -> Int
    private let isApplicationActiveProvider: () -> Bool
    private let surfaceEntriesProvider:
        () -> [(key: SurfaceKey, view: TerminalSurfaceView)]
    private let surfaceKeyForIdentityProvider:
        (UInt) -> SurfaceKey?
    private let sessionIDForKeyProvider: (SurfaceKey) -> UUID?
    private let controlModeProcessRootProvider:
        (SurfaceKey) -> ControlModeProcessRoot?
    private let leafSessionIDsByWorktreeIDProvider:
        () -> [UUID: [UUID: UUID]]
    private let updateLastOutputAtHandler:
        (UUID, Date) throws -> Void
    private let updateLastViewedAtHandler:
        (UUID, UUID, Date) throws -> Void
    private let updateLastAgentActivityHandler:
        (UUID, UUID, Date) throws -> Void
    private let fetchEnrichedSnapshotHandler:
        () throws -> WorkspaceSnapshot
    private let applySnapshotHandler: (WorkspaceSnapshot) -> Void
    private let renderTrackerDrainProvider:
        () -> [UInt: Date]
    private let aliveSessions: () -> [TerminalSessionSummary]

    // MARK: - Init

    init(
        notificationService: NotificationService,
        snapshotProvider: @escaping () -> WorkspaceSnapshot,
        selectionProvider: @escaping () -> WorkspaceSelection,
        workspaceConfigurationProvider: @escaping
        () -> WorkspaceConfiguration,
        persistedSessionRecordsByIDProvider: @escaping
        () -> [UUID: TerminalSessionRecord],
        defaultIdleThresholdSecondsProvider: @escaping () -> Int,
        isApplicationActiveProvider: @escaping () -> Bool,
        surfaceEntriesProvider: @escaping
        () -> [(key: SurfaceKey, view: TerminalSurfaceView)],
        surfaceKeyForIdentityProvider: @escaping
        (UInt) -> SurfaceKey?,
        sessionIDForKeyProvider: @escaping (SurfaceKey) -> UUID?,
        controlModeProcessRootProvider: @escaping
        (SurfaceKey) -> ControlModeProcessRoot?,
        leafSessionIDsByWorktreeIDProvider: @escaping
        () -> [UUID: [UUID: UUID]],
        updateLastOutputAtHandler: @escaping
        (UUID, Date) throws -> Void,
        updateLastViewedAtHandler: @escaping
        (UUID, UUID, Date) throws -> Void,
        updateLastAgentActivityHandler: @escaping
        (UUID, UUID, Date) throws -> Void,
        fetchEnrichedSnapshotHandler: @escaping
        () throws -> WorkspaceSnapshot,
        applySnapshotHandler: @escaping
        (WorkspaceSnapshot) -> Void,
        renderTrackerDrainProvider: @escaping
        () -> [UInt: Date],
        aliveSessions: @escaping () -> [TerminalSessionSummary]
    ) {
        self.notificationService = notificationService
        self.snapshotProvider = snapshotProvider
        self.selectionProvider = selectionProvider
        self.workspaceConfigurationProvider =
            workspaceConfigurationProvider
        self.persistedSessionRecordsByIDProvider =
            persistedSessionRecordsByIDProvider
        self.defaultIdleThresholdSecondsProvider =
            defaultIdleThresholdSecondsProvider
        self.isApplicationActiveProvider =
            isApplicationActiveProvider
        self.surfaceEntriesProvider = surfaceEntriesProvider
        self.surfaceKeyForIdentityProvider =
            surfaceKeyForIdentityProvider
        self.sessionIDForKeyProvider = sessionIDForKeyProvider
        self.controlModeProcessRootProvider =
            controlModeProcessRootProvider
        self.leafSessionIDsByWorktreeIDProvider =
            leafSessionIDsByWorktreeIDProvider
        self.updateLastOutputAtHandler = updateLastOutputAtHandler
        self.updateLastViewedAtHandler = updateLastViewedAtHandler
        self.updateLastAgentActivityHandler =
            updateLastAgentActivityHandler
        self.fetchEnrichedSnapshotHandler =
            fetchEnrichedSnapshotHandler
        self.applySnapshotHandler = applySnapshotHandler
        self.renderTrackerDrainProvider =
            renderTrackerDrainProvider
        self.aliveSessions = aliveSessions
    }

    private nonisolated static func cancelForTeardown(
        coordinator: ResourceSamplingCoordinator?
    ) {
        let cancel = { @MainActor in
            coordinator?.cancel()
        }
        if Thread.isMainThread {
            MainActor.assumeIsolated(cancel)
            return
        }
        Task { @MainActor in
            cancel()
        }
    }

    deinit {
        outputFlushTask?.cancel()
        Self.cancelForTeardown(
            coordinator: resourceSamplingCoordinator
        )
    }

    // MARK: - Resource Monitoring

    func installResourceSamplingCoordinator(
        _ coordinator: ResourceSamplingCoordinator
    ) {
        resourceSamplingCoordinator = coordinator
    }

    func startResourceMonitoringLoop() {
        restartResourceMonitoringLoop(
            for: isApplicationActiveProvider()
        )
    }

    func restartResourceMonitoringLoop(for isAppActive: Bool) {
        let plan = ResourceMonitoringPolicy.loopPlan(
            isAppActive: isAppActive
        )
        resourceSamplingCoordinator?.restartLoop(plan: plan)
    }

    func processRootsForResourceMonitoring()
        -> [WorkspaceProcessRoot] {
        var rootsByPID: [pid_t: WorkspaceProcessRoot] = [:]

        for entry in surfaceEntriesProvider() {
            let processID = Self.processRootPID(
                controlModeRoot: controlModeProcessRootProvider(entry.key),
                surfaceChildPID: entry.view.childProcessID
            )
            guard let processID else {
                continue
            }
            rootsByPID[processID] = WorkspaceProcessRoot(
                pid: processID,
                worktreeID: entry.key.worktreeID,
                leafID: entry.key.leafID
            )
        }

        return Array(rootsByPID.values)
    }

    static func processRootPID(
        controlModeRoot: ControlModeProcessRoot?,
        surfaceChildPID: pid_t?
    ) -> pid_t? {
        switch controlModeRoot {
        case let .local(processID):
            return processID
        case .unavailable:
            return nil
        case nil:
            return surfaceChildPID
        }
    }

    func updateAgentSessionState(
        from processSnapshot: ProcessTreeSnapshot?
    ) {
        let snapshot = snapshotProvider()
        let sessionHintsByID = persistedSessionRecordsByIDProvider()
            .mapValues(\.activityHint)
        let aliveSessions = snapshot.sessions.filter(\.isAlive)
        let aliveSessionIDs = Set(aliveSessions.map(\.id))
        var seededRecognizedAgentsBySessionID =
            recognizedAgentBySessionID
                .filter { aliveSessionIDs.contains($0.key) }
        for session in aliveSessions {
            guard seededRecognizedAgentsBySessionID[session.id]
                == nil,
                let hint = sessionHintsByID[session.id],
                let agent =
                WorkspaceActivityTracker
                    .recognizedAgentHint(for: hint)
            else {
                continue
            }
            seededRecognizedAgentsBySessionID[session.id] = agent
        }
        let nextState = AgentSessionResolver.resolve(
            processes: processSnapshot?.processes ?? [],
            aliveSessions: aliveSessions,
            leafSessionIDsByWorktreeID:
            leafSessionIDsByWorktreeIDProvider(),
            existingRecognizedAgentsBySessionID:
            seededRecognizedAgentsBySessionID,
            now: processSnapshot?.capturedAt ?? Date()
        )

        recognizedAgentBySessionID =
            nextState.recognizedAgentsBySessionID
        currentRecognizedAgentSessionIDs =
            nextState.currentRecognizedAgentSessionIDs
        agentSessionIDsByWorktreeID =
            nextState.agentSessionIDsByWorktreeID
        activeAgentWorktreeIDs = nextState.activeAgentWorktreeIDs
        activeAgentLeafIDs = nextState.activeAgentLeafIDs
    }

    func updateActiveProcessState(
        from processSnapshot: ProcessTreeSnapshot?
    ) {
        guard let processSnapshot else {
            activeProcessWorktreeIDs = []
            activeProcessLeafIDs = []
            return
        }

        let activeProcesses = processSnapshot.processes.filter {
            $0.sample.cpuPercent > Self.runningCPUThreshold
        }
        activeProcessWorktreeIDs =
            Set(activeProcesses.compactMap(\.worktreeID))
        activeProcessLeafIDs =
            Set(activeProcesses.compactMap(\.leafID))
    }

    func refreshWorkspaceResourceSummary() {
        let snapshot = snapshotProvider()
        let selection = selectionProvider()
        let monitoringAvailable = ResourceMonitoringPolicy.isAvailable(
            for: selection.selectedHostID,
            in: snapshot
        )
        let latestSnapshot =
            monitoringAvailable ? latestProcessTreeSnapshot : nil
        workspaceResourceSummary =
            WorkspaceResourceModel.summary(
                snapshot: snapshot,
                selectedHostID: selection.selectedHostID,
                aggregate: latestSnapshot?.aggregate,
                processes: latestSnapshot?.processes ?? [],
                lastUpdatedAt: latestSnapshot?.capturedAt,
                refreshIntervalSeconds: monitoringAvailable
                    ? resourceMonitoringRefreshIntervalSeconds()
                    : 0
            )
        if monitoringAvailable {
            paneResourceSamples =
                WorkspacePaneResourceModel.samples(
                    selectedWorktreeID:
                    selection.selectedWorktreeID,
                    selectedWorktreePath:
                    selection.selectedWorktreeID.flatMap {
                        snapshot.worktree(id: $0)?.path
                    },
                    processes: latestSnapshot?.processes ?? []
                )
        } else {
            paneResourceSamples = [:]
            paneAgentActivities = [:]
        }
    }

    func scheduleResourceRefresh(
        after delaySeconds: TimeInterval
    ) {
        resourceSamplingCoordinator?.scheduleRefresh(
            after: delaySeconds
        )
    }

    func applyResourceSnapshot(
        _ snapshot: ProcessTreeSnapshot?,
        roots: [WorkspaceProcessRoot]
    ) {
        latestProcessTreeSnapshot = snapshot
        updateActiveProcessState(from: snapshot)
        updateAgentSessionState(from: snapshot)
        if let snapshot {
            writeResourceLog(
                "Ghosthub resources: sampled roots=\(roots.count)"
                    + " processes=\(snapshot.processes.count)"
                    + " cpu=\(String(format: "%.1f", snapshot.aggregate.cpuPercent))"
                    + " rss=\(snapshot.aggregate.residentMB)"
            )
        } else {
            let rootSummary = roots.map { root in
                let worktree =
                    root.worktreeID?.uuidString.prefix(8)
                        ?? "none"
                let leaf =
                    root.leafID?.uuidString.prefix(8)
                        ?? "none"
                return "\(root.pid):w=\(worktree):l=\(leaf)"
            }.joined(separator: ",")
            writeResourceLog(
                "Ghosthub resources: no snapshot"
                    + " appPID=\(getpid())"
                    + " explicitRoots=[\(rootSummary)]"
            )
        }
        refreshWorkspaceResourceSummary()
        refreshActivityState(now: snapshot?.capturedAt ?? Date())
    }

    private func writeResourceLog(_ message: String) {
        guard ResourceMonitoringPolicy.traceEnabled(
            environment: ProcessInfo.processInfo.environment
        ) else {
            return
        }
        Self.resourceLogger.debug(
            "\(message, privacy: .public)"
        )
    }

    func activateWorktreeForResourceMonitoringIfNeeded(
        _ worktreeID: UUID
    ) {
        let snapshot = snapshotProvider()
        guard let worktree = snapshot.worktree(id: worktreeID),
              ResourceMonitoringPolicy.isAvailable(
                  for: worktree.hostID,
                  in: snapshot
              )
        else {
            return
        }
        activatedWorktreeIDs.insert(worktreeID)
    }

    func handleApplicationDidBecomeActiveForResourceMonitoring() {
        guard resourceSamplingCoordinator?.isRunning == true else {
            return
        }
        restartResourceMonitoringLoop(for: true)
    }

    func handleApplicationDidResignActiveForResourceMonitoring() {
        guard resourceSamplingCoordinator?.isRunning == true else {
            return
        }
        restartResourceMonitoringLoop(for: false)
    }

    var isResourceSamplingRunning: Bool {
        resourceSamplingCoordinator?.isRunning == true
    }

    // MARK: - Output Flush & Idle Detection

    func startOutputFlushLoop() {
        outputFlushTask?.cancel()
        outputFlushTask = Task { [weak self] in
            while let self, !Task.isCancelled {
                flushRenderOutput()
                refreshActivityState(now: Date())
                do {
                    try await Task.sleep(
                        for: .seconds(
                            Self.outputFlushIntervalSeconds
                        )
                    )
                } catch {
                    break
                }
            }
        }
    }

    func flushRenderOutput() {
        let entriesDict = renderTrackerDrainProvider()
        guard !entriesDict.isEmpty else { return }

        let selection = selectionProvider()
        let snapshot = snapshotProvider()
        var sessionUpdates: [(sessionID: UUID, date: Date)] = []
        var flushedWorktreeIDs = Set<UUID>()
        for (identity, date) in entriesDict {
            guard let key = surfaceKeyForIdentityProvider(
                identity
            ) else {
                continue
            }
            if let worktreeID = key.worktreeID {
                flushedWorktreeIDs.insert(worktreeID)
            }
            if let sessionID = sessionIDForKeyProvider(key) {
                sessionUpdates.append((sessionID, date))
            }
        }

        guard !sessionUpdates.isEmpty else { return }

        do {
            for update in sessionUpdates {
                try updateLastOutputAtHandler(
                    update.sessionID,
                    update.date
                )
            }

            if let selectedID = selection.selectedWorktreeID,
               flushedWorktreeIDs.contains(selectedID),
               let worktree = snapshot.worktree(id: selectedID) {
                try updateLastViewedAtHandler(
                    selectedID,
                    worktree.hostID,
                    Date()
                )
            }

            let updatedSnapshot =
                try fetchEnrichedSnapshotHandler()
            applySnapshotHandler(updatedSnapshot)
            refreshWorkspaceResourceSummary()
            refreshActivityState(now: Date())
        } catch {
            AppLogger.shared.error(
                "output flush failed: \(error)"
            )
        }
        writeLastAgentActivity(at: Date())
    }

    func updateLastViewedAt(
        worktreeID: UUID,
        hostID: UUID
    ) {
        do {
            try updateLastViewedAtHandler(
                worktreeID,
                hostID,
                Date()
            )
            let updatedSnapshot =
                try fetchEnrichedSnapshotHandler()
            applySnapshotHandler(updatedSnapshot)
            refreshActivityState(now: Date())
        } catch {
            AppLogger.shared.error(
                "updateLastViewedAt failed: \(error)"
            )
        }
    }

    func writeLastAgentActivity(at date: Date) {
        guard !activeAgentWorktreeIDs.isEmpty else { return }
        let snapshot = snapshotProvider()
        do {
            for worktreeID in activeAgentWorktreeIDs {
                guard let wt = snapshot.worktree(id: worktreeID)
                else { continue }
                try updateLastAgentActivityHandler(
                    worktreeID,
                    wt.hostID,
                    date
                )
            }
        } catch {
            AppLogger.shared.error(
                "writeLastAgentActivity failed: \(error)"
            )
        }
    }

    func refreshActivityState(now: Date) {
        let snapshot = snapshotProvider()
        let selection = selectionProvider()
        let workspaceConfiguration =
            workspaceConfigurationProvider()
        let persistedSessionRecordsByID =
            persistedSessionRecordsByIDProvider()
        let sessionHintsByID = persistedSessionRecordsByID
            .mapValues(\.activityHint)
        let defaultIdleThresholdSeconds =
            defaultIdleThresholdSecondsProvider()
        let evaluation = WorkspaceActivityTracker.evaluate(
            now: now,
            input: ActivityEvaluationInput(
                snapshot: snapshot,
                selectedWorktreeID:
                selection.selectedWorktreeID,
                suppressSelectedWorktreeNotifications:
                isApplicationActiveProvider(),
                notifiedIdleWorktreeIDs:
                notifiedIdleWorktreeIDs,
                defaultIdleThresholdSeconds:
                defaultIdleThresholdSeconds,
                workspaceConfiguration:
                workspaceConfiguration,
                sessionHintsByID:
                sessionHintsByID,
                recognizedAgentBySessionID:
                recognizedAgentBySessionID,
                currentRecognizedAgentSessionIDs:
                currentRecognizedAgentSessionIDs,
                leafSessionIDsByWorktreeID:
                leafSessionIDsByWorktreeIDProvider(),
                activeAgentLeafIDs: activeAgentLeafIDs,
                activeProcessLeafIDs: activeProcessLeafIDs
            )
        )
        activityReferenceDate = now
        if paneAgentActivities != evaluation.paneAgentActivities {
            paneAgentActivities = evaluation.paneAgentActivities
        }
        notifiedIdleWorktreeIDs =
            evaluation.nextNotifiedWorktreeIDs

        for request in evaluation.notificationsToPost {
            guard let worktree = snapshot.worktree(
                id: request.worktreeID
            ),
                let project = snapshot.project(
                    id: worktree.projectID
                )
            else {
                continue
            }
            switch request.kind {
            case .agentsNeedAttention:
                notificationService.postAgentsNeedAttention(
                    worktreeName: worktree.branch,
                    projectName: project.name
                )
            case .worktreeBecameIdle:
                notificationService.postWorktreeBecameIdle(
                    worktreeName: worktree.branch,
                    projectName: project.name
                )
            }
        }

        notificationService.updateDockBadge(
            unseenCount: evaluation.unseenCount
        )
    }

    // MARK: - Private Helpers

    private func resourceMonitoringRefreshIntervalSeconds()
        -> Int {
        ResourceMonitoringPolicy.refreshIntervalSeconds(
            isAppActive: isApplicationActiveProvider()
        )
    }
}
