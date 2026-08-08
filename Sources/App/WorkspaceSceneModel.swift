@preconcurrency import Combine
import Foundation
import OSLog
import SwiftUI
import GhosthubPersistence
import GhosthubSettings
import GhosthubTerminal
import GhosthubTerminalSupport
import GhosthubTmux
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

enum TmuxSessionThemeError: Error, Equatable, LocalizedError {
    case unavailable(session: String)

    var errorDescription: String? {
        switch self {
        case let .unavailable(session):
            return "The theme cannot be applied to session “\(session)”"
                + " because its active tmux attachment is unavailable."
        }
    }
}

struct WorkspaceInventoryRefreshProgress: Equatable {
    var kwtCompleted = false
    var tmuxCompleted = false

    var isComplete: Bool {
        kwtCompleted && tmuxCompleted
    }
}

enum BorrowedTmuxRecoveryState: Equatable {
    case reconnecting(message: String)
    case needsAttention(message: String, canReviewConnection: Bool)

    var isReconnecting: Bool {
        if case .reconnecting = self {
            return true
        }
        return false
    }

    var allowsReconnectNow: Bool {
        switch self {
        case .reconnecting:
            true
        case let .needsAttention(_, canReviewConnection):
            !canReviewConnection
        }
    }
}

@MainActor
final class WorktreeMutationCoordinator {
    struct Scope: Hashable, Sendable {
        let hostID: UUID
        let projectIdentity: String
    }

    typealias RemovalTombstone = KwtWorktreeIdentity

    enum Phase: Sendable {
        case began
        case willRemove
        case ended
    }

    struct Event: Sendable {
        let phase: Phase
        let scope: Scope
        let removalTombstones: Set<RemovalTombstone>
        let removalPresentationTargets: Set<WorkspaceTmuxSessionSelection>
        let requiresWorkspaceReestablishment: Bool
    }

    static let shared = WorktreeMutationCoordinator()

    private var activeScopes: Set<Scope> = []
    private var pendingRemovalsByScope: [Scope: Set<RemovalTombstone>] = [:]
    private let eventSubject = PassthroughSubject<Event, Never>()

    var events: AnyPublisher<Event, Never> {
        eventSubject.eraseToAnyPublisher()
    }

    var scopes: Set<Scope> {
        activeScopes
    }

    var pendingRemovals: [Scope: Set<RemovalTombstone>] {
        pendingRemovalsByScope
    }

    func acquire(
        hostID: UUID,
        projectIdentity: String
    ) -> Bool {
        let scope = Scope(
            hostID: hostID,
            projectIdentity: projectIdentity
        )
        let inserted = activeScopes.insert(scope).inserted
        if inserted {
            eventSubject.send(
                Event(
                    phase: .began,
                    scope: scope,
                    removalTombstones: [],
                    removalPresentationTargets: [],
                    requiresWorkspaceReestablishment: false
                )
            )
        }
        return inserted
    }

    func release(
        hostID: UUID,
        projectIdentity: String,
        removalTombstones: Set<RemovalTombstone> = [],
        requiresWorkspaceReestablishment: Bool = false
    ) {
        let scope = Scope(
            hostID: hostID,
            projectIdentity: projectIdentity
        )
        if activeScopes.remove(scope) != nil {
            pendingRemovalsByScope.removeValue(forKey: scope)
            eventSubject.send(
                Event(
                    phase: .ended,
                    scope: scope,
                    removalTombstones: removalTombstones,
                    removalPresentationTargets: [],
                    requiresWorkspaceReestablishment:
                    requiresWorkspaceReestablishment
                )
            )
        }
    }

    func prepareRemoval(
        hostID: UUID,
        projectIdentity: String,
        worktrees: Set<RemovalTombstone>,
        presentationTargets: Set<WorkspaceTmuxSessionSelection>
    ) {
        let scope = Scope(
            hostID: hostID,
            projectIdentity: projectIdentity
        )
        guard activeScopes.contains(scope), !worktrees.isEmpty else { return }
        pendingRemovalsByScope[scope, default: []].formUnion(worktrees)
        eventSubject.send(
            Event(
                phase: .willRemove,
                scope: scope,
                removalTombstones: worktrees,
                removalPresentationTargets: presentationTargets,
                requiresWorkspaceReestablishment: false
            )
        )
    }
}

@MainActor
final class WorkspaceSceneModel: ObservableObject {
    typealias KwtInventoryLoader = @Sendable (
        TmuxHost
    ) async throws -> KwtHostInventory
    typealias KwtRemoteProvisioner = @Sendable (
        SSHHost
    ) async throws -> Void
    typealias KwtWorktreeCreator = @Sendable (
        WorktreeCreateRequest, String, TmuxHost
    ) async throws -> Void
    typealias KwtWorktreeRemover = @Sendable (
        String, String, String, TmuxHost
    ) async throws -> Void
    typealias KwtBranchLister = @Sendable (
        String, TmuxHost
    ) async throws -> [WorktreeBranchCandidate]
    typealias KwtPullRequestLister = @Sendable (
        String, TmuxHost
    ) async throws -> [PullRequestCandidate]
    typealias KwtPullRequestImporter = @Sendable (
        String, String, TmuxHost
    ) async throws -> KwtPullRequestImportResult
    typealias KwtProjectRegistration = @Sendable (
        String, TmuxHost
    ) async throws -> KwtProjectRecord
    typealias TmuxSessionDiscovery = @Sendable (
        TmuxHost
    ) async -> Result<[DiscoveredTmuxSession], TmuxBinaryError>
    typealias TmuxSessionExactProbe = @Sendable (
        TmuxSessionProbeTarget
    ) -> Result<Bool, TmuxBinaryError>
    typealias TmuxSessionKilling = @Sendable (
        WorkspaceTmuxSessionSelection, TmuxSessionIdentity, TmuxHost
    ) async throws -> Void
    typealias TmuxSessionIdentityReading = @Sendable (
        WorkspaceTmuxSessionSelection, TmuxHost
    ) async throws -> TmuxSessionIdentity
    typealias TmuxSessionStyling = @Sendable (
        TmuxPresentationStyle, WorkspaceTmuxSessionSelection,
        TmuxSessionIdentity, TmuxHost
    ) async throws -> Void
    typealias SSHHostProbeRunner = @Sendable (
        SSHHostInfo, String
    ) -> (status: Int32, stdout: String, stderr: String)

    @Published var snapshot: WorkspaceSnapshot {
        didSet {
            reconcileInventoryHosts()
        }
    }
    private var tmuxDiscoveryEnabled = false
    private var isApplyingInventoryOverlay = false
    private var inventoryHosts: [UUID: TmuxHost] = [:]
    private var tmuxSessionsByHost: [UUID: [TmuxSessionSummary]] = [:]
    private var tmuxReachabilityByHost: [UUID: Bool] = [:]
    private var tmuxLastSeenByHost: [UUID: Date] = [:]
    private var tmuxDiscoveryFailuresByHost: [UUID: String] = [:]
    private var isTmuxDiscoveryLoading = false
    private var inventoryRefreshProgress = WorkspaceInventoryRefreshProgress()
    private var tmuxDiscoveryGeneration = 0
    private var tmuxDiscoveryTask: Task<Void, Never>?
    private var createdSessionDiscoveryTasks: [UUID: Task<Void, Never>] = [:]
    private var exhaustedCreatedTmuxSessionHandles: Set<UUID> = []
    private var endedCreatedTmuxSessionHandles: Set<UUID> = []
    private var confirmedEndedTmuxSessionHandles: Set<UUID> = []
    private let createdSessionDiscoveryDelays: [Duration]
    private let tmuxSessionProbeBroker: TmuxSessionProbeBroker
    private let tmuxReconnectIntervals: [Duration]
    private let tmuxReconnectProbeDeadline: Duration
    @Published private(set) var workspaceInventoryState:
        WorkspaceInventoryState = .loading
    @Published private(set) var workspaceInventoryWarning: String?
    @Published private(set) var workspaceInventoryWarningsByHost:
        [UUID: String] = [:]
    private var kwtInventoryEnabled = false
    private var kwtInventoryGeneration = 0
    private var kwtInventoryTask: Task<Void, Never>?
    private var kwtInventoriesByHost: [UUID: KwtHostInventory] = [:]
    private var kwtAvailabilityByHost: [UUID: Bool] = [:]
    private var kwtInventoryFailuresByHost: [UUID: String] = [:]
    private var isKwtInventoryLoading = false
    private var ownsWorktreeMutation = false
    private let worktreeMutationCoordinator: WorktreeMutationCoordinator
    private var fencedWorktreeMutationScopes:
        Set<WorktreeMutationCoordinator.Scope> = []
    private var worktreeRemovalTombstones:
        [
            WorktreeMutationCoordinator.Scope:
                Set<WorktreeMutationCoordinator.RemovalTombstone>
        ] = [:]

