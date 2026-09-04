import GhosthubTransport
import AppKit
import Combine
import Foundation
import GhosthubHerdr
import GhosthubTestSupport
import SwiftUI
import XCTest
import GhosthubPersistence
import GhosthubSettings
import GhosthubTmux
import GhosthubWorkspace
import GhosthubZellij
@testable import GhosthubTerminal
import GhosthubTerminalSupport
@testable import GhosthubApp

func successfulTmuxResolution(
    _ path: String,
    version: String = "tmux 3.4"
) -> Result<ResolvedTmuxBinary, TmuxBinaryError> {
    .success(ResolvedTmuxBinary(path: path, version: version))
}

// MARK: - Environment Setup

struct HostEnv {
    let id: UUID
    let configKey: String
    let name: String
    let kind: HostKind
    let platform: HostPlatform
    let sshDestination: String?
}

struct ProjectEnv {
    let id: UUID
    let hostID: UUID
    let scopedKey: String
    let name: String
    let rootPath: String
    let defaultBranch: String
    var registryID: String?
}

struct WorktreeEnv {
    let id: UUID
    let hostID: UUID
    let projectID: UUID
    let scopedKey: String
    let name: String
    let path: String
    let branch: String
    let isPrimary: Bool
    let isHidden: Bool
    var registryID: String?
}

struct StandardEnvironment {
    let database: WorkspaceDatabase
    let host: HostEnv
    let project: ProjectEnv
    let worktree: WorktreeEnv
    let snapshot: WorkspaceSnapshot
}

func setupStandardEnvironment() throws -> StandardEnvironment {
    let database = try WorkspaceDatabase.inMemory()
    let hostID = UUID()
    let projectID = UUID()
    let worktreeID = UUID()
    let host = HostEnv(
        id: hostID,
        configKey: "local",
        name: "This Mac",
        kind: .selfHost,
        platform: .macOS,
        sshDestination: nil
    )
    let project = ProjectEnv(
        id: projectID,
        hostID: hostID,
        scopedKey: "repo:/tmp/ghosthub",
        name: "Ghosthub",
        rootPath: "/tmp/ghosthub",
        defaultBranch: "main",
        registryID: "mm-proj-local"
    )
    // The primary root checkout is a first-class inventory row
    // (registryID set) since the 2026-06-11 primary-root registration.
    let worktree = WorktreeEnv(
        id: worktreeID,
        hostID: hostID,
        projectID: projectID,
        scopedKey: "worktree:/tmp/ghosthub",
        name: "root",
        path: "/tmp/ghosthub",
        branch: "main",
        isPrimary: true,
        isHidden: false,
        registryID: "mm-wt-root"
    )
    let snapshot = WorkspaceSnapshot(
        hosts: [
            HostSummary(
                id: hostID, configKey: host.configKey,
                name: host.name, kind: host.kind,
                platform: host.platform,
                sshDestination: host.sshDestination
            ),
        ],
        projects: [
            ProjectSummary(
                id: projectID, hostID: hostID,
                scopedKey: project.scopedKey,
                registryID: project.registryID,
                name: project.name,
                rootPath: project.rootPath,
                registrationFingerprint: "standard-registration",
                defaultBranch: project.defaultBranch
            ),
        ],
        worktrees: [
            WorktreeSummary(
                id: worktreeID, hostID: hostID,
                projectID: projectID,
                scopedKey: worktree.scopedKey,
                registryID: worktree.registryID,
                name: worktree.name,
                path: worktree.path,
                branch: worktree.branch,
                isPrimary: worktree.isPrimary
            ),
        ]
    )
    return StandardEnvironment(
        database: database,
        host: host,
        project: project,
        worktree: worktree,
        snapshot: snapshot
    )
}

struct HostEnvironment {
    let database: WorkspaceDatabase
    let host: HostEnv
    let snapshot: WorkspaceSnapshot
}

