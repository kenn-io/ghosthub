import Foundation
import GhosthubWorkspace

@MainActor
final class ResourceSamplingCoordinator {
    typealias RootsProvider = @MainActor @Sendable () -> [WorkspaceProcessRoot]
    typealias SnapshotHandler = @MainActor @Sendable (
        ProcessTreeSnapshot?,
        [WorkspaceProcessRoot]
    ) -> Void
    typealias Sample = @Sendable (
        [WorkspaceProcessRoot],
        UInt64,
        SamplingGenerationTracker
    ) async -> ProcessTreeSnapshot?

    private let sample: Sample
    private let generationTracker: SamplingGenerationTracker
    private let rootsProvider: RootsProvider
    private let snapshotHandler: SnapshotHandler
    private var monitoringTask: Task<Void, Never>?
    private var pendingRefreshTask: Task<Void, Never>?
    private var samplingTask: Task<Void, Never>?
    private var samplingGeneration: UInt64 = 0

    convenience init(
        rootsProvider: @escaping RootsProvider,
        snapshotHandler: @escaping SnapshotHandler
    ) {
        let sampler = WorkspaceProcessSamplingActor()
        self.init(
            sample: { roots, generation, generationTracker in
                await sampler.sample(
                    roots: roots,
                    generation: generation,
                    generationTracker: generationTracker
                )
            },
            generationTracker: SamplingGenerationTracker(),
            rootsProvider: rootsProvider,
            snapshotHandler: snapshotHandler
        )
    }

    init(
        sample: @escaping Sample,
        generationTracker: SamplingGenerationTracker,
        rootsProvider: @escaping RootsProvider,
        snapshotHandler: @escaping SnapshotHandler
    ) {
        self.sample = sample
        self.generationTracker = generationTracker
        self.rootsProvider = rootsProvider
        self.snapshotHandler = snapshotHandler
    }

    deinit {
        monitoringTask?.cancel()
        pendingRefreshTask?.cancel()
        samplingTask?.cancel()
    }

    var isRunning: Bool {
        monitoringTask != nil
    }

    func cancel() {
        monitoringTask?.cancel()
        monitoringTask = nil
        pendingRefreshTask?.cancel()
        pendingRefreshTask = nil
        samplingTask?.cancel()
        samplingTask = nil
    }

    func restartLoop(plan: ResourceMonitoringPlan) {
        monitoringTask?.cancel()
        pendingRefreshTask?.cancel()
        pendingRefreshTask = nil
        if plan.sampleImmediately {
            sampleNow()
        }
        monitoringTask = Task { @MainActor [weak self] in
            while let self, !Task.isCancelled {
                do {
                    try await Task.sleep(
                        for: .seconds(plan.refreshIntervalSeconds)
                    )
                } catch {
                    break
                }
                guard !Task.isCancelled else {
                    break
                }
                sampleNow()
            }
        }
    }

    func scheduleRefresh(
        after delaySeconds: TimeInterval
    ) {
        pendingRefreshTask?.cancel()
        pendingRefreshTask = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(
                    for: .milliseconds(Int(delaySeconds * 1_000))
                )
            } catch {
                return
            }
            guard let self, !Task.isCancelled else {
                return
            }
            sampleNow()
        }
    }

    func sampleNow() {
        let roots = rootsProvider()
        samplingGeneration += 1
        let generation = samplingGeneration
        generationTracker.store(generation)
        samplingTask?.cancel()
        samplingTask = Task { [weak self, roots, generation] in
            guard let self else {
                return
            }
            guard !Task.isCancelled else {
                return
            }
            let snapshot = await sample(
                roots,
                generation,
                generationTracker
            )
            guard !Task.isCancelled,
                  generationTracker.load() == generation
            else {
                return
            }
            snapshotHandler(snapshot, roots)
        }
    }
}