    var isWorkspaceInventoryRefreshComplete: Bool {
        inventoryRefreshProgress.isComplete
            && !isKwtInventoryLoading
            && !isTmuxDiscoveryLoading
            && kwtInventoryFailuresByHost.isEmpty
            && tmuxDiscoveryFailuresByHost.isEmpty
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
        [UUID: ConnectionState] = [:]
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
        BorrowedTmuxRecoveryState?
    @Published private(set) var tmuxConnectionRecoveryRequest:
        TmuxConnectionRecoveryRequest?
    private enum RemoteTmuxEstablishmentPhase: Equatable {
        case establishingWorkspace
        case establishingProfile(initialCommand: String)
        case attachOnly
    }
    private struct TmuxReconnectContext: Equatable {
        var selection: WorkspaceTmuxSessionSelection
        var handleID: UUID
        var host: TmuxHost
        var phase: RemoteTmuxEstablishmentPhase
        var surfaceExitCode: UInt32?
    }
    private struct TmuxPresentationKey: Hashable {
        var hostID: UUID
        var name: String
        var socketName: String?

        init(_ selection: WorkspaceTmuxSessionSelection) {
            hostID = selection.hostID
            name = selection.name
            socketName = selection.socketName
        }
    }
    private final class RetainedTmuxPresentation {
        var selection: WorkspaceTmuxSessionSelection
        var handle: BorrowedTmuxSessionHandle
        var launchMode: TmuxAttachmentLaunchMode
        var reconnectContext: TmuxReconnectContext?
        var recoveryState: BorrowedTmuxRecoveryState?
        var recoveryRequest: TmuxConnectionRecoveryRequest?
        let reconnectSupervisor: TmuxSessionReconnectSupervisor
        var establishmentConfirmationTask: Task<Void, Never>?

        init(
            selection: WorkspaceTmuxSessionSelection,
            handle: BorrowedTmuxSessionHandle,
            launchMode: TmuxAttachmentLaunchMode,
            reconnectContext: TmuxReconnectContext?,
            reconnectSupervisor: TmuxSessionReconnectSupervisor
        ) {
            self.selection = selection
            self.handle = handle
            self.launchMode = launchMode
            self.reconnectContext = reconnectContext
            self.reconnectSupervisor = reconnectSupervisor
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
        [
            WorktreeMutationCoordinator.Scope:
                [TmuxPresentationKey: PendingRemovalPresentation]
        ] = [:]
    private var userNavigationRevision: UInt64 = 0
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
    private var protectedRestorationProbeTask: Task<Void, Never>?
    private var protectedRestorationProbeID: UUID?
    private var protectedRestorationRefreshPending = false
    var activeBorrowedTmuxSessionIsConnected: Bool {
        guard let handle = activeBorrowedTmuxHandle else {
            return false
        }
        return borrowedTmuxConnectionStates[handle.id] == .connected
    }
    var canSplitActiveTmuxPane: Bool {
        guard let selection = activeBorrowedTmuxSelection,
              isConnectedActiveTmuxSession(selection),
              let handle = activeBorrowedTmuxHandle,
              nativeTmuxSessionCoordinator.supportsPaneSplitting(handle)
        else { return false }
        return true
    }

    func splitActiveTmuxPane(
        _ shortcut: TerminalTmuxSplitShortcut,
        requiresKeyboardFocus: Bool = false
    ) {
        guard canSplitActiveTmuxPane,
              let handle = activeBorrowedTmuxHandle
        else { return }
        nativeTmuxSessionCoordinator.requestPaneSplit(
            shortcut,
            handle: handle,
            requiresKeyboardFocus: requiresKeyboardFocus
        )
    }

    var canApplyThemeToActiveTmuxSession: Bool {
        guard let selection = activeBorrowedTmuxSelection,
              isConnectedActiveTmuxSession(selection),
              let hostSummary = snapshot.host(id: selection.hostID),
              let host = TmuxHostResolver.resolve(hostSummary),
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
            guard isFocusedWindow, !oldValue else { return }
            syncTerminalConfig()
        }
    }
    @Published var selection: WorkspaceSelection {
        didSet {
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
    let localHostID: UUID
    private let notificationService: NotificationService
    private let tmuxSessionActivityController:
        TmuxSessionActivityController?
    private let kwtInventoryLoader: KwtInventoryLoader
    private let kwtRemoteProvisioner: KwtRemoteProvisioner
    private let kwtWorktreeCreator: KwtWorktreeCreator
    private let kwtWorktreeRemover: KwtWorktreeRemover
    private let kwtBranchLister: KwtBranchLister
    private let kwtPullRequestLister: KwtPullRequestLister
    private let kwtPullRequestImporter: KwtPullRequestImporter
    private let kwtProjectRegistration: KwtProjectRegistration
    private let tmuxSessionDiscovery: TmuxSessionDiscovery
    private let tmuxSessionKiller: TmuxSessionKilling
    private let tmuxSessionIdentityReader: TmuxSessionIdentityReading
    private let tmuxSessionStyler: TmuxSessionStyling
    private let tmuxPresentationStyleProvider:
        (UInt?) -> TmuxPresentationStyle?
    private let sshHostProbeRunner: SSHHostProbeRunner
    private let sshAuthenticationCoordinator: SSHAuthenticationCoordinator
    private let sshAuthenticationScopeID = UUID()
    private var pendingSSHAuthenticationTargets:
        [String: SSHAuthenticationTarget] = [:]
    private var configuredSSHAuthenticationTargets:
        [String: SSHAuthenticationTarget] = [:]
    private var sshAuthenticationControlPaths:
        [SSHAuthenticationTarget: String] = [:]
    private let configuredSSHHostsProvider: () -> [SSHHost]
    private var configuredSSHHostsCancellable: AnyCancellable?
    private let configuredExeHostsProvider: () -> [ExeConfiguredHost]
    private let refreshExeHosts: () -> Void
    private let startExeHostInventory: () -> Void
    private var configuredExeHostsCancellable: AnyCancellable?
    private var terminalColorsCancellable: AnyCancellable?
    private var deferredTmuxPresentationTasks: [UUID: Task<Void, Never>] = [:]
    private var drainingDeferredTmuxPresentationTasks:
        [UUID: Task<Void, Never>] = [:]
    private var tmuxActivityEnrollmentTasks:
        [UUID: Task<Void, Never>] = [:]
    private let deferredTmuxPresentationRetryDelays: [Duration]
    private var worktreeMutationCancellable: AnyCancellable?
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
    private var activityCancellable: AnyCancellable?
    private var tmuxSessionActivityCancellable: AnyCancellable?
    private var panelRoutingCancellable: AnyCancellable?
    var isAppActive = true
    var childExitCancellable: AnyCancellable?
    var appDidBecomeActiveCancellable: AnyCancellable?
    var appDidResignActiveCancellable: AnyCancellable?
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
    convenience init(
        terminalRuntime: LibghosttyRuntime = .shared,
        sshAuthenticationCoordinator: SSHAuthenticationCoordinator
    ) {
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
                sshAuthenticationCoordinator: sshAuthenticationCoordinator,
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
        nativeTmuxSurfaceStore: (any TmuxSurfaceStoring)? = nil,
        nativeTmuxPathProvider:
        (@Sendable () -> Result<ResolvedTmuxBinary, TmuxBinaryError>)? = nil,
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
        kwtInventoryLoader: @escaping KwtInventoryLoader = { host in
            try await KwtInventoryClient().load(from: host)
        },
        kwtRemoteProvisioner: @escaping KwtRemoteProvisioner = { host in
            try await KwtRemoteProvisioningCoordinator.shared
                .ensureInstalled(on: host)
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
            worktreePath, generation, projectPath, host in
            try await KwtWorktreeClient().remove(
                worktreePath: worktreePath,
                generation: generation,
                projectPath: projectPath,
                on: host
            )
        },
        worktreeMutationCoordinator: WorktreeMutationCoordinator = .shared,
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
            try await KwtProjectRegistrar().register(
                projectPath: projectPath,
                on: host
            )
        },
        tmuxSessionDiscovery: @escaping TmuxSessionDiscovery = { host in
            let resolver = TmuxBinaryResolver()
            return switch host {
            case .local:
                resolver.discoverSessions()
            case let .ssh(info):
                resolver.discoverSessions(on: info)
            }
        },
        tmuxExactSessionProbe: @escaping TmuxSessionExactProbe = { target in
            TmuxBinaryResolver().sessionExists(
                name: target.name,
                socketName: target.socketName,
                on: target.host
            )
        },
        tmuxSessionKiller: @escaping TmuxSessionKilling = {
            selection, identity, host in
            try await TmuxSessionKiller().kill(
                selection,
                expectedIdentity: identity,
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
        tmuxSessionStyler: @escaping TmuxSessionStyling = {
            style, selection, identity, host in
            try await TmuxSessionStyler().apply(
                style,
                to: selection,
                expectedIdentity: identity,
                on: host
            )
        },
        sshHostProbeRunner: @escaping SSHHostProbeRunner = { host, command in
            TmuxBinaryResolver.runRemoteLoginShellSeparatingStandardError(
                host: host,
                command: command,
                timeout: 10
            )
        },
        sshAuthenticationCoordinator: SSHAuthenticationCoordinator =
            SSHAuthenticationCoordinator(),
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
            TmuxSessionReconnectSupervisor.defaultProbeDeadline,
        startServices: Bool = false
    ) throws {
        self.database = database
        panelPreferenceStore = PanelPreferenceStore(database: database)
        panelRoutingService = PanelRoutingService(
            preferenceStore: panelPreferenceStore
        )
        self.workspaceConfiguration = workspaceConfiguration
        self.worktreeMutationCoordinator = worktreeMutationCoordinator
        self.sceneSettings = sceneSettings
        self.terminalRuntime = terminalRuntime
        self.kwtInventoryLoader = kwtInventoryLoader
        self.kwtRemoteProvisioner = kwtRemoteProvisioner
        self.kwtWorktreeCreator = kwtWorktreeCreator
        self.kwtWorktreeRemover = kwtWorktreeRemover
        self.kwtBranchLister = kwtBranchLister
        self.kwtPullRequestLister = kwtPullRequestLister
        self.kwtPullRequestImporter = kwtPullRequestImporter
        self.kwtProjectRegistration = kwtProjectRegistration
        self.tmuxSessionDiscovery = tmuxSessionDiscovery
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
                    tmuxExactSessionProbe(target)
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
        self.tmuxSessionKiller = tmuxSessionKiller
        self.tmuxSessionIdentityReader = tmuxSessionIdentityReader
        self.tmuxSessionStyler = tmuxSessionStyler
        self.tmuxPresentationStyleProvider =
            tmuxPresentationStyleProvider
        self.sshHostProbeRunner = sshHostProbeRunner
        self.sshAuthenticationCoordinator = sshAuthenticationCoordinator
        self.createdSessionDiscoveryDelays =
            createdSessionDiscoveryDelays
        self.deferredTmuxPresentationRetryDelays =
            deferredTmuxPresentationRetryDelays
        self.configuredSSHHostsProvider = configuredSSHHostsProvider
        self.configuredExeHostsProvider = configuredExeHostsProvider
        self.refreshExeHosts = refreshExeHosts
        self.startExeHostInventory = startExeHostInventory
        terminalCoordinator = TerminalSurfaceCoordinator(runtime: terminalRuntime)
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
            remoteTmuxPathProvider: remoteTmuxPathProvider
        )
        nativeTmuxSessionCoordinatorBacking?.onStateChanged = {
            [weak self] handle, state in
            self?.nativeTmuxStateChanged(handle: handle, state: state)
        }
        nativeTmuxSessionCoordinatorBacking?.onSurfaceReady = {
            [weak self] handle in
            guard let self,
                  retainedTmuxPresentation(for: handle) != nil
            else { return }
            _ = nativeTmuxSessionCoordinator.surface(handle: handle)
            if activeBorrowedTmuxHandle == handle {
                objectWillChange.send()
            }
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
        fencedWorktreeMutationScopes = worktreeMutationCoordinator.scopes
        pendingWorktreeRemovals = worktreeMutationCoordinator.pendingRemovals
        let sshHostsPublisher = configuredSSHHostsPublisher
            ?? SettingsStore.shared.$sshHosts.eraseToAnyPublisher()
        let exeHostsPublisher = configuredExeHostsPublisher
            ?? ExeVMInventoryStore.shared.$hosts.eraseToAnyPublisher()
        // Defer post-init work that mutates @Published state to
        // avoid "Publishing changes from within view updates" when
        // @StateObject creates the model during body evaluation.
        DispatchQueue.main.async {
            [self, sshHostsPublisher, exeHostsPublisher] in
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
                startKwtInventory()
                syncTerminalConfig()
                startResourceMonitoringLoop()
                activityController.startOutputFlushLoop()
                subscribeChildExitEvents()
                subscribeAppActivity()
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
        worktreeMutationCancellable?.cancel()
        kwtInventoryTask?.cancel()
        tmuxDiscoveryTask?.cancel()
        createdSessionDiscoveryTasks.values.forEach { $0.cancel() }
        deferredTmuxPresentationTasks.values.forEach { $0.cancel() }
        tmuxActivityEnrollmentTasks.values.forEach { $0.cancel() }
        childExitCancellable?.cancel()
        appDidBecomeActiveCancellable?.cancel()
        appDidResignActiveCancellable?.cancel()
        shortcutMonitor?.uninstall()
        // Nil out controller backings so their deinits run now,
        // cancelling detached tasks that could fire closures
        // against this partially deallocated instance.
        activityControllerBacking = nil
    }

    func beginRestoration(_ state: WorkspaceWindowState) {
        guard state.navigation != nil || state.tmux != nil else { return }
        pendingRestoration = state
        isWorkspaceRestorationPending = true
        suppressesAutomaticWorktreeSessionOpen = true
        attemptPendingRestoration()
    }

    func cancelPendingRestoration() {
        pendingRestoration = nil
        isWorkspaceRestorationPending = false
        suppressesAutomaticWorktreeSessionOpen = false
        protectedRestorationProbeTask?.cancel()
        protectedRestorationProbeTask = nil
        protectedRestorationProbeID = nil
        protectedRestorationRefreshPending = false
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
            snapshot: snapshot
        )
    }

    func selectFromUser(_ newSelection: WorkspaceSelection) {
        cancelPendingRestoration()
        userNavigationRevision &+= 1
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
        selection = newSelection
    }

    private func applyRestoredSelection(_ restored: WorkspaceSelection) {
        selection = restored
    }

    private func attemptPendingRestoration() {
        guard let pendingRestoration else { return }
        guard protectedRestorationProbeTask == nil else {
            protectedRestorationRefreshPending = true
            return
        }
        switch WorkspaceWindowRestorationResolver.resolve(
            pendingRestoration,
            in: snapshot
        ) {
        case .invalid:
            cancelPendingRestoration()
        case let .pending(resolvedSelection):
            if let resolvedSelection {
                applyRestoredSelection(resolvedSelection)
            }
        case let .ready(resolvedSelection, tmuxSelection):
            applyRestoredSelection(resolvedSelection)
            if let tmuxSelection {
                _ = presentTmuxSession(
                    tmuxSelection,
                    launchMode: .attach,
                    intent: .restoreOnly
                )
                suppressesAutomaticWorktreeSessionOpen = false
            }
            self.pendingRestoration = nil
            isWorkspaceRestorationPending = false
        case let .needsProtectedProbe(resolvedSelection, tmuxSelection):
            beginProtectedRestorationProbe(
                selection: resolvedSelection,
                tmuxSelection: tmuxSelection,
                expectedState: pendingRestoration
            )
        }
    }

    private func beginProtectedRestorationProbe(
        selection resolvedSelection: WorkspaceSelection,
        tmuxSelection: WorkspaceTmuxSessionSelection,
        expectedState: WorkspaceWindowState
    ) {
        guard protectedRestorationProbeTask == nil,
              let hostSummary = snapshot.host(id: tmuxSelection.hostID),
              let host = TmuxHostResolver.resolve(hostSummary)
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
                  let currentHost = TmuxHostResolver.resolve(
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
        for presentation in retainedTmuxPresentations.values {
            cancelTmuxReconnect(presentation)
        }
        retainedTmuxPresentations.removeAll()
        retainedTmuxPresentationKeysByHandle.removeAll()
        pendingRemovalPresentationRestorations.removeAll()
        activeBorrowedTmuxSelection = nil
        activeBorrowedTmuxHandle = nil
        activeBorrowedTmuxLaunchMode = nil
        kwtInventoryTask?.cancel()
        tmuxDiscoveryTask?.cancel()
        createdSessionDiscoveryTasks.values.forEach { $0.cancel() }
        createdSessionDiscoveryTasks.removeAll()
        deferredTmuxPresentationTasks.values.forEach { $0.cancel() }
        deferredTmuxPresentationTasks.removeAll()
        tmuxActivityEnrollmentTasks.values.forEach { $0.cancel() }
        tmuxActivityEnrollmentTasks.removeAll()
        drainingDeferredTmuxPresentationTasks.removeAll()
        exhaustedCreatedTmuxSessionHandles.removeAll()
        endedCreatedTmuxSessionHandles.removeAll()
        confirmedEndedTmuxSessionHandles.removeAll()
        nativeTmuxSessionCoordinatorBacking?.shutdown()
        sshAuthenticationCoordinator.cancelAll(
            scopeID: sshAuthenticationScopeID
        )
    }

    /// Refreshes the sidebar from provider, kwt, and tmux inventories.
    func refreshWorkspaceInventory() {
        refreshHosts()
        refreshKwtInventory()
    }

    /// Refreshes the sidebar directly from each host's kwt and tmux inventory.
    func refreshKwtInventory() {
        scheduleKwtInventory()
        scheduleTmuxSessionDiscovery()
    }

    func startKwtInventory() {
        guard !kwtInventoryEnabled else { return }
        kwtInventoryEnabled = true
        let generation = kwtInventoryGeneration
        reconcileInventoryHosts()
        if generation == kwtInventoryGeneration {
            scheduleKwtInventory()
        }
    }

    func createWorktree(_ request: WorktreeCreateRequest) async throws {
        guard GitBranchName.isValid(request.branchName) else {
            throw KwtWorktreeError.invalidBranchName
        }
        guard let project = snapshot.project(id: request.projectID),
              snapshot.canCreateWorktree(in: project),
              let hostSummary = snapshot.host(id: project.hostID),
              let host = TmuxHostResolver.resolve(hostSummary)
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
        // The scene-wide refresh is cancelled so it cannot race the mutation,
        // and only the mutated host is reloaded inline. Every exit therefore
        // owes the remaining hosts a fresh sweep.
        invalidateKwtInventoryRefresh()
        defer {
            ownsWorktreeMutation = false
            worktreeMutationCoordinator.release(
                hostID: mutationHostID,
                projectIdentity: mutationProjectIdentity
            )
        }

        do {
            try await kwtWorktreeCreator(request, project.rootPath, host)
            cancelPendingRestoration()

            let refreshed = try await kwtInventoryLoader(host)
            applyAuthoritativeKwtInventory(
                refreshed,
                hostID: project.hostID
            )
            scheduleTmuxSessionDiscovery()
        } catch {
            if isRemoteKwtUnavailable(error, hostID: project.hostID) {
                kwtAvailabilityByHost[project.hostID] = false
                kwtInventoryFailuresByHost.removeValue(forKey: project.hostID)
                applyInventoryOverlayIfNeeded()
                updateWorkspaceInventoryState()
            }
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
              let host = TmuxHostResolver.resolve(hostSummary)
        else {
            throw KwtWorktreeError.projectUnavailable
        }
        return try await kwtBranchLister(project.rootPath, host)
    }

    func prepareWorktreeRemoval(
        _ worktreeID: UUID,
        refreshSessionIdentity: Bool = false
    ) async throws -> WorktreeRemovalRequest {
        guard let worktree = snapshot.worktree(id: worktreeID),
              let project = snapshot.project(id: worktree.projectID),
              let hostSummary = snapshot.host(id: worktree.hostID),
              let host = TmuxHostResolver.resolve(hostSummary)
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
                    let identity = try await tmuxSessionIdentityReader(
                        session,
                        host
                    )
                    sessionKillRequest = TmuxSessionKillRequest(
                        session: session,
                        confirmedHost: hostSummary,
                        serverPID: identity.serverPID,
                        sessionID: identity.sessionID,
                        sessionCreatedAt: identity.createdAt
                    )
                } catch TmuxSessionKillError.sessionNotRunning {
                    sessionKillRequest = nil
                }
            }
        } else {
            sessionKillRequest = nil
        }
        return WorktreeRemovalRequest(
            worktree: worktree,
            project: project,
            confirmedHost: hostSummary,
            sessionKillRequest: sessionKillRequest
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
            let currentHost = TmuxHostResolver.resolve(hostSummary)
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
        guard request.confirmedHost.id == requestedWorktree.hostID,
              let confirmedHost = TmuxHostResolver.resolve(
                  request.confirmedHost
              ),
              currentHost == confirmedHost
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
        var requiresWorkspaceReestablishment = false
        var terminatedSession = false
        invalidateKwtInventoryRefresh()
        defer {
            ownsWorktreeMutation = false
            worktreeMutationCoordinator.release(
                hostID: mutationHostID,
                projectIdentity: mutationProjectIdentity,
                removalTombstones: removalTombstones,
                requiresWorkspaceReestablishment:
                requiresWorkspaceReestablishment
            )
        }

        let preflight: KwtHostInventory
        do {
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
            if !checkoutAlreadyAbsent {
                do {
                    try await kwtWorktreeRemover(
                        worktree.path,
                        generation,
                        project.rootPath,
                        confirmedHost
                    )
                } catch {
                    requiresWorkspaceReestablishment = terminatedSession
                    throw error
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
        scheduleTmuxSessionDiscovery()
        guard !checkoutAlreadyAbsent else { return }

        do {
            let refreshed = try await kwtInventoryLoader(confirmedHost)
            applyAuthoritativeKwtInventory(
                refreshed,
                hostID: project.hostID,
                excludingWorktrees: [
                    KwtWorktreeIdentity(
                        path: worktree.path,
                        generation: generation
                    ),
                ]
            )
        } catch {
            if isRemoteKwtUnavailable(error, hostID: project.hostID) {
                kwtAvailabilityByHost[project.hostID] = false
            }
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
        } catch TmuxSessionKillError.sessionChanged,
            TmuxSessionKillError.sessionNotRunning {
            guard removalHostEndpointMatches(request) else {
                throw KwtWorktreeError.removalHostChanged
            }
            return await .confirmationRequired(
                try prepareWorktreeRemoval(
                    request.worktree.id,
                    refreshSessionIdentity: true
                )
            )
        } catch {
            guard let worktreeError = error as? KwtWorktreeError else {
                throw error
            }
            switch worktreeError {
            case .removalTargetChanged:
                guard removalHostEndpointMatches(request) else {
                    throw KwtWorktreeError.removalHostChanged
                }
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
            case .sessionStartedAfterConfirmation:
                guard removalHostEndpointMatches(request) else {
                    throw KwtWorktreeError.removalHostChanged
                }
                return await .confirmationRequired(
                    try prepareWorktreeRemoval(request.worktree.id)
                )
            default:
                throw error
            }
        }
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
        if let repositoryItem,
           let pathItem,
           repositoryItem.project.repository != pathItem.project.repository {
            applyAuthoritativeKwtInventory(inventory, hostID: hostID)
            throw KwtWorktreeError.removalTargetChanged
        }
        guard let item = repositoryItem ?? pathItem else {
            applyAuthoritativeKwtInventory(inventory, hostID: hostID)
            throw KwtWorktreeError.removalTargetChanged
        }
        if let warning = item.warning {
            throw KwtWorktreeError.removalPreflightUnavailable(
                host: request.confirmedHost.name,
                message: warning
            )
        }
        guard item.project.repository == request.project.scopedKey,
              item.project.path == request.project.rootPath
        else {
            applyAuthoritativeKwtInventory(inventory, hostID: hostID)
            throw KwtWorktreeError.removalTargetChanged
        }
        guard let record = item.worktrees.first(where: {
            $0.path == request.worktree.path
        }) else {
            if let confirmedGeneration = request.worktree.generation,
               item.worktrees.contains(where: {
                   $0.generation == confirmedGeneration
               }) {
                applyAuthoritativeKwtInventory(inventory, hostID: hostID)
                throw KwtWorktreeError.removalTargetChanged
            }
            if item.worktrees.contains(where: {
                removalTmuxEndpoint(request.worktree, matches: $0)
            }) {
                applyAuthoritativeKwtInventory(inventory, hostID: hostID)
                throw KwtWorktreeError.removalTargetChanged
            }
            return nil
        }
        applyAuthoritativeKwtInventory(inventory, hostID: hostID)
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
                    matches: $0.tmuxSocketName
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
                matches: record.tmuxSocketName
            )
    }

    private func removalTmuxSocket(
        _ confirmedSocket: String?,
        matches candidateSocket: String?
    ) -> Bool {
        // Missing inventory metadata cannot prove that a same-name session
        // moved away from the confirmed protected server.
        candidateSocket == confirmedSocket
            || (confirmedSocket != nil && candidateSocket == nil)
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
    }

    private func removalConfirmationChanged(
        from request: WorktreeRemovalRequest,
        to updatedRequest: WorktreeRemovalRequest
    ) -> Bool {
        !removalRequest(
            request,
            matches: updatedRequest.worktree,
            project: updatedRequest.project
        ) || updatedRequest.sessionKillRequest != request.sessionKillRequest
    }

    private func removalHostEndpointMatches(
        _ request: WorktreeRemovalRequest
    ) -> Bool {
        guard request.confirmedHost.id == request.worktree.hostID,
              let currentSummary = snapshot.host(
                  id: request.worktree.hostID
              ),
              let currentHost = TmuxHostResolver.resolve(currentSummary),
              let confirmedHost = TmuxHostResolver.resolve(
                  request.confirmedHost
              )
        else {
            return false
        }
        return currentHost == confirmedHost
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
              let host = TmuxHostResolver.resolve(hostSummary)
        else {
            throw KwtPullRequestError.projectUnavailable
        }
        do {
            return try await kwtPullRequestLister(
                project.scopedKey,
                host
            )
        } catch {
            if isRemoteKwtUnavailable(error, hostID: project.hostID) {
                kwtAvailabilityByHost[project.hostID] = false
                applyInventoryOverlayIfNeeded()
                updateWorkspaceInventoryState()
            }
            throw error
        }
    }

    func importPullRequest(
        _ request: PullRequestImportRequest
    ) async throws {
        guard let project = snapshot.project(id: request.projectID),
              snapshot.canImportPullRequest(in: project),
              let hostSummary = snapshot.host(id: project.hostID),
              let host = TmuxHostResolver.resolve(hostSummary)
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
        // See `createWorktree`: cancelling the scene-wide refresh leaves every
        // host but this one stale, including on the success path.
        invalidateKwtInventoryRefresh()
        defer {
            ownsWorktreeMutation = false
            worktreeMutationCoordinator.release(
                hostID: mutationHostID,
                projectIdentity: mutationProjectIdentity
            )
        }

        let result: KwtPullRequestImportResult
        do {
            result = try await kwtPullRequestImporter(
                request.pullRequestID,
                project.scopedKey,
                host
            )
            cancelPendingRestoration()
        } catch {
            if isRemoteKwtUnavailable(error, hostID: project.hostID) {
                kwtAvailabilityByHost[project.hostID] = false
                kwtInventoryFailuresByHost.removeValue(
                    forKey: project.hostID
                )
                applyInventoryOverlayIfNeeded()
                updateWorkspaceInventoryState()
            }
            throw error
        }

        do {
            let refreshed = try await kwtInventoryLoader(host)
            applyAuthoritativeKwtInventory(
                refreshed,
                hostID: project.hostID
            )
        } catch {
            kwtInventoryFailuresByHost[project.hostID] =
                error.localizedDescription
        }

        mergeImportedWorkspace(
            result.workspace,
            project: project
        )
        kwtAvailabilityByHost[project.hostID] = true
        applyInventoryOverlayIfNeeded()
        annotateImportedPullRequest(
            result.pullRequest,
            workspace: result.workspace,
            hostID: project.hostID
        )
        updateWorkspaceInventoryState()
        scheduleTmuxSessionDiscovery()

        guard let imported = snapshot.worktrees.first(where: {
            $0.hostID == project.hostID
                && normalizedWorkspacePath($0.path)
                == normalizedWorkspacePath(result.workspace.path)
        }) else {
            throw KwtPullRequestError.importedWorkspaceMissing(
                path: result.workspace.path
            )
        }
        var importedSelection = selection
        importedSelection.select(
            .worktree(imported.id),
            in: snapshot,
            visibility: worktreeVisibility
        )
        selectFromUser(importedSelection)
    }

    private func mergeImportedWorkspace(
        _ workspace: PullRequestWorkspace,
        project: ProjectSummary
    ) {
        guard var inventory = kwtInventoriesByHost[project.hostID] else {
            mergeImportedWorkspaceIntoSnapshot(
                workspace,
                project: project
            )
            return
        }
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
            tmuxSocketName: workspace.tmuxSocketName
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
            } else {
                inventory.projects[projectIndex].worktrees.append(worktree)
            }
        } else {
            inventory.projects.append(KwtProjectInventory(
                project: KwtProjectRecord(
                    repository: project.scopedKey,
                    name: project.name,
                    path: project.rootPath,
                    lastTouched: nil
                ),
                worktrees: [worktree],
                warning: nil
            ))
        }
        kwtInventoriesByHost[project.hostID] = inventory
    }

    private func mergeImportedWorkspaceIntoSnapshot(
        _ workspace: PullRequestWorkspace,
        project: ProjectSummary
    ) {
        if let index = snapshot.worktrees.firstIndex(where: {
            $0.hostID == project.hostID
                && normalizedWorkspacePath($0.path)
                == normalizedWorkspacePath(workspace.path)
        }) {
            snapshot.worktrees[index].branch = workspace.branch
            snapshot.worktrees[index].tmuxSessionName =
                workspace.sessionName
            snapshot.worktrees[index].tmuxSocketName =
                workspace.tmuxSocketName
            return
        }
        snapshot.worktrees.append(WorktreeSummary(
            id: UUID(),
            hostID: project.hostID,
            projectID: project.id,
            scopedKey: workspace.path,
            name: workspace.branch,
            path: workspace.path,
            branch: workspace.branch,
            tmuxSessionName: workspace.sessionName,
            tmuxSocketName: workspace.tmuxSocketName,
            sessionBackend:
            snapshot.host(id: project.hostID)?.kind == .remote
                ? .remoteTmux
                : .localTmux
        ))
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
                TmuxHostResolver.resolve(host).map { (host.id, $0) }
            }
        )
        guard resolved != inventoryHosts else {
            applyInventoryOverlayIfNeeded()
            return
        }

        let retainedHostIDs = Set(resolved.compactMap { hostID, target in
            inventoryHosts[hostID] == target ? hostID : nil
        })
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
        worktreeRemovalTombstones = worktreeRemovalTombstones.filter {
            retainedHostIDs.contains($0.key.hostID)
        }
        inventoryHosts = resolved
        applyInventoryOverlayIfNeeded()
        scheduleKwtInventory()
        scheduleTmuxSessionDiscovery()
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

    private func scheduleKwtInventory() {
        guard kwtInventoryEnabled,
              !ownsWorktreeMutation else { return }
        let fencedHostIDs = Set(
            fencedWorktreeMutationScopes.map(\.hostID)
        )
        let targets = inventoryHosts.filter {
            !fencedHostIDs.contains($0.key)
        }
        let configuredHosts = Dictionary(
            (configuredSSHHostsProvider()
                + configuredExeHostsProvider().map(\.sshHost))
                .map { ($0.configKey, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        let automaticProvisioningHosts: [UUID: SSHHost] = Dictionary(
            uniqueKeysWithValues: targets.compactMap { hostID, target in
                guard case .ssh = target,
                      let summary = snapshot.host(id: hostID),
                      let host = configuredHosts[summary.configKey],
                      host.platform == .macOS || host.platform == .linux
                else { return nil }
                return (hostID, host)
            }
        )
        kwtInventoryGeneration += 1
        let generation = kwtInventoryGeneration
        kwtInventoryTask?.cancel()
        guard !targets.isEmpty else {
            kwtInventoryTask = nil
            isKwtInventoryLoading = false
            inventoryRefreshProgress.kwtCompleted = true
            updateWorkspaceInventoryState()
            return
        }
        inventoryRefreshProgress.kwtCompleted = false
        isKwtInventoryLoading = true
        updateWorkspaceInventoryState()
        let kwtInventoryLoader = kwtInventoryLoader
        let kwtRemoteProvisioner = kwtRemoteProvisioner
        kwtInventoryTask = Task { [weak self] in
            await withTaskGroup(
                of: (UUID, Result<KwtHostInventory, Error>).self
            ) { group in
                for (hostID, host) in targets {
                    group.addTask {
                        do {
                            if let remoteHost =
                                automaticProvisioningHosts[hostID] {
                                try await kwtRemoteProvisioner(remoteHost)
                            }
                            return await (
                                hostID,
                                .success(
                                    try kwtInventoryLoader(host)
                                )
                            )
                        } catch {
                            return (hostID, .failure(error))
                        }
                    }
                }
                for await (hostID, result) in group {
                    guard let self, !Task.isCancelled,
                          generation == self.kwtInventoryGeneration else {
                        group.cancelAll()
                        return
                    }
                    switch result {
                    case let .success(inventory):
                        let tombstones =
                            self.activeRemovalTombstones(
                                after: inventory,
                                hostID: hostID
                            )
                        self.applyAuthoritativeKwtInventory(
                            inventory,
                            hostID: hostID,
                            excludingWorktrees: tombstones
                        )
                    case let .failure(error):
                        if error is KwtRemoteInstallError {
                            // Provisioning failures disable worktree actions
                            // but remain visible because they require a
                            // packaging, transport, or remote-host repair.
                            self.kwtAvailabilityByHost[hostID] = false
                            self.kwtInventoryFailuresByHost[hostID] =
                                error.localizedDescription
                        } else if self.isRemoteKwtUnavailable(
                            error,
                            hostID: hostID
                        ) {
                            // SSH hosts remain useful for ordinary tmux even
                            // when kwt is not installed. Keep any last-known
                            // project inventory without presenting the absent
                            // optional capability as a host failure.
                            self.kwtInventoryFailuresByHost.removeValue(
                                forKey: hostID
                            )
                            self.kwtAvailabilityByHost[hostID] = false
                        } else {
                            self.kwtInventoryFailuresByHost[hostID] =
                                error.localizedDescription
                        }
                    }
                    if case .failure = result {
                        self.applyInventoryOverlayIfNeeded()
                        self.updateWorkspaceInventoryState()
                    }
                }
            }
            guard let self, !Task.isCancelled,
                  generation == kwtInventoryGeneration else { return }
            isKwtInventoryLoading = false
            inventoryRefreshProgress.kwtCompleted = true
            updateWorkspaceInventoryState()
        }
    }

    private func invalidateKwtInventoryRefresh() {
        kwtInventoryGeneration += 1
        kwtInventoryTask?.cancel()
        kwtInventoryTask = nil
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
        case .ended:
            fencedWorktreeMutationScopes.remove(event.scope)
            pendingWorktreeRemovals.removeValue(forKey: event.scope)
            let pendingRestorations =
                pendingRemovalPresentationRestorations.removeValue(
                    forKey: event.scope
                )
            if !event.removalTombstones.isEmpty {
                worktreeRemovalTombstones[event.scope, default: []]
                    .formUnion(event.removalTombstones)
                applyRemovalTombstones(
                    event.removalTombstones,
                    hostID: event.scope.hostID
                )
            } else if let pendingRestorations {
                restorePresentationsAfterFailedRemoval(
                    pendingRestorations,
                    requiresWorkspaceReestablishment:
                    event.requiresWorkspaceReestablishment
                )
            }
        }
        guard inventoryHosts[event.scope.hostID] != nil else { return }
        invalidateKwtInventoryRefresh()
        scheduleKwtInventory()
        if event.phase == .ended {
            scheduleTmuxSessionDiscovery()
        }
    }

    private func applyRemovalTombstones(
        _ tombstones: Set<WorktreeMutationCoordinator.RemovalTombstone>,
        hostID: UUID
    ) {
        let matches: (String, String?) -> Bool = { path, generation in
            Self.removalTombstones(
                tombstones,
                matchPath: path,
                generation: generation
            )
        }
        if var inventory = kwtInventoriesByHost[hostID] {
            for index in inventory.projects.indices {
                inventory.projects[index].worktrees.removeAll {
                    matches($0.path, $0.generation)
                }
            }
            kwtInventoriesByHost[hostID] = inventory
        }
        let removedIDs = worktreeIDs(
            matching: tombstones,
            hostID: hostID
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
            pendingRemovalPresentationRestorations[event.scope, default: [:]][
                key
            ] = PendingRemovalPresentation(
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

    private func restorePresentationsAfterFailedRemoval(
        _ presentations: [TmuxPresentationKey: PendingRemovalPresentation],
        requiresWorkspaceReestablishment: Bool
    ) {
        for presentation in presentations.values {
            let establishesWorkspace = requiresWorkspaceReestablishment
                || presentation.requiresWorkspaceEstablishment
            _ = presentTmuxSession(
                presentation.selection,
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

    private func worktreeIDs(
        matching tombstones:
        Set<WorktreeMutationCoordinator.RemovalTombstone>,
        hostID: UUID
    ) -> Set<UUID> {
        Set(snapshot.worktrees.compactMap { worktree in
            guard worktree.hostID == hostID,
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
    ) -> Set<KwtWorktreeIdentity> {
        var activeTombstones: Set<KwtWorktreeIdentity> = []
        let scopes = worktreeRemovalTombstones.keys.filter {
            $0.hostID == hostID
        }
        for scope in scopes {
            guard let tombstones = worktreeRemovalTombstones[scope] else {
                continue
            }
            let project = inventory.projects.first {
                $0.project.repository == scope.projectIdentity
            }
            let active = tombstones.filter { tombstone in
                guard let project else { return false }
                if project.warning != nil {
                    return true
                }
                return project.worktrees.contains {
                    Self.removalTombstones(
                        [tombstone],
                        matchPath: $0.path,
                        generation: $0.generation
                    )
                }
            }
            if active.isEmpty {
                worktreeRemovalTombstones.removeValue(forKey: scope)
            } else {
                worktreeRemovalTombstones[scope] = active
                activeTombstones.formUnion(active)
            }
        }
        return activeTombstones
    }

    private func applyAuthoritativeKwtInventory(
        _ inventory: KwtHostInventory,
        hostID: UUID,
        excludingWorktrees: Set<KwtWorktreeIdentity> = []
    ) {
        let previous = kwtInventoriesByHost[hostID]
        kwtInventoriesByHost[hostID] =
            inventory.retainingFailedProjectWorktrees(
                from: previous,
                excludingWorktrees: excludingWorktrees
            )
        kwtAvailabilityByHost[hostID] = true
        kwtInventoryFailuresByHost.removeValue(forKey: hostID)
        applyInventoryOverlayIfNeeded()
        reconcileRetainedTmuxPresentations(
            afterAuthoritativeInventoryFor: hostID
        )
        updateWorkspaceInventoryState()
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
        if let pullRequestError = error as? KwtPullRequestError,
           case .commandFailed(_, 127, _, _, _) = pullRequestError {
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
            tmuxReachabilityByHost: tmuxReachabilityByHost,
            tmuxLastSeenByHost: tmuxLastSeenByHost,
            to: source
        )
    }

    func refreshTmuxSessionDiscovery() {
        scheduleTmuxSessionDiscovery()
    }

    func startTmuxSessionDiscovery() {
        guard !tmuxDiscoveryEnabled else { return }
        tmuxDiscoveryEnabled = true
        let generation = tmuxDiscoveryGeneration
        reconcileInventoryHosts()
        if generation == tmuxDiscoveryGeneration {
            scheduleTmuxSessionDiscovery()
        }
    }

    private func scheduleTmuxSessionDiscovery() {
        guard tmuxDiscoveryEnabled else { return }
        let targets = Array(inventoryHosts)
        tmuxDiscoveryGeneration += 1
        let generation = tmuxDiscoveryGeneration
        tmuxDiscoveryTask?.cancel()
        inventoryRefreshProgress.tmuxCompleted = false
        isTmuxDiscoveryLoading = true
        updateWorkspaceInventoryState()
        let broker = tmuxSessionProbeBroker
        tmuxDiscoveryTask = Task { [weak self] in
            await withTaskGroup(
                of: (UUID, Result<[DiscoveredTmuxSession], TmuxBinaryError>).self
            ) { group in
                for (hostID, host) in targets {
                    group.addTask {
                        await (hostID, broker.sessions(on: host))
                    }
                }
                for await (hostID, result) in group {
                    guard let self, !Task.isCancelled,
                          generation == self.tmuxDiscoveryGeneration else {
                        group.cancelAll()
                        return
                    }
                    self.applyTmuxDiscoveryResult(result, hostID: hostID)
                }
            }
            guard let self, !Task.isCancelled,
                  generation == tmuxDiscoveryGeneration else { return }
            isTmuxDiscoveryLoading = false
            inventoryRefreshProgress.tmuxCompleted = true
            updateWorkspaceInventoryState()
        }
    }

    private func applyTmuxDiscoveryResult(
        _ result: Result<[DiscoveredTmuxSession], TmuxBinaryError>,
        hostID: UUID
    ) {
        guard case let .success(discovered) = result else {
            if case let .failure(error) = result {
                tmuxReachabilityByHost[hostID] = false
                let hostName = snapshot.host(id: hostID)?.name
                    ?? "Unknown host"
                tmuxDiscoveryFailuresByHost[hostID] =
                    "\(hostName): \(error.localizedDescription)"
            }
            applyInventoryOverlayIfNeeded()
            updateWorkspaceInventoryState()
            return
        }
        tmuxDiscoveryFailuresByHost.removeValue(forKey: hostID)
        tmuxReachabilityByHost[hostID] = true
        tmuxLastSeenByHost[hostID] = Date()
        reconcileEndedTmuxSession(discovered, hostID: hostID)
        tmuxSessionsByHost[hostID] = reconciledTmuxSessions(
            discovered,
            hostID: hostID
        )
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
        applyInventoryOverlayIfNeeded()
        updateWorkspaceInventoryState()
        applyDeferredTmuxPresentationsIfReady()
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
        host: TmuxHost
    ) {
        tmuxSessionProbeBroker.invalidateSessions(on: host)
        tmuxDiscoveryGeneration += 1
        tmuxDiscoveryTask?.cancel()
        tmuxDiscoveryTask = nil
        isTmuxDiscoveryLoading = false
        inventoryRefreshProgress.tmuxCompleted = false
        if tmuxDiscoveryEnabled {
            scheduleTmuxSessionDiscovery()
        } else {
            updateWorkspaceInventoryState()
        }
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
        workspaceInventoryWarningsByHost = Dictionary(
            uniqueKeysWithValues: hostIDs.compactMap { hostID in
                let warnings = [
                    kwtInventoryFailuresByHost[hostID],
                    tmuxDiscoveryFailuresByHost[hostID],
                    projectListWarningsByHost[hostID],
                    directoryWarningsByHost[hostID],
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
        let hasCachedInventory = hasVisibleInventory
            || !kwtInventoriesByHost.isEmpty
            || !tmuxSessionsByHost.isEmpty
        let hasPendingSources = isKwtInventoryLoading
            || isTmuxDiscoveryLoading
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
        let quotedPath = Self.shellQuote(AppLogger.logFilePath)
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

    private static func shellQuote(_ value: String) -> String {
        "'\(value.replacingOccurrences(of: "'", with: "'\\''"))'"
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
        invalidateTmuxAttachments(for: invalidatedHostIDs)
        return updated
    }

    private static func resolvedEndpoints(
        of snapshot: WorkspaceSnapshot
    ) -> [UUID: TmuxHost] {
        Dictionary(
            uniqueKeysWithValues: snapshot.hosts.compactMap { host in
                TmuxHostResolver.resolve(host).map { (host.id, $0) }
            }
        )
    }

    private func invalidateTmuxAttachments(for hostIDs: Set<UUID>) {
        guard !hostIDs.isEmpty else { return }
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
                if let key = retainedTmuxPresentationKeysByHandle
                    .removeValue(forKey: handle.id),
                    let presentation = retainedTmuxPresentations
                    .removeValue(forKey: key) {
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
        }
        guard let active = activeBorrowedTmuxSelection,
              hostIDs.contains(active.hostID) else { return }
        activeBorrowedTmuxSelection = nil
        activeBorrowedTmuxHandle = nil
        activeBorrowedTmuxLaunchMode = nil
        activeBorrowedTmuxRecoveryState = nil
        tmuxConnectionRecoveryRequest = nil
    }

    func pendingSSHHostKeyConfirmation(
        for host: SSHHost
    ) async -> Result<SSHHostKeyReviewRequirement, HostProbeError> {
        guard let resolved = resolvedSSHHost(host) else {
            return .failure(.message("Enter a valid SSH destination."))
        }
        let result = await resolveSSHHostTrust(for: resolved)
        return mapSSHHostTrustRequirement(
            result,
            destination: resolved.destination
        )
    }

    func pendingSSHHostKeyConfirmation(
        forHostID hostID: UUID
    ) async -> Result<SSHHostKeyReviewRequirement, HostProbeError> {
        guard let host = configuredSSHHost(for: hostID) else {
            return .failure(.message(
                "The selected remote host is no longer configured."
            ))
        }
        return await pendingSSHHostKeyConfirmation(for: host)
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

        guard let resolved = resolvedSSHHost(host) else {
            return .connectionIssue("Enter a valid SSH destination.")
        }
        let trustResult = await resolveSSHHostTrust(for: resolved)
        switch trustResult {
        case let .success(requirement):
            switch requirement {
            case let .confirmation(confirmation):
                return .hostKey(confirmation)
            case let .authentication(target):
                pendingSSHAuthenticationTargets[resolved.destination] = target
                return .authenticationRequired
            case .none:
                pendingSSHAuthenticationTargets.removeValue(
                    forKey: resolved.destination
                )
            }
        case let .failure(error):
            return .connectionIssue(error.displayMessage)
        }

        switch await probeSSHHost(host) {
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
        let result = await resolveSSHHostTrust(
            for: resolved,
            operation: { manager in
                try manager.acceptRequirement(
                    confirmation,
                    for: resolved.info,
                    destination: resolved.destination
                )
            }
        )
        return mapSSHHostTrustRequirement(
            result,
            destination: resolved.destination
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
        guard let target = sshAuthenticationTarget(for: resolved) else {
            return nil
        }
        guard let controlPath = sshAuthenticationControlPaths[target] else {
            return nil
        }
        return AnyView(SSHAuthenticationView(
            session: sshAuthenticationCoordinator.session(
                scopeID: sshAuthenticationScopeID,
                presentationID: surfaceID,
                target: target,
                controlPath: controlPath
            ),
            finalDestination: resolved.info
        ))
    }

    func sshAuthenticationView(forHostID hostID: UUID) -> AnyView? {
        guard let host = configuredSSHHost(for: hostID) else { return nil }
        return sshAuthenticationView(surfaceID: hostID, for: host)
    }

    func isSSHAuthenticationReady(
        for host: SSHHost
    ) async -> SSHAuthenticationReadiness {
        guard let resolved = resolvedSSHHost(host) else { return .pending }
        guard let target = sshAuthenticationTarget(for: resolved) else {
            return .pending
        }
        guard let controlPath = sshAuthenticationControlPaths[target] else {
            return .pending
        }
        if sshAuthenticationCoordinator.requiresRecoveryRestart(
            target: target,
            controlPath: controlPath
        ) {
            invalidateSSHAuthentication(
                destination: resolved.destination,
                target: target,
                controlPath: controlPath
            )
            return .reviewRequired
        }
        let isReady = await Task.detached {
            SSHConnectionPool.isAuthenticated(
                target.host,
                controlPath: controlPath
            )
        }.value
        guard !Task.isCancelled else { return .pending }
        if isReady {
            let currentIdentity = await Task.detached(priority: .userInitiated) {
                Self.currentSSHAuthenticationIdentity(
                    for: target,
                    finalHost: resolved.info
                )
            }.value
            guard !Task.isCancelled else { return .pending }
            guard currentIdentity?.target == target,
                  currentIdentity?.controlPath == controlPath else {
                invalidateSSHAuthentication(
                    destination: resolved.destination,
                    target: target,
                    controlPath: controlPath
                )
                return .reviewRequired
            }
        }
        sshAuthenticationCoordinator.reconcileIdentity(
            target: target,
            controlPath: controlPath
        )
        if isReady {
            sshAuthenticationCoordinator.markConnected(
                target: target,
                controlPath: controlPath
            )
            guard let configuredTarget =
                configuredSSHAuthenticationTargets[resolved.destination]
            else { return .pending }
            if target != configuredTarget {
                pendingSSHAuthenticationTargets.removeValue(
                    forKey: resolved.destination
                )
                return .reviewRequired
            }
            return .connected
        }
        return .pending
    }

    nonisolated static func currentSSHAuthenticationIdentity(
        for target: SSHAuthenticationTarget,
        finalHost: SSHHostInfo,
        configurationProvider: SSHConfigurationResolver.ConfigurationProvider =
            SSHConfigurationResolver.configuration
    ) -> SSHAuthenticationIdentity? {
        let snapshot = SSHConnectionPool.configurationSnapshot(
            for: finalHost,
            configurationProvider: configurationProvider
        )
        return SSHConnectionPool.authenticationIdentity(
            for: target,
            configurationSnapshot: snapshot
        )
    }

    func isSSHAuthenticationReady(
        forHostID hostID: UUID
    ) async -> SSHAuthenticationReadiness {
        guard let host = configuredSSHHost(for: hostID) else { return .pending }
        return await isSSHAuthenticationReady(for: host)
    }

    func cancelSSHAuthentication(surfaceID: UUID) {
        sshAuthenticationCoordinator.cancel(
            scopeID: sshAuthenticationScopeID,
            presentationID: surfaceID
        )
    }

    private func mapSSHHostTrustRequirement(
        _ result: Result<SSHHostTrustRequirement, HostProbeError>,
        destination: String
    ) -> Result<SSHHostKeyReviewRequirement, HostProbeError> {
        switch result {
        case let .success(requirement):
            switch requirement {
            case let .confirmation(confirmation):
                pendingSSHAuthenticationTargets.removeValue(
                    forKey: destination
                )
                return .success(.confirmation(confirmation))
            case let .authentication(target):
                pendingSSHAuthenticationTargets[destination] = target
                return .success(.authenticationRequired)
            case .none:
                pendingSSHAuthenticationTargets.removeValue(
                    forKey: destination
                )
                return .success(.none)
            }
        case let .failure(error):
            return .failure(error)
        }
    }

    private func sshAuthenticationTarget(
        for resolved: (info: SSHHostInfo, destination: String)
    ) -> SSHAuthenticationTarget? {
        pendingSSHAuthenticationTargets[resolved.destination]
            ?? configuredSSHAuthenticationTargets[resolved.destination]
    }

    private func resolveSSHHostTrust(
        for resolved: (info: SSHHostInfo, destination: String)
    ) async -> Result<SSHHostTrustRequirement, HostProbeError> {
        await resolveSSHHostTrust(
            for: resolved,
            operation: { manager in
                try manager.pendingRequirement(
                    for: resolved.info,
                    destination: resolved.destination
                )
            }
        )
    }

    private func resolveSSHHostTrust(
        for resolved: (info: SSHHostInfo, destination: String),
        operation: @escaping @Sendable (SSHHostTrustManager) throws
            -> SSHHostTrustRequirement
    ) async -> Result<SSHHostTrustRequirement, HostProbeError> {
        let resolutionTask = Task.detached(priority: .userInitiated) {
            let snapshot = SSHConnectionPool.configurationSnapshot(
                for: resolved.info
            )
            let identity = SSHConnectionPool.authenticationIdentity(
                for: snapshot
            )
            do {
                let requirement = try operation(SSHHostTrustManager(
                    configurationSnapshot: snapshot
                ))
                let requirementIdentity: SSHAuthenticationIdentity?
                if case let .authentication(target) = requirement {
                    requirementIdentity = SSHConnectionPool
                        .authenticationIdentity(
                            for: target,
                            configurationSnapshot: snapshot
                        )
                } else {
                    requirementIdentity = nil
                }
                return (
                    identity,
                    requirementIdentity,
                    Result<SSHHostTrustRequirement, HostProbeError>.success(
                        requirement
                    )
                )
            } catch {
                return (
                    identity,
                    nil,
                    Result<SSHHostTrustRequirement, HostProbeError>.failure(
                        .message(error.localizedDescription)
                    )
                )
            }
        }
        let resolution = await withTaskCancellationHandler {
            await resolutionTask.value
        } onCancel: {
            resolutionTask.cancel()
        }
        if !Task.isCancelled {
            if let identity = resolution.0 {
                configuredSSHAuthenticationTargets[resolved.destination] =
                    identity.target
                sshAuthenticationControlPaths[identity.target] =
                    identity.controlPath
            }
            if let requirementIdentity = resolution.1,
               requirementIdentity.target != resolution.0?.target {
                sshAuthenticationControlPaths[requirementIdentity.target] =
                    requirementIdentity.controlPath
            }
        }
        return resolution.2
    }

    private func invalidateSSHAuthentication(
        destination: String,
        target: SSHAuthenticationTarget,
        controlPath: String
    ) {
        pendingSSHAuthenticationTargets.removeValue(forKey: destination)
        configuredSSHAuthenticationTargets.removeValue(forKey: destination)
        sshAuthenticationControlPaths.removeValue(forKey: target)
        sshAuthenticationCoordinator.invalidate(
            target: target,
            controlPath: controlPath
        )
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

    private func resolvedSSHHost(
        _ host: SSHHost
    ) -> (info: SSHHostInfo, destination: String)? {
        let destination = host.sshDestination.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        guard let parsed = TmuxHostResolver.parseSSHDestination(
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
        return await Task.detached {
            let result = sshHostProbeRunner(
                sshHost,
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
            } else if !kwtAvailable {
                diagnostics = [.missingKwtCapability]
            } else {
                diagnostics = []
            }
            return .success(HostProbeSummary(
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
        }.value
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
            try await KwtRemoteInstaller().install(on: host)
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
        guard let sshHost = TmuxHostResolver.parseSSHDestination(
            host.sshDestination
        ) else {
            return .failure(.message("Enter a valid SSH destination."))
        }
        do {
            let project = try await KwtProjectRegistrar().register(
                projectPath: projectPath,
                on: sshHost
            )
            refreshKwtInventory()
            return .success(project.name)
        } catch {
            return .failure(.message(error.localizedDescription))
        }
    }

    func registerProject(
        _ projectPath: String,
        on host: HostSummary
    ) async -> Result<String, HostProbeError> {
        guard let capturedTarget = TmuxHostResolver.resolve(host) else {
            return .failure(.message("Enter a valid SSH destination."))
        }
        guard let currentHost = snapshot.host(id: host.id),
              let currentTarget = TmuxHostResolver.resolve(currentHost),
              currentTarget == capturedTarget
        else {
            return .failure(.message(
                "The host connection changed. Close Add Project and try again."
            ))
        }
        do {
            let project = try await kwtProjectRegistration(
                projectPath,
                currentTarget
            )
            refreshKwtInventory()
            return .success(project.name)
        } catch {
            return .failure(.message(error.localizedDescription))
        }
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
        guard TmuxHostResolver.resolve(host) != nil else {
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
                    self?.nativeTmuxSessionCoordinator.surface(handle: handle)
                },
                onCloseRequest: {
                    NotificationCenter.default.post(
                        name: .ghosthubCloseTab, object: nil
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
        guard let handle = activeBorrowedTmuxHandle else { return }
        _ = nativeTmuxSessionCoordinator.surface(handle: handle)
    }

    func openBorrowedTmuxSession(_ selection: WorkspaceTmuxSessionSelection) {
        cancelPendingRestoration()
        userNavigationRevision &+= 1
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
        if selection.socketName != nil {
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
        activatesPresentation: Bool = true
    ) -> BorrowedTmuxSessionHandle? {
        var selection = selection
        if let worktreeID = selection.worktreeID,
           selection.worktreeGeneration == nil,
           let generation = snapshot.worktree(id: worktreeID)?.generation,
           WorktreeGeneration.isCanonical(generation) {
            selection.worktreeGeneration = generation
        }
        guard !worktreeRemovalIsPending(for: selection) else { return nil }
        let effectiveLaunchMode: TmuxAttachmentLaunchMode =
            selection.socketName != nil && launchMode == .create
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
                    let generationChanged = if let retainedGeneration =
                        retained.worktreeGeneration,
                        let selectionGeneration = selection
                        .worktreeGeneration {
                        retainedGeneration != selectionGeneration
                    } else {
                        false
                    }
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
                    activateTmuxPresentation(retained)
                }
                return retained.handle
            }
        }
        guard let host = snapshot.host(id: selection.hostID),
              let attachmentHost = TmuxHostResolver.resolve(host)
        else {
            if activatesPresentation {
                activeBorrowedTmuxSelection = selection
                activeBorrowedTmuxHandle = nil
                activeBorrowedTmuxLaunchMode = effectiveLaunchMode
                activeBorrowedTmuxRecoveryState = nil
                tmuxConnectionRecoveryRequest = nil
            }
            return nil
        }
        let knownSessions = tmuxSessionsByHost[selection.hostID]
            ?? host.tmuxSessions
        let sessionIsDiscovered = selection.socketName == nil
            && knownSessions.contains { $0.name == selection.name }
        let managedKwtUnavailable = host.remoteDiagnostics.contains {
            $0.code == .missingKwt
        }
        let openWorkspace = intent == .userInitiated
            && effectiveLaunchMode == .attach
            && selection.socketName == nil
            && selection.workspacePath != nil
            && (!sessionIsDiscovered || !managedKwtUnavailable)
        let protectedSessionNeedsEstablishment = intent == .userInitiated
            && effectiveLaunchMode == .attach
            && selection.socketName != nil
            && selection.workspacePath != nil
        let handle = nativeTmuxSessionCoordinator.attach(
            hostID: selection.hostID,
            name: selection.name,
            host: attachmentHost,
            socketName: selection.socketName,
            launchMode: effectiveLaunchMode,
            initialCommand: effectiveLaunchMode == .create
                ? initialCommand
                : nil,
            workingDirectory: selection.workspacePath,
            openWorkspace: openWorkspace,
            sessionIdentity: Self.discoveredTmuxSessionIdentity(
                selection,
                hostSummary: host
            )
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
                phase: phase,
                surfaceExitCode: nil
            )
            : nil
        let presentation = RetainedTmuxPresentation(
            selection: selection,
            handle: handle,
            launchMode: effectiveLaunchMode,
            reconnectContext: reconnectContext,
            reconnectSupervisor: TmuxSessionReconnectSupervisor(
                intervals: tmuxReconnectIntervals,
                probeDeadline: tmuxReconnectProbeDeadline
            )
        )
        retainedTmuxPresentations[key] = presentation
        retainedTmuxPresentationKeysByHandle[handle.id] = key
        if activatesPresentation {
            activateTmuxPresentation(presentation)
        }
        borrowedTmuxConnectionStates[handle.id] = .connecting
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
                    if let retainedGeneration = retained.worktreeGeneration,
                       let currentGeneration = current.worktreeGeneration,
                       retainedGeneration != currentGeneration {
                        return retained
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
        activeBorrowedTmuxSelection = presentation.selection
        activeBorrowedTmuxHandle = presentation.handle
        activeBorrowedTmuxLaunchMode = presentation.launchMode
        activeBorrowedTmuxRecoveryState = presentation.recoveryState
        tmuxConnectionRecoveryRequest = presentation.recoveryRequest
        applyDeferredTmuxPresentationIfReady(presentation)
    }

    private func publishActiveState(
        for presentation: RetainedTmuxPresentation
    ) {
        guard activeBorrowedTmuxHandle == presentation.handle else { return }
        activeBorrowedTmuxLaunchMode = presentation.launchMode
        activeBorrowedTmuxRecoveryState = presentation.recoveryState
        tmuxConnectionRecoveryRequest = presentation.recoveryRequest
    }

    func hideBorrowedTmuxSession(
        _ selection: WorkspaceTmuxSessionSelection
    ) {
        guard activeBorrowedTmuxSelection == selection else { return }
        activeBorrowedTmuxSelection = nil
        activeBorrowedTmuxHandle = nil
        activeBorrowedTmuxLaunchMode = nil
        activeBorrowedTmuxRecoveryState = nil
        tmuxConnectionRecoveryRequest = nil
    }

    var retainedBorrowedTmuxPresentationCount: Int {
        retainedTmuxPresentations.count
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
        closeBorrowedTmuxSession(selection, recordsExplicitDismissal: true)
    }

    private func invalidateBorrowedTmuxSession(
        _ selection: WorkspaceTmuxSessionSelection
    ) {
        closeBorrowedTmuxSession(selection, recordsExplicitDismissal: false)
    }

    private func closeBorrowedTmuxSession(
        _ selection: WorkspaceTmuxSessionSelection,
        recordsExplicitDismissal: Bool
    ) {
        cancelPendingRestoration()
        if recordsExplicitDismissal, let worktreeID = selection.worktreeID {
            explicitlyDismissedWorktreePresentationIDs.insert(worktreeID)
        }
        if recordsExplicitDismissal,
           let directoryID = selection.directoryWorkspaceID {
            explicitlyDismissedDirectoryPresentationIDs.insert(directoryID)
        }
        let key = TmuxPresentationKey(selection)
        guard let presentation = retainedTmuxPresentations.removeValue(
            forKey: key
        ) else {
            guard activeBorrowedTmuxSelection == selection else { return }
            activeBorrowedTmuxSelection = nil
            activeBorrowedTmuxHandle = nil
            activeBorrowedTmuxLaunchMode = nil
            activeBorrowedTmuxRecoveryState = nil
            tmuxConnectionRecoveryRequest = nil
            return
        }
        let handle = presentation.handle
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
            tmuxConnectionRecoveryRequest = nil
        }
        nativeTmuxSessionCoordinator.detach(
            hostID: presentation.selection.hostID,
            name: presentation.selection.name,
            socketName: presentation.selection.socketName
        )
    }

    func prepareTmuxSessionKill(
        _ selection: WorkspaceTmuxSessionSelection
    ) async throws -> TmuxSessionKillRequest {
        guard let currentHostSummary = snapshot.host(id: selection.hostID),
              let currentHost = TmuxHostResolver.resolve(currentHostSummary)
        else {
            throw TmuxSessionKillError.hostChanged(
                session: selection.name
            )
        }

        let discoveredIdentity = Self.discoveredTmuxSessionIdentity(
            selection,
            hostSummary: currentHostSummary
        )
        let identity: TmuxSessionIdentity
        if let discoveredIdentity {
            identity = discoveredIdentity
        } else if isConnectedActiveTmuxSession(selection) {
            identity = try await tmuxSessionIdentityReader(
                selection,
                currentHost
            )
        } else {
            throw TmuxSessionKillError.sessionNotRunning(
                host: currentHost.displayName,
                session: selection.name
            )
        }

        return TmuxSessionKillRequest(
            session: selection,
            confirmedHost: currentHostSummary,
            serverPID: identity.serverPID,
            sessionID: identity.sessionID,
            sessionCreatedAt: identity.createdAt
        )
    }

    func killTmuxSession(
        _ request: TmuxSessionKillRequest
    ) async throws {
        let tmuxSelection = request.session
        guard request.confirmedHost.id == tmuxSelection.hostID,
              let confirmedHost = TmuxHostResolver.resolve(
                  request.confirmedHost
              ),
              let currentHostSummary = snapshot.host(
                  id: tmuxSelection.hostID
              ),
              let currentHost = TmuxHostResolver.resolve(
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
              let host = TmuxHostResolver.resolve(hostSummary),
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
              }),
              summary.hasStableIdentity,
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
        _ host: TmuxHost
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
        borrowedTmuxConnectionStates[handle.id] = state
        guard let presentation = retainedTmuxPresentation(for: handle) else {
            return
        }
        if state == .connected {
            confirmedEndedTmuxSessionHandles.remove(handle.id)
            presentation.recoveryState = nil
            presentation.recoveryRequest = nil
            if presentation.reconnectContext?.handleID == handle.id {
                presentation.reconnectContext?.surfaceExitCode = nil
                startEstablishmentConfirmationIfNeeded(
                    presentation: presentation
                )
            }
            warmConnectedTmuxSession(handle: handle)
            publishActiveState(for: presentation)
            applyDeferredTmuxPresentationIfReady(presentation)
        } else {
            tmuxActivityEnrollmentTasks.removeValue(
                forKey: handle.id
            )?.cancel()
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

    private func startTmuxReconnect(
        _ presentation: RetainedTmuxPresentation,
        context: TmuxReconnectContext
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
        presentation.reconnectSupervisor.start { [weak self, weak presentation] in
            guard let presentation else { return .stop }
            guard let self else { return .stop }
            return await attemptTmuxReconnect(
                presentation,
                context: context
            )
        }
    }

    private func attemptTmuxReconnect(
        _ presentation: RetainedTmuxPresentation,
        context: TmuxReconnectContext
    ) async -> TmuxReconnectDecision {
        guard presentation.reconnectContext == context,
              presentation.handle.id == context.handleID,
              retainedTmuxPresentation(for: presentation.handle)
              === presentation
        else { return .stop }
        let outcome = await tmuxProbeOutcome(
            for: presentation,
            context: context
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
                && currentContext.surfaceExitCode == context.surfaceExitCode
        guard currentContext == context || advancedToAttachOnly,
              presentation.handle.id == context.handleID,
              retainedTmuxPresentation(for: presentation.handle)
              === presentation
        else { return .stop }
        return reconnectDecision(
            for: presentation,
            context: currentContext,
            outcome: outcome
        )
    }

    private func tmuxProbeOutcome(
        for presentation: RetainedTmuxPresentation,
        context: TmuxReconnectContext
    ) async -> TmuxSessionProbeOutcome {
        guard case let .ssh(host) = context.host else {
            return .failure(.sessionContextUnavailable)
        }
        if context.selection.socketName == nil {
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
                  .flatMap(TmuxHostResolver.resolve) == context.host
            else {
                return .failure(.sessionContextUnavailable)
            }
            if case let .failure(error) = result,
               case .probeCancelled = error {
                return .failure(error)
            }
            applyTmuxDiscoveryResult(
                result,
                hostID: context.selection.hostID
            )
            switch result {
            case let .success(sessions):
                return sessions.contains { $0.name == context.selection.name }
                    ? .present
                    : .absent
            case let .failure(error):
                return .failure(error)
            }
        }
        return await tmuxSessionProbeBroker.session(
            TmuxSessionProbeTarget(
                host: host,
                name: context.selection.name,
                socketName: context.selection.socketName
            )
        )
    }

    private func reconnectDecision(
        for presentation: RetainedTmuxPresentation,
        context: TmuxReconnectContext,
        outcome: TmuxSessionProbeOutcome
    ) -> TmuxReconnectDecision {
        guard !Task.isCancelled else { return .retry }
        guard presentation.reconnectContext == context,
              presentation.handle.id == context.handleID,
              retainedTmuxPresentation(for: presentation.handle)
              === presentation
        else { return .stop }
        switch outcome {
        case .present:
            guard context.surfaceExitCode == 255 else {
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
            guard context.surfaceExitCode == 255 else {
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
                        TmuxConnectionRecoveryRequest(
                            hostID: context.selection.hostID,
                            message: message
                        )
                }
                publishActiveState(for: presentation)
                return .stop
            case .hostKeyChanged:
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
        guard let host = snapshot.host(id: selection.hostID),
              let attachmentHost = TmuxHostResolver.resolve(host)
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
        let managedKwtUnavailable = host.remoteDiagnostics.contains {
            $0.code == .missingKwt
        }
        let openWorkspace = intent == .userInitiated
            && launchMode == .attach
            && selection.socketName == nil
            && selection.workspacePath != nil
            && (!sessionIsDiscovered || !managedKwtUnavailable)
        let protectedSessionNeedsEstablishment = intent == .userInitiated
            && launchMode == .attach
            && selection.socketName != nil
            && selection.workspacePath != nil
        let previousHandle = presentation.handle
        let handle = nativeTmuxSessionCoordinator.attach(
            hostID: selection.hostID,
            name: selection.name,
            host: attachmentHost,
            socketName: selection.socketName,
            launchMode: launchMode,
            initialCommand: launchMode == .create ? initialCommand : nil,
            workingDirectory: selection.workspacePath,
            openWorkspace: openWorkspace
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
            phase: phase,
            surfaceExitCode: nil
        )
        borrowedTmuxConnectionStates[handle.id] = .connecting
        if activeBorrowedTmuxHandle == previousHandle {
            activeBorrowedTmuxHandle = handle
            publishActiveState(for: presentation)
        }
        _ = nativeTmuxSessionCoordinator.surface(handle: handle)
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

    func resumeTmuxReconnectAfterSSHRecovery(
        _ recoveryRequest: TmuxConnectionRecoveryRequest
    ) {
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
        let delays = [.zero] + createdSessionDiscoveryDelays
        presentation.establishmentConfirmationTask = Task {
            [weak self, weak presentation] in
            for delay in delays {
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
              let host = TmuxHostResolver.resolve(hostSummary)
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
                      TmuxHostResolver.resolve(currentHostSummary) == host
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
            let host = TmuxHostResolver.resolve(hostSummary),
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
                      TmuxHostResolver.resolve(currentHostSummary) == host
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
                  TmuxHostResolver.resolve
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
                switch result {
                case let .success(discovered):
                    fenceTmuxDiscoveryForCreationReconciliation(host: host)
                    tmuxDiscoveryFailuresByHost.removeValue(
                        forKey: pending.selection.hostID
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
                    if found {
                        applyDeferredTmuxPresentationsIfReady()
                    }
                    if found || isLastAttempt {
                        createdSessionDiscoveryTasks.removeValue(
                            forKey: handleID
                        )
                        return
                    }
                case let .failure(error):
                    let hostName = snapshot.host(
                        id: pending.selection.hostID
                    )?.name ?? "Unknown host"
                    tmuxDiscoveryFailuresByHost[pending.selection.hostID] =
                        "\(hostName): \(error.localizedDescription)"
                    updateWorkspaceInventoryState()
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
                createdAt: session.createdAt
            )
        }
        let discoveredNames = Set(summaries.map(\.name))
        let pendingForHost = pendingCreatedTmuxSessions.filter {
            $0.value.selection.hostID == hostID
        }
        for (handleID, pending) in pendingForHost {
            if discoveredNames.contains(pending.selection.name) {
                if let key = retainedTmuxPresentationKeysByHandle[handleID],
                   let presentation = retainedTmuxPresentations[key],
                   Self.sameTmuxSession(
                       presentation.selection,
                       pending.selection
                   ) {
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
                createdSessionDiscoveryTasks.removeValue(
                    forKey: handleID
                )?.cancel()
                exhaustedCreatedTmuxSessionHandles.remove(handleID)
                endedCreatedTmuxSessionHandles.remove(handleID)
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
