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
    public let activeTmuxSession: WorkspaceTmuxSessionSelection?

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
        activeTmuxSession: WorkspaceTmuxSessionSelection? = nil
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
        self.activeTmuxSession = activeTmuxSession
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
public struct InteractionHandlers {
    public let closeWindow: (() -> Void)?
    public let dismissLogViewer: (() -> Void)?
    public let openTmuxSession: ((WorkspaceTmuxSessionSelection) -> Void)?
    public let closeTmuxSession: ((WorkspaceTmuxSessionSelection) -> Void)?
    public let createTmuxSession: ((WorkspaceTmuxSessionSelection) -> Void)?
    public let refreshWorkspaceInventory: (() -> Void)?
    public let createWorktree:
        ((WorktreeCreateRequest) async throws -> Void)?

    public init(
        closeWindow: (() -> Void)? = nil,
        dismissLogViewer: (() -> Void)? = nil,
        openTmuxSession: ((WorkspaceTmuxSessionSelection) -> Void)? = nil,
        closeTmuxSession: ((WorkspaceTmuxSessionSelection) -> Void)? = nil,
        createTmuxSession: ((WorkspaceTmuxSessionSelection) -> Void)? = nil,
        refreshWorkspaceInventory: (() -> Void)? = nil,
        createWorktree:
            ((WorktreeCreateRequest) async throws -> Void)? = nil
    ) {
        self.closeWindow = closeWindow
        self.dismissLogViewer = dismissLogViewer
        self.openTmuxSession = openTmuxSession
        self.closeTmuxSession = closeTmuxSession
        self.createTmuxSession = createTmuxSession
        self.refreshWorkspaceInventory = refreshWorkspaceInventory
        self.createWorktree = createWorktree
    }
}
