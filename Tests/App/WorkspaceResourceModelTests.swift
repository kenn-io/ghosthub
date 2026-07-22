import Foundation
import GhosthubTestSupport
import Testing
import GhosthubWorkspace
@testable import GhosthubApp

struct WorkspaceResourceModelTests {
    @Test("resource summary attributes process resources by worktree path prefix")
    func summaryAttributesProcessResourcesByWorktreePathPrefix() {
        var builder = ResourceTestBuilder()
        let main = builder.addWorktree(
            name: "primary checkout",
            path: "/Users/wesm/code/ghosthub",
            branch: "main",
            isPrimary: true
        )
        let feature = builder.addWorktree(
            name: "resource",
            path: "/Users/wesm/code/ghosthub-resource",
            branch: "feature/resource"
        )

        let summary = builder.makeSummary(
            aggregate: .fixture(
                cpuPercent: 8.5,
                residentMB: 700,
                processCount: 4
            ),
            processes: [
                .fixture(
                    workingDirectory: "/Users/wesm/code/ghosthub",
                    cpuPercent: 1.5,
                    residentMB: 220
                ),
                .fixture(
                    workingDirectory: "/Users/wesm/code/ghosthub-resource",
                    cpuPercent: 2.0,
                    residentMB: 180
                ),
                .fixture(
                    workingDirectory: "/Users/wesm/code/ghosthub-resource/subdir",
                    cpuPercent: 1.0,
                    residentMB: 40
                ),
            ]
        )

        #expect(summary.worktreeSamples[main.id]?.residentMB == 220)
        #expect(summary.worktreeSamples[feature.id]?.residentMB == 220)
        #expect(summary.analytics.visibleWorktreeResidentMB == 440)
        #expect(summary.analytics.unattributedResidentMB == 260)
    }

    @Test("resource summary ignores processes outside visible host worktrees")
    func summaryIgnoresProcessesOutsideVisibleHostWorktrees() {
        let localHost = HostSummary.fixture(
            name: "This Mac", kind: .selfHost, platform: .macOS
        )
        let remoteHost = HostSummary.fixture(
            name: "Remote", kind: .remote, platform: .linux
        )
        let localProject = ProjectSummary.fixture(
            hostID: localHost.id, name: "ghosthub",
            rootPath: "/Users/wesm/code/ghosthub"
        )
        let remoteProject = ProjectSummary.fixture(
            hostID: remoteHost.id, name: "api",
            rootPath: "/srv/api"
        )
        let localWorktree = WorktreeSummary.fixture(
            hostID: localHost.id,
            projectID: localProject.id,
            name: "main",
            path: "/Users/wesm/code/ghosthub",
            branch: "main"
        )
        let remoteWorktree = WorktreeSummary.fixture(
            hostID: remoteHost.id,
            projectID: remoteProject.id,
            name: "release",
            path: "/srv/api-release",
            branch: "release"
        )

        let summary = buildSummary(
            hosts: [localHost, remoteHost],
            projects: [localProject, remoteProject],
            worktrees: [localWorktree, remoteWorktree],
            selectedHostID: remoteHost.id,
            aggregate: .fixture(
                cpuPercent: 3.0,
                residentMB: 300,
                processCount: 2
            ),
            processes: [
                .fixture(
                    workingDirectory: "/Users/wesm/code/ghosthub",
                    cpuPercent: 1.0,
                    residentMB: 150
                ),
            ],
            refreshIntervalSeconds: 15
        )

        #expect(summary.worktreeSamples.isEmpty)
        #expect(summary.analytics.visibleWorktreeResidentMB == 0)
        #expect(summary.analytics.unattributedResidentMB == 300)
    }

    @Test("resource summary attributes processes by worktree id")
    func summaryAttributesProcessesByWorktreeID() {
        var builder = ResourceTestBuilder()
        let worktreeA = builder.addWorktree(
            name: "feature-a",
            path: "/Users/wesm/code/ghosthub-a",
            branch: "feature/a"
        )
        let worktreeB = builder.addWorktree(
            name: "feature-b",
            path: "/Users/wesm/code/ghosthub-b",
            branch: "feature/b"
        )

        let summary = builder.makeSummary(
            aggregate: .fixture(
                cpuPercent: 10.0,
                residentMB: 500,
                processCount: 3
            ),
            processes: [
                .fixture(
                    worktreeID: worktreeA.id,
                    cpuPercent: 3.0,
                    residentMB: 150
                ),
                .fixture(
                    worktreeID: worktreeB.id,
                    cpuPercent: 2.0,
                    residentMB: 100
                ),
                .fixture(
                    worktreeID: worktreeA.id,
                    cpuPercent: 1.0,
                    residentMB: 50
                ),
            ]
        )

        #expect(summary.worktreeSamples[worktreeA.id]?.residentMB == 200)
        #expect(summary.worktreeSamples[worktreeA.id]?.cpuPercent == 4.0)
        #expect(summary.worktreeSamples[worktreeA.id]?.processCount == 2)
        #expect(summary.worktreeSamples[worktreeB.id]?.residentMB == 100)
        #expect(summary.analytics.visibleWorktreeResidentMB == 300)
        #expect(summary.analytics.unattributedResidentMB == 200)
    }

