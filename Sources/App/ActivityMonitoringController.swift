import Foundation
import GhosthubPersistence
import GhosthubTerminal
import GhosthubWorkspace

@MainActor
final class ActivityMonitoringController {
    static let outputFlushIntervalSeconds: TimeInterval = 1
    private var outputFlushTask: Task<Void, Never>?
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
    private let surfaceKeyForIdentityProvider:
        (UInt) -> SurfaceKey?
    private let sessionIDForKeyProvider: (SurfaceKey) -> UUID?
    private let updateLastOutputAtHandler:
        (UUID, Date) throws -> Void
    private let updateLastViewedAtHandler:
        (UUID, UUID, Date) throws -> Void
    private let fetchEnrichedSnapshotHandler:
        () throws -> WorkspaceSnapshot
    private let applySnapshotHandler: (WorkspaceSnapshot) -> Void
    private let renderTrackerDrainProvider:
        () -> [UInt: Date]

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
        surfaceKeyForIdentityProvider: @escaping
        (UInt) -> SurfaceKey?,
        sessionIDForKeyProvider: @escaping (SurfaceKey) -> UUID?,
        updateLastOutputAtHandler: @escaping
        (UUID, Date) throws -> Void,
        updateLastViewedAtHandler: @escaping
        (UUID, UUID, Date) throws -> Void,
        fetchEnrichedSnapshotHandler: @escaping
        () throws -> WorkspaceSnapshot,
        applySnapshotHandler: @escaping
        (WorkspaceSnapshot) -> Void,
        renderTrackerDrainProvider: @escaping
        () -> [UInt: Date]
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
        self.surfaceKeyForIdentityProvider =
            surfaceKeyForIdentityProvider
        self.sessionIDForKeyProvider = sessionIDForKeyProvider
        self.updateLastOutputAtHandler = updateLastOutputAtHandler
        self.updateLastViewedAtHandler = updateLastViewedAtHandler
        self.fetchEnrichedSnapshotHandler =
            fetchEnrichedSnapshotHandler
        self.applySnapshotHandler = applySnapshotHandler
        self.renderTrackerDrainProvider =
            renderTrackerDrainProvider
    }

    deinit {
        outputFlushTask?.cancel()
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
            refreshActivityState(now: Date())
        } catch {
            AppLogger.shared.error(
                "output flush failed: \(error)"
            )
        }
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
                recognizedAgentBySessionID: [:],
                currentRecognizedAgentSessionIDs: []
            )
        )
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

}