func setupHostEnvironment() throws -> HostEnvironment {
    let database = try WorkspaceDatabase.inMemory()
    let hostID = UUID()
    let host = HostEnv(
        id: hostID,
        configKey: "local",
        name: "This Mac",
        kind: .selfHost,
        platform: .macOS,
        sshDestination: nil
    )
    let snapshot = WorkspaceSnapshot(
        hosts: [
            HostSummary(
                id: hostID, configKey: host.configKey,
                name: host.name, kind: host.kind,
                platform: host.platform,
                sshDestination: host.sshDestination
            ),
        ],
        projects: [],
        worktrees: []
    )
    return HostEnvironment(database: database, host: host, snapshot: snapshot)
}

struct RemoteEnvironment {
    let database: WorkspaceDatabase
    let host: HostEnv
    let project: ProjectEnv
    let worktree: WorktreeEnv
    let snapshot: WorkspaceSnapshot
}

struct RemoteTmuxTestEnvironment {
    let database: WorkspaceDatabase
    let snapshot: WorkspaceSnapshot
    let localHostID: UUID
    let remoteHost: HostSummary
}

func setupRemoteTmuxEnvironment() throws -> RemoteTmuxTestEnvironment {
    let standard = try setupStandardEnvironment()
    let remoteHost = HostSummary(
        id: UUID(),
        configKey: "build-box",
        name: "Build Box",
        kind: .remote,
        platform: .linux,
        sshDestination: "wesm@build-box",
        preferredTransport: .ssh,
        lastKnownReachable: true,
        tmuxSessions: [
            TmuxSessionSummary(
                name: "release-work",
                managed: false,
                windows: []
            ),
        ]
    )
    var snapshot = standard.snapshot
    snapshot.hosts.append(remoteHost)
    return RemoteTmuxTestEnvironment(
        database: standard.database,
        snapshot: snapshot,
        localHostID: standard.host.id,
        remoteHost: remoteHost
    )
}

func setupRemoteEnvironment() throws -> RemoteEnvironment {
    let database = try WorkspaceDatabase.inMemory()
    let hostID = UUID()
    let projectID = UUID()
    let worktreeID = UUID()
    let host = HostEnv(
        id: hostID,
        configKey: "office-linux",
        name: "Office Linux",
        kind: .remote,
        platform: .linux,
        sshDestination: "wesm@office-linux"
    )
    let project = ProjectEnv(
        id: projectID,
        hostID: hostID,
        scopedKey: "repo:/srv/ghosthub",
        name: "Ghosthub",
        rootPath: "/srv/ghosthub",
        defaultBranch: "main",
        registryID: "mm-proj-1"
    )
    let worktree = WorktreeEnv(
        id: worktreeID,
        hostID: hostID,
        projectID: projectID,
        scopedKey: "worktree:/srv/ghosthub",
        name: "root",
        path: "/srv/ghosthub",
        branch: "main",
        isPrimary: false,
        isHidden: false,
        registryID: "mm-wt-1"
    )
    let snapshot = WorkspaceSnapshot(
        hosts: [
            HostSummary(
                id: hostID, configKey: host.configKey,
                name: host.name, kind: host.kind,
                platform: host.platform,
                sshDestination: host.sshDestination
            ),
        ],
        projects: [
            ProjectSummary(
                id: projectID, hostID: hostID,
                scopedKey: project.scopedKey,
                registryID: project.registryID,
                name: project.name,
                rootPath: project.rootPath,
                registrationFingerprint: "remote-registration",
                defaultBranch: project.defaultBranch
            ),
        ],
        worktrees: [
            WorktreeSummary(
                id: worktreeID, hostID: hostID,
                projectID: projectID,
                scopedKey: worktree.scopedKey,
                registryID: worktree.registryID,
                name: worktree.name,
                path: worktree.path,
                branch: worktree.branch,
                isPrimary: worktree.isPrimary,
                sessionBackend: .remoteTmux
            ),
        ]
    )
    return RemoteEnvironment(
        database: database,
        host: host,
        project: project,
        worktree: worktree,
        snapshot: snapshot
    )
}

