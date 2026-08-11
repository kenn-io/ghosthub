import Foundation

enum SessionReconnectDecision: Sendable {
    case retry
    case stop
}

@MainActor
final class SessionReconnectSupervisor {
    typealias Attempt = @MainActor @Sendable () async -> SessionReconnectDecision
    typealias Sleep = @Sendable (Duration) async throws -> Void

    nonisolated static let defaultProbeDeadline = Duration.seconds(15)
    private nonisolated static let defaultIntervals = [
        Duration.seconds(1),
        .seconds(2),
        .seconds(4),
        .seconds(8),
        .seconds(16),
        .seconds(30),
    ]

    private enum Phase {
        case idle
        case probing
        case waiting
    }

    private enum AttemptRace: Sendable {
        case decision(SessionReconnectDecision)
        case deadline
        case cancelled
    }

    private let intervals: [Duration]
    private let probeDeadline: Duration
    private let sleep: Sleep
    private let probeSleep: Sleep
    private(set) var isRunning = false
    private var phase = Phase.idle
    private var generation = UUID()
    private var task: Task<Void, Never>?
    private var waitTask: Task<Void, Error>?

    init(
        intervals: [Duration] = defaultIntervals,
        probeDeadline: Duration = defaultProbeDeadline,
        sleep: @escaping Sleep = { try await Task.sleep(for: $0) },
        probeSleep: @escaping Sleep = { try await Task.sleep(for: $0) }
    ) {
        precondition(!intervals.isEmpty)
        self.intervals = intervals
        self.probeDeadline = probeDeadline
        self.sleep = sleep
        self.probeSleep = probeSleep
    }

    func start(attempt: @escaping Attempt) {
        cancel()
        let generation = UUID()
        self.generation = generation
        isRunning = true
        phase = .probing
        task = Task { [weak self] in
            await self?.run(generation: generation, attempt: attempt)
        }
    }

    func reconnectNow() {
        guard isRunning, phase == .waiting else { return }
        waitTask?.cancel()
    }

    func cancel() {
        generation = UUID()
        task?.cancel()
        waitTask?.cancel()
        task = nil
        waitTask = nil
        phase = .idle
        isRunning = false
    }

    nonisolated static func remainingDelay(
        interval: Duration,
        elapsed: Duration
    ) -> Duration {
        max(.zero, interval - elapsed)
    }

    private func run(
        generation: UUID,
        attempt: @escaping Attempt
    ) async {
        var intervalIndex = 0
        while isCurrent(generation) {
            phase = .probing
            let clock = ContinuousClock()
            let started = clock.now
            let decision = await runAttempt(attempt)
            guard isCurrent(generation) else { return }
            switch decision {
            case .stop:
                finish(generation)
                return
            case .retry:
                break
            }

            let interval = intervals[min(intervalIndex, intervals.count - 1)]
            intervalIndex += 1
            let delay = Self.remainingDelay(
                interval: interval,
                elapsed: started.duration(to: clock.now)
            )
            phase = .waiting
            let sleep = sleep
            let waitTask = Task { try await sleep(delay) }
            self.waitTask = waitTask
            _ = await waitTask.result
            guard isCurrent(generation) else { return }
            self.waitTask = nil
        }
    }

    private func runAttempt(
        _ attempt: @escaping Attempt
    ) async -> SessionReconnectDecision {
        let deadline = probeDeadline
        let probeSleep = probeSleep
        return await withTaskGroup(of: AttemptRace.self) { group in
            group.addTask {
                await .decision(attempt())
            }
            group.addTask {
                do {
                    try await probeSleep(deadline)
                    return .deadline
                } catch {
                    return .cancelled
                }
            }

            let first = await group.next() ?? .cancelled
            group.cancelAll()
            while await group.next() != nil {}
            switch first {
            case let .decision(decision):
                return decision
            case .deadline:
                return .retry
            case .cancelled:
                return .stop
            }
        }
    }

    private func isCurrent(_ generation: UUID) -> Bool {
        self.generation == generation && !Task.isCancelled
    }

    private func finish(_ generation: UUID) {
        guard self.generation == generation else { return }
        task = nil
        waitTask = nil
        phase = .idle
        isRunning = false
    }
}