    @Test("worktreeID takes priority over working directory")
    func worktreeIDTakesPriorityOverWorkingDirectory() {
        var builder = ResourceTestBuilder()
        let worktreeA = builder.addWorktree(
            name: "feature-a",
            path: "/Users/wesm/code/ghosthub-a",
            branch: "feature/a"
        )
        let worktreeB = builder.addWorktree(
            name: "feature-b",
            path: "/Users/wesm/code/ghosthub-b",
            branch: "feature/b"
        )

        let summary = builder.makeSummary(
            aggregate: .fixture(
                cpuPercent: 5.0,
                residentMB: 200,
                processCount: 1
            ),
            processes: [
                .fixture(
                    worktreeID: worktreeA.id,
                    workingDirectory: "/Users/wesm/code/ghosthub-b",
                    cpuPercent: 5.0,
                    residentMB: 200
                ),
            ]
        )

        #expect(summary.worktreeSamples[worktreeA.id]?.residentMB == 200)
        #expect(summary.worktreeSamples[worktreeB.id] == nil)
    }

    @Test("processes with unknown worktree ids are not attributed")
    func processWithUnknownWorktreeIDIsNotAttributed() {
        var builder = ResourceTestBuilder()
        _ = builder.addWorktree(
            name: "main",
            path: "/Users/wesm/code/ghosthub",
            branch: "main"
        )
        let unknownWorktreeID = UUID()

        let summary = builder.makeSummary(
            aggregate: .fixture(
                cpuPercent: 3.0,
                residentMB: 100,
                processCount: 1
            ),
            processes: [
                .fixture(
                    worktreeID: unknownWorktreeID,
                    cpuPercent: 3.0,
                    residentMB: 100
                ),
            ]
        )

        #expect(summary.worktreeSamples.isEmpty)
        #expect(summary.analytics.unattributedResidentMB == 100)
    }

    @Test("processes without a worktree id or matching path stay unattributed")
    func processWithNullWorktreeIDAndNullPathIsUnattributed() {
        var builder = ResourceTestBuilder()
        _ = builder.addWorktree(
            name: "main",
            path: "/Users/wesm/code/ghosthub",
            branch: "main"
        )

        let summary = builder.makeSummary(
            aggregate: .fixture(
                cpuPercent: 5.0,
                residentMB: 300,
                processCount: 2
            ),
            processes: [
                .fixture(cpuPercent: 3.0, residentMB: 200),
                .fixture(
                    workingDirectory: "/usr/local/bin",
                    cpuPercent: 2.0,
                    residentMB: 100
                ),
            ]
        )

        #expect(summary.worktreeSamples.isEmpty)
        #expect(summary.analytics.unattributedResidentMB == 300)
    }

    @Test("analytics top entries are sorted by memory then CPU")
    func analyticsTopEntriesSortedByMemoryThenCPU() {
        var builder = ResourceTestBuilder(rootPath: "/tmp/gh")
        let wtHigh = builder.addWorktree(
            name: "high-mem",
            path: "/tmp/gh-high",
            branch: "high-mem"
        )
        let wtLow = builder.addWorktree(
            name: "low-mem",
            path: "/tmp/gh-low",
            branch: "low-mem"
        )
        let wtSameMem = builder.addWorktree(
            name: "same-mem-high-cpu",
            path: "/tmp/gh-same",
            branch: "same-mem"
        )

        let summary = builder.makeSummary(
            aggregate: .fixture(
                cpuPercent: 20.0,
                residentMB: 1000,
                processCount: 3
            ),
            processes: [
                .fixture(
                    worktreeID: wtHigh.id,
                    cpuPercent: 2.0,
                    residentMB: 400
                ),
                .fixture(
                    worktreeID: wtLow.id,
                    cpuPercent: 8.0,
                    residentMB: 100
                ),
                .fixture(
                    worktreeID: wtSameMem.id,
                    cpuPercent: 10.0,
                    residentMB: 100
                ),
            ]
        )

        let entries = summary.analytics.topEntries
        #expect(entries.count == 3)
        #expect(entries[0].branch == "high-mem")
        #expect(entries[0].residentMB == 400)
        #expect(entries[1].branch == "same-mem")
        #expect(entries[1].cpuPercent == 10.0)
        #expect(entries[2].branch == "low-mem")
    }

