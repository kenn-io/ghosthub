import GhosthubTransport
@preconcurrency import Combine
import Foundation
import GhosthubHerdr
import OSLog
import SwiftUI
import GhosthubPersistence
import GhosthubSettings
import GhosthubTerminal
import GhosthubTerminalSupport
import GhosthubTmux
import GhosthubZellij
import GhosthubUI
import GhosthubWorkspace
#if canImport(AppKit)
import AppKit
#endif

#if canImport(AppKit)
@MainActor
private func presentGhosthubAlert(
    _ alert: NSAlert
) -> NSApplication.ModalResponse {
    guard let window = NSApp.keyWindow ?? NSApp.mainWindow else {
        return alert.runModal()
    }

    var response: NSApplication.ModalResponse?
    alert.beginSheetModal(for: window) { modalResponse in
        response = modalResponse
    }

    while response == nil {
        _ = RunLoop.current.run(
            mode: .default,
            before: Date(timeIntervalSinceNow: 0.01)
        )
    }

    return response ?? .abort
}
#endif

@MainActor
final class WorkspaceSceneModel: ObservableObject {
    nonisolated static func runReconnectValidationProbe<Value: Sendable>(
        _ operation: @escaping @Sendable () -> Value
    ) async -> Value {
        await BlockingTask.run(operation)
    }

    typealias KwtInventoryLoader = @Sendable (
        CommandHost
    ) async throws -> KwtHostInventory
    typealias KwtConditionalInventoryLoader = @Sendable (
        CommandHost, String?
    ) async throws -> KwtHostInventory
    typealias KwtRemoteProvisioner = @Sendable (
        SSHHost
    ) async throws -> Void
    typealias KwtRemoteInstalling = @Sendable (
        SSHHost
    ) async throws -> Void
    typealias KwtWorktreeCreator = @Sendable (
        WorktreeCreateRequest, String, CommandHost
    ) async throws -> Void
    typealias KwtWorktreeRemover = @Sendable (
        String, String, String, String?, CommandHost
    ) async throws -> Void
    typealias KwtWorktreeChangeReader = @Sendable (
        String, String, CommandHost
    ) async throws -> WorktreeChangeSummary
    typealias SSHRouteIdentityResolver = @Sendable (
        SSHHostInfo
    ) async throws -> String
    typealias KwtBranchLister = @Sendable (
        String, CommandHost
    ) async throws -> [WorktreeBranchCandidate]
    typealias KwtPullRequestLister = @Sendable (
        String, CommandHost
    ) async throws -> [PullRequestCandidate]
    typealias KwtPullRequestImporter = @Sendable (
        String, String, CommandHost
    ) async throws -> KwtPullRequestImportResult
    typealias KwtProjectRegistration = @Sendable (
        String, CommandHost
    ) async throws -> KwtProjectRecord
    typealias KwtProjectRemoval = @Sendable (
        String, String, String, String?, CommandHost
    ) async throws -> KwtProjectRecord
    typealias TmuxSessionDiscovery = @Sendable (
        CommandHost
    ) async -> Result<[DiscoveredTmuxSession], TmuxBinaryError>
    typealias TmuxSessionValidationDiscovery = @Sendable (
        CommandHost, [String]
    ) async -> Result<[DiscoveredTmuxSession], TmuxBinaryError>
    typealias HerdrSessionDiscovery = @Sendable (
        CommandHost
    ) async -> HerdrDiscoveryResult
    typealias ZellijSessionDiscovery = @Sendable (
        CommandHost
    ) async -> ZellijDiscoveryResult
    typealias ZellijSessionValidationDiscovery = @Sendable (
        CommandHost, [String]
    ) async -> ZellijDiscoveryResult
    typealias ZellijSessionKilling = @Sendable (
        String, CommandHost, [String]
    ) async -> Result<Void, ZellijCommandError>
    typealias HerdrSessionValidationDiscovery = @Sendable (
        CommandHost, [String]
    ) async -> HerdrDiscoveryResult
    typealias HerdrSessionExactProbe = @Sendable (
        String, CommandHost, [String]
    ) async -> HerdrSessionProbeOutcome
    typealias HerdrSessionRecordReading = @Sendable (
        String, CommandHost, [String]
    ) async -> Result<HerdrSessionRecord, HerdrSessionLifecycleError>
    typealias HerdrSessionMutating = @Sendable (
        HerdrSessionLifecycleAction, HerdrSessionRecord, CommandHost, [String]
    ) async -> Result<HerdrSessionRecord, HerdrSessionLifecycleError>
    typealias TmuxSessionExactProbe = @Sendable (
        TmuxSessionProbeTarget
    ) async -> Result<Bool, TmuxBinaryError>
    typealias TmuxSessionValidationExactProbe = @Sendable (
        TmuxSessionProbeTarget, [String]
    ) async -> Result<Bool, TmuxBinaryError>
    typealias SSHConnectionSnapshotProvider = @Sendable (
        SSHHostInfo
    ) async -> SSHConnectionArgumentsSnapshot
    typealias TmuxSessionKilling = @Sendable (
        WorkspaceTmuxSessionSelection, TmuxSessionIdentity, CommandHost
    ) async throws -> Void
    typealias ReviewedTmuxSessionKilling = @Sendable (
        WorkspaceTmuxSessionSelection, TmuxSessionIdentity, String?, CommandHost
    ) async throws -> Void
    typealias TmuxSessionIdentityReading = @Sendable (
        WorkspaceTmuxSessionSelection, CommandHost
    ) async throws -> TmuxSessionIdentity
    typealias TmuxSessionIdentityReviewReading = @Sendable (
        WorkspaceTmuxSessionSelection, TmuxSessionIdentity?, CommandHost
    ) async throws -> ReviewedTmuxSessionIdentity
    typealias TmuxSessionStyling = @Sendable (
        TmuxPresentationStyle, WorkspaceTmuxSessionSelection,
        TmuxSessionIdentity, CommandHost
    ) async throws -> Void
    typealias SSHHostProbeRunner = @Sendable (
        SSHHostInfo, [String], String
    ) -> (status: Int32, stdout: String, stderr: String)
    typealias HostSSHConnectionProvider = @MainActor @Sendable (
        SSHHostInfo, String
    ) async throws -> KwtSSHConnection
    typealias HostSSHSessionProvider = @MainActor @Sendable (
        SSHHostInfo, String
    ) -> KwtSSHConnectionSession

    @Published var snapshot: WorkspaceSnapshot {
        didSet {
            sidebarSnapshotRevision &+= 1
            publishProtectedTmuxEndpoints()
            reconcileInventoryHosts()
        }
    }
    let sidebarSectionCache = WorkspaceSidebarSectionCache()
    private(set) var sidebarSnapshotRevision: UInt64 = 0
    private var tmuxDiscoveryEnabled = false
    private var isApplyingInventoryOverlay = false
    private var inventoryHosts: [UUID: CommandHost] = [:]
    private var tmuxSessionsByHost: [UUID: [TmuxSessionSummary]] = [:]
    private var tmuxReachabilityByHost: [UUID: Bool] = [:]
    private var tmuxLastSeenByHost: [UUID: Date] = [:]
    private var tmuxDiscoveryFailuresByHost: [UUID: String] = [:]
    private var tmuxFreshHostIDs: Set<UUID> = []
    private var isTmuxDiscoveryLoading = false
    private(set) var inventoryRefreshProgress =
        WorkspaceInventoryRefreshProgress()
    private var tmuxDiscoveryObservationSequence: UInt64 = 0
    private var latestTmuxDiscoveryObservationByHost: [UUID: UInt64] = [:]
    private var herdrDiscoveryEnabled = false
    private var herdrSessionsByHost: [UUID: [HerdrSessionSummary]] = [:]
    private var herdrAvailabilityByHost: [UUID: Bool] = [:]
    private var herdrDiscoveryFailuresByHost: [UUID: String] = [:]
    private var isHerdrDiscoveryLoading = false
    private var herdrDiscoveryGeneration = 0
    private var herdrDiscoveryTask: Task<Void, Never>?
    private var herdrFreshHostIDs: Set<UUID> = []
    private var zellijDiscoveryEnabled = false
    private var zellijSessionsByHost: [UUID: [ZellijSessionSummary]] = [:]
    private var zellijAvailabilityByHost: [UUID: Bool] = [:]
    private var zellijDiscoveryFailuresByHost: [UUID: String] = [:]
    private var isZellijDiscoveryLoading = false
    private var zellijDiscoveryGeneration = 0
    private var zellijDiscoveryTask: Task<Void, Never>?
    private var zellijCreationDiscoveryRetryTask: Task<Void, Never>?
    private var zellijCreationDiscoveryRetryID: UUID?
    private var zellijCreationDiscoveryRetryAttempt = 0
    private var zellijFreshHostIDs: Set<UUID> = []
    private var createdSessionDiscoveryTasks: [UUID: Task<Void, Never>] = [:]
    private var exhaustedCreatedTmuxSessionHandles: Set<UUID> = []
    private var endedCreatedTmuxSessionHandles: Set<UUID> = []
    private var confirmedEndedTmuxSessionHandles: Set<UUID> = []
    private let createdSessionDiscoveryDelays: [Duration]
    private let tmuxSessionProbeBroker: TmuxSessionProbeBroker
    private let herdrSessionProbeBroker: HerdrSessionProbeBroker
    private let herdrSessionValidationDiscovery:
        HerdrSessionValidationDiscovery
    private let herdrSessionExactProbe: HerdrSessionExactProbe
    private let tmuxReconnectIntervals: [Duration]
    private let tmuxReconnectProbeDeadline: Duration
    private let herdrReconnectSupervisor: SessionReconnectSupervisor
    private let zellijReconnectSupervisor: SessionReconnectSupervisor
    @Published private(set) var workspaceInventoryState:
        WorkspaceInventoryState = .loading
    @Published private(set) var workspaceInventoryWarning: String?
    @Published private(set) var workspaceInventoryWarningsByHost:
        [UUID: String] = [:]
    private var kwtInventoryEnabled = false
    private var kwtInventoriesByHost: [UUID: KwtHostInventory] = [:]
    private var kwtAvailabilityByHost: [UUID: Bool] = [:]
    private var kwtInventoryFailuresByHost: [UUID: String] = [:]
    private var isKwtInventoryLoading = false
    private struct SharedInventoryApplicationKey: Hashable {
        let hostID: UUID
        let commandHost: CommandHost
    }
    private let workspaceInventoryStore: WorkspaceInventoryStore
    private let workspaceInventorySubscriberID = UUID()
    private var workspaceInventoryCancellable: AnyCancellable?
    private var appliedKwtInventoryRevisions:
        [SharedInventoryApplicationKey: UInt64] = [:]
    private var appliedKwtObservationRevisions:
        [SharedInventoryApplicationKey: UInt64] = [:]
    private var appliedTmuxInventoryRevisions:
        [SharedInventoryApplicationKey: UInt64] = [:]
    private var appliedTmuxObservationRevisions:
        [SharedInventoryApplicationKey: UInt64] = [:]
    private var isConsumingSharedInventory = false
    private var ownsWorktreeMutation = false
    private let worktreeMutationCoordinator: WorktreeMutationCoordinator
    private let worktreeMutationParticipantID = UUID()
    private let herdrLifecycleCoordinator: HerdrSessionLifecycleCoordinator
    private let zellijSessionKillCoordinator: ZellijSessionKillCoordinator
    private let herdrSessionRecordReader: HerdrSessionRecordReading
    private let herdrSessionMutator: HerdrSessionMutating
    private let herdrSSHConnectionSnapshotProvider:
        SSHConnectionSnapshotProvider
    private struct HerdrLifecycleAuthority {
        var host: CommandHost
        var routeIdentity: String?
    }
    private struct HerdrSessionValidation {
        var session: HerdrSessionSummary?
        var host: CommandHost
        var connection: SSHConnectionArgumentsSnapshot
    }
    private struct HerdrSessionProbeValidation {
        var outcome: HerdrSessionProbeOutcome
        var validation: HerdrSessionValidation
    }
    private var herdrLifecycleAuthorities:
        [UUID: HerdrLifecycleAuthority] = [:]
    private var fencedWorktreeMutationScopes:
        Set<WorktreeMutationCoordinator.Scope> = []
    private var worktreeRemovalTombstones:
        [
            WorktreeMutationCoordinator.Scope:
                Set<WorktreeMutationCoordinator.RemovalTombstone>
        ] = [:]

    var isWorkspaceInventoryRefreshComplete: Bool {
        inventoryRefreshProgress.kwtCompleted
            && inventoryRefreshProgress.tmuxCompleted
            && (!herdrDiscoveryEnabled
                || inventoryRefreshProgress.herdrCompleted)
            && (!zellijDiscoveryEnabled
                || inventoryRefreshProgress.zellijCompleted)
            && !isKwtInventoryLoading
            && !isTmuxDiscoveryLoading
            && !isHerdrDiscoveryLoading
            && !isZellijDiscoveryLoading
            && kwtInventoryFailuresByHost.isEmpty
            && tmuxDiscoveryFailuresByHost.isEmpty
            && herdrDiscoveryFailuresByHost.isEmpty
            && zellijDiscoveryFailuresByHost.isEmpty
    }

    var workspaceResourceSummary: WorkspaceResourceSummary {
        activityController.workspaceResourceSummary
    }
    var paneResourceSamples: [UUID: WorkspaceResourceSample] {
        activityController.paneResourceSamples
    }
    var paneAgentActivities: [UUID: PaneAgentActivity] {
        activityController.paneAgentActivities
    }
    var activatedWorktreeIDs: Set<UUID> {
        activityController.activatedWorktreeIDs
    }
    var activeAgentWorktreeIDs: Set<UUID> {
        activityController.activeAgentWorktreeIDs
    }
    var activeProcessWorktreeIDs: Set<UUID> {
        activityController.activeProcessWorktreeIDs
    }
    let panelRoutingService: PanelRoutingService

    var isSidePanelVisible: Bool {
        panelRoutingService.isSidePanelVisible
    }
    @Published var preferredActiveSurfaceTarget: WorkspaceTerminalSurfaceTarget?
    @Published private var borrowedTmuxConnectionStates:
        [UUID: ConnectionState] = [:] {
        didSet {
            refreshConnectedBorrowedTmuxSessionIDs()
        }
    }
    private(set) var connectedBorrowedTmuxSessionIDs:
        Set<String> = []
    private struct PendingTmuxSessionCreation: Equatable {
        var request: WorkspaceTmuxSessionCreationRequest
        var commandReplayAuthorized: Bool

        var selection: WorkspaceTmuxSessionSelection {
            request.selection
        }

        var initialCommand: String? {
            request.initialCommand
        }
    }
    private var pendingCreatedTmuxSessions:
        [UUID: PendingTmuxSessionCreation] = [:]
    var pendingCreatedTmuxSessionCount: Int {
        pendingCreatedTmuxSessions.count
    }
    var exhaustedCreatedTmuxSessionCount: Int {
        exhaustedCreatedTmuxSessionHandles.count
    }
    @Published private(set) var activeBorrowedTmuxSelection:
        WorkspaceTmuxSessionSelection?
    private var activeBorrowedTmuxHandle: BorrowedTmuxSessionHandle?
    private(set) var activeBorrowedTmuxLaunchMode:
        TmuxAttachmentLaunchMode?
    @Published private(set) var activeBorrowedTmuxRecoveryState:
        NativeSessionRecoveryState?
    @Published private var borrowedHerdrConnectionStates:
        [UUID: ConnectionState] = [:]
    @Published private(set) var activeBorrowedHerdrSelection:
        WorkspaceHerdrSessionSelection?
    private var activeBorrowedHerdrHandle: BorrowedHerdrSessionHandle?
    var pendingHerdrShortcutSelection: WorkspaceHerdrSessionSelection?
    var herdrShortcutNavigationTask: Task<Void, Never>?
    var herdrShortcutNavigationID: UUID?
    var activeBorrowedHerdrConnectionState: ConnectionState? {
        guard let activeBorrowedHerdrHandle else { return nil }
        return borrowedHerdrConnectionStates[activeBorrowedHerdrHandle.id]
    }
    private struct PendingHerdrLaunch {
        let operation: HerdrSessionLifecycleCoordinator.Operation
        var authority: HerdrAttachmentAuthority?
    }
    private var pendingHerdrLaunchOperations: [UUID: PendingHerdrLaunch] = [:]
    private var herdrLaunchConfirmationTasks:
        [UUID: Task<Void, Never>] = [:]
    private struct FailedHerdrLaunchIntent: Equatable {
        var selection: WorkspaceHerdrSessionSelection
        var kind: HerdrSessionLifecycleCoordinator.OperationKind
    }
    private var failedHerdrLaunchIntent: FailedHerdrLaunchIntent?
    @Published private(set) var activeBorrowedHerdrRecoveryState:
        NativeSessionRecoveryState?
    @Published private var borrowedZellijConnectionStates:
        [UUID: ConnectionState] = [:]
    @Published private(set) var activeBorrowedZellijSelection:
        WorkspaceZellijSessionSelection?
    private var activeBorrowedZellijHandle: BorrowedZellijSessionHandle?
    @Published private(set) var activeBorrowedZellijRecoveryState:
        NativeSessionRecoveryState?
    private var zellijPresentationTask: Task<Void, Never>?
    private struct ZellijPresentationIntent {
        var id: UUID
        var selection: WorkspaceZellijSessionSelection
        var navigationRevision: UInt64
        var revision: UInt64
        var host: CommandHost
    }
    private var zellijPresentationIntent: ZellijPresentationIntent?
    private var zellijPresentationRevision: UInt64 = 0
    var pendingZellijPresentationSelection:
        WorkspaceZellijSessionSelection? {
        zellijPresentationIntent?.selection
    }
    private struct SuppressedZellijKillPresentation {
        var selection: WorkspaceZellijSessionSelection
        var navigationRevision: UInt64
        var host: CommandHost
        var restoresActivePresentation: Bool
        var presentationIntent: ZellijPresentationIntent?
    }
    private var suppressedZellijKillPresentations:
        [UUID: SuppressedZellijKillPresentation] = [:]
    var activeBorrowedZellijConnectionState: ConnectionState? {
        guard let activeBorrowedZellijHandle else { return nil }
        return borrowedZellijConnectionStates[activeBorrowedZellijHandle.id]
    }
    private struct ActiveZellijReconnectContext: Equatable {
        var selection: WorkspaceZellijSessionSelection
        var handleID: UUID
        var host: CommandHost
        var routeIdentity: String?
        var surfaceExitCode: UInt32?
        /// The previous attempt failed before the terminal client could start,
        /// so there is no exit code to inspect and reattachment is still safe.
        var surfaceLaunchFailed = false

    }
    private var activeZellijReconnectContext: ActiveZellijReconnectContext?
    private struct ZellijSessionValidation {
        var result: ZellijDiscoveryResult
        var host: CommandHost
        var connection: SSHConnectionArgumentsSnapshot
        var executablePath: String?
    }
    private struct ZellijKillAuthority {
        var hostID: UUID
        var host: CommandHost
        var routeIdentity: String?
    }
    private var zellijKillAuthorities: [UUID: ZellijKillAuthority] = [:]
    private var pendingCreatedZellijSessions:
        [UUID: WorkspaceZellijSessionSelection] = [:]
    private var failedZellijCreationIntent:
        WorkspaceZellijSessionSelection?
    var zellijReconnectSupervisorIsRunning: Bool {
        zellijReconnectSupervisor.isRunning
    }
    private struct SuppressedHerdrStop {
        var selection: WorkspaceHerdrSessionSelection
        var reconnectContext: ActiveHerdrReconnectContext?
    }
    private var suppressedHerdrStops:
        [UUID: SuppressedHerdrStop] = [:]
    var herdrReconnectSupervisorIsRunning: Bool {
        herdrReconnectSupervisor.isRunning
    }

    /// tmux supervisors are per presentation, so unlike Herdr and Zellij this
    /// reports whether any retained presentation is still recovering.
    var anyTmuxReconnectSupervisorIsRunning: Bool {
        retainedTmuxPresentations.values.contains {
            $0.reconnectSupervisor.isRunning
        }
    }
    @Published private(set) var sessionConnectionRecoveryRequest:
        SessionConnectionRecoveryRequest?
    @Published private(set) var presentationSSHSession:
        KwtSSHConnectionSession?
    private var presentationSSHSessionID: UUID?
    private var presentationSSHSessions:
        [UUID: KwtSSHConnectionSession] = [:]
    private var presentationSSHSessionOrder: [UUID] = []
    private enum RemoteTmuxEstablishmentPhase: Equatable {
        case establishingWorkspace
        case establishingProfile(initialCommand: String)
        case attachOnly
    }
    private struct TmuxReconnectContext: Equatable {
        var selection: WorkspaceTmuxSessionSelection
        var handleID: UUID
        var host: CommandHost
        var routeIdentity: String?
        var phase: RemoteTmuxEstablishmentPhase
        var surfaceExitCode: UInt32?
        var usesKwtWorkspaceCommand = false
        /// The previous attempt failed before the terminal client could start,
        /// so there is no exit code to inspect and replay is still safe.
        var surfaceLaunchFailed = false
    }

    private struct TmuxReconnectProbeResult {
        var outcome: TmuxSessionProbeOutcome
        var discovery: (
            sequence: UInt64,
            epoch: UInt64?,
            result: Result<[DiscoveredTmuxSession], TmuxBinaryError>
        )?
    }
    private struct TmuxPresentationKey: Hashable {
        var hostID: UUID
        var name: String
        var socketName: String?
        var tmuxAttachMode: TmuxAttachMode?

        init(_ selection: WorkspaceTmuxSessionSelection) {
            hostID = selection.hostID
            name = selection.name
            socketName = selection.socketName
            tmuxAttachMode = selection.tmuxAttachMode
        }

        var previewKey: TmuxPreviewKey {
            TmuxPreviewKey(
                hostID: hostID,
                name: name,
                socketName: socketName
            )
        }

        var sessionID: String {
            [
                hostID.uuidString,
                tmuxAttachMode?.rawValue ?? "unbound",
                socketName ?? "default",
                name,
            ].joined(separator: ":")
        }
    }
    private final class RetainedTmuxPresentation {
        var selection: WorkspaceTmuxSessionSelection
        var handle: BorrowedTmuxSessionHandle
        var launchMode: TmuxAttachmentLaunchMode
        var reconnectContext: TmuxReconnectContext?
        var recoveryState: NativeSessionRecoveryState?
        var recoveryRequest: SessionConnectionRecoveryRequest?
        let reconnectSupervisor: SessionReconnectSupervisor
        var establishmentConfirmationTask: Task<Void, Never>?
        var verifiedPreviewIdentity: TmuxSessionIdentity?
        var reconnectExpectedIdentity: TmuxSessionIdentity?
        var previewIdentityUnavailable = false
        var previewPromotionID: UUID?
        var previewPromotionTask: Task<Void, Never>?
        var previewPromotionNavigationRevision: UInt64?
        var pendingPreviewPromotionNavigationRevision: UInt64?

        var previewPromotionIsPending: Bool {
            previewPromotionTask != nil
                || pendingPreviewPromotionNavigationRevision != nil
        }

        var expectedPreviewIdentity: TmuxSessionIdentity? {
            verifiedPreviewIdentity ?? reconnectExpectedIdentity
        }

        init(
            selection: WorkspaceTmuxSessionSelection,
            handle: BorrowedTmuxSessionHandle,
            launchMode: TmuxAttachmentLaunchMode,
            reconnectContext: TmuxReconnectContext?,
            reconnectSupervisor: SessionReconnectSupervisor,
            verifiedPreviewIdentity: TmuxSessionIdentity?
        ) {
            self.selection = selection
            self.handle = handle
            self.launchMode = launchMode
            self.reconnectContext = reconnectContext
            self.reconnectSupervisor = reconnectSupervisor
            self.verifiedPreviewIdentity = verifiedPreviewIdentity
        }
    }
    private struct PendingRemovalPresentation {
        var selection: WorkspaceTmuxSessionSelection
        var launchMode: TmuxAttachmentLaunchMode
        var requiresWorkspaceEstablishment: Bool
        var wasActive: Bool
        var userNavigationRevision: UInt64
    }
    private var retainedTmuxPresentations:
        [TmuxPresentationKey: RetainedTmuxPresentation] = [:]
    private var retainedTmuxPresentationKeysByHandle:
        [UUID: TmuxPresentationKey] = [:]
    private var alwaysLiveManagedTmuxPresentationKeys:
        Set<TmuxPresentationKey> = []
    private var alwaysLiveIneligibleTmuxPresentationIdentities:
        [TmuxPresentationKey: TmuxSessionIdentity] = [:]
    private var pendingAlwaysLiveTmuxSurfaceHandles:
        [BorrowedTmuxSessionHandle] = []
    private var pendingAlwaysLiveTmuxSurfaceHandleIDs: Set<UUID> = []
    private var alwaysLiveTmuxSurfaceLaunchTask: Task<Void, Never>?
    private var alwaysLiveTmuxSurfaceLaunchID: UUID?
    private var protectedTmuxAttachmentScopesByHandle:
        [UUID: WorktreeMutationCoordinator.Scope] = [:]
    private var pendingProtectedTmuxAttachmentScopesByHandle:
        [UUID: WorktreeMutationCoordinator.Scope] = [:]
    private struct ActiveHerdrReconnectContext: Equatable {
        var selection: WorkspaceHerdrSessionSelection
        var handleID: UUID
        var host: CommandHost
        var routeIdentity: String?
        var surfaceExitCode: UInt32?
        /// The previous attempt failed before the terminal client could start,
        /// so there is no exit code to inspect and reattachment is still safe.
        var surfaceLaunchFailed = false
    }
    private var activeHerdrReconnectContext: ActiveHerdrReconnectContext?
    @Published private(set) var isWorkspaceRestorationPending = false
    @Published private(set) var suppressesAutomaticWorktreeSessionOpen = false
    @Published private var explicitlyDismissedWorktreePresentationIDs:
        Set<UUID> = []
    @Published private var explicitlyDismissedDirectoryPresentationIDs:
        Set<UUID> = []
    @Published private var pendingWorktreeRemovals:
        [
            WorktreeMutationCoordinator.Scope:
                Set<WorktreeMutationCoordinator.RemovalTombstone>
        ] = [:]
    private var pendingRemovalPresentationRestorations:
        [WorktreeMutationCoordinator.Scope:
            [TmuxPresentationKey: PendingRemovalPresentation]] = [:]
    private var userNavigationRevision: UInt64 = 0
    private var isShutDown = false
    private var sceneActivityGeneration: UInt64 = 0
    var suppressesSelectedWorktreeSessionOpen: Bool {
        suppressesAutomaticWorktreeSessionOpen
            || selection.selectedWorktreeID.map {
                explicitlyDismissedWorktreePresentationIDs.contains($0)
            } == true
            || selection.selectedDirectoryWorkspaceID.map {
                explicitlyDismissedDirectoryPresentationIDs.contains($0)
            } == true
            || selectedWorktreeRemovalIsPending
    }
    private var pendingRestoration: WorkspaceWindowState?
    private var pendingRestorationLaunchIntent:
        WorkspaceWindowLaunchIntent?
    private var protectedRestorationProbeTask: Task<Void, Never>?
    private var protectedRestorationProbeID: UUID?
    private var protectedRestorationRefreshPending = false
    private var herdrRestorationValidationTask: Task<Void, Never>?
    private var herdrRestorationValidationID: UUID?
    private var zellijRestorationValidationTask: Task<Void, Never>?
    private var zellijRestorationValidationID: UUID?
    private struct ZellijRestorationRoute {
        let id: UUID
        var state: WorkspaceWindowState
        var selection: WorkspaceZellijSessionSelection
        var host: CommandHost
        var routeIdentity: String?
    }
    private struct ZellijSuccessfulKillFence {
        var killRevision: UInt64
        var presentationRevision: UInt64
        var discoveryGeneration: Int
        var activeHandleID: UUID?
        var presentationIntentID: UUID?
        var pendingCreationHandleIDs: Set<UUID>
        var sessions: [ZellijSessionSummary]
        var restorationRouteID: UUID?
    }
    private var zellijRestorationRoute: ZellijRestorationRoute?
    var activeBorrowedTmuxSessionIsConnected: Bool {
        guard let handle = activeBorrowedTmuxHandle else {
            return false
        }
        return borrowedTmuxConnectionStates[handle.id] == .connected
    }
    private var canSplitActiveTmuxPane: Bool {
        guard let selection = activeBorrowedTmuxSelection,
              isConnectedActiveTmuxSession(selection),
              let handle = activeBorrowedTmuxHandle,
              nativeTmuxSessionCoordinator.supportsPaneSplitting(handle)
        else { return false }
        return true
    }

    private var canSplitActiveHerdrPane: Bool {
        guard let handle = activeBorrowedHerdrHandle,
              borrowedHerdrConnectionStates[handle.id] == .connected,
              nativeHerdrSessionCoordinator.supportsPaneSplitting(handle)
        else { return false }
        return true
    }

    var canSplitActivePane: Bool {
        canSplitActiveTmuxPane || canSplitActiveHerdrPane
    }

    func splitActivePane(
        _ shortcut: TerminalPaneSplitShortcut,
        requiresKeyboardFocus: Bool = false
    ) {
        if canSplitActiveTmuxPane, let handle = activeBorrowedTmuxHandle {
            nativeTmuxSessionCoordinator.requestPaneSplit(
                shortcut,
                handle: handle,
                requiresKeyboardFocus: requiresKeyboardFocus
            )
        } else if canSplitActiveHerdrPane,
                  let handle = activeBorrowedHerdrHandle {
            nativeHerdrSessionCoordinator.requestPaneSplit(
                shortcut,
                handle: handle,
                requiresKeyboardFocus: requiresKeyboardFocus
            )
        }
    }

    var canApplyThemeToActiveTmuxSession: Bool {
        guard let selection = activeBorrowedTmuxSelection,
              isConnectedActiveTmuxSession(selection),
              let hostSummary = snapshot.host(id: selection.hostID),
              let host = CommandHostResolver.resolve(hostSummary),
              Self.supportsTmuxSessionStyling(host),
              let handle = activeBorrowedTmuxHandle,
              tmuxPresentationStyleProvider(
                  nativeTmuxSessionCoordinator.surfaceIdentity(handle: handle)
              ) != nil
        else {
            return false
        }
        return true
    }
    var activeBorrowedTmuxSessionIsConfirmedEnded: Bool {
        guard let handle = activeBorrowedTmuxHandle else { return false }
        return confirmedEndedTmuxSessionHandles.contains(handle.id)
    }
    var activeBorrowedTmuxRetryRequiresConfirmation: Bool {
        guard let handle = activeBorrowedTmuxHandle,
              case .disconnected = borrowedTmuxConnectionStates[handle.id],
              let pending = activePendingTmuxCreation?.pending,
              pending.initialCommand != nil,
              !pending.commandReplayAuthorized
        else { return false }
        return true
    }

    var activeBorrowedTmuxRetryCommand: String? {
        guard activeBorrowedTmuxRetryRequiresConfirmation else { return nil }
        return activePendingTmuxCreation?.pending.initialCommand
    }

    private var activePendingTmuxCreation:
        (handleID: UUID, pending: PendingTmuxSessionCreation)? {
        guard let selection = activeBorrowedTmuxSelection else { return nil }
        if let handle = activeBorrowedTmuxHandle,
           let pending = pendingCreatedTmuxSessions[handle.id] {
            return (handle.id, pending)
        }
        return pendingCreatedTmuxSessions.first {
            Self.sameTmuxSession($0.value.selection, selection)
        }.map {
            ($0.key, $0.value)
        }
    }

    var activityReferenceDate: Date {
        activityController.activityReferenceDate
    }

    /// Set by `WorkspaceWindow` to indicate this scene model's
    /// window is the key window.  Used to disambiguate app-wide
    /// events (keyboard shortcuts, split actions without source
    /// identity) so only the focused window handles them.
    var isFocusedWindow = false {
        didSet {
            guard isFocusedWindow != oldValue else { return }
            tmuxSessionPreviewCoordinator.sceneWindowFocusDidChange(
                isKey: isFocusedWindow
            )
            guard isFocusedWindow else { return }
            syncTerminalConfig()
        }
    }
    weak var workspaceWindow: NSWindow?
    var acceptsApplicationShortcutKeyEvents: Bool {
        workspaceWindow?.isKeyWindow ?? isFocusedWindow
    }
    @Published var selection: WorkspaceSelection {
        didSet {
            if selection != oldValue {
                tmuxSessionPreviewCoordinator.cancelPendingActivation()
            }
            syncTerminalConfig()
            activityController
                .refreshWorkspaceResourceSummary()
            if let worktreeID = selection.selectedWorktreeID {
                activityController
                    .activateWorktreeForResourceMonitoringIfNeeded(
                        worktreeID
                    )
            }
            if selection.selectedWorktreeID
                != oldValue.selectedWorktreeID {
                recordSelectedWorktreeView()
            }
            activityController.refreshActivityState(now: Date())
        }
    }
    /// Not @Published — NavigationSplitView writes back during layout,
    /// which would re-fire objectWillChange on every frame, creating an
    /// infinite update loop.  Manual deduplication avoids this.
    var columnVisibility: NavigationSplitViewVisibility = .all {
        didSet {
            guard oldValue != columnVisibility else { return }
            objectWillChange.send()
        }
    }
    var isCommandPalettePresented = false {
        didSet {
            guard oldValue != isCommandPalettePresented else { return }
            objectWillChange.send()
        }
    }
    var isLogViewerPresented = false {
        didSet {
            guard oldValue != isLogViewerPresented else { return }
            objectWillChange.send()
        }
    }
    var isSettingsPresented = false {
        didSet {
            guard oldValue != isSettingsPresented else { return }
            objectWillChange.send()
        }
    }
    /// When true, the model was created with an override
    /// snapshot for testing. fetchEnrichedSnapshot returns
    /// the current in-memory snapshot instead of re-fetching
    /// from the empty test database.
    private var hasOverrideSnapshot = false

    private let database: WorkspaceDatabase
    private let panelPreferenceStore: PanelPreferenceStore
    private var workspaceConfiguration: WorkspaceConfiguration
    private let sceneSettings: WorkspaceSceneSettings
    let terminalRuntime: LibghosttyRuntime
    let terminalCoordinator: TerminalSurfaceCoordinator
    let tmuxSessionPreviewCoordinator: TmuxSessionPreviewCoordinator
    let localHostID: UUID
    private let notificationService: NotificationService
    private let tmuxSessionActivityController:
        TmuxSessionActivityController?
    private let kwtInventoryLoader: KwtInventoryLoader
    private let kwtConditionalInventoryLoader: KwtConditionalInventoryLoader
    private let kwtRemoteProvisioner: KwtRemoteProvisioner
    private let kwtRemoteInstaller: KwtRemoteInstalling
    private let kwtWorktreeCreator: KwtWorktreeCreator
    private let kwtWorktreeRemover: KwtWorktreeRemover
    private let kwtForceWorktreeRemover: KwtWorktreeRemover
    private let kwtWorktreeChangeReader: KwtWorktreeChangeReader
    private let sshRouteIdentityResolver: SSHRouteIdentityResolver
    private let kwtBranchLister: KwtBranchLister
    private let kwtPullRequestLister: KwtPullRequestLister
    private let kwtPullRequestImporter: KwtPullRequestImporter
    private let kwtProjectRegistration: KwtProjectRegistration
    private let kwtProjectRemoval: KwtProjectRemoval
    private let tmuxSessionDiscovery: TmuxSessionDiscovery
    private let tmuxSessionValidationDiscovery:
        TmuxSessionValidationDiscovery?
    private let tmuxSessionValidationExactProbe:
        TmuxSessionValidationExactProbe?
    private let zellijSessionDiscovery: ZellijSessionDiscovery
    private let zellijSessionValidationDiscovery:
        ZellijSessionValidationDiscovery
    private let zellijExecutableResolver:
        @Sendable (CommandHost, [String])
        -> Result<String, ZellijCommandError>
    private let zellijSessionKiller: ZellijSessionKilling
    private let zellijSSHConnectionSnapshotProvider:
        SSHConnectionSnapshotProvider
    private let presentationSSHConnectionProvider:
        (@MainActor @Sendable (UUID, SSHHostInfo) async throws
            -> KwtSSHConnection)?
    private let presentationSSHAcquisitionCoordinator:
        KwtSSHAcquisitionCoordinator
    private let presentationSSHEnvironment: [String: String]
    private let tmuxSessionKiller: ReviewedTmuxSessionKilling
    private let tmuxSessionIdentityReader: TmuxSessionIdentityReading
    private let tmuxSessionIdentityReviewer:
        TmuxSessionIdentityReviewReading
    private let tmuxSessionStyler: TmuxSessionStyling
    private let tmuxPresentationStyleProvider:
        (UInt?) -> TmuxPresentationStyle?
    /// Displays macOS currently reports as active. Zero means nothing can be
    /// rendered, so an attach cannot succeed; see `DisplayAvailability`.
    private let activeDisplayCount: @Sendable () -> Int
    private let sshHostProbeRunner: SSHHostProbeRunner
    private let hostSSHConnectionProvider: HostSSHConnectionProvider?
    private let hostSSHSessionProvider: HostSSHSessionProvider
    private var hostSSHSessionDestination: String?
    private var hostSSHSessionOwnerID: UUID?
    private var hostSSHSessionSurfaceID: UUID?
    @Published private(set) var hostSSHSession: KwtSSHConnectionSession?
    private let configuredSSHHostsProvider: () -> [SSHHost]
    private var configuredSSHHostsCancellable: AnyCancellable?
    private let configuredExeHostsProvider: () -> [ExeConfiguredHost]
    private let refreshExeHosts: () -> Void
    private let startExeHostInventory: () -> Void
    private var configuredExeHostsCancellable: AnyCancellable?
    private var terminalColorsCancellable: AnyCancellable?
    private var sessionPreviewModeCancellable: AnyCancellable?
    private var deferredTmuxPresentationTasks: [UUID: Task<Void, Never>] = [:]
    private var drainingDeferredTmuxPresentationTasks:
        [UUID: Task<Void, Never>] = [:]
    private var tmuxActivityEnrollmentTasks:
        [UUID: Task<Void, Never>] = [:]
    private let deferredTmuxPresentationRetryDelays: [Duration]
    private var worktreeMutationCancellable: AnyCancellable?
    private var herdrLifecycleCancellable: AnyCancellable?
    private var zellijSessionKillCancellable: AnyCancellable?
    private var activityControllerBacking: ActivityMonitoringController?
    var activityController: ActivityMonitoringController {
        guard let activityControllerBacking else {
            preconditionFailure(
                "activity controller was not initialized"
            )
        }
        return activityControllerBacking
    }
    private var nativeTmuxSessionCoordinatorBacking:
        NativeTmuxSessionCoordinator?
    private var nativeTmuxSessionCoordinator: NativeTmuxSessionCoordinator {
        guard let nativeTmuxSessionCoordinatorBacking else {
            preconditionFailure(
                "native tmux session coordinator was not initialized"
            )
        }
        return nativeTmuxSessionCoordinatorBacking
    }
    private var nativeHerdrSessionCoordinatorBacking:
        NativeHerdrSessionCoordinator?
    private var nativeHerdrSessionCoordinator: NativeHerdrSessionCoordinator {
        guard let nativeHerdrSessionCoordinatorBacking else {
            preconditionFailure(
                "native Herdr session coordinator was not initialized"
            )
        }
        return nativeHerdrSessionCoordinatorBacking
    }
    private var nativeZellijSessionCoordinatorBacking:
        NativeZellijSessionCoordinator?
    private var nativeZellijSessionCoordinator: NativeZellijSessionCoordinator {
        guard let nativeZellijSessionCoordinatorBacking else {
            preconditionFailure(
                "native Zellij session coordinator was not initialized"
            )
        }
        return nativeZellijSessionCoordinatorBacking
    }
    private var activityCancellable: AnyCancellable?
    private var tmuxSessionActivityCancellable: AnyCancellable?
    private var panelRoutingCancellable: AnyCancellable?
    var isAppActive = true
    var childExitCancellable: AnyCancellable?
    var appDidBecomeActiveCancellable: AnyCancellable?
    var appDidResignActiveCancellable: AnyCancellable?
    var screenParametersCancellable: AnyCancellable?
    var shortcutMonitor: ShortcutMonitor?
    var openTerminalSurfaceCount: Int {
        terminalCoordinator.surfaceEntries().reduce(into: 0) { count, entry in
            if entry.view.error == nil {
                count += 1
            }
        }
    }
    var sessionIdleThresholdsByID: [UUID: Int] {
        return WorkspaceActivityTracker.idleThresholdsBySessionID(
            sessions: snapshot.sessions,
            defaultIdleThresholdSeconds: defaultIdleThresholdSeconds,
            workspaceConfiguration: workspaceConfiguration,
            sessionHintsByID: [:],
            recognizedAgentBySessionID:
            activityController.recognizedAgentBySessionID
        )
    }
    var defaultIdleThresholdSeconds: Int {
        workspaceConfiguration.notifications.idleThresholdSeconds
    }
    var workingTmuxSessionIDs: Set<String> {
        tmuxSessionActivityController?.workingSessionIDs ?? []
    }
    var tmuxWindowCountsBySessionID: [String: Int] {
        tmuxSessionActivityController?.windowCountsBySessionID ?? [:]
    }
    convenience init(terminalRuntime: LibghosttyRuntime = .shared) {
        do {
            let boot = try WorkspaceSceneBootstrap.resources()
            try self.init(
                database: boot.database,
                workspaceConfiguration: boot.workspaceConfiguration,
                terminalRuntime: terminalRuntime,
                notificationService: boot.notificationService,
                tmuxPresentationStyleProvider: { surfaceIdentity in
                    let preferences = SettingsStore.shared
                        .terminalAppearancePreferences
                    let resolvedColors = surfaceIdentity.flatMap {
                        terminalRuntime.resolvedTerminalColors(
                            forSurfaceIdentity: $0
                        )
                    }
                    return TmuxPresentationStyleResolver.resolve(
                        preferences: preferences,
                        resolvedColors: resolvedColors
                    )
                },
                appliesTmuxPresentationStyleToExistingSessionsProvider: {
                    SettingsStore.shared.terminalAppearancePreferences
                        .appliesThemeToTmuxSessions
                },
                tmuxSessionActivityController:
                boot.tmuxSessionActivityController,
                localHostID: boot.localHostID,
                startServices: true
            )
        } catch {
            fatalError(
                "Failed to bootstrap workspace scene: \(error)"
            )
        }
    }

    init(
        database: WorkspaceDatabase,
        workspaceConfiguration: WorkspaceConfiguration = .defaults(),
        terminalRuntime: LibghosttyRuntime = .shared,
        notificationService: NotificationService,
        nativeTmuxSurfaceStore: (any NativeSessionSurfaceStoring)? = nil,
        nativeHerdrSurfaceStore: (any NativeSessionSurfaceStoring)? = nil,
        nativeZellijSurfaceStore: (any NativeSessionSurfaceStoring)? = nil,
        nativeTmuxPathProvider:
        (@Sendable () -> Result<ResolvedTmuxBinary, TmuxBinaryError>)? = nil,
        nativeHerdrPathProvider: (@Sendable (CommandHost)
            -> Result<String, HerdrCommandError>)? = nil,
        nativeZellijPathProvider: (@Sendable (CommandHost)
            -> Result<String, ZellijCommandError>)? = nil,
        herdrPaneSplitCapabilityProvider:
        NativeHerdrSessionCoordinator.PaneSplitCapabilityProvider? = nil,
        herdrPaneSplitter: HerdrPaneSplitter = HerdrPaneSplitter(),
        nativeTmuxPaneSplitter: TmuxPaneSplitter = TmuxPaneSplitter(),
        localKwtPathProvider: @escaping @Sendable () -> String? = {
            KwtBinaryLocator.bundledPath()
        },
        remoteTmuxPathProvider: @escaping @Sendable (SSHHostInfo, [String])
            -> Result<ResolvedTmuxBinary, TmuxBinaryError> = {
                TmuxBinaryResolver().resolveTmuxBinary(
                    on: $0,
                    sshConnectionArguments: $1
                )
            },
        tmuxPresentationStyleProvider:
        @escaping (UInt?) -> TmuxPresentationStyle? = { _ in nil },
        appliesTmuxPresentationStyleToExistingSessionsProvider:
        @escaping () -> Bool = { false },
        activeDisplayCount: @escaping @Sendable () -> Int = {
            DisplayAvailability.activeCount()
        },
        kwtInventoryLoader: @escaping KwtInventoryLoader = { host in
            try await KwtInventoryService().load(from: host)
        },
        kwtConditionalInventoryLoader:
        @escaping KwtConditionalInventoryLoader = {
            host, expectedRouteIdentity in
            try await KwtInventoryService().load(
                from: host,
                expectedRouteIdentity: expectedRouteIdentity
            )
        },
        kwtRemoteProvisioner: @escaping KwtRemoteProvisioner = { host in
            try await KwtRemoteProvisioningCoordinator.shared
                .ensureInstalled(on: host)
        },
        kwtRemoteInstaller: @escaping KwtRemoteInstalling = { host in
            try await KwtRemoteProvisioningCoordinator.shared
                .install(on: host)
        },
        kwtWorktreeCreator: @escaping KwtWorktreeCreator = {
            request, projectPath, host in
            try await KwtWorktreeClient().create(
                request: request,
                projectPath: projectPath,
                on: host
            )
        },
        kwtWorktreeRemover: @escaping KwtWorktreeRemover = {
            worktreePath, generation, projectPath, routeIdentity, host in
            try await KwtWorktreeClient().remove(
                worktreePath: worktreePath,
                generation: generation,
                projectPath: projectPath,
                expectedRouteIdentity: routeIdentity,
                on: host
            )
        },
        kwtForceWorktreeRemover: @escaping KwtWorktreeRemover = {
            worktreePath, generation, projectPath, routeIdentity, host in
            try await KwtWorktreeClient().remove(
                worktreePath: worktreePath,
                generation: generation,
                projectPath: projectPath,
                force: true,
                expectedRouteIdentity: routeIdentity,
                on: host
            )
        },
        kwtWorktreeChangeReader: @escaping KwtWorktreeChangeReader = {
            worktreePath, projectPath, host in
            try await KwtWorktreeClient().changes(
                worktreePath: worktreePath,
                projectPath: projectPath,
                on: host
            )
        },
        sshRouteIdentityResolver: @escaping SSHRouteIdentityResolver = {
            host in
            try await BlockingTask.runThrowing(priority: .userInitiated) {
                try KwtSSHRouteClient().resolve(host).routeIdentity
            }
        },
        worktreeMutationCoordinator: WorktreeMutationCoordinator = .shared,
        workspaceInventoryStore: WorkspaceInventoryStore = .shared,
        herdrLifecycleCoordinator: HerdrSessionLifecycleCoordinator = .shared,
        zellijSessionKillCoordinator: ZellijSessionKillCoordinator = .shared,
        herdrSessionRecordReader:
        @escaping HerdrSessionRecordReading = { name, host, arguments in
            await Task.detached(priority: .userInitiated) {
                HerdrSessionLifecycleClient().record(
                    named: name,
                    on: host,
                    sshConnectionArguments: arguments
                )
            }.value
        },
        herdrSessionMutator:
        @escaping HerdrSessionMutating = { action, record, host, arguments in
            await Task.detached(priority: .userInitiated) {
                let client = HerdrSessionLifecycleClient()
                return switch action {
                case .stop:
                    client.stop(
                        record,
                        on: host,
                        sshConnectionArguments: arguments
                    )
                case .delete:
                    client.delete(
                        record,
                        on: host,
                        sshConnectionArguments: arguments
                    )
                }
            }.value
        },
        herdrSSHConnectionSnapshotProvider:
        @escaping SSHConnectionSnapshotProvider =
            WorkspaceSceneModel.borrowedConnectionSnapshot,
        kwtBranchLister: @escaping KwtBranchLister = {
            projectPath, host in
            try await KwtWorktreeClient().branches(
                projectPath: projectPath,
                on: host
            )
        },
        kwtPullRequestLister: @escaping KwtPullRequestLister = {
            projectIdentity, host in
            try await KwtPullRequestClient().list(
                projectIdentity: projectIdentity,
                on: host
            )
        },
        kwtPullRequestImporter: @escaping KwtPullRequestImporter = {
            id, projectIdentity, host in
            try await KwtPullRequestClient().importPullRequest(
                id: id,
                projectIdentity: projectIdentity,
                on: host
            )
        },
        kwtProjectRegistration: @escaping KwtProjectRegistration = {
            projectPath, host in
            try await KwtProjectRegistryClient().register(
                projectPath: projectPath,
                on: host
            )
        },
        kwtProjectRemoval: @escaping KwtProjectRemoval = {
            projectPath, expectedRepository, expectedRegistration,
            routeIdentity, host in
            try await KwtProjectRegistryClient().unregister(
                projectPath: projectPath,
                expectedRepository: expectedRepository,
                expectedRegistration: expectedRegistration,
                expectedRouteIdentity: routeIdentity,
                on: host
            )
        },
        tmuxSessionDiscovery: @escaping TmuxSessionDiscovery = { host in
            let resolver = TmuxBinaryResolver()
            return switch host {
            case .local:
                await Task.detached(priority: .utility) {
                    resolver.discoverSessions()
                }.value
            case let .ssh(info):
                await resolver.discoverSessions(on: info)
            }
        },
        tmuxSessionValidationDiscovery:
        TmuxSessionValidationDiscovery? = { host, arguments in
            let resolver = TmuxBinaryResolver()
            return await WorkspaceSceneModel.runReconnectValidationProbe {
                switch host {
                case .local:
                    resolver.discoverSessions()
                case let .ssh(info):
                    resolver.discoverSessions(
                        on: info,
                        sshConnectionArguments: arguments
                    )
                }
            }
        },
        herdrSessionDiscovery: @escaping HerdrSessionDiscovery = { host in
            await HerdrInventoryClient().discover(on: host)
        },
        zellijSessionDiscovery: @escaping ZellijSessionDiscovery = { host in
            await ZellijInventoryClient().discover(on: host)
        },
        zellijSessionValidationDiscovery:
        @escaping ZellijSessionValidationDiscovery = { host, arguments in
            let probe = Task.detached(priority: .utility) {
                ZellijInventoryClient().discover(
                    on: host,
                    sshConnectionArguments: arguments
                )
            }
            return await withTaskCancellationHandler {
                await probe.value
            } onCancel: {
                probe.cancel()
            }
        },
        zellijSessionKiller:
        @escaping ZellijSessionKilling = { name, host, arguments in
            await Task.detached(priority: .userInitiated) {
                ZellijInventoryClient().kill(
                    sessionName: name,
                    on: host,
                    sshConnectionArguments: arguments
                )
            }.value
        },
        zellijSSHConnectionSnapshotProvider:
        @escaping SSHConnectionSnapshotProvider =
            WorkspaceSceneModel.borrowedConnectionSnapshot,
        presentationSSHConnectionProvider:
        (@MainActor @Sendable (UUID, SSHHostInfo) async throws
            -> KwtSSHConnection)? = nil,
        presentationSSHAcquisitionCoordinator:
        KwtSSHAcquisitionCoordinator = .shared,
        presentationSSHEnvironment: [String: String] =
            ProcessInfo.processInfo.environment,
        herdrSessionValidationDiscovery:
        @escaping HerdrSessionValidationDiscovery = { host, arguments in
            await WorkspaceSceneModel.runReconnectValidationProbe {
                HerdrInventoryClient().discover(
                    on: host,
                    sshConnectionArguments: arguments
                )
            }
        },
        herdrSessionExactProbe: @escaping HerdrSessionExactProbe = {
            name, host, arguments in
            await WorkspaceSceneModel.runReconnectValidationProbe {
                HerdrSessionProbeOutcome.exact(
                    name: name,
                    discovery: HerdrInventoryClient().discover(
                        on: host,
                        sshConnectionArguments: arguments
                    )
                )
            }
        },
        tmuxExactSessionProbe: @escaping TmuxSessionExactProbe = { target in
            await TmuxBinaryResolver().sessionExists(
                name: target.name,
                socketName: target.socketName,
                on: target.host
            )
        },
        tmuxSessionValidationExactProbe:
        TmuxSessionValidationExactProbe? = { target, arguments in
            await WorkspaceSceneModel.runReconnectValidationProbe {
                TmuxBinaryResolver().sessionExists(
                    name: target.name,
                    socketName: target.socketName,
                    on: target.host,
                    sshConnectionArguments: arguments
                )
            }
        },
        tmuxSessionKiller: @escaping ReviewedTmuxSessionKilling = {
            selection, identity, routeIdentity, host in
            try await TmuxSessionKiller().killReviewed(
                selection,
                expectedIdentity: identity,
                expectedRouteIdentity: routeIdentity,
                on: host
            )
        },
        tmuxSessionIdentityReader: @escaping TmuxSessionIdentityReading = {
            selection, host in
            try await TmuxSessionKiller().sessionIdentity(
                selection,
                on: host
            )
        },
        tmuxSessionIdentityReviewer:
        @escaping TmuxSessionIdentityReviewReading = {
            selection, knownIdentity, host in
            try await TmuxSessionKiller().reviewedIdentity(
                selection,
                knownIdentity: knownIdentity,
                on: host
            )
        },
        tmuxSessionStyler: @escaping TmuxSessionStyling = {
            style, selection, identity, host in
            try await TmuxSessionStyler().apply(
                style,
                to: selection,
                expectedIdentity: identity,
                on: host
            )
        },
        sshHostProbeRunner: @escaping SSHHostProbeRunner = {
            host, connectionArguments, command in
            let output = AccountCommandRunner(
                loginShellProvider: AccountCommandRunner.loginShell
            ).runRemoteLoginShell(
                host: host,
                connectionArguments: connectionArguments,
                command: command,
                timeout: 10,
                retryPolicy: .idempotent
            )
            return (output.status, output.stdout, output.stderr)
        },
        hostSSHConnectionProvider: HostSSHConnectionProvider? = nil,
        hostSSHSessionProvider: @escaping HostSSHSessionProvider = {
            KwtSSHConnectionSession(host: $0, destination: $1)
        },
        configuredSSHHostsProvider: @escaping () -> [SSHHost] = {
            SettingsStore.shared.sshHosts
        },
        configuredSSHHostsPublisher: AnyPublisher<[SSHHost], Never>? = nil,
        configuredExeHostsProvider: @escaping () -> [ExeConfiguredHost] = {
            ExeVMInventoryStore.shared.hosts
        },
        configuredExeHostsPublisher:
        AnyPublisher<[ExeConfiguredHost], Never>? = nil,
        refreshExeHosts: @escaping () -> Void = {
            _ = ExeVMInventoryStore.shared.refresh()
        },
        startExeHostInventory: @escaping () -> Void = {
            ExeVMInventoryStore.shared.start()
        },
        terminalColorsPublisher:
        AnyPublisher<[UInt: TerminalResolvedColors], Never>? = nil,
        sessionPreviewCoordinator: TmuxSessionPreviewCoordinator? = nil,
        sessionPreviewModePublisher:
        AnyPublisher<SessionPreviewMode, Never>? = nil,
        tmuxSessionActivityController:
        TmuxSessionActivityController? = nil,
        sceneSettings: WorkspaceSceneSettings = .live(),
        localHostID: UUID? = nil,
        overrideSnapshot: WorkspaceSnapshot? = nil,
        createdSessionDiscoveryDelays: [Duration] = [
            .milliseconds(500),
            .seconds(1),
            .seconds(2),
            .seconds(4),
        ],
        deferredTmuxPresentationRetryDelays: [Duration] = [
            .milliseconds(250), .milliseconds(500), .seconds(1), .seconds(2),
            .seconds(4), .seconds(8),
        ],
        tmuxReconnectIntervals: [Duration] = [
            .seconds(1), .seconds(2), .seconds(4), .seconds(8),
            .seconds(16), .seconds(30),
        ],
        tmuxReconnectProbeDeadline: Duration =
            SessionReconnectSupervisor.defaultProbeDeadline,
        startServices: Bool = false
    ) throws {
        self.database = database
        panelPreferenceStore = PanelPreferenceStore(database: database)
        panelRoutingService = PanelRoutingService(
            preferenceStore: panelPreferenceStore
        )
        self.workspaceConfiguration = workspaceConfiguration
        self.worktreeMutationCoordinator = worktreeMutationCoordinator
        self.workspaceInventoryStore = workspaceInventoryStore
        self.herdrLifecycleCoordinator = herdrLifecycleCoordinator
        self.zellijSessionKillCoordinator = zellijSessionKillCoordinator
        self.herdrSessionRecordReader = herdrSessionRecordReader
        self.herdrSessionMutator = herdrSessionMutator
        self.herdrSSHConnectionSnapshotProvider =
            herdrSSHConnectionSnapshotProvider
        self.sceneSettings = sceneSettings
        self.terminalRuntime = terminalRuntime
        self.kwtInventoryLoader = kwtInventoryLoader
        self.kwtConditionalInventoryLoader = kwtConditionalInventoryLoader
        self.kwtRemoteProvisioner = kwtRemoteProvisioner
        self.kwtRemoteInstaller = kwtRemoteInstaller
        self.kwtWorktreeCreator = kwtWorktreeCreator
        self.kwtWorktreeRemover = kwtWorktreeRemover
        self.kwtForceWorktreeRemover = kwtForceWorktreeRemover
        self.kwtWorktreeChangeReader = kwtWorktreeChangeReader
        self.sshRouteIdentityResolver = sshRouteIdentityResolver
        self.kwtBranchLister = kwtBranchLister
        self.kwtPullRequestLister = kwtPullRequestLister
        self.kwtPullRequestImporter = kwtPullRequestImporter
        self.kwtProjectRegistration = kwtProjectRegistration
        self.kwtProjectRemoval = kwtProjectRemoval
        self.tmuxSessionDiscovery = tmuxSessionDiscovery
        self.tmuxSessionValidationDiscovery =
            tmuxSessionValidationDiscovery
        self.tmuxSessionValidationExactProbe =
            tmuxSessionValidationExactProbe
        self.zellijSessionDiscovery = zellijSessionDiscovery
        self.zellijSessionValidationDiscovery =
            zellijSessionValidationDiscovery
        let zellijExecutableResolver:
            @Sendable (CommandHost, [String])
            -> Result<String, ZellijCommandError> = { host, arguments in
                if let nativeZellijPathProvider {
                    return nativeZellijPathProvider(host)
                }
                return ZellijInventoryClient().resolveExecutable(
                    on: host,
                    sshConnectionArguments: arguments
                )
            }
        self.zellijExecutableResolver = zellijExecutableResolver
        self.zellijSessionKiller = zellijSessionKiller
        self.zellijSSHConnectionSnapshotProvider =
            zellijSSHConnectionSnapshotProvider
        self.presentationSSHConnectionProvider =
            presentationSSHConnectionProvider
        self.presentationSSHAcquisitionCoordinator =
            presentationSSHAcquisitionCoordinator
        self.presentationSSHEnvironment = presentationSSHEnvironment
        tmuxSessionProbeBroker = TmuxSessionProbeBroker(
            discover: { host in
                let probe = Task.detached(priority: .utility) {
                    await tmuxSessionDiscovery(host)
                }
                return await withTaskCancellationHandler {
                    await probe.value
                } onCancel: {
                    probe.cancel()
                }
            },
            exactProbe: { target in
                let probe = Task.detached(priority: .utility) {
                    await tmuxExactSessionProbe(target)
                }
                return await withTaskCancellationHandler {
                    await probe.value
                } onCancel: {
                    probe.cancel()
                }
            }
        )
        self.tmuxReconnectIntervals = tmuxReconnectIntervals
        self.tmuxReconnectProbeDeadline = tmuxReconnectProbeDeadline
        herdrSessionProbeBroker = HerdrSessionProbeBroker(
            discover: { host in
                let probe = Task.detached(priority: .utility) {
                    await herdrSessionDiscovery(host)
                }
                return await withTaskCancellationHandler {
                    await probe.value
                } onCancel: {
                    probe.cancel()
                }
            }
        )
        self.herdrSessionValidationDiscovery =
            herdrSessionValidationDiscovery
        self.herdrSessionExactProbe = herdrSessionExactProbe
        herdrReconnectSupervisor = SessionReconnectSupervisor(
            intervals: tmuxReconnectIntervals,
            probeDeadline: tmuxReconnectProbeDeadline
        )
        zellijReconnectSupervisor = SessionReconnectSupervisor(
            intervals: tmuxReconnectIntervals,
            probeDeadline: tmuxReconnectProbeDeadline
        )
        self.tmuxSessionKiller = tmuxSessionKiller
        self.tmuxSessionIdentityReader = tmuxSessionIdentityReader
        self.tmuxSessionIdentityReviewer = tmuxSessionIdentityReviewer
        self.tmuxSessionStyler = tmuxSessionStyler
        self.tmuxPresentationStyleProvider =
            tmuxPresentationStyleProvider
        self.activeDisplayCount = activeDisplayCount
        self.sshHostProbeRunner = sshHostProbeRunner
        self.hostSSHConnectionProvider = hostSSHConnectionProvider
        self.hostSSHSessionProvider = hostSSHSessionProvider
        self.createdSessionDiscoveryDelays =
            createdSessionDiscoveryDelays
        self.deferredTmuxPresentationRetryDelays =
            deferredTmuxPresentationRetryDelays
        self.configuredSSHHostsProvider = configuredSSHHostsProvider
        self.configuredExeHostsProvider = configuredExeHostsProvider
        self.refreshExeHosts = refreshExeHosts
        self.startExeHostInventory = startExeHostInventory
        let terminalCoordinator = TerminalSurfaceCoordinator(
            runtime: terminalRuntime
        )
        terminalCoordinator.applicationShortcutsProvider = {
            SettingsStore.shared.shortcutPreferences.resolved
        }
        self.terminalCoordinator = terminalCoordinator
        tmuxSessionPreviewCoordinator = sessionPreviewCoordinator
            ?? TmuxSessionPreviewCoordinator(
                mode: SettingsStore.shared.sessionPreviewMode,
                snapshotter: TerminalSurfaceSnapshotter()
            )
        self.notificationService = notificationService
        self.tmuxSessionActivityController =
            tmuxSessionActivityController

        var snapshot = try overrideSnapshot ?? database.fetchSessionSnapshot()
        let resolvedLocalHostID = localHostID
            ?? snapshot.hosts.first(where: { $0.kind == .selfHost })?.id
            ?? WorkspaceSceneBootstrap.fallbackLocalHostID
        if !snapshot.hosts.contains(where: { $0.kind == .selfHost }),
           snapshot.host(id: resolvedLocalHostID) == nil {
            snapshot.hosts.insert(
                HostSummary(
                    id: resolvedLocalHostID,
                    configKey: "local",
                    name: ProcessInfo.processInfo.hostName,
                    kind: .selfHost,
                    platform: .macOS,
                    preferredTransport: .local,
                    decodedConnectionState: .local
                ),
                at: 0
            )
        }
        if startServices, overrideSnapshot == nil {
            snapshot = ConfiguredHostOverlay.apply(
                configuredSSHHostsProvider(),
                exeHosts: configuredExeHostsProvider(),
                to: snapshot
            )
            tmuxSessionActivityController?.reconcile(
                endpointsByHostID: Self.resolvedEndpoints(of: snapshot)
            )
        }
        self.snapshot = snapshot
        hasOverrideSnapshot = overrideSnapshot != nil
        self.localHostID = resolvedLocalHostID
        workspaceInventoryState = startServices ? .loading : .loaded
        let initialSelection = WorkspaceSelectionResolver.initialSelection(
            in: snapshot,
            localHostID: resolvedLocalHostID
        )
        let initialWorktreeVisibility =
            sceneSettings.worktreeVisibility()
        let normalizedSelection = initialSelection.normalized(
            in: snapshot,
            visibility: initialWorktreeVisibility
        )
        selection = normalizedSelection

        let tmuxResolver = TmuxBinaryResolver()
        let tmuxPathCache = TmuxPathCache(
            resolve: nativeTmuxPathProvider
                ?? tmuxResolver.resolveTmuxBinary
        )
        nativeTmuxSessionCoordinatorBacking = NativeTmuxSessionCoordinator(
            terminalCoordinator: nativeTmuxSurfaceStore
                ?? terminalCoordinator,
            tmuxPathProvider: {
                tmuxPathCache.resolveTmuxBinary()
            },
            localKwtPathProvider: localKwtPathProvider,
            presentationStyleProvider: {
                tmuxPresentationStyleProvider(nil)
            },
            appliesPresentationStyleToExistingSessionsProvider:
            appliesTmuxPresentationStyleToExistingSessionsProvider,
            remoteTmuxPathProvider: remoteTmuxPathProvider,
            remoteConnectionProvider: { [weak self] hostID, info in
                guard let self else { throw CancellationError() }
                return try await acquirePresentationSSHConnection(
                    hostID: hostID,
                    info: info
                )
            },
            paneSplitter: nativeTmuxPaneSplitter
        )
        nativeTmuxSessionCoordinatorBacking?.onStateChanged = {
            [weak self] handle, state in
            self?.nativeTmuxStateChanged(handle: handle, state: state)
        }
        nativeTmuxSessionCoordinatorBacking?.onSurfaceReady = {
            [weak self] handle in
            self?.tmuxSurfaceBecameReady(handle)
        }
        nativeTmuxSessionCoordinatorBacking?
            .onAttachedSessionIdentityUnavailable = {
                [weak self] handle in
                self?.tmuxAttachedSessionIdentityBecameUnavailable(handle)
            }
        nativeHerdrSessionCoordinatorBacking = NativeHerdrSessionCoordinator(
            terminalCoordinator: nativeHerdrSurfaceStore
                ?? terminalCoordinator,
            herdrPathProvider: { host, arguments in
                if let nativeHerdrPathProvider {
                    return nativeHerdrPathProvider(host)
                }
                return HerdrInventoryClient().resolveExecutable(
                    on: host,
                    sshConnectionArguments: arguments
                )
            },
            remoteConnectionProvider: { [weak self] hostID, info in
                guard let self else { throw CancellationError() }
                return try await acquirePresentationSSHConnection(
                    hostID: hostID,
                    info: info
                )
            },
            paneSplitCapabilityProvider:
            herdrPaneSplitCapabilityProvider ?? { host, arguments, path, name in
                HerdrInventoryClient().paneSplitCapability(
                    on: host,
                    herdrPath: path,
                    sessionName: name,
                    sshConnectionArguments: arguments
                )
            },
            paneSplitter: herdrPaneSplitter
        )
        nativeHerdrSessionCoordinatorBacking?.onStateChanged = {
            [weak self] handle, state in
            self?.nativeHerdrStateChanged(handle: handle, state: state)
        }
        nativeHerdrSessionCoordinatorBacking?.onSurfaceReady = {
            [weak self] handle in
            guard self?.activeBorrowedHerdrHandle == handle else { return }
            self?.objectWillChange.send()
            if self?.activeBorrowedHerdrRecoveryState != nil {
                self?.prepareActiveBorrowedHerdrSurface()
            }
        }
        nativeZellijSessionCoordinatorBacking = NativeZellijSessionCoordinator(
            terminalCoordinator: nativeZellijSurfaceStore
                ?? terminalCoordinator,
            zellijPathProvider: zellijExecutableResolver,
            remoteConnectionProvider: { [weak self] hostID, info in
                guard let self else { throw CancellationError() }
                return try await acquirePresentationSSHConnection(
                    hostID: hostID,
                    info: info
                )
            }
        )
        nativeZellijSessionCoordinatorBacking?.onStateChanged = {
            [weak self] handle, state in
            self?.nativeZellijStateChanged(handle: handle, state: state)
        }
        nativeZellijSessionCoordinatorBacking?.onSurfaceReady = {
            [weak self] handle in
            guard let self, activeBorrowedZellijHandle == handle else { return }
            objectWillChange.send()
            prepareActiveBorrowedZellijSurface()
        }
        activityControllerBacking = ActivityMonitoringController(
            notificationService: notificationService,
            snapshotProvider: { [weak self] in
                self?.snapshot ?? WorkspaceSnapshot.empty
            },
            selectionProvider: { [weak self] in
                self?.selection ?? WorkspaceSelection(
                    selectedHostID: UUID()
                )
            },
            workspaceConfigurationProvider: { [weak self] in
                self?.workspaceConfiguration
                    ?? .defaults()
            },
            persistedSessionRecordsByIDProvider: { [:] },
            defaultIdleThresholdSecondsProvider: { [weak self] in
                self?.defaultIdleThresholdSeconds ?? 30
            },
            isApplicationActiveProvider: { [weak self] in
                self?.isApplicationActiveForResourceMonitoring
                    ?? true
            },
            surfaceEntriesProvider: { [weak self] in
                self?.terminalCoordinator.surfaceEntries() ?? []
            },
            surfaceKeyForIdentityProvider: {
                [weak self] identity in
                self?.terminalCoordinator.surfaceKey(
                    forSurfaceIdentity: identity
                )
            },
            sessionIDForKeyProvider: { _ in nil },
            controlModeProcessRootProvider: { _ in nil },
            leafSessionIDsByWorktreeIDProvider: { [:] },
            updateLastOutputAtHandler: {
                [weak self] sessionID, date in
                try self?.database.terminalSessions
                    .updateLastOutputAt(
                        sessionID: sessionID,
                        at: date
                    )
            },
            updateLastViewedAtHandler: {
                [weak self] worktreeID, hostID, date in
                guard let self else { return }
                let wt = self.snapshot.worktree(id: worktreeID)
                let host = self.snapshot.host(id: hostID)
                let hostKey = host?.configKey ?? ""
                let scopedKey = wt?.scopedKey
                    ?? "worktree:\(worktreeID.uuidString)"
                try self.database.presentationState
                    .upsertLastViewedAt(
                        hostID: hostKey,
                        scopedKey: scopedKey,
                        at: date
                    )
            },
            updateLastAgentActivityHandler: {
                [weak self] worktreeID, hostID, date in
                guard let self else { return }
                let wt = self.snapshot.worktree(id: worktreeID)
                let host = self.snapshot.host(id: hostID)
                let hostKey = host?.configKey ?? ""
                let scopedKey = wt?.scopedKey
                    ?? "worktree:\(worktreeID.uuidString)"
                try self.database.presentationState
                    .upsertLastAgentActivity(
                        hostID: hostKey,
                        scopedKey: scopedKey,
                        at: date
                    )
            },
            fetchEnrichedSnapshotHandler: { [weak self] in
                guard let self else {
                    return WorkspaceSnapshot.empty
                }
                return try fetchEnrichedSnapshot()
            },
            applySnapshotHandler: { [weak self] snapshot in
                self?.snapshot = snapshot
            },
            renderTrackerDrainProvider: { [weak self] in
                self?.terminalRuntime.renderTracker.drain() ?? [:]
            },
            aliveSessions: { [weak self] in
                self?.snapshot.sessions.filter(\.isAlive) ?? []
            }
        )
        activityController.installResourceSamplingCoordinator(
            makeResourceSamplingCoordinator()
        )
        if let worktreeID = normalizedSelection.selectedWorktreeID {
            activityController
                .activateWorktreeForResourceMonitoringIfNeeded(
                    worktreeID
                )
        }
        activityCancellable = activityController.objectWillChange.sink { [weak self] _ in
            self?.objectWillChange.send()
        }
        tmuxSessionActivityCancellable = tmuxSessionActivityController?
            .objectWillChange.sink { [weak self] _ in
                self?.objectWillChange.send()
            }
        terminalColorsCancellable = (terminalColorsPublisher
            ?? terminalRuntime.$resolvedTerminalColorsBySurface
            .eraseToAnyPublisher())
            .dropFirst()
            .sink { [weak self] _ in
                DispatchQueue.main.async { [weak self] in
                    self?.terminalPresentationStyleDidChange()
                }
            }
        let previewModePublisher = sessionPreviewModePublisher
            ?? (sessionPreviewCoordinator == nil
                ? SettingsStore.shared.$sessionPreviewMode
                .eraseToAnyPublisher()
                : nil)
        // Forward panel routing changes to WSM's
        // objectWillChange so SwiftUI picks up state.
        panelRoutingCancellable = panelRoutingService
            .objectWillChange.sink { [weak self] _ in
                self?.objectWillChange.send()
            }
        worktreeMutationCancellable = worktreeMutationCoordinator.events.sink {
            [weak self] event in
            self?.worktreeMutationEvent(event)
        }
        workspaceInventoryCancellable = workspaceInventoryStore.$snapshot
            .sink { [weak self] snapshot in
                self?.consumeSharedInventory(snapshot)
            }
        publishProtectedTmuxEndpoints()
        herdrLifecycleCancellable = herdrLifecycleCoordinator.events.sink {
            [weak self] event in
            self?.herdrLifecycleEvent(event)
        }
        zellijSessionKillCancellable = zellijSessionKillCoordinator.events.sink {
            [weak self] event in
            self?.zellijSessionKillEvent(event)
        }
        let quarantinedScopes = Set(
            worktreeMutationCoordinator.quarantinedProjectRemovals.keys
        )
        fencedWorktreeMutationScopes = worktreeMutationCoordinator.scopes
            .subtracting(quarantinedScopes)
        pendingWorktreeRemovals = worktreeMutationCoordinator.pendingRemovals
        let sshHostsPublisher = configuredSSHHostsPublisher
            ?? SettingsStore.shared.$sshHosts.eraseToAnyPublisher()
        let exeHostsPublisher = configuredExeHostsPublisher
            ?? ExeVMInventoryStore.shared.$hosts.eraseToAnyPublisher()
        // Defer post-init work that mutates @Published state to
        // avoid "Publishing changes from within view updates" when
        // @StateObject creates the model during body evaluation.
        DispatchQueue.main.async {
            [self, sshHostsPublisher, exeHostsPublisher, previewModePublisher] in
            guard !isShutDown else { return }
            sessionPreviewModeCancellable = previewModePublisher?
                .removeDuplicates()
                .sink { [weak self] mode in
                    self?.sessionPreviewModeDidChange(mode)
                }
            configuredSSHHostsCancellable = sshHostsPublisher.sink {
                [weak self] hosts in
                guard let self, !self.hasOverrideSnapshot else { return }
                self.snapshot = applyingConfiguredSSHHosts(
                    hosts,
                    exeHosts: configuredExeHostsProvider(),
                    to: self.snapshot
                )
            }
            configuredExeHostsCancellable = exeHostsPublisher.sink {
                [weak self] hosts in
                guard let self, !self.hasOverrideSnapshot else { return }
                self.snapshot = applyingConfiguredSSHHosts(
                    configuredSSHHostsProvider(),
                    exeHosts: hosts,
                    to: self.snapshot
                )
            }
            if startServices {
                startExeHostInventory()
                startTmuxSessionDiscovery()
                startHerdrSessionDiscovery()
                startZellijSessionDiscovery()
                startKwtInventory()
                syncTerminalConfig()
                startResourceMonitoringLoop()
                activityController.startOutputFlushLoop()
                subscribeChildExitEvents()
                subscribeAppActivity()
                subscribeDisplayAvailability()
                activityController
                    .refreshWorkspaceResourceSummary()
                installShortcutMonitor()
                Task {
                    await notificationService
                        .requestAuthorization()
                }
            } else {
                reconcileInventoryHosts()
                activityController
                    .refreshWorkspaceResourceSummary()
            }
        }
    }

    deinit {
        // Cancel Combine subscriptions first so no new events
        // arrive from child controllers during teardown.
        activityCancellable?.cancel()
        tmuxSessionActivityCancellable?.cancel()
        panelRoutingCancellable?.cancel()
        configuredSSHHostsCancellable?.cancel()
        configuredExeHostsCancellable?.cancel()
        terminalColorsCancellable?.cancel()
        sessionPreviewModeCancellable?.cancel()
        workspaceInventoryCancellable?.cancel()
        let workspaceInventoryStore = workspaceInventoryStore
        let workspaceInventorySubscriberID = workspaceInventorySubscriberID
        Task { @MainActor in
            workspaceInventoryStore.removeSubscriber(
                id: workspaceInventorySubscriberID
            )
        }
        worktreeMutationCancellable?.cancel()
        let mutationCoordinator = worktreeMutationCoordinator
        let mutationParticipantID = worktreeMutationParticipantID
        Task { @MainActor in
            mutationCoordinator.retireProtectedEndpoints(
                for: mutationParticipantID
            )
        }
        herdrLifecycleCancellable?.cancel()
        zellijSessionKillCancellable?.cancel()
        herdrDiscoveryTask?.cancel()
        herdrShortcutNavigationTask?.cancel()
        zellijDiscoveryTask?.cancel()
        zellijCreationDiscoveryRetryTask?.cancel()
        zellijCreationDiscoveryRetryTask = nil
        zellijCreationDiscoveryRetryID = nil
        zellijPresentationTask?.cancel()
        zellijRestorationValidationTask?.cancel()
        createdSessionDiscoveryTasks.values.forEach { $0.cancel() }
        herdrLaunchConfirmationTasks.values.forEach { $0.cancel() }
        deferredTmuxPresentationTasks.values.forEach { $0.cancel() }
        tmuxActivityEnrollmentTasks.values.forEach { $0.cancel() }
        childExitCancellable?.cancel()
        appDidBecomeActiveCancellable?.cancel()
        appDidResignActiveCancellable?.cancel()
        screenParametersCancellable?.cancel()
        shortcutMonitor?.uninstall()
        // Nil out controller backings so their deinits run now,
        // cancelling detached tasks that could fire closures
        // against this partially deallocated instance.
        activityControllerBacking = nil
    }

    func beginRestoration(
        _ state: WorkspaceWindowState,
        launchIntent: WorkspaceWindowLaunchIntent? = nil
    ) {
        guard state.navigation != nil || state.tmux != nil
            || state.herdr != nil || state.zellij != nil else { return }
        if let launchIntent {
            pendingRestorationLaunchIntent = launchIntent
        } else if pendingRestoration?.windowID != state.windowID {
            pendingRestorationLaunchIntent = nil
        }
        zellijRestorationRoute = state.zellij.flatMap { descriptor in
            guard let hostSummary = snapshot.hosts.first(where: {
                $0.configKey == descriptor.hostKey
            }),
                let host = CommandHostResolver.resolve(hostSummary),
                Self.supportsZellij(host)
            else { return nil }
            return ZellijRestorationRoute(
                id: UUID(),
                state: state,
                selection: WorkspaceZellijSessionSelection(
                    hostID: hostSummary.id,
                    name: descriptor.sessionName
                ),
                host: host,
                routeIdentity: nil
            )
        }
        pendingRestoration = state
        isWorkspaceRestorationPending = true
        suppressesAutomaticWorktreeSessionOpen = true
        attemptPendingRestoration()
    }

    func cancelPendingRestoration() {
        pendingRestoration = nil
        pendingRestorationLaunchIntent = nil
        isWorkspaceRestorationPending = false
        suppressesAutomaticWorktreeSessionOpen = false
        protectedRestorationProbeTask?.cancel()
        protectedRestorationProbeTask = nil
        protectedRestorationProbeID = nil
        protectedRestorationRefreshPending = false
        herdrRestorationValidationTask?.cancel()
        herdrRestorationValidationTask = nil
        herdrRestorationValidationID = nil
        zellijRestorationValidationTask?.cancel()
        zellijRestorationValidationTask = nil
        zellijRestorationValidationID = nil
        zellijRestorationRoute = nil
    }

    func restorationState(windowID: UUID) -> WorkspaceWindowState {
        if var pendingRestoration {
            pendingRestoration.windowID = windowID
            return pendingRestoration
        }
        return WorkspaceWindowState.capture(
            windowID: windowID,
            selection: selection,
            activeTmux: activeBorrowedTmuxSelection,
            activeHerdr: activeBorrowedHerdrSelection,
            activeZellij: activeBorrowedZellijSelection,
            snapshot: snapshot
        )
    }

    func selectFromUser(_ newSelection: WorkspaceSelection) {
        cancelPendingRestoration()
        cancelPendingHerdrShortcutNavigation()
        invalidateZellijPresentationIntent()
        userNavigationRevision &+= 1
        cancelPendingTmuxPreviewActivations()
        if let worktreeID = newSelection.selectedWorktreeID {
            explicitlyDismissedWorktreePresentationIDs.remove(worktreeID)
        }
        if let directoryID = newSelection.selectedDirectoryWorkspaceID {
            explicitlyDismissedDirectoryPresentationIDs.remove(directoryID)
        }
        selection = newSelection
        attachReplacedWorktreeSessionIfNeeded()
    }

    /// An active presentation keeps the worktree generation it observed even
    /// when inventory replaces the worktree behind the same runtime ID.
    /// Explicitly reselecting that worktree is the user asking for the
    /// canonical target, so attach the replacement session.
    private func attachReplacedWorktreeSessionIfNeeded() {
        guard let active = activeBorrowedTmuxSelection,
              let activeGeneration = active.worktreeGeneration,
              let replacement = WorkspaceSidebarModel.tmuxSessionSelection(
                  for: selection,
                  in: snapshot
              ),
              replacement.worktreeID == active.worktreeID,
              let generation = WorktreeGeneration.canonical(
                  replacement.worktreeGeneration
              ),
              generation != activeGeneration
        else { return }
        invalidateBorrowedTmuxSession(active)
        openBorrowedTmuxSession(replacement)
    }

    func synchronizeSelection(_ newSelection: WorkspaceSelection) {
        guard newSelection != selection else { return }
        invalidateZellijPresentationIntent()
        selection = newSelection
    }

    func cancelPendingZellijPresentation() {
        invalidateZellijPresentationIntent()
    }

    private func invalidateZellijPresentationIntent() {
        zellijPresentationRevision &+= 1
        zellijPresentationTask?.cancel()
        zellijPresentationTask = nil
        zellijPresentationIntent = nil
    }

    private func applyRestoredSelection(_ restored: WorkspaceSelection) {
        selection = restored
    }

    private func attemptPendingRestoration() {
        guard let pendingRestoration else { return }
        if protectedRestorationProbeTask != nil {
            protectedRestorationRefreshPending = true
            return
        }
        guard herdrRestorationValidationTask == nil,
              zellijRestorationValidationTask == nil else { return }
        switch WorkspaceWindowRestorationResolver.resolve(
            pendingRestoration,
            in: snapshot,
            launchIntent: pendingRestorationLaunchIntent,
            herdrFreshHostIDs: herdrFreshHostIDs,
            zellijFreshHostIDs: zellijFreshHostIDs,
            pendingHerdrSessions: pendingHerdrSessionSelections
        ) {
        case .invalid:
            cancelPendingRestoration()
        case let .pending(resolvedSelection):
            if let resolvedSelection {
                applyRestoredSelection(resolvedSelection)
            }
        case let .ready(resolvedSelection, presentation):
            switch presentation {
            case let .tmux(tmuxSelection):
                applyRestoredSelection(resolvedSelection)
                _ = presentTmuxSession(
                    tmuxSelection,
                    launchMode: .attach,
                    intent: pendingRestorationLaunchIntent == .openWorktree
                        ? .userInitiated
                        : .restoreOnly
                )
                suppressesAutomaticWorktreeSessionOpen = false
            case let .herdr(herdrSelection):
                beginHerdrRestorationValidation(
                    selection: resolvedSelection,
                    herdrSelection: herdrSelection,
                    expectedState: pendingRestoration
                )
                return
            case let .zellij(zellijSelection):
                beginZellijRestorationValidation(
                    selection: resolvedSelection,
                    zellijSelection: zellijSelection,
                    expectedState: pendingRestoration
                )
                return
            case nil:
                applyRestoredSelection(resolvedSelection)
            }
            self.pendingRestoration = nil
            pendingRestorationLaunchIntent = nil
            isWorkspaceRestorationPending = false
        case let .needsProtectedProbe(resolvedSelection, tmuxSelection):
            beginProtectedRestorationProbe(
                selection: resolvedSelection,
                tmuxSelection: tmuxSelection,
                expectedState: pendingRestoration
            )
        }
    }

    private func beginHerdrRestorationValidation(
        selection resolvedSelection: WorkspaceSelection,
        herdrSelection: WorkspaceHerdrSessionSelection,
        expectedState: WorkspaceWindowState
    ) {
        guard herdrRestorationValidationTask == nil else { return }
        let validationID = UUID()
        herdrRestorationValidationID = validationID
        herdrRestorationValidationTask = Task { [weak self] in
            guard let self else { return }
            let validation: HerdrSessionValidation
            do {
                validation = try await revalidatedHerdrSession(
                    herdrSelection
                )
            } catch HerdrSessionPresentationError
                .routeChangedDuringValidation {
                cancelHerdrRestorationValidation(
                    validationID,
                    expectedState: expectedState
                )
                return
            } catch {
                retryHerdrRestorationValidation(
                    validationID,
                    expectedState: expectedState,
                    hostID: herdrSelection.hostID
                )
                return
            }
            guard !Task.isCancelled,
                  herdrRestorationValidationID == validationID,
                  pendingRestoration == expectedState
            else { return }
            let currentResolution = WorkspaceWindowRestorationResolver.resolve(
                expectedState,
                in: snapshot,
                herdrFreshHostIDs: herdrFreshHostIDs,
                pendingHerdrSessions: pendingHerdrSessionSelections
            )
            if case .invalid = currentResolution {
                cancelHerdrRestorationValidation(
                    validationID,
                    expectedState: expectedState
                )
                return
            }
            guard case let .ready(
                currentSelection,
                currentPresentation
            ) = currentResolution,
                case let .herdr(currentHerdrSelection) =
                currentPresentation,
                currentSelection == resolvedSelection,
                currentHerdrSelection == herdrSelection,
                validation.session?.name == herdrSelection.name,
                validation.session?.state == .running
            else {
                retryHerdrRestorationValidation(
                    validationID,
                    expectedState: expectedState,
                    hostID: herdrSelection.hostID
                )
                return
            }
            herdrRestorationValidationTask = nil
            herdrRestorationValidationID = nil
            applyRestoredSelection(resolvedSelection)
            guard presentHerdrSession(
                herdrSelection,
                validation: validation
            ) != nil else {
                cancelPendingRestoration()
                return
            }
            pendingRestoration = nil
            isWorkspaceRestorationPending = false
            suppressesAutomaticWorktreeSessionOpen = false
        }
    }

    private func cancelHerdrRestorationValidation(
        _ validationID: UUID,
        expectedState: WorkspaceWindowState
    ) {
        guard herdrRestorationValidationID == validationID else { return }
        herdrRestorationValidationTask = nil
        herdrRestorationValidationID = nil
        guard pendingRestoration == expectedState else { return }
        cancelPendingRestoration()
    }

    private func retryHerdrRestorationValidation(
        _ validationID: UUID,
        expectedState: WorkspaceWindowState,
        hostID: UUID
    ) {
        guard herdrRestorationValidationID == validationID else { return }
        herdrRestorationValidationTask = nil
        herdrRestorationValidationID = nil
        guard pendingRestoration == expectedState else { return }
        herdrFreshHostIDs.remove(hostID)
        scheduleHerdrSessionDiscovery()
    }

    private func beginZellijRestorationValidation(
        selection resolvedSelection: WorkspaceSelection,
        zellijSelection: WorkspaceZellijSessionSelection,
        expectedState: WorkspaceWindowState
    ) {
        guard zellijRestorationValidationTask == nil,
              let hostSummary = snapshot.host(id: zellijSelection.hostID),
              let host = CommandHostResolver.resolve(hostSummary),
              Self.supportsZellij(host)
        else { return }
        let killKey = ZellijSessionKillCoordinator.Key(
            hostID: zellijSelection.hostID,
            sessionName: zellijSelection.name
        )
        if let route = zellijRestorationRoute,
           route.state == expectedState {
            guard route.selection == zellijSelection,
                  route.host == host
            else {
                cancelPendingRestoration()
                return
            }
        } else {
            zellijRestorationRoute = ZellijRestorationRoute(
                id: UUID(),
                state: expectedState,
                selection: zellijSelection,
                host: host,
                routeIdentity: nil
            )
        }
        let validationID = UUID()
        zellijRestorationValidationID = validationID
        zellijRestorationValidationTask = Task { [weak self] in
            guard let self else { return }
            let connection = await zellijConnectionSnapshot(on: host)
            guard !Task.isCancelled,
                  zellijRestorationValidationID == validationID,
                  pendingRestoration == expectedState
            else { return }
            guard snapshot.host(id: zellijSelection.hostID)
                .flatMap(CommandHostResolver.resolve) == host,
                var route = zellijRestorationRoute,
                route.state == expectedState,
                route.selection == zellijSelection,
                route.host == host
            else {
                cancelZellijRestorationValidation(
                    validationID,
                    expectedState: expectedState
                )
                return
            }
            if let frozenRouteIdentity = route.routeIdentity {
                guard frozenRouteIdentity == connection.routeIdentity else {
                    cancelZellijRestorationValidation(
                        validationID,
                        expectedState: expectedState
                    )
                    return
                }
            } else {
                route.routeIdentity = connection.routeIdentity
                zellijRestorationRoute = route
            }
            guard !zellijSessionKillCoordinator.isPending(killKey) else {
                zellijRestorationValidationTask = nil
                zellijRestorationValidationID = nil
                return
            }
            let killRevision = zellijSessionKillCoordinator.revision(
                for: killKey
            )
            let validation = await validatedZellijSession(
                on: host,
                connection: connection
            )
            guard !Task.isCancelled,
                  zellijRestorationValidationID == validationID,
                  pendingRestoration == expectedState
            else { return }
            guard let validation else {
                cancelZellijRestorationValidation(
                    validationID,
                    expectedState: expectedState
                )
                return
            }
            guard snapshot.host(id: zellijSelection.hostID)
                .flatMap(CommandHostResolver.resolve) == host else {
                cancelZellijRestorationValidation(
                    validationID,
                    expectedState: expectedState
                )
                return
            }
            let currentResolution = WorkspaceWindowRestorationResolver.resolve(
                expectedState,
                in: snapshot,
                zellijFreshHostIDs: zellijFreshHostIDs
            )
            guard case let .ready(
                currentSelection,
                currentPresentation
            ) = currentResolution,
                case let .zellij(currentZellijSelection) = currentPresentation,
                currentSelection == resolvedSelection,
                currentZellijSelection == zellijSelection,
                !zellijSessionKillCoordinator.isPending(killKey),
                killRevision
                == zellijSessionKillCoordinator.revision(for: killKey),
                case let .available(names) = validation.result,
                names.contains(zellijSelection.name)
            else {
                retryZellijRestorationValidation(
                    validationID,
                    expectedState: expectedState,
                    hostID: zellijSelection.hostID
                )
                return
            }
            zellijRestorationValidationTask = nil
            zellijRestorationValidationID = nil
            applyRestoredSelection(resolvedSelection)
            guard presentZellijSession(
                zellijSelection,
                validation: validation,
                expectedKillRevision: killRevision
            ) != nil else {
                cancelPendingRestoration()
                return
            }
            pendingRestoration = nil
            isWorkspaceRestorationPending = false
            suppressesAutomaticWorktreeSessionOpen = false
            zellijRestorationRoute = nil
        }
    }

    private func cancelZellijRestorationValidation(
        _ validationID: UUID,
        expectedState: WorkspaceWindowState
    ) {
        guard zellijRestorationValidationID == validationID else { return }
        zellijRestorationValidationTask = nil
        zellijRestorationValidationID = nil
        guard pendingRestoration == expectedState else { return }
        cancelPendingRestoration()
    }

    private func retryZellijRestorationValidation(
        _ validationID: UUID,
        expectedState: WorkspaceWindowState,
        hostID: UUID
    ) {
        guard zellijRestorationValidationID == validationID else { return }
        zellijRestorationValidationTask = nil
        zellijRestorationValidationID = nil
        guard pendingRestoration == expectedState else { return }
        zellijFreshHostIDs.remove(hostID)
        scheduleZellijSessionDiscovery()
    }

    private func beginProtectedRestorationProbe(
        selection resolvedSelection: WorkspaceSelection,
        tmuxSelection: WorkspaceTmuxSessionSelection,
        expectedState: WorkspaceWindowState
    ) {
        guard protectedRestorationProbeTask == nil,
              let hostSummary = snapshot.host(id: tmuxSelection.hostID),
              let host = CommandHostResolver.resolve(hostSummary)
        else { return }
        let probeID = UUID()
        protectedRestorationProbeID = probeID
        protectedRestorationProbeTask = Task { [weak self] in
            defer {
                if self?.protectedRestorationProbeID == probeID {
                    self?.protectedRestorationProbeTask = nil
                    self?.protectedRestorationProbeID = nil
                }
            }
            do {
                _ = try await self?.tmuxSessionIdentityReader(
                    tmuxSelection,
                    host
                )
            } catch {
                self?.retryProtectedRestorationAfterProbeCleanupIfNeeded(
                    probeID
                )
                return
            }
            guard !Task.isCancelled,
                  let self,
                  protectedRestorationProbeID == probeID else {
                return
            }
            guard pendingRestoration == expectedState,
                  case let .needsProtectedProbe(
                      currentSelection,
                      currentTmuxSelection
                  ) = WorkspaceWindowRestorationResolver.resolve(
                      expectedState,
                      in: snapshot
                  ),
                  let currentHostSummary = snapshot.host(
                      id: tmuxSelection.hostID
                  ),
                  let currentHost = CommandHostResolver.resolve(
                      currentHostSummary
                  )
            else {
                retryProtectedRestorationAfterProbeCleanupIfNeeded(probeID)
                return
            }
            guard currentSelection == resolvedSelection,
                  currentTmuxSelection == tmuxSelection,
                  currentHost == host else {
                retryProtectedRestorationAfterProbeCleanupIfNeeded(probeID)
                return
            }
            protectedRestorationRefreshPending = false
            applyRestoredSelection(resolvedSelection)
            _ = presentTmuxSession(
                tmuxSelection,
                launchMode: .attach,
                intent: .restoreOnly
            )
            pendingRestoration = nil
            isWorkspaceRestorationPending = false
            suppressesAutomaticWorktreeSessionOpen = false
        }
    }

    private func retryProtectedRestorationAfterProbeCleanupIfNeeded(
        _ probeID: UUID
    ) {
        guard protectedRestorationProbeID == probeID,
              protectedRestorationRefreshPending else { return }
        protectedRestorationRefreshPending = false
        Task { @MainActor [weak self] in
            await Task.yield()
            self?.attemptPendingRestoration()
        }
    }

    /// Releases per-window terminal connection resources while preserving the
    /// tmux server sessions they attach to. Called by `WorkspaceWindow` before
    /// the scene model leaves the app-level window registry.
    func shutdown() async {
        guard !isShutDown else { return }
        isShutDown = true
        cancelAllPresentationSSHAcquisitions()
        configuredSSHHostsCancellable?.cancel()
        configuredExeHostsCancellable?.cancel()
        workspaceInventoryCancellable?.cancel()
        workspaceInventoryStore.removeSubscriber(
            id: workspaceInventorySubscriberID
        )
        worktreeMutationCancellable?.cancel()
        worktreeMutationCoordinator.retireProtectedEndpoints(
            for: worktreeMutationParticipantID
        )
        sceneActivityGeneration &+= 1
        userNavigationRevision &+= 1
        alwaysLiveTmuxSurfaceLaunchTask?.cancel()
        alwaysLiveTmuxSurfaceLaunchTask = nil
        alwaysLiveTmuxSurfaceLaunchID = nil
        pendingAlwaysLiveTmuxSurfaceHandles.removeAll()
        pendingAlwaysLiveTmuxSurfaceHandleIDs.removeAll()
        cancelPendingRestoration()
        cancelPendingHerdrShortcutNavigation()
        for presentation in retainedTmuxPresentations.values {
            presentation.previewPromotionID = nil
            presentation.previewPromotionNavigationRevision = nil
            presentation.previewPromotionTask?.cancel()
            presentation.previewPromotionTask = nil
            tmuxSessionPreviewCoordinator.remove(
                TmuxPresentationKey(presentation.selection).previewKey,
                reason: .close
            )
            cancelTmuxReconnect(presentation)
        }
        tmuxSessionPreviewCoordinator.shutdown()
        releaseAllProtectedTmuxAttachmentScopes()
        retainedTmuxPresentations.removeAll()
        retainedTmuxPresentationKeysByHandle.removeAll()
        pendingRemovalPresentationRestorations.removeAll()
        activeBorrowedTmuxSelection = nil
        activeBorrowedTmuxHandle = nil
        activeBorrowedTmuxLaunchMode = nil
        cancelHerdrReconnect()
        failedHerdrLaunchIntent = nil
        herdrLifecycleAuthorities.removeAll()
        herdrLifecycleCancellable?.cancel()
        zellijSessionKillCancellable?.cancel()
        herdrDiscoveryTask?.cancel()
        zellijDiscoveryTask?.cancel()
        zellijCreationDiscoveryRetryTask?.cancel()
        zellijCreationDiscoveryRetryTask = nil
        zellijCreationDiscoveryRetryID = nil
        createdSessionDiscoveryTasks.values.forEach { $0.cancel() }
        createdSessionDiscoveryTasks.removeAll()
        herdrLaunchConfirmationTasks.values.forEach { $0.cancel() }
        herdrLaunchConfirmationTasks.removeAll()
        deferredTmuxPresentationTasks.values.forEach { $0.cancel() }
        deferredTmuxPresentationTasks.removeAll()
        tmuxActivityEnrollmentTasks.values.forEach { $0.cancel() }
        tmuxActivityEnrollmentTasks.removeAll()
        drainingDeferredTmuxPresentationTasks.removeAll()
        exhaustedCreatedTmuxSessionHandles.removeAll()
        endedCreatedTmuxSessionHandles.removeAll()
        confirmedEndedTmuxSessionHandles.removeAll()
        failPendingHerdrLaunchOperations { _ in true }
        invalidateZellijPresentationIntent()
        cancelZellijReconnect()
        zellijKillAuthorities.removeAll()
        pendingCreatedZellijSessions.removeAll()
        failedZellijCreationIntent = nil
        suppressedZellijKillPresentations.removeAll()
        activeBorrowedZellijSelection = nil
        activeBorrowedZellijHandle = nil
        await withTaskGroup(of: Void.self) { group in
            if let coordinator = nativeTmuxSessionCoordinatorBacking {
                group.addTask { await coordinator.shutdown() }
            }
            if let coordinator = nativeHerdrSessionCoordinatorBacking {
                group.addTask { await coordinator.shutdown() }
            }
            if let coordinator = nativeZellijSessionCoordinatorBacking {
                group.addTask { await coordinator.shutdown() }
            }
        }
        hostSSHSession?.cancel()
        hostSSHSession = nil
        hostSSHSessionDestination = nil
        hostSSHSessionOwnerID = nil
        hostSSHSessionSurfaceID = nil
    }

    /// Refreshes the sidebar from provider, kwt, and tmux inventories.
    func refreshWorkspaceInventory() {
        refreshHosts()
        refreshKwtInventory()
    }

    /// Refreshes the sidebar directly from each host's kwt and tmux inventory.
    func refreshKwtInventory() {
        workspaceInventoryStore.refreshAll(
            for: workspaceInventorySubscriberID
        )
        refreshHerdrSessionDiscovery()
        refreshZellijSessionDiscovery()
    }

    func startKwtInventory() {
        guard !kwtInventoryEnabled else { return }
        kwtInventoryEnabled = true
        reconcileInventoryHosts()
        updateSharedInventorySubscription()
    }

    func createWorktree(_ request: WorktreeCreateRequest) async throws {
        guard GitBranchName.isValid(request.branchName) else {
            throw KwtWorktreeError.invalidBranchName
        }
        guard let project = snapshot.project(id: request.projectID),
              snapshot.canCreateWorktree(in: project),
              let hostSummary = snapshot.host(id: project.hostID),
              let host = CommandHostResolver.resolve(hostSummary)
        else {
            throw KwtWorktreeError.projectUnavailable
        }

        let mutationHostID = project.hostID
        let mutationProjectIdentity = project.scopedKey
        guard !ownsWorktreeMutation else {
            throw KwtWorktreeError.creationInProgress
        }
        ownsWorktreeMutation = true
        guard worktreeMutationCoordinator.acquire(
            hostID: mutationHostID,
            projectIdentity: mutationProjectIdentity
        ) else {
            ownsWorktreeMutation = false
            throw KwtWorktreeError.creationInProgress
        }
        invalidateKwtInventoryRefresh()
        let mutation = kwtMutationPublication(hostID: mutationHostID)
        defer {
            ownsWorktreeMutation = false
            worktreeMutationCoordinator.release(
                hostID: mutationHostID,
                projectIdentity: mutationProjectIdentity
            )
        }

        do {
            try await ensureRemoteKwtForOperation(hostID: project.hostID)
            guard let current = validatedProjectOperationTarget(
                project,
                capturedHost: host
            ) else {
                throw KwtWorktreeError.projectUnavailable
            }
            try await kwtWorktreeCreator(
                request,
                current.project.rootPath,
                current.host
            )
            cancelPendingRestoration()

            let refreshed = try await kwtInventoryLoader(current.host)
            applyAuthoritativeKwtInventory(
                refreshed,
                hostID: current.project.hostID,
                mutation: mutation
            )
        } catch {
            recordKwtUnavailability(error, hostID: project.hostID)
            throw error
        }

        guard let created = snapshot.worktrees.first(where: {
            $0.projectID == project.id && $0.branch == request.branchName
        }) else {
            throw KwtWorktreeError.createdWorktreeMissing(
                branch: request.branchName
            )
        }
        var createdSelection = selection
        createdSelection.select(
            .worktree(created.id),
            in: snapshot,
            visibility: worktreeVisibility
        )
        selectFromUser(createdSelection)
    }

    func branches(
        for projectID: UUID
    ) async throws -> [WorktreeBranchCandidate] {
        guard let project = snapshot.project(id: projectID),
              snapshot.canCreateWorktree(in: project),
              let hostSummary = snapshot.host(id: project.hostID),
              let host = CommandHostResolver.resolve(hostSummary)
        else {
            throw KwtWorktreeError.projectUnavailable
        }
        do {
            try await ensureRemoteKwtForOperation(hostID: project.hostID)
            guard let current = validatedProjectOperationTarget(
                project,
                capturedHost: host
            ) else {
                throw KwtWorktreeError.projectUnavailable
            }
            return try await kwtBranchLister(
                current.project.rootPath,
                current.host
            )
        } catch {
            recordKwtUnavailability(error, hostID: project.hostID)
            throw error
        }
    }

    func prepareWorktreeRemoval(
        _ worktreeID: UUID,
        refreshSessionIdentity: Bool = false
    ) async throws -> WorktreeRemovalRequest {
        guard let worktree = snapshot.worktree(id: worktreeID),
              let project = snapshot.project(id: worktree.projectID),
              let hostSummary = snapshot.host(id: worktree.hostID),
              let host = CommandHostResolver.resolve(hostSummary)
        else {
            throw KwtWorktreeError.worktreeUnavailable
        }
        guard !worktree.isPrimary else {
            throw KwtWorktreeError.primaryWorktreeCannotBeRemoved
        }
        guard snapshot.canRemoveWorktree(worktree) else {
            throw KwtWorktreeError.worktreeUnavailable
        }
        guard WorktreeGeneration.isCanonical(
            worktree.generation
        ) else {
            throw KwtWorktreeError.removalIdentityUnavailable
        }
        let changes: WorktreeChangeSummary
        do {
            try await ensureRemoteKwtForOperation(hostID: project.hostID)
            guard validatedProjectOperationTarget(
                project,
                capturedHost: host
            ) != nil else {
                throw KwtWorktreeError.removalHostChanged
            }
            changes = try await kwtWorktreeChangeReader(
                worktree.path,
                project.rootPath,
                host
            )
        } catch {
            recordKwtUnavailability(error, hostID: project.hostID)
            throw error
        }

        let sessionKillRequest: TmuxSessionKillRequest?
        if let session = WorkspaceSidebarModel.tmuxSessionSelection(
            for: worktree
        ) {
            if !refreshSessionIdentity,
               WorkspaceSidebarModel.canRequestKill(
                   session,
                   in: snapshot,
                   activeSelection: activeBorrowedTmuxSelection,
                   activeSelectionIsConnected:
                   activeBorrowedTmuxSessionIsConnected
               ) {
                sessionKillRequest = try await prepareTmuxSessionKill(session)
            } else {
                do {
                    let review = try await tmuxSessionIdentityReviewer(
                        session,
                        nil,
                        host
                    )
                    sessionKillRequest = TmuxSessionKillRequest(
                        session: session,
                        confirmedHost: hostSummary,
                        serverPID: review.identity.serverPID,
                        sessionID: review.identity.sessionID,
                        sessionCreatedAt: review.identity.createdAt,
                        routeIdentity: review.routeIdentity
                    )
                } catch TmuxSessionKillError.sessionNotRunning {
                    sessionKillRequest = nil
                }
            }
        } else {
            sessionKillRequest = nil
        }
        let routeIdentity: String?
        switch host {
        case .local:
            routeIdentity = nil
        case let .ssh(info):
            if let sessionRouteIdentity = sessionKillRequest?.routeIdentity {
                routeIdentity = sessionRouteIdentity
            } else {
                routeIdentity = try await sshRouteIdentityResolver(info)
            }
        }
        return WorktreeRemovalRequest(
            worktree: worktree,
            project: project,
            confirmedHost: hostSummary,
            routeIdentity: routeIdentity,
            sessionKillRequest: sessionKillRequest,
            changes: changes
        )
    }

    func removeWorktree(
        _ request: WorktreeRemovalRequest
    ) async throws {
        guard let requestedWorktree = currentRemovalTarget(for: request) else {
            if currentRemovalTmuxEndpointOwner(for: request) != nil {
                throw KwtWorktreeError.removalTargetChanged
            }
            throw KwtWorktreeError.worktreeUnavailable
        }
        guard let requestedProject = snapshot.project(
            id: requestedWorktree.projectID
        ),
            let hostSummary = snapshot.host(id: requestedWorktree.hostID),
            CommandHostResolver.resolve(hostSummary) != nil
        else {
            throw KwtWorktreeError.worktreeUnavailable
        }
        guard removalRequest(
            request,
            matches: requestedWorktree,
            project: requestedProject
        ) else {
            throw KwtWorktreeError.removalTargetChanged
        }
        guard snapshot.canRemoveWorktree(requestedWorktree) else {
            throw KwtWorktreeError.worktreeUnavailable
        }
        guard removalHostEndpointMatches(request),
              let confirmedHost = CommandHostResolver.resolve(
                  request.confirmedHost
              )
        else {
            throw KwtWorktreeError.removalHostChanged
        }

        let mutationHostID = requestedProject.hostID
        let mutationProjectIdentity = requestedProject.scopedKey
        guard !ownsWorktreeMutation else {
            throw KwtWorktreeError.removalInProgress
        }
        ownsWorktreeMutation = true
        guard worktreeMutationCoordinator.acquire(
            hostID: mutationHostID,
            projectIdentity: mutationProjectIdentity
        ) else {
            ownsWorktreeMutation = false
            throw KwtWorktreeError.removalInProgress
        }
        var removalTombstones:
            Set<WorktreeMutationCoordinator.RemovalTombstone> = []
        var reconciledRestorationTargets:
            Set<WorkspaceTmuxSessionSelection>?
        var requiresWorkspaceReestablishment = false
        var terminatedSession = false
        var killedSessionReestablishmentTarget:
            WorkspaceTmuxSessionSelection?
        invalidateKwtInventoryRefresh()
        let mutation = kwtMutationPublication(hostID: mutationHostID)
        defer {
            ownsWorktreeMutation = false
            worktreeMutationCoordinator.release(
                hostID: mutationHostID,
                projectIdentity: mutationProjectIdentity,
                removalTombstones: removalTombstones,
                reconciledRestorationTargets: reconciledRestorationTargets,
                requiresWorkspaceReestablishment:
                requiresWorkspaceReestablishment
            )
            if let killedSessionReestablishmentTarget {
                _ = presentTmuxSession(
                    killedSessionReestablishmentTarget,
                    launchMode: .attach,
                    intent: .userInitiated,
                    activatesPresentation: false
                )
            }
        }

        let preflight: KwtHostInventory
        do {
            try await ensureRemoteKwtForOperation(
                hostID: requestedProject.hostID
            )
            guard removalHostEndpointMatches(request) else {
                throw KwtWorktreeError.removalHostChanged
            }
            preflight = try await kwtInventoryLoader(confirmedHost)
        } catch {
            recordKwtUnavailability(
                error,
                hostID: requestedProject.hostID
            )
            throw error
        }
        guard removalHostEndpointMatches(request) else {
            throw KwtWorktreeError.removalHostChanged
        }
        guard try await removalRouteIdentityMatches(
            request.routeIdentity,
            on: confirmedHost
        ) else {
            throw KwtWorktreeError.removalHostChanged
        }
        let preflightTarget = try reconcileRemovalPreflight(
            preflight,
            request: request
        )
        let worktree = preflightTarget?.0 ?? request.worktree
        let project = preflightTarget?.1 ?? requestedProject
        let checkoutAlreadyAbsent = preflightTarget == nil
        guard let generation = worktree.generation else {
            throw KwtWorktreeError.removalTargetChanged
        }
        if !checkoutAlreadyAbsent {
            let currentChanges: WorktreeChangeSummary
            do {
                currentChanges = try await kwtWorktreeChangeReader(
                    worktree.path,
                    project.rootPath,
                    confirmedHost
                )
            } catch {
                recordKwtUnavailability(error, hostID: project.hostID)
                throw error
            }
            guard removalHostEndpointMatches(request) else {
                throw KwtWorktreeError.removalHostChanged
            }
            if currentChanges.hasUncommittedChanges,
               !request.forceRemoval {
                throw KwtWorktreeError.removalChangesChanged
            }
        }
        let removalTombstone =
            WorktreeMutationCoordinator.RemovalTombstone(
                path: worktree.path,
                generation: generation
            )

        if request.sessionKillRequest == nil,
           let session = WorkspaceSidebarModel.tmuxSessionSelection(
               for: worktree
           ) {
            do {
                _ = try await tmuxSessionIdentityReader(
                    session,
                    confirmedHost
                )
                throw KwtWorktreeError.sessionStartedAfterConfirmation(
                    session: session.name
                )
            } catch TmuxSessionKillError.sessionNotRunning {
                // The confirmation remains accurate.
            }
        }

        worktreeMutationCoordinator.prepareRemoval(
            hostID: mutationHostID,
            projectIdentity: mutationProjectIdentity,
            worktrees: [removalTombstone],
            presentationTargets: Set(
                WorkspaceSidebarModel.tmuxSessionSelection(for: worktree)
                    .map { [$0] } ?? []
            )
        )

        do {
            if let sessionKillRequest = request.sessionKillRequest {
                try await killTmuxSession(sessionKillRequest)
                terminatedSession = true
                requiresWorkspaceReestablishment = true
            }
            guard removalHostEndpointMatches(request) else {
                throw KwtWorktreeError.removalHostChanged
            }
            if checkoutAlreadyAbsent {
                guard try await removalRouteIdentityMatches(
                    request.routeIdentity,
                    on: confirmedHost
                ) else {
                    throw KwtWorktreeError.removalHostChanged
                }
            } else {
                do {
                    let remover = request.forceRemoval
                        ? kwtForceWorktreeRemover
                        : kwtWorktreeRemover
                    try await remover(
                        worktree.path,
                        generation,
                        project.rootPath,
                        request.routeIdentity,
                        confirmedHost
                    )
                } catch {
                    let removalError = error
                    requiresWorkspaceReestablishment = terminatedSession
                    let outcome = await classifyFailedRemoval(
                        request,
                        tombstone: removalTombstone,
                        hostID: project.hostID,
                        confirmedHost: confirmedHost,
                        mutation: mutation
                    )
                    reconciledRestorationTargets =
                        outcome.restorationTargets
                    if outcome.identityRemoved {
                        removalTombstones.insert(removalTombstone)
                        requiresWorkspaceReestablishment = false
                    }
                    if outcome.targetChanged {
                        throw KwtWorktreeError.removalTargetChanged
                    }
                    let killedRestorationTarget = terminatedSession
                        ? outcome.restorationTargets?.first
                        : nil
                    let shouldReadChanges: Bool
                    if !request.forceRemoval,
                       let worktreeError = removalError as? KwtWorktreeError,
                       case .removalFailed = worktreeError {
                        shouldReadChanges = true
                    } else {
                        shouldReadChanges = false
                    }
                    let changes: WorktreeChangeSummary?
                    if shouldReadChanges {
                        do {
                            changes = try await kwtWorktreeChangeReader(
                                worktree.path,
                                project.rootPath,
                                confirmedHost
                            )
                        } catch {
                            recordKwtUnavailability(
                                error,
                                hostID: project.hostID
                            )
                            changes = nil
                        }
                    } else {
                        changes = nil
                    }
                    if shouldReadChanges,
                       let changes,
                       removalHostEndpointMatches(request),
                       !terminatedSession || killedRestorationTarget != nil,
                       changes.hasUncommittedChanges {
                        killedSessionReestablishmentTarget =
                            killedRestorationTarget
                        throw KwtWorktreeError.removalChangesChanged
                    }
                    throw removalError
                }
            }
            cancelPendingRestoration()
            removalTombstones.insert(removalTombstone)
        } catch {
            recordKwtUnavailability(error, hostID: project.hostID)
            throw error
        }

        removeWorktreeFromCachedState(
            worktree,
            hostID: project.hostID
        )
        guard !checkoutAlreadyAbsent else { return }

        do {
            let refreshed = try await kwtInventoryLoader(confirmedHost)
            applyAuthoritativeKwtInventory(
                refreshed,
                hostID: project.hostID,
                excludingWorktrees: [
                    project.scopedKey: [
                        KwtWorktreeIdentity(
                            path: worktree.path,
                            generation: generation
                        ),
                    ],
                ],
                mutation: mutation
            )
        } catch {
            recordKwtUnavailability(error, hostID: project.hostID)
            kwtInventoryFailuresByHost[project.hostID] =
                "The worktree was removed, but inventory refresh failed: "
                    + error.localizedDescription
            applyInventoryOverlayIfNeeded()
            updateWorkspaceInventoryState()
        }
    }

    func resolveWorktreeRemoval(
        _ request: WorktreeRemovalRequest
    ) async throws -> WorktreeRemovalResult {
        do {
            try await removeWorktree(request)
            return .removed
        } catch {
            guard let recovery = Self.removalRecovery(for: error) else {
                throw error
            }
            guard removalHostEndpointMatches(request) else {
                throw KwtWorktreeError.removalHostChanged
            }
            switch recovery {
            case .refreshSessionIdentity:
                return await .confirmationRequired(
                    try prepareWorktreeRemoval(
                        request.worktree.id,
                        refreshSessionIdentity: true
                    )
                )
            case .reconfirmChangedTarget:
                let updatedRequest = try await prepareCurrentWorktreeRemoval(
                    request
                )
                guard removalConfirmationChanged(
                    from: request,
                    to: updatedRequest
                ) else {
                    throw KwtWorktreeError.removalTargetChanged
                }
                return .confirmationRequired(updatedRequest)
            case .reconfirmStartedSession:
                return await .confirmationRequired(
                    try prepareWorktreeRemoval(request.worktree.id)
                )
            }
        }
    }

    private enum RemovalRecovery {
        case refreshSessionIdentity
        case reconfirmChangedTarget
        case reconfirmStartedSession
    }

    private static func removalRecovery(
        for error: Error
    ) -> RemovalRecovery? {
        switch error {
        case TmuxSessionKillError.sessionChanged,
             TmuxSessionKillError.sessionNotRunning:
            return .refreshSessionIdentity
        case KwtWorktreeError.removalTargetChanged:
            return .reconfirmChangedTarget
        case KwtWorktreeError.removalChangesChanged:
            return .reconfirmChangedTarget
        case KwtWorktreeError.sessionStartedAfterConfirmation:
            return .reconfirmStartedSession
        default:
            return nil
        }
    }

    /// Classifies a failed removal against a freshly loaded inventory so
    /// the caller can decide between tombstoning the removed identity and
    /// requiring a new confirmation. When the refresh confirms a surviving
    /// target, `restorationTargets` carries its current endpoints so every
    /// scene restores against the reconciled state rather than a saved
    /// preflight endpoint. Refresh or reconciliation errors leave both
    /// flags false and the targets `nil` to preserve the original removal
    /// failure and the saved endpoints.
    private func classifyFailedRemoval(
        _ request: WorktreeRemovalRequest,
        tombstone: WorktreeMutationCoordinator.RemovalTombstone,
        hostID: UUID,
        confirmedHost: CommandHost,
        mutation: WorkspaceInventoryStore.MutationPublication?
    ) async -> (
        identityRemoved: Bool,
        targetChanged: Bool,
        restorationTargets: Set<WorkspaceTmuxSessionSelection>?
    ) {
        do {
            let refreshed = try await removalReconciliationInventory(
                on: confirmedHost,
                expectedRouteIdentity: request.routeIdentity
            )
            guard removalHostEndpointMatches(request) else {
                return (false, false, nil)
            }
            do {
                if let (intact, _) = try reconcileRemovalPreflight(
                    refreshed,
                    request: request
                ) {
                    return (false, false, Set(
                        WorkspaceSidebarModel.tmuxSessionSelection(
                            for: intact
                        ).map { [$0] } ?? []
                    ))
                }
                applyAuthoritativeKwtInventory(
                    refreshed,
                    hostID: hostID,
                    excludingWorktrees: [
                        request.project.scopedKey: [tombstone],
                    ],
                    mutation: mutation
                )
                return (true, false, nil)
            } catch KwtWorktreeError.removalTargetChanged {
                // Survival is judged within the confirmed repository: the
                // identity lives on when its path is still present or when
                // its canonical generation reappears at a new path. The
                // same path or generation under another repository is no
                // longer this removal's target and must not keep stale
                // presentations restorable.
                let generation = WorktreeGeneration.canonical(
                    tombstone.generation
                )
                guard let item = refreshed.projects.first(where: {
                    $0.project.repository == request.project.scopedKey
                }) else {
                    return (true, true, nil)
                }
                // An incomplete worktree list cannot prove removal, but it
                // cannot vouch for a restoration endpoint either.
                guard item.warning == nil else {
                    return (false, true, nil)
                }
                let survives = item.worktrees.contains { record in
                    tombstone.matches(
                        path: record.path,
                        generation: record.generation
                    )
                        || (generation != nil
                            && WorktreeGeneration.canonical(
                                record.generation
                            ) == generation)
                }
                guard survives else {
                    return (true, true, nil)
                }
                let target = generation.flatMap { generation in
                    scopedRestorationTarget(
                        generation: generation,
                        hostID: hostID,
                        projectIdentity: request.project.scopedKey
                    )
                }
                return (false, true, Set(target.map { [$0] } ?? []))
            } catch {
                return (false, false, nil)
            }
        } catch KwtSSHLeaseError.routeChanged {
            return (false, true, nil)
        } catch {
            return (false, false, nil)
        }
    }

    /// Resolves the current tmux endpoint for a surviving generation
    /// within the removal's repository scope after the snapshot was
    /// refreshed by reconciliation.
    private func scopedRestorationTarget(
        generation: String,
        hostID: UUID,
        projectIdentity: String
    ) -> WorkspaceTmuxSessionSelection? {
        let projectIDs = Set(
            snapshot.projects.filter {
                $0.hostID == hostID
                    && $0.scopedKey == projectIdentity
            }.map(\.id)
        )
        guard let worktree = snapshot.worktrees.first(where: {
            $0.hostID == hostID
                && projectIDs.contains($0.projectID)
                && WorktreeGeneration.canonical($0.generation) == generation
        }) else { return nil }
        return WorkspaceSidebarModel.tmuxSessionSelection(for: worktree)
    }

    private func reconcileRemovalPreflight(
        _ inventory: KwtHostInventory,
        request: WorktreeRemovalRequest
    ) throws -> (WorktreeSummary, ProjectSummary)? {
        let hostID = request.project.hostID
        if let warning = inventory.projectsWarning {
            throw KwtWorktreeError.removalPreflightUnavailable(
                host: request.confirmedHost.name,
                message: warning
            )
        }
        let repositoryItem = inventory.projects.first {
            $0.project.repository == request.project.scopedKey
        }
        let pathItem = inventory.projects.first {
            $0.project.path == request.project.rootPath
        }
        // An incomplete owning repository cannot prove anything about the
        // target, so its warning outranks every identity conclusion below,
        // including a repository/path conflict.
        if let repositoryItem, let warning = repositoryItem.warning {
            throw KwtWorktreeError.removalPreflightUnavailable(
                host: request.confirmedHost.name,
                message: warning
            )
        }
        if let repositoryItem,
           let pathItem,
           repositoryItem.project.repository != pathItem.project.repository {
            applyAuthoritativeKwtInventory(
                inventory,
                hostID: hostID,
                publishToStore: false
            )
            throw KwtWorktreeError.removalTargetChanged
        }
        guard let item = repositoryItem else {
            // A path-only match is a different repository at the confirmed
            // location; only its warning is worth surfacing before failing.
            if let warning = pathItem?.warning {
                throw KwtWorktreeError.removalPreflightUnavailable(
                    host: request.confirmedHost.name,
                    message: warning
                )
            }
            applyAuthoritativeKwtInventory(
                inventory,
                hostID: hostID,
                publishToStore: false
            )
            throw KwtWorktreeError.removalTargetChanged
        }
        guard item.project.path == request.project.rootPath else {
            applyAuthoritativeKwtInventory(
                inventory,
                hostID: hostID,
                publishToStore: false
            )
            throw KwtWorktreeError.removalTargetChanged
        }
        guard let record = item.worktrees.first(where: {
            $0.path == request.worktree.path
        }) else {
            let hostWorktrees = inventory.projects.flatMap(\.worktrees)
            if let confirmedGeneration = request.worktree.generation,
               hostWorktrees.contains(where: {
                   $0.generation == confirmedGeneration
               }) {
                applyAuthoritativeKwtInventory(
                    inventory,
                    hostID: hostID,
                    publishToStore: false
                )
                throw KwtWorktreeError.removalTargetChanged
            }
            if hostWorktrees.contains(where: {
                removalTmuxEndpoint(request.worktree, matches: $0)
            }) {
                applyAuthoritativeKwtInventory(
                    inventory,
                    hostID: hostID,
                    publishToStore: false
                )
                throw KwtWorktreeError.removalTargetChanged
            }
            if let warning = inventory.projects.compactMap(\.warning).first {
                throw KwtWorktreeError.removalPreflightUnavailable(
                    host: request.confirmedHost.name,
                    message: warning
                )
            }
            return nil
        }
        applyAuthoritativeKwtInventory(
            inventory,
            hostID: hostID,
            publishToStore: false
        )
        guard let worktree = snapshot.worktree(id: request.worktree.id),
              let project = snapshot.project(id: request.project.id),
              record.repository == request.project.scopedKey,
              record.branch == request.worktree.branch,
              record.isMain == request.worktree.isPrimary,
              let confirmedGeneration = request.worktree.generation,
              record.generation == confirmedGeneration,
              record.sessionName == request.worktree.tmuxSessionName,
              removalRequest(
                  request,
                  matches: worktree,
                  project: project
              )
        else {
            throw KwtWorktreeError.removalTargetChanged
        }
        return (worktree, project)
    }

    private func prepareCurrentWorktreeRemoval(
        _ request: WorktreeRemovalRequest
    ) async throws -> WorktreeRemovalRequest {
        guard let worktree = currentRemovalTarget(for: request)
            ?? currentRemovalTmuxEndpointOwner(for: request)
        else {
            throw KwtWorktreeError.worktreeUnavailable
        }
        return try await prepareWorktreeRemoval(worktree.id)
    }

    private func currentRemovalTarget(
        for request: WorktreeRemovalRequest
    ) -> WorktreeSummary? {
        if let generation = WorktreeGeneration.canonical(
            request.worktree.generation
        ) {
            return snapshot.worktrees.first {
                $0.hostID == request.worktree.hostID
                    && $0.projectID == request.project.id
                    && $0.generation == generation
            }
        }
        return snapshot.worktree(id: request.worktree.id)
    }

    private func currentRemovalTmuxEndpointOwner(
        for request: WorktreeRemovalRequest
    ) -> WorktreeSummary? {
        guard let sessionName = request.worktree.tmuxSessionName else {
            return nil
        }
        return snapshot.worktrees.first {
            $0.hostID == request.worktree.hostID
                && $0.projectID == request.project.id
                && $0.tmuxSessionName == sessionName
                && removalTmuxSocket(
                    request.worktree.tmuxSocketName,
                    mode: request.worktree.tmuxAttachMode,
                    matches: $0.tmuxSocketName,
                    candidateMode: $0.tmuxAttachMode
                )
        }
    }

    private func removalTmuxEndpoint(
        _ worktree: WorktreeSummary,
        matches record: KwtWorktreeRecord
    ) -> Bool {
        guard let sessionName = worktree.tmuxSessionName else { return false }
        return record.sessionName == sessionName
            && removalTmuxSocket(
                worktree.tmuxSocketName,
                mode: worktree.tmuxAttachMode,
                matches: record.tmuxSocketName,
                candidateMode: record.tmuxAttachMode
            )
    }

    private func removalTmuxSocket(
        _ confirmedSocket: String?,
        mode: TmuxAttachMode,
        matches candidateSocket: String?,
        candidateMode: TmuxAttachMode
    ) -> Bool {
        guard candidateMode == mode else { return false }
        return candidateSocket == confirmedSocket
            || (mode == .protected
                && confirmedSocket != nil
                && candidateSocket == nil)
    }

    private func removalRequest(
        _ request: WorktreeRemovalRequest,
        matches worktree: WorktreeSummary,
        project: ProjectSummary
    ) -> Bool {
        guard worktree.id == request.worktree.id,
              worktree.hostID == request.worktree.hostID,
              worktree.projectID == request.worktree.projectID,
              worktree.scopedKey == request.worktree.scopedKey,
              worktree.path == request.worktree.path,
              worktree.branch == request.worktree.branch,
              worktree.isPrimary == request.worktree.isPrimary,
              worktree.generation == request.worktree.generation,
              worktree.tmuxSessionName == request.worktree.tmuxSessionName,
              worktree.tmuxSocketName == request.worktree.tmuxSocketName,
              worktree.tmuxAttachMode == request.worktree.tmuxAttachMode,
              project.id == request.project.id,
              project.hostID == request.project.hostID,
              project.scopedKey == request.project.scopedKey,
              project.rootPath == request.project.rootPath
        else { return false }
        guard let killRequest = request.sessionKillRequest else { return true }
        return killRequest.session.hostID == worktree.hostID
            && killRequest.session.name == worktree.tmuxSessionName
            && killRequest.session.worktreeID == worktree.id
            && killRequest.session.workspacePath == worktree.path
            && killRequest.session.socketName == worktree.tmuxSocketName
            && killRequest.session.tmuxAttachMode == worktree.tmuxAttachMode
    }

    private func removalConfirmationChanged(
        from request: WorktreeRemovalRequest,
        to updatedRequest: WorktreeRemovalRequest
    ) -> Bool {
        !removalRequest(
            request,
            matches: updatedRequest.worktree,
            project: updatedRequest.project
        ) || updatedRequest.routeIdentity != request.routeIdentity
            || updatedRequest.sessionKillRequest != request.sessionKillRequest
            || updatedRequest.changes != request.changes
    }

    private func removalHostEndpointMatches(
        _ request: WorktreeRemovalRequest
    ) -> Bool {
        guard request.confirmedHost.id == request.worktree.hostID,
              let currentSummary = snapshot.host(
                  id: request.worktree.hostID
              ),
              let currentHost = CommandHostResolver.resolve(currentSummary),
              let confirmedHost = CommandHostResolver.resolve(
                  request.confirmedHost
              )
        else {
            return false
        }
        return currentHost == confirmedHost
    }

    private func removalRouteIdentityMatches(
        _ expectedRouteIdentity: String?,
        on host: CommandHost
    ) async throws -> Bool {
        switch host {
        case .local:
            return expectedRouteIdentity == nil
        case let .ssh(info):
            return try await sshRouteIdentityResolver(info)
                == expectedRouteIdentity
        }
    }

    private func removeWorktreeFromCachedState(
        _ worktree: WorktreeSummary,
        hostID: UUID
    ) {
        closeRetainedTmuxPresentations(forWorktreeIDs: [worktree.id])
        explicitlyDismissedWorktreePresentationIDs.remove(worktree.id)
        if let inventory = kwtInventoriesByHost[hostID] {
            kwtInventoriesByHost[hostID] =
                inventory.removingWorktree(atPath: worktree.path)
        }
        snapshot.worktrees.removeAll { $0.id == worktree.id }
        snapshot.sessions.removeAll { $0.worktreeID == worktree.id }
        applyInventoryOverlayIfNeeded()
        let removalSelection = Self.selectionAfterWorktreeRemoval(
            selection,
            in: snapshot,
            visibility: worktreeVisibility
        )
        synchronizeSelection(removalSelection)
        updateWorkspaceInventoryState()
    }

    static func selectionAfterWorktreeRemoval(
        _ current: WorkspaceSelection,
        in snapshot: WorkspaceSnapshot,
        visibility: WorktreeVisibility
    ) -> WorkspaceSelection {
        current.normalized(
            in: snapshot,
            visibility: visibility
        )
    }

    private func recordKwtUnavailability(
        _ error: Error,
        hostID: UUID
    ) {
        guard isRemoteKwtUnavailable(error, hostID: hostID) else { return }
        markRemoteKwtUnavailable(hostID: hostID)
    }

    private func markRemoteKwtUnavailable(hostID: UUID) {
        kwtAvailabilityByHost[hostID] = false
        kwtInventoryFailuresByHost.removeValue(forKey: hostID)
        applyInventoryOverlayIfNeeded()
        updateWorkspaceInventoryState()
    }

    func pullRequests(
        for projectID: UUID
    ) async throws -> [PullRequestCandidate] {
        guard let project = snapshot.project(id: projectID),
              snapshot.canImportPullRequest(in: project),
              let hostSummary = snapshot.host(id: project.hostID),
              let host = CommandHostResolver.resolve(hostSummary)
        else {
            throw KwtPullRequestError.projectUnavailable
        }
        do {
            try await ensureRemoteKwtForOperation(hostID: project.hostID)
            guard let current = validatedProjectOperationTarget(
                project,
                capturedHost: host
            ) else {
                throw KwtPullRequestError.projectUnavailable
            }
            return try await kwtPullRequestLister(
                current.project.scopedKey,
                current.host
            )
        } catch {
            recordKwtUnavailability(error, hostID: project.hostID)
            throw error
        }
    }

    func importPullRequest(
        _ request: PullRequestImportRequest
    ) async throws {
        guard let project = snapshot.project(id: request.projectID),
              snapshot.canImportPullRequest(in: project),
              let hostSummary = snapshot.host(id: project.hostID),
              let host = CommandHostResolver.resolve(hostSummary)
        else {
            throw KwtPullRequestError.projectUnavailable
        }

        let mutationHostID = project.hostID
        let mutationProjectIdentity = project.scopedKey
        guard !ownsWorktreeMutation else {
            throw KwtPullRequestError.importInProgress
        }
        ownsWorktreeMutation = true
        guard worktreeMutationCoordinator.acquire(
            hostID: mutationHostID,
            projectIdentity: mutationProjectIdentity
        ) else {
            ownsWorktreeMutation = false
            throw KwtPullRequestError.importInProgress
        }
        invalidateKwtInventoryRefresh()
        let mutation = kwtMutationPublication(hostID: mutationHostID)
        defer {
            ownsWorktreeMutation = false
            worktreeMutationCoordinator.release(
                hostID: mutationHostID,
                projectIdentity: mutationProjectIdentity
            )
        }

        let operation: (
            result: KwtPullRequestImportResult,
            project: ProjectSummary,
            host: CommandHost
        )
        do {
            try await ensureRemoteKwtForOperation(hostID: project.hostID)
            guard let current = validatedProjectOperationTarget(
                project,
                capturedHost: host
            ) else {
                throw KwtPullRequestError.projectUnavailable
            }
            let result = try await kwtPullRequestImporter(
                request.pullRequestID,
                current.project.scopedKey,
                current.host
            )
            operation = (result, current.project, current.host)
            cancelPendingRestoration()
        } catch {
            recordKwtUnavailability(error, hostID: project.hostID)
            throw error
        }

        kwtAvailabilityByHost[operation.project.hostID] = true
        var refreshedSuccessfully = false
        do {
            let refreshed = try await kwtInventoryLoader(operation.host)
            applyAuthoritativeKwtInventory(
                refreshed,
                hostID: operation.project.hostID,
                publish: false,
                publishToStore: false
            )
            refreshedSuccessfully = true
        } catch {
            recordKwtUnavailability(
                error,
                hostID: operation.project.hostID
            )
            kwtInventoryFailuresByHost[operation.project.hostID] =
                error.localizedDescription
        }

        let mergedInventory = mergeImportedWorkspace(
            operation.result.workspace,
            project: operation.project
        )
        applyAuthoritativeKwtInventory(
            mergedInventory,
            hostID: operation.project.hostID,
            mutation: mutation,
            recordsSuccessfulLoad: refreshedSuccessfully
        )
        annotateImportedPullRequest(
            operation.result.pullRequest,
            workspace: operation.result.workspace,
            hostID: operation.project.hostID
        )
        updateWorkspaceInventoryState()

        guard let importedWorktree = snapshot.worktrees.first(where: {
            $0.hostID == operation.project.hostID
                && normalizedWorkspacePath($0.path)
                == normalizedWorkspacePath(operation.result.workspace.path)
        }) else {
            throw KwtPullRequestError.importedWorkspaceMissing(
                path: operation.result.workspace.path
            )
        }
        var importedSelection = selection
        importedSelection.select(
            .worktree(importedWorktree.id),
            in: snapshot,
            visibility: worktreeVisibility
        )
        selectFromUser(importedSelection)
    }

    private func mergeImportedWorkspace(
        _ workspace: PullRequestWorkspace,
        project: ProjectSummary
    ) -> KwtHostInventory {
        var inventory = kwtInventoriesByHost[project.hostID]
            ?? inventoryHosts[project.hostID].flatMap {
                workspaceInventoryStore.snapshot.kwtByHost[$0]?.inventory
            }
            ?? kwtInventoryFromSnapshot(hostID: project.hostID)
        let projectIndex = inventory.projects.firstIndex {
            $0.project.repository == project.scopedKey
                || normalizedWorkspacePath($0.project.path)
                == normalizedWorkspacePath(project.rootPath)
        }
        let worktree = KwtWorktreeRecord(
            path: workspace.path,
            branch: workspace.branch,
            commitHash: "",
            isMain: false,
            createdAt: nil,
            repository: workspace.repository,
            sessionName: workspace.sessionName,
            tmuxSocketName: workspace.tmuxSocketName,
            tmuxAttachMode: workspace.tmuxAttachMode
        )
        if let projectIndex {
            if let worktreeIndex = inventory.projects[
                projectIndex
            ].worktrees.firstIndex(where: {
                normalizedWorkspacePath($0.path)
                    == normalizedWorkspacePath(workspace.path)
            }) {
                inventory.projects[projectIndex].worktrees[
                    worktreeIndex
                ].sessionName = workspace.sessionName
                inventory.projects[projectIndex].worktrees[
                    worktreeIndex
                ].tmuxSocketName = workspace.tmuxSocketName
                inventory.projects[projectIndex].worktrees[
                    worktreeIndex
                ].tmuxAttachMode = workspace.tmuxAttachMode
            } else {
                inventory.projects[projectIndex].worktrees.append(worktree)
            }
        } else {
            inventory.projects.append(KwtProjectInventory(
                project: KwtProjectRecord(
                    repository: project.scopedKey,
                    name: project.name,
                    path: project.rootPath,
                    lastTouched: nil,
                    registrationFingerprint:
                    project.registrationFingerprint
                ),
                worktrees: [worktree],
                warning: nil
            ))
        }
        kwtInventoriesByHost[project.hostID] = inventory
        return inventory
    }

    private func kwtInventoryFromSnapshot(hostID: UUID) -> KwtHostInventory {
        let projects = snapshot.projects.filter {
            $0.hostID == hostID && !$0.isSynthesized
        }.map { project in
            KwtProjectInventory(
                project: KwtProjectRecord(
                    repository: project.scopedKey,
                    name: project.name,
                    path: project.rootPath,
                    lastTouched: nil,
                    registrationFingerprint:
                    project.registrationFingerprint
                ),
                worktrees: snapshot.worktrees.filter {
                    $0.hostID == hostID && $0.projectID == project.id
                }.map { worktree in
                    KwtWorktreeRecord(
                        path: worktree.path,
                        branch: worktree.branch,
                        commitHash: "",
                        isMain: worktree.isPrimary,
                        createdAt: worktree.createdAt,
                        generation: worktree.generation,
                        repository: project.scopedKey,
                        sessionName: worktree.tmuxSessionName ?? "",
                        tmuxSocketName: worktree.tmuxSocketName,
                        tmuxAttachMode: worktree.tmuxAttachMode
                    )
                },
                warning: nil
            )
        }
        return KwtHostInventory(
            projects: projects,
            directoryWorkspaces: snapshot.directoryWorkspaces
                .filter { $0.hostID == hostID }
                .map(KwtDirectoryWorkspaceRecord.init)
        )
    }

    private func annotateImportedPullRequest(
        _ pullRequest: PullRequestCandidate,
        workspace: PullRequestWorkspace,
        hostID: UUID
    ) {
        guard let index = snapshot.worktrees.firstIndex(where: {
            $0.hostID == hostID
                && normalizedWorkspacePath($0.path)
                == normalizedWorkspacePath(workspace.path)
        }) else { return }
        snapshot.worktrees[index].linkedPullRequestNumber =
            pullRequest.number
        snapshot.worktrees[index].pullRequestTitle = pullRequest.title
        snapshot.worktrees[index].pullRequestURL = pullRequest.url
        snapshot.worktrees[index].pullRequestState = pullRequest.isDraft
            ? .draft
            : PRState(rawValue: pullRequest.state)
    }

    private func normalizedWorkspacePath(_ path: String) -> String {
        URL(fileURLWithPath: path).standardizedFileURL.path
    }

    private func reconcileInventoryHosts() {
        guard !isApplyingInventoryOverlay else { return }
        let resolved = Dictionary(
            uniqueKeysWithValues: snapshot.hosts.compactMap { host in
                CommandHostResolver.resolve(host).map { (host.id, $0) }
            }
        )
        guard resolved != inventoryHosts else {
            updateSharedInventorySubscription()
            applyInventoryOverlayIfNeeded()
            return
        }

        let invalidatedHostIDs = Set(inventoryHosts.compactMap {
            hostID, previousHost in
            resolved[hostID] != previousHost ? hostID : nil
        })
        invalidateAlwaysLiveTmuxPresentations(for: invalidatedHostIDs)
        let retainedHostIDs = Set(resolved.compactMap { hostID, target in
            inventoryHosts[hostID] == target ? hostID : nil
        })
        let retainedHerdrHostIDs = Set(resolved.compactMap { hostID, target in
            inventoryHosts[hostID] == target && Self.supportsHerdr(target)
                ? hostID
                : nil
        })
        let retainedZellijHostIDs = Set(resolved.compactMap { hostID, target in
            inventoryHosts[hostID] == target && Self.supportsZellij(target)
                ? hostID
                : nil
        })
        for (hostID, previousHost) in inventoryHosts
            where resolved[hostID] != previousHost
            && Self.supportsHerdr(previousHost) {
            herdrSessionProbeBroker.invalidateSessions(on: previousHost)
        }
        kwtInventoriesByHost = kwtInventoriesByHost.filter {
            retainedHostIDs.contains($0.key)
        }
        kwtAvailabilityByHost = kwtAvailabilityByHost.filter {
            retainedHostIDs.contains($0.key)
        }
        kwtInventoryFailuresByHost = kwtInventoryFailuresByHost.filter {
            retainedHostIDs.contains($0.key)
        }
        tmuxSessionsByHost = tmuxSessionsByHost.filter {
            retainedHostIDs.contains($0.key)
        }
        tmuxReachabilityByHost = tmuxReachabilityByHost.filter {
            retainedHostIDs.contains($0.key)
        }
        tmuxLastSeenByHost = tmuxLastSeenByHost.filter {
            retainedHostIDs.contains($0.key)
        }
        tmuxDiscoveryFailuresByHost = tmuxDiscoveryFailuresByHost.filter {
            retainedHostIDs.contains($0.key)
        }
        latestTmuxDiscoveryObservationByHost =
            latestTmuxDiscoveryObservationByHost.filter {
                retainedHostIDs.contains($0.key)
            }
        tmuxFreshHostIDs.formIntersection(retainedHostIDs)
        herdrSessionsByHost = herdrSessionsByHost.filter {
            retainedHerdrHostIDs.contains($0.key)
        }
        herdrAvailabilityByHost = herdrAvailabilityByHost.filter {
            retainedHerdrHostIDs.contains($0.key)
        }
        herdrDiscoveryFailuresByHost = herdrDiscoveryFailuresByHost.filter {
            retainedHerdrHostIDs.contains($0.key)
        }
        herdrFreshHostIDs.formIntersection(retainedHerdrHostIDs)
        for (hostID, target) in resolved where !Self.supportsHerdr(target) {
            herdrSessionsByHost[hostID] = []
        }
        zellijSessionsByHost = zellijSessionsByHost.filter {
            retainedZellijHostIDs.contains($0.key)
        }
        zellijAvailabilityByHost = zellijAvailabilityByHost.filter {
            retainedZellijHostIDs.contains($0.key)
        }
        zellijDiscoveryFailuresByHost = zellijDiscoveryFailuresByHost.filter {
            retainedZellijHostIDs.contains($0.key)
        }
        zellijFreshHostIDs.formIntersection(retainedZellijHostIDs)
        for (hostID, target) in resolved where !Self.supportsZellij(target) {
            zellijSessionsByHost[hostID] = []
        }
        worktreeRemovalTombstones = worktreeRemovalTombstones.filter {
            retainedHostIDs.contains($0.key.hostID)
        }
        inventoryHosts = resolved
        appliedKwtInventoryRevisions = appliedKwtInventoryRevisions.filter {
            resolved[$0.key.hostID] == $0.key.commandHost
        }
        appliedKwtObservationRevisions =
            appliedKwtObservationRevisions.filter {
                resolved[$0.key.hostID] == $0.key.commandHost
            }
        appliedTmuxInventoryRevisions =
            appliedTmuxInventoryRevisions.filter {
                resolved[$0.key.hostID] == $0.key.commandHost
            }
        appliedTmuxObservationRevisions =
            appliedTmuxObservationRevisions.filter {
                resolved[$0.key.hostID] == $0.key.commandHost
            }
        updateSharedInventorySubscription()
        applyInventoryOverlayIfNeeded()
        scheduleHerdrSessionDiscovery()
        scheduleZellijSessionDiscovery()
    }

    private func applyInventoryOverlayIfNeeded() {
        let overlaid = applyingCachedInventories(to: snapshot)
        if overlaid != snapshot {
            isApplyingInventoryOverlay = true
            snapshot = overlaid
            isApplyingInventoryOverlay = false
        }
        attemptPendingRestoration()
    }

    private func applyRuntimeInventoryOverlayIfNeeded(hostID: UUID? = nil) {
        if let hostID {
            applyHostInventoryOverlayIfNeeded(
                hostID: hostID,
                includeKwtInventory: false
            )
            return
        }
        let overlaid = HostInventoryOverlay.applyRuntimeSessions(
            tmuxSessionsByHost: tmuxSessionsByHost,
            herdrSessionsByHost: herdrSessionsByHost,
            zellijSessionsByHost: zellijSessionsByHost,
            herdrAvailabilityByHost: herdrAvailabilityByHost,
            zellijAvailabilityByHost: zellijAvailabilityByHost,
            tmuxReachabilityByHost: tmuxReachabilityByHost,
            tmuxLastSeenByHost: tmuxLastSeenByHost,
            tmuxAuthoritativeHostIDs: tmuxFreshHostIDs,
            to: snapshot
        )
        if overlaid != snapshot {
            isApplyingInventoryOverlay = true
            snapshot = overlaid
            isApplyingInventoryOverlay = false
        }
        attemptPendingRestoration()
    }

    private func applyHostInventoryOverlayIfNeeded(
        hostID: UUID,
        includeKwtInventory: Bool
    ) {
        let overlaid = HostInventoryOverlay.apply(
            kwtInventoriesByHost: includeKwtInventory
                ? hostScopedValue(kwtInventoriesByHost, hostID: hostID)
                : [:],
            kwtAvailabilityByHost: hostScopedValue(
                kwtAvailabilityByHost,
                hostID: hostID
            ),
            tmuxSessionsByHost: hostScopedValue(
                tmuxSessionsByHost,
                hostID: hostID
            ),
            herdrSessionsByHost: hostScopedValue(
                herdrSessionsByHost,
                hostID: hostID
            ),
            zellijSessionsByHost: hostScopedValue(
                zellijSessionsByHost,
                hostID: hostID
            ),
            herdrAvailabilityByHost: hostScopedValue(
                herdrAvailabilityByHost,
                hostID: hostID
            ),
            zellijAvailabilityByHost: hostScopedValue(
                zellijAvailabilityByHost,
                hostID: hostID
            ),
            tmuxReachabilityByHost: hostScopedValue(
                tmuxReachabilityByHost,
                hostID: hostID
            ),
            tmuxLastSeenByHost: hostScopedValue(
                tmuxLastSeenByHost,
                hostID: hostID
            ),
            tmuxAuthoritativeHostIDs: tmuxFreshHostIDs.intersection([hostID]),
            to: snapshot
        )
        if overlaid != snapshot {
            isApplyingInventoryOverlay = true
            snapshot = overlaid
            isApplyingInventoryOverlay = false
        }
        attemptPendingRestoration()
    }

    private func hostScopedValue<Value>(
        _ values: [UUID: Value],
        hostID: UUID
    ) -> [UUID: Value] {
        guard let value = values[hostID] else { return [:] }
        return [hostID: value]
    }

    private func updateSharedInventorySubscription() {
        guard !isShutDown else { return }
        let configuredHosts = Dictionary(
            (configuredSSHHostsProvider()
                + configuredExeHostsProvider().map(\.sshHost))
                .map { ($0.configKey, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        let registrations = inventoryHosts.map { hostID, commandHost in
            let provisioningHost: SSHHost? = {
                guard case .ssh = commandHost,
                      let summary = snapshot.host(id: hostID),
                      let host = configuredHosts[summary.configKey],
                      host.platform == .macOS || host.platform == .linux
                else { return nil }
                return host
            }()
            return WorkspaceInventoryStore.HostRegistration(
                hostID: hostID,
                commandHost: commandHost,
                provisioningHost: provisioningHost
            )
        }
        workspaceInventoryStore.updateSubscriber(
            id: workspaceInventorySubscriberID,
            registrations: registrations,
            wantsKwt: kwtInventoryEnabled,
            wantsTmux: tmuxDiscoveryEnabled
        )
        consumeSharedInventory(workspaceInventoryStore.snapshot)
    }

    private func consumeSharedInventory(
        _ shared: WorkspaceInventoryStore.Snapshot
    ) {
        guard !isShutDown, !isConsumingSharedInventory else { return }
        isConsumingSharedInventory = true
        defer { isConsumingSharedInventory = false }
        var successfulKwtHosts: [(UUID, CommandHost, KwtHostInventory)] = []
        var successfulTmuxHostIDs: Set<UUID> = []

        for (hostID, commandHost) in inventoryHosts {
            let applicationKey = SharedInventoryApplicationKey(
                hostID: hostID,
                commandHost: commandHost
            )
            if kwtInventoryEnabled,
               let entry = shared.kwtByHost[commandHost] {
                if entry.inventoryRevision
                    > appliedKwtInventoryRevisions[
                        applicationKey,
                        default: 0
                    ],
                    let inventory = entry.inventory {
                    appliedKwtInventoryRevisions[applicationKey] =
                        entry.inventoryRevision
                    let recordsSuccessfulLoad = entry.isFresh
                        && {
                            if case .loaded = entry.state {
                                return true
                            }
                            return false
                        }()
                    let tombstones = recordsSuccessfulLoad
                        ? activeRemovalTombstones(
                            after: inventory,
                            hostID: hostID
                        )
                        : removalTombstones(hostID: hostID)
                    applyAuthoritativeKwtInventory(
                        inventory,
                        hostID: hostID,
                        excludingWorktrees: tombstones,
                        publish: false,
                        publishToStore: false,
                        recordsSuccessfulLoad: recordsSuccessfulLoad
                    )
                    if recordsSuccessfulLoad {
                        successfulKwtHosts.append((
                            hostID,
                            commandHost,
                            inventory
                        ))
                    }
                }
                if entry.observationRevision
                    > appliedKwtObservationRevisions[
                        applicationKey,
                        default: 0
                    ] {
                    appliedKwtObservationRevisions[applicationKey] =
                        entry.observationRevision
                    switch entry.state {
                    case .idle, .loading, .loaded:
                        break
                    case .provisioningFailed:
                        kwtAvailabilityByHost[hostID] = false
                        kwtInventoryFailuresByHost.removeValue(
                            forKey: hostID
                        )
                    case let .failed(error):
                        if isRemoteKwtUnavailable(error, hostID: hostID) {
                            kwtAvailabilityByHost[hostID] = false
                            kwtInventoryFailuresByHost.removeValue(
                                forKey: hostID
                            )
                        } else {
                            kwtInventoryFailuresByHost[hostID] =
                                error.localizedDescription
                        }
                    }
                }
            }

            if tmuxDiscoveryEnabled,
               let entry = shared.tmuxByHost[commandHost] {
                if entry.inventoryRevision
                    > appliedTmuxInventoryRevisions[
                        applicationKey,
                        default: 0
                    ],
                    let sessions = entry.sessions {
                    appliedTmuxInventoryRevisions[applicationKey] =
                        entry.inventoryRevision
                    applyTmuxDiscoveryResult(
                        .success(sessions),
                        hostID: hostID,
                        publish: false
                    )
                    successfulTmuxHostIDs.insert(hostID)
                }
                if entry.observationRevision
                    > appliedTmuxObservationRevisions[
                        applicationKey,
                        default: 0
                    ] {
                    appliedTmuxObservationRevisions[applicationKey] =
                        entry.observationRevision
                    _ = beginTmuxDiscoveryObservation(hostID: hostID)
                    if case let .failed(error) = entry.state {
                        applyTmuxDiscoveryResult(
                            .failure(error),
                            hostID: hostID,
                            publish: false
                        )
                    }
                }
            }
        }

        applySharedInventoryProgress(shared)
        applyInventoryOverlayIfNeeded()
        for (hostID, commandHost, inventory) in successfulKwtHosts {
            reconcileRetainedTmuxPresentations(
                afterAuthoritativeInventoryFor: hostID
            )
            resolveQuarantinedProjectRemovals(
                after: inventory,
                hostID: hostID,
                sourceHost: commandHost
            )
        }
        if !successfulTmuxHostIDs.isEmpty {
            applyDeferredTmuxPresentationsIfReady()
            for hostID in successfulTmuxHostIDs {
                reconcileAlwaysLiveTmuxPresentations(hostID: hostID)
            }
        }
        updateWorkspaceInventoryState()
    }

    private func applySharedInventoryProgress(
        _ shared: WorkspaceInventoryStore.Snapshot
    ) {
        let commandHosts = Set(inventoryHosts.values)
        if kwtInventoryEnabled {
            let entries = commandHosts.map { shared.kwtByHost[$0] }
            isKwtInventoryLoading = entries.contains { entry in
                guard let entry else { return true }
                if case .idle = entry.state {
                    return true
                }
                if case .loading = entry.state {
                    return true
                }
                return false
            }
            inventoryRefreshProgress.kwtCompleted =
                !isKwtInventoryLoading
        }
        if tmuxDiscoveryEnabled {
            let entries = commandHosts.map { shared.tmuxByHost[$0] }
            isTmuxDiscoveryLoading = entries.contains { entry in
                guard let entry else { return true }
                if case .idle = entry.state {
                    return true
                }
                if case .loading = entry.state {
                    return true
                }
                return false
            }
            inventoryRefreshProgress.tmuxCompleted =
                !isTmuxDiscoveryLoading
        }
    }

    private func kwtMutationPublication(
        hostID: UUID
    ) -> WorkspaceInventoryStore.MutationPublication? {
        inventoryHosts[hostID].map {
            .init(
                hostID: hostID,
                host: $0,
                epoch: workspaceInventoryStore.kwtMutationEpoch(on: $0)
            )
        }
    }

    private func scheduleKwtInventory() {
        guard kwtInventoryEnabled,
              !ownsWorktreeMutation else { return }
        workspaceInventoryStore.refreshKwt(
            for: workspaceInventorySubscriberID
        )
    }

    private func invalidateKwtInventoryRefresh() {
        isKwtInventoryLoading = false
        inventoryRefreshProgress.kwtCompleted = false
        updateWorkspaceInventoryState()
    }

    private func worktreeMutationEvent(
        _ event: WorktreeMutationCoordinator.Event
    ) {
        switch event.phase {
        case .began:
            fencedWorktreeMutationScopes.insert(event.scope)
        case .willRemove:
            pendingWorktreeRemovals[event.scope, default: []]
                .formUnion(event.removalTombstones)
            retainPresentationsForFailedRemoval(event)
            return
        case .registered:
            worktreeRemovalTombstones.removeValue(forKey: event.scope)
            return
        case .quarantined:
            fencedWorktreeMutationScopes.remove(event.scope)
        case .ended:
            if !worktreeMutationCoordinator.scopes.contains(event.scope) {
                fencedWorktreeMutationScopes.remove(event.scope)
            }
            pendingWorktreeRemovals.removeValue(forKey: event.scope)
            let pendingRestoration =
                pendingRemovalPresentationRestorations.removeValue(
                    forKey: event.scope
                )
            if !event.allowsRemovalRestoration, !event.removesProject {
                dismissSelectedWorktreePresentation(in: event.scope)
            }
            if event.removesProject {
                applyProjectRemoval(scope: event.scope)
            } else if !event.removalTombstones.isEmpty {
                worktreeRemovalTombstones[event.scope, default: []]
                    .formUnion(event.removalTombstones)
                applyRemovalTombstones(
                    event.removalTombstones,
                    scope: event.scope
                )
            } else if let pendingRestoration {
                if event.allowsRemovalRestoration {
                    restorePresentationsAfterFailedRemoval(
                        pendingRestoration,
                        reconciledTargets: event.reconciledRestorationTargets,
                        requiresWorkspaceReestablishment:
                        event.requiresWorkspaceReestablishment
                    )
                } else {
                    explicitlyDismissedWorktreePresentationIDs.formUnion(
                        pendingRestoration.values.compactMap {
                            $0.selection.worktreeID
                        }
                    )
                }
            }
            if !event.removesProject {
                retryProtectedTmuxAttachments(after: event.scope)
            }
        }
        guard inventoryHosts[event.scope.hostID] != nil else { return }
        applySharedInventoryProgress(workspaceInventoryStore.snapshot)
        updateWorkspaceInventoryState()
    }

    private func retryProtectedTmuxAttachments(
        after scope: WorktreeMutationCoordinator.Scope
    ) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            let presentations = retainedTmuxPresentations.values.filter {
                protectedTmuxAttachmentScope(for: $0) == scope
                    && pendingProtectedTmuxAttachmentScopesByHandle[
                        $0.handle.id
                    ] == scope
            }
            for presentation in presentations {
                guard acquireProtectedTmuxAttachmentScopeIfNeeded(
                    for: presentation
                ) else { continue }
                _ = protectedTmuxSurface(handle: presentation.handle)
            }
        }
    }

    private func applyProjectRemoval(
        scope: WorktreeMutationCoordinator.Scope
    ) {
        if var inventory = kwtInventoriesByHost[scope.hostID] {
            inventory.projects.removeAll {
                $0.project.repository == scope.projectIdentity
            }
            kwtInventoriesByHost[scope.hostID] = inventory
        }
        let projectIDs = Set(snapshot.projects.compactMap { project in
            project.hostID == scope.hostID
                && project.scopedKey == scope.projectIdentity
                ? project.id : nil
        })
        let worktreeIDs = Set(snapshot.worktrees.compactMap { worktree in
            projectIDs.contains(worktree.projectID) ? worktree.id : nil
        })
        closeRetainedTmuxPresentations(forWorktreeIDs: worktreeIDs)
        explicitlyDismissedWorktreePresentationIDs.subtract(worktreeIDs)
        snapshot.sessions.removeAll { session in
            session.worktreeID.map(worktreeIDs.contains) == true
        }
        snapshot.worktrees.removeAll { worktreeIDs.contains($0.id) }
        snapshot.projects.removeAll { projectIDs.contains($0.id) }
        applyInventoryOverlayIfNeeded()
        selection = selection.normalized(
            in: snapshot,
            visibility: worktreeVisibility
        )
        updateWorkspaceInventoryState()
    }

    private func herdrLifecycleEvent(
        _ event: HerdrSessionLifecycleCoordinator.Event
    ) {
        let selection = WorkspaceHerdrSessionSelection(
            hostID: event.operation.key.hostID,
            name: event.operation.key.sessionName
        )
        switch event.phase {
        case .began:
            herdrFreshHostIDs.remove(selection.hostID)
            invalidateHerdrProbe(for: selection.hostID)
            objectWillChange.send()
        case .willStop:
            guard event.operation.kind == .stop,
                  activeBorrowedHerdrSelection == selection else { return }
            suppressedHerdrStops[event.operation.id] = SuppressedHerdrStop(
                selection: selection,
                reconnectContext: activeHerdrReconnectContext
            )
            herdrReconnectSupervisor.cancel()
            activeBorrowedHerdrRecoveryState = nil
            sessionConnectionRecoveryRequest = nil
        case .succeeded:
            suppressedHerdrStops.removeValue(forKey: event.operation.id)
            switch event.operation.kind {
            case .create, .restart:
                refreshHerdrInventory(
                    hostID: selection.hostID
                )
            case .stop, .delete:
                applyHerdrLifecycleSuccess(
                    event.operation,
                    selection: selection
                )
            }
        case .failed:
            switch event.operation.kind {
            case .create, .restart:
                refreshHerdrInventory(
                    hostID: selection.hostID
                )
            case .stop, .delete:
                let suppressed = suppressedHerdrStops[event.operation.id]
                Task { [weak self] in
                    await self?.reconcileFailedHerdrLifecycle(
                        event.operation,
                        suppressed: suppressed
                    )
                }
            }
        }
    }

    private func zellijSessionKillEvent(
        _ event: ZellijSessionKillCoordinator.Event
    ) {
        let selection = WorkspaceZellijSessionSelection(
            hostID: event.operation.key.hostID,
            name: event.operation.key.sessionName
        )
        switch event.phase {
        case .began:
            let activePresentationHost = activeZellijReconnectContext?.host
                ?? snapshot.host(id: selection.hostID)
                .flatMap(CommandHostResolver.resolve)
            let restoresActivePresentation =
                activeBorrowedZellijSelection == selection
                    && activePresentationHost == event.operation.host
                    && (!event.operation.host.isRemote
                        || activeZellijReconnectContext?.routeIdentity
                        == event.operation.connectionCacheKey.routeIdentity)
            let presentationIntent = zellijPresentationIntent.flatMap {
                $0.selection == selection
                    && $0.navigationRevision == userNavigationRevision
                    && $0.host == event.operation.host
                    ? $0
                    : nil
            }
            guard restoresActivePresentation || presentationIntent != nil,
                  let host = presentationIntent?.host
                  ?? activePresentationHost
            else {
                return
            }
            suppressedZellijKillPresentations[event.operation.id] = .init(
                selection: selection,
                navigationRevision: userNavigationRevision,
                host: host,
                restoresActivePresentation: restoresActivePresentation,
                presentationIntent: presentationIntent
            )
            if restoresActivePresentation {
                closeBorrowedZellijSession(selection)
            }
        case .succeeded:
            suppressedZellijKillPresentations.removeValue(
                forKey: event.operation.id
            )
            zellijDiscoveryGeneration += 1
            zellijDiscoveryTask?.cancel()
            zellijDiscoveryTask = nil
            if zellijPresentationIntent?.selection == selection {
                invalidateZellijPresentationIntent()
            }
            let activePresentationHost = activeZellijReconnectContext?.host
                ?? snapshot.host(id: selection.hostID)
                .flatMap(CommandHostResolver.resolve)
            let activePresentationMatchesOperation =
                activeBorrowedZellijSelection == selection
                    && activePresentationHost == event.operation.host
                    && (!event.operation.host.isRemote
                        || activeZellijReconnectContext?.routeIdentity
                        == event.operation.connectionCacheKey.routeIdentity)
            if activePresentationMatchesOperation {
                closeBorrowedZellijSession(selection)
            } else if let route = zellijRestorationRoute,
                      route.selection == selection,
                      route.host == event.operation.host,
                      let routeIdentity = route.routeIdentity,
                      routeIdentity
                      == event.operation.connectionCacheKey.routeIdentity {
                cancelPendingRestoration()
            }
            let sessions = zellijSessionsByHost[selection.hostID]
                ?? snapshot.host(id: selection.hostID)?.zellijSessions
                ?? []
            let fence = ZellijSuccessfulKillFence(
                killRevision: zellijSessionKillCoordinator.revision(
                    for: event.operation.key
                ),
                presentationRevision: zellijPresentationRevision,
                discoveryGeneration: zellijDiscoveryGeneration,
                activeHandleID: activeBorrowedZellijSelection == selection
                    ? activeBorrowedZellijHandle?.id
                    : nil,
                presentationIntentID: zellijPresentationIntent?.selection
                    == selection
                    ? zellijPresentationIntent?.id
                    : nil,
                pendingCreationHandleIDs: Set(
                    pendingCreatedZellijSessions.compactMap { handleID, pending in
                        pending == selection ? handleID : nil
                    }
                ),
                sessions: sessions,
                restorationRouteID: zellijRestorationRoute?.id
            )
            Task { [weak self] in
                await self?.reconcileSuccessfulZellijKill(
                    event.operation,
                    selection: selection,
                    fence: fence
                )
            }
        case .failed:
            let suppressed = suppressedZellijKillPresentations.removeValue(
                forKey: event.operation.id
            )
            let pendingIntent = zellijPresentationIntent.flatMap {
                $0.selection == selection
                    && $0.navigationRevision == userNavigationRevision
                    ? $0
                    : nil
            }
            let resumableIntent = pendingIntent
                ?? suppressed?.presentationIntent
            let resumesValidation = resumableIntent.map {
                $0.selection == selection
                    && $0.navigationRevision == userNavigationRevision
                    && $0.revision == zellijPresentationRevision
                    && snapshot.host(id: selection.hostID)
                    .flatMap(CommandHostResolver.resolve) == $0.host
                    && activeBorrowedTmuxSelection == nil
                    && activeBorrowedHerdrSelection == nil
                    && (activeBorrowedZellijSelection == nil
                        || activeBorrowedZellijSelection == selection)
            } ?? false
            let restoresSuppressedPresentation =
                suppressed?.selection == selection
                    && suppressed?.navigationRevision == userNavigationRevision
                    && suppressed?.restoresActivePresentation == true
                    && snapshot.host(id: selection.hostID)
                    .flatMap(CommandHostResolver.resolve) == suppressed?.host
                    && activeBorrowedTmuxSelection == nil
                    && activeBorrowedHerdrSelection == nil
                    && activeBorrowedZellijSelection == nil
            if resumesValidation || restoresSuppressedPresentation {
                validateAndPresentZellijSession(selection)
                return
            }
            if let restoration = pendingRestoration?.zellij,
               let host = snapshot.host(id: selection.hostID),
               restoration.hostKey == host.configKey,
               restoration.sessionName == selection.name {
                if let route = zellijRestorationRoute,
                   CommandHostResolver.resolve(host) != route.host {
                    cancelPendingRestoration()
                    return
                }
                attemptPendingRestoration()
            }
        }
    }

    private func reconcileSuccessfulZellijKill(
        _ operation: ZellijSessionKillCoordinator.Operation,
        selection: WorkspaceZellijSessionSelection,
        fence: ZellijSuccessfulKillFence
    ) async {
        guard !isShutDown,
              let hostSummary = snapshot.host(id: selection.hostID),
              CommandHostResolver.resolve(hostSummary) == operation.host
        else {
            resumeZellijRouteAfterIgnoredKill(selection)
            return
        }
        let connection = await zellijConnectionSnapshot(on: operation.host)
        guard !Task.isCancelled, !isShutDown,
              let currentHostSummary = snapshot.host(id: selection.hostID),
              CommandHostResolver.resolve(currentHostSummary)
              == operation.host,
              connection.cacheKey == operation.connectionCacheKey
        else {
            resumeZellijRouteAfterIgnoredKill(selection)
            return
        }
        let activeHandleID = activeBorrowedZellijSelection == selection
            ? activeBorrowedZellijHandle?.id
            : nil
        let presentationIntentID = zellijPresentationIntent?.selection
            == selection
            ? zellijPresentationIntent?.id
            : nil
        let pendingCreationHandleIDs = Set(
            pendingCreatedZellijSessions.compactMap { handleID, pending in
                pending == selection ? handleID : nil
            }
        )
        let sessions = zellijSessionsByHost[selection.hostID]
            ?? snapshot.host(id: selection.hostID)?.zellijSessions
            ?? []
        if let restorationRouteID = fence.restorationRouteID,
           let route = zellijRestorationRoute,
           route.id == restorationRouteID,
           route.selection == selection,
           route.host == operation.host,
           route.routeIdentity == nil
           || route.routeIdentity
           == operation.connectionCacheKey.routeIdentity {
            cancelPendingRestoration()
        }
        let statePredatesKill =
            fence.killRevision
                == zellijSessionKillCoordinator.revision(for: operation.key)
                && fence.presentationRevision == zellijPresentationRevision
                && fence.discoveryGeneration == zellijDiscoveryGeneration
                && fence.activeHandleID == activeHandleID
                && fence.presentationIntentID == presentationIntentID
                && fence.pendingCreationHandleIDs
                == pendingCreationHandleIDs
                && fence.sessions == sessions
        guard statePredatesKill else {
            if fence.presentationIntentID != nil,
               zellijPresentationIntent?.id == fence.presentationIntentID {
                invalidateZellijPresentationIntent()
            }
            zellijFreshHostIDs.remove(selection.hostID)
            scheduleZellijSessionDiscovery()
            return
        }
        if zellijPresentationIntent?.selection == selection {
            invalidateZellijPresentationIntent()
        }
        zellijFreshHostIDs.remove(selection.hostID)
        pendingCreatedZellijSessions = pendingCreatedZellijSessions.filter {
            $0.value != selection
        }
        if failedZellijCreationIntent == selection {
            failedZellijCreationIntent = nil
        }
        if activeBorrowedZellijSelection == selection {
            closeBorrowedZellijSession(selection)
        }
        zellijSessionsByHost[selection.hostID] = sessions.filter {
            $0.name != selection.name
        }
        applyRuntimeInventoryOverlayIfNeeded(hostID: selection.hostID)
        updateWorkspaceInventoryState()
        scheduleZellijSessionDiscovery()
    }

    private func resumeZellijRouteAfterIgnoredKill(
        _ selection: WorkspaceZellijSessionSelection
    ) {
        zellijFreshHostIDs.remove(selection.hostID)
        scheduleZellijSessionDiscovery()
        let currentHost = snapshot.host(id: selection.hostID)
            .flatMap(CommandHostResolver.resolve)
        if let intent = zellijPresentationIntent,
           intent.selection == selection,
           intent.navigationRevision == userNavigationRevision,
           intent.revision == zellijPresentationRevision,
           intent.host == currentHost,
           activeBorrowedTmuxSelection == nil,
           activeBorrowedHerdrSelection == nil,
           activeBorrowedZellijSelection == nil {
            validateAndPresentZellijSession(selection)
            return
        }
        if let restorationState = pendingRestoration,
           restorationState.zellij?.sessionName == selection.name,
           let route = zellijRestorationRoute,
           route.state == restorationState,
           route.selection == selection,
           route.host == currentHost {
            attemptPendingRestoration()
        }
    }

    private func refreshHerdrInventory(
        hostID: UUID
    ) {
        guard !isShutDown else { return }
        objectWillChange.send()
        invalidateHerdrProbe(for: hostID)
        scheduleHerdrSessionDiscovery()
    }

    private func applyHerdrLifecycleSuccess(
        _ operation: HerdrSessionLifecycleCoordinator.Operation,
        selection target: WorkspaceHerdrSessionSelection
    ) {
        let wasActive = activeBorrowedHerdrSelection == target
        if wasActive {
            closeBorrowedHerdrSession(target)
        }
        var sessions = snapshot.host(id: target.hostID)?.herdrSessions ?? []
        switch operation.kind {
        case .stop:
            if let index = sessions.firstIndex(where: {
                $0.name == target.name
            }) {
                sessions[index].state = .stopped
            }
        case .delete:
            sessions.removeAll { $0.name == target.name }
        case .create, .restart:
            return
        }
        herdrSessionsByHost[target.hostID] = sessions
        herdrAvailabilityByHost[target.hostID] = true
        applyInventoryOverlayIfNeeded()
        updateWorkspaceInventoryState()
        if wasActive {
            selection.select(
                .host(target.hostID),
                in: snapshot,
                visibility: worktreeVisibility
            )
        }
        invalidateHerdrProbe(for: target.hostID)
        scheduleHerdrSessionDiscovery()
    }

    private func reconcileFailedHerdrLifecycle(
        _ operation: HerdrSessionLifecycleCoordinator.Operation,
        suppressed: SuppressedHerdrStop?
    ) async {
        defer {
            suppressedHerdrStops.removeValue(forKey: operation.id)
            objectWillChange.send()
        }
        guard operation.kind == .stop,
              let suppressed,
              let hostSummary = snapshot.host(id: operation.key.hostID),
              let host = CommandHostResolver.resolve(hostSummary)
        else {
            scheduleHerdrSessionDiscovery()
            return
        }
        let lifecycleRevision = herdrLifecycleCoordinator.revision(
            for: operation.key.hostID
        )
        guard !herdrLifecycleCoordinator.isPending(operation.key) else {
            return
        }
        let probe = await validatedHerdrSessionProbe(
            named: operation.key.sessionName,
            on: host
        )
        guard !Task.isCancelled else { return }
        guard let probe else {
            if activeBorrowedHerdrSelection == suppressed.selection {
                stopHerdrReconnectWithUnableToAttach(
                    "The SSH connection changed while Ghosthub was checking the Herdr session. Try again to use the current connection."
                )
            }
            scheduleHerdrSessionDiscovery()
            return
        }
        guard herdrLifecycleCoordinator.revision(
            for: operation.key.hostID
        ) == lifecycleRevision,
            !herdrLifecycleCoordinator.isPending(operation.key),
            snapshot.host(id: operation.key.hostID)
            .flatMap(CommandHostResolver.resolve) == host
        else { return }
        switch probe.outcome {
        case .present:
            guard activeBorrowedHerdrSelection == suppressed.selection else {
                return
            }
            activeHerdrReconnectContext = suppressed.reconnectContext
            if let handle = activeBorrowedHerdrHandle,
               nativeHerdrSessionCoordinator.attachmentClosure(handle) != nil {
                guard presentHerdrSession(
                    suppressed.selection,
                    validation: probe.validation
                ) != nil else {
                    return
                }
                prepareActiveBorrowedHerdrSurface()
            }
        case .absent:
            if activeBorrowedHerdrSelection == suppressed.selection {
                closeBorrowedHerdrSession(suppressed.selection)
            }
        case .unavailable:
            if activeBorrowedHerdrSelection == suppressed.selection {
                closeBorrowedHerdrSession(suppressed.selection)
            }
        case let .failure(.commandFailed(status, _)) where status == 255:
            guard activeBorrowedHerdrSelection == suppressed.selection,
                  var context = suppressed.reconnectContext
            else { return }
            context.surfaceExitCode = 255
            activeHerdrReconnectContext = context
            if herdrReconnectDecision(
                for: context,
                outcome: probe.outcome
            ) == .retry {
                startHerdrReconnect(context)
            }
        case let .failure(error):
            if activeBorrowedHerdrSelection == suppressed.selection {
                stopHerdrReconnectWithUnableToAttach(
                    error.localizedDescription
                )
            }
        }
        scheduleHerdrSessionDiscovery()
    }

    private func invalidateHerdrProbe(for hostID: UUID) {
        guard let hostSummary = snapshot.host(id: hostID),
              let host = CommandHostResolver.resolve(hostSummary)
        else { return }
        herdrSessionProbeBroker.invalidateSessions(on: host)
    }

    /// Tombstones identify a removal within one repository; the same path
    /// and generation under another repository is a different worktree and
    /// must stay visible.
    private func applyRemovalTombstones(
        _ tombstones: Set<WorktreeMutationCoordinator.RemovalTombstone>,
        scope: WorktreeMutationCoordinator.Scope
    ) {
        let matches: (String, String?) -> Bool = { path, generation in
            Self.removalTombstones(
                tombstones,
                matchPath: path,
                generation: generation
            )
        }
        if var inventory = kwtInventoriesByHost[scope.hostID] {
            for index in inventory.projects.indices
                where Self.removalScopeIncludesRepository(
                    inventory.projects[index].project.repository,
                    scope: scope
                ) {
                inventory.projects[index].worktrees.removeAll {
                    matches($0.path, $0.generation)
                }
            }
            kwtInventoriesByHost[scope.hostID] = inventory
        }
        let removedIDs = worktreeIDs(
            matching: tombstones,
            scope: scope
        )
        closeRetainedTmuxPresentations(forWorktreeIDs: removedIDs)
        explicitlyDismissedWorktreePresentationIDs.subtract(removedIDs)
        snapshot.worktrees.removeAll { removedIDs.contains($0.id) }
        snapshot.sessions.removeAll {
            guard let worktreeID = $0.worktreeID else { return false }
            return removedIDs.contains(worktreeID)
        }
        applyInventoryOverlayIfNeeded()
        selection = Self.selectionAfterWorktreeRemoval(
            selection,
            in: snapshot,
            visibility: worktreeVisibility
        )
        updateWorkspaceInventoryState()
    }

    private func retainPresentationsForFailedRemoval(
        _ event: WorktreeMutationCoordinator.Event
    ) {
        let presentations:
            [(RetainedTmuxPresentation, WorkspaceTmuxSessionSelection)] =
            retainedTmuxPresentations.values.compactMap { presentation in
                let selection = presentation.selection
                guard selection.hostID == event.scope.hostID else { return nil }
                let endpointTarget = event.removalPresentationTargets.first {
                    Self.sameTmuxEndpoint(selection, $0)
                }
                let pathMatches = selection.workspacePath.map { path in
                    Self.removalTombstones(
                        event.removalTombstones,
                        matchPath: path,
                        generation: selection.worktreeGeneration
                    )
                } == true
                if pathMatches {
                    guard let path = selection.workspacePath,
                          let pathTarget = event.removalPresentationTargets
                          .first(where: {
                              $0.hostID == selection.hostID
                                  && $0.workspacePath == path
                          })
                    else { return nil }
                    return (presentation, pathTarget)
                }
                guard let endpointTarget else { return nil }
                return (presentation, endpointTarget)
            }
        for (presentation, restorationSelection) in presentations {
            let key = TmuxPresentationKey(presentation.selection)
            pendingRemovalPresentationRestorations[
                event.scope, default: [:]
            ][key] = PendingRemovalPresentation(
                selection: restorationSelection,
                launchMode: presentation.launchMode,
                requiresWorkspaceEstablishment:
                presentation.reconnectContext?.phase
                    == .establishingWorkspace,
                wasActive: activeBorrowedTmuxHandle == presentation.handle,
                userNavigationRevision: userNavigationRevision
            )
            invalidateBorrowedTmuxSession(presentation.selection)
        }
    }

    private func dismissSelectedWorktreePresentation(
        in scope: WorktreeMutationCoordinator.Scope
    ) {
        guard let worktreeID = selection.selectedWorktreeID,
              let worktree = snapshot.worktree(id: worktreeID),
              let project = snapshot.project(id: worktree.projectID),
              project.hostID == scope.hostID,
              project.scopedKey == scope.projectIdentity
        else { return }
        explicitlyDismissedWorktreePresentationIDs.insert(worktreeID)
    }

    private func restorePresentationsAfterFailedRemoval(
        _ restoration: [TmuxPresentationKey: PendingRemovalPresentation],
        reconciledTargets: Set<WorkspaceTmuxSessionSelection>?,
        requiresWorkspaceReestablishment: Bool
    ) {
        for presentation in restoration.values {
            guard let selection = Self.restorationSelection(
                for: presentation.selection,
                reconciledTargets: reconciledTargets
            ) else { continue }
            let establishesWorkspace = requiresWorkspaceReestablishment
                || presentation.requiresWorkspaceEstablishment
            _ = presentTmuxSession(
                selection,
                launchMode: establishesWorkspace
                    ? .attach : presentation.launchMode,
                intent: establishesWorkspace
                    ? .userInitiated : .restoreOnly,
                activatesPresentation: presentation.wasActive
                    && presentation.userNavigationRevision
                    == userNavigationRevision
            )
        }
    }

    /// Reconciliation can refresh the surviving worktree's tmux session
    /// name or socket between removal preflight and restoration; restoring
    /// the saved endpoint would leave a presentation the next inventory
    /// pass immediately invalidates. The reconciled targets carried on the
    /// mutation event are authoritative for every scene, including scenes
    /// whose own snapshot is stale. Without reconciled targets the saved
    /// endpoint stands; with them, a saved endpoint whose generation no
    /// longer resolves has no trustworthy target and is skipped.
    private static func restorationSelection(
        for saved: WorkspaceTmuxSessionSelection,
        reconciledTargets: Set<WorkspaceTmuxSessionSelection>?
    ) -> WorkspaceTmuxSessionSelection? {
        guard let reconciledTargets,
              let generation = WorktreeGeneration.canonical(
                  saved.worktreeGeneration
              )
        else { return saved }
        return reconciledTargets.first {
            WorktreeGeneration.canonical($0.worktreeGeneration) == generation
        }
    }

    /// A removed identity is stripped from its own repository and from
    /// projects whose identity is legacy-empty, so scenes that have not
    /// yet resolved a repository identity still drop the removed worktree.
    /// A different non-empty repository identity is another project's
    /// worktree — for example a reassignment — and stays visible.
    private static func removalScopeIncludesRepository(
        _ repository: String,
        scope: WorktreeMutationCoordinator.Scope
    ) -> Bool {
        repository.isEmpty || repository == scope.projectIdentity
    }

    private func worktreeIDs(
        matching tombstones:
        Set<WorktreeMutationCoordinator.RemovalTombstone>,
        scope: WorktreeMutationCoordinator.Scope
    ) -> Set<UUID> {
        let projectIDs = Set(
            snapshot.projects.filter {
                $0.hostID == scope.hostID
                    && Self.removalScopeIncludesRepository(
                        $0.scopedKey,
                        scope: scope
                    )
            }.map(\.id)
        )
        return Set(snapshot.worktrees.compactMap { worktree in
            guard worktree.hostID == scope.hostID,
                  projectIDs.contains(worktree.projectID),
                  Self.removalTombstones(
                      tombstones,
                      matchPath: worktree.path,
                      generation: worktree.generation
                  )
            else { return nil }
            return worktree.id
        })
    }

    private static func removalTombstones(
        _ tombstones: Set<WorktreeMutationCoordinator.RemovalTombstone>,
        matchPath path: String,
        generation: String?
    ) -> Bool {
        tombstones.contains { tombstone in
            tombstone.matches(path: path, generation: generation)
        }
    }

    private func activeRemovalTombstones(
        after inventory: KwtHostInventory,
        hostID: UUID
    ) -> [String: Set<KwtWorktreeIdentity>] {
        var activeTombstones: [String: Set<KwtWorktreeIdentity>] = [:]
        let scopes = worktreeRemovalTombstones.keys.filter {
            $0.hostID == hostID
        }
        for scope in scopes {
            guard let tombstones = worktreeRemovalTombstones[scope] else {
                continue
            }
            let projects = inventory.projects.filter {
                Self.removalScopeIncludesRepository(
                    $0.project.repository,
                    scope: scope
                )
            }
            let active = tombstones.filter { tombstone in
                projects.contains { project in
                    project.warning != nil
                        || project.worktrees.contains {
                            Self.removalTombstones(
                                [tombstone],
                                matchPath: $0.path,
                                generation: $0.generation
                            )
                        }
                }
            }
            if active.isEmpty {
                worktreeRemovalTombstones.removeValue(forKey: scope)
            } else {
                worktreeRemovalTombstones[scope] = active
                activeTombstones[scope.projectIdentity, default: []]
                    .formUnion(active)
            }
        }
        return activeTombstones
    }

    private func removalTombstones(
        hostID: UUID
    ) -> [String: Set<KwtWorktreeIdentity>] {
        worktreeRemovalTombstones.reduce(into: [:]) { active, entry in
            guard entry.key.hostID == hostID else { return }
            active[entry.key.projectIdentity, default: []]
                .formUnion(entry.value)
        }
    }

    private func applyAuthoritativeKwtInventory(
        _ inventory: KwtHostInventory,
        hostID: UUID,
        excludingWorktrees: [String: Set<KwtWorktreeIdentity>] = [:],
        publish: Bool = true,
        publishToStore: Bool = true,
        mutation: WorkspaceInventoryStore.MutationPublication? = nil,
        recordsSuccessfulLoad: Bool = true
    ) {
        // A result that predates a later mutation on the host still shows
        // this scene its own mutation, but it is provisional: it is neither
        // authoritative here nor shared, and the fence-end reload replaces it.
        let isStaleMutation = mutation.map { mutation in
            inventoryHosts[hostID].map {
                $0 != mutation.host
                    || workspaceInventoryStore.kwtMutationEpoch(on: $0)
                    != mutation.epoch
            } ?? true
        } ?? false
        let recordsSuccessfulLoad = recordsSuccessfulLoad && !isStaleMutation
        let publishToStore = publishToStore && !isStaleMutation
        if recordsSuccessfulLoad {
            worktreeMutationCoordinator.reconcileRetiredProtectedEndpoints(
                after: inventory,
                hostID: hostID
            )
        }
        let previous = kwtInventoriesByHost[hostID]
        var exclusions = inventoryHosts[hostID].map {
            workspaceInventoryStore.removalTombstones(on: $0)
        } ?? [:]
        for (repository, identities) in excludingWorktrees {
            exclusions[repository, default: []].formUnion(identities)
        }
        var reconciled = inventory.retainingFailedProjectWorktrees(
            from: previous,
            excludingWorktrees: exclusions
        )
        if let commandHost = inventoryHosts[hostID] {
            let removedProjects = workspaceInventoryStore
                .projectRemovalTombstones(on: commandHost)
            reconciled.projects.removeAll { item in
                removedProjects.contains { $0.matches(item.project) }
            }
        }
        kwtInventoriesByHost[hostID] = reconciled
        if recordsSuccessfulLoad {
            kwtAvailabilityByHost[hostID] = true
            kwtInventoryFailuresByHost.removeValue(forKey: hostID)
        }
        if publish {
            applyInventoryOverlayIfNeeded()
            reconcileRetainedTmuxPresentations(
                afterAuthoritativeInventoryFor: hostID
            )
            updateWorkspaceInventoryState()
        }
        if publishToStore, let commandHost = inventoryHosts[hostID] {
            let wasConsumingSharedInventory = isConsumingSharedInventory
            isConsumingSharedInventory = true
            workspaceInventoryStore.publishKwtInventory(
                inventory,
                on: commandHost,
                excludingWorktrees: excludingWorktrees,
                mutation: mutation,
                recordsSuccessfulLoad: recordsSuccessfulLoad
            )
            isConsumingSharedInventory = wasConsumingSharedInventory
            if !wasConsumingSharedInventory {
                consumeSharedInventory(workspaceInventoryStore.snapshot)
            }
        }
    }

    private func resolveQuarantinedProjectRemovals(
        after inventory: KwtHostInventory,
        hostID: UUID,
        sourceHost: CommandHost
    ) {
        guard inventory.projectsWarning == nil else { return }
        let quarantines = worktreeMutationCoordinator
            .quarantinedProjectRemovals.filter { scope, _ in
                scope.hostID == hostID
            }
        for (scope, quarantine) in quarantines {
            guard quarantine.host == sourceHost else {
                worktreeMutationCoordinator.release(
                    hostID: scope.hostID,
                    projectIdentity: scope.projectIdentity,
                    allowsRemovalRestoration: false
                )
                continue
            }
            let projectPath = quarantine.projectPath
            if let item = inventory.projects.first(where: {
                $0.project.repository == scope.projectIdentity
            }) {
                if item.warning != nil {
                    guard normalizedWorkspacePath(item.project.path)
                        == normalizedWorkspacePath(projectPath)
                    else { continue }
                    worktreeMutationCoordinator.release(
                        hostID: scope.hostID,
                        projectIdentity: scope.projectIdentity,
                        allowsRemovalRestoration: false
                    )
                    continue
                }
                worktreeMutationCoordinator.release(
                    hostID: scope.hostID,
                    projectIdentity: scope.projectIdentity,
                    reconciledRestorationTargets:
                    projectRestorationTargets(
                        hostID: scope.hostID,
                        projectIdentity: scope.projectIdentity
                    )
                )
                continue
            }
            if let replacement = inventory.projects.first(where: {
                normalizedWorkspacePath($0.project.path)
                    == normalizedWorkspacePath(projectPath)
            }) {
                guard replacement.warning == nil else { continue }
            }
            worktreeMutationCoordinator.release(
                hostID: scope.hostID,
                projectIdentity: scope.projectIdentity,
                removalTombstones: worktreeMutationCoordinator
                    .pendingRemovals[scope] ?? [],
                removesProject: true,
                allowsRemovalRestoration: false
            )
        }
    }

    private func projectRestorationTargets(
        hostID: UUID,
        projectIdentity: String
    ) -> Set<WorkspaceTmuxSessionSelection> {
        let projectIDs = Set(snapshot.projects.compactMap { project in
            project.hostID == hostID
                && project.scopedKey == projectIdentity
                ? project.id : nil
        })
        return Set(snapshot.worktrees.compactMap { worktree in
            guard worktree.hostID == hostID,
                  projectIDs.contains(worktree.projectID)
            else { return nil }
            return WorkspaceSidebarModel.tmuxSessionSelection(for: worktree)
        })
    }

    private func publishProtectedTmuxEndpoints() {
        guard !isShutDown else {
            worktreeMutationCoordinator.retireProtectedEndpoints(
                for: worktreeMutationParticipantID
            )
            return
        }
        let scopesByProjectID = Dictionary(
            uniqueKeysWithValues: snapshot.projects.map { project in
                (
                    project.id,
                    WorktreeMutationCoordinator.Scope(
                        hostID: project.hostID,
                        projectIdentity: project.scopedKey
                    )
                )
            }
        )
        var endpoints:
            [
                WorktreeMutationCoordinator.Scope:
                    Set<WorktreeMutationCoordinator.ProtectedEndpoint>
            ] = [:]
        for worktree in snapshot.worktrees
            where worktree.tmuxAttachMode == .protected {
            guard let scope = scopesByProjectID[worktree.projectID],
                  scope.hostID == worktree.hostID
            else { continue }
            endpoints[scope, default: []].insert(
                WorktreeMutationCoordinator.ProtectedEndpoint(
                    worktreeName: worktree.name,
                    worktreeIdentity: KwtWorktreeIdentity(
                        path: worktree.path,
                        generation: worktree.generation ?? ""
                    ),
                    selection: WorkspaceSidebarModel.tmuxSessionSelection(
                        for: worktree
                    )
                )
            )
        }
        worktreeMutationCoordinator.replaceProtectedEndpoints(
            endpoints,
            for: worktreeMutationParticipantID
        )
    }

    private func isRemoteKwtUnavailable(
        _ error: Error,
        hostID: UUID
    ) -> Bool {
        guard inventoryHosts[hostID]?.isRemote == true else { return false }
        if let inventoryError = error as? KwtInventoryError,
           case .commandFailed(_, 127) = inventoryError {
            return true
        }
        if let worktreeError = error as? KwtWorktreeError,
           case .commandFailed(_, 127) = worktreeError {
            return true
        }
        if let worktreeError = error as? KwtWorktreeError,
           case .removalFailed(_, 127) = worktreeError {
            return true
        }
        if let worktreeError = error as? KwtWorktreeError,
           case .changeStatusFailed(_, 127) = worktreeError {
            return true
        }
        if let pullRequestError = error as? KwtPullRequestError,
           case .commandFailed(_, 127, _, _, _) = pullRequestError {
            return true
        }
        if let projectError = error as? KwtProjectCommandError,
           case .commandFailed(_, 127, _, _, _, _) = projectError {
            return true
        }
        return false
    }

    private func applyingCachedInventories(
        to source: WorkspaceSnapshot
    ) -> WorkspaceSnapshot {
        HostInventoryOverlay.apply(
            kwtInventoriesByHost: kwtInventoriesByHost,
            kwtAvailabilityByHost: kwtAvailabilityByHost,
            tmuxSessionsByHost: tmuxSessionsByHost,
            herdrSessionsByHost: herdrSessionsByHost,
            zellijSessionsByHost: zellijSessionsByHost,
            herdrAvailabilityByHost: herdrAvailabilityByHost,
            zellijAvailabilityByHost: zellijAvailabilityByHost,
            tmuxReachabilityByHost: tmuxReachabilityByHost,
            tmuxLastSeenByHost: tmuxLastSeenByHost,
            tmuxAuthoritativeHostIDs: tmuxFreshHostIDs,
            to: source
        )
    }

    func refreshTmuxSessionDiscovery() {
        scheduleTmuxSessionDiscovery()
    }

    func startTmuxSessionDiscovery() {
        guard !tmuxDiscoveryEnabled else { return }
        tmuxDiscoveryEnabled = true
        reconcileInventoryHosts()
        updateSharedInventorySubscription()
    }

    private func scheduleTmuxSessionDiscovery() {
        guard tmuxDiscoveryEnabled else { return }
        workspaceInventoryStore.refreshTmux(
            for: workspaceInventorySubscriberID
        )
    }

    private func beginTmuxDiscoveryObservation(hostID: UUID) -> UInt64 {
        tmuxDiscoveryObservationSequence &+= 1
        let sequence = tmuxDiscoveryObservationSequence
        latestTmuxDiscoveryObservationByHost[hostID] = sequence
        return sequence
    }

    private func isCurrentTmuxDiscoveryObservation(
        _ sequence: UInt64,
        hostID: UUID
    ) -> Bool {
        latestTmuxDiscoveryObservationByHost[hostID] == sequence
    }

    private func tmuxRefreshEpoch(hostID: UUID) -> UInt64? {
        inventoryHosts[hostID].map {
            workspaceInventoryStore.tmuxRefreshEpoch(on: $0)
        }
    }

    func startHerdrSessionDiscovery() {
        guard !isShutDown, !herdrDiscoveryEnabled else { return }
        herdrDiscoveryEnabled = true
        let generation = herdrDiscoveryGeneration
        reconcileInventoryHosts()
        if generation == herdrDiscoveryGeneration {
            scheduleHerdrSessionDiscovery()
        }
    }

    private func refreshHerdrSessionDiscovery() {
        guard !isShutDown else { return }
        herdrFreshHostIDs.removeAll()
        for host in inventoryHosts.values where Self.supportsHerdr(host) {
            herdrSessionProbeBroker.invalidateSessions(on: host)
        }
        scheduleHerdrSessionDiscovery()
    }

    private func scheduleHerdrSessionDiscovery() {
        guard !isShutDown, herdrDiscoveryEnabled else { return }
        let targets = inventoryHosts.filter {
            Self.supportsHerdr($0.value)
        }
        herdrDiscoveryGeneration += 1
        let generation = herdrDiscoveryGeneration
        let revisions = Dictionary(uniqueKeysWithValues: targets.keys.map {
            ($0, herdrLifecycleCoordinator.revision(for: $0))
        })
        herdrDiscoveryTask?.cancel()
        inventoryRefreshProgress.herdrCompleted = false
        isHerdrDiscoveryLoading = true
        updateWorkspaceInventoryState()
        let broker = herdrSessionProbeBroker
        let lifecycleCoordinator = herdrLifecycleCoordinator
        herdrDiscoveryTask = Task { [weak self] in
            var needsFreshDiscovery = false
            await withTaskGroup(
                of: (UUID, HerdrDiscoveryResult).self
            ) { group in
                for (hostID, host) in targets {
                    group.addTask {
                        await (hostID, broker.sessions(on: host))
                    }
                }
                for await (hostID, result) in group {
                    guard let self, !Task.isCancelled,
                          generation == self.herdrDiscoveryGeneration else {
                        group.cancelAll()
                        return
                    }
                    guard revisions[hostID]
                        == lifecycleCoordinator.revision(for: hostID)
                    else {
                        needsFreshDiscovery = true
                        self.herdrFreshHostIDs.remove(hostID)
                        continue
                    }
                    guard !lifecycleCoordinator.pendingKeys.contains(
                        where: { $0.hostID == hostID }
                    ) else {
                        self.herdrFreshHostIDs.remove(hostID)
                        continue
                    }
                    if case .failure(.cancelled) = result {
                        needsFreshDiscovery = true
                        self.herdrFreshHostIDs.remove(hostID)
                        continue
                    }
                    self.applyHerdrDiscoveryResult(
                        result,
                        hostID: hostID
                    )
                }
            }
            guard let self, !Task.isCancelled, !isShutDown,
                  generation == herdrDiscoveryGeneration else { return }
            isHerdrDiscoveryLoading = false
            inventoryRefreshProgress.herdrCompleted = true
            updateWorkspaceInventoryState()
            if needsFreshDiscovery {
                Task { @MainActor [weak self] in
                    guard let self, !isShutDown else { return }
                    scheduleHerdrSessionDiscovery()
                }
            }
        }
    }

    private func applyHerdrDiscoveryResult(
        _ result: HerdrDiscoveryResult,
        hostID: UUID,
        publish: Bool = true
    ) {
        herdrFreshHostIDs.insert(hostID)
        switch result {
        case let .available(sessions):
            herdrSessionsByHost[hostID] = sessions
            herdrAvailabilityByHost[hostID] = true
            herdrDiscoveryFailuresByHost.removeValue(forKey: hostID)
        case .unavailable:
            herdrSessionsByHost[hostID] = []
            herdrAvailabilityByHost[hostID] = false
            herdrDiscoveryFailuresByHost.removeValue(forKey: hostID)
        case let .failure(error):
            herdrSessionsByHost[hostID] = []
            herdrAvailabilityByHost[hostID] = false
            let hostName = snapshot.host(id: hostID)?.name ?? "Unknown host"
            herdrDiscoveryFailuresByHost[hostID] =
                "\(hostName): \(error.localizedDescription)"
        }
        if publish {
            applyRuntimeInventoryOverlayIfNeeded(hostID: hostID)
            updateWorkspaceInventoryState()
        }
    }

    private static func supportsHerdr(_ host: CommandHost) -> Bool {
        switch host {
        case .local:
            true
        case let .ssh(info):
            info.platform == .posix
        }
    }

    func startZellijSessionDiscovery() {
        guard !isShutDown, !zellijDiscoveryEnabled else { return }
        zellijDiscoveryEnabled = true
        let generation = zellijDiscoveryGeneration
        reconcileInventoryHosts()
        if generation == zellijDiscoveryGeneration {
            scheduleZellijSessionDiscovery()
        }
    }

    private func refreshZellijSessionDiscovery() {
        guard !isShutDown else { return }
        zellijFreshHostIDs.removeAll()
        scheduleZellijSessionDiscovery()
    }

    private func scheduleZellijSessionDiscovery() {
        guard !isShutDown, zellijDiscoveryEnabled else { return }
        let targets = inventoryHosts.filter { _, host in
            Self.supportsZellij(host)
        }
        zellijCreationDiscoveryRetryTask?.cancel()
        zellijCreationDiscoveryRetryTask = nil
        zellijCreationDiscoveryRetryID = nil
        zellijDiscoveryGeneration += 1
        let generation = zellijDiscoveryGeneration
        zellijDiscoveryTask?.cancel()
        inventoryRefreshProgress.zellijCompleted = false
        isZellijDiscoveryLoading = true
        updateWorkspaceInventoryState()
        let discovery = zellijSessionDiscovery
        zellijDiscoveryTask = Task { [weak self] in
            let results = await withTaskGroup(
                of: (UUID, ZellijDiscoveryResult).self
            ) { group -> [(UUID, ZellijDiscoveryResult)] in
                for (hostID, host) in targets {
                    group.addTask {
                        let probe = Task.detached(priority: .utility) {
                            await discovery(host)
                        }
                        let result = await withTaskCancellationHandler {
                            await probe.value
                        } onCancel: {
                            probe.cancel()
                        }
                        return (hostID, result)
                    }
                }
                var results: [(UUID, ZellijDiscoveryResult)] = []
                for await result in group {
                    guard let self, !Task.isCancelled,
                          generation == self.zellijDiscoveryGeneration
                    else {
                        group.cancelAll()
                        return []
                    }
                    results.append(result)
                }
                return results
            }
            guard let self, !Task.isCancelled, !isShutDown,
                  generation == zellijDiscoveryGeneration else { return }
            for (hostID, result) in results {
                applyZellijDiscoveryResult(
                    result,
                    hostID: hostID,
                    publish: false
                )
            }
            applyRuntimeInventoryOverlayIfNeeded()
            isZellijDiscoveryLoading = false
            inventoryRefreshProgress.zellijCompleted = true
            updateWorkspaceInventoryState()
            reconcileZellijCreationDiscoveryRetry()
        }
    }

    private func applyZellijDiscoveryResult(
        _ result: ZellijDiscoveryResult,
        hostID: UUID,
        publish: Bool = true
    ) {
        zellijFreshHostIDs.insert(hostID)
        let pending = pendingCreatedZellijSessions.filter {
            $0.value.hostID == hostID
        }
        switch result {
        case let .available(names):
            var sessions = names.map {
                ZellijSessionSummary(name: $0)
            }
            for (handleID, selection) in pending {
                if names.contains(selection.name) {
                    pendingCreatedZellijSessions.removeValue(forKey: handleID)
                } else if !sessions.contains(where: {
                    $0.name == selection.name
                }) {
                    sessions.append(ZellijSessionSummary(name: selection.name))
                }
            }
            zellijSessionsByHost[hostID] = sessions
            zellijAvailabilityByHost[hostID] = true
            zellijDiscoveryFailuresByHost.removeValue(forKey: hostID)
        case .unavailable:
            zellijSessionsByHost[hostID] = pendingZellijSessionSummaries(
                pending
            )
            zellijAvailabilityByHost[hostID] = !pending.isEmpty
            zellijDiscoveryFailuresByHost.removeValue(forKey: hostID)
        case let .failure(error):
            zellijSessionsByHost[hostID] = pendingZellijSessionSummaries(
                pending
            )
            zellijAvailabilityByHost[hostID] = !pending.isEmpty
            let hostName = snapshot.host(id: hostID)?.name ?? "Unknown host"
            zellijDiscoveryFailuresByHost[hostID] =
                "\(hostName): \(error.localizedDescription)"
        }
        if publish {
            applyRuntimeInventoryOverlayIfNeeded(hostID: hostID)
            updateWorkspaceInventoryState()
        }
    }

    private func pendingZellijSessionSummaries(
        _ pending: [UUID: WorkspaceZellijSessionSelection]
    ) -> [ZellijSessionSummary] {
        pending.values
            .map { ZellijSessionSummary(name: $0.name) }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    private func reconcileZellijCreationDiscoveryRetry() {
        let pendingHostIDs = Set(
            pendingCreatedZellijSessions.values.map(\.hostID)
        )
        guard !pendingHostIDs.isEmpty else {
            zellijCreationDiscoveryRetryTask?.cancel()
            zellijCreationDiscoveryRetryTask = nil
            zellijCreationDiscoveryRetryID = nil
            zellijCreationDiscoveryRetryAttempt = 0
            return
        }
        guard zellijCreationDiscoveryRetryTask == nil else { return }
        let delays = createdSessionDiscoveryDelays.isEmpty
            ? [.seconds(1)]
            : createdSessionDiscoveryDelays
        let delayIndex = min(
            zellijCreationDiscoveryRetryAttempt,
            delays.count - 1
        )
        let delay = delays[delayIndex]
        if zellijCreationDiscoveryRetryAttempt < delays.count - 1 {
            zellijCreationDiscoveryRetryAttempt += 1
        }
        let retryID = UUID()
        zellijCreationDiscoveryRetryID = retryID
        zellijCreationDiscoveryRetryTask = Task { [weak self] in
            defer {
                if let self, zellijCreationDiscoveryRetryID == retryID {
                    zellijCreationDiscoveryRetryTask = nil
                    zellijCreationDiscoveryRetryID = nil
                }
            }
            do {
                try await Task.sleep(for: delay)
            } catch {
                return
            }
            guard let self, !isShutDown,
                  zellijCreationDiscoveryRetryID == retryID else { return }
            let currentPendingHostIDs = Set(
                pendingCreatedZellijSessions.values.map(\.hostID)
            )
            guard !currentPendingHostIDs.isEmpty else {
                zellijCreationDiscoveryRetryAttempt = 0
                return
            }
            let targets = inventoryHosts.filter { hostID, host in
                Self.supportsZellij(host)
                    && currentPendingHostIDs.contains(hostID)
            }
            let discovery = zellijSessionDiscovery
            let results = await withTaskGroup(
                of: (UUID, ZellijDiscoveryResult).self
            ) { group -> [(UUID, ZellijDiscoveryResult)] in
                for (hostID, host) in targets {
                    group.addTask {
                        let probe = Task.detached(priority: .utility) {
                            await discovery(host)
                        }
                        let result = await withTaskCancellationHandler {
                            await probe.value
                        } onCancel: {
                            probe.cancel()
                        }
                        return (hostID, result)
                    }
                }
                var results: [(UUID, ZellijDiscoveryResult)] = []
                for await result in group {
                    guard !Task.isCancelled else {
                        group.cancelAll()
                        return []
                    }
                    results.append(result)
                }
                return results
            }
            guard !Task.isCancelled, !isShutDown,
                  zellijCreationDiscoveryRetryID == retryID else { return }
            for (hostID, result) in results {
                applyZellijDiscoveryResult(
                    result,
                    hostID: hostID,
                    publish: false
                )
            }
            applyRuntimeInventoryOverlayIfNeeded()
            updateWorkspaceInventoryState()
            zellijCreationDiscoveryRetryTask = nil
            zellijCreationDiscoveryRetryID = nil
            reconcileZellijCreationDiscoveryRetry()
        }
    }

    private static func supportsZellij(_ host: CommandHost) -> Bool {
        switch host {
        case .local:
            true
        case let .ssh(info):
            info.platform == .posix
        }
    }

    /// Applies a scene-local tmux discovery. Passing `publishingEpoch`, the
    /// store epoch captured before the probe started, shares the result with
    /// every window unless a newer shared refresh has begun since.
    private func applyTmuxDiscoveryResult(
        _ result: Result<[DiscoveredTmuxSession], TmuxBinaryError>,
        hostID: UUID,
        publish: Bool = true,
        publishingEpoch: UInt64? = nil
    ) {
        guard let discovered = recordTmuxDiscoveryState(
            result,
            hostID: hostID
        ) else {
            if publish {
                applyRuntimeInventoryOverlayIfNeeded(hostID: hostID)
                updateWorkspaceInventoryState()
            }
            return
        }
        reconcileEndedTmuxSession(discovered, hostID: hostID)
        tmuxSessionsByHost[hostID] = reconciledTmuxSessions(
            discovered,
            hostID: hostID
        )
        if let publishingEpoch, let commandHost = inventoryHosts[hostID] {
            workspaceInventoryStore.publishTmuxSessions(
                discovered,
                on: commandHost,
                epoch: publishingEpoch
            )
        }
        for presentation in retainedTmuxPresentations.values {
            guard var context = presentation.reconnectContext,
                  context.phase == .establishingWorkspace,
                  context.selection.hostID == hostID,
                  context.selection.socketName == nil,
                  discovered.contains(where: {
                      $0.name == context.selection.name
                  })
            else { continue }
            context.phase = .attachOnly
            presentation.reconnectContext = context
            presentation.establishmentConfirmationTask?.cancel()
            presentation.establishmentConfirmationTask = nil
        }
        if publish {
            applyRuntimeInventoryOverlayIfNeeded(hostID: hostID)
            updateWorkspaceInventoryState()
            applyDeferredTmuxPresentationsIfReady()
            reconcileAlwaysLiveTmuxPresentations(hostID: hostID)
        }
    }

    @discardableResult
    private func recordTmuxDiscoveryState(
        _ result: Result<[DiscoveredTmuxSession], TmuxBinaryError>,
        hostID: UUID
    ) -> [DiscoveredTmuxSession]? {
        switch result {
        case let .success(discovered):
            tmuxDiscoveryFailuresByHost.removeValue(forKey: hostID)
            tmuxFreshHostIDs.insert(hostID)
            tmuxReachabilityByHost[hostID] = true
            tmuxLastSeenByHost[hostID] = Date()
            return discovered
        case let .failure(error):
            tmuxFreshHostIDs.remove(hostID)
            tmuxReachabilityByHost[hostID] =
                !Self.isConfirmedSSHTransportFailure(error)
            let hostName = snapshot.host(id: hostID)?.name
                ?? "Unknown host"
            tmuxDiscoveryFailuresByHost[hostID] =
                "\(hostName): \(error.localizedDescription)"
            return nil
        }
    }

    private func reconcileEndedTmuxSession(
        _ discovered: [DiscoveredTmuxSession],
        hostID: UUID
    ) {
        for presentation in retainedTmuxPresentations.values {
            let selection = presentation.selection
            let handle = presentation.handle
            guard selection.hostID == hostID,
                  selection.socketName == nil,
                  nativeTmuxSessionCoordinator.hasClosedAttachment(handle)
            else { continue }
            if discovered.contains(where: { $0.name == selection.name }) {
                confirmedEndedTmuxSessionHandles.remove(handle.id)
            } else {
                confirmedEndedTmuxSessionHandles.insert(handle.id)
            }
        }
    }

    private func fenceTmuxDiscoveryForCreationReconciliation(
        host: CommandHost
    ) {
        tmuxSessionProbeBroker.invalidateSessions(on: host)
        isTmuxDiscoveryLoading = false
        inventoryRefreshProgress.tmuxCompleted = false
        if tmuxDiscoveryEnabled {
            scheduleTmuxSessionDiscovery()
        } else {
            updateWorkspaceInventoryState()
        }
    }

    private static func isConfirmedSSHTransportFailure(
        _ error: TmuxBinaryError
    ) -> Bool {
        guard case let .sshConnectionFailed(_, classification) = error else {
            return false
        }
        return classification.kind == .transport
    }

    private func updateWorkspaceInventoryState() {
        let projectWarnings = kwtInventoriesByHost.values
            .flatMap(\.projects)
            .compactMap { item in
                item.warning.map { warning in
                    "\(item.project.name): \(warning)"
                }
            }
        let uniqueProjectWarnings = Array(Set(projectWarnings)).sorted()
        let projectListWarningsByHost = kwtInventoriesByHost.compactMapValues {
            $0.projectsWarning.map {
                "Projects: \($0)"
            }
        }
        let directoryWarningsByHost = kwtInventoriesByHost.compactMapValues {
            $0.directoryWorkspaceWarning.map {
                "Directory workspaces: \($0)"
            }
        }
        let hostIDs = Set(kwtInventoryFailuresByHost.keys)
            .union(tmuxDiscoveryFailuresByHost.keys)
            .union(projectListWarningsByHost.keys)
            .union(directoryWarningsByHost.keys)
            .union(herdrDiscoveryFailuresByHost.keys)
            .union(zellijDiscoveryFailuresByHost.keys)
        workspaceInventoryWarningsByHost = Dictionary(
            uniqueKeysWithValues: hostIDs.compactMap { hostID in
                let warnings = [
                    kwtInventoryFailuresByHost[hostID],
                    tmuxDiscoveryFailuresByHost[hostID],
                    projectListWarningsByHost[hostID],
                    directoryWarningsByHost[hostID],
                    herdrDiscoveryFailuresByHost[hostID],
                    zellijDiscoveryFailuresByHost[hostID],
                ].compactMap { $0 }
                let unique = Array(Set(warnings)).sorted()
                guard !unique.isEmpty else { return nil }
                return (hostID, unique.joined(separator: "\n"))
            }
        )
        workspaceInventoryWarning = uniqueProjectWarnings.isEmpty
            ? nil
            : uniqueProjectWarnings.joined(separator: "\n")
        let hasVisibleInventory = !snapshot.projects.isEmpty
            || !snapshot.directoryWorkspaces.isEmpty
            || snapshot.hosts.contains { !$0.tmuxSessions.isEmpty }
            || snapshot.hosts.contains { !$0.herdrSessions.isEmpty }
            || snapshot.hosts.contains { !$0.zellijSessions.isEmpty }
        let hasCachedInventory = hasVisibleInventory
            || !kwtInventoriesByHost.isEmpty
            || !tmuxSessionsByHost.isEmpty
            || herdrSessionsByHost.values.contains { !$0.isEmpty }
            || zellijSessionsByHost.values.contains { !$0.isEmpty }
        let hasPendingSources = isKwtInventoryLoading
            || isTmuxDiscoveryLoading
            || isHerdrDiscoveryLoading
            || isZellijDiscoveryLoading
        if hasPendingSources, !hasVisibleInventory {
            workspaceInventoryState = .loading
            return
        }
        let localWarnings = [
            kwtInventoryFailuresByHost[localHostID],
            tmuxDiscoveryFailuresByHost[localHostID],
        ].compactMap { $0 }
        if !hasPendingSources,
           !hasCachedInventory,
           !localWarnings.isEmpty {
            workspaceInventoryState = .failed(
                Array(Set(localWarnings)).sorted().joined(separator: "\n")
            )
            return
        }
        // Remote discovery is additive. Its failure belongs to that host and
        // must never replace the workspace with a blocking error.
        workspaceInventoryState = .loaded
    }

    func logViewerTerminalView() -> AnyView? {
        guard let hostID = snapshot.hosts.first(
            where: { $0.kind == .selfHost }
        )?.id else {
            return nil
        }
        AppLogger.shared.ensureLogFileExists()
        let key = SurfaceKey(
            worktreeID: nil,
            hostID: hostID,
            target: .logViewer
        )
        let quotedPath = shellQuotedCommandArgument(AppLogger.logFilePath)
        guard let surface = terminalCoordinator.surface(
            for: key,
            configuration: TerminalSurfaceConfiguration(
                command: "tail -f \(quotedPath)",
                waitAfterCommand: true
            )
        ) else {
            return nil
        }
        return AnyView(
            TerminalSurfaceSwiftUIView(surfaceView: surface)
        )
    }

    func dismissLogViewer() {
        isLogViewerPresented = false
        guard let hostID = snapshot.hosts.first(
            where: { $0.kind == .selfHost }
        )?.id else {
            return
        }
        let key = SurfaceKey(
            worktreeID: nil,
            hostID: hostID,
            target: .logViewer
        )
        terminalCoordinator.removeSurface(for: key)
    }

    private func recordSelectedWorktreeView() {
        guard let worktreeID = selection.selectedWorktreeID,
              let worktree = snapshot.worktree(id: worktreeID)
        else { return }
        activityController.updateLastViewedAt(
            worktreeID: worktreeID,
            hostID: worktree.hostID
        )
    }

    func refreshHosts() {
        refreshExeHosts()
        snapshot = applyingConfiguredSSHHosts(
            configuredSSHHostsProvider(),
            exeHosts: configuredExeHostsProvider(),
            to: snapshot
        )
    }

    private func applyingConfiguredSSHHosts(
        _ configuredHosts: [SSHHost],
        exeHosts: [ExeConfiguredHost],
        to source: WorkspaceSnapshot
    ) -> WorkspaceSnapshot {
        let updated = ConfiguredHostOverlay.apply(
            configuredHosts,
            exeHosts: exeHosts,
            to: source
        )
        let previousTargets = Self.resolvedEndpoints(of: source)
        let updatedTargets = Self.resolvedEndpoints(of: updated)
        let invalidatedHostIDs = Set(previousTargets.keys.filter { hostID in
            previousTargets[hostID] != updatedTargets[hostID]
        })
        tmuxSessionActivityController?.reconcile(
            endpointsByHostID: updatedTargets
        )
        invalidateNativeSessionAttachments(for: invalidatedHostIDs)
        releaseObsoleteProjectRemovalQuarantines(
            resolvedEndpoints: updatedTargets
        )
        return updated
    }

    private func releaseObsoleteProjectRemovalQuarantines(
        resolvedEndpoints: [UUID: CommandHost]
    ) {
        for (scope, quarantine) in worktreeMutationCoordinator
            .quarantinedProjectRemovals
            where resolvedEndpoints[scope.hostID] != quarantine.host {
            worktreeMutationCoordinator.release(
                hostID: scope.hostID,
                projectIdentity: scope.projectIdentity,
                allowsRemovalRestoration: false
            )
        }
    }

    private static func resolvedEndpoints(
        of snapshot: WorkspaceSnapshot
    ) -> [UUID: CommandHost] {
        Dictionary(
            uniqueKeysWithValues: snapshot.hosts.compactMap { host in
                CommandHostResolver.resolve(host).map { (host.id, $0) }
            }
        )
    }

    private func invalidateNativeSessionAttachments(for hostIDs: Set<UUID>) {
        guard !hostIDs.isEmpty else { return }
        failPendingHerdrLaunchOperations {
            hostIDs.contains($0.key.hostID)
        }
        for scope in pendingRemovalPresentationRestorations.keys
            where hostIDs.contains(scope.hostID) {
            pendingRemovalPresentationRestorations.removeValue(forKey: scope)
        }
        let pendingForInvalidatedHosts = pendingCreatedTmuxSessions.filter {
            hostIDs.contains($0.value.selection.hostID)
        }
        for (handleID, pending) in pendingForInvalidatedHosts {
            createdSessionDiscoveryTasks.removeValue(
                forKey: handleID
            )?.cancel()
            exhaustedCreatedTmuxSessionHandles.remove(handleID)
            endedCreatedTmuxSessionHandles.remove(handleID)
            pendingCreatedTmuxSessions.removeValue(forKey: handleID)
            borrowedTmuxConnectionStates.removeValue(forKey: handleID)
            removeOptimisticTmuxSession(pending.selection)
        }
        for hostID in hostIDs {
            let handles = nativeTmuxSessionCoordinator.detachAll(
                hostID: hostID
            )
            for handle in handles {
                releaseProtectedTmuxAttachmentScope(handleID: handle.id)
                if let key = retainedTmuxPresentationKeysByHandle
                    .removeValue(forKey: handle.id),
                    let presentation = retainedTmuxPresentations
                    .removeValue(forKey: key) {
                    alwaysLiveManagedTmuxPresentationKeys.remove(key)
                    tmuxSessionPreviewCoordinator.remove(
                        key.previewKey,
                        reason: .replacement
                    )
                    cancelTmuxReconnect(presentation)
                }
                cancelTmuxPresentationTasks(handleID: handle.id)
                borrowedTmuxConnectionStates.removeValue(forKey: handle.id)
                createdSessionDiscoveryTasks.removeValue(
                    forKey: handle.id
                )?.cancel()
                exhaustedCreatedTmuxSessionHandles.remove(handle.id)
                endedCreatedTmuxSessionHandles.remove(handle.id)
            }
            let herdrHandles = nativeHerdrSessionCoordinator.detachAll(
                hostID: hostID
            )
            for handle in herdrHandles {
                borrowedHerdrConnectionStates.removeValue(forKey: handle.id)
            }
            let zellijHandles = nativeZellijSessionCoordinator.detachAll(
                hostID: hostID
            )
            for handle in zellijHandles {
                borrowedZellijConnectionStates.removeValue(forKey: handle.id)
                pendingCreatedZellijSessions.removeValue(forKey: handle.id)
            }
        }
        zellijKillAuthorities = zellijKillAuthorities.filter {
            !hostIDs.contains($0.value.hostID)
        }
        if let activeHerdr = activeBorrowedHerdrSelection,
           hostIDs.contains(activeHerdr.hostID) {
            cancelHerdrReconnect()
            failedHerdrLaunchIntent = nil
            activeBorrowedHerdrSelection = nil
            activeBorrowedHerdrHandle = nil
        }
        if let intent = zellijPresentationIntent,
           hostIDs.contains(intent.selection.hostID) {
            invalidateZellijPresentationIntent()
        }
        if let activeZellij = activeBorrowedZellijSelection,
           hostIDs.contains(activeZellij.hostID) {
            invalidateZellijPresentationIntent()
            cancelZellijReconnect()
            if failedZellijCreationIntent == activeZellij {
                failedZellijCreationIntent = nil
            }
            activeBorrowedZellijSelection = nil
            activeBorrowedZellijHandle = nil
        }
        guard let active = activeBorrowedTmuxSelection,
              hostIDs.contains(active.hostID) else { return }
        activeBorrowedTmuxSelection = nil
        activeBorrowedTmuxHandle = nil
        activeBorrowedTmuxLaunchMode = nil
        activeBorrowedTmuxRecoveryState = nil
        sessionConnectionRecoveryRequest = nil
    }

    private func failPendingHerdrLaunchOperations(
        where shouldFail: (HerdrSessionLifecycleCoordinator.Operation) -> Bool
    ) {
        let matches = pendingHerdrLaunchOperations.filter {
            shouldFail($0.value.operation)
        }
        for (handleID, pending) in matches {
            herdrLaunchConfirmationTasks.removeValue(
                forKey: handleID
            )?.cancel()
            pendingHerdrLaunchOperations.removeValue(forKey: handleID)
            herdrLifecycleCoordinator.finish(
                pending.operation,
                outcome: .failed
            )
        }
    }

    func pendingSSHHostKeyConfirmation(
        for host: SSHHost,
        reviewID: UUID = UUID()
    ) async -> Result<SSHHostKeyReviewRequirement, HostProbeError> {
        guard let resolved = resolvedSSHHost(host) else {
            return .failure(.message("Enter a valid SSH destination."))
        }
        return await mapSSHHostTrustRequirement(
            hostSSHSession(
                for: resolved,
                ownerID: reviewID
            ).pendingRequirement()
        )
    }

    func cancelPresentationSSHAcquisition() {
        guard let presentationSSHSessionID else { return }
        removePresentationSSHSession(
            presentationSSHSessionID,
            cancel: true
        )
    }

    func acquirePresentationSSHConnection(
        hostID: UUID,
        info: SSHHostInfo
    ) async throws -> KwtSSHConnection {
        let demoArguments = demoSSHIsolationArguments(
            environment: presentationSSHEnvironment
        )
        if !demoArguments.isEmpty {
            return KwtSSHConnection(
                arguments: demoArguments,
                routeIdentity: SSHDestination.demoRouteIdentity(info),
                generation: 0
            )
        }
        if let presentationSSHConnectionProvider {
            return try await presentationSSHConnectionProvider(hostID, info)
        }
        let destination = SSHDestination.render(info)
        let sessionID = UUID()
        let session = KwtSSHConnectionSession(
            host: info,
            destination: destination,
            coordinator: presentationSSHAcquisitionCoordinator,
            onPresentationRequired: { [weak self] in
                self?.presentationSSHSessionNeedsAttention(sessionID)
            }
        )
        presentationSSHSessions[sessionID] = session
        presentationSSHSessionOrder.append(sessionID)
        do {
            let connection = try await withTaskCancellationHandler {
                try await session.takeConnection(waitingAcrossRetries: true)
            } onCancel: { [weak self] in
                Task { @MainActor in
                    self?.removePresentationSSHSession(
                        sessionID,
                        cancel: true
                    )
                }
            }
            removePresentationSSHSession(sessionID, cancel: false)
            return connection
        } catch {
            if session.needsPresentation {
                presentationSSHSessionNeedsAttention(sessionID)
            } else {
                removePresentationSSHSession(sessionID, cancel: false)
            }
            throw error
        }
    }

    private func presentationSSHSessionNeedsAttention(_ sessionID: UUID) {
        guard presentationSSHSessions[sessionID]?.needsPresentation == true
        else { return }
        if let activeID = presentationSSHSessionID,
           presentationSSHSessions[activeID]?.needsPresentation == true {
            return
        }
        presentationSSHSessionID = sessionID
        presentationSSHSession = presentationSSHSessions[sessionID]
    }

    private func removePresentationSSHSession(
        _ sessionID: UUID,
        cancel: Bool
    ) {
        guard let session = presentationSSHSessions.removeValue(
            forKey: sessionID
        ) else { return }
        presentationSSHSessionOrder.removeAll { $0 == sessionID }
        if cancel {
            session.cancel()
        }
        guard presentationSSHSessionID == sessionID else { return }
        presentationSSHSessionID = nil
        presentationSSHSession = nil
        if let nextID = presentationSSHSessionOrder.first(where: {
            presentationSSHSessions[$0]?.needsPresentation == true
        }) {
            presentationSSHSessionID = nextID
            presentationSSHSession = presentationSSHSessions[nextID]
        }
    }

    private func cancelAllPresentationSSHAcquisitions() {
        let sessions = Array(presentationSSHSessions.values)
        presentationSSHSessions.removeAll()
        presentationSSHSessionOrder.removeAll()
        presentationSSHSessionID = nil
        presentationSSHSession = nil
        sessions.forEach { $0.cancel() }
    }

    func pendingSSHHostKeyConfirmation(
        forHostID hostID: UUID
    ) async -> Result<SSHHostKeyReviewRequirement, HostProbeError> {
        guard let host = configuredSSHHost(for: hostID) else {
            return .failure(.message(
                "The selected remote host is no longer configured."
            ))
        }
        return await pendingSSHHostKeyConfirmation(
            for: host,
            reviewID: hostID
        )
    }

    func sshConnectionRecovery(
        forHostID hostID: UUID,
        inventoryWarning: String
    ) async -> SSHConnectionRecoveryResult {
        guard let host = configuredSSHHost(for: hostID) else {
            return .connectionIssue(
                "The selected remote host is no longer configured."
            )
        }

        let trustResult = await pendingSSHHostKeyConfirmation(
            for: host,
            reviewID: hostID
        )
        switch trustResult {
        case let .success(requirement):
            switch requirement {
            case let .confirmation(confirmation):
                return .hostKey(confirmation)
            case .authenticationRequired:
                return .authenticationRequired
            case .none:
                break
            }
        case let .failure(error):
            return .connectionIssue(error.displayMessage)
        }

        switch await probeSSHHost(host, reviewID: hostID) {
        case let .success(summary):
            let diagnostic = summary.diagnostics.first.map {
                "\($0.summary) \($0.recoverySuggestion)"
            }
            if summary.host.lastKnownReachable {
                return .inventoryIssue(diagnostic ?? inventoryWarning)
            }
            if summary.diagnostics.first?.code == .sshAuthenticationFailed {
                return .authenticationRequired
            }
            return .connectionIssue(
                diagnostic ?? "Ghosthub could not reach this host over SSH."
            )
        case let .failure(error):
            return .connectionIssue(error.displayMessage)
        }
    }

    func trustSSHHostKey(
        _ confirmation: SSHHostKeyConfirmation,
        for host: SSHHost
    ) async -> Result<SSHHostKeyConfirmation?, HostProbeError> {
        guard let resolved = resolvedSSHHost(host) else {
            return .failure(.message("Enter a valid SSH destination."))
        }
        let session = hostSSHSession(for: resolved)
        guard session.hostKeyConfirmation == confirmation else {
            return .failure(.message(
                "The SSH host-key requirement changed. Review it and try again."
            ))
        }
        session.trust(confirmation)
        return await mapSSHHostTrustRequirement(
            session.pendingRequirement()
        ).map { requirement in
            switch requirement {
            case let .confirmation(confirmation):
                return confirmation
            case .authenticationRequired, .none:
                return nil
            }
        }
    }

    func trustSSHHostKey(
        _ confirmation: SSHHostKeyConfirmation,
        forHostID hostID: UUID
    ) async -> Result<SSHHostKeyConfirmation?, HostProbeError> {
        guard let host = configuredSSHHost(for: hostID) else {
            return .failure(.message(
                "The selected remote host is no longer configured."
            ))
        }
        return await trustSSHHostKey(confirmation, for: host)
    }

    func sshAuthenticationView(
        surfaceID: UUID,
        for host: SSHHost
    ) -> AnyView? {
        guard let resolved = resolvedSSHHost(host) else { return nil }
        guard hostSSHSessionDestination == resolved.destination,
              let session = hostSSHSession
        else { return nil }
        hostSSHSessionSurfaceID = surfaceID
        return AnyView(
            KwtSSHAuthenticationView(
                session: session,
                onCancel: { [weak self] in
                    self?.cancelSSHAuthentication(surfaceID: surfaceID)
                }
            )
            .id(ObjectIdentifier(session))
        )
    }

    func sshAuthenticationView(forHostID hostID: UUID) -> AnyView? {
        guard let host = configuredSSHHost(for: hostID) else { return nil }
        return sshAuthenticationView(surfaceID: hostID, for: host)
    }

    func isSSHAuthenticationReady(
        for host: SSHHost
    ) async -> SSHAuthenticationReadiness {
        guard let resolved = resolvedSSHHost(host) else { return .pending }
        guard hostSSHSessionDestination == resolved.destination,
              let session = hostSSHSession
        else { return .pending }
        switch session.state {
        case .connected:
            return .connected
        case .configurationChanged:
            return .reviewRequired
        case .starting, .prompt, .verifying, .failed:
            return .pending
        }
    }

    func isSSHAuthenticationReady(
        forHostID hostID: UUID
    ) async -> SSHAuthenticationReadiness {
        guard let host = configuredSSHHost(for: hostID) else { return .pending }
        return await isSSHAuthenticationReady(for: host)
    }

    func probeExeAccountConnection(
        _ account: ExeAccount,
        probe: @escaping @Sendable (
            ExeAccount, KwtSSHConnection?
        ) async -> ExeAccountConnectionProbeResult = { account, connection in
            await ExeVMClient().connectionProbe(
                for: account,
                connection: connection
            )
        }
    ) async -> ExeAccountConnectionProbeResult {
        let destination = account.sshDestination.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        let retainedConnection: KwtSSHConnection?
        if hostSSHSessionDestination == destination,
           let session = hostSSHSession,
           session.state == .connected {
            do {
                retainedConnection = try await session.takeConnection()
                hostSSHSession = nil
                hostSSHSessionDestination = nil
                hostSSHSessionOwnerID = nil
                hostSSHSessionSurfaceID = nil
            } catch {
                return .failed(error.localizedDescription)
            }
        } else {
            retainedConnection = nil
        }

        let result = await probe(account, retainedConnection)
        guard let retainedConnection else { return result }
        do {
            try await retainedConnection.release()
            return result
        } catch {
            return .failed(
                "Ghosthub could not release the SSH connection: "
                    + error.localizedDescription
            )
        }
    }

    func cancelSSHAuthentication(surfaceID: UUID) {
        guard hostSSHSessionOwnerID == surfaceID
            || hostSSHSessionSurfaceID == surfaceID
        else { return }
        let session = hostSSHSession
        hostSSHSession = nil
        hostSSHSessionDestination = nil
        hostSSHSessionOwnerID = nil
        hostSSHSessionSurfaceID = nil
        session?.cancel()
    }

    func retainSSHAuthenticationForHandoff(surfaceID: UUID) {
        guard hostSSHSessionSurfaceID == surfaceID,
              hostSSHSession?.state == .connected
        else { return }
        hostSSHSessionSurfaceID = nil
    }

    func completeSSHAuthentication(
        surfaceID: UUID,
        startingNextOwner: @MainActor () -> Void
    ) async {
        guard hostSSHSessionSurfaceID == surfaceID,
              let session = hostSSHSession,
              session.state == .connected
        else {
            startingNextOwner()
            return
        }
        hostSSHSession = nil
        hostSSHSessionDestination = nil
        hostSSHSessionOwnerID = nil
        hostSSHSessionSurfaceID = nil
        do {
            let connection = try await session.takeConnection()
            await connection.handoffToNextOwner(starting: startingNextOwner)
        } catch {
            session.cancel()
            startingNextOwner()
        }
    }

    private func mapSSHHostTrustRequirement(
        _ result: Result<SSHHostTrustRequirement, HostProbeError>
    ) -> Result<SSHHostKeyReviewRequirement, HostProbeError> {
        switch result {
        case let .success(requirement):
            switch requirement {
            case let .confirmation(confirmation):
                return .success(.confirmation(confirmation))
            case .authentication:
                return .success(.authenticationRequired)
            case .none:
                return .success(.none)
            }
        case let .failure(error):
            return .failure(error)
        }
    }

    private func hostSSHSession(
        for resolved: (info: SSHHostInfo, destination: String),
        ownerID: UUID? = nil
    ) -> KwtSSHConnectionSession {
        if hostSSHSessionDestination == resolved.destination,
           let hostSSHSession {
            switch hostSSHSession.state {
            case .failed, .configurationChanged:
                break
            case .starting, .prompt, .verifying, .connected:
                if let ownerID {
                    hostSSHSessionOwnerID = ownerID
                }
                return hostSSHSession
            }
        }
        hostSSHSession?.cancel()
        let session = hostSSHSessionProvider(
            resolved.info,
            resolved.destination
        )
        hostSSHSession = session
        hostSSHSessionDestination = resolved.destination
        hostSSHSessionOwnerID = ownerID
        hostSSHSessionSurfaceID = nil
        return session
    }

    private func configuredSSHHost(for hostID: UUID) -> SSHHost? {
        guard let host = snapshot.host(id: hostID),
              host.kind == .remote,
              let destination = host.sshDestination else { return nil }
        return SSHHost(
            configKey: host.configKey,
            name: host.name,
            platform: host.platform,
            sshDestination: destination
        )
    }

    private func ensureRemoteKwtForOperation(
        on host: SSHHost,
        hostID: UUID? = nil
    ) async throws {
        guard host.platform == .macOS || host.platform == .linux else {
            return
        }
        do {
            try await kwtRemoteProvisioner(host)
            if let hostID {
                kwtAvailabilityByHost[hostID] = true
                kwtInventoryFailuresByHost.removeValue(forKey: hostID)
                applyInventoryOverlayIfNeeded()
                updateWorkspaceInventoryState()
            }
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            if let hostID {
                markRemoteKwtUnavailable(hostID: hostID)
            }
            throw error
        }
    }

    private func ensureRemoteKwtForOperation(hostID: UUID) async throws {
        guard let host = configuredSSHHost(for: hostID) else { return }
        try await ensureRemoteKwtForOperation(on: host, hostID: hostID)
    }

    private func resolvedSSHHost(
        _ host: SSHHost
    ) -> (info: SSHHostInfo, destination: String)? {
        let destination = host.sshDestination.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        guard let parsed = CommandHostResolver.parseSSHDestination(
            destination
        ) else {
            return nil
        }
        return (
            SSHHostInfo(
                user: parsed.user,
                hostname: parsed.hostname,
                port: parsed.port,
                platform: host.platform == .windows ? .windows : .posix
            ),
            destination
        )
    }

    func probeSSHHost(
        _ host: SSHHost,
        reviewID: UUID? = nil,
        protocolNonce: String = UUID().uuidString
    ) async -> Result<
        HostProbeSummary,
        HostProbeError
    > {
        guard let resolved = resolvedSSHHost(host) else {
            return .failure(.message("Enter a valid SSH destination."))
        }
        let sshHost = resolved.info
        let sshHostProbeRunner = sshHostProbeRunner
        let kwtPrelude = KwtBinaryLocator.remoteCommandPrelude(
            revision: KwtBinaryLocator.bundledRemoteRevision()
        )
        let windowsKwtRelativePath =
            KwtBinaryLocator.windowsRemoteManagedRelativePath(
                revision: KwtBinaryLocator.bundledRemoteRevision()
            )
        let protocolStart = "GHOSTHUB_SSH_PROBE_\(protocolNonce)_START"
        let protocolEnd = "GHOSTHUB_SSH_PROBE_\(protocolNonce)_END"
        let probeCommand: String
        if host.platform == .windows {
            probeCommand = """
            $ErrorActionPreference = 'Stop'
            [Console]::OutputEncoding = [System.Text.UTF8Encoding]::new($false)
            $OutputEncoding = [Console]::OutputEncoding
            [Console]::Out.WriteLine()
            Write-Output '\(protocolStart)'
            Write-Output 'GHOSTHUB_SSH_REACHED'
            $ghosthubMuxCommand = Get-Command tmux.exe -CommandType Application -ErrorAction SilentlyContinue
            if ($null -eq $ghosthubMuxCommand) {
                Write-Output 'GHOSTHUB_TMUX_UNAVAILABLE'
                Write-Output '\(protocolEnd)'
                exit 127
            }
            Write-Output 'GHOSTHUB_TMUX_AVAILABLE'
            $ghosthubMux = $ghosthubMuxCommand.Source
            & $ghosthubMux '-V' *> $null
            if ($LASTEXITCODE -ne 0) {
                Write-Output '\(protocolEnd)'
                exit $LASTEXITCODE
            }
            \(KwtPowerShellCommand.availabilityPrelude(
                managedRelativePath: windowsKwtRelativePath
            ))
            if ($ghosthubKwtAvailable) {
                Write-Output 'GHOSTHUB_KWT_AVAILABLE'
            } else {
                Write-Output 'GHOSTHUB_KWT_UNAVAILABLE'
            }
            Write-Output '\(protocolEnd)'
            """
        } else {
            probeCommand =
                "printf '\\n\(protocolStart)\\nGHOSTHUB_SSH_REACHED\\n'; "
                    + "ghosthub_tmux_path=$(command -v tmux) || { "
                    + "printf 'GHOSTHUB_TMUX_UNAVAILABLE\\n\(protocolEnd)\\n'; "
                    + "exit 127; }; "
                    + "printf 'GHOSTHUB_TMUX_AVAILABLE\\n'; "
                    + "\"$ghosthub_tmux_path\" -V >/dev/null || { "
                    + "ghosthub_probe_status=$?; "
                    + "printf '\(protocolEnd)\\n'; "
                    + "exit \"$ghosthub_probe_status\"; }; "
                    + "if ( \(kwtPrelude): ); then "
                    + "printf 'GHOSTHUB_KWT_AVAILABLE\\n'; "
                    + "else printf 'GHOSTHUB_KWT_UNAVAILABLE\\n'; fi; "
                    + "printf '\(protocolEnd)\\n'"
        }
        let connection: KwtSSHConnection
        if let hostSSHConnectionProvider {
            do {
                connection = try await hostSSHConnectionProvider(
                    sshHost,
                    resolved.destination
                )
            } catch {
                return .failure(.message(error.localizedDescription))
            }
        } else {
            let session = hostSSHSession(
                for: resolved,
                ownerID: reviewID
            )
            switch await session.pendingRequirement() {
            case .success(.confirmation):
                return Self.pendingSSHProbeSummary(
                    host: host,
                    diagnostic: RemoteHostDiagnostic(
                        code: .sshConnectionFailed,
                        severity: .error,
                        summary: "The SSH host key needs review.",
                        recoverySuggestion:
                        "Review and approve the host identity before reconnecting."
                    )
                )
            case .success(.authentication):
                return Self.pendingSSHProbeSummary(
                    host: host,
                    diagnostic: RemoteHostDiagnostic(
                        code: .sshAuthenticationFailed,
                        severity: .error,
                        summary: "SSH authentication is required.",
                        recoverySuggestion:
                        "Enter the password or verification code requested by OpenSSH."
                    )
                )
            case .success(.none):
                do {
                    connection = try await session.takeConnection()
                    if hostSSHSession === session {
                        hostSSHSession = nil
                        hostSSHSessionDestination = nil
                        hostSSHSessionOwnerID = nil
                        hostSSHSessionSurfaceID = nil
                    }
                } catch {
                    return .failure(.message(error.localizedDescription))
                }
            case let .failure(error):
                return .failure(error)
            }
        }
        let probe = await BlockingTask.run {
            let result = sshHostProbeRunner(
                sshHost,
                connection.arguments,
                probeCommand
            )
            let protocolLines = Self.sshProbeProtocolLines(
                result.stdout,
                start: protocolStart,
                end: protocolEnd
            ) ?? []
            let sshReached = protocolLines.contains("GHOSTHUB_SSH_REACHED")
            let tmuxAvailable = protocolLines.contains(
                "GHOSTHUB_TMUX_AVAILABLE"
            )
            let kwtAvailable = protocolLines.contains(
                "GHOSTHUB_KWT_AVAILABLE"
            )
            let diagnostics: [RemoteHostDiagnostic]
            if !sshReached {
                diagnostics = [SSHConnectionFailure.diagnostic(
                    status: result.status,
                    output: result.stderr
                )]
            } else if !tmuxAvailable {
                diagnostics = [RemoteHostDiagnostic(
                    code: .missingTmux,
                    severity: .error,
                    summary: host.platform == .windows
                        ? "psmux is not available."
                        : "tmux is not available.",
                    recoverySuggestion: host.platform == .windows
                        ? "Install psmux and ensure its tmux.exe alias is on "
                        + "PATH for this SSH account, then test again."
                        : "Install tmux on this host, then test again."
                )]
            } else if result.status != 0 {
                diagnostics = [RemoteHostDiagnostic(
                    code: .probeFailure,
                    severity: .error,
                    summary: host.platform == .windows
                        ? "psmux did not respond successfully."
                        : "tmux did not respond successfully.",
                    recoverySuggestion:
                    "Run the tmux version command on the host and resolve "
                        + "the reported error, then test again."
                )]
            } else if !kwtAvailable, host.platform == .windows {
                diagnostics = [.missingKwtCapability]
            } else {
                diagnostics = []
            }
            let summary: Result<HostProbeSummary, HostProbeError> =
                .success(HostProbeSummary(
                    host: HostSummary(
                        id: UUID(),
                        configKey: host.configKey,
                        name: host.name,
                        kind: .remote,
                        platform: host.platform,
                        sshDestination: host.sshDestination,
                        preferredTransport: .ssh,
                        lastKnownReachable: sshReached,
                        lastSeenAt: sshReached ? Date() : nil,
                        remoteDiagnostics: diagnostics,
                        decodedConnectionState: !sshReached
                            ? .offline
                            : result.status == 0 ? .online : .degraded
                    )
                ))
            return (summary, result)
        }
        if SSHConnectionFailure.indicatesUnusableConnection(
            status: probe.1.status,
            output: probe.1.stderr
        ) {
            await connection.invalidate()
        }
        do {
            try await connection.release()
        } catch {
            return .failure(.message(
                "Ghosthub could not release the SSH connection: "
                    + error.localizedDescription
            ))
        }
        return probe.0
    }

    private nonisolated static func pendingSSHProbeSummary(
        host: SSHHost,
        diagnostic: RemoteHostDiagnostic
    ) -> Result<HostProbeSummary, HostProbeError> {
        .success(HostProbeSummary(host: HostSummary(
            id: UUID(),
            configKey: host.configKey,
            name: host.name,
            kind: .remote,
            platform: host.platform,
            sshDestination: host.sshDestination,
            preferredTransport: .ssh,
            lastKnownReachable: false,
            lastSeenAt: nil,
            remoteDiagnostics: [diagnostic],
            decodedConnectionState: .offline
        )))
    }

    nonisolated static func sshProbeProtocolLines(
        _ output: String,
        start: String,
        end: String
    ) -> Set<String>? {
        let lines = output.split(
            separator: "\n",
            omittingEmptySubsequences: false
        ).map { String($0).trimmingCharacters(in: .newlines) }
        guard let startIndex = lines.firstIndex(of: start),
              let endIndex = lines[lines.index(after: startIndex)...]
              .firstIndex(of: end)
        else { return nil }
        return Set(lines[lines.index(after: startIndex) ..< endIndex])
    }

    func installRemoteKwt(
        on host: SSHHost
    ) async -> Result<Void, HostProbeError> {
        do {
            let hostID = snapshot.hosts.first {
                $0.configKey == host.configKey
            }?.id
            try await kwtRemoteInstaller(host)
            if let hostID {
                kwtAvailabilityByHost[hostID] = true
                kwtInventoryFailuresByHost.removeValue(forKey: hostID)
                applyInventoryOverlayIfNeeded()
                updateWorkspaceInventoryState()
            }
            refreshHosts()
            refreshKwtInventory()
            return .success(())
        } catch {
            return .failure(.message(error.localizedDescription))
        }
    }

    func installWindowsKwt(
        on host: SSHHost
    ) async -> Result<Void, HostProbeError> {
        switch await KwtWindowsInstaller().install(on: host) {
        case .success:
            refreshHosts()
            refreshKwtInventory()
            return .success(())
        case let .failure(error):
            return .failure(.message(error.localizedDescription))
        }
    }

    func registerRemoteProject(
        _ projectPath: String,
        on host: SSHHost
    ) async -> Result<String, HostProbeError> {
        let destination = host.sshDestination.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        guard let sshHost = CommandHostResolver.parseSSHDestination(
            destination
        ) else {
            return .failure(.message("Enter a valid SSH destination."))
        }
        let target = CommandHost.ssh(SSHHostInfo(
            user: sshHost.user,
            hostname: sshHost.hostname,
            port: sshHost.port,
            platform: host.platform == .windows ? .windows : .posix
        ))
        var provisioningHost = host
        provisioningHost.sshDestination = destination
        let hostID = snapshot.hosts.first {
            $0.configKey == host.configKey
        }?.id
        return await performProjectRegistration(
            projectPath,
            on: target,
            provisioningHost: provisioningHost,
            hostID: hostID,
            revalidatingHostID: hostID
        )
    }

    func registerProject(
        _ projectPath: String,
        on host: HostSummary
    ) async -> Result<String, HostProbeError> {
        guard let capturedTarget = CommandHostResolver.resolve(host) else {
            return .failure(.message("Enter a valid SSH destination."))
        }
        guard let currentHost = snapshot.host(id: host.id),
              let currentTarget = CommandHostResolver.resolve(currentHost),
              currentTarget == capturedTarget
        else {
            return .failure(.message(
                "The host connection changed. Close Add Project and try again."
            ))
        }
        return await performProjectRegistration(
            projectPath,
            on: currentTarget,
            provisioningHost: configuredSSHHost(for: host.id),
            hostID: host.kind == .remote ? host.id : nil,
            revalidatingHostID: host.id
        )
    }

    private func noteProjectRegistration(
        _ project: KwtProjectRecord,
        on target: CommandHost
    ) {
        for hostID in inventoryHosts.filter({ $0.value == target }).keys {
            worktreeMutationCoordinator.noteProjectRegistration(
                hostID: hostID,
                projectIdentity: project.repository,
                projectPath: project.path
            )
        }
    }

    private func performProjectRegistration(
        _ projectPath: String,
        on target: CommandHost,
        provisioningHost: SSHHost?,
        hostID: UUID?,
        revalidatingHostID: UUID?
    ) async -> Result<String, HostProbeError> {
        let registryHost = projectRegistryHost(for: target)
        guard worktreeMutationCoordinator.acquireProjectRegistry(
            host: registryHost
        ) else {
            return .failure(.message(
                "Another project or worktree change is already in progress."
            ))
        }
        defer {
            worktreeMutationCoordinator.releaseProjectRegistry(
                host: registryHost
            )
        }
        do {
            if let provisioningHost {
                try await ensureRemoteKwtForOperation(
                    on: provisioningHost,
                    hostID: hostID
                )
            }
            if let revalidatingHostID {
                guard let currentHost = snapshot.host(
                    id: revalidatingHostID
                ),
                    CommandHostResolver.resolve(currentHost) == target
                else {
                    return .failure(.message(
                        "The host connection changed. "
                            + "Close Add Project and try again."
                    ))
                }
            }
            let project = try await kwtProjectRegistration(
                projectPath,
                target
            )
            noteProjectRegistration(project, on: target)
            refreshKwtInventory()
            return .success(project.name)
        } catch {
            if let hostID {
                recordKwtUnavailability(error, hostID: hostID)
            }
            return .failure(.message(error.localizedDescription))
        }
    }

    func prepareProjectRemoval(
        _ project: ProjectSummary,
        confirmedHost: HostSummary
    ) async throws -> ProjectRemovalRequest {
        guard let capturedTarget = CommandHostResolver.resolve(confirmedHost),
              let current = validatedProjectRemovalTarget(
                  project,
                  confirmedHostID: confirmedHost.id,
                  capturedTarget: capturedTarget
              ),
              current.project.registrationFingerprint
              == project.registrationFingerprint
        else {
            throw projectRemovalTargetChangedError
        }
        let routeIdentity: String?
        switch current.host {
        case .local:
            routeIdentity = nil
        case let .ssh(info):
            routeIdentity = try await sshRouteIdentityResolver(info)
        }
        guard validatedProjectRemovalTarget(
            current.project,
            confirmedHostID: confirmedHost.id,
            capturedTarget: capturedTarget
        ) != nil else {
            throw projectRemovalTargetChangedError
        }
        return ProjectRemovalRequest(
            project: project,
            confirmedHost: confirmedHost,
            routeIdentity: routeIdentity
        )
    }

    func unregisterProject(
        _ project: ProjectSummary,
        confirmedHost: HostSummary
    ) async -> Result<String, HostProbeError> {
        do {
            guard let host = CommandHostResolver.resolve(confirmedHost)
            else { throw projectRemovalTargetChangedError }
            let routeIdentity: String?
            switch host {
            case .local:
                routeIdentity = nil
            case let .ssh(info):
                routeIdentity = try await sshRouteIdentityResolver(info)
            }
            let request = ProjectRemovalRequest(
                project: project,
                confirmedHost: confirmedHost,
                routeIdentity: routeIdentity
            )
            return await unregisterProject(request)
        } catch {
            return .failure(.message(error.localizedDescription))
        }
    }

    func unregisterProject(
        _ request: ProjectRemovalRequest
    ) async -> Result<String, HostProbeError> {
        let project = request.project
        let confirmedHost = request.confirmedHost
        guard let capturedTarget = CommandHostResolver.resolve(confirmedHost)
        else {
            return .failure(.message("Enter a valid SSH destination."))
        }
        guard let initial = validatedProjectRemovalTarget(
            project,
            confirmedHostID: confirmedHost.id,
            capturedTarget: capturedTarget
        )
        else {
            return .failure(projectRemovalTargetChangedError)
        }
        guard !project.registrationFingerprint.isEmpty else {
            refreshKwtInventory()
            return .failure(.message(
                "Refresh projects and confirm removal again."
            ))
        }
        let authorizedPath = project.rootPath
        let authorizedRepository = project.scopedKey
        let authorizedRegistration = project.registrationFingerprint
        guard !ownsWorktreeMutation else {
            return .failure(.message(
                "Another project or worktree change is already in progress."
            ))
        }
        ownsWorktreeMutation = true
        guard worktreeMutationCoordinator.acquireProjectRemoval(
            hostID: initial.project.hostID,
            projectIdentity: initial.project.scopedKey,
            registryHost: projectRegistryHost(for: capturedTarget)
        ) else {
            ownsWorktreeMutation = false
            return .failure(.message(
                "Another project or worktree change is already in progress."
            ))
        }
        invalidateKwtInventoryRefresh()
        let mutation = kwtMutationPublication(hostID: initial.project.hostID)
        var removalTombstones:
            Set<WorktreeMutationCoordinator.RemovalTombstone> = []
        var removesProject = false
        var allowsRemovalRestoration = true
        var reconciledRestorationTargets:
            Set<WorkspaceTmuxSessionSelection>?
        var quarantinesProjectRemoval = false
        let retainedProjectWorktrees = snapshot.worktrees.filter {
            $0.hostID == initial.project.hostID
                && $0.projectID == initial.project.id
        }
        defer {
            ownsWorktreeMutation = false
            if !quarantinesProjectRemoval {
                worktreeMutationCoordinator.release(
                    hostID: initial.project.hostID,
                    projectIdentity: initial.project.scopedKey,
                    removalTombstones: removalTombstones,
                    reconciledRestorationTargets:
                    reconciledRestorationTargets,
                    removesProject: removesProject,
                    allowsRemovalRestoration: allowsRemovalRestoration,
                    projectPath: initial.project.rootPath
                )
            }
        }

        do {
            try await ensureRemoteKwtForOperation(
                hostID: initial.project.hostID
            )
            guard validatedProjectRemovalTarget(
                project,
                confirmedHostID: confirmedHost.id,
                capturedTarget: capturedTarget
            ) != nil else {
                return .failure(projectRemovalTargetChangedError)
            }
            let refreshed = try await kwtInventoryLoader(initial.host)
            if let warning = refreshed.projectsWarning {
                return .failure(projectRemovalInventoryError(warning))
            }
            guard try await removalRouteIdentityMatches(
                request.routeIdentity,
                on: initial.host
            ) else {
                return .failure(projectRemovalTargetChangedError)
            }
            let refreshedProjectWorktrees = KwtSnapshotMerger.merge(
                refreshed,
                hostID: initial.project.hostID,
                into: snapshot
            ).worktrees.filter {
                $0.hostID == initial.project.hostID
                    && $0.projectID == initial.project.id
            }
            guard let probed = validatedProjectRemovalTarget(
                project,
                confirmedHostID: confirmedHost.id,
                capturedTarget: capturedTarget
            ) else {
                return .failure(projectRemovalTargetChangedError)
            }
            worktreeMutationCoordinator.reconcileRetiredProtectedEndpoints(
                after: refreshed,
                hostID: initial.project.hostID
            )
            if let protectedSessionError = await protectedSessionRemovalError(
                for: probed.project,
                on: probed.host,
                retaining: retainedProjectWorktrees
                    + refreshedProjectWorktrees
            ) {
                return .failure(protectedSessionError)
            }
            guard validatedProjectRemovalTarget(
                project,
                confirmedHostID: confirmedHost.id,
                capturedTarget: capturedTarget
            ) != nil else {
                return .failure(projectRemovalTargetChangedError)
            }
            applyAuthoritativeKwtInventory(
                refreshed,
                hostID: initial.project.hostID,
                publishToStore: false
            )
            guard let removal = validatedProjectRemovalTarget(
                project,
                confirmedHostID: confirmedHost.id,
                capturedTarget: capturedTarget
            ) else {
                return .failure(projectRemovalTargetChangedError)
            }
            let projectWorktrees = snapshot.worktrees.filter {
                $0.hostID == removal.project.hostID
                    && $0.projectID == removal.project.id
            }
            let preparedTombstones = Set(projectWorktrees.map { worktree in
                WorktreeMutationCoordinator.RemovalTombstone(
                    path: worktree.path,
                    generation: worktree.generation ?? ""
                )
            })
            worktreeMutationCoordinator.prepareRemoval(
                hostID: removal.project.hostID,
                projectIdentity: removal.project.scopedKey,
                worktrees: preparedTombstones,
                presentationTargets: Set(projectWorktrees.compactMap {
                    WorkspaceSidebarModel.tmuxSessionSelection(for: $0)
                })
            )
            do {
                let removed = try await kwtProjectRemoval(
                    authorizedPath,
                    authorizedRepository,
                    authorizedRegistration,
                    request.routeIdentity,
                    removal.host
                )
                guard validatedProjectRemovalTarget(
                    project,
                    confirmedHostID: confirmedHost.id,
                    capturedTarget: capturedTarget
                ) != nil else {
                    allowsRemovalRestoration = false
                    quarantinesProjectRemoval =
                        quarantineProjectRemovalIfHostIsResolvable(
                            removal.project,
                            on: removal.host
                        )
                    return .failure(projectRemovalTargetChangedError)
                }
                removalTombstones = preparedTombstones
                removesProject = true
                return .success(removed.name)
            } catch {
                let removalError = error
                recordKwtUnavailability(
                    removalError,
                    hostID: removal.project.hostID
                )
                if case let .commandFailed(
                    _, _, code, _, _, _
                ) = removalError as? KwtProjectCommandError,
                    [
                        "registration_changed",
                        "protected_session_live",
                        "protected_endpoint_inventory_incomplete",
                    ].contains(code) {
                    guard validatedProjectRemovalTarget(
                        project,
                        confirmedHostID: confirmedHost.id,
                        capturedTarget: capturedTarget
                    ) != nil else {
                        allowsRemovalRestoration = false
                        return .failure(projectRemovalTargetChangedError)
                    }
                    reconciledRestorationTargets = projectRestorationTargets(
                        hostID: removal.project.hostID,
                        projectIdentity: removal.project.scopedKey
                    )
                    return .failure(.message(
                        removalError.localizedDescription
                    ))
                }
                let reconciliation = await reconcileFailedProjectRemoval(
                    removal.project,
                    on: removal.host,
                    expectedRouteIdentity: request.routeIdentity,
                    mutation: mutation
                )
                guard snapshot.host(id: confirmedHost.id)
                    .flatMap(CommandHostResolver.resolve) == capturedTarget
                else {
                    allowsRemovalRestoration = false
                    quarantinesProjectRemoval =
                        quarantineProjectRemovalIfHostIsResolvable(
                            removal.project,
                            on: removal.host
                        )
                    return .failure(projectRemovalTargetChangedError)
                }
                switch reconciliation {
                case .removed:
                    removalTombstones = preparedTombstones
                    removesProject = true
                    return .success(removal.project.name)
                case let .present(restorationTargets):
                    reconciledRestorationTargets = restorationTargets
                    return .failure(.message(
                        removalError.localizedDescription
                    ))
                case .unverified:
                    allowsRemovalRestoration = false
                    quarantinesProjectRemoval = true
                    worktreeMutationCoordinator.quarantineProjectRemoval(
                        hostID: removal.project.hostID,
                        projectIdentity: removal.project.scopedKey,
                        projectPath: removal.project.rootPath,
                        host: removal.host
                    )
                    return .failure(.message(
                        removalError.localizedDescription
                    ))
                }
            }
        } catch {
            recordKwtUnavailability(
                error,
                hostID: initial.project.hostID
            )
            return .failure(.message(error.localizedDescription))
        }
    }

    private func quarantineProjectRemovalIfHostIsResolvable(
        _ project: ProjectSummary,
        on host: CommandHost
    ) -> Bool {
        guard snapshot.host(id: project.hostID)
            .flatMap(CommandHostResolver.resolve) == host
        else { return false }
        worktreeMutationCoordinator.quarantineProjectRemoval(
            hostID: project.hostID,
            projectIdentity: project.scopedKey,
            projectPath: project.rootPath,
            host: host
        )
        return true
    }

    private func projectRegistryHost(
        for host: CommandHost
    ) -> WorktreeMutationCoordinator.ProjectRegistryHost {
        let target = switch host {
        case .local:
            CommandHost.local
        case let .ssh(info):
            CommandHost.ssh(SSHHostInfo(
                user: info.user,
                hostname: info.hostname.lowercased(),
                port: info.port ?? 22,
                platform: info.platform
            ))
        }
        return WorktreeMutationCoordinator.ProjectRegistryHost(
            target: target
        )
    }

    private enum FailedProjectRemovalReconciliation {
        case removed
        case present(Set<WorkspaceTmuxSessionSelection>)
        case unverified
    }

    private func reconcileFailedProjectRemoval(
        _ project: ProjectSummary,
        on host: CommandHost,
        expectedRouteIdentity: String?,
        mutation: WorkspaceInventoryStore.MutationPublication?
    ) async -> FailedProjectRemovalReconciliation {
        do {
            let inventory = try await removalReconciliationInventory(
                on: host,
                expectedRouteIdentity: expectedRouteIdentity
            )
            guard validatedProjectRemovalTarget(
                project,
                confirmedHostID: project.hostID,
                capturedTarget: host
            ) != nil else {
                return .unverified
            }
            guard inventory.projectsWarning == nil else {
                return .unverified
            }
            if let repositoryItem = inventory.projects.first(where: {
                $0.project.repository == project.scopedKey
            }) {
                guard repositoryItem.warning == nil else {
                    return .unverified
                }
                applyAuthoritativeKwtInventory(
                    inventory,
                    hostID: project.hostID,
                    mutation: mutation
                )
                guard normalizedWorkspacePath(repositoryItem.project.path)
                    == normalizedWorkspacePath(project.rootPath)
                else { return .unverified }
                return .present(projectRestorationTargets(
                    hostID: project.hostID,
                    projectIdentity: project.scopedKey
                ))
            }
            if inventory.projects.contains(where: {
                normalizedWorkspacePath($0.project.path)
                    == normalizedWorkspacePath(project.rootPath)
            }) {
                applyAuthoritativeKwtInventory(
                    inventory,
                    hostID: project.hostID,
                    mutation: mutation
                )
                return .unverified
            }
            applyAuthoritativeKwtInventory(
                inventory,
                hostID: project.hostID,
                mutation: mutation
            )
            return .removed
        } catch {
            recordKwtUnavailability(error, hostID: project.hostID)
            return .unverified
        }
    }

    private func removalReconciliationInventory(
        on host: CommandHost,
        expectedRouteIdentity: String?
    ) async throws -> KwtHostInventory {
        try await kwtConditionalInventoryLoader(
            host,
            expectedRouteIdentity
        )
    }

    private var projectRemovalTargetChangedError: HostProbeError {
        .message(
            "The project or host connection changed. Try removing it again."
        )
    }

    private func validatedProjectOperationTarget(
        _ capturedProject: ProjectSummary,
        capturedHost: CommandHost
    ) -> (project: ProjectSummary, host: CommandHost)? {
        guard let currentProject = snapshot.project(id: capturedProject.id),
              currentProject.hostID == capturedProject.hostID,
              currentProject.scopedKey == capturedProject.scopedKey,
              currentProject.registryID == capturedProject.registryID,
              currentProject.rootPath == capturedProject.rootPath,
              currentProject.registrationFingerprint
              == capturedProject.registrationFingerprint,
              let currentHost = snapshot.host(id: capturedProject.hostID),
              let currentTarget = CommandHostResolver.resolve(currentHost),
              currentTarget == capturedHost
        else { return nil }
        return (currentProject, currentTarget)
    }

    private func projectRemovalInventoryError(
        _ message: String
    ) -> HostProbeError {
        .message(
            "Ghosthub could not verify the project's worktrees. " + message
        )
    }

    private func validatedProjectRemovalTarget(
        _ confirmedProject: ProjectSummary,
        confirmedHostID: UUID,
        capturedTarget: CommandHost
    ) -> (project: ProjectSummary, host: CommandHost)? {
        guard let currentProject = snapshot.project(id: confirmedProject.id),
              let currentHost = snapshot.host(id: confirmedProject.hostID)
        else { return nil }
        return Self.validatedProjectRemovalTarget(
            confirmedProject,
            confirmedHostID: confirmedHostID,
            capturedTarget: capturedTarget,
            currentProject: currentProject,
            currentHost: currentHost
        )
    }

    static func validatedProjectRemovalTarget(
        _ confirmedProject: ProjectSummary,
        confirmedHostID: UUID,
        capturedTarget: CommandHost,
        currentProject: ProjectSummary,
        currentHost: HostSummary
    ) -> (project: ProjectSummary, host: CommandHost)? {
        guard confirmedHostID == confirmedProject.hostID,
              currentProject.id == confirmedProject.id,
              currentProject.hostID == confirmedProject.hostID,
              currentProject.scopedKey == confirmedProject.scopedKey,
              currentProject.rootPath == confirmedProject.rootPath,
              currentHost.id == confirmedHostID,
              let currentTarget = CommandHostResolver.resolve(currentHost),
              currentTarget == capturedTarget
        else { return nil }
        return (currentProject, currentTarget)
    }

    private func protectedSessionRemovalError(
        for project: ProjectSummary,
        on host: CommandHost,
        retaining cachedWorktrees: [WorktreeSummary] = []
    ) async -> HostProbeError? {
        let protectedWorktrees = (snapshot.worktrees + cachedWorktrees).filter {
            $0.projectID == project.id
                && $0.hostID == project.hostID
                && $0.tmuxAttachMode == .protected
        }
        let localEndpoints = preferredProtectedEndpoints(
            protectedWorktrees.map { worktree in
                WorktreeMutationCoordinator.ProtectedEndpoint(
                    worktreeName: worktree.name,
                    worktreeIdentity: KwtWorktreeIdentity(
                        path: worktree.path,
                        generation: worktree.generation ?? ""
                    ),
                    selection: WorkspaceSidebarModel.tmuxSessionSelection(
                        for: worktree
                    )
                )
            }
        )
        let scope = WorktreeMutationCoordinator.Scope(
            hostID: project.hostID,
            projectIdentity: project.scopedKey
        )
        var probedEndpoints: Set<TmuxPresentationKey> = []
        while true {
            let protectedEndpoints = preferredProtectedEndpoints(
                Array(worktreeMutationCoordinator.protectedEndpoints(
                    in: scope
                )) + Array(localEndpoints)
            )
            if let unresolved = protectedEndpoints.first(where: {
                $0.selection == nil
            }) {
                return .message(
                    "Ghosthub could not verify a protected tmux session for "
                        + "worktree “\(unresolved.worktreeName)”. "
                        + "Refresh the host and "
                        + "try again."
                )
            }
            guard let selection = protectedEndpoints.lazy
                .compactMap(\.selection)
                .first(where: {
                    !probedEndpoints.contains(TmuxPresentationKey($0))
                })
            else { return nil }
            probedEndpoints.insert(TmuxPresentationKey(selection))
            do {
                _ = try await tmuxSessionIdentityReader(selection, host)
                return .message(
                    "Session “\(selection.name)” is still running on its "
                        + "protected tmux server. Kill it before removing "
                        + "project “\(project.name)”."
                )
            } catch TmuxSessionKillError.sessionNotRunning {
                worktreeMutationCoordinator.confirmProtectedEndpointAbsent(
                    selection,
                    in: scope
                )
                continue
            } catch {
                return .message(
                    "Ghosthub could not verify protected session "
                        + "“\(selection.name)”. \(error.localizedDescription)"
                )
            }
        }
    }

    private func preferredProtectedEndpoints(
        _ endpoints: [WorktreeMutationCoordinator.ProtectedEndpoint]
    ) -> Set<WorktreeMutationCoordinator.ProtectedEndpoint> {
        var resolved: [
            TmuxPresentationKey:
                WorktreeMutationCoordinator.ProtectedEndpoint
        ] = [:]
        var unresolved: [
            KwtWorktreeIdentity:
                WorktreeMutationCoordinator.ProtectedEndpoint
        ] = [:]
        for endpoint in endpoints {
            if let selection = endpoint.selection {
                resolved[TmuxPresentationKey(selection)] = endpoint
            } else if unresolved[endpoint.worktreeIdentity] == nil {
                unresolved[endpoint.worktreeIdentity] = endpoint
            }
        }
        let resolvedIdentities = Set(resolved.values.map(\.worktreeIdentity))
        return Set(resolved.values).union(unresolved.values.filter {
            !resolvedIdentities.contains($0.worktreeIdentity)
        })
    }

    private func fetchEnrichedSnapshot(
    ) throws -> WorkspaceSnapshot {
        guard !hasOverrideSnapshot else { return snapshot }
        var enriched = snapshot
        enriched.sessions = try database.fetchSessionSnapshot().sessions
        enriched = applyingConfiguredSSHHosts(
            configuredSSHHostsProvider(),
            exeHosts: configuredExeHostsProvider(),
            to: enriched
        )

        struct PresentationKey: Hashable {
            let hostConfigKey: String
            let worktreeScopedKey: String
        }

        let presentationRecords = try database.presentationState.fetchAll()
        let presentationByKey = Dictionary(
            uniqueKeysWithValues: presentationRecords.map { record in
                (
                    PresentationKey(
                        hostConfigKey: record.hostID,
                        worktreeScopedKey: record.scopedKey
                    ),
                    record
                )
            }
        )
        for index in enriched.worktrees.indices {
            let worktree = enriched.worktrees[index]
            guard let host = enriched.host(id: worktree.hostID),
                  let presentation = presentationByKey[
                      PresentationKey(
                          hostConfigKey: host.configKey,
                          worktreeScopedKey: worktree.scopedKey
                      )
                  ]
            else { continue }
            enriched.worktrees[index].lastViewedAt = presentation.lastViewedAt
            enriched.worktrees[index].lastAgentActivity =
                presentation.lastAgentActivity
        }
        return enriched
    }

    var worktreeVisibility: WorktreeVisibility {
        sceneSettings.worktreeVisibility()
    }

    private func syncTerminalConfig() {
        guard isFocusedWindow else { return }
        terminalRuntime.reloadConfig(
            projectRoot: selection.terminalConfigRoot(
                in: snapshot
            )
        )
    }

    func reloadTerminalConfig() {
        SettingsStore.shared.reloadShortcutConfiguration()
        if let issue = SettingsStore.shared.shortcutConfigurationIssue {
            AppLogger.shared.error(
                "shortcut configuration: \(issue.message)"
            )
        }
        terminalRuntime.reloadConfig(
            projectRoot: selection.terminalConfigRoot(
                in: snapshot
            ),
            force: true,
            notifyOnSuccess: true
        )
    }

    private func makeResourceSamplingCoordinator() -> ResourceSamplingCoordinator {
        ResourceSamplingCoordinator(
            rootsProvider: { [weak self] in
                self?.activityController
                    .processRootsForResourceMonitoring() ?? []
            },
            snapshotHandler: { [weak self] snapshot, roots in
                self?.activityController
                    .applyResourceSnapshot(snapshot, roots: roots)
            }
        )
    }

    private func startResourceMonitoringLoop() {
        activityController.startResourceMonitoringLoop()
    }

    func setSidePanelVisible(_ isVisible: Bool) {
        panelRoutingService.setSidePanelVisible(isVisible)
    }

    func borrowedTmuxSessionView(
        host: HostSummary,
        sessionName: String,
        defersTerminalResize: Bool,
        onReconnectNow: @escaping () -> Void = {},
        onReviewConnection: @escaping () -> Void = {}
    ) -> AnyView? {
        guard CommandHostResolver.resolve(host) != nil else {
            return AnyView(
                ContentUnavailableView(
                    "SSH unavailable",
                    systemImage: "network.slash",
                    description: Text(
                        "Add an SSH address for \(host.name) in Hosts settings."
                    )
                )
            )
        }
        guard let selection = activeBorrowedTmuxSelection,
              selection.hostID == host.id,
              selection.name == sessionName,
              let handle = activeBorrowedTmuxHandle
        else {
            return nil
        }
        return AnyView(
            BorrowedTmuxSessionView(
                handle: handle,
                hostName: host.name,
                isRemoteHost: host.kind == .remote,
                displayTitle: snapshot.worktrees.first {
                    $0.hostID == host.id
                        && $0.tmuxSessionName == sessionName
                }?.name ?? snapshot.directoryWorkspaces.first {
                    $0.hostID == host.id
                        && $0.tmuxSessionName == sessionName
                }?.name,
                connectionState: borrowedTmuxConnectionStates[handle.id],
                recoveryState: activeBorrowedTmuxRecoveryState,
                attachmentClosure:
                nativeTmuxSessionCoordinator.attachmentClosure(handle),
                sessionClosed:
                confirmedEndedTmuxSessionHandles.contains(handle.id),
                defersTerminalResize: defersTerminalResize,
                retryRequiresConfirmation:
                activeBorrowedTmuxRetryRequiresConfirmation,
                retryCommand: activeBorrowedTmuxRetryCommand,
                surface: { [weak self] in
                    self?.protectedTmuxSurface(handle: handle)
                },
                onCloseRequest: { [weak self] in
                    guard let self else { return }
                    NotificationCenter.default.post(
                        name: .ghosthubCloseTab,
                        object: self
                    )
                },
                onRetryRequest: { [weak self] in
                    self?.retryBorrowedTmuxSession(selection)
                },
                onConfirmedRetryRequest: { [weak self] in
                    self?
                        .retryBorrowedTmuxSessionAfterProfileCommandConfirmation(
                            selection
                        )
                },
                onReconnectNow: onReconnectNow,
                onReviewConnection: onReviewConnection,
                onHostSettingsRequest: { [weak self] in
                    SettingsStore.shared.selectedDomain = .hosts
                    self?.isSettingsPresented = true
                }
            )
        )
    }

    /// Ensures the active ordinary tmux client has been handed to the terminal
    /// runtime. Kept separate from binary resolution so creation reconciliation
    /// cannot race ahead of the command launch.
    func prepareActiveBorrowedTmuxSurface() {
        guard let handle = activeBorrowedTmuxHandle,
              let presentation = retainedTmuxPresentation(for: handle),
              acquireProtectedTmuxAttachmentScopeIfNeeded(
                  for: presentation
              )
        else { return }
        _ = protectedTmuxSurface(handle: handle)
    }

    func openBorrowedTmuxSession(_ selection: WorkspaceTmuxSessionSelection) {
        tmuxSessionPreviewCoordinator.cancelPendingActivation()
        cancelPendingRestoration()
        invalidateZellijPresentationIntent()
        userNavigationRevision &+= 1
        cancelPendingTmuxPreviewActivations()
        if let worktreeID = selection.worktreeID {
            explicitlyDismissedWorktreePresentationIDs.remove(worktreeID)
        }
        if let directoryID = selection.directoryWorkspaceID {
            explicitlyDismissedDirectoryPresentationIDs.remove(directoryID)
        }
        let pendingCreation = pendingCreatedTmuxSessions.values.first {
            Self.sameTmuxSession($0.selection, selection)
        }
        if pendingCreation?.initialCommand != nil,
           pendingCreation?.commandReplayAuthorized != true {
            presentTmuxSession(selection, launchMode: .attachOnly)
            return
        }
        presentTmuxSession(
            selection,
            launchMode: selection.socketName == nil && pendingCreation != nil
                ? .create
                : .attach,
            initialCommand: pendingCreation?.initialCommand,
            commandReplayAuthorized:
            pendingCreation?.commandReplayAuthorized == true
        )
    }

    private func sessionPreviewModeDidChange(_ mode: SessionPreviewMode) {
        let wasAlwaysLive = tmuxSessionPreviewCoordinator.mode == .alwaysLive
        tmuxSessionPreviewCoordinator.setMode(mode)
        if mode == .alwaysLive {
            reconcileAlwaysLiveTmuxPresentations()
        } else if wasAlwaysLive {
            closeAlwaysLiveManagedTmuxPresentations()
        }
    }

    private func reconcileAlwaysLiveTmuxPresentations(hostID: UUID? = nil) {
        guard tmuxSessionPreviewCoordinator.mode == .alwaysLive else { return }

        let targetHostIDs = hostID.map { Set([$0]) } ?? tmuxFreshHostIDs
        for targetHostID in targetHostIDs
            where tmuxFreshHostIDs.contains(targetHostID) {
            reconcileAlwaysLiveTmuxPresentations(for: targetHostID)
        }

        guard hostID == nil else { return }
        let removedHostSelections = alwaysLiveManagedTmuxPresentationKeys
            .filter { !inventoryHosts.keys.contains($0.hostID) }
            .compactMap { retainedTmuxPresentations[$0]?.selection }
        for selection in removedHostSelections {
            invalidateBorrowedTmuxSession(selection)
        }
    }

    private func invalidateAlwaysLiveTmuxPresentations(
        for hostIDs: Set<UUID>
    ) {
        guard !hostIDs.isEmpty else { return }
        for key in alwaysLiveIneligibleTmuxPresentationIdentities.keys
            where hostIDs.contains(key.hostID) {
            tmuxSessionPreviewCoordinator.remove(
                key.previewKey,
                reason: .replacement
            )
        }
        alwaysLiveIneligibleTmuxPresentationIdentities =
            alwaysLiveIneligibleTmuxPresentationIdentities.filter {
                !hostIDs.contains($0.key.hostID)
            }
        let selections = alwaysLiveManagedTmuxPresentationKeys
            .filter { hostIDs.contains($0.hostID) }
            .compactMap { retainedTmuxPresentations[$0]?.selection }
        for selection in selections {
            invalidateBorrowedTmuxSession(selection)
        }
    }

    private func reconcileAlwaysLiveTmuxPresentations(for hostID: UUID) {
        let supportsNonSizingClients = snapshot.host(id: hostID).map {
            $0.platform != .windows
        } ?? false
        let sessions = (supportsNonSizingClients
            ? tmuxSessionsByHost[hostID]?.filter {
                $0.previewClientSize != nil && $0.hasStableIdentity
            } ?? []
            : []).sorted {
            $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
        let selections = sessions.map {
            alwaysLiveTmuxSelection(hostID: hostID, name: $0.name)
        }
        let desiredKeys = Set(selections.map(TmuxPresentationKey.init))
        let desiredIdentities = Dictionary(uniqueKeysWithValues:
            zip(sessions, selections).compactMap { session, selection in
                Self.tmuxSessionIdentity(session).map {
                    (TmuxPresentationKey(selection), $0)
                }
            })
        for key in alwaysLiveIneligibleTmuxPresentationIdentities.keys
            where key.hostID == hostID && !desiredKeys.contains(key) {
            tmuxSessionPreviewCoordinator.remove(
                key.previewKey,
                reason: .replacement
            )
        }
        alwaysLiveIneligibleTmuxPresentationIdentities =
            alwaysLiveIneligibleTmuxPresentationIdentities.filter {
                $0.key.hostID != hostID
                    || desiredIdentities[$0.key] == $0.value
            }
        let obsoleteSelections = alwaysLiveManagedTmuxPresentationKeys
            .filter { $0.hostID == hostID && !desiredKeys.contains($0) }
            .compactMap { retainedTmuxPresentations[$0]?.selection }
        for selection in obsoleteSelections {
            invalidateBorrowedTmuxSession(selection)
        }

        for (session, selection) in zip(sessions, selections) {
            let key = TmuxPresentationKey(selection)
            guard let discoveredIdentity = desiredIdentities[key],
                  alwaysLiveIneligibleTmuxPresentationIdentities[key]
                  != discoveredIdentity
            else { continue }
            if let retained = retainedTmuxPresentations[key],
               !nativeTmuxSessionCoordinator.hasClosedAttachment(
                   retained.handle
               ),
               let attachedIdentity = retained.expectedPreviewIdentity,
               attachedIdentity != discoveredIdentity {
                invalidateBorrowedTmuxSession(retained.selection)
            }
            let wasRetained = retainedTmuxPresentations[key] != nil
            guard let handle = presentTmuxSession(
                selection,
                launchMode: .attachOnly,
                intent: .restoreOnly,
                activatesPresentation: false,
                ignoresClientSize: true,
                previewGridSize: session.previewClientSize
            ) else { continue }
            if !wasRetained {
                alwaysLiveManagedTmuxPresentationKeys.insert(key)
            }
            if alwaysLiveManagedTmuxPresentationKeys.contains(key) {
                nativeTmuxSessionCoordinator.updatePreviewGridSize(
                    session.previewClientSize,
                    for: handle
                )
            }
            guard canAttachToDisplay,
                  let presentation = retainedTmuxPresentation(for: handle)
            else { continue }
            if nativeTmuxSessionCoordinator.hasClosedAttachment(handle) {
                guard activeBorrowedTmuxHandle != handle,
                      let host = snapshot.host(id: selection.hostID),
                      let discoveredIdentity = Self
                      .discoveredTmuxSessionIdentity(
                          selection,
                          hostSummary: host
                      ),
                      discoveredIdentity
                      != presentation.reconnectExpectedIdentity
                      || nativeTmuxSessionCoordinator
                      .attachmentClosure(handle) == .surfaceUnavailable
                else { continue }
                // A closed hidden client stays closed for the same server-side
                // session. This respects an explicit detach and prevents a
                // persistent attach failure from becoming a spawn loop. A
                // same-name session with a new stable identity gets one fresh
                // attachment attempt, and a retryable surface failure (no
                // display during creation) relaunches display-gated, one
                // attempt per inventory pass.
                presentation.reconnectExpectedIdentity = discoveredIdentity
                relaunchTmuxSession(
                    presentation,
                    launchMode: .attachOnly,
                    intent: .restoreOnly
                )
            } else if !nativeTmuxSessionCoordinator.hasLaunched(handle) {
                // A pending promotion owns this handle's sizing transition.
                // Launching now could attach a hidden client between the
                // interactive-sizing commit and the preview restore, letting
                // it resize the shared tmux session. The promotion re-drives
                // readiness when it settles.
                guard !presentation.previewPromotionIsPending else { continue }
                enqueueAlwaysLiveTmuxSurface(handle)
            } else {
                _ = protectedTmuxSurface(handle: handle)
            }
        }
    }

    private func alwaysLiveTmuxSelection(
        hostID: UUID,
        name: String
    ) -> WorkspaceTmuxSessionSelection {
        if let worktree = snapshot.worktrees.first(where: {
            $0.hostID == hostID
                && !$0.isStale
                && $0.tmuxSocketName == nil
                && $0.tmuxSessionName == name
        }),
            let selection = WorkspaceSidebarModel.tmuxSessionSelection(
                for: worktree
            ) {
            return selection
        }
        if let workspace = snapshot.directoryWorkspaces.first(where: {
            $0.hostID == hostID && $0.tmuxSessionName == name
        }) {
            return WorkspaceSidebarModel.tmuxSessionSelection(for: workspace)
        }
        return WorkspaceTmuxSessionSelection(hostID: hostID, name: name)
    }

    private func closeAlwaysLiveManagedTmuxPresentations() {
        alwaysLiveTmuxSurfaceLaunchTask?.cancel()
        alwaysLiveTmuxSurfaceLaunchTask = nil
        alwaysLiveTmuxSurfaceLaunchID = nil
        pendingAlwaysLiveTmuxSurfaceHandles.removeAll()
        pendingAlwaysLiveTmuxSurfaceHandleIDs.removeAll()
        var pendingPromotionKeys: Set<TmuxPresentationKey> = []
        let selections: [WorkspaceTmuxSessionSelection] =
            alwaysLiveManagedTmuxPresentationKeys.compactMap {
                guard let presentation = retainedTmuxPresentations[$0] else {
                    return nil
                }
                if presentation.handle == activeBorrowedTmuxHandle
                    || presentation.previewPromotionIsPending {
                    if presentation.previewPromotionIsPending {
                        pendingPromotionKeys.insert($0)
                    }
                    return nil
                }
                return presentation.selection
            }
        for selection in selections {
            tmuxSessionPreviewCoordinator.setExpanded(
                false,
                for: TmuxPresentationKey(selection).previewKey
            )
            invalidateBorrowedTmuxSession(selection)
        }
        alwaysLiveManagedTmuxPresentationKeys = pendingPromotionKeys
        alwaysLiveIneligibleTmuxPresentationIdentities.removeAll()
    }

    func borrowedHerdrSessionView(
        host: HostSummary,
        sessionName: String,
        defersTerminalResize: Bool,
        onReconnectNow: @escaping () -> Void = {},
        onReviewConnection: @escaping () -> Void = {}
    ) -> AnyView? {
        guard CommandHostResolver.resolve(host) != nil else {
            return AnyView(
                ContentUnavailableView(
                    "SSH unavailable",
                    systemImage: "network.slash",
                    description: Text(
                        "Add an SSH address for \(host.name) in Hosts settings."
                    )
                )
            )
        }
        guard let selection = activeBorrowedHerdrSelection,
              selection.hostID == host.id,
              selection.name == sessionName,
              let handle = activeBorrowedHerdrHandle
        else { return nil }
        return AnyView(
            BorrowedHerdrSessionView(
                handle: handle,
                hostName: host.name,
                isRemoteHost: host.kind == .remote,
                connectionState: borrowedHerdrConnectionStates[handle.id],
                recoveryState: activeBorrowedHerdrRecoveryState,
                attachmentClosure:
                nativeHerdrSessionCoordinator.attachmentClosure(handle),
                defersTerminalResize: defersTerminalResize,
                surface: { [weak self] in
                    self?.nativeHerdrSessionCoordinator.surface(handle: handle)
                },
                onCloseRequest: { [weak self] in
                    guard let self else { return }
                    NotificationCenter.default.post(
                        name: .ghosthubCloseTab,
                        object: self
                    )
                },
                onRetryRequest: { [weak self] in
                    Task { @MainActor [weak self] in
                        await self?.retryBorrowedHerdrSession(selection)
                    }
                },
                onReconnectNow: onReconnectNow,
                onReviewConnection: onReviewConnection,
                onHostSettingsRequest: { [weak self] in
                    SettingsStore.shared.selectedDomain = .hosts
                    self?.isSettingsPresented = true
                }
            )
        )
    }

    func prepareActiveBorrowedHerdrSurface() {
        guard !isShutDown else { return }
        guard let handle = activeBorrowedHerdrHandle else { return }
        _ = nativeHerdrSessionCoordinator.surface(handle: handle)
    }

    func borrowedZellijSessionView(
        host: HostSummary,
        sessionName: String,
        defersTerminalResize: Bool,
        onReconnectNow: @escaping () -> Void = {},
        onReviewConnection: @escaping () -> Void = {}
    ) -> AnyView? {
        guard CommandHostResolver.resolve(host) != nil else {
            return AnyView(
                ContentUnavailableView(
                    "SSH unavailable",
                    systemImage: "network.slash",
                    description: Text(
                        "Add an SSH address for \(host.name) in Hosts settings."
                    )
                )
            )
        }
        guard let selection = activeBorrowedZellijSelection,
              selection.hostID == host.id,
              selection.name == sessionName,
              let handle = activeBorrowedZellijHandle
        else { return nil }
        return AnyView(
            BorrowedZellijSessionView(
                handle: handle,
                hostName: host.name,
                isRemoteHost: host.kind == .remote,
                connectionState: borrowedZellijConnectionStates[handle.id],
                recoveryState: activeBorrowedZellijRecoveryState,
                attachmentClosure:
                nativeZellijSessionCoordinator.attachmentClosure(handle),
                defersTerminalResize: defersTerminalResize,
                surface: { [weak self] in
                    self?.nativeZellijSessionCoordinator.surface(handle: handle)
                },
                onCloseRequest: { [weak self] in
                    guard let self else { return }
                    NotificationCenter.default.post(
                        name: .ghosthubCloseTab,
                        object: self
                    )
                },
                onRetryRequest: { [weak self] in
                    self?.retryBorrowedZellijSession(selection)
                },
                onReconnectNow: onReconnectNow,
                onReviewConnection: onReviewConnection,
                onHostSettingsRequest: { [weak self] in
                    SettingsStore.shared.selectedDomain = .hosts
                    self?.isSettingsPresented = true
                }
            )
        )
    }

    func prepareActiveBorrowedZellijSurface() {
        guard !isShutDown else { return }
        guard let handle = activeBorrowedZellijHandle else { return }
        _ = nativeZellijSessionCoordinator.surface(handle: handle)
    }

    func openBorrowedZellijSession(
        _ selection: WorkspaceZellijSessionSelection
    ) {
        guard snapshot.host(id: selection.hostID)?.zellijSessions.contains(
            where: { $0.name == selection.name }
        ) == true else { return }
        if activeBorrowedZellijSelection == selection,
           let handle = activeBorrowedZellijHandle,
           nativeZellijSessionCoordinator.attachmentClosure(handle) == nil {
            return
        }
        cancelPendingRestoration()
        cancelPendingTmuxPreviewActivations()
        validateAndPresentZellijSession(selection)
    }

    func createZellijSession(
        _ selection: WorkspaceZellijSessionSelection
    ) async throws {
        let activityGeneration = try captureSceneActivity()
        let navigationRevision = userNavigationRevision
        guard let host = snapshot.host(id: selection.hostID),
              host.zellijAvailable,
              let resolvedHost = CommandHostResolver.resolve(host),
              Self.supportsZellij(resolvedHost),
              !host.zellijSessions.contains(where: {
                  $0.name == selection.name
              })
        else {
            if snapshot.host(id: selection.hostID)?.zellijSessions.contains(
                where: { $0.name == selection.name }
            ) == true {
                throw ZellijSessionPresentationError.sessionExists(
                    selection.name
                )
            }
            throw ZellijSessionPresentationError.unavailable
        }
        let killKey = ZellijSessionKillCoordinator.Key(
            hostID: selection.hostID,
            sessionName: selection.name
        )
        guard !zellijSessionKillCoordinator.isPending(killKey) else {
            throw ZellijSessionPresentationError.operationPending(
                selection.name
            )
        }
        let killRevision = zellijSessionKillCoordinator.revision(for: killKey)
        let validation = await validatedZellijSession(on: resolvedHost)
        try Task.checkCancellation()
        try requireActiveScene(activityGeneration)
        guard navigationRevision == userNavigationRevision else {
            throw CancellationError()
        }
        guard let validation,
              let currentHost = snapshot.host(id: selection.hostID),
              currentHost.zellijAvailable,
              CommandHostResolver.resolve(currentHost) == resolvedHost
        else {
            throw ZellijSessionPresentationError.hostChanged(selection.name)
        }
        guard !currentHost.zellijSessions.contains(where: {
            $0.name == selection.name
        }) else {
            throw ZellijSessionPresentationError.sessionExists(selection.name)
        }
        switch validation.result {
        case let .available(names):
            guard !names.contains(selection.name) else {
                throw ZellijSessionPresentationError.sessionExists(
                    selection.name
                )
            }
        case .unavailable:
            throw ZellijSessionPresentationError.unavailable
        case let .failure(error):
            if error == .unavailable {
                throw ZellijSessionPresentationError.unavailable
            }
            throw error
        }
        guard !zellijSessionKillCoordinator.isPending(killKey),
              killRevision == zellijSessionKillCoordinator.revision(
                  for: killKey
              )
        else {
            throw ZellijSessionPresentationError.operationPending(
                selection.name
            )
        }
        cancelPendingRestoration()
        invalidateZellijPresentationIntent()
        guard let handle = presentZellijSession(
            selection,
            launchMode: .create,
            validation: validation,
            expectedKillRevision: killRevision
        ) else {
            throw ZellijSessionPresentationError.hostChanged(selection.name)
        }
        publishPendingZellijCreation(handle: handle, selection: selection)
    }

    private func publishPendingZellijCreation(
        handle: BorrowedZellijSessionHandle,
        selection: WorkspaceZellijSessionSelection
    ) {
        if failedZellijCreationIntent == selection {
            failedZellijCreationIntent = nil
        }
        pendingCreatedZellijSessions[handle.id] = selection
        var sessions = snapshot.host(id: selection.hostID)?.zellijSessions ?? []
        if !sessions.contains(where: { $0.name == selection.name }) {
            sessions.append(ZellijSessionSummary(name: selection.name))
        }
        zellijSessionsByHost[selection.hostID] = sessions
        zellijAvailabilityByHost[selection.hostID] = true
        applyRuntimeInventoryOverlayIfNeeded(hostID: selection.hostID)
    }

    @discardableResult
    private func presentZellijSession(
        _ selection: WorkspaceZellijSessionSelection,
        launchMode: ZellijAttachmentLaunchMode = .attachExisting,
        validation: ZellijSessionValidation? = nil,
        expectedKillRevision: UInt64? = nil
    ) -> BorrowedZellijSessionHandle? {
        let killKey = ZellijSessionKillCoordinator.Key(
            hostID: selection.hostID,
            sessionName: selection.name
        )
        guard !isShutDown,
              !zellijSessionKillCoordinator.isPending(killKey),
              expectedKillRevision.map({
                  zellijSessionKillCoordinator.revision(for: killKey) == $0
              }) ?? true
        else { return nil }
        cancelPendingTmuxPreviewActivations()
        if activeBorrowedZellijSelection == selection,
           let handle = activeBorrowedZellijHandle,
           nativeZellijSessionCoordinator.attachmentClosure(handle) == nil {
            return handle
        }
        guard let hostSummary = snapshot.host(id: selection.hostID),
              let currentHost = CommandHostResolver.resolve(hostSummary)
        else { return nil }
        guard let validation,
              currentHost == validation.host,
              let executablePath = validation.executablePath
        else { return nil }
        closeActivePresentations(replacingWith: selection)
        let handle = nativeZellijSessionCoordinator.attach(
            hostID: selection.hostID,
            name: selection.name,
            host: validation.host,
            launchMode: launchMode,
            sshConnectionSnapshot: validation.connection,
            resolvedZellijPath: executablePath
        )
        activeBorrowedZellijSelection = selection
        activeBorrowedZellijHandle = handle
        borrowedZellijConnectionStates[handle.id] = .connecting
        activeZellijReconnectContext = validation.host.isRemote
            ? ActiveZellijReconnectContext(
                selection: selection,
                handleID: handle.id,
                host: validation.host,
                routeIdentity: validation.connection.routeIdentity,
                surfaceExitCode: nil
            )
            : nil
        return handle
    }

    private func closeActivePresentations(
        replacingWith selection: WorkspaceZellijSessionSelection
    ) {
        if let activeTmux = activeBorrowedTmuxSelection {
            hideBorrowedTmuxSession(activeTmux)
        }
        if let activeHerdr = activeBorrowedHerdrSelection {
            closeBorrowedHerdrSession(activeHerdr)
        }
        if let active = activeBorrowedZellijSelection,
           active != selection {
            closeBorrowedZellijSession(active)
        }
    }

    func closeBorrowedZellijSession(
        _ selection: WorkspaceZellijSessionSelection
    ) {
        cancelPendingRestoration()
        invalidateZellijPresentationIntent()
        guard activeBorrowedZellijSelection == selection else { return }
        cancelZellijReconnect()
        if failedZellijCreationIntent == selection {
            failedZellijCreationIntent = nil
        }
        var wasPendingCreation = false
        if let handle = activeBorrowedZellijHandle {
            wasPendingCreation = pendingCreatedZellijSessions
                .removeValue(forKey: handle.id) != nil
            borrowedZellijConnectionStates.removeValue(forKey: handle.id)
        }
        activeBorrowedZellijSelection = nil
        activeBorrowedZellijHandle = nil
        nativeZellijSessionCoordinator.detach(
            hostID: selection.hostID,
            name: selection.name
        )
        if wasPendingCreation {
            reconcileZellijCreationDiscoveryRetry()
            scheduleZellijSessionDiscovery()
        }
    }

    func retryBorrowedZellijSession(
        _ selection: WorkspaceZellijSessionSelection
    ) {
        guard activeBorrowedZellijSelection == selection else { return }
        validateAndPresentZellijSession(
            selection,
            createsSessionIfMissing: failedZellijCreationIntent == selection
        )
    }

    private func validateAndPresentZellijSession(
        _ selection: WorkspaceZellijSessionSelection,
        createsSessionIfMissing: Bool = false
    ) {
        invalidateZellijPresentationIntent()
        let killKey = ZellijSessionKillCoordinator.Key(
            hostID: selection.hostID,
            sessionName: selection.name
        )
        let navigationRevision = userNavigationRevision
        guard let hostSummary = snapshot.host(id: selection.hostID),
              let host = CommandHostResolver.resolve(hostSummary),
              Self.supportsZellij(host),
              hostSummary.zellijAvailable
              || activeBorrowedZellijSelection == selection
        else { return }
        let intent = ZellijPresentationIntent(
            id: UUID(),
            selection: selection,
            navigationRevision: navigationRevision,
            revision: zellijPresentationRevision,
            host: host
        )
        zellijPresentationIntent = intent
        guard !zellijSessionKillCoordinator.isPending(killKey) else { return }
        let killRevision = zellijSessionKillCoordinator.revision(for: killKey)
        zellijPresentationTask = Task { [weak self] in
            guard let self else { return }
            defer {
                if zellijPresentationIntent?.id == intent.id {
                    zellijPresentationTask = nil
                    zellijPresentationIntent = nil
                }
            }
            let validation = await validatedZellijSession(on: host)
            guard !Task.isCancelled, !isShutDown,
                  zellijPresentationIntent?.id == intent.id,
                  zellijPresentationRevision == intent.revision,
                  navigationRevision == userNavigationRevision,
                  !zellijSessionKillCoordinator.isPending(killKey),
                  killRevision
                  == zellijSessionKillCoordinator.revision(for: killKey),
                  snapshot.host(id: selection.hostID)
                  .flatMap(CommandHostResolver.resolve) == host
            else { return }
            guard let validation else {
                retainFailedZellijSession(
                    selection,
                    host: host,
                    reason: "The SSH connection changed while Ghosthub was checking the Zellij session. Reopen it to use the current connection."
                )
                scheduleZellijSessionDiscovery()
                return
            }
            let failureReason: String
            var retryableTransportFailure = false
            switch validation.result {
            case let .available(names):
                let sessionIsActive = names.contains(selection.name)
                guard sessionIsActive || createsSessionIfMissing else {
                    failureReason =
                        "The Zellij session is no longer running."
                    break
                }
                let launchMode: ZellijAttachmentLaunchMode = sessionIsActive
                    ? .attachExisting : .create
                guard launchMode != .create
                    || failedZellijCreationIntent == selection
                else { return }
                guard let handle = presentZellijSession(
                    selection,
                    launchMode: launchMode,
                    validation: validation,
                    expectedKillRevision: killRevision
                ) else { return }
                if launchMode == .create {
                    publishPendingZellijCreation(
                        handle: handle,
                        selection: selection
                    )
                }
                return
            case .unavailable:
                failureReason = ZellijCommandError.unavailable
                    .localizedDescription
            case let .failure(error):
                failureReason = error.localizedDescription
                if case let .commandFailed(status, stderr) = error,
                   host.isRemote,
                   validation.connection.routeIdentity != nil,
                   status == 255,
                   SSHConnectionFailure.classify(
                       status: status,
                       output: stderr
                   ).kind == .transport {
                    retryableTransportFailure = true
                }
            }
            retainFailedZellijSession(
                selection,
                host: host,
                reason: failureReason,
                routeIdentity: retryableTransportFailure
                    ? validation.connection.routeIdentity : nil,
                reconnectsAutomatically: retryableTransportFailure
            )
            scheduleZellijSessionDiscovery()
        }
    }

    private func validatedZellijSession(
        on host: CommandHost,
        connection frozenConnection: SSHConnectionArgumentsSnapshot? = nil
    ) async -> ZellijSessionValidation? {
        let connection = if let frozenConnection {
            frozenConnection
        } else {
            await zellijConnectionSnapshot(on: host)
        }
        let result = await zellijSessionValidationDiscovery(
            host,
            connection.arguments
        )
        if case let .failure(error) = result,
           SSHConnectionFailure.indicatesUnusableConnection(error) {
            await connection.invalidate()
        }
        let resolvedPath: Result<String, ZellijCommandError>
        if case .available = result {
            guard !Task.isCancelled else { return nil }
            let resolver = zellijExecutableResolver
            let probe = Task.detached(priority: .userInitiated) {
                resolver(host, connection.arguments)
            }
            resolvedPath = await withTaskCancellationHandler {
                await probe.value
            } onCancel: {
                probe.cancel()
            }
            if case let .failure(error) = resolvedPath,
               SSHConnectionFailure.indicatesUnusableConnection(error) {
                await connection.invalidate()
            }
        } else {
            resolvedPath = .failure(.unavailable)
        }
        let currentConnection = await zellijConnectionSnapshot(on: host)
        guard !Task.isCancelled,
              currentConnection.cacheKey == connection.cacheKey
        else { return nil }
        let validatedResult: ZellijDiscoveryResult
        let executablePath: String?
        switch resolvedPath {
        case let .success(path):
            validatedResult = result
            executablePath = path
        case let .failure(error):
            validatedResult = if case .available = result {
                .failure(error)
            } else {
                result
            }
            executablePath = nil
        }
        return ZellijSessionValidation(
            result: validatedResult,
            host: host,
            connection: connection,
            executablePath: executablePath
        )
    }

    private func retainFailedZellijSession(
        _ selection: WorkspaceZellijSessionSelection,
        host: CommandHost,
        reason: String,
        routeIdentity: String? = nil,
        reconnectsAutomatically: Bool = false
    ) {
        guard activeBorrowedTmuxSelection == nil,
              activeBorrowedHerdrSelection == nil,
              activeBorrowedZellijSelection == nil
              || activeBorrowedZellijSelection == selection
        else { return }
        closeActivePresentations(replacingWith: selection)
        let handle = nativeZellijSessionCoordinator.retainFailedAttachment(
            hostID: selection.hostID,
            name: selection.name,
            host: host,
            reason: reason
        )
        activeBorrowedZellijSelection = selection
        activeBorrowedZellijHandle = handle
        borrowedZellijConnectionStates[handle.id] = .disconnected(
            reason: reason
        )
        activeZellijReconnectContext = host.isRemote
            ? ActiveZellijReconnectContext(
                selection: selection,
                handleID: handle.id,
                host: host,
                routeIdentity: routeIdentity,
                surfaceExitCode: nil
            )
            : nil
        if reconnectsAutomatically,
           var context = activeZellijReconnectContext {
            context.surfaceLaunchFailed = true
            activeZellijReconnectContext = context
            startZellijReconnect(context)
        }
    }

    func prepareZellijSessionKill(
        _ selection: WorkspaceZellijSessionSelection
    ) async throws -> ZellijSessionKillRequest {
        let activityGeneration = try captureSceneActivity()
        guard let hostSummary = snapshot.host(id: selection.hostID),
              hostSummary.zellijAvailable,
              let host = CommandHostResolver.resolve(hostSummary)
        else { throw ZellijSessionPresentationError.unavailable }
        let connection = await zellijConnectionSnapshot(on: host)
        try requireActiveScene(activityGeneration)
        let result = await zellijSessionValidationDiscovery(
            host,
            connection.arguments
        )
        if case let .failure(error) = result,
           SSHConnectionFailure.indicatesUnusableConnection(error) {
            await connection.invalidate()
        }
        let currentConnection = await zellijConnectionSnapshot(on: host)
        try requireActiveScene(activityGeneration)
        guard snapshot.host(id: selection.hostID)
            .flatMap(CommandHostResolver.resolve) == host,
            currentConnection.cacheKey == connection.cacheKey
        else {
            throw ZellijSessionPresentationError.hostChanged(selection.name)
        }
        try requireActiveZellijSession(selection.name, in: result)
        let authorityID = UUID()
        zellijKillAuthorities[authorityID] = ZellijKillAuthority(
            hostID: selection.hostID,
            host: host,
            routeIdentity: connection.routeIdentity
        )
        return ZellijSessionKillRequest(
            authorityID: authorityID,
            session: selection,
            confirmedHost: hostSummary
        )
    }

    func killZellijSession(
        _ request: ZellijSessionKillRequest
    ) async throws {
        let activityGeneration = try captureSceneActivity()
        let selection = request.session
        guard let authority = zellijKillAuthorities.removeValue(
            forKey: request.authorityID
        ),
            authority.hostID == selection.hostID,
            request.confirmedHost.id == selection.hostID,
            let confirmedHost = CommandHostResolver.resolve(
                request.confirmedHost
            ),
            let currentHostSummary = snapshot.host(id: selection.hostID),
            currentHostSummary.zellijAvailable,
            let currentHost = CommandHostResolver.resolve(currentHostSummary),
            currentHost == confirmedHost,
            authority.host == currentHost
        else {
            throw ZellijSessionPresentationError.hostChanged(selection.name)
        }
        let currentConnection = await zellijConnectionSnapshot(on: currentHost)
        try requireActiveScene(activityGeneration)
        guard currentConnection.routeIdentity == authority.routeIdentity else {
            throw ZellijSessionPresentationError.hostChanged(selection.name)
        }
        let key = ZellijSessionKillCoordinator.Key(
            hostID: selection.hostID,
            sessionName: selection.name
        )
        guard let operation = zellijSessionKillCoordinator.begin(
            key: key,
            host: authority.host,
            connectionCacheKey: currentConnection.cacheKey
        )
        else {
            throw ZellijSessionPresentationError.operationPending(
                selection.name
            )
        }
        var outcome = ZellijSessionKillCoordinator.Outcome.failed
        defer {
            zellijSessionKillCoordinator.finish(operation, outcome: outcome)
        }
        let result = await zellijSessionValidationDiscovery(
            currentHost,
            currentConnection.arguments
        )
        if case let .failure(error) = result,
           SSHConnectionFailure.indicatesUnusableConnection(error) {
            await currentConnection.invalidate()
        }
        let postDiscoveryConnection = await zellijConnectionSnapshot(
            on: authority.host
        )
        try requireActiveScene(activityGeneration)
        guard let postDiscoveryHostSummary = snapshot.host(
            id: selection.hostID
        ),
            postDiscoveryHostSummary.zellijAvailable,
            let postDiscoveryHost = CommandHostResolver.resolve(
                postDiscoveryHostSummary
            ),
            postDiscoveryHost == authority.host,
            postDiscoveryConnection.cacheKey
            == currentConnection.cacheKey
        else {
            throw ZellijSessionPresentationError.hostChanged(selection.name)
        }
        try requireActiveZellijSession(selection.name, in: result)
        let killResult = await zellijSessionKiller(
            selection.name,
            postDiscoveryHost,
            currentConnection.arguments
        )
        if case let .failure(error) = killResult,
           SSHConnectionFailure.indicatesUnusableConnection(error) {
            await currentConnection.invalidate()
        }
        try killResult.get()
        outcome = .succeeded
        try requireActiveScene(activityGeneration)
    }

    func cancelPreparedZellijSessionKill(
        _ request: ZellijSessionKillRequest
    ) {
        zellijKillAuthorities.removeValue(forKey: request.authorityID)
    }

    private func requireActiveZellijSession(
        _ name: String,
        in result: ZellijDiscoveryResult
    ) throws {
        switch result {
        case let .available(names):
            guard names.contains(name) else {
                throw ZellijSessionPresentationError.sessionMissing(name)
            }
        case .unavailable:
            throw ZellijSessionPresentationError.unavailable
        case let .failure(error):
            throw error
        }
    }

    private func zellijConnectionSnapshot(
        on host: CommandHost
    ) async -> SSHConnectionArgumentsSnapshot {
        guard case let .ssh(info) = host else {
            return SSHConnectionArgumentsSnapshot(arguments: [])
        }
        return await zellijSSHConnectionSnapshotProvider(info)
    }

    private func captureSceneActivity() throws -> UInt64 {
        guard !isShutDown else { throw CancellationError() }
        return sceneActivityGeneration
    }

    private func requireActiveScene(_ generation: UInt64) throws {
        guard !Task.isCancelled,
              !isShutDown,
              sceneActivityGeneration == generation
        else { throw CancellationError() }
    }

    func openBorrowedHerdrSession(
        _ selection: WorkspaceHerdrSessionSelection
    ) async throws {
        invalidateZellijPresentationIntent()
        cancelPendingTmuxPreviewActivations()
        let activityGeneration = try captureSceneActivity()
        let navigationRevision = userNavigationRevision
        guard snapshot.host(id: selection.hostID)?.herdrSessions.contains(
            where: {
                $0.name == selection.name && $0.state == .running
            }
        ) == true else {
            throw HerdrSessionPresentationError.sessionNotRunning(
                selection.name
            )
        }
        let validation = try await revalidatedHerdrSession(selection)
        try requireActiveScene(activityGeneration)
        guard navigationRevision == userNavigationRevision else {
            throw CancellationError()
        }
        guard validation.session?.state == .running else {
            throw validation.session == nil
                ? HerdrSessionPresentationError.sessionMissing(selection.name)
                : HerdrSessionPresentationError.sessionNotRunning(
                    selection.name
                )
        }
        cancelPendingRestoration()
        if failedHerdrLaunchIntent?.selection == selection {
            failedHerdrLaunchIntent = nil
        }
        _ = presentHerdrSession(
            selection,
            launchMode: .attachExisting,
            validation: validation
        )
    }

    func createHerdrSession(
        _ selection: WorkspaceHerdrSessionSelection
    ) async throws {
        invalidateZellijPresentationIntent()
        let activityGeneration = try captureSceneActivity()
        let navigationRevision = userNavigationRevision
        guard let host = snapshot.host(id: selection.hostID),
              host.herdrAvailable
        else { throw HerdrSessionPresentationError.unavailable }
        guard !host.herdrSessions.contains(where: {
            $0.name == selection.name
        }) else {
            throw HerdrSessionPresentationError.sessionExists(selection.name)
        }
        let validation = try await revalidatedHerdrSession(selection)
        try requireActiveScene(activityGeneration)
        guard navigationRevision == userNavigationRevision
        else { throw CancellationError() }
        guard validation.session == nil else {
            throw HerdrSessionPresentationError.sessionExists(selection.name)
        }
        try launchHerdrSession(
            selection,
            kind: .create,
            validation: validation
        )
    }

    func prepareHerdrSessionLifecycle(
        _ selection: WorkspaceHerdrSessionSelection,
        action: HerdrSessionDestructiveAction
    ) async throws -> HerdrSessionLifecycleRequest {
        let activityGeneration = try captureSceneActivity()
        guard let hostSummary = snapshot.host(id: selection.hostID),
              hostSummary.herdrAvailable,
              let host = CommandHostResolver.resolve(hostSummary)
        else { throw HerdrSessionPresentationError.unavailable }
        guard let summary = hostSummary.herdrSessions.first(where: {
            $0.name == selection.name
        }) else {
            throw HerdrSessionLifecycleError.sessionMissing(selection.name)
        }
        try Self.validateHerdrLifecycleState(
            summary.state,
            isDefault: summary.isDefault,
            name: summary.name,
            action: action
        )
        let connection = await herdrConnectionSnapshot(on: host)
        try requireActiveScene(activityGeneration)
        let recordResult = await herdrSessionRecordReader(
            selection.name,
            host,
            connection.arguments
        )
        if case let .failure(error) = recordResult,
           SSHConnectionFailure.indicatesUnusableConnection(error) {
            await connection.invalidate()
        }
        let record = try recordResult.get()
        try requireActiveScene(activityGeneration)
        try Self.validateHerdrLifecycleState(
            record.state,
            isDefault: record.isDefault,
            name: record.name,
            action: action
        )
        let authorityID = UUID()
        herdrLifecycleAuthorities[authorityID] = HerdrLifecycleAuthority(
            host: host,
            routeIdentity: connection.routeIdentity
        )
        return HerdrSessionLifecycleRequest(
            authorityID: authorityID,
            session: selection,
            confirmedHost: hostSummary,
            isDefault: record.isDefault,
            confirmedSessionDirectory: record.sessionDirectory,
            confirmedSocketPath: record.socketPath,
            action: action
        )
    }

    func performHerdrSessionLifecycle(
        _ request: HerdrSessionLifecycleRequest
    ) async throws {
        let activityGeneration = try captureSceneActivity()
        let selection = request.session
        guard let authority = herdrLifecycleAuthorities.removeValue(
            forKey: request.authorityID
        ),
            request.confirmedHost.id == selection.hostID,
            let confirmedHost = CommandHostResolver.resolve(
                request.confirmedHost
            ),
            let currentHostSummary = snapshot.host(id: selection.hostID),
            currentHostSummary.herdrAvailable,
            let currentHost = CommandHostResolver.resolve(
                currentHostSummary
            ),
            currentHost == confirmedHost,
            authority.host == currentHost
        else {
            throw HerdrSessionLifecycleRequestError.hostChanged(
                selection.name
            )
        }
        let currentConnection = await herdrConnectionSnapshot(on: currentHost)
        try requireActiveScene(activityGeneration)
        guard currentConnection.routeIdentity == authority.routeIdentity else {
            throw HerdrSessionLifecycleRequestError.hostChanged(
                selection.name
            )
        }
        let key = HerdrSessionLifecycleCoordinator.Key(
            hostID: selection.hostID,
            sessionName: selection.name
        )
        let kind: HerdrSessionLifecycleCoordinator.OperationKind =
            request.action == .stop ? .stop : .delete
        guard let operation = herdrLifecycleCoordinator.begin(kind, key: key)
        else {
            throw HerdrSessionPresentationError.operationPending(
                selection.name
            )
        }
        var outcome = HerdrSessionLifecycleCoordinator.Outcome.failed
        defer {
            herdrLifecycleCoordinator.finish(operation, outcome: outcome)
        }

        let recordResult = await herdrSessionRecordReader(
            selection.name,
            currentHost,
            currentConnection.arguments
        )
        if case let .failure(error) = recordResult,
           SSHConnectionFailure.indicatesUnusableConnection(error) {
            await currentConnection.invalidate()
        }
        let record = try recordResult.get()
        try requireActiveScene(activityGeneration)
        guard record.isDefault == request.isDefault,
              record.sessionDirectory == request.confirmedSessionDirectory,
              record.socketPath == request.confirmedSocketPath
        else {
            throw HerdrSessionLifecycleError.locationChanged(selection.name)
        }
        try Self.validateHerdrLifecycleState(
            record.state,
            isDefault: record.isDefault,
            name: record.name,
            action: request.action
        )
        if request.action == .stop {
            herdrLifecycleCoordinator.willStop(operation)
        }
        let lifecycleAction: HerdrSessionLifecycleAction =
            request.action == .stop ? .stop : .delete
        let mutationResult = await herdrSessionMutator(
            lifecycleAction,
            record,
            currentHost,
            currentConnection.arguments
        )
        if case let .failure(error) = mutationResult,
           SSHConnectionFailure.indicatesUnusableConnection(error) {
            await currentConnection.invalidate()
        }
        _ = try mutationResult.get()
        try requireActiveScene(activityGeneration)
        outcome = .succeeded
    }

    func cancelPreparedHerdrSessionLifecycle(
        _ request: HerdrSessionLifecycleRequest
    ) {
        herdrLifecycleAuthorities.removeValue(forKey: request.authorityID)
    }

    private func herdrConnectionSnapshot(
        on host: CommandHost
    ) async -> SSHConnectionArgumentsSnapshot {
        guard case let .ssh(info) = host else {
            return SSHConnectionArgumentsSnapshot(arguments: [])
        }
        return await herdrSSHConnectionSnapshotProvider(info)
    }

    /// Borrows a noninteractive kwt lease and freezes its arguments. The
    /// snapshot owns that borrow until its last copy is gone.
    nonisolated static func borrowedConnectionSnapshot(
        _ host: SSHHostInfo
    ) async -> SSHConnectionArgumentsSnapshot {
        do {
            return try await SSHConnectionArgumentsSnapshot(
                KwtSSHCommandLease().acquire(on: host)
            )
        } catch {
            return .failClosed(error)
        }
    }

    private func validatedHerdrSessionProbe(
        named name: String,
        on host: CommandHost,
        connection frozenConnection: SSHConnectionArgumentsSnapshot? = nil
    ) async -> HerdrSessionProbeValidation? {
        let connection = if let frozenConnection {
            frozenConnection
        } else {
            await herdrConnectionSnapshot(on: host)
        }
        let outcome = await herdrSessionExactProbe(
            name,
            host,
            connection.arguments
        )
        let currentConnection = await herdrConnectionSnapshot(on: host)
        guard !Task.isCancelled,
              currentConnection.cacheKey == connection.cacheKey
        else { return nil }
        return HerdrSessionProbeValidation(
            outcome: outcome,
            validation: HerdrSessionValidation(
                session: nil,
                host: host,
                connection: connection
            )
        )
    }

    private static func validateHerdrLifecycleState(
        _ state: HerdrSessionState,
        isDefault: Bool,
        name: String,
        action: HerdrSessionDestructiveAction
    ) throws {
        switch action {
        case .stop:
            guard state == .running else {
                throw HerdrSessionLifecycleError.stateChanged(
                    name: name,
                    expected: .running
                )
            }
        case .delete:
            guard !isDefault else {
                throw HerdrSessionLifecycleError
                    .defaultSessionCannotBeDeleted
            }
            guard state == .stopped else {
                throw HerdrSessionLifecycleError.stateChanged(
                    name: name,
                    expected: .stopped
                )
            }
        }
    }

    func isHerdrSessionLifecyclePending(
        _ selection: WorkspaceHerdrSessionSelection
    ) -> Bool {
        herdrLifecycleCoordinator.isPending(.init(
            hostID: selection.hostID,
            sessionName: selection.name
        ))
    }

    var pendingHerdrSessionSelections:
        Set<WorkspaceHerdrSessionSelection> {
        Set(herdrLifecycleCoordinator.pendingKeys.map {
            WorkspaceHerdrSessionSelection(
                hostID: $0.hostID,
                name: $0.sessionName
            )
        })
    }

    func restartHerdrSession(
        _ selection: WorkspaceHerdrSessionSelection
    ) async throws {
        let activityGeneration = try captureSceneActivity()
        let navigationRevision = userNavigationRevision
        guard let host = snapshot.host(id: selection.hostID),
              host.herdrAvailable
        else { throw HerdrSessionPresentationError.unavailable }
        guard let session = host.herdrSessions.first(where: {
            $0.name == selection.name
        }) else {
            throw HerdrSessionPresentationError.sessionMissing(selection.name)
        }
        guard session.state == .stopped else {
            throw HerdrSessionPresentationError.sessionNotStopped(
                selection.name
            )
        }
        let validation = try await revalidatedHerdrSession(selection)
        guard let currentSession = validation.session else {
            throw HerdrSessionPresentationError.sessionMissing(selection.name)
        }
        try requireActiveScene(activityGeneration)
        guard navigationRevision == userNavigationRevision else {
            throw CancellationError()
        }
        guard currentSession.state == .stopped else {
            throw HerdrSessionPresentationError.sessionNotStopped(
                selection.name
            )
        }
        try launchHerdrSession(
            selection,
            kind: .restart,
            validation: validation
        )
    }

    private func revalidatedHerdrSession(
        _ selection: WorkspaceHerdrSessionSelection
    ) async throws -> HerdrSessionValidation {
        guard let originalHost = snapshot.host(id: selection.hostID),
              let route = CommandHostResolver.resolve(originalHost)
        else { throw HerdrSessionPresentationError.unavailable }
        let key = HerdrSessionLifecycleCoordinator.Key(
            hostID: selection.hostID,
            sessionName: selection.name
        )
        guard !herdrLifecycleCoordinator.isPending(key) else {
            throw HerdrSessionPresentationError.operationPending(
                selection.name
            )
        }
        let lifecycleRevision = herdrLifecycleCoordinator.revision(
            for: selection.hostID
        )
        let connection = await herdrConnectionSnapshot(on: route)
        let result = await herdrSessionValidationDiscovery(
            route,
            connection.arguments
        )
        if case let .failure(error) = result,
           SSHConnectionFailure.indicatesUnusableConnection(error) {
            await connection.invalidate()
        }
        let currentConnection = await herdrConnectionSnapshot(on: route)
        guard !Task.isCancelled else { throw CancellationError() }
        guard snapshot.host(id: selection.hostID)
            .flatMap(CommandHostResolver.resolve) == route,
            currentConnection.cacheKey == connection.cacheKey
        else {
            throw HerdrSessionPresentationError.routeChangedDuringValidation(
                selection.name
            )
        }
        guard herdrLifecycleCoordinator.revision(for: selection.hostID)
            == lifecycleRevision,
            !herdrLifecycleCoordinator.isPending(key)
        else {
            throw HerdrSessionPresentationError.stateChangedDuringValidation(
                selection.name
            )
        }
        switch result {
        case let .available(sessions):
            return HerdrSessionValidation(
                session: sessions.first { $0.name == selection.name },
                host: route,
                connection: connection
            )
        case .unavailable:
            throw HerdrSessionPresentationError.unavailable
        case let .failure(error):
            throw HerdrSessionPresentationError.stateValidationFailed(
                name: selection.name,
                detail: error.localizedDescription
            )
        }
    }

    private func launchHerdrSession(
        _ selection: WorkspaceHerdrSessionSelection,
        kind: HerdrSessionLifecycleCoordinator.OperationKind,
        validation: HerdrSessionValidation
    ) throws {
        _ = try captureSceneActivity()
        let key = HerdrSessionLifecycleCoordinator.Key(
            hostID: selection.hostID,
            sessionName: selection.name
        )
        guard let operation = herdrLifecycleCoordinator.begin(kind, key: key)
        else {
            throw HerdrSessionPresentationError.operationPending(
                selection.name
            )
        }
        if failedHerdrLaunchIntent?.selection == selection {
            failedHerdrLaunchIntent = nil
        }
        guard let handle = presentHerdrSession(
            selection,
            launchMode: .launchOrAttach,
            validation: validation
        ) else {
            herdrLifecycleCoordinator.finish(operation, outcome: .failed)
            scheduleHerdrSessionDiscovery()
            throw HerdrSessionPresentationError.unavailable
        }
        pendingHerdrLaunchOperations[handle.id] = PendingHerdrLaunch(
            operation: operation,
            authority: nil
        )
    }

    @discardableResult
    private func presentHerdrSession(
        _ selection: WorkspaceHerdrSessionSelection,
        launchMode: HerdrAttachmentLaunchMode = .attachExisting,
        validation: HerdrSessionValidation? = nil
    ) -> BorrowedHerdrSessionHandle? {
        guard !isShutDown else { return nil }
        cancelPendingTmuxPreviewActivations()
        if let activeTmux = activeBorrowedTmuxSelection {
            hideBorrowedTmuxSession(activeTmux)
        }
        if let activeZellij = activeBorrowedZellijSelection {
            closeBorrowedZellijSession(activeZellij)
        }
        if let active = activeBorrowedHerdrSelection,
           active != selection {
            closeBorrowedHerdrSession(active)
        }
        if activeBorrowedHerdrSelection == selection,
           let handle = activeBorrowedHerdrHandle,
           nativeHerdrSessionCoordinator.attachmentClosure(handle) == nil {
            let existingMode = nativeHerdrSessionCoordinator
                .attachmentLaunchMode(handle)
            let routeMatches = if let validation,
                                  let authority = nativeHerdrSessionCoordinator
                                  .attachmentAuthority(handle) {
                authority.host == validation.host
            } else {
                validation == nil
            }
            if launchMode == .attachExisting
                || existingMode == .launchOrAttach,
                routeMatches {
                return handle
            }
            closeBorrowedHerdrSession(selection)
        }
        guard let host = snapshot.host(id: selection.hostID),
              let currentHost = CommandHostResolver.resolve(host)
        else {
            activeBorrowedHerdrSelection = selection
            activeBorrowedHerdrHandle = nil
            return nil
        }
        let attachmentHost = validation?.host ?? currentHost
        guard currentHost == attachmentHost else { return nil }
        let handle = nativeHerdrSessionCoordinator.attach(
            hostID: selection.hostID,
            name: selection.name,
            host: attachmentHost,
            isDefault: validation?.session?.isDefault ?? false,
            launchMode: launchMode,
            sshConnectionSnapshot: validation?.connection
        )
        activeBorrowedHerdrSelection = selection
        activeBorrowedHerdrHandle = handle
        borrowedHerdrConnectionStates[handle.id] = .connecting
        activeHerdrReconnectContext = attachmentHost.isRemote
            ? ActiveHerdrReconnectContext(
                selection: selection,
                handleID: handle.id,
                host: attachmentHost,
                routeIdentity: validation?.connection.routeIdentity,
                surfaceExitCode: nil
            )
            : nil
        return handle
    }

    func closeBorrowedHerdrSession(
        _ selection: WorkspaceHerdrSessionSelection
    ) {
        cancelPendingRestoration()
        guard activeBorrowedHerdrSelection == selection else { return }
        cancelHerdrReconnect()
        if failedHerdrLaunchIntent?.selection == selection {
            failedHerdrLaunchIntent = nil
        }
        if let handle = activeBorrowedHerdrHandle {
            borrowedHerdrConnectionStates.removeValue(forKey: handle.id)
            herdrLaunchConfirmationTasks.removeValue(
                forKey: handle.id
            )?.cancel()
            if let pending = pendingHerdrLaunchOperations.removeValue(
                forKey: handle.id
            ) {
                herdrLifecycleCoordinator.finish(
                    pending.operation,
                    outcome: .failed
                )
                scheduleHerdrSessionDiscovery()
            }
        }
        activeBorrowedHerdrSelection = nil
        activeBorrowedHerdrHandle = nil
        nativeHerdrSessionCoordinator.detach(
            hostID: selection.hostID,
            name: selection.name
        )
    }

    func retryBorrowedHerdrSession(
        _ selection: WorkspaceHerdrSessionSelection
    ) async {
        guard let activityGeneration = try? captureSceneActivity() else {
            return
        }
        guard activeBorrowedHerdrSelection == selection else { return }
        let key = HerdrSessionLifecycleCoordinator.Key(
            hostID: selection.hostID,
            sessionName: selection.name
        )
        guard !herdrLifecycleCoordinator.isPending(key),
              !suppressedHerdrStops.values.contains(where: {
                  $0.selection == selection
              })
        else { return }
        if let intent = failedHerdrLaunchIntent,
           intent.selection == selection {
            do {
                let validation = try await revalidatedHerdrSession(
                    selection
                )
                try requireActiveScene(activityGeneration)
                guard activeBorrowedHerdrSelection == selection else {
                    return
                }
                if validation.session?.state == .running {
                    failedHerdrLaunchIntent = nil
                    closeBorrowedHerdrSession(selection)
                    guard presentHerdrSession(
                        selection,
                        launchMode: .attachExisting,
                        validation: validation
                    ) != nil else {
                        stopHerdrReconnectWithUnableToAttach(
                            HerdrSessionPresentationError.unavailable
                                .localizedDescription
                        )
                        return
                    }
                    prepareActiveBorrowedHerdrSurface()
                    return
                }
                switch intent.kind {
                case .create:
                    guard validation.session == nil else {
                        throw HerdrSessionPresentationError.sessionExists(
                            selection.name
                        )
                    }
                case .restart:
                    guard let currentSession = validation.session else {
                        throw HerdrSessionPresentationError.sessionMissing(
                            selection.name
                        )
                    }
                    guard currentSession.state == .stopped else {
                        throw HerdrSessionPresentationError.sessionNotStopped(
                            selection.name
                        )
                    }
                case .stop, .delete:
                    return
                }
                try launchHerdrSession(
                    selection,
                    kind: intent.kind,
                    validation: validation
                )
                prepareActiveBorrowedHerdrSurface()
            } catch is CancellationError {
                return
            } catch {
                let invalidatesIntent = if let error = error as?
                    HerdrSessionPresentationError {
                    switch error {
                    case .sessionExists, .sessionMissing,
                         .sessionNotRunning, .sessionNotStopped:
                        true
                    case .unavailable, .operationPending,
                         .routeChangedDuringValidation,
                         .stateChangedDuringValidation,
                         .stateValidationFailed:
                        false
                    }
                } else {
                    false
                }
                failedHerdrLaunchIntent = invalidatesIntent ? nil : intent
                stopHerdrReconnectWithUnableToAttach(
                    error.localizedDescription
                )
            }
            return
        }
        guard let handle = activeBorrowedHerdrHandle,
              let hostSummary = snapshot.host(id: selection.hostID),
              let host = CommandHostResolver.resolve(hostSummary)
        else { return }
        let probe = await validatedHerdrSessionProbe(
            named: selection.name,
            on: host
        )
        guard let probe else {
            if !Task.isCancelled {
                stopHerdrReconnectWithUnableToAttach(
                    "The SSH connection changed while Ghosthub was checking the Herdr session. Try again to use the current connection."
                )
            }
            return
        }
        guard (try? requireActiveScene(activityGeneration)) != nil,
              activeBorrowedHerdrSelection == selection,
              activeBorrowedHerdrHandle == handle,
              snapshot.host(id: selection.hostID)
              .flatMap(CommandHostResolver.resolve) == host,
              !herdrLifecycleCoordinator.isPending(key),
              !suppressedHerdrStops.values.contains(where: {
                  $0.selection == selection
              })
        else { return }
        guard probe.outcome == .present else {
            switch probe.outcome {
            case .absent, .unavailable:
                refreshHerdrInventory(hostID: selection.hostID)
            case .failure(.cancelled):
                break
            case let .failure(error):
                stopHerdrReconnectWithUnableToAttach(
                    error.localizedDescription
                )
            case .present:
                break
            }
            return
        }
        closeBorrowedHerdrSession(selection)
        guard presentHerdrSession(
            selection,
            validation: probe.validation
        ) != nil else { return }
        prepareActiveBorrowedHerdrSurface()
    }

    func createTmuxSession(_ selection: WorkspaceTmuxSessionSelection) {
        createTmuxSession(WorkspaceTmuxSessionCreationRequest(
            selection: selection
        ))
    }

    func createTmuxSession(_ request: WorkspaceTmuxSessionCreationRequest) {
        let isPendingCommandReplay = request.initialCommand != nil
            && pendingCreatedTmuxSessions.values.contains {
                Self.sameTmuxSession($0.selection, request.selection)
            }
        createTmuxSession(
            request,
            commandReplayAuthorized: !isPendingCommandReplay
        )
    }

    private func createTmuxSession(
        _ request: WorkspaceTmuxSessionCreationRequest,
        commandReplayAuthorized: Bool
    ) {
        cancelPendingRestoration()
        let selection = request.selection
        userNavigationRevision &+= 1
        if let worktreeID = selection.worktreeID {
            explicitlyDismissedWorktreePresentationIDs.remove(worktreeID)
        }
        if let directoryID = selection.directoryWorkspaceID {
            explicitlyDismissedDirectoryPresentationIDs.remove(directoryID)
        }
        let hasPendingCreation = pendingCreatedTmuxSessions.values.contains {
            Self.sameTmuxSession($0.selection, selection)
        }
        let knownSessions = tmuxSessionsByHost[selection.hostID]
            ?? snapshot.host(id: selection.hostID)?.tmuxSessions
            ?? []
        let sessionAlreadyKnown = knownSessions.contains {
            $0.name == selection.name
        }
        let launchMode: TmuxAttachmentLaunchMode
        if selection.tmuxAttachMode == .protected
            || selection.socketName != nil {
            launchMode = .attach
        } else {
            launchMode =
                !hasPendingCreation && sessionAlreadyKnown ? .attach : .create
        }
        guard let handle = presentTmuxSession(
            selection,
            launchMode: launchMode,
            initialCommand: launchMode == .create
                ? request.initialCommand
                : nil,
            commandReplayAuthorized: commandReplayAuthorized
        ) else { return }
        if launchMode == .create {
            pendingCreatedTmuxSessions[handle.id] =
                PendingTmuxSessionCreation(
                    request: request,
                    commandReplayAuthorized: false
                )
            _ = publishCreatedTmuxSession(selection)
        }
    }

    private enum TmuxPresentationIntent: Equatable {
        case userInitiated
        case restoreOnly
    }

    @discardableResult
    private func presentTmuxSession(
        _ selection: WorkspaceTmuxSessionSelection,
        launchMode: TmuxAttachmentLaunchMode,
        initialCommand: String? = nil,
        commandReplayAuthorized: Bool = false,
        intent: TmuxPresentationIntent = .userInitiated,
        activatesPresentation: Bool = true,
        ignoresClientSize: Bool = false,
        previewGridSize: TmuxGridSize? = nil
    ) -> BorrowedTmuxSessionHandle? {
        if activatesPresentation {
            cancelPendingTmuxPreviewActivations()
        }
        if activatesPresentation, let activeHerdr = activeBorrowedHerdrSelection {
            closeBorrowedHerdrSession(activeHerdr)
        }
        if activatesPresentation,
           let activeZellij = activeBorrowedZellijSelection {
            closeBorrowedZellijSession(activeZellij)
        }
        var selection = selection
        if let worktreeID = selection.worktreeID,
           selection.worktreeGeneration == nil,
           let generation = snapshot.worktree(id: worktreeID)?.generation,
           WorktreeGeneration.isCanonical(generation) {
            selection.worktreeGeneration = generation
        }
        guard !worktreeRemovalIsPending(for: selection) else { return nil }
        let effectiveLaunchMode: TmuxAttachmentLaunchMode =
            (selection.tmuxAttachMode == .protected
                || selection.socketName != nil) && launchMode == .create
            ? .attach
            : launchMode
        guard effectiveLaunchMode != .create
            || initialCommand == nil
            || commandReplayAuthorized
        else { return nil }
        if let worktreeID = selection.worktreeID {
            let replacedSelections: [WorkspaceTmuxSessionSelection] =
                retainedTmuxPresentations.values.compactMap { presentation in
                    let retained = presentation.selection
                    guard retained.worktreeID == worktreeID else { return nil }
                    let endpointChanged = !Self.sameTmuxEndpoint(
                        retained,
                        selection
                    )
                    let generationChanged = Self
                        .hasDifferentKnownWorktreeGeneration(
                            retained,
                            selection
                        )
                    return endpointChanged || generationChanged
                        ? retained
                        : nil
                }
            for replaced in replacedSelections {
                invalidateBorrowedTmuxSession(replaced)
            }
        }
        let key = TmuxPresentationKey(selection)
        if let retained = retainedTmuxPresentations[key] {
            let recreatesClosedAttachment = effectiveLaunchMode == .create
                && nativeTmuxSessionCoordinator.hasClosedAttachment(
                    retained.handle
                )
            if recreatesClosedAttachment {
                invalidateBorrowedTmuxSession(retained.selection)
            } else {
                var reboundSelection = selection
                if retained.selection.worktreeID == selection.worktreeID,
                   retained.selection.directoryWorkspaceID
                   == selection.directoryWorkspaceID,
                   retained.selection.workspacePath == selection.workspacePath,
                   reboundSelection.worktreeGeneration == nil {
                    reboundSelection.worktreeGeneration =
                        retained.selection.worktreeGeneration
                }
                if retained.selection != reboundSelection {
                    let reconnectWasRunning =
                        retained.reconnectSupervisor.isRunning
                    retained.selection = reboundSelection
                    retained.reconnectContext?.selection = reboundSelection
                    if reboundSelection.workspacePath == nil,
                       retained.reconnectContext?.phase
                       == .establishingWorkspace {
                        retained.reconnectContext?.phase = .attachOnly
                        retained.establishmentConfirmationTask?.cancel()
                        retained.establishmentConfirmationTask = nil
                        releaseProtectedTmuxAttachmentScope(
                            handleID: retained.handle.id
                        )
                    }
                    if reconnectWasRunning,
                       let reboundContext = retained.reconnectContext {
                        startTmuxReconnect(
                            retained,
                            context: reboundContext
                        )
                    }
                }
                if activatesPresentation {
                    if alwaysLiveManagedTmuxPresentationKeys.contains(key) {
                        stageTmuxPresentationActivation(retained)
                        promoteAlwaysLiveManagedPresentation(
                            retained,
                            key: key,
                            navigationRevision: userNavigationRevision
                        )
                        return retained.handle
                    }
                    activateTmuxPresentation(retained)
                }
                return retained.handle
            }
        }
        guard let host = snapshot.host(id: selection.hostID),
              let attachmentHost = CommandHostResolver.resolve(host)
        else {
            if activatesPresentation {
                prepareActiveTmuxPreviewForDeactivation()
                activeBorrowedTmuxSelection = selection
                activeBorrowedTmuxHandle = nil
                activeBorrowedTmuxLaunchMode = effectiveLaunchMode
                activeBorrowedTmuxRecoveryState = nil
                sessionConnectionRecoveryRequest = nil
            }
            return nil
        }
        let knownSessions = tmuxSessionsByHost[selection.hostID]
            ?? host.tmuxSessions
        let sessionIsDiscovered = selection.socketName == nil
            && knownSessions.contains { $0.name == selection.name }
        let managedKwtUnavailable =
            kwtAvailabilityByHost[selection.hostID] == false
        let openWorkspace = intent == .userInitiated
            && effectiveLaunchMode == .attach
            && selection.tmuxAttachMode == .direct
            && selection.workspacePath != nil
            && (!sessionIsDiscovered || !managedKwtUnavailable)
        let protectedSessionNeedsEstablishment = intent == .userInitiated
            && effectiveLaunchMode == .attach
            && selection.tmuxAttachMode == .protected
            && selection.workspacePath != nil
        let discoveredIdentity = Self.discoveredTmuxSessionIdentity(
            selection,
            hostSummary: host
        )
        let handle = nativeTmuxSessionCoordinator.attach(
            hostID: selection.hostID,
            name: selection.name,
            host: attachmentHost,
            socketName: selection.socketName,
            tmuxAttachMode: selection.tmuxAttachMode,
            launchMode: effectiveLaunchMode,
            initialCommand: effectiveLaunchMode == .create
                ? initialCommand
                : nil,
            workingDirectory: selection.workspacePath,
            openWorkspace: openWorkspace,
            sessionIdentity: discoveredIdentity,
            ignoresClientSize: ignoresClientSize,
            previewGridSize: previewGridSize
        )
        let phase: RemoteTmuxEstablishmentPhase
        if openWorkspace || protectedSessionNeedsEstablishment {
            phase = .establishingWorkspace
        } else if effectiveLaunchMode == .create,
                  let initialCommand,
                  !initialCommand.isEmpty {
            phase = .establishingProfile(initialCommand: initialCommand)
        } else {
            phase = .attachOnly
        }
        let reconnectContext = attachmentHost.isRemote
            || openWorkspace
            || protectedSessionNeedsEstablishment
            ? TmuxReconnectContext(
                selection: selection,
                handleID: handle.id,
                host: attachmentHost,
                routeIdentity: nativeTmuxSessionCoordinator
                    .attachmentRouteIdentity(handle),
                phase: phase,
                surfaceExitCode: nil,
                usesKwtWorkspaceCommand: openWorkspace
            )
            : nil
        let presentation = RetainedTmuxPresentation(
            selection: selection,
            handle: handle,
            launchMode: effectiveLaunchMode,
            reconnectContext: reconnectContext,
            reconnectSupervisor: SessionReconnectSupervisor(
                intervals: tmuxReconnectIntervals,
                probeDeadline: tmuxReconnectProbeDeadline
            ),
            verifiedPreviewIdentity: nil
        )
        presentation.reconnectExpectedIdentity = discoveredIdentity
        objectWillChange.send()
        retainedTmuxPresentations[key] = presentation
        retainedTmuxPresentationKeysByHandle[handle.id] = key
        borrowedTmuxConnectionStates[handle.id] = .connecting
        registerTmuxPreview(
            presentation,
            identityIsResolved: false
        )
        _ = acquireProtectedTmuxAttachmentScopeIfNeeded(
            for: presentation
        )
        if activatesPresentation {
            activateTmuxPresentation(presentation)
        }
        if effectiveLaunchMode == .create {
            transferPendingCreation(
                for: PendingTmuxSessionCreation(
                    request: WorkspaceTmuxSessionCreationRequest(
                        selection: selection,
                        initialCommand: initialCommand
                    ),
                    commandReplayAuthorized: false
                ),
                to: handle
            )
        }
        return handle
    }

    private func promoteAlwaysLiveManagedPresentation(
        _ presentation: RetainedTmuxPresentation,
        key: TmuxPresentationKey,
        navigationRevision: UInt64,
        resumesProvisioning: Bool = false
    ) {
        presentation.previewPromotionNavigationRevision = navigationRevision
        if !resumesProvisioning {
            presentation.pendingPreviewPromotionNavigationRevision =
                navigationRevision
        }
        pendingAlwaysLiveTmuxSurfaceHandleIDs.remove(presentation.handle.id)
        pendingAlwaysLiveTmuxSurfaceHandles.removeAll {
            $0.id == presentation.handle.id
        }
        guard presentation.previewPromotionTask == nil else { return }
        let promotionID = UUID()
        presentation.previewPromotionID = promotionID
        presentation.previewPromotionTask = Task { @MainActor [weak self, weak presentation] in
            guard let self, let presentation else { return }
            defer {
                if presentation.previewPromotionID == promotionID {
                    presentation.previewPromotionID = nil
                    presentation.previewPromotionTask = nil
                    let provisioningFinished = presentation
                        .pendingPreviewPromotionNavigationRevision != nil
                        && !nativeTmuxSessionCoordinator.isProvisioning(
                            presentation.handle
                        )
                    let restoredManagedPreview =
                        alwaysLiveManagedTmuxPresentationKeys.contains(key)
                            && !nativeTmuxSessionCoordinator.isProvisioning(
                                presentation.handle
                            )
                            && !nativeTmuxSessionCoordinator.hasLaunched(
                                presentation.handle
                            )
                    if resumesProvisioning || provisioningFinished
                        || restoredManagedPreview,
                        retainedTmuxPresentations[key] === presentation {
                        tmuxSurfaceBecameReady(presentation.handle)
                    }
                }
            }

            while !Task.isCancelled {
                var promotionResult: TmuxClientSizingTransitionResult
                repeat {
                    promotionResult = await nativeTmuxSessionCoordinator
                        .enableInteractiveSizing(for: presentation.handle)
                    guard !Task.isCancelled,
                          presentation.previewPromotionID == promotionID,
                          retainedTmuxPresentations[key] === presentation,
                          alwaysLiveManagedTmuxPresentationKeys.contains(key)
                    else { return }
                } while promotionResult == .stale
                switch promotionResult {
                case .applied:
                    presentation.pendingPreviewPromotionNavigationRevision = nil
                case .pending:
                    return
                case .stale:
                    return
                case let .failure(failure):
                    presentation.pendingPreviewPromotionNavigationRevision = nil
                    let retriesInteractiveAttachment =
                        presentation.previewPromotionNavigationRevision
                            == userNavigationRevision
                    let selection = presentation.selection
                    presentation.previewPromotionNavigationRevision = nil
                    excludeAlwaysLiveTmuxPresentation(
                        presentation,
                        key: key
                    )
                    AppLogger.shared.error(
                        "tmux preview promotion: "
                            + failure.localizedDescription,
                        context: "tmux"
                    )
                    if retriesInteractiveAttachment {
                        openBorrowedTmuxSession(selection)
                    }
                    return
                }

                if tmuxPresentationActivationIsPending(presentation) {
                    presentation.previewPromotionNavigationRevision = nil
                    activateTmuxPresentation(presentation)
                    alwaysLiveManagedTmuxPresentationKeys.remove(key)
                    pendingAlwaysLiveTmuxSurfaceHandleIDs.remove(
                        presentation.handle.id
                    )
                    pendingAlwaysLiveTmuxSurfaceHandles.removeAll {
                        $0.id == presentation.handle.id
                    }
                    return
                }

                presentation.previewPromotionNavigationRevision = nil
                if activeBorrowedTmuxHandle == presentation.handle {
                    alwaysLiveManagedTmuxPresentationKeys.remove(key)
                    pendingAlwaysLiveTmuxSurfaceHandleIDs.remove(
                        presentation.handle.id
                    )
                    pendingAlwaysLiveTmuxSurfaceHandles.removeAll {
                        $0.id == presentation.handle.id
                    }
                    return
                }
                var restoreResult: TmuxClientSizingTransitionResult
                repeat {
                    restoreResult = await nativeTmuxSessionCoordinator
                        .restorePreviewSizing(
                            previewGridSize(for: presentation.selection),
                            for: presentation.handle
                        )
                    guard !Task.isCancelled,
                          presentation.previewPromotionID == promotionID,
                          retainedTmuxPresentations[key] === presentation,
                          alwaysLiveManagedTmuxPresentationKeys.contains(key)
                    else { return }
                } while restoreResult == .stale
                if case let .failure(failure) = restoreResult {
                    excludeAlwaysLiveTmuxPresentation(
                        presentation,
                        key: key
                    )
                    AppLogger.shared.error(
                        "tmux preview sizing restore: "
                            + failure.localizedDescription,
                        context: "tmux"
                    )
                    return
                }
                if tmuxSessionPreviewCoordinator.mode != .alwaysLive,
                   activeBorrowedTmuxHandle != presentation.handle,
                   !tmuxPresentationActivationIsPending(presentation) {
                    invalidateBorrowedTmuxSession(presentation.selection)
                    return
                }
                guard presentation.previewPromotionNavigationRevision
                    == userNavigationRevision
                    || activeBorrowedTmuxHandle == presentation.handle
                    || tmuxPresentationActivationIsPending(presentation)
                else { return }
            }
        }
    }

    private func cancelPendingTmuxPreviewActivations() {
        for presentation in retainedTmuxPresentations.values {
            presentation.previewPromotionNavigationRevision = nil
        }
    }

    private func previewGridSize(
        for selection: WorkspaceTmuxSessionSelection
    ) -> TmuxGridSize? {
        let sessions = tmuxSessionsByHost[selection.hostID]
            ?? snapshot.host(id: selection.hostID)?.tmuxSessions
        return sessions?.first {
            $0.name == selection.name
        }?.previewClientSize
    }

    private func retainedTmuxPresentation(
        for handle: BorrowedTmuxSessionHandle
    ) -> RetainedTmuxPresentation? {
        retainedTmuxPresentationKeysByHandle[handle.id].flatMap {
            retainedTmuxPresentations[$0]
        }
    }

    private func retainedTmuxPresentation(
        for selection: WorkspaceTmuxSessionSelection
    ) -> RetainedTmuxPresentation? {
        retainedTmuxPresentations[TmuxPresentationKey(selection)]
    }

    private func registerTmuxPreview(
        _ presentation: RetainedTmuxPresentation,
        identityIsResolved: Bool = true
    ) {
        let key = TmuxPresentationKey(presentation.selection)
        tmuxSessionPreviewCoordinator.register(
            .init(
                key: key.previewKey,
                surface: { [weak self, weak presentation] in
                    guard let self, let presentation,
                          retainedTmuxPresentations[key] === presentation
                    else { return nil }
                    return protectedTmuxSurface(handle: presentation.handle)
                },
                handleID: { [weak presentation] in
                    presentation?.handle.id
                },
                generation: { [weak presentation] in
                    presentation?.selection.worktreeGeneration
                },
                identity: { [weak presentation] in
                    presentation?.verifiedPreviewIdentity
                },
                connectionState: { [weak self, weak presentation] in
                    guard let self, let presentation else { return nil }
                    return borrowedTmuxConnectionStates[presentation.handle.id]
                },
                hasLaunched: { [weak self, weak presentation] in
                    guard let self, let presentation else { return false }
                    return nativeTmuxSessionCoordinator.hasLaunched(
                        presentation.handle
                    )
                },
                isActive: { [weak self, weak presentation] in
                    guard let self, let presentation else { return false }
                    return activeBorrowedTmuxHandle == presentation.handle
                },
                activate: { [weak self, weak presentation] in
                    guard let self, let presentation,
                          retainedTmuxPresentations[key] === presentation
                    else { return }
                    commitTmuxPresentationActivation(presentation)
                },
                ensureIdentity: { [weak self, weak presentation] in
                    guard let self, let presentation else { return }
                    readTmuxPreviewIdentityIfNeeded(presentation)
                },
                refreshIdentity: { [weak self, weak presentation] in
                    guard let self, let presentation else { return nil }
                    return await revalidateTmuxPreviewIdentity(presentation)
                }
            ),
            identityIsResolved: identityIsResolved,
            identityIsUnavailable: presentation.previewIdentityUnavailable
        )
    }

    private func readTmuxPreviewIdentityIfNeeded(
        _ presentation: RetainedTmuxPresentation
    ) {
        let handleID = presentation.handle.id
        let key = TmuxPresentationKey(presentation.selection)
        guard retainedTmuxPresentations[key] === presentation,
              borrowedTmuxConnectionStates[handleID] == .connected
        else { return }
        if presentation.verifiedPreviewIdentity != nil,
           !presentation.previewIdentityUnavailable {
            registerTmuxPreview(presentation)
            return
        }
        switch nativeTmuxSessionCoordinator
            .attachedSessionIdentityResolution(presentation.handle) {
        case .pending:
            nativeTmuxSessionCoordinator.requestAttachedSessionIdentity(
                presentation.handle
            )
        case let .resolved(identity):
            presentation.previewIdentityUnavailable = false
            presentation.verifiedPreviewIdentity = identity
            presentation.reconnectExpectedIdentity = nil
            registerTmuxPreview(presentation, identityIsResolved: true)
        case .unavailable:
            presentation.previewIdentityUnavailable = true
            presentation.verifiedPreviewIdentity = nil
            registerTmuxPreview(
                presentation,
                identityIsResolved: false
            )
        }
    }

    func tmuxAttachedSessionIdentityBecameUnavailable(
        _ handle: BorrowedTmuxSessionHandle
    ) {
        guard let presentation = retainedTmuxPresentation(for: handle) else {
            return
        }
        if presentation.reconnectContext?.handleID == handle.id,
           let routeIdentity = nativeTmuxSessionCoordinator
           .attachmentRouteIdentity(handle) {
            presentation.reconnectContext?.routeIdentity = routeIdentity
        }
        let key = TmuxPresentationKey(presentation.selection)
        if alwaysLiveManagedTmuxPresentationKeys.contains(key) {
            excludeAlwaysLiveTmuxPresentation(presentation, key: key)
            return
        }
        readTmuxPreviewIdentityIfNeeded(presentation)
    }

    private func revalidateTmuxPreviewIdentity(
        _ presentation: RetainedTmuxPresentation
    ) async -> TmuxSessionIdentity? {
        let handle = presentation.handle
        let key = TmuxPresentationKey(presentation.selection)
        guard retainedTmuxPresentations[key] === presentation,
              borrowedTmuxConnectionStates[handle.id] == .connected,
              let expectedIdentity = presentation.verifiedPreviewIdentity
        else { return nil }
        guard let currentIdentity = await nativeTmuxSessionCoordinator
            .revalidateAttachedSessionIdentity(handle)
        else { return nil }
        guard retainedTmuxPresentations[key] === presentation,
              presentation.handle == handle,
              borrowedTmuxConnectionStates[handle.id] == .connected,
              presentation.verifiedPreviewIdentity == expectedIdentity
        else { return nil }
        guard currentIdentity == expectedIdentity else {
            // A managed hidden client that switched sessions must be
            // released, not just marked unavailable: clearing the verified
            // identity below would blind reconciliation to the mismatch and
            // leave the client attached under a permanently dead tile.
            // Exclusion records the expected identity, so a recreated
            // session gets one fresh attachment attempt.
            if alwaysLiveManagedTmuxPresentationKeys.contains(key) {
                excludeAlwaysLiveTmuxPresentation(
                    presentation,
                    key: key,
                    previewRemovalReason: .identityMismatch
                )
                return nil
            }
            presentation.previewIdentityUnavailable = true
            presentation.verifiedPreviewIdentity = nil
            registerTmuxPreview(
                presentation,
                identityIsResolved: false
            )
            return nil
        }
        return currentIdentity
    }

    private func beginTmuxPreviewReconnect(
        _ presentation: RetainedTmuxPresentation
    ) {
        if presentation.reconnectExpectedIdentity == nil {
            presentation.reconnectExpectedIdentity =
                presentation.verifiedPreviewIdentity
        }
        presentation.previewIdentityUnavailable = false
        presentation.verifiedPreviewIdentity = nil
        tmuxSessionPreviewCoordinator.remove(
            TmuxPresentationKey(presentation.selection).previewKey,
            reason: .reconnect
        )
    }

    private func prepareActiveTmuxPreviewForDeactivation() {
        guard let handle = activeBorrowedTmuxHandle,
              let presentation = retainedTmuxPresentation(for: handle)
        else { return }
        let key = TmuxPresentationKey(presentation.selection)
        tmuxSessionPreviewCoordinator.captureBeforeDeactivation(
            key.previewKey,
            completion: { [weak self, weak presentation] in
                Task { @MainActor in
                    await Task.yield()
                    guard let self, let presentation,
                          self.retainedTmuxPresentations[key] === presentation
                    else { return }
                    self.tmuxSessionPreviewCoordinator.finishDeactivation(
                        key.previewKey
                    )
                }
            }
        )
    }

    private func tmuxSurfaceBecameReady(
        _ handle: BorrowedTmuxSessionHandle
    ) {
        guard let presentation = retainedTmuxPresentation(for: handle) else {
            return
        }
        if presentation.reconnectContext?.handleID == handle.id,
           let routeIdentity = nativeTmuxSessionCoordinator
           .attachmentRouteIdentity(handle) {
            presentation.reconnectContext?.routeIdentity = routeIdentity
        }
        let key = TmuxPresentationKey(presentation.selection)
        // Resume a pending user promotion before the preview-support
        // filter: a session the user explicitly opened during provisioning
        // must become an ordinary interactive attachment even when the
        // resolved tmux version cannot host automatic previews. A stale
        // promotion restores preview sizing and re-drives readiness, so a
        // still-managed unsupported preview reaches the exclusion below.
        if let navigationRevision = presentation
            .pendingPreviewPromotionNavigationRevision {
            guard presentation.previewPromotionTask == nil else { return }
            presentation.pendingPreviewPromotionNavigationRevision = nil
            promoteAlwaysLiveManagedPresentation(
                presentation,
                key: key,
                navigationRevision: navigationRevision,
                resumesProvisioning: true
            )
            return
        }
        if alwaysLiveManagedTmuxPresentationKeys.contains(key),
           !nativeTmuxSessionCoordinator.supportsPaneSplitting(handle) {
            excludeAlwaysLiveTmuxPresentation(presentation, key: key)
            return
        }
        if alwaysLiveManagedTmuxPresentationKeys.contains(key),
           activeBorrowedTmuxHandle != handle,
           !nativeTmuxSessionCoordinator.hasLaunched(handle) {
            enqueueAlwaysLiveTmuxSurface(handle)
            return
        }
        finishTmuxSurfaceReadiness(handle)
    }

    private func excludeAlwaysLiveTmuxPresentation(
        _ presentation: RetainedTmuxPresentation,
        key: TmuxPresentationKey,
        previewRemovalReason: TmuxSessionPreviewCoordinator.RemovalReason =
            .replacement
    ) {
        if let identity = presentation.expectedPreviewIdentity {
            alwaysLiveIneligibleTmuxPresentationIdentities[key] = identity
        }
        invalidateBorrowedTmuxSession(
            presentation.selection,
            previewRemovalReason: previewRemovalReason
        )
    }

    private func enqueueAlwaysLiveTmuxSurface(
        _ handle: BorrowedTmuxSessionHandle
    ) {
        guard pendingAlwaysLiveTmuxSurfaceHandleIDs.insert(handle.id).inserted
        else { return }
        pendingAlwaysLiveTmuxSurfaceHandles.append(handle)
        startAlwaysLiveTmuxSurfaceLaunchIfNeeded()
    }

    private func startAlwaysLiveTmuxSurfaceLaunchIfNeeded() {
        guard canAttachToDisplay,
              !pendingAlwaysLiveTmuxSurfaceHandles.isEmpty,
              alwaysLiveTmuxSurfaceLaunchTask == nil
        else { return }
        let launchID = UUID()
        alwaysLiveTmuxSurfaceLaunchID = launchID
        alwaysLiveTmuxSurfaceLaunchTask = Task { @MainActor [weak self] in
            guard let self else { return }
            defer {
                if alwaysLiveTmuxSurfaceLaunchID == launchID {
                    alwaysLiveTmuxSurfaceLaunchTask = nil
                    alwaysLiveTmuxSurfaceLaunchID = nil
                }
            }
            while !Task.isCancelled,
                  canAttachToDisplay,
                  !pendingAlwaysLiveTmuxSurfaceHandles.isEmpty {
                let next = pendingAlwaysLiveTmuxSurfaceHandles.removeFirst()
                pendingAlwaysLiveTmuxSurfaceHandleIDs.remove(next.id)
                finishTmuxSurfaceReadiness(next)
                if !pendingAlwaysLiveTmuxSurfaceHandles.isEmpty {
                    do {
                        // Give AppKit a render opportunity between expensive
                        // libghostty surface creations for large fleets.
                        try await Task.sleep(for: .milliseconds(10))
                    } catch {
                        break
                    }
                }
            }
        }
    }

    private func finishTmuxSurfaceReadiness(
        _ handle: BorrowedTmuxSessionHandle
    ) {
        guard let presentation = retainedTmuxPresentation(for: handle),
              acquireProtectedTmuxAttachmentScopeIfNeeded(
                  for: presentation
              )
        else { return }
        _ = protectedTmuxSurface(handle: handle)
        tmuxSessionPreviewCoordinator.presentationDidChange(
            TmuxPresentationKey(presentation.selection).previewKey
        )
        readTmuxPreviewIdentityIfNeeded(presentation)
        if activeBorrowedTmuxHandle == handle {
            objectWillChange.send()
        }
    }

    private func protectedTmuxSurface(
        handle: BorrowedTmuxSessionHandle
    ) -> TerminalSurfaceView? {
        guard let presentation = retainedTmuxPresentation(for: handle) else {
            return nil
        }
        if let scope = protectedTmuxAttachmentScope(for: presentation),
           protectedTmuxAttachmentScopesByHandle[handle.id] != scope {
            return nil
        }
        return nativeTmuxSessionCoordinator.surface(handle: handle)
    }

    private func acquireProtectedTmuxAttachmentScopeIfNeeded(
        for presentation: RetainedTmuxPresentation
    ) -> Bool {
        let handleID = presentation.handle.id
        guard let scope = protectedTmuxAttachmentScope(for: presentation)
        else {
            pendingProtectedTmuxAttachmentScopesByHandle.removeValue(
                forKey: handleID
            )
            return true
        }
        if let acquired = protectedTmuxAttachmentScopesByHandle[handleID] {
            return acquired == scope
        }
        guard worktreeMutationCoordinator.acquire(
            hostID: scope.hostID,
            projectIdentity: scope.projectIdentity
        ) else {
            pendingProtectedTmuxAttachmentScopesByHandle[handleID] = scope
            return false
        }
        pendingProtectedTmuxAttachmentScopesByHandle.removeValue(
            forKey: handleID
        )
        protectedTmuxAttachmentScopesByHandle[handleID] = scope
        return true
    }

    private func protectedTmuxAttachmentScope(
        for presentation: RetainedTmuxPresentation
    ) -> WorktreeMutationCoordinator.Scope? {
        guard presentation.selection.tmuxAttachMode == .protected,
              presentation.reconnectContext?.phase == .establishingWorkspace,
              let worktreeID = presentation.selection.worktreeID,
              let worktree = snapshot.worktree(id: worktreeID),
              let project = snapshot.project(id: worktree.projectID),
              project.hostID == presentation.selection.hostID
        else { return nil }
        return WorktreeMutationCoordinator.Scope(
            hostID: project.hostID,
            projectIdentity: project.scopedKey
        )
    }

    private func releaseProtectedTmuxAttachmentScope(handleID: UUID) {
        pendingProtectedTmuxAttachmentScopesByHandle.removeValue(
            forKey: handleID
        )
        guard let scope = protectedTmuxAttachmentScopesByHandle.removeValue(
            forKey: handleID
        ) else { return }
        worktreeMutationCoordinator.release(
            hostID: scope.hostID,
            projectIdentity: scope.projectIdentity
        )
    }

    private func releaseAllProtectedTmuxAttachmentScopes() {
        let scopes = Array(protectedTmuxAttachmentScopesByHandle.values)
        protectedTmuxAttachmentScopesByHandle.removeAll()
        pendingProtectedTmuxAttachmentScopesByHandle.removeAll()
        for scope in scopes {
            worktreeMutationCoordinator.release(
                hostID: scope.hostID,
                projectIdentity: scope.projectIdentity
            )
        }
    }

    private var selectedWorktreeRemovalIsPending: Bool {
        guard let worktreeID = selection.selectedWorktreeID,
              let worktree = snapshot.worktree(id: worktreeID),
              let tmuxSelection = WorkspaceSidebarModel
              .tmuxSessionSelection(for: worktree)
        else { return false }
        return worktreeRemovalIsPending(for: tmuxSelection)
    }

    private func worktreeRemovalIsPending(
        for selection: WorkspaceTmuxSessionSelection
    ) -> Bool {
        guard let path = selection.workspacePath else { return false }
        return pendingWorktreeRemovals.contains { scope, tombstones in
            scope.hostID == selection.hostID
                && Self.removalTombstones(
                    tombstones,
                    matchPath: path,
                    generation: selection.worktreeGeneration
                )
        }
    }

    private func reconcileRetainedTmuxPresentations(
        afterAuthoritativeInventoryFor hostID: UUID
    ) {
        let invalidSelections: [WorkspaceTmuxSessionSelection] =
            retainedTmuxPresentations.values.compactMap { presentation in
                var retained = presentation.selection
                guard retained.hostID == hostID else { return nil }
                if let worktreeID = retained.worktreeID {
                    guard let worktree = snapshot.worktree(id: worktreeID),
                          worktree.hostID == hostID,
                          let current = WorkspaceSidebarModel
                          .tmuxSessionSelection(for: worktree),
                          Self.sameTmuxEndpoint(retained, current)
                    else { return retained }
                    if Self.hasDifferentKnownWorktreeGeneration(
                        retained,
                        current
                    ) {
                        return retained
                    }
                    if retained.worktreeGeneration == nil,
                       let canonicalGeneration = WorktreeGeneration.canonical(
                           current.worktreeGeneration
                       ) {
                        retained.worktreeGeneration = canonicalGeneration
                        presentation.selection = retained
                        if activeBorrowedTmuxHandle == presentation.handle {
                            activeBorrowedTmuxSelection = retained
                        }
                    }
                    return nil
                }
                if let directoryID = retained.directoryWorkspaceID {
                    guard let directory = snapshot.directoryWorkspace(
                        id: directoryID
                    ),
                        directory.hostID == hostID,
                        directory.path == retained.workspacePath,
                        Self.sameTmuxEndpoint(
                            retained,
                            WorkspaceSidebarModel.tmuxSessionSelection(
                                for: directory
                            )
                        )
                    else { return retained }
                }
                return nil
            }
        for invalidSelection in invalidSelections {
            if let worktreeID = invalidSelection.worktreeID,
               selection.selectedWorktreeID == worktreeID {
                explicitlyDismissedWorktreePresentationIDs.insert(worktreeID)
            }
            if let directoryID = invalidSelection.directoryWorkspaceID,
               selection.selectedDirectoryWorkspaceID == directoryID {
                explicitlyDismissedDirectoryPresentationIDs.insert(directoryID)
            }
            invalidateBorrowedTmuxSession(invalidSelection)
        }
        explicitlyDismissedWorktreePresentationIDs.formIntersection(
            Set(snapshot.worktrees.map(\.id))
        )
        explicitlyDismissedDirectoryPresentationIDs.formIntersection(
            Set(snapshot.directoryWorkspaces.map(\.id))
        )
    }

    private func closeRetainedTmuxPresentations(
        forWorktreeIDs worktreeIDs: Set<UUID>
    ) {
        guard !worktreeIDs.isEmpty else { return }
        let selections: [WorkspaceTmuxSessionSelection] =
            retainedTmuxPresentations.values.compactMap { presentation in
                guard let worktreeID = presentation.selection.worktreeID,
                      worktreeIDs.contains(worktreeID)
                else { return nil }
                return presentation.selection
            }
        for selection in selections {
            invalidateBorrowedTmuxSession(selection)
        }
    }

    private func activateTmuxPresentation(
        _ presentation: RetainedTmuxPresentation
    ) {
        let key = TmuxPresentationKey(presentation.selection)
        tmuxSessionPreviewCoordinator.prepareToActivate(
            key.previewKey,
            activate: { [weak self, weak presentation] in
                guard let self, let presentation,
                      retainedTmuxPresentations[key] === presentation
                else { return }
                commitTmuxPresentationActivation(presentation)
            }
        )
    }

    private func stageTmuxPresentationActivation(
        _ presentation: RetainedTmuxPresentation
    ) {
        if let activeHandle = activeBorrowedTmuxHandle,
           activeHandle != presentation.handle {
            prepareActiveTmuxPreviewForDeactivation()
        }
        activeBorrowedTmuxSelection = presentation.selection
        activeBorrowedTmuxHandle = nil
        activeBorrowedTmuxLaunchMode = presentation.launchMode
        activeBorrowedTmuxRecoveryState = presentation.recoveryState
        sessionConnectionRecoveryRequest = presentation.recoveryRequest
    }

    private func tmuxPresentationActivationIsPending(
        _ presentation: RetainedTmuxPresentation
    ) -> Bool {
        activeBorrowedTmuxSelection == presentation.selection
            && activeBorrowedTmuxHandle == nil
    }

    private func commitTmuxPresentationActivation(
        _ presentation: RetainedTmuxPresentation
    ) {
        if let activeHandle = activeBorrowedTmuxHandle,
           activeHandle != presentation.handle {
            prepareActiveTmuxPreviewForDeactivation()
        }
        activeBorrowedTmuxSelection = presentation.selection
        activeBorrowedTmuxHandle = presentation.handle
        activeBorrowedTmuxLaunchMode = presentation.launchMode
        activeBorrowedTmuxRecoveryState = presentation.recoveryState
        sessionConnectionRecoveryRequest = presentation.recoveryRequest
        applyDeferredTmuxPresentationIfReady(presentation)
    }

    private func publishActiveState(
        for presentation: RetainedTmuxPresentation
    ) {
        guard activeBorrowedTmuxHandle == presentation.handle else { return }
        activeBorrowedTmuxLaunchMode = presentation.launchMode
        activeBorrowedTmuxRecoveryState = presentation.recoveryState
        sessionConnectionRecoveryRequest = presentation.recoveryRequest
    }

    func hideBorrowedTmuxSession(
        _ selection: WorkspaceTmuxSessionSelection
    ) {
        guard activeBorrowedTmuxSelection == selection else { return }
        prepareActiveTmuxPreviewForDeactivation()
        activeBorrowedTmuxSelection = nil
        activeBorrowedTmuxHandle = nil
        activeBorrowedTmuxLaunchMode = nil
        activeBorrowedTmuxRecoveryState = nil
        sessionConnectionRecoveryRequest = nil
    }

    var retainedBorrowedTmuxPresentationCount: Int {
        retainedTmuxPresentations.count
    }

    var previewableTmuxSessionIDs: Set<String> {
        Set(retainedTmuxPresentations.keys.map(\.sessionID))
    }

    private func refreshConnectedBorrowedTmuxSessionIDs() {
        let connected = Set(
            retainedTmuxPresentations.compactMap { key, presentation in
                borrowedTmuxConnectionStates[presentation.handle.id] == .connected
                    ? key.sessionID : nil
            }
        )
        guard connected != connectedBorrowedTmuxSessionIDs else { return }
        connectedBorrowedTmuxSessionIDs = connected
    }

    func retainedBorrowedTmuxHandle(
        for selection: WorkspaceTmuxSessionSelection
    ) -> BorrowedTmuxSessionHandle? {
        retainedTmuxPresentation(for: selection)?.handle
    }

    func retainedBorrowedTmuxSessionIsConnected(
        _ selection: WorkspaceTmuxSessionSelection
    ) -> Bool {
        guard let handle = retainedTmuxPresentation(for: selection)?.handle
        else { return false }
        return borrowedTmuxConnectionStates[handle.id] == .connected
    }

    private static func sameTmuxSession(
        _ lhs: WorkspaceTmuxSessionSelection,
        _ rhs: WorkspaceTmuxSessionSelection
    ) -> Bool {
        sameTmuxEndpoint(lhs, rhs)
            && lhs.worktreeGeneration == rhs.worktreeGeneration
    }

    private static func hasDifferentKnownWorktreeGeneration(
        _ lhs: WorkspaceTmuxSessionSelection,
        _ rhs: WorkspaceTmuxSessionSelection
    ) -> Bool {
        guard lhs.worktreeID != nil,
              lhs.worktreeID == rhs.worktreeID,
              let lhsGeneration = lhs.worktreeGeneration,
              let rhsGeneration = rhs.worktreeGeneration
        else { return false }
        return lhsGeneration != rhsGeneration
    }

    /// Kill targets a live tmux endpoint; inventory can change the owning
    /// worktree generation while that endpoint keeps running, so kill
    /// probing and cleanup must not compare generations.
    private static func sameTmuxEndpoint(
        _ lhs: WorkspaceTmuxSessionSelection,
        _ rhs: WorkspaceTmuxSessionSelection
    ) -> Bool {
        lhs.hostID == rhs.hostID
            && lhs.name == rhs.name
            && lhs.socketName == rhs.socketName
            && lhs.tmuxAttachMode == rhs.tmuxAttachMode
    }

    private func transferPendingCreation(
        for pendingCreation: PendingTmuxSessionCreation,
        to handle: BorrowedTmuxSessionHandle
    ) {
        let request = pendingCreation.request
        let previousHandleIDs = pendingCreatedTmuxSessions.compactMap {
            handleID, pending in
            Self.sameTmuxSession(pending.selection, request.selection)
                ? handleID
                : nil
        }
        guard !previousHandleIDs.isEmpty,
              !previousHandleIDs.contains(handle.id) else { return }
        let retainedCommand = request.initialCommand
            ?? previousHandleIDs.lazy.compactMap {
                self.pendingCreatedTmuxSessions[$0]?.initialCommand
            }.first
        for handleID in previousHandleIDs {
            createdSessionDiscoveryTasks.removeValue(
                forKey: handleID
            )?.cancel()
            exhaustedCreatedTmuxSessionHandles.remove(handleID)
            endedCreatedTmuxSessionHandles.remove(handleID)
            pendingCreatedTmuxSessions.removeValue(forKey: handleID)
            borrowedTmuxConnectionStates.removeValue(forKey: handleID)
        }
        pendingCreatedTmuxSessions[handle.id] =
            PendingTmuxSessionCreation(
                request: WorkspaceTmuxSessionCreationRequest(
                    selection: request.selection,
                    initialCommand: retainedCommand
                ),
                commandReplayAuthorized:
                pendingCreation.commandReplayAuthorized
            )
    }

    func closeBorrowedTmuxSession(_ selection: WorkspaceTmuxSessionSelection) {
        cancelPendingRestoration()
        closeBorrowedTmuxSession(
            selection,
            recordsExplicitDismissal: true,
            previewRemovalReason: .close
        )
    }

    private func invalidateBorrowedTmuxSession(
        _ selection: WorkspaceTmuxSessionSelection,
        previewRemovalReason: TmuxSessionPreviewCoordinator.RemovalReason =
            .replacement
    ) {
        closeBorrowedTmuxSession(
            selection,
            recordsExplicitDismissal: false,
            previewRemovalReason: previewRemovalReason
        )
    }

    private func closeBorrowedTmuxSession(
        _ selection: WorkspaceTmuxSessionSelection,
        recordsExplicitDismissal: Bool,
        previewRemovalReason: TmuxSessionPreviewCoordinator.RemovalReason
    ) {
        if recordsExplicitDismissal, let worktreeID = selection.worktreeID {
            explicitlyDismissedWorktreePresentationIDs.insert(worktreeID)
        }
        if recordsExplicitDismissal,
           let directoryID = selection.directoryWorkspaceID {
            explicitlyDismissedDirectoryPresentationIDs.insert(directoryID)
        }
        let key = TmuxPresentationKey(selection)
        if recordsExplicitDismissal,
           tmuxSessionPreviewCoordinator.mode == .alwaysLive,
           let identity = retainedTmuxPresentations[key]?
           .expectedPreviewIdentity {
            alwaysLiveIneligibleTmuxPresentationIdentities[key] = identity
        }
        alwaysLiveManagedTmuxPresentationKeys.remove(key)
        retainedTmuxPresentations[key]?.previewPromotionID = nil
        retainedTmuxPresentations[key]?
            .previewPromotionNavigationRevision = nil
        retainedTmuxPresentations[key]?.previewPromotionTask?.cancel()
        retainedTmuxPresentations[key]?.previewPromotionTask = nil
        if activeBorrowedTmuxSelection == selection {
            prepareActiveTmuxPreviewForDeactivation()
        }
        if retainedTmuxPresentations[key] != nil {
            objectWillChange.send()
        }
        guard let presentation = retainedTmuxPresentations.removeValue(
            forKey: key
        ) else {
            guard activeBorrowedTmuxSelection == selection else { return }
            if let handle = activeBorrowedTmuxHandle {
                releaseProtectedTmuxAttachmentScope(handleID: handle.id)
            }
            activeBorrowedTmuxSelection = nil
            activeBorrowedTmuxHandle = nil
            activeBorrowedTmuxLaunchMode = nil
            activeBorrowedTmuxRecoveryState = nil
            sessionConnectionRecoveryRequest = nil
            return
        }
        let handle = presentation.handle
        tmuxSessionPreviewCoordinator.remove(
            key.previewKey,
            reason: previewRemovalReason
        )
        releaseProtectedTmuxAttachmentScope(handleID: handle.id)
        retainedTmuxPresentationKeysByHandle.removeValue(forKey: handle.id)
        cancelTmuxReconnect(presentation)
        cancelTmuxPresentationTasks(handleID: handle.id)
        tmuxActivityEnrollmentTasks.removeValue(
            forKey: handle.id
        )?.cancel()
        confirmedEndedTmuxSessionHandles.remove(handle.id)
        borrowedTmuxConnectionStates.removeValue(forKey: handle.id)
        if var pending = pendingCreatedTmuxSessions[handle.id] {
            if nativeTmuxSessionCoordinator.hasLaunched(handle) {
                pending.commandReplayAuthorized = false
                pendingCreatedTmuxSessions[handle.id] = pending
                endedCreatedTmuxSessionHandles.insert(handle.id)
                reconcileCreatedTmuxSession(
                    handleID: handle.id,
                    immediately: true
                )
            } else if recordsExplicitDismissal
                || pending.initialCommand == nil {
                discardPendingTmuxSession(handleID: handle.id)
            }
        }
        if activeBorrowedTmuxHandle == handle {
            activeBorrowedTmuxSelection = nil
            activeBorrowedTmuxHandle = nil
            activeBorrowedTmuxLaunchMode = nil
            activeBorrowedTmuxRecoveryState = nil
            sessionConnectionRecoveryRequest = nil
        }
        nativeTmuxSessionCoordinator.detach(
            hostID: presentation.selection.hostID,
            name: presentation.selection.name,
            socketName: presentation.selection.socketName,
            tmuxAttachMode: presentation.selection.tmuxAttachMode
        )
    }

    func prepareTmuxSessionKill(
        _ selection: WorkspaceTmuxSessionSelection
    ) async throws -> TmuxSessionKillRequest {
        guard let currentHostSummary = snapshot.host(id: selection.hostID),
              let currentHost = CommandHostResolver.resolve(currentHostSummary)
        else {
            throw TmuxSessionKillError.hostChanged(
                session: selection.name
            )
        }

        let discoveredIdentity = Self.discoveredTmuxSessionIdentity(
            selection,
            hostSummary: currentHostSummary
        )
        guard discoveredIdentity != nil
            || isConnectedActiveTmuxSession(selection)
        else {
            throw TmuxSessionKillError.sessionNotRunning(
                host: currentHost.displayName,
                session: selection.name
            )
        }
        let review = try await tmuxSessionIdentityReviewer(
            selection,
            discoveredIdentity,
            currentHost
        )

        return TmuxSessionKillRequest(
            session: selection,
            confirmedHost: currentHostSummary,
            serverPID: review.identity.serverPID,
            sessionID: review.identity.sessionID,
            sessionCreatedAt: review.identity.createdAt,
            routeIdentity: review.routeIdentity
        )
    }

    func killTmuxSession(
        _ request: TmuxSessionKillRequest
    ) async throws {
        let tmuxSelection = request.session
        guard request.confirmedHost.id == tmuxSelection.hostID,
              let confirmedHost = CommandHostResolver.resolve(
                  request.confirmedHost
              ),
              let currentHostSummary = snapshot.host(
                  id: tmuxSelection.hostID
              ),
              let currentHost = CommandHostResolver.resolve(
                  currentHostSummary
              ),
              currentHost == confirmedHost
        else {
            throw TmuxSessionKillError.hostChanged(
                session: tmuxSelection.name
            )
        }
        try await tmuxSessionKiller(
            tmuxSelection,
            TmuxSessionIdentity(
                serverPID: request.serverPID,
                sessionID: request.sessionID,
                createdAt: request.sessionCreatedAt
            ),
            request.routeIdentity,
            confirmedHost
        )

        let activeTargetAfterKill = activeBorrowedTmuxSelection.flatMap {
            Self.sameTmuxEndpoint($0, tmuxSelection) ? $0 : nil
        }
        if let retainedTarget = retainedTmuxPresentations.values.first(
            where: {
                Self.sameTmuxEndpoint($0.selection, tmuxSelection)
            }
        )?.selection {
            invalidateBorrowedTmuxSession(retainedTarget)
        }
        if tmuxSelection.socketName == nil {
            tmuxSessionsByHost[tmuxSelection.hostID]?.removeAll {
                $0.name == tmuxSelection.name
            }
            applyInventoryOverlayIfNeeded()
            updateWorkspaceInventoryState()
        }
        if activeTargetAfterKill != nil {
            selection.select(
                .host(tmuxSelection.hostID),
                in: snapshot,
                visibility: worktreeVisibility
            )
        }
        refreshKwtInventory()
    }

    func applyTheme(
        to selection: WorkspaceTmuxSessionSelection
    ) async throws {
        guard let activeSelection = activeBorrowedTmuxSelection,
              Self.sameTmuxSession(activeSelection, selection),
              isConnectedActiveTmuxSession(activeSelection),
              let hostSummary = snapshot.host(id: activeSelection.hostID),
              let host = CommandHostResolver.resolve(hostSummary),
              Self.supportsTmuxSessionStyling(host),
              let activeHandle = activeBorrowedTmuxHandle,
              let style = tmuxPresentationStyleProvider(
                  nativeTmuxSessionCoordinator.surfaceIdentity(
                      handle: activeHandle
                  )
              )
        else {
            throw TmuxSessionThemeError.unavailable(
                session: selection.name
            )
        }
        // A deferred ladder in flight would race this manual choice and could
        // land last with older colors. Supersede it and wait it out first.
        // Claim the deferred marker before suspending so no trigger during
        // this apply can start a concurrent ladder; the user has taken manual
        // control, and on failure the manual action is its own recovery path.
        nativeTmuxSessionCoordinator.markDeferredPresentationStyleApplied(
            activeHandle
        )
        cancelTmuxPresentationTasks(handleID: activeHandle.id)
        // Manual applies join the same drain chain as deferred ladders: any
        // concurrent manual or deferred successor awaits this operation, so a
        // slower older command can never land after newer colors.
        let handleID = activeHandle.id
        let predecessor = drainingDeferredTmuxPresentationTasks[handleID]
        let discoveredIdentity = Self.discoveredTmuxSessionIdentity(
            activeSelection,
            hostSummary: hostSummary
        )
        let identityReader = tmuxSessionIdentityReader
        let styler = tmuxSessionStyler
        let styling = Task { [weak self] () -> Error? in
            await self?.settleSupersededTmuxPresentationTask(
                predecessor,
                handleID: handleID
            )
            do {
                let expectedIdentity = if let discoveredIdentity {
                    discoveredIdentity
                } else {
                    try await identityReader(activeSelection, host)
                }
                try await styler(style, activeSelection, expectedIdentity, host)
                return nil
            } catch {
                return error
            }
        }
        let chained = Task { _ = await styling.value }
        drainingDeferredTmuxPresentationTasks[handleID] = chained
        let stylingError = await styling.value
        if drainingDeferredTmuxPresentationTasks[handleID] == chained {
            drainingDeferredTmuxPresentationTasks.removeValue(
                forKey: handleID
            )
        }
        if let stylingError {
            throw stylingError
        }
    }

    private static func discoveredTmuxSessionIdentity(
        _ selection: WorkspaceTmuxSessionSelection,
        hostSummary: HostSummary
    ) -> TmuxSessionIdentity? {
        guard selection.socketName == nil,
              let summary = hostSummary.tmuxSessions.first(where: {
                  $0.name == selection.name
              })
        else { return nil }
        return tmuxSessionIdentity(summary)
    }

    private static func tmuxSessionIdentity(
        _ summary: TmuxSessionSummary
    ) -> TmuxSessionIdentity? {
        guard summary.hasStableIdentity,
              let serverPID = summary.serverPID,
              let sessionID = summary.sessionID,
              let createdAt = summary.createdAt
        else { return nil }
        return TmuxSessionIdentity(
            serverPID: serverPID,
            sessionID: sessionID,
            createdAt: createdAt
        )
    }

    private static func supportsTmuxSessionStyling(
        _ host: CommandHost
    ) -> Bool {
        if case let .ssh(info) = host, info.platform == .windows {
            return false
        }
        return true
    }

    private func isConnectedActiveTmuxSession(
        _ selection: WorkspaceTmuxSessionSelection
    ) -> Bool {
        guard let activeSelection = activeBorrowedTmuxSelection,
              Self.sameTmuxEndpoint(activeSelection, selection),
              let activeHandle = activeBorrowedTmuxHandle
        else {
            return false
        }
        return borrowedTmuxConnectionStates[activeHandle.id] == .connected
    }

    private func nativeTmuxStateChanged(
        handle: BorrowedTmuxSessionHandle,
        state: ConnectionState
    ) {
        let previousState = borrowedTmuxConnectionStates[handle.id]
        switch state {
        case .disconnected:
            releaseProtectedTmuxAttachmentScope(handleID: handle.id)
        case .connecting, .connected, .reconnecting:
            break
        }
        borrowedTmuxConnectionStates[handle.id] = state
        guard let presentation = retainedTmuxPresentation(for: handle) else {
            return
        }
        let key = TmuxPresentationKey(presentation.selection)
        if case .disconnected = state,
           alwaysLiveManagedTmuxPresentationKeys.contains(key),
           !nativeTmuxSessionCoordinator.hasLaunched(handle),
           nativeTmuxSessionCoordinator.attachmentClosure(handle)
           != .surfaceUnavailable,
           nativeTmuxSessionCoordinator.attachmentClosure(handle)
           != .retryableTransportFailure {
            // Identity exclusion is for permanent launch and setup failures.
            // A retryable surface failure (for example the display vanished
            // during creation) keeps the policy-owned presentation so
            // reconciliation can relaunch it once a display returns.
            excludeAlwaysLiveTmuxPresentation(presentation, key: key)
            return
        }
        if case .disconnected = state {
            beginTmuxPreviewReconnect(presentation)
        } else if case .reconnecting = state {
            if previousState == .connected {
                beginTmuxPreviewReconnect(presentation)
            }
        }
        if state == .connected {
            confirmedEndedTmuxSessionHandles.remove(handle.id)
            presentation.recoveryState = nil
            presentation.recoveryRequest = nil
            if presentation.reconnectContext?.handleID == handle.id {
                presentation.reconnectContext?.routeIdentity =
                    nativeTmuxSessionCoordinator
                        .attachmentRouteIdentity(handle)
                presentation.reconnectContext?.surfaceExitCode = nil
                // Belt and braces: relaunch already rebuilds the context, but
                // clearing here keeps "only the attempt that failed may skip
                // the exit-code check" true regardless of that path.
                presentation.reconnectContext?.surfaceLaunchFailed = false
                startEstablishmentConfirmationIfNeeded(
                    presentation: presentation
                )
            }
            warmConnectedTmuxSession(handle: handle)
            publishActiveState(for: presentation)
            applyDeferredTmuxPresentationIfReady(presentation)
            registerTmuxPreview(
                presentation,
                identityIsResolved:
                presentation.verifiedPreviewIdentity != nil
            )
        } else {
            tmuxActivityEnrollmentTasks.removeValue(
                forKey: handle.id
            )?.cancel()
        }
        if case .disconnected = state,
           nativeTmuxSessionCoordinator.attachmentClosure(handle)
           == .retryableTransportFailure,
           var context = presentation.reconnectContext,
           context.handleID == handle.id {
            // SSH failed before the tmux client could start, so retrying the
            // original attachment cannot replay remote client side effects.
            context.surfaceLaunchFailed = true
            presentation.reconnectContext = context
            startTmuxReconnect(presentation, context: context)
            return
        }
        if case .disconnected = state,
           presentation.recoveryState != nil,
           nativeTmuxSessionCoordinator.attachmentClosure(handle)
           == .surfaceUnavailable,
           var context = presentation.reconnectContext,
           context.handleID == handle.id {
            // The surface could not be created, which is transient. Re-arm
            // recovery behind its configured delay instead of immediately
            // relaunching another surface.
            context.surfaceLaunchFailed = true
            presentation.reconnectContext = context
            startTmuxReconnect(
                presentation,
                context: context,
                waitBeforeFirstAttempt: true
            )
            return
        }
        if case .disconnected = state,
           presentation.recoveryState != nil,
           nativeTmuxSessionCoordinator.attachmentClosure(handle)
           == .launchFailed {
            cancelTmuxReconnect(presentation)
            return
        }
        if case .disconnected = state,
           nativeTmuxSessionCoordinator.hasLaunched(handle) {
            cancelTmuxPresentationTasks(handleID: handle.id)
            if var context = presentation.reconnectContext,
               context.handleID == handle.id,
               context.host.isRemote,
               case let .processExited(code) =
               nativeTmuxSessionCoordinator.attachmentClosure(handle) {
                presentation.establishmentConfirmationTask?.cancel()
                presentation.establishmentConfirmationTask = nil
                if code == 127, context.usesKwtWorkspaceCommand {
                    markRemoteKwtUnavailable(
                        hostID: context.selection.hostID
                    )
                }
                context.surfaceExitCode = code
                presentation.reconnectContext = context
                startTmuxReconnect(presentation, context: context)
                return
            }
            scheduleTmuxSessionDiscovery()
        }
        guard var pending = pendingCreatedTmuxSessions[handle.id] else {
            return
        }
        switch state {
        case .connected:
            reconcileCreatedTmuxSession(handleID: handle.id)
        case .disconnected:
            guard nativeTmuxSessionCoordinator.hasLaunched(handle) else {
                if pending.initialCommand != nil {
                    pending.commandReplayAuthorized = true
                    pendingCreatedTmuxSessions[handle.id] = pending
                } else {
                    discardPendingTmuxSession(handleID: handle.id)
                }
                return
            }
            pending.commandReplayAuthorized = false
            pendingCreatedTmuxSessions[handle.id] = pending
            endedCreatedTmuxSessionHandles.insert(handle.id)
            reconcileCreatedTmuxSession(
                handleID: handle.id,
                immediately: true
            )
        case .connecting, .reconnecting:
            break
        }
    }

    private func nativeHerdrStateChanged(
        handle: BorrowedHerdrSessionHandle,
        state: ConnectionState
    ) {
        guard !isShutDown else { return }
        borrowedHerdrConnectionStates[handle.id] = state
        if var pending = pendingHerdrLaunchOperations[handle.id] {
            switch state {
            case .connected:
                guard let authority = nativeHerdrSessionCoordinator
                    .attachmentAuthority(handle),
                    authority.launchMode == .launchOrAttach
                else {
                    finishPendingHerdrLaunch(
                        handleID: handle.id,
                        operation: pending.operation,
                        outcome: .failed
                    )
                    scheduleHerdrSessionDiscovery()
                    return
                }
                pending.authority = authority
                pendingHerdrLaunchOperations[handle.id] = pending
                confirmHerdrLaunch(
                    handle: handle,
                    operation: pending.operation,
                    authority: authority
                )
            case .disconnected:
                herdrLaunchConfirmationTasks.removeValue(
                    forKey: handle.id
                )?.cancel()
                pendingHerdrLaunchOperations.removeValue(forKey: handle.id)
                herdrLifecycleCoordinator.finish(
                    pending.operation,
                    outcome: .failed
                )
                if activeBorrowedHerdrHandle == handle {
                    failedHerdrLaunchIntent = FailedHerdrLaunchIntent(
                        selection: WorkspaceHerdrSessionSelection(
                            hostID: pending.operation.key.hostID,
                            name: pending.operation.key.sessionName
                        ),
                        kind: pending.operation.kind
                    )
                }
            case .connecting, .reconnecting:
                break
            }
        }
        guard activeBorrowedHerdrHandle == handle else { return }
        if state == .connected {
            activeBorrowedHerdrRecoveryState = nil
            sessionConnectionRecoveryRequest = nil
            activeHerdrReconnectContext?.surfaceExitCode = nil
            activeHerdrReconnectContext?.surfaceLaunchFailed = false
            return
        }
        guard case .disconnected = state else { return }
        if suppressedHerdrStops.values.contains(where: {
            $0.selection.hostID == handle.hostID
                && $0.selection.name == handle.name
        }) {
            return
        }
        if nativeHerdrSessionCoordinator.attachmentClosure(handle)
            == .retryableTransportFailure,
            var context = activeHerdrReconnectContext,
            context.handleID == handle.id {
            context.surfaceLaunchFailed = true
            activeHerdrReconnectContext = context
            startHerdrReconnect(context)
            return
        }
        // Checked before `hasLaunched`: a surface that failed to be created
        // never launched, so the guard below would drop this transient failure
        // and the session would latch. See the tmux path.
        if nativeHerdrSessionCoordinator.attachmentClosure(handle)
            == .surfaceUnavailable,
            var context = activeHerdrReconnectContext,
            context.handleID == handle.id {
            context.surfaceLaunchFailed = true
            activeHerdrReconnectContext = context
            startHerdrReconnect(context)
            return
        }
        if activeBorrowedHerdrRecoveryState != nil,
           nativeHerdrSessionCoordinator.attachmentClosure(handle)
           == .launchFailed {
            cancelHerdrReconnect()
            return
        }
        guard nativeHerdrSessionCoordinator.hasLaunched(handle) else { return }
        switch nativeHerdrSessionCoordinator.attachmentClosure(handle) {
        case .detached:
            cancelHerdrReconnect()
            refreshHerdrInventory(hostID: handle.hostID)
        case let .processExited(code):
            guard var context = activeHerdrReconnectContext,
                  context.handleID == handle.id,
                  context.host.isRemote,
                  code == 255
            else {
                cancelHerdrReconnect()
                refreshHerdrInventory(hostID: handle.hostID)
                return
            }
            context.surfaceExitCode = code
            activeHerdrReconnectContext = context
            startHerdrReconnect(context)
        case .retryableTransportFailure, .surfaceUnavailable:
            // Recoverable failures are re-armed above, before `hasLaunched`.
            // Reaching here means no matching reconnect context survives.
            cancelHerdrReconnect()
        case .launchFailed, nil:
            cancelHerdrReconnect()
        }
    }

    private func nativeZellijStateChanged(
        handle: BorrowedZellijSessionHandle,
        state: ConnectionState
    ) {
        guard !isShutDown else { return }
        borrowedZellijConnectionStates[handle.id] = state
        guard activeBorrowedZellijHandle == handle else { return }
        switch state {
        case .connected:
            zellijReconnectSupervisor.cancel()
            activeBorrowedZellijRecoveryState = nil
            if failedZellijCreationIntent
                == activeBorrowedZellijSelection {
                failedZellijCreationIntent = nil
            }
            if var context = activeZellijReconnectContext,
               context.handleID == handle.id {
                context.surfaceExitCode = nil
                context.surfaceLaunchFailed = false
                activeZellijReconnectContext = context
            }
            sessionConnectionRecoveryRequest = nil
            scheduleZellijSessionDiscovery()
        case .disconnected:
            if nativeZellijSessionCoordinator.attachmentClosure(handle)
                == .retryableTransportFailure,
                var context = activeZellijReconnectContext,
                context.handleID == handle.id {
                context.surfaceLaunchFailed = true
                activeZellijReconnectContext = context
                startZellijReconnect(context)
                return
            }
            // Checked before `hasLaunched`: a surface that failed to be created
            // never launched, so the guard below would drop this transient
            // failure and the session would latch. See the tmux path.
            if nativeZellijSessionCoordinator.attachmentClosure(handle)
                == .surfaceUnavailable,
                var context = activeZellijReconnectContext,
                context.handleID == handle.id {
                context.surfaceLaunchFailed = true
                activeZellijReconnectContext = context
                startZellijReconnect(context)
                return
            }
            guard nativeZellijSessionCoordinator.hasLaunched(handle) else {
                if let selection = pendingCreatedZellijSessions
                    .removeValue(forKey: handle.id) {
                    failedZellijCreationIntent = selection
                    zellijSessionsByHost[selection.hostID] = snapshot
                        .host(id: selection.hostID)?
                        .zellijSessions.filter {
                            $0.name != selection.name
                        } ?? []
                    applyRuntimeInventoryOverlayIfNeeded(
                        hostID: selection.hostID
                    )
                }
                zellijReconnectSupervisor.cancel()
                activeBorrowedZellijRecoveryState = nil
                return
            }
            switch nativeZellijSessionCoordinator.attachmentClosure(handle) {
            case .detached:
                pendingCreatedZellijSessions.removeValue(forKey: handle.id)
                zellijReconnectSupervisor.cancel()
                activeBorrowedZellijRecoveryState = nil
                scheduleZellijSessionDiscovery()
            case let .processExited(code):
                guard var context = activeZellijReconnectContext,
                      context.handleID == handle.id,
                      context.host.isRemote,
                      code == 255
                else {
                    if let selection = pendingCreatedZellijSessions
                        .removeValue(forKey: handle.id) {
                        failedZellijCreationIntent = selection
                    }
                    zellijReconnectSupervisor.cancel()
                    activeBorrowedZellijRecoveryState = nil
                    scheduleZellijSessionDiscovery()
                    return
                }
                context.surfaceExitCode = code
                activeZellijReconnectContext = context
                startZellijReconnect(context)
            case .retryableTransportFailure, .surfaceUnavailable:
                // Recoverable failures are re-armed above, before
                // `hasLaunched`. Reaching here means no matching reconnect
                // context survives.
                fallthrough
            case .launchFailed, nil:
                if let selection = pendingCreatedZellijSessions
                    .removeValue(forKey: handle.id) {
                    failedZellijCreationIntent = selection
                }
                zellijReconnectSupervisor.cancel()
                activeBorrowedZellijRecoveryState = nil
                scheduleZellijSessionDiscovery()
            }
        case .connecting, .reconnecting:
            break
        }
    }

    private func startZellijReconnect(
        _ context: ActiveZellijReconnectContext
    ) {
        guard !isShutDown,
              activeZellijReconnectContext == context,
              activeBorrowedZellijHandle?.id == context.handleID,
              !zellijSessionKillCoordinator.isPending(.init(
                  hostID: context.selection.hostID,
                  sessionName: context.selection.name
              ))
        else { return }
        let message = "Waiting for \(hostName(for: context.selection.hostID)). "
            + "Ghosthub will reconnect automatically."
        activeBorrowedZellijRecoveryState = .reconnecting(message: message)
        borrowedZellijConnectionStates[context.handleID] = .reconnecting(
            reason: message
        )
        sessionConnectionRecoveryRequest = nil
        zellijReconnectSupervisor.start { [weak self] in
            guard let self else { return .stop }
            return await attemptZellijReconnect(context)
        }
    }

    private func attemptZellijReconnect(
        _ context: ActiveZellijReconnectContext
    ) async -> SessionReconnectDecision {
        guard activeZellijReconnectContext == context,
              activeBorrowedZellijHandle?.id == context.handleID
        else { return .stop }
        guard canAttachToDisplay else { return .retry }
        let connection = await zellijConnectionSnapshot(on: context.host)
        if let routeIdentity = connection.routeIdentity,
           routeIdentity != context.routeIdentity {
            stopZellijReconnect(
                "The SSH connection changed while Ghosthub was checking the Zellij session. Reopen it to use the current connection."
            )
            return .stop
        }
        let result = await zellijSessionValidationDiscovery(
            context.host,
            connection.arguments
        )
        let after = await zellijConnectionSnapshot(on: context.host)
        guard !Task.isCancelled else { return .retry }
        guard activeZellijReconnectContext == context,
              activeBorrowedZellijHandle?.id == context.handleID,
              snapshot.host(id: context.selection.hostID)
              .flatMap(CommandHostResolver.resolve) == context.host
        else { return .stop }
        if connection.routeIdentity != nil {
            guard let routeIdentity = after.routeIdentity else {
                return .retry
            }
            guard routeIdentity == context.routeIdentity else {
                stopZellijReconnect(
                    "The SSH connection changed while Ghosthub was checking the Zellij session. Reopen it to use the current connection."
                )
                return .stop
            }
        }
        let executablePath: String?
        if case .available = result {
            guard !Task.isCancelled else { return .retry }
            let resolver = zellijExecutableResolver
            let probe = Task.detached(priority: .userInitiated) {
                resolver(context.host, connection.arguments)
            }
            let resolution = await withTaskCancellationHandler {
                await probe.value
            } onCancel: {
                probe.cancel()
            }
            guard !Task.isCancelled else { return .retry }
            guard activeZellijReconnectContext == context,
                  activeBorrowedZellijHandle?.id == context.handleID,
                  snapshot.host(id: context.selection.hostID)
                  .flatMap(CommandHostResolver.resolve) == context.host
            else { return .stop }
            let finalConnection = await zellijConnectionSnapshot(
                on: context.host
            )
            guard !Task.isCancelled else { return .retry }
            guard activeZellijReconnectContext == context,
                  activeBorrowedZellijHandle?.id == context.handleID,
                  snapshot.host(id: context.selection.hostID)
                  .flatMap(CommandHostResolver.resolve) == context.host
            else { return .stop }
            if connection.routeIdentity != nil {
                guard let routeIdentity = finalConnection.routeIdentity else {
                    return .retry
                }
                guard routeIdentity == context.routeIdentity else {
                    stopZellijReconnect(
                        "The SSH connection changed while Ghosthub was checking the Zellij session. Reopen it to use the current connection."
                    )
                    return .stop
                }
            }
            switch resolution {
            case let .success(path):
                executablePath = path
            case let .failure(error):
                if SSHConnectionFailure.indicatesUnusableConnection(error) {
                    await connection.invalidate()
                }
                return zellijReconnectDecision(
                    for: context,
                    result: .failure(error),
                    connection: connection,
                    executablePath: nil
                )
            }
        } else {
            executablePath = nil
        }
        if case let .failure(error) = result,
           SSHConnectionFailure.indicatesUnusableConnection(error) {
            await connection.invalidate()
        }
        return zellijReconnectDecision(
            for: context,
            result: result,
            connection: connection,
            executablePath: executablePath
        )
    }

    private func zellijReconnectDecision(
        for context: ActiveZellijReconnectContext,
        result: ZellijDiscoveryResult,
        connection: SSHConnectionArgumentsSnapshot,
        executablePath: String?
    ) -> SessionReconnectDecision {
        guard !Task.isCancelled else { return .retry }
        guard activeZellijReconnectContext == context,
              activeBorrowedZellijHandle?.id == context.handleID,
              !zellijSessionKillCoordinator.isPending(.init(
                  hostID: context.selection.hostID,
                  sessionName: context.selection.name
              ))
        else { return .stop }
        switch result {
        case let .available(names):
            guard names.contains(context.selection.name) else {
                if let selection = pendingCreatedZellijSessions.removeValue(
                    forKey: context.handleID
                ) {
                    failedZellijCreationIntent = selection
                }
                stopZellijReconnect(
                    "The Zellij session is no longer running."
                )
                scheduleZellijSessionDiscovery()
                return .stop
            }
            guard context.surfaceExitCode == 255
                || context.surfaceLaunchFailed
            else {
                stopZellijReconnect(
                    "The remote Zellij client exited before it could attach."
                )
                return .stop
            }
            guard presentZellijSession(
                context.selection,
                validation: ZellijSessionValidation(
                    result: result,
                    host: context.host,
                    connection: connection,
                    executablePath: executablePath
                )
            ) != nil else {
                stopZellijReconnect(
                    "The remote host is no longer available."
                )
                return .stop
            }
            return .stop
        case .unavailable:
            stopZellijReconnect(
                "Zellij is no longer available on this host."
            )
            scheduleZellijSessionDiscovery()
            return .stop
        case let .failure(.commandFailed(status, stderr))
            where status == 255
            || status == AccountCommandRunner.timedOutStatus:
            let classification = SSHConnectionFailure.classify(
                status: status,
                output: stderr
            )
            switch classification.kind {
            case .transport:
                let message = classification.diagnostic.summary + " "
                    + "Ghosthub will reconnect automatically."
                activeBorrowedZellijRecoveryState = .reconnecting(
                    message: message
                )
                borrowedZellijConnectionStates[context.handleID] =
                    .reconnecting(reason: message)
                return .retry
            case .authenticationRequired, .hostKeyReviewRequired:
                let message = classification.diagnostic.summary + " "
                    + classification.diagnostic.recoverySuggestion
                stopZellijReconnect(
                    message,
                    recoveryState: .needsAttention(
                        message: message,
                        canReviewConnection: true
                    )
                )
                if sessionConnectionRecoveryRequest == nil {
                    sessionConnectionRecoveryRequest =
                        SessionConnectionRecoveryRequest(
                            hostID: context.selection.hostID,
                            message: message
                        )
                }
                return .stop
            case .hostKeyChanged, .configurationChanged:
                let message = classification.diagnostic.summary + " "
                    + classification.diagnostic.recoverySuggestion
                stopZellijReconnect(
                    message,
                    recoveryState: .needsAttention(
                        message: message,
                        canReviewConnection: false
                    )
                )
                return .stop
            }
        case let .failure(error):
            stopZellijReconnect(error.localizedDescription)
            return .stop
        }
    }

    private func stopZellijReconnect(
        _ reason: String,
        recoveryState: NativeSessionRecoveryState? = nil
    ) {
        sessionConnectionRecoveryRequest = nil
        activeBorrowedZellijRecoveryState = recoveryState
        guard let handle = activeBorrowedZellijHandle else { return }
        if let selection = pendingCreatedZellijSessions.removeValue(
            forKey: handle.id
        ) {
            failedZellijCreationIntent = selection
            zellijSessionsByHost[selection.hostID] = snapshot
                .host(id: selection.hostID)?
                .zellijSessions.filter { $0.name != selection.name } ?? []
            applyRuntimeInventoryOverlayIfNeeded(hostID: selection.hostID)
            reconcileZellijCreationDiscoveryRetry()
        }
        borrowedZellijConnectionStates[handle.id] = .disconnected(
            reason: reason
        )
    }

    private func cancelZellijReconnect() {
        zellijReconnectSupervisor.cancel()
        activeZellijReconnectContext = nil
        activeBorrowedZellijRecoveryState = nil
        sessionConnectionRecoveryRequest = nil
    }

    func reconnectActiveZellijSessionNow() {
        guard let recoveryState = activeBorrowedZellijRecoveryState,
              recoveryState.allowsReconnectNow
        else { return }
        if recoveryState.isReconnecting {
            zellijReconnectSupervisor.reconnectNow()
            return
        }
        guard let context = activeZellijReconnectContext,
              activeBorrowedZellijHandle?.id == context.handleID
        else { return }
        startZellijReconnect(context)
    }

    private func confirmHerdrLaunch(
        handle: BorrowedHerdrSessionHandle,
        operation: HerdrSessionLifecycleCoordinator.Operation,
        authority: HerdrAttachmentAuthority
    ) {
        guard !isShutDown else { return }
        guard herdrLaunchConfirmationTasks[handle.id] == nil else { return }
        guard let activityGeneration = try? captureSceneActivity() else {
            finishPendingHerdrLaunch(
                handleID: handle.id,
                operation: operation,
                outcome: .failed
            )
            return
        }
        let delays = [.zero] + createdSessionDiscoveryDelays
        herdrLaunchConfirmationTasks[handle.id] = Task { [weak self] in
            for (index, delay) in delays.enumerated() {
                do {
                    try await Task.sleep(for: delay)
                } catch {
                    return
                }
                guard let self,
                      let pending = pendingHerdrLaunchOperations[handle.id],
                      pending.operation == operation,
                      pending.authority?.sshConnectionSnapshot.cacheKey
                      == authority.sshConnectionSnapshot.cacheKey,
                      (try? requireActiveScene(activityGeneration)) != nil,
                      snapshot.host(id: operation.key.hostID)
                      .flatMap(CommandHostResolver.resolve) == authority.host
                else { return }
                let outcome = await herdrSessionExactProbe(
                    operation.key.sessionName,
                    authority.host,
                    authority.sshConnectionSnapshot.arguments
                )
                guard let pending = pendingHerdrLaunchOperations[handle.id],
                      pending.operation == operation,
                      pending.authority?.sshConnectionSnapshot.cacheKey
                      == authority.sshConnectionSnapshot.cacheKey,
                      (try? requireActiveScene(activityGeneration)) != nil,
                      snapshot.host(id: operation.key.hostID)
                      .flatMap(CommandHostResolver.resolve) == authority.host
                else { return }
                if outcome == .present {
                    finishPendingHerdrLaunch(
                        handleID: handle.id,
                        operation: operation,
                        outcome: .succeeded
                    )
                    return
                }
                if index == delays.indices.last {
                    finishPendingHerdrLaunch(
                        handleID: handle.id,
                        operation: operation,
                        outcome: .failed
                    )
                    return
                }
            }
        }
    }

    private func finishPendingHerdrLaunch(
        handleID: UUID,
        operation: HerdrSessionLifecycleCoordinator.Operation,
        outcome: HerdrSessionLifecycleCoordinator.Outcome
    ) {
        guard pendingHerdrLaunchOperations[handleID]?.operation == operation
        else {
            return
        }
        pendingHerdrLaunchOperations.removeValue(forKey: handleID)
        herdrLaunchConfirmationTasks.removeValue(forKey: handleID)
        herdrLifecycleCoordinator.finish(operation, outcome: outcome)
        if outcome == .succeeded,
           let handle = activeBorrowedHerdrHandle,
           handle.id == handleID {
            nativeHerdrSessionCoordinator.refreshPaneSplitCapability(handle)
        }
    }

    private func startHerdrReconnect(
        _ context: ActiveHerdrReconnectContext
    ) {
        guard !isShutDown,
              activeHerdrReconnectContext == context,
              activeBorrowedHerdrHandle?.id == context.handleID
        else { return }
        activeBorrowedHerdrRecoveryState = .reconnecting(
            message: "Waiting for \(hostName(for: context.selection.hostID)). "
                + "Ghosthub will reconnect automatically."
        )
        sessionConnectionRecoveryRequest = nil
        herdrReconnectSupervisor.start { [weak self] in
            guard let self else { return .stop }
            return await attemptHerdrReconnect(context)
        }
    }

    private func attemptHerdrReconnect(
        _ context: ActiveHerdrReconnectContext
    ) async -> SessionReconnectDecision {
        guard activeHerdrReconnectContext == context,
              activeBorrowedHerdrHandle?.id == context.handleID
        else { return .stop }
        guard canAttachToDisplay else { return .retry }
        let connection = await herdrConnectionSnapshot(on: context.host)
        guard !Task.isCancelled else { return .retry }
        guard activeHerdrReconnectContext == context,
              activeBorrowedHerdrHandle?.id == context.handleID
        else { return .stop }
        if let routeIdentity = connection.routeIdentity,
           routeIdentity != context.routeIdentity {
            stopHerdrReconnectWithUnableToAttach(
                "The SSH connection changed while Ghosthub was checking the Herdr session. Reopen it to use the current connection."
            )
            return .stop
        }
        let outcome = await herdrSessionExactProbe(
            context.selection.name,
            context.host,
            connection.arguments
        )
        let currentConnection = await herdrConnectionSnapshot(on: context.host)
        guard !Task.isCancelled else { return .retry }
        guard activeHerdrReconnectContext == context,
              activeBorrowedHerdrHandle?.id == context.handleID,
              snapshot.host(id: context.selection.hostID)
              .flatMap(CommandHostResolver.resolve) == context.host
        else { return .stop }
        if connection.routeIdentity != nil {
            guard let routeIdentity = currentConnection.routeIdentity else {
                return .retry
            }
            guard routeIdentity == context.routeIdentity else {
                stopHerdrReconnectWithUnableToAttach(
                    "The SSH connection changed while Ghosthub was checking the Herdr session. Reopen it to use the current connection."
                )
                return .stop
            }
        }
        if case let .failure(error) = outcome,
           SSHConnectionFailure.indicatesUnusableConnection(error) {
            await connection.invalidate()
        }
        return herdrReconnectDecision(
            for: context,
            outcome: outcome,
            validation: HerdrSessionValidation(
                session: nil,
                host: context.host,
                connection: connection
            )
        )
    }

    private func herdrReconnectDecision(
        for context: ActiveHerdrReconnectContext,
        outcome: HerdrSessionProbeOutcome,
        validation: HerdrSessionValidation? = nil
    ) -> SessionReconnectDecision {
        guard !Task.isCancelled else { return .retry }
        guard activeHerdrReconnectContext == context,
              activeBorrowedHerdrHandle?.id == context.handleID
        else { return .stop }
        switch outcome {
        case .present:
            // SSH reserves 255 for transport failure, but a client could also choose it.
            // The accepted ambiguity self-corrects because every retry first probes the
            // exact running Herdr session and stops when that session is absent.
            guard context.surfaceExitCode == 255
                || context.surfaceLaunchFailed
            else {
                stopHerdrReconnectWithUnableToAttach(
                    "The remote Herdr client exited before it could attach."
                )
                return .stop
            }
            guard let validation else {
                stopHerdrReconnectWithUnableToAttach(
                    "The remote Herdr route could not be verified."
                )
                return .stop
            }
            guard presentHerdrSession(
                context.selection,
                validation: validation
            ) != nil else {
                stopHerdrReconnectWithUnableToAttach(
                    "The remote host is no longer available."
                )
                return .stop
            }
            prepareActiveBorrowedHerdrSurface()
            return .stop
        case .absent:
            activeBorrowedHerdrRecoveryState = nil
            sessionConnectionRecoveryRequest = nil
            borrowedHerdrConnectionStates[context.handleID] = .disconnected(
                reason: "The Herdr session is no longer running."
            )
            refreshHerdrInventory(hostID: context.selection.hostID)
            return .stop
        case .unavailable:
            activeBorrowedHerdrRecoveryState = nil
            sessionConnectionRecoveryRequest = nil
            borrowedHerdrConnectionStates[context.handleID] = .disconnected(
                reason: "Herdr is no longer available on this host."
            )
            refreshHerdrInventory(hostID: context.selection.hostID)
            return .stop
        case .failure(.cancelled):
            return .retry
        case let .failure(.commandFailed(status, stderr))
            where status == 255:
            let classification = SSHConnectionFailure.classify(
                status: status,
                output: stderr
            )
            switch classification.kind {
            case .transport:
                activeBorrowedHerdrRecoveryState = .reconnecting(
                    message: classification.diagnostic.summary + " "
                        + "Ghosthub will reconnect automatically."
                )
                return .retry
            case .authenticationRequired, .hostKeyReviewRequired:
                let message = classification.diagnostic.summary + " "
                    + classification.diagnostic.recoverySuggestion
                activeBorrowedHerdrRecoveryState = .needsAttention(
                    message: message,
                    canReviewConnection: true
                )
                if sessionConnectionRecoveryRequest == nil {
                    sessionConnectionRecoveryRequest =
                        SessionConnectionRecoveryRequest(
                            hostID: context.selection.hostID,
                            message: message
                        )
                }
                return .stop
            case .hostKeyChanged, .configurationChanged:
                activeBorrowedHerdrRecoveryState = .needsAttention(
                    message: classification.diagnostic.summary + " "
                        + classification.diagnostic.recoverySuggestion,
                    canReviewConnection: false
                )
                sessionConnectionRecoveryRequest = nil
                return .stop
            }
        case let .failure(error):
            stopHerdrReconnectWithUnableToAttach(error.localizedDescription)
            return .stop
        }
    }

    private func stopHerdrReconnectWithUnableToAttach(_ reason: String) {
        activeBorrowedHerdrRecoveryState = nil
        sessionConnectionRecoveryRequest = nil
        guard let handle = activeBorrowedHerdrHandle else { return }
        borrowedHerdrConnectionStates[handle.id] = .disconnected(
            reason: reason
        )
    }

    func reconnectActiveHerdrSessionNow() {
        guard let recoveryState = activeBorrowedHerdrRecoveryState,
              recoveryState.allowsReconnectNow
        else { return }
        if recoveryState.isReconnecting {
            herdrReconnectSupervisor.reconnectNow()
            return
        }
        guard let context = activeHerdrReconnectContext,
              activeBorrowedHerdrHandle?.id == context.handleID
        else { return }
        startHerdrReconnect(context)
    }

    private func cancelHerdrReconnect() {
        herdrReconnectSupervisor.cancel()
        activeHerdrReconnectContext = nil
        activeBorrowedHerdrRecoveryState = nil
        sessionConnectionRecoveryRequest = nil
    }

    private func startTmuxReconnect(
        _ presentation: RetainedTmuxPresentation,
        context: TmuxReconnectContext,
        waitBeforeFirstAttempt: Bool = false
    ) {
        guard presentation.reconnectContext == context,
              presentation.handle.id == context.handleID,
              retainedTmuxPresentation(for: presentation.handle)
              === presentation
        else { return }
        presentation.recoveryState = .reconnecting(
            message: "Waiting for \(hostName(for: context.selection.hostID)). "
                + "Ghosthub will reconnect automatically."
        )
        presentation.recoveryRequest = nil
        publishActiveState(for: presentation)
        let attempt: SessionReconnectSupervisor.Attempt = {
            [weak self, weak presentation] in
            guard let presentation else { return .stop }
            guard let self else { return .stop }
            return await attemptTmuxReconnect(
                presentation,
                context: context
            )
        }
        if waitBeforeFirstAttempt {
            presentation.reconnectSupervisor.startAfterDelay(attempt: attempt)
        } else {
            presentation.reconnectSupervisor.start(attempt: attempt)
        }
    }

    /// Whether an attach can succeed right now.
    ///
    /// libghostty's renderer needs an active display to build the vsync display
    /// link it creates with every surface, so attaching with none — lid shut, no
    /// external monitor — always fails. Holding instead of attempting keeps the
    /// supervisor's backoff intact and stops Ghosthub waking SSH on every dark
    /// wake while the lid is closed. `subscribeDisplayAvailability()` retries
    /// the moment a display comes back.
    private var canAttachToDisplay: Bool {
        activeDisplayCount() > 0
    }

    /// Resumes recovery as soon as a display comes back, so a session held by
    /// `canAttachToDisplay` attaches on lid open instead of waiting out the
    /// supervisor's remaining delay.
    func handleDisplayParametersChanged() {
        guard canAttachToDisplay else { return }
        for presentation in retainedTmuxPresentations.values
            where presentation.reconnectSupervisor.isRunning {
            presentation.reconnectSupervisor.reconnectNow()
        }
        if herdrReconnectSupervisor.isRunning {
            herdrReconnectSupervisor.reconnectNow()
        }
        if zellijReconnectSupervisor.isRunning {
            zellijReconnectSupervisor.reconnectNow()
        }
        reconcileAlwaysLiveTmuxPresentations()
        startAlwaysLiveTmuxSurfaceLaunchIfNeeded()
    }

    private func attemptTmuxReconnect(
        _ presentation: RetainedTmuxPresentation,
        context: TmuxReconnectContext
    ) async -> SessionReconnectDecision {
        guard presentation.reconnectContext == context,
              presentation.handle.id == context.handleID,
              retainedTmuxPresentation(for: presentation.handle)
              === presentation
        else { return .stop }
        guard canAttachToDisplay else { return .retry }
        if case let .ssh(info) = context.host,
           context.routeIdentity == nil {
            let routeIdentity: String
            do {
                routeIdentity = try await sshRouteIdentityResolver(info)
            } catch {
                guard !Task.isCancelled else { return .retry }
                guard presentation.reconnectContext == context,
                      presentation.handle.id == context.handleID,
                      retainedTmuxPresentation(for: presentation.handle)
                      === presentation
                else { return .stop }
                stopTmuxReconnectWithUnableToAttach(
                    presentation,
                    "Ghosthub could not verify the SSH route before reconnecting. Reopen the session to use the current connection. \(error.localizedDescription)"
                )
                return .stop
            }
            guard !Task.isCancelled else { return .retry }
            guard presentation.reconnectContext == context,
                  presentation.handle.id == context.handleID,
                  retainedTmuxPresentation(for: presentation.handle)
                  === presentation,
                  snapshot.host(id: context.selection.hostID)
                  .flatMap(CommandHostResolver.resolve) == context.host
            else { return .stop }
            var anchoredContext = context
            anchoredContext.routeIdentity = routeIdentity
            presentation.reconnectContext = anchoredContext
            startTmuxReconnect(
                presentation,
                context: anchoredContext,
                waitBeforeFirstAttempt: false
            )
            return .stop
        }
        var frozenConnection: SSHConnectionArgumentsSnapshot?
        if case let .ssh(info) = context.host {
            let connection: KwtSSHConnection
            do {
                connection = try await acquirePresentationSSHConnection(
                    hostID: context.selection.hostID,
                    info: info
                )
            } catch {
                guard !Task.isCancelled else { return .retry }
                guard presentation.reconnectContext == context,
                      presentation.handle.id == context.handleID,
                      retainedTmuxPresentation(for: presentation.handle)
                      === presentation
                else { return .stop }
                return tmuxSSHAcquisitionFailureDecision(
                    presentation,
                    error: error
                )
            }
            let snapshot = SSHConnectionArgumentsSnapshot(connection)
            guard !Task.isCancelled else { return .retry }
            guard presentation.reconnectContext == context,
                  presentation.handle.id == context.handleID,
                  retainedTmuxPresentation(for: presentation.handle)
                  === presentation
            else { return .stop }
            if let expectedRouteIdentity = context.routeIdentity,
               snapshot.routeIdentity != expectedRouteIdentity {
                stopTmuxReconnectWithUnableToAttach(
                    presentation,
                    "The SSH connection changed while Ghosthub was checking the tmux session. Reopen it to use the current connection."
                )
                return .stop
            }
            frozenConnection = snapshot
        }
        let probe = await tmuxReconnectProbe(
            for: presentation,
            context: context,
            connection: frozenConnection
        )
        guard !Task.isCancelled else { return .retry }
        guard let currentContext = presentation.reconnectContext else {
            return .stop
        }
        let advancedToAttachOnly =
            context.phase != .attachOnly
                && currentContext.phase == .attachOnly
                && currentContext.selection == context.selection
                && currentContext.handleID == context.handleID
                && currentContext.host == context.host
                && currentContext.routeIdentity == context.routeIdentity
                && currentContext.surfaceExitCode == context.surfaceExitCode
        guard currentContext == context || advancedToAttachOnly,
              presentation.handle.id == context.handleID,
              retainedTmuxPresentation(for: presentation.handle)
              === presentation
        else { return .stop }
        if let frozenConnection,
           case let .failure(.sshConnectionFailed(_, classification)) =
           probe.outcome,
           classification.connectionUnusable {
            await frozenConnection.invalidate()
        }
        if let frozenConnection,
           case let .ssh(info) = context.host {
            let after: KwtSSHConnection
            do {
                after = try await acquirePresentationSSHConnection(
                    hostID: context.selection.hostID,
                    info: info
                )
            } catch {
                guard !Task.isCancelled else { return .retry }
                guard presentation.reconnectContext == currentContext,
                      presentation.handle.id == context.handleID,
                      retainedTmuxPresentation(for: presentation.handle)
                      === presentation
                else { return .stop }
                return tmuxSSHAcquisitionFailureDecision(
                    presentation,
                    error: error
                )
            }
            let afterRouteIdentity = after.routeIdentity
            try? await after.release()
            guard !Task.isCancelled else { return .retry }
            guard presentation.reconnectContext == currentContext,
                  presentation.handle.id == context.handleID,
                  retainedTmuxPresentation(for: presentation.handle)
                  === presentation
            else { return .stop }
            guard afterRouteIdentity == frozenConnection.routeIdentity else {
                stopTmuxReconnectWithUnableToAttach(
                    presentation,
                    "The SSH connection changed while Ghosthub was checking the tmux session. Reopen it to use the current connection."
                )
                return .stop
            }
        }
        if let discovery = probe.discovery {
            let refreshStarted = discovery.epoch
                != tmuxRefreshEpoch(hostID: context.selection.hostID)
            if !refreshStarted,
               isCurrentTmuxDiscoveryObservation(
                   discovery.sequence,
                   hostID: context.selection.hostID
               ) {
                applyTmuxDiscoveryResult(
                    discovery.result,
                    hostID: context.selection.hostID,
                    publishingEpoch: discovery.epoch
                )
            } else {
                if !refreshStarted {
                    scheduleTmuxSessionDiscovery()
                }
                // A concurrent inventory pass superseded this observation.
                // A route-fenced positive probe can still attach safely, but
                // absence or failure must yield to the newer observation.
                guard probe.outcome == .present else { return .retry }
            }
        }
        guard var decisionContext = presentation.reconnectContext else {
            return .stop
        }
        let discoveryAdvancedToAttachOnly =
            currentContext.phase != .attachOnly
                && decisionContext.phase == .attachOnly
                && decisionContext.selection == currentContext.selection
                && decisionContext.handleID == currentContext.handleID
                && decisionContext.host == currentContext.host
                && decisionContext.routeIdentity
                == currentContext.routeIdentity
                && decisionContext.surfaceExitCode
                == currentContext.surfaceExitCode
        guard decisionContext == currentContext
            || discoveryAdvancedToAttachOnly
        else { return .stop }
        if decisionContext.routeIdentity == nil,
           let frozenConnection {
            switch probe.outcome {
            case .present, .absent:
                // Initial attachment recovery has no route to fence until its
                // first successful probe. Bind that stable route before any
                // relaunch so the new client cannot switch SSH destinations.
                decisionContext.routeIdentity = frozenConnection.routeIdentity
                presentation.reconnectContext = decisionContext
            case .failure:
                break
            }
        }
        return reconnectDecision(
            for: presentation,
            context: decisionContext,
            outcome: probe.outcome
        )
    }

    private func tmuxSSHAcquisitionFailureDecision(
        _ presentation: RetainedTmuxPresentation,
        error: Error
    ) -> SessionReconnectDecision {
        if let classification = SSHConnectionFailure
            .retryableTransportFailure(error) {
            presentation.recoveryState = .reconnecting(
                message: classification.diagnostic.summary + " "
                    + "Ghosthub will reconnect automatically."
            )
            publishActiveState(for: presentation)
            return .retry
        }
        stopTmuxReconnectWithUnableToAttach(
            presentation,
            error.localizedDescription
        )
        return .stop
    }

    private func tmuxReconnectProbe(
        for presentation: RetainedTmuxPresentation,
        context: TmuxReconnectContext,
        connection: SSHConnectionArgumentsSnapshot?
    ) async -> TmuxReconnectProbeResult {
        guard let connection,
              case let .ssh(host) = context.host
        else {
            return await TmuxReconnectProbeResult(
                outcome: tmuxProbeOutcome(
                    for: presentation,
                    context: context
                ),
                discovery: nil
            )
        }
        let target = TmuxSessionProbeTarget(
            host: host,
            name: context.selection.name,
            socketName: context.selection.socketName
        )
        if context.selection.socketName != nil {
            guard let tmuxSessionValidationExactProbe else {
                return await TmuxReconnectProbeResult(
                    outcome: tmuxProbeOutcome(
                        for: presentation,
                        context: context
                    ),
                    discovery: nil
                )
            }
            let outcome = switch await tmuxSessionValidationExactProbe(
                target,
                connection.arguments
            ) {
            case let .success(isPresent):
                isPresent ? TmuxSessionProbeOutcome.present : .absent
            case let .failure(error):
                TmuxSessionProbeOutcome.failure(error)
            }
            return TmuxReconnectProbeResult(
                outcome: outcome,
                discovery: nil
            )
        }
        guard let tmuxSessionValidationDiscovery else {
            return await TmuxReconnectProbeResult(
                outcome: tmuxProbeOutcome(
                    for: presentation,
                    context: context
                ),
                discovery: nil
            )
        }
        let sequence = beginTmuxDiscoveryObservation(
            hostID: context.selection.hostID
        )
        let epoch = tmuxRefreshEpoch(hostID: context.selection.hostID)
        let result = await tmuxSessionValidationDiscovery(
            context.host,
            connection.arguments
        )
        let outcome = switch result {
        case let .success(sessions):
            sessions.contains(where: {
                $0.name == context.selection.name
            }) ? TmuxSessionProbeOutcome.present : .absent
        case let .failure(error):
            TmuxSessionProbeOutcome.failure(error)
        }
        return TmuxReconnectProbeResult(
            outcome: outcome,
            discovery: (sequence, epoch, result)
        )
    }

    private func tmuxProbeOutcome(
        for presentation: RetainedTmuxPresentation,
        context: TmuxReconnectContext
    ) async -> TmuxSessionProbeOutcome {
        if context.selection.socketName == nil {
            let observationSequence = beginTmuxDiscoveryObservation(
                hostID: context.selection.hostID
            )
            let epoch = tmuxRefreshEpoch(hostID: context.selection.hostID)
            var didReconcileObservation = false
            defer {
                if !didReconcileObservation,
                   !isShutDown,
                   isCurrentTmuxDiscoveryObservation(
                       observationSequence,
                       hostID: context.selection.hostID
                   ),
                   tmuxRefreshEpoch(hostID: context.selection.hostID) == epoch {
                    scheduleTmuxSessionDiscovery()
                }
            }
            let result = await tmuxSessionProbeBroker.sessions(
                on: context.host
            )
            guard !Task.isCancelled else {
                return .failure(.probeCancelled(
                    shell: context.host.displayName
                ))
            }
            guard presentation.reconnectContext == context,
                  presentation.handle.id == context.handleID,
                  retainedTmuxPresentation(for: presentation.handle)
                  === presentation,
                  snapshot.host(id: context.selection.hostID)
                  .flatMap(CommandHostResolver.resolve) == context.host
            else {
                return .failure(.sessionContextUnavailable)
            }
            if case let .failure(error) = result,
               case .probeCancelled = error {
                return .failure(error)
            }
            guard isCurrentTmuxDiscoveryObservation(
                observationSequence,
                hostID: context.selection.hostID
            ),
                tmuxRefreshEpoch(hostID: context.selection.hostID) == epoch
            else {
                return .failure(.probeCancelled(
                    shell: context.host.displayName
                ))
            }
            didReconcileObservation = true
            applyTmuxDiscoveryResult(
                result,
                hostID: context.selection.hostID,
                publishingEpoch: epoch
            )
            switch result {
            case let .success(sessions):
                guard sessions.contains(where: {
                    $0.name == context.selection.name
                }) else { return .absent }
                return .present
            case let .failure(error):
                return .failure(error)
            }
        }
        if context.selection.socketName != nil,
           context.host == .local {
            do {
                _ = try await tmuxSessionIdentityReader(
                    context.selection,
                    context.host
                )
                return .present
            } catch TmuxSessionKillError.sessionNotRunning {
                return .absent
            } catch {
                return .failure(.sessionContextUnavailable)
            }
        }
        guard case let .ssh(host) = context.host else {
            return .failure(.sessionContextUnavailable)
        }
        return await tmuxSessionProbeBroker.session(
            TmuxSessionProbeTarget(
                host: host,
                name: context.selection.name,
                socketName: context.selection.socketName
            )
        )
    }

    private func confirmPendingTmuxCreation(
        handleID: UUID,
        selection: WorkspaceTmuxSessionSelection
    ) {
        guard let pending = pendingCreatedTmuxSessions[handleID],
              Self.sameTmuxSession(pending.selection, selection)
        else { return }
        if let key = retainedTmuxPresentationKeysByHandle[handleID],
           let presentation = retainedTmuxPresentations[key],
           Self.sameTmuxSession(presentation.selection, selection) {
            presentation.launchMode = .attach
            if let context = presentation.reconnectContext,
               context.handleID == handleID,
               case .establishingProfile = context.phase {
                presentation.reconnectContext?.phase = .attachOnly
                presentation.establishmentConfirmationTask?.cancel()
                presentation.establishmentConfirmationTask = nil
            }
            publishActiveState(for: presentation)
        }
        pendingCreatedTmuxSessions.removeValue(forKey: handleID)
        createdSessionDiscoveryTasks.removeValue(forKey: handleID)?.cancel()
        exhaustedCreatedTmuxSessionHandles.remove(handleID)
        endedCreatedTmuxSessionHandles.remove(handleID)
    }

    private func reconnectDecision(
        for presentation: RetainedTmuxPresentation,
        context: TmuxReconnectContext,
        outcome: TmuxSessionProbeOutcome
    ) -> SessionReconnectDecision {
        guard !Task.isCancelled else { return .retry }
        guard presentation.reconnectContext == context,
              presentation.handle.id == context.handleID,
              retainedTmuxPresentation(for: presentation.handle)
              === presentation
        else { return .stop }
        switch outcome {
        case .present:
            guard context.surfaceExitCode == 255
                || context.surfaceLaunchFailed
                || (context.surfaceExitCode == 127
                    && context.usesKwtWorkspaceCommand)
            else {
                stopTmuxReconnectWithUnableToAttach(
                    presentation,
                    "The remote tmux client exited before it could attach."
                )
                return .stop
            }
            confirmedEndedTmuxSessionHandles.remove(context.handleID)
            relaunchTmuxSession(
                presentation,
                launchMode: .attachOnly,
                intent: .restoreOnly
            )
            return .stop
        case .absent:
            guard context.phase != .attachOnly else {
                confirmedEndedTmuxSessionHandles.insert(context.handleID)
                presentation.recoveryState = nil
                presentation.recoveryRequest = nil
                publishActiveState(for: presentation)
                return .stop
            }
            guard context.surfaceExitCode == 255
                || (context.phase == .establishingWorkspace
                    && context.surfaceLaunchFailed)
            else {
                stopTmuxReconnectWithUnableToAttach(
                    presentation,
                    "The remote workspace could not be established."
                )
                return .stop
            }
            switch context.phase {
            case .establishingWorkspace:
                relaunchTmuxSession(
                    presentation,
                    launchMode: .attach,
                    intent: .userInitiated
                )
            case .establishingProfile:
                stopTmuxReconnectWithUnableToAttach(
                    presentation,
                    "The session was not found after the connection dropped. "
                        + "The launch command may have already run. Review the"
                        + " command before trying it again."
                )
            case .attachOnly:
                break
            }
            return .stop
        case .failure(.probeCancelled), .failure(.probeTimedOut):
            return .retry
        case let .failure(.sshConnectionFailed(_, classification)):
            switch classification.kind {
            case .transport:
                presentation.recoveryState = .reconnecting(
                    message: classification.diagnostic.summary + " "
                        + "Ghosthub will reconnect automatically."
                )
                publishActiveState(for: presentation)
                return .retry
            case .authenticationRequired, .hostKeyReviewRequired:
                let message = classification.diagnostic.summary + " "
                    + classification.diagnostic.recoverySuggestion
                presentation.recoveryState = .needsAttention(
                    message: message,
                    canReviewConnection: true
                )
                if presentation.recoveryRequest == nil {
                    presentation.recoveryRequest =
                        SessionConnectionRecoveryRequest(
                            hostID: context.selection.hostID,
                            message: message
                        )
                }
                publishActiveState(for: presentation)
                return .stop
            case .hostKeyChanged, .configurationChanged:
                presentation.recoveryState = .needsAttention(
                    message: classification.diagnostic.summary + " "
                        + classification.diagnostic.recoverySuggestion,
                    canReviewConnection: false
                )
                presentation.recoveryRequest = nil
                publishActiveState(for: presentation)
                return .stop
            }
        case let .failure(error):
            stopTmuxReconnectWithUnableToAttach(
                presentation,
                error.localizedDescription
            )
            return .stop
        }
    }

    private func relaunchTmuxSession(
        _ presentation: RetainedTmuxPresentation,
        launchMode: TmuxAttachmentLaunchMode,
        initialCommand: String? = nil,
        intent: TmuxPresentationIntent
    ) {
        let selection = presentation.selection
        beginTmuxPreviewReconnect(presentation)
        guard let host = snapshot.host(id: selection.hostID),
              let attachmentHost = CommandHostResolver.resolve(host)
        else {
            stopTmuxReconnectWithUnableToAttach(
                presentation,
                "The remote host is no longer available."
            )
            return
        }
        let knownSessions = tmuxSessionsByHost[selection.hostID]
            ?? host.tmuxSessions
        let sessionIsDiscovered = selection.socketName == nil
            && knownSessions.contains { $0.name == selection.name }
        let managedKwtUnavailable =
            kwtAvailabilityByHost[selection.hostID] == false
        let openWorkspace = intent == .userInitiated
            && launchMode == .attach
            && selection.tmuxAttachMode == .direct
            && selection.workspacePath != nil
            && (!sessionIsDiscovered || !managedKwtUnavailable)
        let protectedSessionNeedsEstablishment = intent == .userInitiated
            && launchMode == .attach
            && selection.tmuxAttachMode == .protected
            && selection.workspacePath != nil
        let previousHandle = presentation.handle
        let routeIdentity = presentation.reconnectContext?.routeIdentity
        let presentationKey = TmuxPresentationKey(selection)
        let isAlwaysLiveManaged = alwaysLiveManagedTmuxPresentationKeys
            .contains(presentationKey)
        let previewGridSize = (tmuxSessionsByHost[selection.hostID]
            ?? host.tmuxSessions).first { $0.name == selection.name }?
            .previewClientSize
        let handle = nativeTmuxSessionCoordinator.attach(
            hostID: selection.hostID,
            name: selection.name,
            host: attachmentHost,
            socketName: selection.socketName,
            tmuxAttachMode: selection.tmuxAttachMode,
            launchMode: launchMode,
            initialCommand: launchMode == .create ? initialCommand : nil,
            workingDirectory: selection.workspacePath,
            openWorkspace: openWorkspace,
            sessionIdentity: presentation.reconnectExpectedIdentity,
            expectedRouteIdentity: routeIdentity,
            ignoresClientSize: isAlwaysLiveManaged
                && host.platform != .windows,
            previewGridSize: isAlwaysLiveManaged ? previewGridSize : nil
        )
        if handle.id != previousHandle.id {
            retainedTmuxPresentationKeysByHandle.removeValue(
                forKey: previousHandle.id
            )
            retainedTmuxPresentationKeysByHandle[handle.id] =
                TmuxPresentationKey(selection)
        }
        presentation.handle = handle
        presentation.launchMode = launchMode
        let phase: RemoteTmuxEstablishmentPhase
        if openWorkspace || protectedSessionNeedsEstablishment {
            phase = .establishingWorkspace
        } else if launchMode == .create,
                  let initialCommand,
                  !initialCommand.isEmpty {
            phase = .establishingProfile(initialCommand: initialCommand)
        } else {
            phase = .attachOnly
        }
        presentation.reconnectContext = TmuxReconnectContext(
            selection: selection,
            handleID: handle.id,
            host: attachmentHost,
            routeIdentity: routeIdentity,
            phase: phase,
            surfaceExitCode: nil,
            usesKwtWorkspaceCommand: openWorkspace
        )
        borrowedTmuxConnectionStates[handle.id] = .connecting
        if activeBorrowedTmuxHandle == previousHandle {
            activeBorrowedTmuxHandle = handle
            publishActiveState(for: presentation)
        }
        guard acquireProtectedTmuxAttachmentScopeIfNeeded(
            for: presentation
        ) else { return }
        _ = protectedTmuxSurface(handle: handle)
    }

    private func stopTmuxReconnectWithUnableToAttach(
        _ presentation: RetainedTmuxPresentation,
        _ reason: String
    ) {
        presentation.recoveryState = nil
        presentation.recoveryRequest = nil
        borrowedTmuxConnectionStates[presentation.handle.id] = .disconnected(
            reason: reason
        )
        publishActiveState(for: presentation)
    }

    private func hostName(for hostID: UUID) -> String {
        snapshot.host(id: hostID)?.name ?? "the remote host"
    }

    func reconnectActiveTmuxSessionNow() {
        guard let handle = activeBorrowedTmuxHandle,
              let presentation = retainedTmuxPresentation(for: handle),
              let recoveryState = presentation.recoveryState,
              recoveryState.allowsReconnectNow
        else { return }
        if recoveryState.isReconnecting {
            presentation.reconnectSupervisor.reconnectNow()
            return
        }
        guard let context = presentation.reconnectContext,
              handle.id == context.handleID
        else { return }
        startTmuxReconnect(presentation, context: context)
    }

    func resumeSessionReconnectAfterSSHRecovery(
        _ recoveryRequest: SessionConnectionRecoveryRequest
    ) {
        if case .needsAttention(_, true) = activeBorrowedHerdrRecoveryState,
           sessionConnectionRecoveryRequest == recoveryRequest,
           var context = activeHerdrReconnectContext,
           context.selection.hostID == recoveryRequest.hostID,
           activeBorrowedHerdrHandle?.id == context.handleID {
            context.surfaceExitCode = 255
            activeHerdrReconnectContext = context
            sessionConnectionRecoveryRequest = nil
            startHerdrReconnect(context)
            return
        }
        if case .needsAttention(_, true) = activeBorrowedZellijRecoveryState,
           sessionConnectionRecoveryRequest == recoveryRequest,
           var context = activeZellijReconnectContext,
           context.selection.hostID == recoveryRequest.hostID,
           activeBorrowedZellijHandle?.id == context.handleID {
            context.surfaceExitCode = 255
            activeZellijReconnectContext = context
            sessionConnectionRecoveryRequest = nil
            startZellijReconnect(context)
            return
        }
        guard let presentation = retainedTmuxPresentations.values.first(
            where: { $0.recoveryRequest?.id == recoveryRequest.id }
        ),
            case .needsAttention(_, true) = presentation.recoveryState,
            let request = presentation.recoveryRequest,
            request == recoveryRequest,
            var context = presentation.reconnectContext,
            context.selection.hostID == request.hostID,
            presentation.handle.id == context.handleID
        else { return }
        context.surfaceExitCode = 255
        presentation.reconnectContext = context
        presentation.recoveryRequest = nil
        publishActiveState(for: presentation)
        startTmuxReconnect(presentation, context: context)
    }

    private func cancelTmuxReconnect(
        _ presentation: RetainedTmuxPresentation
    ) {
        presentation.reconnectSupervisor.cancel()
        presentation.establishmentConfirmationTask?.cancel()
        presentation.establishmentConfirmationTask = nil
        presentation.reconnectContext = nil
        presentation.recoveryState = nil
        presentation.recoveryRequest = nil
        publishActiveState(for: presentation)
    }

    private func startEstablishmentConfirmationIfNeeded(
        presentation: RetainedTmuxPresentation
    ) {
        let handle = presentation.handle
        guard let context = presentation.reconnectContext,
              context.handleID == handle.id,
              context.phase != .attachOnly
        else { return }
        presentation.establishmentConfirmationTask?.cancel()
        let initialDelays = [.zero] + createdSessionDiscoveryDelays
        let keepsProbingUntilConfirmed =
            context.selection.tmuxAttachMode == .protected
        let settledDelay = createdSessionDiscoveryDelays.last(where: {
            $0 > .zero
        }) ?? .seconds(4)
        presentation.establishmentConfirmationTask = Task {
            [weak self, weak presentation] in
            var retryIndex = 0
            while retryIndex < initialDelays.count
                || keepsProbingUntilConfirmed {
                let delay = retryIndex < initialDelays.count
                    ? initialDelays[retryIndex] : settledDelay
                retryIndex += 1
                do {
                    try await Task.sleep(for: delay)
                } catch {
                    return
                }
                guard let self, let presentation,
                      !Task.isCancelled,
                      presentation.reconnectContext == context,
                      borrowedTmuxConnectionStates[handle.id] == .connected
                else { return }
                let outcome = await tmuxProbeOutcome(
                    for: presentation,
                    context: context
                )
                guard !Task.isCancelled,
                      presentation.reconnectContext == context,
                      borrowedTmuxConnectionStates[handle.id] == .connected
                else { return }
                if outcome == .present {
                    presentation.reconnectContext?.phase = .attachOnly
                    presentation.establishmentConfirmationTask = nil
                    releaseProtectedTmuxAttachmentScope(handleID: handle.id)
                    return
                }
            }
            guard let presentation,
                  presentation.reconnectContext == context
            else { return }
            presentation.establishmentConfirmationTask = nil
        }
    }

    private func warmConnectedTmuxSession(
        handle: BorrowedTmuxSessionHandle
    ) {
        guard let activityController = tmuxSessionActivityController,
              let selection = retainedTmuxPresentation(for: handle)?
              .selection,
              !nativeTmuxSessionCoordinator.hasClosedAttachment(handle),
              let hostSummary = snapshot.host(id: selection.hostID),
              let host = CommandHostResolver.resolve(hostSummary)
        else { return }
        tmuxActivityEnrollmentTasks.removeValue(
            forKey: handle.id
        )?.cancel()
        let retryDelays: [Duration] = [.zero]
            + createdSessionDiscoveryDelays
        let settledRetryDelay = createdSessionDiscoveryDelays.last(where: {
            $0 > .zero
        }) ?? .seconds(4)
        tmuxActivityEnrollmentTasks[handle.id] = Task { [weak self] in
            var retryIndex = 0
            while true {
                let delay = retryIndex < retryDelays.count
                    ? retryDelays[retryIndex]
                    : settledRetryDelay
                retryIndex += 1
                do {
                    try await Task.sleep(for: delay)
                } catch {
                    return
                }
                guard let self,
                      !Task.isCancelled,
                      borrowedTmuxConnectionStates[handle.id] == .connected,
                      let currentSelection = retainedTmuxPresentation(
                          for: handle
                      )?.selection,
                      Self.sameTmuxEndpoint(currentSelection, selection),
                      let currentHostSummary = snapshot.host(
                          id: currentSelection.hostID
                      ),
                      CommandHostResolver.resolve(currentHostSummary) == host
                else { return }
                let identity: TmuxSessionIdentity
                do {
                    identity = try await tmuxSessionIdentityReader(
                        currentSelection,
                        host
                    )
                } catch {
                    continue
                }
                guard !Task.isCancelled,
                      !nativeTmuxSessionCoordinator.hasClosedAttachment(
                          handle
                      ),
                      borrowedTmuxConnectionStates[handle.id] == .connected,
                      retainedTmuxPresentation(for: handle).map({
                          Self.sameTmuxEndpoint(
                              $0.selection,
                              currentSelection
                          )
                      }) == true
                else { return }
                activityController.warm(
                    currentSelection,
                    identity: identity,
                    on: host
                )
                tmuxActivityEnrollmentTasks.removeValue(
                    forKey: handle.id
                )
                return
            }
        }
    }

    private func discardPendingTmuxSession(handleID: UUID) {
        guard let request = pendingCreatedTmuxSessions[handleID] else {
            return
        }
        createdSessionDiscoveryTasks.removeValue(forKey: handleID)?.cancel()
        pendingCreatedTmuxSessions.removeValue(forKey: handleID)
        exhaustedCreatedTmuxSessionHandles.remove(handleID)
        endedCreatedTmuxSessionHandles.remove(handleID)
        removeOptimisticTmuxSession(request.selection)
    }

    /// True once no deferred or draining styling work remains. Tests wait on
    /// this before re-triggering so they never race pending task cleanup.
    var tmuxStylingQuiesced: Bool {
        deferredTmuxPresentationTasks.isEmpty
            && drainingDeferredTmuxPresentationTasks.isEmpty
    }

    func terminalPresentationStyleDidChange() {
        objectWillChange.send()
        let presentations = Array(retainedTmuxPresentations.values)
        for presentation in presentations {
            cancelTmuxPresentationTasks(handleID: presentation.handle.id)
        }
        for presentation in presentations {
            applyDeferredTmuxPresentationIfReady(presentation)
        }
    }

    /// A cancelled ladder keeps draining until its in-flight tmux command
    /// returns. Successors await that drain so an older styling command can
    /// never land after a newer one and reapply stale colors.
    private func cancelTmuxPresentationTasks(handleID: UUID) {
        guard let task = deferredTmuxPresentationTasks.removeValue(
            forKey: handleID
        ) else { return }
        task.cancel()
        drainingDeferredTmuxPresentationTasks[handleID] = task
    }

    /// The predecessor must be captured synchronously at successor creation:
    /// reading the draining map from inside the successor's closure can find
    /// the successor itself (cancelled before it first ran) and self-deadlock.
    private func settleSupersededTmuxPresentationTask(
        _ superseded: Task<Void, Never>?,
        handleID: UUID
    ) async {
        guard let superseded else { return }
        await superseded.value
        if drainingDeferredTmuxPresentationTasks[handleID] == superseded {
            drainingDeferredTmuxPresentationTasks.removeValue(
                forKey: handleID
            )
        }
    }

    /// Deferred styling is one-shot and best-effort. It retries briefly while
    /// kwt finishes creating or repairing the session, revalidates the style
    /// policy before every attempt, and otherwise leaves the explicit
    /// Apply Theme action as the recovery path.
    private func applyDeferredTmuxPresentationsIfReady() {
        for presentation in retainedTmuxPresentations.values {
            applyDeferredTmuxPresentationIfReady(presentation)
        }
    }

    private func applyDeferredTmuxPresentationIfReady(
        _ presentation: RetainedTmuxPresentation
    ) {
        let handle = presentation.handle
        let selection = presentation.selection
        guard nativeTmuxSessionCoordinator.hasDeferredPresentationStyle(
            handle
        ),
            nativeTmuxSessionCoordinator.shouldApplyPresentationStyle(
                handle
            ),
            deferredTmuxPresentationTasks[handle.id] == nil,
            pendingCreatedTmuxSessions[handle.id] == nil,
            borrowedTmuxConnectionStates[handle.id] == .connected,
            let hostSummary = snapshot.host(id: selection.hostID),
            let host = CommandHostResolver.resolve(hostSummary),
            Self.supportsTmuxSessionStyling(host),
            let surfaceIdentity = nativeTmuxSessionCoordinator
            .surfaceIdentity(handle: handle),
            let style = tmuxPresentationStyleProvider(surfaceIdentity)
        else { return }
        let capturedIdentity = Self.discoveredTmuxSessionIdentity(
            selection,
            hostSummary: hostSummary
        )
        let identityReader = tmuxSessionIdentityReader
        let styler = tmuxSessionStyler
        let retryDelays = deferredTmuxPresentationRetryDelays
        let superseded = drainingDeferredTmuxPresentationTasks[handle.id]
        deferredTmuxPresentationTasks[handle.id] = Task { [weak self] in
            await self?.settleSupersededTmuxPresentationTask(
                superseded,
                handleID: handle.id
            )
            // Success and exhaustion both consume the deferred marker so a
            // persistently failing session cannot re-run the ladder on every
            // later trigger. An interrupted ladder (cancellation or
            // disconnect) leaves the marker for the next eligible trigger.
            var consumesMarker = false
            var expectedIdentity = capturedIdentity
            for attempt in 0 ... retryDelays.count {
                guard let self,
                      !Task.isCancelled,
                      retainedTmuxPresentation(for: handle) === presentation,
                      borrowedTmuxConnectionStates[handle.id] == .connected,
                      nativeTmuxSessionCoordinator
                      .hasDeferredPresentationStyle(handle),
                      nativeTmuxSessionCoordinator
                      .shouldApplyPresentationStyle(handle),
                      let currentHostSummary = snapshot.host(
                          id: selection.hostID
                      ),
                      CommandHostResolver.resolve(currentHostSummary) == host
                else { break }
                do {
                    let identity: TmuxSessionIdentity
                    if let expectedIdentity {
                        identity = expectedIdentity
                    } else {
                        // Pin the first read for the whole ladder: re-reading
                        // after a failure could adopt a same-name replacement
                        // session's identity and defeat the identity check.
                        identity = try await identityReader(selection, host)
                        expectedIdentity = identity
                    }
                    try Task.checkCancellation()
                    try await styler(style, selection, identity, host)
                    consumesMarker = true
                    break
                } catch TmuxSessionStyleError.sessionChanged {
                    // The armed session is gone; retrying could only style a
                    // replacement. Give up and leave recovery to the manual
                    // action.
                    consumesMarker = !Task.isCancelled
                    break
                } catch {
                    guard attempt < retryDelays.count else {
                        consumesMarker = !Task.isCancelled
                        break
                    }
                    do {
                        try await Task.sleep(for: retryDelays[attempt])
                    } catch {
                        break
                    }
                }
            }
            // A cancelled task was already unregistered by its canceller and
            // must not remove a successor task from the map.
            guard let self, !Task.isCancelled else { return }
            deferredTmuxPresentationTasks.removeValue(forKey: handle.id)
            if consumesMarker {
                nativeTmuxSessionCoordinator
                    .markDeferredPresentationStyleApplied(handle)
            }
        }
    }

    private func reconcileCreatedTmuxSession(
        handleID: UUID,
        immediately: Bool = false
    ) {
        guard let pending = pendingCreatedTmuxSessions[handleID],
              let host = inventoryHosts[pending.selection.hostID]
              ?? snapshot.host(id: pending.selection.hostID).flatMap(
                  CommandHostResolver.resolve
              )
        else { return }
        createdSessionDiscoveryTasks.removeValue(
            forKey: handleID
        )?.cancel()
        exhaustedCreatedTmuxSessionHandles.remove(handleID)
        let discovery = tmuxSessionDiscovery
        let delays: [Duration] = immediately
            ? [.zero] + createdSessionDiscoveryDelays
            : createdSessionDiscoveryDelays
        createdSessionDiscoveryTasks[handleID] = Task { [weak self] in
            for (index, delay) in delays.enumerated() {
                do {
                    try await Task.sleep(for: delay)
                } catch {
                    return
                }
                guard let self,
                      pendingCreatedTmuxSessions[handleID] == pending
                else { return }
                let observationSequence = beginTmuxDiscoveryObservation(
                    hostID: pending.selection.hostID
                )
                let epoch = workspaceInventoryStore.tmuxRefreshEpoch(on: host)
                let probe = Task.detached(priority: .utility) {
                    await discovery(host)
                }
                let result = await withTaskCancellationHandler {
                    await probe.value
                } onCancel: {
                    probe.cancel()
                }
                guard !Task.isCancelled,
                      pendingCreatedTmuxSessions[handleID] == pending
                else { return }
                guard isCurrentTmuxDiscoveryObservation(
                    observationSequence,
                    hostID: pending.selection.hostID
                ),
                    workspaceInventoryStore.tmuxRefreshEpoch(on: host) == epoch
                else {
                    if index == delays.indices.last {
                        createdSessionDiscoveryTasks.removeValue(
                            forKey: handleID
                        )
                        exhaustedCreatedTmuxSessionHandles.insert(handleID)
                        fenceTmuxDiscoveryForCreationReconciliation(host: host)
                        return
                    }
                    continue
                }
                switch result {
                case let .success(discovered):
                    recordTmuxDiscoveryState(
                        .success(discovered),
                        hostID: pending.selection.hostID
                    )
                    let found = discovered.contains {
                        $0.name == pending.selection.name
                    }
                    let isLastAttempt = index == delays.indices.last
                    if !found, isLastAttempt {
                        exhaustedCreatedTmuxSessionHandles.insert(
                            handleID
                        )
                    }
                    tmuxSessionsByHost[pending.selection.hostID] =
                        reconciledTmuxSessions(
                            discovered,
                            hostID: pending.selection.hostID
                        )
                    applyInventoryOverlayIfNeeded()
                    updateWorkspaceInventoryState()
                    workspaceInventoryStore.publishTmuxSessions(
                        discovered,
                        on: host,
                        epoch: epoch
                    )
                    if found {
                        applyDeferredTmuxPresentationsIfReady()
                    }
                    fenceTmuxDiscoveryForCreationReconciliation(host: host)
                    if found || isLastAttempt {
                        createdSessionDiscoveryTasks.removeValue(
                            forKey: handleID
                        )
                        return
                    }
                case let .failure(error):
                    recordTmuxDiscoveryState(
                        .failure(error),
                        hostID: pending.selection.hostID
                    )
                    applyRuntimeInventoryOverlayIfNeeded(
                        hostID: pending.selection.hostID
                    )
                    updateWorkspaceInventoryState()
                    fenceTmuxDiscoveryForCreationReconciliation(host: host)
                }
            }
            guard let self,
                  pendingCreatedTmuxSessions[handleID] == pending
            else { return }
            createdSessionDiscoveryTasks.removeValue(forKey: handleID)
            exhaustedCreatedTmuxSessionHandles.insert(handleID)
            fenceTmuxDiscoveryForCreationReconciliation(host: host)
        }
    }

    private func reconciledTmuxSessions(
        _ discovered: [DiscoveredTmuxSession],
        hostID: UUID
    ) -> [TmuxSessionSummary] {
        var summaries = discovered.map { session in
            TmuxSessionSummary(
                name: session.name,
                managed: session.managed,
                windows: (0 ..< session.windowCount).map { offset in
                    TmuxWindowSummary(
                        id: "discovered-\(offset)",
                        index: offset,
                        name: ""
                    )
                },
                serverPID: session.serverPID,
                sessionID: session.sessionID,
                createdAt: session.createdAt,
                activeWindowSize: session.activeWindowSize,
                previewClientSize: session.previewClientSize
            )
        }
        let discoveredNames = Set(summaries.map(\.name))
        let pendingForHost = pendingCreatedTmuxSessions.filter {
            $0.value.selection.hostID == hostID
        }
        for (handleID, pending) in pendingForHost {
            if discoveredNames.contains(pending.selection.name) {
                confirmPendingTmuxCreation(
                    handleID: handleID,
                    selection: pending.selection
                )
            } else if pending.initialCommand == nil,
                      exhaustedCreatedTmuxSessionHandles.contains(handleID),
                      endedCreatedTmuxSessionHandles.contains(handleID) {
                pendingCreatedTmuxSessions.removeValue(forKey: handleID)
                createdSessionDiscoveryTasks.removeValue(
                    forKey: handleID
                )?.cancel()
                exhaustedCreatedTmuxSessionHandles.remove(handleID)
                endedCreatedTmuxSessionHandles.remove(handleID)
            } else {
                summaries.append(TmuxSessionSummary(
                    name: pending.selection.name,
                    managed: false,
                    windows: []
                ))
            }
        }
        return summaries
    }

    private func publishCreatedTmuxSession(
        _ selection: WorkspaceTmuxSessionSelection
    ) -> Bool {
        var sessions = tmuxSessionsByHost[selection.hostID]
            ?? snapshot.host(id: selection.hostID)?.tmuxSessions
            ?? []
        guard !sessions.contains(where: { $0.name == selection.name }) else {
            return false
        }
        sessions.append(TmuxSessionSummary(
            name: selection.name,
            managed: false,
            windows: []
        ))
        tmuxSessionsByHost[selection.hostID] = sessions
        applyInventoryOverlayIfNeeded()
        return true
    }

    private func removeOptimisticTmuxSession(
        _ selection: WorkspaceTmuxSessionSelection
    ) {
        tmuxSessionsByHost[selection.hostID]?.removeAll {
            $0.name == selection.name
        }
        if let hostIndex = snapshot.hosts.firstIndex(where: {
            $0.id == selection.hostID
        }) {
            snapshot.hosts[hostIndex].tmuxSessions.removeAll {
                $0.name == selection.name
            }
        }
        applyInventoryOverlayIfNeeded()
    }

    func retryBorrowedTmuxSession(
        _ selection: WorkspaceTmuxSessionSelection
    ) {
        guard !activeBorrowedTmuxRetryRequiresConfirmation else { return }
        retryBorrowedTmuxSession(
            selection,
            confirmedPendingCreation: nil
        )
    }

    func retryBorrowedTmuxSessionAfterProfileCommandConfirmation(
        _ selection: WorkspaceTmuxSessionSelection
    ) {
        guard activeBorrowedTmuxRetryRequiresConfirmation,
              let activePending = activePendingTmuxCreation,
              Self.sameTmuxSession(
                  activePending.pending.selection,
                  selection
              )
        else { return }
        var pendingCreation = activePending.pending
        pendingCreation.commandReplayAuthorized = true
        pendingCreatedTmuxSessions[activePending.handleID] = pendingCreation
        retryBorrowedTmuxSession(
            selection,
            confirmedPendingCreation: pendingCreation
        )
    }

    private func retryBorrowedTmuxSession(
        _ selection: WorkspaceTmuxSessionSelection,
        confirmedPendingCreation: PendingTmuxSessionCreation?
    ) {
        guard activeBorrowedTmuxSelection == selection else { return }
        if let confirmedPendingCreation,
           let activePending = activePendingTmuxCreation,
           activePending.pending == confirmedPendingCreation {
            var consumedPendingCreation = confirmedPendingCreation
            consumedPendingCreation.commandReplayAuthorized = false
            pendingCreatedTmuxSessions[activePending.handleID] =
                consumedPendingCreation
        }
        let sessionConfirmedEnded = activeBorrowedTmuxHandle.map {
            confirmedEndedTmuxSessionHandles.contains($0.id)
        } == true
        let pendingCreation = confirmedPendingCreation
            ?? activeBorrowedTmuxHandle.flatMap {
                pendingCreatedTmuxSessions[$0.id]
            } ?? pendingCreatedTmuxSessions.values.first {
                Self.sameTmuxSession($0.selection, selection)
            }
        let recreateEndedNamedSession =
            sessionConfirmedEnded
                && selection.socketName == nil
                && selection.worktreeID == nil
                && selection.workspacePath == nil
        let launchMode: TmuxAttachmentLaunchMode =
            confirmedPendingCreation == nil
                ? Self.retryLaunchMode(
                    for: selection,
                    current: activeBorrowedTmuxLaunchMode,
                    sessionConfirmedEnded: sessionConfirmedEnded
                )
                : .create
        invalidateBorrowedTmuxSession(selection)
        if recreateEndedNamedSession {
            guard let handle = presentTmuxSession(
                selection,
                launchMode: .create,
                initialCommand: pendingCreation?.initialCommand,
                commandReplayAuthorized:
                pendingCreation?.commandReplayAuthorized == true
            ) else { return }
            pendingCreatedTmuxSessions[handle.id] =
                PendingTmuxSessionCreation(
                    request: pendingCreation?.request
                        ?? WorkspaceTmuxSessionCreationRequest(
                            selection: selection
                        ),
                    commandReplayAuthorized: false
                )
            _ = publishCreatedTmuxSession(selection)
            return
        }
        switch launchMode {
        case .create:
            createTmuxSession(
                pendingCreation?.request
                    ?? WorkspaceTmuxSessionCreationRequest(
                        selection: selection
                    ),
                commandReplayAuthorized:
                pendingCreation?.commandReplayAuthorized == true
            )
        case .attach, .attachOnly:
            presentTmuxSession(selection, launchMode: launchMode)
        }
    }

    static func retryLaunchMode(
        for selection: WorkspaceTmuxSessionSelection,
        current: TmuxAttachmentLaunchMode?,
        sessionConfirmedEnded: Bool
    ) -> TmuxAttachmentLaunchMode {
        if sessionConfirmedEnded, selection.workspacePath != nil {
            return .attach
        }
        return current ?? .attach
    }

    private var isApplicationActiveForResourceMonitoring: Bool {
        #if canImport(AppKit)
        NSApplication.shared.isActive
        #else
        true
        #endif
    }

}
