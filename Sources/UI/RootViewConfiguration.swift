import Foundation
import GhosthubSettings
import GhosthubWorkspace
import SwiftUI

/// Snapshot data and display flags consumed by RootView.
public struct WorkspaceDisplayState {
    public let snapshot: WorkspaceSnapshot
    public let workspaceResourceSummary: WorkspaceResourceSummary
    public let activatedWorktreeIDs: Set<UUID>
    public let activeAgentWorktreeIDs: Set<UUID>
    public let activeProcessWorktreeIDs: Set<UUID>
    public let paneResourceSamples: [UUID: WorkspaceResourceSample]
    public let paneAgentActivities: [UUID: PaneAgentActivity]
    public let activityReferenceDate: Date
    public let idleThresholdsBySessionID: [UUID: Int]
    public let defaultIdleThresholdSeconds: Int
    public let isWorkspaceInventoryLoading: Bool
    public let workspaceInventoryError: String?
    public let workspaceInventoryWarning: String?
    public let workspaceInventoryWarningsByHost: [UUID: String]
    public let isWorkspaceRestorationPending: Bool
    public let suppressesAutomaticWorktreeSessionOpen: Bool
    public let activeTmuxSession: WorkspaceTmuxSessionSelection?
    public let activeTmuxSessionIsConnected: Bool
    public let activeTmuxSessionCanApplyTheme: Bool

    public init(
        snapshot: WorkspaceSnapshot,
        workspaceResourceSummary: WorkspaceResourceSummary = .empty,
        activatedWorktreeIDs: Set<UUID> = [],
        activeAgentWorktreeIDs: Set<UUID> = [],
        activeProcessWorktreeIDs: Set<UUID> = [],
        paneResourceSamples: [UUID: WorkspaceResourceSample] = [:],
        paneAgentActivities: [UUID: PaneAgentActivity] = [:],
        activityReferenceDate: Date = .now,
        idleThresholdsBySessionID: [UUID: Int] = [:],
        defaultIdleThresholdSeconds: Int = 300,
        isWorkspaceInventoryLoading: Bool = false,
        workspaceInventoryError: String? = nil,
        workspaceInventoryWarning: String? = nil,
        workspaceInventoryWarningsByHost: [UUID: String] = [:],
        isWorkspaceRestorationPending: Bool = false,
        suppressesAutomaticWorktreeSessionOpen: Bool = false,
        activeTmuxSession: WorkspaceTmuxSessionSelection? = nil,
        activeTmuxSessionIsConnected: Bool = false,
        activeTmuxSessionCanApplyTheme: Bool = false
    ) {
        self.snapshot = snapshot
        self.workspaceResourceSummary = workspaceResourceSummary
        self.activatedWorktreeIDs = activatedWorktreeIDs
        self.activeAgentWorktreeIDs = activeAgentWorktreeIDs
        self.activeProcessWorktreeIDs = activeProcessWorktreeIDs
        self.paneResourceSamples = paneResourceSamples
        self.paneAgentActivities = paneAgentActivities
        self.activityReferenceDate = activityReferenceDate
        self.idleThresholdsBySessionID = idleThresholdsBySessionID
        self.defaultIdleThresholdSeconds = defaultIdleThresholdSeconds
        self.isWorkspaceInventoryLoading = isWorkspaceInventoryLoading
        self.workspaceInventoryError = workspaceInventoryError
        self.workspaceInventoryWarning = workspaceInventoryWarning
        self.workspaceInventoryWarningsByHost =
            workspaceInventoryWarningsByHost
        self.isWorkspaceRestorationPending =
            isWorkspaceRestorationPending
        self.suppressesAutomaticWorktreeSessionOpen =
            suppressesAutomaticWorktreeSessionOpen
        self.activeTmuxSession = activeTmuxSession
        self.activeTmuxSessionIsConnected =
            activeTmuxSessionIsConnected
        self.activeTmuxSessionCanApplyTheme =
            activeTmuxSessionCanApplyTheme
    }
}

/// View factory closures and providers consumed by RootView.
public struct ContentBuilders {
    public let tmuxSessionContentBuilder:
        ((HostSummary, String) -> AnyView?)?
    public let settingsSheetBuilder: ((SettingsStore) -> AnyView)?
    public let logViewerBuilder: (() -> AnyView?)?

    public init(
        tmuxSessionContentBuilder:
        ((HostSummary, String) -> AnyView?)? = nil,
        settingsSheetBuilder: ((SettingsStore) -> AnyView)? = nil,
        logViewerBuilder: (() -> AnyView?)? = nil
    ) {
        self.tmuxSessionContentBuilder = tmuxSessionContentBuilder
        self.settingsSheetBuilder = settingsSheetBuilder
        self.logViewerBuilder = logViewerBuilder
    }
}

/// Action callbacks consumed by RootView.
public struct TmuxSessionKillRequest: Equatable, Sendable {
    public let session: WorkspaceTmuxSessionSelection
    public let confirmedHost: HostSummary
    public let serverPID: String
    public let sessionID: String
    public let sessionCreatedAt: String

    public init(
        session: WorkspaceTmuxSessionSelection,
        confirmedHost: HostSummary,
        serverPID: String,
        sessionID: String,
        sessionCreatedAt: String
    ) {
        self.session = session
        self.confirmedHost = confirmedHost
        self.serverPID = serverPID
        self.sessionID = sessionID
        self.sessionCreatedAt = sessionCreatedAt
    }
}