    @Test("host resource patch targets self host aggregate")
    func hostResourcePatchTargetsSelfHostAggregate() throws {
        let selfHost = HostSummary.fixture(
            configKey: "local",
            name: "This Mac",
            kind: .selfHost
        )
        let remoteHost = HostSummary.fixture(
            configKey: "build-box",
            name: "Build Box",
            kind: .remote,
            platform: .linux
        )
        let summary = WorkspaceResourceSummary(
            aggregate: .fixture(
                cpuPercent: 4.25,
                residentMB: 318,
                processCount: 3
            ),
            worktreeSamples: [:],
            analytics: WorkspaceResourceSummary.empty.analytics
        )

        let patch = try #require(
            WorkspaceResourceModel.hostResourcePatch(
                snapshot: WorkspaceSnapshot(
                    hosts: [remoteHost, selfHost],
                    projects: [],
                    worktrees: []
                ),
                summary: summary
            )
        )

        #expect(
            patch == WorkspaceHostResourcePatch(
                hostKey: "local",
                cpuPercent: 4.25,
                residentMB: 318
            )
        )
    }

    @Test("host resource patch requires aggregate and self host")
    func hostResourcePatchRequiresAggregateAndSelfHost() {
        let remoteHost = HostSummary.fixture(
            configKey: "build-box",
            name: "Build Box",
            kind: .remote,
            platform: .linux
        )
        let summary = WorkspaceResourceSummary(
            aggregate: .fixture(
                cpuPercent: 2.0,
                residentMB: 128,
                processCount: 1
            ),
            worktreeSamples: [:],
            analytics: WorkspaceResourceSummary.empty.analytics
        )

        #expect(
            WorkspaceResourceModel.hostResourcePatch(
                snapshot: WorkspaceSnapshot(
                    hosts: [remoteHost],
                    projects: [],
                    worktrees: []
                ),
                summary: summary
            ) == nil
        )
        #expect(
            WorkspaceResourceModel.hostResourcePatch(
                snapshot: WorkspaceSnapshot(
                    hosts: [
                        HostSummary.fixture(
                            configKey: "local",
                            kind: .selfHost
                        ),
                    ],
                    projects: [],
                    worktrees: []
                ),
                summary: .empty
            ) == nil
        )
    }

}

// MARK: - Resource Test Builder

private struct ResourceTestBuilder {
    let host: HostSummary
    let project: ProjectSummary
    var worktrees: [WorktreeSummary] = []

    init(rootPath: String = "/Users/wesm/code/ghosthub") {
        host = .fixture(
            name: "This Mac", kind: .selfHost, platform: .macOS
        )
        project = .fixture(
            hostID: host.id, name: "ghosthub",
            rootPath: rootPath
        )
    }

    @discardableResult
    mutating func addWorktree(
        name: String,
        path: String,
        branch: String,
        isPrimary: Bool = false
    ) -> WorktreeSummary {
        let wt = WorktreeSummary.fixture(
            hostID: host.id,
            projectID: project.id,
            name: name,
            path: path,
            branch: branch,
            isPrimary: isPrimary
        )
        worktrees.append(wt)
        return wt
    }

    func makeSummary(
        aggregate: WorkspaceResourceSample? = nil,
        processes: [WorkspaceProcessResource] = []
    ) -> WorkspaceResourceSummary {
        buildSummary(
            hosts: [host],
            projects: [project],
            worktrees: worktrees,
            selectedHostID: host.id,
            aggregate: aggregate,
            processes: processes
        )
    }
}

// MARK: - Summary Factory

private func buildSummary(
    hosts: [HostSummary],
    projects: [ProjectSummary],
    worktrees: [WorktreeSummary],
    selectedHostID: UUID,
    aggregate: WorkspaceResourceSample?,
    processes: [WorkspaceProcessResource],
    lastUpdatedAt: Date? = nil,
    refreshIntervalSeconds: Int = 5
) -> WorkspaceResourceSummary {
    WorkspaceResourceModel.summary(
        snapshot: WorkspaceSnapshot(
            hosts: hosts,
            projects: projects,
            worktrees: worktrees
        ),
        selectedHostID: selectedHostID,
        aggregate: aggregate,
        processes: processes,
        lastUpdatedAt: lastUpdatedAt,
        refreshIntervalSeconds: refreshIntervalSeconds
    )
}

extension WorkspaceProcessResource {
    fileprivate static func fixture(
        worktreeID: UUID? = nil,
        leafID: UUID? = nil,
        workingDirectory: String? = nil,
        cpuPercent: Double = 0.0,
        residentMB: Int = 0,
        processCount: Int = 1
    ) -> Self {
        WorkspaceProcessResource(
            worktreeID: worktreeID,
            leafID: leafID,
            workingDirectory: workingDirectory,
            sample: WorkspaceResourceSample(
                cpuPercent: cpuPercent,
                residentMB: residentMB,
                processCount: processCount
            )
        )
    }
}

extension WorkspaceResourceSample {
    fileprivate static func fixture(
        cpuPercent: Double = 0.0,
        residentMB: Int = 0,
        processCount: Int = 1
    ) -> Self {
        WorkspaceResourceSample(
            cpuPercent: cpuPercent,
            residentMB: residentMB,
            processCount: processCount
        )
    }
}
