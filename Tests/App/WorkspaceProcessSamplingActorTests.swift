import Foundation
import Testing
@testable import GhosthubApp

private let testAppPID: pid_t = 100

struct WorkspaceProcessSamplingActorTests {
    @Test("generation-aware sampling drops stale results without advancing the CPU baseline")
    func generationAwareSamplingDropsStaleResultWithoutAdvancingBaseline() async {
        let tracker = SamplingGenerationTracker()
        let allowFirstSampleToFinish = DispatchSemaphore(value: 0)
        let lock = NSLock()
        var callIndex = 0
        let firstSampleDidStart = LockedValue(false)

        let monitor = makeTestMonitor(usage: { pid in
            guard pid == testAppPID else { return nil }
            lock.lock()
            callIndex += 1
            let currentCall = callIndex
            if currentCall == 1 {
                firstSampleDidStart.store(true)
            }
            lock.unlock()

            if currentCall == 1 {
                allowFirstSampleToFinish.wait()
                return (1_000_000_000, 50)
            }

            return (2_000_000_000, 50)
        })
        let actor = WorkspaceProcessSamplingActor(monitor: monitor)

        tracker.store(1)
        async let staleSnapshot = actor.testSample(
            at: 1, generation: 1, tracker: tracker
        )

        await waitUntil {
            firstSampleDidStart.load()
        }

        tracker.store(2)
        async let freshSnapshot = actor.testSample(
            at: 2, generation: 2, tracker: tracker
        )

        allowFirstSampleToFinish.signal()

        let firstResult = await staleSnapshot
        let secondResult = await freshSnapshot

        #expect(firstResult == nil)
        #expect(secondResult?.aggregate.cpuPercent == 0)
    }

    @Test(
        "generation-aware sampling does not commit when the generation flips before compare-and-store"
    )
    func generationAwareSamplingDoesNotCommitWhenGenerationFlipsBeforeCommit() async {
        var tracker: SamplingGenerationTracker!
        tracker = SamplingGenerationTracker(beforeCompareAndStore: {
            tracker.store(2)
        })
        tracker.store(1)

        let actor = WorkspaceProcessSamplingActor(
            monitor: makeTestMonitor()
        )

        let stale = await actor.testSample(
            at: 1, generation: 1, tracker: tracker
        )
        let fresh = await actor.testSample(
            at: 2, generation: 2, tracker: tracker
        )

        #expect(stale == nil)
        #expect(fresh?.aggregate.cpuPercent == 0)
    }

    @Test("sampling actor returns snapshots from the wrapped monitor")
    func samplingActorReturnsSnapshotsFromWrappedMonitor() async {
        let shellPID: pid_t = 200
        let worktreeID = UUID()
        let leafID = UUID()
        let monitor = makeTestMonitor(
            children: { pid in
                switch pid {
                case testAppPID: return []
                case shellPID: return []
                default: return []
                }
            },
            usage: { pid in
                switch pid {
                case testAppPID: return (1_000_000_000, 48)
                case shellPID: return (2_000_000_000, 64)
                default: return nil
                }
            }
        )
        let actor = WorkspaceProcessSamplingActor(monitor: monitor)

        let snapshot = await actor.testSample(
            at: 1,
            roots: [
                WorkspaceProcessRoot(
                    pid: shellPID,
                    worktreeID: worktreeID,
                    leafID: leafID
                ),
            ]
        )

        #expect(snapshot?.aggregate.residentMB == 112)
        #expect(
            snapshot?.processes.contains {
                $0.worktreeID == worktreeID
                    && $0.leafID == leafID
                    && $0.sample.residentMB == 64
            } == true
        )
    }

    @Test("default usage closure follows a custom app pid")
    func defaultUsageClosureFollowsCustomAppPID() async {
        let customPID: pid_t = 999
        let monitor = makeTestMonitor(appPID: customPID)
        let actor = WorkspaceProcessSamplingActor(monitor: monitor)

        let snapshot = await actor.testSample(at: 1)

        #expect(snapshot?.aggregate.processCount == 1)
        #expect(snapshot?.aggregate.residentMB == 50)
    }

    @Test("sampling actor keeps one monitor history across samples")
    func samplingActorKeepsMonitorHistoryAcrossSamples() async {
        var cpuValue: UInt64 = 1_000_000_000
        let monitor = makeTestMonitor(usage: { pid in
            guard pid == testAppPID else { return nil }
            defer { cpuValue += 1_000_000_000 }
            return (cpuValue, 50)
        })
        let actor = WorkspaceProcessSamplingActor(monitor: monitor)

        _ = await actor.testSample(at: 1)
        let second = await actor.testSample(at: 2)

        #expect(second?.aggregate.processCount == 1)
        #expect((second?.aggregate.cpuPercent ?? 0) > 0)
    }
}

// MARK: - Fixture Helpers

private extension WorkspaceProcessSamplingActor {
    func testSample(
        at timeSeconds: TimeInterval,
        roots: [WorkspaceProcessRoot] = [],
        generation: UInt64 = 1,
        tracker: SamplingGenerationTracker? = nil
    ) -> ProcessTreeSnapshot? {
        let now = Date(timeIntervalSince1970: timeSeconds)
        if let tracker {
            return sample(
                roots: roots,
                now: now,
                generation: generation,
                generationTracker: tracker
            )
        } else {
            return sample(
                roots: roots,
                now: now
            )
        }
    }
}

private func makeTestMonitor(
    appPID: pid_t = testAppPID,
    children: @escaping (pid_t) -> [pid_t] = { _ in [] },
    usage: ((pid_t) -> (UInt64, Int)?)? = nil
) -> ProcessResourceMonitor {
    let resolvedUsage = usage ?? { pid in
        pid == appPID ? (1_000_000_000, 50) : nil
    }
    return ProcessResourceMonitor(
        rootPIDProvider: { appPID },
        childProcessProvider: { pid in children(pid) },
        processUsageProvider: { pid in resolvedUsage(pid) }
    )
}
