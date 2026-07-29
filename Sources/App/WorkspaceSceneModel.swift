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

@MainActor
final class WorkspaceSceneModel: ObservableObject {
    typealias KwtInventoryLoader = @Sendable (
        TmuxHost
    ) async throws -> KwtHostInventory
    typealias KwtWorktreeCreator = @Sendable (
        WorktreeCreateRequest, String, TmuxHost
    ) async throws -> Void
    typealias KwtWorktreeRemover = @Sendable (
        String, String, TmuxHost
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
    ) -> Result<[DiscoveredTmuxSession], TmuxBinaryError>
    typealias TmuxSessionKilling = @Sendable (
        WorkspaceTmuxSessionSelection, TmuxSessionIdentity, TmuxHost
    ) async throws -> Void
    typealias TmuxSessionIdentityReading = @Sendable (
        WorkspaceTmuxSessionSelection, TmuxHost
    ) async throws -> TmuxSessionIdentity
    typealias SSHHostProbeRunner = @Sendable (
        SSHHostInfo, String
    ) -> (status: Int32, stdout: String)

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
    private var tmuxDiscoveryGeneration = 0
    private var tmuxDiscoveryTask: Task<Void, Never>?
    private var createdSessionDiscoveryTasks: [UUID: Task<Void, Never>] = [:]
    private var exhaustedCreatedTmuxSessionHandles: Set<UUID> = []
    private var endedCreatedTmuxSessionHandles: Set<UUID> = []
    private let createdSessionDiscoveryDelays: [Duration]
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
    private var isWorktreeCreationInProgress = false
    private var isPullRequestImportInProgress = false
    private var isWorktreeRemovalInProgress = false

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
    private var pendingCreatedTmuxSessions:
        [UUID: WorkspaceTmuxSessionSelection] = [:]
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
    var activeBorrowedTmuxSessionIsConnected: Bool {
        guard let handle = activeBorrowedTmuxHandle else {
            return false
        }
        return borrowedTmuxConnectionStates[handle.id] == .connected
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
    private let kwtInventoryLoader: KwtInventoryLoader
    private let kwtWorktreeCreator: KwtWorktreeCreator
    private let kwtWorktreeRemover: KwtWorktreeRemover
    private let kwtBranchLister: KwtBranchLister
    private let kwtPullRequestLister: KwtPullRequestLister
    private let kwtPullRequestImporter: KwtPullRequestImporter
    private let kwtProjectRegistration: KwtProjectRegistration
    private let tmuxSessionDiscovery: TmuxSessionDiscovery
    private let tmuxSessionKiller: TmuxSessionKilling
    private let tmuxSessionIdentityReader: TmuxSessionIdentityReading
    private let sshHostProbeRunner: SSHHostProbeRunner
    private let configuredSSHHostsProvider: () -> [SSHHost]
    private var configuredSSHHostsCancellable: AnyCancellable?
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
    convenience init(terminalRuntime: LibghosttyRuntime = .shared) {
        do {
            let boot = try WorkspaceSceneBootstrap.resources()
            try self.init(
                database: boot.database,
                workspaceConfiguration: boot.workspaceConfiguration,
                terminalRuntime: terminalRuntime,
                notificationService: boot.notificationService,
                tmuxPresentationStyleProvider: {
                    let preferences = SettingsStore.shared
                        .terminalAppearancePreferences
                    guard preferences.appliesThemeToTmuxSessions,
                          let spec = preferences.theme.spec
                    else { return nil }
                    return TmuxPresentationStyle(
                        foreground: spec.foreground.hexRGB,
                        background: spec.background.hexRGB
                    )
                },
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
        (@Sendable () -> Result<String, TmuxBinaryError>)? = nil,
        remoteTmuxPathProvider: @escaping @Sendable (SSHHostInfo)
            -> Result<String, TmuxBinaryError> = {
                TmuxBinaryResolver().resolveTmuxPath(on: $0)
            },
        tmuxPresentationStyleProvider:
        @escaping () -> TmuxPresentationStyle? = { nil },
        kwtInventoryLoader: @escaping KwtInventoryLoader = { host in
            try await KwtInventoryClient().load(from: host)
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
            worktreePath, projectPath, host in
            try await KwtWorktreeClient().remove(
                worktreePath: worktreePath,
                projectPath: projectPath,
                on: host
            )
        },
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
        sshHostProbeRunner: @escaping SSHHostProbeRunner = { host, command in
            TmuxBinaryResolver.runRemoteLoginShell(
                host: host,
                command: command,
                timeout: 10
            )
        },
        configuredSSHHostsProvider: @escaping () -> [SSHHost] = {
            SettingsStore.shared.sshHosts
        },
        configuredSSHHostsPublisher: AnyPublisher<[SSHHost], Never>? = nil,
        sceneSettings: WorkspaceSceneSettings = .live(),
        localHostID: UUID? = nil,
        overrideSnapshot: WorkspaceSnapshot? = nil,
        createdSessionDiscoveryDelays: [Duration] = [
            .milliseconds(500),
            .seconds(1),
            .seconds(2),
            .seconds(4),
        ],
        startServices: Bool = false
    ) throws {
        self.database = database
        panelPreferenceStore = PanelPreferenceStore(database: database)
        panelRoutingService = PanelRoutingService(
            preferenceStore: panelPreferenceStore
        )
        self.workspaceConfiguration = workspaceConfiguration
        self.sceneSettings = sceneSettings
        self.terminalRuntime = terminalRuntime
        self.kwtInventoryLoader = kwtInventoryLoader
        self.kwtWorktreeCreator = kwtWorktreeCreator
        self.kwtWorktreeRemover = kwtWorktreeRemover
        self.kwtBranchLister = kwtBranchLister
        self.kwtPullRequestLister = kwtPullRequestLister
        self.kwtPullRequestImporter = kwtPullRequestImporter
        self.kwtProjectRegistration = kwtProjectRegistration
        self.tmuxSessionDiscovery = tmuxSessionDiscovery
        self.tmuxSessionKiller = tmuxSessionKiller
        self.tmuxSessionIdentityReader = tmuxSessionIdentityReader
        self.sshHostProbeRunner = sshHostProbeRunner
        self.createdSessionDiscoveryDelays =
            createdSessionDiscoveryDelays
        self.configuredSSHHostsProvider = configuredSSHHostsProvider
        terminalCoordinator = TerminalSurfaceCoordinator(runtime: terminalRuntime)
        self.notificationService = notificationService

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
                to: snapshot
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
                ?? tmuxResolver.resolveTmuxPath
        )
        nativeTmuxSessionCoordinatorBacking = NativeTmuxSessionCoordinator(
            terminalCoordinator: nativeTmuxSurfaceStore
                ?? terminalCoordinator,
            tmuxPathProvider: {
                tmuxPathCache.resolveTmuxPath()
            },
            presentationStyleProvider: tmuxPresentationStyleProvider,
            remoteTmuxPathProvider: remoteTmuxPathProvider
        )
        nativeTmuxSessionCoordinatorBacking?.onStateChanged = {
            [weak self] handle, state in
            self?.nativeTmuxStateChanged(handle: handle, state: state)
        }
        nativeTmuxSessionCoordinatorBacking?.onSurfaceReady = {
            [weak self] handle in
            guard self?.activeBorrowedTmuxHandle == handle else { return }
            self?.objectWillChange.send()
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
        // Forward panel routing changes to WSM's
        // objectWillChange so SwiftUI picks up state.
        panelRoutingCancellable = panelRoutingService
            .objectWillChange.sink { [weak self] _ in
                self?.objectWillChange.send()
            }
        let sshHostsPublisher = configuredSSHHostsPublisher
            ?? SettingsStore.shared.$sshHosts.eraseToAnyPublisher()
        // Defer post-init work that mutates @Published state to
        // avoid "Publishing changes from within view updates" when
        // @StateObject creates the model during body evaluation.
        DispatchQueue.main.async { [self, sshHostsPublisher] in
            configuredSSHHostsCancellable = sshHostsPublisher.sink {
                [weak self] hosts in
                guard let self, !self.hasOverrideSnapshot else { return }
                self.snapshot = applyingConfiguredSSHHosts(
                    hosts,
                    to: self.snapshot
                )
            }
            if startServices {
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
        panelRoutingCancellable?.cancel()
        configuredSSHHostsCancellable?.cancel()
        kwtInventoryTask?.cancel()
        tmuxDiscoveryTask?.cancel()
        createdSessionDiscoveryTasks.values.forEach { $0.cancel() }
        childExitCancellable?.cancel()
        appDidBecomeActiveCancellable?.cancel()
        appDidResignActiveCancellable?.cancel()
        shortcutMonitor?.uninstall()
        // Nil out controller backings so their deinits run now,
        // cancelling detached tasks that could fire closures
        // against this partially deallocated instance.
        activityControllerBacking = nil
    }

    /// Releases per-window terminal connection resources while preserving the
    /// tmux server sessions they attach to. Called by `WorkspaceWindow` before
    /// the scene model leaves the app-level window registry.
    func shutdown() async {
        kwtInventoryTask?.cancel()
        tmuxDiscoveryTask?.cancel()
        createdSessionDiscoveryTasks.values.forEach { $0.cancel() }
        createdSessionDiscoveryTasks.removeAll()
        exhaustedCreatedTmuxSessionHandles.removeAll()
        endedCreatedTmuxSessionHandles.removeAll()
        nativeTmuxSessionCoordinatorBacking?.shutdown()
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
        guard !isWorktreeCreationInProgress else {
            throw KwtWorktreeError.creationInProgress
        }
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

        isWorktreeCreationInProgress = true
        // The scene-wide refresh is cancelled so it cannot race the mutation,
        // and only the mutated host is reloaded inline. Every exit therefore
        // owes the remaining hosts a fresh sweep.
        invalidateKwtInventoryRefresh()
        defer {
            isWorktreeCreationInProgress = false
            scheduleKwtInventory()
        }

        do {
            try await kwtWorktreeCreator(request, project.rootPath, host)

            let refreshed = try await kwtInventoryLoader(host)
            let previous = kwtInventoriesByHost[project.hostID]
            kwtInventoriesByHost[project.hostID] =
                refreshed.retainingFailedProjectWorktrees(from: previous)
            kwtAvailabilityByHost[project.hostID] = true
            kwtInventoryFailuresByHost.removeValue(forKey: project.hostID)
            applyInventoryOverlayIfNeeded()
            updateWorkspaceInventoryState()
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
        selection.select(
            .worktree(created.id),
            in: snapshot,
            visibility: worktreeVisibility
        )
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
        _ worktreeID: UUID
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

        let sessionKillRequest: TmuxSessionKillRequest?
        if let session = WorkspaceSidebarModel.tmuxSessionSelection(
            for: worktree
        ) {
            if WorkspaceSidebarModel.canRequestKill(
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
            sessionKillRequest: sessionKillRequest
        )
    }

    func removeWorktree(
        _ request: WorktreeRemovalRequest
    ) async throws {
        guard !isWorktreeRemovalInProgress else {
            throw KwtWorktreeError.removalInProgress
        }
        guard let requestedWorktree = snapshot.worktree(
            id: request.worktree.id
        ),
            requestedWorktree.path == request.worktree.path,
            requestedWorktree.projectID == request.project.id,
            snapshot.canRemoveWorktree(requestedWorktree),
            let requestedProject = snapshot.project(id: request.project.id),
            requestedProject.rootPath == request.project.rootPath,
            let hostSummary = snapshot.host(id: requestedWorktree.hostID),
            let host = TmuxHostResolver.resolve(hostSummary)
        else {
            throw KwtWorktreeError.worktreeUnavailable
        }

        isWorktreeRemovalInProgress = true
        invalidateKwtInventoryRefresh()
        defer {
            isWorktreeRemovalInProgress = false
            scheduleKwtInventory()
        }

        let preflight: KwtHostInventory
        do {
            preflight = try await kwtInventoryLoader(host)
        } catch {
            recordKwtUnavailability(
                error,
                hostID: requestedProject.hostID
            )
            throw error
        }
        let (worktree, project) = try reconcileRemovalPreflight(
            preflight,
            request: request
        )

        if request.sessionKillRequest == nil,
           let session = WorkspaceSidebarModel.tmuxSessionSelection(
               for: worktree
           ) {
            do {
                _ = try await tmuxSessionIdentityReader(session, host)
                throw KwtWorktreeError.sessionStartedAfterConfirmation(
                    session: session.name
                )
            } catch TmuxSessionKillError.sessionNotRunning {
                // The confirmation remains accurate.
            }
        }

        do {
            if let sessionKillRequest = request.sessionKillRequest {
                try await killTmuxSession(sessionKillRequest)
            }
            try await kwtWorktreeRemover(
                worktree.path,
                project.rootPath,
                host
            )
        } catch {
            recordKwtUnavailability(error, hostID: project.hostID)
            throw error
        }

        removeWorktreeFromCachedState(
            worktree,
            hostID: project.hostID
        )
        scheduleTmuxSessionDiscovery()

        do {
            let refreshed = try await kwtInventoryLoader(host)
            let previous = kwtInventoriesByHost[project.hostID]
            kwtInventoriesByHost[project.hostID] =
                refreshed.retainingFailedProjectWorktrees(
                    from: previous,
                    excludingWorktreePaths: [worktree.path]
                )
            kwtAvailabilityByHost[project.hostID] = true
            kwtInventoryFailuresByHost.removeValue(forKey: project.hostID)
            applyInventoryOverlayIfNeeded()
            updateWorkspaceInventoryState()
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

    private func reconcileRemovalPreflight(
        _ inventory: KwtHostInventory,
        request: WorktreeRemovalRequest
    ) throws -> (WorktreeSummary, ProjectSummary) {
        let hostID = request.project.hostID
        let previous = kwtInventoriesByHost[hostID]
        kwtInventoriesByHost[hostID] =
            inventory.retainingFailedProjectWorktrees(from: previous)
        kwtAvailabilityByHost[hostID] = true
        kwtInventoryFailuresByHost.removeValue(forKey: hostID)
        applyInventoryOverlayIfNeeded()
        updateWorkspaceInventoryState()

        guard let item = inventory.projects.first(where: {
            $0.project.repository == request.project.scopedKey
                || $0.project.path == request.project.rootPath
        }),
            item.warning == nil,
            item.project.repository == request.project.scopedKey,
            item.project.path == request.project.rootPath,
            let record = item.worktrees.first(where: {
                $0.path == request.worktree.path
            }),
            record.repository == request.project.scopedKey,
            record.branch == request.worktree.branch,
            record.isMain == request.worktree.isPrimary,
            record.sessionName == request.worktree.tmuxSessionName,
            record.tmuxSocketName == request.worktree.tmuxSocketName,
            let worktree = snapshot.worktree(id: request.worktree.id),
            let project = snapshot.project(id: request.project.id),
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
            && killRequest.session.worktreePath == worktree.path
            && killRequest.session.socketName == worktree.tmuxSocketName
    }

    private func removeWorktreeFromCachedState(
        _ worktree: WorktreeSummary,
        hostID: UUID
    ) {
        if let inventory = kwtInventoriesByHost[hostID] {
            kwtInventoriesByHost[hostID] =
                inventory.removingWorktree(atPath: worktree.path)
        }
        snapshot.worktrees.removeAll { $0.id == worktree.id }
        snapshot.sessions.removeAll { $0.worktreeID == worktree.id }
        applyInventoryOverlayIfNeeded()
        selection = Self.selectionAfterWorktreeRemoval(
            selection,
            in: snapshot,
            visibility: worktreeVisibility
        )
        updateWorkspaceInventoryState()
    }

    static func selectionAfterWorktreeRemoval(
        _ current: WorkspaceSelection,
        in snapshot: WorkspaceSnapshot,
        visibility: WorktreeVisibility
    ) -> WorkspaceSelection {
        current.normalizedBySelectingVisibleFallback(
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
        guard !isPullRequestImportInProgress else {
            throw KwtPullRequestError.importInProgress
        }
        guard let project = snapshot.project(id: request.projectID),
              snapshot.canImportPullRequest(in: project),
              let hostSummary = snapshot.host(id: project.hostID),
              let host = TmuxHostResolver.resolve(hostSummary)
        else {
            throw KwtPullRequestError.projectUnavailable
        }

        isPullRequestImportInProgress = true
        // See `createWorktree`: cancelling the scene-wide refresh leaves every
        // host but this one stale, including on the success path.
        invalidateKwtInventoryRefresh()
        defer {
            isPullRequestImportInProgress = false
            scheduleKwtInventory()
        }

        let result: KwtPullRequestImportResult
        do {
            result = try await kwtPullRequestImporter(
                request.pullRequestID,
                project.scopedKey,
                host
            )
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
            let previous = kwtInventoriesByHost[project.hostID]
            kwtInventoriesByHost[project.hostID] =
                refreshed.retainingFailedProjectWorktrees(from: previous)
            kwtInventoryFailuresByHost.removeValue(forKey: project.hostID)
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
        selection.select(
            .worktree(imported.id),
            in: snapshot,
            visibility: worktreeVisibility
        )
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
        inventoryHosts = resolved
        applyInventoryOverlayIfNeeded()
        scheduleKwtInventory()
        scheduleTmuxSessionDiscovery()
    }

    private func applyInventoryOverlayIfNeeded() {
        let overlaid = applyingCachedInventories(to: snapshot)
        guard overlaid != snapshot else { return }
        isApplyingInventoryOverlay = true
        snapshot = overlaid
        isApplyingInventoryOverlay = false
    }

    private func scheduleKwtInventory() {
        guard kwtInventoryEnabled,
              Self.canScheduleKwtInventory(
                  isWorktreeCreationInProgress:
                  isWorktreeCreationInProgress,
                  isPullRequestImportInProgress:
                  isPullRequestImportInProgress,
                  isWorktreeRemovalInProgress:
                  isWorktreeRemovalInProgress
              ) else { return }
        let targets = Array(inventoryHosts)
        kwtInventoryGeneration += 1
        let generation = kwtInventoryGeneration
        kwtInventoryTask?.cancel()
        isKwtInventoryLoading = true
        updateWorkspaceInventoryState()
        let kwtInventoryLoader = kwtInventoryLoader
        kwtInventoryTask = Task { [weak self] in
            await withTaskGroup(
                of: (UUID, Result<KwtHostInventory, Error>).self
            ) { group in
                for (hostID, host) in targets {
                    group.addTask {
                        do {
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
                        let previous = self.kwtInventoriesByHost[hostID]
                        self.kwtInventoriesByHost[hostID] =
                            inventory.retainingFailedProjectWorktrees(
                                from: previous
                            )
                        self.kwtAvailabilityByHost[hostID] = true
                        // A host inventory is useful even when one project
                        // cannot be read. Retain that project's cached
                        // worktrees and keep other hosts available.
                        self.kwtInventoryFailuresByHost.removeValue(
                            forKey: hostID
                        )
                    case let .failure(error):
                        if self.isRemoteKwtUnavailable(
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
                    self.applyInventoryOverlayIfNeeded()
                    self.updateWorkspaceInventoryState()
                }
            }
            guard let self, !Task.isCancelled,
                  generation == kwtInventoryGeneration else { return }
            isKwtInventoryLoading = false
            updateWorkspaceInventoryState()
        }
    }

    static func canScheduleKwtInventory(
        isWorktreeCreationInProgress: Bool,
        isPullRequestImportInProgress: Bool,
        isWorktreeRemovalInProgress: Bool
    ) -> Bool {
        !isWorktreeCreationInProgress
            && !isPullRequestImportInProgress
            && !isWorktreeRemovalInProgress
    }

    private func invalidateKwtInventoryRefresh() {
        kwtInventoryGeneration += 1
        kwtInventoryTask?.cancel()
        kwtInventoryTask = nil
        isKwtInventoryLoading = false
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
        isTmuxDiscoveryLoading = true
        updateWorkspaceInventoryState()
        let tmuxSessionDiscovery = tmuxSessionDiscovery
        tmuxDiscoveryTask = Task { [weak self] in
            await withTaskGroup(
                of: (UUID, Result<[DiscoveredTmuxSession], TmuxBinaryError>).self
            ) { group in
                for (hostID, host) in targets {
                    group.addTask {
                        (hostID, tmuxSessionDiscovery(host))
                    }
                }
                for await (hostID, result) in group {
                    guard let self, !Task.isCancelled,
                          generation == self.tmuxDiscoveryGeneration else {
                        group.cancelAll()
                        return
                    }
                    guard case let .success(discovered) = result else {
                        if case let .failure(error) = result {
                            self.tmuxReachabilityByHost[hostID] = false
                            let hostName = self.snapshot.host(id: hostID)?.name
                                ?? "Unknown host"
                            self.tmuxDiscoveryFailuresByHost[hostID] =
                                "\(hostName): \(error.localizedDescription)"
                        }
                        self.applyInventoryOverlayIfNeeded()
                        self.updateWorkspaceInventoryState()
                        continue
                    }
                    self.tmuxDiscoveryFailuresByHost.removeValue(forKey: hostID)
                    self.tmuxReachabilityByHost[hostID] = true
                    self.tmuxLastSeenByHost[hostID] = Date()
                    self.tmuxSessionsByHost[hostID] =
                        self.reconciledTmuxSessions(
                            discovered,
                            hostID: hostID
                        )
                    self.applyInventoryOverlayIfNeeded()
                    self.updateWorkspaceInventoryState()
                }
            }
            guard let self, !Task.isCancelled,
                  generation == tmuxDiscoveryGeneration else { return }
            isTmuxDiscoveryLoading = false
            updateWorkspaceInventoryState()
        }
    }

    private func fenceTmuxDiscoveryForCreationReconciliation() {
        tmuxDiscoveryGeneration += 1
        tmuxDiscoveryTask?.cancel()
        tmuxDiscoveryTask = nil
        isTmuxDiscoveryLoading = false
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
        let hostIDs = Set(kwtInventoryFailuresByHost.keys)
            .union(tmuxDiscoveryFailuresByHost.keys)
        workspaceInventoryWarningsByHost = Dictionary(
            uniqueKeysWithValues: hostIDs.compactMap { hostID in
                let warnings = [
                    kwtInventoryFailuresByHost[hostID],
                    tmuxDiscoveryFailuresByHost[hostID],
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
        snapshot = applyingConfiguredSSHHosts(
            configuredSSHHostsProvider(),
            to: snapshot
        )
    }

    private func applyingConfiguredSSHHosts(
        _ configuredHosts: [SSHHost],
        to source: WorkspaceSnapshot
    ) -> WorkspaceSnapshot {
        let updated = ConfiguredHostOverlay.apply(
            configuredHosts,
            to: source
        )
        let previousTargets = Dictionary(
            uniqueKeysWithValues: source.hosts.compactMap { host in
                TmuxHostResolver.resolve(host).map { (host.id, $0) }
            }
        )
        let updatedTargets = Dictionary(
            uniqueKeysWithValues: updated.hosts.compactMap { host in
                TmuxHostResolver.resolve(host).map { (host.id, $0) }
            }
        )
        let invalidatedHostIDs = Set(previousTargets.keys.filter { hostID in
            previousTargets[hostID] != updatedTargets[hostID]
        })
        invalidateTmuxAttachments(for: invalidatedHostIDs)
        return updated
    }

    private func invalidateTmuxAttachments(for hostIDs: Set<UUID>) {
        guard !hostIDs.isEmpty else { return }
        let pendingForInvalidatedHosts = pendingCreatedTmuxSessions.filter {
            hostIDs.contains($0.value.hostID)
        }
        for (handleID, pending) in pendingForInvalidatedHosts {
            createdSessionDiscoveryTasks.removeValue(
                forKey: handleID
            )?.cancel()
            exhaustedCreatedTmuxSessionHandles.remove(handleID)
            endedCreatedTmuxSessionHandles.remove(handleID)
            pendingCreatedTmuxSessions.removeValue(forKey: handleID)
            borrowedTmuxConnectionStates.removeValue(forKey: handleID)
            removeOptimisticTmuxSession(pending)
        }
        for hostID in hostIDs {
            let handles = nativeTmuxSessionCoordinator.detachAll(
                hostID: hostID
            )
            for handle in handles {
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
    }

    func probeSSHHost(
        _ host: SSHHost
    ) async -> Result<
        HostProbeSummary,
        HostProbeError
    > {
        guard let parsedSSHHost = TmuxHostResolver.parseSSHDestination(
            host.sshDestination
        ) else {
            return .failure(.message("Enter a valid SSH destination."))
        }
        let sshHost = SSHHostInfo(
            user: parsedSSHHost.user,
            hostname: parsedSSHHost.hostname,
            port: parsedSSHHost.port,
            platform: host.platform == .windows ? .windows : .posix
        )
        let sshHostProbeRunner = sshHostProbeRunner
        let kwtPrelude = KwtBinaryLocator.remoteCommandPrelude(
            revision: KwtBinaryLocator.bundledRemoteRevision()
        )
        let windowsKwtRelativePath =
            KwtBinaryLocator.windowsRemoteManagedRelativePath(
                revision: KwtBinaryLocator.bundledRemoteRevision()
            )
        let probeCommand: String
        if host.platform == .windows {
            probeCommand = """
            $ErrorActionPreference = 'Stop'
            [Console]::OutputEncoding = [System.Text.UTF8Encoding]::new($false)
            $OutputEncoding = [Console]::OutputEncoding
            Write-Output 'GHOSTHUB_SSH_REACHED'
            $ghosthubMuxCommand = Get-Command tmux.exe -CommandType Application -ErrorAction SilentlyContinue
            if ($null -eq $ghosthubMuxCommand) {
                Write-Output 'GHOSTHUB_TMUX_UNAVAILABLE'
                exit 127
            }
            Write-Output 'GHOSTHUB_TMUX_AVAILABLE'
            $ghosthubMux = $ghosthubMuxCommand.Source
            & $ghosthubMux '-V' *> $null
            if ($LASTEXITCODE -ne 0) {
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
            """
        } else {
            probeCommand =
                "printf 'GHOSTHUB_SSH_REACHED\\n'; "
                    + "ghosthub_tmux_path=$(command -v tmux) || { "
                    + "printf 'GHOSTHUB_TMUX_UNAVAILABLE\\n'; exit 127; }; "
                    + "printf 'GHOSTHUB_TMUX_AVAILABLE\\n'; "
                    + "\"$ghosthub_tmux_path\" -V >/dev/null || exit $?; "
                    + "if ( \(kwtPrelude): ); then "
                    + "printf 'GHOSTHUB_KWT_AVAILABLE\\n'; "
                    + "else printf 'GHOSTHUB_KWT_UNAVAILABLE\\n'; fi"
        }
        return await Task.detached {
            let result = sshHostProbeRunner(
                sshHost,
                probeCommand
            )
            let sshReached = result.stdout.contains(
                "GHOSTHUB_SSH_REACHED"
            )
            let tmuxAvailable = result.stdout.contains(
                "GHOSTHUB_TMUX_AVAILABLE"
            )
            let kwtAvailable = result.stdout.contains(
                "GHOSTHUB_KWT_AVAILABLE"
            )
            let diagnostics: [RemoteHostDiagnostic]
            if !sshReached {
                diagnostics = [RemoteHostDiagnostic(
                    code: .sshConnectionFailed,
                    severity: .error,
                    summary: "SSH could not be reached.",
                    recoverySuggestion:
                    "Run `ssh \(host.sshDestination)` in Terminal once to "
                        + "accept the host key, then verify key-based "
                        + "authentication works without a prompt."
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
        sessionName: String
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
                displayTitle: snapshot.worktrees.first {
                    $0.hostID == host.id
                        && $0.tmuxSessionName == sessionName
                }?.name,
                connectionState: borrowedTmuxConnectionStates[handle.id],
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
        let hasPendingCreation = pendingCreatedTmuxSessions.values.contains {
            Self.sameTmuxSession($0, selection)
        }
        presentTmuxSession(
            selection,
            launchMode: selection.socketName == nil && hasPendingCreation
                ? .create
                : .attach
        )
    }

    func createTmuxSession(_ selection: WorkspaceTmuxSessionSelection) {
        let hasPendingCreation = pendingCreatedTmuxSessions.values.contains {
            Self.sameTmuxSession($0, selection)
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
            launchMode: launchMode
        ) else { return }
        if launchMode == .create {
            pendingCreatedTmuxSessions[handle.id] = selection
            _ = publishCreatedTmuxSession(selection)
        }
    }

    @discardableResult
    private func presentTmuxSession(
        _ selection: WorkspaceTmuxSessionSelection,
        launchMode: TmuxAttachmentLaunchMode
    ) -> BorrowedTmuxSessionHandle? {
        let effectiveLaunchMode: TmuxAttachmentLaunchMode =
            selection.socketName == nil ? launchMode : .attach
        if let active = activeBorrowedTmuxSelection, active != selection {
            closeBorrowedTmuxSession(active)
        }
        guard let host = snapshot.host(id: selection.hostID),
              let attachmentHost = TmuxHostResolver.resolve(host)
        else {
            activeBorrowedTmuxSelection = selection
            activeBorrowedTmuxHandle = nil
            activeBorrowedTmuxLaunchMode = effectiveLaunchMode
            return nil
        }
        let knownSessions = tmuxSessionsByHost[selection.hostID]
            ?? host.tmuxSessions
        let sessionIsDiscovered = selection.socketName == nil
            && knownSessions.contains { $0.name == selection.name }
        let managedKwtUnavailable = host.remoteDiagnostics.contains {
            $0.code == .missingKwt
        }
        let openWorkspace = effectiveLaunchMode == .attach
            && selection.socketName == nil
            && selection.worktreePath != nil
            && (!sessionIsDiscovered || !managedKwtUnavailable)
        let handle = nativeTmuxSessionCoordinator.attach(
            hostID: selection.hostID,
            name: selection.name,
            host: attachmentHost,
            socketName: selection.socketName,
            launchMode: effectiveLaunchMode,
            workingDirectory: selection.worktreePath,
            openWorkspace: openWorkspace
        )
        activeBorrowedTmuxSelection = selection
        activeBorrowedTmuxHandle = handle
        activeBorrowedTmuxLaunchMode = effectiveLaunchMode
        borrowedTmuxConnectionStates[handle.id] = .connecting
        if effectiveLaunchMode == .create {
            transferPendingCreation(for: selection, to: handle)
        }
        return handle
    }

    private static func sameTmuxSession(
        _ lhs: WorkspaceTmuxSessionSelection,
        _ rhs: WorkspaceTmuxSessionSelection
    ) -> Bool {
        lhs.hostID == rhs.hostID
            && lhs.name == rhs.name
            && lhs.socketName == rhs.socketName
    }

    private func transferPendingCreation(
        for selection: WorkspaceTmuxSessionSelection,
        to handle: BorrowedTmuxSessionHandle
    ) {
        let previousHandleIDs = pendingCreatedTmuxSessions.compactMap {
            handleID, pending in
            Self.sameTmuxSession(pending, selection) ? handleID : nil
        }
        guard !previousHandleIDs.isEmpty,
              !previousHandleIDs.contains(handle.id) else { return }
        for handleID in previousHandleIDs {
            createdSessionDiscoveryTasks.removeValue(
                forKey: handleID
            )?.cancel()
            exhaustedCreatedTmuxSessionHandles.remove(handleID)
            endedCreatedTmuxSessionHandles.remove(handleID)
            pendingCreatedTmuxSessions.removeValue(forKey: handleID)
            borrowedTmuxConnectionStates.removeValue(forKey: handleID)
        }
        pendingCreatedTmuxSessions[handle.id] = selection
    }

    func closeBorrowedTmuxSession(_ selection: WorkspaceTmuxSessionSelection) {
        guard activeBorrowedTmuxSelection == selection else { return }
        if let handle = activeBorrowedTmuxHandle {
            borrowedTmuxConnectionStates.removeValue(forKey: handle.id)
            if pendingCreatedTmuxSessions[handle.id] != nil,
               nativeTmuxSessionCoordinator.hasLaunched(handle) {
                endedCreatedTmuxSessionHandles.insert(handle.id)
                reconcileCreatedTmuxSession(
                    handleID: handle.id,
                    immediately: true
                )
            } else if let pending = pendingCreatedTmuxSessions[handle.id] {
                createdSessionDiscoveryTasks.removeValue(
                    forKey: handle.id
                )?.cancel()
                pendingCreatedTmuxSessions.removeValue(forKey: handle.id)
                exhaustedCreatedTmuxSessionHandles.remove(handle.id)
                endedCreatedTmuxSessionHandles.remove(handle.id)
                removeOptimisticTmuxSession(pending)
            }
        }
        activeBorrowedTmuxSelection = nil
        activeBorrowedTmuxHandle = nil
        activeBorrowedTmuxLaunchMode = nil
        nativeTmuxSessionCoordinator.detach(
            hostID: selection.hostID,
            name: selection.name,
            socketName: selection.socketName
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

        let discoveredIdentity = selection.socketName == nil
            ? currentHostSummary.tmuxSessions.first {
                $0.name == selection.name
            }.flatMap { summary -> TmuxSessionIdentity? in
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
            : nil
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
            Self.sameTmuxSession($0, tmuxSelection) ? $0 : nil
        }
        if let activeTargetAfterKill {
            closeBorrowedTmuxSession(activeTargetAfterKill)
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

    private func isConnectedActiveTmuxSession(
        _ selection: WorkspaceTmuxSessionSelection
    ) -> Bool {
        guard let activeSelection = activeBorrowedTmuxSelection,
              Self.sameTmuxSession(activeSelection, selection),
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
        guard pendingCreatedTmuxSessions[handle.id] != nil else {
            return
        }
        switch state {
        case .connected:
            reconcileCreatedTmuxSession(handleID: handle.id)
        case .disconnected:
            guard nativeTmuxSessionCoordinator.hasLaunched(handle) else {
                return
            }
            endedCreatedTmuxSessionHandles.insert(handle.id)
            reconcileCreatedTmuxSession(
                handleID: handle.id,
                immediately: true
            )
        case .connecting, .reconnecting:
            break
        }
    }

    private func reconcileCreatedTmuxSession(
        handleID: UUID,
        immediately: Bool = false
    ) {
        guard let pending = pendingCreatedTmuxSessions[handleID],
              let host = inventoryHosts[pending.hostID]
              ?? snapshot.host(id: pending.hostID).flatMap(
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
                    discovery(host)
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
                    fenceTmuxDiscoveryForCreationReconciliation()
                    tmuxDiscoveryFailuresByHost.removeValue(
                        forKey: pending.hostID
                    )
                    let found = discovered.contains {
                        $0.name == pending.name
                    }
                    let isLastAttempt = index == delays.indices.last
                    if !found, isLastAttempt {
                        exhaustedCreatedTmuxSessionHandles.insert(
                            handleID
                        )
                    }
                    tmuxSessionsByHost[pending.hostID] =
                        reconciledTmuxSessions(
                            discovered,
                            hostID: pending.hostID
                        )
                    applyInventoryOverlayIfNeeded()
                    updateWorkspaceInventoryState()
                    if found || isLastAttempt {
                        createdSessionDiscoveryTasks.removeValue(
                            forKey: handleID
                        )
                        return
                    }
                case let .failure(error):
                    let hostName = snapshot.host(
                        id: pending.hostID
                    )?.name ?? "Unknown host"
                    tmuxDiscoveryFailuresByHost[pending.hostID] =
                        "\(hostName): \(error.localizedDescription)"
                    updateWorkspaceInventoryState()
                }
            }
            guard let self,
                  pendingCreatedTmuxSessions[handleID] == pending
            else { return }
            createdSessionDiscoveryTasks.removeValue(forKey: handleID)
            exhaustedCreatedTmuxSessionHandles.insert(handleID)
            fenceTmuxDiscoveryForCreationReconciliation()
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
            $0.value.hostID == hostID
        }
        for (handleID, pending) in pendingForHost {
            if discoveredNames.contains(pending.name) {
                if activeBorrowedTmuxHandle?.id == handleID,
                   activeBorrowedTmuxSelection.map({
                       Self.sameTmuxSession($0, pending)
                   }) == true {
                    activeBorrowedTmuxLaunchMode = .attach
                }
                pendingCreatedTmuxSessions.removeValue(forKey: handleID)
                createdSessionDiscoveryTasks.removeValue(
                    forKey: handleID
                )?.cancel()
                exhaustedCreatedTmuxSessionHandles.remove(handleID)
                endedCreatedTmuxSessionHandles.remove(handleID)
            } else if exhaustedCreatedTmuxSessionHandles.contains(handleID),
                      endedCreatedTmuxSessionHandles.contains(handleID) {
                pendingCreatedTmuxSessions.removeValue(forKey: handleID)
                createdSessionDiscoveryTasks.removeValue(
                    forKey: handleID
                )?.cancel()
                exhaustedCreatedTmuxSessionHandles.remove(handleID)
                endedCreatedTmuxSessionHandles.remove(handleID)
            } else {
                summaries.append(TmuxSessionSummary(
                    name: pending.name,
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
        applyInventoryOverlayIfNeeded()
    }

    func retryBorrowedTmuxSession(
        _ selection: WorkspaceTmuxSessionSelection
    ) {
        guard activeBorrowedTmuxSelection == selection else { return }
        let launchMode = activeBorrowedTmuxLaunchMode ?? .attach
        closeBorrowedTmuxSession(selection)
        switch launchMode {
        case .create:
            createTmuxSession(selection)
        case .attach:
            presentTmuxSession(selection, launchMode: .attach)
        }
    }

    private var isApplicationActiveForResourceMonitoring: Bool {
        #if canImport(AppKit)
        NSApplication.shared.isActive
        #else
        true
        #endif
    }

}
