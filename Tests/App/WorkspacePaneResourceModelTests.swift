import Foundation
import GhosthubWorkspace
import Testing
@testable import GhosthubApp

struct WorkspacePaneResourceModelTests {
    @Test("samples aggregate processes per leaf for the selected worktree")
    func samplesAggregateProcessesPerLeafForSelectedWorktree() {
        let worktreeID = UUID()
        let otherWorktreeID = UUID()
        let leafA = UUID()
        let leafB = UUID()

        let samples = WorkspacePaneResourceModel.testSamples(
            selectedWorktreeID: worktreeID,
            processes:
            .fixtures(forWorktree: worktreeID, configs: [
                (leafID: leafA, cpu: 4.5, mb: 120),
                (leafID: leafA, cpu: 1.5, mb: 40),
                (leafID: leafB, cpu: 2.0, mb: 64),
            ])
                + [
                    .fixture(
                        worktreeID: otherWorktreeID,
                        leafID: UUID(),
                        cpuPercent: 9.0,
                        residentMB: 512
                    ),
                ]
        )

        expectSample(samples[leafA], cpu: 6.0, residentMB: 160, processCount: 2)
        expectSample(samples[leafB], cpu: 2.0, residentMB: 64)
        #expect(samples.count == 2)
    }

    @Test("samples fall back to path matching when worktree ids are unavailable")
    func samplesFallbackToPathMatchingWhenWorktreeIDIsUnavailable() {
        let leafID = UUID()

        let samples = WorkspacePaneResourceModel.testSamples(
            selectedWorktreePath:
            "/Users/wesm/.ghosthub/worktrees/ghosthub-feature",
            processes: [
                .fixture(
                    leafID: leafID,
                    workingDirectory:
                    "/Users/wesm/.ghosthub/worktrees/"
                        + "ghosthub-feature/subdir",
                    cpuPercent: 3.0,
                    residentMB: 96
                ),
                .fixture(
                    workingDirectory:
                    "/Users/wesm/.ghosthub/worktrees/other",
                    cpuPercent: 1.0,
                    residentMB: 32
                ),
            ]
        )

        expectSample(samples[leafID], cpu: 3.0, residentMB: 96)
        #expect(samples.count == 1)
    }
}

// MARK: - Test Helpers

extension WorkspacePaneResourceModel {
    fileprivate static func testSamples(
        selectedWorktreeID: UUID = UUID(),
        selectedWorktreePath: String = "/mock/worktree/path",
        processes: [WorkspaceProcessResource]
    ) -> [UUID: WorkspaceResourceSample] {
        samples(
            selectedWorktreeID: selectedWorktreeID,
            selectedWorktreePath: selectedWorktreePath,
            processes: processes
        )
    }
}

private func expectSample(
    _ sample: WorkspaceResourceSample?,
    cpu: Double,
    residentMB: Int,
    processCount: Int? = nil,
    sourceLocation: SourceLocation = #_sourceLocation
) {
    guard let sample else {
        Issue.record("Expected sample to exist", sourceLocation: sourceLocation)
        return
    }
    #expect(
        sample.cpuPercent == cpu,
        sourceLocation: sourceLocation
    )
    #expect(
        sample.residentMB == residentMB,
        sourceLocation: sourceLocation
    )
    if let processCount {
        #expect(
            sample.processCount == processCount,
            sourceLocation: sourceLocation
        )
    }
}

extension [WorkspaceProcessResource] {
    fileprivate static func fixtures(
        forWorktree worktreeID: UUID,
        configs: [(leafID: UUID, cpu: Double, mb: Int)]
    ) -> Self {
        configs.map {
            .fixture(
                worktreeID: worktreeID,
                leafID: $0.leafID,
                cpuPercent: $0.cpu,
                residentMB: $0.mb
            )
        }
    }
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