// MARK: - Model Factory

@MainActor
func makeModel(
    database: WorkspaceDatabase,
    localHostID: UUID,
    snapshot: WorkspaceSnapshot? = nil,
    configuration: WorkspaceConfiguration = .defaults(),
    terminalRuntime: LibghosttyRuntime = .shared,
    notificationService: any NotificationService = NotificationServiceStub(),
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
        -> Result<ResolvedTmuxBinary, TmuxBinaryError> = { _, _ in
            .failure(.notFound(shell: "test"))
        },
    tmuxPresentationStyleProvider:
    @escaping (UInt?) -> TmuxPresentationStyle? = { _ in nil },
    appliesTmuxPresentationStyleToExistingSessionsProvider:
    @escaping () -> Bool = { false },
    activeDisplayCount: @escaping @Sendable () -> Int = { 1 },
    kwtInventoryLoader: @escaping WorkspaceSceneModel.KwtInventoryLoader = {
        host in
        try await KwtInventoryClient().load(from: host)
    },
    kwtConditionalInventoryLoader:
    WorkspaceSceneModel.KwtConditionalInventoryLoader? = nil,
    kwtRemoteProvisioner:
    @escaping WorkspaceSceneModel.KwtRemoteProvisioner = { _ in },
    kwtRemoteInstaller:
    @escaping WorkspaceSceneModel.KwtRemoteInstalling = { _ in },
    kwtWorktreeCreator: @escaping WorkspaceSceneModel.KwtWorktreeCreator = {
        request, projectPath, host in
        try await KwtWorktreeClient().create(
            request: request,
            projectPath: projectPath,
            on: host
        )
    },
    kwtWorktreeRemover: @escaping WorkspaceSceneModel.KwtWorktreeRemover = {
        worktreePath, generation, projectPath, routeIdentity, host in
        try await KwtWorktreeClient().remove(
            worktreePath: worktreePath,
            generation: generation,
            projectPath: projectPath,
            expectedRouteIdentity: routeIdentity,
            on: host
        )
    },
    kwtForceWorktreeRemover:
    @escaping WorkspaceSceneModel.KwtWorktreeRemover = { _, _, _, _, _ in },
    kwtWorktreeChangeReader:
    @escaping WorkspaceSceneModel.KwtWorktreeChangeReader = { _, _, _ in
        .clean
    },
    sshRouteIdentityResolver:
    @escaping WorkspaceSceneModel.SSHRouteIdentityResolver = { _ in
        "sha256:test-route"
    },
    worktreeMutationCoordinator: WorktreeMutationCoordinator =
        WorktreeMutationCoordinator(),
    herdrLifecycleCoordinator: HerdrSessionLifecycleCoordinator =
        HerdrSessionLifecycleCoordinator(),
    zellijSessionKillCoordinator: ZellijSessionKillCoordinator =
        ZellijSessionKillCoordinator(),
    herdrSessionRecordReader:
    @escaping WorkspaceSceneModel.HerdrSessionRecordReading = { name, _, _ in
        .failure(.sessionMissing(name))
    },
    herdrSessionMutator:
    @escaping WorkspaceSceneModel.HerdrSessionMutating = { _, record, _, _ in
        .success(record)
    },
    herdrSSHConnectionSnapshotProvider:
    @escaping WorkspaceSceneModel.SSHConnectionSnapshotProvider = {
        _ in SSHConnectionArgumentsSnapshot(arguments: [])
    },
    kwtBranchLister: @escaping WorkspaceSceneModel.KwtBranchLister = {
        projectPath, host in
        try await KwtWorktreeClient().branches(
            projectPath: projectPath,
            on: host
        )
    },
    kwtPullRequestLister:
    @escaping WorkspaceSceneModel.KwtPullRequestLister = {
        projectIdentity, host in
        try await KwtPullRequestClient().list(
            projectIdentity: projectIdentity,
            on: host
        )
    },
    kwtPullRequestImporter:
    @escaping WorkspaceSceneModel.KwtPullRequestImporter = {
        id, projectIdentity, host in
        try await KwtPullRequestClient().importPullRequest(
            id: id,
            projectIdentity: projectIdentity,
            on: host
        )
    },
    kwtProjectRegistration:
    @escaping WorkspaceSceneModel.KwtProjectRegistration = {
        projectPath, host in
        try await KwtProjectRegistryClient().register(
            projectPath: projectPath,
            on: host
        )
    },
    kwtProjectRemoval:
    @escaping WorkspaceSceneModel.KwtProjectRemoval = {
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
    tmuxSessionDiscovery: @escaping
    WorkspaceSceneModel.TmuxSessionDiscovery = { _ in .success([]) },
    tmuxSessionValidationDiscovery:
    WorkspaceSceneModel.TmuxSessionValidationDiscovery? = nil,
    herdrSessionDiscovery: @escaping
    WorkspaceSceneModel.HerdrSessionDiscovery = { _ in .unavailable },
    zellijSessionDiscovery: @escaping
    WorkspaceSceneModel.ZellijSessionDiscovery = { _ in .unavailable },
    zellijSessionValidationDiscovery:
    WorkspaceSceneModel.ZellijSessionValidationDiscovery? = nil,
    zellijSessionKiller: @escaping
    WorkspaceSceneModel.ZellijSessionKilling = { _, _, _ in .success(()) },
    zellijSSHConnectionSnapshotProvider:
    @escaping WorkspaceSceneModel.SSHConnectionSnapshotProvider = {
        _ in SSHConnectionArgumentsSnapshot(arguments: [])
    },
    presentationSSHConnectionProvider:
    (@MainActor @Sendable (UUID, SSHHostInfo) async throws
        -> KwtSSHConnection)? = { _, _ in
        testKwtSSHAttachment()
    },
    presentationSSHAcquisitionCoordinator:
    KwtSSHAcquisitionCoordinator = .shared,
    presentationSSHEnvironment: [String: String] = [:],
    herdrSessionValidationDiscovery:
    WorkspaceSceneModel.HerdrSessionValidationDiscovery? = nil,
    herdrSessionExactProbe:
    WorkspaceSceneModel.HerdrSessionExactProbe? = nil,
    tmuxExactSessionProbe: @escaping
    WorkspaceSceneModel.TmuxSessionExactProbe = { _ in .success(false) },
    tmuxSessionValidationExactProbe:
    WorkspaceSceneModel.TmuxSessionValidationExactProbe? = nil,
    tmuxSessionKiller: @escaping
    WorkspaceSceneModel.TmuxSessionKilling = {
        selection, identity, host in
        try await TmuxSessionKiller().kill(
            selection,
            expectedIdentity: identity,
            on: host
        )
    },
    tmuxSessionIdentityReader: @escaping
    WorkspaceSceneModel.TmuxSessionIdentityReading = { selection, host in
        try await TmuxSessionKiller().sessionIdentity(selection, on: host)
    },
    tmuxRoutedSessionIdentityReader: @escaping
    WorkspaceSceneModel.TmuxRoutedSessionIdentityReading = {
        selection, host, arguments in
        try await TmuxSessionKiller().sessionIdentity(
            selection,
            on: host,
            sshConnectionArguments: arguments
        )
    },
    tmuxSessionIdentityReviewer:
    WorkspaceSceneModel.TmuxSessionIdentityReviewReading? = nil,
    tmuxSessionStyler: @escaping
    WorkspaceSceneModel.TmuxSessionStyling = { style, selection, identity, host in
        try await TmuxSessionStyler().apply(
            style,
            to: selection,
            expectedIdentity: identity,
            on: host
        )
    },
    sshHostProbeRunner: @escaping
    WorkspaceSceneModel.SSHHostProbeRunner = { _, _, _ in
        (status: 255, stdout: "", stderr: "")
    },
    hostSSHConnectionProvider:
    WorkspaceSceneModel.HostSSHConnectionProvider? = { _, _ in
        testKwtSSHAttachment(arguments: ["-test-connection"])
    },
    hostSSHSessionProvider:
    @escaping WorkspaceSceneModel.HostSSHSessionProvider = {
        host, destination in
        let route = KwtSSHRouteSnapshot.fixture(
            logicalTarget: KwtSSHTarget(host),
            routeIdentity: "sha256:test-host-route-\(destination)"
        )
        return KwtSSHConnectionSession(
            route: route,
            host: host,
            destination: destination,
            pool: KwtSSHConnectionPool { route, _ in
                KwtSSHTestLease(routeIdentity: route.routeIdentity)
            }
        )
    },
    configuredSSHHostsProvider: @escaping () -> [SSHHost] = { [] },
    configuredSSHHostsPublisher: AnyPublisher<[SSHHost], Never> =
        Empty(completeImmediately: false).eraseToAnyPublisher(),
    configuredExeHostsProvider: @escaping () -> [ExeConfiguredHost] = { [] },
    configuredExeHostsPublisher: AnyPublisher<[ExeConfiguredHost], Never> =
        Empty(completeImmediately: false).eraseToAnyPublisher(),
    refreshExeHosts: @escaping () -> Void = {},
    startExeHostInventory: @escaping () -> Void = {},
    terminalColorsPublisher:
    AnyPublisher<[UInt: TerminalResolvedColors], Never>? = nil,
    sessionPreviewCoordinator: TmuxSessionPreviewCoordinator? = nil,
    sessionPreviewModePublisher:
    AnyPublisher<SessionPreviewMode, Never>? = nil,
    tmuxSessionActivityController:
    TmuxSessionActivityController? = nil,
    sceneSettings: WorkspaceSceneSettings = .live(),
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
) throws -> WorkspaceSceneModel {
    return try WorkspaceSceneModel(
        database: database,
        workspaceConfiguration: configuration,
        terminalRuntime: terminalRuntime,
        notificationService: notificationService,
        nativeTmuxSurfaceStore: nativeTmuxSurfaceStore,
        nativeHerdrSurfaceStore: nativeHerdrSurfaceStore,
        nativeZellijSurfaceStore: nativeZellijSurfaceStore,
        nativeTmuxPathProvider: nativeTmuxPathProvider,
        nativeHerdrPathProvider: nativeHerdrPathProvider,
        nativeZellijPathProvider: nativeZellijPathProvider,
        herdrPaneSplitCapabilityProvider: herdrPaneSplitCapabilityProvider,
        herdrPaneSplitter: herdrPaneSplitter,
        nativeTmuxPaneSplitter: nativeTmuxPaneSplitter,
        localKwtPathProvider: localKwtPathProvider,
        remoteTmuxPathProvider: remoteTmuxPathProvider,
        tmuxPresentationStyleProvider: tmuxPresentationStyleProvider,
        appliesTmuxPresentationStyleToExistingSessionsProvider:
        appliesTmuxPresentationStyleToExistingSessionsProvider,
        activeDisplayCount: activeDisplayCount,
        kwtInventoryLoader: kwtInventoryLoader,
        kwtConditionalInventoryLoader:
        kwtConditionalInventoryLoader ?? { host, _ in
            try await kwtInventoryLoader(host)
        },
        kwtRemoteProvisioner: kwtRemoteProvisioner,
        kwtRemoteInstaller: kwtRemoteInstaller,
        kwtWorktreeCreator: kwtWorktreeCreator,
        kwtWorktreeRemover: kwtWorktreeRemover,
        kwtForceWorktreeRemover: kwtForceWorktreeRemover,
        kwtWorktreeChangeReader: kwtWorktreeChangeReader,
        sshRouteIdentityResolver: sshRouteIdentityResolver,
        worktreeMutationCoordinator: worktreeMutationCoordinator,
        herdrLifecycleCoordinator: herdrLifecycleCoordinator,
        zellijSessionKillCoordinator: zellijSessionKillCoordinator,
        herdrSessionRecordReader: herdrSessionRecordReader,
        herdrSessionMutator: herdrSessionMutator,
        herdrSSHConnectionSnapshotProvider:
        herdrSSHConnectionSnapshotProvider,
        kwtBranchLister: kwtBranchLister,
        kwtPullRequestLister: kwtPullRequestLister,
        kwtPullRequestImporter: kwtPullRequestImporter,
        kwtProjectRegistration: kwtProjectRegistration,
        kwtProjectRemoval: kwtProjectRemoval,
        tmuxSessionDiscovery: tmuxSessionDiscovery,
        tmuxSessionValidationDiscovery: tmuxSessionValidationDiscovery,
        herdrSessionDiscovery: herdrSessionDiscovery,
        zellijSessionDiscovery: zellijSessionDiscovery,
        zellijSessionValidationDiscovery:
        zellijSessionValidationDiscovery ?? { host, _ in
            await zellijSessionDiscovery(host)
        },
        zellijSessionKiller: zellijSessionKiller,
        zellijSSHConnectionSnapshotProvider:
        zellijSSHConnectionSnapshotProvider,
        presentationSSHConnectionProvider:
        presentationSSHConnectionProvider,
        presentationSSHAcquisitionCoordinator:
        presentationSSHAcquisitionCoordinator,
        presentationSSHEnvironment: presentationSSHEnvironment,
        herdrSessionValidationDiscovery:
        herdrSessionValidationDiscovery ?? { host, _ in
            await herdrSessionDiscovery(host)
        },
        herdrSessionExactProbe: herdrSessionExactProbe ?? {
            name, host, _ in
            await HerdrSessionProbeOutcome.exact(
                name: name,
                discovery: herdrSessionDiscovery(host)
            )
        },
        tmuxExactSessionProbe: tmuxExactSessionProbe,
        tmuxSessionValidationExactProbe: tmuxSessionValidationExactProbe,
        tmuxSessionKiller: { selection, identity, _, host in
            try await tmuxSessionKiller(selection, identity, host)
        },
        tmuxSessionIdentityReader: tmuxSessionIdentityReader,
        tmuxRoutedSessionIdentityReader: tmuxRoutedSessionIdentityReader,
        tmuxSessionIdentityReviewer: tmuxSessionIdentityReviewer ?? {
            selection, knownIdentity, host in
            let identity: TmuxSessionIdentity
            if let knownIdentity {
                identity = knownIdentity
            } else {
                identity = try await tmuxSessionIdentityReader(
                    selection,
                    host
                )
            }
            return ReviewedTmuxSessionIdentity(
                identity: identity,
                routeIdentity: nil
            )
        },
        tmuxSessionStyler: tmuxSessionStyler,
        sshHostProbeRunner: sshHostProbeRunner,
        hostSSHConnectionProvider: hostSSHConnectionProvider,
        hostSSHSessionProvider: hostSSHSessionProvider,
        configuredSSHHostsProvider: configuredSSHHostsProvider,
        configuredSSHHostsPublisher: configuredSSHHostsPublisher,
        configuredExeHostsProvider: configuredExeHostsProvider,
        configuredExeHostsPublisher: configuredExeHostsPublisher,
        refreshExeHosts: refreshExeHosts,
        startExeHostInventory: startExeHostInventory,
        terminalColorsPublisher: terminalColorsPublisher,
        sessionPreviewCoordinator: sessionPreviewCoordinator,
        sessionPreviewModePublisher: sessionPreviewModePublisher,
        tmuxSessionActivityController: tmuxSessionActivityController,
        sceneSettings: sceneSettings,
        localHostID: localHostID,
        overrideSnapshot: snapshot,
        createdSessionDiscoveryDelays: createdSessionDiscoveryDelays,
        deferredTmuxPresentationRetryDelays:
        deferredTmuxPresentationRetryDelays,
        tmuxReconnectIntervals: tmuxReconnectIntervals,
        tmuxReconnectProbeDeadline: tmuxReconnectProbeDeadline,
        startServices: startServices
    )
}

// MARK: - Protocol Stubs

@MainActor
final class RecordingNativeSessionSurfaceStore: NativeSessionSurfaceStoring {
    let surface: RecordingNativeSessionPaneSurface
    private(set) var requestedKeys: [SurfaceKey] = []
    private(set) var requestedConfigurations: [TerminalSurfaceConfiguration] = []
    private(set) var removedKeys: [SurfaceKey] = []
    private var hasSurface = false

    var lastCommand: String? { requestedConfigurations.last?.command }

    init(
        launchError: Error? = nil,
        launchFailureIsRetryable: Bool = false,
        closeOnRegistrationCode: UInt32? = nil
    ) {
        surface = RecordingNativeSessionPaneSurface(
            launchError: launchError,
            launchFailureIsRetryable: launchFailureIsRetryable,
            closeOnRegistrationCode: closeOnRegistrationCode
        )
    }

    func paneSurface(
        for key: SurfaceKey,
        configuration: TerminalSurfaceConfiguration
    ) -> (any NativeSessionPaneSurfacing)? {
        requestedKeys.append(key)
        requestedConfigurations.append(configuration)
        hasSurface = true
        return surface
    }

    func paneSurfaceIfPresent(
        for _: SurfaceKey
    ) -> (any NativeSessionPaneSurfacing)? {
        hasSurface ? surface : nil
    }

    func removeSurface(for key: SurfaceKey) {
        removedKeys.append(key)
        hasSurface = false
    }
}

@MainActor
final class RecordingNativeSessionPaneSurface: NativeSessionPaneSurfacing {
    var blocksClipboardReads = false
    var remoteImagePasteHandler: ((TerminalClipboardImage) -> Void)?
    var terminalOperationErrorMessage: String?
    var terminalFindController = TerminalFindController.unavailable
    var hasEffectiveKeyboardFocus = false
    var paneSplitShortcutHandler: ((TerminalPaneSplitShortcut) -> Void)?
    /// Mutable so a test can fail one attach and let the next succeed, which is
    /// how a transient surface failure behaves in practice.
    var launchError: Error?
    var launchFailureIsRetryable: Bool
    private var closeOnRegistrationCode: UInt32?
    var childExitCode: UInt32?
    private(set) var closeObservers: [UUID: (Bool, UInt32?) -> Void] = [:]
    private(set) var previewGridSizes: [TmuxGridSize] = []
    private(set) var clearPreviewGridCount = 0
    var onPreviewGridSize: ((TmuxGridSize) -> Void)?
    var onClearPreviewGrid: (() -> Void)?
    private(set) var programmaticPastes: [String] = []

    init(
        launchError: Error? = nil,
        launchFailureIsRetryable: Bool = false,
        closeOnRegistrationCode: UInt32? = nil
    ) {
        self.launchError = launchError
        self.launchFailureIsRetryable = launchFailureIsRetryable
        self.closeOnRegistrationCode = closeOnRegistrationCode
    }

    @discardableResult
    func sizeForPreviewGrid(columns: Int, rows: Int) -> Bool {
        let gridSize = TmuxGridSize(columns: columns, rows: rows)
        previewGridSizes.append(gridSize)
        onPreviewGridSize?(gridSize)
        return true
    }

    func clearPreviewGridSize() {
        clearPreviewGridCount += 1
        onClearPreviewGrid?()
    }

    @discardableResult
    func pasteProgrammaticInput(_ string: String) -> Bool {
        programmaticPastes.append(string)
        return true
    }

    func registerSurfaceCloseObserver(
        id: UUID,
        onSurfaceClosed: @escaping (Bool, UInt32?) -> Void
    ) {
        closeObservers[id] = onSurfaceClosed
        guard let code = closeOnRegistrationCode else { return }
        closeOnRegistrationCode = nil
        Task { @MainActor in
            onSurfaceClosed(false, code)
        }
    }
}

final class NotificationServiceStub: NotificationService {
    struct IdleNotification: Equatable {
        let worktreeName: String
        let projectName: String
    }

    var idleNotifications: [IdleNotification] = []
    var agentAttentionNotifications: [IdleNotification] = []
    var dockBadgeCounts: [Int] = []

    func requestAuthorization() async {}
    func postAgentFinished(worktreeName: String, projectName: String) {}
    func postWorktreeBecameIdle(worktreeName: String, projectName: String) {
        idleNotifications.append(
            IdleNotification(
                worktreeName: worktreeName,
                projectName: projectName
            )
        )
    }
    func postAgentsNeedAttention(worktreeName: String, projectName: String) {
        agentAttentionNotifications.append(
            IdleNotification(
                worktreeName: worktreeName,
                projectName: projectName
            )
        )
    }
    func updateDockBadge(unseenCount: Int) {
        dockBadgeCounts.append(unseenCount)
    }
    func playCompletionSound() {}
}

// MARK: - XCTest Polling Helpers

extension XCTestCase {
    @MainActor
    func waitUntil(
        timeout: TimeInterval = 5.0,
        file: StaticString = #filePath,
        line: UInt = #line,
        condition: @escaping () -> Bool
    ) {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() {
                return
            }
            RunLoop.main.run(until: Date().addingTimeInterval(0.01))
        }
        XCTFail("Timed out waiting for condition", file: file, line: line)
    }

    @MainActor
    func waitUntilAsync(
        timeout: TimeInterval = 5.0,
        file: StaticString = #filePath,
        line: UInt = #line,
        condition: @escaping @Sendable () async -> Bool
    ) async {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if await condition() {
                return
            }
            try? await Task.sleep(for: .milliseconds(20))
        }
        XCTFail(
            "Timed out waiting for async condition",
            file: file, line: line
        )
    }
}

