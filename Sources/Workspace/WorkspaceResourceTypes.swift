import Foundation

public struct WorkspaceResourceSample: Equatable, Sendable {
    public var cpuPercent: Double
    public var residentMB: Int
    public var processCount: Int

    public init(
        cpuPercent: Double,
        residentMB: Int,
        processCount: Int
    ) {
        self.cpuPercent = cpuPercent
        self.residentMB = residentMB
        self.processCount = processCount
    }
}

public struct WorkspaceProcessResource: Equatable, Sendable {
    public var worktreeID: UUID?
    public var leafID: UUID?
    public var workingDirectory: String?
    public var executableName: String?
    public var recognizedAgent: WorkspaceKnownAgent?
    public var sample: WorkspaceResourceSample

    public init(
        worktreeID: UUID? = nil,
        leafID: UUID? = nil,
        workingDirectory: String? = nil,
        executableName: String? = nil,
        recognizedAgent: WorkspaceKnownAgent? = nil,
        sample: WorkspaceResourceSample
    ) {
        self.worktreeID = worktreeID
        self.leafID = leafID
        self.workingDirectory = workingDirectory
        self.executableName = executableName
        self.recognizedAgent = recognizedAgent
        self.sample = sample
    }
}

public struct WorkspaceMemoryAnalyticsEntry: Equatable, Sendable, Identifiable {
    public var worktreeID: UUID
    public var branch: String
    public var residentMB: Int
    public var cpuPercent: Double

    public var id: UUID {
        worktreeID
    }

    public init(
        worktreeID: UUID,
        branch: String,
        residentMB: Int,
        cpuPercent: Double
    ) {
        self.worktreeID = worktreeID
        self.branch = branch
        self.residentMB = residentMB
        self.cpuPercent = cpuPercent
    }
}

public struct WorkspaceMemoryAnalytics: Equatable, Sendable {
    public var visibleWorktreeResidentMB: Int
    public var unattributedResidentMB: Int
    public var totalTrackedProcesses: Int
    public var topEntries: [WorkspaceMemoryAnalyticsEntry]
    public var lastUpdatedAt: Date?
    public var refreshIntervalSeconds: Int

    public init(
        visibleWorktreeResidentMB: Int,
        unattributedResidentMB: Int,
        totalTrackedProcesses: Int,
        topEntries: [WorkspaceMemoryAnalyticsEntry],
        lastUpdatedAt: Date?,
        refreshIntervalSeconds: Int
    ) {
        self.visibleWorktreeResidentMB = visibleWorktreeResidentMB
        self.unattributedResidentMB = unattributedResidentMB
        self.totalTrackedProcesses = totalTrackedProcesses
        self.topEntries = topEntries
        self.lastUpdatedAt = lastUpdatedAt
        self.refreshIntervalSeconds = refreshIntervalSeconds
    }
}

public struct WorkspaceResourceSummary: Equatable, Sendable {
    public var aggregate: WorkspaceResourceSample?
    public var worktreeSamples: [UUID: WorkspaceResourceSample]
    public var analytics: WorkspaceMemoryAnalytics

    public init(
        aggregate: WorkspaceResourceSample?,
        worktreeSamples: [UUID: WorkspaceResourceSample],
        analytics: WorkspaceMemoryAnalytics
    ) {
        self.aggregate = aggregate
        self.worktreeSamples = worktreeSamples
        self.analytics = analytics
    }

    public static let empty = WorkspaceResourceSummary(
        aggregate: nil,
        worktreeSamples: [:],
        analytics: WorkspaceMemoryAnalytics(
            visibleWorktreeResidentMB: 0,
            unattributedResidentMB: 0,
            totalTrackedProcesses: 0,
            topEntries: [],
            lastUpdatedAt: nil,
            refreshIntervalSeconds: 0
        )
    )
}
