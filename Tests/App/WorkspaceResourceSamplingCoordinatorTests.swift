import Foundation
import GhosthubWorkspace
import Testing
@testable import GhosthubApp

@MainActor
struct ResourceSamplingCoordinatorTests {
    @Test("schedule refresh cancels the earlier delayed refresh")
    func scheduleRefreshCancelsEarlierDelay() async {
        let ctx = TestContext(pids: [41])
        defer { ctx.coordinator.cancel() }

        let recorder = ctx.recorder
        ctx.coordinator.scheduleRefresh(after: 0.2)
        // Replace the pending task before yielding so scheduler load cannot
        // let the first refresh fire before the cancellation under test.
        ctx.coordinator.scheduleRefresh(after: 0.01)

        await waitUntilMainActor {
            recorder.handledCount == 1
        }
        try? await Task.sleep(for: .milliseconds(250))

        #expect(recorder.sampleCount == 1)
        #expect(recorder.handledCount == 1)
        #expect(recorder.lastHandledRootPIDs == [41])
    }

    @Test("restart loop samples immediately when the plan requires it")
    func restartLoopSamplesImmediately() async {
        let ctx = TestContext(pids: [77])
        defer { ctx.coordinator.cancel() }

        let recorder = ctx.recorder
        ctx.coordinator.restartLoop(
            plan: ResourceMonitoringPlan(
                refreshIntervalSeconds: 3600,
                sampleImmediately: true
            )
        )

        await waitUntilMainActor {
            recorder.handledCount == 1
        }

        #expect(recorder.sampleCount == 1)
        #expect(recorder.lastHandledRootPIDs == [77])
    }

    @Test("restart loop defers the first sample when the plan disables immediate sampling")
    func restartLoopDefersFirstSample() async {
        let ctx = TestContext(pids: [88])
        defer { ctx.coordinator.cancel() }

        ctx.coordinator.restartLoop(
            plan: ResourceMonitoringPlan(
                refreshIntervalSeconds: 1,
                sampleImmediately: false
            )
        )

        try? await Task.sleep(for: .milliseconds(100))

        #expect(ctx.recorder.sampleCount == 0)
        #expect(ctx.recorder.handledCount == 0)
    }

    @Test("cancel stops a pending delayed refresh")
    func cancelStopsPendingDelayedRefresh() async {
        let ctx = TestContext(pids: [99])
        defer { ctx.coordinator.cancel() }

        ctx.coordinator.scheduleRefresh(after: 0.2)
        ctx.coordinator.cancel()
        try? await Task.sleep(for: .milliseconds(250))

        #expect(ctx.recorder.sampleCount == 0)
        #expect(ctx.recorder.handledCount == 0)
    }
}

// MARK: - Test Fixtures

@MainActor
private final class TestContext {
    let recorder: SamplingRecorder
    let coordinator: ResourceSamplingCoordinator

    init(pids: [pid_t]) {
        let recorder = SamplingRecorder()
        self.recorder = recorder
        let roots = pids.map {
            WorkspaceProcessRoot(
                pid: $0, worktreeID: UUID(), leafID: nil
            )
        }
        coordinator = ResourceSamplingCoordinator(
            sample: { roots, _, _ in
                recorder.recordSample(roots)
                return nil
            },
            generationTracker: SamplingGenerationTracker(),
            rootsProvider: { roots },
            snapshotHandler: { _, roots in
                recorder.recordHandled(roots)
            }
        )
    }
}

private final class SamplingRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var sampledRootPIDs: [[pid_t]] = []
    private var handledRootPIDsStorage: [[pid_t]] = []

    var sampleCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return sampledRootPIDs.count
    }

    var handledCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return handledRootPIDsStorage.count
    }

    var lastHandledRootPIDs: [pid_t] {
        lock.lock()
        defer { lock.unlock() }
        return handledRootPIDsStorage.last ?? []
    }

    func recordSample(_ roots: [WorkspaceProcessRoot]) {
        lock.lock()
        sampledRootPIDs.append(roots.map(\.pid))
        lock.unlock()
    }

    func recordHandled(_ roots: [WorkspaceProcessRoot]) {
        lock.lock()
        handledRootPIDsStorage.append(roots.map(\.pid))
        lock.unlock()
    }
}