public struct WorktreeRemovalRequest: Equatable, Sendable {
    public let worktree: WorktreeSummary
    public let project: ProjectSummary
    public let confirmedHost: HostSummary
    public let sessionKillRequest: TmuxSessionKillRequest?

    public init(
        worktree: WorktreeSummary,
        project: ProjectSummary,
        confirmedHost: HostSummary,
        sessionKillRequest: TmuxSessionKillRequest? = nil
    ) {
        self.worktree = worktree
        self.project = project
        self.confirmedHost = confirmedHost
        self.sessionKillRequest = sessionKillRequest
    }
}

public struct InteractionHandlers {
    public let closeWindow: (() -> Void)?
    public let dismissLogViewer: (() -> Void)?
    public let reloadTerminalConfig: (() -> Void)?
    public let selectWorkspace: ((WorkspaceSelection) -> Void)?
    public let openTmuxSession: ((WorkspaceTmuxSessionSelection) -> Void)?
    public let closeTmuxSession: ((WorkspaceTmuxSessionSelection) -> Void)?
    public let prepareTmuxSessionKill:
        ((WorkspaceTmuxSessionSelection) async throws
            -> TmuxSessionKillRequest)?
    public let killTmuxSession:
        ((TmuxSessionKillRequest) async throws -> Void)?
    public let applyTmuxSessionTheme:
        ((WorkspaceTmuxSessionSelection) async throws -> Void)?
    public let createTmuxSession: ((WorkspaceTmuxSessionSelection) -> Void)?
    public let refreshWorkspaceInventory: (() -> Void)?
    public let reviewSSHHostKey:
        ((UUID) async -> Result<SSHHostKeyConfirmation?, HostProbeError>)?
    public let trustSSHHostKey:
        ((UUID, SSHHostKeyConfirmation) async -> Result<
            SSHHostKeyConfirmation?, HostProbeError
        >)?
    public let registerProject:
        ((HostSummary, String) async -> Result<String, HostProbeError>)?
    public let createWorktree:
        ((WorktreeCreateRequest) async throws -> Void)?
    public let listBranches:
        ((UUID) async throws -> [WorktreeBranchCandidate])?
    public let listPullRequests:
        ((UUID) async throws -> [PullRequestCandidate])?
    public let importPullRequest:
        ((PullRequestImportRequest) async throws -> Void)?
    public let prepareWorktreeRemoval:
        ((UUID) async throws -> WorktreeRemovalRequest)?
    public let removeWorktree:
        ((WorktreeRemovalRequest) async throws -> Void)?

    public init(
        closeWindow: (() -> Void)? = nil,
        dismissLogViewer: (() -> Void)? = nil,
        reloadTerminalConfig: (() -> Void)? = nil,
        selectWorkspace: ((WorkspaceSelection) -> Void)? = nil,
        openTmuxSession: ((WorkspaceTmuxSessionSelection) -> Void)? = nil,
        closeTmuxSession: ((WorkspaceTmuxSessionSelection) -> Void)? = nil,
        prepareTmuxSessionKill:
        ((WorkspaceTmuxSessionSelection) async throws
            -> TmuxSessionKillRequest)? = nil,
        killTmuxSession:
        ((TmuxSessionKillRequest) async throws -> Void)? = nil,
        applyTmuxSessionTheme:
        ((WorkspaceTmuxSessionSelection) async throws -> Void)? = nil,
        createTmuxSession: ((WorkspaceTmuxSessionSelection) -> Void)? = nil,
        refreshWorkspaceInventory: (() -> Void)? = nil,
        reviewSSHHostKey:
        ((UUID) async -> Result<SSHHostKeyConfirmation?, HostProbeError>)? = nil,
        trustSSHHostKey:
        ((UUID, SSHHostKeyConfirmation) async -> Result<
            SSHHostKeyConfirmation?, HostProbeError
        >)? = nil,
        registerProject:
        ((HostSummary, String) async -> Result<String, HostProbeError>)? = nil,
        createWorktree:
        ((WorktreeCreateRequest) async throws -> Void)? = nil,
        listBranches:
        ((UUID) async throws -> [WorktreeBranchCandidate])? = nil,
        listPullRequests:
        ((UUID) async throws -> [PullRequestCandidate])? = nil,
        importPullRequest:
        ((PullRequestImportRequest) async throws -> Void)? = nil,
        prepareWorktreeRemoval:
        ((UUID) async throws -> WorktreeRemovalRequest)? = nil,
        removeWorktree:
        ((WorktreeRemovalRequest) async throws -> Void)? = nil
    ) {
        self.closeWindow = closeWindow
        self.dismissLogViewer = dismissLogViewer
        self.reloadTerminalConfig = reloadTerminalConfig
        self.selectWorkspace = selectWorkspace
        self.openTmuxSession = openTmuxSession
        self.closeTmuxSession = closeTmuxSession
        self.prepareTmuxSessionKill = prepareTmuxSessionKill
        self.killTmuxSession = killTmuxSession
        self.applyTmuxSessionTheme = applyTmuxSessionTheme
        self.createTmuxSession = createTmuxSession
        self.refreshWorkspaceInventory = refreshWorkspaceInventory
        self.reviewSSHHostKey = reviewSSHHostKey
        self.trustSSHHostKey = trustSSHHostKey
        self.registerProject = registerProject
        self.createWorktree = createWorktree
        self.listBranches = listBranches
        self.listPullRequests = listPullRequests
        self.importPullRequest = importPullRequest
        self.prepareWorktreeRemoval = prepareWorktreeRemoval
        self.removeWorktree = removeWorktree
    }
}