// MARK: - View Hosting Helpers

@MainActor
func hostView(
    rootView: AnyView,
    size: CGSize = CGSize(width: 960, height: 640)
) -> NSHostingView<AnyView> {
    let hostingView = NSHostingView(rootView: rootView)
    hostingView.frame = NSRect(origin: .zero, size: size)
    hostingView.layoutSubtreeIfNeeded()
    RunLoop.main.run(until: Date().addingTimeInterval(0.2))
    return hostingView
}

@MainActor
func hostWindow(
    rootView: AnyView,
    size: CGSize = CGSize(width: 960, height: 640)
) -> NSWindow {
    let hostingView = hostView(rootView: rootView, size: size)
    let window = NSWindow(
        contentRect: NSRect(origin: .zero, size: size),
        styleMask: [.titled, .closable, .resizable],
        backing: .buffered,
        defer: false
    )
    window.contentView = hostingView
    window.makeKeyAndOrderFront(nil)
    window.displayIfNeeded()
    RunLoop.main.run(until: Date().addingTimeInterval(0.2))
    return window
}

// MARK: - View Hierarchy Traversal

@MainActor
func descendants(
    of view: NSView
) -> [NSView] {
    [view] + view.subviews.flatMap(descendants(of:))
}

@MainActor
func buttons(
    in view: NSView
) -> [NSButton] {
    descendants(of: view).compactMap { $0 as? NSButton }
}

@MainActor
func button(
    accessibilityIdentifier identifier: String,
    in view: NSView
) -> NSButton? {
    if let button = buttons(in: view)
        .first(where: { $0.accessibilityIdentifier() == identifier }) {
        return button
    }
    guard let identifiedView = descendants(of: view).first(
        where: { $0.accessibilityIdentifier() == identifier }
    ) else {
        return nil
    }
    if let button = identifiedView as? NSButton {
        return button
    }
    return descendants(of: identifiedView).compactMap { $0 as? NSButton }.first
}
