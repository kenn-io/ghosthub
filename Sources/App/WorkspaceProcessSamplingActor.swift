import Foundation

final class SamplingGenerationTracker: @unchecked Sendable {
    private let lock = NSLock()
    private var latestGeneration: UInt64 = 0
    private let beforeCompareAndStore: (() -> Void)?

    init(
        beforeCompareAndStore: (() -> Void)? = nil
    ) {
        self.beforeCompareAndStore = beforeCompareAndStore
    }

    func store(_ generation: UInt64) {
        lock.lock()
        latestGeneration = generation
        lock.unlock()
    }

    func load() -> UInt64 {
        lock.lock()
        let generation = latestGeneration
        lock.unlock()
        return generation
    }

    func compareAndStoreIfCurrent(
        _ expected: UInt64,
        commit: () -> Void
    ) -> Bool {
        beforeCompareAndStore?()
        lock.lock()
        defer { lock.unlock() }
        guard latestGeneration == expected else {
            return false
        }
        commit()
        return true
    }
}

actor WorkspaceProcessSamplingActor {
    private let monitor: ProcessResourceMonitor
    private var state = ProcessSamplingState()

    init(
        monitor: ProcessResourceMonitor = ProcessResourceMonitor()
    ) {
        self.monitor = monitor
    }

    func sample(
        roots: [WorkspaceProcessRoot],
        now: Date = .now
    ) -> ProcessTreeSnapshot? {
        let result = monitor.sample(
            roots: roots,
            now: now,
            state: state
        )
        state = result.nextState
        return result.snapshot
    }

    func sample(
        roots: [WorkspaceProcessRoot],
        now: Date = .now,
        generation: UInt64,
        generationTracker: SamplingGenerationTracker
    ) -> ProcessTreeSnapshot? {
        guard generationTracker.load() == generation else {
            return nil
        }

        let result = monitor.sample(
            roots: roots,
            now: now,
            state: state
        )

        guard generationTracker.compareAndStoreIfCurrent(
            generation,
            commit: { state = result.nextState }
        ) else {
            return nil
        }
        return result.snapshot
    }
}
